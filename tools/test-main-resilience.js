// =============================================================================
//  main.js resilience harness — backend crash recovery + auto-update retries
// =============================================================================
//  main.js only runs inside Electron, so this loads the REAL module with the
//  'electron', 'electron-updater', 'child_process' and 'http' modules stubbed,
//  and drives it on a deterministic fake clock. No window is shown, no port is
//  bound, no registry key is read and no real waiting happens: a one-second
//  backoff is a synchronous advance(1000), so the whole suite runs in
//  milliseconds and cannot flake.
//
//  Run: node tools/test-main-resilience.js
// =============================================================================
'use strict';

const path = require('path');
const Module = require('module');
const EventEmitter = require('events');
const fs = require('fs');
const http = require('http');
const cp = require('child_process');

const REPO = path.resolve(__dirname, '..');
const MAIN = path.join(REPO, 'main.js');
const realLog = console.log.bind(console);
const realImmediate = setImmediate;
// Several real ticks: main.js chains callbacks (exec → Promise.all → spawn →
// probe → fireReady), and one immediate is not enough to drain a chain.
const flush = async () => {
    for (let i = 0; i < 8; i++) await new Promise(r => realImmediate(r));
};

const TOKEN_OLD = Buffer.alloc(32, 0x11).toString('base64'); // 44 chars, like the backend's
const TOKEN_NEW = Buffer.alloc(32, 0x22).toString('base64');

let passed = 0;
let failed = 0;
function Section(name) { realLog('\n--- ' + name + ' ---'); }
function Check(what, ok, detail) {
    if (ok) { passed++; realLog('  PASS  ' + what); }
    else { failed++; realLog('  FAIL  ' + what + (detail ? '  -> ' + detail : '')); }
}

// ── Fake clock ───────────────────────────────────────────────────────────────
// Records every requested delay (so the backoff ladder can be asserted) and runs
// due callbacks in time order when advance() is called.
function makeClock() {
    let now = 0;
    let seq = 1;
    let timers = [];
    const requested = [];
    const api = {
        now: () => now,
        requested,
        setTimeout(fn, delay, ...args) {
            const d = Number(delay) || 0;
            requested.push(d);
            const t = { id: seq++, at: now + d, fn, args, done: false };
            timers.push(t);
            return t.id;
        },
        clearTimeout(id) {
            const t = timers.find(x => x.id === id);
            if (t) t.done = true;
        },
        pending: () => timers.filter(t => !t.done).length,
        advance(ms) {
            const target = now + ms;
            for (;;) {
                const due = timers
                    .filter(t => !t.done && t.at <= target)
                    .sort((a, b) => a.at - b.at || a.id - b.id)[0];
                if (!due) break;
                due.done = true;
                now = due.at;
                due.fn(...due.args);
            }
            now = target;
        },
    };
    return api;
}

// ── Stub bundle ──────────────────────────────────────────────────────────────
let current = null;

