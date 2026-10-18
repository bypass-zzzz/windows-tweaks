const { app, BrowserWindow, ipcMain, shell, dialog } = require('electron');
const { spawn, exec } = require('child_process');
const path = require('path');
const fs = require('fs');
const http = require('http');

let updater = null;
try { updater = require('electron-updater').autoUpdater; } catch (_) { updater = null; }
let updateBusy = false;
let updateCheckedOnce = false;

let mainWindow = null;
let splashWindow = null;
let psServer = null;
// Set from the backend's stdout marker line; gates every HTTP call from the renderer.
let apiToken = '';
let stdoutCarry = '';
let backendReady = false;
// ─── Backend crash recovery ───
// A backend that was serving traffic and then died used to leave the app dead
// until it was relaunched: every API call failed and nothing retried. It is now
// restarted with a bounded, widening delay. backendEverReady distinguishes "died
// mid-session" (recoverable) from "never started" (a config/UAC problem, which
// keeps the existing message and retry budget of pollBackend).
let backendEverReady = false;
let backendStopping = false;
let pendingRestartNotice = false;
let backendRestartIndex = 0;
let backendRestartTimer = null;
let backendStableTimer = null;
const BACKEND_RESTART_DELAYS_MS = [1000, 3000, 9000];
// A backend that stays up this long is healthy again, so the next crash gets the
// full retry budget rather than inheriting it from an earlier crash loop.
const BACKEND_STABLE_MS = 30000;
// True once the app is on its way out; suppresses restarts and update retries.
let appQuitting = false;
// True once the splash has dissolved and the real UI has been shown. The main
// window is created hidden at startup, so the second-instance handler must not
// raise it before this flips (see the second-instance handler).
let uiRevealed = false;
const PORT = 48921;
const FALLBACK_PORT = 48922;
// Whichever port the backend actually bound. server.ps1 retries on
// FALLBACK_PORT when PORT is already taken, so this is not always PORT.
let activePort = PORT;
function serverScriptPath() {
    // Packaged builds unpack server.ps1 next to the asar — powershell.exe
    // cannot read files from inside app.asar, so never point it there.
    if (app.isPackaged) {
        const unpacked = path.join(process.resourcesPath, 'app.asar.unpacked', 'server.ps1');
        try { if (fs.existsSync(unpacked)) return unpacked; } catch (_) {}
    }
    return path.join(__dirname, 'server.ps1');
}
const PUBLIC_DIR = path.join(__dirname, 'public');

// Cool rotating status lines shown under the progress bar
const COOL_LINES = [
    'Waking the engine…',
    'Warming up the invariant TSC…',
    'Polishing every pixel…',
    'Tuning TCP for zero-lag packets…',
    'Locking the kernel in RAM…',
    'Evicting telemetry gremlins…',
    'Calibrating the 1.1.1.1 ping stream…',
    'Charging the liquid glass…',
];

function sendProgress(pct, status) {
    if (splashWindow && !splashWindow.isDestroyed()) {
        try { splashWindow.webContents.send('loading-progress', { pct, status }); } catch (_) {}
    }
}

// ─── Require Administrator (tweaks touch BCD / registry / drivers) ───
// The packaged exe also ships with a requireAdministrator manifest, but this
// covers the portable build and dev runs, and re-prompts if UAC was skipped.
function isAdminSync() {
    try {
        require('child_process').execSync('net session >nul 2>&1', { stdio: 'ignore' });
        return true;
    } catch (_) { return false; }
}

