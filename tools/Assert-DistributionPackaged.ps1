param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][ValidateSet('standard','pico_cn_store')][string]$ExpectedChannel
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $entry = $zip.GetEntry('assets/project.binary')
    if (-not $entry) { throw 'APK is missing its compiled Godot project settings.' }
    $reader = [IO.BinaryReader]::new($entry.Open())
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'ECFG') { throw 'Unknown Godot settings encoding.' }
        $count = $reader.ReadUInt32()
        $channel = $null
        for ($index = 0; $index -lt $count; $index++) {
            $keyLength = $reader.ReadUInt32()
            if ($keyLength -gt $entry.Length) { throw 'Invalid Godot setting key length.' }
            $key = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($keyLength))
            $valueLength = $reader.ReadUInt32()
            if ($valueLength -gt $entry.Length) { throw 'Invalid Godot setting value length.' }
            $value = $reader.ReadBytes($valueLength)
            if ($key -eq 'application/config/distribution_channel') {
                if ($value.Length -lt 8 -or [BitConverter]::ToUInt32($value,0) -ne 4) { throw 'Distribution channel must be a string.' }
                $length = [BitConverter]::ToUInt32($value,4)
                if ($length -gt $value.Length - 8) { throw 'Invalid distribution channel length.' }
                $channel = [Text.Encoding]::UTF8.GetString($value,8,$length)
            }
        }
        if ($channel -cne $ExpectedChannel) { throw "Packaged distribution channel mismatch: expected $ExpectedChannel; actual $channel" }
        Write-Output "Packaged distribution channel verified: $channel"
    } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