function makeBundle() {
    const bundle = {
        clock: makeClock(),
        sent: [],          // renderer messages: [channel, payload]
        logs: [],
        spawned: [],       // fake powershell children
        spawnArgs: [],     // argv of each fake spawn
        killed: [],        // child.kill() calls (pids)
        loaded: [],        // paths passed to loadFile (splash.html + index.html)
        probeAnswers: { 48921: 200, 48922: 200 }, // per-port /api/status status (0 = refused)
        probeLog: [],      // "<port>:<status>" per probe, in call order
        ipcHandlers: {},
        ipcOn: {},
        appHandlers: {},
        windows: [],
        windowClosed: null,
        updateCalls: 0,
    };

    const makeChild = () => {
        const child = new EventEmitter();
        child.stdout = new EventEmitter();
        child.stderr = new EventEmitter();
        child.pid = 5000 + bundle.spawned.length;
        child.kill = () => { bundle.killed.push(child.pid); };
        return child;
    };

    bundle.electron = {
        app: {
            isPackaged: true,
            whenReady: () => Promise.resolve(),
            requestSingleInstanceLock: () => true,
            releaseSingleInstanceLock: () => {},
            getAppPath: () => REPO,
            quit: () => {},
            on: (ev, fn) => { bundle.appHandlers[ev] = fn; },
        },
        BrowserWindow: class {
            constructor() {
                this.webContents = {
                    send: (ch, payload) => bundle.sent.push([ch, payload]),
                    reloadIgnoringCache: () => Promise.resolve(),
                    executeJavaScript: () => Promise.resolve(),
                };
                bundle.windows.push(this);
            }
            loadFile(filePath) { bundle.loaded.push(String(filePath)); return Promise.resolve(); }
            on(ev, fn) { if (ev === 'closed') bundle.windowClosed = fn; }
            once() {}
            show() {} close() {} focus() {} restore() {} maximize() {}
            isDestroyed() { return false; }
            isMinimized() { return false; }
            isMaximized() { return false; }
        },
        ipcMain: {
            on: (ch, fn) => { bundle.ipcOn[ch] = fn; },
            handle: (ch, fn) => { bundle.ipcHandlers[ch] = fn; },
        },
        dialog: { showMessageBox: () => Promise.resolve({ response: 1 }) },
        shell: { openExternal: () => {} },
    };

    const updaterEvents = new EventEmitter();
    bundle.updater = Object.assign(updaterEvents, {
        autoDownload: false,
        autoInstallOnAppQuit: false,
        checkForUpdates: () => { bundle.updateCalls++; return Promise.reject(new Error('simulated offline')); },
    });

    // helpers for the scenarios
    bundle.spawn = () => bundle.spawned[bundle.spawned.length - 1];
    bundle.statuses = (state) => bundle.sent
        .filter(([ch, p]) => ch === 'backend-status' && p.state === state && p.message)
        .map(([, p]) => p.message);
    bundle.channelOf = (ch) => bundle.sent.filter(([c]) => c === ch).map(([, p]) => p);
    bundle.backendLog = (needle) => bundle.logs.some(l => l.includes(needle) && l.includes('[PS Backend]'));
    bundle.ipcHandler = (name) => bundle.ipcHandlers[name];
    bundle.emitToken = (token) => bundle.spawn().stdout.emit('data', Buffer.from('__WT_TOKEN__' + token + '\n'));
    bundle.crash = (code) => bundle.spawn().emit('exit', code);
    bundle.indexLoads = () => bundle.loaded.filter(p => /index\.html$/i.test(p)).length;
    bundle.splashLoads = () => bundle.loaded.filter(p => /splash\.html$/i.test(p)).length;
    return bundle;
}

function loadApp() {
    const bundle = makeBundle();
    current = bundle;

    // Fake clock for everything main.js schedules.
    global.setTimeout = (fn, delay, ...args) => bundle.clock.setTimeout(fn, delay, ...args);
    global.clearTimeout = (id) => bundle.clock.clearTimeout(id);
    // Console noise goes to the bundle instead of the user's terminal.
    console.log = (...a) => bundle.logs.push(a.map(String).join(' '));
    console.error = (...a) => bundle.logs.push('ERR ' + a.map(String).join(' '));

    // process.resourcesPath is undefined under plain Node; without it
    // serverScriptPath() would throw before falling back to __dirname.
    process.resourcesPath = REPO;

    // Deliberate, visible side effects are the point of the app, and none of them
    // may happen here: no process is spawned and no socket is opened.
    cp.spawn = (cmd, args) => {
        const c = new EventEmitter();
        c.stdout = new EventEmitter();
        c.stderr = new EventEmitter();
        c.pid = 5000 + bundle.spawned.length;
        c.kill = () => { bundle.killed.push(c.pid); };
        bundle.spawned.push(c);
        bundle.spawnArgs.push((args || []).map(String));
        return c;
    };
    cp.exec = (cmd, cb) => {
        if (typeof cb === 'function') realImmediate(() => cb(null, ''));
        return { unref() {} };
    };
    cp.execSync = () => ''; // isAdminSync(): succeed, so no UAC relaunch path
    http.get = (opts, cb) => {
        const req = new EventEmitter();
        req.destroy = () => {};
        const code = bundle.probeAnswers[opts.port] || 0;
        bundle.probeLog.push(opts.port + ':' + code);
        realImmediate(() => {
            if (code) cb({ statusCode: code, resume() {} });
            else req.emit('error', new Error('ECONNREFUSED'));
        });
        return req;
    };
    // Keep the test hermetic: no watcher on the user's public/ directory.
    fs.watch = () => ({ close() {} });

    delete require.cache[require.resolve(MAIN)];
    require(MAIN); // executes the real module with the stubs in place
    return bundle;
}

