#Requires -Version 5.1
<#
    test-composite-writes.ps1 - a tweak may edit ONE key inside a key=value
    payload string instead of overwriting it.

    Why: "Optimizations for windowed games" is not a value of its own. It is the
    SwapEffectUpgradeEnable pair inside
    HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings,
    a string of the form "SwapEffectUpgradeEnable=0;VRROptimizeEnable=0;". A
    plain write would either wipe the neighbouring pairs or fail to change
    anything, so the writer has to read, edit the one pair, and write back.

    Extraction technique is the same as test-dryrun-guard.ps1 / the multipath
    test: the real functions are lifted out of server.ps1 with the AST parser and
    driven against an HKCU scratch key. No elevation.

    Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-composite-writes.ps1
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root 'server.ps1'

$script:Passed = 0
$script:Failed = 0
function Assert-True {
    param([string]$Label, [bool]$Condition)
    if ($Condition) { $script:Passed++; Write-Host "  PASS  $Label" }
    else { $script:Failed++; Write-Host "  FAIL  $Label" }
}

Write-Host '=== COMPOSITE (key=value payload) WRITE TEST ==='
Write-Host "server: $server"
Write-Host ''

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($server, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count) { throw 'server.ps1 failed to parse' }

$wanted = 'Get-InstalledRamGB', 'Get-TweakTargetValue', 'Get-ValuePath', 'Get-RegTweakValue', 'Set-RegTweakValue', 'Split-MergeString', 'Join-MergeString', 'Get-MergeStringValue', 'Set-MergeStringValue', 'Get-RegTweakState', 'Set-RegTweak'
$found = @{}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $fn.Name) { $found[$fn.Name] = $fn.Extent.Text }
}
foreach ($name in $wanted) {
    if (-not $found.ContainsKey($name)) { throw "could not extract $name from server.ps1" }
    Invoke-Expression $found[$name]
}

$keyPath  = 'HKCU:\Software\WindowsTweaks\CompositeTest'
$treeRoot = 'HKCU:\Software\WindowsTweaks'
$valueName = 'DirectXUserGlobalSettings'
function Reset-Scratch {
    if (Test-Path $treeRoot) { Remove-Item -Path $treeRoot -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue }
}
function Get-Raw { (Get-ItemProperty -Path $keyPath -Name $valueName -ErrorAction SilentlyContinue).$valueName }
function Set-Raw([string]$s) {
    if (-not (Test-Path $keyPath)) { New-Item -Path $keyPath -Force | Out-Null }
    Set-ItemProperty -Path $keyPath -Name $valueName -Value $s -Type String -Force | Out-Null
}
Reset-Scratch

$def = @{
    id = 'windowedGamesProbe'; path = $keyPath; type = 'merge'
    valueName = $valueName; mergeKey = 'SwapEffectUpgradeEnable'; mergeOn = '1'; mergeOff = '0'
    defaultOn = $true
}

Write-Host '--- fresh machine (value absent, default is ON) ---'
Assert-True 'state is true when the value is absent and defaultOn is set' ((Get-RegTweakState $def) -eq $true)
$written = Set-MergeStringValue -def $def -on $true
Assert-True 'write returned the new payload' ($written -eq 'SwapEffectUpgradeEnable=1;')
Assert-True 'the payload landed with a trailing separator' ((Get-Raw) -eq 'SwapEffectUpgradeEnable=1;')
Assert-True 'state now reads true' ((Get-RegTweakState $def) -eq $true)

Write-Host ''
Write-Host '--- turn it off: only the one pair moves ---'
Set-MergeStringValue -def $def -on $false | Out-Null
Assert-True 'the pair flipped to 0' ((Get-Raw) -eq 'SwapEffectUpgradeEnable=0;')
Assert-True 'state reads false' ((Get-RegTweakState $def) -eq $false)

