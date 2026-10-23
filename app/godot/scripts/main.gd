extends Node3D

const ScreenPresets := preload("res://scripts/screen_presets.gd")

const DisplayController := preload("res://scripts/xr_display.gd")
const Board := preload("res://scripts/calibration_board.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const MediaLocation := preload("res://scripts/media_location.gd")
var favorites: RefCounted
var _migrating_favorites := false
var _playing_protected := false
const Log := preload("res://scripts/diagnostic_log.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const AlphaEdge := preload("res://scripts/alpha_edge.gd")
const StickControls := preload("res://scripts/player_stick_controls.gd")
const HandPointer := preload("res://scripts/hand_pointer.gd")
const InputVisuals := preload("res://scripts/input_visuals.gd")
const ControllerFeedback := preload("res://scripts/controller_feedback.gd")
const WristWatch := preload("res://scripts/wrist_watch.gd")
## Hand-tracking wrist watch; the control bar's watch toggle (watch/enabled) turns it off.
var wrist_watch: Node3D
var _watch_owned := false
var _watch_probe_ms := 0
const Geometry := preload("res://scripts/video_geometry.gd")
const LibraryMenu := preload("res://scripts/library_menu.gd")
const PuzzleLibraryMenu := preload("res://scripts/puzzle/puzzle_library_menu.gd")
const StorageVolume := preload("res://scripts/storage_volume.gd")
const Quality := preload("res://scripts/display_quality.gd")
const ThumbnailCache := preload("res://scripts/thumbnail_cache.gd")
const SETTINGS_PATH := "user://player_settings.cfg"
const LIBRARY_DISTANCE_DEFAULT := 1.4
const PhotoDisplay := preload("res://scripts/photo_display.gd")
const PhotoMenu := preload("res://scripts/puzzle/puzzle_photo_menu.gd")
const PuzzleHost := preload("res://scripts/puzzle/puzzle_host.gd")
var puzzle_game: Node3D
const PhotoHandGestures := preload("res://scripts/photo_hand_gestures.gd")
const PhotoPalmSwipe := preload("res://scripts/photo_palm_swipe.gd")
const ImageInfo := preload("res://scripts/image_info.gd")
const PlayerMenu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const PlatformMethods := preload("res://scripts/platform_methods.gd")
const FpsOverlay := preload("res://scripts/fps_overlay.gd")
const PlaybackStatusOverlay := preload("res://scripts/playback_status_overlay.gd")
const SeekFeedback := preload("res://scripts/seek_feedback.gd")
const SeekOverlay := preload("res://scripts/seek_overlay.gd")
const Background := preload("res://scripts/app_background.gd")
const CinemaEnvironment := preload("res://scripts/environments/cinema_environment.gd")
const CinemaFilmLight := preload("res://scripts/environments/cinema_film_light.gd")
const CinemaFeature := preload("res://scripts/environments/cinema_feature.gd")
const CinemaMenuLayout := preload("res://scripts/environments/cinema_menu_layout.gd")
## Picture size on the fixed cinema screen, as a fraction of the largest fit.
const CINEMA_PICTURE_MIN := 0.4
## Shrinking moves the picture centre down by this share of the freed height.
const CINEMA_PICTURE_DROP := 0.2
## Automatic house lights wait this long after playback stops before rising.
const CINEMA_LIGHTS_UP_DELAY_MS := 1500
## -1 while playback is requested; otherwise when it stopped (0 = long ago).
var _cinema_lights_idle_since := 0
var cinema_environment: Node3D
## Samples the picture so the baked screen light follows the film.
var cinema_film_light: Node
var _cinema_screen_saved := {}
var _cinema_transport_saved := {}
var _cinema_desktop_look := false
var _cinema_last_mode := "watch"
var _cinema_was_active := false
var _cinema_move_hands := {}
const BackgroundAudio := preload("res://scripts/background_audio.gd")
var background_audio: Node
var _background_save_after := 0
var _background_app_paused := false
const MusicMenu := preload("res://scripts/music_menu.gd")
var music_menu: Node3D
var _music_return_photo := false
var _music_return_video := false
var _audio_import_pending := false
var _audio_import_playlist := ""
var _audio_file_dialog: FileDialog
var _subtitle_browse_session := 0
const ViewFollow := preload("res://scripts/view_follow.gd")
const ControllerBindings := preload("res://scripts/controller_bindings.gd")
const InterfaceMove := preload("res://scripts/interface_move.gd")
const MenuComposition := preload("res://scripts/menu_composition.gd")
var menu_composition: Node
var controller_bindings := ControllerBindings.new()
var interface_move := InterfaceMove.new()
var _controller_consumed := {}
const RVM_PROFILES := ["256x144", "384x216", "512x288", "256x256", "384x384", "512x512", "320x320"]
const ALPHA_FPS_DEFAULT := 30
const ALPHA_FPS_LIMITS := Vector2i(10, 40)

var display := DisplayController.new()
var display_quality := Quality.DEFAULT
## GPU name used for the quality tier; empty reads the active renderer (tests may preset it).
var gpu_adapter := ""
var low_end_gpu := false
var status_label: Label3D
## The capability report is built and written on the main thread (about 8-12 ms on Quest 3), so
## it follows state changes instead of a fixed clock; a steady cadence cost a late frame each time.
var report_timer: Timer
const REPORT_INTERVAL := 2.0
## Device tools poll the report: a debug command keeps the periodic report on this long.
const REPORT_TOOLING_MS := 600000
## Coalesces bursts of state changes into one report.
const REPORT_MIN_GAP_MS := 2000
var _report_tooling_until := -1
var _report_due_ms := -1
var _report_saved_ms := -REPORT_MIN_GAP_MS
var platform_plugin: Object
var last_request := 0
var android_report: Dictionary = {}
var photo: Node3D
var photo_active := false
var video_menu: Node3D
var photo_menu: Node3D
var video: Node3D
var video_queue: Array[Dictionary] = []
const VideoQueuePages := preload("res://scripts/video_queue_pages.gd")
const PLAYBACK_MODES := ["single", "repeat_one", "sequence", "repeat_all"]
const PLAYBACK_NAMES := {"single": "Single video", "repeat_one": "Repeat video", "sequence": "Play in order", "repeat_all": "Repeat playlist"}
var playback_mode := "single"
var video_queue_pages := VideoQueuePages.new()
var video_directory: Node
var _video_directory_reorder := false
var _video_directory_location := {}
var _video_queue_wait := {}
var _pending_video_end := {}
var calibration_board: Node3D
var last_rvm_request := 0
var next_rvm_case := 0
var rvm_report: Dictionary = {}
var rvm_status := "RVM benchmark not run"
var right_controller: XRController3D
var left_controller: XRController3D
var hand_pointers := {}
var photo_hands := PhotoHandGestures.new()
var photo_swipe := PhotoPalmSwipe.new()
var memory_swipe := preload("res://scripts/memory_swipe.gd").new()
var _gallery_save_after := 0
var _gallery_saved_state := ""
var _pip_image_target: WeakRef
var _pip_image_dialog: FileDialog
var _photo_open_hide_controls := false
var _photo_pointer_hand := ""
var _inspect_hand := ""
var _inspect_blocked := {}
var _inspect_desktop_ray: Variant
var hand_marks := {}
var input_visuals: Node3D
var controller_feedback: Node3D
var _flat_zoom_hand := ""
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var fps_overlay: Label3D
var playback_status_overlay: Label3D
var capture_overlay: Node3D
var disc_menu_bar: Node3D
var seek_overlay: Node3D
var seek_feedback := SeekFeedback.new()
var stick_controls := StickControls.new()
var recent_menu: Node3D
var cast_session := preload("res://scripts/cast_session.gd").new()
var player_menu: Node3D
var settings := ConfigFile.new()
var settings_path := SETTINGS_PATH
var directory_browse_memory := preload("res://scripts/directory_browse_memory.gd").new()
var _audio_save_after := 0
var background: Node
var view_follow := ViewFollow.new()
var temporary_passthrough := false
var controlled_request := 0
var controlled_report: Dictionary = {}
var controlled_status := "Controlled decoder probe not run"

func _init() -> void:
	stick_controls.suspended.connect(seek_feedback.cancel_preview)

func _create_video_display() -> Node3D:
	return Video.new()

func _ready() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var origin := XROrigin3D.new()
	xr_origin = origin
	origin.name = "XROrigin3D"
	add_child(origin)
	var camera := XRCamera3D.new()
	xr_camera = camera
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	var desktop := OS.get_name() != "Android" or OS.get_cmdline_user_args().has("--mpv-diagnostic-2d")
	if desktop:
		camera.position.y = 1.6
	for hand in ["left_hand", "right_hand"]:
		hand_pointers[hand] = HandPointer.new()
		var mark := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.006
		sphere.height = 0.012
		mark.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
		mark.material_override = material
		mark.visible = false
		origin.add_child(mark)
		hand_marks[hand] = mark
		var controller := XRController3D.new()
		controller.tracker = hand
		controller.pose = "aim"
		controller.button_pressed.connect(_on_controller_button.bind(hand))
		controller.button_released.connect(_on_controller_release.bind(hand))
		origin.add_child(controller)
		if hand == "right_hand":
			right_controller = controller
		else:
			left_controller = controller
	controller_feedback = ControllerFeedback.new()
	controller_feedback.woken.connect(func(hand, reason): Log.record("controller_wake", {"hand": hand, "reason": reason}))
	origin.add_child(controller_feedback)
	var board := Board.new()
	calibration_board = board
	board.name = "CalibrationBoard"
	add_child(board)
	status_label = Label3D.new()
	status_label.position = Vector3(0, 2.45, -2)
	status_label.font_size = 22
	status_label.pixel_size = 0.003
	status_label.outline_size = 5
	add_child(status_label)
	display.status_changed.connect(_update_status)
	display.status_changed.connect(_on_input_session_changed)
	display.status_changed.connect(_queue_report)
	settings.load(settings_path)
	wrist_watch = WristWatch.new()
	wrist_watch.name = "WristWatch"
	add_child(wrist_watch)
	background_audio = BackgroundAudio.new()
	background_audio.load_settings(settings)
	background_audio.focused = false
	if Engine.has_singleton("QuestPlayer"): background_audio.importer.platform = Engine.get_singleton("QuestPlayer")
	background_audio.preferences_changed.connect(_on_background_preferences_changed)
	background_audio.changed.connect(_on_background_audio_changed)
	add_child(background_audio)
	Privacy.restore(settings)
	favorites = Favorites.new()
	Privacy.vault = favorites
	directory_browse_memory.load_file("user://directory_browse.cfg")
	favorites.lock_level = str(settings.get_value("privacy", "lock_level", "relaxed"))
	if Engine.has_singleton("QuestPlayer"): favorites.platform = Engine.get_singleton("QuestPlayer")
	favorites.changed.connect(_on_favorites_changed)
	favorites.locking.connect(func():
		if video: video._record_history(true))
	favorites.lock_changed.connect(_on_favorites_lock_changed)
	controller_bindings.restore(settings.get_value("input", "controller_bindings", {}))
	I18n.use(str(settings.get_value("ui", "language", "auto")))
	fps_overlay = FpsOverlay.new()
	fps_overlay.source = _fps_sample
	camera.add_child(fps_overlay)
	fps_overlay.set_shown(bool(settings.get_value("ui", "show_fps", false)))
	playback_status_overlay = PlaybackStatusOverlay.new()
	playback_status_overlay.source = _playback_status_sample
	camera.add_child(playback_status_overlay)
	capture_overlay = preload("res://scripts/capture_overlay.gd").new()
	capture_overlay.stop_requested.connect(func(): if video: video.captures.stop())
	camera.add_child(capture_overlay)
	disc_menu_bar = preload("res://scripts/disc_menu_bar.gd").new()
	disc_menu_bar.action_requested.connect(_on_disc_menu_bar)
	add_child(disc_menu_bar)
	seek_overlay = SeekOverlay.new()
	seek_overlay.source = _seek_overlay_sample
	camera.add_child(seek_overlay)
	# Eye-buffer render scale: the background and shader-drawn media. Compositor layers (menus,
	# layer video and photos) keep their own resolution.
	display_quality = Quality.load_quality(settings)
	if gpu_adapter.is_empty(): gpu_adapter = RenderingServer.get_video_adapter_name()
	low_end_gpu = Quality.is_low_end_gpu(gpu_adapter)
	display.render_scale = Quality.render_scale(display_quality, low_end_gpu)
	display.configure(get_viewport(), world.environment, XRServer.find_interface("OpenXR"), desktop)
	display.attach_backdrop(camera)
	input_visuals = InputVisuals.new()
	input_visuals.name = "InputVisuals"
	origin.add_child(input_visuals)
	# Long-press of the controller's Meta button recenters the runtime's space; bring the screen
	# and menus in front of the new view, exactly as the in-app Recenter does.
	var openxr := XRServer.find_interface("OpenXR")
	if not desktop and openxr and openxr.has_signal("pose_recentered"):
		openxr.connect("pose_recentered", _on_system_recentered)
	_head_placed = desktop
	# Everyday playback uses the validated default model, including migrated settings.
	if str(settings.get_value("alpha", "model", "fast")) != "fast":
		settings.set_value("alpha", "model", "fast")
		settings.save(settings_path)
	# The video node warms the RVM model when it enters the tree: select the model first.
	if Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").set_rvm_model("fast")
	video = _create_video_display()
	video.name = "VideoDisplay"
	video.preferred_depth_strength = video.DepthStrength.load_preference(settings, false)
	video.depth_strength = video.preferred_depth_strength
	video.changed.connect(_on_video_changed)
	video.playback_completed.connect(_on_video_completed)
	playback_mode = str(settings.get_value("video", "playback_mode", "single"))
	if playback_mode not in PLAYBACK_MODES: playback_mode = "single"
	video.loop_enabled = playback_mode == "repeat_one"
	video_queue_pages.platform = video.platform
	video_queue_pages.completed.connect(_on_video_queue_page)
	video_queue_pages.failed.connect(_on_video_queue_failed)
	video.playback_failed.connect(_on_video_playback_failed)
	video.seek_presented.connect(_on_stick_seek_presented)
	video.audio_options_changed.connect(_on_audio_options_changed)
	_restore_audio_preferences()
	video.mode_lock_changed.connect(_on_mode_lock_changed.bind("video"))
	video.thumbnail_ready.connect(_on_video_thumbnail_ready)
	video.prefer_clone_voice = bool(settings.get_value("audio", "prefer_clone_voice", false))
	video.narration.load_settings(settings)
	video.pip.load_settings(settings)
	video.pip.compositor.density = 20.0 if low_end_gpu else 26.0
	video.pip.image_requested.connect(_begin_pip_image)
	video.pip.zoom_changed.connect(_on_pip_zoom_changed)
	video.pip.window_opened.connect(func(window):
		if menu_composition: menu_composition.register_companion(window))
	video.pip.changed.connect(func():
		stick_controls.suspend()
		if video_menu and video_menu.visible: video_menu.refresh())
	video.narration.voice_choice_changed.connect(func(): video.narration.save(settings); settings.save(settings_path))
	video.history_enabled = Privacy.mode != Privacy.NONE
	_restore_seek_settings()
	# The chosen Alpha model size, warmed now so Alpha starts without the first-use compile.
	video.select_profile(_alpha_profile())
	video.load_mode_lock(settings.get_value("video", "mode_lock", {}))
	_restore_subtitle_settings()
	video.color_grade.restore(settings.get_value("video", "color_grade", {}))
	_restore_flat_video_settings()
	video.screen_curve = clampf(float(settings.get_value("screen", "curve", 0.0)), 0.0, 1.0)
	add_child(video)
	_update_thumbnail_protection()
	video.sharpness = Quality.load_sharpness(settings, low_end_gpu)
	video.view_camera = camera
	photo = PhotoDisplay.new()
	photo.name = "PhotoDisplay"
	photo.depth_strength = photo.DepthStrength.load_preference(settings, true)
	photo.auto_depth = bool(settings.get_value("effects", "auto_3d", true))
	photo.load_mode_lock(settings.get_value("photo", "mode_lock", {}))
	photo.catalog = video.recent_files
	photo.history_enabled = video.history_enabled
	photo.changed.connect(_on_photo_changed)
	photo.mode_lock_changed.connect(_on_mode_lock_changed.bind("photo"))
	photo.restore_view_settings(settings)
	add_child(photo)
	photo.sharpness = Quality.load_sharpness(settings, low_end_gpu)
	photo.view_camera = camera
	photo.video_layer = video.video_layer # one compositor layer provider for both players
	if video.video_layer: video.video_layer.supersampling = Quality.load_supersampling(settings)
	display.set_foveation(int(settings.get_value("video", "foveation", 0)))
	recent_menu = PuzzleLibraryMenu.new()
	recent_menu.browse_memory = directory_browse_memory
	recent_menu.restore_directory_position = bool(settings.get_value("library", "restore_position", true))
	recent_menu.controls_page.bindings = controller_bindings
	recent_menu.catalog = video.recent_files
	recent_menu.collections.store = favorites
	recent_menu.file_actions.load(settings.get_value("library", "orders", {}))
	recent_menu.load_view_mode(settings.get_value("library", "view_mode", "grid"))
	recent_menu.file_actions.set_enabled(bool(settings.get_value("library", "file_editing", false)))
	recent_menu.file_renamed.connect(_on_file_renamed)
	recent_menu.current_file_provider = func(): return _viewer().local_uri
	recent_menu.file_delete_preparing.connect(_prepare_file_delete)
	recent_menu.file_deleted.connect(_forget_deleted_file)
	recent_menu.settings_provider = _library_settings
	recent_menu.chosen.connect(_on_library_chosen)
	recent_menu.cast_requested.connect(cast_session.command)
	recent_menu.archives.opening.connect(func():
		if photo and photo.archive_mode: photo.close_image())
	recent_menu.archives.closing.connect(func():
		if photo and photo.archive_mode: photo.close_image())
	recent_menu.directory_order_changed.connect(_on_directory_order_changed)
	recent_menu.audio_import_selected.connect(_on_audio_import_selected)
	recent_menu.audio_import_cancelled.connect(_on_audio_import_cancelled)
	recent_menu.image_selected.connect(_on_pip_image_selected)
	recent_menu.image_picker_cancelled.connect(_on_pip_image_cancelled)
	recent_menu.subtitle_selected.connect(_on_subtitle_selected)
	recent_menu.subtitle_picker_cancelled.connect(_on_subtitle_picker_cancelled)
	recent_menu.background_audio_provider = background_audio.snapshot
	recent_menu.music_requested.connect(func(): _show_music_management(false))
	recent_menu.online_panoramas_requested.connect(_show_online_panoramas)
	recent_menu.puzzle_requested.connect(func(): if puzzle_game: puzzle_game.open_hub())
	recent_menu.puzzle_progress_provider=func(): return puzzle_game!=null and puzzle_game.has_progress()
	recent_menu.puzzle_mode_provider=func(): return puzzle_game!=null and puzzle_game.is_mode_enabled()
	recent_menu.music_toggle_requested.connect(background_audio.toggle_pause)
	recent_menu.audio_preview_requested.connect(background_audio.preview_audio)
	recent_menu.audio_preview_stopped.connect(background_audio.stop_preview)
	recent_menu.audio_preview_scrubbed.connect(background_audio.scrub_preview)
	recent_menu.storage_eject_requested.connect(_on_storage_eject_requested)
	recent_menu.storage_removed.connect(_release_storage_readers)
	recent_menu.layout_requested.connect(_toggle_library_layout)
	recent_menu.setting_changed.connect(_on_setting_changed)
	recent_menu.setting_previewed.connect(_on_playback_adjustment)
	_connect_session_controls(recent_menu)
	add_child(recent_menu)
	if Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		recent_menu.attach_platform(plugin)
		plugin.connect("mpv_debug_command", _on_display_debug_command)
		plugin.set_mpv_output_width(Quality.output_width(Quality.load_output_choice(settings), low_end_gpu))
		if PlatformMethods.supports(plugin, "set_mpv_alpha_fps"):
			plugin.set_mpv_alpha_fps(_alpha_fps())
		video.set_alpha_edge(_alpha_edge_value("alpha_feather"), _alpha_edge_value("alpha_shrink"))
	player_menu = PlayerMenu.new()
	player_menu.state_provider = _menu_state
	player_menu.favorite_provider = _favorite_state
	player_menu.favorite_requested.connect(_toggle_favorite)
	player_menu.action_requested.connect(_on_menu_action)
	player_menu.cast_requested.connect(cast_session.command)
	player_menu.recent_requested.connect(_show_recent_menu)
	player_menu.seek_requested.connect(_on_menu_seek)
	player_menu.bookmark_requested.connect(_on_bookmark_request)
	player_menu.bookmark_loop_requested.connect(_on_bookmark_loop_request)
	player_menu.bookmark_mode_requested.connect(_on_bookmark_mode_requested)
	player_menu.setting_requested.connect(_on_player_setting)
	player_menu.volume_requested.connect(_on_menu_volume)
	player_menu.whisper_requested.connect(_on_menu_whisper)
	player_menu.whisper_haptic.connect(_on_whisper_haptic)
	player_menu.adjustment_requested.connect(_on_playback_adjustment)
	player_menu.adjustment_committed.connect(_save_playback_adjustments)
	player_menu.subtitle_requested.connect(video.set_subtitle_track)
	player_menu.subtitle_files_requested.connect(video.request_subtitle_files)
	player_menu.subtitle_file_requested.connect(video.select_subtitle_file)
	player_menu.subtitle_browse_requested.connect(_begin_subtitle_browse)
	player_menu.depth_strength_requested.connect(_on_depth_strength.bind(false))
	player_menu.depth_strength_committed.connect(_save_depth_strength.bind(false))
	_connect_session_controls(player_menu)
	add_child(player_menu)
	video.captures.saved.connect(_on_capture_saved)
	video_menu = player_menu
	photo_menu = PhotoMenu.new()
	photo_menu.state_provider = _photo_menu_state
	photo_menu.favorite_provider = _favorite_state
	photo_menu.favorite_requested.connect(_toggle_favorite)
	photo_menu.queue_provider = func(): return photo.queue
	photo_menu.action_requested.connect(_on_photo_action)
	photo_menu.online.platform = platform_plugin
	photo_menu.online_image_requested.connect(_open_online_panorama)
	photo_menu.adjustment_requested.connect(_on_photo_adjustment)
	photo_menu.adjustment_committed.connect(_save_photo_adjustments)
	photo_menu.depth_strength_requested.connect(_on_depth_strength.bind(true))
	photo_menu.depth_strength_committed.connect(_save_depth_strength.bind(true))
	photo_menu.recent_requested.connect(_show_recent_menu)
	_connect_session_controls(photo_menu)
	add_child(photo_menu)
	music_menu = MusicMenu.new(); music_menu.audio = background_audio
	music_menu.close_requested.connect(_close_music_menu)
	music_menu.import_requested.connect(_begin_audio_import)
	_connect_session_controls(music_menu); add_child(music_menu)
	video_menu.expanded_library = recent_menu
	photo_menu.expanded_library = recent_menu
	menu_composition = MenuComposition.new()
	add_child(menu_composition)
	if OS.is_debug_build(): # capture-density experiments; applies at launch
		menu_composition.debug_pixel_scale = float(settings.get_value("debug", "menu_layer_scale", 0.0))
		menu_composition.debug_bands = bool(settings.get_value("debug", "menu_layer_bands", false))
	menu_composition.configure(origin, camera, display, [recent_menu, video_menu, photo_menu, music_menu], low_end_gpu)
	menu_composition.register_companion(disc_menu_bar)
	background = Background.new()
	background.choice = CinemaFeature.normalize_background(str(settings.get_value("appearance", "background", "belfast")))
	background.custom_path = str(settings.get_value("appearance", "custom_path", ""))
	background.custom_title = str(settings.get_value("appearance", "custom_title", ""))
	background.custom_orientation = int(settings.get_value("appearance", "custom_orientation", 1))
	background.yaw = fposmod(float(settings.get_value("appearance", "background_yaw", 0.0)), 360.0)
	background.brightness = clampf(float(settings.get_value("appearance", "background_brightness", 1.0)), 0.5, 1.25)
	background.changed.connect(_on_background_changed)
	background.custom_saved.connect(_on_custom_background_saved)
	if CinemaFeature.enabled():
		cinema_environment = CinemaEnvironment.new()
		add_child(cinema_environment)
		cinema_environment.configure(xr_origin, xr_camera)
		cinema_environment.changed.connect(_on_cinema_environment_changed)
	add_child(background)
	if Engine.has_singleton("QuestPlayer"):
		platform_plugin = Engine.get_singleton("QuestPlayer")
		_sync_native_privacy()
		if PlatformMethods.supports(platform_plugin, "set_ui_language"):
			platform_plugin.set_ui_language(I18n.choice)
		platform_plugin.connect("capabilities_ready", _on_capabilities_ready)
		platform_plugin.connect("android_lifecycle", _on_android_lifecycle)
		platform_plugin.connect("rvm_benchmark_result", _on_rvm_result)
		for kind in ["state", "frame", "error"]:
			platform_plugin.connect("controlled_" + kind, _on_controlled_event.bind(kind))
		request_capabilities()
	else:
		Log.record("android_plugin_unavailable", {"desktop_preview": desktop})
	report_timer = Timer.new()
	report_timer.wait_time = REPORT_INTERVAL
	report_timer.timeout.connect(_on_report_timer)
	cast_session.bind(self, video.platform)
	add_child(report_timer)
	report_timer.start()
	_update_status()
	if not OS.get_cmdline_user_args().has("--mpv-diagnostic-2d"):
		puzzle_game = PuzzleHost.new(); puzzle_game.app = self; add_child(puzzle_game)
		_show_recent_menu()
	Log.record("ui_ready", {"library_visible": recent_menu.visible, "player_visible": player_menu.visible,
		"diagnostics_visible": status_label.visible, "calibration_visible": calibration_board.visible,
		"menu_selection": "controller_ray_trigger_or_hand_pinch"})
	Log.record("app_started", {"version": ProjectSettings.get_setting("application/config/version"), "os": OS.get_name()})
	# Source distribution: private capture automation is excluded.

## Desktop preview: dragging with the mouse moves the picture, the wheel zooms immersive views.
func _unhandled_input(event: InputEvent) -> void:
	if _cinema_desktop_input(event): return
	if puzzle_game and puzzle_game.active:
		puzzle_game.desktop(event); get_viewport().set_input_as_handled(); return
	if photo_active and photo.inspect:
		if event is InputEventMouseMotion:
			_inspect_desktop_ray = [photo.view_camera.project_ray_origin(event.position), photo.view_camera.project_ray_normal(event.position)]
			_update_photo_inspect()
		elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_close_photo_inspect()
		return
	if _active_menu() or not video or _viewer().local_uri.is_empty():
		return
	if photo_active and photo.gallery.mode != 0 and event is InputEventMouse:
		var origin: Vector3 = photo.view_camera.project_ray_origin(event.position)
		var direction: Vector3 = photo.view_camera.project_ray_normal(event.position)
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if photo.gallery.press_pointer("desktop", origin, direction): return
			elif photo.gallery.release_pointer("desktop", origin, direction): return
		elif event is InputEventMouseMotion:
			photo.gallery.update_pointer("desktop", origin, direction)
			if photo.gallery.has_capture(): return
		elif event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and photo.gallery.overview():
			photo.zoom_picture(0.08 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.08); return
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_turn_picture(-event.relative.x * MOUSE_TURN, -event.relative.y * MOUSE_TURN)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var forward := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if photo_active:
			_toggle_photo_inspect()
			if display.preview:
				_inspect_desktop_ray = [photo.view_camera.project_ray_origin(event.position), photo.view_camera.project_ray_normal(event.position)]
			_update_photo_inspect()
		elif _viewer().geometry != Geometry.Geometry.FLAT:
			_viewer().zoom_view(0.05 * forward)
		else:
			_push_screen(0.1 * forward)
			_save_screen()

func _unhandled_key_input(event: InputEvent) -> void:
	if _cinema_interaction_owns() and not _active_menu() and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_cinema_return_to_playback(); get_viewport().set_input_as_handled(); return
		if event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_LEFT, KEY_RIGHT]:
			get_viewport().set_input_as_handled(); return
	if puzzle_game and puzzle_game.active:
		puzzle_game.desktop(event); get_viewport().set_input_as_handled(); return
	if event is InputEventKey and event.pressed and not event.echo:
		if photo_active and photo.inspect and event.keycode in [KEY_ESCAPE, KEY_SPACE]:
			_close_photo_inspect()
			return
		if event.keycode == KEY_TAB:
			_toggle_player_menu()
			return
		var menu := _active_menu()
		if menu:
			if OS.get_name() == "Android":
				return
			if event.keycode == KEY_ESCAPE:
				if menu == music_menu: _navigate_back()
				else: menu.dismiss()
			elif menu == recent_menu:
				match event.keycode:
					KEY_UP: recent_menu.move_focus(-1)
					KEY_DOWN: recent_menu.move_focus(1)
					KEY_ENTER: recent_menu.activate_desktop()
			return
		if photo_active:
			match event.keycode:
				KEY_LEFT: if not photo.inspect: photo.navigate(-1)
				KEY_RIGHT: if not photo.inspect: photo.navigate(1)
				KEY_SPACE: _toggle_photo_inspect()
				KEY_R: _reset_picture()
				KEY_P: photo.cycle_projection()
				KEY_S: photo.toggle_stereo()
				KEY_E: photo.toggle_eye_order()
				KEY_O: _show_recent_menu()
			return
		match event.keycode:
			KEY_T:
				_toggle_display()
			KEY_R:
				_recenter()
			KEY_D:
				request_capabilities()
			KEY_O:
				_show_recent_menu()
			KEY_SPACE:
				video.toggle_play()
			KEY_S:
				video.toggle_stereo()
			KEY_P:
				video.cycle_projection()
			KEY_LEFT:
				video.seek_relative(-10000)
			KEY_RIGHT:
				video.seek_relative(10000)
			KEY_L:
				_cycle_playback_mode()
			KEY_M:
				video.toggle_mute()
			KEY_U:
				video.change_volume(10.0)
			KEY_J:
				video.change_volume(-10.0)
			KEY_H:
				video.cycle_audio_track()
			KEY_C:
				video.cycle_subtitle_track()
			KEY_E:
				video.toggle_eye_order()
			KEY_V:
				video.play_calibration_clip()
			KEY_F8:
				_request_rvm_benchmark(false)
			KEY_F9:
				_request_rvm_benchmark(true)
			KEY_F6:
				_request_rvm_benchmark(next_rvm_case % 2 == 1, RVM_PROFILES[next_rvm_case >> 1])
			KEY_F7:
				_request_controlled_probe()

# Menus are ray + trigger only. A list row clicks on release unless the ray dragged to scroll.
# Video triggers select controls or resize flat corners; grips move pictures. Photo/hand dragging is separate.
func _on_controller_release(action: String, hand: String = "") -> void:
	if action == "ax_button" and _cinema_move_hands.has(hand):
		controller_bindings.release(hand, action)
		_cinema_pointer_release(hand); return
	if puzzle_game and puzzle_game.active:
		puzzle_game.button(action, hand, true); return
	controller_bindings.release(hand, action)
	var consumed_key := hand + "/" + action
	var consumed: bool = _controller_consumed.has(consumed_key)
	_controller_consumed.erase(consumed_key)
	if video and video.get("pip") and video.pip.release(hand, action): stick_controls.suspend(); return
	if not interface_move.capture.is_empty() and interface_move.capture.hand == hand and interface_move.capture.input == action:
		_finish_interface_move(); return
	if not _grab.is_empty() and _grab.get("release_input", "trigger_click") == action and _grab.hand == hand:
		_on_pointer_release("trigger_click", hand); return
	if consumed: return
	if not _controller_allowed(hand): return
	_on_pointer_release(action, hand)

func _finish_interface_move() -> void:
	if interface_move.capture.is_empty(): return
	if interface_move.capture.moved:
		_menu_touched_ms = Time.get_ticks_msec()
		var head: Variant = _head_pose()
		for target in interface_move.capture.targets:
			if not is_instance_valid(target.node): continue
			if head != null and target.kind in ["menu", "screen", "detail"]:
				var world: Transform3D = target.node.global_transform * target.node.flat_pose if target.kind == "screen" else target.node.global_transform
				var frame: Transform3D = InterfaceMove.menu_head(head, view_follow.enabled) if target.kind == "menu" else head
				interface_move.placements[target.key] = frame.affine_inverse() * world
				if target.kind != "detail": view_follow.capture(target.key, head, world)
				elif photo: photo.detail_placement = interface_move.placements[target.key]
			if target.kind == "gallery": target.node.remember_layout_pose()
			if target.kind == "menu" and target.node == recent_menu and not is_zero_approx(float(interface_move.capture.get("depth", 0.0))):
				_remember_library_distance(head)
			if target.kind == "screen":
				target.node.set_screen_distance(_surface_distance(target.node))
				if photo_active and photo.gallery.focus >= 0: photo.gallery.remember_focus_pose(photo.global_transform * photo.flat_pose)
		if video and not _viewer().local_uri.is_empty() and interface_move.capture.targets.any(func(target): return target.kind in ["screen", "immersive", "gallery"]): _save_screen()
	interface_move.cancel(); stick_controls.suspend()

func _on_pointer_release(action: String, hand: String) -> void:
	if video and video.get("pip") and video.pip.release(hand, action): stick_controls.suspend(); return
	if action == "trigger_click" and _inspect_blocked.has(hand):
		_inspect_blocked.erase(hand)
		return
	if action == "trigger_click" and _ray(hand) == null:
		_cancel_pointer(hand)
		return
	if action == "trigger_click" and not _video_control_tap.is_empty() and _video_control_tap.get("hand", "") == hand:
		var tap := _video_control_tap
		_video_control_tap = {}
		if photo_active == tap.get("photo", false) and _viewer() and _viewer().local_uri == tap.uri:
			if tap.has("dismiss"):
				if _active_menu() == tap.dismiss:
					if tap.dismiss == music_menu: _close_music_menu()
					else: tap.dismiss.dismiss()
			elif _has_open_media() and not _active_menu(): _show_player_menu()
		return
	if action == "trigger_click" and photo_active and photo.gallery.capture.get("hand", "") == hand:
		var ray: Variant = _ray(hand)
		photo.gallery.release_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null)
		stick_controls.suspend()
		return
	if action == "trigger_click" and not _grab.is_empty() and _grab.hand == hand:
		var grab := _grab
		_grab = {}
		_viewer().set_corner_hover(-1)
		if grab.moved and not grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT:
			_save_screen()
		if grab.get("resize_only", false):
			stick_controls.suspend(); return
		if not grab.moved:
			if player_menu.visible:
				player_menu.dismiss()
			elif not grab.get("hid_menu", false):
				_show_player_menu()
		return
	var menu := _active_menu()
	if action != "trigger_click" or not menu or not menu.has_method("release_pointer"):
		return
	var ray: Variant = _ray(hand)
	menu.release_pointer(hand, ray[0] if ray != null else Vector3.ZERO,
		ray[1] if ray != null else Vector3.ZERO, ray != null)

