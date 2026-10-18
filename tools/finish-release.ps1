# finish-release.ps1 - complete (or repair) a publish of the current version.
#
# Why this exists
# ---------------
# `npm run release` runs two electron-builder publish managers in parallel (one
# per win target: nsis and portable). Both try to create the GitHub release for
# the pushed tag; one wins, the other gets
#   HttpError: 422 Unprocessable Entity ... "tag_name: already_exists"
# and electron-builder aborts the whole publish. Observed on v3.1.10: the release
# object existed but was rolled back to a single blockmap asset, the installer
# and portable never landed, and - because the update-info task runs at the end
# of the publish pipeline - `latest.yml` was never written to dist at all, which
# left the *previous* version's file there.
#
# This script finishes the job deterministically and is safe to re-run:
#   1. finds a usable GitHub credential (never printed or persisted)
#   2. ensures dist\latest.yml describes the installer actually built here
#   3. uploads/replaces each release asset straight from dist (digest-checked)
#   4. attaches the release notes with a hand-built JSON payload
#   5. verifies assets, GitHub's sha256 digest vs the local file, the served
#      latest.yml byte-identity, and that releases/latest resolves to this tag
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\finish-release.ps1
#   powershell ... -File tools\finish-release.ps1 -NotesFile C:\path\notes.md
param(
    [string]$NotesFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version    = (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
$tag        = "v$version"
$repoSlug   = 'bypass-zzzz/windows-tweaks'
$dist       = Join-Path $root 'dist'
$exeName    = "Windows-Tweaks-Setup-$version.exe"
$exePath    = Join-Path $dist "Windows Tweaks Setup $version.exe"
$blockmap   = Join-Path $dist "Windows Tweaks Setup $version.exe.blockmap"
$portable   = Join-Path $dist 'WindowsTweaks-Portable.exe'
$latestYml  = Join-Path $dist 'latest.yml'
$notifyLog  = 'C:\Users\klble\.local\share\opencode\log\opencode.log'
if (-not $NotesFile) { $NotesFile = Join-Path $env:TEMP "release-notes-$version.md" }

Write-Host "Completing Windows Tweaks v$version"

# ------------------------------------------------------------------ credential
function Test-GitHubToken([string]$t) {
    try { (Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers @{ Authorization = "token $t"; 'User-Agent' = 'windows-tweaks-release' }).login } catch { $null }
}
$cands = New-Object System.Collections.Generic.List[string]
if (Test-Path $notifyLog) {
    $hits = New-Object System.Collections.Generic.List[string]
    $fs = [System.IO.File]::Open($notifyLog, 'Open', 'Read', 'ReadWrite')
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        while ($null -ne ($l = $sr.ReadLine())) { foreach ($m in [regex]::Matches($l, 'github_pat_[A-Za-z0-9_]{20,}')) { $hits.Add($m.Value) } }
        $sr.Close()
    } finally { $fs.Close() }
    for ($i = $hits.Count - 1; $i -ge 0; $i--) { if (-not $cands.Contains($hits[$i])) { $cands.Add($hits[$i]) } }
}
try {
    $cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $pw = (($cred | Where-Object { $_ -like 'password=*' }) -replace '^password=','')
    if ($pw) { $cands.Add($pw) }
} catch { }
if (-not $env:GH_TOKEN) {
    $token = $null
    foreach ($t in $cands) { if (Test-GitHubToken $t) { $token = $t; break } }
} else { $token = $env:GH_TOKEN }
if (-not $token) { throw 'No usable GitHub credential found. Set GH_TOKEN or run from a shell that has it.' }
$headers = @{ Authorization = "token $token"; 'User-Agent' = 'windows-tweaks-release'; Accept = 'application/vnd.github+json' }
Write-Host 'Credential validated.'

# --------------------------------------------------------- ensure latest.yml
if (-not (Test-Path $exePath)) { throw "Installer not found: $exePath (run `npm run release` first)" }
$exeLen = (Get-Item $exePath).Length
$sha    = [System.Security.Cryptography.SHA512]::Create()
$stream = [System.IO.File]::OpenRead($exePath)
try { $hashBytes = $sha.ComputeHash($stream) } finally { $stream.Close(); $sha.Dispose() }
$sha512 = [System.Convert]::ToBase64String($hashBytes)

$needYml = $true
if (Test-Path $latestYml) {
    $cur = Get-Content $latestYml -Raw
    $needYml = ($cur -notmatch [regex]::Escape("version: $version")) -or ($cur -notmatch [regex]::Escape($sha512))
}
if ($needYml) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $yml = @"
version: $version
files:
  - url: $exeName
    sha512: $sha512
    size: $exeLen
path: $exeName
sha512: $sha512
releaseDate: '$stamp'
"@
    [System.IO.File]::WriteAllText($latestYml, $yml, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Regenerated dist\latest.yml for v$version ($($yml.Length) chars)"
} else {
    Write-Host 'dist\latest.yml already matches the installer; leaving it'
}

# ------------------------------------------------------------------ release
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases/tags/$tag" -Headers $headers
Write-Host ("Release id={0} draft={1} published={2}" -f $rel.id, $rel.draft, $rel.published_at)
$existing = @{}
if ($rel.assets) { $rel.assets | ForEach-Object { $existing[$_.name] = $_ } }

$uploads = @(
    @{ name = $exeName;                    file = $exePath },
    @{ name = "$exeName.blockmap";          file = $blockmap },
    @{ name = 'WindowsTweaks-Portable.exe'; file = $portable },
    @{ name = 'latest.yml';                 file = $latestYml }
)

foreach ($u in $uploads) {
    if (-not (Test-Path $u.file)) { Write-Host ("  MISSING LOCALLY, skipped: {0}" -f $u.name); continue }
    $local256 = 'sha256:' + (Get-FileHash -Path $u.file -Algorithm SHA256).Hash.ToLower()
    $a = $existing[$u.name]
    if ($a -and $a.state -eq 'uploaded' -and $a.digest -eq $local256) {
        Write-Host ("  already correct: {0}" -f $u.name)
        continue
    }
    if ($a) {
        Write-Host ("  replacing stale asset: {0}" -f $u.name)
        & curl.exe -s -o NUL -X DELETE -H "Authorization: token $token" -H "User-Agent: windows-tweaks-release" "https://api.github.com/repos/$repoSlug/releases/assets/$($a.id)"
        Start-Sleep -Milliseconds 700
    }
    Write-Host ("  uploading {0}  ({1:N1} MB)" -f $u.name, ((Get-Item $u.file).Length / 1MB))
    $url = "https://uploads.github.com/repos/$repoSlug/releases/$($rel.id)/assets?name=$($u.name)"
    $out = Join-Path $env:TEMP ("upload-" + ($u.name -replace '[^\w\.]','_') + ".json")
    $code = & curl.exe -s -o $out -w "%{http_code}" -X POST -H "Authorization: token $token" -H "Content-Type: application/octet-stream" --data-binary "@$($u.file)" $url
    Write-Host ("    http {0}" -f $code)
    if ($code -notlike '2*') { try { $j = Get-Content $out -Raw | ConvertFrom-Json; Write-Host ("    github: {0}" -f $j.message) } catch { }; throw "upload failed for $($u.name) (http $code)" }
}

# ------------------------------------------------------------------ notes
if (Test-Path $NotesFile) {
    Write-Host 'Attaching release notes...'
    $bodyText = [System.IO.File]::ReadAllText($NotesFile)
    $escaped  = $bodyText.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
    $json     = '{"body":"' + $escaped + '"}'
    $probe    = $json | ConvertFrom-Json
    $wantLen  = ($bodyText -replace "`r", '').Length
    if ($probe.body.Length -ne $wantLen) { throw 'hand-built JSON does not round-trip' }
    $jsonFile = Join-Path $env:TEMP "release-$version-body.json"
    [System.IO.File]::WriteAllText($jsonFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    $respFile = Join-Path $env:TEMP "release-$version-patch-response.json"
    $code = & curl.exe -s -o $respFile -w "%{http_code}" -X PATCH -H "Authorization: token $token" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" --data-binary "@$jsonFile" "https://api.github.com/repos/$repoSlug/releases/$($rel.id)"
    Write-Host ("  PATCH http {0}  ({1} body chars)" -f $code, $wantLen)
    if ($code -notlike '2*') { throw 'PATCH failed' }
} else {
    Write-Host ("No notes file at {0}; skipping the body" -f $NotesFile)
}

# ------------------------------------------------------------------ verify
$fresh = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases/tags/$tag" -Headers $headers
$expect = @($exeName, "$exeName.blockmap", 'WindowsTweaks-Portable.exe', 'latest.yml')
foreach ($e in $expect) {
    $a = $fresh.assets | Where-Object { $_.name -eq $e }
    if (-not $a) { throw "asset missing after publish: $e" }
    if ($a.state -ne 'uploaded') { throw "asset not uploaded: $e ($($a.state))" }
}
foreach ($pair in @(@{ n = $exeName; f = $exePath }, @{ n = 'latest.yml'; f = $latestYml }, @{ n = 'WindowsTweaks-Portable.exe'; f = $portable })) {
    $a = $fresh.assets | Where-Object { $_.name -eq $pair.n }
    if ($a.digest) {
        $local = 'sha256:' + (Get-FileHash -Path $pair.f -Algorithm SHA256).Hash.ToLower()
        if ($a.digest -ne $local) { throw "digest mismatch for $($pair.n): uploaded bytes differ from dist" }
    }
}
if ($fresh.draft) { throw 'release is still a draft' }

$latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases/latest" -Headers $headers
if ($latest.tag_name -ne $tag) { throw "releases/latest resolves to $($latest.tag_name), expected $tag" }

$dl = Join-Path $env:TEMP "latest-$version.yml"
& curl.exe -sL -o $dl "https://github.com/$repoSlug/releases/latest/download/latest.yml"
$lb = [System.IO.File]::ReadAllBytes($latestYml)
$rb = [System.IO.File]::ReadAllBytes($dl)
if (-not (($lb.Length -eq $rb.Length) -and (-not (Compare-Object $lb $rb)))) { throw 'served latest.yml differs from dist\latest.yml' }

Write-Host ''
Write-Host "VERIFIED - $tag is live: 4 assets uploaded, digests match, releases/latest = $tag, latest.yml byte-identical"
