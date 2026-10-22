param(
    [string]$Godot = 'godot_console',
    [string]$Blender = $(if ($env:BLENDER) { $env:BLENDER } else { 'blender' }),
    [int]$Atlas = 4096,
    [int]$Samples = 160,
    [string]$Preview = '',
    [switch]$Quick
)
# Regenerates the cinema manifest (Godot blueprint), then models, bakes and
# exports local hall assets (Blender). Generated outputs are excluded from public Git.
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$assets = Join-Path $project 'environments/grand_cinema'
$work = Join-Path $workspace 'tmp/cinema-build'
New-Item -ItemType Directory -Path $work -Force | Out-Null
if (-not (Get-Command $Blender -ErrorAction SilentlyContinue)) { throw "Blender not found: $Blender (set -Blender or BLENDER)" }

$ErrorActionPreference = 'Continue'
& $Godot --headless --xr-mode off --path $project --script ../../tools/Generate-CinemaModel.gd 2>&1 | Tee-Object -Variable manifestLog | Out-Null
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0 -or -not ($manifestLog -match 'CINEMA_MANIFEST_OK')) { throw 'Cinema manifest generation failed' }

$arguments = @('--background', '--factory-startup', '--python', (Join-Path $PSScriptRoot 'cinema/build_hall.py'), '--',
    '--manifest', (Join-Path $assets 'manifest.json'), '--out', (Join-Path $assets 'cinema.glb'),
    '--atlas', $Atlas, '--samples', $Samples, '--work', $work)
if ($Preview) { $arguments += @('--preview', $Preview) }
if ($Quick) { $arguments += '--quick' }
$log = Join-Path $work 'blender.log'
# Windows PowerShell turns native stderr lines into terminating errors under Stop.
$ErrorActionPreference = 'Continue'
& $Blender @arguments *> $log
$ErrorActionPreference = 'Stop'
$result = Select-String -LiteralPath $log -Pattern 'CINEMA_BLENDER_OK' | Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Blender cinema build failed; see $log" }
Write-Output $result.Line
