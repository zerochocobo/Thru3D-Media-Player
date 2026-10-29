param([string]$Godot = '', [switch]$Focused)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { (Get-Command godot_console.exe -ErrorAction Stop).Source } }
$output = Join-Path $workspace 'build/output/picture-center-guide'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$env:SDL_JOYSTICK_HIDAPI = '0'
# Only host logic and OpenGL pixels. Never build APKs or start an XR/device session.
$cases = @('test_picture_center_guide', 'test_controller_bindings', 'test_controller_feedback', 'test_interface_depth', 'test_immersive_adjustments', 'render_picture_center_guide')
if ($Focused) { $cases = @('test_picture_center_guide', 'render_picture_center_guide') }
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
    if ($process.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $log -notmatch '(checks, 0 failures|checks=\d+ failures=0)') { throw "$case failed; see $stdout and $stderr" }
    ($log -split '\r?\n' | Where-Object { $_ -match 'checks' }) | Write-Output
}
