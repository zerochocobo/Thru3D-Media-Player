param([Parameter(Mandatory=$true)][string]$ArchivePath, [switch]$ExpectExcluded)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$directory = 'environments/private_beach/'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
try {
    $prefix = if ([IO.Path]::GetExtension($ArchivePath) -ieq '.apk') { 'assets/' } else { '' }
    $exclusionMarker = $zip.GetEntry($prefix + 'environments/private_beach_debug_excluded.txt')
    # Every build ships the beach now; only an explicit -ExpectExcluded check accepts its absence.
    if ($ExpectExcluded) {
        if (-not $exclusionMarker) { throw 'Package is missing the beach exclusion marker.' }
        $markerReader = [IO.StreamReader]::new($exclusionMarker.Open())
        try { if ($markerReader.ReadToEnd() -cne "private_beach_models_excluded_v1`n") { throw 'Invalid beach exclusion marker.' } }
        finally { $markerReader.Dispose() }
        # No local modeling manifest or current model hashes are required by
        # excluding builds. Imported file hashes identify their original res path.
        $md5 = [Security.Cryptography.MD5]::Create()
        try {
            foreach ($entry in $zip.Entries) {
                if (-not $entry.FullName.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
                $relative = $entry.FullName.Substring($prefix.Length)
                if ($relative.StartsWith($directory, [StringComparison]::Ordinal)) {
                    throw "Package contains beach modeling resource: $relative"
                }
                $mapping = [regex]::Match($relative, '^\.godot/imported/(.+)-([0-9a-f]{32})\.')
                if ($mapping.Success) {
                    $sourcePath = 'res://' + $directory + $mapping.Groups[1].Value
                    $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourcePath))).Replace('-', '').ToLowerInvariant()
                    if ($hash -ceq $mapping.Groups[2].Value) {
                        throw "Package contains imported beach modeling resource: $relative"
                    }
                }
            }
        } finally { $md5.Dispose() }
        Write-Output 'Private beach modeling resources excluded from package.'
        return
    }
    if ($exclusionMarker) { throw 'Package unexpectedly excludes the private beach.' }
    $manifest = Get-Content -LiteralPath (Join-Path $project ($directory + 'build_manifest.json')) -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 2 -or $manifest.scene_id -ne 'private_beach') { throw 'Unsupported beach staging manifest.' }
    function Require-Entry([string]$Relative) {
        $entry = $zip.GetEntry($prefix + $Relative)
        if (-not $entry -or $entry.Length -le 0) { throw "Beach package is missing: $Relative" }
        return $entry
    }
    function Read-EntryText([string]$Relative) {
        $entry = Require-Entry $Relative
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    function Assert-EntryMatchesFile([string]$Relative, [string]$FilePath) {
        $entry = Require-Entry $Relative
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($digest -ne (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash) {
            throw "Packaged beach resource differs from source: $Relative"
        }
    }
    # The bundle carries layout, navigation, mask mapping and real resource
    # dependencies. The offline staging JSON is deliberately not a runtime file.
    $bundle = $directory + 'beach_bundle.res'
    Assert-EntryMatchesFile $bundle (Join-Path $project $bundle)
    foreach ($name in @('terrain.glb', 'props.glb', 'vegetation.glb', 'grill.glb')) {
        $mapping = Read-EntryText ($directory + $name + '.import')
        $match = [regex]::Match($mapping, '(?m)^path="res://([^"]+\.scn)"')
        if (-not $match.Success) { throw "Beach model has no exported scene mapping: $name" }
        $source = [IO.File]::ReadAllText((Join-Path $project ($directory + $name + '.import')))
        $expected = [regex]::Match($source, '(?m)^path="res://([^"]+\.scn)"')
        if (-not $expected.Success -or $match.Groups[1].Value -cne $expected.Groups[1].Value) { throw "Beach model mapping differs: $name" }
        Assert-EntryMatchesFile $match.Groups[1].Value (Join-Path $project $match.Groups[1].Value)
    }
    $keys = @('micro_color', 'micro_normal', 'macro_color', 'wood_color', 'rock_color', 'rock_normal', 'rock_arm', 'static_mask', 'cliff_color', 'cliff_normal', 'sand_surface', 'wave_slopes', 'vegetation_contact', 'grill_contact', 'cloud_coverage', 'moon_albedo', 'groundcover_color', 'groundcover_normal', 'near_leaf_color', 'near_leaf_alpha', 'near_leaf_normal')
    foreach ($key in $keys) {
        $name = [string]$manifest.textures.$key
        if ([string]::IsNullOrEmpty($name)) { throw "Beach texture is absent from staging manifest: $key" }
        $mapping = Read-EntryText ($directory + $name + '.import')
        $match = [regex]::Match($mapping, '(?m)^path(?:\.etc2)?="res://([^"]+\.ctex)"')
        if (-not $match.Success) { throw "Beach texture has no exported ETC2 or uncompressed mapping: $name" }
        $relative = $match.Groups[1].Value
        $source = [IO.File]::ReadAllText((Join-Path $project ($directory + $name + '.import')))
        $expected = [regex]::Match($source, '(?m)^path(?:\.etc2)?="res://([^"]+\.ctex)"')
        if (-not $expected.Success -or $relative -cne $expected.Groups[1].Value) { throw "Beach texture mapping differs: $name" }
        Assert-EntryMatchesFile $relative (Join-Path $project $relative)
    }
    foreach ($name in @($manifest.study.firework_streams) + @('sea-monster-roar.wav')) {
        $mapping = Read-EntryText ($directory + $name + '.import')
        $match = [regex]::Match($mapping, '(?m)^path="res://([^"]+\.sample)"')
        if (-not $match.Success) { throw "Beach audio has no exported mapping: $name" }
        Assert-EntryMatchesFile $match.Groups[1].Value (Join-Path $project $match.Groups[1].Value)
    }
    foreach ($name in @('firework_spark.gdshader', 'body_halo.gdshader', 'sky_texture.gdshaderinc', 'time_sky_common.gdshaderinc', 'moon_surface.gdshaderinc', 'moving_shadow.gdshaderinc', 'ground_cover.gdshaderinc', 'sand.gdshader', 'sand_low.gdshader', 'rock.gdshader', 'props.gdshader', 'water.gdshader', 'water_low.gdshader', 'foliage.gdshader', 'grill.gdshader', 'moving_shadow_depth.gdshader', 'time_sky.gdshader', 'time_backdrop.gdshader', 'props_low.gdshader', 'foliage_low.gdshader', 'grill_low.gdshader')) {
        $relative = 'shaders/private_beach/' + $name
        if ((Read-EntryText $relative) -cne [IO.File]::ReadAllText((Join-Path $project $relative))) { throw "Packaged beach shader differs: $name" }
    }
    if ((Read-EntryText 'shaders/private_beach/celestial_glow.gdshader') -cne [IO.File]::ReadAllText((Join-Path $project 'shaders/private_beach/celestial_glow.gdshader'))) { throw 'Packaged celestial shader differs.' }
    foreach ($name in @('bundle', 'environment', 'interaction', 'locomotion', 'navigation', 'screen', 'screen_edit', 'video', 'water', 'time', 'clouds', 'shadow', 'fireworks', 'firework_audio', 'fireworks_control', 'drag', 'celestial_easter_eggs')) {
        $mapping = Read-EntryText "scripts/environments/private_beach_$name.gd.remap"
        $match = [regex]::Match($mapping, 'path="res://([^"]+\.gdc)"')
        if (-not $match.Success) { throw "Beach runtime script has no compiled mapping: $name" }
        $null = Require-Entry $match.Groups[1].Value
    }
    Write-Output 'Private beach package verified: layout/navigation bundle, models, textures, firework/creature audio, shaders and runtime scripts.'
} finally { $zip.Dispose() }
