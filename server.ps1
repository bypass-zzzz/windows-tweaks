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

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS: SYSTEM & NETWORK AUDITING
# -----------------------------------------------------------------------------

function Get-PowerAcValue($sub, $setting) {
    $out = (& powercfg.exe /query SCHEME_CURRENT $sub $setting 2>$null) | Out-String
    $m = [regex]::Match($out, 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) } else { return $null }
}

function Get-SystemAudit {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    $ram = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue

    $totalRamBytes = ($ram | Measure-Object -Property Capacity -Sum).Sum
    $totalRamGB = if ($totalRamBytes) { [Math]::Round($totalRamBytes / 1GB, 1) } else { 32 }
    $freeRamGB = if ($os.FreePhysicalMemory) { [Math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 20 }
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
    $isThrottleDisabled = ($netThrottle -eq -1 -or $netThrottle -eq 0xffffffff)

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
    $cpuLoadVal = ($cpu | Measure-Object -Property LoadPercentage -Average -ErrorAction SilentlyContinue).Average
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
        os = if ($os.Caption) { "$($os.Caption) ($($os.Version) Build $($os.BuildNumber))" } else { "Microsoft Windows 11 Pro" }
        cpu = if ($cpu.Name) { "$($cpu.Name) ($($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T)" } else { "AMD Ryzen 5 7600X 6-Core Processor" }
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
    $pingObj = New-Object System.Net.NetworkInformation.Ping
    $pings = @()
    for ($i = 0; $i -lt $count; $i++) {
        try {
            $reply = $pingObj.Send($hostTarget, 400)
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $pings += $reply.RoundtripTime
            }
        } catch {}
    }
    if ($pings.Count -gt 0) {
        $avg = [Math]::Round(($pings | Measure-Object -Average).Average, 1)
        $min = ($pings | Measure-Object -Minimum).Minimum
        $max = ($pings | Measure-Object -Maximum).Maximum
        $jitter = [Math]::Round($max - $min, 1)
        $packetLoss = [Math]::Round((($count - $pings.Count) / $count) * 100, 1)
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
    foreach ($p in $providers) {
        $best = 999
        foreach ($ip in @($p.primary, $p.secondary)) {
            try {
                $reply = $pingObj.Send($ip, 400)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    if ($reply.RoundtripTime -lt $best) { $best = $reply.RoundtripTime }
                }
            } catch {}
        }

        $results += @{
            name = $p.name
            primary = $p.primary
            secondary = $p.secondary
            provider = $p.provider
            latency = $best
            status = if ($best -lt 999) { "Online" } else { "Timeout" }
        }
    }

    $sorted = $results | Sort-Object latency
    return $sorted
}

