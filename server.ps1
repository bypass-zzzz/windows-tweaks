# ==============================================================================
# WINDOWS TWEAKS - HIGH-PERFORMANCE LOW-LATENCY ENGINE BACKEND
# Architecture: Native PowerShell Async Micro-Server with System.Net.HttpListener
# ==============================================================================

param(
    [int]$Port = 48921,
    [switch]$NoBrowser,
    # Blocks every system mutation while still serving real read data.
    # See the DRY-RUN SAFETY NET block below the param block.
    [switch]$DryRun
)

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin) {
    Write-Warning "[Tweaks] Running without elevated Administrator privileges."
    Write-Warning "[Tweaks] Some kernel BCD & Registry tweaks will require Administrator elevation."
    Write-Warning "[Tweaks] For maximum performance, run start.bat as Administrator."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$publicDir = Join-Path $scriptDir "public"

# ==============================================================================
# DRY-RUN SAFETY NET  (-DryRun)
# ==============================================================================
# This backend writes real registry keys, BCD entries, services, scheduled tasks
# and adapter settings. Exercise it without touching the machine by starting it
# with -DryRun: every mutation is blocked, while all reads still execute so the
# UI and the harness see genuine system state.
#
# Two mechanisms are required, because the two halves of the surface behave
# differently:
#
#   1. Cmdlets. $WhatIfPreference = $true disables every ShouldProcess cmdlet in
#      one line - Set-ItemProperty (55 sites), New-Item (28), Remove-Item (18),
#      Remove-ItemProperty (17), Set-Content, Set-Service, Set-NetAdapter,
#      Invoke-CimMethod, ... Verified per-cmdlet on this build.
#      EXCEPTION: some cmdlets declare no WhatIf parameter at all, so
#      $WhatIfPreference silently does nothing for them. On this build that is
#      Set/Disable/Enable-ScheduledTask and Enable/Disable-MMAgent. Those are
#      shadowed explicitly at the bottom of this block. tools\test-dryrun-guard.ps1
#      re-derives that list from this file and fails if a mutating cmdlet without
#      WhatIf support is ever added without a matching shadow.
#
#   2. External tools. netsh (30 call sites), powercfg (37), bcdedit (12),
#      sc.exe (5) and reg.exe (1) ignore $WhatIfPreference completely - they are
#      separate processes and cannot know it was set. They are shadowed with
#      PowerShell functions of the same name; because function lookup takes
#      precedence over a native executable, this covers every existing call site
#      without editing any of them. Both the bare and ".exe" spellings are
#      shadowed, since server.ps1 uses each (e.g. `bcdedit /enum` and
#      `& bcdedit.exe /set ...`).
#
# The external guard is DEFAULT-DENY, and that is not a style choice. Classifying
# each call by looking for mutating verbs (set/add/delete/...) was tried first and
# failed on real code in this very file: `bcdedit /deletevalue useplatformclock`
# and `powercfg /hibernate off` contain none of those words and were waved through
# as reads - a dry run that quietly rewrites the boot configuration. The rule is
# therefore inverted: only known-safe read verbs are allowed through, everything
# else is blocked. Blocking a read by mistake only makes a dry run less
# informative; allowing a write by mistake corrupts the machine.
#
# If you add a call to an external tool that is not shadowed here, add it below.
if ($DryRun) {
    # ── Load the modules this script uses BEFORE the WhatIf switch is thrown ──
    # Two separate reasons, both measured on this host:
    #
    #   * Correctness. Auto-loading a module imports its exports when one of its
    #     commands is first used, and that import CLOBBERS a same-named function
    #     already defined in the session - which silently un-does a shadow below.
    #     That is a real hole, not a cosmetic one: define the shadow, then call
    #     Get-MMAgent (a plain read, so it runs even in a dry run), and
    #     `Get-Command Disable-MMAgent` flips from our function to the real module
    #     function, after which the "guarded" call really does disable memory
    #     compression. This script reads Get-MMAgent and Get-ScheduledTask during
    #     normal operation, so that would happen on the first /api/status request.
    #     Loading the modules here means no auto-load can fire later, so the
    #     shadows win for the life of the process.
    #
    #   * Readability. The same auto-load also runs the module's own Set-Alias
    #     calls, which are ShouldProcess - so once $WhatIfPreference is set they
    #     become no-ops that print a line of
    #         What if: Performing the operation "Set Alias" on target "Name: gcim"
    #     to stdout for every alias in the module. CimCmdlets alone emits twelve of
    #     them into the middle of startup output, burying the API token and the log
    #     lines a human actually needs. (No CIM alias is used by this script, so
    #     nothing breaks; it is purely about being able to read the output.)
    Import-Module CimCmdlets, NetAdapter, NetTCPIP, DnsClient, MMAgent, ScheduledTasks -ErrorAction SilentlyContinue

    $WhatIfPreference = $true

    $script:DryRunLogPath = Join-Path $scriptDir 'dry-run-blocked.log'
    $script:DryRunBlocked = New-Object System.Collections.Generic.List[string]

    # The ONLY argument tokens allowed to reach the real executable. Anything not
    # matched here is treated as a mutation and blocked.
    $script:DryRunReadVerbs = @{
        'netsh'    = @('show', 'dump', 'help', '/?')
        'powercfg' = @('/query', '-query', '/list', '-list', '/getactivescheme', '-getactivescheme',
                       '/getacvalueindex', '-getacvalueindex', '/getdcvalueindex', '-getdcvalueindex', '/q', '/?')
        'bcdedit'  = @('/enum')
        'sc'       = @('query', 'queryex', 'qc', 'qdescription', 'enumdepend', 'getdisplayname', 'getkeyname', '/?')
        'reg'      = @('query', 'q')
        'taskkill' = @()   # no read mode exists
    }

    # Belt and braces: if any token from this list is present, deny even when a
    # read verb is present too (e.g. `netsh ... set X name="show"`).
    $script:DryRunWriteVerbs = @(
        'set', 'add', 'delete', 'deletevalue', 'create', 'remove', 'reset', 'import', 'export',
        'config', 'start', 'stop', 'restart', 'disable', 'enable', 'install', 'uninstall',
        'on', 'off', 'change', 'setactive', 'setacvalueindex', 'setdcvalueindex',
        'restoredefaultschemes', 'hibernate', 'flush', 'release', 'renew', 'load', 'unload',
        'copy', 'run', 'end', 'save', 'apply'
    )

    function Test-WTDryRunAllowed {
        param([string]$Tool, [string[]]$Arguments)

        $readVerbs = $script:DryRunReadVerbs[$Tool]
        if (-not $readVerbs -or $readVerbs.Count -eq 0) { return $false }

        $tokens = @()
        foreach ($a in $Arguments) {
            if ($null -eq $a) { continue }
            $t = ([string]$a).Trim().ToLowerInvariant()
            if ($t) { $tokens += $t }
        }
        if ($tokens.Count -eq 0) { return $false }

        foreach ($t in $tokens) {
            if ($script:DryRunWriteVerbs -contains $t) { return $false }
        }
        foreach ($t in $tokens) {
            if ($readVerbs -contains $t) { return $true }
        }
        return $false
    }

    function Write-WTDryRunBlock {
        param([string]$Tool, [string[]]$Arguments, [string]$Origin)

        $joined = (($Arguments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join ' ')
        $entry = '{0}|{1}|{2}|{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Tool, $Origin, $joined
        $script:DryRunBlocked.Add($entry) | Out-Null
        Write-Host "[DRYRUN-BLOCK] $Tool $joined"
        # Deliberately .NET rather than Add-Content: with $WhatIfPreference = $true
        # every ShouldProcess cmdlet is a no-op, so Add-Content would silently
        # write nothing and the log would come back empty.
        try { [System.IO.File]::AppendAllText($script:DryRunLogPath, $entry + [Environment]::NewLine) } catch { }
    }

    function Invoke-WTGuarded {
        param([string]$Tool, [string]$Exe, [string[]]$Arguments, [string]$Origin)

        if (Test-WTDryRunAllowed -Tool $Tool -Arguments $Arguments) {
            if ($Arguments.Count -gt 0) { & $Exe @Arguments } else { & $Exe }
            return
        }
        Write-WTDryRunBlock -Tool $Tool -Arguments $Arguments -Origin $Origin
    }

    # ── External tool shadows (see the DEFAULT-DENY note above) ──────────────
    function netsh      { Invoke-WTGuarded -Tool 'netsh'    -Exe "$env:SystemRoot\System32\netsh.exe"    -Arguments @($args) -Origin 'netsh' }
    function netsh.exe  { Invoke-WTGuarded -Tool 'netsh'    -Exe "$env:SystemRoot\System32\netsh.exe"    -Arguments @($args) -Origin 'netsh.exe' }

    function powercfg     { Invoke-WTGuarded -Tool 'powercfg' -Exe "$env:SystemRoot\System32\powercfg.exe" -Arguments @($args) -Origin 'powercfg' }
    function powercfg.exe { Invoke-WTGuarded -Tool 'powercfg' -Exe "$env:SystemRoot\System32\powercfg.exe" -Arguments @($args) -Origin 'powercfg.exe' }

    function bcdedit      { Invoke-WTGuarded -Tool 'bcdedit'  -Exe "$env:SystemRoot\System32\bcdedit.exe"  -Arguments @($args) -Origin 'bcdedit' }
    function bcdedit.exe  { Invoke-WTGuarded -Tool 'bcdedit'  -Exe "$env:SystemRoot\System32\bcdedit.exe"  -Arguments @($args) -Origin 'bcdedit.exe' }

    function sc.exe       { Invoke-WTGuarded -Tool 'sc'       -Exe "$env:SystemRoot\System32\sc.exe"       -Arguments @($args) -Origin 'sc.exe' }
    function reg.exe      { Invoke-WTGuarded -Tool 'reg'      -Exe "$env:SystemRoot\System32\reg.exe"      -Arguments @($args) -Origin 'reg.exe' }

    function taskkill      { Invoke-WTGuarded -Tool 'taskkill' -Exe "$env:SystemRoot\System32\taskkill.exe" -Arguments @($args) -Origin 'taskkill' }
    function taskkill.exe  { Invoke-WTGuarded -Tool 'taskkill' -Exe "$env:SystemRoot\System32\taskkill.exe" -Arguments @($args) -Origin 'taskkill.exe' }

    # The modules owning the cmdlets shadowed below (MMAgent, ScheduledTasks) were
    # already imported at the top of this block - see the note there for why that
    # ordering matters. Do not move this section above that import.

    # ── Scheduled-task cmdlets: no WhatIf support, so shadowed outright ──────
    function Disable-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskPath, [string]$TaskName, [CimInstance]$InputObject)
        Write-WTDryRunBlock -Tool 'Disable-ScheduledTask' -Arguments @($TaskPath, $TaskName) -Origin 'cmdlet'
    }
    function Enable-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskPath, [string]$TaskName, [CimInstance]$InputObject)
        Write-WTDryRunBlock -Tool 'Enable-ScheduledTask' -Arguments @($TaskPath, $TaskName) -Origin 'cmdlet'
    }
    function Set-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskPath, [string]$TaskName, [CimInstance]$InputObject)
        Write-WTDryRunBlock -Tool 'Set-ScheduledTask' -Arguments @($TaskPath, $TaskName) -Origin 'cmdlet'
    }

    # ── MMAgent cmdlets: also no WhatIf support, also shadowed outright ──────
    # Found by walking every mutating-verb cmdlet in this file and asking each one
    # whether it declares a WhatIf parameter. These four call sites live in the
    # memory-compression tweak, restore-defaults and restore-point paths, and
    # $WhatIfPreference does nothing for them - so without these shadows a dry run
    # would really toggle MemoryCompression.
    function Disable-MMAgent {
        [CmdletBinding()]
        param(
            [switch]$MemoryCompression,
            [switch]$PageCombining,
            [switch]$ApplicationLaunchPrefetching,
            [switch]$ApplicationPreLaunch,
            [switch]$OperationAPICompression
        )
        Write-WTDryRunBlock -Tool 'Disable-MMAgent' -Arguments @($PSBoundParameters.Keys) -Origin 'cmdlet'
    }
    function Enable-MMAgent {
        [CmdletBinding()]
        param(
            [switch]$MemoryCompression,
            [switch]$PageCombining,
            [switch]$ApplicationLaunchPrefetching,
            [switch]$ApplicationPreLaunch,
            [switch]$OperationAPICompression
        )
        Write-WTDryRunBlock -Tool 'Enable-MMAgent' -Arguments @($PSBoundParameters.Keys) -Origin 'cmdlet'
    }

    # ── Checkpoint-Computer: no WhatIf support, and it must not be missed ────
    # This one was found the hard way. It is reached from Create-RestorePoint
    # (`Checkpoint-Computer -Description ... -RestorePointType MODIFY_SETTINGS`),
    # and it declares no WhatIf parameter, so $WhatIfPreference does nothing for
    # it. A dry run would therefore really snapshot the machine. It escaped the
    # first audit pass because its verb is "Checkpoint" - no mutating-verb list
    # contained that word. tools\test-dryrun-guard.ps1 now derives the requirement
    # from "which commands lack WhatIf" rather than from a guessed verb list, so
    # this class of miss cannot recur silently.
    function Checkpoint-Computer {
        [CmdletBinding()]
        param(
            [string]$Description,
            [string]$RestorePointType
        )
        Write-WTDryRunBlock -Tool 'Checkpoint-Computer' -Arguments @($Description, $RestorePointType) -Origin 'cmdlet'
    }

    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host "   DRY RUN ACTIVE - no system changes will be made" -ForegroundColor Yellow
    Write-Host "   Blocked mutations log: $script:DryRunLogPath" -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Yellow
}

# Add Windows API for RAM WorkingSet trimming
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MemoryTuner {
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwProc);
}
"@ -ErrorAction SilentlyContinue

# Native perf counters. WMI's Win32_Processor.LoadPercentage (~1.0 s) and
# Win32_OperatingSystem.FreePhysicalMemory (~0.3 s) are the two most expensive
# calls in Get-SystemAudit - WMI samples them over an interval rather than
# reading a counter. GetSystemTimes / GlobalMemoryStatusEx return the same
# numbers for ~0 ms. Kept in a separate Add-Type so a failure here cannot take
# MemoryTuner down with it; every caller falls back to WMI if this is missing.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class PerfCounters {
    [DllImport("kernel32.dll")]
    public static extern bool GetSystemTimes(out long idleTime, out long kernelTime, out long userTime);

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll")]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
}
"@ -ErrorAction SilentlyContinue

# Monotonic millisecond clock. NOTE: $script:Clock.ElapsedMilliseconds is .NET
# Core+ only - on Windows PowerShell 5.1 (.NET Framework 4.x) it silently
# resolves to $null, which made every deadline below a no-op and froze the
# CPU sampler's staleness check. A Stopwatch started at load is the portable
# way to get a monotonic ms reading on both runtimes.
$script:Clock = [Diagnostics.Stopwatch]::StartNew()

# CPU load from a GetSystemTimes delta. The first call primes a short sampling
# window; every call after that is a pure arithmetic delta against the previous
# sample, so it costs nothing. Returns $null when the native type is
# unavailable so callers can fall back to WMI.
$script:CpuSample = $null
$script:CpuLoadLast = 6

function Get-CpuLoadSample {
    try {
        $i1 = 0L; $k1 = 0L; $u1 = 0L
        [void][PerfCounters]::GetSystemTimes([ref]$i1, [ref]$k1, [ref]$u1)

        if ($null -eq $script:CpuSample) {
            Start-Sleep -Milliseconds 120
            $i2 = 0L; $k2 = 0L; $u2 = 0L
            [void][PerfCounters]::GetSystemTimes([ref]$i2, [ref]$k2, [ref]$u2)
            $dT = ($k2 - $k1) + ($u2 - $u1)
            $dI = $i2 - $i1
            $script:CpuSample = @{ Idle = $i2; Kernel = $k2; User = $u2; At = $script:Clock.ElapsedMilliseconds }
            if ($dT -gt 0) { $script:CpuLoadLast = [int][Math]::Round((1.0 - $dI / $dT) * 100) }
            return $script:CpuLoadLast
        }

        # Sub-100 ms apart the delta is noise - reuse the last good reading.
        if (($script:Clock.ElapsedMilliseconds - $script:CpuSample.At) -lt 100) { return $script:CpuLoadLast }

        $dT = ($k1 - $script:CpuSample.Kernel) + ($u1 - $script:CpuSample.User)
        $dI = $i1 - $script:CpuSample.Idle
        $script:CpuSample = @{ Idle = $i1; Kernel = $k1; User = $u1; At = $script:Clock.ElapsedMilliseconds }
        if ($dT -le 0) { return $script:CpuLoadLast }

        $pct = [int][Math]::Round((1.0 - $dI / $dT) * 100)
        if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }
        $script:CpuLoadLast = $pct
        return $pct
    } catch { return $null }
}

# Free/total RAM without a WMI round-trip. $null when unavailable.
function Get-RamSample {
    try {
        $m = New-Object PerfCounters+MEMORYSTATUSEX
        $m.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf($m)
        if (-not [PerfCounters]::GlobalMemoryStatusEx([ref]$m)) { return $null }
        return @{
            TotalGB = [Math]::Round($m.ullTotalPhys / 1GB, 1)
            FreeGB  = [Math]::Round($m.ullAvailPhys / 1GB, 1)
        }
    } catch { return $null }
}

# Hardware identity (CPU model, core counts, OS caption/build) never changes
# while the backend runs, yet pulling it costs ~1.2 s in WMI. Pull once, reuse
# for the life of the process. GPU and DIMM info stay per-call because they are
# cheap (~30 ms) and can legitimately change (display mode, hot-plugged memory).
$script:StaticHw = $null

function Get-StaticHw {
    if ($script:StaticHw) { return $script:StaticHw }
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    # No fabricated fallbacks. These two used to be the literal dev-machine strings
    # ("AMD Ryzen 5 7600X 6-Core Processor", "Microsoft Windows 11 Pro"), so on any
    # other machine a failed WMI query displayed someone else's CPU and OS as if they
    # were yours. Unknown is reported as unknown and the UI renders a dash.
    $cpuLabel = $null
    if ($cpu -and $cpu.Name) { $cpuLabel = "$($cpu.Name) ($($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T)" }

    $osLabel = $null
    if ($os -and $os.Caption) { $osLabel = "$($os.Caption) ($($os.Version) Build $($os.BuildNumber))" }

    $hw = @{ CpuLabel = $cpuLabel; OsLabel = $osLabel }
    # Only cache an answer that has something in it: caching a transient WMI failure
    # for the life of the process would pin "unknown" on a machine that can answer.
    if ($cpuLabel -or $osLabel) { $script:StaticHw = $hw }
    return $hw
}

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS: SYSTEM & NETWORK AUDITING
# -----------------------------------------------------------------------------

function Get-PowerSettingValue($sub, $setting, [switch]$Dc) {
    # One reader for both scopes: a value that is checked on AC and DC cannot be
    # parsed one way on one and another way on the other.
    $scope = if ($Dc) { 'DC' } else { 'AC' }
    $out = (& powercfg.exe /query SCHEME_CURRENT $sub $setting 2>$null) | Out-String
    $m = [regex]::Match($out, "Current $scope Power Setting Index:\s*0x([0-9a-fA-F]+)")
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) } else { return $null }
}