func _on_controller_button(action: String, hand: String = "") -> void:
	if hand not in ControllerBindings.HANDS or not _controller_allowed(hand): return
	if _watch_owned and hand == "right_hand" and action != "menu_button":
		_controller_consumed[hand + "/" + action] = true; return
	if puzzle_game and puzzle_game.active:
		puzzle_game.button(action, hand); return
	if action == "menu_button":
		if controller_feedback: controller_feedback.wake(hand)
		interface_move.cancel()
		_on_pointer_button(action, hand); return
	# Capacitive touches are boolean OpenXR events too; only actual clicks wake.
	if action not in ControllerBindings.BUTTONS: return
	if controller_bindings.blocked[hand].has(action): return
	var first_press := controller_bindings.press(hand, action)
	if action == "ax_button" and hand == "right_hand" and _cinema_interaction_owns():
		if first_press and not _cinema_input_blocked(): _cinema_pointer_press(hand)
		return
	if action == "trigger_click" and first_press and _cinema_interaction_owns() and not _cinema_input_blocked():
		cinema_environment.suspend(); _show_player_menu()
		_controller_consumed[hand + "/" + action] = true; return
	if first_press and action == "by_button" and hand == "right_hand" and video and not video.captures.recording.is_empty():
		video.captures.stop()
		_controller_consumed[hand + "/" + action] = true
		return
	if action == "by_button" and first_press and _cinema_interaction_owns() and not _active_menu():
		_cinema_return_to_playback()
		_controller_consumed[hand + "/" + action] = true
		return
	if first_press and controller_feedback and _input_feedback_visible(): controller_feedback.wake(hand)
	if action in ControllerBindings.MODIFIERS and not first_press: return
	if action == "by_button" and not first_press: return
	var consumed_key := hand + "/" + action
	# B on a disc menu goes back to the disc's top menu unless an app panel is open.
	if action == "by_button" and first_press and video and not photo_active and video.disc.menu_session and not _active_menu() \
		and video.disc_menu.top_menu(video.platform):
		_controller_consumed[consumed_key] = true; return
	# The trigger is also a chord modifier; a disc menu button under the ray takes it first.
	if action == "trigger_click" and first_press and (_disc_menu_bar_press(hand) or _disc_menu_press(hand)): return
	if not photo_active and video and video.get("pip") and video.pip.capturing():
		_pip_pointer_press(action, hand)
		_controller_consumed[consumed_key] = true; return
	# Either modifier order can take over this hand's picture movement, even after
	# natural motion committed it. Real UI/other-hand captures keep their ownership.
	if action in ControllerBindings.MODIFIERS and controller_bindings.is_modifier(hand, action, _controller_context()) \
		and ControllerBindings.MODIFIERS.all(func(mod): return controller_bindings.down[hand].has(mod)):
		if _video_control_tap.get("hand", "") == hand: _video_control_tap.clear()
		if (interface_move.capture.is_empty() or interface_move.capture.hand == hand) \
			and _shortcut_allowed("follow_photo" if photo_active else "follow_video", true, hand):
			_finish_interface_move()
			if not _grab.is_empty():
				if _grab.moved and not _grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT: _save_screen()
				_grab.clear(); _viewer().set_corner_hover(-1)
			stick_controls.suspend()
		_controller_consumed[consumed_key] = true; return
	if not interface_move.capture.is_empty() and interface_move.capture.moved:
		_controller_consumed[consumed_key] = true; return
	var id := controller_bindings.resolve(hand, action, _controller_context())
	if id in ["turn_180_video", "turn_180_photo", "previous_video", "next_video"] and not first_press: return
	if photo_active and photo.inspect and not (id in ["photo_close", "move_photo"] and _shortcut_allowed(id)):
		_on_pointer_button(action, hand); return
	var menu := _active_menu()
	# A real UI hit/capture keeps trigger selection, regardless of user shortcut mappings.
	if action == "trigger_click" and menu:
		var ray: Variant = _ray(hand)
		var chord_modifier: bool = controller_bindings.down[hand].has("grip_click") and controller_bindings.is_modifier(hand, action, _controller_context()) and _shortcut_allowed("play")
		if _menu_captured(menu) or (not chord_modifier and ray != null and not menu.ray_hit(ray[0], ray[1]).is_empty()):
			interface_move.cancel()
			if photo_active: _on_pointer_button(action, hand)
			else: _on_video_trigger(hand)
			return
		if photo_active and menu != player_menu and ray != null and menu.grab_hit(ray[0], ray[1]).is_empty() \
			and controller_bindings.is_modifier(hand, "grip_click", _controller_context()):
			_video_control_tap = {"hand": hand, "uri": photo.local_uri, "dismiss": menu, "photo": true}
			return
	if _pip_pointer_press(action, hand):
		_controller_consumed[consumed_key] = true; return
	if interface_move.pending() and not id.begins_with("move_") and not _is_chord(id, hand, action):
		_controller_consumed[consumed_key] = true; return
	if action == "trigger_click" and _try_corner_resize(hand): return
	if id.begins_with("move_") and _shortcut_allowed(id):
		_begin_interface_move(hand, action); _controller_consumed[consumed_key] = true; return
	if controller_bindings.is_modifier(hand, action, _controller_context()):
		_controller_consumed[consumed_key] = true; return
	if not photo_active and action == "trigger_click":
		_on_video_trigger(hand)
		return
	if not id.is_empty() and _shortcut_allowed(id, _is_chord(id, hand, action)):
		if interface_move.pending(): interface_move.cancel()
		if id.begins_with("drag_"):
			_on_pointer_button("trigger_click", hand)
			if not _grab.is_empty(): _grab["release_input"] = action
		else:
			_controller_consumed[consumed_key] = true
			_execute_shortcut(id, hand, 1.0, 0.18)
		return
	if action == "by_button":
		_controller_consumed[consumed_key] = true
		# Full or partial chords must not fall through to ordinary Back.
		if controller_bindings.modifier_held(hand, _controller_context()): return
		_on_pointer_button(action, hand)
		return
	if menu and action == "trigger_click": _on_pointer_button(action, hand)
	else: _controller_consumed[consumed_key] = true

## A fixed controller UI action, independent of saved playback bindings and picture grabs.
var _video_control_tap := {}
func _on_video_trigger(hand: String) -> void:
	if _capture_pointer_press(hand): return
	if _disc_menu_press(hand): return
	if not _video_control_tap.is_empty() or not _grab.is_empty():
		_controller_consumed[hand + "/trigger_click"] = true
		return
	var ray: Variant = _ray(hand)
	if ray == null: return
	var menu := _active_menu()
	if menu:
		var captured := _menu_captured(menu)
		if _update_menu_pointer(hand, true) or captured: return
		# This press only dismisses the controls; it never becomes a picture drag.
		if menu.ray_hit(ray[0], ray[1]).is_empty() and (menu == player_menu or menu.grab_hit(ray[0], ray[1]).is_empty()):
			if controller_bindings.is_modifier(hand, "grip_click", _controller_context()):
				_video_control_tap = {"hand": hand, "uri": video.local_uri, "dismiss": menu}
				return
			if menu == music_menu: _close_music_menu()
			else: menu.dismiss()
			_controller_consumed[hand + "/trigger_click"] = true
		return
	if not _has_open_media():
		_show_recent_menu()
		_controller_consumed[hand + "/trigger_click"] = true
	else:
		_video_control_tap = {"hand": hand, "uri": video.local_uri}

func _binding_page() -> bool:
	return recent_menu is LibraryMenu and recent_menu.controls_page.active()

func _controller_context() -> String:
	if photo_active: return "photo"
	return "video_immersive" if video and video.geometry != Geometry.Geometry.FLAT else "video_flat"

func _menu_captured(menu: Node3D) -> bool:
	if menu == null: return false
	if menu.has_method("has_pointer_capture"): return menu.has_pointer_capture()
	if menu is LibraryMenu: return not menu._drag.is_empty() or not menu.choices.capture.is_empty() or not menu.account_panel.web_hand.is_empty()
	return false

func _shortcut_allowed(id: String, chord: bool = false, chord_hand: String = "") -> bool:
	if not photo_active and video and video.get("pip") and video.pip.blocked(): return false
	if wrist_watch and (not wrist_watch.logic.scrub.is_empty() or not wrist_watch.logic.pressed.is_empty()): return false
	if _cinema_interaction_owns() and not _active_menu(): return false
	if not _input_focused() or not _inspect_blocked.is_empty(): return false
	if photo_active and ((photo.inspect and id not in ["photo_close", "move_photo"]) or photo.gallery.has_capture() or not photo_hands.owners.is_empty()): return false
	var menu := _active_menu()
	if _menu_captured(menu): return false
	if not _grab.is_empty() and (not chord or _grab.hand != chord_hand or _grab.has("inspect")): return false
	if id == "photo_close": return photo_active and photo.gallery.mode in [2, 3] and photo.gallery.focus >= 0 and not photo.gallery.returning and (menu == null or menu == photo_menu)
	if id.begins_with("move_"): return not (_binding_page() and (not recent_menu.choices.opened.is_empty() or not recent_menu.controls_page.pending.is_empty()))
	if menu:
		var still_seek := id in ["back10", "forward10", "back20", "forward20"] and _stills_playback_priority(menu)
		if not still_seek and (menu != player_menu or photo_active or not player_menu.allows_playback_sticks()): return false
		if id.begins_with("drag_"): return false
		if not chord and id in ["library_video", "library_photo", "reset_video", "reset_photo", "projection_video", "projection_photo", "inspect"]: return false
	if id == "play": return video != null and not video.local_uri.is_empty() and video.media.accepts(video.media.session_id)
	if id in ["turn_180_video", "turn_180_photo"]:
		return _has_open_media() and _viewer().geometry == Geometry.Geometry.EQUIRECT_360
	if id in ["previous_video", "next_video"]:
		return _has_open_media() and not _adjacent_video(-1 if id == "previous_video" else 1).is_empty()
	return true

func _execute_shortcut(id: String, hand: String = "right_hand", amount: float = 1.0, delta: float = 1.0 / 72.0) -> void:
	match id:
		"play": video.toggle_play()
		"library_video", "library_photo": _show_recent_menu()
		"reset_video", "reset_photo": _reset_picture()
		"projection_video", "projection_photo": _viewer().cycle_projection()
		"inspect": _toggle_photo_inspect(hand)
		"back20", "forward20", "back10", "forward10":
			var seconds := 20 if id.ends_with("20") else 10
			video.seek_relative(seconds * 1000 * (-1 if id.begins_with("back") else 1))
		"volume_up", "flat_volume_up": video.change_volume(10)
		"volume_down", "flat_volume_down": video.change_volume(-10)
		"zoom_in", "zoom_out", "flat_zoom_in", "flat_zoom_out":
			_zoom_video((1 if id.ends_with("_in") else -1) * absf(amount) * ZOOM_SPEED * delta, hand)
		"photo_next", "photo_previous": photo.navigate(1 if id == "photo_next" else -1)
		"previous_video", "next_video":
			if _has_open_media(): _navigate_video(-1 if id == "previous_video" else 1)
		"turn_180_video", "turn_180_photo":
			if _has_open_media() and _viewer().geometry == Geometry.Geometry.EQUIRECT_360: _viewer().turn_view(PI, 0.0)
		"photo_close":
			if photo.inspect: _close_photo_inspect(false)
			if photo.portrait_requested: photo.set_portrait(false)
			photo.gallery.return_focus(); stick_controls.suspend()
		"photo_zoom_in", "photo_zoom_out":
			if photo.geometry != Geometry.Geometry.FLAT and not photo.gallery.overview(): _toggle_photo_inspect(hand)
			else: photo.zoom_picture((1 if id == "photo_zoom_in" else -1) * absf(amount) * ZOOM_SPEED * delta)
		"subtitles":
			_show_player_menu(); player_menu._activate(110)
		"passthrough_video", "passthrough_photo": _on_session_control("temporary_passthrough")
		"follow_video", "follow_photo": _on_session_control("follow")
		"grade_next", "grade_previous":
			var presets: Array = video.color_grade.PRESETS
			var index: int = presets.find(video.color_grade.preset)
			_on_playback_adjustment("grade_preset", presets[posmod(index + (1 if id == "grade_next" else -1), presets.size())]); _save_playback_adjustments()
		"temperature_up", "temperature_down":
			_on_playback_adjustment("temperature", video.color_grade.values().temperature + (100 if id == "temperature_down" else -100)); _save_playback_adjustments()
		"mute": video.toggle_mute()
		"audio_next": video.cycle_audio_track(1)
		"subtitle_next": video.cycle_subtitle_track(1)
		"eyes": video.toggle_eye_order()
		"alpha": _on_menu_action("alpha")
	if player_menu and player_menu.visible and not photo_active:
		_menu_touched_ms = Time.get_ticks_msec(); player_menu.refresh_values()

func _axis_binding(hand: String, input: String) -> Dictionary:
	var id := ""
	if _debug_sticks.has(hand):
		# A probed stick is a bare deflection: buttons the hand tracker reports (a resting
		# headset sees phantom pinches) must not turn it into a chord such as next video.
		var held: Dictionary = controller_bindings.down[hand]
		controller_bindings.down[hand] = {}
		id = controller_bindings.resolve(hand, input, _controller_context())
		controller_bindings.down[hand] = held
	else: id = controller_bindings.resolve(hand, input, _controller_context())
	if id.is_empty(): return {}
	if interface_move.pending() and not _is_chord(id, hand, input): return {}
	return {"operation": "shortcut", "id": id, "hand": hand, "input": input, "continuous": controller_bindings.definition(id).continuous}

func _is_chord(id: String, hand: String, input: String) -> bool:
	return controller_bindings.bindings(id).any(func(binding): return binding.hand == hand and binding.input == input and not binding.modifiers.is_empty() and binding.modifiers.all(func(mod): return controller_bindings.down[hand].has(mod)))

func _move_pose(hand: String) -> Variant:
	var controller: XRController3D = left_controller if hand == "left_hand" else right_controller
	return controller.global_transform if controller and controller.get_is_active() and controller.get_has_tracking_data() and _controller_allowed(hand) else null

func _begin_interface_move(hand: String, input: String) -> void:
	var pose: Variant = _move_pose(hand)
	var head: Variant = _head_pose()
	if pose == null or head == null: return
	_video_control_tap = {} # Starting a grip cannot leave a deferred trigger tap behind.
	if photo_active and photo.inspect:
		var detail: MeshInstance3D = photo._detail
		if detail and detail.visible and interface_move.begin(hand, input, pose, [{"node": detail, "kind": "detail", "pose": detail.global_transform, "key": "magnifier"}], detail.global_position, head):
			stick_controls.suspend()
		return
	var targets: Array = []
	var menu := _active_menu()
	if _cinema_scene_active() and menu == video_menu: return
	var ray: Variant = _ray(hand)
	var hit: Dictionary = menu.grab_hit(ray[0], ray[1]) if menu and ray != null else {}
	var surface := _viewer()
	var media_anchor: Variant = _media_move_anchor(surface, ray)
	if _cinema_scene_active() and not photo_active: media_anchor = null
	# Movement range changes the linked targets, never turns a miss into a grab.
	if hit.is_empty() and media_anchor == null: return
	var scope: String = controller_bindings.move_scope
	var move_media := scope != "panel" or menu == null
	if menu and (scope != "panel" or not hit.is_empty()):
		targets.append({"node": menu, "kind": "menu", "pose": menu.global_transform, "key": _menu_key(menu)})
	else: move_media = true
	if _cinema_scene_active() and not photo_active: move_media = false
	if scope == "all":
		for other in [recent_menu, video_menu, photo_menu, music_menu]:
			if other == recent_menu and _library_is_attached(): continue
			if _cinema_scene_active() and other == video_menu: continue
			if other and other != menu:
				if not other.visible: _place_menu(other)
				targets.append({"node": other, "kind": "menu", "pose": other.global_transform, "key": _menu_key(other)})
	if move_media and surface and not surface.local_uri.is_empty():
		if photo_active and photo.gallery.overview():
			targets.append({"node": photo.gallery, "kind": "gallery", "pose": photo.gallery.anchor, "key": "gallery"})
		else:
			targets.append({"node": surface, "kind": "screen" if surface.geometry == Geometry.Geometry.FLAT else "immersive", "pose": surface.global_transform * surface.flat_pose, "key": _surface_key(surface)})
	if targets.is_empty(): return
	targets = targets.filter(func(target): return target.kind != "menu" or not target.node.space_locked())
	if targets.is_empty(): return
	for target in targets:
		if target.kind == "screen":
			target["distance_limits"] = photo.PHOTO_DISTANCE_LIMITS if photo_active else video.DISTANCE_LIMITS
			target["cinema"] = target.node == video and video.cinema.active(video)
		elif target.kind == "gallery": target["distance_limits"] = photo.gallery.DISTANCE_LIMITS
	var anchor: Vector3 = menu.to_global(hit.point) if not hit.is_empty() else media_anchor
	if interface_move.begin(hand, input, pose, targets, anchor, head, view_follow.enabled): stick_controls.suspend()

func _media_move_anchor(surface: Node3D, ray: Variant) -> Variant:
	if surface == null or surface.local_uri.is_empty() or ray == null: return null
	if not ray[0].is_finite() or not ray[1].is_finite() or ray[1].length_squared() < 0.00001: return null
	if photo_active and photo.gallery.overview():
		var hit: Dictionary = photo.gallery.ray_hit(ray[0], ray[1])
		return hit.get("point")
	if not surface.panel.visible: return null
	if surface.geometry == Geometry.Geometry.FLAT:
		return surface.screen_hit(ray[0], ray[1])
	# A 360 picture fills every direction; VR180 still has an empty rear half.
	var origin: Vector3 = surface.panel.to_local(ray[0])
	var direction: Vector3 = (surface.panel.global_basis.inverse() * ray[1]).normalized()
	var b := origin.dot(direction)
	var discriminant: float = b * b - origin.length_squared() + surface.SPHERE_RADIUS * surface.SPHERE_RADIUS
	if discriminant < 0 or direction.length_squared() < 0.5: return null
	var distance := -b + sqrt(discriminant)
	if distance <= 0: return null
	var point := origin + direction * distance
	if surface.geometry == Geometry.Geometry.HALF_EQUIRECT and point.z > 0: return null
	if surface.geometry == Geometry.Geometry.FISHEYE and acos(clampf(-point.normalized().z, -1, 1)) > deg_to_rad(surface.fisheye_fov) * 0.5: return null
	return surface.panel.to_global(point)

func _update_interface_move() -> void:
	if interface_move.capture.is_empty(): return
	var pose: Variant = _move_pose(interface_move.capture.hand)
	var head: Variant = _head_pose()
	if pose == null or head == null or not _input_focused(): interface_move.cancel(); stick_controls.suspend(); return
	if interface_move.update(pose, head, view_follow):
		stick_controls.suspend(); _menu_touched_ms = Time.get_ticks_msec()
		if photo_active and photo.inspect:
			photo.detail_placement = interface_move.placements.get("magnifier")
			photo._update_inspect()

func _on_pointer_button(action: String, hand: String) -> void:
	if action == "trigger_click" and _capture_pointer_press(hand): return
	if _pip_pointer_press(action, hand): return
	if action == "by_button" and hand == "right_hand" and video and video.captures.stop(): return
	if action == "trigger_click" and _cinema_interaction_owns() and not _cinema_input_blocked():
		cinema_environment.suspend(); _show_player_menu(); _controller_consumed[hand + "/" + action] = true; return
	if action == "by_button" and _cinema_interaction_owns() and not _active_menu():
		_cinema_request_interaction("watch"); return
	if puzzle_game and puzzle_game.active:
		puzzle_game.button(action, hand); return
	if not interface_move.capture.is_empty():
		if action == "menu_button": interface_move.cancel()
		elif interface_move.capture.moved: return
	if _inspect_blocked.has(hand): return
	if hand in ["left_hand", "right_hand"]: _photo_pointer_hand = hand
	if photo_active and photo.inspect:
		if action in ["trigger_click", "by_button", "menu_button"]:
			if action == "trigger_click": _inspect_blocked[hand] = true
			_close_photo_inspect()
		elif action == "ax_button":
			_close_photo_inspect(false)
			_show_recent_menu()
		return
	if action == "menu_button":
		_toggle_player_menu()
		return
	if action == "by_button":
		_navigate_back()
		return
	var menu := _active_menu()
	# ax_button is A on the right controller and X on the left. Only A controls video transport.
	if not photo_active and action == "ax_button" and hand == "right_hand":
		if not video or video.local_uri.is_empty() or not video.media.accepts(video.media.session_id): return
		if not _grab.is_empty() or (menu and (menu != player_menu or not player_menu.allows_playback_sticks())): return
		video.toggle_play()
		if menu:
			_menu_touched_ms = Time.get_ticks_msec()
			player_menu.refresh_values()
		return
	if menu:
		match action:
			"trigger_click":
				# Shared photo/hand pointer gestures may drag; physical video controllers
				# use _on_video_trigger instead and never enter this picture-grab path.
				if not _update_menu_pointer(hand, true):
					var ray: Variant = _ray(hand)
					# A slider owned by the other hand rejects this press; it is not a screen drag.
					if menu == player_menu:
						if ray != null and menu.ray_hit(ray[0], ray[1]).is_empty(): _begin_grab(hand)
					elif ray != null and menu.grab_hit(ray[0], ray[1]).is_empty():
						if menu == music_menu: _close_music_menu()
						else: menu.dismiss()
		return
	if photo_active:
		match action:
			"trigger_click":
				if photo.local_uri.is_empty(): _show_recent_menu()
				elif not _grab.is_empty(): return
				else:
					var ray: Variant = _ray(hand)
					if ray != null and photo.gallery.press_pointer(hand, ray[0], ray[1]): stick_controls.suspend()
					else: _begin_grab(hand)
			"ax_button": _show_recent_menu()
			"primary_click":
				if hand == "left_hand": photo.cycle_projection()
				else: _reset_picture()
		return
	match action:
		"trigger_click":
			if _viewer().local_uri.is_empty():
				_show_recent_menu()
			else:
				_begin_grab(hand)
		"ax_button":
			if hand == "left_hand": _show_recent_menu()
		"primary_click":
			if hand == "left_hand":
				video.cycle_projection()
			else:
				_reset_picture()

## Menus shown at launch are placed before the headset reports a pose (the camera is still at
## the floor origin): once the head is first tracked, recenter and place everything again.
var _head_placed := false

func _head_tracked() -> bool:
	var head := XRServer.get_tracker("head") as XRPositionalTracker
	if not head or not head.has_pose("default"):
		return false
	var pose := head.get_pose("default")
	return pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

func _on_system_recentered() -> void:
	Log.record("system_recentered")
	if controller_feedback: controller_feedback.rebase()
	_recenter()

func _process(delta: float) -> void:
	cast_session.tick()
	if video:
		if video.video_layer:
			video.video_layer.reserved_layers = 2 + (menu_composition.layer_reservation() if menu_composition else 5)
		video.captures.tick()
		if capture_overlay:
			capture_overlay.sync(video.captures.status())
			if capture_overlay.visible:
				for hand in ["left_hand", "right_hand"]:
					var capture_ray: Variant = _ray(hand) if _input_focused() else null
					capture_overlay.update_pointer(hand, capture_ray[0] if capture_ray != null else Vector3.ZERO, capture_ray[1] if capture_ray != null else Vector3.ZERO, capture_ray != null)
	video_queue_pages.poll()
	if not _pending_video_end.is_empty():
		_advance_completed_video(_pending_video_end.uri, _pending_video_end.session, _pending_video_end.sequence)
	_sync_background_audio()
	if _background_save_after > 0 and Time.get_ticks_msec() >= _background_save_after: _save_background_preferences()
	if favorites: favorites.tick(Time.get_ticks_msec())
	_update_seek_feedback(delta)
	if _audio_save_after > 0 and Time.get_ticks_msec() >= _audio_save_after: _save_audio_preferences()
	display.set_video_layer((video != null and not photo_active and video.video_layer_shown) or (photo != null and photo_active and photo.layer_shown))
	_sync_display_policy()
	_sync_cinema_screen()
	_update_cinema_film_light(delta)
	_update_view_follow()
	_refresh_session_controls()
	if _gallery_save_after > 0 and Time.get_ticks_msec() >= _gallery_save_after:
		_gallery_save_after = 0; _save_photo_adjustments()
	_update_wrist_watch(delta)
	_update_hand_input(delta)
	_disc_menu_hover()
	_sync_disc_menu_bar()
	if puzzle_game and puzzle_game.active:
		if video: video.cinema.hide_guide()
		puzzle_game.tick(delta); stick_controls.suspend(); display.set_video_layer(false); return
	if not _head_placed and _head_tracked():
		_head_placed = true
		if not view_follow.enabled: _recenter(false)
	if video and (_viewer().local_uri != _screen_uri or (photo_active and photo.placement_pending)):
		_screen_uri = _viewer().local_uri
		if not _screen_uri.is_empty():
			if not photo_active or photo.placement_pending: _place_screen()
			if photo_active: photo.placement_pending = false
	_update_photo_inspect()
	_update_grab()
	_update_interface_move()
	_update_pip_input()
	if photo_active and not _active_menu() and not photo.inspect:
		for hand in ["left_hand", "right_hand"]:
			var ray: Variant = _ray(hand)
			photo.gallery.update_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null)
	if photo:
		var targeted: bool = photo_active and not _active_menu() and not photo.inspect and (photo.gallery.hover.values().has(photo.index) or photo.gallery.focus >= 0)
		var held: bool = targeted and (not photo_hands.owners.is_empty() or not _grab.is_empty())
		photo.set_target_feedback(2 if held else (1 if targeted else 0))
	var right := _stick(right_controller)
	var left := _stick(left_controller)
	if display.preview and _cinema_interaction_owns() and not _active_menu():
		left = Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
		right = Vector2(float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)), 0)
	_update_corner_hover()
	_update_flat_grab_stick(left, right, delta)
	_process_sticks(left, right, delta)
	_update_controller_feedback(delta)

var _cinema_adjusting := false
## A wanted rate must hold this long before it applies: a video revision briefly drops the layer and
## the state, and every switch costs the runtime a few frames.
const REFRESH_SETTLE_MS := 1500
var _refresh_wanted := 0.0
var _refresh_since := 0

## Refresh rate follows the playing video's frame rate; CPU/GPU levels stay high while playing.
func _sync_display_policy() -> void:
	var playing: bool = video != null and not photo_active and not video.local_uri.is_empty() and video.media.state in ["playing", "paused"]
	# Playback keeps 0.12.5's sustained-high levels (network demux, decode, inference); menus, idle
	# and power-saving playback without inference drop to sustained-low.
	var inference: bool = playing and (video.alpha_requested or video.depth_requested)
	var saving: bool = Quality.load_refresh_cap(settings, low_end_gpu) == Quality.POWER_SAVING_CAP
	display.set_performance_demand((playing and not saving) or inference or (photo_active and photo != null and photo.depth_requested))
	var rate := 0.0
	# GPU inference shares the GPU with every extra refresh: 8K VR180 Alpha ran 62 fps at 72 Hz,
	# 40 at 90 and 25 at 120 on Quest 3 (2026-10-21). Alpha and 2D->3D keep the menu rate.
	if playing and not video.alpha_requested and not video.depth_requested:
		var fps := str(video.media.playback.get("details", {}).get("container_fps", ""))
		if fps.is_valid_float():
			# Eye-buffer video (shaped screens, packed masks) renders every refresh: at most 90 Hz.
			var cap: float = Quality.load_refresh_cap(settings, low_end_gpu)
			if not video.layer_capable() or video.fisheye_overloaded: cap = minf(cap, 90.0)
			rate = display.video_refresh_rate(float(fps), display.available_refresh_rates(), cap)
	var now := Time.get_ticks_msec()
	if not is_equal_approx(rate, _refresh_wanted):
		_refresh_wanted = rate; _refresh_since = now
	elif now - _refresh_since >= REFRESH_SETTLE_MS:
		display.set_refresh_preference(rate)
	display.check_refresh()

func _process_sticks(left: Vector2, right: Vector2, delta: float) -> void:
	_cinema_adjusting = false
	_process_stick_input(left, right, delta)
	_update_cinema_guide()

func _update_cinema_guide() -> void:
	if not video: return
	var adjusting := false
	if not photo_active and _input_focused() and video.cinema.active(video) and not (puzzle_game and puzzle_game.active):
		var menu := _active_menu()
		if menu == player_menu and is_instance_valid(player_menu) and player_menu.visible:
			adjusting = player_menu._adjust_target in [450, 451] and not player_menu._adjust_hand.is_empty() and _ray(player_menu._adjust_hand) != null
		if not menu or (menu == player_menu and player_menu.allows_playback_sticks()):
			adjusting = adjusting or (_cinema_adjusting and not _flat_zoom_hand.is_empty() and _ray(_flat_zoom_hand) != null)
			if _grab.has("resize") and _ray(_grab.hand) != null: adjusting = true
		# Grip depth is permitted even while the playback controls are open.
		if _cinema_adjusting and not interface_move.capture.is_empty(): adjusting = true
	video.cinema.show_guide(video, _head_pose(), adjusting)

func _stills_playback_priority(menu: Node3D) -> bool:
	# An open video session owns the sticks even while browsing a film's stills.
	# Pause/buffering must not silently turn a held seek gesture into picture navigation.
	if photo_active or not video or video.local_uri.is_empty() or not video.media.accepts(video.media.session_id): return false
	if not recent_menu is LibraryMenu or not recent_menu.media_picture_open() or _menu_captured(menu) or not recent_menu.server_browser.gallery.capture.is_empty(): return false
	return menu == recent_menu or (menu == player_menu and _library_is_attached())

