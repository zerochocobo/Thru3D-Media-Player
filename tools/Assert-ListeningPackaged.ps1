param([Parameter(Mandatory)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root 'third_party/moonshine/model.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$receipt = Get-Content (Join-Path $root 'build/listening-runtime/receipt.json') -Raw | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash.ToLowerInvariant()
if ($receipt.revision -ne $manifest.revision -or $receipt.manifest_sha256 -ne $manifestHash -or
    $receipt.builder_sha256 -ne (Get-FileHash (Join-Path $root 'tools/environment/Build-ListeningRuntime.ps1')).Hash.ToLowerInvariant()) { throw 'Stale Moonshine source-build receipt; prepare listening again.' }
if ($receipt.patcher_sha256 -ne (Get-FileHash (Join-Path $root 'tools/moonshine/patch_runtime.py')).Hash.ToLowerInvariant()) { throw 'Stale Moonshine lifetime patch receipt.' }
$runtime = & "$PSScriptRoot/Assert-ListeningRuntime.ps1" -LibraryPath (Join-Path $root 'android/player-plugin/src/main/jniLibs/arm64-v8a/libmoonshine.so')
if ($receipt.library.sha256 -ne $runtime.sha256) { throw 'Moonshine binary differs from the verified source build.' }
$ort = Get-Content (Join-Path $root 'third_party/narration/dependencies.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $prefix = if ($ArchivePath.EndsWith('.apk')) { 'lib' } else { 'jni' }
    $checks = @(
        @{ name="assets/moonshine/model.json"; bytes=(Get-Item -LiteralPath $manifestPath).Length; sha256=(Get-FileHash -LiteralPath $manifestPath).Hash },
        @{ name="$prefix/arm64-v8a/libmoonshine.so"; bytes=$runtime.bytes; sha256=$runtime.sha256 }
    )
    foreach ($library in @('quest_listening', 'onnxruntime', 'avformat', 'avcodec', 'avutil', 'swresample')) {
        $entry = $zip.GetEntry("$prefix/arm64-v8a/lib$library.so")
        if (-not $entry -or $entry.Length -le 0) { throw "Listening library missing: $library" }
    }
    foreach ($language in @('zh', 'en', 'ja')) {
        $model = $manifest.models.$language
        if ($model.directory -ne "listening/$language") { throw 'Unexpected listening model directory.' }
        foreach ($file in $model.files.PSObject.Properties) {
            if ($file.Name -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe listening model filename.' }
            $checks += @{ name="assets/$($model.directory)/$($file.Name)"; bytes=$file.Value.bytes; sha256=$file.Value.sha256 }
        }
    }
    foreach ($item in $checks) {
        $entry = $zip.GetEntry($item.name)
        if (-not $entry -or $entry.Length -ne $item.bytes) { throw "Listening asset missing or wrong size: $($item.name)" }
        $stream = $entry.Open(); $digest = [Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($digest.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
        finally { $stream.Dispose(); $digest.Dispose() }
        if ($hash -ne $item.sha256) { throw "Listening asset hash mismatch: $($item.name)" }
    }
    $stream = $zip.GetEntry("$prefix/arm64-v8a/libonnxruntime.so").Open()
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($digest.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $stream.Dispose(); $digest.Dispose() }
    if ($hash -notin @($ort.runtime_library.sha256, $ort.runtime_library.packaged_sha256)) { throw 'Packaged ONNX Runtime differs from the existing pinned library.' }
} finally { $zip.Dispose() }
