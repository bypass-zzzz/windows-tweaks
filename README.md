# Windows Tweaks

**Windows Optimizations for Gaming - an ultra-low latency, zero-bloat tuning suite for Windows.**

Windows Tweaks is a desktop app that applies real, measurable performance and de-bloat changes to the machine it runs on: CPU timer behavior and scheduling, the GPU driver path, the TCP/IP stack and NIC, background services, scheduled telemetry tasks, startup programs, and a data-driven catalog of 90-plus registry tweaks spanning performance, network, privacy, interface, AI features and updates.

It is deliberately **not** a "one-click optimizer". Every switch is driven by what the machine actually reports: the app reads live state first, writes only when asked, and then reads the value back to prove the write landed. Any tweak that trades something away - battery life, security, stability - says so on its face, and says who should not enable it.

Current release: **v3.1.8 (KERNEL EDITION)**, published to GitHub Releases with in-app auto-update (`electron-updater` + `latest.yml`).

## Contents

- [What the app does, tab by tab](#what-the-app-does-tab-by-tab)
- [The tweak engine](#the-tweak-engine)
- [Safety model](#safety-model)
- [Under the hood](#under-the-hood)
- [Verification tooling](#verification-tooling)
- [Build from source](#build-from-source)
- [Theming](#theming)
- [Notable design decisions](#notable-design-decisions)
- [Requirements](#requirements)

## What the app does, tab by tab

### 1. Overview and Telemetry

The dashboard. A hardware strip (CPU, GPU, NIC, OS) plus live metric tiles:

- **Network Ping** - rolling latency to 1.1.1.1 with a jitter readout.
- **CPU Activity** - load percentage, live clock, and an "Invariant TSC" badge wired to the machine's actual `useplatformtick` state.
- **Physical Memory** - usage and installed total, RAM speed, a "Kernel In RAM" badge bound to the real `DisablePagingExecutive` value, and a **Purge RAM** button (trims working sets / purges the standby list).
- **Active Processes** - count, with Telemetry and Debloated badges computed from live state, not markup.
- **Real-Time Latency Stream** - a rolling canvas graph with min / avg / max / jitter and a manual ping trigger.
- **Optimization Engine Status** - a live checklist of the core optimizations and whether each is actually applied.

### 2. Network and Ping Lab

- **MTU** - locks the active subinterface to the standard 1500. (A previous version forced 1280; see [Notable design decisions](#notable-design-decisions).)
- **DNS benchmark and switcher** - measures Cloudflare / Google / Quad9 resolution latency side by side and applies the winner in one click.
- **Network Components** - everything the active adapter is bound to, with "Keep IPv4 Only" (fenced with an honest warning that disabling IPv6 breaks Steam, parts of Windows Update and some VPNs) and a one-click **Restore** that puts back exactly what was changed. The IPv4 binding itself is never touched.
- **TCP/IP stack and NIC offloads** - Nagle's algorithm (`TCPNoDelay`), delayed ACKs (`TcpAckFrequency`), Windows network throttling, receive-side scaling, NIC checksum offload and Energy-Efficient Ethernet, QoS reserved bandwidth, and an ephemeral-port / TIME_WAIT expansion.
- **Network and Ping settings** - the catalog's network group (LLMNR, WPAD auto-proxy, SMB1, Teredo/ISATAP/6to4 tunnels, TCP receive window, NCSI probes, and more).

### 3. Kernel and Latency Tuning

- **GPU and display latency** - Hardware-Accelerated GPU Scheduling (HAGS), windowed-game flip-model optimizations, GameDVR / background capture off, and GPU MSI interrupt priority raised to High.
- **CPU timers and memory latency** - dynamic ticks disabled (`disabledynamictick`), native invariant TSC enforced (`useplatformtick`), the kernel pinned in RAM (`DisablePagingExecutive`), and the Hybrid Low Latency power plan with USB selective-suspend off (carries a "not for laptops with bad cooling" warning, because it keeps the CPU out of idle states by design).
- **Windows Gaming and Responsiveness** - Game Mode, transparency/Acrylic off, instant menus (`MenuShowDelay = 0`), raw mouse input (no pointer acceleration), memory compression off, CPU min/max frequency pinned at 100%, and on NVIDIA machines the low-latency driver flag.

### 4. Processes and Debloater

- **Live process manager** - top memory and CPU consumers, background-bloatware detection (OneDrive, Edge updaters, update helpers), and a kill action per process.
- **Standby RAM purge.**
- **Scheduled telemetry tasks** - the Windows tasks that phone home on a schedule (compatibility telemetry, CEIP uploads), each individually switchable plus "Disable All". The app tracks the real task names Windows uses across builds and falls back to the legacy name where needed.

### 5. Startup Apps

Every program that launches with Windows, with publisher, location, startup impact and an enable/disable switch. Here the switch reads naturally: ON = runs at startup, OFF = disabled.

### 6. Windows Services

Every service on the machine (270-plus on a typical install), grouped into a spectrum from "obvious background consumer junk" to "things Windows cannot boot without": Telemetry, Windows Update, Xbox and gaming, consumer bloatware, cloud integration, printing/media, search and indexing, Bluetooth and device discovery, vendor/driver services, security, networking, and Windows core.

- Start type and live status are read from the **Service Control Manager**, never assumed.
- Only the groups it is safe to bulk-disable offer a bulk button, and even then each write is gated by a per-service allow-list of vetted services.
- **Vendor, Security, Networking and Core groups are read-only** - the note on each explains why (vendor services belong to your drivers; core services keep the machine bootable).
- Windows' own description text is used for most services (it is Microsoft's text and therefore honest); the app only overrides descriptions where Windows is vague about what turning the service off actually does.

### 7. Performance Tweaks Catalog

The data-driven heart of the app: ON/OFF tweaks where **ON = optimized** and OFF = what Windows ships. Only entries with a real, measurable mechanism are listed, and two honesty labels are used throughout:

- `PERF` - the tweak trades something (security, battery or stability) for measurable speed. The note says exactly what it trades and who should not enable it.
- `unverified` - the intent is sound but the exact registry value has not been confirmed on this Windows build; enable at your own judgement.

Entries that need a reboot are marked. The catalog includes dropdown-style tweaks (currently 7) such as the SysMain mode and the MMCSS scheduling categories, which read a single named value and render "Windows default" honestly when the value has never been written - because 0 is often a real, deliberate choice and must not collapse into "unset".

### 8. General Tweaks

Everything that is not a measured performance tweak or a network setting, organized by intent:

- **Privacy** - telemetry off, advertising ID, tailored experiences, activity history, location sensors, feedback prompts, typing personalization, recent-document tracking.
- **AI features** - Recall / AI data analysis, Copilot (user and machine-policy routes), Cortana, Edge AI features, Copilot in Microsoft 365, Teams chat AI, Click to Do, Studio Effects, and web results in Start search.
- **Updates** - no forced reboots after updates, driver updates off, Delivery Optimization capped or disabled, consumer bloat-reinstall blocking, OneDrive file sync off.
- **Interface** - window/taskbar animations, Aero Peek and Shake, file extensions and hidden files, snap assist, lock-screen skip, widgets/chat/Copilot taskbar removals, dark mode, small or never-combined taskbar buttons, Explorer to This PC, thumbnail cache.
- **System** - power throttling, 8.3 short names, long paths, last-access tracking, fast startup, timer resolution, CPU side-channel mitigations and VBS/HVCI (both PERF-marked), SysMain mode, MPO, background apps and more.

### 9. Engine Activity Stream

A live console of engine activity - applies, verifications and reverts as they happen - plus a Clear Log button. This is an activity feed for transparency, not a command shell.

**Header actions:** Safety Restore Point (creates a Windows System Restore point before changes), Restore Defaults (reverts the app's settings to Windows factory state), Check for Updates, and the theme picker.

## The tweak engine

As of v3.1.8 the registry catalog holds **93 entries**, defined as data rather than code: id, category, human label, description, registry path, ON value, OFF value, and optional modifiers. The UI renders the entire catalog from `/api/tweak/catalog`, and the same definition drives both the write path and the read-back, so the dashboard, the switch on screen and the machine cannot drift apart.

Categories, with entry counts:

| Category | Entries |
|---|---|
| Interface | 23 |
| System | 19 |
| AI Features | 13 |
| Privacy | 12 |
| Network | 10 |
| Gaming | 9 |
| Updates | 7 |

Semantics that matter:

- `ON = optimized` is consistent across every tab; OFF restores what Windows ships.
- An OFF value of `__REMOVE__` means Windows ships the value **absent**, so turning the tweak off deletes it rather than writing a zero.
- Some values are machine-dependent (for example thresholds Windows itself derives from installed RAM); those are resolved live instead of being hard-coded.
- Enum tweaks read a single named value; "never written" is rendered as "Windows default" and stays distinct from 0.
- Every toggle write is followed by a **read-back**: the API returns the measured result, and "applied" is only claimed when the machine confirms it. A write that silently did nothing (a refused BCD edit, a wrong registry hive, a `powercfg` that needed elevation) reports failure instead of a success toast. In dry-run mode a blocked write reports "blocked", which is deliberately distinct from "failed".

## Safety model

The app edits the registry, BCD store, services, scheduled tasks, power schemes and adapter configuration, so the safety model is the feature:

- **Read-back verification.** "Measured, not asserted" is the core rule: no success is reported without reading the value back from the machine. This replaced an earlier design that returned success unconditionally.
- **Dry-run mode (`server.ps1 -DryRun`).** Every mutation is blocked while all reads still execute, so the whole app can be exercised end-to-end without touching the machine; blocked calls are written to `dry-run-blocked.log`.
  - Cmdlets are intercepted with `$WhatIfPreference` (covering ~118 mutating call sites such as `Set-ItemProperty`, `New-Item`, `Remove-Item`). The few cmdlets that do not declare `WhatIf` support (ScheduledTask/MMAgent set/disable/enable) are explicitly shadowed, and `tools/test-dryrun-guard.ps1` re-derives that list from the source and fails if a new unshadowed mutator is ever added.
  - External tools (`netsh`, `powercfg`, `bcdedit`, `sc.exe`, `reg.exe` - 85+ call sites) ignore `$WhatIfPreference` because they are separate processes, so they are shadowed by PowerShell functions of the same name. The guard is **default-deny**: only known-safe read verbs pass through. That is not style - an earlier verb-based classifier waved through real mutations such as `bcdedit /deletevalue useplatformclock` and `powercfg /hibernate off`.
- **Restore point, then Restore Defaults.** Snapshot before, revert after.
- **Guardrails by construction.** The Core service group is read-only; the IPv4 binding is never touched; bulk service disable only ever touches individually vetted services; and each setting has a single writer (the Services tab is the only home for service switches, `SystemResponsiveness` has one owner) so two controls can never fight over one value.
- **Trade-offs are disclosed, not buried.** CPU side-channel mitigations, VBS/HVCI, the Hybrid Low Latency plan, disabling the print spooler - each one states its cost and who should skip it.

## Under the hood

Desktop app = Electron shell + a local PowerShell engine. Everything runs on the machine; nothing is sent anywhere.

```
+--------------------------------------------------------------+
| Electron main process (main.js)                              |
|  - single-instance lock, UAC elevation hand-off              |
|  - spawns the backend, lifts the API token off its stdout    |
|  - splash -> main window, electron-updater (auto-update)     |
+-----------------------------+--------------------------------+
                              | spawn: powershell -File server.ps1
                              v
+--------------------------------------------------------------+
| PowerShell backend (server.ps1)                              |
|  - System.Net.HttpListener on 127.0.0.1:48921, falling       |
|    back to 48922 when the port is taken                      |
|  - serves public/ (the UI) + /api/* JSON endpoints           |
|  - registry / BCD / services / tasks / netsh / powercfg      |
+-----------------------------+--------------------------------+
                              ^ HTTP from the renderer; every
                              | request carries the per-process
                              | token in X-WT-Token; CORS is
                              | restricted to the app origin
+-----------------------------+--------------------------------+
| Renderer UI (public/: index.html, app.js, themes.js, css)    |
|  - vanilla HTML/CSS/JS, no framework, CSP locked to the      |
|    two loopback ports                                        |
+--------------------------------------------------------------+
```

- **The backend is a native PowerShell micro-server** built on `System.Net.HttpListener` - no Node server, no Python. It serves the static UI, exposes 26 JSON endpoints, and owns every system write.
- **Auth is a per-process token.** Each launch generates a cryptographically random token (CSPRNG - not `Get-Random`), prints it on a marker line that the shell lifts off stdout, and requires it on every API request. It cannot be replayed across restarts, and an origin allow-list stops random web pages from poking the local API (this closed a real CORS hole in v3.1.7, where any visited web page could have posted registry writes to the local backend).
- **Startup warm-up.** The first system audit (~2.2 s) and network audit (~1.0 s) are paid while the splash is on screen, before the listener accepts traffic, so the first real request is fast and cannot time out.
- **Elevation without duplicate prompts.** The installer ships a `requireAdministrator` manifest; portable and dev runs re-prompt via UAC, and the process holds the single-instance lock until the elevated copy is on its way so a burst of launches cannot each spawn its own UAC prompt.
- **Single instance.** Spam-clicking the exe focuses the existing window instead of opening another.
- **Auto-update.** `electron-updater` against GitHub Releases (`latest.yml` + installer + blockmap), checked once on launch plus a manual "Check for Updates" button.
- **Dev hot reload.** Edits under `public/` hot-reload while the app is running in dev.
- **Browser fallback.** `start.bat` prefers the installed app, then `dist\win-unpacked`, then the portable exe. With none present it runs the backend directly and opens the UI in the browser (Brave app-mode when available), self-elevating first.

### API surface (26 endpoints)

| Area | Endpoints |
|---|---|
| Dashboards | `/api/status`, `/api/network`, `/api/processes` |
| Network lab | `/api/ping`, `/api/dns-benchmark`, `/api/apply-dns`, `/api/mtu-test`, `/api/apply-mtu`, `/api/network/bindings` |
| Toggles | `/api/tweak/set`, `/api/tweak/catalog`, `/api/tweak/network`, `/api/tweak/system`, `/api/tweak/all` |
| Services | `/api/services`, `/api/services/set`, `/api/services/group`, `/api/services/optimize` |
| Tasks and startup | `/api/tasks`, `/api/tasks/set`, `/api/startup`, `/api/startup/set` |
| Process actions | `/api/processes/kill`, `/api/processes/clean-ram` |
| Safety | `/api/restore-point`, `/api/revert-defaults` |

## Verification tooling

The repo carries the harnesses that were used to prove the app's behavior, so future changes can be checked the same way:

| Tool | What it proves |
|---|---|
| `tools/test-endpoints-dryrun.ps1` | Boots a dry-run backend and exercises the endpoint surface (52 checks); safe on any machine because every write is blocked. |
| `tools/test-list-truth.ps1` | Audits `/api/services`, `/api/tasks` and `/api/startup` against machine truth read independently of the app (89 checks); refuses to POST unless the dry-run banner is seen. |
| `tools/test-dryrun-guard.ps1` | Re-derives the list of mutating cmdlets that lack `WhatIf` support from the source and fails if a new one is added without a matching shadow (51 checks). |
| `tools/mutation-inventory.ps1` | Inventories every mutation call site in `server.ps1` (cmdlets and external tools) to keep the dry-run guard complete. |
| `tools/release.ps1` | The gated release runbook: branch and clean-tree check, `GH_TOKEN` validation, push main, create and push the version tag, then `npm run release`. |

## Build from source

Prerequisites: Windows 10/11 x64, PowerShell 5.1 (built in), Node.js and npm for building.

```
npm install
npm start              # dev: Electron app with live-reloading UI
npm run build          # NSIS installer + portable + latest.yml in dist\
npm run build-portable # portable exe only
npm run release        # build + publish to GitHub (requires GH_TOKEN)
```

The installer, portable exe and unpacked build all carry the app icon and version resources, and the build generates the auto-update metadata (`latest.yml`) that ships with each release. `tools/release.ps1` wraps the release flow with the guardrails (tag-first publish, token validation).

## Theming

Twelve palettes - Obsidian, Oxblood, Midnight, Amethyst, Copper, Forest, Prussian, Azure, Molten, Gold, Platinum and Slate - selected from a frosted radial wheel that opens over a blurred backdrop. The wheel is a proper dialog: arrow keys cycle, Enter applies, Escape closes. Platinum (white on black) is the default for fresh installs, and the choice is stored per user and applied before first paint, so there is never a flash of default chrome.

## Notable design decisions

- **MTU stays at 1500.** The app used to force 1280 on the belief that a smaller packet always means less latency; 1280 is the IPv6 minimum, not an optimization, and the runtime fragmentation probe that "decided" it was unreliable. 1500 is the standard Ethernet MTU and the fastest setting.
- **"Keep IPv4 Only" is offered but fenced** with explicit warnings and a precise undo, because disabling IPv6 genuinely breaks real software (Steam, parts of Windows Update, some VPN clients).
- **The Hybrid Low Latency power plan keeps the CPU out of idle and boost ramp-down states by design** - excellent for frame pacing, at the cost of idle heat and fan noise. Laptops with poor cooling are told to skip it.
- **Honest defaults.** Where Windows already enables something (Game Mode, windowed flip model, RSS), the switch says exactly that instead of pretending to add magic; OFF explicitly disables it.
- **One writer per setting.** `SystemResponsiveness` has a single owner; service switches live only on the Services tab; static tweak definitions feed both the write path and the read-back.
- **The catalog only lists tweaks with a measurable mechanism.** Anything with a plausible but unconfirmed value is marked `unverified` rather than removed or overclaimed.

## Requirements

- Windows 10 or Windows 11, x64.
- Administrator rights for full effect - registry, service, BCD, power and adapter writes need elevation. Without it the app still runs and reports honestly what it cannot change.
- At runtime, the app needs nothing beyond what Windows ships (PowerShell 5.1) and its own bundled Electron runtime.