function relaunchAsAdmin() {
    // Always use process.execPath — require('electron') inside Electron's main
    // process returns the API namespace object, not a file path, so it would
    // produce Start-Process "[object Object]" which silently fails.
    const exe = process.execPath;
    const args = app.isPackaged ? '' : `"${app.getAppPath()}"`;
    const cmd = args
        ? `Start-Process -FilePath "${exe}" -ArgumentList '${args}' -Verb RunAs`
        : `Start-Process -FilePath "${exe}" -Verb RunAs`;

    // This process must hold the single-instance lock until the elevated copy
    // is on its way: release it before spawning and a burst of launches could
    // each win the freshly freed lock and spawn a UAC prompt of their own.
    // Start-Process only returns once UAC was answered (or throws if it was
    // denied), so the launcher's exit is the signal to let go and quit.
    let handedOff = false;
    const release = () => {
        if (handedOff) return;
        handedOff = true;
        try { app.releaseSingleInstanceLock(); } catch (_) {}
        app.quit();
    };

    try {
        const child = spawn('powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
            { windowsHide: true, stdio: 'ignore' }
        );
        child.on('exit', release);
        child.on('error', release);
        // Never wedge on an ignored UAC prompt: give up waiting after 60s.
        const cap = setTimeout(release, 60000);
        if (cap.unref) cap.unref();
    } catch (_) {
        release();
    }
}

// ─── Instant Splash (shows immediately, no waiting) ───
function createSplash() {
    splashWindow = new BrowserWindow({
        width: 460,
        height: 660,
        title: 'Windows Tweaks',
        icon: path.join(PUBLIC_DIR, 'assets', 'logo.jpg'),
        backgroundColor: '#000000',
        frame: false,
        titleBarStyle: 'hidden',
        resizable: false,
        minimizable: false,
        maximizable: false,
        center: true,
        show: true,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            contextIsolation: true,
            nodeIntegration: false,
        },
    });

    splashWindow.loadFile(path.join(PUBLIC_DIR, 'splash.html'));
    splashWindow.on('closed', () => { splashWindow = null; });
}

// ─── Main Window (hidden until backend + UI ready) ───
function createMainWindow() {
    mainWindow = new BrowserWindow({
        width: 1360,
        height: 880,
        minWidth: 1100,
        minHeight: 700,
        title: 'Windows Tweaks',
        icon: path.join(PUBLIC_DIR, 'assets', 'logo.jpg'),
        backgroundColor: '#000000',
        frame: false,
        titleBarStyle: 'hidden',
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            contextIsolation: true,
            nodeIntegration: false,
        },
        show: false,
        resizable: true,
    });

    mainWindow.on('closed', () => {
        killBackend();
        mainWindow = null;
    });
}

// ─── Hot-reload: theme/code edits apply instantly, no relaunch ───
let reloadDebounce = null;
function watchPublic() {
    try {
        fs.watch(PUBLIC_DIR, { recursive: true }, (_event, filename) => {
            if (!filename || !/\.(css|js|html)$/i.test(filename)) return;
            clearTimeout(reloadDebounce);
            reloadDebounce = setTimeout(() => {
                try {
                    if (/splash\.html$/i.test(filename)) {
                        if (splashWindow && !splashWindow.isDestroyed()) splashWindow.reload();
                        return;
                    }
                    if (mainWindow && !mainWindow.isDestroyed()) {
                        mainWindow.webContents.reloadIgnoringCache().catch(() => {});
                    }
                } catch (_) {}
            }, 250);
        });
    } catch (_) {
        // fs.watch recursive unsupported — hot-reload silently disabled
    }
}

// ─── PowerShell Backend (with progress) ───
// Frees our ports first so a crashed/duplicate run can't starve the backend.
function freePorts(ports, done) {
    let pending = ports.length;
    if (!pending) return done();
    ports.forEach((port) => {
        exec(`netstat -ano | findstr :${port}`, (err, stdout) => {
            const kills = [];
            if (stdout) {
                stdout.trim().split('\n').forEach(line => {
                    const parts = line.trim().split(/\s+/);
                    const pid = parts[parts.length - 1];
                    // Only kill LISTENING sockets on 127.0.0.1 — never our own PID
                    if (pid && !isNaN(pid) && /LISTENING/i.test(line) && Number(pid) !== process.pid) {
                        kills.push(new Promise((res) => exec(`taskkill /PID ${pid} /F`, () => res())));
                    }
                });
            }
            Promise.all(kills).then(() => { if (--pending === 0) done(); });
        });
    });
}