func _process_stick_input(left: Vector2, right: Vector2, delta: float) -> void:
	if cinema_environment and _cinema_input_blocked(): cinema_environment.suspend()
	if not _flat_zoom_hand.is_empty() and (photo_active or video.geometry != Geometry.Geometry.FLAT \
		or (left if _flat_zoom_hand == "left_hand" else right).length() < 0.3): _finish_flat_zoom()
	_update_seek_feedback(0.0)
	var menu := _active_menu()
	if menu:
		_update_menu_pointer("left_hand")
		_update_menu_pointer("right_hand")
	if not photo_active and video and video.get("pip") and video.pip.blocked():
		var capture: Dictionary = video.pip.movement.capture
		if not capture.is_empty() and _input_focused():
			var hand: String = capture.hand
			video.pip.adjust_distance(hand, left if hand == "left_hand" else right, delta, _move_pose(hand), _head_pose())
		stick_controls.suspend(); return
	if not interface_move.capture.is_empty() and _input_focused():
		var held := left if interface_move.capture.hand == "left_hand" else right
		var chord_pending: bool = interface_move.pending() and controller_bindings.down[interface_move.capture.hand].has("trigger_click")
		_cinema_adjusting = not chord_pending and interface_move.capture.get("depth_ready", false) and held.is_finite() and absf(held.y) > 0.2 and absf(held.y) > absf(held.x) \
			and interface_move.capture.get("targets", []).any(func(target): return target.node == video and target.kind == "screen")
		if not chord_pending and interface_move.adjust_distance(held, delta):
			_update_interface_move()
			if interface_move.capture.is_empty(): _cinema_adjusting = false
			for target in interface_move.capture.get("targets", []):
				if target.kind == "screen" and is_instance_valid(target.node): target.node.set_screen_distance(_surface_distance(target.node))
			if menu and not interface_move.capture.is_empty(): _update_menu_pointer(interface_move.capture.hand)
		if not chord_pending: stick_controls.suspend(); return
	if not interface_move.capture.is_empty() and interface_move.capture.moved:
		stick_controls.suspend(); return
	if _grab.has("resize"):
		stick_controls.suspend(); return
	if photo_active and photo.gallery.has_capture():
		stick_controls.suspend(); return
	if photo_active and photo.inspect:
		stick_controls.suspend()
		return
	if not _input_focused() and _debug_sticks.is_empty():
		stick_controls.suspend()
		return
	if photo_active and photo.geometry == Geometry.Geometry.FLAT and not photo_hands.owners.is_empty():
		stick_controls.suspend()
		return
	if menu and not _stills_playback_priority(menu) and (menu != player_menu or photo_active or not player_menu.allows_playback_sticks()):
		stick_controls.suspend()
		# Either stick scrolls a list, never selects or controls playback at the same time.
		if menu.has_method("stick_scroll_horizontal"):
			menu.stick_scroll_horizontal(left.x if absf(left.x) > absf(right.x) else right.x, delta)
		if menu.has_method("stick_scroll") and (menu != player_menu or not player_menu.has_pointer_capture()):
			menu.stick_scroll(left.y if absf(left.y) > absf(right.y) else right.y, delta)
		_update_controls_visibility(menu)
		return
	if cinema_environment and cinema_environment.active and not menu and cinema_environment.poll_sticks(left, right, delta, _cinema_input_blocked()):
		stick_controls.suspend()
		return
	var actions := stick_controls.poll(left, right, video != null) if controller_bindings.overrides.is_empty() and not interface_move.pending() else stick_controls.poll_mapped(left, right, _axis_binding)
	if not _grab.is_empty():
		# Holding the picture: only zoom; other stick shortcuts wait for the stick to recenter.
		actions = actions.filter(func(action): return action.operation == "zoom")
	_apply_stick_actions(actions, delta)
	if seek_feedback.phase == "preview":
		var hand := seek_feedback.owner
		var controller := left_controller if hand == "left_hand" else right_controller
		var valid := display.preview or _debug_sticks.has(hand) or (controller != null and controller.get_is_active() and controller.get_has_tracking_data() and _controller_allowed(hand))
		if not valid or (not seek_feedback.action_id.is_empty() and _axis_binding(hand, seek_feedback.input).get("id", "") != seek_feedback.action_id):
			stick_controls.suspend()
		elif seek_feedback.poll(left if hand == "left_hand" else right, delta):
			# Install the expected sequence before seek_absolute emits synchronous changed events.
			seek_feedback.sequence = video.control.sequence + 1
			if not video.seek_absolute(seek_feedback.target_ms): seek_feedback.clear()
			_update_seek_feedback(0.0)
	if menu == player_menu and menu != null:
		if not actions.is_empty() or player_menu._state.get("seek_feedback", {}) != seek_feedback.snapshot():
			_menu_touched_ms = Time.get_ticks_msec()
			player_menu.refresh_values()
		_update_controls_visibility(menu)

func _update_controls_visibility(menu: Node3D) -> void:
	if menu != player_menu or menu == null or not menu.visible: return
	if player_menu.has_expanded_library(): return
	var now := Time.get_ticks_msec()
	if menu.has_pointer_capture() or (photo_active and menu._hover.values().any(func(target): return int(target) != menu.NONE)):
		_menu_touched_ms = now
		return
	# Keep popups, sliders and pending seeks visible; use media state, not the seek queue's state.
	if menu.section != 0 or menu._mode_open or not menu._adjustment.is_empty() or menu._volume_open or menu._depth_open: return
	if photo_active and photo_menu._layout_open: return
	if photo_active:
		if photo_menu.online.opened or photo_menu._gallery_open or photo.loading: return
	else:
		if not menu.choices.opened.is_empty() or menu._audio_open or menu._subtitle_open or menu.bookmarks.opened or not video.requested_play or video.media.state != "playing" \
			or video.control.pending or video.control.in_flight > 0 or not seek_feedback.phase.is_empty() or not video.loading_caption().is_empty(): return
	if now - _menu_touched_ms > CONTROLS_HIDE_MS: menu.dismiss()

## Debug device probes: a stick deflection held for a time, through the normal stick path.
var _debug_sticks := {}
func _debug_stick(hand: String) -> Variant:
	if not OS.is_debug_build() or not _debug_sticks.has(hand): return null
	if Time.get_ticks_msec() < int(_debug_sticks[hand][1]): return _debug_sticks[hand][0]
	# Then centered for a moment, as a released stick: a seek preview commits on release.
	if Time.get_ticks_msec() < int(_debug_sticks[hand][1]) + 500: return Vector2.ZERO
	_debug_sticks.erase(hand)
	return null

func _stick(controller: XRController3D) -> Vector2:
	var injected: Variant = _debug_stick(str(controller.tracker)) if controller else null
	if injected != null: return injected
	return controller.get_vector2("primary") if controller and controller.get_is_active() and _controller_allowed(str(controller.tracker)) else Vector2.ZERO

func _hand_tracker(hand: String) -> XRHandTracker:
	return XRServer.get_tracker("/user/hand_tracker/" + ("left" if hand == "left_hand" else "right")) as XRHandTracker

func _hand_action_tracker(hand: String) -> XRPositionalTracker:
	return XRServer.get_tracker(hand) as XRPositionalTracker

func _meta_aim_tracker(hand: String) -> XRPositionalTracker:
	return XRServer.get_tracker("/user/fbhandaim/" + ("left" if hand == "left_hand" else "right")) as XRPositionalTracker

func _input_focused() -> bool:
	return display.preview or display.session_state == "session_focussed"

func _controller_allowed(hand: String) -> bool:
	if not _input_focused(): return false
	# Query current data too: XR input signals may arrive before our process callback.
	return not HandPointer.is_optical(_hand_tracker(hand)) and not HandPointer.is_hand_profile(_hand_action_tracker(hand)) \
		and not (hand_pointers.has(hand) and hand_pointers[hand].source == "hand")

func _controller_ray(hand: String) -> Variant:
	var controller := left_controller if hand == "left_hand" else right_controller
	if not controller or not controller.get_is_active() or not controller.get_has_tracking_data(): return null
	var pose := controller.get_pose()
	if not pose or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return null
	return [controller.global_position, -controller.global_basis.z]

func _update_hand_input(delta: float) -> void:
	var inputs := {}
	var wave_enabled: bool = photo_active and photo.gallery.mode in [2, 3] and photo.gallery.focus < 0 and not photo.portrait_requested and not _active_menu() and _input_focused()
	for hand in hand_pointers:
		var sample := {}
		var point: Variant = null
		var hand_pose: Variant = null
		var reference_position: Variant = null
		var palm := {}
		if _input_focused():
			var tracker := _hand_tracker(hand)
			if HandPointer.is_optical(tracker) and xr_camera and xr_origin and _head_tracked():
				sample = HandPointer.sample(tracker, hand, xr_camera.global_transform,
					xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale,
					_meta_aim_tracker(hand), _hand_action_tracker(hand), hand_pointers[hand].runtime_trusted)
				point = HandPointer.pinch_position(tracker, xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale)
				if wave_enabled:
					palm = HandPointer.sweep_sample(tracker, xr_camera.global_transform,
						xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale,
						_meta_aim_tracker(hand), _hand_action_tracker(hand))
			elif HandPointer.is_hand_profile(_hand_action_tracker(hand)):
				# Action aim/select is independent of the optional hand-joint stream.
				# Runtimes may also expose controllers through a hand interaction profile.
				if xr_origin:
					sample = HandPointer.runtime_sample(_hand_action_tracker(hand),
						xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale, false)
			elif not HandPointer.is_optical(tracker):
				var ray: Variant = _controller_ray(hand)
				if ray != null: sample = {"source": "controller", "ray": ray}
			if puzzle_game and puzzle_game.active and xr_origin:
				reference_position=HandPointer.palm_position(tracker,xr_origin.global_transform*XRServer.get_reference_frame(),XRServer.world_scale)
				hand_pose=HandPointer.grip_pose(tracker,xr_origin.global_transform*XRServer.get_reference_frame(),XRServer.world_scale)
				if hand_pose==null and sample.get("source")=="hand": hand_pose=sample.get("pose")
		var event: Dictionary = hand_pointers[hand].update(sample, delta)
		if event.cancelled: _cancel_pointer(hand)
		if event.menu and hand == "left_hand": _on_pointer_button("menu_button", hand)
		var pointer: RefCounted = hand_pointers[hand]
		inputs[hand] = event.merged({"source": pointer.source, "tracked": pointer.ray != null,
			"down": pointer.down, "position": point, "palm": palm, "pose": hand_pose,"reference_position":reference_position})
		if hand_marks.has(hand):
			var mark: MeshInstance3D = hand_marks[hand]
			mark.visible = pointer.source == "hand" and pointer.ray != null and _input_feedback_visible()
			if mark.visible:
				# Joint rays start at the knuckle; the mark stays between the pinching fingers.
				mark.global_position = point if point != null and pointer.provider == "joints" else pointer.ray[0]
				mark.scale = Vector3.ONE * XRServer.world_scale * (0.65 if pointer.down else 1.0)
	_dispatch_hand_input(inputs, delta)

# --- wrist watch -----------------------------------------------------------------------------

## Watch offsets from the wrist joint: out of the back of the hand, and toward the elbow.
const WATCH_SKIN := 0.034
const WATCH_TOWARD_ELBOW := 0.03
const WATCH_GRIP_OFFSET := Vector3(0.035, 0, 0.075)   # left grip space: +X leaves the back of the hand

func _update_wrist_watch(delta: float) -> void:
	if not wrist_watch: return
	var enabled: bool = video != null and not photo_active and _has_open_media() and _input_focused() and xr_camera != null \
		and _head_tracked() and not (puzzle_game and puzzle_game.active) and interface_move.capture.is_empty() \
		and (_active_menu() == null or _active_menu() == player_menu) and not _menu_captured(_active_menu()) \
		and _watch_enabled()
	var frame := {"enabled": enabled}
	if enabled:
		frame.head = xr_camera.global_transform
		frame.wrist = _watch_wrist()
		frame.tip = _watch_tip()
		if wrist_watch.visible or frame.wrist != null: frame.media = _watch_media()
	var actions: Array[Dictionary] = wrist_watch.step(frame, delta)
	var owned: bool = wrist_watch.owns_tip()
	if owned and not _watch_owned: _cancel_pointer("right_hand")
	_watch_owned = owned
	for action in actions: _apply_watch_action(action)
	# Debug builds log the glance measurements once a second for device tuning.
	var now := Time.get_ticks_msec()
	if OS.is_debug_build() and video and not video.local_uri.is_empty() and now - _watch_probe_ms >= 1000:
		_watch_probe_ms = now
		Log.record("wrist_watch_probe", {"enabled": enabled, "focused": _input_focused(), "head": _head_tracked(),
			"menu": str(_active_menu().name) if _active_menu() else "", "wrist": frame.get("wrist") != null, "tip": frame.get("tip") != null,
			"left_optical": HandPointer.is_optical(_hand_tracker("left_hand")), "phase": int(wrist_watch.logic.phase),
			"visible": wrist_watch.visible, "metrics": wrist_watch.logic.metrics})

## Remembered across sessions; the watch shows only in hand-tracking mode, never with controllers.
func _watch_enabled() -> bool:
	return bool(settings.get_value("watch", "enabled", true)) and _watch_hand_mode()

func _watch_hand_mode() -> bool:
	return wrist_watch != null and HandPointer.is_optical(_hand_tracker("left_hand"))

func _toggle_wrist_watch() -> void:
	settings.set_value("watch", "enabled", not bool(settings.get_value("watch", "enabled", true)))
	settings.save(settings_path)
	Log.record("setting_changed", {"key": "wrist_watch", "value": settings.get_value("watch", "enabled")})
	if is_instance_valid(player_menu): player_menu.refresh()

func _watch_space() -> Transform3D:
	return xr_origin.global_transform * XRServer.get_reference_frame()

func _watch_wrist() -> Variant:
	var tracker := _hand_tracker("left_hand")
	if HandPointer.is_optical(tracker):
		return _watch_wrist_from_joints(tracker)
	var action := _hand_action_tracker("left_hand")
	if not _controller_allowed("left_hand") or action == null or not action.has_pose("grip"): return null
	var grip := action.get_pose("grip")
	if not grip.has_tracking_data or grip.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return null
	var world := xr_origin.global_transform * grip.get_adjusted_transform()
	var basis := world.basis.orthonormalized()
	# Watch space: +Y out of the face (grip +X), +Z toward the elbow (grip +Z).
	return Transform3D(Basis(basis.x.cross(basis.z), basis.x, basis.z), world * (WATCH_GRIP_OFFSET * XRServer.world_scale))

## Built from joint positions alone: runtimes disagree on joint axes (on Quest 3 the wrist +Y
## runs along the forearm), but the palm triangle always gives the back of the hand.
func _watch_wrist_from_joints(tracker: XRHandTracker) -> Variant:
	var points := {}
	for joint in [XRHandTracker.HAND_JOINT_WRIST, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
			XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]:
		if tracker.get_hand_joint_flags(joint) & HandPointer.POSITION_FLAGS != HandPointer.POSITION_FLAGS: return null
		var point := tracker.get_hand_joint_transform(joint).origin
		if not point.is_finite(): return null
		points[joint] = _watch_space() * (point * XRServer.world_scale)
	var wrist: Vector3 = points[XRHandTracker.HAND_JOINT_WRIST]
	var index: Vector3 = points[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL]
	var pinky: Vector3 = points[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]
	var middle: Vector3 = points[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL]
	# Left hand: (index - wrist) x (pinky - wrist) leaves the back of the hand.
	var back := (index - wrist).cross(pinky - wrist)
	var elbow := wrist - middle
	if back.length_squared() < 1e-8 or elbow.length_squared() < 1e-6: return null
	back = back.normalized()
	elbow = (elbow - back * elbow.dot(back)).normalized()
	var scale := XRServer.world_scale
	return Transform3D(Basis(back.cross(elbow), back, elbow), wrist + back * WATCH_SKIN * scale + elbow * WATCH_TOWARD_ELBOW * scale)

func _watch_tip() -> Variant:
	var tracker := _hand_tracker("right_hand")
	if HandPointer.is_optical(tracker):
		var joint := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
		if tracker.get_hand_joint_flags(joint) & HandPointer.POSITION_FLAGS != HandPointer.POSITION_FLAGS: return null
		var point := tracker.get_hand_joint_transform(joint).origin
		return _watch_space() * (point * XRServer.world_scale) if point.is_finite() else null
	var ray: Variant = _controller_ray("right_hand") if _controller_allowed("right_hand") else null
	return ray[0] if ray != null else null

func _watch_media() -> Dictionary:
	return {"has_video": video.media.accepts(video.media.session_id), "playing": video.requested_play,
		"position_ms": video.control.display_position_ms(), "duration_ms": video.control.duration_ms,
		"bookmarks": video.bookmarks_snapshot().get("bookmarks", [])}

func _apply_watch_action(action: Dictionary) -> void:
	var op := str(action.get("op", ""))
	match op:
		"play": video.toggle_play()
		"menu": _show_player_menu()
		"seek": video.seek_absolute(int(action.position_ms))
		"scrub_begin", "scrub_end", "tap": pass
		_: return
	Log.record("wrist_watch", action)
	if right_controller and not HandPointer.is_optical(_hand_tracker("right_hand")):
		right_controller.trigger_haptic_pulse("haptic", 0.0, 0.35 if op != "scrub_end" else 0.2, 0.03, 0.0)

func _is_photo_hand(hand: String) -> bool:
	return photo_active and photo != null and photo.geometry == Geometry.Geometry.FLAT \
		and hand_pointers.has(hand) and hand_pointers[hand].source == "hand"

func _dispatch_hand_input(inputs: Dictionary, _delta: float = 1.0 / 72.0) -> void:
	if puzzle_game and puzzle_game.active:
		puzzle_game.hand_inputs(inputs); return
	if _watch_owned and inputs.has("right_hand"):
		inputs = inputs.duplicate(); inputs.erase("right_hand")
	if not interface_move.capture.is_empty(): return
	if photo_active:
		inputs = inputs.duplicate(true)
		var overview_enabled: bool = (photo.gallery.overview() or (photo.gallery.focus >= 0 and photo.geometry == 0 and photo.panel.visible)) and not photo.inspect and not _active_menu() and _input_focused() and photo_hands.owners.is_empty()
		var zoom: Dictionary = photo.gallery.hand_zoom(inputs, overview_enabled)
		for hand in zoom.consumed: inputs.erase(hand)
		if not zoom.consumed.is_empty(): stick_controls.suspend(); _grab = {}
		if zoom.finished: _save_photo_adjustments()
		var wave_enabled: bool = photo.gallery.overview() and overview_enabled and photo.gallery._swap_phase == 0
		var head := xr_camera.global_transform if xr_camera else Transform3D.IDENTITY
		var waves: Array = memory_swipe.update(inputs, wave_enabled, photo.gallery.has_capture() or inputs.values().any(func(input): return input.get("down", false)), head, XRServer.world_scale, _delta)
		for detail in memory_swipe.diagnostics: Log.record("memory_wave", detail)
		memory_swipe.diagnostics.clear()
		if not waves.is_empty():
			if photo.gallery.change_batch(int(waves[0].direction)): Log.record("photo_batch", {"input": "wave", "hand": waves[0].hand, "layout": photo.gallery.mode})
	if photo_active and photo.gallery.mode != 0 and not photo.inspect and not _active_menu() and _input_focused() and photo_hands.owners.is_empty():
		inputs = inputs.duplicate(true)
		for hand in inputs.keys():
			if inputs[hand].get("source") != "hand": continue
			var ray: Variant = _ray(hand)
			var reserved: bool = photo.gallery.capture.get("hand", "") == hand
			var hit: Dictionary = photo.gallery.ray_hit(ray[0], ray[1]) if ray != null else {}
			if inputs[hand].get("pressed", false) and not hit.is_empty() and (photo.gallery.cards.has(int(hit.index)) or int(hit.index) == photo.gallery.focus):
				photo_hands.cancel(); _on_pointer_button("trigger_click", hand); reserved = true
			if reserved:
				if inputs[hand].get("released", false): _on_pointer_release("trigger_click", hand)
				inputs.erase(hand)
	var flat_photo: bool = photo_active and photo != null and photo.geometry == Geometry.Geometry.FLAT
	var inspecting: bool = photo_active and photo != null and photo.inspect
	if inspecting:
		for hand in inputs:
			if inputs[hand].get("source") == "hand" and inputs[hand].get("pressed", false):
				for side in inputs:
					if inputs[side].get("down", false) or inputs[side].get("pressed", false): _inspect_blocked[side] = true
				_close_photo_inspect()
				break
	var enabled: bool = flat_photo and (photo.panel.visible or photo.placeholder_visible()) and _input_focused() and not _active_menu() and _grab.is_empty() \
		and not inspecting and not photo.inspect and _inspect_blocked.is_empty()
	var pose := xr_camera.global_basis if xr_camera else Basis.IDENTITY
	var result: Dictionary = photo_hands.update(inputs, enabled,
		photo.screen_scale if flat_photo else 1.0,
		pose, XRServer.world_scale, photo._serial if photo else -1)
	for action in result.actions:
		match action.operation:
			"tap": _show_player_menu()
			"navigate":
				var accepted: bool = photo.navigate(int(action.direction))
				if action.has("hand"): Log.record("photo_pinch_navigation", {"hand":action.hand, "direction":action.direction, "accepted":accepted})
			"zoom":
				photo.finish_transition(); photo.set_hand_scale(float(action.value))
			"finish":
				_save_screen()
	if flat_photo and not result.actions.any(func(action): return action.operation == "navigate"):
		photo.preview_navigation(float(result.get("preview", 0.0)))
	for hand in inputs:
		if _inspect_blocked.has(hand):
			if inputs[hand].get("released", false) or inputs[hand].get("cancelled", false) or not inputs[hand].get("tracked", false) or not inputs[hand].get("down", false):
				_inspect_blocked.erase(hand)
			continue
		if hand in result.consumed: continue
		if inputs[hand].get("pressed", false): _on_pointer_button("trigger_click", hand)
		if inputs[hand].get("released", false): _on_pointer_release("trigger_click", hand)

func _cancel_pointer(hand: String) -> void:
	if video and video.get("pip"): video.pip.cancel_pointer(hand)
	if cinema_environment: cinema_environment.cancel_pointer(hand)
	controller_bindings.cancel_hand(hand)
	if _video_control_tap.get("hand", "") == hand: _video_control_tap = {}
	if not interface_move.capture.is_empty() and interface_move.capture.hand == hand: interface_move.cancel()
	if photo: photo.gallery.cancel_pointer(hand)
	_inspect_blocked.erase(hand)
	if not _grab.is_empty() and _grab.hand == hand:
		if _grab.moved and not _grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT: _save_screen()
		_grab = {}
		_viewer().set_corner_hover(-1)
	# Cancellation never becomes a tap, row selection, or fling.
	for menu in [recent_menu, video_menu, photo_menu, music_menu]:
		if is_instance_valid(menu) and menu.has_method("cancel_pointer"): menu.cancel_pointer(hand)

func _on_input_session_changed() -> void:
	if cinema_environment: cinema_environment.suspend()
	if not _input_focused() and _cinema_desktop_look:
		_cinema_desktop_look = false; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if puzzle_game and puzzle_game.active and not _input_focused():
		puzzle_game.show_panel(true)
	if favorites: favorites.focus_changed(_input_focused(), Time.get_ticks_msec())
	if _input_focused(): return
	if video: video.cinema.hide_guide()
	if controller_feedback: controller_feedback.rebase()
	_finish_flat_zoom()
	_video_control_tap = {}
	controller_bindings.reset_inputs(); interface_move.cancel(); stick_controls.suspend()
	photo_hands.cancel()
	photo_swipe.cancel(); memory_swipe.cancel()
	for hand in hand_pointers:
		hand_pointers[hand].update({}, 0)
		_cancel_pointer(hand)
		if hand_marks.has(hand): hand_marks[hand].visible = false

func _hand_input_report() -> Dictionary:
	var report := {}
	for hand in hand_pointers:
		var pointer: RefCounted = hand_pointers[hand]
		var action := _hand_action_tracker(hand)
		var joints := _hand_tracker(hand)
		report[hand] = {"source": pointer.source, "provider": pointer.provider, "tracked": pointer.ray != null, "pinching": pointer.down,
			"runtime_trusted": pointer.runtime_trusted,
			"profile": str(action.get_tracker_profile()) if action else "",
			"action_aim_tracked": _input_pose_tracked(action, "aim"), "action_grip_tracked": _input_pose_tracked(action, "grip"),
			"joint_tracking": joints != null and joints.has_tracking_data,
			"joint_source": int(joints.hand_tracking_source) if joints else -1}
	return report

static func _input_pose_tracked(tracker: XRPositionalTracker, pose_name: String) -> bool:
	if tracker == null or not tracker.has_pose(pose_name): return false
	var pose := tracker.get_pose(pose_name)
	return pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

# --- dragging the picture -------------------------------------------------------------------

const GRAB_START := 0.035   # radians the ray turns before a trigger press becomes a drag
const MOUSE_TURN := 0.004   # radians per pixel in the desktop preview
const ZOOM_SPEED := 0.6     # sphere radii per second at full deflection
const PUSH_SPEED := 1.5     # metres per second the held flat screen moves at full deflection
const STICK_DEADZONE := 0.2
## Photo trigger / hand pinch outside menus: hand, start/last ray angles, moved; a press on a
## flat screen corner adds resize = {corner, start_length, start_scale}.
var _grab := {}

func _update_flat_grab_stick(left: Vector2, right: Vector2, delta: float) -> void:
	if not _input_focused() or _active_menu() or not interface_move.capture.is_empty() or _grab.is_empty() or _grab.has("resize") or _grab.has("inspect") or _viewer().geometry != Geometry.Geometry.FLAT:
		return
	var held := left if _grab.hand == "left_hand" else right
	if not held.is_finite() or not is_finite(delta) or delta <= 0 or absf(held.y) <= STICK_DEADZONE or absf(held.x) >= absf(held.y): return
	var amount := signf(held.y) * (absf(held.y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE) * delta
	_grab.moved = true
	_push_screen(amount * PUSH_SPEED)
	stick_controls.suspend()

func _eye() -> Vector3:
	if is_instance_valid(_viewer().view_camera) and _viewer().view_camera.is_inside_tree():
		return _viewer().view_camera.global_position
	return Vector3(0, 1.6, 0)

func _ray(hand: String) -> Variant:
	if not _input_focused(): return null
	if hand_pointers.has(hand) and hand_pointers[hand].source == "hand": return hand_pointers[hand].ray
	if HandPointer.is_optical(_hand_tracker(hand)): return null
	return _controller_ray(hand)

## Activity uses raw tracking-space metres, independently of the head, XR origin,
## reference-frame adjustment and the world-space ray used to draw/hit media.
func _controller_activity(hand: String) -> Dictionary:
	if not _controller_allowed(hand): return {}
	var tracker := XRServer.get_tracker(hand) as XRPositionalTracker
	if not tracker or not tracker.has_pose("grip") or not tracker.has_pose("aim"): return {}
	var grip := tracker.get_pose("grip")
	var aim := tracker.get_pose("aim")
	if not grip.has_tracking_data or not aim.has_tracking_data \
		or grip.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_HIGH \
		or aim.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_HIGH: return {}
	if not grip.transform.is_finite() or not aim.transform.is_finite(): return {}
	return {"position": grip.transform.origin, "direction": -aim.transform.basis.z}

func _input_feedback_visible() -> bool:
	# Photos remain interactive even when their controls are closed.
	if photo_active: return true
	# Cinema seat/move mode is an explicit interactive scene, separate from watching;
	# so is a disc menu, whose buttons are pointed at on the screen.
	return _active_menu() != null or _cinema_interaction_owns() or (video != null and video.disc.menu_session)

func _update_controller_feedback(delta: float) -> void:
	if not controller_feedback: return
	var focused := _input_focused() and (_head_tracked() or display.preview)
	var menu := _active_menu()
	var feedback_visible := _input_feedback_visible()
	var alphas := {}
	for hand in ControllerBindings.HANDS:
		var pose: Variant = _move_pose(hand) if focused else null
		var ray: Variant = _ray(hand) if focused and (pose != null or photo_active) else null
		# Optical photo aim does not require a physical controller grip pose.
		if photo_active and pose == null and ray != null: pose = Transform3D(Basis.IDENTITY, ray[0])
		if cinema_environment:
			var valid_cinema_ray: bool = ray != null and focused and _cinema_interaction_owns() and not _cinema_input_blocked()
			cinema_environment.update_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.FORWARD, valid_cinema_ray)
		var engaged: bool = not controller_bindings.down[hand].is_empty() \
			or interface_move.capture.get("hand", "") == hand or _grab.get("hand", "") == hand \
			or (photo_active and photo.gallery.capture.get("hand", "") == hand)
		# A suspended latch or an unassigned/diagonal axis is not an accepted action.
		var pointer_engaged: bool = engaged or _menu_pointer_owned(menu, hand)
		engaged = engaged or stick_controls.active_hands.has(hand.trim_suffix("_hand")) or _menu_pointer_owned(menu, hand)
		if photo_active: pointer_engaged = engaged
		var captured: bool = interface_move.capture.get("hand", "") == hand or _grab.get("hand", "") == hand
		var point: Variant = _media_move_anchor(_viewer(), ray) if ray != null else null
		if interface_move.capture.get("hand", "") == hand: point = interface_move.capture.anchor
		elif _grab.get("hand", "") == hand and _grab.has("resize"):
			point = _viewer().panel.to_global(_viewer().screen_corner(int(_grab.resize.corner)))
		elif ray != null and _viewer() and not (photo_active and (photo.inspect or photo.gallery.overview())):
			var corner: int = _viewer().corner_at(ray[0], ray[1])
			if corner >= 0: point = _viewer().panel.to_global(_viewer().screen_corner(corner))
		var world_pointer: bool = not (photo_active and photo.inspect) and not (_cinema_interaction_owns() and not menu)
		if not photo_active and video and video.geometry != Geometry.Geometry.FLAT: world_pointer = captured
		elif not photo_active and stick_controls.active_hands.has(hand.trim_suffix("_hand")) and not captured: world_pointer = false
		if not photo_active and video and video.get("pip") and ray != null and (not video.pip.hit(ray[0], ray[1]).is_empty() \
			or video.pip.resize.get("hand", "") == hand or video.pip.movement.capture.get("hand", "") == hand \
			or (video.pip.selecting > 0 and video.pip.selection_hand == hand)):
			# The local window draws its own endpoint; avoid a second ray through it to the video.
			world_pointer = false; engaged = true; pointer_engaged = true
		alphas[hand] = controller_feedback.update_hand(hand, pose, ray, point, engaged, menu != null, delta,
			world_pointer, _controller_activity(hand) if pose != null and feedback_visible else {}, false, pointer_engaged, feedback_visible, photo_active)
		if menu and not photo_active and pose != null:
			_menu_touched_ms = maxi(_menu_touched_ms, Time.get_ticks_msec() - int(controller_feedback.activity_age(hand) * 1000.0))
		if photo: photo.gallery.hide_pointer(hand)
		if not feedback_visible and hand_marks.has(hand): hand_marks[hand].visible = false
	if photo and not feedback_visible: photo.hide_inspect_pointer()
	if input_visuals:
		var moving: bool = _cinema_interaction_owns() and not _cinema_input_blocked()
		input_visuals.set_cinema_move_hint(moving)
		if moving: alphas["right_hand"] = 1.0
		# Both hands stay drawn while the watch shows, so the finger can find its keys.
		var watching: bool = wrist_watch != null and wrist_watch.visible
		if watching:
			for hand in ["left_hand", "right_hand"]: alphas[hand] = 1.0
		input_visuals.update_visibility(focused, alphas, feedback_visible or watching)

func _menu_pointer_owned(menu: Node3D, hand: String) -> bool:
	if menu == null: return false
	if menu==photo_menu and photo_menu.online.hand==hand: return true
	if menu is PlayerMenu:
		if hand in [menu._seek_hand, menu._volume_hand, menu._depth_hand, menu._adjust_hand] or menu.choices.capture.get("hand", "") == hand or menu.bookmarks.capture.get("hand", "") == hand: return true
		return menu.has_expanded_library() and _menu_pointer_owned(menu.expanded_library, hand)
	if menu is LibraryMenu:
		return menu._drag.get("hand", "") == hand or menu.choices.capture.get("hand", "") == hand or menu.account_panel.web_hand == hand or menu.server_browser.gallery.capture.get("hand", "") == hand
	return false

## A ray near a flat screen corner shows its bracket: pressing there resizes.
func _update_corner_hover() -> void:
	if not photo_active and video and video.get("pip") and video.pip.blocked():
		video.set_corner_hover(-1); return
	if _cinema_scene_active() and not photo_active:
		if video: video.set_corner_hover(-1)
		return
	if photo_active and photo.gallery.overview():
		photo.set_corner_hover(-1); return
	if not video or not _viewer().has_method("corner_at"):
		return
	if not _input_feedback_visible():
		_viewer().set_corner_hover(-1); return
	var corner := -1
	if _grab.has("resize"):
		corner = int(_grab.resize.corner)
	elif _grab.is_empty() and interface_move.capture.is_empty() and not recent_menu.visible and not _viewer().local_uri.is_empty() and not (photo_active and photo.inspect):
		for hand in ["right_hand", "left_hand"]:
			if _is_photo_hand(hand): continue
			var ray: Variant = _ray(hand)
			if ray != null and not (player_menu.visible and player_menu._hover.get(hand, -1) != -1):
				if not photo_active and video.get("pip") and not video.pip.hit(ray[0], ray[1]).is_empty(): continue
				corner = _viewer().corner_at(ray[0], ray[1])
				if corner >= 0:
					break
	_viewer().set_corner_hover(corner)

func _try_corner_resize(hand: String) -> bool:
	if _cinema_video_locked(): return false
	if not _grab.is_empty() or not interface_move.capture.is_empty() or not _has_open_media(): return false
	if _viewer().geometry != Geometry.Geometry.FLAT or (photo_active and (photo.inspect or photo.gallery.overview())): return false
	var menu := _active_menu()
	if not menu or menu != player_menu or photo_active or not player_menu.allows_playback_sticks(): return false
	var ray: Variant = _ray(hand)
	if ray == null or _viewer().corner_at(ray[0], ray[1]) < 0: return false
	_begin_grab(hand, true)
	if not _grab.has("resize"): return false
	_grab["resize_only"] = true
	_video_control_tap.clear(); stick_controls.suspend()
	return true

