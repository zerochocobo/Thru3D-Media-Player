[CmdletBinding()]
param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$IncludeDiagnostics)
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
    }
}
'@
$initPath = Join-Path $temporary 'runtime.gradle'
[IO.File]::WriteAllText($initPath, $init.Replace('__RUNTIME__', $runtimePath))
$godotApi = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
$mutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
$held = $false
$inputs = @(
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoBrowserResourceReader.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDouyinCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoNetworkCapture.kt',
    'android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/WebVideoDescriptor.kt',
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
    'android/web-browser/src/main/java/org/vrpassthroughplayer/plugin/WebBrowserNetworkMedia.kt',
    'android/player-plugin/src/test/java/org/vrpassthroughplayer/plugin/WebVideoDesktopProbe.kt',
    'android/player-plugin/src/test/java/org/vrpassthroughplayer/plugin/WebVideoCnDesktopProbe.kt')
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
    & "$workspace/android/gradlew.bat" -p "$workspace/android" -I $initPath "-PgodotAarPath=$godotApi" "-PincludeDiagnostics=$($IncludeDiagnostics.IsPresent.ToString().ToLowerInvariant())" :player-plugin:prepareWebVideoDesktopRuntime --console=plain 2>&1 | Out-File (Join-Path $output 'prepare.log') -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Desktop media probe compile failed; see build/output/web-video-desktop-host/prepare.log.' }
    $after = Measure-ProbeInputs
    if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { throw 'Media probe inputs changed while preparing; run preparation again.' }
    $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json -AsHashtable
    $runtime['source_sha256'] = $after
    $runtime['include_diagnostics'] = $IncludeDiagnostics.IsPresent
    [IO.File]::WriteAllText($runtimePath, ($runtime | ConvertTo-Json -Depth 6))
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
Write-Output "Desktop media probe runtime: $runtimePath"
