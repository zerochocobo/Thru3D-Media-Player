param([switch]$RenderUI, [switch]$SkipJvm, [string[]]$Cases = @('test_reading_render_cache', 'test_reading_page_window', 'test_pdf_reading', 'test_container_locations', 'test_archive_comics', 'test_archive_memory', 'test_photo_magazine', 'test_photo_recovery', 'test_video_pip_images', 'test_image_picker_memory', 'test_privacy_memory', 'test_recent_files', 'test_library_menu'))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/pdf'
New-Item -ItemType Directory -Force $output | Out-Null
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
if (!$SkipJvm) {
    & "$workspace/android/gradlew.bat" -p "$workspace/android" ('-PgodotAarPath=' + (Join-Path $env:QUEST_TOOL_ROOT 'godot-android-api/4.7.2/godot-lib.template_debug.aar')) :player-plugin:testDebugUnitTest --tests org.vrpassthroughplayer.plugin.ReadingPageCacheTest --tests org.vrpassthroughplayer.plugin.ReadingRenderPolicyTest --tests org.vrpassthroughplayer.plugin.ReadingMemoryPolicyTest --tests org.vrpassthroughplayer.plugin.PdfDocumentsTest --tests org.vrpassthroughplayer.plugin.PdfReadCacheTest --tests org.vrpassthroughplayer.plugin.CloudStreamSourceTest --tests org.vrpassthroughplayer.plugin.PhotoCacheTest --tests org.vrpassthroughplayer.plugin.ArchiveKindsTest --console=plain *> "$output/jvm.log"
    if ($LASTEXITCODE) { throw 'PDF JVM checks failed; see build/output/pdf/jvm.log.' }
}
$env:SDL_JOYSTICK_HIDAPI = '0'
if ($RenderUI) { $Cases += 'render_pdf_reading' }
foreach ($case in $Cases) {
    $mode = if ($case.StartsWith('render_')) { '--rendering-method gl_compatibility' } else { '--headless' }
    $arguments = '{0} --xr-mode off --path "{1}" --script res://tests/{2}.gd' -f $mode, "$workspace/app/godot", $case
    $process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$output/$case.stdout.log" -RedirectStandardError "$output/$case.stderr.log"
    if (!$process.WaitForExit(120000)) { Stop-Process -Id $process.Id; throw "$case timed out." }
    $result = (Get-Content "$output/$case.stdout.log" -Raw) + (Get-Content "$output/$case.stderr.log" -Raw)
    if ($process.ExitCode -ne 0 -or $result -match 'SCRIPT ERROR|SHADER ERROR|(?m)^ERROR:' -or $result -notmatch '0 failures|failures=0|passed') { throw "$case failed; see build/output/pdf." }
    $result -split '\r?\n' | Where-Object { $_ -match '0 failures|failures=0|passed' } | Write-Output
}
Write-Output 'PDF source checks passed. No APK/AAR packaging, installation or device operation.'
