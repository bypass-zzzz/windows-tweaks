#Requires -Version 5.1
<#
.SYNOPSIS
    Inventories every system-mutating call in server.ps1, grouped by enclosing function.

.DESCRIPTION
    The windows-tweaks backend writes real registry keys, BCD entries, services,
    scheduled tasks and network adapter settings. Before adding a dry-run mode - or
    refactoring any of it - we need the COMPLETE mutation surface, because a dry-run
    that misses a single call site is more dangerous than no dry-run at all: it
    creates false confidence.

    This classifies every mutation by whether it can be neutered for free:

      cmdlet   - PowerShell cmdlets supporting ShouldProcess. A single
                 $WhatIfPreference = $true disables all of them.
      external - External executables (netsh, bcdedit, powercfg, sc, reg, taskkill).
                 These IGNORE $WhatIfPreference entirely and must be intercepted
                 explicitly - this is where a naive dry-run leaks real changes.
      file     - File/registry-provider writes outside the ShouldProcess path.

.PARAMETER ServerScript
    Path to server.ps1. Defaults to this repo's copy.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\mutation-inventory.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerScript,
    [switch]$ShowReads
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# $PSScriptRoot is not populated during param-block evaluation on PowerShell 5.1,
# so resolve the default here instead.
if (-not $ServerScript) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ServerScript = Join-Path (Split-Path -Parent $scriptDir) 'server.ps1'
}

if (-not (Test-Path -LiteralPath $ServerScript)) {
    Write-Error "server.ps1 not found at: $ServerScript"
    exit 1
}

# Cmdlets that honour $WhatIfPreference / -WhatIf (ShouldProcess).
$cmdletRules = @(
    @{ Name = 'Set-ItemProperty';    Regex = '\bSet-ItemProperty\b' }
    @{ Name = 'New-ItemProperty';    Regex = '\bNew-ItemProperty\b' }
    @{ Name = 'Remove-ItemProperty'; Regex = '\bRemove-ItemProperty\b' }
    @{ Name = 'Remove-Item';         Regex = '\bRemove-Item\b' }
    @{ Name = 'New-Item';            Regex = '\bNew-Item\b' }
    @{ Name = 'Set-Service';         Regex = '\bSet-Service\b' }
    @{ Name = 'Stop-Service';        Regex = '\bStop-Service\b' }
    @{ Name = 'Start-Service';       Regex = '\bStart-Service\b' }
    @{ Name = 'Stop-Process';        Regex = '\bStop-Process\b' }
    @{ Name = 'ScheduledTask';       Regex = '\b(Set|Disable|Enable)-ScheduledTask\b' }
    @{ Name = 'NetAdapter';          Regex = '\b(Set|Disable|Enable)-NetAdapter\b' }
)

# File / provider writes that are NOT ShouldProcess-guarded.
$fileRules = @(
    @{ Name = 'Set-Content';  Regex = '\b(Set-Content|Add-Content|Out-File)\b' }
    @{ Name = 'DotNet-File';  Regex = '\[System\.IO\.File\]::(WriteAllText|WriteAllLines|AppendAllText|Delete|Copy|Move)' }
    @{ Name = 'DotNet-Dir';   Regex = '\[System\.IO\.Directory\]::(CreateDirectory|Delete|Move)' }
)

# External executables. Each needs a mutating-verb test, because most invocations
# in this script are actually READS (netsh show, powercfg /getactivescheme ...).
#
# `Base` drives the call-site test: a match only counts when the exe appears in
# command position (start of line, or after & | ; ( ). Without this the catalog
# data at the top of server.ps1 - plain hashtables full of prose like "netsh" and
# "set" - gets counted as thousands of mutations that do not exist.
$exeRules = @(
    @{ Name = 'bcdedit';   Base = 'bcdedit';   Mutating = '\s/(set|create|delete|export|import|copy)\b' }
    @{ Name = 'netsh';     Base = 'netsh';     Mutating = '\s(set|add|delete|reset|import)\s' }
    @{ Name = 'powercfg';  Base = 'powercfg';  Mutating = '(-|/)(setactive|change|delete|setacvalueindex|setdcvalueindex|restoredefaultschemes|setactiveoverlayscheme)' }
    @{ Name = 'sc.exe';    Base = 'sc';        Mutating = '\s(config|stop|start|delete|create)\s' }
    @{ Name = 'reg.exe';   Base = 'reg';       Mutating = '\s(add|delete|import|copy|load|unload)\s' }
    @{ Name = 'schtasks';  Base = 'schtasks';  Mutating = '\s/(create|change|delete|run|end)\b' }
    @{ Name = 'taskkill';  Base = 'taskkill' }
    @{ Name = 'fsutil';    Base = 'fsutil';    Mutating = '\s(set|dirty|repair)\b' }
    @{ Name = 'CimMethod'; Base = $null;       Regex = '\bInvoke-CimMethod\b' }
    @{ Name = 'Defender';  Base = $null;       Regex = '\b(Set|Add)-MpPreference\b' }
    @{ Name = 'Appx';      Base = $null;       Regex = '\bRemove-AppxPackage\b' }
)

