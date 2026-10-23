param([switch]$Render, [string[]]$Cases = @('test_cast_receiver', 'test_dlna_menu', 'test_player_menu', 'test_file_mode_memory', 'test_video_capture', 'test_narration', 'test_privacy_memory', 'test_video_playback_modes'))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$godotPath = $env:GODOT_EXE
if (-not $godotPath) { $godotPath = 'godot' }
if (-not (Test-Path -LiteralPath $godotPath)) { throw 'Set GODOT_EXE to the Godot console executable.' }
$output = Join-Path $workspace 'build/output/dlna-receiver'
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($case in $Cases) {
    $log = Join-Path $output ($case + '.log')
    & $godotPath --headless --xr-mode off --path (Join-Path $workspace 'app/godot') --quit-after 600 --script ('res://tests/' + $case + '.gd') 2>&1 | Out-File $log -Encoding utf8
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(failures=0|0 failures|checks: passed)') { throw "DLNA regression failed: $case. See $log" }
    Write-Output "Passed: $case"
}
if ($Render) {
    $log = Join-Path $output 'render.log'
    $errorLog = Join-Path $output 'render-errors.log'
    $start = @{ FilePath=$godotPath; PassThru=$true; Wait=$true; RedirectStandardOutput=$log; RedirectStandardError=$errorLog
        ArgumentList=@('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',('"' + (Join-Path $workspace 'app/godot') + '"'),'--quit-after','1800','--script','res://tests/render_cast_receiver.gd') }
    if ($env:OS -eq 'Windows_NT') { $start.WindowStyle='Hidden' }
    $process = Start-Process @start
    $result = (Get-Content -LiteralPath $log -Raw) + (Get-Content -LiteralPath $errorLog -Raw)
    if ($process.ExitCode -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or $result -notmatch 'Cast layouts=20') { throw "DLNA render failed. See $log" }
}
# Host-only checks. No packaging, device connection or installation.
