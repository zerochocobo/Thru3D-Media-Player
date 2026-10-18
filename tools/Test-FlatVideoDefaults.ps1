param([string]$Godot = 'godot')
$ErrorActionPreference = 'Stop'
$env:SDL_JOYSTICK_HIDAPI = '0'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/flat-video-defaults'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$tests = @('test_flat_video_defaults', 'test_flat_screen_controls', 'test_interface_depth', 'test_library_distance',
    'test_view_follow', 'test_immersive_lifecycle', 'test_photo_frame', 'test_player_menu', 'test_controller_feedback', 'test_i18n')
foreach ($test in $tests) {
    $log = Join-Path $output ($test + '.log')
    & $Godot --headless --xr-mode off --path (Join-Path $workspace 'app/godot') --quit-after 18000 --script ('res://tests/' + $test + '.gd') 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $result -notmatch '(0 failures|failures=0|passed)') {
        throw "$test failed; see $log"
    }
    ($result -split '\r?\n' | Where-Object { $_ -match '(0 failures|failures=0|passed)' }) | Write-Output
}
$log = Join-Path $output 'render.log'
& $Godot --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path (Join-Path $workspace 'app/godot') --quit-after 1800 --script res://tests/render_flat_video_defaults.gd 2>&1 | Out-File -LiteralPath $log -Encoding utf8
$result = Get-Content -LiteralPath $log -Raw
if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch 'Flat video defaults render: [0-9]+ checks, 0 failures') {
    throw "Flat video defaults render failed; see $log"
}
($result -split '\r?\n' | Where-Object { $_ -match '0 failures' }) | Write-Output
