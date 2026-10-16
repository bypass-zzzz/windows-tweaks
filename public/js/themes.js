/* ==============================================================================
   WINDOWS TWEAKS — THEME ENGINE (js/themes.js)

   Loaded by index.html and splash.html before first paint. Every theme is two
   authored hex colours. The DARKER of the pair becomes the shell (backgrounds,
   surfaces, chrome) and the LIGHTER becomes the highlight (accents, glows,
   fills) — so both "primary/accent" orderings work without a mapping table.
   The engine writes the whole palette as CSS custom properties inline on
   <html>; css/style.css reads those variables everywhere. There is no
   [data-theme] CSS any more, so adding a theme = ONE entry in THEMES below.

   `mono` is special: its palette is the hand-tuned default in style.css and
   the engine only clears its inline overrides (untinted mode).

   `data-tinted` on <html> marks "coloured theme active" and is what the
   stylesheet keys its two motion/extra flavours off (mono vs everything else).
   ============================================================================== */
(function () {
    "use strict";

    var STORE_KEY = "wt.theme";

    /* Authored pairs, in the order they were supplied. */
    var THEMES = [
        { id: "mono",     name: "Monochrome", primary: "#ffffff", accent: "#000000", mono: true },
        { id: "obsidian", name: "Obsidian",   primary: "#ff2d55", accent: "#0d0507" },
        { id: "oxblood",  name: "Oxblood",    primary: "#8b0000", accent: "#080808" },
        { id: "midnight", name: "Midnight",   primary: "#080808", accent: "#191970" },
        { id: "amethyst", name: "Amethyst",   primary: "#080808", accent: "#6a0dad" },
        { id: "copper",   name: "Copper",     primary: "#252525", accent: "#b87333" },
        { id: "wine",     name: "Wine",       primary: "#660000", accent: "#111111" },
        { id: "indigo",   name: "Indigo",     primary: "#4b0082", accent: "#0a0a0a" },
        { id: "forest",   name: "Forest",     primary: "#006400", accent: "#151515" },
        { id: "prussian", name: "Prussian",   primary: "#003153", accent: "#171717" },
        { id: "neon",     name: "Neon",       primary: "#39ff14", accent: "#101010" },
        { id: "azure",    name: "Azure",      primary: "#00bfff", accent: "#121212" },
        { id: "magenta",  name: "Magenta",    primary: "#ff00ff", accent: "#161616" },
        { id: "molten",   name: "Molten",     primary: "#ff4500", accent: "#141414" },
        { id: "gold",     name: "Gold",       primary: "#d4af37", accent: "#202020" },
        { id: "platinum", name: "Platinum",   primary: "#c0c0c0", accent: "#181818" },
        { id: "bordeaux", name: "Bordeaux",   primary: "#800020", accent: "#d8cfc4" },
        { id: "slate",    name: "Slate",      primary: "#708090", accent: "#e5e5e5" }
    ];

    /* ---------- colour math (plain sRGB; the palettes are display colours,
       not perceptual proofs, and every channel here stays well-behaved) ---- */
    function hexToRgb(value) {
        var h = String(value).replace("#", "");
        if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
        var n = parseInt(h, 16);
        if (isNaN(n)) return { r: 0, g: 0, b: 0 };
        return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
    }
    function clamp(n) { return Math.max(0, Math.min(255, Math.round(n))); }
    function mix(a, b, t) {
        return { r: clamp(a.r + (b.r - a.r) * t), g: clamp(a.g + (b.g - a.g) * t), b: clamp(a.b + (b.b - a.b) * t) };
    }
    var WHITE = { r: 255, g: 255, b: 255 }, BLACK = { r: 0, g: 0, b: 0 };
    function lighten(c, t) { return mix(c, WHITE, t); }
    function darken(c, t) { return mix(c, BLACK, t); }
    function rgba(c, a) { return "rgba(" + c.r + ", " + c.g + ", " + c.b + ", " + a + ")"; }
    function hex(c) { return "#" + [c.r, c.g, c.b].map(function (x) { return x.toString(16).padStart(2, "0"); }).join(""); }
    /* WCAG relative luminance — used to pick legible foregrounds on fills. */
    function luminance(c) {
        var f = function (x) { x /= 255; return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
    }
    function onColor(c) { return luminance(c) > 0.4 ? "#000000" : "#ffffff"; }

    /* ---------- the derivation: shell + highlight -> every CSS variable ----- */
    function derive(shell, hi) {
        var bgBase = darken(shell, 0.55);
        var emerald = lighten(hi, 0.18);
        var violet = darken(hi, 0.25);
        var rose = lighten(hi, 0.40);
        var amber = darken(hi, 0.15);
        var txtFg = onColor(hi);
        return {
            "--bg-base": hex(bgBase),
            "--bg-surface": hex(shell),
            "--bg-card": "linear-gradient(150deg, " + rgba(hi, 0.10) + " 0%, " + rgba(hi, 0.02) + " 100%)",
            "--bg-card-hover": "linear-gradient(150deg, " + rgba(hi, 0.18) + " 0%, " + rgba(hi, 0.04) + " 100%)",
            "--bg-card-active": "linear-gradient(150deg, " + rgba(hi, 0.24) + " 0%, " + rgba(hi, 0.06) + " 100%)",
            "--border-subtle": rgba(hi, 0.14),
            "--border-medium": rgba(hi, 0.26),
            "--border-accent": rgba(hi, 0.48),
            "--glass-highlight": "inset 0 1px 0 " + rgba(lighten(hi, 0.20), 0.22),
            "--text-primary": hex(mix(hi, WHITE, 0.94)),
            "--text-secondary": hex(mix(lighten(hi, 0.42), { r: 207, g: 207, b: 214 }, 0.5)),
            "--text-muted": hex(mix(hi, { r: 111, g: 111, b: 120 }, 0.68)),
            "--accent-cyan": hex(hi),
            "--accent-cyan-glow": rgba(hi, 0.32),
            "--accent-emerald": hex(emerald),
            "--accent-emerald-glow": rgba(emerald, 0.22),
            "--accent-violet": hex(violet),
            "--accent-violet-glow": rgba(violet, 0.18),
            "--accent-rose": hex(rose),
            "--accent-amber": hex(amber),
            "--mono-white": hex(emerald),
            "--mono-light": hex(lighten(hi, 0.55)),
            "--mono-mid": hex(mix(hi, { r: 142, g: 142, b: 147 }, 0.55)),
            "--mono-dark": hex(mix(shell, hi, 0.26)),
            "--gradient-primary": "linear-gradient(180deg, " + hex(lighten(hi, 0.22)) + " 0%, " + hex(hi) + " 50%, " + hex(violet) + " 100%)",
            "--gradient-surface": "linear-gradient(180deg, " + hex(lighten(shell, 0.06)) + " 0%, " + hex(bgBase) + " 100%)",
            "--gradient-glass": "linear-gradient(150deg, " + rgba(hi, 0.20) + " 0%, " + rgba(hi, 0.05) + " 50%, " + rgba(hi, 0.10) + " 100%)",
            "--gradient-text": "linear-gradient(180deg, " + hex(lighten(hi, 0.78)) + " 20%, " + hex(hi) + " 100%)",
            "--shadow-card": "0 20px 60px rgba(0,0,0,0.75), 0 0 0 1px " + rgba(hi, 0.08) + ", 0 1px 0 " + rgba(lighten(hi, 0.20), 0.10) + " inset",
            "--shadow-glow": "0 0 34px " + rgba(hi, 0.30),
            "--shadow-btn": "0 6px 24px " + rgba(hi, 0.34) + ", 0 1px 0 " + rgba(lighten(hi, 0.55), 0.5) + " inset",
            "--wash-1": rgba(hi, 0.20),
            "--wash-2": rgba(darken(hi, 0.45), 0.16),
            "--wash-3": rgba(darken(hi, 0.65), 0.14),
            "--wash-base": "linear-gradient(180deg, " + hex(lighten(shell, 0.06)) + " 0%, " + hex(bgBase) + " 42%, #000000 100%)",
            "--app-header-bg": rgba(shell, 0.66),
            "--scroll-thumb": "linear-gradient(180deg, " + rgba(hi, 0.42) + ", " + rgba(hi, 0.16) + ")",
            "--scroll-thumb-hover": rgba(hi, 0.62),
            "--selection-bg": rgba(hi, 0.85),
            "--selection-fg": txtFg,
            "--focus-ring": rgba(hi, 0.75),
            "--badge-active-bg": "linear-gradient(180deg, " + hex(hi) + ", " + hex(violet) + ")",
            "--badge-active-fg": "#ffffff",
            "--badge-active-border": rgba(lighten(hi, 0.32), 0.5),
            "--badge-active-shadow": "0 2px 14px " + rgba(hi, 0.42),
            "--badge-warning-bg": rgba(hi, 0.16),
            "--badge-warning-fg": hex(rose),
            "--badge-warning-border": rgba(hi, 0.34),
            "--badge-neutral-bg": rgba(hi, 0.08),
            "--btn-primary-fg": txtFg,
            "--btn-primary-hover-shadow": "0 6px 28px " + rgba(hi, 0.30) + ", inset 0 1px 0 " + rgba(lighten(hi, 0.78), 0.8),
            "--nav-active-fg": txtFg,
            "--nav-active-shadow": "0 2px 18px " + rgba(hi, 0.40) + ", inset 0 1px 0 " + rgba(lighten(hi, 0.68), 0.55),
            "--nav-active-border": rgba(lighten(hi, 0.32), 0.5),
            "--metric-icon-bg": rgba(hi, 0.12),
            "--metric-icon-border": rgba(hi, 0.14),
            "--metric-icon-fg": hex(rose),
            "--table-wrapper-bg": rgba(hi, 0.03),
            "--legend-bg": rgba(hi, 0.05),
            "--boot-logo-bg": "var(--gradient-primary)",
            "--boot-logo-border": rgba(lighten(hi, 0.3), 0.28),
            "--boot-title-grad": "linear-gradient(180deg, " + hex(lighten(hi, 0.78)) + " 22%, " + hex(hi) + " 100%)",
            "--boot-fill-bg": "linear-gradient(90deg, " + hex(violet) + ", " + hex(lighten(hi, 0.22)) + " 70%, " + rgba(hi, 0.85) + ")",
            "--boot-fill-glow": "0 0 14px " + rgba(hi, 0.6),
            "--boot-bar-bg": rgba(hi, 0.12),
            "--slider-track": rgba(hi, 0.14),
            "--slider-track-border": rgba(hi, 0.22),
            "--slider-knob": "linear-gradient(180deg, " + hex(lighten(hi, 0.55)) + ", " + hex(amber) + ")",
            "--slider-knob-shadow": "0 2px 8px rgba(0,0,0,0.5)",
            "--slider-checked-bg": "var(--gradient-primary)",
            "--slider-checked-border": rgba(lighten(hi, 0.32), 0.55),
            "--slider-checked-glow": "0 0 18px " + rgba(hi, 0.45),
            "--slider-checked-knob": "#ffffff",
            "--slider-checked-knob-border": "rgba(255,255,255,0.6)",
            "--theme-dot-bg": "linear-gradient(180deg, " + hex(lighten(hi, 0.22)) + ", " + hex(violet) + ")",
            "--theme-dot-shadow": "0 0 10px " + rgba(hi, 0.8),
            "--theme-hover-shadow": "0 0 18px " + rgba(hi, 0.30),
            "--brand-pulse": rgba(hi, 0.38),
            "--adv-caution-bg": rgba(hi, 0.07),
            "--adv-caution-border": rgba(hi, 0.16),
            "--select-bg": hex(darken(shell, 0.30)),
            "--select-bg-hover": hex(darken(shell, 0.18)),
            "--select-fg": hex(mix(hi, WHITE, 0.92)),
            "--select-border": rgba(hi, 0.22),
            "--select-border-hover": rgba(hi, 0.38)
        };
    }

    /* Every property the engine may write (used to clear on theme switch). */
    var MANAGED = Object.keys(derive(hexToRgb("#808080"), hexToRgb("#404040")));

    function byId(id) {
        for (var i = 0; i < THEMES.length; i++) if (THEMES[i].id === id) return THEMES[i];
        return THEMES[0];
    }

    /* Resolve the authored pair into the actual direction (dark = shell). */
    function themed(theme) {
        var a = hexToRgb(theme.primary), b = hexToRgb(theme.accent);
        var shell = luminance(a) <= luminance(b) ? a : b;
        var hi = (shell === a) ? b : a;
        return { shell: shell, hi: hi };
    }

    function clear(root) {
        for (var i = 0; i < MANAGED.length; i++) root.style.removeProperty(MANAGED[i]);
    }

    function apply(id, persist) {
        var theme = byId(id);
        var root = document.documentElement;
        clear(root);
        var colors = themed(theme);
        if (!theme.mono) {
            var vars = derive(colors.shell, colors.hi);
            for (var k in vars) root.style.setProperty(k, vars[k]);
            root.setAttribute("data-tinted", "true");
        } else {
            root.removeAttribute("data-tinted");
        }
        root.setAttribute("data-theme", theme.id);
        if (persist) {
            try { localStorage.setItem(STORE_KEY, theme.id); } catch (_) { /* file:// storage may be unavailable */ }
        }
        return theme;
    }

    function savedId() {
        try { return localStorage.getItem(STORE_KEY) || "mono"; } catch (_) { return "mono"; }
    }

    window.WTTheme = {
        KEY: STORE_KEY,
        list: function () {
            return THEMES.map(function (t) {
                var c = themed(t);
                var shell = t.mono ? BLACK : c.shell;
                var hi = t.mono ? WHITE : c.hi;
                return {
                    id: t.id, name: t.name, primary: t.primary, accent: t.accent,
                    shell: hex(shell),
                    highlight: hex(hi),
                    /* Wheel-only tones: `core` keeps the pair's dark end visible
                       at the wedge's inner edge, `gloss` is the specular outer
                       rim that gives the glass its lit edge. */
                    core: hex(mix(shell, hi, 0.32)),
                    gloss: hex(lighten(hi, 0.30))
                };
            });
        },
        current: savedId,
        apply: function (id) { return apply(id, true); },
        applySaved: function () { return apply(savedId(), false); }
    };
})();