$lines = Get-Content -LiteralPath $ServerScript
$currentFn = '<script scope>'
$findings = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $lineNo = $i + 1

    $fnMatch = [regex]::Match($line, '^\s*function\s+([A-Za-z0-9_-]+)')
    if ($fnMatch.Success) { $currentFn = $fnMatch.Groups[1].Value }

    # Skip comments: a mutation named only in a comment is not a call site.
    $isComment = $line.TrimStart().StartsWith('#')

    foreach ($rule in $cmdletRules) {
        if (-not $isComment -and $line -match $rule.Regex) {
            $findings.Add([pscustomobject]@{ Line = $lineNo; Function = $currentFn; Kind = 'cmdlet'; Name = $rule.Name; Code = $line.Trim() })
        }
    }
    foreach ($rule in $fileRules) {
        if (-not $isComment -and $line -match $rule.Regex) {
            $findings.Add([pscustomobject]@{ Line = $lineNo; Function = $currentFn; Kind = 'file'; Name = $rule.Name; Code = $line.Trim() })
        }
    }
    foreach ($rule in $exeRules) {
        if ($isComment) { continue }

        # Require the exe in command position, not merely mentioned in prose.
        if ($rule.Base) {
            $callRegex = '(^|[&|;({]\s*)' + [regex]::Escape($rule.Base) + '(\.exe)?\b'
            if ($line -notmatch $callRegex) { continue }
        } elseif (-not ($line -match $rule.Regex)) { continue }

        $mutating = $true
        if ($rule.ContainsKey('Mutating')) { $mutating = ($line -match $rule.Mutating) }
        # bcdedit /enum is a read; anything else rewrites the boot configuration.
        if ($rule.Name -eq 'bcdedit' -and $line -match '/enum') { $mutating = $false }

        $findings.Add([pscustomobject]@{
            Line     = $lineNo
            Function = $currentFn
            Kind     = $(if ($mutating) { 'external' } else { 'external-read' })
            Name     = $rule.Name
            Code     = $line.Trim()
        })
    }
}

$mutating = @($findings | Where-Object { $_.Kind -in @('cmdlet', 'file', 'external') })
$reads    = @($findings | Where-Object { $_.Kind -eq 'external-read' })

Write-Host "`n=== server.ps1 MUTATION INVENTORY ===" -ForegroundColor Cyan
Write-Host ("Script          : {0}" -f $ServerScript)
Write-Host ("Lines           : {0}" -f $lines.Count)
Write-Host ("Mutating calls  : {0}" -f $mutating.Count) -ForegroundColor Yellow
Write-Host ("External reads  : {0}  (safe, listed only to prove they were classified)" -f $reads.Count) -ForegroundColor DarkGray

$byKind = $mutating | Group-Object Kind | Sort-Object Count -Descending
Write-Host "`n--- by mechanism ---" -ForegroundColor Cyan
foreach ($g in $byKind) {
    $note = switch ($g.Name) {
        'cmdlet'   { 'neutered free by $WhatIfPreference' }
        'file'     { 'NOT ShouldProcess-guarded - needs explicit guard' }
        'external' { 'IGNORES $WhatIfPreference - needs interception' }
        default    { '' }
    }
    Write-Host ("  {0,-10} {1,4}   {2}" -f $g.Name, $g.Count, $note)
}

Write-Host "`n--- the calls a naive dry-run would MISS ---" -ForegroundColor Red
$risky = @($mutating | Where-Object { $_.Kind -ne 'cmdlet' })
Write-Host ("  {0} call sites" -f $risky.Count) -ForegroundColor Red
foreach ($r in $risky) {
    $code = if ($r.Code.Length -gt 96) { $r.Code.Substring(0, 96) + '...' } else { $r.Code }
    Write-Host ("  {0,5}  {1,-26} {2,-9} {3}" -f $r.Line, $r.Function, $r.Name, $code)
}

if ($ShowReads) {
    Write-Host "`n--- external invocations classified as READS (must still pass through) ---" -ForegroundColor Green
    foreach ($r in $reads) {
        $code = if ($r.Code.Length -gt 96) { $r.Code.Substring(0, 96) + '...' } else { $r.Code }
        Write-Host ("  {0,5}  {1,-26} {2,-14} {3}" -f $r.Line, $r.Function, $r.Name, $code)
    }
}

Write-Host "`n--- mutating call sites per function ---" -ForegroundColor Cyan
$mutating | Group-Object Function | Sort-Object Count -Descending | ForEach-Object {
    $ext = @($_.Group | Where-Object { $_.Kind -eq 'external' }).Count
    Write-Host ("  {0,-26} {1,3} total  ({2} external)" -f $_.Name, $_.Count, $ext)
}
Write-Host ""
