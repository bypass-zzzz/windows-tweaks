// ==============================================================================
// WINDOWS TWEAKS - CLIENT APPLICATION LOGIC
// High-Speed REST Client & Real-time Canvas Latency Monitor
// ==============================================================================

// In Electron the UI loads from file:// so location.origin is "null" —
// probe the real backend instead (packaged port, page origin, fallbacks).
let API_BASE = 'http://127.0.0.1:48921';

async function probeBase(url) {
    try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 1500);
        const res = await fetch(`${url}/api/status`, { signal: ctrl.signal });
        clearTimeout(t);
        return res.ok;
    } catch (_) { return false; }
}

async function initApiBase() {
    const candidates = [];
    try {
        if (window.electronAPI && window.electronAPI.getPort) {
            const p = await window.electronAPI.getPort();
            if (p) candidates.push(`http://127.0.0.1:${p}`);
        }
    } catch (_) {}
    if (window.location.protocol && window.location.protocol.indexOf('http') === 0) {
        candidates.push(window.location.origin);
    }
    candidates.push('http://127.0.0.1:48921', 'http://127.0.0.1:48922');
    for (const c of candidates) {
        if (await probeBase(c)) { API_BASE = c; return; }
    }
}

let pingHistory = [];
const MAX_PING_HISTORY = 40;
let pingInterval = null;
let statusInterval = null;

// Initialize on DOM Ready
document.addEventListener("DOMContentLoaded", async () => {
    initTabs();
    initCanvas();
    bindEvents();
    initBootOverlay();
    initThemeToggle();

    await initApiBase(); // find the backend before the first fetch

    initUpdaterFeed();
        
    // Initial Data Fetch
    fetchSystemStatus();
    fetchNetworkStatus();
    fetchServices();
    fetchProcesses();
    startPingStream();

    // Periodic Polling (fast + smooth)
    statusInterval = setInterval(fetchSystemStatus, 2000);
});

// -----------------------------------------------------------------------------
// THEME TOGGLE â€” Monochrome (default) <-> Obsidian (black & red)
// The Obsidian palette is entirely in CSS under [data-theme="obsidian"], so
// this only flips the attribute on <html> and syncs the button label.
// Choice persists in localStorage and is applied before first paint by the
// inline snippet in index.html, so there is no flash of the wrong theme.
// -----------------------------------------------------------------------------
const THEME_KEY = "wt.theme";

function applyTheme(theme) {
    const obsidian = theme === "obsidian";
    if (obsidian) {
        document.documentElement.setAttribute("data-theme", "obsidian");
    } else {
        document.documentElement.removeAttribute("data-theme");
    }
    const label = document.getElementById("themeToggleLabel");
    if (label) label.textContent = obsidian ? "Obsidian" : "Mono";
    const btn = document.getElementById("btnThemeToggle");
    if (btn) btn.setAttribute("aria-pressed", obsidian ? "true" : "false");
}

function initThemeToggle() {
    let stored = null;
    try { stored = localStorage.getItem(THEME_KEY); } catch (_) {}
    applyTheme(stored || "mono");

    const btn = document.getElementById("btnThemeToggle");
    if (!btn) return;
    btn.addEventListener("click", () => {
        const next = document.documentElement.getAttribute("data-theme") === "obsidian" ? "mono" : "obsidian";
        applyTheme(next);
        try { localStorage.setItem(THEME_KEY, next); } catch (_) {}
        showToast(next === "obsidian" ? "Obsidian theme (black & red)" : "Monochrome theme", "info");
    });
}

// -----------------------------------------------------------------------------
// AUTO-UPDATE FEED â€” main process pushes status here (toast + terminal)
// -----------------------------------------------------------------------------
function setUpdatesButton(busy) {
    const btn = document.getElementById("btnCheckUpdates");
    if (!btn) return;
    btn.disabled = !!busy;
    btn.style.opacity = busy ? "0.55" : "";
    btn.style.pointerEvents = busy ? "none" : "";
    if (busy) {
        if (!btn.dataset.orig) btn.dataset.orig = btn.innerHTML;
        btn.innerHTML = "Checking…";
    } else if (btn.dataset.orig) {
        btn.innerHTML = btn.dataset.orig;
        delete btn.dataset.orig;
    }
}

function initUpdaterFeed() {
    if (!window.electronAPI || !window.electronAPI.onUpdater) return;
    let lastProgress = 0;
    window.electronAPI.onUpdater((status, message) => {
        if (status === 'checking' || status === 'available' || status === 'progress') setUpdatesButton(true);
        if (status === 'idle' || status === 'downloaded' || status === 'error' || status === 'busy') setUpdatesButton(false);
        if (status === 'progress') {
            const pct = parseInt((message.match(/(\d+)%/) || [])[1] || '0', 10);
            if (pct - lastProgress < 20 && pct < 100) return; // avoid toast spam
            lastProgress = pct;
        }
        appendLog(`[UPDATE] ${message || status}`);
        if (status === 'progress') return; // progress lives in the terminal, not toasts
        showToast(message || status, status === 'error' ? 'error' : status === 'downloaded' || status === 'available' ? 'success' : 'info');
    });
}
// -----------------------------------------------------------------------------
// BOOT OVERLAY — hide once live data arrives (failsafe 8s)
// -----------------------------------------------------------------------------
let bootHidden = false;
function hideBootOverlay() {
    if (bootHidden) return;
    bootHidden = true;
    const el = document.getElementById("bootOverlay");
    if (el) {
        el.classList.add("hidden");
        setTimeout(() => el.remove(), 600);
    }
}
function initBootOverlay() {
    const lines = [
        "Warming up the engine…",
        "Polishing every pixel…",
        "Tuning TCP for zero-lag packets…",
        "Locking the kernel in RAM…",
        "Calibrating the ping stream…"
    ];
    let i = 0;
    const el = document.getElementById("bootStatus");
    const rot = setInterval(() => {
        if (bootHidden || !el) { clearInterval(rot); return; }
        i = (i + 1) % lines.length;
        el.textContent = lines[i];
    }, 1400);
    setTimeout(hideBootOverlay, 8000); // failsafe: never trap the user
}

// -----------------------------------------------------------------------------
// TAB NAVIGATION
// -----------------------------------------------------------------------------
function initTabs() {
    const tabs = document.querySelectorAll(".nav-tab");
    tabs.forEach(tab => {
        tab.addEventListener("click", () => {
            tabs.forEach(t => t.classList.remove("active"));
            document.querySelectorAll(".tab-pane").forEach(p => p.classList.remove("active"));
            
            tab.classList.add("active");
            const targetId = tab.getAttribute("data-tab");
            const pane = document.getElementById(targetId);
            if (pane) pane.classList.add("active");

                if (targetId === "tab-advanced") {
                    catalogFilter = "performance";
                    catalogHostId = "advGroups";
                    renderCatalog();
                }
                if (targetId === "tab-routing") {
                    catalogFilter = "all";
                    catalogHostId = "gamingGroups";
                    renderCatalog();
                }
                if (targetId === "tab-network") {
                    catalogFilter = "cat:Network";
                    catalogHostId = "networkGroups";
                    renderCatalog();
                }
                if (targetId === "tab-processes") {
                fetchProcesses();
                fetchServices();
                fetchTasks();
            }
            if (targetId === "tab-startup") {
                fetchStartupApps();
            }
            if (targetId === "tab-advanced" || targetId === "tab-routing" || targetId === "tab-network") {
                fetchCatalog();
            }
        });
    });
}

