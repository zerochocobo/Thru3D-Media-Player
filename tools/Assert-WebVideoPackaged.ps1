param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pinPath = Join-Path $root 'third_party/web-video/runtime.json'
$pin = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    foreach ($name in @('libpython.so', 'libpython.zip.so', 'libqjs.so', 'libxul.so', 'libmozglue.so', 'libplugin-container.so')) {
        $entry = $zip.GetEntry("lib/arm64-v8a/$name")
        if (-not $entry -or $entry.Length -le 0) { throw "Web runtime library missing: $name" }
    }
    $omni = $zip.GetEntry('assets/omni.ja')
    if (-not $omni -or $omni.Length -lt 1MB) { throw 'Gecko runtime resources missing.' }
    $checks = @(
        @{ name='assets/web-video/yt-dlp.zip'; bytes=$pin.bytes; sha256=$pin.sha256 },
        @{ name='assets/web-video/runtime.json'; bytes=(Get-Item $pinPath).Length; sha256=(Get-FileHash $pinPath).Hash }
    )
    $bootstrap = Join-Path $root 'android/player-plugin/src/main/assets/web-video/extract.py'
    $checks += @{ name='assets/web-video/extract.py'; bytes=(Get-Item $bootstrap).Length; sha256=(Get-FileHash $bootstrap).Hash }
    foreach ($name in @('manifest.json', 'media.js', 'background.js', 'network.js', 'bilibili.js', 'bilibili-response.js')) {
        $path = Join-Path $root "android/web-browser/src/main/assets/web-browser/$name"
        $checks += @{ name="assets/web-browser/$name"; bytes=(Get-Item $path).Length; sha256=(Get-FileHash $path).Hash }
    }
    foreach ($check in $checks) {
        $entry = $zip.GetEntry($check.name)
        if (-not $entry -or $entry.Length -ne $check.bytes) { throw "Web asset missing or wrong size: $($check.name)" }
        $stream = $entry.Open(); $digest = [Security.Cryptography.SHA256]::Create()
        # BitConverter keeps this check working on Windows PowerShell 5.1 as well as 7.
        try { $hash = [BitConverter]::ToString($digest.ComputeHash($stream)).Replace("-", "") }
        finally { $stream.Dispose(); $digest.Dispose() }
        if ($hash -ne $check.sha256) { throw "Web asset differs from source: $($check.name)" }
    }
} finally { $zip.Dispose() }
Write-Host 'Packaged browser resources and pinned extractor verified.'
