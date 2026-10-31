param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$SkipJvm)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/video-mode-transition'
New-Item -ItemType Directory -Force $output | Out-Null
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
if (!$SkipJvm) {
    $taskMutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
    $taskLocked = $false
    try {
        try { $taskLocked = $taskMutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $taskLocked = $true }
        if (!$taskLocked) { throw 'Another build owns the workspace; retry when it completes.' }
        & "$workspace/android/gradlew.bat" -p "$workspace/android" "-PgodotAarPath=$ToolRoot\godot-android-api\4.7.2\godot-lib.template_debug.aar" --offline --console=plain :player-plugin:compileDebugKotlin :player-plugin:compileReleaseKotlin :player-plugin:testDebugUnitTest --tests '*FrameCopyResultsTest' --tests '*MediaSessionGateTest' --tests '*PairDisplayGateTest' *> "$output/android.log"
        if ($LASTEXITCODE) { throw 'Mode transition Android checks failed; see android.log.' }
    } finally { if ($taskLocked) { $taskMutex.ReleaseMutex() }; $taskMutex.Dispose() }
}
$project = Join-Path $workspace 'app/godot'
$cases = @('test_video_mode_transition', 'test_mpv_seek_hold', 'test_frame_picture_layer', 'test_layer_thumbnail', 'test_depth_strength_scale', 'test_video_layer')
foreach ($case in $cases) {
    $arguments = '--headless --xr-mode off --path "{0}" --script res://tests/{1}.gd' -f $project, $case
    $taskProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$output/$case.stdout.log" -RedirectStandardError "$output/$case.stderr.log"
    if (!$taskProcess.WaitForExit(45000)) { Stop-Process -Id $taskProcess.Id; throw "$case timed out." }
    $result = (Get-Content "$output/$case.stdout.log" -Raw) + (Get-Content "$output/$case.stderr.log" -Raw)
    if ($taskProcess.ExitCode -ne 0 -or $result -match 'SCRIPT ERROR|SHADER ERROR|(?m)^ERROR:' -or $result -notmatch '0 failures|failures=0|passed') { throw "$case failed; see build/output/video-mode-transition." }
    $result -split '\r?\n' | Where-Object { $_ -match '0 failures|failures=0|passed' } | Write-Output
}
$arguments = '--xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path "{0}" --script res://tests/test_video_mode_transition.gd' -f $project
$taskProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$output/render.stdout.log" -RedirectStandardError "$output/render.stderr.log"
if (!$taskProcess.WaitForExit(45000)) { Stop-Process -Id $taskProcess.Id; throw 'Mode transition render timed out.' }
$result = (Get-Content "$output/render.stdout.log" -Raw) + (Get-Content "$output/render.stderr.log" -Raw)
if ($taskProcess.ExitCode -ne 0 -or $result -match 'SCRIPT ERROR|SHADER ERROR|(?m)^ERROR:' -or $result -notmatch 'Video mode transition: [0-9]+ checks, 0 failures') { throw 'Mode transition pixels failed; see render logs.' }
$result -split '\r?\n' | Where-Object { $_ -match 'Video mode transition:' } | Write-Output
Write-Output 'Mode transition source checks passed. No APK packaging or device operation.'
