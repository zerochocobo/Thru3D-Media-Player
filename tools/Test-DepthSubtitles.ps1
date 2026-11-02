param([string]$Godot = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot_console.exe -ErrorAction Stop).Source } }
$output = Join-Path $workspace 'build/output/depth-subtitles'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$env:SDL_JOYSTICK_HIDAPI = '0'
# Host-only subtitle isolation/regression checks. No build, device, signing or deployment.
$cases = @('test_depth_subtitles', 'test_subtitle_layout_memory', 'test_cast_receiver', 'test_privacy_memory', 'test_file_mode_memory', 'test_file_track_memory', 'test_mpv_subtitles', 'test_subtitle_layers', 'test_subtitle_sliders',
    'test_subtitle_center', 'test_subtitle_projection', 'test_subtitle_effect_recovery', 'test_subtitle_timing',
    'test_subtitle_encoding', 'test_subtitle_files', 'test_dual_subtitles', 'test_live_interpretation',
    'test_narration', 'test_i18n', 'render_depth_subtitles', 'render_flat_subtitle_layers',
    'render_mpv_subtitles', 'render_bitmap_subtitles')
$env:QUEST_SUBTITLE_PREVIEW_DIR = Join-Path $output 'original-subtitles'
foreach ($case in $cases) {
    $stdout = Join-Path $output "$case.log"
    $stderr = Join-Path $output "$case.errors.log"
    $arguments = @('--xr-mode', 'off', '--path', ('"' + (Join-Path $workspace 'app/godot') + '"'), '--script', "res://tests/$case.gd")
    if ($case.StartsWith('test_')) { $arguments += '--headless' }
    else { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $process.Handle | Out-Null # Retain the exit code on Windows PowerShell after a short child exits.
    if (-not $process.WaitForExit(60000)) { throw "$case remains active (PID $($process.Id)); inspect before retrying." }
    $process.Refresh()
    $log = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:|FAIL:)') { throw "$case failed; see $stdout and $stderr" }
    ($log -split '\r?\n' | Where-Object { $_ -notmatch '^\s*\{' -and $_ -match '(checks|comparisons|passed|completed)' }) -join "`n"
}
$report = Get-Content -LiteralPath (Join-Path $output 'render-verification.json') -Raw | ConvertFrom-Json
if ($report.failures.Count -ne 0 -or $report.samples.Count -ne 18) { throw 'Incomplete screen-down subtitle render evidence.' }
Write-Output "Depth subtitle host verification passed. Logs: $output"
