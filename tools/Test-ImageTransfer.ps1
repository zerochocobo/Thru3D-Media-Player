param([string]$Godot = $(if ($env:GODOT_EXE) { $env:GODOT_EXE } else { 'godot' }), [string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/thru3d-toolchain' }), [switch]$SkipJvm, [switch]$Benchmark, [switch]$CoreOnly, [string[]]$Only = @(), [string]$ProjectDirectory = '')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (!$ProjectDirectory) { $ProjectDirectory = Join-Path $workspace 'app/godot' }
$output = Join-Path $workspace 'build/output/image-transfer'
New-Item -ItemType Directory -Force $output | Out-Null
& python "$PSScriptRoot/check_image_transfers.py"
if ($LASTEXITCODE) { throw 'Image transfer source guard failed.' }
if (!$SkipJvm) {
    . "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
    $gate = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
    $held = $false
    try {
        try { $held = $gate.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (!$held) { throw 'Another build owns the workspace; retry after it completes.' }
        & "$workspace/android/gradlew.bat" -p "$workspace/android" "-PgodotAarPath=$ToolRoot/godot-android-api/4.7.2/godot-lib.template_debug.aar" --offline --console=plain :player-plugin:compileDebugKotlin :player-plugin:compileReleaseKotlin :player-plugin:testDebugUnitTest --tests '*RawPhotoTest' --tests '*Photo*Test' --tests '*Panorama*Test' --tests '*PipScreenshotTest' --tests '*Animated*Test' *> "$output/android.log"
        if ($LASTEXITCODE) { throw 'Android image transfer regression failed; see android.log.' }
    } finally { if ($held) { $gate.ReleaseMutex() }; $gate.Dispose() }
}
$cases = @('test_raw_image', 'test_photos', 'test_online_panorama', 'test_photo_preload',
    'test_photo_gallery_resources', 'test_photo_magazine', 'test_photo_loading', 'test_photo_recovery',
    'test_photo_animation', 'test_photo_animation_depth', 'test_photo_portrait', 'test_photo_portrait_cache', 'test_photo_cache_settings',
    'test_photo_depth_payload', 'test_photo_orientation', 'test_video_pip_images', 'test_pip_screenshot', 'render_online_panorama', 'render_photo_animation_depth')
if ($CoreOnly) { $cases = @('test_raw_image') }
if ($Only.Count) {
    foreach ($name in $Only) { if ($name -notin $cases) { throw "Unknown image transfer test: $name" } }
    $cases = $Only
}
if ($Benchmark) { $cases += 'benchmark_image_transfer' }
$failed = @()
foreach ($case in $cases) {
    $outLog = Join-Path $output "$case.stdout.log"
    $errLog = Join-Path $output "$case.stderr.log"
    # test_photos instantiates the real cinema: dummy rendering can report invalid mesh RIDs.
    # Use a hidden real GL window for that integration and the panorama pixel oracle.
    $renderer = if ($case -in @('test_photos','render_online_panorama','render_photo_animation_depth')) { '--rendering-method gl_compatibility --rendering-driver opengl3' } else { '--headless' }
    $arguments = '{0} --xr-mode off --path "{1}" --script res://tests/{2}.gd' -f $renderer, $ProjectDirectory, $case
    $run = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    if (!$run.WaitForExit(180000)) { $run.Kill($true); $failed += "$case (timeout)"; continue }
    $run.WaitForExit()
    $log = (Get-Content $outLog -Raw) + (Get-Content $errLog -Raw)
    if ($run.ExitCode -ne 0 -or $log -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $log -notmatch '0 failures') { $failed += $case }
    Write-Output "$case : exit=$($run.ExitCode)"
}
if ($failed.Count) { throw ('Image transfer regressions failed: ' + ($failed -join ', ')) }
Write-Output "Image transfer regression: $($cases.Count) groups passed."
