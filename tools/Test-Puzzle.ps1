param(
    [string]$GodotExe = 'godot',
    [switch]$RenderPreview,
    [switch]$Regression
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$projectDirectory = Join-Path $workspace 'app/godot'
$outputDirectory = Join-Path $workspace 'build/output/puzzle-p0'
$taskAppData = Join-Path $outputDirectory 'userdata'
New-Item -ItemType Directory -Force -Path $outputDirectory, $taskAppData | Out-Null
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
function Invoke-PuzzleGodot([string[]]$Arguments, [string]$Log) {
    # Capture native stderr directly; Windows PowerShell otherwise turns SDL notices
    # into terminating NativeCommandError records before the log can be checked.
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $GodotExe
    $process.StartInfo.Arguments = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [IO.File]::WriteAllText($Log, $stdout.Result + $stderr.Result, (New-Object Text.UTF8Encoding($false)))
    $code = $process.ExitCode
    $process.Dispose()
    return $code
}
try {
    # Keep application history, favorites, settings and imported audio out of the real profile.
    $env:APPDATA = $taskAppData
    $env:LOCALAPPDATA = $taskAppData
    $tests = @('test_puzzle_core', 'test_puzzle_store', 'test_puzzle_panorama', 'test_puzzle_integration', 'test_puzzle_flow', 'test_puzzle_panorama_flow', 'test_puzzle_mode', 'test_puzzle_entry_flow', 'test_library_filter_scope', 'test_puzzle_frame_input', 'test_puzzle_rotation', 'test_puzzle_placement', 'test_puzzle_reference', 'test_puzzle_feedback', 'test_puzzle_history', 'test_puzzle_usability')
    if ($Regression) { $tests += @('test_photos', 'test_spatial_photos', 'test_photo_hand_gestures', 'test_photo_inspect_input', 'test_hand_pointer', 'test_controller_bindings', 'test_controller_feedback', 'test_background_audio', 'test_music_quick_controls', 'test_i18n') }
    foreach ($test in $tests) {
        $log = Join-Path $outputDirectory ($test + '.log')
        $exitCode = Invoke-PuzzleGodot @('--headless', '--xr-mode', 'off', '--path', $projectDirectory, '--quit-after', '2400', '--script', ('res://tests/' + $test + '.gd')) $log
        $text = Get-Content -LiteralPath $log -Raw
        if ($exitCode -ne 0 -or $text -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $text -notmatch '(?i)(0 failures|failures=0)') { throw "Puzzle check failed: $test (exit $exitCode). See $log" }
        ($text -split '\r?\n' | Where-Object { $_ -match '(?i)(0 failures|failures=0)' }) | Write-Output
    }
    if ($RenderPreview) {
      foreach ($render in @('render_puzzle', 'render_puzzle_flow', 'render_puzzle_panorama', 'render_puzzle_feedback')) {
        $log = Join-Path $outputDirectory ($render + '.log')
        $exitCode = Invoke-PuzzleGodot @('--xr-mode', 'off', '--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--path', $projectDirectory, '--quit-after', '2400', '--script', ('res://tests/' + $render + '.gd')) $log
        $text = Get-Content -LiteralPath $log -Raw
        # This host may have an unavailable SDL USB gamepad. Rendering and test errors still fail.
        $errors = $text -split '\r?\n' | Where-Object { $_ -match '^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -and $_ -notmatch "^ERROR: Error opening gamepad at index \d+: Couldn't setup USB mode$" }
        if ($exitCode -ne 0 -or $errors -or $text -notmatch 'Puzzle (flow |panorama |feedback )?render: \d+ checks, 0 failures') { throw "Puzzle rendering failed. See $log" }
        ($text -split '\r?\n' | Where-Object { $_ -match '^Puzzle (flow |panorama |feedback )?render:' }) | Write-Output
      }
    }
} finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
}
