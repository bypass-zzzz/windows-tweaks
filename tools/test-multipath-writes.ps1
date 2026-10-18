#Requires -Version 5.1
<#
    test-multipath-writes.ps1 - a multi-write entry may target more than one
    registry key.

    Why: several Winhance settings write the same logical toggle to HKCU *and*
    HKLM (Background App Permissions, Storage Sense, GameDVR, VBS/HVCI). The
    catalog's `values=@(@{name=..;..})` list assumed the entry's single `path`
    for every value, so the second key could never be reached from one card.

    The fix: an optional `path` on a value definition, defaulting to the
    entry's path. This test extracts the real writer and reader out of
    server.ps1 with the AST parser (same technique as test-dryrun-guard.ps1)
    and drives them against two HKCU scratch keys - no elevation, no machine
    state beyond the scratch tree, which the test removes afterwards.

    Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-multipath-writes.ps1
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

Write-Host '=== MULTIPATH WRITE TEST ==='
Write-Host "server: $server"
Write-Host ''

# ── Install the real functions from server.ps1 into this scope ───────────────
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($server, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count) { throw 'server.ps1 failed to parse' }

$wanted = 'Get-InstalledRamGB', 'Get-TweakTargetValue', 'Get-ValuePath', 'Get-RegTweakValue', 'Set-RegTweakValue', 'Get-RegTweakState', 'Set-RegTweak'
$found = @{}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $fn.Name) { $found[$fn.Name] = $fn.Extent.Text }
}
foreach ($name in $wanted) {
    if (-not $found.ContainsKey($name)) { throw "could not extract $name from server.ps1" }
    Invoke-Expression $found[$name]
}

# ── Scratch keys ─────────────────────────────────────────────────────────────
$baseA = 'HKCU:\Software\WindowsTweaks\MultipathTest\A'
$baseB = 'HKCU:\Software\WindowsTweaks\MultipathTest\B'
$treeRoot = 'HKCU:\Software\WindowsTweaks'
function Reset-Scratch {
    if (Test-Path $treeRoot) { Remove-Item -Path $treeRoot -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue }
}
Reset-Scratch

$def = @{
    id        = 'mpProbe'
    path      = $baseA
    defaultOn = $false
    values    = @(
        @{ name = 'Alpha'; type = 'DWord'; on = 1; off = '__REMOVE__' },
        @{ name = 'Beta';  type = 'DWord'; on = 1; off = '__REMOVE__'; path = $baseB }
    )
}

Write-Host '--- initial ---'
Assert-True 'state is false before anything is written' (-not (Get-RegTweakState $def))

Write-Host ''
Write-Host '--- apply (on) ---'
Set-RegTweak -def $def -on $true
$alpha = (Get-ItemProperty -Path $baseA -Name 'Alpha' -ErrorAction SilentlyContinue).Alpha
$beta  = (Get-ItemProperty -Path $baseB -Name 'Beta'  -ErrorAction SilentlyContinue).Beta
$stray = (Get-ItemProperty -Path $baseA -Name 'Beta'  -ErrorAction SilentlyContinue).Beta
Assert-True 'the first value landed on the entry path (A\Alpha = 1)' ($alpha -eq 1)
Assert-True 'the second value landed on its OWN path (B\Beta = 1)' ($beta -eq 1)
Assert-True 'no stray Beta was written to the entry path (A\Beta absent)' ($null -eq $stray)
Assert-True 'state reads back as applied' ((Get-RegTweakState $def) -eq $true)

Write-Host ''
Write-Host '--- revert (__REMOVE__ on every value) ---'
Set-RegTweak -def $def -on $false
$alphaGone = $null -eq (Get-ItemProperty -Path $baseA -Name 'Alpha' -ErrorAction SilentlyContinue).Alpha
$betaGone  = $null -eq (Get-ItemProperty -Path $baseB -Name 'Beta'  -ErrorAction SilentlyContinue).Beta
Assert-True 'the first value was removed from the entry path' $alphaGone
Assert-True 'the second value was removed from its own path' $betaGone
Assert-True 'state reads back as not applied' ((Get-RegTweakState $def) -eq $false)

Write-Host ''
Write-Host '--- defaults: an entry with no per-value path still uses its own ---'
$plain = @{ id = 'plainProbe'; path = $baseA; defaultOn = $false; values = @(@{ name = 'Gamma'; type = 'DWord'; on = 1; off = '__REMOVE__' }) }
Set-RegTweak -def $plain -on $true
Assert-True 'single-path entries are unchanged (A\Gamma = 1)' (((Get-ItemProperty -Path $baseA -Name 'Gamma' -ErrorAction SilentlyContinue).Gamma) -eq 1)

Reset-Scratch
Assert-True 'the scratch tree was cleaned up' (-not (Test-Path $treeRoot))

Write-Host ''
Write-Host '=== RESULT ==='
Write-Host ("  passed: {0}" -f $script:Passed)
Write-Host ("  failed: {0}" -f $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
Write-Host '  multi-path value writes behave as designed'
exit 0