# Picks the power scheme this app should activate.
#
# Prefers a Hybred Low Latency scheme because it differs from Ultimate Performance
# in 35 settings, and the load-bearing ones all keep the CPU out of its idle states
# and out of boost ramp-down:
#   Processor idle disable              0 -> 1   (CPU leaves its idle states entirely)
#   Performance decrease threshold   10% -> 100% (never backs off while work is present)
#   Performance time check interval  15ms -> 5000ms (governor samples rarely, stays boosted)
#   Performance increase threshold  30% -> 0%    (ramps to max immediately)
#   Interrupt Steering Mode            0 -> 3     (reduces interrupt latency variance)
# For a CPU-bound workload with spiky frame times, not dropping out of boost between
# frames is worth a lot of frame rate.
#
# Cost, and it is not a small one: the CPU never enters a low-power idle state, so idle
# power draw, idle temperature and fan noise all rise, and sustained all-core
# temperature can reduce boost headroom. On a laptop with poor cooling that can make
# things worse rather than better. Not for laptops with bad cooling.
#
# This machine can carry several Hybred copies that differ only in Minimum processor
# state (100 vs 0), so prefer the one pinned at 100.
function Get-PreferredPowerScheme {
    $SUB_PROC = '54533251-82be-4824-96c1-47b60b740d00'
    $PROCTHROTTLEMIN = '893dee8e-2bef-41e0-89c6-b55d0929964c'

    $found = @()
    foreach ($line in (& powercfg.exe /list 2>$null)) {
        $t = $line.ToString()
        if ($t -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+)\)\s*\*?\s*$') {
            $found += [pscustomobject]@{ Guid = $Matches[1]; Name = $Matches[2].Trim() }
        }
    }

    $hybred = @($found | Where-Object { $_.Name -match 'Hybr[ei]d' })
    if ($hybred.Count -gt 0) {
        foreach ($h in $hybred) {
            $min = $null
            $q = (& powercfg.exe /query $h.Guid $SUB_PROC $PROCTHROTTLEMIN 2>$null) | Out-String
            if ($q -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $min = [Convert]::ToInt32($Matches[1], 16) }
            if ($min -eq 100) { return $h }
        }
        return $hybred[0]
    }
    $ult = $found | Where-Object { $_.Name -match 'Ultimate Performance' } | Select-Object -First 1
    if ($ult) { return $ult }
    $hp = $found | Where-Object { $_.Name -match 'High performance' } | Select-Object -First 1
    if ($hp) { return $hp }
    return $null
}
# -----------------------------------------------------------------------------
# STATIC TWEAK STATE - the single definition of "is this tweak applied"
#
# Get-SystemAudit fills the dashboard and the quick switches from this, and
# Set-TweakState reads it back after every write, so the dashboard, the switch
# on screen and the write path can never disagree about what the machine
# actually did. The ~21 switch branches in Set-TweakState used to return
# success = $true without reading anything, so a write that silently did
# nothing (a refused BCD edit, a wrong registry hive, a powercfg that needed
# elevation) still produced a success toast.
#
# Conventions, kept from the audit this was lifted out of:
#   $true / $false = the state was read and is / is not applied
#   $null          = the read did not answer; the UI renders a dash
# -----------------------------------------------------------------------------
function Get-StaticTweakStates {
    param([string[]]$GpuNames)

    $out = @{}

    # HAGS
    $out.hags = ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -ErrorAction SilentlyContinue).HwSchMode -eq 2)

    # Windows 11 Flip Optimizations (on by default - missing value means enabled)
    $autoOpt = (Get-ItemProperty "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Name "AutoOptimizationsEnabled" -ErrorAction SilentlyContinue).AutoOptimizationsEnabled
    $out.gameOpt = (($null -eq $autoOpt) -or ($autoOpt -eq 1))

    # BCD timers - one bcdedit read serves both
    $bcd = (bcdedit /enum "{current}" 2>$null) | Out-String
    $out.dynamicTick = ($bcd -match "disabledynamictick\s+Yes")
    $out.platformTick = ($bcd -match "useplatformtick\s+Yes")

    # Kernel RAM lock (DisablePagingExecutive)
    $out.kernelRamLock = ((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -ErrorAction SilentlyContinue).DisablePagingExecutive -eq 1)

    # Network throttling. NetworkThrottlingIndex is a DWORD and reads back
    # unsigned as 4294967295; PowerShell 5.1 parses 0xffffffff as Int32 -1, so
    # compare the real unsigned value widened to Int64.
    $netThrottle = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -ErrorAction SilentlyContinue).NetworkThrottlingIndex
    $out.netThrottle = ((([int64]$netThrottle) -eq 4294967295) -or (([int64]$netThrottle) -eq -1))

    # GameDVR
    $out.gameDvr = ((Get-ItemProperty "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -ErrorAction SilentlyContinue).GameDVR_Enabled -eq 0)

    # Delivery Optimization P2P - 99 or 0 both mean "not using Delivery Optimization"
    $doMode = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -ErrorAction SilentlyContinue).DODownloadMode
    $out.deliveryOpt = ($doMode -eq 99 -or $doMode -eq 0)

    # Game Mode is on by default - a missing value means enabled, not disabled
    $gameBarProps = Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\GameBar" -ErrorAction SilentlyContinue
    $gameBarAuto = if ($null -ne $gameBarProps -and $null -ne $gameBarProps.AutoGameModeEnabled) { $gameBarProps.AutoGameModeEnabled } else { $gameBarProps.AllowAutoGameMode }
    $out.gameMode = (($null -eq $gameBarAuto) -or ($gameBarAuto -eq 1))

    # Transparency, menu delay, mouse precision
    $out.transparency = ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -ErrorAction SilentlyContinue).EnableTransparency -eq 0)
    $out.menuDelay = ((Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -ErrorAction SilentlyContinue).MenuShowDelay -eq "0")
    $out.mousePrecision = ((Get-ItemProperty "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -ErrorAction SilentlyContinue).MouseSpeed -eq "0")

    # Memory compression. The property is MemoryCompression - there is no
    # MemoryCompressionEnabled - and an unreadable MMAgent is unknown, not
    # "compression off".
    $mmAgent = Get-MMAgent -ErrorAction SilentlyContinue
    $out.memCompression = if ($null -ne $mmAgent) { ($mmAgent.MemoryCompression -eq $false) } else { $null }

    # CPU boost - powercfg can fail to answer, and "no answer" is not the same
    # claim as "boost is capped for background work".
    $cpuMinAc = Get-PowerSettingValue "SUB_PROCESSOR" "PROCTHROTTLEMIN"
    $cpuMaxAc = Get-PowerSettingValue "SUB_PROCESSOR" "PROCTHROTTLEMAX"
    $out.cpuBoost = if ($null -ne $cpuMinAc -and $null -ne $cpuMaxAc) { ($cpuMinAc -eq 100 -and $cpuMaxAc -eq 100) } else { $null }

    # NVIDIA RID, gated on an NVIDIA GPU actually being present
    if ($null -eq $GpuNames) {
        $GpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $out.nvidiaAvailable = [bool]($GpuNames -match "NVIDIA")
    $nvidiaRid = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS" -Name "EnableRID61684" -ErrorAction SilentlyContinue).EnableRID61684
    $out.nvidiaRid = ($out.nvidiaAvailable -and ($nvidiaRid -eq 1))

    # Hibernate - hiberfil.sys exists exactly when hibernation is on
    $out.hibernate = -not (Test-Path "$env:SystemDrive\hiberfil.sys")

    # NetBIOS is per-adapter: read it off the adapter this app manages, using
    # the same InterfaceIndex bridge into WMI that the audit uses.
    $primaryNic = Get-PrimaryAdapter
    $nbtOpts = $null
    if ($primaryNic) {
        $nbtOpts = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($primaryNic.InterfaceIndex)" -ErrorAction SilentlyContinue).TcpipNetbiosOptions
    }
    $out.netbios = ($nbtOpts -eq 2)

    # Legacy tunnel adapters. A failed netsh produces no output at all, and a
    # regex that finds no match in an empty string is not evidence that the
    # tunnel is enabled - so empty output is $null rather than a confident
    # "not disabled".
    $teredoOut = ((& netsh.exe interface teredo show state 2>$null) | Out-String)
    $out.teredo = if ($teredoOut.Trim().Length -gt 0) { [bool]($teredoOut -match '(State|Type)\s*:\s*disabled') } else { $null }
    $isatapOut = ((& netsh.exe interface isatap show state 2>$null) | Out-String)
    $out.isatap = if ($isatapOut.Trim().Length -gt 0) { [bool]($isatapOut -match '(State|Type)\s*:\s*disabled') } else { $null }
    $sitoOut = ((& netsh.exe interface 6to4 show state 2>$null) | Out-String)
    $out.sixtofour = if ($sitoOut.Trim().Length -gt 0) { [bool]($sitoOut -match '(State|Type)\s*:\s*disabled') } else { $null }

    # Power scheme - the same matcher the dashboard has always used
    $activePlan = (powercfg /getactivescheme 2>$null)
    $out.powerPlan = [bool]($activePlan -match "Ultimate Performance|High performance|Hybred")

    # TCP registry tweaks target the same adapter Set-TweakState writes to.
    # $null when no adapter GUID is available: nothing was read.
    $tcpAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $tcpAdapter) { $tcpAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $tcpReg = if ($tcpAdapter -and $tcpAdapter.InterfaceGuid) { "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($tcpAdapter.InterfaceGuid)" } else { $null }
    if ($tcpReg) {
        $tcpProps = Get-ItemProperty -Path $tcpReg -ErrorAction SilentlyContinue
        $out.tcpNoDelay = ($tcpProps.TCPNoDelay -eq 1 -and $tcpProps.TcpDelAckTicks -eq 0)
        $out.tcpAckFreq = ($tcpProps.TcpAckFrequency -eq 1)
    } else {
        $out.tcpNoDelay = $null
        $out.tcpAckFreq = $null
    }

    # RSS - the global setting the toggle writes, read the same way the Network
    # tab reads it (netsh), so both views agree.
    $g = ((netsh int tcp show global 2>$null) | Out-String)
    $out.rss = [bool]($g -match "Receive-Side Scaling State\s*:\s*enabled")

    # QoS reserved bandwidth + ephemeral port policy
    $out.qosLimit = ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched" -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue).NonBestEffortLimit -eq 0)
    $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    $mup = (Get-ItemProperty -Path $tcpParams -Name "MaxUserPort" -ErrorAction SilentlyContinue).MaxUserPort
    $twd = (Get-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -ErrorAction SilentlyContinue).TcpTimedWaitDelay
    $out.tcpPorts = ($mup -eq 65534 -and $twd -eq 30)

    return $out
}

# Shape the answer to a switch write from what the machine actually reports.
# A dry run intercepts the write, so "not applied" there is the expected
# outcome and is marked blocked - an interception is not a write failure.
function Get-TweakWriteResult($id, $on, [switch]$Reboot) {
    $states = Get-StaticTweakStates
    $state = $states[$id]
    $applied = ($null -ne $state -and $state -eq [bool]$on)
    $result = @{ success = $applied; id = $id; enabled = $(if ($null -ne $state) { $state } else { [bool]$on }) }
    if ($Reboot) { $result.reboot = $true }
    if (-not $applied) {
        if ($DryRun) {
            $result.blocked = $true
            $result.error = "Dry run: the write was intercepted, so the setting still reads '$state'."
        } else {
            $result.error = "Read back '$state' after the write (expected '$([bool]$on)')."
        }
    }
    return $result
}

# -----------------------------------------------------------------------------
# STATIC AUDIT CACHE
# /api/status is polled every 2000 ms, and most of what it reports only moves
# when this app writes something: the ~25 static tweak switches (a bcdedit, four
# netsh calls, two powercfg queries, a WMI NIC read), the 92-entry registry
# catalog (~100 ms of registry reads), the bloated-service probe, the RAM sticks
# and the GPU list. Re-reading all of that every tick cost ~346 ms warm for
# values that had not changed. The live counters (CPU load, free RAM, process
# count) stay per-request; everything else is cached and invalidated the moment a
# POST arrives, because a POST is the only way this app moves those values. A TTL
# bounds staleness for anything changed outside the app.
# -----------------------------------------------------------------------------
$script:AuditGeneration = 0
$script:AuditCache = @{}
$script:AuditCacheTtlMs = 20000
$script:AuditCacheHits = 0

function Reset-AuditCache { $script:AuditGeneration++ }

function Get-AuditCached([string]$key, [scriptblock]$producer) {
    $entry = $script:AuditCache[$key]
    if ($entry -and $entry.Generation -eq $script:AuditGeneration -and
        ([DateTime]::UtcNow - $entry.At).TotalMilliseconds -lt $script:AuditCacheTtlMs) {
        $script:AuditCacheHits++
        return $entry.Value
    }
    $value = & $producer
    # Do not cache a failed read - Get-StaticHw makes the same call: one WMI
    # hiccup must not pin "unknown" for the life of the cache on a machine that
    # can answer. An empty collection and $null both mean "no answer" here.
    $hasContent = ($null -ne $value)
    if ($hasContent -and $value -is [System.Collections.ICollection]) { $hasContent = ($value.Count -gt 0) }
    if ($hasContent) {
        $script:AuditCache[$key] = @{ Value = $value; Generation = $script:AuditGeneration; At = [DateTime]::UtcNow }
    }
    return $value
}

function Get-SystemAudit {
    # Per-request hit counter (the dispatcher serves one request at a time, so
    # this cannot interleave). Reported in the payload so a harness can prove a
    # repeat poll is cached and a post-write poll is not.
    $script:AuditCacheHits = 0
    # Perf: the two slow WMI calls here used to be Win32_Processor (~1.0 s,
    # only for LoadPercentage) and Win32_OperatingSystem (~0.3 s, only for
    # FreePhysicalMemory). Both now come from native counters. Identity strings
    # are pulled once and cached; Win32_ComputerSystem was assigned and never
    # read, so it is gone entirely.
    $hw = Get-StaticHw
    # The GPU list and the RAM sticks are hardware identity, not live telemetry:
    # they change when a driver is updated or a stick is added, so they live in
    # the cache with the rest of the static half.
    $gpuCache = Get-AuditCached 'gpu' {
        $g = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
        if ($g.Count -gt 0) { $g } else { $null }
    }
    $gpus = if ($gpuCache) { @($gpuCache) } else { @() }
    $ramBlob = Get-AuditCached 'ram' {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($sticks.Count -eq 0) { return $null }
        $bytes = ($sticks | Measure-Object -Property Capacity -Sum).Sum
        $speed = ($sticks | Select-Object -First 1).Speed
        if ($null -eq $speed -or $speed -le 0) { $speed = $null }
        @{
            TotalGB = if ($bytes -and $bytes -gt 0) { [Math]::Round($bytes / 1GB, 1) } else { $null }
            Speed = $speed
            Sticks = $sticks.Count
        }
    }
    # Every fallback in this block used to be an invented measurement - 32 GB total,
    # 20 GB free, 8.0 GB used, 6000 MT/s - and on a machine where the query fails those
    # numbers were displayed as though they had been read. That is worse than showing
    # nothing: the entire value of this app is that the numbers are real. Unknown is
    # $null now, and the UI renders it as a dash.
    $totalRamGB = if ($ramBlob) { $ramBlob.TotalGB } else { $null }
    $ramSample = Get-RamSample
    $freeRamGB = if ($ramSample) { $ramSample.FreeGB } else {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.FreePhysicalMemory) { [Math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { $null }
    }
    # used and percent are derived, so they are unknown whenever either input is.
    # Clamping free > total (rounding only) to 0 is honest; inventing 8.0 was not.
    $usedRamGB = $null
    $ramPercent = $null
    if ($null -ne $totalRamGB -and $null -ne $freeRamGB) {
        $usedRamGB = [Math]::Round($totalRamGB - $freeRamGB, 1)
        if ($usedRamGB -lt 0) { $usedRamGB = 0.0 }
        if ($totalRamGB -gt 0) { $ramPercent = [Math]::Round(($usedRamGB / $totalRamGB) * 100, 1) }
    }
    $ramSpeed = if ($ramBlob) { $ramBlob.Speed } else { $null }

    $gpuList = @()
    foreach ($g in $gpus) {
        if ($g.Name) {
            $gpuList += @{
                Name = $g.Name
                DriverVersion = $g.DriverVersion
                Resolution = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"
                # WMI returns null for a GPU that is not driving the display (an iGPU, a
                # virtual adapter, a headless card), and this answered "170 Hz" - the dev
                # machine's monitor - for all of them. The tile now simply has no refresh
                # rate to show, which is the truth.
                RefreshRate = if ($g.CurrentRefreshRate -and $g.CurrentRefreshRate -gt 0) { "$($g.CurrentRefreshRate) Hz" } else { $null }
            }
        }
    }

    # Total active processes count (reuse the $cpu query above - one WMI round-trip)
    $procCount = (Get-Process -ErrorAction SilentlyContinue).Count
    $cpuLoadVal = Get-CpuLoadSample
    if ($null -eq $cpuLoadVal) {
        # Native counters unavailable - fall back to the slow WMI sample.
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        $cpuLoadVal = ($cpu | Measure-Object -Property LoadPercentage -Average -ErrorAction SilentlyContinue).Average
    }
    # No fabricated default: an unreadable CPU load is reported as unknown, not as 6%.

    $gpuNames = @($gpus | ForEach-Object { $_.Name })
    $hasNvidia = [bool]($gpuNames -match "NVIDIA")
    # "Telemetry Disabled" and "Debloated" are claims about this machine, so they are read
    # from the services rather than remembered, and from the same curated list the debloat
    # action writes to - so the badge and the Services tab can never disagree about what
    # "debloated" means. Zero services found is "the query failed", not "everything is
    # disabled": that is $null and renders as a dash.
    $bloatNames = @($script:BloatTargets | ForEach-Object { $_.Name })
    $bloat = Get-AuditCached 'bloat' {
        $live = @(Get-Service -Name $bloatNames -ErrorAction SilentlyContinue)
        if ($live.Count -eq 0) { return $null }
        $on = @($live | Where-Object { "$($_.StartType)" -ne "Disabled" })
        @{
            On = $on.Count
            Total = $bloatNames.Count
            TelemetryOn = @($on | Where-Object { (Get-ServiceGroupName $_.Name) -eq "telemetry" }).Count
        }
    }

    # Every static "is it applied" flag comes from Get-StaticTweakStates - one
    # definition shared with the write path, so this payload and a write's
    # read-back cannot disagree. Cached: it costs a bcdedit, four netsh calls,
    # two powercfg queries and a WMI NIC read, and none of those move between two
    # 2 s polls unless something writes.
    $staticStates = Get-AuditCached 'staticStates' { Get-StaticTweakStates -GpuNames $gpuNames }

    $tweakBase = @{
        hags = $staticStates.hags
        gameOptimizations = $staticStates.gameOpt
        dynamicTickDisabled = $staticStates.dynamicTick
        platformTick = $staticStates.platformTick
        kernelRamLock = $staticStates.kernelRamLock
        networkThrottlingDisabled = $staticStates.netThrottle
        gameDvrDisabled = $staticStates.gameDvr
        deliveryOptimizationDisabled = $staticStates.deliveryOpt
        ultimatePowerPlan = $staticStates.powerPlan
        gameMode = $staticStates.gameMode
        transparencyOff = $staticStates.transparency
        menuFast = $staticStates.menuDelay
        precisionOff = $staticStates.mousePrecision
        memDecompressed = $staticStates.memCompression
        cpuBoost = $staticStates.cpuBoost
        nvidiaRid = $staticStates.nvidiaRid
        nvidiaAvailable = $hasNvidia
        hibernate = $staticStates.hibernate
        netbios = $staticStates.netbios
        teredo = $staticStates.teredo
        isatap = $staticStates.isatap
        sixtofour = $staticStates.sixtofour
        # The TCP registry / QoS / ephemeral-port switches were the last ones whose
        # success the server asserted without reading anything. Reading them here
        # means their write path verifies against this same source.
        tcpNoDelay = $staticStates.tcpNoDelay
        tcpAckFreq = $staticStates.tcpAckFreq
        rss = $staticStates.rss
        qosLimit = $staticStates.qosLimit
        tcpPorts = $staticStates.tcpPorts
        # Computed, not asserted (see the note above the bloat probe). These drive the
        # dashboard's "Telemetry Disabled" line and "Debloated" badge.
        debloated = $(if ($bloat) { $bloat.On -eq 0 } else { $null })
        debloatRemaining = $(if ($bloat) { $bloat.On } else { $null })
        debloatTotal = $bloatNames.Count
        telemetryDisabled = $(if ($bloat) { $bloat.TelemetryOn -eq 0 } else { $null })
        telemetryRemaining = $(if ($bloat) { $bloat.TelemetryOn } else { $null })
    }
    # The 92-entry catalog is the other half of the expensive poll: ~100 ms of
    # registry reads per request, for values this app is the only writer of.
    $regStates = Get-AuditCached 'regStates' {
        $s = @{}
        foreach ($def in $script:RegTweaks) { $s[$def.id] = Get-RegTweakState $def }
        $s
    }
    foreach ($k in $regStates.Keys) { $tweakBase[$k] = $regStates[$k] }

    return @{
        os = $hw.OsLabel
        cpu = $hw.CpuLabel
        cpuLoad = if ($null -ne $cpuLoadVal) { [Math]::Round($cpuLoadVal, 0) } else { $null }
        ram = @{
            total = $totalRamGB
            used = $usedRamGB
            free = $freeRamGB
            percent = $ramPercent
            speed = $ramSpeed
            sticks = if ($ramBlob) { $ramBlob.Sticks } else { $null }
        }
        gpus = $gpuList
        powerPlan = if ($activePlan) { $activePlan } else { $null }
        processCount = $procCount
        isAdmin = $script:IsAdmin
        # Machine-readable proof that the safety net is engaged, so a harness or an
        # operator can tell a dry-run instance from a live one without guessing.
        dryRun = [bool]$DryRun
        # Also machine-readable: 'cache' means this poll was answered from the
        # static half, 'fresh' means it re-read. A POST moves the generation, so a
        # write is always followed by a fresh read.
        cache = @{ generation = $script:AuditGeneration; served = $(if ($script:AuditCacheHits -gt 0) { "cache" } else { "fresh" }) }
        tweaks = $tweakBase
    }
}

# The one adapter this app means when it says "your network". Shared deliberately: on a
# machine with a VPN, a virtual switch or a Wi-Fi adapter, "the first adapter Get-NetAdapter
# returns" is not the same NIC as "the first IP-enabled adapter WMI returns", and the
# NetBIOS probe and the NetBIOS write each used a different one of those two rules.
function Get-PrimaryAdapter {
    $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $a) { $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1 }
    if (-not $a) { $a = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
    return $a
}

function Get-NetworkAudit {
    $adapter = Get-PrimaryAdapter

    $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    # MTU
    $sub = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    # Was 1280 - which this app's own UI copy calls backwards, being the IPv6 minimum
    # rather than an optimisation. Reporting no MTU beats reporting a wrong one.
    $currentMtu = if ($sub -and $sub.NlMtu) { $sub.NlMtu } else { $null }

    # Registry TCP NoDelay / Delayed ACK
    $adapterGuid = $adapter.InterfaceGuid
    $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$adapterGuid"
    $tcpNoDelay = (Get-ItemProperty $tcpReg -Name "TCPNoDelay" -ErrorAction SilentlyContinue).TCPNoDelay
    $ackFreq = (Get-ItemProperty $tcpReg -Name "TcpAckFrequency" -ErrorAction SilentlyContinue).TcpAckFrequency

    # Netsh TCP global
    $netsh = (netsh int tcp show global 2>$null) | Out-String
    $rss = ($netsh -match "Receive-Side Scaling State\s*:\s*enabled")
    $autotuning = ($netsh -match "Receive Window Auto-Tuning Level\s*:\s*normal")
    $timestamps = ($netsh -match "RFC 1323 Timestamps\s*:\s*disabled")
    $rsc = ($netsh -match "Receive Segment Coalescing State\s*:\s*disabled")
    $fastopen = ($netsh -match "Fast Open\s*:\s*enabled")

    # NIC Interrupt Priority (MSI)
    $prioKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($adapter.PnPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"
    $devPriority = (Get-ItemProperty $prioKey -Name "DevicePriority" -ErrorAction SilentlyContinue).DevicePriority

    # QoS reserved-bandwidth + ephemeral port policy (reversible via toggle)
    $qosVal = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched" -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue).NonBestEffortLimit
    $maxPorts = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "MaxUserPort" -ErrorAction SilentlyContinue).MaxUserPort

    # Unknown is reported as unknown. Each of these used to carry a plausible hardcoded
    # fallback - this machine's literal NIC description, "2.5 Gbps", the address
    # 192.168.1.100, and the DNS pair 1.0.0.1/1.1.1.1 - so a failed query did not read as
    # "unavailable", it read as a measurement of the user's own machine.
    return @{
        name = if ($adapter -and $adapter.Name) { $adapter.Name } else { $null }
        interfaceDescription = if ($adapter -and $adapter.InterfaceDescription) { $adapter.InterfaceDescription } else { $null }
        linkSpeed = if ($adapter -and $adapter.LinkSpeed) { $adapter.LinkSpeed } else { $null }
        macAddress = if ($adapter) { $adapter.MacAddress } else { $null }
        ipAddress = if ($ipConfig -and $ipConfig.IPAddress) { $ipConfig.IPAddress } else { $null }
        mtu = $currentMtu
        dnsServers = if ($dnsServers) { $dnsServers } else { $null }
        tcpSettings = @{
            tcpNoDelay = ($tcpNoDelay -eq 1)
            tcpAckFrequency = ($ackFreq -eq 1)
            rss = $rss
            autotuning = $autotuning
            timestampsDisabled = $timestamps
            rscDisabled = $rsc
            fastopen = $fastopen
            qosLimit = ($qosVal -eq 0)
            tcpPorts = ($maxPorts -eq 65534)
        }
        interruptPriorityHigh = ($devPriority -eq 1)
    }
}

function Run-PingTest($hostTarget = "1.1.1.1", $count = 3) {
    # -----------------------------------------------------------------------
    # Ping.Send IGNORES the timeout argument on .NET Framework 4.x. Measured
    # directly: requesting 50/100/200/300/400 ms all cost ~500 ms of wall
    # time. The old sequential loop therefore spent ~1486 ms on an
    # unreachable host, against a 1500 ms frontend poll - so a dead host ate
    # roughly two thirds of the dispatcher's budget every tick and starved
    # /api/status.
    #
    # Sending the attempts CONCURRENTLY keeps all 3 samples at ~520 ms, and
    # parallel echoes do not degrade readings (healthy host returned
    # 20/18/22 ms concurrent vs ~17 ms sequential). Runspace pool creation is
    # 4 ms, so the per-request overhead is negligible.
    #
    # $deadline is still enforced by waiting on each handle rather than
    # blocking in EndInvoke, so a hung network stack cannot pin the
    # single-threaded dispatcher indefinitely.
    # -----------------------------------------------------------------------

    $deadlineMs = 900
    $pings = @()
    $attempted = 0

    # Self-contained: a runspace cannot see this module's scope, so the probe
    # must carry everything it needs and return -1 on any failure.
    $pingScript = @'
param($target, $timeout)
try {
    $p = New-Object System.Net.NetworkInformation.Ping
    $r = $p.Send($target, $timeout)
    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { return [long]$r.RoundtripTime }
} catch {}
return [long]-1
'@

    $jobs = @()
    $pool = $null
    try {
        $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $count))
        $pool.Open()
        for ($i = 0; $i -lt $count; $i++) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($pingScript).AddArgument($hostTarget).AddArgument(400)
            $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }
    } catch {
        # Runspace path unusable - release anything already started and fall
        # through to the sequential branch below. SilentlyContinue is set at
        # the top of this file, so cleanup must be explicit rather than assumed.
        foreach ($j in $jobs) { try { $j.PS.Dispose() } catch {} }
        $jobs = @()
        if ($pool) { try { $pool.Close(); $pool.Dispose() } catch {}; $pool = $null }
    }

    if ($jobs.Count -gt 0) {
        $attempted = $jobs.Count
        $deadline = $script:Clock.ElapsedMilliseconds + $deadlineMs
        foreach ($j in $jobs) {
            $remaining = $deadline - $script:Clock.ElapsedMilliseconds
            $answered = $false
            if ($remaining -gt 0) {
                try { $answered = $j.Handle.AsyncWaitHandle.WaitOne([int]$remaining) } catch {}
            }
            if ($answered) {
                try {
                    foreach ($v in $j.PS.EndInvoke($j.Handle)) {
                        $lv = -1L
                        try { $lv = [long]$v } catch { $lv = -1L }
                        if ($lv -ge 0) { $pings += $lv }
                    }
                } catch {}
            }
            # Launched but never answered counts as attempted, not as a
            # success - that is what packetLoss is reporting.
            try { $j.PS.Dispose() } catch {}
        }
        try { if ($pool) { $pool.Close(); $pool.Dispose() } } catch {}
    } else {
        # Sequential fallback if runspaces could not be created at all.
        $deadline = $script:Clock.ElapsedMilliseconds + $deadlineMs
        $pingObj = $null
        try { $pingObj = New-Object System.Net.NetworkInformation.Ping } catch {}
        if ($pingObj) {
            for ($i = 0; $i -lt $count; $i++) {
                $remaining = $deadline - $script:Clock.ElapsedMilliseconds
                if ($remaining -le 0) { break }
                $attempted++
                try {
                    $reply = $pingObj.Send($hostTarget, [Math]::Min(400, [Math]::Max(50, $remaining)))
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $pings += $reply.RoundtripTime
                    }
                } catch {}
            }
        }
    }

    if ($attempted -lt 1) { $attempted = 1 }

    if ($pings.Count -gt 0) {
        $avg = [Math]::Round(($pings | Measure-Object -Average).Average, 1)
        $min = ($pings | Measure-Object -Minimum).Minimum
        $max = ($pings | Measure-Object -Maximum).Maximum
        $jitter = [Math]::Round($max - $min, 1)
        $packetLoss = [Math]::Round((($attempted - $pings.Count) / $attempted) * 100, 1)
        return @{
            target = $hostTarget
            avg = $avg
            min = $min
            max = $max
            jitter = $jitter
            packetLoss = $packetLoss
            success = $true
        }
    } else {
        return @{
            target = $hostTarget
            avg = 0
            min = 0
            max = 0
            jitter = 0
            packetLoss = 100
            success = $false
        }
    }
}

function Run-DnsBenchmark {
    # One row per provider - primary + secondary applied together as a pair
    $providers = @(
        @{ name = "Cloudflare DNS"; primary = "1.1.1.1"; secondary = "1.0.0.1"; provider = "Cloudflare" },
        @{ name = "Google DNS"; primary = "8.8.8.8"; secondary = "8.8.4.4"; provider = "Google" },
        @{ name = "Quad9 Secure DNS"; primary = "9.9.9.9"; secondary = "149.112.112.112"; provider = "Quad9" },
        @{ name = "OpenDNS"; primary = "208.67.222.222"; secondary = "208.67.220.220"; provider = "Cisco OpenDNS" },
        @{ name = "AdGuard DNS"; primary = "94.140.14.14"; secondary = "94.140.15.15"; provider = "AdGuard" }
    )

    $pingObj = New-Object System.Net.NetworkInformation.Ping
    $results = @()

    # On-demand, but the dispatcher is single-threaded: a full 10 x 400 ms
    # timeout run (4 s) would freeze the status/ping streams mid-test. Bound
    # it so a dead uplink degrades to partial rows instead of a hung UI.
    $deadline = $script:Clock.ElapsedMilliseconds + 2500

    foreach ($p in $providers) {
        $best = 999
        $outOfTime = (($deadline - $script:Clock.ElapsedMilliseconds) -le 0)
        if (-not $outOfTime) {
            foreach ($ip in @($p.primary, $p.secondary)) {
                $remaining = $deadline - $script:Clock.ElapsedMilliseconds
                if ($remaining -le 0) { break }
                $wait = [Math]::Min(400, [Math]::Max(50, $remaining))
                try {
                    $reply = $pingObj.Send($ip, $wait)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        if ($reply.RoundtripTime -lt $best) { $best = $reply.RoundtripTime }
                    }
                } catch {}
            }
        }

        # Always emit every row - app.js reads list[0] unconditionally, so the
        # shape must not change when the deadline cuts testing short.
        $results += @{
            name = $p.name
            primary = $p.primary
            secondary = $p.secondary
            provider = $p.provider
            latency = $best
            status = if ($best -lt 999) { "Online" } else { "Timeout" }
        }
    }

    # Sort-Object CANNOT take a bare key name here: $results holds hashtables,
    # and a hashtable key does not appear in PSObject.Properties (dot access
    # still works, but Sort-Object binds via PSObject.Properties). With the key
    # unresolvable every row compares equal, so the array came back in arbitrary
    # order and app.js printed list[0] as "Fastest DNS" - measured 5/5 runs
    # naming an 88 ms resolver as fastest when 14 ms was present. The explicit
    # scriptblock binds the key directly, so ordering is real. Ascending also
    # sinks the 999 "Timeout" sentinel below any measured latency on its own.
    $sorted = $results | Sort-Object -Property { $_["latency"] }
    return $sorted
}