// -----------------------------------------------------------------------------
// TOAST NOTIFICATIONS
// -----------------------------------------------------------------------------
function showToast(message, type = "info") {
    const container = document.getElementById("toastContainer");
    const toast = document.createElement("div");
    toast.className = "toast";
    
    // Icon colours come from CSS custom properties so they follow the active
    // theme; the inline fallbacks only apply if the vars are missing.
    const infoC = "var(--accent-cyan, #ffffff)";
    const okC = "var(--accent-emerald, #ffffff)";
    const errC = "var(--text-muted, #8e8e93)";
    const warnC = "var(--accent-amber, #c7c7cc)";

    let icon = `<span class="pulse-dot" style="color:${infoC};"></span>`;
    if (type === "success") icon = `<span class="pulse-dot" style="color:${okC};"></span>`;
    if (type === "error") icon = `<span class="pulse-dot" style="color:${errC};"></span>`;
    if (type === "warn") icon = `<span class="pulse-dot" style="color:${warnC};"></span>`;

    toast.innerHTML = `${icon} <span>${message}</span>`;
    container.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = "0";
        toast.style.transform = "translateY(8px)";
        toast.style.transition = "all 0.3s ease";
        setTimeout(() => toast.remove(), 300);
    }, 3800);
}

// -----------------------------------------------------------------------------
// LOG TERMINAL
// -----------------------------------------------------------------------------
function appendLog(text, type = "info") {
    const term = document.getElementById("terminalLog");
    const time = new Date().toLocaleTimeString();
    let prefixClass = "log-entry-info";
    if (type === "ok" || text.includes("[OK]")) prefixClass = "log-entry-ok";
    if (type === "warn" || text.includes("[WARN]")) prefixClass = "log-entry-warn";
    if (type === "err" || text.includes("[ERR]")) prefixClass = "log-entry-err";

    const line = document.createElement("div");
    line.className = prefixClass;
    line.textContent = `[${time}] ${text}`;
    term.appendChild(line);
    term.scrollTop = term.scrollHeight;
}

// -----------------------------------------------------------------------------
// SYSTEM STATUS AUDIT
// -----------------------------------------------------------------------------
async function fetchSystemStatus() {
    try {
        const res = await fetch(`${API_BASE}/api/status`);
        if (!res.ok) return;
        const data = await res.json();
        hideBootOverlay();

        // Hardware Specs Header
        if (data.cpu) document.getElementById("specCpu").textContent = data.cpu;
        if (data.gpus && data.gpus.length > 0) {
            document.getElementById("specGpu").textContent = `${data.gpus[0].Name} (${data.gpus[0].RefreshRate || '60Hz'})`;
        }
        if (data.os) document.getElementById("specOs").textContent = data.os;

        // Metric Tiles
        document.getElementById("valCpu").textContent = data.cpuLoad !== undefined ? data.cpuLoad : "4";
        document.getElementById("barCpu").style.width = `${Math.min(100, Math.max(5, data.cpuLoad || 4))}%`;

        if (data.ram) {
            document.getElementById("valRam").textContent = data.ram.used;
            document.getElementById("valRamTotal").textContent = `/ ${data.ram.total} GB`;
            document.getElementById("barRam").style.width = `${data.ram.percent}%`;
            document.getElementById("valRamSpeed").textContent = `${data.ram.speed || 6000} MT/s (${data.ram.sticks} Sticks)`;
        }

        if (data.processCount) {
            document.getElementById("valProcesses").textContent = data.processCount;
        }

        // Quick Audit Checklist + live switch state (skip re-render if unchanged)
        if (data.tweaks) {
            lastTweaks = data.tweaks;
            const auditJson = JSON.stringify(data.tweaks);
            if (auditJson !== lastAuditJson) {
                lastAuditJson = auditJson;
                renderQuickAudit(data.tweaks);
            }
            syncSwitches();
            updateBadge("badgeHagsOverall", data.tweaks.hags, "HAGS Active", "HAGS Off");
            const nvRow = document.getElementById("tweakRowNvidia");
            if (nvRow) nvRow.style.display = data.tweaks.nvidiaAvailable ? "" : "none";
        }

    } catch (e) {
        console.error("fetchSystemStatus error", e);
    }
}

function renderQuickAudit(tweaks) {
    if (!tweaks) return;
    const container = document.getElementById("quickAuditList");
    if (!container) return;

    const items = [
        { id: "hags", label: "Hardware Accelerated GPU Scheduling (HAGS)", active: tweaks.hags, desc: "Direct GPU VRAM Management" },
        { id: "platformTick", label: "High-Precision Invariant TSC Timer", active: tweaks.platformTick, desc: "useplatformtick = Yes (0.5ms precision)" },
        { id: "dynamicTick", label: "Disable Dynamic Ticks (Zero Clock Drift)", active: tweaks.dynamicTickDisabled, desc: "bcdedit /set disabledynamictick yes" },
        { id: "kernelRamLock", label: "Windows Kernel Locked in Physical RAM", active: tweaks.kernelRamLock, desc: "DisablePagingExecutive = 1" },
        { id: "netThrottle", label: "Windows Network Throttling Removed", active: tweaks.networkThrottlingDisabled, desc: "NetworkThrottlingIndex = 0xFFFFFFFF" },
        { id: "gameDvr", label: "Xbox GameDVR & Background Recording", active: tweaks.gameDvrDisabled, desc: "Freed background GPU encoding" },
        { id: "deliveryOpt", label: "Delivery Optimization P2P Blocked", active: tweaks.deliveryOptimizationDisabled, desc: "Zero random ping spikes" }
    ];

    container.innerHTML = items.map(item => `
        <div class="tweak-item" style="padding:10px 14px;">
            <div class="tweak-left">
                <div class="tweak-name" style="font-size:0.8rem;">
                    ${item.label}
                </div>
                <div class="tweak-desc" style="font-size:0.7rem;">${item.desc}</div>
            </div>
            <label class="switch" title="ON = optimized, OFF = Windows default">
                <input type="checkbox" data-tweak="${item.id}" ${item.active ? 'checked' : ''}>
                <span class="slider"></span>
            </label>
        </div>
    `).join("");
}

// -----------------------------------------------------------------------------
// TOGGLE SWITCHES — live system state, flippable both ways (ON = optimized)
// -----------------------------------------------------------------------------
let lastTweaks = null;
let lastTcp = null;
let lastAuditJson = "";
let lastCatalog = {};
let cachedCatalogList = [];
let cachedStartupApps = [];