func _begin_grab(hand: String, keep_controls: bool = false) -> void:
	if not _grab.is_empty() or (photo_active and photo.inspect): return
	if view_follow.enabled and _head_pose() == null: return
	var ray: Variant = _ray(hand)
	if ray == null:
		if player_menu.visible:
			player_menu.dismiss()
		return
	var angles := _ray_angles(ray[1])
	_grab = {"hand": hand, "start": angles, "last": angles, "moved": false,
		"start_direction": ray[1], "last_direction": ray[1]}
	if _is_photo_hand(hand) or (photo_active and photo.gallery.overview()):
		_grab["tap_only"] = true
		return
	var corner: int = _viewer().corner_at(ray[0], ray[1])
	var point: Variant = _viewer().screen_point(ray[0], ray[1]) if corner >= 0 else null
	if point != null and Vector2(point.x, point.y).length() > 0.05:
		_grab["resize"] = {"corner": corner, "start_length": Vector2(point.x, point.y).length(), "start_scale": _viewer().screen_scale}
		if not photo_active and video.cinema.active(video):
			_grab.resize["cinema_anchor"] = video.cinema.content_bottom(video)
			var anchor: Transform3D = _grab.resize.cinema_anchor
			var denominator: float = ray[1].dot(anchor.basis.z)
			if absf(denominator) > 0.00001:
				_grab.resize["cinema_vector"] = ray[0] + ray[1] * ((anchor.origin - ray[0]).dot(anchor.basis.z) / denominator) - anchor.origin
			else: _grab.erase("resize")
	# A deliberate screen press leaves the controls before sticks may affect playback.
	# Remember this on release so a tap does not immediately reopen the controls.
	if not keep_controls and not photo_active and _viewer().geometry == Geometry.Geometry.FLAT and _viewer().panel.visible and player_menu.visible:
		if point == null: point = _viewer().screen_point(ray[0], ray[1])
		if point != null and (corner >= 0 or (absf(point.x) <= _viewer()._flat.size.x / 2 and absf(point.y) <= _viewer()._flat.size.y / 2)):
			_grab["hid_menu"] = true
			player_menu.dismiss()

func _update_grab() -> void:
	if _grab.is_empty():
		return
	if view_follow.enabled and _head_pose() == null:
		_grab.clear()
		return
	if _grab.get("tap_only", false): return
	var ray: Variant = _ray(_grab.hand)
	if ray == null \
		or not video or _viewer().local_uri.is_empty() or recent_menu.visible:
		_grab = {}
		return
	if _grab.has("inspect"):
		photo.inspect_ray(ray[0], ray[1], true)
		return
	var angles := _ray_angles(ray[1])
	var head: Variant = _head_pose()
	var local_drag: bool = view_follow.enabled and _flat_followable(_viewer()) and head != null
	if local_drag:
		angles = _ray_angles(head.basis.inverse() * ray[1])
	if not _grab.moved:
		var start_angles: Vector2 = _ray_angles(head.basis.inverse() * _grab.start_direction) if local_drag else _grab.start
		var turned: Vector2 = angles - start_angles
		turned.x = wrapf(turned.x, -PI, PI)
		if turned.length() < GRAB_START:
			return
		_grab.moved = true
	if _grab.has("resize"):
		if _grab.resize.has("cinema_anchor"):
			var anchor: Transform3D = _grab.resize.cinema_anchor
			var normal := anchor.basis.z
			var denominator: float = ray[1].dot(normal)
			if absf(denominator) > 0.00001:
				var t: float = (anchor.origin - ray[0]).dot(normal) / denominator
				if t > 0:
					var vector: Vector3 = _grab.resize.cinema_vector
					video.set_screen_scale(float(_grab.resize.start_scale) * maxf(0.0, (ray[0] + ray[1] * t - anchor.origin).dot(vector) / vector.length_squared()))
			return
		# The corner follows the ray: the screen grows or shrinks about its centre.
		var point: Variant = _viewer().screen_point(ray[0], ray[1])
		if point != null:
			_viewer().set_screen_scale(float(_grab.resize.start_scale) * Vector2(point.x, point.y).length() / float(_grab.resize.start_length))
		return
	var last_angles: Vector2 = _ray_angles(head.basis.inverse() * _grab.last_direction) if local_drag else _grab.last
	var step: Vector2 = angles - last_angles
	_grab.last = angles
	_grab.last_direction = ray[1]
	_turn_picture(wrapf(step.x, -PI, PI), step.y)

## Yaw (positive left) and pitch (positive up) of a direction.
static func _ray_angles(direction: Vector3) -> Vector2:
	var unit := direction.normalized()
	return Vector2(atan2(-unit.x, -unit.z), asin(clampf(unit.y, -1.0, 1.0)))

## The picture follows the pointer: immersive views turn, the flat screen moves around the head
## at its distance and keeps facing the eyes.
func _turn_picture(yaw: float, pitch: float) -> void:
	if _cinema_video_locked() and video.geometry == Geometry.Geometry.FLAT: return
	if photo_active and photo.inspect: return
	if not photo_active and video.cinema.active(video):
		var pose: Transform3D = video.global_transform * video.flat_pose
		pose.origin += pose.basis.x * (-yaw * video.screen_distance) + Vector3.UP * pitch * video.screen_distance
		video.set_flat_world_pose(pose)
		return
	if view_follow.enabled and _head_pose() == null: return
	if is_zero_approx(yaw) and is_zero_approx(pitch): return
	if _viewer().geometry != Geometry.Geometry.FLAT:
		_viewer().turn_view(yaw, pitch)
		return
	var head: Variant = _head_pose()
	if view_follow.enabled and _flat_followable(_viewer()) and head != null:
		var local: Transform3D = head.affine_inverse() * (_viewer().global_transform * _viewer().flat_pose)
		var offset := local.origin
		if offset.length() < 0.1: return
		var angles := _ray_angles(offset) + Vector2(yaw, pitch)
		var direction := (Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.5, 1.5))) * Vector3.FORWARD
		local.basis = Basis(Quaternion(offset.normalized(), direction)) * local.basis
		local.origin = direction * offset.length()
		_viewer().set_flat_world_pose(head * local)
		_capture_follow_screen(_viewer(), head)
		return
	var eye := _eye()
	var offset: Vector3 = (_viewer().global_transform * _viewer().flat_pose).origin - eye
	var distance := offset.length()
	if distance < 0.1:
		return
	var angles := _ray_angles(offset) + Vector2(yaw, pitch)
	var facing := Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.3, 1.3))
	var pose := Transform3D(facing, eye + facing * Vector3(0, 0, -distance))
	if photo_active:
		photo.set_flat_world_pose(pose)
	else:
		_viewer().flat_pose = _viewer().global_transform.affine_inverse() * pose
		_viewer()._apply_geometry()
	_capture_follow_screen(_viewer(), head)

## The flat screen nearer (negative) or farther along the line from the eyes, still facing them.
func _push_screen(amount: float) -> void:
	if _cinema_video_locked(): return
	if not photo_active and video.cinema.active(video):
		video.cinema.push(video, _eye(), amount)
		return
	if view_follow.enabled and _head_pose() == null: return
	var eye := _eye()
	var world: Transform3D = _viewer().global_transform * _viewer().flat_pose
	var offset: Vector3 = world.origin - eye
	if offset.length() < 0.1:
		return
	_viewer().set_screen_distance(offset.length() + amount)
	var pose := Transform3D(world.basis, eye + offset.normalized() * _viewer().screen_distance)
	_viewer().set_flat_world_pose(pose)
	_capture_follow_screen(_viewer(), _head_pose())
	if photo_active and photo.gallery.focus >= 0:
		photo.gallery.remember_focus_pose(photo.global_transform * photo.flat_pose)

## Explicit defaults are separate from the last viewing state written by gestures and sliders.
func _surface_distance(surface: Node3D) -> float:
	if surface == video and video.cinema.active(video): return video.cinema.distance(video, _eye())
	return (surface.global_transform * surface.flat_pose).origin.distance_to(_eye())

func _cinema_default(key: String = "default_cinema") -> Dictionary:
	var value: Variant = settings.get_value("screen", key, {})
	if not value is Dictionary: return {"enabled": false, "height": -0.5, "preset": ""}
	var height_value: Variant = value.get("height", -0.5)
	var height := float(height_value) if (height_value is float or height_value is int) and is_finite(float(height_value)) else -0.5
	var preset := str(value.get("preset", ""))
	if ScreenPresets.find(preset).is_empty(): preset = ""
	return {"enabled": value.get("enabled", false) == true, "height": clampf(height, -30, 30), "preset": preset}

func _apply_screen_preset(id: String) -> void:
	if _cinema_video_locked(): return
	if photo_active or not video or video.local_uri.is_empty() or video.geometry != Geometry.Geometry.FLAT: return
	var preset: Dictionary = ScreenPresets.find(id)
	var head: Variant = _head_pose()
	if preset.is_empty() or not head is Transform3D: return
	_finish_flat_zoom()
	_set_cinema_mode(true)
	video.screen_preset = id
	video.set_screen_curve(0.0)
	video._apply_geometry()
	video.set_screen_distance(preset.distance)
	# A preset establishes a new seat; manual resizing afterwards retains the bottom anchor.
	video.cinema.height = -preset.size.y * preset.eye_level
	video.cinema.recenter(video, head)
	_cinema_adjusting = false
	_save_screen()

func _active_screen_preset() -> String:
	var preset: Dictionary = ScreenPresets.find(video.screen_preset)
	if preset.is_empty() or not video.cinema.active(video) or video.screen_curve != 0: return ""
	if not is_equal_approx(_surface_distance(video), float(preset.distance)): return ""
	if not is_equal_approx(video.cinema.eye_level(video, _eye()), float(preset.eye_level)): return ""
	return video.screen_preset

func _set_cinema_mode(enabled: bool) -> void:
	if _cinema_scene_active(): return
	if photo_active or not video or video.geometry != Geometry.Geometry.FLAT: return
	interface_move.cancel(); _grab.clear(); stick_controls.suspend()
	var leaving: bool = video.cinema.enabled and not enabled
	# Cinema measures depth to the plane; its elevated centre is farther from the eyes.
	var distance: float = _surface_distance(video)
	if enabled and view_follow.enabled: _on_session_control("follow")
	interface_move.placements.erase(&"video"); view_follow.forget(&"video")
	video.cinema.configure(video, enabled, _head_pose())
	video.set_screen_distance(clampf(distance, video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y))
	if leaving: _place_screen(true)

func _flat_video_is_default() -> bool:
	if not settings.has_section_key("screen", "default_view"): return false
	var distance: float = _surface_distance(video) if video.cinema.active(video) else video.screen_distance
	if not Vector2(distance, video.screen_scale).is_equal_approx(_flat_video_defaults()): return false
	var saved := _cinema_default()
	if video.cinema.enabled != saved.enabled: return false
	if video.screen_preset != saved.preset: return false
	return not saved.enabled or (video.cinema.bottom is Transform3D and is_equal_approx(video.cinema.bottom.origin.y - _eye().y, saved.height))

func _flat_video_defaults() -> Vector2:
	var value: Variant = settings.get_value("screen", "default_view", Vector2(video.SCREEN_DISTANCE, 1.0))
	if not value is Vector2 or not value.is_finite(): return Vector2(video.SCREEN_DISTANCE, 1.0)
	var preset := str(_cinema_default().preset)
	if not preset.is_empty(): value.y = ScreenPresets.scale_for(preset, video._screen_base)
	return Vector2(clampf(value.x, video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y),
		clampf(value.y, video.SCALE_LIMITS.x, video.SCALE_LIMITS.y))

func _restore_flat_video_settings() -> void:
	# Keep legacy viewing state until the user explicitly saves a default; never infer intent from it.
	var value := _flat_video_defaults()
	if not settings.has_section_key("screen", "default_view"):
		value = Vector2(float(settings.get_value("screen", "distance", video.SCREEN_DISTANCE)),
			float(settings.get_value("screen", "scale", 1.0)))
		if not value.is_finite(): value = Vector2(video.SCREEN_DISTANCE, 1.0)
	video.screen_distance = clampf(value.x, video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y)
	video.screen_scale = clampf(value.y, video.SCALE_LIMITS.x, video.SCALE_LIMITS.y)
	var saved := _cinema_default("default_cinema" if settings.has_section_key("screen", "default_view") else "cinema")
	video.cinema.enabled = saved.enabled
	video.cinema.height = saved.height
	video.cinema.placed = false
	video.screen_preset = saved.preset

func _current_cinema_state() -> Dictionary:
	var height: float = video.cinema.bottom.origin.y - _eye().y if video.cinema.active(video) and video.cinema.bottom is Transform3D else video.cinema.height
	return {"enabled": video.cinema.enabled, "height": height, "preset": video.screen_preset}

func _cinema_video_locked() -> bool:
	return not photo_active and (not _cinema_screen_saved.is_empty() or
		(CinemaFeature.enabled() and background != null and background.choice == "cinema"))

func _set_screen_preference(key: String, value: Variant) -> void:
	# Last write boundary also covers a photo/context switch before screen restoration.
	if not _cinema_screen_saved.is_empty() or _cinema_video_locked(): return
	settings.set_value("screen", key, value)

func _remember_current_screen() -> void:
	if _cinema_video_locked(): return
	_set_screen_preference("distance", video.screen_distance)
	_set_screen_preference("scale", video.screen_scale)
	if video.geometry == Geometry.Geometry.FLAT:
		var cinema := _current_cinema_state()
		video.cinema.height = cinema.height
		_set_screen_preference("cinema", cinema)

func _save_flat_video_defaults(locked: bool = true) -> void:
	if _cinema_video_locked(): return
	if photo_active or not video or video.local_uri.is_empty() or video.geometry != Geometry.Geometry.FLAT: return
	var value := Vector2(_surface_distance(video) if video.cinema.active(video) else video.screen_distance, video.screen_scale)
	if not value.is_finite() or value.x < video.DISTANCE_LIMITS.x - 0.0001 or value.x > video.DISTANCE_LIMITS.y + 0.0001: return
	value.x = clampf(value.x, video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y)
	var previous := {}
	for key in ["default_view", "default_cinema", "distance", "scale", "cinema"]:
		if settings.has_section_key("screen", key): previous[key] = settings.get_value("screen", key)
	var cinema := _current_cinema_state()
	if locked:
		_set_screen_preference("default_view", value)
		_set_screen_preference("default_cinema", cinema)
	else:
		for key in ["default_view", "default_cinema"]:
			if settings.has_section_key("screen", key): settings.erase_section_key("screen", key)
	# Switching back to automatic must survive restart without resurrecting the old lock.
	_set_screen_preference("distance", value.x)
	_set_screen_preference("scale", value.y)
	_set_screen_preference("cinema", cinema)
	var error := settings.save(settings_path)
	if error != OK:
		for key in ["default_view", "default_cinema", "distance", "scale", "cinema"]:
			if previous.has(key): _set_screen_preference(key, previous[key])
			elif settings.has_section_key("screen", key): settings.erase_section_key("screen", key)
		Log.record("screen_default_save_failed", {"error": error})
	else: video.cinema.height = cinema.height

func _save_screen() -> void:
	if _cinema_video_locked(): return
	if photo_active:
		_save_photo_adjustments()
		return
	_remember_current_screen()
	_set_screen_preference("curve", video.screen_curve)
	settings.save(settings_path)

func _zoom_video(amount: float, hand: String = "right_hand") -> void:
	if _cinema_video_locked() and video.geometry == Geometry.Geometry.FLAT: return
	_cinema_adjusting = true
	if video.geometry == Geometry.Geometry.FLAT:
		video.set_screen_scale(video.screen_scale * exp(amount))
		_set_screen_preference("scale", video.screen_scale)
		_flat_zoom_hand = hand
	else: video.zoom_view(amount)

func _finish_flat_zoom() -> void:
	if _flat_zoom_hand.is_empty(): return
	# Commit the last scaled video's value, even if another media is now displayed.
	_remember_current_screen()
	settings.save(settings_path); _flat_zoom_hand = ""

## Right stick press: the picture back at its natural size and distance (the curve stays). It stays
## where it is: only the menu's recenter button brings the screen in front of the head again.
func _reset_picture() -> void:
	if _cinema_video_locked() and video.geometry != Geometry.Geometry.FLAT:
		video.reset_view(); return
	if _cinema_video_locked(): return
	_viewer().reset_view()
	_viewer().set_screen_scale(1.0)
	var offset: Vector3 = (_viewer().global_transform * _viewer().flat_pose).origin - _eye()
	var distance: float = photo.DEFAULT_DISTANCE if photo_active else video.SCREEN_DISTANCE
	if _viewer().geometry == Geometry.Geometry.FLAT and offset.length() >= 0.1:
		_push_screen(distance - _surface_distance(_viewer()))
	_viewer().set_screen_distance(distance)
	_save_screen()

func _update_menu_pointer(hand: String, pressed: bool = false) -> bool:
	var menu := _active_menu()
	if not menu or hand not in ["left_hand", "right_hand"]:
		return false
	var ray: Variant = _ray(hand)
	var tracked := ray != null
	var origin: Vector3 = ray[0] if tracked else Vector3.ZERO
	var direction: Vector3 = ray[1] if tracked else Vector3.ZERO
	if not pressed and capture_overlay and capture_overlay.visible and not menu.has_pointer_capture() and tracked \
		and not capture_overlay.pointer_hit(origin, direction).is_empty():
		menu.update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
		return true
	if pressed:
		_menu_touched_ms = Time.get_ticks_msec()
		var handled: bool = menu.press_pointer(hand, origin, direction, tracked)
		if menu != player_menu or photo_active or not player_menu.allows_playback_sticks():
			stick_controls.suspend()
		return handled
	if not interface_move.capture.is_empty():
		# Clear normal hover and child-browser rays, then draw only the owning grip's anchor.
		menu.update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
		if hand == interface_move.capture.hand:
			menu.update_move_pointer(hand, origin, interface_move.capture.anchor, tracked)
		return true
	menu.update_pointer(hand, origin, direction, tracked)
	return true

func _on_pip_zoom_changed(slot: int, zoom: float) -> void:
	settings.set_value("pip", "zoom_%d" % slot, zoom)
	settings.save(settings_path)

func _pip_pointer_press(action: String, hand: String) -> bool:
	if photo_active or not video or not video.get("pip") or not video.pip.active() or not _input_focused(): return false
	if not _grab.is_empty() or not interface_move.capture.is_empty(): return false
	if video.pip.capturing():
		video.pip.press(hand, action, _ray(hand), _pip_move_pose(hand), _head_pose(), _pip_hand_pointer(hand))
		stick_controls.suspend(); return true
	var menu := _active_menu()
	if _menu_captured(menu): return false
	var ray: Variant = _ray(hand)
	if action not in ["by_button", "menu_button"] and menu:
		if menu != player_menu or not player_menu.allows_pip_input(): return false
		if ray != null and not menu.ray_hit(ray[0], ray[1]).is_empty(): return false
	if video.pip.press(hand, action, ray, _pip_move_pose(hand), _head_pose(), _pip_hand_pointer(hand)):
		_video_control_tap.clear(); stick_controls.suspend(); return true
	return false

func _pip_hand_pointer(hand: String) -> bool:
	return hand_pointers.has(hand) and hand_pointers[hand].source == "hand"

func _pip_move_pose(hand: String) -> Variant:
	if not _pip_hand_pointer(hand): return _move_pose(hand)
	# Reuse the validated/stabilized ray for Meta aim, hand profiles and joint fallback.
	# No controller grip or optional joint stream is required in hand mode.
	var ray: Variant = _ray(hand)
	if ray == null or not ray[0].is_finite() or not ray[1].is_finite() or ray[1].length_squared() < 0.00001: return null
	var direction: Vector3 = ray[1].normalized()
	var up := Vector3.RIGHT if absf(direction.dot(Vector3.UP)) > 0.999 else Vector3.UP
	return Transform3D(Basis.looking_at(direction, up), ray[0])

func _update_pip_input() -> void:
	if not video or not video.get("pip") or not video.pip.active(): return
	var rays := {}; var poses := {}
	var menu := _active_menu()
	video.pip.identify(player_menu.pip_controls.hovered_slots() if menu == player_menu and player_menu and not photo_active and _input_focused() else [])
	var enabled: bool = not photo_active and _input_focused() and _grab.is_empty() and interface_move.capture.is_empty() \
		and (menu == null or (menu == player_menu and player_menu.allows_pip_input()))
	if not enabled: video.pip.cancel_interaction()
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = _ray(hand) if enabled else null
		if menu and ray != null and not menu.ray_hit(ray[0], ray[1]).is_empty() and video.pip.resize.is_empty() and video.pip.movement.capture.is_empty(): ray = null
		rays[hand] = ray; poses[hand] = _pip_move_pose(hand) if enabled else null
	video.pip.update_input(rays, poses, _head_pose(), Time.get_ticks_msec())

func _capture_pointer_press(hand: String) -> bool:
	if not capture_overlay or not capture_overlay.visible or not _input_focused(): return false
	var menu := _active_menu()
	if menu and menu.has_pointer_capture(): return false
	if not interface_move.capture.is_empty(): return false
	var ray: Variant = _ray(hand)
	if ray == null: return false
	if capture_overlay.pointer_hit(ray[0], ray[1]).is_empty(): return false
	capture_overlay.press_pointer(hand, ray[0], ray[1], true)
	return true

func _on_capture_saved(result: Dictionary) -> void:
	if not recent_menu or recent_menu.section != recent_menu.Section.LOCAL: return
	var directory := str(result.get("directory", ""))
	var path: String = recent_menu._local_path().trim_suffix("/")
	if directory.is_empty() or not (path.ends_with("/" + directory) or path.ends_with("/" + directory.get_base_dir())): return
	# File lists are snapshots. Refresh an already open destination after atomic publication.
	recent_menu._load_section()

const CONTROLS_HIDE_MS := int(ControllerFeedback.IDLE_SECONDS * 1000.0)
var _menu_touched_ms := 0
var _bar_appearance_return := false

func _toggle_controls_lock() -> void:
	if not player_menu: return
	interface_move.cancel(); _grab.clear(); stick_controls.suspend()
	var locked: bool = player_menu.get_meta("space_locked", false)
	player_menu.set_meta("space_locked", not locked)
	if not locked:
		player_menu.set_meta("space_pose", player_menu.global_transform)
		player_menu.set_meta("space_head", _head_pose())
	else:
		var head: Variant = _head_pose()
		if head is Transform3D:
			interface_move.placements[_menu_key(player_menu)] = InterfaceMove.menu_head(head, view_follow.enabled).affine_inverse() * player_menu.global_transform
			view_follow.capture(_menu_key(player_menu), head, player_menu.global_transform)
	player_menu.refresh()

func _clear_controls_locks() -> void:
	for menu in [video_menu, photo_menu]:
		if menu:
			var changed: bool = menu.get_meta("space_locked", false)
			menu.set_meta("space_locked", false)
			if menu.has_meta("space_pose"): menu.remove_meta("space_pose")
			if menu.has_meta("space_head"): menu.remove_meta("space_head")
			if changed and menu.visible: menu.refresh()

func _set_bar_transparency(value: float) -> void:
	if not is_finite(value): return
	value = clampf(value, 0, 80)
	settings.set_value("ui", "bar_transparency", value)
	for menu in [video_menu, photo_menu]:
		if menu: menu.set_bar_transparency(value)

func _open_bar_appearance() -> void:
	_bar_appearance_return = true
	if recent_menu: recent_menu.dismiss()
	_show_player_menu()
	player_menu.show_bar_appearance()

func _finish_bar_appearance() -> void:
	settings.save(settings_path)
	if not _bar_appearance_return: return
	_bar_appearance_return = false
	_show_full_library()
	recent_menu.section = recent_menu.Section.SETTINGS
	recent_menu.tab = recent_menu.DISPLAY_TAB
	recent_menu.refresh()

func _viewer() -> Node3D:
	return photo if photo_active and photo else video

func _prepare_cast_switch() -> void:
	_clear_controls_locks()
	_grab.clear(); interface_move.cancel(); stick_controls.suspend()
	photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel()

func _on_library_chosen(uri: String, title: String, retained_photo: Dictionary = {}) -> void:
	if preload("res://scripts/archive_panel.gd").named(uri, title):
		recent_menu.show(); recent_menu.archives.open({"uri":uri,"title":title}); return
	cast_session.local_selection()
	if video_directory: video_directory.cancel()
	if puzzle_game and puzzle_game.active:
		puzzle_game.finish()
		if puzzle_game.active: return
	_cancel_video_queue_wait()
	var controls_pose: Variant = recent_menu.get_parent().global_transform if _library_is_attached() else null
	if recent_menu is LibraryMenu: recent_menu.playback_expanded = false
	var location: Dictionary = recent_menu.collections.selected_location.duplicate(true)
	if location.is_empty() or not retained_photo.is_empty(): location = MediaLocation.infer(uri)
	if title.get_extension().to_lower() == "strm": Privacy.sources[uri] = false
	video.source_location = location; photo.source_location = location
	var is_comic := uri.begins_with("comic://")
	var is_photo: bool = is_comic or ImageInfo.is_image(uri, title) or recent_menu.is_image_uri(uri)
	var directory_context: Dictionary = recent_menu.photo_directory_context() if is_photo and not is_comic and retained_photo.is_empty() else {}
	if is_photo and retained_photo.is_empty() and recent_menu._playback_context.get("uri", "") == uri:
		directory_context = recent_menu._playback_context.get("photo_directory", {}).duplicate(true)
	video_queue_pages.platform = video.platform
	if is_comic: video_queue_pages.cancel(); video_queue_pages.context = {}
	else: video_queue_pages.capture(recent_menu, uri)
	recent_menu.dismiss()
	if player_menu: player_menu.dismiss()
	_grab = {}
	stick_controls.suspend()
	if is_photo:
		video.close_video()
		photo_active = true
		player_menu = photo_menu
		_photo_open_hide_controls = not (controls_pose is Transform3D) and hand_pointers.values().any(func(pointer): return pointer.source == "hand")
		var image_queue: Array[Dictionary] = []
		if is_comic: image_queue.assign(recent_menu.archives.image_queue())
		elif recent_menu.section == recent_menu.Section.RECENT or not retained_photo.is_empty(): image_queue.append({"uri": uri, "title": title, "kind": "image"})
		else: image_queue.assign(recent_menu.image_queue())
		if not retained_photo.is_empty(): photo.set_layout_mode(0)
		photo.open_image(uri, title, image_queue, location, retained_photo)
		if is_comic:
			photo.archive_origin = str(recent_menu.archives.target.get("uri", ""))
			photo.archive_browser_session = recent_menu.archives.browsing
		photo.start_directory(directory_context)
		_show_player_menu()
	else:
		_photo_open_hide_controls = false
		photo.close_image()
		photo_active = false
		player_menu = video_menu
		video_queue.clear()
		video_queue.assign(recent_menu.video_queue())
		var metadata: Dictionary = recent_menu.server_browser.selection.duplicate(true) if uri.begins_with("medialib://") else {}
		if not uri.begins_with("medialib://"):
			for row in recent_menu.rows:
				if str(row.get("uri", "")) == uri: metadata = row.duplicate(true); break
		recent_menu.server_browser.selection = {}
		if metadata.get("uri", "") != uri: metadata = {}
		metadata.location = location
		if video.open_library(uri, title, metadata): _show_player_menu()
		var context: Dictionary = recent_menu._playback_context.get("photo_directory", {}) if recent_menu._playback_context.get("uri", "") == uri else recent_menu.photo_directory_context()
		if not context.is_empty(): _start_video_directory(context)
	if controls_pose is Transform3D and not player_menu.space_locked() and not (_cinema_scene_active() and player_menu == video_menu):
		player_menu.global_transform = controls_pose
		var head: Variant = _head_pose()
		if head is Transform3D:
			player_menu.set_layout_viewer(head, view_follow.enabled, false)
			view_follow.capture(_menu_key(player_menu), head, controls_pose)
			interface_move.placements[_menu_key(player_menu)] = InterfaceMove.menu_head(head, view_follow.enabled).affine_inverse() * controls_pose

func _on_file_renamed(old_uri: String, new_uri: String, title: String) -> void:
	var target: Dictionary = recent_menu.file_actions.target
	var known: Array = video.recent_files.list_recent() + video_queue + target.get("affected_media", []) + recent_menu._local_entries + recent_menu._smb_entries + recent_menu._cloud_entries
	var mappings := []
	if target.get("folder", false):
		var prefix := old_uri.trim_suffix("/") + "/"
		var seen := {}
		for item in known:
			var uri := str(item.get("uri", ""))
			if not uri.begins_with(prefix) or seen.has(uri): continue
			seen[uri] = true
			mappings.append({"old": uri, "new": new_uri.trim_suffix("/") + "/" + uri.substr(prefix.length()),
				"title": str(item.get("title", uri.get_file().uri_decode())), "size": int(item.get("size", -1))})
	else:
		mappings.append({"old":old_uri, "new":new_uri, "title":title, "size":int(target.get("size", -1))})
		for move in recent_menu.file_actions.rename.moves:
			var from := str(move.get("old_uri", old_uri.get_base_dir() + "/" + str(move.from).uri_encode()))
			if from == old_uri: continue
			var size := int(move.get("size", -1))
			for item in known:
				if str(item.get("uri", "")) == from and int(item.get("size", -1)) >= 0: size = int(item.size); break
			mappings.append({"old":from, "new":str(move.get("new_uri", new_uri.get_base_dir() + "/" + str(move.to).uri_encode())), "title":str(move.to), "size":size})
	for item in mappings: _relocate_file_records(item.old, item.new, item.title, item.size)
	_update_thumbnail_protection()

func _relocate_file_records(old_uri: String, new_uri: String, title: String, size: int) -> void:
	if favorites: favorites.relocate(old_uri, new_uri, title)
	video.recent_files.relocate(old_uri, new_uri, title)
	if not video.recent_files.save(): recent_menu.file_actions.rename.migration_failed = true
	video.mode_memory.relocate(old_uri, new_uri)
	if not video.mode_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	video.track_memory.relocate(old_uri, new_uri)
	if not video.track_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	video.whisper_memory.relocate(old_uri, new_uri)
	if not video.whisper_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	video.subtitle_timing.relocate(old_uri, new_uri)
	if not video.subtitle_timing.save(): recent_menu.file_actions.rename.migration_failed = true
	video.narration.memory.relocate(old_uri, new_uri)
	if not video.narration.memory.save(): recent_menu.file_actions.rename.migration_failed = true
	photo.mode_memory.relocate(old_uri, new_uri)
	if not photo.mode_memory.save(): recent_menu.file_actions.rename.migration_failed = true
	if not video.bookmark_store.relocate(old_uri, new_uri, title, size): recent_menu.file_actions.rename.migration_failed = true
	LibraryMenu.Thumbnails.relocate(old_uri, new_uri)
	for item in video_queue:
		if str(item.get("uri", "")) == old_uri: item.uri = new_uri; item.title = title; item.erase("metadata")
	_update_thumbnail_protection()

func _prepare_file_delete(uri: String) -> void:
	# Retain known child identities before closing readers clears their queues.
	if recent_menu and recent_menu.file_actions.modal == "rename" and recent_menu.file_actions.target.get("folder", false):
		var known: Array = video.recent_files.list_recent() + video_queue + photo.queue
		for surface in [video, photo]:
			if not surface.local_uri.is_empty(): known.append({"uri":surface.local_uri, "title":surface.local_uri.get_file().uri_decode(), "size":-1})
		recent_menu.file_actions.target["affected_media"] = known.duplicate(true)
	if video.local_uri == uri or video.local_uri.begins_with(uri.trim_suffix("/") + "/"): video.close_video()
	if photo.local_uri == uri or photo.local_uri.begins_with(uri.trim_suffix("/") + "/") or photo.queue.any(func(item): return str(item.get("uri", "")) == uri or str(item.get("uri", "")).begins_with(uri.trim_suffix("/") + "/")):
		photo.close_image(); photo_active = false
		if photo_menu: photo_menu.dismiss()
		player_menu = video_menu
	_grab = {}; stick_controls.suspend()

func _forget_deleted_file(uri: String) -> void:
	video_queue = video_queue.filter(func(item): return str(item.get("uri", "")) != uri and not str(item.get("uri", "")).begins_with(uri.trim_suffix("/") + "/"))
	# Photo preload readers must be released before removing a queued image.
	if photo.queue.any(func(item): return str(item.get("uri", "")) == uri):
		photo.close_image(); photo_active = false; player_menu = video_menu
	for entry in video.recent_files.list_recent():
		if str(entry.uri) == uri or str(entry.uri).begins_with(uri.trim_suffix("/") + "/"): video.recent_files.forget(str(entry.uri))
	video.recent_files.save()
	_update_thumbnail_protection()

func _on_storage_eject_requested(volume: Dictionary) -> void:
	_release_storage_readers(volume)
	recent_menu.stop_storage(volume)