// Tells the renderer what the backend is doing. The UI re-resolves its base URL
// and API token on 'ready': a restarted backend prints a new token, and on a
// port race it can land on the fallback port, so the old pair can be both stale
// and wrong.
function notifyBackendStatus(state, message) {
    try {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send('backend-status', { state, message, port: activePort });
        }
    } catch (_) {}
    console.log('[PS Backend]', state, '-', message || '');
}

// Restart the backend after an unexpected exit, with a bounded number of
// widening delays (1s, 3s, 9s). Gives up loudly rather than crash-looping
// forever; a manual relaunch is always still available.
function scheduleBackendRestart(reason) {
    if (appQuitting || backendStopping || backendRestartTimer) return;
    // From the moment the process exits, its token is dead. Clearing it here
    // makes get-api-token wait for the replacement instead of handing the
    // renderer a value that is certain to 403.
    apiToken = '';
    stdoutCarry = '';
    if (backendRestartIndex >= BACKEND_RESTART_DELAYS_MS.length) {
        notifyBackendStatus('failed', `Backend stopped (${reason}) and could not be restarted. Relaunch the app.`);
        return;
    }
    const delay = BACKEND_RESTART_DELAYS_MS[backendRestartIndex];
    backendRestartIndex++;
    notifyBackendStatus('restarting', `Backend stopped (${reason}) - restarting in ${Math.round(delay / 1000)}s (attempt ${backendRestartIndex} of ${BACKEND_RESTART_DELAYS_MS.length}).`);
    backendRestartTimer = setTimeout(() => {
        backendRestartTimer = null;
        if (appQuitting || backendStopping) return;
        pendingRestartNotice = true;
        // onReady is a no-op here: the UI is already on screen, and the
        // backend-status event tells the renderer to reconnect.
        startBackend(sendProgress, () => {});
    }, delay);
    if (backendRestartTimer.unref) backendRestartTimer.unref();
}

function startBackend(onProgress, onReady) {
    onProgress(10, COOL_LINES[0]);
    backendReady = false;
    activePort = PORT;

    const script = serverScriptPath();
    try {
        if (!fs.existsSync(script)) {
            console.error('[PS Backend] script missing:', script);
            onProgress(20, 'Backend script missing — reinstall the app.');
            onReady();
            return;
        }
    } catch (_) {}

    freePorts([PORT, FALLBACK_PORT], () => {
        const psArgs = [
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', script,
            '-NoBrowser'
        ];

        psServer = spawn('powershell.exe', psArgs, {
            windowsHide: true,
            stdio: ['ignore', 'pipe', 'pipe']
        });

        onProgress(16, COOL_LINES[1]);

        psServer.stdout.on('data', (data) => {
            const text = data.toString();
            console.log('[PS Backend]', text.trim());
            // The backend prints its per-process API token on a marker line. Lift it
            // off stdout here so the renderer can authenticate; without it every
            // request is refused. A chunk can split the marker across reads, so keep
            // a small carry buffer and only clear it after a full 44-char match
            // (Base64 of 32 bytes = exactly 44 chars including any = padding).
            stdoutCarry = (stdoutCarry + text).slice(-512);
            const m = stdoutCarry.match(/__WT_TOKEN__([A-Za-z0-9+/=]{44})/);
            if (m) { apiToken = m[1]; stdoutCarry = ''; }
        });

        psServer.stderr.on('data', (data) => {
            console.error('[PS Backend ERR]', data.toString().trim());
        });

        psServer.on('exit', (code) => {
            console.log('[PS Backend] Exited with code', code);
            psServer = null;
            if (!backendReady) {
                onProgress(30, 'Backend failed to start — try relaunching as Administrator.');
            }
            // Died after having served traffic: that is a crash, not a failed
            // start, and the app can recover from it without a relaunch.
            if (backendEverReady) {
                scheduleBackendRestart(`exit code ${code}`);
            }
        });

        pollBackend(onProgress, onReady);
    });
}

