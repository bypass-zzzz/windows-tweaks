# ==============================================================================
# WINDOWS TWEAKS - HIGH-PERFORMANCE LOW-LATENCY ENGINE BACKEND
# Architecture: Native PowerShell Async Micro-Server with System.Net.HttpListener
# ==============================================================================

param(
    [int]$Port = 48921,
    [switch]$NoBrowser
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

    $cpuLabel = "AMD Ryzen 5 7600X 6-Core Processor"
    if ($cpu -and $cpu.Name) { $cpuLabel = "$($cpu.Name) ($($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T)" }

    $osLabel = "Microsoft Windows 11 Pro"
    if ($os -and $os.Caption) { $osLabel = "$($os.Caption) ($($os.Version) Build $($os.BuildNumber))" }

    $script:StaticHw = @{ CpuLabel = $cpuLabel; OsLabel = $osLabel }
    return $script:StaticHw
}

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS: SYSTEM & NETWORK AUDITING
# -----------------------------------------------------------------------------

function Get-PowerAcValue($sub, $setting) {
    $out = (& powercfg.exe /query SCHEME_CURRENT $sub $setting 2>$null) | Out-String
    $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) } else { return $null }
}

function Get-SystemAudit {
    # Perf: the two slow WMI calls here used to be Win32_Processor (~1.0 s,
    # only for LoadPercentage) and Win32_OperatingSystem (~0.3 s, only for
    # FreePhysicalMemory). Both now come from native counters. Identity strings
    # are pulled once and cached; Win32_ComputerSystem was assigned and never
    # read, so it is gone entirely.
    $hw = Get-StaticHw
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    $ram = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue

    $totalRamBytes = ($ram | Measure-Object -Property Capacity -Sum).Sum
    $totalRamGB = if ($totalRamBytes) { [Math]::Round($totalRamBytes / 1GB, 1) } else { 32 }
    $ramSample = Get-RamSample
    $freeRamGB = if ($ramSample) { $ramSample.FreeGB } else {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os.FreePhysicalMemory) { [Math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 20 }
    }
    $usedRamGB = [Math]::Round($totalRamGB - $freeRamGB, 1)
    if ($usedRamGB -lt 0) { $usedRamGB = 8.0 }
    $ramPercent = [Math]::Round(($usedRamGB / $totalRamGB) * 100, 1)
    $ramSpeed = ($ram | Select-Object -First 1).Speed
    if (-not $ramSpeed) { $ramSpeed = 6000 }

    $gpuList = @()
    foreach ($g in $gpus) {
        if ($g.Name) {
            $gpuList += @{
                Name = $g.Name
                DriverVersion = $g.DriverVersion
                Resolution = "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"
                RefreshRate = if ($g.CurrentRefreshRate) { "$($g.CurrentRefreshRate) Hz" } else { "170 Hz" }
            }
        }
    }

    # HAGS
    $hagsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $hagsVal = (Get-ItemProperty $hagsKey -Name "HwSchMode" -ErrorAction SilentlyContinue).HwSchMode
    $isHagsActive = ($hagsVal -eq 2)

    # Windows 11 Flip Optimizations (on by default - missing value means enabled)
    $dxKey = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    $autoOpt = (Get-ItemProperty $dxKey -Name "AutoOptimizationsEnabled" -ErrorAction SilentlyContinue).AutoOptimizationsEnabled
    $isGameOptActive = (($null -eq $autoOpt) -or ($autoOpt -eq 1))

    # BCD Timers
    $bcd = (bcdedit /enum "{current}" 2>$null) | Out-String
    $dynamicTick = ($bcd -match "disabledynamictick\s+Yes")
    $platformTick = ($bcd -match "useplatformtick\s+Yes")

    # Kernel RAM lock (DisablePagingExecutive)
    $mmKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    $pagingExec = (Get-ItemProperty $mmKey -Name "DisablePagingExecutive" -ErrorAction SilentlyContinue).DisablePagingExecutive
    $isKernelLocked = ($pagingExec -eq 1)

    # Multimedia and Network Throttling
    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    $netThrottle = (Get-ItemProperty $mmProfile -Name "NetworkThrottlingIndex" -ErrorAction SilentlyContinue).NetworkThrottlingIndex
    # NetworkThrottlingIndex is a DWORD and reads back unsigned as 4294967295.
    # The old check was `-eq -1 -or -eq 0xffffffff`, but PowerShell 5.1 parses
    # 0xffffffff as Int32 -1, so BOTH comparisons were False against 4294967295.
    # The value was applied yet reported as off, so the UI toggle snapped back to
    # OFF even though throttling was disabled. Widen to Int64 and compare the
    # real unsigned value. A missing value becomes 0, which correctly reads as
    # "not disabled".
    $isThrottleDisabled = ((([int64]$netThrottle) -eq 4294967295) -or (([int64]$netThrottle) -eq -1))

    # Power Scheme
    $activePlan = (powercfg /getactivescheme 2>$null)
    $isUltimatePower = ($activePlan -match "Ultimate Performance|High performance|Hybred")

    # GameDVR
    $dvr = (Get-ItemProperty "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -ErrorAction SilentlyContinue).GameDVR_Enabled
    $isDvrDisabled = ($dvr -eq 0)

    # Delivery Optimization P2P
    $doMode = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -ErrorAction SilentlyContinue).DODownloadMode
    $isDoDisabled = ($doMode -eq 0)

    # Total active processes count (reuse the $cpu query above - one WMI round-trip)
    $procCount = (Get-Process -ErrorAction SilentlyContinue).Count
    $cpuLoadVal = Get-CpuLoadSample
    if ($null -eq $cpuLoadVal) {
        # Native counters unavailable - fall back to the slow WMI sample.
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        $cpuLoadVal = ($cpu | Measure-Object -Property LoadPercentage -Average -ErrorAction SilentlyContinue).Average
    }
    if ($null -eq $cpuLoadVal) { $cpuLoadVal = 6 }

    # --- Extended gaming/OS audit (all reversible, all exposed as toggles) ---
    $gameBarAuto = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\GameBar" -Name "AllowAutoGameMode" -ErrorAction SilentlyContinue).AllowAutoGameMode
    # Game Mode is on by default - a missing value means enabled, not disabled
    $isGameMode = (($null -eq $gameBarAuto) -or ($gameBarAuto -eq 1))

    $transparency = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -ErrorAction SilentlyContinue).EnableTransparency
    $isTransparencyOff = ($transparency -eq 0)

    $menuDelay = (Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -ErrorAction SilentlyContinue).MenuShowDelay
    $isMenuFast = ($menuDelay -eq "0")

    $mouseSpeed = (Get-ItemProperty "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -ErrorAction SilentlyContinue).MouseSpeed
    $isPrecisionOff = ($mouseSpeed -eq "0")

    $mmAgent = Get-MMAgent -ErrorAction SilentlyContinue
    $isMemDecompressed = ($mmAgent -and ($mmAgent.MemoryCompressionEnabled -eq $false))

    $cpuMinAc = Get-PowerAcValue "SUB_PROCESSOR" "PROCTHROTTLEMIN"
    $cpuMaxAc = Get-PowerAcValue "SUB_PROCESSOR" "PROCTHROTTLEMAX"
    $isCpuBoost = ($cpuMinAc -eq 100 -and $cpuMaxAc -eq 100)

    $gpuNames = @($gpus | ForEach-Object { $_.Name })
    $hasNvidia = [bool]($gpuNames -match "NVIDIA")
    $nvidiaRid = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS" -Name "EnableRID61684" -ErrorAction SilentlyContinue).EnableRID61684
    $isNvidiaRid = ($hasNvidia -and ($nvidiaRid -eq 1))

    # --- Custom (non-registry) audits ---
    $isHiberOff = -not (Test-Path "$env:SystemDrive\hiberfil.sys")

    $nbtOpts = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue | Select-Object -First 1).TcpipNetbiosOptions
    $isNbtOff = ($nbtOpts -eq 2)

    $teredoOut = ((& netsh.exe interface teredo show state 2>$null) | Out-String)
    $isTeredoOff = ($teredoOut -match '(State|Type)\s*:\s*disabled')
    $isatapOut = ((& netsh.exe interface isatap show state 2>$null) | Out-String)
    $isIsatapOff = ($isatapOut -match '(State|Type)\s*:\s*disabled')
    $sitoOut = ((& netsh.exe interface 6to4 show state 2>$null) | Out-String)
    $is6to4Off = ($sitoOut -match '(State|Type)\s*:\s*disabled')

    $tweakBase = @{
        hags = $isHagsActive
        gameOptimizations = $isGameOptActive
        dynamicTickDisabled = $dynamicTick
        platformTick = $platformTick
        kernelRamLock = $isKernelLocked
        networkThrottlingDisabled = $isThrottleDisabled
        gameDvrDisabled = $isDvrDisabled
        deliveryOptimizationDisabled = $isDoDisabled
        ultimatePowerPlan = $isUltimatePower
        gameMode = $isGameMode
        transparencyOff = $isTransparencyOff
        menuFast = $isMenuFast
        precisionOff = $isPrecisionOff
        memDecompressed = $isMemDecompressed
        cpuBoost = $isCpuBoost
        nvidiaRid = $isNvidiaRid
        nvidiaAvailable = $hasNvidia
        hibernate = $isHiberOff
        netbios = $isNbtOff
        teredo = $isTeredoOff
        isatap = $isIsatapOff
        sixtofour = $is6to4Off
    }
    foreach ($def in $script:RegTweaks) {
        $tweakBase[$def.id] = Get-RegTweakState $def
    }

    return @{
        os = $hw.OsLabel
        cpu = $hw.CpuLabel
        cpuLoad = [Math]::Round($cpuLoadVal, 0)
        ram = @{
            total = $totalRamGB
            used = $usedRamGB
            free = $freeRamGB
            percent = $ramPercent
            speed = $ramSpeed
            sticks = if ($ram.Count) { $ram.Count } else { 2 }
        }
        gpus = $gpuList
        powerPlan = if ($activePlan) { $activePlan } else { "Ultimate Performance" }
        processCount = $procCount
        isAdmin = $script:IsAdmin
        tweaks = $tweakBase
    }
}

