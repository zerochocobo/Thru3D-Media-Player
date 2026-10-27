param([string]$DictionaryJar = '', [string]$OutputDirectory = 'build/output/comic-japanese-20261027/package-tests')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $DictionaryJar) { $DictionaryJar = Join-Path $workspace 'android/player-plugin/build/japanese-reading/kuromoji-ipadic-reader-0.9.0.jar' }
$out = [IO.Path]::GetFullPath((Join-Path $workspace $OutputDirectory))
New-Item -ItemType Directory -Force -Path $out | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$check = Join-Path $workspace 'tools/Assert-ComicJapanesePackaged.ps1'
& $check -ArchivePath $DictionaryJar

# A deliberately incomplete jar and a same-size corrupt resource must both fail.
$source = [IO.Compression.ZipFile]::OpenRead($DictionaryJar)
try {
    foreach ($kind in @('missing','corrupt')) {
        $path = Join-Path $out ($kind + '.jar')
        $file = [IO.File]::Open($path, [IO.FileMode]::Create)
        $zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $source.Entries | Where-Object { $_.FullName.EndsWith('.bin') }) {
                $targeted = $entry.FullName.EndsWith('/connectionCosts.bin')
                if ($targeted -and $kind -eq 'missing') { continue }
                $input = $entry.Open(); $memory = [IO.MemoryStream]::new()
                try { $input.CopyTo($memory); $bytes = $memory.ToArray() } finally { $input.Dispose(); $memory.Dispose() }
                if ($targeted) { $bytes[0] = $bytes[0] -bxor 1 }
                $output = $zip.CreateEntry($entry.FullName).Open()
                try { $output.Write($bytes, 0, $bytes.Length) } finally { $output.Dispose() }
            }
        } finally { $zip.Dispose(); $file.Dispose() }
        $rejected = $false
        try { & $check -ArchivePath $path } catch { $rejected = $true }
        if (-not $rejected) { throw "Invalid Japanese dictionary accepted: $kind" }
    }
} finally { $source.Dispose() }

# Exercise nested AAR lookup without building or replacing an Android plugin.
$path = Join-Path $out 'fixture.aar'
$file = [IO.File]::Open($path, [IO.FileMode]::Create)
$zip = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
try {
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $DictionaryJar, 'libs/kuromoji-ipadic-reader-0.9.0.jar') | Out-Null
    # AGP merges the jar's Java dictionary resources into classes.jar.
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $DictionaryJar, 'classes.jar') | Out-Null
    foreach ($name in @('LICENSE.md','NOTICE.md','CONTRIBUTORS.md')) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $workspace ('third_party/kuromoji/' + $name)), ('assets/kuromoji/' + $name)) | Out-Null
    }
} finally { $zip.Dispose(); $file.Dispose() }
& $check -ArchivePath $path
Write-Output 'PASS: dictionary bytes, missing resource, same-size corruption, nested AAR and notices'