function pollBackend(onProgress, onReady) {
    let attempts = 0;
    const MAX_ATTEMPTS = 30;
    let readyFired = false;
    const fireReady = () => {
        if (readyFired) return;
        readyFired = true;
        backendReady = true;
        backendEverReady = true;
        // Re-arm the retry budget once the backend has proven it can stay up,
        // so one flaky crash loop cannot exhaust it for the rest of the session.
        clearTimeout(backendStableTimer);
        backendStableTimer = setTimeout(() => { backendRestartIndex = 0; }, BACKEND_STABLE_MS);
        if (backendStableTimer.unref) backendStableTimer.unref();
        // The first start reveals the UI through onReady. A restart does not: it
        // tells the renderer its old token and possibly its old port are stale.
        if (pendingRestartNotice) {
            pendingRestartNotice = false;
            notifyBackendStatus('ready', 'Backend restarted - reconnected.');
        }
        onReady();
    };

    const tick = () => {
        attempts++;
        const pct = Math.round(18 + (attempts / MAX_ATTEMPTS) * 66);
        onProgress(pct, COOL_LINES[attempts % COOL_LINES.length]);

        // The backend binds PORT unless it is already taken, in which case
        // server.ps1 retries on FALLBACK_PORT. Probe both within the same tick and
        // remember which one answered, so a fallback backend is detected on the
        // first tick instead of after all 30 attempts (~15s of stalled splash).
        const ports = [PORT, FALLBACK_PORT];
        let pending = ports.length;
        let settled = false;

        const retryOrGiveUp = () => {
            if (settled) return;
            settled = true;
            if (attempts >= MAX_ATTEMPTS) {
                fireReady(); // show UI anyway; API calls will retry
            } else {
                setTimeout(tick, 500);
            }
        };

        ports.forEach(port => {
            let finished = false;
            const finish = (ready) => {
                if (finished) return;
                finished = true;
                if (ready) {
                    // The ports are probed in preference order and settled is
                    // shared, so the preferred port wins even when both answer
                    // within the same tick (a stale backend on PORT would only
                    // 403, but the winner must not depend on that).
                    if (settled) return;
                    activePort = port;
                    settled = true;
                    fireReady();
                } else if (--pending === 0) {
                    retryOrGiveUp();
                }
            };

            const req = http.get({
                hostname: '127.0.0.1',
                port,
                path: '/api/status',
                timeout: 1000,
                headers: apiToken ? { 'X-WT-Token': apiToken } : {}
            }, (res) => {
                res.resume(); // drain
                // Only 200 means backend is authenticated and ready. 403 means it's
                // listening but the token hasn't been received yet — keep polling.
                finish(res.statusCode === 200);
            });
            // A port that accepts the connection but never answers must not wedge
            // the loop: `pending` would never reach zero and the tick would never
            // retry. destroy() surfaces an error, which settles this probe.
            req.on('timeout', () => req.destroy());
            req.on('error', () => finish(false));
        });
    };
    setTimeout(tick, 500);
}

function killBackend() {
    // Deliberate shutdown: never restart what we just killed (the window was
    // closed, or the app is quitting). Repeat calls are no-ops.
    if (backendStopping && !psServer) return;
    backendStopping = true;
    clearTimeout(backendRestartTimer);
    backendRestartTimer = null;
    clearTimeout(backendStableTimer);
    backendStableTimer = null;
    if (psServer) {
        try { psServer.kill('SIGTERM'); } catch (_) {}
        // Kill any leftover listeners on both ports; guard against PID 0 and
        // our own PID which would kill the Electron process itself.
        [PORT, FALLBACK_PORT].forEach(port => {
            exec(`netstat -ano | findstr :${port}`, (err, stdout) => {
                if (!stdout) return;
                stdout.trim().split('\n').forEach(line => {
                    if (!/LISTENING/i.test(line)) return;
                    const parts = line.trim().split(/\s+/);
                    const pid = Number(parts[parts.length - 1]);
                    if (pid && pid !== 0 && pid !== process.pid) {
                        exec(`taskkill /PID ${pid} /F`);
                    }
                });
            });
        });
        psServer = null;
    }
}

