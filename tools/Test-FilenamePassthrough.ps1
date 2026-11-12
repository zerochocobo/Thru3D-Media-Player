param(
    [string]$Godot = $(if ($env:GODOT_EXE) { $env:GODOT_EXE } else { 'godot' }),
    [switch]$RenderPreview,
    [string[]]$Tests = @('test_filename_passthrough', 'test_media_naming', 'test_file_mode_memory',
        'test_packed_mask', 'test_alpha_background', 'test_video_playback_modes',
        'test_video_mode_transition', 'test_fisheye_layer', 'test_video_layer',
        'test_cast_receiver', 'test_external_playback', 'test_video_auto_3d_startup', 'test_subtitle_effect_recovery',
        'test_privacy_memory', 'test_i18n')
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/filename-passthrough-checks'
$project = Join-Path $workspace 'app/godot'
$savedAppData = $env:APPDATA
$savedJoystick = $env:SDL_JOYSTICK_HIDAPI
$results = @()
New-Item -ItemType Directory -Force -Path $output | Out-Null
try {
    $env:APPDATA = Join-Path $output ('appdata-' + [guid]::NewGuid().ToString('N'))
    $env:SDL_JOYSTICK_HIDAPI = '0'
    New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
    foreach ($test in $Tests) {
        $log = Join-Path $output ($test + '.log')
        & $Godot --headless --xr-mode off --path $project --quit-after 18000 --script ('res://tests/' + $test + '.gd') 2>&1 | Out-File -LiteralPath $log -Encoding utf8
        $exitCode = $LASTEXITCODE
        $content = Get-Content -LiteralPath $log -Raw
        if ($exitCode -ne 0 -or $content -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or
            $content -notmatch '(failures[:=]\s*0|0 failures|checks: passed \(\d+\))') {
            throw "$test failed; see $log"
        }
        $summary = ($content -split '\r?\n' | Where-Object { $_ -match '(failures[:=]\s*0|0 failures|checks: passed \(\d+\))' }) -join "`n"
        $summary | Write-Output
        $results += @{ test = $test; exit_code = $exitCode; summary = $summary }
    }
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'results.json') -Encoding utf8
    if ($RenderPreview) {
        $log = Join-Path $output 'render.log'
        $errors = Join-Path $output 'render-errors.log'
        $arguments = @('--xr-mode', 'off', '--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3',
            '--path', ('"' + $project + '"'), '--quit-after', '1800', '--script', 'res://tests/render_filename_passthrough.gd')
        $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errors
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            throw 'Filename passthrough preview timed out.'
        }
        $content = (Get-Content -LiteralPath $log -Raw) + (Get-Content -LiteralPath $errors -Raw)
        if ($process.ExitCode -ne 0 -or $content -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or
            $content -notmatch 'Filename passthrough render: 8 frames, 0 failures') { throw "Render failed; see $log and $errors" }
        'Filename passthrough render: 8 frames, 0 failures' | Write-Output
    }
} finally {
    $env:APPDATA = $savedAppData
    $env:SDL_JOYSTICK_HIDAPI = $savedJoystick
}
