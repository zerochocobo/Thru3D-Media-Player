param([switch]$Render)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$godotPath = $env:GODOT_EXE
if (-not $godotPath) { $godotPath = (Get-Command godot -ErrorAction Stop).Source }
$consolePath = Join-Path (Split-Path -Parent $godotPath) 'godot_console.exe'
if (Test-Path -LiteralPath $consolePath) { $godotPath = $consolePath }
if (-not (Test-Path -LiteralPath $godotPath)) { throw 'Set GODOT_EXE to the Godot console executable.' }
$output = Join-Path $workspace 'build/output/voice-clone-regression'
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($case in @('test_narration_voice_feedback', 'test_narration_clone', 'test_narration', 'test_narration_status', 'test_library_menu', 'test_choice_fields', 'test_controller_bindings')) {
    $log = Join-Path $output ($case + '.log')
    & $godotPath --headless --xr-mode off --path (Join-Path $workspace 'app/godot') --quit-after 1800 --script ('res://tests/' + $case + '.gd') 2>&1 | Out-File $log -Encoding utf8
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(failures=0|0 failures)') { throw "Voice clone regression failed: $case. See $log" }
    Write-Output "Passed: $case"
}
& (Join-Path $workspace 'tests/packaging/test_narration_packaged.ps1')
if ($Render) {
    $log = Join-Path $output 'render.log'
    $errorLog = Join-Path $output 'render-errors.log'
    $start = @{ FilePath=$godotPath; PassThru=$true; Wait=$true; RedirectStandardOutput=$log; RedirectStandardError=$errorLog
        ArgumentList=@('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',('"' + (Join-Path $workspace 'app/godot') + '"'),'--quit-after','3600','--script','res://tests/render_narration_clone.gd') }
    if ($env:OS -eq 'Windows_NT') { $start.WindowStyle='Hidden' }
    $process = Start-Process @start
    $result = (Get-Content -LiteralPath $log -Raw) + (Get-Content -LiteralPath $errorLog -Raw)
    if ($process.ExitCode -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or $result -notmatch 'Clone voice render layouts=116 failures=0') { throw "Voice clone render regression failed. See $log" }
}
# Local checks only. This script never connects to, installs on, or starts a headset.
