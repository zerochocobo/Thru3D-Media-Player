param(
    [string]$Godot = 'godot',
    [switch]$Regression,
    [switch]$SkipRender
)
$ErrorActionPreference = 'Stop'
$env:SDL_JOYSTICK_HIDAPI = '0'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/video-pip'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$cases = @('test_video_pip', 'test_video_pip_compositor', 'test_video_pip_refinements', 'test_video_pip_feedback', 'test_video_pip_images', 'test_video_pip_hands', 'test_image_picker_memory', 'test_pip_screenshot')
if ($Regression) {
    $cases += @('test_grip_upright', 'test_video_layer', 'test_controller_bindings', 'test_controller_feedback', 'test_player_sticks',
        'test_video_idle_rays', 'test_video_playback_modes', 'test_spatial_videos', 'test_video_capture')
}
if (-not $SkipRender) { $cases += @('render_video_pip', 'render_video_pip_ui', 'render_video_pip_mono', 'render_video_pip_feedback', 'render_video_pip_edges') }
foreach ($case in $cases) {
    $arguments = @('--xr-mode', 'off', '--path', ('"' + $project + '"'), '--quit-after', '1800', '--script', ('res://tests/' + $case + '.gd'))
    if ($case.StartsWith('render_')) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    else { $arguments += '--headless' }
    $stdout = Join-Path $output ($case + '.stdout.log')
    $stderr = Join-Path $output ($case + '.stderr.log')
    $start = @{FilePath = $Godot; ArgumentList = $arguments; RedirectStandardOutput = $stdout; RedirectStandardError = $stderr; Wait = $true; PassThru = $true}
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $start.WindowStyle = 'Hidden' }
    $process = Start-Process @start
    $result = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(0 failures|failures=0|passed)') {
        throw "$case failed; see $stdout and $stderr"
    }
    $result -split '\r?\n' | Where-Object { $_ -match '(0 failures|failures=0|passed)' } | Write-Output
}
