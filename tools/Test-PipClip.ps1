param([switch]$SkipJvm)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/pip-clip'
New-Item -ItemType Directory -Force $output | Out-Null
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
if (!$SkipJvm) {
    & "$workspace/android/gradlew.bat" -p "$workspace/android" ('-PgodotAarPath=' + (Join-Path $env:QUEST_TOOL_ROOT 'godot-android-api/4.7.2/godot-lib.template_debug.aar')) :player-plugin:testDebugUnitTest --tests '*PipClipTimelineTest' --tests '*PipScreenshotTest' --tests '*CaptureFormatTest' --tests '*HeardPcmTest' --console=plain *> "$output/jvm.log"
    if ($LASTEXITCODE) { throw 'PiP recording JVM checks failed; see build/output/pip-clip/jvm.log.' }
}
$env:SDL_JOYSTICK_HIDAPI = '0'
foreach ($case in @('test_flat_capture', 'test_video_capture', 'test_pip_screenshot', 'test_video_pip_images', 'test_i18n')) {
    $arguments = '--headless --xr-mode off --path "{0}" --script res://tests/{1}.gd' -f "$workspace/app/godot", $case
    $process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$output/$case.stdout.log" -RedirectStandardError "$output/$case.stderr.log"
    if (!$process.WaitForExit(120000)) { Stop-Process -Id $process.Id; throw "$case timed out." }
    $result = (Get-Content "$output/$case.stdout.log" -Raw) + (Get-Content "$output/$case.stderr.log" -Raw)
    if ($process.ExitCode -ne 0 -or $result -match 'SCRIPT ERROR|SHADER ERROR|(?m)^ERROR:' -or $result -notmatch '0 failures|failures=0|passed') { throw "$case failed; see build/output/pip-clip." }
    $result -split '\r?\n' | Where-Object { $_ -match '0 failures|failures=0|passed' } | Write-Output
}
Write-Output 'PiP recording source checks passed. No APK/AAR packaging or device operation.'
