#Requires -Version 5.1
<#
    winhance-catalog-diff.ps1 - coverage + duplicate report against Winhance.

    Answers the two questions Phase 3 needs before a single setting is wired in:

      "one value, one home" - does our catalog already own the registry
      (path, valueName) pair, and is it owned by exactly ONE entry?
      "coverage" - which Winhance settings are already covered, which overlap an
      existing entry (same key, different value), and which are untouched?

    Our side of the diff is read from server.ps1 with the PowerShell AST parser,
    so it reflects the real $script:RegTweaks array rather than a regex guess.
    Winhance's side is the machine-extracted source catalogue JSON.

    Exit codes:
      0  no intra-catalog duplicate (path+valueName owned twice)
      1  a duplicate exists, or the inputs could not be parsed

    Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\winhance-catalog-diff.ps1
      ... -Filter 'gaming-|visual-effects'      # only settings whose id/name matches
      ... -ShowUncovered                         # list every uncovered setting
      ... -Json -OutFile report.json             # machine-readable summary
#>
param(
    [string]$Catalogue = 'C:\Projects\windows-tweaks-winhance-source-catalogue.json',
    [string]$ServerScript,
    [string]$Filter,
    [switch]$ShowUncovered,
    [switch]$ShowCovered,
    [switch]$ShowKeyOnly,
    [switch]$Json,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
if (-not $ServerScript) { $ServerScript = Join-Path $root 'server.ps1' }
if (-not (Test-Path $ServerScript)) { throw "server.ps1 not found: $ServerScript" }
if (-not (Test-Path $Catalogue)) { throw "Winhance catalogue not found: $Catalogue" }

# ── Normalisation ────────────────────────────────────────────────────────────
# Both sides are reduced to "<hive>\<key>" + "<valuename>", lower-cased, so
# "HKLM:\SOFTWARE\X" and "HKEY_LOCAL_MACHINE\SOFTWARE\X" compare equal.
function ConvertTo-NormPath([string]$p) {
    if (-not $p) { return '' }
    $s = $p.Trim().ToLowerInvariant()
    $s = $s -replace '^hkey_local_machine', 'hklm'
    $s = $s -replace '^hkey_current_user',  'hkcu'
    $s = $s -replace '^hkey_classes_root',  'hkcr'
    $s = $s -replace '^hkey_current_config','hkcc'
    $s = $s -replace '^hkey_users',         'hku'
    $s = $s -replace ':', ''
    $s = $s -replace '\\+', '\'
    return $s.Trim('\')
}
function ConvertTo-NormValue([string]$v) { if ($null -eq $v) { return '' } else { return $v.Trim().ToLowerInvariant() } }

# ── Our catalog, via the AST ─────────────────────────────────────────────────
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count) { throw "server.ps1 failed to parse ($($parseErrors.Count) errors)" }

$assign = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:RegTweaks'
    }, $true) | Select-Object -First 1
if (-not $assign) { throw 'could not find the $script:RegTweaks assignment in server.ps1' }

function Get-HashtableMap($table) {
    # HashtableAst.KeyValuePairs is a list of Tuple<ExpressionAst key, StatementAst value>.
    $map = @{}
    foreach ($kv in $table.KeyValuePairs) {
        $keyNode = $kv.Item1
        if ($null -eq $keyNode) { continue }
        $key = Get-NodeLiteral $keyNode
        if ($key) { $map[[string]$key] = $kv.Item2 }
    }
    return $map
}
function Get-NodeLiteral($node) {
    if ($null -eq $node) { return $null }
    # A hashtable value is a StatementAst; unwrap the common pipeline shape.
    if ($node -is [System.Management.Automation.Language.PipelineAst]) {
        $els = @($node.PipelineElements)
        if ($els.Count -ge 1 -and $els[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { return Get-NodeLiteral $els[0].Expression }
        if ($node.Extent) { return $node.Extent.Text }
        return $null
    }
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $node.Value }
    if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $node.Value }
    if ($node.Extent) { return $node.Extent.Text }
    return $null
}

