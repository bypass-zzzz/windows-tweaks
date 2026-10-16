#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies the -DryRun safety net in server.ps1 actually blocks mutations.

.DESCRIPTION
    The dry-run guard is only worth having if it cannot be walked past, so this
    test does not trust a re-implementation of the logic: it parses server.ps1,
    lifts the real `if ($DryRun) { ... }` block out of the AST, and exercises
    those exact statements. If someone edits the guard, this test fails.

    Three layers of proof:

      1. Classification - real argument vectors taken from server.ps1, including
         the ones an earlier verb-matching version wrongly waved through
         (`bcdedit /deletevalue`, `powercfg /hibernate`).
      2. End-to-end blocking - actually calls the shadowed `reg.exe` to write a
         throwaway HKCU key and asserts the key does NOT appear. This is the
         load-bearing test: it proves nothing reached the real executable.
      3. Pass-through - asserts genuine reads still reach the real tool, because
         a guard that blocks reads too makes the harness useless.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-dryrun-guard.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerScript
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $ServerScript) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ServerScript = Join-Path (Split-Path -Parent $here) 'server.ps1'
}
if (-not (Test-Path -LiteralPath $ServerScript)) { Write-Error "server.ps1 not found: $ServerScript"; exit 1 }

$pass = 0
$fail = 0
function Assert-True {
    param([string]$What, [bool]$Condition, [string]$Detail)
    if ($Condition) {
        $script:pass++
        Write-Host ("  PASS  {0}" -f $What) -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host ("  FAIL  {0}{1}" -f $What, $(if ($Detail) { "  -> $Detail" } else { '' })) -ForegroundColor Red
    }
}

Write-Host "`n=== DRY-RUN GUARD TEST ===" -ForegroundColor Cyan
Write-Host "source: $ServerScript"

# ── Extract the real guard block from the AST ────────────────────────────────
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerScript, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count) { Write-Error "server.ps1 has syntax errors; fix those first."; exit 1 }

$ifStatements = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
$guard = $ifStatements | Where-Object { $_.Clauses[0].Item1.Extent.Text -eq '$DryRun' } | Select-Object -First 1
if (-not $guard) { Write-Error "Could not find the 'if (`$DryRun)' guard block in server.ps1"; exit 1 }

$blockText = $guard.Clauses[0].Item2.Extent.Text
$open = $blockText.IndexOf('{'); $close = $blockText.LastIndexOf('}')
$guardBody = $blockText.Substring($open + 1, $close - $open - 1)
Write-Host ("guard block: {0} chars, extracted from line {1}" -f $guardBody.Length, $guard.Clauses[0].Item1.Extent.StartLineNumber)

# The guard writes its log next to $scriptDir; point it at a scratch dir so the
# test never touches the repo.
$scriptDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-guard-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null
$DryRun = $true

# Install the guard into this scope exactly as server.ps1 would.
Invoke-Expression $guardBody

if (-not (Get-Command Test-WTDryRunAllowed -ErrorAction SilentlyContinue)) {
    Write-Error "guard did not define Test-WTDryRunAllowed - extraction failed"
    exit 1
}