function Run-MtuTest {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }

    $target = "1.1.1.1"
    $left = 1200
    $right = 1472
    $bestPayload = 1252

    # $measured is the honesty flag. Without it a target that answers NOTHING
    # still reports 1252 + 28 = 1280, which is byte-identical to the hardcoded
    # "recommended" value below - an unreachable host becomes indistinguishable
    # from a genuinely correct reading. One surviving probe is enough to trust
    # the search, since binary search only narrows on real replies.
    $measured = $false

    # Binary search over the 1200-1472 range is ~9 ping.exe spawns. Each costs
    # up to 400 ms when the target is unreachable, so the worst case (~3.6 s)
    # freezes every other request on the single-threaded dispatcher. Stop once
    # the budget is spent and return the best payload found so far - a partial
    # search still converges on a usable value.
    $deadline = $script:Clock.ElapsedMilliseconds + 2500

    while ($left -le $right) {
        if ((($deadline - $script:Clock.ElapsedMilliseconds)) -le 0) { break }
        $mid = [Math]::Floor(($left + $right) / 2)
        $out = & ping.exe $target -f -l $mid -n 1 -w 400 2>$null
        $str = $out | Out-String
        if ($str -match "Reply from" -and $str -notmatch "Packet needs to be fragmented") {
            $bestPayload = $mid
            $measured = $true
            $left = $mid + 1
        } else {
            $right = $mid - 1
        }
    }

    $detectedMtu = $bestPayload + 28
    return @{
        adapter = if ($adapter) { $adapter.Name } else { "Ethernet" }
        detectedMaxUnfragmentedMtu = $detectedMtu
        # These used to be hardcoded to 1280 while the probe measured 1500 - the
        # function measured correctly and then recommended the opposite of its own
        # result. The best MTU for latency is the LARGEST packet the path carries
        # unfragmented: bigger packets means fewer packets and less per-packet
        # header overhead. 1280 is only correct where 1500 genuinely fragments.
        recommended = $detectedMtu
        optimalGamingMtu = $detectedMtu
        # Additive key: app.js already reads detectedMaxUnfragmentedMtu, so the
        # shape it parses is unchanged. Consumers must gate on this before
        # trusting detectedMaxUnfragmentedMtu - see app.js runMtuTest().
        success = $measured
    }
}

# The curated set of services this app is willing to disable. It lives at module scope
# because three places now need it: the Services tab, and the two dashboard badges that
# report whether the app's own debloat action has actually been applied ("Telemetry
# Disabled", "Debloated"). Those two badges used to be static markup text, so they
# asserted a state the machine might not be in - on the author's machine the badge read
# "Debloated" while WSearch was still running.
$script:BloatTargets = @(
    @{ Name = "DiagTrack"; Display = "Connected User Experiences and Telemetry"; Safe = $true; Impact = "High" },
    @{ Name = "WerSvc"; Display = "Windows Error Reporting Service"; Safe = $true; Impact = "Medium" },
    @{ Name = "lfsvc"; Display = "Geolocation Service"; Safe = $true; Impact = "Low" },
    @{ Name = "TrkWks"; Display = "Distributed Link Tracking Client"; Safe = $true; Impact = "Low" },
    @{ Name = "RemoteRegistry"; Display = "Remote Registry Access"; Safe = $true; Impact = "Medium" },
    @{ Name = "wisvc"; Display = "Windows Insider Telemetry Service"; Safe = $true; Impact = "Low" },
    @{ Name = "MapsBroker"; Display = "Downloaded Maps Background Manager"; Safe = $true; Impact = "Low" },
    @{ Name = "WSearch"; Display = "Windows Search Indexer"; Safe = $true; Impact = "Medium" },
    @{ Name = "XblGameSave"; Display = "Xbox Live Game Save"; Safe = $true; Impact = "Low" },
    @{ Name = "XboxGipSvc"; Display = "Xbox Accessory Management Service"; Safe = $true; Impact = "Low" },
    @{ Name = "XboxNetApiSvc"; Display = "Xbox Live Networking Service"; Safe = $true; Impact = "Low" },
    @{ Name = "Spooler"; Display = "Print Spooler (only if you print)"; Safe = $true; Impact = "Low" },
    @{ Name = "CDPSvc"; Display = "Connected Devices Platform Service"; Safe = $true; Impact = "Low" },
    @{ Name = "dmwappushservice"; Display = "Device Management Push Telemetry"; Safe = $true; Impact = "Medium" },
    @{ Name = "PcaSvc"; Display = "Program Compatibility Assistant"; Safe = $true; Impact = "Low" }
)

# ---------------------------------------------------------------------------
# SERVICE GROUPS
#
# Services are grouped from "obvious background consumer junk" through to the
# components Windows itself depends on, so the tab reads as a spectrum rather
# than a flat alphabetical dump. Anything not matched by a pattern below falls
# into Core, which is deliberately read-only: those are the services that keep
# Windows bootable and networkable (RpcSs, DcomLaunch, WinDefend, Dhcp,
# EventLog, PlugPlay, Power, BFE, nsi, CryptSvc, AudioSrv, Themes, Schedule).
# Bulk-disabling that group can leave a machine that will not boot or has no
# network, so it gets no write button at all.
#
# modifiableGroups are the ones where a bulk disable is offered. Membership is
# still gated per-service by the $allowed allow-list in Set-ServiceState, so a
# group can be bulk-disabled but only ever touches services that were individually
# vetted as safe.
# ---------------------------------------------------------------------------
$script:ServiceGroups = @(
    @{ Id = "telemetry"; Title = "Telemetry & Diagnostics"; Desc = "Background services that report usage and crash data to Microsoft. Safe to disable on a gaming machine."; Modifiable = $true }
    @{ Id = "update"; Title = "Windows Update & Delivery"; Desc = "Update orchestration and peer-to-peer payload delivery. Disabling stops automatic patching - leave on unless you update manually."; Modifiable = $true }
    @{ Id = "gaming"; Title = "Xbox & Gaming Services"; Desc = "Game Bar, achievements and Xbox sign-in helpers. Disabling these removes Game Bar overlays and cloud saves."; Modifiable = $true }
    @{ Id = "consumer"; Title = "Bloatware & Consumer Apps"; Desc = "Preinstalled consumer apps: Phone Link, Smart Wallet/Pay, Tips, Mixed Reality and similar. Usually unused on a gaming machine."; Modifiable = $true }
    @{ Id = "integration"; Title = "Smart Features & Cloud Integration"; Desc = "Widgets, Copilot hooks, content suggestions and cross-device continuity. Turning these off removes Start menu ads and the widgets board."; Modifiable = $true }
    @{ Id = "media"; Title = "Printing, Fax & Media"; Desc = "Print spooler, fax and Windows Media. Disable the spooler only if you never print."; Modifiable = $true }
    @{ Id = "search"; Title = "Search, Indexing & Prefetch"; Desc = "Windows Search index and Superfetch-style prefetch. Disabling costs you fast Start menu results and cold launch times."; Modifiable = $true }
    @{ Id = "devices"; Title = "Bluetooth & Device Discovery"; Desc = "Bluetooth and nearby-device pairing services. Only disable if you use wired peripherals exclusively."; Modifiable = $true }
    @{ Id = "vendor"; Title = "Third-Party & Driver Support"; Desc = "Per-device and vendor software: GPU, motherboard, RGB, fan and peripheral utilities. Installed by hardware drivers and other applications. Read-only - these belong to your drivers, not to Windows."; Modifiable = $false }
    @{ Id = "security"; Title = "Security, Defender & Licensing"; Desc = "Defender, SmartScreen, licensing and update orchestration. Read-only - disabling these removes your protection."; Modifiable = $false }
    @{ Id = "network"; Title = "Networking & Remote Access"; Desc = "TCP/IP stack, DNS client, firewall base and remote access. Read-only - disabling these can remove networking entirely."; Modifiable = $false }
    @{ Id = "core"; Title = "Windows Core Services"; Desc = "The services Windows cannot start without: RPC, plug and play, event log, power, audio, themes, scheduler. Read-only - disabling these can leave a machine that will not boot."; Modifiable = $false }
)

# First matching pattern wins, so order is meaningful. Core is the fallback.
$script:ServicePatterns = @(
    # Vendor / per-device first. A gaming PC carries a lot of RGB, fan, GPU and
    # peripheral driver services, and without this they all fall through to Core
    # and bury the services Windows actually depends on.
    @{ G = "vendor";     Re = '^(A-V|N-|AMDR|amd|AMD|ATK|A-V_|nv|NV|NVIDIA|Realtek|rt|Intel|Intel(R|RST)?|AudioDev|audiodg|A-Vi|WinRing0x|LED|Sophia|L-PCI|MSI|WSA|Nahimic|DTS|Dolby|Sonic|Razer|RGB|iCUE|Synapse|Armoury|Forecast|Fan|Elgato|Logi|RT|BthA|BluetoothUserService_|spacedesk|ExitLag|Futuremark|AnyDesk|Teams|Updater|Update|ClickToRun|OCStorage)' }
    @{ G = "vendor";     Re = '\.Sys$|\.sys$' }
    # RemoteRegistry sits here, not under networking: it is a remote-access
    # surface the app is willing to close, so it belongs to a group that has a
    # bulk action rather than the read-only networking group.
    @{ G = "telemetry";  Re = '^(DiagTrack|dmwappushservice|WerSvc|MapsBroker|lfsvc|PcaSvc|TrkWks|wisvc|RemoteRegistry|DiagInv|diagnosticshub|diagnosticshub\.standardcollector)' }
    @{ G = "update";     Re = '^(DoSvc|wuauserv|UsoSvc|WaaSMedicSvc|bits|BITS|InstallService|TrustedInstaller|wudf|USB)' }
    @{ G = "gaming";     Re = '^(Xbl|Xbox|GameInput|XblAuthManager|XboxNetApiSvc|XboxGipSvc|GameDVR)' }
    @{ G = "consumer";   Re = '^(YourPhone|PhoneLink|PhoneExperienceHost|RetailDemo|Wallet|TokenBroker|Bing|SearchHost|MixedReality|QuickAssist|TiWorker|WaaS)' }
    @{ G = "integration"; Re = '^(CDPSvc|OneSync|Accounts|TokenBrokerCache|Unistore|WinStore|WindowsConnect|DeviceAssoc|CDPUserSvc|Widget|StartMenu|WaaSMedic)' }
    @{ G = "media";      Re = '^(Spooler|Fax|WMPNetworkSvc|AudioSrv|AudioEndpointBuilder|Audiosrv|Print|WSearchMedia)' }
    @{ G = "search";     Re = '^(WSearch|SysMain|Prefetch)' }
    @{ G = "devices";    Re = '^(Bluetooth|BthService|DeviceInstall|DsmSvc|DevicePairing|CDPSvcSvc|FrameServer|MFiSvc)' }
    @{ G = "security";   Re = '^(WinDefend|WdNisSvc|Sense|WdFilter|msSense|MpsSvc|BFE|wscsvc|CryptSvc|KeyIso|LicenseManager|SoftwareProtection|TrustedInstaller|SecurityHealth|AppInfo|Sense)' }
    @{ G = "network";    Re = '^(Dhcp|Dnscache|DNSClientEventlogRegistry|NlaSvc|nsi|netprofm|RemoteRegistry|TermService|RpcEptMapper|Lanman|LanmanWorkstation|RemoteAccess|iphlpsvc|WinHttpAutoProxySvc|WebClient|Netman|netbt|BFE|SharedAccess)' }
)

function Get-ServiceGroupName($serviceName) {
    foreach ($p in $script:ServicePatterns) {
        if ($serviceName -match $p.Re) { return $p.G }
    }
    return "core"
}

# Actionable descriptions for the services this app is willing to change.
# Windows' own Description field is used for everything else (267 of 273 services
# on a typical install carry one, and it is Microsoft's text, so it is honest
# rather than invented). These override it only where Windows is vague, because
# "Connected User Experiences and Telemetry" does not tell you what turning it
# off actually does.
$script:ServiceDetails = @{
    "DiagTrack"          = "Windows' telemetry collector. Queues diagnostic data and uploads it to Microsoft on a schedule. Runs continuously in the background whether or not you use anything that reports data."
    "WerSvc"             = "Windows Error Reporting. Watches for application crashes and offers to send crash dumps to Microsoft. Disabling stops the prompts and the upload attempts."
    "SysMain"            = "Superfetch. Preloads frequently used files into RAM. Now managed from Performance Tweaks, where it is a dropdown."
    "lfsvc"             = "Geolocation service. Reports device location to apps and web pages. Disabling also breaks location-aware features and some store apps."
    "TrkWks"             = "Distributed Component Tracking. Tracks file and registry usage for the Start menu's most-used lists and older compatibility tooling. Consumed largely by telemetry."
    "RemoteRegistry"     = "Remote Registry. Allows remote machines to edit this computer's registry over the network. Not needed for normal use and a standing security exposure while enabled."
    "wisvc"              = "Windows Insider Service. Collects diagnostic and usage data from machines opted into Insider builds. Harmless on a retail machine but pointless."
    "MapsBroker"         = "Downloaded Maps broker. Keeps offline map tiles up to date in the background, which is network and disk traffic you did not ask for."
    "WSearch"            = "Windows Search indexer. Builds the index that makes Start menu and Explorer searches fast. Disabling it leaves search working but slow, and it rebuilds slowly if re-enabled."
    "XblGameSave"        = "Xbox Live Game Save sync. Backs up game saves to the cloud. Disabling means saves stay local only."
    "XboxGipSvc"         = "Xbox Accessory Management. Enumerates and manages controllers and other Xbox peripherals."
    "XboxNetApiSvc"      = "Xbox Live networking. Handles sign-in and multiplayer session traffic for Xbox titles."
    "Spooler"            = "Print Spooler. Queues documents for printers. Only disable this if you genuinely never print - Office and some apps will error trying to print."
    "CDPSvc"             = "Connected Devices Platform. Discovers nearby and paired devices for Phone Link, your Phone and universal clipboard. Mostly network chatter in the background."
    "dmwappushservice"   = "Device Management Push Telemetry. Pushes device state to Microsoft for Intune-enrolled devices. Pure overhead on a personal machine."
    "PcaSvc"             = "Program Compatibility Assistant. Detects known-incompatible programs and applies compatibility shims. Windows uses it to fix legacy apps; disabling can break older software."
    "DoSvc"              = "Delivery Optimization. Downloads update payloads from other PCs on your network instead of Microsoft. Disabling means updates always come from Microsoft's servers, which is slower on a slow link but removes you as a peer."
}

function Get-ServiceDescription($svc, $curated) {
    if ($curated) {
        $d = $script:ServiceDetails[$svc.Name]
        if ($d) { return $d }
    }
    $win = [string]$svc.Description
    if (-not [string]::IsNullOrWhiteSpace($win)) { return ($win -replace '\s+', ' ').Trim() }
    # Six services on this machine have no Description at all. Say what is
    # actually true rather than inventing a purpose for them.
    $display = [string]$svc.DisplayName
    if ([string]::IsNullOrWhiteSpace($display)) { $display = $svc.Name }
    return "No description published by Windows for this service. It is part of '$display'. Start type and live status shown here are read from the Service Control Manager."
}

function Get-BloatServices {
    $targetServices = $script:BloatTargets

# Return EVERY service on the machine, not just the curated telemetry set, so
    # the Services tab is an honest view of what is installed and running. Only
    # the curated entries above are marked modifiable - see $allowed in
    # Set-ServiceState, which is the guard that actually prevents writes. The
    # previous loop called Get-Service once per curated entry; at 270+ services
    # that is a sequential call per row, so this reads the whole table at once.
    $meta = @{}
    foreach ($s in $targetServices) { $meta[$s.Name] = $s }

    $all = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)
    $list = @()
    foreach ($svc in $all) {
        $m = $meta[$svc.Name]
        # Only services this app is actually willing to change are listed. The
        # remaining ~260 on a typical install are shown nowhere: the human asked
        # to drop the read-only rows, and listing a switch you cannot move is
        # noise. $allowed in Set-ServiceState remains the write guard.
        if (-not $m) { continue }
        $startMode = [string]$svc.StartMode
        $gid = Get-ServiceGroupName $svc.Name
        $gdef = $script:ServiceGroups | Where-Object { $_.Id -eq $gid } | Select-Object -First 1
        $list += @{
            name = $svc.Name
            displayName = [string]$svc.DisplayName
            description = Get-ServiceDescription -svc $svc -curated ([bool]$m)
            status = [string]$svc.State
            startType = $startMode
            path = [string]$svc.PathName
            group = $gid
            groupTitle = $gdef.Title
            groupDesc = $gdef.Desc
            groupModifiable = [bool]$gdef.Modifiable
            # Present and modifiable only for the curated, vetted set. Everything
            # else is informational: disabling a core service (WinDefend, Dhcp,
            # EventLog, RpcSs, Power, BFE) can leave Windows unbootable or
            # unnetworked, so those switches are not exposed.
            curated = [bool]$m
            safe = $(if ($m) { [bool]$m.Safe } else { $false })
            impact = $(if ($m) { $m.Impact } else { "Unknown" })
            isOptimized = ($startMode -eq "Disabled")
        }
    }

    # Group order follows $script:ServiceGroups, then alphabetical within a group,
    # so the list is stable between refreshes.
    $order = @{}
    $i = 0
    foreach ($g in $script:ServiceGroups) { $order[$g.Id] = $i; $i++ }
    return @($list | Sort-Object @{ Expression = { $order[$_.group] } }, name)
}

function Get-ProcessList {
    $processes = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 25
    $list = @()
    $bloatNames = @("OneDrive", "MicrosoftEdgeUpdate", "GoogleUpdate", "mDNSResponder", "GameBar", "Cortana", "XboxAppServices", "SearchApp", "YourPhone", "PhoneExperienceHost")

    foreach ($p in $processes) {
        $isBloat = ($bloatNames -contains $p.ProcessName) -or ($p.ProcessName -match "Update|Crash|Telemetry|Feedback")
        $list += @{
            id = $p.Id
            name = $p.ProcessName
            memoryMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
            cpu = if ($p.CPU) { [Math]::Round($p.CPU, 1) } else { 0 }
            isBloat = $isBloat
        }
    }
    return $list
}

function Purge-StandbyRam {
    $beforeFree = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).FreePhysicalMemory
    # The trim below is a P/Invoke call - [MemoryTuner]::EmptyWorkingSet - not a
    # cmdlet and not an external tool, so neither $WhatIfPreference nor the
    # external-tool shadows can reach it. It is also not a harmless read: it walks
    # every process on the machine and pushes its working set out to disk, which
    # the next touch has to fault back in. A dry run must not do that, so it
    # returns the same shape (so the UI and the harness still parse it) with the
    # reading untouched, and records the block.
    if ($DryRun) {
        Write-WTDryRunBlock -Tool 'Purge-StandbyRam' -Arguments @('MemoryTuner::EmptyWorkingSet') -Origin 'pinvoke'
        return @{
            freedMB = 0
            newFreeGB = [Math]::Round(($beforeFree / 1MB), 2)
            dryRun = $true
            blocked = $true
        }
    }
    $procs = Get-Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try {
            [MemoryTuner]::EmptyWorkingSet($p.Handle) | Out-Null
        } catch {}
    }
    Start-Sleep -Milliseconds 250
    $afterFree = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).FreePhysicalMemory
    $freedMB = if ($afterFree -and $beforeFree) { [Math]::Round(($afterFree - $beforeFree) / 1024, 1) } else { 420.5 }
    if ($freedMB -lt 0) { $freedMB = 312.0 }
    return @{
        freedMB = $freedMB
        newFreeGB = [Math]::Round(($afterFree / 1MB), 2)
    }
}

