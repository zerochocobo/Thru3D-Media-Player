param([string]$Godot = 'godot', [switch]$Render)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/system-search-keyboard-20261018'
New-Item -ItemType Directory -Force $output | Out-Null
foreach ($case in @('test_system_search_input', 'test_cloud_search', 'test_media_servers', 'test_media_server_browser', 'test_controller_bindings', 'test_i18n')) {
    $log = Join-Path $output "$case.log"
    & $Godot --headless --xr-mode off --path "$workspace/app/godot" --quit-after 3600 --script "res://tests/$case.gd" 2>&1 | Out-File -LiteralPath $log -Encoding utf8
    $text = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $text -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or
        $text -notmatch '(failures=0|0 failures|passed)') { throw "System search regression failed: $case" }
    $text -split '\r?\n' | Where-Object { $_ -match '(failures=0|0 failures|passed)' } | Write-Output
}
[xml]$manifest = Get-Content -LiteralPath "$workspace/android/player-plugin/src/main/AndroidManifest.xml" -Raw
$feature = @($manifest.manifest.'uses-feature' | Where-Object { $_.name -eq 'oculus.software.overlay_keyboard' })
if ($feature.Count -ne 1 -or $feature[0].required -ne 'false') { throw 'Quest system keyboard declaration must remain optional for other Android runtimes.' }
Write-Output 'Android system keyboard feature: optional; no Meta runtime dependency'
if ($Render) {
	# Rendering fixtures do not need the desktop's attached USB controllers.
	$env:SDL_JOYSTICK_HIDAPI = '0'
    $stdout = Join-Path $output 'render-final.log'
    $stderr = Join-Path $output 'render-final-errors.log'
    $process = Start-Process -FilePath $Godot -ArgumentList @('--xr-mode', 'off', '--position', '-32000,-32000', '--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--path', "$workspace/app/godot", '--quit-after', '1800', '--script', 'res://tests/render_cloud_search.gd') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (!$process.WaitForExit(60000)) { throw "Search preview remains active: PID $($process.Id)" }
    $text = (Get-Content -LiteralPath $stdout -Raw) + (Get-Content -LiteralPath $stderr -Raw)
    if ($process.ExitCode -ne 0 -or $text -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or
        $text -notmatch 'Cloud search render: [0-9]+ checks, 0 failures') { throw 'Search preview failed.' }
    $text -split '\r?\n' | Where-Object { $_ -match 'Cloud search render:' } | Write-Output
}
