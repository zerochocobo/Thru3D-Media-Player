param(
    [string]$Godot = 'godot_console',
    [string]$Blender = $(if ($env:BLENDER) { $env:BLENDER } else { 'blender' }),
    [int]$Atlas = 4096,
    [int]$Samples = 256,
    [string]$Preview = '',
    [switch]$Quick
)
# Keep the original entry point on the current dual-lighting pipeline. Never
# overwrite a dual-state hall with the historical single-state bake.
if ($Preview) { throw 'Render previews with app/godot/tests/render_cinema_full_lighting.gd after importing the hall.' }
if ($Quick) { $Samples = 16 }
& (Join-Path $PSScriptRoot 'Build-CinemaLighting.ps1') -Godot $Godot -Blender $Blender -Atlas $Atlas -Samples $Samples