$hashtables = $assign.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
$ourEntries = New-Object System.Collections.Generic.List[object]
foreach ($t in $hashtables) {
    $map = Get-HashtableMap $t
    if (-not $map.ContainsKey('id')) { continue }   # nested value hashtables have 'name', not 'id'
    $id = [string](Get-NodeLiteral $map['id'])
    if (-not $id) { continue }
    $entry = [ordered]@{
        id        = $id
        category  = [string](Get-NodeLiteral $map['category'])
        path      = [string](Get-NodeLiteral $map['path'])
        valueName = if ($map.ContainsKey('valueName')) { [string](Get-NodeLiteral $map['valueName']) } else { '' }
        type      = [string](Get-NodeLiteral $map['type'])
        mergeKey  = if ($map.ContainsKey('mergeKey')) { [string](Get-NodeLiteral $map['mergeKey']) } else { '' }
        values    = @()
    }
    # Multi-write entries carry values=@(@{name=..;..},..) and no top-level valueName.
    if ($map.ContainsKey('values')) {
        foreach ($vt in $map['values'].FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
            $vm = Get-HashtableMap $vt
            if ($vm.ContainsKey('name')) { $entry.values += [string](Get-NodeLiteral $vm['name']) }
        }
    }
    $ourEntries.Add([pscustomobject]$entry)
}
if ($ourEntries.Count -eq 0) { throw 'no catalog entries were extracted from server.ps1' }

# Build the ownership index. A pair owned by more than one entry is a real bug
# (the same registry value written from two places).
$ourPairs = @{}
# A merge entry ("type=merge") does not own a whole registry value: it owns ONE
# pair inside a shared key=value payload string. Three Winhance cards live in the
# same DirectXUserGlobalSettings string on three different pairs (windowed games,
# VRR optimizations, Auto HDR), so the pair name has to be part of the ownership
# key or they all look like owners of a single value.
$ourMergeOwners = @{}
foreach ($e in $ourEntries) {
    $pairNames = @()
    if ($e.valueName) { $pairNames += $e.valueName }
    $pairNames += $e.values
    $normPath = ConvertTo-NormPath $e.path
    foreach ($vn in ($pairNames | Where-Object { $_ })) {
        $normValue = ConvertTo-NormValue $vn
        $plain = "{0}|{1}" -f $normPath, $normValue
        if (($e.type -eq 'merge') -and $e.mergeKey) {
            $k = "{0}#{1}" -f $plain, (ConvertTo-NormValue $e.mergeKey)
            if (-not $ourMergeOwners.ContainsKey($plain)) { $ourMergeOwners[$plain] = New-Object System.Collections.Generic.List[string] }
            if (-not $ourMergeOwners[$plain].Contains($e.id)) { $ourMergeOwners[$plain].Add($e.id) }
        } else {
            $k = $plain
        }
        if (-not $ourPairs.ContainsKey($k)) { $ourPairs[$k] = New-Object System.Collections.Generic.List[string] }
        $ourPairs[$k].Add($e.id)
    }
}
$ourPaths = @{}
foreach ($e in $ourEntries) {
    $pk = ConvertTo-NormPath $e.path
    if (-not $ourPaths.ContainsKey($pk)) { $ourPaths[$pk] = New-Object System.Collections.Generic.List[string] }
    $ourPaths[$pk].Add($e.id)
}
$duplicates = @()
foreach ($kv in $ourPairs.GetEnumerator()) {
    if ($kv.Value.Count -gt 1) { $duplicates += [pscustomobject]@{ pair = $kv.Key; owners = $kv.Value.ToArray() } }
}
$duplicates = @($duplicates | Sort-Object pair)

