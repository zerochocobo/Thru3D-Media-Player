param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [string]$FfmpegPath = 'ffmpeg')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/web-network-capture'
$fixtures = Join-Path $output 'fixtures'
New-Item -ItemType Directory -Force -Path $fixtures | Out-Null
$ffmpegCommand = (Get-Command $FfmpegPath -ErrorAction Stop).Source
function Invoke-FixtureFfmpeg([string[]]$Parameters) {
    & $ffmpegCommand -v error -y @Parameters
    if ($LASTEXITCODE -ne 0) { throw 'Network media fixture generation failed.' }
}
Invoke-FixtureFfmpeg @('-f','lavfi','-i','testsrc2=size=320x180:rate=15','-f','lavfi','-i','sine=frequency=440:sample_rate=48000',
    '-t','4','-c:v','libx264','-profile:v','high','-pix_fmt','yuv420p','-g','15','-c:a','aac','-movflags','+faststart',"$fixtures/muxed.mp4")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-map','0:v','-c','copy','-movflags','+faststart',"$fixtures/video.mp4")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-map','0:a','-c','copy','-movflags','+faststart',"$fixtures/audio.m4a")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-c:v','libvpx-vp9','-deadline','realtime','-cpu-used','8','-c:a','libopus',"$fixtures/muxed.webm")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-c:v','libx265','-preset','ultrafast','-x265-params','log-level=error','-pix_fmt','yuv420p','-c:a','copy','-movflags','+faststart',"$fixtures/hevc.mp4")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-c:v','libx265','-preset','ultrafast','-x265-params','log-level=error','-pix_fmt','yuv420p10le','-c:a','copy','-movflags','+faststart',"$fixtures/hevc10.mp4")
Invoke-FixtureFfmpeg @('-i',"$fixtures/muxed.mp4",'-c','copy','-f','hls','-hls_time','1','-hls_playlist_type','vod',"$fixtures/sample-network.m3u8")
& node --test "$workspace/android/web-browser/src/test/js/network.test.cjs" "$workspace/android/web-browser/src/test/js/media.test.cjs" "$workspace/android/web-browser/src/test/js/bilibili.test.cjs" *> "$output/extension.log"
if ($LASTEXITCODE -ne 0) { throw "Extension verification failed: $output/extension.log" }
$env:WEB_VIDEO_NETWORK_FIXTURES = $fixtures
$env:WEB_VIDEO_FIXTURES = $fixtures
$env:WEB_VIDEO_FFMPEG = $ffmpegCommand
$api = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
# Host tests and Kotlin only; never assemble/sign/install an APK or operate a headset.
& "$workspace/android/gradlew.bat" -p "$workspace/android" "-PgodotAarPath=$api" --offline --console=plain :player-plugin:testDebugUnitTest --tests '*WebVideo*Test' :web-browser:testDebugUnitTest :player-plugin:compileReleaseKotlin *> "$output/tests.log"
if ($LASTEXITCODE -ne 0) { throw "Browser JVM verification failed: $output/tests.log" }
$env:SDL_JOYSTICK_HIDAPI = '0'
$console = Join-Path (Split-Path $env:GODOT_EXE) 'godot_console.exe'
$runner = if (Test-Path -LiteralPath $console) { $console } else { $env:GODOT_EXE }
foreach ($test in @('test_web_browser_panel','test_web_fullscreen_handoff','test_web_browser_windows','test_i18n')) {
    & $runner --headless --xr-mode off --path "$workspace/app/godot" --quit-after 1800 --script "res://tests/$test.gd" *> "$output/$test.log"
    $log = Get-Content -LiteralPath "$output/$test.log" -Raw
    if ($LASTEXITCODE -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $log -notmatch '\b0 failures\b|\bfailures=0\b') { throw "Browser UI verification failed: $output/$test.log" }
    $log -split "`n" | Where-Object { $_ -match 'checks.*failures|failures=0' } | Write-Output
}
Write-Output "Network media capture host verification passed. Logs: $output"