# ── 1. Classification ────────────────────────────────────────────────────────
Write-Host "`n--- 1. classification (must BLOCK) ---" -ForegroundColor Cyan
$mustBlock = @(
    @{ Tool = 'bcdedit';  Args = @('/deletevalue', 'useplatformclock') }
    @{ Tool = 'bcdedit';  Args = @('/deletevalue', 'disabledynamictick') }
    @{ Tool = 'bcdedit';  Args = @('/set', 'useplatformtick', 'yes') }
    @{ Tool = 'bcdedit';  Args = @('/deletevalue', '{current}', 'useplatformclock') }
    @{ Tool = 'powercfg'; Args = @('/hibernate', 'off') }
    @{ Tool = 'powercfg'; Args = @('/hibernate', 'on') }
    @{ Tool = 'powercfg'; Args = @('/setactive', 'SCHEME_MIN') }
    @{ Tool = 'powercfg'; Args = @('/change', 'monitor-timeout-ac', '0') }
    @{ Tool = 'powercfg'; Args = @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN', '100') }
    @{ Tool = 'netsh';    Args = @('int', 'tcp', 'set', 'global', 'rss=enabled') }
    @{ Tool = 'netsh';    Args = @('interface', 'ipv4', 'set', 'subinterface', 'Ethernet', 'mtu=1500', 'store=persistent') }
    @{ Tool = 'netsh';    Args = @('int', 'ip', 'set', 'address', 'name="show"') }   # write verb present -> deny
    @{ Tool = 'sc';       Args = @('config', 'DiagTrack', 'start=', 'disabled') }
    @{ Tool = 'reg';      Args = @('add', 'HKCU\Software\x', '/v', 'y', '/d', '1', '/f') }
    @{ Tool = 'taskkill'; Args = @('/F', '/IM', 'notepad.exe') }
    @{ Tool = 'netsh';    Args = @() }          # empty -> deny
    @{ Tool = 'bcdedit';  Args = @('save', 'C:\boot.bak') }
)
foreach ($c in $mustBlock) {
    $allowed = Test-WTDryRunAllowed -Tool $c.Tool -Arguments $c.Args
    Assert-True ("BLOCK {0} {1}" -f $c.Tool, ($c.Args -join ' ')) (-not $allowed) 'was allowed through'
}

Write-Host "`n--- 1b. classification (must ALLOW - reads) ---" -ForegroundColor Cyan
$mustAllow = @(
    @{ Tool = 'bcdedit';  Args = @('/enum', '{current}') }
    @{ Tool = 'bcdedit';  Args = @('/enum') }
    @{ Tool = 'powercfg'; Args = @('/getactivescheme') }
    @{ Tool = 'powercfg'; Args = @('/list') }
    @{ Tool = 'powercfg'; Args = @('/query', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMIN') }
    @{ Tool = 'netsh';    Args = @('int', 'tcp', 'show', 'global') }
    @{ Tool = 'netsh';    Args = @('interface', 'ipv4', 'show', 'interfaces') }
    @{ Tool = 'sc';       Args = @('query', 'DiagTrack') }
    @{ Tool = 'sc';       Args = @('qdescription', 'DiagTrack') }
    @{ Tool = 'reg';      Args = @('query', 'HKCU\Software') }
)
foreach ($c in $mustAllow) {
    $allowed = Test-WTDryRunAllowed -Tool $c.Tool -Arguments $c.Args
    Assert-True ("ALLOW {0} {1}" -f $c.Tool, ($c.Args -join ' ')) $allowed 'was blocked (harness usefulness)'
}

# ── 1c. Cmdlets that declare no WhatIf must still be blocked by shadows ──────
Write-Host "`n--- 1c. no-WhatIf cmdlets are shadowed (resolution + log entry) ---" -ForegroundColor Cyan
function Get-BlockLogCount {
    if (Test-Path -LiteralPath $script:DryRunLogPath) { return @([System.IO.File]::ReadAllLines($script:DryRunLogPath)).Count }
    return 0
}
$caseDefs = @(
    @{ Name = 'Disable-MMAgent';       Body = { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } }
    @{ Name = 'Enable-MMAgent';        Body = { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } }
    @{ Name = 'Disable-ScheduledTask'; Body = { Disable-ScheduledTask -TaskPath '\' -TaskName 'WTDryRunProbe' -ErrorAction SilentlyContinue } }
    @{ Name = 'Enable-ScheduledTask';  Body = { Enable-ScheduledTask -TaskPath '\' -TaskName 'WTDryRunProbe' -ErrorAction SilentlyContinue } }
    @{ Name = 'Set-ScheduledTask';     Body = { Set-ScheduledTask -TaskPath '\' -TaskName 'WTDryRunProbe' -ErrorAction SilentlyContinue } }
    @{ Name = 'Checkpoint-Computer';   Body = { Checkpoint-Computer -Description 'WTDryRunProbe' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue } }
)

# DELIBERATELY REPRODUCE THE ORDERING THAT BROKE THIS ONCE ALREADY. server.ps1
# reads Get-MMAgent and Get-ScheduledTask during normal operation, and using any
# command from a module AUTO-LOADS that module - importing every export it has,
# which silently clobbers a same-named shadow defined earlier in the session. That
# turned a "guarded" Disable-MMAgent back into the real cmdlet mid-dry-run. So
# those reads are issued here first, on purpose, and the shadows must still hold.
$mmBefore = $null
try { $mmBefore = (Get-MMAgent -ErrorAction SilentlyContinue).MemoryCompression } catch { }
$null = Get-ScheduledTask -ErrorAction SilentlyContinue

foreach ($case in $caseDefs) {
    $resolved = Get-Command $case.Name -ErrorAction SilentlyContinue
    Assert-True ("{0} still resolves to the guard's shadow after module load" -f $case.Name) ([string]::IsNullOrEmpty($resolved.Source)) ("resolved to module '$($resolved.Source)' - module auto-load clobbered the shadow")
}
foreach ($case in $caseDefs) {
    $before = Get-BlockLogCount
    & $case.Body | Out-Null
    $after = Get-BlockLogCount
    Assert-True ("shadowed {0} intercepts" -f $case.Name) ($after -gt $before) 'no log entry - call reached the real cmdlet'
}
# Strongest available evidence: the underlying system state did not move.
try {
    $mmAfter = (Get-MMAgent -ErrorAction SilentlyContinue).MemoryCompression
    if ($null -ne $mmBefore) {
        Assert-True "MemoryCompression unchanged by dry run" ($mmBefore -eq $mmAfter) "was $mmBefore, now $mmAfter - restore with 'Disable-MMAgent -MemoryCompression'"
    } else {
        Write-Host "  SKIP  MemoryCompression readback unavailable on this host" -ForegroundColor DarkGray
    }
} catch { Write-Host "  SKIP  Get-MMAgent unavailable" -ForegroundColor DarkGray }

# ── 2. End-to-end: a blocked write must leave no trace ───────────────────────
Write-Host "`n--- 2. end-to-end blocking (real reg.exe, throwaway key) ---" -ForegroundColor Cyan
$probeKey = 'HKCU:\Software\WindowsTweaksDryRunProbe'
$probeKeyNative = 'HKCU\Software\WindowsTweaksDryRunProbe'
# Every test-owned cleanup passes -WhatIf:$false explicitly. The guard sets
# $WhatIfPreference = $true in this scope (correctly - its whole job is to neuter
# the entire script), which would otherwise turn the test's own Remove-Item calls
# into silent no-ops and let a probe key survive the run.
if (Test-Path -LiteralPath $probeKey) { Remove-Item -LiteralPath $probeKey -Recurse -Force -WhatIf:$false }

& reg.exe add $probeKeyNative /v probe /d 1 /f 2>&1 | Out-Null
$existsAfterBlockedWrite = Test-Path -LiteralPath $probeKey
Assert-True "blocked 'reg.exe add' created nothing" (-not $existsAfterBlockedWrite) 'key exists - MUTATION LEAKED'

# Positive control: the same write WITHOUT the guard must actually create the key,
# otherwise the assertion above could pass for the wrong reason (e.g. reg.exe
# missing entirely) and prove nothing. Invoking the real binary by full path
# bypasses the shadow, so the guard stays installed for the whole test.
& "$env:SystemRoot\System32\reg.exe" add $probeKeyNative /v probe /d 1 /f 2>&1 | Out-Null
$existsAfterRealWrite = Test-Path -LiteralPath $probeKey
Assert-True "positive control: unguarded reg.exe DOES write" $existsAfterRealWrite 'control write failed - assertion 2 proves nothing'
if (Test-Path -LiteralPath $probeKey) { Remove-Item -LiteralPath $probeKey -Recurse -Force -WhatIf:$false }
Assert-True "probe key cleaned up" (-not (Test-Path -LiteralPath $probeKey)) "still present at $probeKey"

# ── 3. Pass-through: real reads still work through the shadow ────────────────
Write-Host "`n--- 3. pass-through (reads must still reach the real tool) ---" -ForegroundColor Cyan

$readOutput = (& reg.exe query 'HKCU\Software' 2>$null | Out-String)
Assert-True "shadowed 'reg.exe query' returns real data" ($readOutput -match 'HKEY_CURRENT_USER') 'no output from read'

$enumOutput = (& bcdedit.exe /enum '{current}' 2>$null | Out-String)
$enumOk = ($enumOutput -match 'identifier|Windows Boot Loader|description') -or ($enumOutput.Trim().Length -eq 0)
Assert-True "shadowed 'bcdedit.exe /enum' passes through (or declines cleanly)" $enumOk 'unexpected output'

# ── 4. The block log records what was stopped ────────────────────────────────
Write-Host "`n--- 4. block log ---" -ForegroundColor Cyan
$logPath = $script:DryRunLogPath
$logText = ''
if (Test-Path -LiteralPath $logPath) { $logText = [System.IO.File]::ReadAllText($logPath) }
Assert-True "block log written" ($logText.Length -gt 0) "no log at $logPath"
Assert-True "log records the reg.exe write" ($logText -match 'reg') 'reg.exe block not logged'
$loggedCount = @($logText -split "`r?`n" | Where-Object { $_ -match '\|' }).Count
Write-Host ("  ({0} blocked calls logged)" -f $loggedCount) -ForegroundColor DarkGray

# ── 5. Coverage lint ─────────────────────────────────────────────────────────
# Guard coverage is invisible: a mutation that cannot be intercepted is simply
# not intercepted, and nothing says so. The first version of this lint walked a
# hand-written list of mutating verbs - and it passed while
# `Checkpoint-Computer` (no WhatIf parameter) sat in the restore-point path,
# because "Checkpoint" appeared in no verb list, and while
# [MemoryTuner]::EmptyWorkingSet (a P/Invoke, so no cmdlet transport at all) sat
# in the RAM-purge path. A guessed verb list cannot be trusted.
#
# This version inverts the question. Instead of asking "does this look like a
# mutation?", it enumerates every command the script actually invokes, and
# requires each one to be covered by exactly one of: an explicit shadow, a WhatIf
# parameter, a read-only verb, or an entry in the harmless list below. Anything
# left over fails and has to be triaged by a human. Three checks run:
#
#   A. invoked commands  - no WhatIf, not shadowed, not read-only  -> fail
#   B. external tools    - every .exe invoked must be shadowed, and no guarded
#                          tool may be called by full path (which skips shadows)
#   C. native code       - every P/Invoke call site from an Add-Type class must
#                          sit inside a function that checks $DryRun
Write-Host "`n--- 5. coverage lint (A: commands, B: external tools, C: P/Invoke) ---" -ForegroundColor Cyan

# Commands that cannot change system state despite having no -WhatIf parameter.
$harmlessNoWhatIf = @(
    'Add-Type',            # compiles C# into this process only
    'New-Object',
    'Join-Path',
    'Split-Path',
    'Start-Sleep',
    'Start-Process',       # opens a browser window; no persistent change
    'Set-StrictMode',
    'Import-Module',
    'Write-Host', 'Write-Warning', 'Write-Error', 'Write-Verbose', 'Write-Output',
    'Out-Null', 'Out-String', 'Out-File',
    'ConvertTo-Json', 'ConvertFrom-Json'
)

# Verbs that only read. An unknown verb is deliberately NOT assumed safe.
$readVerbs = @(
    'Get','Test','Select','Where','ForEach','Measure','Sort','Group','Compare','Join','Split',
    'ConvertTo','ConvertFrom','Out','Write','Read','Resolve','Find','Search','Show','Receive',
    'Format','Wait','Trace','Debug','Export','Import','Merge','Assert','Ping','Clear'
)

# Split the guard's shadows into cmdlet shadows and external-tool shadows.
$shadowCmdlets = @()
$shadowNatives = @()
$guardAst = [System.Management.Automation.Language.Parser]::ParseInput($guardBody, [ref]$null, [ref]$null)
foreach ($fn in $guardAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Name -match '\.exe$') { $shadowNatives += $fn.Name }
    elseif ($fn.Name -match '-')  { $shadowCmdlets += $fn.Name }
}
Write-Host ("  guard shadows {0} cmdlet(s): {1}" -f $shadowCmdlets.Count, ($shadowCmdlets -join ', ')) -ForegroundColor DarkGray
Write-Host ("  guard shadows {0} tool(s):   {1}" -f $shadowNatives.Count, ($shadowNatives -join ', ')) -ForegroundColor DarkGray

# Functions this app defines itself; their bodies are covered line by line.
$ownFunctions = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($shadowCmdlets -contains $fn.Name) { continue }
    if ($shadowNatives -contains $fn.Name) { continue }
    $ownFunctions += $fn.Name
}

# --- A. every invoked command must be covered ---------------------------------
$invoked = New-Object System.Collections.Generic.List[string]
foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName()
    if ($n) { $invoked.Add($n) }
}
if ($guardAst) {
    foreach ($c in $guardAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName()
        if ($n) { $invoked.Add($n) }
    }
}

$uncovered = @()
$verified = 0
foreach ($name in ($invoked | Sort-Object -Unique)) {
    if ($ownFunctions -contains $name) { continue }
    if ($shadowCmdlets -contains $name) { continue }
    if ($shadowNatives -contains $name) { continue }
    if ($name -match '^\.' -or $name -match '^\[.*\]$') { continue }
    if ($name -match '\.exe$') { continue }              # handled by check B
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { continue }                          # not a command (operator/expression)
    if ($cmd.CommandType -eq 'Application') { continue }  # handled by check B
    if ($cmd.Parameters.ContainsKey('WhatIf')) { $verified++; continue }   # covered by $WhatIfPreference
    if ($harmlessNoWhatIf -contains $name) { continue }
    $verb = ($name -split '-')[0]
    if ($readVerbs -contains $verb) { continue }
    $uncovered += "$name (no WhatIf, not shadowed, verb '$verb' not known read-only)"
}
Assert-True "A. every invoked command is covered (shadow / WhatIf / read-only / harmless)" ($uncovered.Count -eq 0) ($uncovered -join ' ; ')
Write-Host ("  ({0} command(s) rely on `$WhatIfPreference)" -f $verified) -ForegroundColor DarkGray

# External tools that cannot change system state and so need no shadow. Each
# entry must be justifiable: an unshadowed tool is an unguarded execution path.
$readOnlyExternalTools = @(
    'ping.exe'    # sends ICMP echo requests; has no state-changing mode
)

# --- B. external tools must be shadowed, and never called by full path --------
$invokedExes = @(($invoked | Sort-Object -Unique) | Where-Object { $_ -match '\.exe$' })
$unshadowedExes = @($invokedExes | Where-Object { $shadowNatives -notcontains $_ -and $readOnlyExternalTools -notcontains $_ })
Assert-True "B1. every external tool invoked is shadowed (or provably read-only)" ($unshadowedExes.Count -eq 0) ("unshadowed: " + ($unshadowedExes -join ', '))
Write-Host ("  external tools invoked: {0}" -f ($invokedExes -join ', ')) -ForegroundColor DarkGray

# A full-path call bypasses the shadow entirely, so a guarded tool must never be
# reached that way outside the guard block itself.
$guardRange = @($guard.Clauses[0].Item1.Extent.StartLineNumber, $guard.Clauses[0].Item2.Extent.EndLineNumber)
$bypasses = @()
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($ServerScript)) {
    $lineNo++
    if ($line.TrimStart().StartsWith('#')) { continue }
    if ($lineNo -ge $guardRange[0] -and $lineNo -le $guardRange[1]) { continue }
    foreach ($m in [regex]::Matches($line, '(System32|SystemRoot)[^\s"'']*[\\/](netsh|powercfg|bcdedit|sc|reg|taskkill)\.exe')) {
        $bypasses += "line ${lineNo}: $($m.Value)"
    }
}
Assert-True "B2. no guarded tool is called by full path outside the guard" ($bypasses.Count -eq 0) ($bypasses -join ' ; ')

# --- C. P/Invoke call sites must be $DryRun-guarded --------------------------
$declaredTypes = @()
$sourceText = [System.IO.File]::ReadAllText($ServerScript)
foreach ($m in [regex]::Matches($sourceText, 'public\s+(?:static\s+)?(?:partial\s+)?class\s+(\w+)')) { $declaredTypes += $m.Groups[1].Value }
$declaredTypes = @($declaredTypes | Sort-Object -Unique)
Write-Host ("  Add-Type classes: {0}" -f ($declaredTypes -join ', ')) -ForegroundColor DarkGray

# P/Invokes that only read state and are safe to run during a dry run.
$readOnlyPInvokes = @('GetSystemTimes', 'GlobalMemoryStatusEx')

$fnRanges = @()
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $fnRanges += @{ Name = $fn.Name; Start = $fn.Extent.StartLineNumber; End = $fn.Extent.EndLineNumber; HasDryRun = ($fn.Extent.Text -match '\$DryRun') }
}

$unguardedPInvokes = @()
$lineNo = 0
foreach ($line in [System.IO.File]::ReadAllLines($ServerScript)) {
    $lineNo++
    if ($line.TrimStart().StartsWith('#')) { continue }
    foreach ($m in [regex]::Matches($line, '\[(\w+)\]::(\w+)\s*\(')) {
        $type = $m.Groups[1].Value; $method = $m.Groups[2].Value
        if ($declaredTypes -notcontains $type) { continue }        # not an Add-Type class
        if ($readOnlyPInvokes -contains $method) { continue }
        $owner = $fnRanges | Where-Object { $lineNo -ge $_.Start -and $lineNo -le $_.End } | Select-Object -First 1
        if (-not $owner) { $unguardedPInvokes += "line ${lineNo}: [$type]::$method outside any function"; continue }
        if (-not $owner.HasDryRun) { $unguardedPInvokes += "line ${lineNo}: [$type]::$method inside $($owner.Name) which never checks `$DryRun" }
    }
}
Assert-True "C. every P/Invoke call site sits in a function that checks `$DryRun" ($unguardedPInvokes.Count -eq 0) ($unguardedPInvokes -join ' ; ')

# ── Cleanup & verdict ────────────────────────────────────────────────────────
try { Remove-Item -LiteralPath $scriptDir -Recurse -Force -WhatIf:$false } catch { }

Write-Host "`n=== RESULT ===" -ForegroundColor Cyan
Write-Host ("  passed: {0}" -f $pass) -ForegroundColor Green
if ($fail -gt 0) {
    Write-Host ("  failed: {0}" -f $fail) -ForegroundColor Red
    Write-Host "  DRY-RUN SAFETY NET IS NOT TRUSTWORTHY" -ForegroundColor Red
    exit 1
}
Write-Host "  failed: 0" -ForegroundColor Green
Write-Host "  dry-run guard verified" -ForegroundColor Green
exit 0
