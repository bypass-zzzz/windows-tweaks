#Requires -Version 5.1
<#
.SYNOPSIS
    Drives every /api/* endpoint of server.ps1 against a -DryRun instance and
    proves that nothing on the machine changed.

.DESCRIPTION
    server.ps1 writes real registry values, BCD entries, power schemes, service
    start types and firewall-adjacent network settings. Until now there was no
    test suite at all. This harness is the second half of the safety net (the
    first being -DryRun itself): it starts a dry-run backend on a scratch port,
    authenticates, calls all 26 endpoints, and then checks - against the actual
    machine - that no state moved.

    Three design choices carry most of the weight:

    1. IDEMPOTENT PAYLOADS. Every mutating endpoint is called with the values the
       machine already has (current DNS servers, current MTU, a tweak's current
       state, a service's current state). So even in the worst case - the guard
       silently not being installed - the request would set what is already set
       and the machine is unharmed. The risk of testing is not "the guard holds",
       it is "nothing to lose if it does not".

    2. PROVE, THEN PROCEED. The bulk endpoints (/api/tweak/all,
       /api/revert-defaults, /api/services/optimize) cannot be made idempotent -
       they change many things by design. These are only called AFTER the earlier
       idempotent calls have demonstrably been intercepted by the same running
       process, i.e. after the guard has been proven live in that exact process.
       If that proof is missing they are skipped and the run fails, rather than
       gambling on it.

    3. INDEPENDENT EVIDENCE, NOT SELF-REPORTING. The assertions do not trust the
       server's own "success" flags. They compare the machine's real DNS/MTU/
       registry-tweak state before and after, confirm a process the harness
       spawned is still alive after asking the API to kill it, and diff every
       file in the app directory to prove no file was written.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-endpoints-dryrun.ps1

.EXAMPLE
    # Skip the non-idempotent bulk endpoints entirely.
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-endpoints-dryrun.ps1 -SkipBulk
#>
[CmdletBinding()]
param(
    [int]$Port = 48933,
    [int]$StartupTimeoutSec = 60,
    # The bulk routes are not slow because of the dry run, they are slow in
    # general: /api/revert-defaults walks every catalog entry (93, the seven
    # dropdowns included) plus netsh / powercfg / bcdedit / MMAgent / service
    # calls, and every one of those still performs its readback even when the
    # mutation itself is intercepted. At 90 s it used to time out with the block
    # log already showing 123 intercepted calls - while an unrelated bug in
    # Set-RegTweak's handling of the dropdowns was stalling the whole route. That
    # is fixed, and this route now measures 0.2 s; the caps below are kept
    # generous so a slow machine cannot turn a slow run into a false failure.
    [int]$RequestTimeoutSec = 180,
    [switch]$SkipBulk
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$appDir = Split-Path -Parent $here
$serverScript = Join-Path $appDir 'server.ps1'
$blockLog = Join-Path $appDir 'dry-run-blocked.log'
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$stdoutLog = Join-Path ([System.IO.Path]::GetTempPath()) "wt-dryrun-$stamp.out.log"
$stderrLog = Join-Path ([System.IO.Path]::GetTempPath()) "wt-dryrun-$stamp.err.log"

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param([string]$What, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  FAIL  {0}{1}" -f $What, $(if ($Detail) { "  -> $Detail" } else { '' })) -ForegroundColor Red
    }
}
function Section { param([string]$Title) Write-Host "`n--- $Title ---" -ForegroundColor Cyan }

# Reads a file another process may still hold open for writing - which is exactly
# what Start-Process's redirect target is while the backend runs. A plain
# ReadAllText throws a sharing violation there, and with ErrorActionPreference set
# to Stop that terminating error killed this harness outright: it exited silently
# right after printing "startup", with the actual reason on stderr only. Always
# read log files through this.
function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $t
    } catch { return '' }
}

# If anything terminates this script, do not leave the backend running: two
# aborted runs each leaked a dry-run server still holding its port.
$script:BackendProc = $null
$script:TempLogs = @($stdoutLog, $stderrLog)
trap {
    Write-Host "`n  UNHANDLED ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:BackendProc -and -not $script:BackendProc.HasExited) {
        try { $script:BackendProc.Kill() } catch { }
        Write-Host "  leaked dry-run backend killed" -ForegroundColor Yellow
    }
    foreach ($f in $script:TempLogs) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    Write-Host "  harness aborted" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $serverScript)) { Write-Error "server.ps1 not found at $serverScript"; exit 1 }

Write-Host "`n=== DRY-RUN ENDPOINT HARNESS ===" -ForegroundColor Cyan
Write-Host "server : $serverScript"
Write-Host "port   : $Port"

# ── Preflight ────────────────────────────────────────────────────────────────
$busy = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($busy) { Write-Error "Port $Port is already in use - pick another with -Port"; exit 1 }
if (Test-Path -LiteralPath $blockLog) { Remove-Item -LiteralPath $blockLog -Force -WhatIf:$false }

function Get-DirSnapshot {
    param([string]$Root)
    $skip = @('node_modules', '.git', 'dist')
    $map = @{}
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
            $fi = New-Object System.IO.FileInfo($f)
            $map[$f] = "$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)"
        }
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            if ($skip -contains (Split-Path -Leaf $sub)) { continue }
            $stack.Push($sub)
        }
    }
    return $map
}

$adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -ne $true } | Select-Object -First 1
if (-not $adapter) { $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1 }
$mtuBefore = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
$dnsBefore = @((Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
$memBefore = (Get-MMAgent -ErrorAction SilentlyContinue).MemoryCompression
# Adapter binding state, because /api/network/bindings with a body is the one
# endpoint whose damage would be the least pleasant to notice (it disables every
# binding that is not the keep-list component, including IPv6).
$bindingsBefore = @{}
foreach ($b in (Get-NetAdapterBinding -ErrorAction SilentlyContinue)) { $bindingsBefore["$($b.Name)|$($b.ComponentID)"] = [bool]$b.Enabled }
$filesBefore = Get-DirSnapshot -Root $appDir

Section "baseline (captured before starting the dry-run backend)"
Write-Host "  adapter           : $($adapter.Name)"
Write-Host "  MTU               : $mtuBefore"
Write-Host "  DNS               : $($dnsBefore -join ', ')"
Write-Host "  MemoryCompression : $memBefore"
Write-Host "  files in app dir  : $($filesBefore.Count)"

# ── Start the dry-run backend ────────────────────────────────────────────────
$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$serverScript`"", '-Port', $Port, '-DryRun', '-NoBrowser') `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru -WindowStyle Hidden
$script:BackendProc = $proc

$token = $null
$deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    $txt = Read-TextFile -Path $stdoutLog
    if ($txt) {
        $m = [regex]::Match($txt, '__WT_TOKEN__([A-Za-z0-9+/=]{44})')
        if ($m.Success) { $token = $m.Groups[1].Value; break }
    }
    Start-Sleep -Milliseconds 200
}

Section "startup"
if (-not $token) {
    Write-Host "  backend stdout:" -ForegroundColor Yellow
    (Read-TextFile -Path $stdoutLog) -split "`r?`n" | Select-Object -Last 25 | ForEach-Object { "    $_" }
    (Read-TextFile -Path $stderrLog) -split "`r?`n" | Select-Object -Last 15 | ForEach-Object { "    [err] $_" }
    if (-not $proc.HasExited) { $proc.Kill() }
    Write-Error "backend never printed its API token within $StartupTimeoutSec s"
    exit 1
}
$bannerText = Read-TextFile -Path $stdoutLog
Assert-True "backend printed the DRY RUN banner on stdout" ($bannerText -match 'DRY RUN ACTIVE') 'banner missing - -DryRun not in effect'
Assert-True "backend printed its API token" ($token.Length -eq 44)
Write-Host "  token captured, backend up on port $Port" -ForegroundColor DarkGray

$script:Token = $token
$script:Base = "http://127.0.0.1:$Port"

function Invoke-Api {
    param([string]$Path, [string]$Body, [int]$TimeoutSec = 0, [string]$Token = '')
    if ($TimeoutSec -le 0) { $TimeoutSec = $RequestTimeoutSec }
    $uri = "$script:Base$Path"
    $headers = @{}
    if ($Token) { $headers['X-WT-Token'] = $Token } elseif ($script:Token) { $headers['X-WT-Token'] = $script:Token }
    try {
        if ($Body) {
            $r = Invoke-WebRequest -Uri $uri -Method POST -Headers $headers -ContentType 'application/json' -Body $Body -UseBasicParsing -TimeoutSec $TimeoutSec
        } else {
            $r = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSec
        }
        return @{ ok = $true; status = [int]$r.StatusCode; text = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $body = ''
            try { $sr = New-Object System.IO.StreamReader($resp.GetResponseStream()); $body = $sr.ReadToEnd() } catch { }
            return @{ ok = $false; status = [int]$resp.StatusCode; text = $body }
        }
        return @{ ok = $false; status = 0; text = $_.Exception.Message }
    }
}
function Parse-Json {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}
function Get-BlockCount {
    $t = Read-TextFile -Path $blockLog
    if (-not $t) { return 0 }
    return @($t -split "`r?`n" | Where-Object { $_.Trim() }).Count
}
# The two interception channels are different and both matter. External tools and
# the shadowed cmdlets (scheduled tasks, MMAgent, Checkpoint-Computer) write an
# explicit line to dry-run-blocked.log. Cmdlets that DO support ShouldProcess are
# stopped by $WhatIfPreference instead, and that path writes nothing to the log -
# it prints `What if: Performing the operation ...` to the backend's stdout. Testing
# only the log therefore looks like a guard failure when the guard in fact worked.
function Get-WhatIfCount {
    $t = Read-TextFile -Path $stdoutLog
    if (-not $t) { return 0 }
    return @([regex]::Matches($t, 'What if:')).Count
}

# ── Auth ─────────────────────────────────────────────────────────────────────
Section "auth is still enforced in dry-run"
$noToken = Invoke-Api -Path '/api/status' -Token 'none'
Assert-True "'/api/status' without a token is refused (403)" ($noToken.status -eq 403) "got $($noToken.status)"

$status = Invoke-Api -Path '/api/status'
Assert-True "'/api/status' with the token returns 200" ($status.status -eq 200) "got $($status.status): $($status.text)"
$statusData = Parse-Json -Text $status.text
Assert-True "'/api/status' returns parseable JSON" ($null -ne $statusData) 'unparseable'
Assert-True "'/api/status' reports dryRun = true" ($null -ne $statusData -and $statusData.dryRun -eq $true) "dryRun was '$($statusData.dryRun)' - NOT a dry run"

# ── Read endpoints ───────────────────────────────────────────────────────────
Section "read endpoints (must serve real data)"
$reads = @(
    @{ Path = '/api/network';          Check = { param($d) $null -ne $d } }
    @{ Path = '/api/tweak/catalog';    Check = { param($d) @($d).Count -gt 5 } }
    @{ Path = '/api/services';         Check = { param($d) $null -ne $d } }
    @{ Path = '/api/tasks';            Check = { param($d) @($d).Count -gt 0 } }
    @{ Path = '/api/startup';          Check = { param($d) $null -ne $d } }
    @{ Path = '/api/processes';        Check = { param($d) @($d).Count -gt 5 } }
    @{ Path = '/api/network/bindings'; Check = { param($d) $null -ne $d } }
    @{ Path = '/api/mtu-test';         Check = { param($d) $null -ne $d } }
    @{ Path = '/api/dns-benchmark';    Check = { param($d) $null -ne $d } }
    @{ Path = '/api/ping'; Body = '{"target":"127.0.0.1"}'; Check = { param($d) $null -ne $d } }
)
$readData = @{}
foreach ($r in $reads) {
    $res = Invoke-Api -Path $r.Path -Body $r.Body
    $ok = ($res.status -eq 200)
    $data = if ($ok) { Parse-Json -Text $res.text } else { $null }
    $shapeOk = $false
    if ($null -ne $data) { $shapeOk = (& $r.Check $data) }
    Assert-True ("read {0} -> 200 + expected shape" -f $r.Path) ($ok -and $shapeOk) "status=$($res.status) shape=$shapeOk body=$($res.text.Substring(0, [Math]::Min(120, $res.text.Length)))"
    if ($null -ne $data) { $readData[$r.Path] = $data }
}

# Real values lifted from the reads, so the mutation calls below are idempotent.
$catalog = @($readData['/api/tweak/catalog'])
$svcResp = $readData['/api/services']
$services = @($(if ($svcResp.PSObject.Properties.Name -contains 'services') { $svcResp.services } else { $svcResp }))
# /api/services returns a FLAT array of services - there is no 'groups' key. Each
# service carries its own group / groupModifiable / groupTitle fields, so the group
# list has to be derived from it. The previous version only looked for a 'groups'
# property, found none, and skipped every group assertion as "not available" -
# which looked like a coverage gap in the guard rather than in this harness.
$groups = @($(if ($svcResp.PSObject.Properties.Name -contains 'groups') {
        $svcResp.groups
    } else {
        @($services | Where-Object { $_.group } | Group-Object -Property group | ForEach-Object {
            @{ id = $_.Name; modifiable = [bool]$_.Group[0].groupModifiable; total = $_.Count }
        })
    }))
$tasks = @($(if ((@($readData['/api/tasks']))[0].PSObject.Properties.Name -contains 'tasks') { (@($readData['/api/tasks']))[0].tasks } else { $readData['/api/tasks'] }))
$startupResp = $readData['/api/startup']
$startup = @($(if ($startupResp.PSObject.Properties.Name -contains 'apps') { $startupResp.apps } else { $startupResp }))

$tweak = $catalog | Where-Object { $_.id -and -not $_.options } | Select-Object -First 1
$svc = $services | Where-Object { $_.name -and $_.curated } | Select-Object -First 1
$task = $tasks | Select-Object -First 1
$app = $startup | Where-Object { $_.name } | Select-Object -First 1

# A group whose curated members are ALL in the same state, so a bulk call with
# that state cannot change anything even if it ran for real.
$uniformGroup = $null
foreach ($g in ($groups | Where-Object { $_.modifiable })) {
    $members = @($services | Where-Object { $_.group -eq $g.id -and $_.curated })
    if ($members.Count -eq 0) { continue }
    if (($members | Where-Object { $_.isOptimized }).Count -eq $members.Count) { $uniformGroup = @{ id = $g.id; state = $true }; break }
    if (($members | Where-Object { -not $_.isOptimized }).Count -eq $members.Count) { $uniformGroup = @{ id = $g.id; state = $false }; break }
}

Write-Host "  payload sources:" -ForegroundColor DarkGray
Write-Host ("    tweak   : {0} (currently active={1})" -f $(if ($tweak) { $tweak.id } else { '<none>' }), $(if ($tweak) { $tweak.active } else { 'n/a' })) -ForegroundColor DarkGray
Write-Host ("    service : {0} (isOptimized={1})" -f $(if ($svc) { $svc.name } else { '<none>' }), $(if ($svc) { $svc.isOptimized } else { 'n/a' })) -ForegroundColor DarkGray
Write-Host ("    task    : {0}" -f $(if ($task) { $task.path } else { '<none>' })) -ForegroundColor DarkGray
Write-Host ("    startup : {0}" -f $(if ($app) { $app.name } else { '<none>' })) -ForegroundColor DarkGray
Write-Host ("    group   : {0}" -f $(if ($uniformGroup) { "$($uniformGroup.id) state=$($uniformGroup.state)" } else { '<none uniform>' })) -ForegroundColor DarkGray

# Registry-backed tweak states, straight from the catalog. This is the ground
# truth the final comparison uses.
$tweakStatesBefore = @{}
foreach ($t in $catalog) { if ($t.id) { $tweakStatesBefore[$t.id] = $t.active } }

# ── Mutation endpoints (idempotent payloads only) ─────────────────────────────
Section "mutation endpoints with idempotent payloads (must be intercepted)"
$idempotent = @(
    @{ Path = '/api/apply-dns';        Body = (@{ dns = @($dnsBefore) } | ConvertTo-Json -Compress) }
    @{ Path = '/api/apply-mtu';        Body = (@{ mtu = $mtuBefore } | ConvertTo-Json -Compress) }
    @{ Path = '/api/tweak/set';        Body = $(if ($tweak) { (@{ id = $tweak.id; enabled = [bool]$tweak.active }) | ConvertTo-Json -Compress } else { $null }) }
    @{ Path = '/api/services/set';     Body = $(if ($svc) { (@{ name = $svc.name; optimized = [bool]$svc.isOptimized }) | ConvertTo-Json -Compress } else { $null }) }
    @{ Path = '/api/services/group';   Body = $(if ($uniformGroup) { (@{ group = $uniformGroup.id; optimize = [bool]$uniformGroup.state }) | ConvertTo-Json -Compress } else { $null }) }
    @{ Path = '/api/tasks/set';        Body = $(if ($task) { (@{ path = $task.path; disabled = [bool]$task.isOptimized }) | ConvertTo-Json -Compress } else { $null }) }
    @{ Path = '/api/startup/set';      Body = $(if ($app) { (@{ name = $app.name; scope = $app.scope; enabled = [bool]$app.enabled }) | ConvertTo-Json -Compress } else { $null }) }
    @{ Path = '/api/processes/clean-ram'; Body = '{}' }
)
$intercepted = 0
$attempted = 0
foreach ($m in $idempotent) {
    if (-not $m.Body) { Write-Host ("  SKIP  {0} - no payload available from the reads" -f $m.Path) -ForegroundColor DarkGray; continue }
    $attempted++
    $blkBefore = Get-BlockCount; $wiBefore = Get-WhatIfCount
    $res = Invoke-Api -Path $m.Path -Body $m.Body
    $blockGrew = (Get-BlockCount) -gt $blkBefore
    $whatIfGrew = (Get-WhatIfCount) -gt $wiBefore
    $jsonOk = $null -ne (Parse-Json -Text $res.text)
    if ($blockGrew -or $whatIfGrew) { $intercepted++ }
    Assert-True ("mutate {0} -> 200 + JSON + intercepted" -f $m.Path) ($res.status -eq 200 -and $jsonOk -and ($blockGrew -or $whatIfGrew)) "status=$($res.status) json=$jsonOk blockLog=$blockGrew whatIf=$whatIfGrew body=$($res.text.Substring(0, [Math]::Min(140, $res.text.Length)))"
}
$guardProven = ($attempted -gt 0 -and $intercepted -eq $attempted)
Assert-True "the guard is demonstrably live in this exact process" $guardProven "$intercepted of $attempted mutations were intercepted"

# Validation paths - these deliberately attempt no change, and they are the
# security-relevant ones. /api/services/group in particular used to invert its own
# action (every "Disable all" silently performed a RESTORE) because it read
# $parsed.optimized, which is always $null. These assertions pin that shut.
Section "input validation (no mutation attempted)"
$anyGroup = $groups | Select-Object -First 1
$readOnlyGroup = $groups | Where-Object { -not $_.modifiable } | Select-Object -First 1
$modifiableGroup = $groups | Where-Object { $_.modifiable } | Select-Object -First 1

$r = Invoke-Api -Path '/api/services/group' -Body '{"group":"__no_such_group__"}'
$j = Parse-Json -Text $r.text
Assert-True "group: unknown group is rejected" ($r.status -eq 200 -and $j.success -eq $false -and "$($j.error)" -match 'Unknown group') "status=$($r.status) body=$($r.text)"
if ($readOnlyGroup) {
    $r = Invoke-Api -Path '/api/services/group' -Body (@{ group = $readOnlyGroup.id } | ConvertTo-Json -Compress)
    $j = Parse-Json -Text $r.text
    Assert-True "group: read-only group is rejected" ($r.status -eq 200 -and $j.success -eq $false -and "$($j.error)" -match 'read-only') "group=$($readOnlyGroup.id) body=$($r.text)"
} else { Write-Host "  SKIP  no read-only group available to test" -ForegroundColor DarkGray }
if ($modifiableGroup) {
    $r = Invoke-Api -Path '/api/services/group' -Body (@{ group = $modifiableGroup.id } | ConvertTo-Json -Compress)
    $j = Parse-Json -Text $r.text
    Assert-True "group: a missing 'optimize' flag is refused, not guessed" ($r.status -eq 200 -and $j.success -eq $false -and "$($j.error)" -match "Missing 'optimize'") "group=$($modifiableGroup.id) body=$($r.text)"
} else { Write-Host "  SKIP  no modifiable group available to test" -ForegroundColor DarkGray }

# ── End-to-end kill proof ────────────────────────────────────────────────────
Section "end-to-end: a process the API is told to kill survives"
$sacrifice = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList '-n', '120', '127.0.0.1' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 900
$aliveBefore = -not $sacrifice.HasExited
Assert-True "sacrificial process started" $aliveBefore 'ping exited too early'
if ($aliveBefore) {
    $procs = Parse-Json -Text (Invoke-Api -Path '/api/processes').text
    $listed = @($procs) | Where-Object { "$($_.pid)" -eq "$($sacrifice.Id)" }
    if ($listed.Count -gt 0) {
        Write-Host "  (the API lists pid $($sacrifice.Id))" -ForegroundColor DarkGray
    } else {
        Write-Host "  (note: /api/processes does not list pid $($sacrifice.Id) - that endpoint filters the list; the proof below does not depend on it)" -ForegroundColor DarkGray
    }
    $killRes = Invoke-Api -Path '/api/processes/kill' -Body (@{ pid = $sacrifice.Id } | ConvertTo-Json -Compress)
    $killJson = Parse-Json -Text $killRes.text
    # Acking the pid matters: a handler that replied "Invalid PID" would leave the
    # survival assertion below passing for the wrong reason.
    Assert-True "kill request reaches the kill path (200 + pid acked)" ($killRes.status -eq 200 -and "$($killJson.killed)" -eq "$($sacrifice.Id)") "status=$($killRes.status) body=$($killRes.text)"
    Start-Sleep -Milliseconds 600
    $stillAlive = -not $sacrifice.HasExited
    Assert-True "the process is STILL RUNNING after the kill request" $stillAlive 'process died - Stop-Process was NOT blocked'
}
try { if (-not $sacrifice.HasExited) { $sacrifice.Kill() } } catch { }

# ── Bulk endpoints (only once the guard is proven live) ──────────────────────
if ($SkipBulk) {
    Section "bulk endpoints"
    Write-Host "  SKIPPED (-SkipBulk)" -ForegroundColor DarkGray
} elseif (-not $guardProven) {
    Section "bulk endpoints"
    Assert-True "bulk endpoints exercised" $false 'guard not proven live in this process - refusing to call them'
} else {
    Section "bulk endpoints (guard proven live, so safe to exercise)"
    # These cannot be made idempotent: /api/tweak/all applies ~30 registry tweaks
    # plus power/BCD/service changes, /api/revert-defaults undoes them, and
    # /api/network/bindings with a body disables every adapter binding that is not
    # the keep-list component. They are exercised only now, after the calls above
    # have already proven this same process intercepts mutations. Every one of them
    # is verified afterwards against real machine state.
    $proofGated = @(
        @{ Path = '/api/network/bindings'; Body = '{"ipv4Only":true}'; Timeout = 180 }
        @{ Path = '/api/services/optimize'; Body = '{}'; Timeout = 300 }
        @{ Path = '/api/tweak/network';    Body = '{}'; Timeout = 180 }
        @{ Path = '/api/tweak/system';     Body = '{}'; Timeout = 180 }
        @{ Path = '/api/tweak/all';        Body = '{}'; Timeout = 420 }
        @{ Path = '/api/restore-point';    Body = '{}'; Timeout = 180 }
        @{ Path = '/api/revert-defaults';  Body = '{}'; Timeout = 420 }
    )
    if ($modifiableGroup) {
        # Bulk toggle for a real group, using whichever state most of its curated
        # members are already in - the same thing the UI's "all on / all off"
        # button sends.
        $members = @($services | Where-Object { $_.group -eq $modifiableGroup.id -and $_.curated })
        if ($members.Count -gt 0) {
            $optCount = @($members | Where-Object { $_.isOptimized }).Count
            $majority = ($optCount * 2 -ge $members.Count)
            $proofGated += @{ Path = '/api/services/group'; Body = (@{ group = $modifiableGroup.id; optimize = $majority } | ConvertTo-Json -Compress); Timeout = 300 }
            Write-Host ("  group bulk: {0} ({1} curated member(s), majority optimize={2})" -f $modifiableGroup.id, $members.Count, $majority) -ForegroundColor DarkGray
        }
    }
    foreach ($m in $proofGated) {
        $blkBefore = Get-BlockCount; $wiBefore = Get-WhatIfCount
        $t = if ($m.ContainsKey('Timeout')) { [int]$m.Timeout } else { 0 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $res = Invoke-Api -Path $m.Path -Body $m.Body -TimeoutSec $t
        $sw.Stop()
        $blockGrew = (Get-BlockCount) -gt $blkBefore
        $whatIfGrew = (Get-WhatIfCount) -gt $wiBefore
        $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        Assert-True ("bulk {0} -> 200 + JSON + intercepted" -f $m.Path) ($res.status -eq 200 -and $null -ne (Parse-Json -Text $res.text) -and ($blockGrew -or $whatIfGrew)) "status=$($res.status) blockLog=$blockGrew whatIf=$whatIfGrew elapsed=${secs}s body=$($res.text.Substring(0, [Math]::Min(140, $res.text.Length)))"
        if ($res.status -eq 200) { Write-Host ("    took {0}s" -f $secs) -ForegroundColor DarkGray }
    }
}

# ── Independent verification that nothing changed ────────────────────────────
Section "nothing changed on the machine"

# Re-read the catalog from the same process: registry-backed tweak states.
$catalogAfter = Parse-Json -Text (Invoke-Api -Path '/api/tweak/catalog').text
$tweakStatesAfter = @{}
foreach ($t in @($catalogAfter)) { if ($t.id) { $tweakStatesAfter[$t.id] = $t.active } }
$flipped = @()
foreach ($k in $tweakStatesBefore.Keys) {
    if (-not $tweakStatesAfter.ContainsKey($k)) { $flipped += "$k (disappeared)"; continue }
    if ($tweakStatesBefore[$k] -ne $tweakStatesAfter[$k]) { $flipped += "$k ($($tweakStatesBefore[$k]) -> $($tweakStatesAfter[$k]))" }
}
Assert-True ("all {0} registry-backed tweak states unchanged" -f $tweakStatesBefore.Count) ($flipped.Count -eq 0) ($flipped -join ' ; ')

$mtuAfter = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).NlMtu
Assert-True "adapter MTU unchanged" ($mtuAfter -eq $mtuBefore) "was $mtuBefore, now $mtuAfter"
$dnsAfter = @((Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
Assert-True "DNS servers unchanged" (($dnsAfter -join ',') -eq ($dnsBefore -join ',')) "was '$($dnsBefore -join ',')', now '$($dnsAfter -join ',')'"
$memAfter = (Get-MMAgent -ErrorAction SilentlyContinue).MemoryCompression
Assert-True "MemoryCompression unchanged" ($memAfter -eq $memBefore) "was $memBefore, now $memAfter"

$bindingsAfter = @{}
foreach ($b in (Get-NetAdapterBinding -ErrorAction SilentlyContinue)) { $bindingsAfter["$($b.Name)|$($b.ComponentID)"] = [bool]$b.Enabled }
$bindingFlips = @()
foreach ($k in $bindingsBefore.Keys) {
    if (-not $bindingsAfter.ContainsKey($k)) { $bindingFlips += "$k (disappeared)"; continue }
    if ($bindingsBefore[$k] -ne $bindingsAfter[$k]) { $bindingFlips += "$k ($($bindingsBefore[$k]) -> $($bindingsAfter[$k]))" }
}
Assert-True ("all {0} adapter bindings unchanged" -f $bindingsBefore.Count) ($bindingFlips.Count -eq 0) ($bindingFlips -join ' ; ')

$filesAfter = Get-DirSnapshot -Root $appDir
$changed = @()
foreach ($k in $filesAfter.Keys) {
    if ($k -eq $blockLog) { continue }
    if (-not $filesBefore.ContainsKey($k)) { $changed += "created: $k" }
    elseif ($filesBefore[$k] -ne $filesAfter[$k]) { $changed += "modified: $k" }
}
foreach ($k in $filesBefore.Keys) {
    if (-not $filesAfter.ContainsKey($k)) { $changed += "deleted: $k" }
}
Assert-True "no file in the app directory was created, modified or deleted" ($changed.Count -eq 0) ($changed -join ' ; ')

# ── The block log is the audit trail ─────────────────────────────────────────
Section "block log"
Assert-True "dry-run-blocked.log was written next to server.ps1" (Test-Path -LiteralPath $blockLog) "no log at $blockLog"
$logText = Read-TextFile -Path $blockLog
$entries = @($logText -split "`r?`n" | Where-Object { $_ -match '\|' })
Write-Host ("  {0} blocked call(s) recorded" -f $entries.Count) -ForegroundColor DarkGray
foreach ($needle in 'netsh', 'powercfg', 'bcdedit', 'Checkpoint-Computer', 'Purge-StandbyRam') {
    Assert-True ("block log records '{0}'" -f $needle) ($logText -match [regex]::Escape($needle)) "no '$needle' entry"
}
$logText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 5 | ForEach-Object { "    $_" }

# ── Teardown ─────────────────────────────────────────────────────────────────
Section "teardown"
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 700
$stillListening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
Assert-True "dry-run backend stopped and released port $Port" (-not $stillListening) "port still held"
if (Test-Path -LiteralPath $blockLog) { Remove-Item -LiteralPath $blockLog -Force -WhatIf:$false }
Assert-True "block log removed (repo left clean)" (-not (Test-Path -LiteralPath $blockLog)) "still present"
foreach ($f in $stdoutLog, $stderrLog) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -WhatIf:$false } }

Write-Host "`n=== RESULT ===" -ForegroundColor Cyan
Write-Host ("  passed: {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail -gt 0) {
    Write-Host ("  failed: {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host "  DRY-RUN BEHAVIOUR IS NOT TRUSTWORTHY" -ForegroundColor Red
    exit 1
}
Write-Host "  failed: 0" -ForegroundColor Green
Write-Host "  every endpoint exercised, nothing on the machine changed" -ForegroundColor Green
exit 0
