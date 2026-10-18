param([string]$ArchivePath = '', [switch]$AllowDevelopment)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
# Legacy explicit exclusion probe. Normal builds now use Assert-NarrationPackaged.
if ($ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ((!$AllowDevelopment -and ($name -match '(^|/)(libquest_narration|libonnxruntime[^/]*)\.so$' -or $name -match '(^|/)narration/')) -or
                $name -match '(^|/)(moss-nano[^/]*|MOSS-TTS-Nano[^/]*|MOSS-Audio-Tokenizer[^/]*)/' -or
                $name -match '(^|/)(moss_tts_[^/]*|moss_audio_tokenizer_[^/]*|tokenizer\.model|shared_weights\.data)$') {
                throw "Withheld subtitle narration runtime, model or preset found in package: $name"
            }
        }
        if ($AllowDevelopment) {
            $nativePrefix = if ($archive.GetEntry('AndroidManifest.xml') -and $ArchivePath.EndsWith('.apk')) { 'lib' } else { 'jni' }
            foreach ($required in @("$nativePrefix/arm64-v8a/libquest_narration.so", "$nativePrefix/arm64-v8a/libonnxruntime.so", 'assets/narration/model.json')) {
                if (!$archive.GetEntry($required)) { throw "Development package lacks required narration component: $required" }
            }
        }
        $projectEntry = $archive.GetEntry('assets/project.binary')
        if ($projectEntry) {
            $stream = $projectEntry.Open(); $buffer = [IO.MemoryStream]::new()
            try { $stream.CopyTo($buffer); $hasFeature = [Text.Encoding]::UTF8.GetString($buffer.ToArray()).Contains('narration_development') }
            finally { $stream.Dispose(); $buffer.Dispose() }
            if ($hasFeature -ne $AllowDevelopment.IsPresent) { throw 'APK narration development feature does not match the requested build.' }
        }
    } finally { $archive.Dispose() }
}
