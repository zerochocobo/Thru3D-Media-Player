param([string]$ToolRoot=$(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/thru3d-toolchain' }))
$ErrorActionPreference='Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/airplay'
New-Item -ItemType Directory -Path $output -Force | Out-Null
& python -m unittest discover -s "$workspace/tools/tests" -p test_prepare_airplay.py -v *> "$output/preparation.log"
if ($LASTEXITCODE -ne 0) { throw 'AirPlay source preparation regression failed.' }
$godot = $env:GODOT_EXE
if ($IsWindows) {
    $console = Join-Path (Split-Path -Parent $godot) 'godot_console.exe'
    if (Test-Path -LiteralPath $console) { $godot = $console }
}
foreach ($case in @('test_airplay_password_settings','test_airplay_window','test_video_pip','test_cast_receiver')) {
    & $godot --headless --xr-mode off --path "$workspace/app/godot" --quit-after 1800 --script "res://tests/$case.gd" *> "$output/$case.log"
    $text = Get-Content -LiteralPath "$output/$case.log" -Raw
    if ($LASTEXITCODE -ne 0 -or $text -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $text -notmatch '0 failures') { throw "AirPlay regression failed: $case" }
}
$api = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
Push-Location "$workspace/android"
try {
    & ./gradlew.bat :player-plugin:validateLicenseCatalog :player-plugin:testDebugUnitTest --tests '*AirplayPacketsTest' --tests '*DlnaReceiverTest' "-PgodotAarPath=$api" --console=plain *> "$output/jvm.log"
    if ($LASTEXITCODE -ne 0) { throw 'AirPlay JVM checks failed.' }
} finally { Pop-Location }
Write-Output 'AirPlay host checks passed. No APK or headset operation.'