// ─── Auto-Update (GitHub Releases — no more manual Setup downloads) ───
function updaterNotify(status, message) {
    try {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send('updater-status', { status, message });
        }
    } catch (_) {}
    console.log('[Updater]', status, message || '');
}

let autoUpdateInitialized = false;

// The public download page, named whenever a check dies for good. The release
// feed itself is public and token-free (tools/test-release-feed.ps1 enforces
// that), so a failure is a transient network/config problem - either way the
// releases page always carries the newest installer.
const UPDATE_MANUAL_URL = 'https://github.com/bypass-zzzz/windows-tweaks/releases/latest';

// Terminal-failure wording. The hint is added only where a failure is truly
// final (the auto check exhausted its retries, or the user pressed the button
// themselves); retry-phase errors stay plain so a blip a retry may fix does
// not spam the manual-download advice.
function withManualUpdateHint(message) {
    const text = String(message || 'Update failed.');
    return text.includes(UPDATE_MANUAL_URL) ? text : `${text} If this keeps failing, download the latest release manually: ${UPDATE_MANUAL_URL}`;
}

// A failed check reaches the renderer twice in the real app (the promise
// rejection and the 'error' event); both routes come through here so the hint
// logic lives in exactly one place.
function notifyUpdateFailure(e) {
    const raw = (e && e.message) || 'Update check failed.';
    updaterNotify('error', updateStage === 'check-manual' ? withManualUpdateHint(raw) : raw);
}

// Automatic checks used to be strictly one-shot: updateCheckedOnce was set
// before the call, so a single network blip at launch meant no update
// notification for the rest of the session. A failed *check* now retries twice
// with a widening delay; a manual check always starts fresh and cancels any
// pending retry (see checkForUpdates).
const UPDATE_RETRY_DELAYS_MS = [15000, 45000];
let updateRetryIndex = 0;
let updateRetryTimer = null;
let updateStage = 'idle'; // 'idle' | 'check' (automatic) | 'check-manual' | 'download'

function clearUpdateRetry() {
    updateRetryIndex = 0;
    if (updateRetryTimer) { clearTimeout(updateRetryTimer); updateRetryTimer = null; }
}

function scheduleUpdateRetry() {
    if (appQuitting || updateRetryTimer) return;
    // Only a failed *check* is retried: a failed download would re-run the whole
    // check and pull the payload again, which is not what a retry should mean.
    if (updateStage !== 'check') return;
    if (updateRetryIndex >= UPDATE_RETRY_DELAYS_MS.length) {
        updaterNotify('idle', withManualUpdateHint('Update check could not reach GitHub. Use "Check for updates" to try again.'));
        return;
    }
    const delay = UPDATE_RETRY_DELAYS_MS[updateRetryIndex];
    updateRetryIndex++;
    updaterNotify('retry', `Update check failed - retrying in ${Math.round(delay / 1000)}s…`);
    updateRetryTimer = setTimeout(() => {
        updateRetryTimer = null;
        runUpdateCheck(false);
    }, delay);
    if (updateRetryTimer.unref) updateRetryTimer.unref();
}

function runUpdateCheck(manual) {
    if (!updater) {
        if (manual) updaterNotify('error', 'Updater not available in this build.');
        return;
    }
    if (!app.isPackaged) {
        if (manual) updaterNotify('idle', 'Dev mode — updates only check in packaged builds.');
        return;
    }
    if (updateBusy) {
        if (manual) updaterNotify('busy', 'Update check already running…');
        return;
    }
    updateBusy = true;
    // A manual check is labelled separately so its own failure is not
    // auto-retried: the user is right there and can press the button again.
    updateStage = manual ? 'check-manual' : 'check';
    try {
        const p = updater.checkForUpdates();
        if (p && p.catch) p.catch((e) => { updateBusy = false; notifyUpdateFailure(e); scheduleUpdateRetry(); });
    } catch (e) {
        updateBusy = false;
        notifyUpdateFailure(e);
        scheduleUpdateRetry();
    }
}