func _release_storage_readers(volume: Dictionary) -> void:
	if video and StorageVolume.contains_uri(volume,video.local_uri): video.close_video()
	video_queue = video_queue.filter(func(item): return not StorageVolume.contains_uri(volume,str(item.get("uri",""))))
	if photo and photo.release_storage(volume):
		photo_active = false
		if photo_menu: photo_menu.dismiss()
		player_menu = video_menu
	_grab = {}; stick_controls.suspend()

func _adjacent_video(direction: int) -> Dictionary:
	if photo_active or not video or direction == 0 or (_video_directory_reorder and video_directory and video_directory.loading): return {}
	for index in video_queue.size():
		if str(video_queue[index].uri) != video.local_uri: continue
		var target := index + (1 if direction > 0 else -1)
		return video_queue[target] if target >= 0 and target < video_queue.size() else {}
	return {}

func _navigate_video(direction: int) -> void:
	_cancel_video_queue_wait()
	var item := _adjacent_video(direction)
	if item.is_empty():
		if direction > 0: _advance_video_queue(false)
		return
	_open_queued_video(item, false)

func _open_queued_video(item: Dictionary, automatic: bool) -> void:
	_grab = {}
	interface_move.cancel()
	stick_controls.suspend()
	_menu_touched_ms = Time.get_ticks_msec()
	video.open_library(str(item.uri), str(item.title), item.get("metadata", {}), automatic)
	if player_menu and player_menu.visible: player_menu.refresh()

func _set_playback_mode(value: String) -> void:
	if value not in PLAYBACK_MODES: return
	if video and video.cast_token > 0:
		if not video.cast_allows(value): return
		playback_mode = value; video.loop_enabled = value == "repeat_one"; video.changed.emit(); return
	_cancel_video_queue_wait()
	playback_mode = value
	video.loop_enabled = value == "repeat_one"
	settings.set_value("video", "playback_mode", value); settings.save(settings_path)
	video.changed.emit()

func _cycle_playback_mode() -> void:
	if video and video.cast_token > 0:
		_set_playback_mode("single" if playback_mode == "repeat_one" else "repeat_one"); return
	_set_playback_mode(PLAYBACK_MODES[(PLAYBACK_MODES.find(playback_mode) + 1) % PLAYBACK_MODES.size()])

func _on_video_completed() -> void:
	if cast_session.token > 0: return
	if photo_active or playback_mode not in ["sequence", "repeat_all"]: return
	_advance_completed_video.call_deferred(video.local_uri, video.media.session_id, video.control.sequence)

func _advance_completed_video(uri: String, session: int, sequence: int) -> void:
	if photo_active or playback_mode not in ["sequence", "repeat_all"] or video.local_uri != uri or video.media.session_id != session or video.control.sequence != sequence or not video.playback_end_ready():
		_pending_video_end.clear(); return
	var menu := _active_menu()
	if (menu and _menu_captured(menu)) or not _grab.is_empty() or not interface_move.capture.is_empty():
		_pending_video_end = {"uri": uri, "session": session, "sequence": sequence}; return
	_pending_video_end.clear()
	_advance_video_queue(true)

func _advance_video_queue(automatic: bool) -> void:
	if not _video_queue_wait.is_empty() or photo_active or video.local_uri.is_empty(): return
	if _video_directory_reorder and video_directory and video_directory.loading: return
	if not video_queue.any(func(row): return row.uri == video.local_uri): return
	var item := _adjacent_video(1)
	if not item.is_empty(): _open_queued_video(item, automatic); return
	var repeat_list := playback_mode == "repeat_all"
	if video_queue_pages.has_more() or (repeat_list and video_queue_pages.needs_first_page()):
		_video_queue_wait = {"uri": video.local_uri, "session": video.media.session_id, "sequence": video.control.sequence, "automatic": automatic, "page_context": video_queue_pages.context.duplicate(true)}
		video_queue_pages.start(not video_queue_pages.has_more())
	elif repeat_list and not video_queue.is_empty() and video_queue.any(func(row): return row.uri == video.local_uri):
		_open_queued_video(video_queue[0], automatic)

func _cancel_video_queue_wait() -> void:
	_pending_video_end.clear()
	if not _video_queue_wait.is_empty(): video_queue_pages.context = _video_queue_wait.page_context.duplicate(true)
	_video_queue_wait.clear()
	video_queue_pages.cancel()

func _valid_video_queue_wait() -> bool:
	return not _video_queue_wait.is_empty() and not photo_active and video.local_uri == _video_queue_wait.uri and video.media.session_id == _video_queue_wait.session and video.control.sequence == _video_queue_wait.sequence and (not _video_queue_wait.automatic or video.requested_play)

func _on_video_queue_page(items: Array[Dictionary], restart: bool) -> void:
	if not _valid_video_queue_wait(): _cancel_video_queue_wait(); return
	var automatic: bool = _video_queue_wait.automatic
	_video_queue_wait.clear()
	if restart: video_queue.clear()
	var existing := {}
	for row in video_queue: existing[str(row.uri)] = true
	var added: Array[Dictionary] = []
	for item in items:
		if not existing.has(str(item.uri)):
			existing[str(item.uri)] = true; added.append(item)
	if not items.is_empty() and added.is_empty(): _on_video_queue_failed("Unable to load next video"); return
	video_queue.append_array(added)
	if not added.is_empty(): _open_queued_video(added[0], automatic)
	elif playback_mode == "repeat_all" and not video_queue.is_empty():
		if video_queue_pages.needs_first_page(): _advance_video_queue(automatic)
		else: _open_queued_video(video_queue[0], automatic)

func _on_video_queue_failed(message: String) -> void:
	_video_queue_wait.clear()
	video.picker_error = message
	video.changed.emit()
	_on_video_playback_failed()

func _on_photo_changed() -> void:
	_update_favorite_session()
	if not photo_active: return
	var gallery_state := "%d/%s/%s" % [photo.gallery.mode, str(photo.gallery._scales), str(photo.gallery._distances)]
	if gallery_state != _gallery_saved_state:
		_gallery_saved_state = gallery_state; _gallery_save_after = Time.get_ticks_msec() + 450
	if _photo_open_hide_controls and not photo.loading and photo.panel.visible:
		_photo_open_hide_controls = false
		if photo.geometry == Geometry.Geometry.FLAT: photo_menu.dismiss()
	_update_thumbnail_protection()
	_update_background()
	if player_menu and player_menu.visible: player_menu.refresh_values()
	if calibration_board: calibration_board.visible = false

func _on_photo_adjustment(key: String, value: Variant) -> void:
	if key == "bar_transparency": _set_bar_transparency(float(value)); return
	if not photo_active or not is_finite(float(value)): return
	_menu_touched_ms = Time.get_ticks_msec()
	match key:
		"gallery_scale":
			photo.gallery.set_view_scale(float(value)); photo.changed.emit()
		"gallery_distance":
			photo.gallery.set_view_distance(float(value)); photo.changed.emit()
		"screen_distance":
			if photo.geometry != Geometry.Geometry.FLAT: return
			if photo.gallery.focus >= 0: photo.gallery.set_focus_distance(float(value))
			else: _push_screen(clampf(float(value), photo.PHOTO_DISTANCE_LIMITS.x, photo.PHOTO_DISTANCE_LIMITS.y) - (photo.global_transform * photo.flat_pose).origin.distance_to(_eye()))
			photo.changed.emit()
		"screen_scale":
			if photo.geometry != Geometry.Geometry.FLAT: return
			photo.set_screen_scale(float(value))
			photo.changed.emit()
		"inspect_magnification":
			photo.set_inspect_magnification(float(value))

func _save_photo_adjustments() -> void:
	settings.set_value("photo_screen", "distance", photo.screen_distance)
	settings.set_value("photo_screen", "scale", photo.screen_scale)
	settings.set_value("photo_screen", "curve", photo._portrait_curve if photo.portrait_requested else photo.screen_curve)
	settings.set_value("photo_screen", "magnification", photo.inspect_magnification)
	photo.gallery.save_settings(settings)
	_gallery_save_after = 0
	_gallery_saved_state = "%d/%s/%s" % [photo.gallery.mode, str(photo.gallery._scales), str(photo.gallery._distances)]
	settings.save(settings_path)

func _toggle_photo_inspect(hand: String = "") -> void:
	if not photo.panel.visible or photo.portrait_requested: return
	photo.gallery.cancel_all()
	if photo.inspect:
		_close_photo_inspect()
		return
	_grab = {}
	interface_move.cancel()
	photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
	_inspect_hand = hand if hand in ["left_hand", "right_hand"] else _photo_pointer_hand
	_inspect_desktop_ray = null
	photo.toggle_inspect()
	if player_menu: player_menu.dismiss()
	_update_photo_inspect()

func _close_photo_inspect(show_controls: bool = true) -> void:
	for hand in hand_pointers:
		if hand_pointers[hand].source == "hand" and hand_pointers[hand].down: _inspect_blocked[hand] = true
	_grab = {}
	interface_move.cancel()
	photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
	_inspect_hand = ""; _inspect_desktop_ray = null
	photo.close_inspect()
	if show_controls: _show_player_menu()

func _update_photo_inspect() -> void:
	if not photo_active or not photo.inspect or not _input_focused() or _active_menu():
		if photo: photo.hide_inspect_pointer()
		return
	if not interface_move.capture.is_empty() and interface_move.capture.targets.any(func(target): return target.kind == "detail"):
		photo.hide_inspect_pointer()
		return
	var ray: Variant = _ray(_inspect_hand) if _inspect_hand in ["left_hand", "right_hand"] else null
	if ray == null:
		for hand in ["right_hand", "left_hand"]:
			ray = _ray(hand)
			if ray != null:
				_inspect_hand = hand
				break
	if ray == null and display.preview: ray = _inspect_desktop_ray
	if ray == null:
		photo.hide_inspect_pointer()
	else:
		photo.update_inspect_pointer(ray[0], ray[1], _inspect_hand)

func _on_photo_action(operation: String) -> void:
	if operation == "space_lock": _toggle_controls_lock(); return
	if operation == "bar_appearance_done": _finish_bar_appearance(); return
	if operation=="save_pictures": photo.save_to_pictures(); photo_menu.refresh_values(); return
	if operation=="online_panoramas": _show_online_panoramas(); return
	if operation == "photo_puzzle":
		if puzzle_game: puzzle_game.open_hub()
		return
	if operation == "music_open": _show_music_management(true); return
	if operation == "music_toggle": background_audio.toggle_pause(); return
	if operation.begins_with("photo_wall_rows_"):
		_grab = {}; photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		photo.gallery.set_wall_rows(int(operation.trim_prefix("photo_wall_rows_")))
		photo.set_layout_mode(2); photo.changed.emit()
		_save_photo_adjustments()
		return
	if operation.begins_with("photo_layout_"):
		_grab = {}; photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		photo.set_layout_mode(int(operation.trim_prefix("photo_layout_")))
		_save_photo_adjustments()
		return
	_menu_touched_ms = Time.get_ticks_msec()
	match operation:
		"photo_shuffle":
			if photo.gallery.mode == 2: photo.gallery.change_batch(1)
			elif photo.gallery.shuffle_fragments(): Log.record("memory_shuffle", {"input": "menu"})
		"photo_spatial", "photo_spatial_on", "photo_static":
			_grab={}; photo_hands.cancel(); memory_swipe.cancel(); stick_controls.suspend()
			var enabled: bool=not photo.spatial_preferred if operation=="photo_spatial" else operation=="photo_spatial_on"
			if photo.set_spatial_mode(enabled,operation=="photo_static"):
				settings.set_value("photo","spatial_preferred",photo.spatial_preferred)
				settings.set_value("effects","auto_3d",photo.auto_depth)
				settings.save(settings_path)
		"photo_portrait":
			_grab = {}; photo_hands.cancel(); memory_swipe.cancel(); stick_controls.suspend()
			photo.set_portrait(not photo.portrait_requested)
		"photo_return":
			if photo.portrait_requested: photo.set_portrait(false)
			else: photo.gallery.return_focus()
		"photo_previous":
			photo.navigate(-1)
		"photo_next":
			photo.navigate(1)
		"photo_inspect": _toggle_photo_inspect()
		"photo_fit": _close_photo_inspect()
		"spatial_match_fov":
			if photo.match_spatial_fov(): _save_photo_adjustments()
		"stop": _close_current_media()
		"recenter": _recenter()
		"depth":
			if photo.set_depth(not photo.depth_requested): _remember_photo_auto_depth(photo.auto_depth)
		"depth_strength":
			_on_depth_strength(0.5 if photo.depth_strength>=photo.DepthStrength.PHOTO_MAX else photo.depth_strength+0.5,true)
			_save_depth_strength(true)
		"projection_0", "projection_1", "projection_2", "projection_3": photo.set_projection(int(operation.right(1)))
		"lock_mode":
			photo.toggle_mode_lock()
		"stereo_2d": _remember_photo_auto_depth(false); photo.set_depth(false); photo.set_stereo_layout(0)
		"stereo_sbs": photo.set_stereo_layout(1)
		"stereo_tb": photo.set_stereo_layout(2)
		"eyes": photo.toggle_eye_order()
		"fov_180", "fov_190", "fov_200", "fov_220": photo.set_fisheye_fov(int(operation.right(3)))
		"screen_curve": photo.cycle_screen_curve(); _save_screen(); photo.changed.emit()
		"photo_background":
			if background.import_photo(photo.background_source(), photo.display_name):
				_background_photo = {"uri": photo.local_uri, "serial": photo._serial}
				_show_recent_menu()
				recent_menu.section = recent_menu.Section.SETTINGS
				recent_menu.tab = recent_menu.BACKGROUND_TAB
				recent_menu.refresh()
		_:
			if operation.begins_with("photo_index_"): photo.select_image(int(operation.trim_prefix("photo_index_")))

var _screen_uri := ""

## Preserve the full tracked pose; each surface chooses its placement frame.
func _head_pose() -> Variant:
	var camera: Camera3D = xr_camera
	if not is_instance_valid(camera) and (video or photo): camera = _viewer().view_camera
	if not is_instance_valid(camera) or not camera.is_inside_tree(): return null
	if not display.preview and not _head_tracked(): return null
	var pose := camera.global_transform
	if not pose.is_finite(): return null
	return Transform3D(pose.basis.orthonormalized(), pose.origin)

func _view_pose(distance: float, drop: float) -> Variant:
	if not is_instance_valid(_viewer().view_camera) or not _viewer().view_camera.is_inside_tree():
		return null # host tests and desktop preview without an XR camera
	var head: Transform3D = _viewer().view_camera.global_transform
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	if forward.length() <= 0.01:
		# At the zenith/nadir the head's right axis still defines a horizontal heading.
		forward = Vector3.UP.cross(head.basis.x)
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), head.origin + forward * distance + Vector3(0, -drop, 0))

func _place_screen(recenter: bool = false) -> void:
	if _cinema_scene_active() and not photo_active and video and video.geometry == Geometry.Geometry.FLAT:
		_sync_cinema_screen(); return
	var head: Variant = _head_pose()
	if not photo_active and video.cinema.active(video):
		if view_follow.enabled: _on_session_control("follow")
		if head != null and (recenter or not video.cinema.placed): video.cinema.recenter(video, head)
		else: video._apply_geometry()
		return
	var pose: Variant = _view_pose(_viewer().screen_distance, 0.0)
	if recenter and photo_active and photo.gallery.mode in [0, 1] and head != null:
		pose = head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -photo.screen_distance))
	var moved: Variant = interface_move.placement(_surface_key(_viewer()), head) if not recenter and _flat_followable(_viewer()) else null
	if moved != null:
		pose = moved
		view_follow.capture(_surface_key(_viewer()), head, pose)
	elif view_follow.enabled and _flat_followable(_viewer()) and head != null:
		pose = _follow_screen_pose(_viewer(), head, recenter)
	if pose != null:
		_viewer().set_flat_world_pose(pose)
		if _viewer().geometry == Geometry.Geometry.FLAT:
			_viewer()._apply_geometry()

func _flat_followable(surface: Node3D) -> bool:
	if surface == video and _cinema_scene_active(): return false
	if surface == video and video and video.cinema.active(video): return false
	return surface != null and surface.geometry == Geometry.Geometry.FLAT and (surface != photo or photo.gallery.mode == 0 or photo.portrait_requested)

func _surface_key(surface: Node3D) -> StringName:
	return &"photo" if surface == photo else &"video"

func _menu_key(menu: Node3D) -> StringName:
	return StringName("menu_%d" % menu.get_instance_id())

func _follow_screen_pose(surface: Node3D, head: Transform3D, recenter: bool = false) -> Transform3D:
	var key := _surface_key(surface)
	var saved: Variant = null if recenter else view_follow.pose(key, head)
	if saved != null: return saved
	var pose := head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -surface.screen_distance))
	view_follow.capture(key, head, pose)
	return pose

func _capture_follow_screen(surface: Node3D, head: Variant) -> void:
	if head != null and _flat_followable(surface):
		var world: Transform3D = surface.global_transform * surface.flat_pose
		interface_move.placements[_surface_key(surface)] = head.affine_inverse() * world
		view_follow.capture(_surface_key(surface), head, world)

func _update_view_follow() -> void:
	if not view_follow.enabled: return
	var head: Variant = _head_pose()
	if head == null: return
	for menu in [recent_menu, video_menu, photo_menu, music_menu]:
		if not menu or not menu.visible: continue
		if menu.space_locked(): continue
		if menu == recent_menu and _library_is_attached(): continue
		var pose: Variant = view_follow.pose(_menu_key(menu), head)
		if pose == null:
			view_follow.capture(_menu_key(menu), head, menu.global_transform)
		else:
			menu.global_transform = pose
	var surface := _viewer() if video or photo else null
	if surface and _flat_followable(surface) and (not surface.local_uri.is_empty() or (surface == photo and photo.loading)):
		surface.set_flat_world_pose(_follow_screen_pose(surface, head))

func _library_distance() -> float:
	var value: Variant = settings.get_value("ui", "library_distance", LIBRARY_DISTANCE_DEFAULT)
	if not (value is float or value is int) or not is_finite(float(value)) or float(value) <= 0.0:
		return LIBRARY_DISTANCE_DEFAULT
	return clampf(float(value), InterfaceMove.DEPTH_LIMITS.x, InterfaceMove.DEPTH_LIMITS.y)

func _remember_library_distance(head: Variant) -> void:
	if not head is Transform3D or not recent_menu is LibraryMenu or _library_is_attached() or not recent_menu.is_visible_in_tree(): return
	var distance: float = recent_menu.to_global(recent_menu.panel_centre()).distance_to(head.origin)
	if not is_finite(distance): return
	distance = clampf(distance, InterfaceMove.DEPTH_LIMITS.x, InterfaceMove.DEPTH_LIMITS.y)
	if settings.has_section_key("ui", "library_distance") and is_equal_approx(_library_distance(), distance): return
	settings.set_value("ui", "library_distance", distance)
	settings.save(settings_path)

func _place_menu(menu: Node3D, recenter: bool = false) -> void:
	if _cinema_scene_active() and menu == video_menu:
		_sync_cinema_transport(recenter or not menu.visible)
		return
	if menu.get_meta("space_locked", false):
		menu.global_transform = menu.get_meta("space_pose")
		return
	if menu == recent_menu and _library_is_attached(): return
	# The player bar sits low; its popups (settings too) open above it.
	var drop := 0.45 if menu == player_menu else 0.05
	var head: Variant = _head_pose()
	var frame: Variant = InterfaceMove.menu_head(head, view_follow.enabled) if head != null else null
	var moved: Variant = null if recenter or _cinema_scene_active() else interface_move.placement(_menu_key(menu), frame)
	var pose: Variant = moved if moved != null else (frame * Transform3D(Basis.IDENTITY, Vector3(0, -drop, -1.4)) if frame != null else null)
	if pose == null:
		menu.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.6 - drop, -1.55))
	else:
		if menu == recent_menu and menu is LibraryMenu:
			# Persist only the comfort distance. Recenter returns the panel centre to the
			# current gaze on that sphere; facing() below keeps standard menus upright.
			var offset: Vector3 = -head.basis.z if recenter else pose * menu.panel_centre() - head.origin
			if offset.length_squared() < 0.0001: offset = -head.basis.z
			pose.origin = head.origin + offset.normalized() * _library_distance() - pose.basis * menu.panel_centre()
		menu.global_transform = pose
		menu.set_layout_viewer(head, view_follow.enabled)
		view_follow.capture(_menu_key(menu), head, menu.global_transform if menu.is_inside_tree() else pose)

## A disc menu's button area under a ray, unless an app panel is in front of it.
func _disc_menu_uv(hand: String) -> Variant:
	if photo_active or not video or not video.disc.menu_session: return null
	var ray: Variant = _ray(hand)
	if ray == null: return null
	var menu := _active_menu()
	if menu and (_menu_captured(menu) or not menu.ray_hit(ray[0], ray[1]).is_empty()): return null
	return video.disc_menu_uv(ray[0], ray[1])

## The remote's missing keys under a playing disc menu.
func _sync_disc_menu_bar() -> void:
	if not disc_menu_bar: return
	var shown: bool = video != null and not photo_active and video.disc.menu_session and video.media.accepts(video.media.session_id) \
		and video.media.frame_counter > 0 and video.panel.visible and video.geometry == Geometry.Geometry.FLAT
	disc_menu_bar.sync(shown)
	if not shown: return
	disc_menu_bar.place(video.panel, video._flat.size, xr_camera.global_position if xr_camera else video.panel.to_global(Vector3(0, 0, 2.0)))
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = _ray(hand)
		disc_menu_bar.update_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null)

func _disc_menu_bar_press(hand: String) -> bool:
	if not disc_menu_bar or not disc_menu_bar.visible or not _input_focused(): return false
	var ray: Variant = _ray(hand)
	if ray == null: return false
	var menu := _active_menu()
	if menu and (menu.has_pointer_capture() or not menu.ray_hit(ray[0], ray[1]).is_empty()): return false
	if disc_menu_bar.pointer_hit(ray[0], ray[1]).is_empty(): return false
	disc_menu_bar.press_pointer(hand, ray[0], ray[1], true)
	_controller_consumed[hand + "/trigger_click"] = true
	return true

func _on_disc_menu_bar(action: String) -> void:
	if not video or not video.disc.menu_session: return
	match action:
		"top_menu": video.disc_menu.top_menu(video.platform)
		"resume": video.play_disc_main(false)
		"restart": video.play_disc_main(true)
		"eject": _close_current_media()

func _disc_menu_press(hand: String) -> bool:
	if photo_active or not video or not video.disc.menu_session: return false
	var uv: Variant = _disc_menu_uv(hand)
	var sent: bool = uv != null and video.disc_menu.activate(video.platform, uv)
	Log.record("disc_menu_press", {"hand": hand, "result": "sent" if sent else _disc_menu_miss(hand),
		"uv": [snappedf(uv.x, 0.001), snappedf(uv.y, 0.001)] if uv != null else [], "menu": video.disc_menu.state})
	if not sent: return false
	_controller_consumed[hand + "/trigger_click"] = true
	return true

## Why a disc menu press did not reach a button (diagnostics only).
func _disc_menu_miss(hand: String) -> String:
	var ray: Variant = _ray(hand)
	if ray == null: return "no_ray"
	var menu := _active_menu()
	if menu and _menu_captured(menu): return "panel_capture"
	if menu and not menu.ray_hit(ray[0], ray[1]).is_empty(): return "panel_hit"
	if video.disc_menu.bitmap.is_empty(): return "no_buttons"
	if video.screen_uv(ray[0], ray[1]) == null: return "off_screen"
	return "outside_buttons"

var _disc_menu_hover_log_ms := 0
## The pointing ray selects the button under it, as a mouse does on a disc player.
func _disc_menu_hover() -> void:
	if not video or not video.disc.menu_session or not _input_focused(): return
	for hand in ["right_hand", "left_hand"]:
		var uv: Variant = _disc_menu_uv(hand)
		if uv != null:
			video.disc_menu.point(video.platform, uv, Time.get_ticks_msec())
			if Time.get_ticks_msec() >= _disc_menu_hover_log_ms:
				_disc_menu_hover_log_ms = Time.get_ticks_msec() + 2000
				Log.record("disc_menu_hover", {"hand": hand, "uv": [snappedf(uv.x, 0.001), snappedf(uv.y, 0.001)]})
			return

func _active_menu() -> Node3D:
	if puzzle_game and puzzle_game.active: return puzzle_game.input_menu()
	if music_menu and music_menu.visible: return music_menu
	if recent_menu and recent_menu.visible:
		if _library_is_attached(): return recent_menu.get_parent() as Node3D
		return recent_menu
	if puzzle_game:
		var entry: Node3D=puzzle_game.photo_entry_menu()
		if entry: return entry
	if player_menu and player_menu.visible:
		return player_menu
	return null

func _library_is_compact() -> bool:
	return recent_menu is LibraryMenu and recent_menu.compact

func _library_is_attached() -> bool:
	return recent_menu is LibraryMenu and recent_menu.get_parent() is PlayerMenu

func _has_open_media() -> bool:
	if photo_active and photo: return not photo.local_uri.is_empty() or photo.loading or not photo.queue.is_empty()
	return video != null and not video.local_uri.is_empty() and video.media.state not in ["closed", "failed"]

## Return one visible layer at a time, even when the browser is attached to the player bar.
func _navigate_back() -> void:
	if _bar_appearance_return and player_menu and player_menu._adjustment == "bar_transparency":
		player_menu._finish_adjustment(); player_menu._adjustment = ""
		_finish_bar_appearance(); return
	_video_control_tap = {}
	stick_controls.suspend()
	if not _grab.is_empty():
		_cancel_pointer(str(_grab.hand))
		return
	var menu := _active_menu()
	if _menu_captured(menu):
		for hand in ControllerBindings.HANDS: menu.cancel_pointer(hand)
		return
	if music_menu and music_menu.visible:
		if not music_menu.navigate_back(): _close_music_menu()
		return
	if recent_menu and recent_menu.visible:
		if recent_menu.has_method("navigate_back") and recent_menu.navigate_back(): return
		if _has_open_media():
			recent_menu.dismiss()
			_show_player_menu()
		# Without media, retain the last visible library instead of leaving an empty scene.
		return
	if player_menu and player_menu.visible:
		if player_menu.has_method("navigate_back") and player_menu.navigate_back(): return
		if not photo_active and _has_open_media(): _close_current_media()
		elif _has_open_media(): player_menu.dismiss()
		else: _show_full_library()
	elif not photo_active and _has_open_media():
		_close_current_media()
	elif not _has_open_media():
		_show_full_library() # B alone is also a recovery entry for a right-controller-only user.

func _toggle_player_menu() -> void:
	if music_menu and music_menu.visible: _close_music_menu(); return
	if photo_active and photo.inspect:
		_close_photo_inspect()
		return
	if player_menu and player_menu.visible:
		player_menu.dismiss()
	else:
		_show_player_menu()

func _show_player_menu() -> void:
	if _cinema_interaction_owns(): cinema_environment.suspend(); stick_controls.suspend()
	if music_menu: music_menu.dismiss()
	memory_swipe.cancel()
	if photo: photo.gallery.cancel_all()
	if recent_menu:
		recent_menu.dismiss()
	if player_menu and not player_menu.visible:
		_place_menu(player_menu)
		_menu_touched_ms = Time.get_ticks_msec()
		player_menu.toggle()

func _show_recent_menu() -> void:
	memory_swipe.cancel()
	if photo: photo.gallery.cancel_all()
	if photo_active and photo.inspect: _close_photo_inspect(false)
	if recent_menu is LibraryMenu and _has_open_media():
		if photo_active: _photo_open_hide_controls = false
		if player_menu.has_expanded_library():
			recent_menu.dismiss(); stick_controls.suspend(); return
		_show_player_menu()
		player_menu.refresh_layout_reference()
		player_menu._reset_navigation(); player_menu.refresh(); player_menu.expanded_library = recent_menu
		if recent_menu.get_parent() != player_menu: recent_menu.reparent(player_menu, false)
		recent_menu.playback_expanded = false
		recent_menu.show_playback_files(true, _playback_browser_cursor())
		recent_menu.visible = true
		recent_menu.composition_layout_changed.emit()
		stick_controls.suspend(); _menu_touched_ms = Time.get_ticks_msec()
		return
	_show_full_library()

func _show_full_library() -> void:
	if music_menu: music_menu.dismiss()
	var was_attached := _library_is_attached()
	if recent_menu is LibraryMenu: recent_menu.playback_expanded = false
	if player_menu:
		player_menu.dismiss()
	if was_attached:
		recent_menu.hide_for_layout()
		if recent_menu.get_parent() != self: recent_menu.reparent(self, false)
		recent_menu.set_compact(false)
		_place_menu(recent_menu)
		recent_menu.visible = true; recent_menu.refresh()
		recent_menu.composition_layout_changed.emit()
	if recent_menu and not recent_menu.visible:
		_place_menu(recent_menu)
		recent_menu.toggle()
	stick_controls.suspend()

func _toggle_library_layout() -> void:
	if not recent_menu is LibraryMenu: return
	if not _has_open_media():
		_show_full_library()
		return
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	var expand: bool = _library_is_compact()
	player_menu.refresh_layout_reference()
	recent_menu.hide_for_layout()
	recent_menu.playback_controls_pose = null
	recent_menu.playback_expanded = expand
	if recent_menu.get_parent() != player_menu: recent_menu.reparent(player_menu, false)
	player_menu.visible = true; player_menu.refresh()
	recent_menu.set_compact(not expand)
	recent_menu.visible = true; recent_menu.refresh()
	recent_menu.composition_layout_changed.emit()
	_menu_touched_ms = Time.get_ticks_msec()

func _on_directory_order_changed() -> void:
	if not _has_open_media() or not recent_menu is LibraryMenu: return
	if recent_menu.archives.browsing and photo_active and photo.archive_mode:
		photo.reorder(recent_menu.archives.image_queue(), {})
		if player_menu: player_menu.refresh()
		return
	var captured: Dictionary = recent_menu._playback_context
	if captured.get("section", -1) != recent_menu.section or captured.get("location", "") != recent_menu._filter_location(): return
	var context: Dictionary = recent_menu.photo_directory_context()
	if photo_active:
		photo.reorder(recent_menu.image_queue(), context)
	else:
		_cancel_video_queue_wait()
		if not context.is_empty(): _start_video_directory(context, true)
		else:
			video_queue.assign(recent_menu.video_queue())
			video_queue_pages.capture(recent_menu, video.local_uri)
	recent_menu.remember_playback_context(_viewer().local_uri)
	if player_menu: player_menu.refresh()

func _start_video_directory(context: Dictionary, reorder: bool = false) -> void:
	if not video_directory:
		video_directory = preload("res://scripts/photo_directory.gd").new()
		add_child(video_directory)
		video_directory.completed.connect(_on_video_directory)
	_video_directory_reorder = reorder
	_video_directory_location = video.source_location.duplicate(true)
	video_directory.platform = video.platform
	var query := context.duplicate(true); query.kind = "video"
	video_directory.start(query)

func _on_video_directory(entries: Array[Dictionary], complete: bool, _error: String) -> void:
	var reordered := _video_directory_reorder; _video_directory_reorder = false
	if photo_active or video.local_uri.is_empty() or not complete or not entries.any(func(row):return str(row.uri) == video.local_uri): return
	if not reordered and not preload("res://scripts/library_order.gd").preserves_order(video_queue, entries): return
	var waiting: Dictionary = _video_queue_wait.duplicate(true)
	_cancel_video_queue_wait(); video_queue_pages.context = {}
	video_queue.clear()
	for row in entries:
		var metadata := row.duplicate(true); metadata.location = _video_directory_location.duplicate(true)
		video_queue.append({"uri":str(row.uri),"title":str(row.title),"metadata":metadata})
	if not waiting.is_empty(): _advance_video_queue(bool(waiting.get("automatic", false)))
	video.changed.emit()

func _playback_browser_cursor() -> Dictionary:
	if photo_active: return photo.directory.cursor(photo.local_uri)
	if video_directory:
		var cursor: Dictionary = video_directory.cursor(video.local_uri)
		if not cursor.is_empty(): return cursor
	if video_queue_pages.context.get("type", "") != "cloud": return {}
	var context: Dictionary = video_queue_pages.context
	for entry in video_queue:
		if str(entry.uri) == video.local_uri:
			return {"path":context.path,"order":context.order,"offsets":context.get("offsets", []).duplicate(),
				"offset":entry.get("metadata", {}).get("browse_offset", context.get("offset", 0))}
	return {}

func _close_current_media(restore_browser: bool = true) -> void:
	if cast_session.token > 0: cast_session.detach()
	_clear_controls_locks()
	if puzzle_game and puzzle_game.active:
		puzzle_game.finish()
		if puzzle_game.active: return
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	if player_menu: player_menu.dismiss()
	if restore_browser and recent_menu is LibraryMenu and _has_open_media():
		recent_menu.show_playback_files(true, _playback_browser_cursor())
		recent_menu.collections.reveal_uri = _viewer().local_uri
		recent_menu.collections.reveal_pending = false
		recent_menu.set_compact(false)
	if video_directory: video_directory.cancel()
	if photo_active:
		photo.close_image(); photo_active = false; player_menu = video_menu
	else:
		video.close_video()
	_show_full_library()
	if recent_menu is LibraryMenu: recent_menu._playback_context.clear()