function escapeHtml(str) {
    if (!str) return "";
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#039;");
}

function tweakState(id) {
    if (id === "tcpNoDelay") return !!(lastTcp && lastTcp.tcpNoDelay);
    if (id === "tcpAckFreq") return !!(lastTcp && lastTcp.tcpAckFrequency);
    if (id === "rss") return !!(lastTcp && lastTcp.rss);
    if (id === "qosLimit") return !!(lastTcp && lastTcp.qosLimit);
    if (id === "tcpPorts") return !!(lastTcp && lastTcp.tcpPorts);
    if (!lastTweaks) return false;
    switch (id) {
        case "hags": return !!lastTweaks.hags;
        case "gameOpt": return !!lastTweaks.gameOptimizations;
        case "dynamicTick": return !!lastTweaks.dynamicTickDisabled;
        case "platformTick": return !!lastTweaks.platformTick;
        case "kernelRamLock": return !!lastTweaks.kernelRamLock;
        case "netThrottle": return !!lastTweaks.networkThrottlingDisabled;
        case "gameDvr": return !!lastTweaks.gameDvrDisabled;
        case "deliveryOpt": return !!lastTweaks.deliveryOptimizationDisabled;
        case "powerPlan": return !!lastTweaks.ultimatePowerPlan;
        case "gameMode": return !!lastTweaks.gameMode;
        case "transparency": return !!lastTweaks.transparencyOff;
        case "menuDelay": return !!lastTweaks.menuFast;
        case "mousePrecision": return !!lastTweaks.precisionOff;
        case "memCompression": return !!lastTweaks.memDecompressed;
        case "cpuBoost": return !!lastTweaks.cpuBoost;
        case "nvidiaRid": return !!lastTweaks.nvidiaRid;
        case "hibernate": return !!lastTweaks.hibernate;
        case "netbios": return !!lastTweaks.netbios;
        case "teredo": return !!lastTweaks.teredo;
        case "isatap": return !!lastTweaks.isatap;
        case "sixtofour": return !!lastTweaks.sixtofour;
        default: return !!lastCatalog[id];
    }
}

// Sync every static switch (network/system tabs) to the real probed state
function syncSwitches() {
    document.querySelectorAll('input[data-tweak]').forEach(el => {
        // Skip quick-audit rows — renderQuickAudit sets those directly
        if (el.closest('#quickAuditList')) return;
        el.checked = tweakState(el.getAttribute('data-tweak'));
    });
}

// Human-readable name for a tweak. Tweak labels are imperative ("Disable X",
// "Remove Y", "Add Z"), so the switch being ON means that action is being
// APPLIED. The old code showed a generic "Enabling <id>" with the raw id
// (vbsOff), which contradicted the label and told the user nothing.
function tweakName(id) {
    const row = (cachedCatalogList || []).find(t => t.id === id);
    return (row && row.label) ? row.label : id;
}

