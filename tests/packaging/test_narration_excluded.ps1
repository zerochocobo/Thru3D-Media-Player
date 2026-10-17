$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$guard = Join-Path $workspace 'tools/Assert-NarrationExcluded.ps1'
$output = Join-Path $workspace ('build/output/narration-exclusion/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$cases = @(
    'lib/arm64-v8a/libquest_narration.so',
    'jni/arm64-v8a/libonnxruntime.so',
    'lib/x86_64/libonnxruntime_providers_shared.so',
    'assets/narration/model.json',
    'assets/narration/presets/Yuewen.wav',
    'assets/MOSS-TTS-Nano-100M-ONNX/browser_poc_manifest.json',
    'assets/MOSS-Audio-Tokenizer-Nano-ONNX/codec_browser_onnx_meta.json',
    'assets/moss-nano-int8-20261017/voice.bin',
    'assets/other/moss_tts_prefill.onnx',
    'assets/other/moss_audio_tokenizer_decode_step.onnx',
    'assets/other/tokenizer.model',
    'assets/other/shared_weights.data'
)
$checks = 0
foreach ($forbidden in @('') + $cases) {
    $path = Join-Path $output ("case-$checks.zip")
    $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($safe in @('assets/rvm-mnn/rvm.mnn', 'assets/depth-mnn/depth.mnn', 'lib/arm64-v8a/libquest_mpv.so')) {
            $zip.CreateEntry($safe) | Out-Null
        }
        if ($forbidden) { $zip.CreateEntry($forbidden) | Out-Null }
    } finally { $zip.Dispose() }
    $rejected = $false
    try { & $guard -ArchivePath $path }
    catch {
        if ($_.Exception.Message -notlike 'Withheld subtitle narration*') { throw }
        $rejected = $true
    }
    if ($rejected -ne [bool]$forbidden) { throw "Wrong package exclusion result: $forbidden" }
    $checks++
}
Write-Output "Narration package exclusion checks=$checks failures=0"
