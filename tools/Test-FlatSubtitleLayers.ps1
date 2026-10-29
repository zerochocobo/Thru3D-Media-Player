param([string]$Godot = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot_console.exe -ErrorAction Stop).Source } }
$output = Join-Path $workspace 'build/output/flat-subtitle-layers'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$env:SDL_JOYSTICK_HIDAPI = '0'
$env:QUEST_SUBTITLE_PREVIEW_DIR = Join-Path $output 'existing-subtitles'
# Host checks only. No Android build, signing, adb or XR session.
$cases = @('test_video_layer', 'test_subtitle_layers', 'test_video_pip_compositor', 'test_mpv_subtitles',
    'test_subtitle_sliders', 'test_subtitle_center', 'test_subtitle_effect_recovery', 'test_frame_picture_layer',
    'test_mpv_rotation', 'test_video_capture', 'render_flat_subtitle_layers', 'render_mpv_subtitles',
    'render_bitmap_subtitles', 'render_menu_composition', 'render_menu_text_sampling', 'render_menu_slots',
    'render_mono_menu_alignment')
foreach ($case in $cases) {
    $stdout = Join-Path $output "$case.log"
    $stderr = Join-Path $output "$case.errors.log"
    $arguments = @('--xr-mode', 'off', '--path', ('"' + (Join-Path $workspace 'app/godot') + '"'), '--script', "res://tests/$case.gd")
    if ($case.StartsWith('test_')) { $arguments += '--headless' }
    else { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(60000)) { throw "$case remains active (PID $($process.Id)); inspect before retrying." }
    $process.Refresh()
    $log = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "$case failed; see $stdout and $stderr" }
    $summary = ($log -split '\r?\n' | Where-Object { $_ -notmatch '^\s*\{' -and $_ -match '(checks|comparisons|passed|completed)' }) -join "`n"
    Write-Output $(if ($summary) { $summary } else { "$case passed." })
}
$report = Get-Content -LiteralPath (Join-Path $output 'verification.json') -Raw | ConvertFrom-Json
if ($report.failures.Count -ne 0 -or $report.samples.Count -ne 5) { throw 'Incomplete flat subtitle capture evidence.' }
Write-Output "Flat subtitle and menu host verification passed. Logs: $output"
