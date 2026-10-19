param([string]$Godot = 'godot', [string]$Ffmpeg = 'ffmpeg', [switch]$RegenerateClip)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/cinema-prototype'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$clip = Join-Path $output 'cinema-motion.ogv'
if ($RegenerateClip -or !(Test-Path -LiteralPath $clip)) {
    & (Join-Path $PSScriptRoot 'Generate-CinemaTestClip.ps1') -Ffmpeg $Ffmpeg
} else {
    & $Ffmpeg -hide_banner -loglevel error -xerror -i $clip -f null -
    if ($LASTEXITCODE -ne 0) { throw 'Existing cinema motion clip failed full decode validation; regenerate it' }
}
function Invoke-CinemaCheck([string]$Name, [string]$Script, [string]$Success, [switch]$Render) {
    $log = Join-Path $output "$Name.log"
    $arguments = @('--path', $project, '--xr-mode', 'off', '--log-file', $log, '--quit-after', '2400')
    if ($Render) {
        $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--resolution', '1440x960', '--position', '-2400,-1200')
    } else { $arguments += '--headless' }
    $arguments += @('--script', $Script)
    & $Godot @arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name exited with $LASTEXITCODE" }
    $lines = Get-Content -LiteralPath $log
    if (($lines -join "`n") -notmatch $Success) { throw "$Name did not report a successful result" }
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^(SCRIPT ERROR:|SHADER ERROR:)') { throw "$Name reported $line" }
        if ($line -notmatch '^ERROR:') { continue }
        # The restricted host may deny CA/USB access and the user's shader-cache directory.
        # Do not classify unrelated engine or product errors as environmental warnings.
        if ($line -eq 'ERROR: Failed to read the root certificate store.') { continue }
        if ($line -match '^ERROR: Error opening gamepad at index \d+: Couldn.t setup USB mode$') { continue }
        if ($line -eq 'ERROR: Condition "f.is_null()" is true.' -and ($index + 1) -lt $lines.Count -and $lines[$index + 1] -match '_save_to_cache \(drivers/gles3/shader_gles3.cpp:') { continue }
        throw "$Name reported unexpected engine error: $line"
    }
}
Invoke-CinemaCheck 'geometry' 'res://tests/test_cinema_geometry.gd' 'CINEMA_GEOMETRY_OK checks=\d+'
Invoke-CinemaCheck 'loader' 'res://tests/test_cinema_loader.gd' 'Cinema loader: \d+ checks, 0 failures'
Invoke-CinemaCheck 'locomotion' 'res://tests/test_cinema_locomotion.gd' 'Cinema locomotion: \d+ checks, 0 failures'
Invoke-CinemaCheck 'render' 'res://tests/render_cinema_prototype.gd' 'Cinema prototype render: \d+ checks, 0 failures' -Render
Invoke-CinemaCheck 'occlusion' 'res://tests/render_cinema_occlusion.gd' 'Cinema occlusion: \d+ pixel checks, 0 failures' -Render
$occlusion = Get-Content -Raw (Join-Path $output 'occlusion/summary.json') | ConvertFrom-Json
if ($occlusion.unrestricted_transparent_geometry_supported -ne $false) { throw 'Occlusion report lost the known transparent-background limitation' }
Write-Output 'Cinema prototype desktop checks passed; OpenXR and Android remain unverified.'
