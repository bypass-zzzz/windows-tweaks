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
let backendReady = false;
const PORT = 48921;
const FALLBACK_PORT = 48922;
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
    const exe = process.execPath;
    const cmd = app.isPackaged
        ? `Start-Process -FilePath "${exe}" -Verb RunAs`
        : `Start-Process -FilePath "${exe}" -ArgumentList '"${app.getAppPath()}"' -Verb RunAs`;
    try {
        require('child_process').spawnSync(
            'powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd],
            { windowsHide: true, stdio: 'ignore' }
        );
    } catch (_) {}
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

function startBackend(onProgress, onReady) {
    onProgress(10, COOL_LINES[0]);
    backendReady = false;

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
            console.log('[PS Backend]', data.toString().trim());
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
        });

        pollBackend(onProgress, onReady);
    });
}

function pollBackend(onProgress, onReady) {
    let attempts = 0;
    const MAX_ATTEMPTS = 30;
    const poll = setInterval(() => {
        attempts++;
        // Map polling 0..30 → 18%..84% with rotating cool lines
        const pct = Math.round(18 + (attempts / MAX_ATTEMPTS) * 66);
        onProgress(pct, COOL_LINES[attempts % COOL_LINES.length]);

        http.get(`http://127.0.0.1:${PORT}/api/status`, (res) => {
            if (res.statusCode === 200) {
                res.resume(); // drain
                clearInterval(poll);
                backendReady = true;
                onReady();
            } else if (attempts >= MAX_ATTEMPTS) {
                clearInterval(poll);
                onReady(); // show UI anyway; API calls will retry
            }
        }).on('error', () => {
            if (attempts >= MAX_ATTEMPTS) {
                clearInterval(poll);
                onReady();
            }
        });
    }, 500);
}

function killBackend() {
    if (psServer) {
        try { psServer.kill('SIGTERM'); } catch (_) {}
        exec(`netstat -ano | findstr :${PORT}`, (err, stdout) => {
            if (stdout) {
                stdout.trim().split('\n').forEach(line => {
                    const parts = line.trim().split(/\s+/);
                    const pid = parts[parts.length - 1];
                    if (pid && !isNaN(pid)) {
                        exec(`taskkill /PID ${pid} /F`);
                    }
                });
            }
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

function checkForUpdates(manual) {
    if (!updater) {
        if (manual) updaterNotify('error', 'Updater not available in this build.');
        return;
    }
    if (!app.isPackaged) {
        if (manual) updaterNotify('idle', 'Dev mode — updates only check in packaged builds.');
        return;
    }
    if (!manual && updateCheckedOnce) {
        return;
    }
    if (!manual) {
        updateCheckedOnce = true;
    }
    if (updateBusy) {
        if (manual) updaterNotify('busy', 'Update check already running…');
        return;
    }
    updateBusy = true;
    try {
        const p = updater.checkForUpdates();
        if (p && p.catch) p.catch((e) => { updateBusy = false; updaterNotify('error', (e && e.message) || 'Update check failed.'); });
    } catch (e) {
        updateBusy = false;
        updaterNotify('error', (e && e.message) || 'Update check failed.');
    }
}

// Private release repo access is configured via the publish.token field in
// package.json (baked into app-update.yml). electron-updater selects its
// PrivateGitHubProvider from that — requestHeaders alone are not enough.
// WARNING: anyone holding the .exe can extract this token. Keep it scoped
// to the windows-tweaks repo only.
function initAutoUpdate() {
    if (autoUpdateInitialized) return;
    autoUpdateInitialized = true;
    if (!updater || !app.isPackaged) return; // dev runs skip silently
    updater.autoDownload = true;
    updater.autoInstallOnAppQuit = true;

    updater.on('checking-for-update', () => updaterNotify('checking', 'Checking for updates…'));
    updater.on('update-available', (info) => updaterNotify('available', `Update v${info.version} found — downloading…`));
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
    updater.on('error', (e) => { updateBusy = false; updaterNotify('error', (e && e.message) || 'Updater error.'); });

    // Single quiet automatic check 3 seconds after launch
    setTimeout(() => {
        if (!updateCheckedOnce) {
            updateCheckedOnce = true;
            checkForUpdates(false);
        }
    }, 3000);
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

ipcMain.handle('get-port', () => PORT);
ipcMain.on('open-external', (event, url) => shell.openExternal(url));
ipcMain.on('check-updates', () => checkForUpdates(true));

// ─── App Lifecycle ───
// Single instance: a second launch just focuses the running app instead of
// spawning a rival backend that steals the port and gets itself killed.
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
    app.quit();
} else {
    app.on('second-instance', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();
        } else if (splashWindow && !splashWindow.isDestroyed()) {
            splashWindow.focus();
        }
    });

app.whenReady().then(() => {
    if (!isAdminSync()) {
        relaunchAsAdmin(); // UAC prompt — elevated copy takes over
        app.quit();
        return;
    }

    createSplash();        // instant — no backend wait
    watchPublic();         // theme edits hot-reload
    createMainWindow();

    startBackend(sendProgress, () => {
        sendProgress(88, 'Loading interface…');
        mainWindow.loadFile(path.join(PUBLIC_DIR, 'index.html'));

        let shown = false;
        const showMain = () => {
            if (shown) return;
            shown = true;
            sendProgress(100, 'Ready.');
            setTimeout(() => {
                try { if (splashWindow && !splashWindow.isDestroyed()) splashWindow.close(); } catch (_) {}
                if (mainWindow && !mainWindow.isDestroyed()) mainWindow.show();
                initAutoUpdate();
            }, 350);
        };

        mainWindow.once('ready-to-show', showMain);
        // Failsafe: never trap the user on the splash
        setTimeout(showMain, 9000);
    });
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
