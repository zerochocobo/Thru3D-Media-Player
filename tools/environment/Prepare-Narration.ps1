param([string]$Dependencies = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $Dependencies) { $Dependencies = Join-Path $workspace 'tmp/narration-deps' }
$manifest = Get-Content (Join-Path $workspace 'third_party/narration/dependencies.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $Dependencies | Out-Null
foreach ($entry in @($manifest.dependencies) + @($manifest.archives)) {
    $path = Join-Path $Dependencies $entry.file
    & "$PSScriptRoot/Download-Artifact.ps1" -Uri $entry.url -Destination $path -Sha256 $entry.sha256
    if ($entry.folder -and -not (Test-Path -LiteralPath (Join-Path $Dependencies $entry.folder))) {
        & tar -xzf $path -C $Dependencies
        if ($LASTEXITCODE -ne 0) { throw 'Narration dependency extraction failed.' }
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$runtime = Join-Path $Dependencies 'libonnxruntime.so'
if (-not (Test-Path -LiteralPath $runtime) -or (Get-FileHash -LiteralPath $runtime).Hash.ToLowerInvariant() -ne $manifest.runtime_library.sha256) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $Dependencies 'onnxruntime-android-1.28.0.aar'))
    try {
        $entry = $archive.GetEntry('jni/arm64-v8a/libonnxruntime.so')
        if (-not $entry) { throw 'Missing ARM64 ORT library.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $runtime, $true)
    } finally { $archive.Dispose() }
}
if ((Get-FileHash -LiteralPath $runtime).Hash.ToLowerInvariant() -ne $manifest.runtime_library.sha256) { throw 'ORT library digest differs.' }
# Headers only; the APK continues to use its pinned MPV FFmpeg binaries.
$ffmpeg = Join-Path $Dependencies 'FFmpeg-094a2f8a2a5e7fa64736e067de224ce28fdf5979'
$config = Join-Path $ffmpeg 'libavutil/avconfig.h'
$content = "#pragma once`n#define AV_HAVE_BIGENDIAN 0`n#define AV_HAVE_FAST_UNALIGNED 1`n"
if (-not (Test-Path -LiteralPath $config) -or [IO.File]::ReadAllText($config) -ne $content) { [IO.File]::WriteAllText($config, $content) }
Write-Output 'Pinned narration runtime, tokenizer and matching FFmpeg headers prepared.'