# ── Winhance catalogue ───────────────────────────────────────────────────────
$cat = Get-Content $Catalogue -Raw | ConvertFrom-Json
$settings = New-Object System.Collections.Generic.List[object]
foreach ($f in $cat.features) {
    foreach ($s in $f.settings) {
        if ($Filter -and ("$($s.id) $($s.name)" -notmatch $Filter)) { continue }
        $writes = New-Object System.Collections.Generic.List[object]
        foreach ($r in @($s.registry)) {
            if (-not $r) { continue }
            $writes.Add([pscustomobject]@{
                    key       = ConvertTo-NormPath $r.keyPath
                    valueName = ConvertTo-NormValue $r.valueName
                    pair      = ("{0}|{1}" -f (ConvertTo-NormPath $r.keyPath), (ConvertTo-NormValue $r.valueName))
                })
        }
        $settings.Add([pscustomobject]@{
                feature     = $f.featureId
                group       = $f.settingGroupName
                id          = $s.id
                name        = $s.name
                inputType   = $s.inputType
                writes      = $writes
                scriptCount = @($s.scripts).Count
                taskCount   = @($s.tasks).Count
                regCount    = @($s.regContents).Count
                powerCount  = @($s.powerCfg).Count
            })
    }
}

# Classify each setting against our catalog.
$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $settings) {
    $owners = New-Object System.Collections.Generic.List[string]
    $exactPairs = 0
    $pathOnlyOwners = New-Object System.Collections.Generic.List[string]
    foreach ($w in $s.writes) {
        if ($ourPairs.ContainsKey($w.pair)) {
            $exactPairs++
            foreach ($o in $ourPairs[$w.pair]) { if (-not $owners.Contains($o)) { $owners.Add($o) } }
        }
        elseif ($ourMergeOwners.ContainsKey($w.pair)) {
            # We manage a pair inside this payload value. Which pair can only be
            # matched by hand (the catalogue does not say), so this counts as
            # covered and the owner list names the merge entries.
            $exactPairs++
            foreach ($o in $ourMergeOwners[$w.pair]) { if (-not $owners.Contains($o)) { $owners.Add($o) } }
        }
        elseif ($ourPaths.ContainsKey($w.key)) {
            foreach ($o in $ourPaths[$w.key]) { if (-not $pathOnlyOwners.Contains($o)) { $pathOnlyOwners.Add($o) } }
        }
    }
    # Verdicts, in the order they matter for "one value, one home":
    #   conflict  - we already write at least one of these exact values: a real
    #               decision (extend the existing entry, or keep both deliberately)
    #   keyonly   - we write a DIFFERENT value under the same key: co-existence,
    #               no conflict, at most a UI grouping question
    #   covered   - every value this setting writes is already ours
    #   uncovered - nothing of ours touches it
    $verdict = 'uncovered'
    if ($s.writes.Count -eq 0) { $verdict = 'no-registry' }
    elseif ($exactPairs -eq $s.writes.Count -and $owners.Count -gt 0) { $verdict = 'covered' }
    elseif ($exactPairs -gt 0) { $verdict = 'conflict' }
    elseif ($pathOnlyOwners.Count -gt 0) { $verdict = 'keyonly' }
    $rows.Add([pscustomobject]@{
            id             = $s.id
            name           = $s.name
            feature        = $s.feature
            group          = $s.group
            inputType      = $s.inputType
            writes         = $s.writes.Count
            exact          = $exactPairs
            verdict        = $verdict
            owners         = ($owners -join ',')
            pathOwners     = ($pathOnlyOwners -join ',')
            scriptCount    = $s.scriptCount
            taskCount      = $s.taskCount
        })
}

$byVerdict = @{ covered = 0; conflict = 0; keyonly = 0; uncovered = 0; 'no-registry' = 0 }
foreach ($r in $rows) { $byVerdict[$r.verdict]++ }

# ── Report ───────────────────────────────────────────────────────────────────
$w  = '{0,-46} {1,-11} {2,-8} {3,-18} {4}'
Write-Host '=== WINHANCE CATALOG DIFF ==='
Write-Host ("our catalog : {0} entries, {1} owned (path,valueName) pairs" -f $ourEntries.Count, $ourPairs.Count)
Write-Host ("winhance    : {0} settings{1}" -f $rows.Count, $(if ($Filter) { " (filter '$Filter')" } else { '' }))
Write-Host ("verdicts    : covered {0} | VALUE-CONFLICT {1} | key-only {2} | uncovered {3} | no-registry {4}" -f $byVerdict.covered, $byVerdict.conflict, $byVerdict.keyonly, $byVerdict.uncovered, $byVerdict.'no-registry')

