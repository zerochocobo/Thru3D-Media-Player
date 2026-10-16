param([string]$Godot = $(if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot -ErrorAction Stop).Source }), [switch]$RenderOnly)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$projectDirectory = Join-Path $workspace 'app/godot'
$outputDirectory = Join-Path $workspace 'build/output/stereo-view'
New-Item -ItemType Directory -Force $outputDirectory | Out-Null
# Avoid probing unrelated desktop USB controllers during offscreen visual checks.
$env:SDL_JOYSTICK_HIDAPI = '0'
$cases = @('test_stereo_view', 'test_player_menu', 'test_file_mode_memory', 'test_spatial_videos', 'test_spatial_video_metadata', 'test_player_sticks', 'test_i18n', 'test_photos', 'test_photo_adjustments', 'render_stereo_view', 'render_spatial_video_modes')
foreach ($case in $cases) {
    if ($RenderOnly -and -not $case.StartsWith('render_')) { continue }
    $stdout = Join-Path $outputDirectory ($case + '.log')
    $stderr = Join-Path $outputDirectory ($case + '.errors.log')
    $arguments = @('--xr-mode', 'off', '--path', ('"' + $projectDirectory + '"'), '--script', ('res://tests/' + $case + '.gd'), '--quit-after', '3000')
    if ($case.StartsWith('render_')) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    else { $arguments += '--headless' }
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(60000)) { throw "$case remains active (PID $($process.Id)); inspect this process before retrying." }
    $process.Refresh()
    $log = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "$case failed; see $stdout and $stderr" }
    Write-Output (($log -split '\r?\n' | Where-Object { $_ -match '(checks|passed|failures)' }) -join "`n")
}
