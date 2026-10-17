param([string]$ArchivePath = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
# Fail before preparing dependencies or signing if another session restores a gate.
$gates = @(
    @('app/godot/scripts/narration_settings.gd', '(?m)^static var FEATURE_ENABLED := false\s*$'),
    @('android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/NarrationPolicy.kt', '(?m)^\s*const val FEATURE_ENABLED = false\s*$')
)
foreach ($gate in $gates) {
    if ((Get-Content -LiteralPath (Join-Path $workspace $gate[0]) -Raw) -notmatch $gate[1]) {
        throw "Subtitle narration must remain disabled pending explicit user authorization: $($gate[0])"
    }
}
if ($ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name -match '(^|/)(libquest_narration|libonnxruntime[^/]*)\.so$' -or
                $name -match '(^|/)(narration|moss-nano[^/]*|MOSS-TTS-Nano[^/]*|MOSS-Audio-Tokenizer[^/]*)/' -or
                $name -match '(^|/)(moss_tts_[^/]*|moss_audio_tokenizer_[^/]*|tokenizer\.model|shared_weights\.data)$') {
                throw "Withheld subtitle narration runtime, model or preset found in package: $name"
            }
        }
    } finally { $archive.Dispose() }
}