Module._load = ((orig) => function (request, parent, isMain) {
    if (request === 'electron') return current.electron;
    if (request === 'electron-updater') return { autoUpdater: current.updater };
    return orig.apply(this, arguments);
})(Module._load);

// ── Helpers ──────────────────────────────────────────────────────────────────
// Startup → spawn → token → first poll tick → backend ready.
async function bringUp(bundle, token) {
    await flush();                       // whenReady handler runs; freePorts → spawn
    bundle.emitToken(token);
    bundle.clock.advance(500);           // pollBackend's first tick
    await flush();                       // http probe callbacks
    return bundle;
}

async function main() {
    // ── 1. A crash mid-session restarts the backend and reconnects the UI ────
    Section('crash recovery: restart, new token, reconnected renderer');
    let b = loadApp();
    await bringUp(b, TOKEN_OLD);
    Check('the backend is spawned once at startup', b.spawned.length === 1, 'spawns=' + b.spawned.length);
    Check('the first spawn runs the real server script with -NoBrowser',
        b.spawnArgs[0].some(a => a.includes('server.ps1')) && b.spawnArgs[0].includes('-NoBrowser'),
        JSON.stringify(b.spawnArgs[0]));
    Check('the probe settled on the preferred port 48921', (await b.ipcHandler('get-port')()) === 48921,
        'port=' + (await b.ipcHandler('get-port')()) + ' probes=' + b.probeLog.join(','));
    Check('the renderer can read the token', (await b.ipcHandler('get-api-token')()) === TOKEN_OLD);
    Check('the first start does not announce a reconnect', b.statuses('ready').length === 0);
    Check('the splash and the UI were each loaded once',
        b.indexLoads() === 1 && b.splashLoads() === 1,
        'index=' + b.indexLoads() + ' splash=' + b.splashLoads());

    b.crash(1);
    const restarting1 = b.statuses('restarting');
    Check('the crash is announced to the renderer', restarting1.length === 1, JSON.stringify(restarting1));
    Check('the first backoff step is 1s (attempt 1 of 3)',
        /in 1s \(attempt 1 of 3\)/.test(restarting1[0] || ''), restarting1[0]);
    Check('nothing is respawned before the delay elapses', b.spawned.length === 1);

    // The renderer asked for the token right after the crash: it must wait for
    // the replacement rather than hand out the dead process' token.
    const tokenPromise = b.ipcHandler('get-api-token')();
    b.clock.advance(1000);               // backoff elapses
    await flush();                       // freePorts → respawn
    Check('the backend is respawned after the delay', b.spawned.length === 2, 'spawns=' + b.spawned.length);
    b.clock.advance(300);                // a few of the token-wait iterations
    let tokenSettled = false;
    tokenPromise.then(() => { tokenSettled = true; });
    await flush();
    Check('the stale token is not handed to the renderer', tokenSettled === false);

    b.emitToken(TOKEN_NEW);
    b.clock.advance(500);                // probe tick for the replacement
    await flush();
    Check('the renderer gets the NEW token, not the old one', (await tokenPromise) === TOKEN_NEW);
    Check('the restart is announced as reconnected',
        b.statuses('ready').length === 1 && /restarted/i.test(b.statuses('ready')[0]), JSON.stringify(b.statuses('ready')));
    Check('the reconnect carries the port the probe found',
        b.channelOf('backend-status').some(p => p.state === 'ready' && p.port === 48921),
        JSON.stringify(b.channelOf('backend-status').filter(p => p.state === 'ready')));
    Check('a restart does not reload the UI', b.indexLoads() === 1, 'index=' + b.indexLoads());

    // ── 2. The retry budget is bounded, then gives up loudly ────────────────
    Section('crash loop: bounded retries, then an honest give-up');
    b = await bringUp(loadApp(), TOKEN_OLD);
    b.crash(1); b.clock.advance(1000); await flush();
    b.emitToken(TOKEN_NEW); b.clock.advance(500); await flush();
    b.crash(2); b.clock.advance(3000); await flush();
    b.emitToken(TOKEN_NEW); b.clock.advance(500); await flush();
    b.crash(3); b.clock.advance(9000); await flush();
    b.emitToken(TOKEN_NEW); b.clock.advance(500); await flush();
    Check('three restarts were attempted (spawns = 4)', b.spawned.length === 4, 'spawns=' + b.spawned.length);
    const ladder = b.statuses('restarting').map(m => (m.match(/in (\d+)s \(attempt (\d) of 3\)/) || []).slice(1).join('/'));
    Check('the backoff ladder widens 1s, 3s, 9s', ladder.join(' ') === '1/1 3/2 9/3', ladder.join(' '));

    b.crash(4);
    await flush();
    Check('a fourth crash is not restarted', b.spawned.length === 4, 'spawns=' + b.spawned.length);
    Check('the give-up is reported to the renderer',
        b.statuses('failed').length === 1 && /could not be restarted/i.test(b.statuses('failed')[0]),
        JSON.stringify(b.statuses('failed')));
    b.clock.advance(120000);
    await flush();
    Check('nothing further is spawned after giving up', b.spawned.length === 4, 'spawns=' + b.spawned.length);

    // ── 3. A healthy stretch re-arms the budget ─────────────────────────────
    Section('stabbed backend: the retry budget re-arms after 30s of uptime');
    b = await bringUp(loadApp(), TOKEN_OLD);
    b.crash(1); b.clock.advance(1000); await flush();
    b.emitToken(TOKEN_NEW); b.clock.advance(500); await flush();   // ready again (attempt 1 used)
    b.clock.advance(30000);                                       // stability window passes
    b.crash(2);
    const msgs = b.statuses('restarting');
    Check('the next crash starts the ladder over at attempt 1',
        msgs.length === 2 && /in 1s \(attempt 1 of 3\)/.test(msgs[1]), msgs.join(' | '));

    // ── 4. A deliberate shutdown never restarts anything ────────────────────
    Section('deliberate shutdown: closed window / app quit suppress restarts');
    b = await bringUp(loadApp(), TOKEN_OLD);
    b.windowClosed();                    // mainWindow 'closed' → killBackend()
    b.crash(0);
    b.clock.advance(60000);
    await flush();
    Check('a crash after the window closed is not restarted', b.spawned.length === 1, 'spawns=' + b.spawned.length);
    Check('the killed backend was terminated', b.killed.length === 1, 'kills=' + b.killed.length);
    Check('no restart is announced after shutdown', b.statuses('restarting').length === 0);

    b = await bringUp(loadApp(), TOKEN_OLD);
    b.appHandlers['before-quit']();      // app is quitting
    b.crash(0);
    b.clock.advance(60000);
    await flush();
    Check('a crash while quitting is not restarted', b.spawned.length === 1, 'spawns=' + b.spawned.length);
    // quitAndInstall() quits without closing the window first, so 'before-quit'
    // is the only handler that can take the child down there: an orphaned
    // backend would hold the port for the next launch.
    Check('quitting takes the backend down with it (no orphan)', b.killed.length === 1, 'kills=' + b.killed.length);
    b.appHandlers['before-quit']();      // repeat quit signals
    Check('repeat quit signals are no-ops', b.killed.length === 1, 'kills=' + b.killed.length);

    // ── 5. Auto-update: bounded retries on a failed check ───────────────────
    Section('auto-update: a failed check retries twice, then says so');
    b = loadApp();
    await bringUp(b, TOKEN_OLD);         // backend up; the first probe tick lands at 500 ms
    // The splash's failsafe reveal (9000 ms, measured from that first probe) →
    // 350 ms → 460 ms tail, then initAutoUpdate, then its own 3000 ms delay
    // before the quiet check.
    b.clock.advance(10000);
    await flush();
    b.clock.advance(3000);               // the single quiet automatic check
    await flush();
    Check('the automatic check ran once', b.updateCalls === 1, 'calls=' + b.updateCalls);
    Check('the failure is surfaced as an error', b.channelOf('updater-status').some(s => s.status === 'error'));
    const retries = b.channelOf('updater-status').filter(s => s.status === 'retry');
    Check('a retry is announced with a 15s delay',
        retries.length === 1 && /15s/.test(retries[0].message), JSON.stringify(retries));

    b.clock.advance(15000);
    await flush();
    Check('the retry actually re-runs the check', b.updateCalls === 2, 'calls=' + b.updateCalls);
    const retries2 = b.channelOf('updater-status').filter(s => s.status === 'retry');
    Check('the second retry widens to 45s',
        retries2.length === 2 && /45s/.test(retries2[1].message), JSON.stringify(retries2));

    b.clock.advance(45000);
    await flush();
    Check('there is no third retry', b.updateCalls === 3, 'calls=' + b.updateCalls);
    const terminal = b.channelOf('updater-status').filter(s => s.status === 'idle');
    Check('the dead end is stated, with the way out',
        terminal.length === 1 && /Check for updates/.test(terminal[0].message), JSON.stringify(terminal));
    b.clock.advance(300000);
    await flush();
    Check('nothing further is scheduled after giving up', b.updateCalls === 3, 'calls=' + b.updateCalls);

    // ── 6. A manual check cancels a pending retry and does not auto-retry ───
    Section('auto-update: a manual check cancels the pending retry');
    b = loadApp();
    await bringUp(b, TOKEN_OLD);
    b.clock.advance(10000);
    await flush();
    b.clock.advance(3000);
    await flush();
    Check('a retry is pending after the automatic failure',
        b.channelOf('updater-status').some(s => s.status === 'retry'));
    b.ipcOn['check-updates']();          // the user presses "Check for updates"
    await flush();
    Check('the manual check runs immediately', b.updateCalls === 2, 'calls=' + b.updateCalls);
    b.clock.advance(120000);             // the cancelled 15s retry would have fired by now
    await flush();
    Check('the cancelled retry does not fire', b.updateCalls === 2, 'calls=' + b.updateCalls);
    Check('a failed MANUAL check does not schedule its own retry',
        b.channelOf('updater-status').filter(s => s.status === 'retry').length === 1,
        String(b.channelOf('updater-status').filter(s => s.status === 'retry').length));

    // ── 7. A failed download is not retried as if it were a failed check ────
    Section('auto-update: a download failure is not re-checked');
    b = loadApp();
    b.updater.checkForUpdates = () => {
        b.updateCalls++;
        b.updater.emit('update-available', { version: '9.9.9' });
        return Promise.reject(new Error('simulated download failure'));
    };
    await bringUp(b, TOKEN_OLD);
    b.clock.advance(10000);
    await flush();
    b.clock.advance(3000);
    await flush();
    Check('the update was found', b.channelOf('updater-status').some(s => s.status === 'available'));
    Check('a download failure schedules no retry',
        b.channelOf('updater-status').filter(s => s.status === 'retry').length === 0,
        JSON.stringify(b.channelOf('updater-status')));
    b.clock.advance(120000);
    await flush();
    Check('no re-check follows a download failure', b.updateCalls === 1, 'calls=' + b.updateCalls);

    // ── 8. A backend on the fallback port is announced with THAT port ───────
    // The renderer re-resolves its base URL from the announced port, so a wrong
    // port here would strand the UI on a dead socket after a recovery.
    Section('fallback port: the reconnect carries the port that answered');
    b = loadApp();
    b.probeAnswers = { 48921: 0, 48922: 200 };   // 48921 refused, 48922 answers
    await bringUp(b, TOKEN_OLD);
    Check('the probe falls back to 48922', (await b.ipcHandler('get-port')()) === 48922,
        'port=' + (await b.ipcHandler('get-port')()));
    b.crash(9);
    b.clock.advance(1000);
    await flush();
    b.emitToken(TOKEN_NEW);
    b.clock.advance(500);
    await flush();
    Check('the reconnect reports the fallback port',
        b.channelOf('backend-status').some(p => p.state === 'ready' && p.port === 48922),
        JSON.stringify(b.channelOf('backend-status')));

    realLog('\n=== RESULT ===');
    realLog('  passed: ' + passed);
    realLog('  failed: ' + failed);
    realLog('  ' + (failed === 0 ? 'backend recovery and update retries behave as designed' : 'FAILURES ABOVE'));
    process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
    realLog('harness error: ' + (e && e.stack ? e.stack : e));
    process.exit(2);
});
