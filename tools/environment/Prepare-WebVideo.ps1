param()
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$manifest = Get-Content -LiteralPath (Join-Path $workspace 'third_party/web-video/runtime.json') -Raw | ConvertFrom-Json
$directory = Join-Path $workspace 'build/web-video'
$target = Join-Path $directory 'yt-dlp.zip'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
function Test-WebVideoRuntime([string]$Path) {
    (Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -eq $manifest.bytes -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $manifest.sha256
}
if (-not (Test-WebVideoRuntime $target)) {
    $download = Join-Path $directory ('download-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Invoke-WebRequest -Uri $manifest.url -OutFile $download
        if (-not (Test-WebVideoRuntime $download)) { throw 'Web video runtime integrity check failed.' }
        Move-Item -LiteralPath $download -Destination $target -Force
    } finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download } }
}
Write-Output "Web video extractor verified: $($manifest.version)"