function checkForUpdates(manual) {
    if (manual) {
        clearUpdateRetry();
    } else if (updateCheckedOnce) {
        return;
    } else {
        updateCheckedOnce = true;
    }
    runUpdateCheck(manual);
}

// The release feed is PUBLIC: package.json pins publish.private=false and the
// app-update.yml baked into the installer carries no token, so electron-updater
// needs no credential to read it. Never reintroduce publish.token/private=true:
// the old private feed's token was revoked, and every update check on those
// builds hard-failed with 401 forever - the "updates never arrive" outage.
// tools/test-release-feed.ps1 fails the release if either field comes back, and
// release.ps1 runs it as a pre-flight gate.
function initAutoUpdate() {
    if (autoUpdateInitialized) return;
    autoUpdateInitialized = true;
    if (!updater || !app.isPackaged) return; // dev runs skip silently
    updater.autoDownload = true;
    updater.autoInstallOnAppQuit = true;

    updater.on('checking-for-update', () => updaterNotify('checking', 'Checking for updates…'));
    updater.on('update-available', (info) => { updateStage = 'download'; updaterNotify('available', `Update v${info.version} found — downloading…`); });
    updater.on('update-not-available', () => { updateBusy = false; updaterNotify('idle', 'Already on the latest version.'); });
    updater.on('download-progress', (p) => {
        updaterNotify('progress', `Downloading update… ${Math.round(p.percent)}%`);
    });
    updater.on('update-downloaded', (info) => {
        updateBusy = false;
        updaterNotify('downloaded', `Update v${info.version} ready.`);
        try {
            dialog.showMessageBox(mainWindow, {
                type: 'info',
                buttons: ['Restart now', 'Later'],
                defaultId: 0,
                title: 'Update ready',
                message: `Windows Tweaks v${info.version} downloaded.`,
                detail: 'Restart the app to install the update.',
            }).then((r) => {
                if (r.response === 0) { try { updater.quitAndInstall(); } catch (_) {} }
            }).catch(() => {});
        } catch (_) {}
    });
    updater.on('error', (e) => {
        updateBusy = false;
        notifyUpdateFailure(e);
        // The promise rejection and this event both fire for a failed check;
        // scheduling is idempotent while a retry is pending.
        scheduleUpdateRetry();
    });

    // Single quiet automatic check 3 seconds after launch. The one-shot flag is
    // owned by checkForUpdates: setting it here as well made the call return on
    // its own guard before it ever reached the updater, so the launch check
    // never actually ran (only the manual button did).
    setTimeout(() => checkForUpdates(false), 3000);
}

// ─── IPC Handlers ───
ipcMain.on('window-minimize', () => mainWindow && mainWindow.minimize());
ipcMain.on('window-maximize', () => {
    if (!mainWindow) return;
    if (mainWindow.isMaximized()) mainWindow.restore();
    else mainWindow.maximize();
});
ipcMain.on('window-close', () => mainWindow && mainWindow.close());

ipcMain.handle('get-is-admin', async () => {
    return new Promise((resolve) => {
        exec('net session >nul 2>&1', (err) => resolve(!err));
    });
});

// Report the port the backend actually bound, not the preferred one: on a
// fallback the renderer would otherwise be pointed at a dead port.
ipcMain.handle('get-port', () => activePort);
// Per-process API token, read off the backend's stdout. Polls briefly because the
// renderer can ask before the marker line arrives; the backend prints it before the
// listener serves anything, so this resolves on the first or second tick.
ipcMain.handle('get-api-token', async () => {
    for (let i = 0; i < 60 && !apiToken; i++) {
        await new Promise(r => setTimeout(r, 100));
    }
    return apiToken;
});
ipcMain.on('open-external', (event, url) => {
    try {
        const parsed = new URL(url);
        if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
            shell.openExternal(url);
        }
    } catch (_) {}
});
ipcMain.on('check-updates', () => checkForUpdates(true));

