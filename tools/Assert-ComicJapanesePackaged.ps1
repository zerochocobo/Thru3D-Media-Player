param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $workspace 'third_party/kuromoji/distribution.json') -Raw | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
$nested = $null; $memory = $null
try {
    $dictionary = $zip
    if ($ArchivePath.EndsWith('.aar')) {
        if (-not $zip.GetEntry('libs/kuromoji-ipadic-reader-0.9.0.jar')) { throw 'Comic Japanese reading jar is missing from the plugin.' }
        # AGP moves a local jar's Java resources (the dictionary) into the AAR's classes.jar.
        $entry = $zip.GetEntry('classes.jar')
        $memory = [IO.MemoryStream]::new(); $stream = $entry.Open()
        try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
        $memory.Position = 0
        $nested = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
        $dictionary = $nested
    }
    foreach ($file in $manifest.dictionary.PSObject.Properties) {
        $entry = $dictionary.GetEntry($file.Name)
        if (-not $entry -or $entry.Length -ne $file.Value.bytes) { throw "Japanese dictionary is missing or truncated: $($file.Name)" }
        $stream = $entry.Open(); $digest = [Security.Cryptography.SHA256]::Create()
        try { $actual = -join ($digest.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
        finally { $stream.Dispose(); $digest.Dispose() }
        if ($actual -ne $file.Value.sha256) { throw "Japanese dictionary hash differs: $($file.Name)" }
    }
    if (-not $ArchivePath.EndsWith('.jar')) {
        foreach ($name in @('LICENSE.md','NOTICE.md','CONTRIBUTORS.md')) {
            $entry = $zip.GetEntry('assets/kuromoji/' + $name)
            if (-not $entry -or $entry.Length -le 0) { throw "Japanese reading notice is missing: $name" }
        }
    }
} finally {
    if ($nested) { $nested.Dispose() }
    if ($memory) { $memory.Dispose() }
    $zip.Dispose()
}