async function setTweak(id, enabled) {
    const name = tweakName(id);
    showToast(enabled ? `Applying: ${name}...` : `Restoring default: ${name}...`, "info");
    appendLog(`[TWEAK] ${name} → ${enabled ? 'APPLYING' : 'RESTORING WINDOWS DEFAULT'}...`);
    lastCatalog[id] = !!enabled; // optimistic — corrected by refetch below
    try {
        const res = await fetch(`${API_BASE}/api/tweak/set`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ id, enabled })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] ${name} ${enabled ? 'applied' : 'restored to Windows default'}.${data.reboot ? ' Reboot recommended.' : ''}`, "ok");
            showToast(enabled ? `Applied: ${name}${data.reboot ? ' (reboot recommended)' : ''}` : `Restored: ${name}`, "success");
            fetchSystemStatus();
            fetchNetworkStatus();
            fetchCatalog();
        } else {
            appendLog(`[ERR] ${data.error || 'tweak failed'}`, "err");
            showToast(data.error || "Tweak failed", "error");
            fetchSystemStatus();
            fetchNetworkStatus();
            fetchCatalog();
        }
    } catch (e) {
        appendLog(`[ERR] Tweak ${id} failed: ${e.message}`, "err");
        fetchSystemStatus();
        fetchNetworkStatus();
        fetchCatalog();
    }
}

// -----------------------------------------------------------------------------
// ADVANCED CATALOG — 50+ data-driven tweaks rendered from the backend
// -----------------------------------------------------------------------------
// "performance" = only entries with a real, audited performance mechanism (the
// Performance Tweaks tab). "all" = every catalog entry grouped by category.
let catalogFilter = "performance";
let catalogHostId = "advGroups";

function renderCatalog() {
    const q = ((document.getElementById("advSearch") || {}).value || "").trim().toLowerCase();
    const countId = catalogHostId === "gamingGroups" ? "gamingCount"
                  : catalogHostId === "networkGroups" ? "networkTweakCount"
                  : "advCount";
    const countEl = document.getElementById(countId);
    const host = document.getElementById(catalogHostId);
    if (!host) return;

    const all = cachedCatalogList || [];
    // Three views over one catalog: the 11 audited performance entries, the
    // Network category (rendered inside the Network & Ping Lab), or everything
    // else grouped (Gaming Tweaks).
    //
    // Network is EXCLUDED from the Gaming Tweaks view on purpose - it has its own
    // tab now, and showing it in both places was the bug the human reported.
    const NETWORK_TAB_CATEGORIES = ["Network"];
    let list;
    if (catalogFilter === "performance") {
        list = all.filter(t => t.advanced === true);
    } else if (catalogFilter.startsWith("cat:")) {
        const want = catalogFilter.slice(4);
        list = all.filter(t => t.category === want);
    } else {
        list = all.filter(t => !NETWORK_TAB_CATEGORIES.includes(t.category));
    }
    if (!list || list.length === 0) {
        host.innerHTML = `<div style="color:var(--text-muted); font-size:0.8rem; padding:16px;">Loading catalog…</div>`;
        return;
    }

    const order = ["Gaming", "Network", "Privacy", "Interface", "System", "Updates", "AI Features"];
    const groups = {};
    const uncategorised = [];
    let totalMatching = 0;

    list.forEach(t => {
        lastCatalog[t.id] = !!t.active;
        const matchesQuery = !q || (
            (t.label || "").toLowerCase().includes(q) ||
            (t.desc || "").toLowerCase().includes(q) ||
            (t.caution || "").toLowerCase().includes(q) ||
            (t.id || "").toLowerCase().includes(q) ||
            (t.category || "").toLowerCase().includes(q)
        );
        if (matchesQuery) {
            totalMatching++;
            // A row with a missing or empty category used to key the group on the
            // literal string "undefined" (JS coerces the key), which rendered a
            // group literally titled "undefined" with no signal anything was wrong.
            // Collect those separately and name them honestly instead.
            const cat = (t.category || "").trim();
            if (!cat) { uncategorised.push(t); return; }
            (groups[cat] = groups[cat] || []).push(t);
        }
    });

    if (countEl) {
        countEl.textContent = q ? `${totalMatching} of ${list.length}` : `${list.length}`;
    }

    const matchingCategories = order.filter(c => groups[c] && groups[c].length > 0);
    // Any tweak the server sent in a category not in `order` still needs rendering,
    // otherwise a new category would silently vanish from the UI. GAMMA is right
    // that the fallback is correct and the SILENCE is the defect: keep the data,
    // leave a breadcrumb.
    const unknownCats = Object.keys(groups).filter(c => !order.includes(c)).sort();
    const renderOrder = matchingCategories.concat(unknownCats);

    const anomalies = unknownCats.length + (uncategorised.length ? 1 : 0);
    if (anomalies > 0) {
        const bits = [];
        if (unknownCats.length) bits.push(`unrecognised category: ${unknownCats.join(", ")}`);
        if (uncategorised.length) bits.push(`${uncategorised.length} tweak(s) with no category`);
        appendLog(`[WARN] catalog sent ${bits.join("; ")} — not in the UI's category list`, "err");
    }

    // Both conditions must be empty. Testing renderOrder alone silently dropped
    // every row when the whole catalog was uncategorised, because uncategorised
    // rows live in their own array and never reach renderOrder. Found by GAMMA.
    if (renderOrder.length === 0 && uncategorised.length === 0) {
        host.innerHTML = `
            <div style="text-align:center; padding:36px 16px; color:var(--text-muted);">
                <div style="font-size:0.92rem; font-weight:600; margin-bottom:6px; color:var(--text-secondary);">No tweaks matching "${escapeHtml(q)}"</div>
                <div style="font-size:0.78rem;">Try searching for a different keyword like "dns", "game", "telemetry", or "mouse".</div>
            </div>`;
    } else {
        const groupsHtml = renderOrder.map(c => `
            <div class="adv-group">
                <div class="adv-group-title">${escapeHtml(c)} <span class="adv-group-n">${groups[c].length}</span>${c === "AI Features" ? ' <span class="badge badge-neutral" title="Windows features that use AI or send data to a cloud model">cloud-dependent</span>' : ''}</div>
                <div class="tweak-list">
                ${groups[c].map(t => `
                    <div class="tweak-item${t.advanced ? ' is-advanced' : ''}">
                        <div class="tweak-left">
                            <div class="tweak-name">${escapeHtml(t.label)}${t.advanced ? ' <span class="badge badge-warning" title="Real performance effect - read the guidance, some trade security or battery">PERF</span>' : ''}${t.reboot ? ' <span class="badge badge-neutral" title="Needs reboot">↻</span>' : ''}${t.needsVerify ? ' <span class="badge badge-danger" title="Registry value not independently verified on this machine">unverified</span>' : ''}</div>
                            <div class="tweak-desc">${escapeHtml(t.desc)}</div>
                            ${t.caution ? `<div class="tweak-caution"><span class="tweak-caution-tag">${t.advanced ? 'Before you enable' : 'Note'}</span> ${escapeHtml(t.caution)}</div>` : ''}
                        </div>
                        <label class="switch" title="ON = optimized, OFF = Windows default">
                            <input type="checkbox" data-tweak="${escapeHtml(t.id)}" ${t.active ? 'checked' : ''}>
                            <span class="slider"></span>
                        </label>
                    </div>`).join("")}
                </div>
            </div>`).join("");

        const uncategorisedHtml = uncategorised.length ? `
            <div class="adv-group">
                <div class="adv-group-title">Uncategorised <span class="adv-group-n">${uncategorised.length}</span>
                    <span class="badge badge-danger" title="The server sent these without a category">no category</span></div>
                <div class="tweak-list">
                ${uncategorised.map(t => `
                    <div class="tweak-item is-advanced">
                        <div class="tweak-left">
                            <div class="tweak-name">${escapeHtml(t.label)} <span class="badge badge-danger">no category</span></div>
                            <div class="tweak-desc">${escapeHtml(t.desc || "")}</div>
                        </div>
                        <label class="switch" title="ON = optimized, OFF = Windows default">
                            <input type="checkbox" data-tweak="${escapeHtml(t.id)}" ${t.active ? 'checked' : ''}>
                            <span class="slider"></span>
                        </label>
                    </div>`).join("")}
                </div>
            </div>` : "";

        host.innerHTML = groupsHtml + uncategorisedHtml;
    }
    syncSwitches();
}

async function fetchCatalog() {
    try {
        const res = await fetch(`${API_BASE}/api/tweak/catalog`);
        if (!res.ok) return;
        cachedCatalogList = await res.json();
        renderCatalog();
    } catch (e) {
        console.error("fetchCatalog error", e);
    }
}