Write-Host ''
Write-Host '--- neighbouring pairs must survive a flip ---'
Set-Raw 'SwapEffectUpgradeEnable=0;VRROptimizeEnable=0;AutoHDREnable=1;'
Set-MergeStringValue -def $def -on $true | Out-Null
$now = Get-Raw
Assert-True 'the target pair is 1'        ($now -match 'SwapEffectUpgradeEnable=1;')
Assert-True 'VRROptimizeEnable preserved' ($now -match 'VRROptimizeEnable=0;')
Assert-True 'AutoHDREnable preserved'     ($now -match 'AutoHDREnable=1;')
Assert-True 'no pair was duplicated'      (([regex]::Matches($now, 'SwapEffectUpgradeEnable=')).Count -eq 1)
Assert-True 'pair order is stable'        ($now -eq 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;AutoHDREnable=1;')

Write-Host ''
Write-Host '--- odd input: no trailing separator, extra spaces ---'
Set-Raw 'VRROptimizeEnable=1; SwapEffectUpgradeEnable=0'
Set-MergeStringValue -def $def -on $true | Out-Null
$now2 = Get-Raw
Assert-True 'the pair was found and flipped despite spacing' ($now2 -match 'SwapEffectUpgradeEnable=1')
Assert-True 'the neighbour survived'                         ($now2 -match 'VRROptimizeEnable=1')

Write-Host ''
Write-Host '--- defaults: absent value with defaultOn=false ---'
Set-Raw ''
Remove-ItemProperty -Path $keyPath -Name $valueName -ErrorAction SilentlyContinue
$defOff = @{ id = 'offProbe'; path = $keyPath; type = 'merge'; valueName = $valueName; mergeKey = 'SwapEffectUpgradeEnable'; mergeOn = '1'; mergeOff = '0'; defaultOn = $false }
Assert-True 'state is false when absent and defaultOn is not set' ((Get-RegTweakState $defOff) -eq $false)

Write-Host ''
Write-Host '--- Set-RegTweak dispatches merge entries too ---'
Set-Raw 'VRROptimizeEnable=0;SwapEffectUpgradeEnable=0;'
Set-RegTweak -def $def -on $true
Assert-True 'Set-RegTweak routed to the merge writer' ((Get-Raw) -match 'SwapEffectUpgradeEnable=1;')
Set-RegTweak -def $def -on $false
Assert-True 'Set-RegTweak routed the off path too' ((Get-Raw) -match 'SwapEffectUpgradeEnable=0;')

Reset-Scratch
Assert-True 'the scratch tree was cleaned up' (-not (Test-Path $treeRoot))

# ── The real catalogue entries that use this writer ──────────────────────────
# Two cards share ONE payload value. This reads them straight out of server.ps1
# (so it fails if the catalog is edited apart from the writer) and then proves a
# dry-run apply cannot move the machine's real DirectX payload by one byte.
function Get-CatalogEntry([string]$id) {
    $t2 = $null; $e2 = $null
    $a2 = [System.Management.Automation.Language.Parser]::ParseFile($server, [ref]$t2, [ref]$e2)
    foreach ($h in $a2.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        $p = @{}
        foreach ($kv in $h.KeyValuePairs) { $p["$($kv.Item1.Extent.Text)".Trim("'", '"')] = $kv.Item2 }
        if (-not $p.ContainsKey('id')) { continue }
        if ("$($p['id'].Extent.Text)".Trim("'", '"') -ne $id) { continue }
        $out = @{}
        foreach ($k in $p.Keys) { $out[$k] = "$($p[$k].Extent.Text)".Trim("'", '"') }
        return $out
    }
    return $null
}

Write-Host ''
Write-Host '--- the real DirectX cards ---'
$d1 = Get-CatalogEntry 'dxWindowedGames'
$d2 = Get-CatalogEntry 'dxAutoHdr'
Assert-True 'dxWindowedGames is in the catalog' ($null -ne $d1)
Assert-True 'dxAutoHdr is in the catalog' ($null -ne $d2)
Assert-True 'the windowed-games card edits SwapEffectUpgradeEnable (1 on / 0 off)' ($d1.mergeKey -eq 'SwapEffectUpgradeEnable' -and $d1.mergeOn -eq '1' -and $d1.mergeOff -eq '0')
Assert-True 'the Auto HDR card edits AutoHDREnable (1 on / 0 off)' ($d2.mergeKey -eq 'AutoHDREnable' -and $d2.mergeOn -eq '1' -and $d2.mergeOff -eq '0')
Assert-True 'both cards are typed merge' ($d1.type -eq 'merge' -and $d2.type -eq 'merge')
Assert-True 'both cards share ONE payload value and own different pairs' ($d1.path -eq $d2.path -and $d1.valueName -eq $d2.valueName -and $d1.mergeKey -ne $d2.mergeKey)
Assert-True 'windowed games defaults ON, Auto HDR defaults OFF' ($d1.defaultOn -eq '$true' -and $d2.defaultOn -eq '$false')

$realPath = $d1.path
$realName = $d1.valueName
function Get-RealPayload { if (Test-Path $realPath) { [string](Get-ItemProperty -Path $realPath -Name $realName -ErrorAction SilentlyContinue).$realName } else { $null } }
$realBefore = Get-RealPayload
$WhatIfPreference = $true
try {
    # *>&1 | Out-Null swallows the "What if:" lines the guard prints while still
    # exercising the real writer, so this check is about the machine, not the log.
    & {
        Set-RegTweak -def @{ id = $d1.id; path = $d1.path; type = 'merge'; valueName = $d1.valueName; mergeKey = $d1.mergeKey; mergeOn = $d1.mergeOn; mergeOff = $d1.mergeOff; defaultOn = $true } -on $true | Out-Null
        Set-RegTweak -def @{ id = $d2.id; path = $d2.path; type = 'merge'; valueName = $d2.valueName; mergeKey = $d2.mergeKey; mergeOn = $d2.mergeOn; mergeOff = $d2.mergeOff; defaultOn = $false } -on $true | Out-Null
    } *>&1 | Out-Null
} finally { $WhatIfPreference = $false }
$realAfter = Get-RealPayload
Assert-True 'a dry-run apply through Set-RegTweak left the real DirectX payload untouched' ($realBefore -eq $realAfter)

Write-Host ''
Write-Host '=== RESULT ==='
Write-Host ("  passed: {0}" -f $script:Passed)
Write-Host ("  failed: {0}" -f $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
Write-Host '  composite key=value writes behave as designed'
exit 0
