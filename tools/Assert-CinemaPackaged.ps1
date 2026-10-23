param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $prefix = if ($ArchivePath.EndsWith('.apk')) { 'assets/' } else { '' }
    function Require-Entry([string]$Relative) {
        $entry = $zip.GetEntry($prefix + $Relative)
        if (-not $entry -or $entry.Length -le 0) { throw "Cinema package is missing: $Relative" }
        return $entry
    }
    function Read-EntryText([string]$Relative) {
        $entry = Require-Entry $Relative
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    $manifest = Read-EntryText 'environments/grand_cinema/manifest.json'
    if ($manifest -ne [IO.File]::ReadAllText((Join-Path $project 'environments/grand_cinema/manifest.json'))) { throw 'Packaged cinema navigation differs from source.' }
    $resources = @('cinema.glb','cinema_light.jpg','cinema_light_off.jpg','cinema_seat_albedo.jpg',
        'cinema_carpet_color.jpg','cinema_wall_color.jpg','cinema_wood_color.jpg',
        'cinema_metal_brushed.jpg','cinema_cloud_felt.jpg','cinema_velvet_black.jpg')
    foreach ($name in $resources) {
        $relative = 'environments/grand_cinema/' + $name
        $mapping = Read-EntryText ($relative + '.import')
        $pattern = if ($name.EndsWith('.glb')) { '(?m)^path="res://([^"]+)"' } else { '(?m)^path(?:\.etc2)?="res://([^"]+\.etc2\.ctex)"' }
        $match = [regex]::Match($mapping, $pattern)
        if (-not $match.Success) { throw "Cinema resource has no packaged scene/mobile texture mapping: $name" }
        $null = Require-Entry $match.Groups[1].Value
    }
    foreach ($shader in @('cinema_baked_surface','cinema_baked_seat','cinema_house_fixture')) {
        $relative = "shaders/$shader.gdshader"
        if ((Read-EntryText $relative) -ne [IO.File]::ReadAllText((Join-Path $project $relative))) { throw "Packaged cinema shader differs: $shader" }
    }
    foreach ($script in @('cinema_environment','cinema_feature','cinema_loader','cinema_locomotion')) {
        $mapping = Read-EntryText "scripts/environments/$script.gd.remap"
        $match = [regex]::Match($mapping, 'path="res://([^"]+)"')
        if (-not $match.Success) { throw "Cinema script remap is missing: $script" }
        $null = Require-Entry $match.Groups[1].Value
    }
    Write-Output 'Cinema package verified: scene, navigation, both lighting states, 9 mobile textures, shaders and runtime scripts.'
} finally { $zip.Dispose() }
