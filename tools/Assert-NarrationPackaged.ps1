param([string]$ArchivePath = '', [string]$ManifestPath = '', [string]$CloneManifestPath = '', [string]$VadManifestPath = '', [string]$ComicManifestPath = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $workspace 'third_party/narration/model.json' }
if (-not $CloneManifestPath) { $CloneManifestPath = Join-Path $workspace 'third_party/narration/clone_model.json' }
if (-not $VadManifestPath) { $VadManifestPath = Join-Path $workspace 'third_party/narration/vad_model.json' }
if (-not $ComicManifestPath) { $ComicManifestPath = Join-Path $workspace 'third_party/comic-ocr/model.json' }
$sourceChecks = @(
    @('app/godot/scripts/narration_settings.gd', '(?m)^static var FEATURE_ENABLED := true\s*$'),
    @('android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/NarrationPolicy.kt', '(?m)^\s*const val FEATURE_ENABLED = BuildConfig\.NARRATION_ENABLED\s*$')
)
foreach ($check in $sourceChecks) {
    if ((Get-Content -LiteralPath (Join-Path $workspace $check[0]) -Raw) -notmatch $check[1]) { throw "Default subtitle narration is disabled: $($check[0])" }
}
if (-not $ArchivePath) { return }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $prefix = if ($ArchivePath.EndsWith('.apk')) { 'lib' } else { 'jni' }
    foreach ($name in @("$prefix/arm64-v8a/libquest_narration.so", "$prefix/arm64-v8a/libonnxruntime.so")) {
        $entry = $zip.GetEntry($name)
        if (-not $entry -or $entry.Length -le 0) { throw "Narration package is missing: $name" }
    }
    foreach ($bundle in @(@{ path=$ManifestPath; asset='model.json' }, @{ path=$CloneManifestPath; asset='clone_model.json' }, @{ path=$VadManifestPath; asset='vad_model.json' }, @{ path=$ComicManifestPath; asset='model.json'; prefix='comic-ocr' })) {
    $manifestBytes = [IO.File]::ReadAllBytes($bundle.path)
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    if ($manifest.directory -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe model directory.' }
    $assetPrefix = if ($bundle.ContainsKey('prefix')) { $bundle.prefix } else { 'narration' }
    $entry = $zip.GetEntry('assets/' + $assetPrefix + '/' + $bundle.asset)
    if (-not $entry) { throw 'Narration package is missing its manifest.' }
    $stream = $entry.Open(); $copy = [IO.MemoryStream]::new()
    try { $stream.CopyTo($copy); $actualManifest = $copy.ToArray() } finally { $stream.Dispose(); $copy.Dispose() }
    if ([Convert]::ToBase64String($actualManifest) -ne [Convert]::ToBase64String($manifestBytes)) { throw 'Packaged narration manifest differs.' }
    foreach ($file in $manifest.files.PSObject.Properties) {
        if ($file.Name -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe model file path.' }
        $name = 'assets/' + $manifest.directory + '/' + $file.Name
        $entry = $zip.GetEntry($name)
        if (-not $entry -or $entry.Length -ne $file.Value.bytes) { throw "Narration package is missing or has incorrect model bytes: $name" }
        $stream = $entry.Open(); $digest = [Security.Cryptography.SHA256]::Create()
        try { $actual = -join ($digest.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
        finally { $stream.Dispose(); $digest.Dispose() }
        if ($actual -ne $file.Value.sha256) { throw "Packaged narration model digest differs: $name" }
    }
    }
} finally { $zip.Dispose() }
