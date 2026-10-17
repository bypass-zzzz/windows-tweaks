const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
    minimize: () => ipcRenderer.send('window-minimize'),
    maximize: () => ipcRenderer.send('window-maximize'),
    close: () => ipcRenderer.send('window-close'),
    getPort: () => ipcRenderer.invoke('get-port'),
    getApiToken: () => ipcRenderer.invoke('get-api-token'),
    isAdmin: () => ipcRenderer.invoke('get-is-admin'),
    openExternal: (url) => ipcRenderer.send('open-external', url),
    checkUpdates: () => ipcRenderer.send('check-updates'),
    onUpdater: (cb) => {
        ipcRenderer.on('updater-status', (_event, data) => {
            try { cb(data.status, data.message); } catch (_) {}
        });
    },
    // Backend lifecycle (main.js restarts the PowerShell backend after a crash).
    // The renderer re-resolves its base URL and API token when the backend
    // announces it is ready again.
    onBackendStatus: (cb) => {
        ipcRenderer.on('backend-status', (_event, data) => {
            try { cb(data && data.state, data && data.message); } catch (_) {}
        });
    },
});

// Splash-screen progress channel (splash.html). No Node exposure — event-only.
contextBridge.exposeInMainWorld('splashAPI', {
    onProgress: (cb) => {
        ipcRenderer.on('loading-progress', (_event, data) => {
            try { cb(data.pct, data.status); } catch (_) {}
        });
    },
});
