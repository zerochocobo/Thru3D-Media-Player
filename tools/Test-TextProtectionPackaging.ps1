# Exercise the production package gate using small fixture AARs, never real APKs or signing material.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace ('build/output/text-protection/package-check/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$tiny = Join-Path $workspace 'third_party/text-protection/model.json'
$manifest = Get-Content -LiteralPath $tiny -Raw | ConvertFrom-Json
$model = Join-Path $workspace ('models/text-protection/' + $manifest.id + '/multi_PP-OCRv6_det_tiny.onnx')
& "$PSScriptRoot/Assert-TextProtectionModel.ps1"
$empty = Join-Path $output 'standin.json'
[IO.File]::WriteAllText($empty, '{"id":"fixture","directory":"fixture-models","files":{}}')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$checks = 0
foreach ($variant in @('valid', 'missing', 'damaged', 'manifest')) {
    $path = Join-Path $output ($variant + '.aar')
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = @{
            'jni/arm64-v8a/libquest_narration.so' = [byte[]]@(1)
            'jni/arm64-v8a/libonnxruntime.so' = [byte[]]@(1)
            'assets/narration/model.json' = [IO.File]::ReadAllBytes($empty)
            'assets/narration/clone_model.json' = [IO.File]::ReadAllBytes($empty)
            'assets/narration/vad_model.json' = [IO.File]::ReadAllBytes($empty)
            'assets/comic-ocr/model.json' = [IO.File]::ReadAllBytes($empty)
            'assets/text-protection/model.json' = [IO.File]::ReadAllBytes($tiny)
        }
        if ($variant -eq 'manifest') { $entries['assets/text-protection/model.json'] = [IO.File]::ReadAllBytes($empty) }
        if ($variant -ne 'missing') {
            $bytes = [IO.File]::ReadAllBytes($model)
            if ($variant -eq 'damaged') { $bytes[0] = $bytes[0] -bxor 1 }
            $entries['assets/' + $manifest.directory + '/multi_PP-OCRv6_det_tiny.onnx'] = $bytes
        }
        foreach ($item in $entries.GetEnumerator()) {
            $entry = $zip.CreateEntry($item.Key); $stream = $entry.Open()
            try { $stream.Write($item.Value, 0, $item.Value.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $rejected = $false
    try { & "$PSScriptRoot/Assert-NarrationPackaged.ps1" -ArchivePath $path -ManifestPath $empty -CloneManifestPath $empty -VadManifestPath $empty -ComicManifestPath $empty }
    catch {
        if ($_.Exception.Message -notmatch '(missing|differs|incorrect)') { throw }
        $rejected = $true
    }
    if ($rejected -ne ($variant -ne 'valid')) { throw "Text model gate did not handle $variant correctly." }
    $checks++
}
$rejected = $false
try { & "$PSScriptRoot/Assert-TextProtectionModel.ps1" -ModelRoot $output }
catch { if ($_.Exception.Message -notmatch 'Missing Tiny text detector') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Missing source Tiny model was accepted.' }
$checks++
Write-Output "Text protection package/source gate checks=$checks failures=0"
