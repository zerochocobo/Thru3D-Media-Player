param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$RenderPreview)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$projectDirectory = Join-Path $workspace 'app\godot'
& "$PSScriptRoot/Test-DistributionChannel.ps1" -ToolRoot $ToolRoot
$listeningOutput = Join-Path $workspace 'build/output/live-interpretation'
New-Item -ItemType Directory -Path $listeningOutput -Force | Out-Null
$listeningLog = Join-Path $listeningOutput 'test-live_interpretation.log'
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_live_interpretation.gd 2>&1 | Tee-Object -FilePath $listeningLog
if ($LASTEXITCODE -ne 0 -or (Get-Content $listeningLog -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content $listeningLog -Raw) -notmatch 'Live interpretation: [0-9]+ checks, 0 failures') { throw 'Live interpretation regression failed.' }
$subtitlePanelOutput = Join-Path $workspace 'build/output/subtitle-side-panels'
New-Item -ItemType Directory -Path $subtitlePanelOutput -Force | Out-Null
$subtitlePanelLog = Join-Path $subtitlePanelOutput 'side-panels.log'
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 3000 --script res://tests/test_subtitle_side_panels.gd 2>&1 | Tee-Object -FilePath $subtitlePanelLog
if ($LASTEXITCODE -ne 0 -or (Get-Content $subtitlePanelLog -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content $subtitlePanelLog -Raw) -notmatch 'Subtitle side panels: [0-9]+ checks, 0 failures') { throw 'Subtitle column navigation and composition regression failed.' }
if ($RenderPreview) {
    $subtitlePanelRenderLog = Join-Path $subtitlePanelOutput 'render.log'
    & $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 3000 --script res://tests/render_subtitle_side_panels.gd 2>&1 | Tee-Object -FilePath $subtitlePanelRenderLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $subtitlePanelRenderLog -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or (Get-Content $subtitlePanelRenderLog -Raw) -notmatch 'Subtitle side panel render: [0-9]+ checks, 0 failures') { throw 'Subtitle column render failed.' }
}
& "$PSScriptRoot\Test-VideoPip.ps1" -Godot $env:GODOT_EXE
& "$PSScriptRoot\Test-PictureCenterGuide.ps1" -Godot $env:GODOT_EXE -Focused
$orderOutput = Join-Path $workspace 'build/output/media-browse-order'
New-Item -ItemType Directory -Path $orderOutput -Force | Out-Null
$orderLog = Join-Path $orderOutput 'test_media_browse_order.log'
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_browse_order.gd 2>&1 | Tee-Object -FilePath $orderLog
if ($LASTEXITCODE -ne 0 -or (Get-Content $orderLog -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content $orderLog -Raw) -notmatch 'Media browse order: [0-9]+ checks, 0 failures') { throw 'Media browse order / return position regression failed.' }
$videoUxOutput = Join-Path $workspace 'build/output/video-modes-ray'
New-Item -ItemType Directory -Path $videoUxOutput -Force | Out-Null
foreach ($videoUxTest in @('test_video_playback_modes', 'test_video_idle_rays')) {
    $videoUxLog = Join-Path $videoUxOutput ($videoUxTest + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script ('res://tests/' + $videoUxTest + '.gd') 2>&1 | Tee-Object -FilePath $videoUxLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $videoUxLog -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content $videoUxLog -Raw) -notmatch 'Video (playback modes|idle rays): [0-9]+ checks, 0 failures') { throw ('Video playback mode / idle pointer regression failed: ' + $videoUxTest) }
}
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_video_playback_modes.gd 2>&1 | Tee-Object -FilePath (Join-Path $videoUxOutput 'visuals.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $videoUxOutput 'visuals.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or (Get-Content (Join-Path $videoUxOutput 'visuals.log') -Raw) -notmatch 'Video playback modes render: [0-9]+ checks, 0 failures') { throw 'Video playback mode visual and ray regression failed.' }
New-Item -ItemType Directory -Path (Join-Path $workspace 'build/output/background-audio') -Force | Out-Null
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_music_video.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/background-audio/music-video.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/background-audio/music-video.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $workspace 'build/output/background-audio/music-video.log') -Raw) -notmatch 'Music with video: [0-9]+ checks, 0 failures') { throw 'Simultaneous music/video regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_music_quick_controls.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/background-audio/quick-controls.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/background-audio/quick-controls.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Music quick controls and preview regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_audio_native_transport.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/background-audio/native-transport.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/background-audio/native-transport.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Native music transport regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_background_audio.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/background-audio/test.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/background-audio/test.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $workspace 'build/output/background-audio/test.log') -Raw) -notmatch 'Background audio: [0-9]+ checks, 0 failures') { throw 'Background audio and offline import regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_background_audio.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/background-audio/render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/background-audio/render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $workspace 'build/output/background-audio/render.log') -Raw) -notmatch 'Background audio render: [0-9]+ checks, 0 failures') { throw 'Background audio visual and ray regression failed.' }
New-Item -ItemType Directory -Path (Join-Path $workspace 'build/output') -Force | Out-Null
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_controller_bindings.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/controller-bindings-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/controller-bindings-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Controller bindings regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_controller_feedback.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/controller-feedback-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/controller-feedback-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $workspace 'build/output/controller-feedback-host.log') -Raw) -notmatch 'Controller feedback: [0-9]+ checks, 0 failures') { throw 'World controller feedback and picture manipulation regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_controller_feedback.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/controller-feedback-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/controller-feedback-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or (Get-Content (Join-Path $workspace 'build/output/controller-feedback-render.log') -Raw) -notmatch 'Controller feedback render: [0-9]+ checks, 0 failures') { throw 'World controller pointer pixels regression failed.' }
$watchOutput = Join-Path $workspace 'build/output/wrist-watch'
New-Item -ItemType Directory -Path $watchOutput -Force | Out-Null
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_wrist_watch.gd 2>&1 | Tee-Object -FilePath (Join-Path $watchOutput 'host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $watchOutput 'host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $watchOutput 'host.log') -Raw) -notmatch 'Wrist watch: [0-9]+ checks, 0 failures') { throw 'Wrist watch interaction regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_watch_toggle.gd 2>&1 | Tee-Object -FilePath (Join-Path $watchOutput 'toggle-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $watchOutput 'toggle-host.log') -Raw) -notmatch 'Watch toggle: [0-9]+ checks, 0 failures') { throw 'Wrist watch toggle wiring failed.' }
$env:THRU3D_TEST_OUTPUT = $watchOutput
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 3000 --script res://tests/render_wrist_watch.gd 2>&1 | Tee-Object -FilePath (Join-Path $watchOutput 'render.log')
$env:THRU3D_TEST_OUTPUT = $watchOutput
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_watch_toggle.gd 2>&1 | Tee-Object -FilePath (Join-Path $watchOutput 'toggle.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $watchOutput 'toggle.log') -Raw) -notmatch 'Watch toggle render: [0-9]+ checks, 0 failures') { throw 'Wrist watch toggle failed.' }
Remove-Item Env:THRU3D_TEST_OUTPUT
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $watchOutput 'render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or (Get-Content (Join-Path $watchOutput 'render.log') -Raw) -notmatch 'Wrist watch render: [0-9]+ checks, 0 failures') { throw 'Wrist watch rendering failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_portrait.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/photo-portrait-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/photo-portrait-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Photo portrait regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_photo_portrait.gd 2>&1 | Tee-Object -FilePath (Join-Path $workspace 'build/output/photo-portrait-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $workspace 'build/output/photo-portrait-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo portrait pixels failed.' }
$logDirectory = Join-Path $workspace 'build\output\logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
foreach ($privacyMemoryTest in @('test_smb_stereo_memory', 'test_privacy_memory')) {
    $privacyMemoryLog = Join-Path $logDirectory ($privacyMemoryTest + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script ('res://tests/' + $privacyMemoryTest + '.gd') 2>&1 | Tee-Object -FilePath $privacyMemoryLog
    $privacyMemoryResult = Get-Content -LiteralPath $privacyMemoryLog -Raw
    if ($LASTEXITCODE -ne 0 -or $privacyMemoryResult -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $privacyMemoryResult -notmatch '(SMB stereo memory|Independent privacy memory) checks=[0-9]+ failures=0') { throw ('Independent history and per-file memory regression failed: ' + $privacyMemoryTest) }
}
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_collections.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'collections-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'collections-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'collections-host.log') -Raw) -notmatch 'Collections: [0-9]+ checks, 0 failures') { throw 'Favorites, source navigation and privacy regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_collection_interactions.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'collection-interactions-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'collection-interactions-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'collection-interactions-host.log') -Raw) -notmatch 'Collection interactions: [0-9]+ checks, 0 failures') { throw 'Collection interaction regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_view_follow.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'view-follow-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'view-follow-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'View follow and session footer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_interface_depth.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'interface-depth-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'interface-depth-host.log') -Raw) -notmatch 'Interface depth: [0-9]+ checks, 0 failures') { throw 'Interface depth and video recenter regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_distance.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-distance-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'library-distance-host.log') -Raw) -notmatch 'Library distance: [0-9]+ checks, 0 failures') { throw 'Library distance preference regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 18000 --script res://tests/test_photo_layouts.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-layouts-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-layouts-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'photo-layouts-host.log') -Raw) -notmatch 'Photo layouts: [0-9]+ checks, 0 failures') { throw 'Photo layout regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_memory_swipe.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'memory-swipe-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'memory-swipe-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Memory displacement swipe regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 18000 --script res://tests/render_photo_layouts.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-layouts-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-layouts-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'photo-layouts-render.log') -Raw) -notmatch 'Photo layout render: [0-9]+ checks, 0 failures') { throw 'Photo layout rendering failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_spatial_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'spatial-photos-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'spatial-photos-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Spatial photo regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_spatial_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'spatial-photos-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'spatial-photos-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Spatial eye/disparity rendering failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_loading.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-loading-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-loading-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Photo loading feedback regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_presentation.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-presentation-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-presentation-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'photo-presentation-host.log') -Raw) -notmatch 'Photo presentation: [0-9]+ checks, 0 failures') { throw 'Photo presentation readiness regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_photo_loading.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-loading-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-loading-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo loading pixels failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_depth_payload.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-depth-payload.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-depth-payload.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Photo depth payload regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_photo_depth_resolution.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-depth-resolution.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-depth-resolution.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo depth resolution rendering failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_input_visuals.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'input-visuals-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'input-visuals-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Input model visibility regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_menu_depth.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-depth-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-depth-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Menu and input model depth regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_menu_text_sampling.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-text-sampling.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-text-sampling.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Menu text sampling regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_menu_tooltips.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-tooltips.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-tooltips.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Menu tooltip regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_fisheye_layer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'fisheye-layer.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'fisheye-layer.log') -Raw) -notmatch 'Fisheye layer: [0-9]+ checks, 0 failures') { throw 'Fisheye picture layer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_playback_stall_watch.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'playback-stall-watch.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'playback-stall-watch.log') -Raw) -notmatch 'Playback stall watch: [0-9]+ checks, 0 failures') { throw 'Playback stall watch regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_refresh_policy.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'refresh-policy.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'refresh-policy.log') -Raw) -notmatch 'Refresh policy: [0-9]+ checks, 0 failures') { throw 'Video refresh-rate policy regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_diagnostic_log_rotation.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'diagnostic-log-rotation.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'diagnostic-log-rotation.log') -Raw) -notmatch 'Diagnostic log rotation: [0-9]+ checks, 0 failures') { throw 'Diagnostic event log rotation regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_layer_cadence.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'layer-cadence.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'layer-cadence.log') -Raw) -notmatch 'Layer cadence: [0-9]+ checks, 0 failures') { throw 'Layer cadence runtime gate regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2400 --script res://tests/test_dropdown_composition.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'dropdown-composition.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'dropdown-composition.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'dropdown-composition.log') -Raw) -notmatch 'Dropdown composition: [0-9]+ checks, 0 failures') { throw 'Dropdown and surrounding menu capture regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_menu_composition.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-composition.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-composition.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Menu compositor capture regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_menu_slots.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-slots.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-slots.log') -Raw) -notmatch 'Menu slots: [0-9]+ checks, 0 failures') { throw 'Menu compositor slot shape regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_music_hover.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'music-hover-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'music-hover-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)' -or (Get-Content (Join-Path $logDirectory 'music-hover-render.log') -Raw) -notmatch 'Music hover rendering: [0-9]+ checks, 0 failures') { throw 'Music hover capture stability regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_playback_recovery.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'playback-recovery-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'playback-recovery-render.log') -Raw) -notmatch 'Playback recovery render: [0-9]+ checks, 0 failures') { throw 'Playback browser lifecycle capture regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_menu_edge_coverage.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'menu-edge-coverage.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'menu-edge-coverage.log') -Raw) -notmatch 'Menu edge coverage: [0-9]+ checks, 0 failures') { throw 'Menu fractional edge coverage regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_layer_backdrop.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'layer-backdrop.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'layer-backdrop.log') -Raw) -notmatch 'Layer backdrop: [0-9]+ checks, 0 failures') { throw 'Layer backdrop sky regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_i18n.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'i18n-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'i18n-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'UI localization regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_hand_pointer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'hand-pointer-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'hand-pointer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Hand pointer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_hand_gestures.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-hands-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-hands-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo hand gesture regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_input_visibility.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-input-visibility-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-input-visibility-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'photo-input-visibility-host.log') -Raw) -notmatch 'Photo input visibility: [0-9]+ checks, 0 failures') { throw 'Photo input visibility regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_palm_swipe.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-palm-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-palm-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo palm swipe regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_photo_preload.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-preload-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-preload-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo preload/cycle regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_comic_depth_navigation.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'comic-depth-navigation-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'comic-depth-navigation-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'comic-depth-navigation-host.log') -Raw) -notmatch 'Comic depth navigation: [0-9]+ checks, 0 failures') { throw 'Comic depth navigation regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_photo_immersive.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-immersive-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-immersive-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Immersive photo rendering failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c01_c02.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'Host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c03_media.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c03-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C03 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c03-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C03 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c04_layout.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c04-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C04 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c04-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C04 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_video_layer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'video-layer-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'video-layer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Compositor video layer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_rotation.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-rotation-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'mpv-rotation-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV source rotation regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_frame_picture_layer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'frame-picture-layer-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'frame-picture-layer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Frame picture layer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_subtitle_layers.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'subtitle-layers-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'subtitle-layers-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'subtitle-layers-host.log') -Raw) -notmatch 'Subtitle layers: [0-9]+ checks, 0 failures') { throw 'PGS compositor layers and depth conversion regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_flat_subtitle_layers.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'flat-subtitle-layers.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'flat-subtitle-layers.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'flat-subtitle-layers.log') -Raw) -notmatch 'Flat subtitle layers: [0-9]+ checks, 0 failures') { throw 'Flat text subtitle capture, menu budget and clarity regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_alpha_profile.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'alpha-profile-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'alpha-profile-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Alpha model size regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_video_portrait.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'video-portrait-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'video-portrait-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Mono portrait policy regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_video_portrait.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'video-portrait-gles.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'video-portrait-gles.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:)') { throw 'Mono portrait GLES regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_packed_mask.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'packed-mask-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'packed-mask-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Built-in Alpha mask regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_c05_playback.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'c05-host-regression.log')
if ($LASTEXITCODE -ne 0) { throw 'C05 host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'c05-host-regression.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C05 host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_end.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-end-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV EOF host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-end-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV EOF host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_seek_hold.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-seek-hold-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'mpv-seek-hold-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV seek hold regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_layer_thumbnail.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'layer-thumbnail-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'layer-thumbnail-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Compositor layer thumbnail regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_seek_policy.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'seek-policy-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'seek-policy-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Seek precision preferences and actual timeline regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_choice_fields.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'choice-fields-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'choice-fields-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Grouped radio and dropdown settings regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_audio.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-audio-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV audio host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-audio-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV audio host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_whisper_audio.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'whisper-audio-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'whisper-audio-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Per-video whisper enhancement regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_mpv_subtitles.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'mpv-subtitles-host.log')
if ($LASTEXITCODE -ne 0) { throw 'MPV subtitle host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'mpv-subtitles-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'MPV subtitle host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_subtitle_files.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'subtitle-files-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'subtitle-files-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Sibling subtitle selection, restoration and pair timing regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_subtitle_effect_recovery.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'subtitle-effect-recovery-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'subtitle-effect-recovery-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'subtitle-effect-recovery-host.log') -Raw) -notmatch 'Subtitle effect recovery checks=\d+ failures=0') { throw 'Subtitle and narration recovery across output changes failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_mode_memory.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-mode-memory-host.log')
if ($LASTEXITCODE -ne 0) { throw 'File mode memory host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'file-mode-memory-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'File mode memory host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_track_memory.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-track-memory-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'file-track-memory-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Per-file audio and subtitle restoration regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_player_sticks.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'player-sticks-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Player stick host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'player-sticks-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Player stick host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_immersive_adjustments.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'immersive-adjustments-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'immersive-adjustments-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'immersive-adjustments-host.log') -Raw) -notmatch 'Immersive adjustments: [0-9]+ checks, 0 failures') { throw 'Immersive grip controls and per-file adjustments regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_seek_feedback.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'seek-feedback-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'seek-feedback-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'seek-feedback-host.log') -Raw) -notmatch 'Seek feedback checks=\d+ failures=0') { throw 'Deferred stick seek feedback regression failed.' }
if ($RenderPreview) {
    & $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_immersive_adjustments.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'immersive-adjustments-render.log')
    if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'immersive-adjustments-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'immersive-adjustments-render.log') -Raw) -notmatch 'Immersive adjustments render: [0-9]+ checks, 0 failures') { throw 'Immersive settings and fixed controls visual regression failed.' }
    $env:THRU3D_TEST_OUTPUT = Join-Path $logDirectory 'seek-feedback-previews'
    & $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_seek_feedback.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'seek-feedback-render.log')
    if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'seek-feedback-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'seek-feedback-render.log') -Raw) -notmatch 'Seek feedback previews cases=28 checks=\d+ failures=0') { throw 'Seek feedback visual regression failed.' }
}
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_recent_files.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'recent-files-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Recent files host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'recent-files-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Recent files host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_recent_pointer.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'recent-pointer-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Recent pointer host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'recent-pointer-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Recent pointer host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_color_grade.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'color-grade-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'color-grade-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Color grading controls failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_color_grade.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'color-grade-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'color-grade-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Color grading pixels failed.' }
# Library pictures render a frame, so this one needs a renderer.
& $env:GODOT_EXE --xr-mode off --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/test_thumbnails.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'thumbnails-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Library picture host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'thumbnails-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Library picture host regression reported runtime errors.' }
# 2D->3D per-eye parallax from the near map (desktop OpenGL; XR multiview not covered).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_depth_parallax.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'depth-parallax-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Depth parallax render regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_dlna_menu.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'dlna-menu-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'dlna-menu-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'DLNA menu regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_menu.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-menu-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Library menu host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_views.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-views-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'library-views-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Library view mode and position regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_metadata.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-metadata-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'library-metadata-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Played video capacity and metadata regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_compact_library.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'compact-library-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'compact-library-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Playback library expansion, input and placement regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_large_playback_list.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'large-playback-list-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'large-playback-list-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'large-playback-list-host.log') -Raw) -notmatch 'Large playback list checks=\d+ failures=0') { throw 'Large playback list scrolling and selection regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_mutation_position.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-mutation-position-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'file-mutation-position-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'file-mutation-position-host.log') -Raw) -notmatch 'File mutation position checks=\d+ failures=0') { throw 'File mutation position and incremental directory update regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_file_actions.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-file-actions-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'library-file-actions-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Library editing and directory sorting regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_management_lists.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-management-lists-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'file-management-lists-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Opt-in checkboxes, batch deletion and active-file release regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_management_entry.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-management-entry-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'file-management-entry-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'file-management-entry-host.log') -Raw) -notmatch 'File management entry: [0-9]+ checks, 0 failures') { throw 'File management discovery and settings return regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_library_sort.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'library-sort-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'library-sort-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Folder modification time and DLNA name sorting regression failed.' }
foreach ($directorySortTest in @('test_directory_preferences', 'test_library_navigation_memory', 'test_directory_cloud_navigation')) {
    $directorySortLog = Join-Path $logDirectory ($directorySortTest + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script ('res://tests/' + $directorySortTest + '.gd') 2>&1 | Tee-Object -FilePath $directorySortLog
    $directorySortResult = Get-Content -LiteralPath $directorySortLog -Raw
    if ($LASTEXITCODE -ne 0 -or $directorySortResult -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $directorySortResult -notmatch '(Directory preferences: [0-9]+ checks, 0 failures|Library navigation memory checks=[0-9]+ failures=0|Cloud directory navigation: [0-9]+ checks, 0 failures)') { throw ('Per-directory sorting and parent navigation regression failed: ' + $directorySortTest) }
}
foreach ($browseTest in @('test_directory_browse_memory', 'test_directory_browse_cloud')) {
    $browseLog = Join-Path $logDirectory ($browseTest + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2400 --script ('res://tests/' + $browseTest + '.gd') 2>&1 | Tee-Object -FilePath $browseLog
    $browseResult = Get-Content -LiteralPath $browseLog -Raw
    if ($LASTEXITCODE -ne 0 -or $browseResult -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $browseResult -notmatch 'Directory browse (memory|cloud): [0-9]+ checks, 0 failures') { throw ('Directory resume/privacy regression failed: ' + $browseTest) }
}
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_file_editing_memory.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'file-editing-memory-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'file-editing-memory-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Renamed history and bookmarks regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_local_storage.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'local-storage-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'local-storage-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Removable storage host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_cloud_pagination.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'cloud-pagination-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'cloud-pagination-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Cloud pagination regression failed.' }
foreach ($pagingTest in @('test_cloud_native_paging', 'test_cloud_paging_options')) {
    $pagingLog = Join-Path $logDirectory ($pagingTest + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script ('res://tests/' + $pagingTest + '.gd') 2>&1 | Tee-Object -FilePath $pagingLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $pagingLog -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw "Cloud paging regression failed: $pagingTest" }
}
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_servers.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-servers-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'media-servers-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Media server host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_server_browser.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-server-browser-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'media-server-browser-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Media server browser regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_server_management.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-server-management-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'media-server-management-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Media server management UI regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_cloud_accounts.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'cloud-accounts-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'cloud-accounts-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Cloud account management regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_account_panel.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'in-app-accounts-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'in-app-accounts-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'In-app account UI regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_plex_accounts.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'plex-accounts-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'plex-accounts-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Plex account UI regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_media_naming.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'media-naming-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Media naming host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_spatial_videos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'spatial-videos-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'spatial-videos-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Spatial video layout regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_spatial_video_metadata.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'spatial-video-metadata-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'spatial-video-metadata-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Spatial video metadata regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_playback_settings.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'playback-settings-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'playback-settings-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Playback settings regression failed.' }
# Alpha-packed fisheye files decoded by the MPV pair shader (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_packed_alpha_pair.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'packed-alpha-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Packed alpha render regression failed.' }
# Top-bottom eyes and fisheye lens angles in the MPV pair shader (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_layout_lens.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'layout-lens-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Layout and lens render regression failed.' }
# Flat screen curved round the eyes, with a corner bracket (desktop OpenGL).
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_screen_curve.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'screen-curve-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Screen curve render regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_player_menu.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'player-menu-host.log')
if ($LASTEXITCODE -ne 0) { throw 'Player menu host regression failed.' }
if ((Get-Content (Join-Path $logDirectory 'player-menu-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Player menu host regression reported runtime errors.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1200 --script res://tests/test_bar_action_hits.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'bar-action-hits.log')
$barHitLog = Get-Content (Join-Path $logDirectory 'bar-action-hits.log') -Raw
if ($LASTEXITCODE -ne 0 -or $barHitLog -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $barHitLog -notmatch 'Bar action hits: [0-9]+ checks, 0 failures') { throw 'Floating action hit areas and safety gaps regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_bookmarks.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'bookmarks-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'bookmarks-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Bookmark storage and pointer regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_bookmark_loops.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'bookmark-loops-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'bookmark-loops-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or (Get-Content (Join-Path $logDirectory 'bookmark-loops-host.log') -Raw) -notmatch 'Bookmark loops: [0-9]+ checks, 0 failures') { throw 'Bookmark A-B loop regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_audio_popup.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'audio-popup-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'audio-popup-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Audio popup and bookmark entry regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_flat_screen_controls.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'flat-screen-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'flat-screen-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Flat screen controls regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2500 --script res://tests/test_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photos-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photos-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo host regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2500 --script res://tests/test_photo_adjustments.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-adjustments-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-adjustments-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo adjustments regression failed.' }
& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 2500 --script res://tests/test_photo_inspect_input.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-inspect-input-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-inspect-input-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo inspect input regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 2500 --script res://tests/render_photos.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photos-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photos-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo render regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 2500 --script res://tests/render_photo_adjustments.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-adjustments-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-adjustments-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo adjustments render regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 2500 --script res://tests/render_photo_magnifier.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-magnifier-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-magnifier-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo magnifier render regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 3000 --script res://tests/render_photo_magnifier_scale.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'photo-magnifier-scale-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'photo-magnifier-scale-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Photo magnifier visual scale regression failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 3000 --script res://tests/test_background.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'background-test.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'background-test.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Application background regression failed.' }
if ($RenderPreview) {
    $env:QUEST_PREVIEW_PATH = Join-Path $workspace 'build\output\calibration-preview.png'
    $stdoutPath = Join-Path $logDirectory 'preview-render.log'
    $stderrPath = Join-Path $logDirectory 'preview-render-errors.log'
    $arguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_calibration.gd')
    $process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $process.WaitForExit(60000)) { throw "Preview process remains active (PID $($process.Id)); inspect it before retrying." }
    if ($process.ExitCode -ne 0) { throw 'OpenGL preview process failed.' }
    $renderLog = (Get-Content $stdoutPath -Raw) + (Get-Content $stderrPath -Raw)
    if ($renderLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'OpenGL preview reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_PREVIEW_PATH)) { throw 'OpenGL preview did not produce an image.' }
    Write-Output "Preview: $env:QUEST_PREVIEW_PATH"
    $env:QUEST_VIDEO_UV_PATH = Join-Path $workspace 'build\output\video-uv-preview.png'
    $uvStdout = Join-Path $logDirectory 'video-uv-render.log'
    $uvStderr = Join-Path $logDirectory 'video-uv-render-errors.log'
    $uvArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_video_uv.gd')
    $uvProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $uvArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $uvStdout -RedirectStandardError $uvStderr
    if (-not $uvProcess.WaitForExit(60000)) { throw "Video UV render remains active (PID $($uvProcess.Id)); inspect it before retrying." }
    if ($uvProcess.ExitCode -ne 0) { throw 'C03 video UV render failed.' }
    $uvLog = (Get-Content $uvStdout -Raw) + (Get-Content $uvStderr -Raw)
    if ($uvLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C03 video UV render reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_VIDEO_UV_PATH)) { throw 'C03 video UV render did not produce an image.' }
    Write-Output "Video UV preview: $env:QUEST_VIDEO_UV_PATH"
    $env:QUEST_C04_ALPHA_PATH = Join-Path $workspace 'build\output\c04-alpha-preview.png'
    $alphaStdout = Join-Path $logDirectory 'c04-render.log'
    $alphaStderr = Join-Path $logDirectory 'c04-render-errors.log'
    $alphaArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_c04_alpha.gd')
    $alphaProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $alphaArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $alphaStdout -RedirectStandardError $alphaStderr
    if (-not $alphaProcess.WaitForExit(60000)) { throw "C04 render remains active (PID $($alphaProcess.Id)); inspect it before retrying." }
    if ($alphaProcess.ExitCode -ne 0) { throw 'C04 render failed.' }
    $alphaLog = (Get-Content $alphaStdout -Raw) + (Get-Content $alphaStderr -Raw)
    if ($alphaLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'C04 render reported errors.' }
    if (-not (Test-Path -LiteralPath $env:QUEST_C04_ALPHA_PATH)) { throw 'C04 render did not produce an image.' }
    Write-Output "C04 Alpha preview: $env:QUEST_C04_ALPHA_PATH"
    $env:QUEST_R03_PAIR_PATH = Join-Path $workspace 'build\output\r03-pair-render.json'
    $pairStdout = Join-Path $logDirectory 'r03-pair-render.log'
    $pairStderr = Join-Path $logDirectory 'r03-pair-render-errors.log'
    $pairArguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3','--path',$projectDirectory,'--script','res://tests/render_r03_pair.gd')
    $pairProcess = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $pairArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $pairStdout -RedirectStandardError $pairStderr
    if (-not $pairProcess.WaitForExit(60000)) { throw "R03 pair render remains active (PID $($pairProcess.Id)); inspect it before retrying." }
    if ($pairProcess.ExitCode -ne 0) { throw 'R03 native pair render failed.' }
    $pairLog = (Get-Content $pairStdout -Raw) + (Get-Content $pairStderr -Raw)
    if ($pairLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'R03 native pair render reported errors.' }
    $pairReport = Get-Content $env:QUEST_R03_PAIR_PATH -Raw | ConvertFrom-Json
    if ($pairReport.state -ne 'passed' -or $pairReport.samples.Count -ne 288 -or $pairReport.borrow_cycles -ne 3) { throw 'R03 pair render evidence incomplete.' }
    Write-Output "R03 native pair render: $env:QUEST_R03_PAIR_PATH"
}

& $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script res://tests/test_display_quality.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'display-quality-host.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'display-quality-host.log') -Raw) -match '(?m)^(SCRIPT ERROR:|ERROR:)') { throw 'Display quality settings failed.' }
& $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script res://tests/render_sharpness.gd 2>&1 | Tee-Object -FilePath (Join-Path $logDirectory 'sharpness-render.log')
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logDirectory 'sharpness-render.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Sharpness pixels failed.' }

foreach ($regression in @('test_mode_unlock', 'test_immersive_lifecycle')) {
    $regressionLog = Join-Path $logDirectory ($regression + '.log')
    & $env:GODOT_EXE --headless --xr-mode off --path $projectDirectory --quit-after 1800 --script ("res://tests/" + $regression + '.gd') 2>&1 | Tee-Object -FilePath $regressionLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $regressionLog -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "$regression failed." }
}
foreach ($regression in @('render_immersive_alignment', 'render_alpha_menu_clarity')) {
    $regressionLog = Join-Path $logDirectory ($regression + '.log')
    & $env:GODOT_EXE --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $projectDirectory --quit-after 1800 --script ("res://tests/" + $regression + '.gd') 2>&1 | Tee-Object -FilePath $regressionLog
    if ($LASTEXITCODE -ne 0 -or (Get-Content $regressionLog -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw "$regression failed." }
}