// ─── App Lifecycle ───
// Single instance: a second launch just focuses the running app instead of
// spawning a rival backend that steals the port and gets itself killed.
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
    app.quit();
} else {
    app.on('second-instance', () => {
        // Spam-clicking the launcher during startup lands here while the main
        // window exists but has not loaded yet. Raising it that early would
        // flash an empty black window next to the splash, so until the UI is
        // actually revealed this only nudges the splash.
        if (uiRevealed && mainWindow && !mainWindow.isDestroyed()) {
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();
            console.log('[App] second instance blocked — focused the running window');
        } else if (splashWindow && !splashWindow.isDestroyed()) {
            splashWindow.focus();
            console.log('[App] second instance blocked — still starting, focused the splash');
        } else {
            console.log('[App] second instance blocked — nothing shown yet');
        }
    });

app.whenReady().then(() => {
    if (!isAdminSync()) {
        // UAC prompt — the elevated copy takes over. This process stays alive
        // (holding the lock) until relaunchAsAdmin has handed off.
        relaunchAsAdmin();
        return;
    }

    createSplash();        // instant — no backend wait
    watchPublic();         // theme edits hot-reload
    createMainWindow();

    startBackend(sendProgress, () => {
        // Guard: user may have closed the app while the backend was still starting.
        // mainWindow is set to null in its 'closed' handler, so any access here
        // would throw "Cannot read properties of null (reading 'loadFile')" and
        // the Electron uncaught-exception dialog would pop up once per poll tick
        // (up to 30 times). Bail out cleanly instead.
        if (!mainWindow || mainWindow.isDestroyed()) return;

        sendProgress(88, 'Loading interface…');
        try { mainWindow.loadFile(path.join(PUBLIC_DIR, 'index.html')); } catch (_) { return; }

        let shown = false;
        const showMain = () => {
            if (shown) return;
            if (!mainWindow || mainWindow.isDestroyed()) return;
            shown = true;
            sendProgress(100, 'Ready.');
            setTimeout(() => {
                // Dissolve the splash rather than closing it outright. The splash
                // window scales itself down and fades, and the main window is
                // raised underneath one frame later, so the hand-off reads as one
                // continuous reveal instead of a cut from black to a full UI.
                // The close is still guaranteed after the fade, so a renderer
                // that never runs splashDissolve cannot trap the user here.
                const finish = () => {
                    try { if (splashWindow && !splashWindow.isDestroyed()) splashWindow.close(); } catch (_) {}
                    if (mainWindow && !mainWindow.isDestroyed()) {
                        uiRevealed = true;
                        mainWindow.show();
                    }
                    initAutoUpdate();
                };
                let dissolved = false;
                try {
                    if (splashWindow && !splashWindow.isDestroyed()) {
                        splashWindow.webContents.executeJavaScript('window.splashDissolve && window.splashDissolve()')
                            .then(() => { dissolved = true; })
                            .catch(() => {});
                    }
                } catch (_) {}
                // 460ms covers the 0.42s CSS transition in splash.html; the extra
                // guard means we still close if the promise never settles.
                setTimeout(finish, 460);
                void dissolved;
            }, 350);
        };

        if (mainWindow && !mainWindow.isDestroyed()) mainWindow.once('ready-to-show', showMain);
        // Failsafe: never trap the user on the splash
        setTimeout(showMain, 9000);
    });
});

app.on('before-quit', () => {
    // Suppress restarts and update retries once the app is on its way out, and
    // take the child down with us: quitAndInstall() (and any other quit that
    // does not close the window first) would otherwise leave an orphaned backend
    // holding the port.
    appQuitting = true;
    clearUpdateRetry();
    killBackend();
});

app.on('window-all-closed', () => {
    killBackend();
    app.quit();
});

app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
        createSplash();
        createMainWindow();
    }
});
} // end single-instance else
