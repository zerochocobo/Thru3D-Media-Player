param([string]$Godot = 'godot', [switch]$RenderOnly)
$ErrorActionPreference = 'Stop'
$env:SDL_JOYSTICK_HIDAPI = '0'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/cinema-placement'
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($test in @('test_cinema_placement', 'test_controller_bindings', 'test_spatial_videos', 'render_cinema_placement')) {
    $render = $test.StartsWith('render_')
    if ($RenderOnly -and -not $render) { continue }
    $arguments = @('--xr-mode', 'off', '--path', (Join-Path $workspace 'app/godot'), '--quit-after', '1800', '--script', ('res://tests/' + $test + '.gd'))
    if ($render) { $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3') }
    else { $arguments += '--headless' }
    $log = Join-Path $output ($test + '.log')
    & $Godot @arguments 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(0 failures|failures=0|passed)') { throw "$test failed; see $log" }
    ($result -split '\r?\n' | Where-Object { $_ -match '(0 failures|failures=0|passed)' }) | Write-Output
}