func _restore_subtitle_settings() -> void:
	video.subtitle_auto_load = bool(settings.get_value("subtitles", "auto_load", true))
	video.subtitle_distance = float(settings.get_value("subtitles", "distance", 5.0))
	video.subtitle_position = video.SubtitleDepth.restore_position(settings)
	video.subtitle_size = video.SubtitleStyle.size_ratio(float(settings.get_value("subtitles", "size", 1.0)))
	video.subtitle_style = video.SubtitleStyle.normalize(settings.get_value("subtitles", "style", video.SubtitleStyle.DEFAULT))
	video.subtitle_flat_position = float(settings.get_value("subtitles", "flat_position", 0.0))
	video.subtitle_direction = int(settings.get_value("subtitles", "direction", 0))

func _restore_seek_settings() -> void:
	video.seek_mode = video.SeekPolicy.normalize(settings.get_value("video", "seek_mode", video.SeekPolicy.SPEED))
	video.bookmark_seek_mode = video.SeekPolicy.bookmark_override(settings.get_value("video", "bookmark_seek_mode", video.SeekPolicy.GLOBAL))

func _library_settings() -> Dictionary:
	return {"cloud_page_sizes": settings.get_value("library", "cloud_page_sizes", {}), "output_width": Quality.load_output_choice(settings), "alpha_fps": _alpha_fps(),
		"bar_transparency": float(settings.get_value("ui", "bar_transparency", 14.0)),
		"library_backdrop": str(settings.get_value("ui", "library_backdrop", "slideshow")),
		"voice_manager": video.narration.voice_manager_snapshot(),
		"alpha_profile": video.default_profile, "alpha_warming": video.warming.keys(),
		"alpha_cold": video.ALPHA_PROFILES.filter(func(p): return not video.profile_ready(p)),
		"alpha_feather": _alpha_edge_value("alpha_feather"), "alpha_shrink": _alpha_edge_value("alpha_shrink"),
		"show_fps": fps_overlay != null and fps_overlay.visible,
		"display_quality": display_quality, "display_quality_pending": not is_equal_approx(display.render_scale, Quality.render_scale(display_quality, low_end_gpu)),
		"sharpness": Quality.load_sharpness(settings, low_end_gpu),
		"supersampling": Quality.load_supersampling(settings),
		"refresh_cap": Quality.load_refresh_cap(settings, low_end_gpu), "low_end_gpu": low_end_gpu,
		"history": video.history_enabled, "privacy_mode": Privacy.mode, "file_settings_memory": Privacy.file_settings, "favorites_lock_level": favorites.lock_level if favorites else "relaxed",
		"library_restore_position": bool(settings.get_value("library", "restore_position", true)),
		"seek_mode": video.SeekPolicy.normalize(video.seek_mode),
		"subtitle_distance": video.subtitle_distance,
		"subtitle_position": video.subtitle_position,
		"subtitle_direction": video.subtitle_direction,
		"subtitle_size": video.subtitle_size * 100.0,
		"subtitle_style": video.subtitle_style,
		"background": background.choice if background else "belfast",
		"background_custom": background.has_custom() if background else false,
		"background_title": background.custom_title if background else "",
		"background_yaw": background.yaw if background else 0.0,
		"background_brightness": background.brightness if background else 1.0,
		"background_loading": background.loading if background else false,
		"background_error": background.error if background else "",
		"cinema_lights": str(settings.get_value("appearance", "cinema_lights", "auto")),
		"cinema_ready": cinema_environment.is_ready if cinema_environment else false,
		"cinema_loading": cinema_environment.loading if cinema_environment else false,
		"cinema_error": cinema_environment.error if cinema_environment else "",
		"cinema_interaction": cinema_environment.interaction if cinema_environment else "watch",
		"cinema_seat": str(cinema_environment.snapshot().get("seat", "")) if cinema_environment else "",
		"version": str(ProjectSettings.get_setting("application/config/version", ""))}

func _on_setting_changed(key: String, value: Variant) -> void:
	if key.begins_with("cloud_page_size/"):
		var provider := key.trim_prefix("cloud_page_size/")
		if not recent_menu.CloudPagination.DEFAULTS.has(provider): return
		if not recent_menu.CloudPagination.choices(provider).any(func(option): return int(option.value) == int(value)): return
		var sizes: Dictionary = settings.get_value("library", "cloud_page_sizes", {}).duplicate()
		sizes[provider] = int(value)
		settings.set_value("library", "cloud_page_sizes", sizes); settings.save(settings_path)
		recent_menu.refresh(); return
	match key:
		"bar_transparency": _open_bar_appearance(); return
		"library_backdrop":
			if str(value) not in ["off", "static", "slideshow"]: return
			settings.set_value("ui", key, str(value)); settings.save(settings_path)
			recent_menu.server_browser.backdrop.mode = str(value)
		"narration_voice_manager": video.narration.global_voice_command(value)
		"controller_bindings":
			controller_bindings.restore(value)
			interface_move.cancel(); _grab.clear(); stick_controls.suspend()
			settings.set_value("input", "controller_bindings", controller_bindings.snapshot()); settings.save(settings_path)
		"file_editing":
			recent_menu.file_actions.set_enabled(bool(value))
			settings.set_value("library", "file_editing", bool(value))
			settings.save(settings_path)
		"library_orders":
			settings.set_value("library", "orders", value)
			settings.save(settings_path)
			# Browsing remembers directories too; keep diagnostics bounded as the map grows.
			Log.record("setting_changed", {"key": key, "directory_count": value.get("directories", {}).size()})
			return
		"library_default_order", "library_default_folders_first":
			recent_menu.file_actions.set_default(key, value)
			recent_menu.refresh()
		"library_restore_position":
			settings.set_value("library", "restore_position", bool(value)); settings.save(settings_path)
			if recent_menu:
				recent_menu.restore_directory_position = bool(value); recent_menu.refresh()
		"library_view_mode":
			settings.set_value("library", "view_mode", recent_menu.Presentation.mode(value))
			settings.save(settings_path)
		"seek_mode":
			video.seek_mode = video.SeekPolicy.normalize(value)
			settings.set_value("video", "seek_mode", video.seek_mode)
			settings.save(settings_path)
		"restart_app", "quit_app":
			_finish_app(key == "restart_app")
		"display_quality":
			display_quality = clampi(int(value), Quality.AUTO, Quality.SCALES.size() - 1)
			# Apply at next startup: live OpenXR resizing fails to free GLES3 targets on Quest.
			settings.set_value("video", "display_quality", display_quality)
			settings.save(settings_path)
		"refresh_cap":
			if Quality.REFRESH_CAPS.has(int(value)):
				settings.set_value("video", "refresh_cap", int(value))
				settings.save(settings_path)
		"supersampling":
			settings.set_value("video", "supersampling", clampi(int(value), 0, Quality.SUPERSAMPLING_NAMES.size() - 1))
			if video.video_layer: video.video_layer.supersampling = Quality.load_supersampling(settings)
			settings.save(settings_path)
		"sharpness":
			video.sharpness = float(value)
			photo.sharpness = float(value)
			if photo._detail_material: photo._detail_material.set_shader_parameter("sharpness", photo.sharpness)
			settings.set_value("video", "sharpness", video.sharpness)
			settings.save(settings_path)
		"background":
			if background.select(str(value)): _save_background()
		"background_remove":
			if background.remove_custom(): _on_custom_background_saved("", "", 1)
		"cinema_lights":
			if str(value) in ["auto", "on", "off"]:
				settings.set_value("appearance", "cinema_lights", str(value)); settings.save(settings_path)
				_sync_cinema_lights()
		"cinema_interaction":
			_cinema_request_interaction(str(value))
		"cinema_home":
			if cinema_environment and cinema_environment.home():
				stick_controls.suspend(); _sync_cinema_screen(); _reposition_cinema_menus()
		"background_yaw":
			if value is bool: background.rotate_sky()
			else: background.set_yaw(float(value))
			_save_background()
		"background_brightness":
			if value is bool: background.cycle_brightness()
			else: background.set_brightness(float(value))
			_save_background()
		"alpha_fps":
			_apply_alpha_fps(value)
			settings.save(settings_path)
		"alpha_profile":
			if str(value) in video.ALPHA_PROFILES:
				settings.set_value("alpha", "profile", str(value))
				settings.save(settings_path)
				video.select_profile(str(value))
		"alpha_feather", "alpha_shrink":
			_apply_alpha_edge(key, value)
			settings.save(settings_path)
		"show_fps":
			if fps_overlay: fps_overlay.set_shown(bool(value))
			settings.set_value("ui", "show_fps", bool(value))
			settings.save(settings_path)
			if player_menu and player_menu.visible: player_menu.refresh()
		"output_width":
			settings.set_value("video", "output_width", int(value))
			settings.save(settings_path)
			if platform_plugin:
				platform_plugin.set_mpv_output_width(Quality.output_width(Quality.load_output_choice(settings), low_end_gpu))
		"history":
			if recent_menu: recent_menu.checkpoint_browse()
			Privacy.configure(Privacy.ALL if bool(value) else Privacy.NONE)
			if recent_menu: recent_menu.browse_policy_changed()
			video.history_enabled = bool(value)
			photo.history_enabled = bool(value)
			settings.set_value("library", "history", bool(value))
			settings.set_value("privacy", "history", Privacy.mode)
			settings.save(settings_path)
			_sync_native_privacy()
		"clear_history":
			_clear_private_history(false)
		"privacy_mode":
			if recent_menu: recent_menu.checkpoint_browse()
			Privacy.configure(str(value)); video.history_enabled = Privacy.mode != Privacy.NONE; photo.history_enabled = video.history_enabled
			if recent_menu: recent_menu.browse_policy_changed()
			settings.set_value("privacy", "history", Privacy.mode); settings.save(settings_path)
			_sync_native_privacy()
		"file_settings_memory":
			Privacy.configure_file_settings(str(value))
			settings.set_value("privacy", "file_settings", Privacy.file_settings); settings.save(settings_path)
		"favorites_lock_level":
			favorites.lock_level = str(value) if str(value) in ["relaxed", "balanced", "strict", "manual"] else "relaxed"
			settings.set_value("privacy", "lock_level", favorites.lock_level); settings.save(settings_path)
			favorites.tick(Time.get_ticks_msec())
		"favorites_security_changed":
			if recent_menu: recent_menu.browse_policy_changed()
			_migrate_protected_favorites(); _sync_native_privacy()
			if favorites.protected:
				ThumbnailCache.clear()
				preload("res://scripts/photo_preview_cache.gd").clear_disk()
				if PlatformMethods.supports(platform_plugin, "clear_photo_cache"): platform_plugin.clear_photo_cache()
				if PlatformMethods.supports(platform_plugin, "clear_playback_private_data"): platform_plugin.clear_playback_private_data()
		"privacy_clear":
			_clear_private_history(str(value) == "network")
		"file_settings_clear":
			_clear_file_settings(str(value) == "network")
		"language":
			settings.set_value("ui", "language", str(value))
			settings.save(settings_path)
			I18n.use(str(value))
			if PlatformMethods.supports(platform_plugin, "set_ui_language"):
				platform_plugin.set_ui_language(I18n.choice)
			for menu in [recent_menu, player_menu, photo_menu, music_menu]:
				if menu.visible:
					menu.refresh()
		"subtitle_distance":
			video.subtitle_distance = float(value)
			settings.set_value("subtitles", "distance", video.subtitle_distance)
			settings.save(settings_path)
		"subtitle_size":
			_on_playback_adjustment(key, value)
			settings.set_value("subtitles", "size", video.subtitle_size)
			settings.save(settings_path)
		"subtitle_style":
			video.subtitle_style = video.SubtitleStyle.normalize(value)
			settings.set_value("subtitles", "style", video.subtitle_style)
			settings.save(settings_path)
		"subtitle_direction":
			video.subtitle_direction = int(value)
			settings.set_value("subtitles", "direction", video.subtitle_direction)
			settings.save(settings_path)
		"subtitle_position":
			video.subtitle_position = float(value)
			settings.set_value("subtitles", "elevation_degrees", video.subtitle_position)
			settings.save(settings_path)
	Log.record("setting_changed", {"key": key, "value": value})

func _on_menu_action(operation: String) -> void:
	if operation.begins_with("pip_focus_") and video and not photo_active:
		video.pip.focus(operation.trim_prefix("pip_focus_").to_int()); return
	if operation.begins_with("pip_slot_") and video and not photo_active:
		var head: Variant = _head_pose()
		if head is Transform3D: video.toggle_pip_slot(operation.trim_prefix("pip_slot_").to_int(), head)
		return
	if operation.begins_with("pip_count_") and video and not photo_active:
		var head: Variant = _head_pose()
		if head is Transform3D: video.set_pip_count(operation.trim_prefix("pip_count_").to_int(), head)
		return
	if operation == "space_lock": _toggle_controls_lock(); return
	if operation == "wrist_watch_toggle": _toggle_wrist_watch(); return
	if operation == "bar_appearance_done": _finish_bar_appearance(); return
	if not photo_active and video and operation in ["capture_screenshot", "capture_record"]:
		if operation == "capture_screenshot": video.captures.screenshot()
		else: video.captures.toggle()
		return
	if operation.begins_with("screen_") and _cinema_video_locked(): return
	if operation == "cinema_seat": return # Retired action, including stale UI events.
	if operation.begins_with("cinema_lights_"):
		_on_setting_changed("cinema_lights", operation.trim_prefix("cinema_lights_")); return
	if operation == "cinema_move": _cinema_request_interaction("move"); return
	if operation == "cinema_home":
		if cinema_environment and cinema_environment.home():
			stick_controls.suspend(); _reposition_cinema_menus()
		return
	if photo_active:
		_on_photo_action(operation)
		return
	if operation == "music_open": _show_music_management(false, true); return
	if operation == "music_toggle":
		if background_audio and background_audio.play_during_video: background_audio.toggle_pause()
		return
	if video and not video.mode_action_allowed(operation): return
	match operation:
		"open_file": _show_recent_menu()
		"seek_mode":
			_on_setting_changed("seek_mode", video.SeekPolicy.EXACT if video.seek_mode == video.SeekPolicy.SPEED else video.SeekPolicy.SPEED)
		"play": video.toggle_play()
		"alpha": video.set_alpha(not video.alpha_wanted())
		"depth":
			video.set_depth(not video.depth_requested)
		"depth_strength":
			video.cycle_depth_strength()
			_save_depth_strength(false)
		"clone_voice":
			if video.toggle_clone_voice():
				settings.set_value("audio", "prefer_clone_voice", video.prefer_clone_voice)
				settings.save(settings_path)
		"previous_video": _navigate_video(-1)
		"next_video": _navigate_video(1)
		"loop": _cycle_playback_mode()
		"stop": _close_current_media()
		"stereo": video.toggle_stereo()
		"eyes": video.toggle_eye_order()
		"projection": video.cycle_projection()
		"projection_0", "projection_1", "projection_2", "projection_3": video.set_projection(int(operation.right(1)))
		"stereo_2d":
			video.set_depth(false) # plain 2D: also ends 2D -> 3D
			video.set_stereo_layout(0)
		"lock_mode":
			video.toggle_mode_lock()
		"stereo_sbs": video.set_stereo_layout(1)
		"stereo_tb": video.set_stereo_layout(2)
		"stereo_half_sbs": video.set_stereo_layout(3)
		"stereo_half_tb": video.set_stereo_layout(4)
		"fov_180", "fov_190", "fov_200", "fov_220": video.set_fisheye_fov(int(operation.right(3)))
		"packed_mask": video.set_packed_mask(not video.packed_mask_on())
		"recenter": _recenter()
		"screen_curve":
			video.cycle_screen_curve()
			_save_screen()
		"calibration": video.play_calibration_clip()
		"volume_down": video.change_volume(-10.0)
		"volume_up": video.change_volume(10.0)
		"mute": video.toggle_mute()
		"audio": video.cycle_audio_track()
		"capabilities": request_capabilities()

func _on_menu_seek(position_ms: int) -> void:
	if photo_active: return
	video.seek_absolute(position_ms)

func _on_player_setting(key: String, value: Variant) -> void:
	if not photo_active and video and not video.cast_allows(key): return
	if not photo_active and video and video.cast_token > 0 and key.begins_with("narration_clone"): return
	if key == "playback_mode" and not photo_active and video and not video.cast_allows(str(value)): return
	if key == "narration_add_voice":
		_show_full_library()
		recent_menu.section = LibraryMenu.Section.SETTINGS
		recent_menu._state = video.narration.voice_manager_snapshot()
		recent_menu.voice_manager.open(true)
		recent_menu.voice_manager.sample.begin()
		return
	if key == "cinema_picture_size":
		# The cinema screen itself stays fixed; this only scales the picture on it.
		settings.set_value("appearance", "cinema_picture_size", clampf(float(value) / 100.0, CINEMA_PICTURE_MIN, 1.0))
		_sync_cinema_screen()
		return
	if _cinema_video_locked() and key.begins_with("screen_"): return
	if photo_active: return
	if key.begins_with("narration_"):
		if video.narration.set_option(key, value):
			video.narration.save(settings); settings.save(settings_path)
		return
	match key:
		"subtitle_auto_load":
			video.set_subtitle_auto_load(bool(value))
			settings.set_value("subtitles", "auto_load", video.subtitle_auto_load)
			settings.save(settings_path)
		"audio_delay":
			if value is Dictionary and not video.commit_audio_delay(float(value.value), str(value.source_uri), str(value.audio_key)):
				if is_instance_valid(player_menu): player_menu.refresh()
		"subtitle_delay":
			if value is Dictionary and not video.commit_subtitle_delay(float(value.value), str(value.source_uri), str(value.get("subtitle_key", "__current__"))):
				if is_instance_valid(player_menu): player_menu.refresh()
		"seek_mode", "subtitle_distance", "subtitle_position", "subtitle_direction", "subtitle_style": _on_setting_changed(key, value)
		"viewing_eye": video.set_viewing_eye(int(value))
		"spatial_auto_disparity": video.set_spatial_auto_disparity(bool(value))
		"spatial_match_fov":
			if video.match_spatial_fov(): _save_screen()
		"subtitle_size", "subtitle_flat_position": _on_playback_adjustment(key, value); _save_playback_adjustments()
		"loop": _set_playback_mode("repeat_one" if bool(value) else "single")
		"playback_mode": _set_playback_mode(str(value))
		"show_fps": _on_setting_changed(key, value)
		"screen_curve": video.set_screen_curve(float(value)); _save_screen(); video.changed.emit()
		"disc_title": video.select_disc_title(int(value))
		"disc_menu":
			# The disc's menu owns the screen: our bar steps aside (it returns as usual).
			if video.open_disc_menu() and player_menu: player_menu.dismiss()
		"audio_track":
			if video.select_audio_track(int(value)):
				settings.set_value("audio", "prefer_clone_voice", video.prefer_clone_voice)
				settings.save(settings_path)

func _on_bookmark_mode_requested(mode: String, scope: String) -> void:
	if photo_active or scope != video.bookmark_scope() or mode not in [video.SeekPolicy.GLOBAL, video.SeekPolicy.SPEED, video.SeekPolicy.EXACT]: return
	_menu_touched_ms = Time.get_ticks_msec()
	video.bookmark_seek_mode = mode
	settings.set_value("video", "bookmark_seek_mode", mode)
	settings.save(settings_path)
	Log.record("setting_changed", {"key": "bookmark_seek_mode", "value": mode})

func _on_bookmark_loop_request(operation: String, payload: Dictionary, scope: String) -> void:
	if video and video.cast_token > 0: return
	if photo_active: return
	_menu_touched_ms = Time.get_ticks_msec()
	var message: String = video.bookmark_loop.action(operation, payload, scope)
	if not message.is_empty(): player_menu.bookmarks.notify(I18n.t(message))
	else: player_menu.refresh_values()

func _on_bookmark_request(operation: String, marker_id: String, scope: String) -> void:
	if photo_active: return
	_menu_touched_ms = Time.get_ticks_msec()
	var message: String = video.bookmark_action(operation, marker_id, scope)
	if message == "Bookmark added":
		player_menu.bookmarks.notify(I18n.t(message) + " · " + player_menu._time(int(video.bookmark_last_added.position_ms)), str(video.bookmark_last_added.id))
	elif not message.is_empty(): player_menu.bookmarks.notify(I18n.t(message))
	else: player_menu.refresh_values()

## Muting keeps the level, so unmuting (left stick) brings the sound back where it was.
func _on_menu_volume(volume: float, muted: bool) -> void:
	if photo_active: return
	if video.system_volume.supported(): video.set_volume_level(0 if muted else volume)
	else: video.set_audio_options(video.audio_track_id, video.audio_volume if muted else volume, muted)

func _on_menu_whisper(level: int, source_uri: String) -> void:
	if not photo_active and source_uri == video.local_uri: video.set_audio_whisper(level)

func _on_whisper_haptic(hand: String) -> void:
	var controller := left_controller if hand == "left_hand" else right_controller
	if controller is XRController3D: controller.trigger_haptic_pulse("haptic", 0.0, 0.25, 0.04, 0.0)

func _restore_audio_preferences() -> void:
	if video.system_volume.supported():
		video.system_volume.poll(true); return
	var level := float(settings.get_value("audio", "volume", 100.0))
	video.audio_volume = clampf(level, 1.0, 100.0) if is_finite(level) and level > 0.0 else 100.0
	video.audio_muted = bool(settings.get_value("audio", "muted", false))

func _on_audio_options_changed(volume: float, muted: bool) -> void:
	if video.system_volume.supported(): return
	if settings.get_value("audio", "volume", 100.0) == volume and settings.get_value("audio", "muted", false) == muted: return
	settings.set_value("audio", "volume", volume); settings.set_value("audio", "muted", muted)
	_audio_save_after = Time.get_ticks_msec() + 350

func _save_audio_preferences() -> void:
	_audio_save_after = 0
	settings.save(settings_path)

func _exit_tree() -> void:
	cast_session.close()
	if is_instance_valid(recent_menu): recent_menu.checkpoint_browse()
	_cancel_video_queue_wait()
	video_queue_pages.dispose()
	if background_audio:
		background_audio.save_settings(settings); _save_background_preferences()
	if _audio_save_after > 0: _save_audio_preferences()

func _on_depth_strength(strength: float, for_photo: bool) -> void:
	var viewer: Node3D = photo if for_photo else video
	if viewer.set_depth_strength(strength):
		if for_photo:
			settings.set_value("photo", "depth_strength", viewer.depth_strength)
			_remember_photo_auto_depth(viewer.auto_depth)

func _remember_photo_auto_depth(enabled: bool) -> void:
	if photo: photo.auto_depth = enabled
	if settings.get_value("effects", "auto_3d", true) != enabled:
		settings.set_value("effects", "auto_3d", enabled)
		settings.save(settings_path)

func _on_mode_lock_changed(lock: Dictionary, media_kind: String) -> void:
	settings.set_value(media_kind, "mode_lock", lock)
	settings.save(settings_path)

func _save_depth_strength(for_photo: bool = false) -> void:
	# Keep dragging live without writing settings on every pointer movement.
	if for_photo: settings.save(settings_path)
	elif video and video._remember_file and video.media.accepts(video.media.session_id):
		settings.set_value("video", "depth_strength", video.preferred_depth_strength)
		settings.save(settings_path)
		video._remember_mode()

func _menu_state() -> Dictionary:
	if not video:
		return {}
	var details: Dictionary = video.media.playback.get("details", {})
	var audio_options: Array = [{"value": -1, "label": "Auto"}]
	for track in details.get("audio_tracks", []):
		if track is Dictionary and int(track.get("id", 0)) > 0:
			var label := _audio_option_label(track)
			var option := {"value": int(track.id), "label": label, "hint": label}
			if track.get("external", false) and (str(track.get("title", "")) == "Clone voice" or str(track.get("title", "")).to_lower().ends_with(".si.mix.m4a")): audio_options.insert(1, option)
			else: audio_options.append(option)
	audio_options.append({"value": 0, "label": "Off"})
	var text_tracks: Array = video.subtitle_tracks()
	var result := {"has_video": not video.local_uri.is_empty() and video.media.accepts(video.media.session_id),
		"has_previous_video": not _adjacent_video(-1).is_empty(), "has_next_video": not _adjacent_video(1).is_empty() or (video_queue.any(func(row): return row.uri == video.local_uri) and (video_queue_pages.has_more() or playback_mode == "repeat_all")),
		"playing": video.requested_play, "playback_state": video.media.state, "loading_caption": _video_loading_caption(),
		"alpha_requested": video.alpha_wanted(), "alpha_enabled": video.alpha_enabled,
		"loop": video.loop_enabled, "playback_mode": playback_mode, "stereo": video.stereo_sbs, "swap_eyes": video.swap_eyes,
		"viewing_eye": video.viewing_eye, "stereo_horizontal": video.stereo_horizontal, "stereo_vertical": video.stereo_vertical,
		"top_bottom": video.stereo_sbs and video.top_bottom, "stereo_half": video.stereo_sbs and video.stereo_half, "fisheye_fov": video.fisheye_fov,
		"packed_mask": video.packed_mask_on(), "packed_mask_available": video.packed_mask_available(),
		"projection": ["Flat", "VR180", "Fisheye", "360"][video.geometry], "geometry": video.geometry, "profile": video.profile,
		"mode_lock": video.mode_lock,
		"spatial_video": video.is_spatial_video(),
		"spatial_metadata": video.spatial_metadata(), "spatial_auto_disparity": video.spatial_auto_disparity,
		"spatial_fov_available": video.spatial_fov_scale() > 0.0,
		"volume": video.system_volume.level() if video.system_volume.supported() else video.audio_volume, "muted": video.audio_muted,
		"volume_writable": video.system_volume.writable if video.system_volume.supported() else true,
		"boost_saved": video.audio_boost_saved,
		"audio_whisper": video.audio_whisper, "whisper_available": PlatformMethods.supports(video.platform, "set_mpv_whisper"),
		"whisper_error": video.whisper_error,
		"audio_available": details.get("audio_tracks", []).size() > 0,
		"audio_options": audio_options, "audio_track_id": video.audio_track_id,
		"disc_titles": video.disc.titles if video.disc.uri == video.local_uri else [],
		"disc_playlist": video.disc.playing, "disc_main": video.disc.main, "disc_first_view": video.disc.first_view,
		"disc_menu_available": video.disc.menu_available() and video.disc.uri == video.local_uri, "disc_menu_session": video.disc.menu_session,
		"disc_menu_unsupported": video.disc.menu_unsupported() and video.disc.uri == video.local_uri,
		"audio_delay": video.audio_delay, "audio_timing_key": video.audio_timing_key(),
		"audio_tracks": details.get("audio_tracks", []).size(), "audio_track": _audio_track_name(details),
		"clone_voice": video.clone_voice_track() > 0, "clone_voice_active": video.clone_voice_active(),
		"depth_requested": video.depth_requested, "depth_enabled": video.depth_enabled, "depth_strength": video.depth_strength,
		"screen_curve": video.screen_curve, "screen_distance": _surface_distance(video) if video.cinema.active(video) else video.screen_distance,
		"screen_is_default": _flat_video_is_default(), "screen_default_locked": settings.has_section_key("screen", "default_view"), "screen_cinema": video.cinema.enabled,
		"screen_scene_locked": _cinema_video_locked(),
		"cinema_lights": str(settings.get_value("appearance", "cinema_lights", "auto")),
		"cinema_picture_size": _cinema_picture_size() * 100.0,
		"screen_preset": _active_screen_preset(), "screen_dimensions": video._flat.size,
		"screen_eye_level": video.cinema.eye_level(video, _eye()),
		"screen_scale": video.screen_scale * 100.0, "screen_rotation": video.screen_rotation, "playback_speed": video.playback_speed,
		"alpha_fps": _alpha_fps(), "alpha_feather": _alpha_edge_value("alpha_feather"), "alpha_shrink": _alpha_edge_value("alpha_shrink"),
		"show_fps": fps_overlay != null and fps_overlay.visible,
		"subtitle_size": video.subtitle_size * 100, "subtitle_flat_position": video.subtitle_flat_position * 100,
		"subtitle_style": video.subtitle_style,
		"subtitle_distance": video.subtitle_distance, "color_grade": video.color_grade.snapshot(),
		"subtitle_position": video.subtitle_position,
		"subtitle_direction": video.subtitle_direction,
		"grade_values": video.color_grade.values(),
		# Options that leave the compositor layer carry a warning only where the layer exists.
		"layer_available": video.video_layer != null and video.video_layer.available(),
		"grade_on_layer": video.video_layer != null and video.video_layer.color_scale_bias,
		"depth_error": str(video.media.playback.get("depth_error", "")),
		"text_subtitle_tracks": text_tracks.size(), "subtitle_options": text_tracks,
		"subtitle_track": video.subtitles.requested_track, "source_uri": video.local_uri,
		"subtitle_auto_load": video.subtitle_auto_load,
		"subtitle_delay": video.subtitle_delay,
		"subtitle_timing_key": video.subtitle_timing_key(),
		"subtitle_files_available": video.subtitle_files_available(), "subtitle_files": video.subtitle_files,
		"subtitle_browse_available": video.PlatformMethods.supports(video.platform, "load_mpv_subtitle_uri"),
		"subtitle_files_revision": video.subtitle_files_revision,
		"subtitle_files_state": video.subtitle_files_state, "subtitle_file_loading": video.subtitle_file_loading, "subtitle_file_error": video.subtitle_file_error,
		"title": video.display_name, "source_size": "%s x %s" % [video.media.format.get("width", "?"), video.media.format.get("height", "?")],
		"codec": details.get("codec", "Unknown codec"),
		"position_ms": video.control.display_position_ms(), "duration_ms": video.control.duration_ms,
		"seek_feedback": seek_feedback.snapshot(),
		"xr_state": "Desktop preview" if display.preview else display.session_state,
		"capabilities_available": platform_plugin != null,
		"error": _menu_error(), "error_report": video.media.error_report if video.picker_error.is_empty() else {}}
	result.merge(video.bookmarks_snapshot())
	result["watch_available"] = wrist_watch != null
	result["watch_enabled"] = bool(settings.get_value("watch", "enabled", true))
	result["capture"] = video.captures.snapshot()
	result["pip_count"] = video.pip.windows.size()
	result["pip_slots"] = video.pip.windows.keys()
	result["pip_available"] = video.pip_available()
	result.merge(video.narration.snapshot())
	if background_audio: result.merge(background_audio.snapshot())
	if video.cast_token > 0: result = preload("res://scripts/cast_capabilities.gd").apply(result, preload("res://scripts/cast_capabilities.gd").capabilities(video))
	return result

## Preserve native titles/IDs for sidecar recognition; localize their presentation only.
func _audio_option_label(track: Dictionary) -> String:
	if track.get("external", false):
		var filename := str(track.get("title", "")).replace("\n", " ").replace("\r", " ").strip_edges()
		if filename == "Clone voice": return I18n.t("Dubbing")
		return I18n.t("Dubbing") + ": " + filename
	var title := str(track.get("title", "")).replace("\n", " ").replace("\r", " ").strip_edges()
	var language := str(track.get("language", "")).replace("_", "-").to_lower().split("-")[0]
	var names := {"en": "English", "eng": "English", "zh": "Chinese", "zho": "Chinese", "chi": "Chinese",
		"ja": "Japanese", "jpn": "Japanese", "fr": "French", "fra": "French", "fre": "French",
		"de": "German", "deu": "German", "ger": "German", "es": "Spanish", "spa": "Spanish",
		"ko": "Korean", "kor": "Korean", "ru": "Russian", "rus": "Russian"}
	var language_label := I18n.t(str(names.get(language, language))) if language not in ["", "und"] else ""
	if title.is_empty(): title = I18n.t("Track %d") % int(track.get("id", 0))
	return title + (" · " + language_label if not language_label.is_empty() else "")

func _audio_track_name(details: Dictionary) -> String:
	var current := str(details.get("audio_track_id", ""))
	for track in details.get("audio_tracks", []):
		if track is Dictionary and str(track.get("id", "")) == current:
			return _audio_option_label(track)
	return current if not current.is_empty() else "Auto"

func _menu_error() -> String:
	var error: String = video.picker_error if not video.picker_error.is_empty() else video.media.error
	if error.is_empty():
		error = display.error_code
	match error:
		"PERMISSION_LOST", "LOCAL_DOCUMENT_PERMISSION_LOST": error = "File access lost. Select the video again (PERMISSION_LOST)."
		"MISSING", "LOCAL_DOCUMENT_MISSING": error = "Video no longer exists. Select another file (MISSING)."
		"TIMEOUT", "LOCAL_DOCUMENT_TIMEOUT": error = "File access timed out. Try opening again."
		"UNREADABLE": error = "Unable to read the video. Select another file."
	return I18n.t(error)