async function setService(name, optimize) {
    showToast(`${optimize ? 'Disabling' : 'Restoring'} ${name}...`, "info");
    try {
        const res = await fetch(`${API_BASE}/api/services/set`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name, optimized: optimize })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] Service '${name}' ${optimize ? 'stopped and disabled' : 'restored to automatic and started'}.`, "ok");
            showToast(`${name} ${optimize ? 'disabled' : 'restored'}`, "success");
            fetchServices();
        } else {
            appendLog(`[ERR] ${data.error || 'service change failed'}`, "err");
            showToast(data.error || "Service change failed", "error");
            fetchServices();
        }
    } catch (e) {
        appendLog(`[ERR] Service ${name} failed: ${e.message}`, "err");
    }
}

// -----------------------------------------------------------------------------
// NETWORK STATUS & MTU
// -----------------------------------------------------------------------------
async function fetchNetworkStatus() {
    try {
        const res = await fetch(`${API_BASE}/api/network`);
        if (!res.ok) return;
        const data = await res.json();

        if (data.interfaceDescription) {
            document.getElementById("specNic").textContent = `${data.interfaceDescription} (${data.linkSpeed || '2.5 Gbps'})`;
        }

        if (data.mtu) {
            document.getElementById("currentMtuDisplay").textContent = data.mtu;
            document.getElementById("mtuSlider").value = data.mtu;
            document.getElementById("mtuSliderVal").textContent = data.mtu;
        }

        // Update TCP switches from live state
        if (data.tcpSettings) {
            lastTcp = data.tcpSettings;
            syncSwitches();
        }

    } catch (e) {
        console.error("fetchNetworkStatus error", e);
    }
}

// Legacy badge helper kept for any remaining static badges
function updateBadge(id, isActive, activeText = "Active", inactiveText = "Disabled") {
    const el = document.getElementById(id);
    if (!el) return;
    if (el.matches && el.matches('input[type="checkbox"]')) {
        el.checked = !!isActive;
        return;
    }
    if (isActive) {
        el.className = "badge badge-active";
        el.textContent = activeText;
    } else {
        el.className = "badge badge-inactive";
        el.textContent = inactiveText;
    }
}

// -----------------------------------------------------------------------------
// LIVE PING RADAR & CANVAS SPARKLINE
// -----------------------------------------------------------------------------
let canvas, ctx;

function initCanvas() {
    canvas = document.getElementById("pingCanvas");
    if (!canvas) return;
    ctx = canvas.getContext("2d");
    resizeCanvas();
    window.addEventListener("resize", resizeCanvas);
}

function resizeCanvas() {
    if (!canvas) return;
    canvas.width = canvas.parentElement.clientWidth;
    canvas.height = canvas.parentElement.clientHeight;
    drawPingChart();
}

function startPingStream() {
    executePing();
    pingInterval = setInterval(executePing, 1500);
}

async function executePing(target = "1.1.1.1") {
    try {
        const res = await fetch(`${API_BASE}/api/ping`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ target })
        });
        if (!res.ok) return;
        const data = await res.json();

        if (!data.success) {
            // No fake numbers — show the gap honestly
            document.getElementById("valPing").textContent = "--";
            document.getElementById("valJitter").textContent = "Jitter: --";
            return;
        }

        if (data.avg > 0) {
            document.getElementById("valPing").textContent = data.avg;
            document.getElementById("valJitter").textContent = `Jitter: ${data.jitter}ms`;
            
            pingHistory.push(data.avg);
            if (pingHistory.length > MAX_PING_HISTORY) pingHistory.shift();

            // Calculate metrics
            const min = Math.min(...pingHistory);
            const max = Math.max(...pingHistory);
            const avg = Math.round((pingHistory.reduce((a, b) => a + b, 0) / pingHistory.length) * 10) / 10;
            
            document.getElementById("pingMin").textContent = min;
            document.getElementById("pingAvg").textContent = avg;
            document.getElementById("pingMax").textContent = max;
            document.getElementById("pingJitter").textContent = Math.round((max - min) * 10) / 10;

            drawPingChart();
        }
    } catch (e) {
        console.error("executePing error", e);
    }
}

function drawPingChart() {
    if (!ctx || !canvas || pingHistory.length < 2) return;
    const w = canvas.width;
    const h = canvas.height;

    ctx.clearRect(0, 0, w, h);

    // Subtle background grid lines
    ctx.strokeStyle = "rgba(255, 255, 255, 0.04)";
    ctx.lineWidth = 1;
    for (let y = 20; y < h; y += 30) {
        ctx.beginPath();
        ctx.moveTo(0, y);
        ctx.lineTo(w, y);
        ctx.stroke();
    }

    const maxVal = Math.max(...pingHistory, 35) + 5;
    const minVal = Math.max(0, Math.min(...pingHistory) - 5);
    const stepX = w / (MAX_PING_HISTORY - 1);

    // Gradient fill under the line — monochrome iOS
    const gradient = ctx.createLinearGradient(0, 0, 0, h);
    gradient.addColorStop(0, "rgba(255, 255, 255, 0.35)");
    gradient.addColorStop(1, "rgba(255, 255, 255, 0.0)");

    ctx.beginPath();
    pingHistory.forEach((val, i) => {
        const x = i * stepX;
        const norm = (val - minVal) / (maxVal - minVal);
        const y = h - (norm * (h - 24)) - 12;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });

    ctx.lineTo((pingHistory.length - 1) * stepX, h);
    ctx.lineTo(0, h);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    // Draw the bright stroke
    ctx.beginPath();
    pingHistory.forEach((val, i) => {
        const x = i * stepX;
        const norm = (val - minVal) / (maxVal - minVal);
        const y = h - (norm * (h - 24)) - 12;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    });

    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 2.5;
    ctx.stroke();

    // Draw pulse dot on last point
    const lastVal = pingHistory[pingHistory.length - 1];
    const lastX = (pingHistory.length - 1) * stepX;
    const lastNorm = (lastVal - minVal) / (maxVal - minVal);
    const lastY = h - (lastNorm * (h - 24)) - 12;

    ctx.beginPath();
    ctx.arc(lastX, lastY, 4.5, 0, Math.PI * 2);
    ctx.fillStyle = "#ffffff";
    ctx.fill();
    ctx.beginPath();
    ctx.arc(lastX, lastY, 8, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(255, 255, 255, 0.5)";
    ctx.lineWidth = 2;
    ctx.stroke();
}

// -----------------------------------------------------------------------------
// EVENT BINDINGS & ACTIONS
// -----------------------------------------------------------------------------
function bindEvents() {
    // Toggle switches (event delegation — rows re-render, so bind once globally)
    if (!bindEvents.switchesBound) {
        bindEvents.switchesBound = true;
        document.addEventListener("change", (e) => {
            const t = e.target;
            if (t && t.matches && t.matches('input[data-tweak]')) {
                setTweak(t.getAttribute("data-tweak"), t.checked);
            } else if (t && t.matches && t.matches('input[data-service]')) {
                setService(t.getAttribute("data-service"), t.checked);
            } else if (t && t.matches && t.matches('input[data-task]')) {
                setTask(t.getAttribute("data-task"), t.checked);
            } else if (t && t.matches && t.matches('input[data-startup]')) {
                toggleStartupApp(t.getAttribute("data-startup"), t.getAttribute("data-scope"), t.checked);
            }
        });
    }

    // Restore Point
    const btnRestore = document.getElementById("btnCreateRestore");
    if (btnRestore) btnRestore.addEventListener("click", createRestorePoint);

    // Revert Defaults
    const btnRevert = document.getElementById("btnRevertDefaults");
    if (btnRevert) btnRevert.addEventListener("click", revertDefaults);

    // Check for Updates
    const btnUpdates = document.getElementById("btnCheckUpdates");
    if (btnUpdates) btnUpdates.addEventListener("click", () => {
        if (btnUpdates.disabled) return;
        setUpdatesButton(true);
        showToast("Checking for updates...", "info");
        if (window.electronAPI && window.electronAPI.checkUpdates) window.electronAPI.checkUpdates();
        else { setUpdatesButton(false); showToast("Update checks need the desktop app.", "warn"); }
    });

    // Manual Ping
    const btnPing = document.getElementById("btnManualPing");
    if (btnPing) btnPing.addEventListener("click", () => {
        btnPing.textContent = "Pinging...";
        executePing().then(() => btnPing.textContent = "Ping Now");
    });

    // Standby RAM Purge
    const btnPurge1 = document.getElementById("btnQuickPurgeRam");
    const btnPurge2 = document.getElementById("btnPurgeRamTab");
    if (btnPurge1) btnPurge1.addEventListener("click", purgeStandbyRam);
    if (btnPurge2) btnPurge2.addEventListener("click", purgeStandbyRam);

    // MTU Slider
    const mtuSlider = document.getElementById("mtuSlider");
    if (mtuSlider) {
        mtuSlider.addEventListener("input", (e) => {
            document.getElementById("mtuSliderVal").textContent = e.target.value;
        });
    }

    // MTU Buttons
    const btnApplyGamingMtu = document.getElementById("btnApplyGamingMtu");
    if (btnApplyGamingMtu) btnApplyGamingMtu.addEventListener("click", () => applyMtu(1280));

    const btnApplyStdMtu = document.getElementById("btnApplyStandardMtu");
    if (btnApplyStdMtu) btnApplyStdMtu.addEventListener("click", () => applyMtu(1500));

    const btnRunMtu = document.getElementById("btnRunMtuTest");
    if (btnRunMtu) btnRunMtu.addEventListener("click", runMtuTest);

    // DNS Benchmark
    const btnDns = document.getElementById("btnBenchmarkDns");
    if (btnDns) btnDns.addEventListener("click", runDnsBenchmark);

    // Network Tweaks
    const btnNet = document.getElementById("btnApplyNetworkTweaks");
    if (btnNet) btnNet.addEventListener("click", applyNetworkTweaks);

    // System Tweaks
    const btnSys = document.getElementById("btnApplySystemTweaks");
    if (btnSys) btnSys.addEventListener("click", applySystemTweaks);

    // Debloat Services
    const btnDebloat = document.getElementById("btnDebloatServices");
    if (btnDebloat) btnDebloat.addEventListener("click", debloatServices);

    // Scheduled tasks: refresh + disable-all
    const btnRefTasks = document.getElementById("btnRefreshTasks");
    if (btnRefTasks) btnRefTasks.addEventListener("click", fetchTasks);
    const btnDisableTasks = document.getElementById("btnDisableAllTasks");
    if (btnDisableTasks) btnDisableTasks.addEventListener("click", disableAllTasks);

    // Advanced catalog search - instant client-side filtering
    const advSearch = document.getElementById("advSearch");
    if (advSearch) advSearch.addEventListener("input", renderCatalog);

    // Startup Apps Search & Refresh
    const startupSearch = document.getElementById("startupSearch");
    if (startupSearch) startupSearch.addEventListener("input", renderStartupApps);

    const btnRefStartup = document.getElementById("btnRefreshStartup");
    if (btnRefStartup) btnRefStartup.addEventListener("click", fetchStartupApps);

    // Refresh Processes
    const btnRefProc = document.getElementById("btnRefreshProcesses");
    if (btnRefProc) btnRefProc.addEventListener("click", fetchProcesses);

    // Clear Terminal
    const btnClearTerm = document.getElementById("btnClearTerminal");
    if (btnClearTerm) btnClearTerm.addEventListener("click", () => {
        document.getElementById("terminalLog").innerHTML = "";
        appendLog("Terminal cleared.");
    });
}

// -----------------------------------------------------------------------------
// API CALLS: BACKUP / REVERT
// -----------------------------------------------------------------------------
async function createRestorePoint() {
    showToast("Creating Windows System Restore Point...", "info");
    appendLog("[BACKUP] Requesting Windows Checkpoint-Computer...");

    try {
        const res = await fetch(`${API_BASE}/api/restore-point`, { method: "POST" });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] ${data.message}`, "ok");
            showToast("Safety Restore Point Created Successfully!", "success");
        } else {
            appendLog(`[WARN] ${data.message}`, "warn");
            showToast("Could not create restore point (check system protection).", "warn");
        }
    } catch (e) {
        appendLog(`[ERROR] Restore point failed: ${e.message}`, "err");
    }
}

