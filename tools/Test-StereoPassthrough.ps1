param([string]$Godot = $(if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot -ErrorAction Stop).Source }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/stereo-passthrough'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$env:SDL_JOYSTICK_HIDAPI = '0'
$cases = @('test_video_portrait', 'test_player_menu', 'test_cinema_player_integration',
    'test_stereo_view', 'test_video_layer', 'test_file_mode_memory', 'test_i18n',
    'render_portrait_distance_menu', 'render_stereo_view')
foreach ($case in $cases) {
    $arguments = @('--xr-mode', 'off', '--path', ('"' + $project + '"'), '--quit-after', '2400',
        '--script', ('res://tests/' + $case + '.gd'))
    if ($case.StartsWith('render_')) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    else { $arguments += '--headless' }
    $stdout = Join-Path $output ($case + '.log')
    $stderr = Join-Path $output ($case + '.errors.log')
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(60000)) { throw "$case remains active (PID $($process.Id)); inspect before retrying." }
    $process.Refresh()
    $report = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    Write-Output (($report -split '\r?\n' | Where-Object { $_ -match '(checks|passed|failures|FAIL|ERROR)' }) -join "`n")
    if ($process.ExitCode -ne 0 -or $report -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') {
        throw "$case failed; see $stdout and $stderr"
    }
}