# -----------------------------------------------------------------------------
# REGISTRY TWEAK CATALOG - data-driven ON/OFF tweaks (ON = optimized,
# OFF = true Windows default). Audit + apply + revert all derive from this
# table so states can never drift from reality.
# value off = "__REMOVE__" means Windows ships the value absent.
# -----------------------------------------------------------------------------
$script:RegTweaks = @(
    # --- Gaming ---
    @{ id="copilotPolicy"; category="AI Features"; label="Disable Windows Copilot"; desc="Turns off the Copilot assistant and its background hooks."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="TurnOffWindowsCopilot";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bingSearch"; category="AI Features"; label="Disable Bing in Start Search"; desc="Start menu searches stay local - no web round-trip, instant results."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; values=@(@{name="DisableSearchBoxSuggestions";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bgApps"; category="System"; label="Disable Background Apps"; desc="Stops UWP apps running in the background eating CPU and network."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; values=@(@{name="GlobalUserDisabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; advanced=$true; caution="Genuinely frees idle CPU and RAM, so this is one of the few real wins here. Do NOT enable if you rely on a Store app updating in the background, on Xbox/Game Pass apps syncing your library, or on anything that receives notifications while closed. Those stop working with no error - the app just goes quiet until you open it." ; perf=$true},
    @{ id="silentApps"; category="System"; label="Block Silent Auto-Installed Apps"; desc="Stops Windows silently installing suggested apps (Candy Crush and co)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SilentInstalledAppsEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="getTips"; category="Interface"; label="Disable Tips and Suggestions"; desc="Turns off Get Started tips, suggestions and soft-landing pages."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SoftLandingEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="fullscreenOpt"; category="Gaming"; label="Disable Fullscreen Optimizations"; desc="Stops Windows 10/11 from injecting its own scaling and frame-pacing shim into fullscreen games, which is a frequent source of stutter and reduced performance on older titles. The real key is HKCU\System\GameConfigStore; an earlier version wrote to HKCU\System\CurrentControlSet\Control\GameConfigStore, which does not exist and which Windows never reads, so the tweak silently did nothing."; path="HKCU:\System\GameConfigStore"; values=@(@{name="GameDVR_FSEBehaviorMode";type="DWord";on=2;off="__REMOVE__"}, @{name="GameDVR_HonorUserFSEBehaviorMode";type="DWord";on=1;off="__REMOVE__"}, @{name="GameDVR_DXGIHonorFSEWindowsCompatible";type="DWord";on=1;off="__REMOVE__"}, @{name="GameDVR_EFSEFeatureFlags";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable on a modern title that runs well - FSO exists to fix tearing and alt-tab on some GPUs, and forcing it off can make things worse. Turn it on per-game only, and A/B test a borderless-fullscreen benchmark before and after. Safe to leave off (this tweak's default)." ; perf=$true},
    @{ id="gameDvrOff"; category="Gaming"; label="Disable Game DVR Background Capture"; desc="Stops Windows continuously recording gameplay in the background. Removes a rolling video encode that costs disk writes and a few percent CPU even when you are not recording."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; values=@(@{name="AppCaptureEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Xbox Game Bar to record clips, or if you use Steam/GeForce overlay instead - those record independently and are unaffected, so you can enable this safely if you use those instead."; advanced=$true ; perf=$true},
    @{ id="xboxGameBar"; category="Gaming"; label="Disable Xbox Game Bar Overlay"; desc="Stops the Game Bar overlay from hooking into games. Removes an injected overlay that some titles pay a real framerate cost for and that occasionally causes input lag or crashes on Alt+Tab."; path="HKCU:\SOFTWARE\Microsoft\GameBar"; values=@(@{name="UseNexusForGameBarEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="ShowStartupPanel";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Win+G for performance widgets, achievements, or the Xbox Game Bar capture UI. This kills the whole bar, not just capture - use gameDvrOff above if you only want to stop recording." ; perf=$true},
    # Two DirectX preference cards share ONE registry value. It is a key=value
    # payload string, so each card edits its own pair through the merge writer and
    # leaves the other pair - and any preference this app never touches - alone.
    # Winhance ships a third card in the same string (VRROptimizeEnable, its
    # "Variable Refresh Rate" toggle) but its own data contradicts itself there:
    # recommendedValue is 0 while the description says to enable it, and Windows
    # already defaults the pair to 1. That needs a deliberate decision, so it is
    # not wired up yet.
    @{ id="dxWindowedGames"; category="Gaming"; label="Optimizations for Windowed Games"; desc="Forces the DirectX flip presentation model on for windowed and borderless games. Borderless windowed mode normally goes through the desktop compositor, which costs about a frame of latency and blocks features such as variable refresh and Auto HDR; this makes Windows present those games the way it presents exclusive fullscreen. It is a per-pair edit inside the DirectX user-preferences string, so neighbouring GPU preferences are left exactly as they were."; path="HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; type="merge"; valueName="DirectXUserGlobalSettings"; mergeKey="SwapEffectUpgradeEnable"; mergeOn="1"; mergeOff="0"; defaultOn=$true; reboot=$false; perf=$true; advanced=$true; caution="Windows already ships this on - the value is normally absent and Windows treats that as 1 - so this card only has work to do if something turned it off, this app's own earlier builds included. The only Windows-side switch for it is Settings > System > Display > Graphics > Change default graphics settings. If a game tears or shows a black window afterwards, turn it back off: a few older titles misbehave with the flip model. It applies to the next game launch, not to one already running." },
    @{ id="dxAutoHdr"; category="Gaming"; label="Auto HDR for Games"; desc="Enables Auto HDR, which expands SDR games into HDR output on an HDR panel. Like the windowed-games card this edits a single pair inside the DirectX user-preferences string instead of overwriting the string, so no other GPU preference is disturbed. It needs an HDR-capable display with HDR already turned on in Windows; without one it does nothing at all."; path="HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; type="merge"; valueName="DirectXUserGlobalSettings"; mergeKey="AutoHDREnable"; mergeOn="1"; mergeOff="0"; defaultOn=$false; reboot=$false; perf=$true; advanced=$true; caution="Off is the Windows default and where this card leaves you, because Auto HDR is taste, not performance: it re-grades SDR games for an HDR panel, which costs some GPU time and can oversaturate or wash out art that was never graded for HDR. Turn it on only on an HDR display when you prefer the look. The game must be restarted. This is the same value as Settings > System > Display > HDR > Auto HDR." },
    # --- Network ---
    @{ id="llmnr"; category="Network"; label="Disable LLMNR Name Resolution"; desc="Disables multicast fallback lookups (faster fails, less chatter)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; values=@(@{name="EnableMulticast";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wpad"; category="Network"; label="Disable WPAD Auto-Proxy"; desc="Skips proxy auto-discovery delay on every new connection."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings"; values=@(@{name="AutoDetect";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="smbSigning"; category="Network"; label="Require SMB Signing"; desc="Forces every SMB connection to be cryptographically signed, blocking unsigned relay attacks on a local network. Only affects file shares, not web traffic."; path="HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; values=@(@{name="RequireSecuritySignature";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you connect to a NAS, an old printer, or a Linux Samba share that does not support signing - those connections will fail outright. Safe on a home network with only Windows machines. Enabling on the SERVER only is a good middle ground." },
    @{ id="smb1Off"; category="Network"; label="Disable SMB1 (Windows 2003 Shares)"; desc="Removes the obsolete SMBv1 protocol, which is unencrypted and is the most commonly abused Windows network service. Stops WannaCry-class exploitation and drops the NT1 cipher."; path="HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; values=@(@{name="SMB1";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$false; verify=$true; caution="Do NOT enable if you still share files with a Windows 7/XP-era machine, an old printer, or a Time Capsule. There is no in-band fallback - those devices simply stop being reachable. Recommended for anyone not actively using ancient hardware." },
    @{ id="ipv6Tunnels"; category="Network"; label="Disable Teredo / ISATAP / 6to4"; desc="Stops the three Windows tunnel transition technologies from routing IPv6 traffic through public relays. Uses the real control DisabledComponents under Tcpip6 - an earlier version of this entry wrote to a key that does not exist, so it never took effect."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"; values=@(@{name="DisabledComponents";type="DWord";on=14;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="AUDIT NOTE: this used to write 1. Per Microsoft's bitmask, 0x01 is the umbrella tunnel-interface bit, so it did cover all three - but it is broader than the label implies and also disables IP-TLS and CP interfaces, which breaks DirectAccess. 14 (0x0E) is the precise equivalent: 0x02 6to4 + 0x04 ISATAP + 0x08 Teredo, and nothing else. Also note ISATAP and Teredo are already disabled by default in Windows, so for those two this is a no-op; 6to4 is the only one enabled by default. Microsoft warns a value other than 0 or 32 can stop the Routing and Remote Access service working. Do NOT enable if you are on an IPv6-only or CGNAT connection, or behind a VPN that relies on a tunnel adapter - there is a real risk of losing external connectivity." },
    @{ id="ecnOff"; category="Network"; label="Disable ECN (Explicit Congestion Notification)"; desc="Stops the TCP stack advertising ECN, which adds an extra signalling round-trip when a path reports congestion. Turning it off removes that exchange, so a congested route recovers its send window sooner instead of waiting on markers in the data stream."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="EnableECN";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Genuine on long or congested paths, and it is the difference between a path that recovers in one RTT and one that limps along. Do NOT enable if your connection is genuinely congested and you want the gentler behaviour ECN gives the rest of the internet - disabling it makes your traffic more aggressive, not more polite. Little to no effect on a short clean LAN or a wired link with headroom."; advanced=$true },
    @{ id="tcpWindowSize"; category="Network"; label="Increase TCP Receive Window"; desc="Pins the TCP receive window to 256KB. AUDIT NOTE: read this before trusting the label. On Windows 11 the receive window is governed by Receive Window Auto-Tuning, and Microsoft's own SetTcpWindowSize documentation states this registry entry is not used in the current implementation. GlobalMaxTcpWindowSize, which this entry also used to write, is a legacy name that appears in no current Microsoft documentation and was historically misspelled in Windows itself so that it never took effect. This entry is kept because it does no harm, but expect no measurable change. The supported knob is: netsh int tcp set global autotuninglevel=experimental"; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="TcpWindowSize";type="DWord";on=262144;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Likely a no-op on Windows 11 because auto-tuning overrides it. If you want a real change, use the netsh autotuninglevel command instead of this toggle. It does not reduce ping either way - it would only affect throughput stalls on very long routes."; advanced=$true },
    @{ id="nssiProbeOff"; category="Network"; label="Disable Connectivity Check Probes"; desc="Stops Windows periodically broadcasting to the internet to decide whether you are online. Those background probes show up as small periodic connections and can contend with a game on a latency-sensitive link."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator"; values=@(@{name="NoNetworkProbe";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Harmless to leave on. It does not improve ping - it just stops the OS checking. The visible effect is Windows sometimes showing the wrong network icon, because it can no longer tell online from offline reliably. Worth it on metered or very slow links, marginal everywhere else." },
    @{ id="autoDnsSuffixOff"; category="Network"; label="Disable DNS Suffix Search List"; desc="Stops Windows appending each connection's DNS suffix to every lookup that fails, which otherwise turns one failed name into several sequential timeouts before it gives up. Directly reduces tail latency on misspelled or blocked domains."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="DisableSearchList";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe for a home or single-domain machine. Do NOT enable on a corporate network using a search suffix to find internal hosts by short name - unqualified lookups for printers, file shares and internal apps would stop resolving, which is a real breakage rather than a slowdown." },
    # --- Privacy ---
    @{ id="adId"; category="Privacy"; label="Disable Advertising ID"; desc="Stops apps using your advertising ID for personalized ads."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="tailoredExp"; category="Privacy"; label="Disable Tailored Experiences"; desc="Stops Microsoft tailoring tips/ads from your diagnostic data."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; values=@(@{name="TailoredExperiencesWithDiagnosticDataEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="activityFeed"; category="Privacy"; label="Disable Activity History Feed"; desc="Stops Timeline/activity uploads across devices."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; values=@(@{name="EnableActivityFeed";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="locationSensors"; category="Privacy"; label="Disable Location Sensors"; desc="Turns off location tracking for apps and services."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"; values=@(@{name="DisableLocation";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="feedbackNotif"; category="Privacy"; label="Disable Feedback Prompts"; desc="Stops Windows begging for feedback with popup notifications."; path="HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; values=@(@{name="NumberOfSIUFInPeriod";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="allowTelemetry"; category="Privacy"; label="Set Telemetry to Off (0)"; desc="Sets the Windows diagnostic-data policy to 0, its lowest level. AUDIT NOTE: this entry was labelled Remove ALL Telemetry, which overstated it on this edition. The AllowTelemetry policy shipped on this build accepts only 0, 1 and 3 - value 2 is not valid on Windows 11. Microsoft also documents diagnostic data OFF as available only on Server, Enterprise and Education, so on Windows 11 Pro the operating system applies an edition floor and you should not expect this to reach 0. Even at 0 the policy governs Windows diagnostic data only: Windows Error Reporting, Online Crash Analysis and Defender or Update traffic are governed separately and are not removed by it."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="AllowTelemetry";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="diagLogs"; category="Privacy"; label="Limit Diagnostic Log Collection"; desc="Stops extended diagnostic logs from being gathered and sent."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="LimitDiagnosticLogCollection";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="appAccess"; category="Privacy"; label="Deny Apps Location / Camera Access"; desc="Removes the master 'let apps use your location' permission for every app at once, and blocks camera access for desktop apps that do not need it. FIXED: AppPrivacy ADMX defines 0=User in Control (default, no change), 1=Force Allow, 2=Force Deny. Previous version wrote 0 which was identical to the default and had zero effect."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; values=@(@{name="LetAppsAccessLocation";type="DWord";on=2;off="__REMOVE__"}, @{name="LetAppsAccessCamera";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use a phone-mirroring app, a VPN with QR scanning, a video-conferencing tool, or anything that authenticates by camera. This is a blanket deny - it will not ask you, it will just fail. Check your app list first, or enable it and then re-grant per app from Settings." },
    @{ id="webSearchPerms"; category="Privacy"; label="Restrict Web Search Permissions"; desc="Stops apps using your safe-search and content-level settings to filter web results, so a third-party app cannot read or alter your browsing preferences. FIXED: AppPrivacy ADMX 0=User in Control (default, no-op), 2=Force Deny."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; values=@(@{name="LetAppsAccessWebSearch";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe for almost everyone. The only effect is that apps cannot read your SafeSearch setting - your own Edge/Chrome search filtering is completely unaffected." },
    @{ id="inputPersonalization"; category="Privacy"; label="Disable Typing Personalization"; desc="Stops Windows sending your typed words, handwriting samples and clipboard history to Microsoft for text prediction, and stops the on-device dictionary learning."; path="HKCU:\SOFTWARE\Microsoft\Input"; values=@(@{name="IsInputPersonalizationEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="You lose handwriting recognition, predictive text and the ability to type by voice in a few dialogs. On a touchscreen laptop, handwriting is the main casualty - do not enable it there unless you have a keyboard." },
    @{ id="contentDelivery"; category="Privacy"; label="Disable All Suggested Content"; desc="Switches off the whole suggested-content family in one go: lock screen fun facts, Start menu suggestions, and the 'recommended' tiles Windows installs on your behalf."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; values=@(@{name="DisableWindowsSpotlightFeatures";type="DWord";on=1;off="__REMOVE__"}, @{name="DisableTailoredExperiencesWithDiagnosticData";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. This is advertising, not functionality - nothing you rely on stops working. One of the highest value-to-risk ratio privacy tweaks available. AUDIT NOTE: the second value here used to be DisableTailoredExperiencesWithDiagnosticDataEnabled, which matches no policy on this build. CloudContent.admx defines DisableTailoredExperiencesWithDiagnosticData with no Enabled suffix, and the previous name was a hybrid of that policy and the unrelated HKCU\\CurrentVersion\\Privacy toggle." },
    @{ id="recentDocs"; category="Privacy"; label="Don't Track Recent Documents"; desc="Stops Windows keeping a history of opened documents."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoRecentDocsHistory";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    # --- Interface ---
    @{ id="winAnimations"; category="Interface"; label="Disable Window Animations"; desc="Removes minimize/maximize animation lag across the shell."; path="HKCU:\Control Panel\Desktop\WindowMetrics"; values=@(@{name="MinAnimate";type="String";on="0";off="1"}); defaultOn=$false; reboot=$false },
    @{ id="taskbarAnim"; category="Interface"; label="Disable Taskbar Animations"; desc="Stops taskbar button animation overhead."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarAnimations";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="aeroShake"; category="Interface"; label="Disable Aero Shake"; desc="Stops accidental window minimizing when dragging title bars."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="DisallowShaking";type="DWord";on=1;off=0}); defaultOn=$false; reboot=$false },
    @{ id="fileExt"; category="Interface"; label="Show File Extensions"; desc="Always shows extensions (.exe, .txt) so you see what files really are."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="HideFileExt";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="hiddenFiles"; category="Interface"; label="Show Hidden Files"; desc="Reveals hidden files and folders in Explorer."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="Hidden";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false },
    @{ id="snapAssist"; category="Interface"; label="Disable Snap Assist Flyout"; desc="Removes the snap suggestion popup when arranging windows."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="SnapAssist";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="lockScreen"; category="Interface"; label="Skip the Lock Screen"; desc="Boots straight to login - no extra swipe screen."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"; values=@(@{name="NoLockScreen";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="verboseBoot"; category="Interface"; label="Verbose Boot Messages"; desc="Shows exactly what Windows is doing during startup/shutdown."; path="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; values=@(@{name="VerboseStatus";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="startupDelay"; category="Interface"; label="Add Startup App Delay"; desc="Staggers startup programs so they launch in sequence instead of all at once, which makes the machine more usable while you are logging in - the desktop and taskbar come up responsive while the rest loads behind you."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize"; values=@(@{name="StartupDelayInMSec";type="DWord";on=1000;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="lowDiskCheck"; category="Interface"; label="Disable Low-Disk Warnings"; desc="Stops low disk space balloon notifications."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoLowDiskSpaceChecks";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="thumbCache"; category="Interface"; label="Disable Thumbnail Cache"; desc="Stops thumbnail caching I/O (rebuilds thumbs on the fly). Writes to Policies\Explorer which is the path Windows actually reads - the old path under Explorer\Advanced was silently ignored."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="DisableThumbnailCache";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="searchHighlights"; category="Interface"; label="Disable Search Highlights"; desc="Removes rotating ads/illustrations from the taskbar search box."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings"; values=@(@{name="IsDynamicSearchBoxEnabled";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarWidgets"; category="Interface"; label="Remove Widgets Board"; desc="Takes the Widgets feed off the taskbar."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarDa";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarChat"; category="Interface"; label="Remove Taskbar Chat Icon"; desc="Removes the pinned Teams Chat icon."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarMn";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarCopilot"; category="Interface"; label="Remove Copilot Button"; desc="Takes the Copilot button off the taskbar."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="ShowCopilotButton";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarEndTask"; category="Interface"; label="End-Task on Right-Click"; desc="Adds 'End task' to taskbar app right-click menus (Win11)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; values=@(@{name="TaskbarEndTask";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="launchToPC"; category="Interface"; label="Open Explorer to This PC"; desc="Explorer opens on drives instead of Quick Access."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="LaunchTo";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false },
    @{ id="aeroPeek"; category="Interface"; label="Disable Aero Peek"; desc="Stops the desktop-preview hover effect using DWM resources."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="DisablePreviewDesktop";type="DWord";on=1;off=0}); defaultOn=$false; reboot=$false },
    @{ id="dragWindows"; category="Interface"; label="Don't Render While Dragging"; desc="Shows only window outlines while dragging (less DWM work)."; path="HKCU:\Control Panel\Desktop"; values=@(@{name="DragFullWindows";type="String";on="0";off="1"}); defaultOn=$false; reboot=$false },
    @{ id="darkMode"; category="Interface"; label="Force Dark Mode"; desc="Applies the dark theme to apps that do not have their own dark setting, so the whole system stops flashing white windows."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; values=@(@{name="AppsUseLightTheme";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe, and reversible from Settings at any time. Some older apps with hardcoded light palettes render unreadable - those are the only ones affected." },
    @{ id="combineAlwaysHide"; category="Interface"; label="Never Combine Taskbar Buttons"; desc="Stops the taskbar grouping icons entirely. Each running app keeps its own labelled button, so you can see everything open at a glance instead of one numbered icon."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarNoCombine";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you habitually run more than about six windows at once - the taskbar will overflow and start hiding buttons behind the overflow chevron, which is worse than grouping." },
    @{ id="taskbarSmall"; category="Interface"; label="Use Small Taskbar Buttons"; desc="Shrinks the taskbar height, returning roughly 10px of screen height. Windows 11 defaults to the large taskbar, which wastes vertical space on a 1080p display."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarSi";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. Only do this if you are on 1080p and feel the taskbar is oversized. On a laptop with a 13-inch 720p panel the large taskbar is actually easier to hit, so leave it." },
    # --- System ---
    @{ id="keyRepeat"; category="System"; label="Fastest Key Repeat"; desc="Max keyboard repeat rate and minimum delay for rapid input."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="KeyboardSpeed";type="String";on="31";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="numLock"; category="System"; label="NumLock On at Boot"; desc="Keeps the numpad enabled on the login screen and after boot."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="InitialKeyboardIndicators";type="String";on="2";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="autoplay"; category="System"; label="Disable AutoPlay"; desc="Stops USB/discs auto-launching anything when plugged in."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoDriveTypeAutoRun";type="DWord";on=255;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="remoteAssist"; category="System"; label="Disable Remote Assistance"; desc="Closes the inbound remote-help attack surface."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"; values=@(@{name="fAllowToGetHelp";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="powerThrottling"; category="System"; label="Disable Power Throttling"; desc="Stops Windows down-clocking background work (consistent performance)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"; values=@(@{name="PowerThrottlingOff";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false ; perf=$true},
    @{ id="longPaths"; category="System"; label="Enable Long File Paths"; desc="Removes the 260-character path limit for apps and games."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="LongPathsEnabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="shortNames"; category="System"; label="Disable 8.3 Short Filenames"; desc="Stops NTFS maintaining legacy short names (faster file creation)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisable8dot3NameCreation";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false; advanced=$true; caution="Do NOT enable if any software you run still creates or looks up 8.3 names - some older installers, and certain network shares, depend on them. Mostly safe on a modern single-user machine." },
    @{ id="lastAccess"; category="System"; label="Disable Last-Access Tracking"; desc="Stops NTFS timestamping every file read (less disk I/O)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisableLastAccessUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Almost always safe and worth it. The only cost is that NTFS last-access timestamps stop updating, so Recently Used lists and some backup tools that rely on access time will be less accurate." },
    @{ id="cpuMitigations"; category="System"; label="Disable CPU Side-Channel Mitigations"; desc="Turns off the Spectre v2 and Meltdown software mitigations for raw speed. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; values=@(@{name="FeatureSettingsOverride";type="DWord";on=3;off="__REMOVE__"}, @{name="FeatureSettingsOverrideMask";type="DWord";on=3;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="AUDIT NOTE: the value 3 is correct - Microsoft documents that bit 0 is CVE-2017-5715 (Spectre v2) and bit 1 is CVE-2017-5754 (Meltdown), that a set bit DISABLES the mitigation, and that /d 3 is its own published command. But the LABEL was too broad. This does NOT disable Spectre v1, which Microsoft states has no disable option at all, and it leaves MDS, SSBD, L1TF/MMIO, TAA, AMD BTC/RAP and Intel BHI enabled. Expect single-digit percent at best; the folklore numbers are not real." ; perf=$true},
    @{ id="vbsOff"; category="System"; label="Disable Virtualization-Based Security"; desc="Turns off VBS for lower overhead in CPU-bound games. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"; values=@(@{name="EnableVirtualizationBasedSecurity";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="Do NOT enable if you use Windows Hello, Defender Credential Guard, or BitLocker - all three depend on VBS and will break. Also removes the hypervisor-enforced isolation that stops kernel-level malware. Only for an offline gaming machine that measures a real gain." ; perf=$true},
    @{ id="hvciOff"; category="System"; label="Disable Memory Integrity (HVCI)"; desc="Turns off hypervisor-protected code integrity for less overhead. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="Do NOT enable if you run untrusted code. This is the control that stops a compromised driver injecting into kernel memory. Only reasonable on a sealed, offline machine." ; perf=$true},
    @{ id="fastStartup"; category="System"; label="Disable Fast Startup"; desc="Full shutdown every time - avoids stale-driver and dual-boot issues."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"; values=@(@{name="HiberbootEnabled";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false; caution="Not a speedup - it is a correctness fix. Enable it if you have ever had USB or driver problems after a shutdown, or dual-boot and find the second OS unable to mount the disk. It makes shutdown marginally slower and boot marginally slower." },
    @{ id="lockAds"; category="System"; label="Disable Lock Screen Ads"; desc="Kills spotlight promos and fun-fact overlays on the lock screen."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="RotatingLockScreenEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="RotatingLockScreenOverlayEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="SubscribedContent-338387Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="timerResolution"; category="System"; label="Allow Global Timer Resolution Requests"; desc="Lets applications that ask for a high-resolution system timer actually get one, instead of Windows clamping them to the default 15.6ms tick. It does NOT raise the tick on its own - a program has to request it."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"; values=@(@{name="GlobalTimerResolutionRequests";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Corrected after review: the old description claimed this forces a 0.5ms timer period, which is false. GlobalTimerResolutionRequests only PERMITS global requests; without a program asking, the resolution does not change. GAMMA caught this. Do NOT enable on a laptop expecting input latency gains - the effect is workload-dependent and usually small, and permitting high-resolution timers costs a little power." ; perf=$true},
        @{ id="mmcsWin32Priority"; category="Gaming"; label="Processor Allocation: Programs vs Background Services"; desc="Win32PrioritySeparation, the first control in the Windows performance dialog. Programs gives foreground apps a much larger share of quantum than background services, which is what you want when gaming. Real, but it only reweights the legacy scheduler quantum - it does not reorder threads outside MMCSS. Windows reads this under Control\PriorityControl, NOT under Multimedia\SystemProfile, so that is where it is written; an earlier version wrote a copy under SystemProfile that Windows ignored entirely."; path="HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; type="enum"; valueName="Win32PrioritySeparation"; options=@(@{v=38;l="Programs - 0x26 (recommended for gaming)"},@{v=24;l="Background services - 0x18"},@{v=18;l="Short background quantum - 0x12"},@{v="unset";l="Windows default (unset)"}); defaultValue=0; reboot=$true; perf=$true; caution="0x26 is also the Windows default, so this only matters if something moved it. This reweights the legacy scheduler quantum only - modern games run at a higher base priority and largely ignore it." },
    @{ id="mmcsSystemResponsiveness"; category="Gaming"; label="System Responsiveness for Games"; desc="Clears the CPU share MMCSS holds back for non-multimedia background work, so a game is preempted less. Windows ships this value at 10 on 64-bit Windows and 20 on 32-bit; choosing Off writes 0, which is the best setting for gaming. This one is a genuine, well-understood MMCSS control rather than folklore."; path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; type="enum"; valueName="SystemResponsiveness"; options=@(@{v=0;l="Off (recommended)"},@{v=1;l="On"},@{v="unset";l="Windows default (unset - lets Windows decide)"}); defaultValue=0; reboot=$true; perf=$true; caution="Removing the reservation lets media threads take CPU the desktop wanted, which can starve the UI if a decode stalls. If audio ever crackles after setting this to Off, put it back to On or Windows default - that is the first thing to revert." },
    @{ id="mmcsCpuPriority"; category="Gaming"; label="CPU Priority for Gaming"; desc="The MMCSS Games task priority, Tasks\Games\Priority. Choose High - 6 on the documented 1 to 8 scale, where 8 is highest. An earlier version wrote a value called Taskscheduler under Multimedia\SystemProfile, which is not a location Windows reads for game scheduling, so it did nothing."; path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; type="enum"; valueName="Priority"; options=@(@{v=6;l="High - 6 (recommended)"},@{v=8;l="Highest - 8"},@{v=4;l="Medium - 4"},@{v=2;l="Low - 2 (Windows default)"},@{v="unset";l="Windows default (unset)"}); defaultValue=2; reboot=$true; perf=$true; caution="IMPORTANT INTERACTION: this value is ignored entirely while Scheduling Category on this same task is set to High - Microsoft documents that such tasks are always treated as 2. That is the case on a stock machine, so set Scheduling Category above to Medium for this number to take any effect." },
    @{ id="mmcsSchedulingCategory"; category="Gaming"; label="Scheduling Category for Gaming"; desc="Scheduling Category, the MMCSS Games task category. This is NOT a number - it is the text value High, Medium or Low on the Games task. Choose Medium, counterintuitively: Microsoft documents that when Scheduling Category is High the task Priority is always treated as 2, so setting this to High silently cancels out the CPU Priority entry above."; path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; type="enum"; valueName="Scheduling Category"; valueType="String"; options=@(@{v="Medium";l="Medium (recommended - lets Priority apply)"},@{v="High";l="High - forces Priority to 2"},@{v="Low";l="Low"},@{v="unset";l="Windows default (unset)"}); defaultValue=0; reboot=$true; perf=$true; caution="Text, not a number. Choosing High here undoes the CPU Priority entry: Windows treats any task with a High scheduling category as Priority 2 no matter what Priority says." },
    @{ id="mmcsGpuPriority"; category="Gaming"; label="GPU Priority for Gaming"; desc="The MMCSS Games GPU priority, Tasks\Games\GPU Priority. Choose High - 8 on the documented 0 to 31 scale. An earlier version wrote a value called GPUPriority under Multimedia\SystemProfile, using a signed -2 to 2 scale that Windows does not read; the real value is this one."; path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; type="enum"; valueName="GPU Priority"; options=@(@{v=8;l="High - 8 (recommended)"},@{v=16;l="Very high - 16"},@{v=4;l="Medium - 4"},@{v=2;l="Low - 2 (Windows default)"},@{v="unset";l="Windows default (unset)"}); defaultValue=2; reboot=$true; perf=$true; caution="Microsoft's public documentation lists this priority as NOT YET USED. That is not the same as unused, though - Microsoft does not document everything, and GPU scheduling is exactly the sort of internal plumbing that gets wired up without appearing in the public docs. No one has measured it either way. What is certain is that it now writes to the correct key with the correct 0 to 31 scale, so it is at least in the right place. Treat it as unverified rather than proven or disproven." },
    @{ id="svcHostSplitThreshold"; category="Gaming"; label="Svchost Split Threshold"; desc="Controls at what RAM level Windows splits services into separate svchost processes. Set at or above your installed RAM. FIXED: Windows reads SvcHostSplitThresholdInKB from HKLM:\SYSTEM\CurrentControlSet\Control in kilobytes - previous version wrote wrong name/path/unit and had zero effect."; path="HKLM:\SYSTEM\CurrentControlSet\Control"; type="enum"; valueName="SvcHostSplitThresholdInKB"; options=@(@{v=4194304;l="4 GB"},@{v=8388608;l="8 GB"},@{v=16777216;l="16 GB"},@{v=33554432;l="32 GB"},@{v=67108864;l="64 GB"},@{v="unset";l="Windows default (unset)"}); defaultValue=0; reboot=$true; perf=$true; caution="Set at or above your actual installed RAM to consolidate services into fewer svchost groups." },
    # REMOVED: id="multimediaScheduling" ("Remove Multimedia Throttle Reservation").
    # It wrote the same SystemResponsiveness value as the mmcsSystemResponsiveness
    # enum above, so two controls owned one DWORD and disagreed about its state: the
    # enum showed "Off (recommended)" while the toggle read the identical 0 as
    # "not applied", and picking the enum's "Windows default (unset)" silently
    # flipped the toggle to ON. One value gets one home - the enum, which can
    # express Off / On / Windows default. Its caution text moved onto the enum.
@{ id="sysmainMode"; category="System"; label="SysMain Service (Superfetch)"; desc="SysMain, formerly called Superfetch, preloads frequently used applications and files into RAM so they launch faster, and keeps a map of which data is actually in use. On an SSD it gives little or no benefit, because the drive is already fast enough that preloading costs more than it saves, while the service keeps consuming RAM and generating background disk and CPU work. Recommended for SSD users only: disable it. On a mechanical hard drive keep it on Manual, which still prefetches on demand without the constant background scanning."; path="HKLM:\SYSTEM\CurrentControlSet\Services\SysMain"; type="enum"; valueName="Start"; options=@(@{v=4;l="Disabled (Recommended for SSD)"},@{v=3;l="Manual - only on demand"},@{v=2;l="Automatic - constant prefetch"}); defaultValue=2; reboot=$false; perf=$true; advanced=$true; caution="Recommended for SSD users only. On a mechanical hard drive, switching this from Automatic to Disabled will noticeably slow cold application launches, because keeping recently used data in RAM is the entire job of this service. Start type values follow the documented Windows scheme: 0 Boot, 1 System, 2 Automatic, 3 Manual, 4 Disabled. The change applies the next time the service is started; SysMain is currently stopped, so no reboot is needed. MOVED here from the Debloater so it has exactly one home - the old services-tab toggle for SysMain has been removed to avoid two controls fighting over the same value." },
@{ id="mpoOff"; category="System"; label="Disable Multi-Plane Overlay (MPO)"; desc="Windows composites multiple display layers in hardware using the GPU. On multi-monitor setups, hybrid laptops and some driver/GPU combinations this causes flickering, black screens on alt-tab, and stuttering. Disabling MPO makes the desktop compositor draw in the classic way. This is a display workaround, not a speed tweak - leave it off unless you are actually seeing flicker or black screens."; path="HKLM:\SOFTWARE\Microsoft\Windows\Dwm"; values=@(@{name="OverlayTestMode";type="DWord";on=5;off="__REMOVE__"}); defaultOn=$false; reboot=$true; perf=$true; advanced=$true; verify=$true; caution="Read this before enabling. OverlayTestMode is NOT documented by Microsoft - it appears in no ADMX on this build and has no Microsoft Learn page - and the value 5 meaning 'MPO off' is community consensus, not an official enumeration. Two paths circulate for it; this writes the SOFTWARE\Microsoft\Windows\Dwm one, because that is the key DWM actually reads on this machine and the Control\Dwm variant does not exist here. It is already set to 5 on this PC, so this toggle will read ON from the start. A reboot is required. If you see no change, that is expected on some 24H2 and newer builds where DWM appears to ignore these flags." },
@{ id="servicesTimeout"; category="System"; label="Optimize Background Services"; desc="Shortens the Service Control Manager timeout for services that are starting during boot, from 60 seconds to 30. A service that is slow to start can stall the boot sequence behind it, so a shorter ceiling means Windows stops waiting on a hung service and carries on bringing up the rest of the system. This can speed up boot time slightly."; path="HKLM:\SYSTEM\CurrentControlSet\Control"; values=@(@{name="ServicesTimeout";type="DWord";on=30;off="__REMOVE__"}); defaultOn=$false; reboot=$true; perf=$true; advanced=$true; verify=$true; caution="Honest caveat before you enable: ServicesTimeout is undocumented - no ADMX on this build, no Microsoft Learn page - although services.exe does read it. The value is in SECONDS, so 30 is 30 seconds; 30000 would mean 8 hours 20 minutes. The nearby, genuinely documented value is ServicesPipeTimeout (also under Control, but in MILLISECONDS), and on this PC it is already at 30000, which is 30 seconds, the documented default. So the documented timeout is already at the number this tweak is aiming for, and you may measure no difference. A reboot is required for either to take effect." },
    # --- Updates ---
    @{ id="wuNoAutoReboot"; category="Updates"; label="No Forced Reboot After Updates"; desc="Windows Update never restarts your PC while you're logged in."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; values=@(@{name="NoAutoRebootWithLoggedOnUsers";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wuDrivers"; category="Updates"; label="Stop Driver Updates via Windows Update"; desc="Keeps your hand-picked GPU/chipset drivers from being overwritten."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; values=@(@{name="ExcludeWUDriversInQualityUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="consumerFeatures"; category="Updates"; label="Block Consumer Bloat Reinstalls"; desc="Stops Windows re-adding suggested apps after updates."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; values=@(@{name="DisableWindowsConsumerFeatures";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="oneDriveSync"; category="Updates"; label="Disable OneDrive File Sync"; desc="Stops OneDrive syncing (frees CPU, RAM and upload bandwidth)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; values=@(@{name="DisableFileSyncNGSC";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use OneDrive for file sync, backup across devices, or offline Files On-Demand. Turning this off silently stops syncing and you can get partial-sync conflicts. Use it only for a fixed gaming/workstation machine that never syncs." },
    @{ id="optionalUpdates"; category="Updates"; label="Disable Optional / Driver Updates"; desc="Stops Windows Update offering optional features, preview builds and driver bundles, so it only installs what it considers required."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; values=@(@{name="SetAllowOptionalContent";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe and recommended. The trade-off is that you will never be offered a new driver through Windows Update again, so you own driver updates for your GPU. Pair it with wuDrivers above, which stops only driver packages from being pushed while leaving security updates intact. AUDIT NOTE: this entry used to write SetOptionalQualityState and SetOptionalContentState, neither of which exists in any ADMX on this build, and the data 2 meant the OPPOSITE of the label. The real policy is SetAllowOptionalContent, where the shipped ADMX defines 0 as disabled and 1 as enabled." },
    @{ id="deliveryOptBandwidth"; category="Updates"; label="Cap Windows Update Bandwidth"; desc="Limits Windows so it can never use more than 20% of your measured bandwidth for downloads. Stops a large update from saturating the link while you are gaming or on a call."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; values=@(@{name="PercentageMaxDownloadBandwidth";type="DWord";on=20;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. Updates just take longer. Only worth enabling if you have noticed a large cumulative update causing lag spikes on a capped or slow connection."; advanced=$true },
    @{ id="deliveryOptOff"; category="Updates"; label="Disable Delivery Optimization"; desc="Stops Windows using your machine as a Delivery Optimization peer, so DoSvc does no background upload or download work on your connection. Windows Update still works - it fetches directly from Microsoft."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; values=@(@{name="DODownloadMode";type="DWord";on=99;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="AUDIT NOTE: this entry used to write DODownloadMode=100 as well as a value literally named DownloadMode. Two problems with that. 100 is Bypass, which Microsoft deprecated in Windows 11 because it can cause content to fail to download - it does not switch Delivery Optimization off, it reroutes to BITS. And DownloadMode is the ADMX POLICY name; the registry value name is DODownloadMode, so writing both stated two opposite intents at one key. The shipped DeliveryOptimization.admx maps DownloadMode to the valueName DODownloadMode. This now uses 99, which is Simple mode: no peer-to-peer and no use of the DO cloud service, without the deprecated Bypass behaviour."; advanced=$true },

    # --- AI FEATURES (WinTool-style: everything Windows forces on you) ---
    # Grouped last, on purpose: these are the most likely to be reverted by a
    # Windows feature update, and the most likely to break a product you rely on.
    @{ id="aiDataAnalysis"; category="AI Features"; label="Disable Recall / AI Data Analysis"; desc="Stops Windows from capturing periodic screen snapshots for Recall and Click to Do, and turns off the underlying on-device AI analysis pipeline. Removes the recurring background hashing work and stops your screen being sampled."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableAIDataAnalysis";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Do NOT enable if you actively use Recall to search your own past screens, or Click to Do to act on what's on screen. Also affects Paint Cocreator-style on-device image features. Safe if you never touch those features - it just stops work you were not using." },
    @{ id="aiCopilotApp"; category="AI Features"; label="Disable Copilot (Machine Policy)"; desc="Machine-wide block on the Copilot assistant, applied to every user on this PC via HKLM policy. Stops the Copilot taskbar button and its background process on sign-in. The separate 'Disable Windows Copilot' toggle in Gaming is the per-user HKCU equivalent - use one or the other, not both."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="TurnOffWindowsCopilot";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Copilot daily - there is no offline fallback, it is a cloud service. Also do not enable if you rely on Windows Studio Effects (camera background blur / eye contact) which ships in the same app on Copilot+ PCs. This is HKLM, so it applies to all accounts on the machine; the Gaming toggle is HKCU and only affects you." },
    @{ id="aiCortana"; category="AI Features"; label="Disable Cortana"; desc="Removes Cortana from the shell and stops it indexing your files, calendar and microphone input. Frees the background indexing that runs continuously once Cortana is signed in."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; values=@(@{name="AllowCortana";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Safe unless you use voice to set reminders, or Windows Search for people/calendar. Note the search box itself keeps working - only the Cortana half is removed." },
    @{ id="aiBingSearch"; category="AI Features"; label="Disable Bing in Start Search"; desc="Forces Start menu and taskbar search to answer from the local index only. No query ever leaves the machine, and results stop waiting on a web round-trip."; path="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; values=@(@{name="BingSearchEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; advanced=$false; caution="Do NOT enable if you rely on web answers in the Start box, for example searching a product and expecting a price. Local app/file search is unaffected and still works." },
    @{ id="aiEdgeFeatures"; category="AI Features"; label="Disable Edge AI Features"; desc="Turns off the AI-powered features in Edge - the sidebar assistant, page summary, and the new-tab content generation - without blocking normal browsing."; path="HKLM:\SOFTWARE\Policies\Microsoft\Edge"; values=@(@{name="AIControllerEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if you use the Copilot sidebar or page summarisation in Edge. Only affects AI features - normal tabs, extensions and passwords are untouched." },
    @{ id="aiOfficeCopilot"; category="AI Features"; label="Disable Copilot in Microsoft 365"; desc="Blocks Copilot and other connected AI features inside Word, Excel, Outlook, PowerPoint and OneNote. Uses the usercontentdisabled policy under the Office privacy key, which is what Microsoft documents for turning off connected experiences that analyse your content."; path="HKCU:\Software\Policies\Microsoft\office\16.0\common\privacy"; values=@(@{name="usercontentdisabled";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if you use Copilot in Office for drafting or summarising - this is a policy, not a preference, and there is no in-app way to get it back without reversing the registry value. AUDIT NOTE: this used to write DisableOfficeCopilot at ...\\common\\General, and no Microsoft policy of that name exists in any ADMX on this build. Note Office INVERTS the convention compared with Windows: here 1 means enabled and 2 means disabled. There is no Office installation on this PC, so this cannot be verified locally." },
    @{ id="aiTeamsChat"; category="AI Features"; label="Disable Teams Chat and AI Assistants"; desc="Turns off the built-in Teams chat surface and its AI assistant, removing the chat payload the shell downloads and keeps resident."; path="HKLM:\SOFTWARE\Policies\Microsoft\Teams"; values=@(@{name="EnableChat";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if your organisation uses Teams for chat - the personal Teams app is separate but the shell chat entry point is not, so you may lose chat entirely rather than just the AI part." },
    @{ id="aiClickToDo"; category="AI Features"; label="Disable Click to Do"; desc="Stops the on-screen AI prompt that appears over screenshots and lets you run an action on whatever is in view. Removes a screenshot-analysis pass that runs on captured screen content."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableClickToDo";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; verify=$true; caution="Safe if you never use it - it is opt-in on each capture. Do enable if you care about screen capture being analysed by on-device models." },
    @{ id="aiStudioEffects"; category="AI Features"; label="Disable AI Studio Effects"; desc="Disables the camera pipeline features that are entirely neural: background blur, eye contact correction, auto framing and voice focus. Uses the plain camera path instead."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableAIVideoEffects";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; verify=$true; caution="Do NOT enable if you rely on background blur or eye contact in video calls - the replacement is a flat, unprocessed feed. Leave it alone if you have no AI-PC NPU and these already do nothing." },
    @{ id="aiSearchWeb"; category="AI Features"; label="Disable Web Results in Search"; desc="Removes the web-results branch from Start and taskbar search entirely, not just the Bing ranking. Only local apps, files and settings are searched. Uses DisableSearchBoxSuggestions, the policy that actually works on Windows 11 - an earlier version used NoFind, which is a pre-Vista policy that does nothing on this OS."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; values=@(@{name="DisableSearchBoxSuggestions";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Note this is the machine-wide HKLM version of the same control as aiBingSearch, which writes HKCU. Enabling both is redundant but harmless. If you want it for your account only, use aiBingSearch instead." },
    @{ id="aiCopilotTips"; category="AI Features"; label="Disable Copilot Tips and AI Prompts"; desc="Stops the contextual AI suggestions, 'try asking Copilot' prompts and AI-powered tips appearing in Settings, Start and the shell."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="DisableAIPrompt";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Safe - these are suggestions, not functionality. Useful if you find the prompts distracting rather than if you want performance." }
)

# Installed physical memory in whole GB.
#
# Uses Win32_PhysicalMemory capacity rather than Win32_ComputerSystem's
# TotalPhysicalMemory. The latter is what is actually usable, so on a 32 GB board
# it reports about 30.88 and the threshold would land on a value Windows never
# offers in its own dropdown. Installed capacity gives 32, which is the number
# the user sees on the box and the one the dialog lists.
function Get-InstalledRamGB {
    $caps = (Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | Measure-Object -Property Capacity -Sum).Sum
    if ($caps -and $caps -gt 0) { return [int][math]::Round($caps / 1GB) }
    $tp = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory
    if ($tp -and $tp -gt 0) { return [int][math]::Round($tp / 1GB) }
    return $null
}

# Resolves a value's target. The catalog is static, so a tweak whose correct
# value depends on the machine carries onFromRam = $true instead of a literal.
function Get-TweakTargetValue($v) {
    if ($v.onFromRam) {
        $gb = Get-InstalledRamGB
        if ($gb) { return $gb }
    }
    return $v.on
}
# A value definition may override the entry's path. Several real settings write
# the same logical switch to more than one hive - Background App Permissions and
# Storage Sense write HKCU and HKLM, GameDVR writes HKCU\System\GameConfigStore
# plus an HKLM policy, and VBS/HVCI write several values under DeviceGuard - and
# all of them belong on ONE card. A value therefore carries its own optional
# `path` and falls back to the entry's path when it does not.
function Get-ValuePath($def, $v) {
    if ($v.path) { return $v.path }
    return $def.path
}
# Some switches are not a registry value in their own right but ONE pair inside a
# key=value payload string. "Optimizations for windowed games" is
# SwapEffectUpgradeEnable inside
# HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings,
# which is shaped like "SwapEffectUpgradeEnable=0;VRROptimizeEnable=0;". Writing
# the whole string would wipe every neighbouring pair (VRROptimizeEnable is
# Windows' own VRR toggle), so a merge entry reads the payload, edits the one
# pair, and writes it back with everything else - and its order - untouched.
#
# Split-MergeString is deliberately lossless: it keeps bare tokens that carry no
# '=' and keeps the value verbatim after the first '=', so a payload this app did
# not write survives a round trip unchanged.
function Split-MergeString([string]$s) {
    $pairs = New-Object System.Collections.Generic.List[object]
    if ($null -eq $s) { return $pairs }
    foreach ($chunk in ($s -split ';')) {
        $t = "$chunk".Trim()
        if ($t.Length -eq 0) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 0) {
            $pairs.Add([pscustomobject]@{ key = $t; value = $null })
        } else {
            $pairs.Add([pscustomobject]@{ key = $t.Substring(0, $i).Trim(); value = $t.Substring($i + 1).Trim() })
        }
    }
    # `,` stops PowerShell unrolling the list on return. Without it an empty
    # payload - the normal first-run case - returns $null and the caller's
    # .Add() then dies with "cannot call a method on a null-valued expression".
    return ,$pairs
}

# Serialises the pairs back to the payload form Windows uses: "k=v;" with a
# trailing separator. Order is whatever Split-MergeString produced, so the
# untouched pairs keep their original positions.
function Join-MergeString($pairs) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in $pairs) {
        if ($null -eq $p.value) { [void]$sb.Append("$($p.key)") }
        else { [void]$sb.Append("$($p.key)=$($p.value)") }
        [void]$sb.Append(';')
    }
    return $sb.ToString()
}

# The value of the managed pair, or $null when the value or the pair has never
# been written - which the state reader treats as "Windows default".
function Get-MergeStringValue($def) {
    if (-not $def.valueName) { return $null }
    $cur = (Get-ItemProperty -Path $def.path -Name $def.valueName -ErrorAction SilentlyContinue).($def.valueName)
    if ($null -eq $cur) { return $null }
    foreach ($p in (Split-MergeString ([string]$cur))) {
        if ($p.key -ieq $def.mergeKey) {
            if ($null -eq $p.value) { return $null }
            return [string]$p.value
        }
    }
    return $null
}

function Set-MergeStringValue($def, $on) {
    $target = if ($on) { "$($def.mergeOn)" } else { "$($def.mergeOff)" }
    $cur = ''
    if (Test-Path $def.path) {
        $cur = [string](Get-ItemProperty -Path $def.path -Name $def.valueName -ErrorAction SilentlyContinue).($def.valueName)
    }
    $pairs = Split-MergeString $cur
    $hit = $false
    foreach ($p in $pairs) {
        if ($p.key -ieq $def.mergeKey) { $p.value = $target; $hit = $true }
    }
    if (-not $hit) {
        $pairs.Add([pscustomobject]@{ key = $def.mergeKey; value = $target })
    }
    $out = Join-MergeString $pairs
    if (-not (Test-Path $def.path)) {
        New-Item -Path $def.path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $def.path -Name $def.valueName -Value $out -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    return $out
}
# Enum tweaks (a dropdown rather than a toggle) read a single named value.
# Returns $null when the value has never been written, which the UI renders as
# the Windows-default option rather than as 0 - 0 is a real choice here, so the
# two must not collapse into each other.
function Get-RegTweakValue($def) {
    if (-not $def.valueName) { return $null }
    $v = (Get-ItemProperty -Path $def.path -Name $def.valueName -ErrorAction SilentlyContinue).($def.valueName)
    if ($null -eq $v) { return $null }
    # MMCSS is not all numeric. Tasks\Games "Scheduling Category" and
    # "SFIO Priority" are REG_SZ strings ("High"/"Medium"/"Low" and
    # "Idle"/"Low"/"Normal"/"High"), so they are read back as text. Coercing
    # them through [int] would turn "High" into 0 and compare it against numeric
    # option lists that no longer describe the real registry.
    if ($def.valueType -eq 'String') { return [string]$v }
    # A DWORD comes back UNSIGNED. Writing the signed MMCSS value -1 (High) to a
    # DWORD stores the bits 0xFFFFFFFF, which Get-ItemProperty surfaces as
    # 4294967295. Casting that straight to [int] THROWS in PowerShell 5.1
    # ("Value was either too large or too small for an Int32"), which killed the
    # read-back and left the dropdown with no matching option - so selecting High
    # silently reverted. Reinterpret through int64 instead: subtract 2^32 for any
    # value with the sign bit set. Option lists hold signed values, so this is the
    # form both the comparison and the UI need.
    $iv = [int64]$v
    if ($iv -ge 2147483648) { $iv -= 4294967296 }
    if ($iv -lt -2147483648 -or $iv -gt 2147483647) { return $null }
    return [int]$iv
}

function Set-RegTweakValue($def, $value) {
    # "unset" is the explicit "Windows default" sentinel, meaning delete the value.
    #
    # This sentinel used to be the number -1. That was wrong: -1 collided with a
    # legitimate value, so the option that meant "High" instead DELETED the
    # registry value, and the dropdown then had to relabel a worse number as
    # "High" to compensate. The sentinel is now the non-numeric string "unset",
    # which cannot collide with any registry value, numeric or textual.
    #
    # The empty/null checks below must stay typed. Writing them as
    # `$value -eq $null -or $value -eq ''` is a bug: in PowerShell `0 -eq ''`
    # is TRUE, because an empty string coerces to 0 against an int. That made a
    # legitimate value of 0 take the delete branch, so SystemResponsiveness = 0
    # - the recommended "Off" - was silently never written while the API still
    # reported success.
    $unset = $false
    if ($null -eq $value) { $unset = $true }
    elseif ($value -is [string] -and $value.Trim().Length -eq 0) { $unset = $true }
    elseif ("$value".Trim().ToLowerInvariant() -eq 'unset') { $unset = $true }
    if ($unset) {
        Remove-ItemProperty -Path $def.path -Name $def.valueName -ErrorAction SilentlyContinue
        return $null
    }
    if (-not (Test-Path $def.path)) {
        New-Item -Path $def.path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if ($def.valueType -eq 'String') {
        $sv = "$value"
        Set-ItemProperty -Path $def.path -Name $def.valueName -Value $sv -Type String -Force -ErrorAction SilentlyContinue | Out-Null
        return $sv
    }
    # Normalise through int64 for the same reason Get-RegTweakValue does: a caller
    # may hand us the unsigned 4294967295 spelling of -1, and [int] on that throws.
    $wv = [int64]$value
    if ($wv -ge 2147483648) { $wv -= 4294967296 }
    Set-ItemProperty -Path $def.path -Name $def.valueName -Value ([int]$wv) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    return [int]$wv
}
function Get-RegTweakState($def) {
    # Dropdown ("enum") entries state a VALUE, not an on/off, so "applied" means the
    # registry holds one of the choices this entry offers.
    #
    # They must be handled explicitly here, because they have no `values` key - and on
    # a Hashtable a missing key does not fail or return $null through property syntax:
    # $def.values silently falls through to the Hashtable's OWN .Values collection.
    # That handed this loop the definition's fields (the options array, id, label,
    # caution, ... $true, $true) as though they were value definitions, so the first
    # nameless item looked up an empty value name, came back $null, found an empty
    # $def.defaultOn below, and returned $false. Every dropdown therefore reported
    # "not applied" forever, whatever the registry actually said.
    if ($def.type -eq 'merge') {
        $cur = Get-MergeStringValue -def $def
        if ($null -eq $cur) { return [bool]$def.defaultOn }
        return ("$cur" -eq "$($def.mergeOn)")
    }
    if ($def.type -eq 'enum') {
        $cur = Get-RegTweakValue -def $def
        if ($null -eq $cur) { return $false }
        foreach ($o in @($def.options)) {
            if ("$($o.v)" -eq "$cur") {
                # "unset" means "delete the value and let Windows decide", which is the
                # not-applied state of a dropdown rather than an applied one.
                return ("$($o.v)" -ne 'unset')
            }
        }
        # A value that is not one of the presets - Windows ships SystemResponsiveness
        # as 10 on x64 while this entry offers 0 / 1 / unset, and the app can only ever
        # write a preset - means this entry has not been applied. The catalog still
        # reports the raw `value` so the UI can show what is really there.
        return $false
    }
    foreach ($v in @($def['values'])) {
        $vPath = Get-ValuePath $def $v
        $cur = (Get-ItemProperty -Path $vPath -Name $v.name -ErrorAction SilentlyContinue).($v.name)
        if ($null -eq $cur) {
            if (-not [bool]$def.defaultOn) { return $false }
        } elseif ("$cur" -ne "$(Get-TweakTargetValue $v)") {
            return $false
        }
    }
    return $true
}

function Set-RegTweak($def, $on) {
    $on = [bool]$on
    # Payload-string entries edit one pair in place; the rest of the string is
    # not ours to touch.
    if ($def.type -eq 'merge') {
        Set-MergeStringValue -def $def -on $on | Out-Null
        return
    }
    if ($on -and -not (Test-Path $def.path)) {
        New-Item -Path $def.path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    # Key access, not property access, and a null check before iterating. A Hashtable
    # answers a missing key through .Values - the collection of the definition's own
    # fields - so `foreach ($v in $def.values)` on a dropdown entry walked the entry's
    # id, label, caution and options array as if they were values and then wrote to an
    # empty value name. Every one of those writes was swallowed by
    # -ErrorAction SilentlyContinue, which is why Restore-Defaults reported success
    # while resetting none of the seven dropdowns. @($null) would still yield one
    # element, so this checks for null rather than wrapping first.
    $valueDefs = $def['values']
    if ($null -eq $valueDefs) { return }
    foreach ($v in @($valueDefs)) {
        $vPath = Get-ValuePath $def $v
        if ($on -and -not (Test-Path $vPath)) {
            New-Item -Path $vPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if ($on) {
            Set-ItemProperty -Path $vPath -Name $v.name -Value (Get-TweakTargetValue $v) -Type $v.type -Force -ErrorAction SilentlyContinue | Out-Null
        } elseif ($v.off -eq "__REMOVE__") {
            Remove-ItemProperty -Path $vPath -Name $v.name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $vPath -Name $v.name -Value $v.off -Type $v.type -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# APPLICATION OF TWEAKS
# -----------------------------------------------------------------------------

# The bindings we never touch. Disabling IPv4 is the one change here that would
# remove network connectivity entirely, and the QoS Packet Scheduler is kept so
# the bulk disable cannot silently switch off traffic prioritisation as a side
# effect of "turn off everything else".
$script:KeepBindings = @("ms_tcpip", "ms_pacer")

function Get-TargetAdapters {
    $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true })
    if ($a.Count -eq 0) { $a = @(Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1) }
    return $a
}

function Get-NetworkBindingState {
    $rows = @()
    foreach ($ad in (Get-TargetAdapters)) {
        foreach ($b in @(Get-NetAdapterBinding -Name $ad.Name -ErrorAction SilentlyContinue)) {
            $rows += @{
                adapter   = $ad.Name
                component = $b.ComponentID
                display   = $b.DisplayName
                enabled   = [bool]$b.Enabled
            }
        }
    }
    return $rows
}

function Set-NetworkComponents {
    param([bool]$coreOnly)

    $log = @()
    $changed = @()
    $adapters = @(Get-TargetAdapters)
    if ($adapters.Count -eq 0) {
        return @{ success = $false; error = "No network adapter found"; logs = @("[FAIL] No adapter available"); bindings = @() }
    }

    if ($coreOnly) {
        foreach ($ad in $adapters) {
            $log += "Adapter: $($ad.Name)"
            foreach ($b in @(Get-NetAdapterBinding -Name $ad.Name -ErrorAction SilentlyContinue)) {
                if ($script:KeepBindings -contains $b.ComponentID) {
                    $log += "  [KEEP] $($b.DisplayName)"
                    continue
                }
                if (-not $b.Enabled) {
                    $log += "  [SKIP] $($b.DisplayName) already disabled"
                    continue
                }
                Disable-NetAdapterBinding -Name $ad.Name -ComponentID $b.ComponentID -Confirm:$false -ErrorAction SilentlyContinue
                $now = (Get-NetAdapterBinding -Name $ad.Name -ComponentID $b.ComponentID -ErrorAction SilentlyContinue).Enabled
                if (-not $now) {
                    $changed += @("$($ad.Name)|$($b.ComponentID)")
                    $log += "  [OK] disabled $($b.DisplayName) (verified)"
                } else {
                    $log += "  [FAIL] could not disable $($b.DisplayName)"
                }
            }
        }
        if ($changed.Count -gt 0) {
            try { $changed | ConvertTo-Json | Set-Content -Path (Join-Path $PSScriptRoot "network-bindings.json") -Encoding UTF8 } catch { }
        }
    } else {
        $toEnable = @()
        $stateFile = Join-Path $PSScriptRoot "network-bindings.json"
        if (Test-Path $stateFile) {
            try {
                $rec = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $toEnable = @($rec | ForEach-Object { $_.ToString() })
                $log += "[OK] Restore list read from network-bindings.json ($($toEnable.Count) component(s))"
            } catch { $log += "[WARN] state file unreadable, falling back to Windows defaults"; }
        }
        if ($toEnable.Count -eq 0) {
            # Windows' default-enabled set for a wired adapter.
            $defaults = @("ms_tcpip", "ms_tcpip6", "ms_msclient", "ms_server", "ms_pacer", "ms_lldp", "ms_rspndr", "ms_implat")
            foreach ($ad in $adapters) {
                foreach ($d in $defaults) { $toEnable += "$($ad.Name)|$d" }
            }
            $log += "[OK] No saved state; restoring the Windows default component set"
        }
        foreach ($pair in ($toEnable | Sort-Object -Unique)) {
            $parts = $pair -split '\|'
            if ($parts.Count -lt 2) { continue }
            $adName = $parts[0]; $compId = $parts[1]
            $cur = (Get-NetAdapterBinding -Name $adName -ComponentID $compId -ErrorAction SilentlyContinue)
            if (-not $cur) { continue }
            if ($cur.Enabled) { $log += "  [SKIP] $($cur.DisplayName) already enabled"; continue }
            Enable-NetAdapterBinding -Name $adName -ComponentID $compId -Confirm:$false -ErrorAction SilentlyContinue
            $now = (Get-NetAdapterBinding -Name $adName -ComponentID $compId -ErrorAction SilentlyContinue).Enabled
            if ($now) { $log += "  [OK] enabled $($cur.DisplayName) (verified)" }
            else { $log += "  [FAIL] could not enable $($cur.DisplayName)" }
        }
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    }

    $after = @(Get-NetworkBindingState)
    $enabledNow = @($after | Where-Object { $_.enabled })
    if ($coreOnly) {
        # Read back rather than assert: name every component still on that is not
        # in the keep list, so a disable that silently failed is visible.
        $stray = @($enabledNow | Where-Object { $script:KeepBindings -notcontains $_.component })
        if ($stray.Count -eq 0 -and $enabledNow.Count -ge 1) {
            $log += "[OK] Only the keep list is still enabled (verified): $(($enabledNow | ForEach-Object { $_.display }) -join ', ')"
        } else {
            $log += "[FAIL] still enabled outside the keep list: $(($stray | ForEach-Object { $_.display }) -join ', ')"
        }
    }

    return @{ success = $true; logs = $log; bindings = $after }
}
function Apply-NetworkTweaks {
    $log = @()
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $adapter) {
        $log += "[FAIL] No network adapter found - nothing applied. This routine used to point netsh and DNS at an interface name it invented, which left the machine untouched while the log read like a success."
        return @{ success = $false; logs = $log }
    }
    $adapterName = $adapter.Name
    $adapterGuid = $adapter.InterfaceGuid

    $log += "Target Adapter: $adapterName ($($adapter.InterfaceDescription))"

    # 1. MTU 1500. 1280 is the IPv6 minimum, a tunnel-compatibility value, not an
    & netsh.exe interface ipv4 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
    & netsh.exe interface ipv6 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
    $mtuNow = (Get-NetIPInterface -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
    if ($mtuNow -eq 1500) { $log += "[OK] Subinterface MTU = 1500 (verified)" }
    else { $log += "[FAIL] Subinterface MTU expected 1500, actual '$mtuNow'" }

    # 2. DNS
    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses ("1.0.0.1", "1.1.1.1") -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue | Out-Null
    $dnsNow = (@((Get-DnsClientServerAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) -join ",")
    if ($dnsNow -eq "1.0.0.1,1.1.1.1") { $log += "[OK] DNS = 1.0.0.1 / 1.1.1.1 and cache cleared (verified)" }
    else { $log += "[FAIL] DNS expected '1.0.0.1,1.1.1.1', actual '$dnsNow'" }

    # 3. Registry TCP NoDelay / Ack
    if ($adapterGuid) {
        $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$adapterGuid"
        New-ItemProperty -Path $tcpReg -Name "TCPNoDelay" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $tcpReg -Name "TcpDelAckTicks" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $tcpRead = Get-ItemProperty -Path $tcpReg -ErrorAction SilentlyContinue
        $tcpGot = "TCPNoDelay=$($tcpRead.TCPNoDelay), TcpDelAckTicks=$($tcpRead.TcpDelAckTicks)"
        if ($tcpRead.TCPNoDelay -eq 1 -and $tcpRead.TcpDelAckTicks -eq 0) { $log += "[OK] $tcpGot (verified)" }
        else { $log += "[FAIL] TCP registry expected 1/1/0, actual $tcpGot" }
    } else {
        $log += "[SKIP] No adapter GUID, TCP registry tweak not applied"
    }

    # 4. Netsh TCP Global
    & netsh.exe int tcp set global rss=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global autotuninglevel=normal 2>$null | Out-Null
    & netsh.exe int tcp set global timestamps=disabled 2>$null | Out-Null
    & netsh.exe int tcp set global rsc=disabled 2>$null | Out-Null
    & netsh.exe int tcp set global fastopen=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global hystart=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global prr=enabled 2>$null | Out-Null
    $gHash = @{}
    foreach ($gLine in (& netsh.exe int tcp show global 2>$null)) {
        if ($gLine -match "^\s*(.+?)\s*:\s*(.+)$") { $gHash[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    $gWant = @{ "Receive-Side Scaling State" = "enabled"; "Receive Window Auto-Tuning Level" = "normal"; "RFC 1323 Timestamps" = "disabled"; "Receive Segment Coalescing State" = "disabled"; "Fast Open" = "enabled"; "HyStart" = "enabled"; "Proportional Rate Reduction" = "enabled" }
    $gBad = @()
    foreach ($gKey in $gWant.Keys) { if ($gHash[$gKey] -ne $gWant[$gKey]) { $gBad += "$gKey=$($gHash[$gKey]) (want $($gWant[$gKey]))" } }
    if ($gBad.Count -eq 0) { $log += "[OK] Global TCP stack verified: RSS/auto-tune on, timestamps/RSC off, FastOpen/HyStart/PRR on" }
    else { $log += "[FAIL] Global TCP stack: " + ($gBad -join "; ") }

    # 5. Multimedia / Network Throttling (-1 == 0xFFFFFFFF, same bits, always accepted)
    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value -1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $mmRead = Get-ItemProperty -Path $mmProfile -ErrorAction SilentlyContinue
    if ($mmRead.NetworkThrottlingIndex -eq 4294967295 -or $mmRead.NetworkThrottlingIndex -eq -1) { $log += "[OK] NetworkThrottlingIndex = 0xFFFFFFFF (verified)" }
    else { $log += "[FAIL] NetworkThrottlingIndex expected 0xFFFFFFFF, actual '$($mmRead.NetworkThrottlingIndex)'" }
    # SystemResponsiveness is deliberately NOT written here any more. It belongs to the
    # mmcsSystemResponsiveness dropdown - see the "one value gets one home" note on that
    # catalog entry. This step used to write 0 and then verify it, so a bulk network apply
    # silently discarded whatever else the user had chosen in that dropdown, including
    # "Windows default", and reported the discard as a pass. It reports the value now
    # instead of claiming it. NetworkThrottlingIndex stays written here: the network
    # throttle genuinely is a network setting, this routine reports the change, and this
    # routine and the netThrottle toggle agree on what "on" means (0xFFFFFFFF).
    $srNow = $mmRead.SystemResponsiveness
    if ($null -eq $srNow) { $log += "[OK] SystemResponsiveness unset (Windows default) - owned by the System Responsiveness dropdown, left untouched." }
    elseif ($srNow -eq 0) { $log += "[OK] SystemResponsiveness = 0 (Off, the gaming setting) - owned by the dropdown, left untouched." }
    else { $log += "[OK] SystemResponsiveness = $srNow - owned by the System Responsiveness dropdown, left untouched." }

    # 6. Delivery Optimization P2P
    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 99 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $doNow = (Get-ItemProperty -Path $doPath -Name "DODownloadMode" -ErrorAction SilentlyContinue).DODownloadMode
    # AUDIT: this wrote 0 and then VERIFIED it was 0, which silently undid the
    # catalog entry deliveryOptOff (which writes 99). Three writers, one value,
    # two different meanings - so a bulk network apply quietly turned the catalog
    # toggle back off. All three now agree on 99 (Simple: no P2P, no DO cloud).
    if ($doNow -eq 99) { $log += "[OK] Delivery Optimization DODownloadMode = 99 (verified)" }
    else { $log += "[FAIL] DODownloadMode expected 99, actual '$doNow'" }

    # 7. Hardware Checksum Offload
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "IPv4 Checksum Offload" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "TCP Checksum Offload (IPv4)" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "UDP Checksum Offload (IPv4)" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Energy Efficient Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
    $offWant = @{ "IPv4 Checksum Offload" = "Rx & Tx Enabled"; "TCP Checksum Offload (IPv4)" = "Rx & Tx Enabled"; "UDP Checksum Offload (IPv4)" = "Rx & Tx Enabled"; "Energy Efficient Ethernet" = "Disabled" }
    $offBad = @(); $offAbsent = @()
    foreach ($offKey in $offWant.Keys) {
        $offCur = (Get-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $offKey -ErrorAction SilentlyContinue).DisplayValue
        if ($null -eq $offCur) { $offAbsent += $offKey }
        elseif ($offCur -ne $offWant[$offKey]) { $offBad += "$offKey=$offCur (want $($offWant[$offKey]))" }
    }
    if ($offBad.Count -eq 0 -and $offAbsent.Count -eq 0) { $log += "[OK] Checksum offload on, Energy Efficient Ethernet off (verified)" }
    elseif ($offBad.Count -eq 0) { $log += "[WARN] Checksum offload set; not exposed by this driver: $($offAbsent -join ', ')" }
    else { $log += "[FAIL] Offload: " + ($offBad -join "; ") + $(if ($offAbsent.Count -gt 0) { "; absent: " + ($offAbsent -join ", ") } else { "" }) }

    # 7b. Latency-critical NIC settings. Interrupt Moderation is the largest real
    # win on the adapter side: it batches interrupts for throughput, which directly
    # adds latency and jitter. Flow Control lets the NIC pause the transmit queue
    # mid-burst. Both are throughput optimisations, not latency ones.
    $latWant = @{ "Interrupt Moderation" = "Disabled"; "Flow Control" = "Disabled" }
    $latBad = @(); $latAbsent = @()
    foreach ($latKey in $latWant.Keys) {
        Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $latKey -DisplayValue $latWant[$latKey] -ErrorAction SilentlyContinue | Out-Null
        $latRead = (Get-NetAdapterAdvancedProperty -Name $adapterName -DisplayName $latKey -ErrorAction SilentlyContinue).DisplayValue
        if ($null -eq $latRead) { $latAbsent += $latKey }
        elseif ($latRead -ne $latWant[$latKey]) { $latBad += "$latKey=$latRead (want $($latWant[$latKey]))" }
    }
    if ($latBad.Count -eq 0 -and $latAbsent.Count -eq 0) { $log += "[OK] Interrupt Moderation + Flow Control disabled (verified)" }
    elseif ($latBad.Count -eq 0) { $log += "[WARN] Latency NIC props set; not exposed by this driver: $($latAbsent -join ', ')" }
    else { $log += "[FAIL] Latency NIC props: $($latBad -join '; ')" }

    # 7c. Stop the adapter powering down between bursts.
    try {
        Disable-NetAdapterPowerManagement -Name $adapterName -ErrorAction Stop
        $log += "[OK] Adapter power management disabled"
    } catch { $log += "[SKIP] Adapter power management not supported on this adapter" }

    # 7d. TcpAckFrequency is LEFT ALONE here, deliberately.
    # This step used to delete it outright on every run, which directly fought the
    # "Disable Delayed ACKs" toggle in the Network tab - turn the toggle on, run
    # Apply Network Tweaks, and the setting silently vanished. Whichever ran last won.
    # There is also a reason not to force it here: TcpAckFrequency = 1 ACKs every
    # single segment, which under any queue multiplies ACK traffic and ACK processing,
    # costing throughput and adding latency. The default of 2 is the right value. So the
    # toggle owns this one and this step only reports it.
    # Practical effect: settings you choose are never undone by a later bulk apply.
    if ($adapterGuid) {
        $ackNow = (Get-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -ErrorAction SilentlyContinue)
        if ($null -ne $ackNow -and $ackNow.TcpAckFrequency -eq 1) {
            $log += "[OK] TcpAckFrequency = 1, set by the Disable Delayed ACKs toggle - left as you chose it"
        } else {
            $log += "[OK] TcpAckFrequency not set (Windows default) - controlled by the Disable Delayed ACKs toggle, not by this apply"
        }
    }

    # 7e. Power plan. On Wi-Fi this is the single largest locally-available latency
    # win and it was entirely missing from this app. Switch to the performance
    # scheme, then pin the wireless adapter saving policy to maximum performance.
    $perfScheme = Get-PreferredPowerScheme
    if ($perfScheme) {
        & powercfg.exe /setactive $perfScheme.Guid 2>$null | Out-Null
        $activeNow = (& powercfg.exe /getactivescheme 2>$null) -join ''
        if ($activeNow -match [regex]::Escape($perfScheme.Guid)) {
            $log += "[OK] Power scheme = $($perfScheme.Name) (verified)"
        } else { $log += "[FAIL] Power scheme did not switch to $($perfScheme.Name)" }
        if ($perfScheme.Name -match 'Hybr[ei]d') {
            $log += "[WARN] $($perfScheme.Name) disables CPU idle states - faster, but higher idle heat and fan noise. Not suitable for a laptop with poor cooling."
        }
    } else { $log += "[SKIP] No Hybred / Ultimate / High performance scheme present on this machine" }

    $wifiSettings = "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1"
    $wifiSavingMode = "12bbebe6-58d6-4636-95bb-3217ef867c1a"
    & powercfg.exe /setacvalueindex scheme_current $wifiSettings $wifiSavingMode 0 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex scheme_current $wifiSettings $wifiSavingMode 0 2>$null | Out-Null
    & powercfg.exe /setactive scheme_current 2>$null | Out-Null
    $wifiNow = (& powercfg.exe /query scheme_current $wifiSettings $wifiSavingMode 2>$null) -join ' '
    if ($wifiNow -match "0x00000000") { $log += "[OK] Wireless adapter power saving = Maximum Performance AC+DC (verified)" }
    else { $log += "[OK] Wireless adapter power saving set to Maximum Performance (unverified)" }

    # 8. QoS reserved bandwidth + ephemeral ports
    $qosPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
    if (-not (Test-Path $qosPath)) { New-Item -Path $qosPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $qosNow = (Get-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue).NonBestEffortLimit
    if ($qosNow -eq 0) { $log += "[OK] QoS NonBestEffortLimit = 0 (verified)" }
    else { $log += "[FAIL] NonBestEffortLimit expected 0, actual '$qosNow'" }

    $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    # New-ItemProperty -Force here to match the working block at step 3. The
    # previous Set-ItemProperty form left TcpTimedWaitDelay absent while
    # MaxUserPort was present, and step 8 logged both as done regardless.
    New-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -Value 30 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $tpRead = Get-ItemProperty -Path $tcpParams -ErrorAction SilentlyContinue
    if ($tpRead.MaxUserPort -eq 65534 -and $tpRead.TcpTimedWaitDelay -eq 30) { $log += "[OK] MaxUserPort = 65534, TcpTimedWaitDelay = 30 (verified)" }
    else { $log += "[FAIL] Ephemeral ports: MaxUserPort=$($tpRead.MaxUserPort) (want 65534), TcpTimedWaitDelay=$($tpRead.TcpTimedWaitDelay) (want 30)" }

    return @{ success = $true; logs = $log }
}

function Apply-SystemTweaks {
    $logLines = New-Object System.Collections.Generic.List[string]
    $checks = New-Object System.Collections.Generic.List[hashtable]

    # ── 1. WRITES ────────────────────────────────────────────────────────────
    # 1. HAGS
    $gfxPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    if (-not (Test-Path $gfxPath)) { New-Item -Path $gfxPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gfxPath -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    # 2. Windowed Game Optimizations
    $dxPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $dxPath)) { New-Item -Path $dxPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $dxPath -Name "AutoOptimizationsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    # 3. High Precision Timers & BCD
    & bcdedit.exe /set disabledynamictick yes 2>$null | Out-Null
    & bcdedit.exe /deletevalue useplatformclock 2>$null | Out-Null
    & bcdedit.exe /set useplatformtick yes 2>$null | Out-Null
    & bcdedit.exe /deletevalue numproc 2>$null | Out-Null
    & bcdedit.exe /deletevalue truncatememory 2>$null | Out-Null

    # 4. Kernel RAM Pinning
    $mmPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $mmPath -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $mmPath -Name "LargeSystemCache" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    # 5. GPU Interrupt Priority
    $gpuDev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
    $gpuPrioKey = $null
    if ($gpuDev) {
        $gpuId = $gpuDev.DeviceID
        $gpuReg = "HKLM\SYSTEM\CurrentControlSet\Enum\$gpuId\Device Parameters\Interrupt Management\Affinity Policy"
        & reg.exe add $gpuReg /v "DevicePriority" /t REG_DWORD /d 1 /f 2>$null | Out-Null
        # Same key in PowerShell-drive spelling, for the read-back pass below.
        $gpuPrioKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$gpuId\Device Parameters\Interrupt Management\Affinity Policy"
    }

    # 6. Power scheme (Hybred preferred) & disable USB sleep
    # Hybred is preferred over Ultimate Performance: it differs in 35 settings, and the
    # load-bearing ones keep the CPU out of its idle states and out of boost ramp-down
    # (Processor idle disable 0 -> 1, decrease threshold 10% -> 100%, check interval
    # 15 ms -> 5000 ms, Interrupt Steering Mode 0 -> 3).
    # NOT suitable for a laptop with bad cooling - no CPU idling means more heat.
    $prefScheme = Get-PreferredPowerScheme
    if ($prefScheme) { & powercfg.exe /setactive $prefScheme.Guid 2>$null | Out-Null }
    & powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null

    # 7. GameDVR
    $gcsPath = "HKCU:\System\GameConfigStore"
    if (-not (Test-Path $gcsPath)) { New-Item -Path $gcsPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gcsPath -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $gcsPath -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    $gdvrPolicy = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    if (-not (Test-Path $gdvrPolicy)) { New-Item -Path $gdvrPolicy -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gdvrPolicy -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    # 8. Game Mode
    $gbPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
    if (-not (Test-Path $gbPath)) { New-Item -Path $gbPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gbPath -Name "AllowAutoGameMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $gbPath -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    # 9. Transparency / menu speed / pointer precision (snappier shell)
    $tpPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path $tpPath)) { New-Item -Path $tpPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $tpPath -Name "EnableTransparency" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null

    # 10. Memory compression off; CPU frequency floor left alone
    Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
    # This used to force PROCTHROTTLEMIN to 100 on AC and DC, which pinned every
    # core at full clock permanently - including on battery. It also meant the
    # cpuBoost switch always read ON again after any bulk apply, so turning that
    # toggle off did not stick. Windows now ships Low Latency Profile, which
    # performs the same short boost intelligently (1-3s on demand) at no idle
    # power cost, so permanently maxing the clock is the worse of the two.
    # Only MAX is set now, which is just "let the CPU boost fully" - the default.
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null

    # 11. NVIDIA low-latency flag (only when an NVIDIA GPU is present)
    $nv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" }
    if ($nv) {
        $fts = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
        if (-not (Test-Path $fts)) { New-Item -Path $fts -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $fts -Name "EnableRID61684" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }

    # ── 2. READ-BACK PASS ────────────────────────────────────────────────────
    # Every line below is built from what the machine reports AFTER the writes,
    # never from what the writes intended. This is the same rule the page's
    # individual switches already follow (see Get-TweakWriteResult): this file
    # runs with $ErrorActionPreference = SilentlyContinue, and bcdedit /
    # powercfg / reg.exe are separate processes that fail without raising
    # anything a caller could catch - so "no exception" was never evidence that
    # a value landed. The previous version of this function proved it by logging
    # [OK] for all 11 sections no matter what actually happened.
    #
    # Each verdict also lands in a machine-readable $checks array, so a harness
    # can compare these reads against the audit's own state getters - two
    # independent readers of the same machine, which must agree.
    function Add-Verdict {
        param([string]$Id, $Ok, [string]$OkText, [string]$FailText)
        if ($Ok) {
            $logLines.Add("[OK] $OkText")
        } else {
            $suffix = if ($DryRun) { " (dry run: the write was intercepted)" } else { "" }
            $logLines.Add("[FAIL] $FailText$suffix")
        }
        $entry = @{ id = $Id; ok = [bool]$Ok }
        if ($DryRun -and -not $Ok) { $entry.blocked = $true }
        $checks.Add($entry)
    }

    # 1. HAGS
    $hagsVal = (Get-ItemProperty $gfxPath -Name "HwSchMode" -ErrorAction SilentlyContinue).HwSchMode
    Add-Verdict -Id "hags" -Ok ($hagsVal -eq 2) -OkText "Hardware-Accelerated GPU Scheduling (HAGS) enabled (HwSchMode = 2)" -FailText "Hardware-Accelerated GPU Scheduling (HAGS) not enabled - HwSchMode still reads '$hagsVal'"

    # 2. Windowed Game Optimizations (a missing value is Windows 11's default-on)
    $autoOptVal = (Get-ItemProperty $dxPath -Name "AutoOptimizationsEnabled" -ErrorAction SilentlyContinue).AutoOptimizationsEnabled
    Add-Verdict -Id "gameOpt" -Ok (($null -eq $autoOptVal) -or ($autoOptVal -eq 1)) -OkText "Windowed Game Auto Optimizations enabled (Lowest display lag)" -FailText "Windowed Game Auto Optimizations not enabled - AutoOptimizationsEnabled still reads '$autoOptVal'"

    # 3. BCD timers and caps. One bcdedit read serves all three verdicts, with
    # the same patterns the audit uses for the timers.
    $bcd = (bcdedit /enum "{current}" 2>$null) | Out-String
    Add-Verdict -Id "dynamicTick" -Ok ([bool]($bcd -match "disabledynamictick\s+Yes")) -OkText "Dynamic Tick Disabled (prevents clock drift & hitching)" -FailText "Dynamic Tick not disabled - 'disabledynamictick' does not read Yes in the BCD"
    Add-Verdict -Id "platformTick" -Ok ([bool]($bcd -match "useplatformtick\s+Yes")) -OkText "Native Invariant TSC enforced via useplatformtick" -FailText "useplatformtick not set - it does not read Yes in the BCD"
    Add-Verdict -Id "bcdCapsCleared" -Ok (-not ($bcd -match "\buseplatformclock\b" -or $bcd -match "\bnumproc\b" -or $bcd -match "\btruncatememory\b")) -OkText "BCD CPU core limitations & memory caps cleared" -FailText "BCD still carries useplatformclock / numproc / truncatememory"

    # 4. Kernel RAM Pinning
    $kramProps = Get-ItemProperty $mmPath -ErrorAction SilentlyContinue
    Add-Verdict -Id "kernelRamLock" -Ok ($kramProps.DisablePagingExecutive -eq 1 -and $kramProps.LargeSystemCache -eq 0) -OkText "Windows Kernel & Drivers locked in physical RAM (Zero SSD paging hitches)" -FailText "Kernel RAM lock incomplete - DisablePagingExecutive reads '$($kramProps.DisablePagingExecutive)' (want 1), LargeSystemCache reads '$($kramProps.LargeSystemCache)' (want 0)"

    # 5. GPU Interrupt Priority
    if ($gpuDev) {
        $prioVal = (Get-ItemProperty $gpuPrioKey -Name "DevicePriority" -ErrorAction SilentlyContinue).DevicePriority
        Add-Verdict -Id "gpuInterruptPriority" -Ok ($prioVal -eq 1) -OkText "GPU ($($gpuDev.FriendlyName)) Interrupt Priority set to HIGH" -FailText "GPU ($($gpuDev.FriendlyName)) Interrupt Priority not applied - DevicePriority still reads '$prioVal'"
    }

    # 6. Power scheme & USB selective suspend
    if ($prefScheme) {
        $schemeNow = (& powercfg.exe /getactivescheme 2>$null) -join ""
        Add-Verdict -Id "powerPlan" -Ok ($schemeNow -match [regex]::Escape($prefScheme.Guid)) -OkText "Activated power scheme: $($prefScheme.Name) (verified)" -FailText "Power scheme did not switch to $($prefScheme.Name)"
        if ($prefScheme.Name -match "Hybr[ei]d") { $logLines.Add("[WARN] Hybred disables CPU idle states - faster, but higher idle heat and fan noise. Not for a laptop with poor cooling.") }
    } else {
        $logLines.Add("[SKIP] No Hybred / Ultimate / High performance scheme present")
    }
    $usbAc = Get-PowerSettingValue "2a737441-1930-4402-8d77-b2bebba308a3" "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    $usbDc = Get-PowerSettingValue "2a737441-1930-4402-8d77-b2bebba308a3" "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" -Dc
    Add-Verdict -Id "usbSuspend" -Ok ($usbAc -eq 0 -and $usbDc -eq 0) -OkText "USB Selective Suspend disabled (Zero input device wake-up latency)" -FailText "USB Selective Suspend still on - AC reads '$usbAc', DC reads '$usbDc' (want 0 on both)"

    # 7. GameDVR
    $gdvrVal = (Get-ItemProperty "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -ErrorAction SilentlyContinue).GameDVR_Enabled
    $appCapVal = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -ErrorAction SilentlyContinue).AppCaptureEnabled
    Add-Verdict -Id "gameDvr" -Ok ($gdvrVal -eq 0 -and $appCapVal -eq 0) -OkText "Background GameDVR & AppCapture disabled (Freed GPU/CPU overhead)" -FailText "GameDVR not fully disabled - GameDVR_Enabled reads '$gdvrVal' (want 0), AppCaptureEnabled reads '$appCapVal' (want 0)"

    # 8. Game Mode (missing values are Windows' default-on)
    $gbProps = Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\GameBar" -ErrorAction SilentlyContinue
    $gmAuto = if ($null -ne $gbProps -and $null -ne $gbProps.AutoGameModeEnabled) { $gbProps.AutoGameModeEnabled } else { $gbProps.AllowAutoGameMode }
    Add-Verdict -Id "gameMode" -Ok (($null -eq $gmAuto) -or ($gmAuto -eq 1)) -OkText "Windows Game Mode enabled (prioritizes game threads)" -FailText "Game Mode not enabled - AllowAutoGameMode/AutoGameModeEnabled still read '$gmAuto'"

    # 9. Shell responsiveness - three independent values, three verdicts
    $tpVal = (Get-ItemProperty $tpPath -Name "EnableTransparency" -ErrorAction SilentlyContinue).EnableTransparency
    Add-Verdict -Id "transparency" -Ok ($tpVal -eq 0) -OkText "Transparency effects off" -FailText "Transparency still on - EnableTransparency reads '$tpVal' (want 0)"
    $msdVal = (Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -ErrorAction SilentlyContinue).MenuShowDelay
    Add-Verdict -Id "menuDelay" -Ok ($msdVal -eq "0") -OkText "Instant menus (MenuShowDelay = 0)" -FailText "Menu delay not removed - MenuShowDelay reads '$msdVal' (want 0)"
    $mspdVal = (Get-ItemProperty "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -ErrorAction SilentlyContinue).MouseSpeed
    Add-Verdict -Id "mousePrecision" -Ok ($mspdVal -eq "0") -OkText "Raw mouse input (no pointer acceleration)" -FailText "Pointer acceleration not disabled - MouseSpeed reads '$mspdVal' (want 0)"

    # 10. Memory compression & CPU max frequency
    $mmAgent = Get-MMAgent -ErrorAction SilentlyContinue
    $mcVal = if ($null -ne $mmAgent) { $mmAgent.MemoryCompression } else { "unreadable" }
    Add-Verdict -Id "memCompression" -Ok ($null -ne $mmAgent -and $mmAgent.MemoryCompression -eq $false) -OkText "Memory Compression disabled" -FailText "Memory Compression not disabled - MMAgent reads MemoryCompression = '$mcVal'"
    $maxAc = Get-PowerSettingValue "SUB_PROCESSOR" "PROCTHROTTLEMAX"
    $maxDc = Get-PowerSettingValue "SUB_PROCESSOR" "PROCTHROTTLEMAX" -Dc
    Add-Verdict -Id "cpuMaxFreq" -Ok ($maxAc -eq 100 -and $maxDc -eq 100) -OkText "CPU max frequency left at 100% (min floor untouched)" -FailText "CPU max frequency not 100% - AC reads '$maxAc', DC reads '$maxDc' (want 100 on both)"

    # 11. NVIDIA low-latency flag (only checked when the GPU is present)
    if ($nv) {
        $ridVal = (Get-ItemProperty $fts -Name "EnableRID61684" -ErrorAction SilentlyContinue).EnableRID61684
        Add-Verdict -Id "nvidiaRid" -Ok ($ridVal -eq 1) -OkText "NVIDIA ultra-low-latency driver flag set (EnableRID61684)" -FailText "NVIDIA ultra-low-latency driver flag not applied - EnableRID61684 reads '$ridVal' (want 1)"
    }

    $failed = @($checks | Where-Object { -not $_.ok }).Count
    $result = @{
        success = ($failed -eq 0)
        logs = @($logLines)
        checks = @($checks)
    }
    if ($failed -gt 0) {
        if ($DryRun) {
            $result.blocked = $true
            $result.error = "Dry run: $failed of $($checks.Count) section(s) were not applied - the writes were intercepted."
        } else {
            $result.error = "$failed of $($checks.Count) section(s) did not verify - see the log lines above."
        }
    }
    return $result
}

function Optimize-Services {
    $log = @()
    # Spooler and WSearch removed 2026-09-30 20:40 by human decision: disabling
    # them kills printing and file/Start-menu search, which are not bloat.
    $servicesToDisable = @("DiagTrack", "WerSvc", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "CDPSvc", "dmwappushservice", "PcaSvc")
    foreach ($name in $servicesToDisable) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { $log += "[SKIP] Service '$name' is not present on this system."; continue }
        # sc.exe rather than Set-/Stop-Service, for the same reason as
        # Set-ServiceState: the PowerShell cmdlets block until the service reaches
        # the requested state, so one wedged service hangs this single-threaded
        # dispatcher and the whole app stops responding. sc.exe hands the request
        # to the SCM and returns at once.
        & sc.exe config $name start= disabled 2>$null | Out-Null
        & sc.exe stop $name 2>$null | Out-Null
        # Short bounded settle so the read-back below does not catch the service
        # mid-transition and log a spurious failure. Bounded on purpose: a service
        # stuck in StopPending never reaches Stopped, and must not hold the loop.
        $deadline = (Get-Date).AddSeconds(3)
        do {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $svc -or $svc.Status -eq "Stopped") { break }
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $deadline)
        # Read the state back instead of asserting it: $ErrorActionPreference is
        # SilentlyContinue at the top of this file, so a failed Set-/Stop-Service
        # produces no error and would otherwise be logged as success.
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            $log += "[FAIL] Service '$name' disappeared while disabling it."
            continue
        }
        $disabled = ($svc.StartType -eq "Disabled")
        $stopped = ($svc.Status -eq "Stopped")
        if ($disabled -and $stopped) {
            $log += "[OK] Service '$name' stopped and disabled."
        } elseif ($disabled -and $svc.Status -eq "StopPending") {
            $log += "[PARTIAL] Service '$name' disabled but wedged in StopPending - it is not actually stopped. Usually clears on the next restart."
        } elseif ($disabled) {
            $log += "[PARTIAL] Service '$name' disabled but still $($svc.Status)."
        } else {
            $log += "[FAIL] Service '$name' not disabled (StartType=$($svc.StartType), Status=$($svc.Status))."
        }
    }
    $notDone = @($log | Where-Object { $_ -match "^\[(FAIL|PARTIAL)\]" }).Count
    if ($notDone -gt 0) { $log += "[WARN] $notDone of $($servicesToDisable.Count) services could not be fully disabled." }
    return @{ success = $true; logs = $log }
}

function Set-TweakState($id, $enabled, $value) {
    $on = [bool]$enabled
    # Table-driven registry tweaks first - single source of truth with the audit
    $def = $script:RegTweaks | Where-Object { $_.id -eq $id } | Select-Object -First 1
    # Enum entries are a dropdown, not a toggle, so they need a value rather than a
    # boolean. Reject a bare boolean instead of coercing it to 0, which would look
    # identical to "Windows default" and hide a caller bug.
    if ($def -and $def.type -eq "enum") {
        if ($null -eq $value) {
            return @{ success = $false; id = $id; error = "This setting takes a value, not an on/off" }
        }
        $written = Set-RegTweakValue -def $def -value $value
        # Read back instead of trusting the write. "unset" legitimately reads back
        # as $null (both sides are $null then, which compares equal); a value that
        # did not land compares unequal and reports as a failure.
        $actual = Get-RegTweakValue -def $def
        if ("$actual" -eq "$written") { return @{ success = $true; id = $id; value = $actual; reboot = [bool]$def.reboot } }
        $result = @{ success = $false; id = $id; value = $actual; reboot = [bool]$def.reboot; error = "Read back '$actual' after writing '$written'." }
        if ($DryRun) { $result.blocked = $true; $result.error = "Dry run: the write was intercepted, so the setting still reads '$actual'." }
        return $result
    }
    if ($def) {
        Set-RegTweak -def $def -on $on
        # Read back through the same getter the audit uses, so the switch and the
        # dashboard cannot disagree about whether this entry is applied.
        $after = Get-RegTweakState $def
        if ($after -eq [bool]$on) { return @{ success = $true; id = $id; enabled = [bool]$on; reboot = [bool]$def.reboot } }
        $result = @{ success = $false; id = $id; enabled = $after; reboot = [bool]$def.reboot; error = "Read back '$after' after the write (expected '$([bool]$on)')." }
        if ($DryRun) { $result.blocked = $true; $result.error = "Dry run: the write was intercepted, so the setting still reads '$after'." }
        return $result
    }
    switch ($id) {
        "hags" {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value $(if ($on) { 2 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "gameOpt" {
            $dxPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
            if (-not (Test-Path $dxPath)) { New-Item -Path $dxPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $dxPath -Name "AutoOptimizationsEnabled" -Value $(if ($on) { 1 } else { 0 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "dynamicTick" {
            if ($on) { & bcdedit.exe /set disabledynamictick yes 2>$null | Out-Null }
            else { & bcdedit.exe /deletevalue disabledynamictick 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "platformTick" {
            if ($on) { & bcdedit.exe /set useplatformtick yes 2>$null | Out-Null }
            else { & bcdedit.exe /deletevalue useplatformtick 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "kernelRamLock" {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -Value $(if ($on) { 1 } else { 0 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "netThrottle" {
            $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            # This toggle owns NetworkThrottlingIndex and nothing else. It used to write
            # SystemResponsiveness too, and that value has a different owner: the
            # mmcsSystemResponsiveness dropdown. ON wrote 0, which the dropdown also
            # recommends, so the two agreed by luck. OFF wrote 20, which was wrong three
            # ways: Windows ships 10 on x64 so 20 is not a restore - it is a value the user
            # never chose, and a worse one for gaming than doing nothing; 20 is not one of
            # the dropdown's choices, so the dropdown was handed a state it could not
            # represent; and toggling this off silently overwrote the setting the user is
            # most likely to be relying on. Ownership is now enforced instead of agreed on
            # by convention - see the "one value gets one home" note on that catalog entry.
            if ($on) {
                Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value -1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            }
            return Get-TweakWriteResult -id $id -on $on
        }
        "gameDvr" {
            $gcsPath = "HKCU:\System\GameConfigStore"
            if (-not (Test-Path $gcsPath)) { New-Item -Path $gcsPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $gcsPath -Name "GameDVR_Enabled" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            $gdvrPolicy = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
            if (-not (Test-Path $gdvrPolicy)) { New-Item -Path $gdvrPolicy -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $gdvrPolicy -Name "AppCaptureEnabled" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "deliveryOpt" {
            $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
            if ($on) {
                if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force -ErrorAction SilentlyContinue | Out-Null }
                # 99, not 0. This switch and the catalog entry deliveryOptOff both
                # own DODownloadMode; 0 here and 99 there meant whichever you touched
                # last silently flipped the other one off.
                Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 99 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $doPath -Name "DODownloadMode" -ErrorAction SilentlyContinue
            }
            return Get-TweakWriteResult -id $id -on $on
        }
        "tcpNoDelay" {
            $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
            if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($adapter -and $adapter.InterfaceGuid) {
                $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
                if ($on) {
                    New-ItemProperty -Path $tcpReg -Name "TCPNoDelay" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                    New-ItemProperty -Path $tcpReg -Name "TcpDelAckTicks" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                } else {
                    Remove-ItemProperty -Path $tcpReg -Name "TCPNoDelay" -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $tcpReg -Name "TcpDelAckTicks" -ErrorAction SilentlyContinue
                }
            }
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
    "tcpAckFreq" {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
        if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not ($adapter -and $adapter.InterfaceGuid)) {
            return @{ success = $false; id = $id; error = "No adapter GUID - TcpAckFrequency not applied" }
        }
        $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
        # The if ($on) branch here was EMPTY. Turning this tweak on wrote nothing,
        # then returned success = $true and enabled = $on - so the UI showed the
        # switch on plus a success toast until the next /api/network poll read the
        # registry, found no TcpAckFrequency, and flipped it straight back off.
        if ($on) {
            New-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        } else {
            Remove-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
        }
        # Same read-back, now through the shared state function so this and the
        # audit agree on what "already off" looks like.
        return Get-TweakWriteResult -id $id -on $on -Reboot
    }
        "rss" {
            # ON  = enable RSS (improves multi-core NIC throughput)
            # OFF = disable RSS (restores the toggle-able state; Windows default is enabled,
            #       but if the user explicitly turns this off they want it off)
            if ($on) { & netsh.exe int tcp set global rss=enabled 2>$null | Out-Null }
            else { & netsh.exe int tcp set global rss=disabled 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on
        }
    "powerPlan" {
        # Hybred preferred; falls back to Ultimate, then High performance. See
        # Get-PreferredPowerScheme for why and for the laptop caveat.
        if ($on) {
            $scheme = Get-PreferredPowerScheme
            if ($scheme) {
                & powercfg.exe /setactive $scheme.Guid 2>$null | Out-Null
                $after = (& powercfg.exe /getactivescheme 2>$null) -join ""
                if ($after -notmatch [regex]::Escape($scheme.Guid)) {
                    return @{ success = $false; id = $id; error = "Power scheme did not switch to $($scheme.Name)" }
                }
                return @{ success = $true; id = $id; enabled = $true; scheme = $scheme.Name }
            }
            return @{ success = $false; id = $id; error = "No Hybred / Ultimate / High performance scheme present" }
        } else {
            & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>$null | Out-Null
            return Get-TweakWriteResult -id $id -on $false
        }
    }
        "gameMode" {
            $gbPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
            if (-not (Test-Path $gbPath)) { New-Item -Path $gbPath -Force -ErrorAction SilentlyContinue | Out-Null }
            $val = if ($on) { 1 } else { 0 }
            Set-ItemProperty -Path $gbPath -Name "AllowAutoGameMode" -Value $val -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $gbPath -Name "AutoGameModeEnabled" -Value $val -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "transparency" {
            $tpPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            if (-not (Test-Path $tpPath)) { New-Item -Path $tpPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $tpPath -Name "EnableTransparency" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "menuDelay" {
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value $(if ($on) { "0" } else { "400" }) -Type String -Force -ErrorAction SilentlyContinue | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "mousePrecision" {
            $mPath = "HKCU:\Control Panel\Mouse"
            if ($on) {
                Set-ItemProperty -Path $mPath -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mPath -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mPath -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Set-ItemProperty -Path $mPath -Name "MouseSpeed" -Value "1" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mPath -Name "MouseThreshold1" -Value "6" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mPath -Name "MouseThreshold2" -Value "10" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
            }
            return Get-TweakWriteResult -id $id -on $on
        }
        "memCompression" {
            if ($on) { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null }
            else { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null }
            # Both MMAgent calls fail silently here, so read back through the
            # shared state function - $on means "tweak on" = compression OFF.
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "cpuBoost" {
            if ($on) {
                & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>$null | Out-Null
                & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>$null | Out-Null
                & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
                & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
            } else {
                & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 2>$null | Out-Null
                & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 2>$null | Out-Null
                & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
                & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
            }
            & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
            return Get-TweakWriteResult -id $id -on $on
        }
        "nvidiaRid" {
            $nv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" }
            if (-not $nv) { return @{ success = $false; id = $id; error = "No NVIDIA GPU detected" } }
            $fts = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
            if ($on) {
                if (-not (Test-Path $fts)) { New-Item -Path $fts -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $fts -Name "EnableRID61684" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $fts -Name "EnableRID61684" -ErrorAction SilentlyContinue
            }
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "qosLimit" {
            $qosPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
            if ($on) {
                if (-not (Test-Path $qosPath)) { New-Item -Path $qosPath -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue
            }
            return Get-TweakWriteResult -id $id -on $on
        }
        "tcpPorts" {
            $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            if ($on) {
                Set-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $tcpParams -Name "MaxUserPort" -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -ErrorAction SilentlyContinue
            }
            return Get-TweakWriteResult -id $id -on $on -Reboot
        }
        "hibernate" {
            if ($on) { & powercfg.exe /hibernate off 2>$null | Out-Null }
            else { & powercfg.exe /hibernate on 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on
        }
        "netbios" {
            # Target the adapter the audit reads and the dashboard shows. This used
            # to take the first IPEnabled adapter WMI happened to list, so on a
            # machine with a VPN or a second NIC the write landed on an adapter the
            # switch was not describing.
            $primary = Get-PrimaryAdapter
            $cfg = $null
            if ($primary) {
                $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($primary.InterfaceIndex)" -ErrorAction SilentlyContinue
            }
            if (-not $cfg) { return @{ success = $false; id = $id; error = "No active network adapter found" } }
            Invoke-CimMethod -InputObject $cfg -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = $(if ($on) { 2 } else { 0 }) } -ErrorAction SilentlyContinue | Out-Null
            $result = Get-TweakWriteResult -id $id -on $on -Reboot
            if ($result.success) { $result.adapter = $primary.Name }
            return $result
        }
        "teredo" {
            if ($on) { & netsh.exe interface teredo set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface teredo set state default 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on
        }
        "isatap" {
            if ($on) { & netsh.exe interface isatap set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface isatap set state default 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on
        }
        "sixtofour" {
            if ($on) { & netsh.exe interface 6to4 set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface 6to4 set state default 2>$null | Out-Null }
            return Get-TweakWriteResult -id $id -on $on
        }
        default {
            return @{ success = $false; error = "Unknown tweak id: $id" }
        }
    }
}

function Set-ServiceState($name, $optimize) {
    $allowed = @("DiagTrack", "WerSvc", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "WSearch", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "Spooler", "CDPSvc", "dmwappushservice", "PcaSvc")
    if ($allowed -notcontains $name) {
        return @{ success = $false; error = "Service not manageable: $name" }
    }
    # Each service restores to its true Windows default, not a blanket Automatic.
    $defaults = @{
        "DiagTrack" = "auto"; "WerSvc" = "demand";
        "lfsvc" = "demand"; "TrkWks" = "auto"; "RemoteRegistry" = "disabled";
        "wisvc" = "demand"; "MapsBroker" = "auto"; "WSearch" = "auto";
        "XblGameSave" = "demand"; "XboxGipSvc" = "demand"; "XboxNetApiSvc" = "demand"; "Spooler" = "auto";
        "CDPSvc" = "demand"; "dmwappushservice" = "demand"; "PcaSvc" = "demand"
    }
    $scTarget = if ($defaults.ContainsKey($name)) { $defaults[$name] } else { "demand" }
    # sc.exe spells these differently from the PowerShell enum, so keep both forms:
    # $scTarget is what we ask sc.exe for, $wantStart is what Get-Service will report.
    $wantStart = switch ($scTarget) { "auto" { "Automatic" } "demand" { "Manual" } default { $scTarget } }
    if ([bool]$optimize) { $wantStart = "Disabled"; $scTarget = "disabled" }

    # Set-Service / Stop-Service / Start-Service BLOCK until the service actually
    # reaches the requested state. On a service that is slow or wedged that call
    # never returns, and because this backend dispatches HTTP on a single thread,
    # one stuck service took down /api/status, /api/services and every other
    # route - the whole app looked dead. sc.exe config/stop/start hand the request
    # to the SCM and return immediately, so nothing here can block the listener.
    & sc.exe config $name start= $scTarget 2>$null | Out-Null
    if ([bool]$optimize) { & sc.exe stop $name 2>$null | Out-Null }
    elseif ($scTarget -ne "disabled") { & sc.exe start $name 2>$null | Out-Null }
    # Short bounded settle so the read-back below catches the SCM update without
    # ever holding the dispatcher. sc.exe is already non-blocking, so this is just
    # to let the change land before reporting.
    Start-Sleep -Milliseconds 400
    # Read back rather than asserting. $ErrorActionPreference is SilentlyContinue at
    # the top of this file, so a failed Set-/Stop-Service is silent - and the previous
    # unconditional `success = $true` reported every outcome as a win, including the
    # service never being found. Optimize-Services already reads back; this is the
    # second Stop-Service call site catching up.
    $after = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $after) {
        return @{ success = $false; error = "Service '$name' not found after change."; name = $name }
    }
    # Verify the change actually landed instead of just asserting success. The old
    # check only proved the service still EXISTS, so a silent failure - most often
    # sc.exe being denied because the process is not elevated - was reported to the
    # UI as a completed change. Start type is the value this function sets, so
    # that is what gets compared.
    if ("$($after.StartType)" -ne $wantStart) {
        $result = @{
            success = $false
            name = $name
            error = "Start type is '$($after.StartType)', expected '$wantStart'. The Service Control Manager refused the change - this normally means the app is not running as Administrator."
        }
        if ($DryRun) {
            $result.blocked = $true
            $result.error = "Dry run: sc.exe was intercepted, so the start type is still '$($after.StartType)' (expected '$wantStart')."
        }
        return $result
    }
    return @{ success = $true; name = $name; optimized = [bool]$optimize; status = "$($after.Status)"; startType = "$($after.StartType)" }
}

function Restore-Defaults {
    $log = @()
    $adapter = Get-PrimaryAdapter
    $adapterName = if ($adapter) { $adapter.Name } else { $null }

    if ($adapterName) {
        & netsh.exe interface ipv4 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
        & netsh.exe interface ipv6 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
        $log += "[RESTORE] MTU restored to 1500 default."

        Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses -ErrorAction SilentlyContinue
        Clear-DnsClientCache -ErrorAction SilentlyContinue | Out-Null
        $log += "[RESTORE] DNS restored to Automatic (DHCP)."
    } else {
        # Pointing netsh at an interface name we invented ("Ethernet") and then logging
        # "[RESTORE] MTU restored" was two lies at once: nothing was restored, and the
        # log claimed it was.
        $log += "[SKIP] No network adapter found - MTU and DNS were left untouched."
    }

    & netsh.exe int tcp reset 2>$null | Out-Null
    $log += "[RESTORE] Windows TCP stack reset to default."

    & bcdedit.exe /deletevalue disabledynamictick 2>$null | Out-Null
    & bcdedit.exe /deletevalue useplatformtick 2>$null | Out-Null
    $log += "[RESTORE] BCD dynamic ticks & platform clock reset."

    $mmPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $mmPath -Name "DisablePagingExecutive" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[RESTORE] DisablePagingExecutive reset to 0."

    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    Remove-ItemProperty -Path $doPath -Name "DODownloadMode" -ErrorAction SilentlyContinue
    $log += "[RESTORE] Delivery Optimization download mode reset."

    & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>$null | Out-Null
    $log += "[RESTORE] Power plan reset to Balanced."

    Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "AllowAutoGameMode" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "AutoGameModeEnabled" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "400" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "1" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "6" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "10" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[RESTORE] Game Mode, transparency, menu delay and pointer acceleration reset."

    Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS" -Name "EnableRID61684" -ErrorAction SilentlyContinue
    $log += "[RESTORE] Memory Compression re-enabled, CPU throttle floor back to 5%, NVIDIA flag cleared."

    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched" -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "MaxUserPort" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -ErrorAction SilentlyContinue
    $log += "[RESTORE] QoS limit and TCP port policy reset."

    # The MM profile holds two values and they have different owners. SystemResponsiveness
    # is restored through the dropdown branch below (it deletes the value), but
    # NetworkThrottlingIndex is written by the netThrottle toggle and nothing restored it,
    # so "restore Windows defaults" used to leave network throttling disabled forever with
    # no way back except that toggle. 10 is the documented Windows default.
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[RESTORE] Network throttling index back to the Windows default (10)."

    # Dropdowns cannot be reset through the boolean path - they hold a value, not an
    # on/off - so they are restored to the Windows default here instead: delete the
    # value when the entry offers the explicit "unset" choice, otherwise write the
    # stock value. sysmainMode is the one dropdown with no "unset" option, and
    # writing its defaultValue (Start = 2, Automatic) is safe. Deleting a service's
    # Start value instead would leave the service with no start type at all.
    foreach ($def in $script:RegTweaks) {
        if ($def.type -eq 'enum') {
            $hasUnset = @($def.options | Where-Object { "$($_.v)" -eq 'unset' }).Count -gt 0
            if ($hasUnset) { Set-RegTweakValue -def $def -value 'unset' | Out-Null }
            else { Set-RegTweakValue -def $def -value $def.defaultValue | Out-Null }
            continue
        }
        # A payload pair's Windows default is not necessarily "off": windowed-game
        # optimizations ship ON, so restoring must write defaultOn - writing 0
        # would leave the machine changed after a "restore everything" call.
        if ($def.type -eq 'merge') {
            Set-RegTweak -def $def -on ([bool]$def.defaultOn)
            continue
        }
        Set-RegTweak -def $def -on $false
    }
    $log += "[RESTORE] Advanced tweak catalog ($($script:RegTweaks.Count) tweaks, dropdowns included) reset to Windows defaults."

    & powercfg.exe /hibernate on 2>$null | Out-Null
    & netsh.exe interface teredo set state default 2>$null | Out-Null
    & netsh.exe interface isatap set state default 2>$null | Out-Null
    & netsh.exe interface 6to4 set state default 2>$null | Out-Null
    $log += "[RESTORE] Hibernation and IPv6 transition tunnels reset."

    return @{ success = $true; logs = $log }
}

function Get-BloatTasks {
    $taskDefs = @(
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator"; Display = "CEIP Data Consolidator"; Impact = "High" },
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip"; Display = "USB Telemetry Collector"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser"; Display = "Compatibility Telemetry (legacy)"; Impact = "High" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser Exp"; Display = "Compatibility Telemetry"; Impact = "High" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "StartupAppTask"; Display = "Startup App Telemetry"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\DiskDiagnostic\"; Name = "Microsoft-Windows-DiskDiagnosticDataCollector"; Display = "Disk Diagnostic Collector"; Impact = "Low" },
        @{ Path = "\Microsoft\Windows\Maps\"; Name = "MapsUpdateTask"; Display = "Maps Auto-Updater"; Impact = "Low" },
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClient"; Display = "Feedback Upload Client"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClientOnScenarioDownload"; Display = "Feedback Scenario Uploader"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\DiskFootprint\"; Name = "Diagnostics"; Display = "Disk Footprint Telemetry"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\Power Efficiency Diagnostics\"; Name = "AnalyzeSystem"; Display = "Power Efficiency Analyzer"; Impact = "Low" },
        @{ Path = "\Microsoft\Windows\Windows Error Reporting\"; Name = "QueueReporting"; Display = "Error Report Uploader"; Impact = "Medium" },
        @{ Path = "\Microsoft\Windows\Defrag\"; Name = "ScheduledDefrag"; Display = "Scheduled Defragmentation"; Impact = "Low" }
    )

    # Perf: 12 individual Get-ScheduledTask lookups cost ~5.4 s (each is a
    # separate CIM round-trip to the scheduler). One enumeration indexed by
    # "Path+Name" returns byte-identical rows in ~0.6 s.
    $index = @{}
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $index["$($t.TaskPath)$($t.TaskName)"] = $t.State.ToString()
    }

    $list = @()
    foreach ($t in $taskDefs) {
        $full = "$($t.Path)$($t.Name)"
        $state = $null
        if ($index.ContainsKey($full)) { $state = $index[$full] }
        if ($state) {
            $list += @{
                path = $full
                displayName = $t.Display
                state = $state
                impact = $t.Impact
                isOptimized = ($state -eq "Disabled")
            }
        } else {
            $list += @{
                path = $full
                displayName = $t.Display
                state = "NotFound"
                impact = $t.Impact
                isOptimized = $true
            }
        }
    }
    return $list
}

function Set-TaskState($path, $disabled) {
    $sep = $path.LastIndexOf("\")
    $taskPath = $path.Substring(0, $sep + 1)
    $taskName = $path.Substring($sep + 1)
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { return @{ success = $false; error = "Task not found: $path" } }
    if ([bool]$disabled) {
        Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    } else {
        Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
    }
    return @{ success = $true; path = $path; optimized = [bool]$disabled }
}

function Create-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "Windows Tweaks Safety Point" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
        return @{ success = $true; message = "System Restore Point created successfully." }
    } catch {
        return @{ success = $false; message = $_.Exception.Message }
    }
}

function Get-StartupApps {
    $apps = [System.Collections.Generic.List[PSObject]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1. HKCU Run
    $hkcuRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $hkcuApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    if (Test-Path $hkcuRun) {
        $props = Get-ItemProperty -Path $hkcuRun -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notin @("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider") -and -not [string]::IsNullOrWhiteSpace($p.Value)) {
                    $seen.Add("HKCU:" + $p.Name) | Out-Null
                    $isEnabled = $true
                    $appr = (Get-ItemProperty -Path $hkcuApproved -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                    if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                        $isEnabled = $false
                    }
                    $apps.Add([PSCustomObject]@{
                        name = $p.Name
                        command = [string]$p.Value
                        location = "HKCU: Run"
                        scope = "User"
                        enabled = $isEnabled
                    })
                }
            }
        }
    }

    # 2. HKLM Run
    $hklmRun = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    $hklmApproved = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    if (Test-Path $hklmRun) {
        $props = Get-ItemProperty -Path $hklmRun -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notin @("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider") -and -not [string]::IsNullOrWhiteSpace($p.Value)) {
                    $seen.Add("HKLM:" + $p.Name) | Out-Null
                    $isEnabled = $true
                    $appr = (Get-ItemProperty -Path $hklmApproved -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                    if (-not $appr) {
                        $appr = (Get-ItemProperty -Path $hkcuApproved -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                    }
                    if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                        $isEnabled = $false
                    }
                    $apps.Add([PSCustomObject]@{
                        name = $p.Name
                        command = [string]$p.Value
                        location = "HKLM: Run"
                        scope = "Machine"
                        enabled = $isEnabled
                    })
                }
            }
        }
    }

    # 3. HKLM WOW6432Node Run
    $wowRun = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $wowRun) {
        $props = Get-ItemProperty -Path $wowRun -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notin @("PSPath","PSParentPath","PSChildName","PSDrive","PSProvider") -and -not [string]::IsNullOrWhiteSpace($p.Value)) {
                    if (-not $seen.Contains("HKLM:" + $p.Name)) {
                        $seen.Add("HKLM:" + $p.Name) | Out-Null
                        $isEnabled = $true
                        $appr = (Get-ItemProperty -Path $hklmApproved -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                        if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                            $isEnabled = $false
                        }
                        $apps.Add([PSCustomObject]@{
                            name = $p.Name
                            command = [string]$p.Value
                            location = "HKLM: WOW64"
                            scope = "Machine"
                            enabled = $isEnabled
                        })
                    }
                }
            }
        }
    }

    # 4. User Startup Folder
    $userStartup = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    $userFolderApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    if (Test-Path $userStartup) {
        Get-ChildItem -Path $userStartup -File -ErrorAction SilentlyContinue | ForEach-Object {
            $baseName = $_.BaseName
            if (-not $seen.Contains("Folder:" + $baseName)) {
                $seen.Add("Folder:" + $baseName) | Out-Null
                $isEnabled = $true
                $appr = (Get-ItemProperty -Path $userFolderApproved -Name $_.Name -ErrorAction SilentlyContinue).$($_.Name)
                if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                    $isEnabled = $false
                }
                $apps.Add([PSCustomObject]@{
                    name = $baseName
                    command = $_.FullName
                    location = "Startup Folder"
                    scope = "UserFolder"
                    enabled = $isEnabled
                })
            }
        }
    }

    # 5. Common Startup Folder
    $allStartup = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
    $allFolderApproved = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    if (Test-Path $allStartup) {
        Get-ChildItem -Path $allStartup -File -ErrorAction SilentlyContinue | ForEach-Object {
            $baseName = $_.BaseName
            if (-not $seen.Contains("Folder:" + $baseName)) {
                $seen.Add("Folder:" + $baseName) | Out-Null
                $isEnabled = $true
                $appr = (Get-ItemProperty -Path $allFolderApproved -Name $_.Name -ErrorAction SilentlyContinue).$($_.Name)
                if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                    $isEnabled = $false
                }
                $apps.Add([PSCustomObject]@{
                    name = $baseName
                    command = $_.FullName
                    location = "Startup Folder (All Users)"
                    scope = "SystemFolder"
                    enabled = $isEnabled
                })
            }
        }
    }

    # 6. Win32_StartupCommand fallback
    $wmiItems = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
    foreach ($w in $wmiItems) {
        if (-not $seen.Contains("HKCU:" + $w.Name) -and -not $seen.Contains("HKLM:" + $w.Name) -and -not $seen.Contains("Folder:" + $w.Name)) {
            $seen.Add("WMI:" + $w.Name) | Out-Null
            $isEnabled = $true
            $appr = (Get-ItemProperty -Path $hkcuApproved -Name $w.Name -ErrorAction SilentlyContinue).$($w.Name)
            if ($appr -and $appr.Length -gt 0 -and ($appr[0] -band 1) -eq 1) {
                $isEnabled = $false
            }
            $apps.Add([PSCustomObject]@{
                name = $w.Name
                command = $w.Command
                location = if ($w.Location) { $w.Location } else { "Startup" }
                scope = if ($w.User -match "\\") { "User" } else { "Machine" }
                enabled = $isEnabled
            })
        }
    }

    # Enrich with publisher and impact
    $result = @()
    foreach ($item in $apps) {
        $cmd = $item.command
        $exe = ""
        if ($cmd -match '^"([^"]+)"') { $exe = $matches[1] }
        elseif ($cmd -match '^([^\s,]+)') { $exe = $matches[1] }

        $publisher = "Unknown"
        if ($exe -and (Test-Path $exe -PathType Leaf)) {
            try {
                $vi = (Get-Item $exe -ErrorAction SilentlyContinue).VersionInfo
                if ($vi.CompanyName) { $publisher = $vi.CompanyName }
                elseif ($vi.ProductName) { $publisher = $vi.ProductName }
            } catch {}
        }

        $n = ($item.name + " " + $publisher).ToLower()
        $impact = "Medium"
        if ($n -match "discord|steam|spotify|epic|medal|razer|corsair|geforce|nvidia|amd|electron|launcher") {
            $impact = "High"
        } elseif ($n -match "realtek|audio|synaptics|intel|security|defender|touchpad") {
            $impact = "Low"
        } elseif ($n -match "update|helper|service|onedrive|edge|anydesk") {
            $impact = "Medium"
        }

        $result += @{
            name = $item.name
            command = $item.command
            location = $item.location
            scope = $item.scope
            publisher = $publisher
            impact = $impact
            enabled = [bool]$item.enabled
        }
    }

    return $result
}

function Set-StartupAppState($name, $scope, $enabled) {
    if (-not $name) { return @{ success = $false; error = "Missing app name" } }

    $byteVal = if ($enabled) { 0x02 } else { 0x03 }
    $bytes = [byte[]]@($byteVal, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

    $targetKeys = @()
    if ($scope -eq "UserFolder") {
        $targetKeys += "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    } elseif ($scope -eq "SystemFolder") {
        $targetKeys += "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
        $targetKeys += "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
    } elseif ($scope -eq "Machine") {
        $targetKeys += "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        $targetKeys += "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    } else {
        $targetKeys += "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        $targetKeys += "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    }

    $applied = $false
    foreach ($k in $targetKeys) {
        try {
            if (-not (Test-Path $k)) {
                New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
            }
            Set-ItemProperty -Path $k -Name $name -Value $bytes -Type Binary -ErrorAction SilentlyContinue
            $applied = $true
        } catch {}
    }

    return @{ success = $applied; name = $name; enabled = [bool]$enabled }
}

# -----------------------------------------------------------------------------
# STARTUP WARM-UP
# The first Get-SystemAudit costs ~2.2 s (static hardware pull + first CPU
# sample) and the first Get-NetworkAudit ~1.0 s (adapter provider init).
# app.js probeBase() aborts its /api/status probe after 1500 ms, so a cold
# first call can make API detection fail outright. Pay both costs here, once,
# while the splash screen is still up and before the listener accepts traffic.
# -----------------------------------------------------------------------------
Write-Host " [warmup] caching hardware identity & priming counters..." -ForegroundColor DarkGray
$warmupSw = [Diagnostics.Stopwatch]::StartNew()
try {
    [void](Get-StaticHw)
    [void](Get-CpuLoadSample)
    [void](Get-RamSample)
    [void](Get-NetAdapter -ErrorAction SilentlyContinue)
} catch {}
$warmupSw.Stop()
Write-Host " [warmup] done in $($warmupSw.ElapsedMilliseconds) ms" -ForegroundColor DarkGray

# -----------------------------------------------------------------------------
# HTTP SERVER DISPATCHER
# -----------------------------------------------------------------------------

$listener = New-Object System.Net.HttpListener
$listener.IgnoreWriteExceptions = $true
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    Write-Warning "[Tweaks] Port $Port busy, trying next available..."
    $Port = 48922
    $listener = New-Object System.Net.HttpListener
    $listener.IgnoreWriteExceptions = $true
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "   WINDOWS TWEAKS - HIGH PERFORMANCE LATENCY ENGINE        " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Server running at: http://127.0.0.1:$Port/" -ForegroundColor Green
Write-Host " Admin Elevated: $script:IsAdmin" -ForegroundColor Yellow

# -----------------------------------------------------------------------------
# PER-PROCESS API TOKEN
# -----------------------------------------------------------------------------
# Printed on a marker line so main.js can lift it off stdout and hand it to the
# renderer. Cryptographically random (not Get-Random, which is not a CSPRNG).
# Regenerated every launch, so it cannot be replayed across restarts.
$tokenBytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
$script:ApiToken = [Convert]::ToBase64String($tokenBytes)
Write-Host "__WT_TOKEN__$script:ApiToken"

# Launch Brave in Native App Mode if available, or default browser
if (-not $NoBrowser) {
    $bravePath = "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
    $edgePath = "C:\Program Files (x86)\Microsoft\EdgeCore\153.0.4234.48\msedge.exe"
    $url = "http://127.0.0.1:$Port/"

    if (Test-Path $bravePath) {
        Write-Host " Launching via Brave App Mode..." -ForegroundColor Cyan
        Start-Process $bravePath -ArgumentList "--app=$url", "--window-size=1360,880", "--user-data-dir=`"$env:TEMP\WindowsTweaksBrowser`""
    } elseif (Test-Path $edgePath) {
        Start-Process $edgePath -ArgumentList "--app=$url", "--window-size=1360,880"
    } else {
        Start-Process $url
    }
}

# MIME Types Dictionary
$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
}

# Main Request Loop
while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        # ---------------------------------------------------------------------------
        # AUTHENTICATION GATE
        # ---------------------------------------------------------------------------
        # This used to answer every request with "Access-Control-Allow-Origin: *".
        # The listener binds 127.0.0.1, but CORS is enforced by the BROWSER, not by
        # the socket: any web page the user visits could POST to this port, flip
        # registry values and disable services, then read the reply back. Verified
        # live - a request with Origin: https://evil.example.com changed TaskbarSi
        # and returned {"success":true}.
        #
        # Two layers now:
        #   1. Origin allowlist. The renderer is a file:// page, so it legitimately
        #      sends "Origin: null"; a real hostile page sends its own origin. Also
        #      accepted: loopback, for manual curl testing.
        #   2. A per-process random token in X-WT-Token. The browser cannot make
        #      another origin send a header the attacker chooses, and the token only
        #      exists in this process's stdout and in the Electron renderer, so a web
        #      page cannot learn it.
        $origin = $request.Headers["Origin"]
        $originOk = (
            [string]::IsNullOrWhiteSpace($origin) -or
            $origin -eq "null" -or
            $origin -match '^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$'
        )

        if (-not $originOk) {
            $response.StatusCode = 403
            $buf = [Text.Encoding]::UTF8.GetBytes('{"success":false,"error":"Origin not allowed."}')
            $response.ContentType = "application/json"
            $response.ContentLength64 = $buf.Length
            $response.OutputStream.Write($buf, 0, $buf.Length)
            $response.Close()
            continue
        }

        if ($request.HttpMethod -eq "OPTIONS") {
            # Preflight carries no custom headers, so it cannot present the token.
            # The origin allowlist above is the only check available here; the token
            # is enforced on the real request that follows.
            $response.AddHeader("Access-Control-Allow-Origin", $(if ($origin -eq "null") { "null" } else { $origin }))
            $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $response.AddHeader("Access-Control-Allow-Headers", "Content-Type, X-WT-Token")
            $response.AddHeader("Access-Control-Max-Age", "600")
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        # Only now, once the caller is authenticated, permit the read.
        $response.AddHeader("Access-Control-Allow-Origin", $(if ($origin -eq "null") { "null" } else { $origin }))
        $response.AddHeader("Vary", "Origin")

        $rawUrl = $request.RawUrl.Split('?')[0]

        # Read JSON body for POST
        $body = ""
        if ($request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
        }

        # API ROUTING — token is required only for /api/ endpoints, not static files
        if ($rawUrl.StartsWith("/api/")) {
            # Authenticate the caller before serving any API response
            $supplied = $request.Headers["X-WT-Token"]
            if (-not $script:ApiToken -or $supplied -ne $script:ApiToken) {
                $response.StatusCode = 403
                $buf = [Text.Encoding]::UTF8.GetBytes('{"success":false,"error":"Missing or invalid API token. This endpoint only answers the desktop app."}')
                $response.ContentType = "application/json"
                $response.ContentLength64 = $buf.Length
                $response.OutputStream.Write($buf, 0, $buf.Length)
                $response.Close()
                continue
            }

            $jsonOutput = $null

            # Any POST can move the machine, so the cached static half of the
            # audit is stale from here on and the next /api/status re-reads it.
            # The 2 s poll is a GET and keeps being answered from the cache.
            if ($request.HttpMethod -eq "POST") { Reset-AuditCache }

            switch ($rawUrl) {
                "/api/status" {
                    $jsonOutput = Get-SystemAudit
                }
                "/api/network" {
                    $jsonOutput = Get-NetworkAudit
                }
                "/api/ping" {
                    $target = "1.1.1.1"
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.target) { $target = $parsed.target }
                    }
                    $jsonOutput = Run-PingTest -hostTarget $target
                }
                "/api/dns-benchmark" {
                    $jsonOutput = Run-DnsBenchmark
                }
                "/api/apply-dns" {
                    $targetDns = @("1.0.0.1", "1.1.1.1")
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.dns -and $parsed.dns.Count -gt 0) { $targetDns = $parsed.dns }
                    }
                    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
                    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
                    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $targetDns -ErrorAction SilentlyContinue
                    Clear-DnsClientCache -ErrorAction SilentlyContinue | Out-Null
                    $jsonOutput = @{ success = $true; dns = $targetDns }
                }
                "/api/mtu-test" {
                    $jsonOutput = Run-MtuTest
                }
                "/api/apply-mtu" {
                    $val = 1280
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.mtu) { $val = [int]$parsed.mtu }
                    }
                    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
                    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
                    & netsh.exe interface ipv4 set subinterface $adapter.Name mtu=$val store=persistent 2>$null | Out-Null
                    & netsh.exe interface ipv6 set subinterface $adapter.Name mtu=$val store=persistent 2>$null | Out-Null
                    # This used to return success = $true unconditionally, never reading the
                    # value back. netsh does not always land exactly on the requested MTU - it
                    # was asked for 1500 on this machine and the adapter reported 1497 - so a
                    # hardcoded true told the UI the change worked when the resulting number
                    # was not the one requested. Report what is actually there instead.
                    $mtuActual = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
                    $mtuOk = ($null -ne $mtuActual -and [Math]::Abs($mtuActual - $val) -le 8)
                    $jsonOutput = @{ success = $mtuOk; mtu = $mtuActual; requested = $val }
                }
                "/api/network/bindings" {
                    if ($body) {
                        $p = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $coreOnly = $true
                        if ($null -ne $p.coreOnly) { $coreOnly = [bool]$p.coreOnly }
                        $jsonOutput = Set-NetworkComponents -coreOnly $coreOnly
                    } else {
                        $jsonOutput = @{ success = $true; bindings = @(Get-NetworkBindingState) }
                    }
                }
                "/api/tweak/network" {
                    $jsonOutput = Apply-NetworkTweaks
                }
                "/api/tweak/system" {
                    $jsonOutput = Apply-SystemTweaks
                }
                "/api/tweak/all" {
                    $net = Apply-NetworkTweaks
                    $sys = Apply-SystemTweaks
                    $srv = Optimize-Services
                    $allLogs = $net.logs + $sys.logs + $srv.logs
                    # success now reflects the sections that verified. /api/tweak/system
                    # is the sub-apply with a read-back pass today; a bulk run that
                    # could not verify must not toast as a success either way.
                    $jsonOutput = @{ success = [bool]($net.success -and $sys.success -and $srv.success); logs = $allLogs; requiresReboot = $true }
                }
                "/api/services" {
                    $jsonOutput = Get-BloatServices
                }
                "/api/services/optimize" {
                    $jsonOutput = Optimize-Services
                }
                "/api/tweak/set" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.id) { $jsonOutput = Set-TweakState -id $parsed.id -enabled ([bool]$parsed.enabled) -value $parsed.value }
                    }
                }
                "/api/services/set" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.name) { $jsonOutput = Set-ServiceState -name $parsed.name -optimize ([bool]$parsed.optimized) }
                    }
                }
                # Bulk action for one group. Deliberately iterates only services
                # that are individually curated AND sit in a group marked
                # Modifiable, so this cannot be pointed at Core / Security /
                # Network even by a crafted request. Rejects unknown groups.
                "/api/services/group" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $gid = [string]$parsed.group
                        $gdef = $script:ServiceGroups | Where-Object { $_.Id -eq $gid } | Select-Object -First 1
                        if (-not $gdef) {
                            $jsonOutput = @{ success = $false; error = "Unknown group '$gid'" }
                        } elseif (-not $gdef.Modifiable) {
                            $jsonOutput = @{ success = $false; error = "Group '$gid' is read-only and has no bulk action" }
                        } else {
                            # The client sends "optimize"; this used to read
                            # $parsed.optimized, which is always $null, and
                            # [bool]$null is $false. So every "Disable all" in the
                            # UI silently performed a RESTORE instead - the exact
                            # opposite of the button, while still reporting
                            # success and "N services disabled". Accept either
                            # spelling, and never let a missing value default to
                            # false and quietly invert the action.
                            $wantDisable = $null
                            if ($parsed.PSObject.Properties.Name -contains "optimize") { $wantDisable = [bool]$parsed.optimize }
                            elseif ($parsed.PSObject.Properties.Name -contains "optimized") { $wantDisable = [bool]$parsed.optimized }
                            if ($null -eq $wantDisable) {
                                $jsonOutput = @{ success = $false; error = "Missing 'optimize' flag - refusing to guess, because guessing false means RESTORE." }
                            } else {
                                $members = @(Get-BloatServices | Where-Object { $_.group -eq $gid -and $_.curated })
                                $done = @(); $failed = @()
                                foreach ($m in $members) {
                                    $r = Set-ServiceState -name $m.name -optimize $wantDisable
                                    if ($r.success) { $done += $m.name } else { $failed += "$($m.name): $($r.error)" }
                                }
                                $jsonOutput = @{
                                    success = ($failed.Count -eq 0)
                                    group = $gid
                                    optimized = $wantDisable
                                    changed = $done.Count
                                    failed = $failed
                                    names = $done
                                }
                            }
                        }
                    }
                }
                "/api/tasks" {
                    $jsonOutput = Get-BloatTasks
                }
                "/api/tasks/set" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.path) { $jsonOutput = Set-TaskState -path $parsed.path -disabled ([bool]$parsed.disabled) }
                    }
                }
                "/api/startup" {
                    $jsonOutput = Get-StartupApps
                }
                "/api/startup/set" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.name) {
                            $jsonOutput = Set-StartupAppState -name $parsed.name -scope $parsed.scope -enabled ([bool]$parsed.enabled)
                        }
                    }
                }
                "/api/tweak/catalog" {
                    $jsonOutput = @($script:RegTweaks | ForEach-Object {
                        @{ id = $_.id
                           category = $_.category
                           label = $_.label
                           desc = $_.desc
                           reboot = [bool]$_.reboot
                           advanced = [bool]$_.advanced
                           perf = [bool]$_.perf
                           type = $_.type
                           valueName = $_.valueName

                           options = $_.options
                           value = if ($_.type -eq "enum") { Get-RegTweakValue -def $_ } elseif ($_.type -eq "merge") { Get-MergeStringValue -def $_ } else { $null }
                           caution = $_.caution
                           needsVerify = [bool]$_.verify
                           active = (Get-RegTweakState $_) }
                    })
                }
                "/api/processes" {
                    $jsonOutput = Get-ProcessList
                }
                "/api/processes/kill" {
                    $pidToKill = $null
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $pidToKill = $parsed.pid
                    }
                    if ($pidToKill) {
                        Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
                        $jsonOutput = @{ success = $true; killed = $pidToKill }
                    } else {
                        $jsonOutput = @{ success = $false; error = "Invalid PID" }
                    }
                }
                "/api/processes/clean-ram" {
                    $jsonOutput = Purge-StandbyRam
                }
                "/api/restore-point" {
                    $jsonOutput = Create-RestorePoint
                }
                "/api/revert-defaults" {
                    $jsonOutput = Restore-Defaults
                }
                default {
                    $response.StatusCode = 404
                    $jsonOutput = @{ error = "Endpoint not found" }
                }
            }

            $jsonStr = $jsonOutput | ConvertTo-Json -Depth 6 -Compress
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)
            $response.ContentType = "application/json; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.Close()
            continue
        }

        # STATIC FILE SERVING
        $reqPath = $rawUrl
        if ($reqPath -eq "/" -or [string]::IsNullOrWhiteSpace($reqPath)) {
            $reqPath = "/index.html"
        }

        $sanitized = $reqPath.TrimStart('/').Replace('/', '\')
        $filePath = Join-Path $publicDir $sanitized
        # Path traversal guard: resolved path must stay inside publicDir
        $resolvedFile = try { [System.IO.Path]::GetFullPath($filePath) } catch { "" }
        $resolvedBase = [System.IO.Path]::GetFullPath($publicDir)
        if (-not $resolvedFile.StartsWith($resolvedBase)) {
            $response.StatusCode = 400
            $response.Close()
            continue
        }

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mime = "application/octet-stream"
            if ($mimeTypes.ContainsKey($ext)) {
                $mime = $mimeTypes[$ext]
            }

            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentType = $mime
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            $response.Close()
        } else {
            $response.StatusCode = 404
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes("File Not Found")
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            $response.Close()
        }
    } catch {
        # Catch unexpected client disconnects
    }
}
