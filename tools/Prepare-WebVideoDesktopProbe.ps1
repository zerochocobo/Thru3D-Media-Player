[CmdletBinding()]
param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$IncludeDiagnostics, [string[]]$TestFilter = @())
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/web-video-desktop-host'
$temporary = Join-Path $workspace 'tmp/web-video-desktop-host'
New-Item -ItemType Directory -Path $output, $temporary -Force | Out-Null
$runtimePath = (Join-Path $output 'runtime.json').Replace('\', '/')
$init = @'
gradle.afterProject { project ->
    if (project.path == ':player-plugin') {
        project.tasks.register('prepareWebVideoDesktopRuntime') {
            // The Test task also materializes current runtime-class jars. Compilation
            // alone leaves AGP's previous runtime jar on this classpath.
            dependsOn 'testDebugUnitTest', ':web-browser:testDebugUnitTest'
            doLast {
                def tests = project.tasks.named('testDebugUnitTest').get()
                def paths = (tests.classpath.files + tests.testClassesDirs.files).unique()
                def binary = System.getProperty('os.name').toLowerCase().contains('windows') ? 'java.exe' : 'java'
                def report = [java: new File(System.getProperty('java.home'), 'bin/' + binary).absolutePath,
                    classpath: paths.collect { it.absolutePath }.join(File.pathSeparator),
                    main: 'org.vrpassthroughplayer.plugin.WebVideoDesktopProbe',
                    cn_main: 'org.vrpassthroughplayer.plugin.WebVideoCnDesktopProbe']
                new File('__RUNTIME__').text = groovy.json.JsonOutput.toJson(report)
            }
        }
        def selected = project.findProperty('webVideoProbeTests')?.toString()?.split(',')?.toList() ?: []
        if (selected) project.tasks.withType(org.gradle.api.tasks.testing.Test).configureEach {
            if (name == 'testDebugUnitTest') filter { selected.each { includeTestsMatching(it) } }
        }
    }
}
'@
$initPath = Join-Path $temporary 'runtime.gradle'
[IO.File]::WriteAllText($initPath, $init.Replace('__RUNTIME__', $runtimePath))
$godotApi = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
$mutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
$held = $false
$inputs = @(
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserDirectFile.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDirectFile.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoResolver.kt',
    'android/player-plugin/src/test/java/org/vrpassthroughplayer/plugin/WebVideoDirectFileDesktopProbe.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoBrowserResourceReader.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDouyinCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoWeiboCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoTencentCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoMangoCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoYoukuCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/MpvVideoBridge.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/MpvSourceEpochGate.kt',
    'app/godot/scripts/mpv_video_display.gd',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoNiconicoCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoTwitchCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoTikTokCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoInstagramCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoTedCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoRedBullCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoStreamableCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoRedditCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoNaverCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoArchiveCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoOdyseeCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDailymotionCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoMp4Header.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/Mp4InterleavePolicy.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoIqiyiCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoIqiyiResources.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserIqiyi.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserYouku.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserNiconico.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserTwitch.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserTikTok.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserInstagram.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserTed.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserRedBull.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserStreamable.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserReddit.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserNaver.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserArchive.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserOdysee.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserDailymotion.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserMediaPolicy.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserNetworkPolicy.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoResolver.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserMango.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowser.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserPlaybackHold.kt',
    'app/godot/scripts/web_browser_panel.gd',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserWeibo.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserTencent.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoNetworkCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDescriptor.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoInternationalPages.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoContainer.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoTsDimensions.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoStreams.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoHls.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/LocalStreamServer.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/HttpRangeStreamSource.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoRequestHeaders.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/RemoteMediaHttp.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/SphericalVideoMetadata.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserDouyin.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserCaptureDiagnostics.kt',
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserNetworkMedia.kt',
    'android/player-plugin/src/test/java/org/vrpassthroughplayer/plugin/WebVideoDesktopProbe.kt',
    'android/player-plugin/src/test/java/org/vrpassthroughplayer/plugin/WebVideoCnDesktopProbe.kt')
# Include the renderer's scheduling helper only while it participates in the
# current bridge, so a helper-only edit cannot leave a falsely current runtime.
if ((Get-Content -LiteralPath (Join-Path $workspace 'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/MpvVideoBridge.kt') -Raw) -match '\bLayerAlphaCadence\b') {
    $inputs += 'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/LayerAlphaCadence.kt'
}
function Measure-ProbeInputs {
    $hashes = [ordered]@{}
    foreach ($relative in $inputs) { $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $workspace $relative) -Algorithm SHA256).Hash.ToLowerInvariant() }
    return $hashes
}
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) {
        Write-Output 'Waiting for the active player build to finish...'
        try { $held = $mutex.WaitOne() } catch [Threading.AbandonedMutexException] { $held = $true }
    }
    $before = Measure-ProbeInputs
    foreach($test in $TestFilter) { if($test -notmatch '^org\.vrpassthroughplayer\.plugin\.[A-Za-z0-9_.*$]+$') { throw 'Probe test filters must name project test classes.' } }
    $selection=@()
    if($TestFilter.Count) { $selection+="-PwebVideoProbeTests=$($TestFilter -join ',')" }
    & "$workspace/android/gradlew.bat" -p "$workspace/android" -I $initPath "-PgodotAarPath=$godotApi" "-PincludeDiagnostics=$($IncludeDiagnostics.IsPresent.ToString().ToLowerInvariant())" @selection :player-plugin:prepareWebVideoDesktopRuntime --console=plain 2>&1 | Out-File (Join-Path $output 'prepare.log') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Desktop media probe compile failed; see build/output/web-video-desktop-host/prepare.log.' }
    $after = Measure-ProbeInputs
    if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { throw 'Media probe inputs changed while preparing; run preparation again.' }
    $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json -AsHashtable
    $runtime['source_sha256'] = $after
    $runtime['include_diagnostics'] = $IncludeDiagnostics.IsPresent
    $runtime['unit_test_filter'] = @($TestFilter)
    [IO.File]::WriteAllText($runtimePath, ($runtime | ConvertTo-Json -Depth 6))
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
Write-Output "Desktop media probe runtime: $runtimePath"
