[CmdletBinding()]
param([ValidateSet('stable', 'nightly', 'both')][string]$Channel = 'both')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pin = Get-Content -LiteralPath (Join-Path $root 'third_party/web-video/runtime.json') -Raw | ConvertFrom-Json
$channels = if ($Channel -eq 'both') { @('stable', 'nightly') } else { @($Channel) }
foreach ($name in $channels) {
    $repo = if ($name -eq 'stable') { 'yt-dlp/yt-dlp' } else { 'yt-dlp/yt-dlp-nightly-builds' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Thru3D-runtime-maintenance' } -TimeoutSec 30
    $assets = @($release.assets | Where-Object name -eq 'yt-dlp')
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "Missing unambiguous yt-dlp asset/digest in $repo. Review upstream manually."
    }
    $asset = $assets[0]
    [pscustomobject]@{
        channel = $name
        current = $pin.version
        latest = $release.tag_name
        same_version = $pin.version -eq $release.tag_name
        same_asset = $pin.sha256 -eq $asset.digest.Substring(7)
        published = $release.published_at
        release = $release.html_url
        url = $asset.browser_download_url
        bytes = $asset.size
        sha256 = $asset.digest.Substring(7)
    }
}
