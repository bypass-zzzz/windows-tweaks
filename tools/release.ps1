# release.ps1 - publish the current package.json version to GitHub.
#
# Usage (from the repo root or anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1
#
# What it does:
#   1. verifies the branch is main and the working tree is clean
#   2. validates GH_TOKEN (prompting for it with hidden input if not set)
#   3. pushes main so the release tag points at the right commit
#   4. runs `npm run release` (electron-builder --win --x64 --publish always)
#
# The publish config in package.json targets bypass-zzzz/windows-tweaks and
# releaseType "release", so this creates a published release tagged
# v<version> with the installer, blockmap and latest.yml attached. The
# default release name is "v<version>" - rename it on GitHub if a custom
# title is wanted.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
Write-Host "Releasing Windows Tweaks v$version"

$branch = (git rev-parse --abbrev-ref HEAD)
if ($branch -ne 'main') { throw "Current branch is '$branch', expected 'main'. Aborting." }

$dirty = git status --porcelain
if ($dirty) {
    Write-Warning 'Working tree is not clean:'
    $dirty | ForEach-Object { Write-Host "  $_" }
    throw 'Commit or stash the changes first. Aborting.'
}

if (-not $env:GH_TOKEN) {
    $secure = Read-Host -Prompt 'GitHub token (GH_TOKEN, input hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $env:GH_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $env:GH_TOKEN) { throw 'No GH_TOKEN provided. Aborting.' }

# fail fast on a bad token before spending minutes on the build
try {
    $null = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers @{ Authorization = "token $env:GH_TOKEN"; 'User-Agent' = 'windows-tweaks-release' }
    Write-Host 'GH_TOKEN validated.'
} catch {
    throw "GH_TOKEN failed validation: $($_.Exception.Message)"
}

git push origin main
if ($LASTEXITCODE -ne 0) { throw 'git push failed. Aborting.' }

npm run release
if ($LASTEXITCODE -ne 0) { throw 'electron-builder publish failed.' }

Write-Host ''
Write-Host "Done. Release: https://github.com/bypass-zzzz/windows-tweaks/releases/tag/v$version"