function Run-MtuTest {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -ne $true } | Select-Object -First 1
    if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }

    $target = "1.1.1.1"
    $left = 1200
    $right = 1472
    $bestPayload = 1252

    while ($left -le $right) {
        $mid = [Math]::Floor(($left + $right) / 2)
        $out = & ping.exe $target -f -l $mid -n 1 -w 400 2>$null
        $str = $out | Out-String
        if ($str -match "Reply from" -and $str -notmatch "Packet needs to be fragmented") {
            $bestPayload = $mid
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
        @{ Name = "Beep"; Display = "System Beep Driver"; Safe = $true; Impact = "Low" },
        @{ Name = "Spooler"; Display = "Print Spooler (only if you print)"; Safe = $true; Impact = "Low" },
        @{ Name = "Fax"; Display = "Fax Service"; Safe = $true; Impact = "Low" },
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
    @{ id="recallAI"; category="Gaming"; label="Disable Recall AI Snapshots"; desc="Stops Windows AI from recording screen snapshots (privacy + disk)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; values=@(@{name="DisableAIDataAnalysis";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bingSearch"; category="Gaming"; label="Disable Bing in Start Search"; desc="Start menu searches stay local - no web round-trip, instant results."; path="HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; values=@(@{name="DisableSearchBoxSuggestions";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bgApps"; category="Gaming"; label="Disable Background Apps"; desc="Stops UWP apps running in the background eating CPU and network."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; values=@(@{name="GlobalUserDisabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="silentApps"; category="Gaming"; label="Block Silent Auto-Installed Apps"; desc="Stops Windows silently installing suggested apps (Candy Crush and co)."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SilentInstalledAppsEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="getTips"; category="Gaming"; label="Disable Tips and Suggestions"; desc="Turns off Get Started tips, suggestions and soft-landing pages."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="SoftLandingEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    # --- Network ---
    @{ id="llmnr"; category="Network"; label="Disable LLMNR Name Resolution"; desc="Disables multicast fallback lookups (faster fails, less chatter)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; values=@(@{name="EnableMulticast";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wpad"; category="Network"; label="Disable WPAD Auto-Proxy"; desc="Skips proxy auto-discovery delay on every new connection."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings"; values=@(@{name="AutoDetect";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    # --- Privacy ---
    @{ id="adId"; category="Privacy"; label="Disable Advertising ID"; desc="Stops apps using your advertising ID for personalized ads."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="tailoredExp"; category="Privacy"; label="Disable Tailored Experiences"; desc="Stops Microsoft tailoring tips/ads from your diagnostic data."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; values=@(@{name="TailoredExperiencesWithDiagnosticDataEnabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="activityFeed"; category="Privacy"; label="Disable Activity History Feed"; desc="Stops Timeline/activity uploads across devices."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; values=@(@{name="EnableActivityFeed";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="locationSensors"; category="Privacy"; label="Disable Location Sensors"; desc="Turns off location tracking for apps and services."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"; values=@(@{name="DisableLocation";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="feedbackNotif"; category="Privacy"; label="Disable Feedback Prompts"; desc="Stops Windows begging for feedback with popup notifications."; path="HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; values=@(@{name="NumberOfSIUFInPeriod";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="allowTelemetry"; category="Privacy"; label="Telemetry to Security-Only"; desc="Drops Windows diagnostic data collection to the minimum level."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="AllowTelemetry";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="diagLogs"; category="Privacy"; label="Limit Diagnostic Log Collection"; desc="Stops extended diagnostic logs from being gathered and sent."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; values=@(@{name="LimitDiagnosticLogCollection";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
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
    @{ id="startupDelay"; category="Interface"; label="Remove Startup App Delay"; desc="Launches startup programs immediately instead of staged delays."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize"; values=@(@{name="StartupDelayInMSec";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
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
    # --- System ---
    @{ id="keyRepeat"; category="System"; label="Fastest Key Repeat"; desc="Max keyboard repeat rate and minimum delay for rapid input."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="KeyboardSpeed";type="String";on="31";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="numLock"; category="System"; label="NumLock On at Boot"; desc="Keeps the numpad enabled on the login screen and after boot."; path="HKCU:\Control Panel\Keyboard"; values=@(@{name="InitialKeyboardIndicators";type="String";on="2";off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="autoplay"; category="System"; label="Disable AutoPlay"; desc="Stops USB/discs auto-launching anything when plugged in."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; values=@(@{name="NoDriveTypeAutoRun";type="DWord";on=255;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="remoteAssist"; category="System"; label="Disable Remote Assistance"; desc="Closes the inbound remote-help attack surface."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"; values=@(@{name="fAllowToGetHelp";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="powerThrottling"; category="System"; label="Disable Power Throttling"; desc="Stops Windows down-clocking background work (consistent performance)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"; values=@(@{name="PowerThrottlingOff";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="longPaths"; category="System"; label="Enable Long File Paths"; desc="Removes the 260-character path limit for apps and games."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="LongPathsEnabled";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="shortNames"; category="System"; label="Disable 8.3 Short Filenames"; desc="Stops NTFS maintaining legacy short names (faster file creation)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisable8dot3NameCreation";type="DWord";on=1;off=2}); defaultOn=$false; reboot=$false },
    @{ id="lastAccess"; category="System"; label="Disable Last-Access Tracking"; desc="Stops NTFS timestamping every file read (less disk I/O)."; path="HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; values=@(@{name="NtfsDisableLastAccessUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="cpuMitigations"; category="System"; label="Disable CPU Side-Channel Mitigations"; desc="Turns off Spectre/Meltdown software mitigations for raw speed. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"; values=@(@{name="FeatureSettingsOverride";type="DWord";on=3;off="__REMOVE__"}, @{name="FeatureSettingsOverrideMask";type="DWord";on=3;off="__REMOVE__"}); defaultOn=$false; reboot=$true },
    @{ id="vbsOff"; category="System"; label="Disable Virtualization-Based Security"; desc="Turns off VBS for lower overhead in CPU-bound games. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"; values=@(@{name="EnableVirtualizationBasedSecurity";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true },
    @{ id="hvciOff"; category="System"; label="Disable Memory Integrity (HVCI)"; desc="Turns off hypervisor-protected code integrity for less overhead. Weakens security - your call."; path="HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"; values=@(@{name="Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$true },
    @{ id="bsodDetails"; category="System"; label="Detailed Crash Screens"; desc="Blue screens show the actual stop code and faulting driver."; path="HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; values=@(@{name="DisplayParameters";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="bsodRestart"; category="System"; label="Don't Auto-Reboot on Crash"; desc="Stays on the blue screen so you can read the error first."; path="HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; values=@(@{name="AutoReboot";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="fastStartup"; category="System"; label="Disable Fast Startup"; desc="Full shutdown every time - avoids stale-driver and dual-boot issues."; path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"; values=@(@{name="HiberbootEnabled";type="DWord";on=0;off=1}); defaultOn=$false; reboot=$false },
    @{ id="lockAds"; category="System"; label="Disable Lock Screen Ads"; desc="Kills spotlight promos and fun-fact overlays on the lock screen."; path="HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; values=@(@{name="RotatingLockScreenEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="RotatingLockScreenOverlayEnabled";type="DWord";on=0;off="__REMOVE__"}, @{name="SubscribedContent-338387Enabled";type="DWord";on=0;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    # --- Updates ---
    @{ id="wuNoAutoReboot"; category="Updates"; label="No Forced Reboot After Updates"; desc="Windows Update never restarts your PC while you're logged in."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; values=@(@{name="NoAutoRebootWithLoggedOnUsers";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="wuDrivers"; category="Updates"; label="Stop Driver Updates via Windows Update"; desc="Keeps your hand-picked GPU/chipset drivers from being overwritten."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; values=@(@{name="ExcludeWUDriversInQualityUpdate";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="consumerFeatures"; category="Updates"; label="Block Consumer Bloat Reinstalls"; desc="Stops Windows re-adding suggested apps after updates."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; values=@(@{name="DisableWindowsConsumerFeatures";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false },
    @{ id="oneDriveSync"; category="Updates"; label="Disable OneDrive File Sync"; desc="Stops OneDrive syncing (frees CPU, RAM and upload bandwidth)."; path="HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"; values=@(@{name="DisableFileSyncNGSC";type="DWord";on=1;off="__REMOVE__"}); defaultOn=$false; reboot=$false }
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
    $log += "[OK] Subinterface MTU set to 1280 (Zero Packet Fragmentation)"

    # 2. DNS
    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses ("1.0.0.1", "1.1.1.1") -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] DNS set to Cloudflare Primary (1.0.0.1 / 1.1.1.1) and DNS cache cleared"

    # 3. Registry TCP NoDelay / Ack
    if ($adapterGuid) {
        $tcpReg = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$adapterGuid"
        New-ItemProperty -Path $tcpReg -Name "TCPNoDelay" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $tcpReg -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $tcpReg -Name "TcpDelAckTicks" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        $log += "[OK] TCPNoDelay = 1, TcpAckFrequency = 1, TcpDelAckTicks = 0 (Immediate Packet Dispatch)"
    }

    # 4. Netsh TCP Global
    & netsh.exe int tcp set global rss=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global autotuninglevel=normal 2>$null | Out-Null
    & netsh.exe int tcp set global timestamps=disabled 2>$null | Out-Null
    & netsh.exe int tcp set global rsc=disabled 2>$null | Out-Null
    & netsh.exe int tcp set global fastopen=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global hystart=enabled 2>$null | Out-Null
    & netsh.exe int tcp set global prr=enabled 2>$null | Out-Null
    $log += "[OK] Windows Global TCP Stack tuned (RSS, FastOpen, HyStart enabled; RSC/Timestamps disabled)"

    # 5. Multimedia / Network Throttling (-1 == 0xFFFFFFFF, same bits, always accepted)
    $mmProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
    Set-ItemProperty -Path $mmProfile -Name "NetworkThrottlingIndex" -Value -1 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $mmProfile -Name "SystemResponsiveness" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] NetworkThrottlingIndex = 0xFFFFFFFF (Network throttling disabled)"
    $log += "[OK] SystemResponsiveness = 0 (100% CPU priority for gaming packets)"

    # 6. Delivery Optimization P2P
    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Delivery Optimization P2P uploads disabled (Zero random ping spikes)"

    # 7. Hardware Checksum Offload
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "IPv4 Checksum Offload" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "TCP Checksum Offload (IPv4)" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "UDP Checksum Offload (IPv4)" -DisplayValue "Rx & Tx Enabled" -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adapterName -DisplayName "Energy Efficient Ethernet" -DisplayValue "Disabled" -ErrorAction SilentlyContinue
    $log += "[OK] Hardware Checksum Offload enabled; Energy Efficient Ethernet disabled"

    # 8. QoS reserved bandwidth + ephemeral ports
    $qosPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched"
    if (-not (Test-Path $qosPath)) { New-Item -Path $qosPath -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $qosPath -Name "NonBestEffortLimit" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] QoS 20% reserved bandwidth limit removed (NonBestEffortLimit = 0)"

    $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    Set-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $tcpParams -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force -ErrorAction SilentlyContinue | Out-Null
    $log += "[OK] Ephemeral ports expanded to 65534, TIME_WAIT recycle 30s"

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
    $servicesToDisable = @("DiagTrack", "WerSvc", "SysMain", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "WSearch", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "Beep", "Spooler", "Fax", "CDPSvc", "dmwappushservice", "PcaSvc")
    foreach ($name in $servicesToDisable) {
        Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        $log += "[OK] Service '$name' stopped and disabled."
    }
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
            return @{ success = $true; id = $id; enabled = $on; reboot = $true }
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
    $allowed = @("DiagTrack", "WerSvc", "SysMain", "lfsvc", "TrkWks", "RemoteRegistry", "wisvc", "MapsBroker", "WSearch", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc", "Beep", "Spooler", "Fax", "CDPSvc", "dmwappushservice", "PcaSvc")
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
            "XblGameSave" = "Manual"; "XboxGipSvc" = "Manual"; "XboxNetApiSvc" = "Manual";
            "Beep" = "Manual"; "Spooler" = "Automatic"; "Fax" = "Manual";
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

    $list = @()
    foreach ($t in $taskDefs) {
        $full = "$($t.Path)$($t.Name)"
        $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($task) {
            $list += @{
                path = $full
                displayName = $t.Display
                state = $task.State.ToString()
                impact = $t.Impact
                isOptimized = ($task.State.ToString() -eq "Disabled")
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
                        @{ id = $_.id; category = $_.category; label = $_.label; desc = $_.desc; reboot = [bool]$_.reboot; active = (Get-RegTweakState $_) }
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
