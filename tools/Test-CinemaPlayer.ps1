param([string]$Godot = 'godot_console')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/cinema-player'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$results = @()
$cases = @(
    @('test_background', 'Application background: \d+ checks, 0 failures', $false),
    @('test_player_sticks', 'Player stick host checks: passed', $false),
    @('test_controller_bindings', 'Controller bindings: \d+ checks, 0 failures', $false),
    @('test_flat_video_defaults', 'Flat video defaults: \d+ checks, 0 failures', $false),
    @('test_cinema_placement', 'Cinema placement: \d+ checks, 0 failures', $false),
    @('test_i18n', 'i18n checks=\d+ failures=0', $false),
    @('test_cinema_environment', 'Cinema environment: \d+ checks, 0 failures', $false),
    @('test_cinema_background_menu', 'CINEMA_BACKGROUND_MENU checks=\d+ failures=0', $true),
    @('test_cinema_player_integration', 'Cinema player integration: \d+ checks, 0 failures', $false),
    @('test_cinema_world_transport', 'CINEMA_WORLD_TRANSPORT checks=\d+ failures=0', $false),
    @('render_cinema_player', 'Cinema player render: \d+ checks, 0 failures', $true)
)
foreach ($case in $cases) {
    $name = $case[0]
    $log = Join-Path $output "$name.log"
    $arguments = @('--path', $project, '--xr-mode', 'off', '--log-file', $log, '--quit-after', '2400')
    if ($case[2]) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--resolution', '1440x960', '--position', '-2400,-1200') }
    else { $arguments += '--headless' }
    $arguments += @('--script', "res://tests/$name.gd")
    & $Godot @arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$name exited with $LASTEXITCODE" }
    $lines = Get-Content -LiteralPath $log
    if (($lines -join "`n") -notmatch $case[1]) { throw "$name failed its expected result" }
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^(SCRIPT ERROR:|SHADER ERROR:|FAIL:)') { throw "$name reported $line" }
        if ($line -notmatch '^ERROR:') { continue }
        if ($line -eq 'ERROR: Failed to read the root certificate store.') { continue }
        if ($line -match '^ERROR: Error opening gamepad at index \d+: Couldn.t setup USB mode$') { continue }
        if ($line -eq 'ERROR: Condition "f.is_null()" is true.' -and ($index + 1) -lt $lines.Count -and $lines[$index + 1] -match '_save_to_cache \(drivers/gles3/shader_gles3.cpp:') { continue }
        throw "$name reported unexpected engine error: $line"
    }
    $summary = @($lines | Where-Object { $_ -match $case[1] })[-1]
    Write-Output $summary
    $results += [ordered]@{name=$name;result=$summary;passed=$true}
}
$results | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $output 'regressions.json')
Write-Output 'Experimental cinema player desktop checks passed. No APK export, installation or OpenXR device test was performed.'
