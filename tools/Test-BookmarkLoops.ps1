param([string]$Godot = 'godot', [switch]$SkipRender, [string[]]$Tests = @())
$ErrorActionPreference = 'Stop'
$env:SDL_JOYSTICK_HIDAPI = '0'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/bookmark-loops'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$cases = @('test_bookmark_loops', 'test_bookmark_manager', 'test_bookmarks', 'test_seek_policy', 'test_mpv_seek_hold', 'test_video_playback_modes', 'test_player_menu', 'test_audio_popup', 'test_player_sticks', 'test_narration', 'test_i18n')
if (-not $SkipRender) { $cases += @('render_bookmark_loops', 'render_menu_composition') }
if ($Tests.Count -gt 0) { $cases = $Tests }
foreach ($case in $cases) {
    $arguments = @('--xr-mode', 'off', '--path', ('"' + (Join-Path $workspace 'app/godot') + '"'), '--quit-after', '1800', '--script', ('res://tests/' + $case + '.gd'))
    if ($case.StartsWith('render_')) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    else { $arguments += '--headless' }
    $stdout = Join-Path $output ($case + '.stdout.log')
    $stderr = Join-Path $output ($case + '.stderr.log')
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -Wait -PassThru
    $result = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(0 failures|failures=0|passed)') {
        throw "$case failed; see $stdout and $stderr"
    }
    $result -split '\r?\n' | Where-Object { $_ -match '(0 failures|failures=0|passed)' } | Write-Output
}
