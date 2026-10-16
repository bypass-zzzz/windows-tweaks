#Requires -Version 5.1
<#
.SYNOPSIS
    Audits the read-only list endpoints against independent machine truth.

.DESCRIPTION
    /api/services, /api/tasks and /api/startup are the app's window onto real
    machine state: a row that disagrees with the registry, the SCM, the task
    scheduler or the Run keys is a lie the UI tells with a straight face.
    This tool launches a -DryRun backend on a scratch port, fetches the three
    lists, and re-derives every reported field from an independent source:

      services  startType  vs the registry Start DWORD (2/3/4 = Auto/Manual/Disabled)
                status     vs Get-Service (SCM), whitespace/case-normalised
                isOptimized vs (startType -eq 'Disabled')
      tasks     state      vs Get-ScheduledTask (the scheduler's own API)
                isOptimized vs state -eq 'Disabled', with NotFound counting as
                            optimized - that is the UI's intended semantics
      startup   no invented rows (every row maps back to a Run value, a
                Startup-folder file, or a Win32_StartupCommand entry),
                no dropped rows (every source entry the design promises to
                list is listed), enabled flags vs the StartupApproved rule,
                and no duplicate (location, name) pairs.

    It also re-proves the dry-run interception mechanism on the write path:
    a blocked registry write must surface as a `What if:` line on the
    backend's stdout (that channel is by design, see test-endpoints-dryrun).

    This tool exists because it earns its keep: the first run found
    "Microsoft Compatibility Appraiser" reported as NotFound on builds where
    the task was renamed to "Microsoft Compatibility Appraiser Exp".

    SAFETY: the only request that would mutate anything is the read-back
    probe, which deliberately posts the OPPOSITE of the current HAGS state.
    It is gated on the backend's "DRY RUN ACTIVE" banner appearing in stdout
    first, so it cannot run against a live instance. Everything else is GET.

.PARAMETER Port
    Scratch port for the dry-run backend. Must be free. Default 48946.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-list-truth.ps1
#>
param([int]$Port = 48946)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $repoRoot 'server.ps1'
if (-not (Test-Path -LiteralPath $serverScript)) { Write-Error "server.ps1 not found: $serverScript"; exit 1 }
$busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($busy) { Write-Error "Port $Port is already in use - pick another with -Port"; exit 1 }

$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$out = Join-Path $env:TEMP "wt-list-truth-$stamp.out"
$err = Join-Path $env:TEMP "wt-list-truth-$stamp.err"
$blockLog = Join-Path $repoRoot 'dry-run-blocked.log'
$blockLogExisted = Test-Path -LiteralPath $blockLog

$script:pass = 0; $script:fail = 0; $script:skip = 0
$failures = New-Object System.Collections.Generic.List[string]

function Section { param([string]$Title) Write-Host "`n--- $Title ---" -ForegroundColor Cyan }
function Check { param([string]$What, [bool]$Condition, [string]$Detail)
    if ($Condition) { $script:pass++ } else { $script:fail++; $script:failures.Add($What + $(if ($Detail) { " ($Detail)" } else { '' })) }
}
function Read-Shared {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close(); return $t
    } catch { return '' }
}
function Get-ApprovedOff {
    param([string]$Key, [string]$Name)
    $a = (Get-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue).$Name
    return [bool]($a -and $a.Length -gt 0 -and (($a[0] -band 1) -eq 1))
}
function Get-RunValues {
    param([string]$Key)
    $vals = @{}
    if (-not (Test-Path $Key)) { return $vals }
    $props = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
    if (-not $props) { return $vals }
    foreach ($pp in $props.PSObject.Properties) {
        if ($pp.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
        if ([string]::IsNullOrWhiteSpace($pp.Value)) { continue }
        $vals[$pp.Name] = [string]$pp.Value
    }
    return $vals
}

$backend = $null
$token = ''
try {
    Write-Host "Launching dry-run backend on port $Port ..."
    $backend = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serverScript, '-DryRun', '-Port', "$Port", '-NoBrowser' -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(150)
    $dryRunBanner = $false
    while ((Get-Date) -lt $deadline) {
        if ($backend.HasExited) { throw "backend exited early (code $($backend.ExitCode)); stderr: $(Read-Shared $err)" }
        $text = Read-Shared $out
        if ($text -match 'DRY RUN ACTIVE') { $dryRunBanner = $true }
        $m = [regex]::Match($text, '__WT_TOKEN__([A-Za-z0-9+/=]{44})')
        if ($m.Success) { $token = $m.Groups[1].Value; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $token) { throw "no token within deadline; stderr: $(Read-Shared $err)" }
    $hdr = @{ 'X-WT-Token' = $token }

    function Get-Json {
        param([string]$Path)
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port$Path" -Headers $hdr -UseBasicParsing -TimeoutSec 120
        Write-Host ("FETCH {0} -> {1} bytes={2}" -f $Path, $r.StatusCode, $r.Content.Length)
        return ($r.Content | ConvertFrom-Json)
    }

    # ---------------------------------------------------------------- write-path interception
    Section "interception proof (write path)"
    Check "dry-run banner seen before any POST" $dryRunBanner "the backend never printed 'DRY RUN ACTIVE'"
    if (-not $dryRunBanner) { throw "refusing to POST: dry-run banner was never observed" }
    $hwKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $hw = (Get-ItemProperty -Path $hwKey -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    $opp = if ([int]$hw -eq 2) { 'false' } else { 'true' }
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/tweak/set" -Method Post -Headers $hdr `
        -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"id":"hags","enabled":' + $opp + '}')) -UseBasicParsing -TimeoutSec 90
    $parsed = $resp.Content | ConvertFrom-Json
    Check "opposite HAGS write reports blocked" ($parsed.success -eq $false -and $parsed.blocked -eq $true) "response: $($resp.Content)"
    Start-Sleep -Milliseconds 500
    $stdoutText = Read-Shared $out
    $whatIf = @([regex]::Matches($stdoutText, 'What if:')).Count
    Check "interception left a 'What if:' line on stdout" ($whatIf -ge 1) "stdout had $whatIf such lines"
    ($stdoutText -split "`r?`n" | Where-Object { $_ -match 'What if:' } | Select-Object -Last 2) | ForEach-Object { Write-Host "  $_" }
    $hwAfter = (Get-ItemProperty -Path $hwKey -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    Check "HwSchMode unchanged by the blocked write" ("$hw" -eq "$hwAfter") "was '$hw', now '$hwAfter'"

    # ---------------------------------------------------------------- services
    Section "services vs registry + SCM"
    $svcData = @(Get-Json '/api/services')
    Write-Host "rows: $($svcData.Count)"
    $startMap = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Auto'; 3 = 'Manual'; 4 = 'Disabled' }
    foreach ($r in $svcData) {
        $name = [string]$r.name
        $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction SilentlyContinue
        $start = $reg.Start
        if ($null -eq $start) { $script:skip++; continue }
        $trueStart = $startMap[[int]$start]
        Check "svc '$name' startType" (([string]$r.startType) -ieq $trueStart) "reported '$($r.startType)', registry says '$trueStart'"
        $svcObj = Get-Service -Name $name -ErrorAction SilentlyContinue
        $trueStatus = if ($svcObj) { [string]$svcObj.Status } else { 'Missing' }
        Check "svc '$name' status" ((([string]$r.status -replace '\s', '').ToLowerInvariant()) -eq (($trueStatus -replace '\s', '').ToLowerInvariant())) "reported '$($r.status)', SCM says '$trueStatus'"
        Check "svc '$name' isOptimized" ([bool]$r.isOptimized -eq ($trueStart -ieq 'Disabled')) "isOptimized=$($r.isOptimized), start='$trueStart'"
    }

    # ---------------------------------------------------------------- tasks
    Section "tasks vs the task scheduler"
    $taskData = @(Get-Json '/api/tasks')
    Write-Host "rows: $($taskData.Count)"
    foreach ($r in $taskData) {
        $full = [string]$r.path
        $sep = $full.LastIndexOf('\')
        $tp = $full.Substring(0, $sep + 1)
        $tn = $full.Substring($sep + 1)
        $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
        $trueState = if ($t) { $t.State.ToString() } else { 'NotFound' }
        Check "task '$full' state" (([string]$r.state) -ieq $trueState) "reported '$($r.state)', scheduler says '$trueState'"
        $expectOpt = ($trueState -ieq 'Disabled') -or ($trueState -ieq 'NotFound')
        Check "task '$full' isOptimized" ([bool]$r.isOptimized -eq $expectOpt) "isOptimized=$($r.isOptimized), state='$trueState'"
    }

    # ---------------------------------------------------------------- startup
    Section "startup vs Run keys + Startup folders"
    $startupData = @(Get-Json '/api/startup')
    Write-Host "rows: $($startupData.Count)"
    foreach ($r in $startupData) { Write-Host "  [$($r.location)] $($r.name) enabled=$($r.enabled)" }

    $hkcuRun = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $hklmRun = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    $wowRun = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    $hkcuAppr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $hklmAppr = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $hkcuFolderAppr = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    $hklmFolderAppr = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    $userStartup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $commonStartup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    $hkcuVals = Get-RunValues $hkcuRun
    $hklmVals = Get-RunValues $hklmRun
    $wowVals = Get-RunValues $wowRun
    $userFiles = @(Get-ChildItem -Path $userStartup -File -ErrorAction SilentlyContinue)
    $commonFiles = @(Get-ChildItem -Path $commonStartup -File -ErrorAction SilentlyContinue)
    $wmiNames = @{}
    foreach ($w in @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)) { $wmiNames[$w.Name] = $true }

    # no duplicate (location, name) pairs
    $pairSeen = @{}
    foreach ($r in $startupData) {
        $pair = "$($r.location)|$($r.name)"
        Check "startup row '$pair' not duplicated" (-not $pairSeen.ContainsKey($pair))
        $pairSeen[$pair] = $true
    }

    # no invented rows: every row maps back to a real source entry
    foreach ($r in $startupData) {
        $loc = [string]$r.location; $nm = [string]$r.name
        switch -Regex ($loc) {
            '^HKCU: Run$' { Check "startup row [HKCU: Run] '$nm' exists" ($hkcuVals.ContainsKey($nm)) 'no such Run value' }
            '^HKLM: Run$' { Check "startup row [HKLM: Run] '$nm' exists" ($hklmVals.ContainsKey($nm)) 'no such Run value' }
            '^HKLM: WOW64$' { Check "startup row [HKLM: WOW64] '$nm' exists" ($wowVals.ContainsKey($nm)) 'no such Run value' }
            '^Startup Folder$' { Check "startup row [Startup Folder] '$nm' exists" ([bool](@($userFiles | Where-Object { $_.BaseName -ieq $nm }).Count)) 'no matching file' }
            '^Startup Folder \(All Users\)$' { Check "startup row [All Users] '$nm' exists" ([bool](@($commonFiles | Where-Object { $_.BaseName -ieq $nm }).Count)) 'no matching file' }
            default { Check "startup row [$loc] '$nm' exists" ($wmiNames.ContainsKey($nm)) 'not a Run value, folder file, or WMI entry' }
        }
    }

    # no dropped rows: every source entry the design promises to list, is listed
    foreach ($k in $hkcuVals.Keys) { Check "HKCU Run value '$k' listed" ($pairSeen.ContainsKey("HKCU: Run|$k")) }
    foreach ($k in $hklmVals.Keys) { Check "HKLM Run value '$k' listed" ($pairSeen.ContainsKey("HKLM: Run|$k")) }
    foreach ($k in $wowVals.Keys) {
        if ($hklmVals.ContainsKey($k)) { $script:skip++; continue }   # design: same name as HKLM Run is de-duplicated
        Check "WOW64 Run value '$k' listed" ($pairSeen.ContainsKey("HKLM: WOW64|$k"))
    }
    foreach ($f in $userFiles) { Check "user Startup file '$($f.Name)' listed" ($pairSeen.ContainsKey("Startup Folder|$($f.BaseName)")) }
    foreach ($f in $commonFiles) {
        if (@($userFiles | Where-Object { $_.BaseName -ieq $f.BaseName }).Count) { $script:skip++; continue }
        Check "common Startup file '$($f.Name)' listed" ($pairSeen.ContainsKey("Startup Folder (All Users)|$($f.BaseName)"))
    }

    # enabled flags follow the StartupApproved rule
    foreach ($r in $startupData) {
        $loc = [string]$r.location; $nm = [string]$r.name
        $expectOff = $null
        switch -Regex ($loc) {
            '^HKCU: Run$' { $expectOff = Get-ApprovedOff $hkcuAppr $nm }
            '^HKLM: Run$' {
                $a = $null
                if (Test-Path $hklmAppr) { $a = (Get-ItemProperty -Path $hklmAppr -Name $nm -ErrorAction SilentlyContinue).$nm }
                if ($a -and $a.Length -gt 0) { $expectOff = Get-ApprovedOff $hklmAppr $nm }
                else { $expectOff = Get-ApprovedOff $hkcuAppr $nm }
            }
            '^HKLM: WOW64$' { $expectOff = Get-ApprovedOff $hklmAppr $nm }
            '^Startup Folder$' {
                $f = $userFiles | Where-Object { $_.BaseName -ieq $nm } | Select-Object -First 1
                if ($f) { $expectOff = Get-ApprovedOff $hkcuFolderAppr $f.Name }
            }
            '^Startup Folder \(All Users\)$' {
                $f = $commonFiles | Where-Object { $_.BaseName -ieq $nm } | Select-Object -First 1
                if ($f) { $expectOff = Get-ApprovedOff $hklmFolderAppr $f.Name }
            }
            default { $expectOff = Get-ApprovedOff $hkcuAppr $nm }
        }
        if ($null -eq $expectOff -or $null -eq $r.enabled) { $script:skip++; continue }
        Check "startup '$nm' [$loc] enabled flag" ([bool]$r.enabled -ne [bool]$expectOff) "enabled=$($r.enabled), StartupApproved says disabled=$expectOff"
    }

    # ---------------------------------------------------------------- summary
    Write-Host ""
    Write-Host "=== RESULT ===" -ForegroundColor Cyan
    Write-Host "  passed: $script:pass"
    Write-Host "  failed: $script:fail"
    Write-Host "  skipped (indeterminate): $script:skip"
    if ($script:fail -gt 0) {
        foreach ($f in ($failures | Select-Object -First 25)) { Write-Host "  FAIL $f" -ForegroundColor Red }
        if ($failures.Count -gt 25) { Write-Host "  ... and $($failures.Count - 25) more" -ForegroundColor Red }
    } else {
        Write-Host "  every reported row matches independent machine state" -ForegroundColor Green
    }
}
finally {
    if ($backend -and -not $backend.HasExited) { Stop-Process -Id $backend.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    $still = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($still) { Write-Host "WARN: port $Port still listening after teardown" -ForegroundColor Yellow }
    if (-not $blockLogExisted -and (Test-Path -LiteralPath $blockLog)) { Remove-Item -LiteralPath $blockLog -Force }
    Remove-Item $out, $err -ErrorAction SilentlyContinue
}
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
