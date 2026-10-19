$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $workspace ('build/output/narration-package-check/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$bytes = [Text.Encoding]::UTF8.GetBytes('verified test model')
$digest = [Security.Cryptography.SHA256]::Create()
try { $hash = -join ($digest.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $digest.Dispose() }
$manifest = @{ id='test'; directory='narration/test'; files=@{ 'model/weights.data'=@{ bytes=$bytes.Length; sha256=$hash } } } | ConvertTo-Json -Depth 5
$manifestPath = Join-Path $output 'model.json'
[IO.File]::WriteAllText($manifestPath,$manifest,[Text.UTF8Encoding]::new($false))
$cloneManifestPath = Join-Path $output 'clone_model.json'
$cloneManifest = @{ id='clone-test'; directory='narration/clone-test'; files=@{ 'encoder.data'=@{ bytes=$bytes.Length; sha256=$hash } } } | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($cloneManifestPath,$cloneManifest,[Text.UTF8Encoding]::new($false))
$checks = 0
foreach ($format in @('aar','apk')) {
    foreach ($fault in @('none','runtime','manifest','weights','length','digest','manifest-drift','clone-manifest','clone-weights','clone-digest')) {
        $path = Join-Path $output "$format-$fault.$format"
        $zip = [IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $prefix = if ($format -eq 'apk') { 'lib' } else { 'jni' }
            $entries = @{
                "$prefix/arm64-v8a/libquest_narration.so"=[byte[]]@(1)
                "$prefix/arm64-v8a/libonnxruntime.so"=[byte[]]@(1)
                'assets/narration/model.json'=[IO.File]::ReadAllBytes($manifestPath)
                'assets/narration/clone_model.json'=[IO.File]::ReadAllBytes($cloneManifestPath)
                'assets/narration/clone-test/encoder.data'=$bytes
                'assets/narration/test/model/weights.data'=$bytes
            }
            switch ($fault) {
                'runtime' { $entries.Remove("$prefix/arm64-v8a/libonnxruntime.so") }
                'manifest' { $entries.Remove('assets/narration/model.json') }
                'weights' { $entries.Remove('assets/narration/test/model/weights.data') }
                'length' { $entries['assets/narration/test/model/weights.data']=[byte[]]@(1) }
                'digest' { $entries['assets/narration/test/model/weights.data']=[byte[]]::new($bytes.Length) }
                'manifest-drift' { $entries['assets/narration/model.json']=[Text.Encoding]::UTF8.GetBytes('{}') }
                'clone-manifest' { $entries.Remove('assets/narration/clone_model.json') }
                'clone-weights' { $entries.Remove('assets/narration/clone-test/encoder.data') }
                'clone-digest' { $entries['assets/narration/clone-test/encoder.data']=[byte[]]::new($bytes.Length) }
            }
            foreach ($name in $entries.Keys) {
                $stream=$zip.CreateEntry($name).Open()
                try { $stream.Write($entries[$name],0,$entries[$name].Length) } finally { $stream.Dispose() }
            }
        } finally { $zip.Dispose() }
        $rejected=$false
        try { & "$workspace/tools/Assert-NarrationPackaged.ps1" -ArchivePath $path -ManifestPath $manifestPath -CloneManifestPath $cloneManifestPath }
        catch { $rejected=$true }
        if ($rejected -ne ($fault -ne 'none')) { throw "Wrong narration package result: $format/$fault" }
        $checks++
    }
}
Write-Output "Default narration package checks=$checks failures=0"
