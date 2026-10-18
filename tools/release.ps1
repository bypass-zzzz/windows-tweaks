# release.ps1 - publish the current package.json version to GitHub.
#
# Usage (from the repo root or anywhere):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\release.ps1
#
# What it does:
#   1. verifies the branch is main and the working tree is clean
#   2. runs the pre-flight gates (main-process resilience + release-feed guard)
#   3. validates GH_TOKEN (prompting for it with hidden input if not set)
#   4. pushes main so the release tag points at the right commit
#   5. creates and pushes the v<version> tag (must exist before publishing)
#   6. runs `npm run release` (electron-builder --win --x64 --publish always)
#
# If step 6 dies after the release object was created - the two parallel publish
# managers (nsis + portable) race on create-release and one gets
# "422 tag_name already_exists" - the release can be left with missing assets and
# an unwritten latest.yml. Finish it deterministically with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\finish-release.ps1
# which uploads the missing pieces, regenerates latest.yml, attaches the notes
# and verifies everything. Do not try to "fix" it with a second `npm run release`.
#
# The publish config in package.json targets bypass-zzzz/windows-tweaks and
# releaseType "release", so this creates a published release tagged
# v<version> with the installer, blockmap and latest.yml attached. The
# default release name is "<version>" - rename it and add notes on GitHub if
# a custom title is wanted (the publisher does not set a body).
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

# ── Pre-flight gates (fast, hermetic) ────────────────────────────────────────
# The update feed must stay public and token-free, and the main process must
# survive its resilience suite; both have caught real regressions already. Do
# not bypass: a bad feed here is the outage that stranded pre-3.1.5 installs.
Write-Host ''
Write-Host 'Running pre-flight gates...'
& node (Join-Path $root 'tools\test-main-resilience.js')
if ($LASTEXITCODE -ne 0) { throw 'test-main-resilience.js failed. Aborting.' }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test-multipath-writes.ps1')
if ($LASTEXITCODE -ne 0) { throw 'test-multipath-writes.ps1 failed. Aborting.' }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test-composite-writes.ps1')
if ($LASTEXITCODE -ne 0) { throw 'test-composite-writes.ps1 failed. Aborting.' }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test-release-feed.ps1')
if ($LASTEXITCODE -ne 0) { throw 'test-release-feed.ps1 failed. Aborting.' }
Write-Host 'Pre-flight gates passed.'
Write-Host ''

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

# Ensure the release tag exists first. Creating a *published* GitHub release
# for a missing tag fails with "Published releases must have a valid tag";
# with the tag pushed first, the publisher attaches to it directly.
$tag = "v$version"
$existing = git rev-parse --verify --quiet "refs/tags/$tag"
if (-not $existing) {
    git tag $tag
    Write-Host "Created tag $tag"
}
git push origin $tag
if ($LASTEXITCODE -ne 0) { throw "Failed to push tag $tag. Aborting." }

# Note: if a publish run dies after the release is created, just re-run - the
# publisher appends missing assets to a recent published release (within 2
# hours; EP_GH_IGNORE_TIME=1 lifts that window).
npm run release
if ($LASTEXITCODE -ne 0) {
    throw 'electron-builder publish failed. If the release object already exists, run tools\finish-release.ps1 to complete it (it uploads the missing assets, rewrites latest.yml and attaches the notes).'
}

Write-Host ''
Write-Host "Done. Release: https://github.com/bypass-zzzz/windows-tweaks/releases/tag/v$version"
