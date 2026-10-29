param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/browser-viewport'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$api = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
# Compile production Kotlin and run host JVM tests only. No AAR/APK, signing or adb.
& "$workspace/android/gradlew.bat" -p "$workspace/android" "-PgodotAarPath=$api" --offline --console=plain :web-browser:testDebugUnitTest :web-browser:compileReleaseKotlin *> "$output/jvm.log"
if ($LASTEXITCODE -ne 0) { throw "Browser JVM verification failed: $output/jvm.log" }
$godotConsole = Join-Path (Split-Path $env:GODOT_EXE) 'godot_console.exe'
$runner = if (Test-Path -LiteralPath $godotConsole) { $godotConsole } else { $env:GODOT_EXE }
foreach ($test in @('test_web_browser_viewport', 'test_web_browser_windows', 'test_web_browser_peers', 'test_web_browser_cinema', 'test_web_browser_panel', 'test_web_browser_start_page', 'test_web_browser_transfer', 'test_web_browser_composition', 'test_web_fullscreen_handoff')) {
    $logPath = Join-Path $output "$test.log"
    & $runner --headless --xr-mode off --path "$workspace/app/godot" --quit-after 1800 --script "res://tests/$test.gd" *> $logPath
    $log = Get-Content -LiteralPath $logPath -Raw
    if ($LASTEXITCODE -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $log -notmatch '\b0 failures\b|\bfailures=0\b') { throw "Browser host verification failed: $logPath" }
    $log -split "`n" | Where-Object { $_ -match 'checks.*failures|failures=0' } | Write-Output
}
Write-Output "Browser viewport host verification passed. Logs: $output"