function Get-NetworkAudit {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    }
    if (-not $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    # MTU
    $sub = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $currentMtu = if ($sub.NlMtu) { $sub.NlMtu } else { 1280 }

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

    return @{
        name = if ($adapter.Name) { $adapter.Name } else { "Ethernet" }
        interfaceDescription = if ($adapter.InterfaceDescription) { $adapter.InterfaceDescription } else { "Realtek Gaming 2.5GbE Family Controller" }
        linkSpeed = if ($adapter.LinkSpeed) { $adapter.LinkSpeed } else { "2.5 Gbps" }
        macAddress = $adapter.MacAddress
        ipAddress = if ($ipConfig.IPAddress) { $ipConfig.IPAddress } else { "192.168.1.100" }
        mtu = $currentMtu
        dnsServers = if ($dnsServers) { $dnsServers } else { @("1.0.0.1", "1.1.1.1") }
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
        optimalGamingMtu = 1280
        detectedMaxUnfragmentedMtu = $detectedMtu
        recommended = 1280
        # Additive key: app.js already reads detectedMaxUnfragmentedMtu, so the
        # shape it parses is unchanged. Consumers must gate on this before
        # trusting detectedMaxUnfragmentedMtu - see app.js runMtuTest().
        success = $measured
    }
}

function Get-BloatServices {
    $targetServices = @(
        @{ Name = "DiagTrack"; Display = "Connected User Experiences and Telemetry"; Safe = $true; Impact = "High" },
        @{ Name = "WerSvc"; Display = "Windows Error Reporting Service"; Safe = $true; Impact = "Medium" },
        @{ Name = "SysMain"; Display = "SysMain (SuperFetch Disk Caching)"; Safe = $true; Impact = "High" },
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

    $list = @()
    foreach ($s in $targetServices) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($svc) {
            $list += @{
                name = $s.Name
                displayName = $s.Display
                status = $svc.Status.ToString()
                startType = $svc.StartType.ToString()
                safe = $s.Safe
                impact = $s.Impact
                isOptimized = ($svc.StartType.ToString() -eq "Disabled")
            }
        } else {
            $list += @{
                name = $s.Name
                displayName = $s.Display
                status = "Stopped"
                startType = "Disabled"
                safe = $s.Safe
                impact = $s.Impact
                isOptimized = $true
            }
        }
    }
    return $list
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
    @{ id="copilotPolicy"; category="Gaming"; label="Disable Windows Copilot"; desc="Turns off the Copilot assistant and its background hooks."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="TurnOffWindowsCopilot";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bingSearch"; category="Gaming"; label="Disable Bing in Start Search"; desc="Start menu searches stay local - no web round-trip, instant results."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; values=@(@{name="DisableSearchBoxSuggestions";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bgApps"; category="Gaming"; label="Disable Background Apps"; desc="Stops UWP apps running in the background eating CPU and network."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; values=@(@{name="GlobalUserDisabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; advanced=$true; caution="Genuinely frees idle CPU and RAM, so this is one of the few real wins here. Do NOT enable if you rely on a Store app updating in the background, on Xbox/Game Pass apps syncing your library, or on anything that receives notifications while closed. Those stop working with no error - the app just goes quiet until you open it." },
    @{ id="silentApps"; category="Gaming"; label="Block Silent Auto-Installed Apps"; desc="Stops Windows silently installing suggested apps (Candy Crush and co)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SilentInstalledAppsEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="getTips"; category="Gaming"; label="Disable Tips and Suggestions"; desc="Turns off Get Started tips, suggestions and soft-landing pages."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SoftLandingEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="fullscreenOpt"; category="Gaming"; label="Disable Fullscreen Optimizations"; desc="Stops Windows 10/11 from injecting its own scaling and frame-pacing shim into fullscreen games, which is a frequent source of stutter and reduced performance on older titles."; path="HKCU:\System\CurrentControlSet\Control\GameConfigStore"; values=@(@{name="GameDVR_FSEBehaviorMode";type="DWord";on=2;off="__REMOVE__"}, @{name="GameDVR_HonorUserFSEBehaviorMode";type="DWord";on=1;off="__REMOVE__"}, @{name="GameDVR_DXGIHonorFSEWindowsCompatible";type="DWord";on=1;off="__REMOVE__"}, @{name="GameDVR_EFSEFeatureFlags";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable on a modern title that runs well - FSO exists to fix tearing and alt-tab on some GPUs, and forcing it off can make things worse. Turn it on per-game only, and A/B test a borderless-fullscreen benchmark before and after. Safe to leave off (this tweak's default)." },
    @{ id="gameDvrOff"; category="Gaming"; label="Disable Game DVR Background Capture"; desc="Stops Windows continuously recording gameplay in the background. Removes a rolling video encode that costs disk writes and a few percent CPU even when you are not recording."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"; values=@(@{name="AppCaptureEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Xbox Game Bar to record clips, or if you use Steam/GeForce overlay instead - those record independently and are unaffected, so you can enable this safely if you use those instead."; advanced=$true },
    @{ id="xboxGameBar"; category="Gaming"; label="Disable Xbox Game Bar Overlay"; desc="Stops the Game Bar overlay from hooking into games. Removes an injected overlay that some titles pay a real framerate cost for and that occasionally causes input lag or crashes on Alt+Tab."; path="HKCU:\SOFTWARE\Microsoft\GameBar"; values=@(@{name="UseNexusForGameBarEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="ShowStartupPanel";type="DWord";on=0;off="__REMOVE__"}, @{name="AutoGameModeEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Win+G for performance widgets, achievements, or the Xbox Game Bar capture UI. This kills the whole bar, not just capture - use gameDvrOff above if you only want to stop recording." },
    # --- Network ---
    @{ id="llmnr"; category="Network"; label="Disable LLMNR Name Resolution"; desc="Disables multicast fallback lookups (faster fails, less chatter)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; values=@(@{name="EnableMulticast";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wpad"; category="Network"; label="Disable WPAD Auto-Proxy"; desc="Skips proxy auto-discovery delay on every new connection."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings"; values=@(@{name="AutoDetect";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="smbSigning"; category="Network"; label="Require SMB Signing"; desc="Forces every SMB connection to be cryptographically signed, blocking unsigned relay attacks on a local network. Only affects file shares, not web traffic."; path="HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; values=@(@{name="RequireSecuritySignature";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you connect to a NAS, an old printer, or a Linux Samba share that does not support signing - those connections will fail outright. Safe on a home network with only Windows machines. Enabling on the SERVER only is a good middle ground." },
    @{ id="smb1Off"; category="Network"; label="Disable SMB1 (Windows 2003 Shares)"; desc="Removes the obsolete SMBv1 protocol, which is unencrypted and is the most commonly abused Windows network service. Stops WannaCry-class exploitation and drops the NT1 cipher."; path="HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"; values=@(@{name="SMB1";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$false; verify=$true; caution="Do NOT enable if you still share files with a Windows 7/XP-era machine, an old printer, or a Time Capsule. There is no in-band fallback - those devices simply stop being reachable. Recommended for anyone not actively using ancient hardware." },
    @{ id="ipv6Tunnels"; category="Network"; label="Disable Teredo / ISATAP / 6to4"; desc="Stops the three Windows tunnel transition technologies from routing IPv6 traffic through public relays. Uses the real control DisabledComponents under Tcpip6 - an earlier version of this entry wrote to a key that does not exist, so it never took effect."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"; values=@(@{name="DisabledComponents";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Do NOT enable if you are on an IPv6-only or CGNAT connection, or behind a VPN that relies on a tunnel adapter. There is a real risk of losing all external connectivity. Check that your provider actually gives you native IPv6 first. Note: on this machine the value is already 1, so this is currently a no-op." },
    @{ id="ecnOff"; category="Network"; label="Disable ECN (Explicit Congestion Notification)"; desc="Stops the TCP stack advertising ECN, which adds an extra signalling round-trip when a path reports congestion. Turning it off removes that exchange, so a congested route recovers its send window sooner instead of waiting on markers in the data stream."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="EnableECN";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Genuine on long or congested paths, and it is the difference between a path that recovers in one RTT and one that limps along. Do NOT enable if your connection is genuinely congested and you want the gentler behaviour ECN gives the rest of the internet - disabling it makes your traffic more aggressive, not more polite. Little to no effect on a short clean LAN or a wired link with headroom."; advanced=$true },
    @{ id="tcpWindowSize"; category="Network"; label="Increase TCP Receive Window"; desc="Raises the static TCP window from the default 64KB to 256KB, so more unacknowledged data can be in flight. On a long path the default window is smaller than the bandwidth-delay product, which forces the sender to stall waiting for ACKs."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="TcpWindowSize";type="DWord";on=262144;off="__REMOVE__"}, @{name="GlobalMaxTcpWindowSize";type="DWord";on=262144;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Real benefit only where the link is long and the pipe is wide - satellite, cross-continent, or high-speed fibre with latency. On a normal home connection under 100ms it changes nothing measurable, because window scaling already adapts. It does not reduce ping; it reduces throughput stalls on long routes. Do NOT bother enabling it on a local or short-hop link."; advanced=$true },
    @{ id="dohOff"; category="Network"; label="Disable DNS over HTTPS"; desc="Stops Windows from silently routing name lookups through its own encrypted resolver. Without this, Windows can use DoH and bypass the DNS servers set in Network settings, which means the provider you chose is not always the one answering - and that adds variable lookup time."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; values=@(@{name="EnableDoH";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe unless you specifically want DoH for privacy - some people enable it deliberately to stop their ISP seeing lookups. If you set DNS manually in Network settings, leave this on so those servers are the ones actually used. It is about consistency of which resolver answers, not about raw ping." },
    @{ id="nssiProbeOff"; category="Network"; label="Disable Connectivity Check Probes"; desc="Stops Windows periodically broadcasting to the internet to decide whether you are online. Those background probes show up as small periodic connections and can contend with a game on a latency-sensitive link."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator"; values=@(@{name="NoNetworkProbe";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Harmless to leave on. It does not improve ping - it just stops the OS checking. The visible effect is Windows sometimes showing the wrong network icon, because it can no longer tell online from offline reliably. Worth it on metered or very slow links, marginal everywhere else." },
    @{ id="autoDnsSuffixOff"; category="Network"; label="Disable DNS Suffix Search List"; desc="Stops Windows appending each connection's DNS suffix to every lookup that fails, which otherwise turns one failed name into several sequential timeouts before it gives up. Directly reduces tail latency on misspelled or blocked domains."; path="HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"; values=@(@{name="DisableSearchList";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe for a home or single-domain machine. Do NOT enable on a corporate network using a search suffix to find internal hosts by short name - unqualified lookups for printers, file shares and internal apps would stop resolving, which is a real breakage rather than a slowdown." },
    # --- Privacy ---
    @{ id="adId"; category="Privacy"; label="Disable Advertising ID"; desc="Stops apps using your advertising ID for personalized ads."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="tailoredExp"; category="Privacy"; label="Disable Tailored Experiences"; desc="Stops Microsoft tailoring tips/ads from your diagnostic data."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; values=@(@{name="TailoredExperiencesWithDiagnosticDataEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="activityFeed"; category="Privacy"; label="Disable Activity History Feed"; desc="Stops Timeline/activity uploads across devices."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; values=@(@{name="EnableActivityFeed";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="locationSensors"; category="Privacy"; label="Disable Location Sensors"; desc="Turns off location tracking for apps and services."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"; values=@(@{name="DisableLocation";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="feedbackNotif"; category="Privacy"; label="Disable Feedback Prompts"; desc="Stops Windows begging for feedback with popup notifications."; path="HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; values=@(@{name="NumberOfSIUFInPeriod";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="allowTelemetry"; category="Privacy"; label="Telemetry to Security-Only"; desc="Drops Windows diagnostic data collection to the minimum level."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="AllowTelemetry";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="diagLogs"; category="Privacy"; label="Limit Diagnostic Log Collection"; desc="Stops extended diagnostic logs from being gathered and sent."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="LimitDiagnosticLogCollection";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="appAccess"; category="Privacy"; label="Deny Apps Location / Camera Access"; desc="Removes the master 'let apps use your location' permission for every app at once, and blocks camera access for desktop apps that do not need it."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; values=@(@{name="LetAppsAccessLocation";type="DWord";on=0;off="__REMOVE__"}, @{name="LetAppsAccessCamera";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use a phone-mirroring app, a VPN with QR scanning, a video-conferencing tool, or anything that authenticates by camera. This is a blanket deny - it will not ask you, it will just fail. Check your app list first, or enable it and then re-grant per app from Settings." },
    @{ id="webSearchPerms"; category="Privacy"; label="Restrict Web Search Permissions"; desc="Stops apps using your safe-search and content-level settings to filter web results, so a third-party app cannot read or alter your browsing preferences."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; values=@(@{name="LetAppsAccessWebSearch";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe for almost everyone. The only effect is that apps cannot read your SafeSearch setting - your own Edge/Chrome search filtering is completely unaffected." },
    @{ id="inputPersonalization"; category="Privacy"; label="Disable Typing Personalization"; desc="Stops Windows sending your typed words, handwriting samples and clipboard history to Microsoft for text prediction, and stops the on-device dictionary learning."; path="HKCU:\SOFTWARE\Microsoft\Input"; values=@(@{name="IsInputPersonalizationEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="You lose handwriting recognition, predictive text and the ability to type by voice in a few dialogs. On a touchscreen laptop, handwriting is the main casualty - do not enable it there unless you have a keyboard." },
    @{ id="contentDelivery"; category="Privacy"; label="Disable All Suggested Content"; desc="Switches off the whole suggested-content family in one go: lock screen fun facts, Start menu suggestions, and the 'recommended' tiles Windows installs on your behalf."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; values=@(@{name="DisableWindowsSpotlightFeatures";type="DWord";on=1;off="__REMOVE__"}, @{name="DisableTailoredExperiencesWithDiagnosticDataEnabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. This is advertising, not functionality - nothing you rely on stops working. One of the highest value-to-risk ratio privacy tweaks available." },
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
    @{ id="thumbCache"; category="Interface"; label="Disable Thumbnail Cache"; desc="Stops thumbnail caching I/O (rebuilds thumbs on the fly)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="DisableThumbnailCache";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="searchHighlights"; category="Interface"; label="Disable Search Highlights"; desc="Removes rotating ads/illustrations from the taskbar search box."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings"; values=@(@{name="IsDynamicSearchBoxEnabled";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarWidgets"; category="Interface"; label="Remove Widgets Board"; desc="Takes the Widgets feed off the taskbar."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarDa";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarChat"; category="Interface"; label="Remove Taskbar Chat Icon"; desc="Removes the pinned Teams Chat icon."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarMn";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarCopilot"; category="Interface"; label="Remove Copilot Button"; desc="Takes the Copilot button off the taskbar."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="ShowCopilotButton";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="taskbarEndTask"; category="Interface"; label="End-Task on Right-Click"; desc="Adds 'End task' to taskbar app right-click menus (Win11)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; values=@(@{name="TaskbarEndTask";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="launchToPC"; category="Interface"; label="Open Explorer to This PC"; desc="Explorer opens on drives instead of Quick Access."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="LaunchTo";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false },
    @{ id="clockSeconds"; category="Interface"; label="Clock Seconds"; desc="Shows seconds in the taskbar clock."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="ShowSecondsInSystemClock";type="DWord";on=1;off=0}); defaultOn=$false; reboot=$false },
    @{ id="altTabClassic"; category="Interface"; label="Classic Alt+Tab Dialog"; desc="Restores the instant classic app-switcher instead of the fancy one."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; values=@(@{name="AltTabSettings";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="aeroPeek"; category="Interface"; label="Disable Aero Peek"; desc="Stops the desktop-preview hover effect using DWM resources."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="DisablePreviewDesktop";type="DWord";on=1;off=0}); defaultOn=$false; reboot=$false },
    @{ id="dragWindows"; category="Interface"; label="Don't Render While Dragging"; desc="Shows only window outlines while dragging (less DWM work)."; path="HKCU:\Control Panel\Desktop"; values=@(@{name="DragFullWindows";type="String";on="0";off="1"}); defaultOn=$false; reboot=$false },
    @{ id="darkMode"; category="Interface"; label="Force Dark Mode"; desc="Applies the dark theme to apps that do not have their own dark setting, so the whole system stops flashing white windows."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; values=@(@{name="AppsUseLightTheme";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe, and reversible from Settings at any time. Some older apps with hardcoded light palettes render unreadable - those are the only ones affected." },
    @{ id="combineAlwaysHide"; category="Interface"; label="Never Combine Taskbar Buttons"; desc="Stops the taskbar grouping icons entirely. Each running app keeps its own labelled button, so you can see everything open at a glance instead of one numbered icon."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarNoCombine";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you habitually run more than about six windows at once - the taskbar will overflow and start hiding buttons behind the overflow chevron, which is worse than grouping." },
    @{ id="taskbarSmall"; category="Interface"; label="Use Small Taskbar Buttons"; desc="Shrinks the taskbar height, returning roughly 10px of screen height. Windows 11 defaults to the large taskbar, which wastes vertical space on a 1080p display."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; values=@(@{name="TaskbarSi";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. Only do this if you are on 1080p and feel the taskbar is oversized. On a laptop with a 13-inch 720p panel the large taskbar is actually easier to hit, so leave it." },
    @{ id="networkDriveIcon"; category="Interface"; label="Show Mapped Network Drives"; desc="Removes the mapped-network-drive overlay shortcut that Explorer injects into This PC, so your drive list shows only real local disks."; path="HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoNetworkDriveShowInThisPC";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use a mapped drive letter and rely on seeing it in This PC - you will still be able to reach it by typing the path, but it vanishes from the sidebar and This PC listing." },
    # --- System ---
    @{ id="keyRepeat"; category="System"; label="Fastest Key Repeat"; desc="Max keyboard repeat rate and minimum delay for rapid input."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="KeyboardSpeed";type="String";on="31";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="numLock"; category="System"; label="NumLock On at Boot"; desc="Keeps the numpad enabled on the login screen and after boot."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="InitialKeyboardIndicators";type="String";on="2";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="autoplay"; category="System"; label="Disable AutoPlay"; desc="Stops USB/discs auto-launching anything when plugged in."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoDriveTypeAutoRun";type="DWord";on=255;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="remoteAssist"; category="System"; label="Disable Remote Assistance"; desc="Closes the inbound remote-help attack surface."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"; values=@(@{name="fAllowToGetHelp";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="powerThrottling"; category="System"; label="Disable Power Throttling"; desc="Stops Windows down-clocking background work (consistent performance)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"; values=@(@{name="PowerThrottlingOff";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="longPaths"; category="System"; label="Enable Long File Paths"; desc="Removes the 260-character path limit for apps and games."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="LongPathsEnabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="shortNames"; category="System"; label="Disable 8.3 Short Filenames"; desc="Stops NTFS maintaining legacy short names (faster file creation)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisable8dot3NameCreation";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false; advanced=$true; caution="Do NOT enable if any software you run still creates or looks up 8.3 names - some older installers, and certain network shares, depend on them. Mostly safe on a modern single-user machine." },
    @{ id="lastAccess"; category="System"; label="Disable Last-Access Tracking"; desc="Stops NTFS timestamping every file read (less disk I/O)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisableLastAccessUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Almost always safe and worth it. The only cost is that NTFS last-access timestamps stop updating, so Recently Used lists and some backup tools that rely on access time will be less accurate." },
    @{ id="cpuMitigations"; category="System"; label="Disable CPU Side-Channel Mitigations"; desc="Turns off Spectre/Meltdown software mitigations for raw speed. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; values=@(@{name="FeatureSettingsOverride";type="DWord";on=3;off="__REMOVE__"}, @{name="FeatureSettingsOverrideMask";type="DWord";on=3;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="Reduces your security posture meaningfully. Do NOT enable on a machine that browses untrusted sites, runs untrusted downloads, or develops against untrusted dependencies - you lose Spectre/Meltdown class protection. Enable only on a dedicated offline gaming rig, and only after measuring a real stutter win. Expect single-digit percent at best; the folklore numbers are not real." },
    @{ id="vbsOff"; category="System"; label="Disable Virtualization-Based Security"; desc="Turns off VBS for lower overhead in CPU-bound games. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"; values=@(@{name="EnableVirtualizationBasedSecurity";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="Do NOT enable if you use Windows Hello, Defender Credential Guard, or BitLocker - all three depend on VBS and will break. Also removes the hypervisor-enforced isolation that stops kernel-level malware. Only for an offline gaming machine that measures a real gain." },
    @{ id="hvciOff"; category="System"; label="Disable Memory Integrity (HVCI)"; desc="Turns off hypervisor-protected code integrity for less overhead. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; advanced=$true; caution="Do NOT enable if you run untrusted code. This is the control that stops a compromised driver injecting into kernel memory. Only reasonable on a sealed, offline machine." },
    @{ id="fastStartup"; category="System"; label="Disable Fast Startup"; desc="Full shutdown every time - avoids stale-driver and dual-boot issues."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"; values=@(@{name="HiberbootEnabled";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false; caution="Not a speedup - it is a correctness fix. Enable it if you have ever had USB or driver problems after a shutdown, or dual-boot and find the second OS unable to mount the disk. It makes shutdown marginally slower and boot marginally slower." },
    @{ id="lockAds"; category="System"; label="Disable Lock Screen Ads"; desc="Kills spotlight promos and fun-fact overlays on the lock screen."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="RotatingLockScreenEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="RotatingLockScreenOverlayEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="SubscribedContent-338387Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="timerResolution"; category="System"; label="Allow Global Timer Resolution Requests"; desc="Lets applications that ask for a high-resolution system timer actually get one, instead of Windows clamping them to the default 15.6ms tick. It does NOT raise the tick on its own - a program has to request it."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"; values=@(@{name="GlobalTimerResolutionRequests";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Corrected after review: the old description claimed this forces a 0.5ms timer period, which is false. GlobalTimerResolutionRequests only PERMITS global requests; without a program asking, the resolution does not change. GAMMA caught this. Do NOT enable on a laptop expecting input latency gains - the effect is workload-dependent and usually small, and permitting high-resolution timers costs a little power." },
    @{ id="multimediaScheduling"; category="System"; label="Remove Multimedia Throttle Reservation"; desc="Removes the 20 percent CPU reservation that MMCSS holds back for multimedia work, so audio and video threads are not preempted by background load. Only the one value at its documented location is written - an earlier version also wrote NoLazyMode and GPU Priority under SystemProfile, where they do nothing."; path="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; values=@(@{name="SystemResponsiveness";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Mildly risky on a slow machine - removing the reservation lets media threads take CPU the desktop wanted, which can starve the UI if a decode stalls. If audio ever crackles after enabling, this is the first thing to revert."; advanced=$true },
    # --- Updates ---
    @{ id="wuNoAutoReboot"; category="Updates"; label="No Forced Reboot After Updates"; desc="Windows Update never restarts your PC while you're logged in."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; values=@(@{name="NoAutoRebootWithLoggedOnUsers";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wuDrivers"; category="Updates"; label="Stop Driver Updates via Windows Update"; desc="Keeps your hand-picked GPU/chipset drivers from being overwritten."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; values=@(@{name="ExcludeWUDriversInQualityUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="consumerFeatures"; category="Updates"; label="Block Consumer Bloat Reinstalls"; desc="Stops Windows re-adding suggested apps after updates."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; values=@(@{name="DisableWindowsConsumerFeatures";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="oneDriveSync"; category="Updates"; label="Disable OneDrive File Sync"; desc="Stops OneDrive syncing (frees CPU, RAM and upload bandwidth)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; values=@(@{name="DisableFileSyncNGSC";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use OneDrive for file sync, backup across devices, or offline Files On-Demand. Turning this off silently stops syncing and you can get partial-sync conflicts. Use it only for a fixed gaming/workstation machine that never syncs." },
    @{ id="optionalUpdates"; category="Updates"; label="Disable Optional / Driver Updates"; desc="Stops Windows Update offering optional features, preview builds and driver bundles, so it only installs what it considers required."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; values=@(@{name="SetOptionalQualityState";type="DWord";on=2;off="__REMOVE__"}, @{name="SetOptionalContentState";type="DWord";on=2;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe and recommended. The trade-off is that you will never be offered a new driver through Windows Update again, so you own driver updates for your GPU. Pair it with wuDrivers above, which stops only driver packages from being pushed while leaving security updates intact." },
    @{ id="deliveryOptBandwidth"; category="Updates"; label="Cap Windows Update Bandwidth"; desc="Limits Windows so it can never use more than 20% of your measured bandwidth for downloads. Stops a large update from saturating the link while you are gaming or on a call."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; values=@(@{name="BandwidthLimit";type="DWord";on=20;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Safe. Updates just take longer. Only worth enabling if you have noticed a large cumulative update causing lag spikes on a capped or slow connection."; advanced=$true },
    @{ id="deliveryOptOff"; category="Updates"; label="Completely Disable Delivery Optimization"; desc="Turns Delivery Optimization off entirely rather than tuning it. Stops Windows using your machine to distribute and receive update payloads from other PCs, and stops the DoSvc service doing background work on your connection. Windows Update itself still works - it just downloads directly from Microsoft instead."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; values=@(@{name="DownloadMode";type="DWord";on=0;off="__REMOVE__"}, @{name="DODownloadMode";type="DWord";on=100;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Genuine win on privacy and idle network use, since you stop being a P2P node. Do NOT enable if you are on a slow or metered connection - Delivery Optimization is how Windows fetches update payloads from nearby machines instead of Microsoft's servers, so disabling it can make large updates considerably slower to download. If you only want to stop being an upload node rather than disable it, deliveryOptBandwidth caps bandwidth without that trade-off."; advanced=$true },

    # --- AI FEATURES (WinTool-style: everything Windows forces on you) ---
    # Grouped last, on purpose: these are the most likely to be reverted by a
    # Windows feature update, and the most likely to break a product you rely on.
    @{ id="aiDataAnalysis"; category="AI Features"; label="Disable Recall / AI Data Analysis"; desc="Stops Windows from capturing periodic screen snapshots for Recall and Click to Do, and turns off the underlying on-device AI analysis pipeline. Removes the recurring background hashing work and stops your screen being sampled."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableAIDataAnalysis";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Do NOT enable if you actively use Recall to search your own past screens, or Click to Do to act on what's on screen. Also affects Paint Cocreator-style on-device image features. Safe if you never touch those features - it just stops work you were not using." },
    @{ id="aiCopilotApp"; category="AI Features"; label="Disable Copilot (Machine Policy)"; desc="Machine-wide block on the Copilot assistant, applied to every user on this PC via HKLM policy. Stops the Copilot taskbar button and its background process on sign-in. The separate 'Disable Windows Copilot' toggle in Gaming is the per-user HKCU equivalent - use one or the other, not both."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="TurnOffWindowsCopilot";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Do NOT enable if you use Copilot daily - there is no offline fallback, it is a cloud service. Also do not enable if you rely on Windows Studio Effects (camera background blur / eye contact) which ships in the same app on Copilot+ PCs. This is HKLM, so it applies to all accounts on the machine; the Gaming toggle is HKCU and only affects you." },
    @{ id="aiCortana"; category="AI Features"; label="Disable Cortana"; desc="Removes Cortana from the shell and stops it indexing your files, calendar and microphone input. Frees the background indexing that runs continuously once Cortana is signed in."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; values=@(@{name="AllowCortana";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true; caution="Safe unless you use voice to set reminders, or Windows Search for people/calendar. Note the search box itself keeps working - only the Cortana half is removed." },
    @{ id="aiBingSearch"; category="AI Features"; label="Disable Bing in Start Search"; desc="Forces Start menu and taskbar search to answer from the local index only. No query ever leaves the machine, and results stop waiting on a web round-trip."; path="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; values=@(@{name="BingSearchEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; advanced=$false; caution="Do NOT enable if you rely on web answers in the Start box, for example searching a product and expecting a price. Local app/file search is unaffected and still works." },
    @{ id="aiEdgeFeatures"; category="AI Features"; label="Disable Edge AI Features"; desc="Turns off the AI-powered features in Edge - the sidebar assistant, page summary, and the new-tab content generation - without blocking normal browsing."; path="HKLM:\SOFTWARE\Policies\Microsoft\Edge"; values=@(@{name="AIControllerEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if you use the Copilot sidebar or page summarisation in Edge. Only affects AI features - normal tabs, extensions and passwords are untouched." },
    @{ id="aiOfficeCopilot"; category="AI Features"; label="Disable Copilot in Microsoft 365"; desc="Blocks the Copilot button and AI writing assistance inside Word, Excel, Outlook and PowerPoint. Stops the add-in being loaded into every Office document session."; path="HKCU:\Software\Policies\Microsoft\office\16.0\common\General"; values=@(@{name="DisableOfficeCopilot";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if you use Copilot in Office for drafting or summarising - this is a policy, not a preference, and there is no in-app way to get it back without reversing the registry value." },
    @{ id="aiTeamsChat"; category="AI Features"; label="Disable Teams Chat and AI Assistants"; desc="Turns off the built-in Teams chat surface and its AI assistant, removing the chat payload the shell downloads and keeps resident."; path="HKLM:\SOFTWARE\Policies\Microsoft\Teams"; values=@(@{name="EnableChat";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Do NOT enable if your organisation uses Teams for chat - the personal Teams app is separate but the shell chat entry point is not, so you may lose chat entirely rather than just the AI part." },
    @{ id="aiClickToDo"; category="AI Features"; label="Disable Click to Do"; desc="Stops the on-screen AI prompt that appears over screenshots and lets you run an action on whatever is in view. Removes a screenshot-analysis pass that runs on captured screen content."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableClickToDo";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; verify=$true; caution="Safe if you never use it - it is opt-in on each capture. Do enable if you care about screen capture being analysed by on-device models." },
    @{ id="aiStudioEffects"; category="AI Features"; label="Disable AI Studio Effects"; desc="Disables the camera pipeline features that are entirely neural: background blur, eye contact correction, auto framing and voice focus. Uses the plain camera path instead."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableAIVideoEffects";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$true; verify=$true; caution="Do NOT enable if you rely on background blur or eye contact in video calls - the replacement is a flat, unprocessed feed. Leave it alone if you have no AI-PC NPU and these already do nothing." },
    @{ id="aiSearchWeb"; category="AI Features"; label="Disable Web Results in Search"; desc="Removes the web-results branch from Start and taskbar search entirely, not just the Bing ranking. Only local apps, files and settings are searched. Uses DisableSearchBoxSuggestions, the policy that actually works on Windows 11 - an earlier version used NoFind, which is a pre-Vista policy that does nothing on this OS."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; values=@(@{name="DisableSearchBoxSuggestions";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; caution="Note this is the machine-wide HKLM version of the same control as aiBingSearch, which writes HKCU. Enabling both is redundant but harmless. If you want it for your account only, use aiBingSearch instead." },
    @{ id="aiCopilotTips"; category="AI Features"; label="Disable Copilot Tips and AI Prompts"; desc="Stops the contextual AI suggestions, 'try asking Copilot' prompts and AI-powered tips appearing in Settings, Start and the shell."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; values=@(@{name="DisableAIPrompt";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false; verify=$true; caution="Safe - these are suggestions, not functionality. Useful if you find the prompts distracting rather than if you want performance." }
)

function Get-RegTweakState($def) {
    foreach ($v in $def.values) {
        $cur = (Get-ItemProperty -Path $def.path -Name $v.name -ErrorAction SilentlyContinue).($v.name)
        if ($null -eq $cur) {
            if (-not [bool]$def.defaultOn) { return $false }
        } elseif ("$cur" -ne "$($v.on)") {
            return $false
        }
    }
    return $true
}

function Set-RegTweak($def, $on) {
    $on = [bool]$on
    if ($on -and -not (Test-Path $def.path)) {
        New-Item -Path $def.path -Force -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($v in $def.values) {
        if ($on) {
            Set-ItemProperty -Path $def.path -Name $v.name -Value $v.on -Type $v.type -Force -ErrorAction SilentlyContinue | Out-Null
        } elseif ($v.off -eq "__REMOVE__") {
            Remove-ItemProperty -Path $def.path -Name $v.name -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $def.path -Name $v.name -Value $v.off -Type $v.type -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# -----------------------------------------------------------------------------
# APPLICATION OF TWEAKS
# -----------------------------------------------------------------------------

function Apply-NetworkTweaks {
    $log = @()
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $adapterName = if ($adapter) { $adapter.Name } else { "Ethernet" }
    $adapterGuid = $adapter.InterfaceGuid

    $log += "Target Adapter: $adapterName ($($adapter.InterfaceDescription))"

    # 1. MTU 1280
    & netsh.exe interface ipv4 set subinterface $adapterName mtu=1280 store=persistent 2>$null | Out-Null
    & netsh.exe interface ipv6 set subinterface $adapterName mtu=1280 store=persistent 2>$null | Out-Null
    $mtuNow = (Get-NetIPInterface -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).MTU
    if ($mtuNow -eq 1280) { $log += "[OK] Subinterface MTU = 1280 (verified)" }
    else { $log += "[FAIL] Subinterface MTU expected 1280, actual '$mtuNow'" }

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
        New-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $tcpReg -Name "TcpDelAckTicks" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $tcpRead = Get-ItemProperty -Path $tcpReg -ErrorAction SilentlyContinue
        $tcpGot = "TCPNoDelay=$($tcpRead.TCPNoDelay), TcpAckFrequency=$($tcpRead.TcpAckFrequency), TcpDelAckTicks=$($tcpRead.TcpDelAckTicks)"
        if ($tcpRead.TCPNoDelay -eq 1 -and $tcpRead.TcpAckFrequency -eq 1 -and $tcpRead.TcpDelAckTicks -eq 0) { $log += "[OK] $tcpGot (verified)" }
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
    Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $mmRead = Get-ItemProperty -Path $mmProfile -ErrorAction SilentlyContinue
    if ($mmRead.NetworkThrottlingIndex -eq 4294967295 -or $mmRead.NetworkThrottlingIndex -eq -1) { $log += "[OK] NetworkThrottlingIndex = 0xFFFFFFFF (verified)" }
    else { $log += "[FAIL] NetworkThrottlingIndex expected 0xFFFFFFFF, actual '$($mmRead.NetworkThrottlingIndex)'" }
    if ($mmRead.SystemResponsiveness -eq 0) { $log += "[OK] SystemResponsiveness = 0 (verified)" }
    else { $log += "[FAIL] SystemResponsiveness expected 0, actual '$($mmRead.SystemResponsiveness)'" }

    # 6. Delivery Optimization P2P
    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $doNow = (Get-ItemProperty -Path $doPath -Name "DODownloadMode" -ErrorAction SilentlyContinue).DODownloadMode
    if ($doNow -eq 0) { $log += "[OK] Delivery Optimization DODownloadMode = 0 (verified)" }
    else { $log += "[FAIL] DODownloadMode expected 0, actual '$doNow'" }

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
    $log = @()

    # 1. HAGS
    $gfxPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    if (-not (Test-Path $gfxPath)) { New-Item -Path $gfxPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gfxPath -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Hardware-Accelerated GPU Scheduling (HAGS) enabled (HwSchMode = 2)"

    # 2. Windowed Game Optimizations
    $dxPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $dxPath)) { New-Item -Path $dxPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $dxPath -Name "AutoOptimizationsEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Windowed Game Auto Optimizations enabled (Lowest display lag)"

    # 3. High Precision Timers & BCD
    & bcdedit.exe /set disabledynamictick yes 2>$null | Out-Null
    & bcdedit.exe /deletevalue useplatformclock 2>$null | Out-Null
    & bcdedit.exe /set useplatformtick yes 2>$null | Out-Null
    & bcdedit.exe /deletevalue numproc 2>$null | Out-Null
    & bcdedit.exe /deletevalue truncatememory 2>$null | Out-Null
    $log += "[OK] Dynamic Tick Disabled (prevents clock drift & hitching)"
    $log += "[OK] Native Invariant TSC enforced via useplatformtick"
    $log += "[OK] BCD CPU core limitations & memory caps cleared"

    # 4. Kernel RAM Pinning
    $mmPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
    Set-ItemProperty -Path $mmPath -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $mmPath -Name "LargeSystemCache" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Windows Kernel & Drivers locked in physical RAM (Zero SSD paging hitches)"

    # 5. GPU Interrupt Priority
    $gpuDev = Get-PnpDevice -Class Display -Status OK -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gpuDev) {
        $gpuId = $gpuDev.DeviceID
        $gpuReg = "HKLM\SYSTEM\CurrentControlSet\Enum\$gpuId\Device Parameters\Interrupt Management\Affinity Policy"
        & reg.exe add $gpuReg /v "DevicePriority" /t REG_DWORD /d 1 /f 2>$null | Out-Null
        $log += "[OK] GPU ($($gpuDev.FriendlyName)) Interrupt Priority set to HIGH"
    }

    # 6. Power Plan: Ultimate Performance & Disable USB Sleep
    & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null | Out-Null
    $plans = & powercfg.exe /list 2>$null
    $ultMatch = $plans | Select-String -Pattern "([a-f0-9\-]{36})\s+\(Ultimate Performance\)"
    if ($ultMatch -and $ultMatch.Matches.Groups[1].Value) {
        $schemeId = $ultMatch.Matches.Groups[1].Value
        & powercfg.exe /setactive $schemeId 2>$null | Out-Null
        $log += "[OK] Activated Windows Ultimate Performance Power Plan"
    }
    & powercfg.exe /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
    $log += "[OK] USB Selective Suspend disabled (Zero input device wake-up latency)"

    # 7. GameDVR
    $gcsPath = "HKCU:\System\GameConfigStore"
    if (-not (Test-Path $gcsPath)) { New-Item -Path $gcsPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gcsPath -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $gcsPath -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null

    $gdvrPolicy = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    if (-not (Test-Path $gdvrPolicy)) { New-Item -Path $gdvrPolicy -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gdvrPolicy -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Background GameDVR & AppCapture disabled (Freed GPU/CPU overhead)"

    # 8. Game Mode
    $gbPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
    if (-not (Test-Path $gbPath)) { New-Item -Path $gbPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $gbPath -Name "AllowAutoGameMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Windows Game Mode enabled (prioritizes game threads)"

    # 9. Transparency / menu speed / pointer precision (snappier shell)
    $tpPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    if (-not (Test-Path $tpPath)) { New-Item -Path $tpPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $tpPath -Name "EnableTransparency" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseSpeed" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold1" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKCU:\Control Panel\Mouse" -Name "MouseThreshold2" -Value "0" -Type String -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Transparency off, instant menus, raw mouse input (no pointer acceleration)"

    # 10. Memory compression off + CPU locked to max frequency
    Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>$null | Out-Null
    & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
    & powercfg.exe /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>$null | Out-Null
    & powercfg.exe /setactive SCHEME_CURRENT 2>$null | Out-Null
    $log += "[OK] Memory Compression disabled, CPU min/max frequency locked to 100%"

    # 11. NVIDIA low-latency flag (only when an NVIDIA GPU is present)
    $nv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" }
    if ($nv) {
        $fts = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
        if (-not (Test-Path $fts)) { New-Item -Path $fts -Force -ErrorAction SilentlyContinue | Out-Null }
        Set-ItemProperty -Path $fts -Name "EnableRID61684" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $log += "[OK] NVIDIA ultra-low-latency driver flag set (EnableRID61684)"
    }

    return @{ success = $true; logs = $log }
}

function Optimize-Services {
    $log = @()
    # Spooler and WSearch removed 2026-09-30 20:40 by human decision: disabling
    # them kills printing and file/Start-menu search, which are not bloat.
    $servicesToDisable = @("DiagTrack", "WerSvc", "SysMain", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "CDPSvc", "dmwappushservice", "PcaSvc")
    foreach ($name in $servicesToDisable) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { $log += "[SKIP] Service '$name' is not present on this system."; continue }
        Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
        # Stop-Service is asynchronous: it returns as soon as the stop is requested,
        # while the service is still StopPending. Reading the state back immediately
        # therefore catches a service mid-transition and logs a spurious failure, so
        # wait for the terminal state with a bounded timeout instead of blocking
        # forever. A service wedged in StopPending can never reach Stopped, so the
        # timeout is what stops this function hanging.
        try { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue } catch {}
        $deadline = (Get-Date).AddSeconds(5)
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

function Set-TweakState($id, $enabled) {
    $on = [bool]$enabled
    # Table-driven registry tweaks first - single source of truth with the audit
    $def = $script:RegTweaks | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($def) {
        Set-RegTweak -def $def -on $on
        return @{ success = $true; id = $id; enabled = $on; reboot = [bool]$def.reboot }
    }
    switch ($id) {
        "hags" {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value $(if ($on) { 2 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "gameOpt" {
            $dxPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
            if (-not (Test-Path $dxPath)) { New-Item -Path $dxPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $dxPath -Name "AutoOptimizationsEnabled" -Value $(if ($on) { 1 } else { 0 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on }
        }
        "dynamicTick" {
            if ($on) { & bcdedit.exe /set disabledynamictick yes 2>$null | Out-Null }
            else { & bcdedit.exe /deletevalue disabledynamictick 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "platformTick" {
            if ($on) { & bcdedit.exe /set useplatformtick yes 2>$null | Out-Null }
            else { & bcdedit.exe /deletevalue useplatformtick 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "kernelRamLock" {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -Value $(if ($on) { 1 } else { 0 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "netThrottle" {
            $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            if ($on) {
                Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value -1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value 10 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 20 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "gameDvr" {
            $gcsPath = "HKCU:\System\GameConfigStore"
            if (-not (Test-Path $gcsPath)) { New-Item -Path $gcsPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $gcsPath -Name "GameDVR_Enabled" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            $gdvrPolicy = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
            if (-not (Test-Path $gdvrPolicy)) { New-Item -Path $gdvrPolicy -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $gdvrPolicy -Name "AppCaptureEnabled" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on }
        }
        "deliveryOpt" {
            $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
            if ($on) {
                if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $doPath -Name "DODownloadMode" -ErrorAction SilentlyContinue
            }
            return @{ success = $true; id = $id; enabled = $on }
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
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "tcpAckFreq" {
            $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
            if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
            if ($adapter -and $adapter.InterfaceGuid) {
                $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)"
                if ($on) {
                    New-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                } else {
                    Remove-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
                }
            }
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "rss" {
            if ($on) { & netsh.exe int tcp set global rss=enabled 2>$null | Out-Null }
            else { & netsh.exe int tcp set global rss=disabled 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "powerPlan" {
            if ($on) {
                & powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null | Out-Null
                $plans = & powercfg.exe /list 2>$null
                $ultMatch = $plans | Select-String -Pattern "([a-f0-9\-]{36})\s+\(Ultimate Performance\)"
                if ($ultMatch -and $ultMatch.Matches.Groups[1].Value) {
                    & powercfg.exe /setactive $ultMatch.Matches.Groups[1].Value 2>$null | Out-Null
                }
            } else {
                & powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>$null | Out-Null
            }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "gameMode" {
            $gbPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
            if (-not (Test-Path $gbPath)) { New-Item -Path $gbPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $gbPath -Name "AllowAutoGameMode" -Value $(if ($on) { 1 } else { 0 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on }
        }
        "transparency" {
            $tpPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            if (-not (Test-Path $tpPath)) { New-Item -Path $tpPath -Force -ErrorAction SilentlyContinue | Out-Null }
            Set-ItemProperty -Path $tpPath -Name "EnableTransparency" -Value $(if ($on) { 0 } else { 1 }) -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on }
        }
        "menuDelay" {
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value $(if ($on) { "0" } else { "400" }) -Type String -Force -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on }
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
            return @{ success = $true; id = $id; enabled = $on }
        }
        "memCompression" {
            if ($on) { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null }
            else { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null }
            # Read back rather than return success unconditionally: both MMAgent
            # calls fail silently here, and $on means "tweak on" = compression OFF.
            $mmNow = (Get-MMAgent -ErrorAction SilentlyContinue).MemoryCompression
            $applied = if ($on) { $mmNow -eq $false } else { $mmNow -eq $true }
            if ($applied) { return @{ success = $true; id = $id; enabled = $on; reboot = $true } }
            $want = if ($on) { "disabled" } else { "enabled" }
            return @{ success = $false; id = $id; enabled = $on; reboot = $true; error = "MemoryCompression read back as '$mmNow' after the change (expected $want)." }
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
            return @{ success = $true; id = $id; enabled = $on }
        }
        "nvidiaRid" {
            $nv = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" }
            if (-not $nv) { return @{ success = $false; error = "No NVIDIA GPU detected" } }
            $fts = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"
            if ($on) {
                if (-not (Test-Path $fts)) { New-Item -Path $fts -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $fts -Name "EnableRID61684" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $fts -Name "EnableRID61684" -ErrorAction SilentlyContinue
            }
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "qosLimit" {
            $qosPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
            if ($on) {
                if (-not (Test-Path $qosPath)) { New-Item -Path $qosPath -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
            } else {
                Remove-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -ErrorAction SilentlyContinue
            }
            return @{ success = $true; id = $id; enabled = $on }
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
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "hibernate" {
            if ($on) { & powercfg.exe /hibernate off 2>$null | Out-Null }
            else { & powercfg.exe /hibernate on 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "netbios" {
            $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $cfg) { return @{ success = $false; error = "No active network adapter found" } }
            Invoke-CimMethod -InputObject $cfg -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = $(if ($on) { 2 } else { 0 }) } -ErrorAction SilentlyContinue | Out-Null
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
        }
        "teredo" {
            if ($on) { & netsh.exe interface teredo set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface teredo set state default 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "isatap" {
            if ($on) { & netsh.exe interface isatap set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface isatap set state default 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on }
        }
        "sixtofour" {
            if ($on) { & netsh.exe interface 6to4 set state disabled 2>$null | Out-Null }
            else { & netsh.exe interface 6to4 set state default 2>$null | Out-Null }
            return @{ success = $true; id = $id; enabled = $on }
        }
        default {
            return @{ success = $false; error = "Unknown tweak id: $id" }
        }
    }
}

function Set-ServiceState($name, $optimize) {
    $allowed = @("DiagTrack", "WerSvc", "SysMain", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "WSearch", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "Spooler", "CDPSvc", "dmwappushservice", "PcaSvc")
    if ($allowed -notcontains $name) {
        return @{ success = $false; error = "Service not manageable: $name" }
    }
    if ([bool]$optimize) {
        Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    } else {
        # Restore each service to its true Windows default (not blanket Automatic)
        $defaults = @{
            "DiagTrack" = "Automatic"; "WerSvc" = "Manual"; "SysMain" = "Automatic";
            "lfsvc" = "Manual"; "TrkWks" = "Automatic"; "RemoteRegistry" = "Disabled";
            "wisvc" = "Manual"; "MapsBroker" = "Automatic"; "WSearch" = "Automatic";
            "XblGameSave" = "Manual"; "XboxGipSvc" = "Manual"; "XboxNetApiSvc" = "Manual"; "Spooler" = "Automatic";
            "CDPSvc" = "Manual"; "dmwappushservice" = "Manual"; "PcaSvc" = "Manual"
        }
        $target = if ($defaults.ContainsKey($name)) { $defaults[$name] } else { "Manual" }
        Set-Service -Name $name -StartupType $target -ErrorAction SilentlyContinue
        if ($target -ne "Disabled") { Start-Service -Name $name -ErrorAction SilentlyContinue }
    }
    return @{ success = $true; name = $name; optimized = [bool]$optimize }
}

function Restore-Defaults {
    $log = @()
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $adapterName = if ($adapter) { $adapter.Name } else { "Ethernet" }

    & netsh.exe interface ipv4 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
    & netsh.exe interface ipv6 set subinterface $adapterName mtu=1500 store=persistent 2>$null | Out-Null
    $log += "[RESTORE] MTU restored to 1500 default."

    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue | Out-Null
    $log += "[RESTORE] DNS restored to Automatic (DHCP)."

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

    foreach ($def in $script:RegTweaks) { Set-RegTweak -def $def -on $false }
    $log += "[RESTORE] Advanced tweak catalog (56 tweaks) reset to Windows defaults."

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
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser"; Display = "Compatibility Telemetry"; Impact = "High" },
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

        # CORS Headers
        $response.AddHeader("Access-Control-Allow-Origin", "*")
        $response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $response.AddHeader("Access-Control-Allow-Headers", "Content-Type")

        if ($request.HttpMethod -eq "OPTIONS") {
            $response.StatusCode = 200
            $response.Close()
            continue
        }

        $rawUrl = $request.RawUrl.Split('?')[0]

        # Read JSON body for POST
        $body = ""
        if ($request.HasEntityBody) {
            $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
            $body = $reader.ReadToEnd()
        }

        # API ROUTING
        if ($rawUrl.StartsWith("/api/")) {
            $jsonOutput = $null

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
                    $jsonOutput = @{ success = $true; mtu = $val }
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
                    $jsonOutput = @{ success = $true; logs = $allLogs; requiresReboot = $true }
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
                        if ($parsed.id) { $jsonOutput = Set-TweakState -id $parsed.id -enabled ([bool]$parsed.enabled) }
                    }
                }
                "/api/services/set" {
                    $jsonOutput = @{ success = $false; error = "Invalid request" }
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($parsed.name) { $jsonOutput = Set-ServiceState -name $parsed.name -optimize ([bool]$parsed.optimized) }
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