func _apply_stick_actions(actions: Array[Dictionary], delta: float = 1.0 / 72.0) -> void:
	var mapped: Array[Dictionary] = actions.filter(func(action): return action.operation == "shortcut")
	for action in mapped:
		if interface_move.pending(): interface_move.cancel()
		if action.id in ["back10", "forward10", "back20", "forward20"] and not photo_active:
			if _shortcut_allowed(action.id):
				_begin_stick_seek(str(action.get("hand", "right_hand")), str(action.get("input", "stick_right")),
					int(str(action.id).trim_prefix("back").trim_prefix("forward")) * 1000 * (-1 if str(action.id).begins_with("back") else 1), action.id)
		else:
			_execute_shortcut(action.id, action.get("hand", "right_hand"), float(action.get("amount", 1.0)), delta)
	if not mapped.is_empty(): actions = actions.filter(func(action): return action.operation != "shortcut")
	if photo_active:
		if photo.inspect: return
		for action in actions:
			if action.operation == "zoom":
				if photo.geometry != Geometry.Geometry.FLAT and not photo.gallery.overview(): _toggle_photo_inspect("left_hand" if action.get("hand") == "left" else "right_hand")
				else: photo.zoom_picture(float(action.amount) * ZOOM_SPEED * delta)
			elif action.operation == "seek" and action.get("hand", "right") == "right" and not photo.inspect: photo.navigate(int(action.direction))
		return
	for action in actions:
		match action.operation:
			"zoom": _zoom_video(float(action.amount) * ZOOM_SPEED * delta)
			"seek": _begin_stick_seek(str(action.get("hand", "right")) + "_hand", "stick_right" if action.direction > 0 else "stick_left", int(action.get("delta_ms", int(action.direction) * 10000)))
			"volume": video.change_volume(float(action.direction) * 10)
			"audio_track": video.cycle_audio_track(int(action.direction))
			"mute": video.toggle_mute()
			"subtitle": video.cycle_subtitle_track(int(action.direction))
			"swap_eyes": video.toggle_eye_order()

func _request_rvm_benchmark(vulkan: bool, profile: String = "256x144") -> void:
	if not platform_plugin:
		rvm_status = "Android RVM benchmark requires Quest"
		_update_status()
		return
	var id: int = platform_plugin.request_rvm_profile_benchmark(vulkan, profile)
	if id <= 0:
		rvm_status = "RVM benchmark busy or unavailable"
	else:
		last_rvm_request = id
		var profile_index := RVM_PROFILES.find(profile)
		next_rvm_case = (profile_index * 2 + (2 if vulkan else 1)) % (RVM_PROFILES.size() * 2)
		rvm_status = "RVM %s %s validation running" % [profile, "Vulkan" if vulkan else "CPU"]
	_update_status()

func _on_rvm_result(id: int, payload: String) -> void:
	if id != last_rvm_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		rvm_status = "RVM benchmark report invalid"
		_update_status()
		return
	rvm_report = parser.data
	rvm_status = "RVM %s %s: %s" % [rvm_report.get("profile_key", rvm_report.get("requested_profile", "?")),
		rvm_report.get("backend", "native"), rvm_report.get("state", "unknown")]
	Log.record("rvm_validation_result", rvm_report)
	_save_report()

func _request_controlled_probe() -> void:
	if not platform_plugin or not video or video.local_uri.is_empty():
		controlled_status = "Select a video or calibration clip first"
		_update_status()
		return
	if controlled_request > 0:
		platform_plugin.close_controlled_video(controlled_request)
	# The probe has a video-only clock. Pause normal audio/video while validating it.
	platform_plugin.set_mpv_playing(video.media.session_id, false)
	controlled_report = {}
	controlled_request = platform_plugin.request_controlled_probe(video.local_uri, 0, video.stereo_sbs,
		"256x256" if video.stereo_sbs else "256x144")
	controlled_status = "Controlled decode probe running" if controlled_request > 0 else "Controlled decode probe unavailable"
	_update_status()

func _on_controlled_event(id: int, payload: String, kind: String) -> void:
	if id != controlled_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		controlled_status = "Controlled probe invalid report"
		return
	controlled_report[kind] = parser.data
	if kind == "frame":
		controlled_status = "Controlled frames: %s | PTS matched | immutable slot" % parser.data.get("captured_frames", 0)
	else:
		controlled_status = "Controlled probe: %s" % parser.data.get("state", parser.data.get("code", "unknown"))
		Log.record("controlled_" + kind, parser.data)
	_update_status()

func _toggle_display() -> void:
	if photo_active:
		_on_photo_action("photo_portrait"); return
	if not video.local_uri.is_empty():
		video.set_alpha(not video.alpha_wanted())
	else:
		background.select("dark" if background.choice == "passthrough" else "passthrough")
		_save_background()
	_save_report()

func _on_video_changed() -> void:
	if not _video_queue_wait.is_empty() and not _valid_video_queue_wait(): _cancel_video_queue_wait()
	_sync_background_audio()
	_update_favorite_session()
	_update_seek_feedback(0.0)
	if playback_status_overlay: playback_status_overlay.refresh()
	if photo_active: return
	_update_thumbnail_protection()
	_update_background()
	_update_status()
	_queue_report()
	if player_menu and player_menu.visible:
		player_menu.refresh_values()
	if recent_menu: recent_menu.refresh_alpha_sizes() # first-use compile of the Alpha model sizes

func _on_video_thumbnail_ready(_uri: String) -> void:
	if recent_menu and recent_menu.visible: recent_menu.refresh()

func _on_video_playback_failed() -> void:
	_cancel_video_queue_wait()
	if photo_active or not video_menu: return
	_grab = {}; stick_controls.suspend(); interface_move.cancel()
	player_menu = video_menu
	_show_player_menu()
	player_menu.show_playback_error()

var _thumbnail_history_sequence := -1
func _update_thumbnail_protection() -> void:
	if not video or _thumbnail_history_sequence == video.recent_files.sequence: return
	_thumbnail_history_sequence = video.recent_files.sequence
	ThumbnailCache.protect_keys(video.recent_files.list_recent().map(func(e): return str(e.uri)))

func _on_background_changed() -> void:
	_update_background()
	if recent_menu and recent_menu.visible and recent_menu.section == recent_menu.Section.SETTINGS and recent_menu.tab == recent_menu.BACKGROUND_TAB:
		recent_menu.refresh()

func _cinema_scene_active() -> bool:
	return CinemaFeature.enabled() and cinema_environment != null and cinema_environment.active

func _cinema_interaction_owns() -> bool:
	return _cinema_scene_active() and cinema_environment.interaction != "watch"

func _cinema_input_blocked() -> bool:
	return not _input_focused() or _active_menu() != null or not interface_move.capture.is_empty() \
		or not _grab.is_empty() or not _inspect_blocked.is_empty() or photo_active or (puzzle_game != null and puzzle_game.active)

func _cinema_request_interaction(value: String) -> bool:
	if not cinema_environment or not cinema_environment.set_interaction(value): return false
	interface_move.cancel(); _grab.clear(); _video_control_tap.clear(); stick_controls.suspend()
	if value != "watch":
		for menu in [recent_menu, video_menu, photo_menu, music_menu]:
			if menu and menu.visible: menu.dismiss()
	_refresh_session_controls()
	return true

func _cinema_return_to_playback() -> void:
	if not _cinema_request_interaction("watch"): return
	_cinema_desktop_look = false
	if display.preview: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_player_menu()

func _cinema_pointer_press(hand: String) -> bool:
	if not _cinema_interaction_owns() or _cinema_input_blocked(): return false
	var ray: Variant = _ray(hand)
	if ray == null: return false
	_video_control_tap.clear(); stick_controls.suspend()
	_cinema_move_hands[hand] = true
	cinema_environment.pointer_press(hand, ray[0], ray[1])
	return true

func _cinema_pointer_release(hand: String) -> bool:
	if not _cinema_move_hands.has(hand): return false
	_cinema_move_hands.erase(hand)
	if not cinema_environment: return true
	var ray: Variant = _ray(hand)
	if _cinema_input_blocked() or ray == null:
		cinema_environment.cancel_pointer(hand)
	else:
		cinema_environment.pointer_release(hand, ray[0], ray[1], true)
	stick_controls.suspend()
	return true

func _on_cinema_environment_changed() -> void:
	var moved_context := _cinema_was_active != _cinema_scene_active()
	_cinema_was_active = _cinema_scene_active()
	if cinema_environment and _cinema_last_mode != cinema_environment.interaction:
		_cinema_last_mode = cinema_environment.interaction
		stick_controls.suspend()
	_update_background()
	if moved_context: _reposition_cinema_menus()
	if player_menu and player_menu.visible: player_menu.refresh()
	if recent_menu and recent_menu.visible and recent_menu.section == recent_menu.Section.SETTINGS and recent_menu.tab == recent_menu.BACKGROUND_TAB:
		recent_menu.refresh()

func _reposition_cinema_menus() -> void:
	for menu in [recent_menu, video_menu, photo_menu, music_menu]:
		if menu:
			interface_move.placements.erase(_menu_key(menu)); view_follow.forget(_menu_key(menu))
			if menu.visible: _place_menu(menu, true)

func _sync_cinema_screen() -> void:
	_sync_cinema_lights()
	_sync_cinema_transport()
	if not video: return
	var fixed: bool = _cinema_scene_active() and not photo_active and video.geometry == Geometry.Geometry.FLAT
	if not fixed:
		if _cinema_screen_saved.is_empty(): return
		var saved := _cinema_screen_saved
		_cinema_screen_saved = {}
		for key in ["screen_distance", "screen_scale", "screen_rotation", "screen_curve", "screen_preset"]: video.set(key, saved[key])
		for key in saved.cinema: video.cinema.set(key, saved.cinema[key])
		view_follow.set_enabled(saved.follow)
		video.flat_pose = saved.pose
		video._apply_geometry()
		if not photo_active and video.geometry == Geometry.Geometry.FLAT:
			interface_move.cancel(); _grab.clear(); _video_control_tap.clear(); stick_controls.suspend()
			interface_move.placements.erase(&"video"); view_follow.forget(&"video")
			# The viewer may have turned or moved in the auditorium. Rebase the ordinary
			# screen from restored preferences, rather than reusing entry-time coordinates.
			_place_screen(true)
		return
	if _cinema_screen_saved.is_empty():
		_cinema_screen_saved = {"screen_distance": video.screen_distance, "screen_scale": video.screen_scale,
			"screen_rotation": video.screen_rotation, "screen_curve": video.screen_curve,
			"screen_preset": video.screen_preset, "pose": video.flat_pose, "follow": view_follow.enabled,
			"cinema": {"enabled": video.cinema.enabled, "bottom": video.cinema.bottom, "height": video.cinema.height,
				"placed": video.cinema.placed, "free_rotation": video.cinema.free_rotation}}
		interface_move.cancel(); _grab.clear(); stick_controls.suspend()
		view_follow.set_enabled(false)
	var screen: Dictionary = cinema_environment.snapshot().get("screen", {})
	if screen.is_empty(): return
	video.cinema.enabled = false
	video.screen_preset = ""
	var dimensions: Vector2 = video._screen_base
	var fit := minf(float(screen.width) / maxf(dimensions.x, 0.01), float(screen.height) / maxf(dimensions.y, 0.01))
	var scale := fit * _cinema_picture_size()
	var anchor := Transform3D(Basis(Vector3.UP, float(screen.get("yaw", 0.0))), Vector3(float(screen.position[0]), float(screen.position[1]), float(screen.position[2])))
	anchor.origin += anchor.basis.z * 0.035
	# A smaller picture settles a little below the screen centre: 30% of the freed
	# height above it, 70% below, which is easier on the neck from the seats.
	anchor.origin -= anchor.basis.y * (dimensions.y * (fit - scale) * CINEMA_PICTURE_DROP)
	if not is_equal_approx(video.screen_scale, scale) or video.screen_curve != 0 or video.screen_rotation != 0:
		video.screen_scale = scale; video.screen_curve = 0.0; video.screen_rotation = 0.0
		video._apply_geometry()
	if not (video.global_transform * video.flat_pose).is_equal_approx(anchor): video.set_flat_world_pose(anchor)

func _update_cinema_film_light(delta: float) -> void:
	if not cinema_environment or not cinema_environment.active or not video: return
	if not cinema_film_light:
		cinema_film_light = CinemaFilmLight.new(); cinema_film_light.name = "CinemaFilmLight"; add_child(cinema_film_light)
	var screen: Dictionary = cinema_environment._manifest.get("screen", {})
	var fraction := 1.0
	if not screen.is_empty():
		# The picture lights the room in proportion to how much of the screen it fills.
		var area := maxf(float(screen.width) * float(screen.height), 0.01)
		fraction = clampf(video._flat.size.x * video._flat.size.y / area, 0.0, 1.0)
	if cinema_film_light.update(delta, video, _cinema_scene_active() and not photo_active, fraction):
		cinema_environment.set_film_light(cinema_film_light.colors)

func _cinema_picture_size() -> float:
	return clampf(float(settings.get_value("appearance", "cinema_picture_size", 1.0)), CINEMA_PICTURE_MIN, 1.0)

func _sync_cinema_lights() -> void:
	if not cinema_environment or not video: return
	# Requested playback keeps the house dark, including while a newly opened file
	# is still loading; otherwise auto would flash the lights up between films.
	var now := Time.get_ticks_msec()
	# Only an open file can be "loading": with nothing open, auto keeps the lights up.
	var opening := not str(video.get("local_uri") if video.get("local_uri") != null else "").is_empty()
	if opening and video.get("requested_play") == true and video.media.state not in ["paused", "ended", "error"]:
		_cinema_lights_idle_since = -1
	elif _cinema_lights_idle_since < 0:
		_cinema_lights_idle_since = now
	# Lights come up only once playback has really stopped for a moment.
	var dark := _cinema_lights_idle_since < 0 or now - _cinema_lights_idle_since < CINEMA_LIGHTS_UP_DELAY_MS
	cinema_environment.set_lighting(str(settings.get_value("appearance", "cinema_lights", "auto")), dark)

func _sync_cinema_transport(recenter: bool = false) -> void:
	if not video_menu: return
	var fixed: bool = _cinema_scene_active() and not photo_active and video and video.geometry == Geometry.Geometry.FLAT
	if not fixed:
		if not _cinema_transport_saved.is_empty():
			var saved := _cinema_transport_saved
			_cinema_transport_saved = {}
			video_menu.set_cinema_world_anchor(false)
			video_menu.ray_max_distance = saved.ray_distance
			video_menu.set_scene_overlay(saved.overlay)
			video_menu.global_transform = saved.pose
			for key in saved.locks:
				if saved.locks[key] == null:
					if video_menu.has_meta(key): video_menu.remove_meta(key)
				else: video_menu.set_meta(key, saved.locks[key])
		return
	var entering := _cinema_transport_saved.is_empty()
	var head: Variant = null
	if entering or recenter:
		head = _head_pose()
		# Restoring a saved cinema can finish before XR head tracking is ready.
		# Leave entry pending so the regular frame sync retries with a real pose.
		if not head is Transform3D: return
	if entering:
		_cinema_transport_saved = {"pose": video_menu.global_transform, "ray_distance": video_menu.ray_max_distance,
			"overlay": video_menu.scene_overlay, "locks": {}}
		for key in ["space_locked", "space_pose", "space_head"]:
			_cinema_transport_saved.locks[key] = video_menu.get_meta(key) if video_menu.has_meta(key) else null
	if entering or recenter:
		video_menu.global_transform = CinemaMenuLayout.near_transport_pose(head)
		video_menu.set_layout_viewer(head, false)
		if video_menu.space_locked():
			video_menu.set_meta("space_pose", video_menu.global_transform)
			video_menu.set_meta("space_head", head)
	if entering:
		video_menu.ray_max_distance = 5.0
		video_menu.set_scene_overlay(true)
		video_menu.set_cinema_world_anchor(true)
	# Keep the native high-density menu compositor enabled in the auditorium.

func _cinema_desktop_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE and not event.pressed and _cinema_desktop_look:
		_cinema_desktop_look = false; Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; return true
	if not display.preview or not _cinema_interaction_owns() or _active_menu() or not xr_camera: return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		_cinema_desktop_look = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		return true
	if event is InputEventMouseMotion and _cinema_desktop_look:
		var pivot := xr_camera.global_position
		xr_origin.rotate_y(-event.relative.x * MOUSE_TURN)
		xr_origin.global_position += pivot - xr_camera.global_position
		xr_camera.rotation.x = clampf(xr_camera.rotation.x - event.relative.y * MOUSE_TURN, -1.3, 1.3)
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed: cinema_environment.suspend(); _show_player_menu()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		var origin := xr_camera.project_ray_origin(event.position)
		var direction := xr_camera.project_ray_normal(event.position)
		if event.pressed: cinema_environment.pointer_press("desktop", origin, direction)
		else: cinema_environment.pointer_release("desktop", origin, direction, not _cinema_input_blocked())
		return true
	return false

func _update_background() -> void:
	if not background or not display.environment: return
	var immersive := false
	var alpha := false
	if puzzle_game and puzzle_game.active and puzzle_game.session!=null:
		immersive=puzzle_game.session.spherical
	elif photo_active and photo:
		immersive = not photo.local_uri.is_empty() and photo.geometry != Geometry.Geometry.FLAT
		alpha = photo.portrait_requested or photo.portrait_enabled
	elif video:
		var active: bool = video.has_active_presentation()
		# A packed mask only exists once a frame shows it (alpha_enabled). Counting the file's
		# packed marker while a slow stream (PTMediaServer live) opens left bare passthrough
		# with no video for seconds before playback.
		alpha = active and (video.alpha_requested or video.alpha_enabled)
		immersive = active and video.geometry != Geometry.Geometry.FLAT
	# Alpha temporarily overrides the saved scenery. An explicit passthrough choice
	# also applies behind immersive media, including the unused half of VR180.
	var wants_passthrough: bool = alpha or temporary_passthrough or background.choice == "passthrough"
	if cinema_environment:
		cinema_environment.select(background.choice == "cinema")
		cinema_environment.set_presented(not immersive and not wants_passthrough and not photo_active and not (puzzle_game and puzzle_game.active))
		_sync_cinema_screen()
	display.set_scenery(null if immersive or wants_passthrough else background.ready_sky(), background.yaw)
	var passthrough: bool = wants_passthrough and display.supports_passthrough()
	if display.applied_passthrough != passthrough or display.requested_passthrough != passthrough:
		display.set_passthrough(passthrough)
	if photo: photo.transparent_background = display.applied_passthrough and not display.preview
	if video:
		# A native Surface mask cannot recover scenery erased from the projection.
		# Mixed image/video windows are independently excluded by direct_compatible().
		video.pip.compositor.surface_background = display.applied_passthrough and not display.preview \
			and not photo_active and not _cinema_scene_active() and not (puzzle_game and puzzle_game.active)
	_refresh_session_controls()

func _connect_session_controls(menu: Node3D) -> void:
	if menu == recent_menu:
		recent_menu.server_browser.backdrop.mode = str(settings.get_value("ui", "library_backdrop", "slideshow"))
	if menu.has_method("set_bar_transparency"):
		menu.set_bar_transparency(float(settings.get_value("ui", "bar_transparency", 14.0)))
	menu.layout_head_provider = _head_pose
	menu.session_controls_provider = _session_controls_state
	menu.session_control_requested.connect(_on_session_control)
	menu.placement_changed.connect(_on_menu_placement_changed.bind(menu))

func _on_menu_placement_changed(menu: Node3D) -> void:
	var head: Variant = _head_pose()
	if head != null: view_follow.capture(_menu_key(menu), head, menu.global_transform)

func _person_passthrough() -> bool:
	if puzzle_game and puzzle_game.active and puzzle_game.session!=null: return false
	if photo_active and photo: return photo.portrait_requested or photo.portrait_enabled
	return not photo_active and video != null and video.has_active_presentation() and (video.alpha_wanted() or video.alpha_enabled)

func _session_controls_state() -> Dictionary:
	return {"follow": view_follow.enabled,
		"passthrough_visible": background != null and background.choice != "passthrough" and display.supports_passthrough(),
		"passthrough": display.applied_passthrough, "alpha": _person_passthrough(),
		"cinema_visible": _cinema_scene_active() and not photo_active, "cinema_moving": _cinema_interaction_owns(),
		"cinema_lights": str(settings.get_value("appearance", "cinema_lights", "auto"))}

func _refresh_session_controls() -> void:
	for menu in [recent_menu, video_menu, photo_menu, music_menu]:
		if menu and menu.visible: menu.refresh_session_controls()

func _on_session_control(operation: String) -> void:
	if operation == "cinema_lights_cycle":
		if not _cinema_scene_active() or photo_active: return
		var modes := ["auto", "on", "off"]
		var current := modes.find(str(settings.get_value("appearance", "cinema_lights", "auto")))
		_on_setting_changed("cinema_lights", modes[(current + 1) % modes.size()])
		_refresh_session_controls(); return
	if operation == "cinema_move_toggle":
		if not _cinema_scene_active() or photo_active: return
		_cinema_request_interaction("watch" if _cinema_interaction_owns() else "move")
		_refresh_session_controls(); return
	if operation == "follow" and _cinema_scene_active() and not photo_active: return
	_menu_touched_ms = Time.get_ticks_msec()
	if operation == "temporary_passthrough":
		if _person_passthrough() or not background or background.choice == "passthrough" or not display.supports_passthrough(): return
		var previous := temporary_passthrough
		temporary_passthrough = not previous
		_update_background()
		if temporary_passthrough and not display.applied_passthrough:
			temporary_passthrough = previous
			_update_background()
	elif operation == "follow":
		_update_view_follow()
		var was_following: bool = view_follow.enabled
		view_follow.set_enabled(not view_follow.enabled)
		if view_follow.enabled and not photo_active and video and video.cinema.active(video): _set_cinema_mode(false)
		interface_move.cancel()
		_grab.clear()
		photo_hands.cancel(); photo_swipe.cancel(); memory_swipe.cancel(); stick_controls.suspend()
		var head: Variant = _head_pose()
		if head != null:
			for menu in [recent_menu, video_menu, photo_menu, music_menu]:
				if menu == recent_menu and _library_is_attached(): continue
				if not menu: continue
				if menu.space_locked(): continue
				var world: Variant = menu.global_transform if menu.visible else interface_move.placement(_menu_key(menu), InterfaceMove.menu_head(head, was_following))
				if world == null: continue
				if not view_follow.enabled: world.basis = InterfaceMove.level_menu(world.basis)
				if menu.visible:
					menu.global_transform = world
					menu.set_layout_viewer(head, view_follow.enabled, false)
				interface_move.placements[_menu_key(menu)] = InterfaceMove.menu_head(head, view_follow.enabled).affine_inverse() * world
				if menu.visible: view_follow.capture(_menu_key(menu), head, world)
		if not view_follow.enabled and recent_menu is LibraryMenu and recent_menu.playback_controls_pose is Transform3D:
			recent_menu.playback_controls_pose.basis = InterfaceMove.level_menu(recent_menu.playback_controls_pose.basis)
		if view_follow.enabled and head != null:
			var surface := _viewer()
			if _flat_followable(surface) and not surface.local_uri.is_empty():
				var local: Vector3 = head.affine_inverse() * (surface.global_transform * surface.flat_pose).origin
				if local.z < -0.1 and absf(local.x / local.z) < 1.0 and absf(local.y / local.z) < 0.9:
					_capture_follow_screen(surface, head)
				else:
					_place_screen(true)
		Log.record("view_follow_changed", {"enabled": view_follow.enabled})
	_refresh_session_controls()

func _save_background() -> void:
	settings.set_value("appearance", "background", background.choice)
	settings.set_value("appearance", "background_yaw", background.yaw)
	settings.set_value("appearance", "background_brightness", background.brightness)
	settings.save(settings_path)

var _background_photo := {}

func _on_custom_background_saved(path: String, title: String, orientation: int) -> void:
	settings.set_value("appearance", "custom_path", path)
	settings.set_value("appearance", "custom_title", title)
	settings.set_value("appearance", "custom_orientation", orientation)
	settings.set_value("appearance", "background", background.choice)
	settings.save(settings_path)
	var imported := _background_photo
	_background_photo = {}
	if not path.is_empty() and background.choice == "custom" and photo_active and photo.local_uri == imported.get("uri", "") and photo._serial == imported.get("serial", -1):
		_close_current_media(false)

func _recenter(restore_defaults: bool = true) -> void:
	if restore_defaults: _clear_controls_locks()
	if _cinema_scene_active():
		interface_move.cancel(); _grab.clear(); stick_controls.suspend()
		cinema_environment.home(); _sync_cinema_screen(); _reposition_cinema_menus()
		return
	interface_move.cancel()
	stick_controls.suspend()
	if restore_defaults:
		interface_move.placements.erase(&"video")
		view_follow.forget(&"video")
		# Only an explicit save locks a baseline. Otherwise recenter uses the latest
		# live dimensions and mode, including legacy settings restored on startup.
		if video and not photo_active and video.geometry == Geometry.Geometry.FLAT and settings.has_section_key("screen", "default_view"):
			var defaults := _flat_video_defaults()
			var cinema_saved := _cinema_default()
			_set_cinema_mode(cinema_saved.enabled)
			video.set_screen_distance(defaults.x)
			video.set_screen_scale(defaults.y)
			video.screen_preset = cinema_saved.preset
			video.cinema.height = cinema_saved.height
			video._apply_geometry()
		for menu in [recent_menu, video_menu, photo_menu, music_menu]:
			if menu:
				interface_move.placements.erase(_menu_key(menu))
				view_follow.forget(_menu_key(menu))
		if recent_menu is LibraryMenu: recent_menu.playback_controls_pose = null
	_grab.clear()
	photo_hands.cancel()
	photo_swipe.cancel(); memory_swipe.cancel()
	if not _viewer().local_uri.is_empty():
		var reset_photo: bool = restore_defaults and photo_active and photo.geometry == Geometry.Geometry.FLAT and photo.gallery.mode in [0, 1] and not photo.portrait_requested
		var reset_video: bool = restore_defaults and not photo_active and video.geometry == Geometry.Geometry.FLAT
		_place_screen(reset_photo or reset_video)
		if reset_video: _save_screen()
		if reset_photo:
			var head: Variant = _head_pose()
			if head != null:
				var pose: Transform3D = photo.global_transform * photo.flat_pose
				interface_move.placements[&"photo"] = head.affine_inverse() * pose
				view_follow.capture(&"photo", head, pose)
		if _viewer().geometry != Geometry.Geometry.FLAT:
			_viewer().reset_view()
	if photo_active:
		photo.gallery.recenter(false)
		if photo.inspect: photo._place_detail()
	for menu in [recent_menu, player_menu]:
		if menu and menu.visible:
			_place_menu(menu, restore_defaults)
	Log.record("recenter_requested")

func request_capabilities() -> void:
	if platform_plugin:
		last_request = platform_plugin.request_capabilities()
		Log.record("capability_probe_requested", {"request_id": last_request})

func _on_capabilities_ready(request_id: int, json_report: String) -> void:
	if request_id != last_request:
		return
	var parsed: Variant = JSON.parse_string(json_report)
	if parsed is Dictionary:
		android_report = parsed
		Log.record("capability_probe_completed", {"request_id": request_id})
	else:
		Log.record("capability_probe_invalid", {"request_id": request_id})
	_save_report()

func _on_android_lifecycle(event: String) -> void:
	if favorites and event in ["pause", "resume"]: favorites.focus_changed(event == "resume", Time.get_ticks_msec())
	Log.record("android_lifecycle", {"event": event})
	if event == "resume":
		request_capabilities()
	elif event == "pause" and video:
		video.checkpoint_playback()

## Periodic only while debug tooling is active or the diagnostics panel shows; otherwise a
## queued state change is written once the minimum gap has passed.
func _on_report_timer() -> void:
	var now := Time.get_ticks_msec()
	if (OS.is_debug_build() and now < _report_tooling_until) or (status_label and status_label.visible):
		_save_report()
	elif _report_due_ms >= 0 and now >= _report_due_ms:
		_save_report()

func _queue_report() -> void:
	if _report_due_ms < 0: _report_due_ms = _report_saved_ms + REPORT_MIN_GAP_MS

func _save_report() -> void:
	_report_due_ms = -1; _report_saved_ms = Time.get_ticks_msec()
	if Privacy.mode != Privacy.ALL or (favorites != null and favorites.protected): return
	var report := {
		"schema_version": 1,
		"app_version": ProjectSettings.get_setting("application/config/version"),
		"engine": Engine.get_version_info(),
		"captured_unix_seconds": Time.get_unix_time_from_system(),
		"xr": display.capabilities(),
		"menu_composition": menu_composition.snapshot() if menu_composition else {},
		"app_render_fps": Engine.get_frames_per_second(),
		"android": android_report,
		"stage": "MP04_shared_MPV_RVM_display_development",
		"video_implemented": true,
		"video_device_validation": "pending",
		"media": video.media.snapshot() if video else {},
		"video_layout": video.layout_snapshot() if video else {},
		"active_media": "image" if photo_active else "video",
		"hand_input": _hand_input_report(),
		"input_visuals": input_visuals.snapshot() if input_visuals else {},
		"background": background.choice if background else "",
		"photo": photo.snapshot() if photo else {},
		"rvm_implemented": true,
		"rvm_benchmark": rvm_report,
		"rvm_video_integrated": true,
		"mpv_rvm_device_validation": "pending",
		"controlled_decode": controlled_report,
	}
	var encoded := JSON.stringify(report, "\t")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open("user://diagnostics/capabilities_latest.json", FileAccess.WRITE)
	if file:
		file.store_string(encoded)
	if platform_plugin:
		var saved_path: String = platform_plugin.save_capability_report(encoded)
		if saved_path.begins_with("ERROR:"):
			Log.record("capability_report_save_failed", {"reason": saved_path})
	_update_status()

func _update_status() -> void:
	if not status_label:
		return
	var mode := "Passthrough" if display.applied_passthrough else "Opaque"
	var detail := "Desktop preview" if display.preview else display.session_state
	status_label.position.y = 2.45
	status_label.visible = OS.get_cmdline_user_args().has("--show-diagnostics")
	calibration_board.visible = status_label.visible and not (video and video.panel and video.panel.visible)
	if not status_label.visible:
		return
	status_label.text = "Thru3D Media Player - MPV\n%s | %s\nLeft Menu / Tab: player menu\nPoint with a controller and press trigger to select\nX / O: open file   A / Space: play,pause   Grip: move interfaces\nLeft click / P: projection   Right click: reset view\nLeft stick: seek 20s, volume   Right stick / arrows: seek 10s   L: playback mode\nB / R: recenter   Trigger / T: Alpha,background\nV: fixture" % [mode, detail]
	if video:
		status_label.text += "\n%s | %s | %s | %s\n%s | RVM %s" % [video.display_name.left(42), video.media.state, "SBS" if video.stereo_sbs else "2D", video.layout_snapshot().geometry, "Alpha on" if video.alpha_enabled else ("Preparing Alpha" if video.alpha_requested else "Normal playback"), video.profile]
		status_label.text += "\n" + rvm_status
		status_label.text += "\n" + controlled_status
		status_label.text += "\n%.1f / %.1f s | %s | %s" % [video.control.observed_position_ms / 1000.0, video.control.duration_ms / 1000.0, video.control.snapshot().state, PLAYBACK_NAMES[playback_mode]]
		status_label.text += "\nAudio: %s | %.0f%% | %s\nL up/down: volume | L left/right: track" % [str(video.media.playback.get("details", {}).get("audio_track_id", "none")), video.audio_volume, "muted" if video.audio_muted else "on"]
		status_label.text += "\nSubtitles: %s | C: track" % ("off" if video.subtitles.requested_track == 0 else str(video.subtitles.requested_track))
		status_label.text += "\nEyes: %s | E: swap" % ("R/L" if video.swap_eyes else "L/R")
		if not video.picker_error.is_empty():
			status_label.text += "\n" + video.picker_error
		if not video.media.error.is_empty():
			status_label.text += "\n" + video.media.error
	if not display.error_code.is_empty():
		status_label.text += "\n" + display.error_code