Write-Host ''
Write-Host '--- duplicate ownership inside OUR catalog (must be zero) ---'
if ($duplicates.Count -eq 0) { Write-Host '  none - one value, one home holds' }
else { foreach ($d in $duplicates) { Write-Host ("  DUPLICATE {0}  <- {1}" -f $d.pair, ($d.owners -join ' + ')) } }

Write-Host ''
Write-Host '--- VALUE CONFLICTS: we already write one of these exact values (decide here) ---'
$conflicts = @($rows | Where-Object { $_.verdict -eq 'conflict' } | Sort-Object feature, id)
if ($conflicts.Count -eq 0) { Write-Host '  none' }
else {
    Write-Host ($w -f 'winhance id', 'input', 'exact', 'our entry', 'name')
    foreach ($r in $conflicts) {
        Write-Host ("{0,-46} {1,-11} {2,-8} {3,-18} {4}" -f $r.id, $r.inputType, ("$($r.exact)/$($r.writes)"), $r.owners, $r.name)
    }
}

Write-Host ''
Write-Host ("--- key-only overlaps: same key, different value (no conflict): {0} ---" -f $byVerdict.keyonly)
if ($ShowKeyOnly) {
    $keyOnly = @($rows | Where-Object { $_.verdict -eq 'keyonly' } | Sort-Object feature, id)
    Write-Host ($w -f 'winhance id', 'input', 'writes', 'our entry (key)', 'name')
    foreach ($r in $keyOnly) { Write-Host ("{0,-46} {1,-11} {2,-8} {3,-18} {4}" -f $r.id, $r.inputType, $r.writes, $r.pathOwners, $r.name) }
}

if ($ShowUncovered) {
    Write-Host ''
    Write-Host '--- uncovered ---'
    $u = @($rows | Where-Object { $_.verdict -eq 'uncovered' } | Sort-Object feature, id)
    Write-Host ($w -f 'winhance id', 'input', 'writes', 'owner', 'name')
    foreach ($r in $u) { Write-Host ("{0,-46} {1,-11} {2,-8} {3,-18} {4}" -f $r.id, $r.inputType, $r.writes, '', $r.name) }
}
if ($ShowCovered) {
    Write-Host ''
    Write-Host '--- covered (already owned; do not re-add) ---'
    $c = @($rows | Where-Object { $_.verdict -eq 'covered' } | Sort-Object feature, id)
    Write-Host ($w -f 'winhance id', 'input', 'writes', 'our entry', 'name')
    foreach ($r in $c) { Write-Host ("{0,-46} {1,-11} {2,-8} {3,-18} {4}" -f $r.id, $r.inputType, $r.writes, $r.owners, $r.name) }
}

if ($Json -or $OutFile) {
    $dupOut = @()
    foreach ($d in @($duplicates)) { $dupOut += ([string]$d.pair + ' <- ' + ($d.owners -join ' + ')) }
    $summary = [ordered]@{
        generatedAt   = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
        ourEntries    = $ourEntries.Count
        ourPairs      = $ourPairs.Count
        duplicates    = $dupOut
        verdicts      = $byVerdict
        rows          = $rows.ToArray()
    }
    $jsonText = $summary | ConvertTo-Json -Depth 6
    if ($OutFile) { [System.IO.File]::WriteAllText($OutFile, $jsonText, (New-Object System.Text.UTF8Encoding($false))); Write-Host ''; Write-Host "wrote $OutFile" }
    if ($Json) { Write-Host ''; Write-Host $jsonText }
}

Write-Host ''
if ($duplicates.Count -gt 0) { Write-Host 'RESULT: FAIL - duplicate (path,valueName) ownership in our catalog'; exit 1 }
Write-Host 'RESULT: OK - no duplicate ownership in our catalog'
exit 0