async function revertDefaults() {
    if (!confirm("Revert network MTU, DNS, and BCD timer settings to Windows factory defaults?")) return;
    
    showToast("Reverting tweaks to factory defaults...", "warn");
    appendLog(">>> REVERTING SETTINGS TO WINDOWS DEFAULTS <<<");

    try {
        const res = await fetch(`${API_BASE}/api/revert-defaults`, { method: "POST" });
        const data = await res.json();
        if (data.success && data.logs) {
            data.logs.forEach(l => appendLog(l, "warn"));
            showToast("Defaults restored successfully.", "info");
            fetchSystemStatus();
            fetchNetworkStatus();
        }
    } catch (e) {
        appendLog(`[ERROR] Revert failed: ${e.message}`, "err");
    }
}

async function purgeStandbyRam() {
    showToast("Purging Working Sets & Standby Memory...", "info");
    try {
        const res = await fetch(`${API_BASE}/api/processes/clean-ram`, { method: "POST" });
        const data = await res.json();
        appendLog(`[OK] Emptied process working sets. Freed ~${data.freedMB} MB RAM. New free: ${data.newFreeGB} GB.`, "ok");
        showToast(`Freed ~${data.freedMB} MB RAM instantly!`, "success");
        fetchSystemStatus();
    } catch (e) {
        console.error("purgeStandbyRam error", e);
    }
}

// -----------------------------------------------------------------------------
// MTU & DNS API CALLS
// -----------------------------------------------------------------------------
async function runMtuTest() {
    showToast("Detecting unfragmented MTU payload...", "info");
    appendLog("[MTU] Executing ICMP packet fragmentation binary search against 1.1.1.1...");
    
    try {
        const res = await fetch(`${API_BASE}/api/mtu-test`);
        const data = await res.json();

        // success=false means the binary search never received a single reply,
        // so detectedMaxUnfragmentedMtu is still the 1252 default + 28 = 1280
        // seed. Presenting that as a measurement is indistinguishable from a
        // real 1280 result - and 1280 is also the hardcoded "recommended"
        // value. Show "--" rather than a fabricated number.
        if (data.success === false) {
            document.getElementById("detectedMtuDisplay").textContent = "--";
            appendLog(`[ERR] MTU test failed - no ICMP replies received. Detected MTU unavailable (target unreachable or probes blocked).`, "err");
            showToast("MTU test failed - target unreachable", "error");
        } else {
            document.getElementById("detectedMtuDisplay").textContent = `${data.detectedMaxUnfragmentedMtu} bytes (Payload: ${data.detectedMaxUnfragmentedMtu - 28})`;
            appendLog(`[OK] Max Unfragmented MTU detected: ${data.detectedMaxUnfragmentedMtu}. Recommended: 1280.`, "ok");
            showToast(`Detected MTU: ${data.detectedMaxUnfragmentedMtu}`, "info");
        }
    } catch (e) {
        appendLog(`[ERR] MTU test failed: ${e.message}`, "err");
    }
}

async function applyMtu(val) {
    showToast(`Setting Subinterface MTU to ${val}...`, "info");
    try {
        const res = await fetch(`${API_BASE}/api/apply-mtu`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ mtu: val })
        });
        const data = await res.json();
        if (data.success) {
            document.getElementById("currentMtuDisplay").textContent = val;
            appendLog(`[OK] Subinterface persistent MTU set to ${val}.`, "ok");
            showToast(`MTU updated to ${val}`, "success");
        }
    } catch (e) {
        appendLog(`[ERR] Setting MTU failed: ${e.message}`, "err");
    }
}

