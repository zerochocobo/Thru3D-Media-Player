param([string]$Godot = 'godot')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/pico-controller-models'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$models = Join-Path $workspace 'app/godot/models/controllers/pico'
$manifest = Get-Content (Join-Path $models 'manifest.json') -Raw | ConvertFrom-Json
foreach ($asset in $manifest.files) {
    $path = Join-Path $models $asset.file
    if ((Get-Item -LiteralPath $path).Length -ne $asset.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $asset.sha256) {
        throw "PICO controller asset does not match its pinned source: $($asset.file)"
    }
}
$env:SDL_JOYSTICK_HIDAPI = '0'
foreach ($test in @('test_pico_controller_models', 'test_input_visuals', 'test_hand_pointer', 'test_photo_input_visibility', 'render_pico_controller_models')) {
    $arguments = @('--xr-mode', 'off', '--path', (Join-Path $workspace 'app/godot'), '--quit-after', '1800', '--script', "res://tests/$test.gd")
    if ($test -eq 'render_pico_controller_models') {
        $arguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3')
    } else { $arguments += '--headless' }
    $log = Join-Path $output "$test.log"
    $stderr = Join-Path $output "$test.stderr.log"
    $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        throw "$test timed out; see $log"
    }
    $process.Refresh()
    $result = (Get-Content -LiteralPath $log -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '0 failures') {
        throw "$test failed; see $log and $stderr"
    }
    $result -split '\r?\n' | Where-Object { $_ -match '0 failures' } | Write-Output
}