func _on_playback_adjustment(key: String, value: Variant) -> void:
	if not photo_active and video and not video.cast_allows(key): return
	if not photo_active and video and key.begins_with("grade_") and not video.cast_allows("color_grade"): return
	if key == "bar_transparency":
		_set_bar_transparency(float(value)); return
	if key == "cinema_picture_size":
		# The cinema screen itself stays fixed; this only scales the picture on it.
		settings.set_value("appearance", "cinema_picture_size", clampf(float(value) / 100.0, CINEMA_PICTURE_MIN, 1.0))
		_sync_cinema_screen()
		return
	if _cinema_video_locked() and key.begins_with("screen_"): return
	if key.begins_with("narration_"):
		video.narration.set_option(key, value)
		return
	if key in ["stereo_horizontal", "stereo_vertical"]:
		if not photo_active: video.set_stereo_alignment(key, float(value))
		return
	elif key == "stereo_reset":
		if not photo_active: video.reset_stereo_alignment()
		return
	elif key == "screen_cinema":
		if photo_active or video.geometry != Geometry.Geometry.FLAT: return
		_set_cinema_mode(bool(value))
		_save_screen()
		return
	elif key == "screen_preset":
		_apply_screen_preset(str(value))
		return
	elif key == "screen_eye_level":
		if photo_active or not video.cinema.active(video) or not is_finite(float(value)): return
		var head: Variant = _head_pose()
		if head is Transform3D:
			video.cinema.set_eye_level(video, head, float(value))
			_save_screen()
		return
	elif key == "screen_set_default":
		_save_flat_video_defaults(bool(value))
		return
	elif key == "screen_distance":
		if photo_active or video.geometry != Geometry.Geometry.FLAT or not is_finite(float(value)): return
		_push_screen(clampf(float(value), video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y) - _surface_distance(video))
		return
	elif key == "screen_scale":
		if photo_active or video.geometry != Geometry.Geometry.FLAT or not is_finite(float(value)): return
		video.set_screen_scale(float(value) / 100.0)
		return
	elif key == "screen_rotation":
		if photo_active or video.cinema.active(video): return
		video.set_screen_rotation(float(value))
		return
	elif key == "playback_speed":
		if photo_active: return
		video.set_playback_speed(float(value))
		return
	elif key == "alpha_fps":
		_apply_alpha_fps(value)
		return
	elif key in ["alpha_feather", "alpha_shrink"]:
		_apply_alpha_edge(key, value)
		return
	elif key == "subtitle_size":
		if not is_finite(float(value)): return
		video.subtitle_size = clampf(float(value) / 100.0, 0.5, 2.0)
	elif key == "audio_delay":
		if value is Dictionary and str(value.source_uri) == video.local_uri and str(value.get("audio_key", "")) == video.audio_timing_key(): video.set_audio_delay(float(value.value))
		return
	elif key == "subtitle_delay":
		if value is Dictionary and str(value.source_uri) == video.local_uri and str(value.get("subtitle_key", video.subtitle_timing_key())) == video.subtitle_timing_key():
			video.set_subtitle_delay(float(value.value))
		return
	elif key == "subtitle_flat_position":
		if not is_finite(float(value)): return
		video.subtitle_flat_position = clampf(float(value) / 100.0, 0.0, 1.0)
	elif key == "subtitle_distance":
		video.subtitle_distance = float(value)
	elif key == "subtitle_position":
		video.subtitle_position = float(value)
	elif key == "grade_preset":
		video.color_grade.select(str(value))
	elif key == "grade_reset":
		video.color_grade.reset_custom()
	elif key == "grade_reset_page":
		video.color_grade.reset_page(int(value))
	else:
		video.color_grade.adjust(key, value)
	video.color_grade.apply(video.material)

func _save_playback_adjustments() -> void:
	video.commit_stereo_view()
	_remember_current_screen()
	settings.set_value("subtitles", "size", video.subtitle_size)
	settings.set_value("subtitles", "style", video.subtitle_style)
	settings.set_value("subtitles", "flat_position", video.subtitle_flat_position)
	settings.set_value("subtitles", "distance", video.subtitle_distance)
	settings.set_value("subtitles", "elevation_degrees", video.subtitle_position)
	settings.set_value("subtitles", "direction", video.subtitle_direction)
	settings.set_value("video", "color_grade", video.color_grade.snapshot())
	settings.save(settings_path)

func _fps_sample() -> Dictionary:
	if not video or photo_active or not video.panel or not video.panel.visible: return {}
	return {"frames": video.presented_frames(), "target": _alpha_fps() if video.alpha_enabled else 0,
		"active": video.media.state == "playing", "path": "L" if video.video_layer_shown else "E:" + video.layer_block_reason()}

func _playback_status_sample() -> Dictionary:
	if not video or photo_active or (video_menu and video_menu.visible) or not _seek_overlay_sample().is_empty(): return {}
	return {"caption": _video_loading_caption(), "fps_visible": fps_overlay != null and fps_overlay.visible}

func _video_loading_caption() -> String:
	return I18n.t("Loading next video…") if not _video_queue_wait.is_empty() else video.loading_caption()

func _stick_seek_sample() -> Dictionary:
	if not video or photo_active: return {}
	var details: Dictionary = video.media.playback.get("details", {})
	return {"active": video.cast_allows("seek") and video.media.accepts(video.media.session_id) and video.picker_error.is_empty() and details.get("seekable", "yes") != "no",
		"uri": video.local_uri, "session": video.media.session_id, "sequence": video.control.sequence,
		"position_ms": video.control.display_position_ms(), "duration_ms": video.control.duration_ms}

func _begin_stick_seek(hand: String, input: String, step: int, id: String = "") -> void:
	seek_feedback.begin(_stick_seek_sample(), hand, input, step, id)

func _update_seek_feedback(delta: float) -> void:
	seek_feedback.sync(_stick_seek_sample(), delta)
	if seek_overlay: seek_overlay.refresh()

func _on_stick_seek_presented(request: int, position_ms: int) -> void:
	seek_feedback.presented(request, position_ms)
	_update_seek_feedback(0.0)

func _seek_overlay_sample() -> Dictionary:
	var sample := seek_feedback.snapshot()
	if sample.is_empty() or photo_active or not _input_focused() or (video_menu and video_menu.visible): return {}
	if _active_menu() != null or video == null: return {}
	sample["caption"] = video.loading_caption() if sample.phase == "waiting" else ""
	if video.geometry == Geometry.Geometry.FLAT and video.panel and xr_camera:
		var bottom: Vector3 = video.panel.to_global(Vector3(0, -video._flat.size.y * 0.5 - 0.10, 0))
		sample["flat_anchor"] = xr_camera.to_local(bottom)
	if xr_camera and video.caption and video.caption.visible and not video.caption.text.is_empty():
		var anchor: Vector3 = video.caption.global_position if video.geometry == Geometry.Geometry.FLAT else video.projected_subtitles.plane_pose.origin
		var point := xr_camera.to_local(anchor)
		if point.z < -0.1: sample["subtitle_y"] = point.y * SeekOverlay.DEPTH / -point.z
	return sample

## Alpha source frame rate (RVM runs once per presented frame); MPV follows it live.
## Alpha mask edge (percent): feather and shrink, saved with the other video settings.
func _alpha_edge_value(key: String) -> float:
	var fallback: float = AlphaEdge.FEATHER_DEFAULT if key == "alpha_feather" else AlphaEdge.SHRINK_DEFAULT
	var value := float(settings.get_value("video", key, fallback))
	return clampf(value, 0.0, 100.0) if is_finite(value) else fallback

func _apply_alpha_edge(key: String, value: Variant) -> void:
	if not is_finite(float(value)): return
	settings.set_value("video", key, clampf(roundf(float(value)), 0.0, 100.0))
	if video: video.set_alpha_edge(_alpha_edge_value("alpha_feather"), _alpha_edge_value("alpha_shrink"))

func _alpha_profile() -> String:
	var value := str(settings.get_value("alpha", "profile", video.AUTOMATIC_PROFILE))
	return value if value in video.ALPHA_PROFILES else video.AUTOMATIC_PROFILE

func _alpha_fps() -> int:
	return clampi(int(settings.get_value("video", "alpha_fps", ALPHA_FPS_DEFAULT)), ALPHA_FPS_LIMITS.x, ALPHA_FPS_LIMITS.y)

func _apply_alpha_fps(value: Variant) -> void:
	if not is_finite(float(value)): return
	settings.set_value("video", "alpha_fps", clampi(roundi(float(value)), ALPHA_FPS_LIMITS.x, ALPHA_FPS_LIMITS.y))
	if PlatformMethods.supports(platform_plugin, "set_mpv_alpha_fps"):
		platform_plugin.set_mpv_alpha_fps(_alpha_fps())

var seek_policy_probe_result: Dictionary = {}
var pip_probe_result: Dictionary = {}

## Debug: the remapped fisheye picture as diagnostics/fisheye_readback.png (top row first).
func _save_fisheye_readback() -> void:
	var data: PackedByteArray = platform_plugin.take_fisheye_readback()
	if data.size() <= 8: Log.record("fisheye_readback", {"saved": false}); return
	var width := data.decode_u32(0); var height := data.decode_u32(4)
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data.slice(8))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	image.save_png("user://diagnostics/fisheye_readback.png")
	Log.record("fisheye_readback", {"saved": true, "size": [width, height]})

func _on_display_debug_command(_id: int, payload: String) -> void:
	var command: Variant = JSON.parse_string(payload)
	if not command is Dictionary: return
	if OS.is_debug_build():
		var first := Time.get_ticks_msec() >= _report_tooling_until
		_report_tooling_until = Time.get_ticks_msec() + REPORT_TOOLING_MS
		if first: _save_report()
	var operation := str(command.get("operation", ""))
	if operation == "seek_policy_ui" and OS.is_debug_build():
		var probe := preload("res://scripts/seek_policy_device_probe.gd").new()
		seek_policy_probe_result = probe.run(self, str(command.step), str(command.get("marker_id", "")))
		seek_policy_probe_result.request_key = str(command.request_key)
		video._write_debug_report()
	elif operation in ["display_quality", "supersampling", "sharpness"]:
		_on_setting_changed(operation, command.get("value", 0))
	elif operation in ["restart_app", "quit_app"]:
		recent_menu._activate(recent_menu.RESTART_APP if operation == "restart_app" else recent_menu.QUIT_APP)
	elif operation == "cloud_accounts":
		_show_recent_menu()
		recent_menu.section = recent_menu.Section.CLOUD
		recent_menu.account_panel.open("cloud", true)
	elif operation == "cloud_page_probe" and OS.is_debug_build():
		var probe := preload("res://scripts/cloud_page_probe.gd").new()
		add_child(probe)
		probe.start(platform_plugin)
	elif operation == "media_library_ui" and OS.is_debug_build():
		var probe := preload("res://scripts/media_server_device_probe.gd").new()
		add_child(probe)
		probe.start(self, command)
	elif operation == "display_menu":
		_show_recent_menu()
		recent_menu.section = recent_menu.Section.SETTINGS
		recent_menu.tab = recent_menu.DISPLAY_TAB
		recent_menu.refresh()
	elif operation == "player_menu":
		_show_player_menu()
	elif operation == "photo_open" and OS.is_debug_build():
		# Photo performance probes: the folder's images in name order, starting at [name].
		var folder := str(command.get("folder", ""))
		var entries: Array = []
		for name in DirAccess.get_files_at(folder):
			if ImageInfo.is_image(name, name):
				entries.append({"uri": "file://" + folder.path_join(name), "title": name, "kind": "image"})
		entries.sort_custom(func(a, b): return str(a.title) < str(b.title))
		video.close_video()
		photo_active = true
		player_menu = photo_menu
		photo.layer_enabled = bool(command.get("layer", true))
		photo.open_image("file://" + folder.path_join(str(command.get("name", ""))), str(command.get("name", "")), entries)
		# Debug layout for this session only; the saved layout changes only through the menu.
		if int(command.get("layout", -1)) >= 0: photo.set_layout_mode(int(command.layout))
	elif operation == "layer_flip" and OS.is_debug_build() and video.video_layer:
		video.video_layer.debug_image_layout = int(command.get("value", -2))
	elif operation == "alpha_blend_probe" and OS.is_debug_build():
		video.alpha_probe = int(command.get("value", 0))
		video._alpha_probe_uploaded = false
	elif operation == "layer_order" and OS.is_debug_build() and video.video_layer and video.video_layer._provider:
		video.video_layer._provider.debug_order = int(command.get("value", 0))
	elif operation == "hide_menus" and OS.is_debug_build():
		# Device captures of the scene itself (layers, subtitles) without menus in front.
		recent_menu.dismiss(); player_menu.dismiss(); photo_menu.dismiss()
	elif operation == "menu_layers" and OS.is_debug_build() and menu_composition:
		menu_composition.set_active(bool(command.get("enabled", false)))
	elif operation == "menu_layer_filter" and OS.is_debug_build() and menu_composition:
		# value = supersampling + 10 * sharpening (0 off, 1 normal, 2 quality each).
		var code := int(command.get("value", 1))
		menu_composition.set_filter(code % 10, code / 10 % 10)
	elif operation == "perf_tune" and OS.is_debug_build():
		# Device A/B of frame pacing and idle cost; nothing is saved to user settings.
		if command.has("keepalive_ms") and menu_composition: menu_composition.keepalive_ms = int(command.keepalive_ms)
		if command.has("refresh_rate"): display.set_debug_refresh(float(command.refresh_rate))
		if command.has("max_fps"): Engine.max_fps = int(command.max_fps)
		if command.has("fisheye_ppd") and video: video.debug_fisheye_density = float(command.fisheye_ppd)
		if command.has("fisheye_readback") and PlatformMethods.supports(platform_plugin, "request_fisheye_readback"):
			platform_plugin.request_fisheye_readback(int(command.fisheye_readback))
		if bool(command.get("fisheye_readback_save", false)) and PlatformMethods.supports(platform_plugin, "take_fisheye_readback"):
			_save_fisheye_readback()
		if command.has("perf_level"): display.debug_performance_level = str(command.perf_level); display.apply_performance_levels()
		# Measure the user's path: debug commands otherwise keep the periodic debug reports running.
		if bool(command.get("quiet", false)):
			_report_tooling_until = -1
			if video: video.set_deferred("_debug_request", 0)
	elif operation == "perf_sample" and OS.is_debug_build():
		var sampler := preload("res://scripts/perf_sample_probe.gd").new()
		add_child(sampler)
		sampler.start(str(command.get("label", "sample")).validate_filename(), float(command.get("seconds", 10.0)))
	elif operation == "menu_layer_holes" and OS.is_debug_build() and menu_composition:
		menu_composition.set_debug_holes(bool(command.get("enabled", true)))
	elif operation == "stick" and OS.is_debug_build():
		# Hold one stick at (x, y) for ms milliseconds; then it returns to center.
		var hand := "left_hand" if str(command.get("hand", "right")) == "left" else "right_hand"
		_debug_sticks[hand] = [Vector2(float(command.get("x", 0.0)), float(command.get("y", 0.0))), Time.get_ticks_msec() + clampi(int(command.get("ms", 100)), 16, 10000)]
	elif operation == "menu_action" and OS.is_debug_build():
		# Device probes: a player-menu action by name, as its button would send it.
		_on_menu_action(str(command.get("target", "")))
	elif operation == "pip_probe" and OS.is_debug_build():
		pip_probe_result = preload("res://scripts/video_pip_device_probe.gd").new().run(self, command)
	elif operation == "menu_nav" and OS.is_debug_build():
		_debug_menu_nav(str(command.get("target", "")))
	elif operation == "menu_bench" and OS.is_debug_build():
		var bench := preload("res://scripts/menu_bench_probe.gd").new()
		add_child(bench)
		bench.start(self, str(command.get("profile", "run")).validate_filename())
	elif operation == "photo_depth" and OS.is_debug_build() and photo_active:
		photo.set_depth(bool(command.get("enabled", false)))
	elif operation == "photo_inspect" and OS.is_debug_build() and photo_active:
		# Magnifier probes: open/close it and place its crop (picture UV, top-first).
		if bool(command.get("enabled", true)) != photo.inspect: photo.toggle_inspect()
		if photo.inspect and command.has("x"):
			photo.crop_center = Vector2(float(command.x), float(command.get("y", 0.5)))
			photo._update_inspect()
	elif operation == "photo_portrait" and OS.is_debug_build() and photo_active:
		photo.set_portrait(bool(command.get("enabled", true)))
	elif operation == "photo_step" and OS.is_debug_build() and photo_active:
		photo.navigate(1 if float(command.get("value", 1.0)) >= 0.0 else -1)

## Debug navigation for device menu probes: "section:N", "tab:N", "scroll:F", "click:TEXT" (first
## button whose labels contain TEXT) or "list" (logs the visible button labels).
func _debug_menu_nav(target: String) -> void:
	if not recent_menu.visible: _show_recent_menu()
	var parts := target.split(":", true, 1)
	var argument := parts[1] if parts.size() > 1 else ""
	var buttons: Array = []
	for button in recent_menu._buttons:
		if not is_instance_valid(button.node): continue
		var texts := PackedStringArray()
		for label in button.node.find_children("*", "Label3D", true, false):
			if not label.text.is_empty(): texts.append(label.text)
		buttons.append({"target": button.target, "text": " ".join(texts)})
	match parts[0]:
		"section": recent_menu._activate(recent_menu.NAV_BASE + int(argument))
		"tab": recent_menu._activate(recent_menu.TAB_BASE + int(argument))
		"scroll":
			recent_menu.scroll = float(argument); recent_menu.refresh()
		"click":
			for button in buttons:
				if argument in button.text:
					recent_menu._activate(button.target); break
		"list": print("MENU_NAV ", JSON.stringify(buttons.map(func(b): return b.text).filter(func(t): return not t.is_empty())))

var _finishing_app := false
func _finish_app(restart: bool) -> void:
	if puzzle_game and puzzle_game.active:
		puzzle_game.show_panel(true)
		if not puzzle_game.save_now(): return
	if photo and _gallery_save_after > 0: _save_photo_adjustments()
	if _finishing_app: return
	_finishing_app = true
	_save_playback_adjustments()
	video.close_video()
	photo.close_image()
	settings.save(settings_path)
	DiagnosticLog.record("app_restart" if restart else "app_close")
	if PlatformMethods.supports(platform_plugin, "finish_app"):
		platform_plugin.finish_app(restart)
	else:
		if restart: OS.set_restart_on_exit(true)
		get_tree().quit()

func _notification(what: int) -> void:
	if puzzle_game and puzzle_game.active and what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		puzzle_game.show_panel(true)
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		if is_instance_valid(recent_menu): recent_menu.checkpoint_browse()
		if photo_menu: photo_menu.online.cancel()
		_background_app_paused = true
		if background_audio: _sync_background_audio()
		if background_audio:
			background_audio.save_settings(settings); _save_background_preferences()
	elif what in [NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN]:
		_background_app_paused = false
		if background_audio: _sync_background_audio()
	if favorites and what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_RESUMED]:
		favorites.focus_changed(what == NOTIFICATION_APPLICATION_RESUMED, Time.get_ticks_msec())
	if what == NOTIFICATION_APPLICATION_PAUSED and _audio_save_after > 0: _save_audio_preferences()
	if what == NOTIFICATION_APPLICATION_PAUSED and video: video.checkpoint_playback()
	if what == NOTIFICATION_APPLICATION_PAUSED and photo and _gallery_save_after > 0:
		_save_photo_adjustments()

func _photo_menu_state() -> Dictionary:
	var state: Dictionary = photo.snapshot() if photo else {}
	if background_audio: state.merge(background_audio.snapshot())
	return state

func _sync_background_audio() -> void:
	if background_audio:
		var has_video: bool = video != null and not video.local_uri.is_empty() and video.media.state not in ["closed", "failed"]
		if puzzle_game and puzzle_game.active and puzzle_game.session!=null: has_video=false
		background_audio.set_context(has_video, _input_focused() and not _background_app_paused)

func _on_background_audio_changed() -> void:
	if is_instance_valid(music_menu) and music_menu.is_inside_tree(): music_menu.refresh_values()
	if is_instance_valid(video_menu) and video_menu.is_inside_tree() and video_menu.visible and not video_menu.has_pointer_capture(): video_menu.refresh_values()
	if is_instance_valid(photo_menu) and photo_menu.is_inside_tree() and photo_menu.visible and not photo_menu.has_pointer_capture(): photo_menu.refresh_values()
	if is_instance_valid(recent_menu) and recent_menu.is_inside_tree() and recent_menu.visible: recent_menu.refresh_background_audio()

func _on_background_preferences_changed() -> void:
	background_audio.save_settings(settings)
	_background_save_after = Time.get_ticks_msec() + 350

func _save_background_preferences() -> void:
	_background_save_after = 0
	settings.save(settings_path)

func _begin_pip_image(window: Node3D) -> void:
	_pip_image_target = weakref(window)
	if not Engine.has_singleton("QuestPlayer"):
		if not _pip_image_dialog:
			_pip_image_dialog = FileDialog.new(); _pip_image_dialog.use_native_dialog = true
			_pip_image_dialog.access = FileDialog.ACCESS_FILESYSTEM; _pip_image_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			_pip_image_dialog.filters = PackedStringArray(["*.jpg,*.jpeg,*.png,*.webp;Images"])
			_pip_image_dialog.file_selected.connect(func(path): _on_pip_image_selected(path, path.get_file()))
			_pip_image_dialog.canceled.connect(_on_pip_image_cancelled)
			add_child(_pip_image_dialog)
		_pip_image_dialog.popup_centered_ratio(0.8); return
	_show_full_library()
	recent_menu.begin_image_picker()

func _on_pip_image_selected(uri: String, _title: String) -> void:
	var window: Node3D = _pip_image_target.get_ref() if _pip_image_target else null
	_pip_image_target = null
	if is_instance_valid(window) and video and not photo_active: video.pip.load_image(window, uri)
	_show_player_menu()

func _on_pip_image_cancelled() -> void:
	_pip_image_target = null
	_show_player_menu()

func _begin_subtitle_browse() -> void:
	if _subtitle_browse_session > 0 or not video or not recent_menu is LibraryMenu: return
	_subtitle_browse_session = video.media.session_id
	var location: Variant = settings.get_value("subtitles", "browse_location", {})
	_show_full_library()
	recent_menu.begin_subtitle_picker(location if location is Dictionary else {})

func _on_subtitle_selected(uri: String, _title: String, location: Dictionary) -> void:
	var id := _subtitle_browse_session
	if id <= 0: return
	_subtitle_browse_session = 0
	settings.set_value("subtitles", "browse_location", location); settings.save(settings_path)
	if video and id == video.media.session_id: video.select_subtitle_uri(uri)
	_return_from_subtitle_picker()

func _on_subtitle_picker_cancelled() -> void:
	if _subtitle_browse_session <= 0: return
	_subtitle_browse_session = 0
	_return_from_subtitle_picker()

func _return_from_subtitle_picker() -> void:
	_show_player_menu()
	if player_menu:
		player_menu.section = 0; player_menu._subtitle_open = true; player_menu.refresh()

func _begin_audio_import(destination: String) -> void:
	if _audio_import_pending: return
	_audio_import_pending = true; _audio_import_playlist = destination
	if not Engine.has_singleton("QuestPlayer"):
		if not _audio_file_dialog:
			_audio_file_dialog = FileDialog.new(); _audio_file_dialog.use_native_dialog = true
			_audio_file_dialog.access = FileDialog.ACCESS_FILESYSTEM; _audio_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
			_audio_file_dialog.filters = PackedStringArray(["*.mp3,*.ogg,*.wav,*.flac,*.dts,*.dtshd;Audio"])
			_audio_file_dialog.files_selected.connect(func(paths):
				var files: Array = []
				for path in paths: files.append({"uri": path, "title": str(path).get_file()})
				_on_audio_import_selected(files))
			_audio_file_dialog.canceled.connect(_on_audio_import_cancelled)
			add_child(_audio_file_dialog)
		_audio_file_dialog.popup_centered_ratio(0.7)
		return
	music_menu.dismiss(); _show_full_library()
	recent_menu.begin_audio_import()

func _on_audio_import_selected(files: Array) -> void:
	if not _audio_import_pending: return
	var destination := _audio_import_playlist
	_audio_import_pending = false; _audio_import_playlist = ""
	background_audio.import_tracks(files, destination)
	_show_music_menu(false, true)

func _on_audio_import_cancelled() -> void:
	if not _audio_import_pending: return
	_audio_import_pending = false; _audio_import_playlist = ""
	_show_music_menu(false, true)

func _show_music_management(from_photo: bool, from_video: bool = false) -> void:
	_show_music_menu(from_photo)
	_music_return_video = from_video
	if music_menu:
		music_menu.compact = false; music_menu.refresh(); _place_menu(music_menu)

func _show_music_menu(mini: bool = false, restore: bool = false) -> void:
	if not music_menu: return
	if not restore:
		_music_return_photo = mini and photo_active
		_music_return_video = false
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	if photo: photo.gallery.cancel_all()
	if recent_menu: recent_menu.dismiss()
	if player_menu: player_menu.dismiss()
	if restore: music_menu.visible = true; music_menu.refresh()
	else: music_menu.open(mini)
	_place_menu(music_menu); _menu_touched_ms = Time.get_ticks_msec()

func _close_music_menu() -> void:
	if music_menu: music_menu.dismiss()
	stick_controls.suspend()
	if puzzle_game and puzzle_game.active and puzzle_game.music_open:
		puzzle_game.return_from_music(); return
	if (_music_return_photo and photo_active) or (_music_return_video and not photo_active and _has_open_media()): _show_player_menu()
	else: _show_full_library()

func _favorite_state() -> Dictionary:
	var viewer := _viewer()
	var enabled: bool = viewer != null and not viewer.local_uri.is_empty()
	if enabled and viewer.local_uri.begins_with("comic://"): enabled = false
	if photo_active and photo: enabled = enabled and not photo.loading and (photo.gallery.mode in [0, 1] or photo.gallery.focus >= 0)
	return {"enabled": enabled, "selected": favorites.contains(viewer.local_uri) if enabled else false, "locked": favorites.locked}

func _toggle_favorite() -> void:
	if not photo_active and video and video.cast_token > 0: return
	if not _favorite_state().enabled: return
	if favorites.locked:
		_show_recent_menu(); recent_menu.collections.open_password("unlock", _toggle_favorite); return
	var viewer := _viewer()
	var location: Dictionary = viewer.source_location if not viewer.source_location.is_empty() else MediaLocation.infer(viewer.local_uri)
	if not favorites.toggle(viewer.local_uri, viewer.display_name, "image" if photo_active else "video", location):
		recent_menu.status = favorites.last_error
		if player_menu: player_menu.show_favorite_feedback(favorites.last_error)

func _update_favorite_session() -> void:
	if not favorites or not video or not photo: return
	var origin: String = photo.archive_origin if photo_active and photo.archive_mode else _viewer().local_uri
	if not favorites.locked: _playing_protected = favorites.protected and favorites.has_record(origin)
	if favorites.protected and not favorites.locked and photo_active and photo and photo.gallery.mode != 0:
		for index in photo.gallery.cards:
			if int(index) < photo.queue.size() and favorites.has_record(str(photo.queue[int(index)].uri)): _playing_protected = true; break
	_sync_native_privacy()

func _on_favorites_changed() -> void:
	if _migrating_favorites: return
	_sync_native_privacy()
	_migrate_protected_favorites()
	_update_favorite_session()
	if recent_menu and recent_menu.visible: recent_menu.refresh()
	for menu in [video_menu, photo_menu]:
		if menu and menu.visible and not menu.has_pointer_capture(): menu.refresh()

func _on_favorites_lock_changed() -> void:
	if not favorites.locked: return
	# Independent sampling must release its reader even when normal playback stays open.
	if video: video.narration.global_voice_command({"operation": "close"})
	if recent_menu:
		if recent_menu.voice_picker_mode: recent_menu.finish_voice_picker()
		if recent_menu.voice_manager.opened: recent_menu.voice_manager.close()
	if _playing_protected and video and photo:
		video.close_video(); photo.close_image(); video_queue.clear(); _playing_protected = false
		_show_full_library()
		recent_menu.section = recent_menu.Section.RECENT; recent_menu.collections.home_tab = 1; recent_menu.refresh()
	ThumbnailCache.clear_memory()
	if recent_menu:
		recent_menu.archives.close()
		recent_menu._cancel_covers(); recent_menu.collections.target.clear(); recent_menu.collections.selected_entry.clear(); recent_menu.collections.selected_location.clear()
	_sync_native_privacy()

func _migrate_protected_favorites() -> void:
	if _migrating_favorites or not favorites.protected or favorites.locked or not video or not photo: return
	_migrating_favorites = true
	if not video.recent_files.import_legacy(favorites):
		favorites.last_error = "Privacy cleanup failed"
		if recent_menu: recent_menu.status = favorites.last_error
	var keys := []
	for favorite in favorites.list_favorites():
		var uri: String = favorite.uri
		var key := Video.ModeMemory.key_for(uri)
		var success := true
		var has_public_data := false
		for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.whisper_memory, video.narration.memory, photo.mode_memory]:
			var memory_key: String = memory.entry_key(uri)
			if memory.entries.has(memory_key):
				has_public_data = true
				success = favorites.private_remember(uri, memory.directory.get_file() + "/" + memory._value_field(), memory.entries[memory_key].get(memory._value_field(), {})) and success
		if success and has_public_data: keys.append(key); ThumbnailCache.forget(uri)
		if success and has_public_data:
			for memory in [video.track_memory, video.subtitle_timing, video.whisper_memory, video.narration.memory]:
				var memory_key: String = memory.entry_key(uri)
				if not keys.has(memory_key): keys.append(memory_key)
	if not keys.is_empty():
		for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.whisper_memory, video.narration.memory, photo.mode_memory]:
			if not memory.purge_keys(keys):
				favorites.last_error = "Privacy cleanup failed"
				if recent_menu: recent_menu.status = favorites.last_error
	_migrating_favorites = false

func _clear_private_history(network_only: bool) -> void:
	if favorites and favorites.protected and favorites.locked:
		recent_menu.collections.open_password("unlock", _clear_private_history.bind(network_only)); return
	if recent_menu:
		if not recent_menu.clear_browse_history(network_only): _privacy_cleanup_failed(); return
	elif not directory_browse_memory.clear_history(network_only):
		_privacy_cleanup_failed(); return
	var keys := []
	var private_uris := []
	for entry in video.recent_files.list_recent():
		if network_only and Privacy.is_local(str(entry.uri)): continue
		keys.append(Video.ModeMemory.key_for(entry.uri)); video.recent_files.forget(entry.uri)
	if favorites:
		for entry in favorites.list_records():
			if not network_only or not Privacy.is_local(str(entry.uri)): private_uris.append(str(entry.uri))
		if not favorites.clear_recent_records(private_uris): _privacy_cleanup_failed(); return
	if not network_only: video.recent_files.clear_all()
	if not video.recent_files.purge_keys(keys): _privacy_cleanup_failed(); return
	if not network_only or not Privacy.is_local(video.local_uri):
		video.discard_history_thumbnail()
		if not video.local_uri.is_empty(): video.recent_files.suppressed[Video.ModeMemory.key_for(video.local_uri)] = true
	if recent_menu: recent_menu._cancel_covers()
	ThumbnailCache.clear(); preload("res://scripts/photo_preview_cache.gd").clear_disk()
	for name in ["events.jsonl", "capabilities_latest.json"]:
		var path: String = "user://diagnostics/" + name
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	if PlatformMethods.supports(platform_plugin, "clear_photo_cache"): platform_plugin.clear_photo_cache()
	if PlatformMethods.supports(platform_plugin, "clear_playback_private_data"): platform_plugin.clear_playback_private_data()
	video.recent_files.undo.clear()

func _clear_file_settings(network_only: bool) -> void:
	if favorites and favorites.protected and favorites.locked:
		recent_menu.collections.open_password("unlock", _clear_file_settings.bind(network_only)); return
	# Commit a held preview first, so a later pointer release cannot restore deleted settings.
	video.commit_stereo_view()
	if not network_only or not Privacy.is_local(video.local_uri): video.discard_file_settings()
	for memory in [video.mode_memory, video.track_memory, video.subtitle_timing, video.audio_timing,
			video.whisper_memory, video.narration.memory, photo.mode_memory]:
		var keys: Array = memory.entries.keys()
		if network_only:
			keys = keys.filter(func(key): return memory.entries[key].get("network", false))
		if not memory.purge_keys(keys): _privacy_cleanup_failed(); return
	if favorites and not favorites.clear_private_records(network_only, true): _privacy_cleanup_failed()

func _privacy_cleanup_failed() -> void:
	if recent_menu: recent_menu.status = I18n.t("Privacy cleanup failed")

func _sync_native_privacy() -> void:
	if PlatformMethods.supports(platform_plugin, "set_playback_privacy"):
		platform_plugin.set_playback_privacy(Privacy.mode, favorites != null and favorites.protected)

func _show_online_panoramas() -> void:
	if not preload("res://scripts/online_panorama_panel.gd").AVAILABLE: return
	_grab = {}; interface_move.cancel(); stick_controls.suspend()
	photo_hands.cancel(); memory_swipe.cancel()
	if photo.inspect: _close_photo_inspect(false)
	if recent_menu: recent_menu.dismiss()
	if player_menu: player_menu.dismiss()
	if not photo_active: video.close_video()
	photo_active = true; player_menu = photo_menu
	photo_menu.online.platform = platform_plugin
	_show_player_menu()
	photo_menu.online.open()

func _open_online_panorama(item: Dictionary, spherical: bool) -> void:
	var uri := str(item.get("uri",""))
	if not uri.begins_with("file://"): return
	_grab = {}; stick_controls.suspend(); photo_hands.cancel(); memory_swipe.cancel()
	video.close_video(); photo_active = true; player_menu = photo_menu
	photo.set_layout_mode(0)
	var location := MediaLocation.infer(uri)
	location["online_source"] = str(item.get("source",""))
	location["website"] = str(item.get("website",""))
	photo.open_image(uri,str(item.get("title","")),[],location,{"projection":"sphere" if spherical else "flat","layout":0})
	_show_player_menu()