async function runDnsBenchmark() {
    const btn = document.getElementById("btnBenchmarkDns");
    btn.textContent = "Benchmarking...";
    showToast("Benchmarking DNS resolvers...", "info");
    appendLog("[DNS] Testing ICMP latency to Cloudflare, Google, Quad9, AdGuard...");

    try {
        const res = await fetch(`${API_BASE}/api/dns-benchmark`);
        const list = await res.json();

        const tbody = document.getElementById("dnsBenchmarkBody");
        tbody.innerHTML = list.map(item => `
            <tr>
                <td><strong>${item.name}</strong><br><span style="font-size:0.68rem; color:var(--text-muted);">${item.provider}</span></td>
                <td style="font-family:var(--font-mono); font-size:0.74rem;">${item.primary}<br>${item.secondary}</td>
                <td><span class="badge ${item.latency < 25 ? 'badge-active' : item.latency < 999 ? 'badge-neutral' : 'badge-inactive'}">${item.latency < 999 ? item.latency + ' ms' : 'Timeout'}</span></td>
                <td><button class="btn btn-secondary btn-sm" onclick="applyDns(['${item.primary}', '${item.secondary}'])">Apply</button></td>
            </tr>
        `).join("");

        // Rows sort ascending by latency, so untested providers (latency 999,
        // status "Timeout") sink to the tail. That means list[0] is a genuinely
        // measured resolver whenever ANY row measured - but if the deadline
        // expired before a single probe landed, every row is 999 and list[0]
        // would still name a "winner" that was never tested, while claiming
        // success. Gate on status so a total timeout reports as one.
        const winner = list[0];
        if (winner && winner.status === "Online") {
            appendLog(`[OK] DNS Benchmark complete. Lowest latency: ${winner.name} (${winner.latency} ms)`, "ok");
            showToast(`Fastest DNS: ${winner.name} (${winner.latency}ms)`, "success");
        } else {
            appendLog(`[ERR] DNS benchmark timed out - no resolver responded within the time budget. Results discarded.`, "err");
            showToast("DNS benchmark timed out - no resolver responded", "error");
        }
    } catch (e) {
        appendLog(`[ERR] DNS benchmark failed: ${e.message}`, "err");
    } finally {
        btn.textContent = "Benchmark DNS";
    }
}

window.applyDns = async function(dnsArray) {
    showToast(`Applying DNS (${dnsArray.join(", ")})...`, "info");
    try {
        const res = await fetch(`${API_BASE}/api/apply-dns`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ dns: dnsArray })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] DNS assigned: ${dnsArray.join(", ")}. Cache flushed.`, "ok");
            showToast("DNS Assigned & Cache Flushed!", "success");
            fetchNetworkStatus();
        }
    } catch (e) {
        appendLog(`[ERR] Assigning DNS failed: ${e.message}`, "err");
    }
};

async function applyNetworkTweaks() {
    showToast("Applying TCP & NIC Network Optimizations...", "info");
    try {
        const res = await fetch(`${API_BASE}/api/tweak/network`, { method: "POST" });
        const data = await res.json();
        if (data.success && data.logs) {
            data.logs.forEach(l => appendLog(l, "ok"));
            showToast("Network Stack Tuned for Lowest Latency!", "success");
            fetchNetworkStatus();
        }
    } catch (e) {
        appendLog(`[ERR] Network tweaks failed: ${e.message}`, "err");
    }
}

async function applySystemTweaks() {
    showToast("Applying Kernel & Latency Optimizations...", "info");
    try {
        const res = await fetch(`${API_BASE}/api/tweak/system`, { method: "POST" });
        const data = await res.json();
        if (data.success && data.logs) {
            data.logs.forEach(l => appendLog(l, "ok"));
            showToast("Kernel & Timers Tuned! (Restart recommended)", "success");
            fetchSystemStatus();
        }
    } catch (e) {
        appendLog(`[ERR] System tweaks failed: ${e.message}`, "err");
    }
}

// -----------------------------------------------------------------------------
// SERVICES & PROCESSES
// -----------------------------------------------------------------------------
async function fetchServices() {
    try {
        const res = await fetch(`${API_BASE}/api/services`);
        if (!res.ok) return;
        const list = await res.json();

        const tbody = document.getElementById("servicesTableBody");
        if (!tbody) return;

        tbody.innerHTML = list.map(s => `
            <tr>
                <td><strong>${s.name}</strong></td>
                <td>${s.displayName}</td>
                <td><span class="badge ${s.impact === 'High' ? 'badge-warning' : 'badge-neutral'}">${s.impact}</span></td>
                <td>
                    <label class="switch switch-sm" title="ON = disabled (optimized), OFF = running">
                        <input type="checkbox" data-service="${s.name}" ${s.isOptimized ? 'checked' : ''}>
                        <span class="slider"></span>
                    </label>
                </td>
            </tr>
        `).join("");
    } catch (e) {
        console.error("fetchServices error", e);
    }
}

async function debloatServices() {
    showToast("Disabling Telemetry & Bloatware Services...", "info");
    try {
        const res = await fetch(`${API_BASE}/api/services/optimize`, { method: "POST" });
        const data = await res.json();
        if (data.success && data.logs) {
            data.logs.forEach(l => appendLog(l, "ok"));
            showToast("Telemetry Services Disabled!", "success");
            fetchServices();
        }
    } catch (e) {
        appendLog(`[ERR] Service debloat failed: ${e.message}`, "err");
    }
}

async function fetchTasks() {
    try {
        const res = await fetch(`${API_BASE}/api/tasks`);
        if (!res.ok) return;
        const list = await res.json();

        const tbody = document.getElementById("tasksTableBody");
        if (!tbody) return;

        tbody.innerHTML = list.map(t => `
            <tr>
                <td><strong>${t.displayName}</strong><br><span style="font-size:0.68rem; color:var(--text-muted); font-family:var(--font-mono);">${t.path}</span></td>
                <td><span class="badge ${t.state === 'Disabled' || t.state === 'NotFound' ? 'badge-active' : 'badge-neutral'}">${t.state.toUpperCase()}</span></td>
                <td><span class="badge ${t.impact === 'High' ? 'badge-warning' : 'badge-neutral'}">${t.impact}</span></td>
                <td>
                    <label class="switch switch-sm" title="ON = disabled (optimized), OFF = enabled">
                        <input type="checkbox" data-task="${t.path}" ${t.isOptimized ? 'checked' : ''}>
                        <span class="slider"></span>
                    </label>
                </td>
            </tr>
        `).join("");
    } catch (e) {
        console.error("fetchTasks error", e);
    }
}

async function setTask(path, disabled) {
    showToast(`${disabled ? 'Disabling' : 'Enabling'} scheduled task...`, "info");
    try {
        const res = await fetch(`${API_BASE}/api/tasks/set`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ path, disabled })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] Task '${path}' ${disabled ? 'disabled' : 're-enabled'}.`, "ok");
            showToast(`Task ${disabled ? 'disabled' : 're-enabled'}`, "success");
            fetchTasks();
        } else {
            appendLog(`[ERR] ${data.error || 'task change failed'}`, "err");
            showToast(data.error || "Task change failed", "error");
            fetchTasks();
        }
    } catch (e) {
        appendLog(`[ERR] Task change failed: ${e.message}`, "err");
    }
}

async function disableAllTasks() {
    showToast("Disabling all telemetry tasks...", "info");
    try {
        const res = await fetch(`${API_BASE}/api/tasks`);
        const list = await res.json();
        for (const t of list.filter(t => !t.isOptimized)) {
            await fetch(`${API_BASE}/api/tasks/set`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ path: t.path, disabled: true })
            });
        }
        appendLog("[OK] All telemetry scheduled tasks disabled.", "ok");
        showToast("All telemetry tasks disabled!", "success");
        fetchTasks();
    } catch (e) {
        appendLog(`[ERR] Disable-all tasks failed: ${e.message}`, "err");
    }
}

async function fetchProcesses() {
    try {
        const res = await fetch(`${API_BASE}/api/processes`);
        if (!res.ok) return;
        const list = await res.json();

        const tbody = document.getElementById("processTableBody");
        if (!tbody) return;

        tbody.innerHTML = list.map(p => `
            <tr>
                <td><strong>${p.name}</strong></td>
                <td style="font-family:var(--font-mono);">${p.id}</td>
                <td style="font-family:var(--font-mono);">${p.memoryMB} MB</td>
                <td>
                    <span class="badge ${p.isBloat ? 'badge-warning' : 'badge-neutral'}">
                        ${p.isBloat ? 'BACKGROUND BLOAT' : 'ACTIVE APP'}
                    </span>
                </td>
                <td>
                    <button class="btn btn-danger btn-sm" style="padding:2px 8px; font-size:0.68rem;" onclick="killProcess(${p.id}, '${p.name}')">End Task</button>
                </td>
            </tr>
        `).join("");
    } catch (e) {
        console.error("fetchProcesses error", e);
    }
}

window.killProcess = async function(pid, name) {
    if (!confirm(`Terminate process ${name} (PID: ${pid})?`)) return;
    try {
        const res = await fetch(`${API_BASE}/api/processes/kill`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ pid })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] Process ${name} (${pid}) terminated.`, "ok");
            showToast(`Terminated ${name}`, "info");
            fetchProcesses();
            fetchSystemStatus();
        }
    } catch (e) {
        appendLog(`[ERR] Failed to kill process ${pid}: ${e.message}`, "err");
    }
};

// -----------------------------------------------------------------------------
// STARTUP APPLICATIONS MANAGER
// -----------------------------------------------------------------------------
function renderStartupApps() {
    const tbody = document.getElementById("startupTableBody");
    const countEl = document.getElementById("startupCount");
    if (!tbody) return;

    const q = ((document.getElementById("startupSearch") || {}).value || "").trim().toLowerCase();
    const list = cachedStartupApps || [];

    const filtered = list.filter(item => {
        if (!q) return true;
        return (
            (item.name || "").toLowerCase().includes(q) ||
            (item.publisher || "").toLowerCase().includes(q) ||
            (item.location || "").toLowerCase().includes(q) ||
            (item.command || "").toLowerCase().includes(q)
        );
    });

    if (countEl) {
        countEl.textContent = q ? `${filtered.length} of ${list.length} apps` : `${list.length} apps`;
    }

    if (filtered.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center; padding:32px 16px; color:var(--text-muted); font-size:0.82rem;">${q ? `No startup apps match "${escapeHtml(q)}"` : 'No startup applications found.'}</td></tr>`;
        return;
    }

    tbody.innerHTML = filtered.map(app => {
        const impactBadge = app.impact === "High" ? "badge-danger" : app.impact === "Medium" ? "badge-warning" : "badge-neutral";
        const safeName = escapeHtml(app.name);
        const safePublisher = escapeHtml(app.publisher || 'Unknown');
        const safeLocation = escapeHtml(app.location || 'Registry');
        const safeCommand = escapeHtml(app.command || '');
        const attrName = app.name.replace(/"/g, '&quot;');
        const attrScope = (app.scope || 'User').replace(/"/g, '&quot;');

        return `
            <tr>
                <td>
                    <div style="font-weight:600; color:var(--text-primary); font-size:0.84rem;">${safeName}</div>
                    <div style="font-size:0.7rem; color:var(--text-muted); font-family:var(--font-mono); max-width:320px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;" title="${safeCommand}">${safeCommand}</div>
                </td>
                <td style="color:var(--text-secondary); font-size:0.8rem;">${safePublisher}</td>
                <td><span class="badge badge-neutral" style="font-size:0.7rem;">${safeLocation}</span></td>
                <td><span class="badge ${impactBadge}">${app.impact}</span></td>
                <td>
                    <label class="switch" title="${app.enabled ? 'Enabled at startup — click to disable' : 'Disabled — click to enable'}">
                        <input type="checkbox" data-startup="${attrName}" data-scope="${attrScope}" ${app.enabled ? 'checked' : ''}>
                        <span class="slider"></span>
                    </label>
                </td>
            </tr>
        `;
    }).join("");
}

async function fetchStartupApps() {
    const tbody = document.getElementById("startupTableBody");
    if (tbody && (!cachedStartupApps || cachedStartupApps.length === 0)) {
        tbody.innerHTML = `<tr><td colspan="5" style="text-align:center; padding:24px; color:var(--text-muted);">Probing startup applications…</td></tr>`;
    }
    try {
        const res = await fetch(`${API_BASE}/api/startup`);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        cachedStartupApps = await res.json();
        renderStartupApps();
        appendLog(`[STARTUP] Loaded ${cachedStartupApps.length} startup items.`);
    } catch (e) {
        console.error("fetchStartupApps error", e);
        if (tbody) tbody.innerHTML = `<tr><td colspan="5" style="text-align:center; padding:20px; color:#ff453a;">Failed to load startup apps: ${escapeHtml(e.message)}</td></tr>`;
    }
}

async function toggleStartupApp(name, scope, enabled) {
    showToast(`${enabled ? 'Enabling' : 'Disabling'} startup app ${name}...`, "info");
    try {
        const res = await fetch(`${API_BASE}/api/startup/set`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name, scope, enabled })
        });
        const data = await res.json();
        if (data.success) {
            appendLog(`[OK] Startup application '${name}' set to ${enabled ? 'ENABLED' : 'DISABLED'}.`, "ok");
            showToast(`${name} ${enabled ? 'enabled' : 'disabled'} at startup`, "success");
            const found = cachedStartupApps.find(a => a.name === name);
            if (found) found.enabled = enabled;
            renderStartupApps();
        } else {
            appendLog(`[ERR] Failed to change ${name}: ${data.error || 'Unknown error'}`, "err");
            showToast(data.error || "Failed to change startup app", "error");
            fetchStartupApps();
        }
    } catch (e) {
        appendLog(`[ERR] Failed to toggle startup app ${name}: ${e.message}`, "err");
        showToast("Startup toggle failed: " + e.message, "error");
        fetchStartupApps();
    }
}
