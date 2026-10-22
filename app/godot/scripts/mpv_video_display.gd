extends "res://scripts/media_surface.gd"
var source_location := {}

signal changed
signal thumbnail_ready(uri: String)
signal playback_failed
signal playback_completed
var _completed_end := ""
signal seek_presented(request_id: int, position_ms: int)

const PlatformMethods := preload("res://scripts/platform_methods.gd")
const I18n := preload("res://scripts/i18n.gd")
const PlaybackErrors := preload("res://scripts/playback_errors.gd")
const Loading := preload("res://scripts/media_loading.gd")
var _loading_status := {}
var _loading_poll_ms := 0
var _loading_started_ms := 0
var _buffering_started_ms := 0
var _loading_bytes := -1
const State := preload("res://scripts/mpv_media_state.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const PlaybackControl := preload("res://scripts/playback_control.gd")
const SeekPolicy := preload("res://scripts/seek_policy.gd")
var seek_mode := SeekPolicy.SPEED
var bookmark_seek_mode := SeekPolicy.GLOBAL
var _last_seek_mode := SeekPolicy.SPEED
const Log := preload("res://scripts/diagnostic_log.gd")
const PixelProbe := preload("res://scripts/mpv_pixel_probe.gd")
const SubtitleState := preload("res://scripts/mpv_subtitle_state.gd")
const BitmapSubtitles := preload("res://scripts/bitmap_subtitles.gd")
const AlphaEdge := preload("res://scripts/alpha_edge.gd")
var bitmap_subtitles := BitmapSubtitles.new()
const ModeMemory := preload("res://scripts/file_mode_memory.gd")
const TrackMemory := preload("res://scripts/file_track_memory.gd")
const SubtitleTiming := preload("res://scripts/file_subtitle_timing.gd")
const StereoView := preload("res://scripts/stereo_view.gd")
var viewing_eye := 0 # 0 binocular; 1/2 duplicate the logical left/right view after eye swap.
var stereo_horizontal := 0.0
var stereo_vertical := 0.0
var _stereo_view_dirty := false
var _mode_user_changed := false # Late USB identity must not replace this open's manual choices.
var _mode_memory_cleared := false # Automatic frames must not resurrect explicitly cleared settings.
const RecentFiles := preload("res://scripts/recent_files.gd")
const BookmarkStore := preload("res://scripts/bookmark_store.gd")
var bookmark_store := BookmarkStore.new()
var _bookmark_metadata: Dictionary = {}
var _bookmark_media_id := ""
var _bookmark_scope_sequence := 0
var _bookmark_cache_revision := -1
var _bookmark_rows: Array = []
var bookmark_last_added: Dictionary = {}
const Naming := preload("res://scripts/media_naming.gd")
const AUTOMATIC_PROFILE := "320x320"
const PROFILES := ["320x320", "384x216", "512x288", "384x384", "512x512", "256x144", "256x256"]

var cinema := preload("res://scripts/cinema_placement.gd").new()
const ScreenPresets := preload("res://scripts/screen_presets.gd")
var screen_preset := ""
var media := State.new()
var _spatial_video := false # Source type survives seek/effect session generations.
const SpatialMetadata := preload("res://scripts/spatial_video_metadata.gd")
var _spatial_metadata: Dictionary = {}
var spatial_auto_disparity := true
var control := PlaybackControl.new()
var platform: Object
var alpha_encoding := 1
var alpha_enabled := false
var alpha_requested := false
## Alpha mask edge from the player settings (AlphaEdge.bounds): shader uniform and compositor mask alike.
var alpha_edge := Vector2(0.0, 1.0)
## Realtime 2D->3D: a depth model drives per-eye parallax on mono sources (never with Alpha or SBS).
var depth_requested := false
var auto_depth := false # This file's conversion choice, retained while changing its projection.
var depth_enabled := false
const DEPTH_STRENGTHS := [0.5, 1.0, 1.5, 2.0]
const DepthStrength := preload("res://scripts/depth_strength.gd")
## Eye-width fraction of the full parallax at strength 1 (PTMediaServer), and the near value kept on
## the screen plane (nearer content comes out of the screen).
const DEPTH_SHIFT := 0.035
const DEPTH_CONVERGENCE := 0.35
var _depth_view_sent := ""
var depth_strength := DepthStrength.VIDEO_DEFAULT
var preferred_depth_strength := DepthStrength.VIDEO_DEFAULT # Global choice; diagnostic opens cannot replace it.
## Pick the clone-voice track (an extra M4A beside the video) whenever a video has one.
var prefer_clone_voice := false
## The file is an alpha-packed fisheye output (its name says so): the mask is in the frame and
## the Alpha switch shows it instead of running RVM.
var packed_file := false
var packed_alpha := false
## What the file name left open; filled from the first frame's shape, then cleared.
var _layout_pending: Variant = null
var _layout_basename := ""
var _rvm_alpha := false # the bound pair carries an inferred Alpha
var _clone_applied := false
var loop_enabled := false
var requested_play := true
var audio_track_id := -1
var audio_volume := 100.0
signal audio_options_changed(volume: float, muted: bool)
var audio_muted := false
const WhisperMemory := preload("res://scripts/file_whisper_memory.gd")
var whisper_memory := WhisperMemory.new()
var audio_whisper := 0 # 0 off; 1 compression only; 2..51 continuous boost.
var audio_boost_saved := 0 # Passive recall mark; never restores system volume.
const SystemVolume := preload("res://scripts/system_video_volume.gd")
var system_volume := SystemVolume.new(self)
var _whisper_command := 0
var _whisper_remember := false
var _whisper_restore_pending := false
var _whisper_restore_remember := false
var whisper_error := ""
var subtitles := SubtitleState.new()
const NarrationSettings := preload("res://scripts/narration_settings.gd")
var narration := NarrationSettings.new(self)
var subtitle_auto_load := true
var _subtitle_auto_pending := false
## Text subtitles: on the flat screen near its lower edge; in immersive modes floating at
## a video-local plane at [subtitle_distance], projected from each physical XR eye.
var playback_speed := 1.0
const SubtitleStyle := preload("res://scripts/subtitle_style.gd")
var subtitle_size := 1.0:
	set(value): subtitle_size = SubtitleStyle.size_ratio(value)
var subtitle_style := SubtitleStyle.DEFAULT:
	set(value): subtitle_style = SubtitleStyle.normalize(value)
var subtitle_flat_position := 0.0:
	set(value): subtitle_flat_position = clampf(value, 0.0, 1.0) if is_finite(value) else 0.0
var _subtitle_surface: MeshInstance3D
var _subtitle_patch: QuadMesh
var _subtitle_material: ShaderMaterial
var caption: Label3D
const ColorGrade := preload("res://scripts/color_grade.gd")
var color_grade := ColorGrade.new()
const SubtitleDepth := preload("res://scripts/subtitle_depth.gd")
var subtitle_distance := 5.0:
	set(value):
		subtitle_distance = SubtitleDepth.distance(value)
var subtitle_position := SubtitleDepth.DEFAULT_POSITION:
	set(value):
		subtitle_position = SubtitleDepth.position(value)
var subtitle_direction := 0:
	set(value):
		subtitle_direction = clampi(value, 0, 1)
const ProjectedSubtitles := preload("res://scripts/projected_subtitles.gd")
var projected_subtitles: Node
const CAPTION_DROP := 0.244 # radians below the line of sight (14 degrees)
var _subtitle_poll_ms := 0
var _subtitle_received_ms := 0
var mode_memory := ModeMemory.new()
var captures := preload("res://scripts/video_capture.gd").new(self)
var _capture_layout_pending := false
var _capture_preference_exists := false
var track_memory := TrackMemory.new()
const AudioTiming := preload("res://scripts/file_audio_timing.gd")
var audio_timing := AudioTiming.new()
var audio_delay := 0.0
var _audio_delay_pending := false
var _audio_timing_key := ""
var subtitle_timing := SubtitleTiming.new()
var subtitle_delay := 0.0
var _subtitle_delay_pending := false
var _subtitle_timing_key := ""
var subtitle_files: Array[String] = []
var subtitle_files_revision := 0
var subtitle_files_state := "idle"
var subtitle_file_error := ""
var subtitle_file_loading := ""
var _subtitle_file_sequence := 0
var _subtitle_list_request := 0
var _subtitle_load_request := 0
var _subtitle_loaded_track := 0
var _subtitle_load_restore := false
var _subtitle_restore_attempted := false
var _subtitle_files_session := 0
var _track_restore: Dictionary = {}
var _track_choices: Dictionary = {}
var _remember_file := false
var recent_files := RecentFiles.new()
## Settings: when off, nothing new is recorded and videos start from the beginning.
var history_enabled := true
var _history_started := false
var _file_permission_persisted := false
var _history_save_ms := 0
var _access_request := 0
var _access_pending: Dictionary = {}
var _audio_pending := false
var local_uri := ""
var display_name := ""
var picker_error := ""
var _picker_request := 0
var profile := AUTOMATIC_PROFILE # ROI default: one square input for full-eye and zoom windows
## Alpha model sizes offered in the settings: square inputs, as the ROI windows are.
const ALPHA_PROFILES := ["256x256", "320x320", "384x384", "512x512"]
## The Alpha model size chosen in the settings; every file opens with it.
var default_profile := AUTOMATIC_PROFILE
## A newly chosen size still compiling while Alpha plays: the session switches once it is ready.
var _profile_pending := ""
var _binding := Binding.new()
var pip := preload("res://scripts/video_pip.gd").new(self)
var _pending_pair: Dictionary = {}
var _pending_revision: Dictionary = {}
var _fixture := -1
var _recover := false
var _recover_ms := 0
var _waiting_first := false
const StallWatch := preload("res://scripts/playback_stall_watch.gd")
var _stall_watch := StallWatch.new()
var _opening_deadline_ms := 0
var _output_deadline_ms := 0
var _buffering_deadline_ms := 0
const OPEN_TIMEOUT_MS := 60000
const OUTPUT_TIMEOUT_MS := 30000
var _thumbnail_busy := false
## A layer copy pins nothing, so pairs keep presenting while it runs.
var _layer_thumbnail_busy := false
var _thumbnail_sequence := 0
var _thumbnail_result: Dictionary = {}
var _library_cover := ""
var _freeze_sequence := 0
var _freeze_request := 0
var _seek_trace: Array[Dictionary] = []
var _open_trace: Array[Dictionary] = []
var _debug_seek_delay_until_ms := 0
var _debug_request := 0
var _debug_commands: Array = []
var _debug_pairs: Array = []
var _debug_status: Dictionary = {}
var _debug_pixels: Dictionary = {}
var _debug_benchmark := false
var _debug_next_report_us := 0
var _pixel_request := 0
var _pixel_request_key := ""
var _pixel_busy := false
const VideoLayer := preload("res://scripts/video_layer.gd")
## Normal playback on the compositor video layer (user setting; the runtime must support it).
var layer_enabled := true
var video_layer: VideoLayer
var _layer_session := false # the native session decodes into the layer surface
## This session was opened on the layer surface; it may report the file incompatible before any frame.
var _layer_requested := false
var _network_interleave_compat := false
var _network_interleave_next := false
var _keep_interleave_during_close := false
var _eye_buffer_only := false # the next open stays on the eye-buffer path (one-shot)
## This file left the layer for a shader effect: back on the layer once the effect is off again.
var _layer_return_uri := ""
## This file cannot use the layer (Dolby Vision Profile 5, software decode): no automatic return.
var _layer_blocked_uri := ""
var _layer_generation := 0 # video_layer.generation the layer session's surface belongs to
## A seek on the layer: its surface keeps the last frame, so it stays shown until the target arrives.
var _layer_seek_hold := false
var _hole_material: ShaderMaterial
var _alignment_border: ShaderMaterial
var video_layer_shown := false # main renders the eye buffers transparent while true
## Source rotation the layer quad turns (a rotated file on the decoder surface keeps its coded orientation).
var layer_rotation := 0
## Immersive subtitles as a quad layer over the video: the caption canvas is copied into its own
## picture swapchain whenever it redraws, instead of a blended patch drawn into both eye buffers.
var _subtitle_on_layer := false
var _subtitle_layer_version := -1 # canvas version in the swapchain, -1 none
var _subtitle_layer_generation := -1
var _subtitle_layer_failed := false
var _subtitle_copy_after := -1 # frames_drawn after which a redrawn canvas has rendered
var _subtitle_texture: ImageTexture
## Debug prototype of Alpha plan B (compositor alpha blending): 0 off, 1 a test mask over what lies
## beneath (passthrough), 2 the same over a test backdrop layer, so a capture shows the blend.
var alpha_probe := 0
## Alpha on the layer: Alpha keeps the decoder surface layer and RVM's mask becomes a compositor mask
## layer beneath it. The platform allows it (read once); see _layer_alpha() for the runtime's part.
var _layer_alpha_allowed := false
## This session's decoder fans its frames out for Alpha (opened with Alpha on the layer): only such a
## session can turn Alpha on in place. Any other layer session reopens with Alpha instead.
var _layer_alpha_host := false
var _revision_refused_logged := false
var _alpha_probe_uploaded := false
## Flat-screen PGS cues: the bitmap in the subtitle swapchain, padded to a size bucket so a new cue
## rarely recreates it, shown as a quad (or a cylinder section on a curved screen) over the video.
var _bitmap_layer_texture: ImageTexture # the cue texture last copied
var _bitmap_layer_size := Vector2i.ZERO
var _picture_token := -1 # the 2D->3D pair last copied into the picture layer
## Frames to copy the held pair again: a strength change re-warps it in place, asynchronously.
var _picture_refresh := 0
## Profile 5 and software decode: MPV's RGBA frames shown on the picture layer this frame.
var _frame_picture := false
## The picture layer could not take this file's frames (swapchain size, copy): eye buffers until the next open.
var _frame_picture_failed := false
## Fisheye has no compositor layer shape. The plugin remaps each new frame to equirect once (at the
## video rate) straight into the equirect picture layer, instead of the lens being sampled into both
## eye buffers at every display refresh: the compositor then holds 120 Hz and an even cadence.
var _fisheye_picture := false
var _processed_picture := false
var _fisheye_failed := false
## Session whose remapped picture is on the layer (0: none yet, the eye buffers show the frame).
var _fisheye_session := 0
var _fisheye_parameters := PackedFloat32Array()
var _fisheye_generation := -1
## Picture density of the remapped views. The eye buffers resolved about 16 pixels per degree on
## Quest 3 (1680 px over ~100 degrees); sampling the 8K lens at full size cost twice the pixels for
## detail the eye-buffer path never showed, and made the remap the frame's bottleneck.
const FISHEYE_PIXELS_PER_DEGREE := VideoLayer.FISHEYE_PIXELS_PER_DEGREE
## Debug A/B only (0 = FISHEYE_PIXELS_PER_DEGREE).
var debug_fisheye_density := 0.0
## The remap rides on the app's frames. A source too heavy for the fast panel (8K60 AV1 at 115 Mbit/s
## kept Quest 3 near 80 of 120 frames) moves this session to the slower rates: once, never back.
const FISHEYE_SLOW_RATIO := 0.9
const FISHEYE_SLOW_SECONDS := 5
var fisheye_overloaded := false
var _fisheye_overloaded_uri := ""
var _fisheye_slow_seconds := 0
var _fisheye_checked_ms := 0

func _ready() -> void:
	mode_memory.load_saved()
	track_memory.load_saved()
	subtitle_timing.load_saved()
	audio_timing.load_saved()
	whisper_memory.load_saved()
	narration.memory.load_saved()
	recent_files.load_saved()
	initialize_surface(load("res://shaders/video_rvm_pair.gdshader"))
	color_grade.apply(material)
	caption = Label3D.new()
	caption.name = "Subtitles"
	caption.font_size = 40
	caption.pixel_size = 0.0015
	caption.outline_size = 8
	caption.no_depth_test = true
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	caption.width = 700
	caption.visible = false
	add_child(caption)
	projected_subtitles = ProjectedSubtitles.new()
	add_child(projected_subtitles)
	_subtitle_surface = MeshInstance3D.new()
	_subtitle_material = ShaderMaterial.new()
	_subtitle_material.shader = preload("res://shaders/subtitle_surface.gdshader")
	_subtitle_material.render_priority = 1
	_subtitle_surface.material_override = _subtitle_material
	_subtitle_surface.visible = false
	add_child(_subtitle_surface)
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		platform = Engine.get_singleton("QuestPlayer")
		_layer_alpha_allowed = PlatformMethods.supports(platform, "video_layer_alpha") and bool(platform.video_layer_alpha())
		if PlatformMethods.supports(platform, "set_mpv_alpha_edge"): platform.set_mpv_alpha_edge(alpha_edge.x, alpha_edge.y)
		platform.connect("local_video_selected", _on_selected)
		platform.connect("local_video_access", _on_local_access)
		platform.connect("mpv_pair_available", _on_pair)
		platform.connect("mpv_state", _on_state)
		if platform.has_signal("mpv_subtitle_files"):
			platform.connect("mpv_subtitle_files", _on_subtitle_files)
		platform.connect("mpv_error", _on_error)
		platform.connect("mpv_detach", _on_detach)
		platform.connect("mpv_released", _on_released)
		platform.connect("mpv_debug_command", _on_debug_command)
		platform.connect("mpv_pixel_mask", _on_pixel_mask)
		platform.connect("mpv_frozen_pair", _on_frozen_pair)
		if platform.has_signal("rvm_warmup"):
			platform.connect("rvm_warmup", _on_rvm_warmup)
		if PlatformMethods.supports(platform, "bind_video_layer"):
			video_layer = VideoLayer.new(platform)
	_hole_material = ShaderMaterial.new()
	_hole_material.shader = preload("res://shaders/video_layer_hole.gdshader")
	_hole_material.render_priority = -128
	_alignment_border = ShaderMaterial.new()
	_alignment_border.shader = preload("res://shaders/video_layer_border.gdshader")
	_alignment_border.render_priority = -127
	# First photo use should not queue behind unrelated video-model cold compilation.
	_apply_geometry()

# First use of an Alpha profile compiles/tunes GPU kernels; start it before playback.
var rvm_warmup := {}
func _warm_rvm() -> void:
	if local_uri.is_empty(): return
	# JNISingleton.has_method() does not see Java plugin methods; test doubles never set this singleton.
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").warm_rvm(profile)

## The RVM model changed: warm it and reopen an Alpha session so it takes effect now.
## First usable displayed source frame, for every stable library URI. No second video decoder.
var _thumb_after_ms := -1          # media position to try; -1: already cached/not wanted
var _thumb_tries := 0

static func _thumbnail_source(uri: String) -> bool:
	return not ModeMemory.key_for(uri).is_empty()

func _maybe_capture_thumbnail() -> void:
	if _thumb_after_ms < 0 or _thumbnail_busy or _layer_thumbnail_busy or _pixel_busy or _waiting_first or not _pending_revision.is_empty() \
		or media.state not in ["playing", "paused", "ended"] or media.last_pair.is_empty() \
		or not (video_layer_shown if _binding.layer else _binding.material != null):
		return
	if int(media.last_pair.get("pts_us", 0)) / 1000 < _thumb_after_ms:
		return
	var uri := local_uri
	var sequence := _thumbnail_sequence
	var pair := media.last_pair.duplicate(true)
	var layer := _binding.layer
	var image: Image
	var failure := ""
	if layer:
		_layer_thumbnail_busy = true
		_thumb_after_ms = -1
		var copied: Array = await _layer_thumbnail(pair)
		_layer_thumbnail_busy = false
		image = copied[0]; failure = copied[1]
	else:
		if not platform.pin_mpv_pair(int(pair.session_id), int(pair.slot_token)): return
		_thumbnail_busy = true
		_thumb_after_ms = -1
		# Own wrappers/ExternalTexture, so a close cannot detach/rebind our readback source.
		var binding := Binding.new()
		var target := ShaderMaterial.new()
		if not binding.bind(target, pair):
			platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
			_thumbnail_busy = false
			return
		var stereo := bool(pair.get("stereo_sbs", false)) or binding.warped
		var tb := stereo and bool(pair.get("top_bottom", false))
		var eye := Vector2(float(pair.width) * (2.0 if binding.warped else 1.0) * (0.5 if stereo and not tb else 1.0), float(pair.height) * (0.5 if tb else 1.0))
		var scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
		image = await Thumbnails.capture(self, binding.color_texture(), str(binding.ticket.get("color_target", "")) == "external",
			stereo, Thumbnails.crop_for(geometry, eye), Vector2(float(scale[0]), float(scale[1])), tb)
		binding.unbind()
		platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
	_thumbnail_busy = false
	if sequence != _thumbnail_sequence or uri != local_uri: return
	if not image or image.is_empty():
		_thumbnail_result = {"state": "capture_failed", "layer": layer, "reason": failure}
		# A runtime whose layer surface cannot be copied fails every time: stop after a few tries.
		_thumb_tries += int(layer)
		_thumb_after_ms = int(pair.pts_us) / 1000 + 2000 if _thumb_tries < 3 else -1
		return
	# A fade or a black opening says nothing about the video: try again a little later.
	var small := image.duplicate() as Image
	small.resize(16, 9, Image.INTERPOLATE_BILINEAR)
	var light := 0.0
	for y in 9:
		for x in 16:
			light += small.get_pixel(x, y).get_luminance()
	_thumb_tries += 1
	if light / 144.0 < 0.06 and _thumb_tries < 3:
		_thumb_after_ms = int(pair.pts_us) / 1000 + 2000
		return
	var stored := Thumbnails.store(uri, image)
	_thumbnail_result = {"state": "stored" if stored else "store_failed", "pts_us": int(pair.pts_us),
		"width": image.get_width(), "height": image.get_height(), "source_epoch": int(pair.source_epoch)}
	if stored: thumbnail_ready.emit(uri)
	_write_debug_report()

## A layer session's picture is only on the decoder surface: the platform copies its last buffer
## once, cropped like Thumbnails.capture (left eye, crop_for). Returns [Image or null, failure].
func _layer_thumbnail(pair: Dictionary) -> Array:
	var stereo := bool(pair.get("stereo_sbs", false))
	var tb := stereo and bool(pair.get("top_bottom", false))
	var crop := Thumbnails.crop_for(geometry, Vector2(float(pair.width) * (0.5 if stereo and not tb else 1.0), float(pair.height) * (0.5 if tb else 1.0)))
	# Eye UV to frame UV: the left eye is the left half, or the top one.
	if tb:
		crop.y *= 0.5; crop.w *= 0.5
	elif stereo:
		crop.x *= 0.5; crop.z *= 0.5
	var size := Thumbnails.SIZE
	var request: int = platform.request_mpv_layer_thumbnail(int(pair.session_id), int(pair.width), int(pair.height),
		int(pair.get("surface_rotation_degrees", 0)), PackedFloat32Array([crop.x, crop.y, crop.z, crop.w]), size.x, size.y)
	if request <= 0: return [null, "not_requested"]
	var deadline := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var state: String = platform.get_mpv_layer_thumbnail_state(request)
		if state == "pending": continue
		if state != "ready": return [null, state]
		var pixels: PackedByteArray = platform.take_mpv_layer_thumbnail(request)
		if pixels.size() != size.x * size.y * 4: return [null, "size"]
		return [Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, pixels), ""]
	return [null, "timeout"]

## Profiles compiling right now (any model), from the warmup reports.
var warming := {}

## Alpha on [value] starts at once; a cold profile first compiles for ~40 s per model.
func profile_ready(value: String) -> bool:
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		return bool(Engine.get_singleton("QuestPlayer").rvm_profile_ready(value))
	return true

## The settings chose a new Alpha model size. Its first use compiles for ~40 s: warm it now, with or
## without a video, and keep a playing Alpha session on its current size until the new one is ready.
func select_profile(value: String) -> void:
	if not value in ALPHA_PROFILES: return
	default_profile = value
	_profile_pending = ""
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").warm_rvm(value)
	if not alpha_requested or local_uri.is_empty():
		profile = value
	elif profile_ready(value):
		set_profile(value)
	else:
		_profile_pending = value
	changed.emit()

func reload_rvm() -> void:
	_warm_rvm()
	if alpha_requested:
		_request_revision()

func _on_rvm_warmup(payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if result is Dictionary:
		rvm_warmup = result
		var key := str(result.get("profile_key", ""))
		if str(result.get("state", "")) == "warming":
			warming[key] = true
		else:
			warming.erase(key)
		if key == _profile_pending and str(result.get("state", "")) in ["ready", "cached"]:
			_profile_pending = ""
			if alpha_requested and not local_uri.is_empty(): set_profile(key)
			else: profile = key
		DiagnosticLog.record("rvm_warmup", result)
		changed.emit()

func pick_file() -> void:
	cancel_pending_open()
	picker_error = ""
	if platform:
		_picker_request = platform.pick_local_video()
		if _picker_request <= 0:
			picker_error = "File picker unavailable"
	else:
		picker_error = "Quest local playback required"
	changed.emit()

func _on_selected(payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or _picker_request <= 0 or result.get("picker_request", -1) != _picker_request:
		return
	if result.get("state") == "selected":
		_picker_request = 0
		requested_play = true
		var uri := str(result.uri)
		if open_local(uri, str(result.get("display_name", "Local video")), _resume(uri), true, false, "", {"basename": result.get("display_name", "")}):
			_file_permission_persisted = bool(result.get("persisted_permission", false))
	elif result.get("state") == "error":
		_picker_request = 0
		picker_error = str(result.get("error", "Local file unavailable"))
	elif result.get("state") == "cancelled":
		_picker_request = 0
		picker_error = ""
	elif result.get("state") == "checking":
		picker_error = "Checking file access..."
	changed.emit()
	if result.get("state") == "error": playback_failed.emit()

func cancel_pending_open() -> void:
	var picker := _picker_request
	_picker_request = 0
	if picker > 0 and platform:
		platform.cancel_local_video_pick(picker)
	var previous := _access_request
	_access_request = 0
	_access_pending = {}
	if previous > 0 and platform:
		platform.cancel_local_video_access(previous)

# Library selection: MediaStore content URIs are readable through the media permission;
# network URIs (smb://, DLNA http) have no document grant to check.
func open_library(uri: String, title: String, metadata: Dictionary = {}, from_start: bool = false) -> bool:
	var cover := str(metadata.get("cover", recent_files.lookup(uri).get("cover", "")))
	var opened := false
	if uri.begins_with("medialib://") and not metadata.is_empty():
		requested_play = true
		var start: int = int(metadata.get("start_ms", -1))
		opened = open_local(uri, title, 0 if from_start else (_resume(uri) if start < 0 else start), true, false, str(metadata.get("basename", "")), metadata)
	elif not recent_files.lookup(uri).is_empty():
		opened = open_recent(uri, from_start, metadata)
	else:
		requested_play = true
		opened = open_local(uri, title, 0, true, false, "", metadata)
	if opened and RecentFiles.valid_cover(cover): _library_cover = cover
	return opened

func open_recent(uri: String, from_start: bool = false, metadata: Dictionary = {}) -> bool:
	var entry := recent_files.lookup(uri)
	if entry.is_empty() or not platform:
		return false
	if not uri.begins_with("content://"):
		requested_play = true
		return open_local(uri, str(entry.title), 0 if from_start else _resume(uri), true, false, "", metadata)
	cancel_pending_open()
	_access_pending = {"uri": uri, "title": str(entry.title), "start_ms": 0 if from_start else _resume(uri), "metadata": metadata.duplicate(true)}
	_access_request = platform.request_local_video_access(uri)
	if _access_request <= 0:
		_access_pending = {}
		picker_error = "File access check busy or unavailable"
		changed.emit()
		playback_failed.emit()
		return false
	picker_error = "Checking file access..."
	changed.emit()
	return true

func _on_local_access(id: int, payload: String) -> void:
	if id != _access_request or _access_pending.is_empty():
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		return
	var result: Dictionary = parser.data
	if result.get("uri") != _access_pending.uri:
		return
	var pending := _access_pending.duplicate(true)
	_access_pending = {}
	_access_request = 0
	if result.get("state") != "readable" or not result.get("persisted_permission") is bool:
		picker_error = str(result.get("error", "File unavailable; select it again"))
		changed.emit()
		playback_failed.emit()
		return
	requested_play = true
	var metadata: Dictionary = pending.get("metadata", {}).duplicate(true)
	if not str(result.get("display_name", "")).is_empty(): metadata.basename = result.display_name
	if open_local(str(pending.uri), str(pending.title), int(pending.start_ms), true, false, "", metadata):
		_file_permission_persisted = result.persisted_permission

func play_calibration_clip() -> void:
	_fixture = (_fixture + 1) % 3
	var filename: String = ["mp03_frame_identity", "c03_sbs_grid", "mp06_audio_clock"][_fixture]
	var source := FileAccess.open("res://media/%s.mp4" % filename, FileAccess.READ)
	if not source:
		picker_error = "Calibration video unavailable"
		changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://fixtures"))
	var path := "user://fixtures/%s.mp4" % filename
	var target := FileAccess.open(path, FileAccess.WRITE)
	if not target:
		return
	while source.get_position() < source.get_length():
		target.store_buffer(source.get_buffer(65536))
	target.close()
	source.close()
	stereo_sbs = true
	geometry = Geometry.Geometry.FLAT
	requested_play = true
	open_local("file://" + ProjectSettings.globalize_path(path), filename, 0, false)

func open_local(uri: String, title: String, start_ms: int = 0, restore_mode: bool = true, alpha: bool = false, basename: String = "", metadata: Dictionary = {}) -> bool:
	_completed_end = ""
	var network_interleave := _network_interleave_next
	_network_interleave_next = false
	source_location = preload("res://scripts/media_location.gd").clean(metadata.get("location", {}))
	if source_location.is_empty(): source_location = preload("res://scripts/media_location.gd").infer(uri)
	recent_files.suppressed.erase(ModeMemory.key_for(uri))
	_open_trace = [{"stage": "requested", "time_ms": Time.get_ticks_msec(), "start_ms": start_ms}]
	if not platform or not platform.mpv_supported():
		picker_error = "MPV playback backend unavailable"
		changed.emit()
		playback_failed.emit()
		return false
	cancel_pending_open()
	_keep_interleave_during_close = network_interleave
	close_video()
	_keep_interleave_during_close = false
	_capture_layout_pending = restore_mode
	_capture_preference_exists = not mode_memory.lookup(uri).is_empty()
	# Alpha-packed and Alpha-wanted files say so in their names (PTMediaServer / DeoVR markers).
	_layout_basename = basename if not basename.is_empty() else (title if not title.is_empty() else uri.uri_decode().get_file())
	var stated := Naming.from_metadata(_layout_basename, metadata)
	if uri.begins_with("medialib://"): stated.erase("alpha")
	packed_file = bool(stated.get("packed", false))
	packed_alpha = packed_file and (alpha or restore_mode)
	_layout_pending = null
	if restore_mode:
		# Ignore legacy per-file model choices: every file uses the size chosen in the settings.
		profile = default_profile
		depth_strength = preferred_depth_strength
		var saved := mode_memory.lookup(uri)
		if not saved.is_empty():
			# The user's own choice for this file wins over its name and shape.
			_restore_saved_mode(saved)
		elif not mode_lock.is_empty() and not stated.has("geometry") and not stated.has("stereo"):
			geometry = int(mode_lock.geometry)
			stereo_sbs = int(mode_lock.layout) != 0
			top_bottom = int(mode_lock.layout) in [2, 4]
			stereo_half = int(mode_lock.layout) in [3, 4]
			fisheye_fov = int(mode_lock.fisheye_fov)
			swap_eyes = false
			depth_requested = false # Projection/layout locks never enable conversion on other files.
		else:
			depth_requested = false
			geometry = int(stated.get("geometry", Geometry.Geometry.FLAT))
			stereo_sbs = bool(stated.get("stereo", geometry in [Geometry.Geometry.HALF_EQUIRECT, Geometry.Geometry.FISHEYE]))
			top_bottom = stereo_sbs and bool(stated.get("top_bottom", false))
			stereo_half = stereo_sbs and bool(stated.get("stereo_half", false))
			fisheye_fov = int(stated.get("fisheye_fov", 180))
			swap_eyes = bool(stated.get("swap", false))
			if not stated.has("geometry") or not stated.has("stereo") or (geometry in [Geometry.Geometry.FLAT, Geometry.Geometry.FISHEYE] and not stated.has("stereo_half")):
				_layout_pending = stated
		auto_depth = depth_requested
	# Manual Alpha is never restored from memory; explicit filename markers still opt in.
	alpha_requested = (alpha or (restore_mode and bool(stated.get("alpha", false)))) and not packed_file
	_thumb_tries = 0
	_thumbnail_result = {}
	_thumb_after_ms = -1
	# A server cover (DLNA albumArt, media servers) is the library picture: no frame is needed.
	var server_cover := str(metadata.get("cover", recent_files.lookup(uri).get("cover", "")))
	if _thumbnail_source(uri) and Thumbnails.texture(uri) == null and not RecentFiles.valid_cover(server_cover):
		_thumb_after_ms = 0
	local_uri = uri
	var saved_whisper := whisper_memory.lookup(uri) if restore_mode else {}
	audio_whisper = 1 if saved_whisper.get("enabled", false) else 0
	audio_boost_saved = int(saved_whisper.get("boost", 0))
	_whisper_command = 0
	_whisper_remember = false
	_whisper_restore_pending = audio_whisper > 0
	_whisper_restore_remember = false
	whisper_error = ""
	_network_interleave_compat = network_interleave
	_warm_rvm()
	display_name = title
	_bookmark_metadata = metadata.duplicate(true)
	if not basename.is_empty(): _bookmark_metadata.basename = basename
	if str(_bookmark_metadata.get("basename", "")).is_empty():
		if uri.begins_with("file://") or uri.begins_with("smb://") or uri.begins_with("cloud://"):
			_bookmark_metadata.basename = uri.uri_decode().get_file()
		elif uri.begins_with("content://"):
			_bookmark_metadata.basename = title
	if uri.begins_with("file://"):
		var source := FileAccess.open(uri.trim_prefix("file://").uri_decode(), FileAccess.READ)
		if source: _bookmark_metadata.size = source.get_length()
	_bookmark_resolve()
	depth_requested = auto_depth and geometry == Geometry.Geometry.FLAT and not stereo_sbs and not alpha_requested
	if depth_requested and OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").warm_depth()
	_last_seek_mode = SeekPolicy.normalize(seek_mode)
	# The cover comes from a displayed frame (never a second decoder). The layer has none to read, so a
	# layer session leaves it to the next eye-buffer session (Alpha, 3D, effects) instead of switching.
	var layer := _layer_wanted() and not _eye_buffer_only and uri != _layer_blocked_uri
	_layer_alpha_host = layer and alpha_requested and _layer_alpha()
	# Opened in the eye buffers only for a setting of the moment (colour grade, 3D, Alpha): go to the
	# layer once that setting is undone, as a session moved off the layer does.
	if not layer and not _eye_buffer_only and uri != _layer_blocked_uri and layer_enabled \
		and video_layer != null and video_layer.available():
		_layer_return_uri = uri
	_eye_buffer_only = false
	_layer_session = false
	_frame_picture_failed = false
	_fisheye_failed = false
	_fisheye_session = 0
	# Reopens of the same file (loop, seeks, mode changes) keep the decision: no retry, no switches.
	if uri != _fisheye_overloaded_uri: fisheye_overloaded = false
	_fisheye_slow_seconds = 0
	_layer_seek_hold = false
	if layer: _layer_generation = video_layer.generation
	_layer_requested = layer
	if PlatformMethods.supports(platform, "set_mpv_video_layer"):
		platform.set_mpv_video_layer(layer)
	if PlatformMethods.supports(platform, "set_mpv_interleave_compat"):
		platform.set_mpv_interleave_compat(network_interleave)
	var id: int = platform.open_mpv_video(uri, maxi(start_ms, 0), stereo_sbs, profile, alpha_requested, true, depth_requested,
		stereo_sbs and top_bottom, SeekPolicy.normalize(seek_mode) == SeekPolicy.EXACT)
	media.begin(id)
	narration.reset_source(uri)
	playback_speed = 1.0
	screen_rotation = 0.0
	if PlatformMethods.supports(platform, "set_mpv_speed"): platform.set_mpv_speed(id, playback_speed)
	_open_trace.append({"stage": "dispatched", "time_ms": Time.get_ticks_msec(), "session_id": id})
	_remember_file = restore_mode and id > 0
	_history_started = false
	_file_permission_persisted = false
	audio_track_id = -1
	_audio_timing_key = ""
	audio_delay = 0.0
	_audio_delay_pending = true
	_clone_applied = false
	subtitles.select(0)
	subtitles.clear(true)
	_subtitle_auto_pending = subtitle_auto_load and restore_mode
	_reset_subtitle_files()
	_subtitle_timing_key = ""
	_queue_track_restore(track_memory.lookup(uri) if restore_mode else {})
	subtitle_delay = float(subtitle_timing.lookup(uri).get("delay_seconds", 0.0)) if restore_mode else 0.0
	subtitles.set_delay(subtitle_delay)
	_subtitle_delay_pending = true
	_apply_subtitle_delay()
	bitmap_subtitles.clear(material)
	if _subtitle_surface: _subtitle_surface.visible = false
	reset_view() # every video starts straight ahead at its natural size
	_audio_pending = id > 0
	if id <= 0:
		picker_error = "Player resources are still closing"
	else:
		_waiting_first = true
		_opening_deadline_ms = Time.get_ticks_msec() + OPEN_TIMEOUT_MS
		_loading_started_ms = Time.get_ticks_msec()
		_loading_status = {"remote": Loading.remote(uri), "phase": "connecting"}
		_loading_poll_ms = 0
		_loading_bytes = -1
		platform.set_mpv_playing(id, false)
		picker_error = ""
	changed.emit()
	if id <= 0: playback_failed.emit()
	return id > 0

func _unbind() -> void:
	var previous: Dictionary = _binding.unbind()
	if platform and not previous.is_empty():
		if int(previous.get("frozen_frame_id", 0)) > 0:
			platform.release_mpv_frozen_frame(int(previous.frozen_frame_id))
		else:
			platform.detach_mpv_pair(int(previous.session_id), int(previous.slot_token))
	alpha_enabled = false
	_rvm_alpha = false
	depth_enabled = false
	panel.visible = false
	if caption:
		caption.visible = false

func close_video() -> void:
	if not pip.reopening: pip.clear()
	else: pip.cancel_interaction()
	captures.stop()
	if not _keep_interleave_during_close and PlatformMethods.supports(platform, "set_mpv_interleave_compat"):
		platform.set_mpv_interleave_compat(false)
	_network_interleave_compat = false
	_network_interleave_next = false
	commit_stereo_view()
	viewing_eye = 0
	stereo_horizontal = 0.0
	stereo_vertical = 0.0
	_spatial_video = false
	_spatial_metadata.clear()
	spatial_auto_disparity = true
	_apply_stereo_view()
	media.format.erase("spatial_video")
	_bookmark_scope_sequence += 1
	_bookmark_media_id = ""
	_bookmark_metadata.clear()
	_bookmark_rows.clear()
	_bookmark_cache_revision = -1
	_thumbnail_sequence += 1
	_library_cover = ""
	_record_history(true)
	cancel_pending_open()
	if mode_memory.dirty:
		mode_memory.save()
	if track_memory.dirty:
		track_memory.save()
	if subtitle_timing.dirty:
		subtitle_timing.save()
	if audio_timing.dirty: audio_timing.save()
	if whisper_memory.dirty: whisper_memory.save()
	if narration.memory.dirty: narration.memory.save()
	if recent_files.dirty:
		recent_files.save()
	_unbind()
	_layer_session = false
	_layer_requested = false # this close must not reopen the file again
	_layer_seek_hold = false
	_update_layer()
	_picture_token = -1
	if PlatformMethods.supports(platform, "destroy_layer_image"):
		platform.destroy_layer_image(VideoLayer.PICTURE_SLOT)
		platform.destroy_layer_image(VideoLayer.SUBTITLE_SLOT)
		_subtitle_layer_version = -1; _bitmap_layer_texture = null; _bitmap_layer_size = Vector2i.ZERO
		_subtitle_layer_failed = false
		if video_layer:
			video_layer.invalidate()
			video_layer.picture_size = Vector2.ZERO
	if platform and media.session_id > 0:
		platform.close_mpv_video(media.session_id)
	media.close()
	narration.reset_source()
	_pending_pair = {}
	_pending_revision = {}
	_freeze_request = 0
	_debug_seek_delay_until_ms = 0
	_waiting_first = false
	_audio_pending = false
	_opening_deadline_ms = 0
	_whisper_command = 0; _whisper_remember = false; _whisper_restore_pending = false
	_whisper_restore_remember = false
	audio_whisper = 0; audio_boost_saved = 0; whisper_error = ""
	system_volume.cancel_source()
	_output_deadline_ms = 0
	_buffering_deadline_ms = 0
	_track_restore.clear()
	_track_choices.clear()
	_reset_subtitle_files()
	control.close()
	_remember_file = false
	_mode_user_changed = false
	_mode_memory_cleared = false
	subtitles.clear(true)
	bitmap_subtitles.clear(material)
	if _subtitle_surface: _subtitle_surface.visible = false
	changed.emit()

func checkpoint_playback() -> void:
	commit_stereo_view()
	_record_history(true)

func clear_history() -> void:
	if recent_files.clear_all() and not recent_files.save():
		Log.record("recent_file_save_failed", {"error": recent_files.last_error})
	_history_started = false

func _resume(uri: String) -> int:
	return recent_files.resume_position(uri) if history_enabled else 0

func discard_history_thumbnail() -> void:
	_thumbnail_sequence += 1
	_thumb_after_ms = -1

func discard_file_settings() -> void:
	commit_stereo_view()
	_mode_memory_cleared = true
	_whisper_remember = false
	_whisper_restore_remember = false

func _record_history(force: bool = false) -> void:
	if recent_files.suppressed.has(ModeMemory.key_for(local_uri)): return
	if not history_enabled or not _remember_file or not media.accepts(media.session_id) or media.last_pair.is_empty() \
		or not media.last_pair.get("source_pts_verified", false) or not panel.visible:
		return
	var pair: Dictionary = media.last_pair
	if int(pair.get("session_id", 0)) != media.session_id or int(pair.get("generation", 0)) != media.generation:
		return
	if not _history_started:
		if not recent_files.opened(local_uri, display_name, _file_permission_persisted):
			return
		recent_files.set_location(local_uri, source_location if not source_location.is_empty() else preload("res://scripts/media_location.gd").infer(local_uri))
		_history_started = true
		recent_files.set_cover(local_uri, _library_cover)
		force = true
	var now := Time.get_ticks_msec()
	if not force and now < _history_save_ms:
		return
	var position_ms := clampi(int(float(pair.pts_us) / 1000.0), 0, 2147483647)
	recent_files.progress(local_uri, position_ms, control.duration_ms, media.state == "ended")
	_history_save_ms = now + 5000
	if not recent_files.save():
		Log.record("recent_file_save_failed", {"error": recent_files.last_error})

func _request_revision(position_ms: int = -1, mode: String = "") -> void:
	if position_ms >= 0: captures.stop()
	if not platform or not media.accepts(media.session_id):
		return
	_pending_revision = {"stereo": stereo_sbs, "alpha": alpha_requested, "profile": profile, "position_ms": position_ms,
		"depth": depth_requested and not alpha_requested and not stereo_sbs, "top_bottom": stereo_sbs and top_bottom,
		"seek_mode": SeekPolicy.normalize(seek_mode if mode.is_empty() else mode)}
	platform.set_mpv_playing(media.session_id, false)
	_waiting_first = true
	_output_deadline_ms = Time.get_ticks_msec() + OUTPUT_TIMEOUT_MS
	_loading_started_ms = Time.get_ticks_msec(); _loading_poll_ms = 0
	subtitles.clear()
	bitmap_subtitles.clear(material)
	if _subtitle_surface: _subtitle_surface.visible = false
	if caption:
		caption.visible = false
	if position_ms >= 0: _seek_event("requested")
	_try_revision()

func _start_seek_freeze() -> bool:
	if _layer_session: return false # the layer surface keeps its frame until the new one
	# Capture exactly once before seek/flush; rapid requests share this frame.
	if _freeze_request == 0 and not _binding.ticket.is_empty() and not _is_frozen():
		var capable := Engine.has_singleton("QuestPlayer") or platform.has_method("freeze_mpv_pair")
		if capable:
			_freeze_sequence += 1
			_freeze_request = _freeze_sequence
			if not platform.freeze_mpv_pair(media.session_id, int(_binding.ticket.slot_token), _freeze_request):
				_abort_frozen_seek("Frame capture request rejected")
			return true
	return false

func _is_frozen() -> bool:
	return int(_binding.ticket.get("frozen_frame_id", 0)) > 0

func _seek_event(stage: String) -> void:
	_seek_trace.append({"stage": stage, "time_ms": Time.get_ticks_msec(), "visible": panel != null and panel.visible,
		"frozen": _is_frozen(), "capture_pending": _freeze_request > 0,
		"session_id": media.session_id, "target_ms": control.target_ms,
		"displayed_pts_us": int(_binding.ticket.get("pts_us", -1)),
		"freeze_copy_us": int(_binding.ticket.get("freeze_copy_us", 0))})
	if _seek_trace.size() > 64: _seek_trace.pop_front()
	_write_debug_report()

func _abort_frozen_seek(reason: String) -> void:
	_freeze_request = 0
	_pending_revision = {}
	_waiting_first = false
	control.reject()
	picker_error = reason
	platform.set_mpv_playing(media.session_id, requested_play)
	_seek_event("capture_failed")
	changed.emit()

func _on_frozen_pair(id: int, payload: String) -> void:
	var report: Variant = JSON.parse_string(payload)
	if not report is Dictionary: return
	var pair: Dictionary = report.get("pair", {})
	if id != media.session_id or int(report.get("request_id", 0)) != _freeze_request \
			or _pending_revision.is_empty() or int(_pending_revision.position_ms) < 0:
		if int(pair.get("frozen_frame_id", 0)) > 0:
			platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		if int(report.get("request_id", 0)) == _freeze_request: _freeze_request = 0
		return
	if report.get("state") != "ready":
		_abort_frozen_seek(str(report.get("error", "Frame capture failed")))
		return
	# Preserve visibility, shader parameters and effect state during replacement.
	var previous := _binding.unbind()
	if not _binding.bind(material, pair):
		_binding.bind(material, previous)
		platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		_abort_frozen_seek("Frozen video frame could not be bound")
		return
	platform.detach_mpv_pair(int(previous.session_id), int(previous.slot_token))
	_freeze_request = 0
	_seek_event("frozen")
	_try_revision()

func _try_revision() -> void:
	if _pending_revision.is_empty() or _freeze_request > 0 or _pixel_busy or _thumbnail_busy:
		return
	if int(_pending_revision.position_ms) >= 0 and _start_seek_freeze(): return
	if int(_pending_revision.position_ms) >= 0 and Time.get_ticks_msec() < _debug_seek_delay_until_ms:
		return
	var request := _pending_revision
	if _layer_session and ((bool(request.alpha) and not _layer_alpha()) or bool(request.depth)):
		_pending_revision = {}
		_reopen_on_eye_buffer(int(request.position_ms))
		return
	if _layer_session and bool(request.alpha) and not _layer_alpha_host:
		# Alpha on a layer session opened without it: its decoder has no frame fan-out for the model.
		_pending_revision = {}
		_reopen_at(int(request.position_ms), true)
		return
	var id: int = platform.revise_mpv_video(media.session_id, request.stereo, request.alpha, request.profile, request.position_ms,
		request.depth, request.top_bottom, request.seek_mode == SeekPolicy.EXACT)
	if id <= 0:
		if OS.is_debug_build() and not _revision_refused_logged:
			_revision_refused_logged = true
			DiagnosticLog.record("mpv_revision_refused", {"request": request, "layer_session": _layer_session})
		return
	_layer_seek_hold = _layer_session and int(request.position_ms) >= 0 and media.frame_counter > 0
	if int(request.position_ms) < 0 or not (_is_frozen() or _layer_seek_hold): _unbind()
	_pending_pair = {}
	_pending_revision = {}
	var held_format := media.format.duplicate()
	_track_choices = _capture_track_choices()
	media.begin(id)
	if _is_frozen() or _layer_seek_hold: media.format = held_format
	platform.set_mpv_playing(id, false)
	if int(request.position_ms) >= 0:
		_last_seek_mode = request.seek_mode
		control.take_pending()
		_debug_seek_delay_until_ms = 0
		_seek_event("seek_started")
	changed.emit()

## Alpha as the user sees it: live RVM, or the mask packed in this file.
func alpha_wanted() -> bool:
	return alpha_requested or (packed_file and packed_alpha)

## The URI/effect preferences survive close for history; they are not playback state.
func has_active_presentation() -> bool:
	if local_uri.is_empty() or not media.accepts(media.session_id): return false
	return media.state != "ended" or (loop_enabled and requested_play) \
		or _waiting_first or not _pending_revision.is_empty()

func set_alpha_edge(feather: float, shrink: float) -> void:
	alpha_edge = AlphaEdge.bounds(feather, shrink)
	if material: material.set_shader_parameter("alpha_edge", alpha_edge)
	if PlatformMethods.supports(platform, "set_mpv_alpha_edge"): platform.set_mpv_alpha_edge(alpha_edge.x, alpha_edge.y)

## The video's own Alpha mask (official packed releases: the mask in the frame corners) is in use.
func packed_mask_on() -> bool:
	return packed_file and packed_alpha

## Only a full side-by-side fisheye frame carries the packed mask layout.
func packed_mask_available() -> bool:
	return not is_spatial_video() and geometry == Geometry.Geometry.FISHEYE and stereo_sbs and not top_bottom and not stereo_half

## The user says this fisheye file carries its own mask (official releases renamed without the
## marker): passthrough then uses that mask, and live matting stops. Off returns to a plain fisheye.
func set_packed_mask(enabled: bool) -> void:
	if enabled and not packed_mask_available(): return
	if enabled == packed_mask_on(): return
	packed_file = enabled
	packed_alpha = enabled
	if enabled and alpha_requested:
		alpha_requested = false
		_request_revision()
	_apply_packed()
	_remember_mode()
	changed.emit()

func set_alpha(enabled: bool) -> bool:
	if packed_file:
		packed_alpha = enabled
		_apply_packed()
		changed.emit()
		return true
	alpha_requested = enabled
	if enabled:
		depth_requested = false
	_remember_mode()
	_request_revision()
	changed.emit()
	return true

## 2D->3D for mono sources; switching it on ends Alpha.
func set_depth(enabled: bool) -> bool:
	if is_spatial_video(): return false
	if enabled and (stereo_sbs or geometry != Geometry.Geometry.FLAT):
		return false
	if enabled != depth_requested: _unlock_mode()
	auto_depth = enabled
	depth_requested = enabled
	if enabled:
		alpha_requested = false
	_remember_mode()
	_request_revision()
	changed.emit()
	return true

## The bridge renders the stereo pair: tell it the strength once per session and change.
func _send_depth_view() -> void:
	if not depth_enabled or media.session_id <= 0 or not platform:
		return
	# JNISingleton.has_method() cannot see Java plugin methods. Only inspect host test doubles.
	if not Engine.has_singleton("QuestPlayer") and not platform.has_method("set_mpv_depth_view"): return
	var strength := depth_strength if depth_requested else 0.0
	var key := "%d:%f" % [media.session_id, strength]
	if key != _depth_view_sent and platform.set_mpv_depth_view(media.session_id,
		DEPTH_SHIFT * strength, DEPTH_CONVERGENCE):
		_depth_view_sent = key

func depth_ready() -> bool:
	return depth_enabled and not media.last_pair.is_empty() and media.last_pair.get("depth_ran", false)

## Depth compiled for this device: 3D starts at once (otherwise frames show flat until it is).
func depth_model_ready() -> bool:
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		return bool(Engine.get_singleton("QuestPlayer").depth_ready())
	return true

func cycle_depth_strength() -> void:
	if set_depth_strength(DEPTH_STRENGTHS[(DEPTH_STRENGTHS.find(depth_strength) + 1) % DEPTH_STRENGTHS.size()]):
		_remember_mode()

func set_depth_strength(value: float) -> bool:
	if is_spatial_video(): return false
	var strength := DepthStrength.clamp_value(value)
	if strength > 0.0 and (stereo_sbs or geometry != 0 or local_uri.is_empty() or media.state == "closed"): return false
	if strength>0.0 and not is_equal_approx(strength,depth_strength): _mode_user_changed=true
	if strength > 0.0:
		depth_strength = strength
		if _remember_file and media.accepts(media.session_id): preferred_depth_strength = strength
	auto_depth = strength > 0.0
	material.set_shader_parameter("depth_shift", DEPTH_SHIFT * strength)
	if depth_requested != (strength > 0.0): set_depth(strength > 0.0)
	# Nonzero changes only update parallax; never revise/restart the processing session.
	_send_depth_view()
	_picture_refresh = 6
	changed.emit()
	return true

## The extra track titled "Clone voice" (see SidecarAudio.kt); 0 when this video has none.
func clone_voice_track() -> int:
	for track in media.playback.get("details", {}).get("audio_tracks", []):
		if track is Dictionary and bool(track.get("external", false)) and (str(track.get("title", "")) == "Clone voice" or str(track.get("title", "")).to_lower().ends_with(".si.mix.m4a")):
			return int(track.get("id", 0))
	return 0

func clone_voice_active() -> bool:
	var clone := clone_voice_track()
	return clone > 0 and str(media.playback.get("details", {}).get("audio_track_id", "")) == str(clone)

## Clone voice <-> the video's own audio. The choice carries over to the next video with a clone voice.
func toggle_clone_voice() -> bool:
	var clone := clone_voice_track()
	if clone <= 0:
		return false
	var active := clone_voice_active()
	if not select_audio_track(-1 if active else clone):
		return false
	prefer_clone_voice = not active
	return true

func alpha_ready() -> bool:
	return alpha_enabled and not media.last_pair.is_empty() and media.last_pair.get("inference_ran", false)

func set_playback_speed(value: float) -> bool:
	if not is_finite(value) or value < 0.25 or value > 3.0 or not media.accepts(media.session_id): return false
	if not is_equal_approx(playback_speed, value): captures.stop()
	if not PlatformMethods.supports(platform, "set_mpv_speed") or not platform.set_mpv_speed(media.session_id, value): return false
	playback_speed = value
	changed.emit()
	return true

func toggle_play() -> void:
	if bool(narration.clone_state.get("opened", false)): return
	if media.state == "ended":
		requested_play = true
		seek_absolute(0)
		return
	requested_play = not requested_play
	if not requested_play:
		_record_history(true)
	if platform and media.accepts(media.session_id):
		platform.set_mpv_playing(media.session_id, requested_play and not _waiting_first)
	changed.emit()

func pause_for_voice_clone() -> void:
	requested_play = false
	if platform and media.accepts(media.session_id): platform.set_mpv_playing(media.session_id, false)
	changed.emit()

func set_audio_whisper(level: int, remember: bool = true) -> bool:
	if level < 0 or level > 51 or not media.accepts(media.session_id) or not PlatformMethods.supports(platform, "set_mpv_whisper"): return false
	var command: int = platform.set_mpv_whisper(media.session_id, level)
	if command <= 0: return false
	audio_whisper = level
	_whisper_command = command
	_whisper_remember = remember
	_whisper_restore_pending = false
	_whisper_restore_remember = false
	whisper_error = ""
	changed.emit()
	return true

func _confirm_audio_whisper(details: Dictionary) -> void:
	if _whisper_command == 0 and audio_whisper > 0 and not str(details.get("whisper_error", "")).is_empty():
		audio_whisper = 0; whisper_error = str(details.whisper_error); changed.emit()
		return
	if _whisper_command <= 0 or int(details.get("whisper_serial", 0)) < _whisper_command: return
	_whisper_command = 0
	whisper_error = str(details.get("whisper_error", ""))
	audio_whisper = int(details.get("whisper_level", 0))
	if _whisper_remember and whisper_error.is_empty() and _remember_file:
		if audio_whisper > 1: audio_boost_saved = audio_whisper - 1
		if whisper_memory.remember(local_uri, {"enabled": audio_whisper > 0, "boost": audio_boost_saved}) and not whisper_memory.save():
			Log.record("file_whisper_save_failed", {"error": whisper_memory.last_error})
	_whisper_remember = false
	changed.emit()

func set_audio_options(track_id: int, volume: float, muted: bool) -> bool:
	if track_id < -1 or not is_finite(volume) or volume < 0.0 or volume > 100.0 or not platform or not media.accepts(media.session_id):
		return false
	if system_volume.supported():
		if not platform.set_mpv_audio(media.session_id, track_id, 100.0, false): return false
		audio_track_id = track_id
		_audio_pending = false
		_sync_audio_timing()
		changed.emit()
		return true
	if volume == 0.0:
		volume = audio_volume if audio_volume > 0.0 else 100.0
		muted = true
	if not platform.set_mpv_audio(media.session_id, track_id, volume, muted):
		return false
	audio_track_id = track_id
	audio_volume = volume
	audio_muted = muted
	audio_options_changed.emit(audio_volume, audio_muted)
	_audio_pending = false
	_sync_audio_timing()
	changed.emit()
	return true

## An explicit menu choice wins over automatic dubbing, including before the first frame.
func select_audio_track(track_id: int) -> bool:
	if not captures.recording.is_empty(): captures.stop()
	if not set_audio_options(track_id, audio_volume, audio_muted): return false
	_clone_applied = true
	prefer_clone_voice = clone_voice_track() > 0 and track_id == clone_voice_track()
	_remember_track("audio", track_id)
	return true

## Raising the volume unmutes (a muted slider shows 0, so a silent step up would look ignored);
## lowering keeps mute.
func set_volume_level(value: float) -> bool:
	if system_volume.supported(): return system_volume.request(value)
	return set_audio_options(audio_track_id, clampf(value, 0, 100), value <= 0)

func change_volume(delta: float) -> bool:
	if system_volume.supported(): return system_volume.request(clampf(system_volume.level() + delta, 0.0, 150.0 if audio_whisper > 0 else 100.0))
	return set_audio_options(audio_track_id, clampf(audio_volume + delta, 0.0, 100.0), audio_muted and delta <= 0.0)

func toggle_mute() -> bool:
	if system_volume.supported(): return system_volume.toggle_mute()
	return set_audio_options(audio_track_id, audio_volume, not audio_muted)

func cycle_audio_track(direction: int = 1) -> bool:
	var details: Dictionary = media.playback.get("details", {})
	var tracks: Array = details.get("audio_tracks", [])
	if tracks.is_empty():
		return false
	var choices: Array[int] = [0]
	for track in tracks:
		if track is Dictionary and int(track.get("id", 0)) > 0:
			choices.append(int(track.id))
	var current := int(details.get("audio_track_id", 0))
	var index := choices.find(current)
	return select_audio_track(choices[posmod(index + direction, choices.size())])

func seek_absolute(position_ms: int, mode: String = "") -> bool:
	if not platform or not media.accepts(media.session_id):
		return false
	captures.stop()
	control.seek_absolute(position_ms)
	_request_revision(control.target_ms, mode)
	return true

func _bookmark_resolve() -> void:
	_bookmark_media_id = bookmark_store.resolve(local_uri, str(_bookmark_metadata.get("basename", "")), _bookmark_metadata.get("size", -1))
	_bookmark_cache_revision = -1

func bookmark_seekable() -> bool:
	var details: Dictionary = media.playback.get("details", {})
	return media.accepts(media.session_id) and control.duration_ms > 0 and details.get("seekable", "") == "yes" \
		and details.get("partially_seekable", "no") != "yes" and media.state not in ["failed", "closed"]

func bookmark_scope() -> String:
	return str(_bookmark_scope_sequence) + "|" + _bookmark_media_id

func bookmark_snapshot() -> Dictionary:
	if not bookmark_seekable() or _waiting_first or control.pending or control.in_flight > 0 \
		or not _pending_revision.is_empty() or _is_frozen() or not panel or not panel.visible: return {}
	var pair: Dictionary = _binding.ticket
	if not pair.get("source_pts_verified", false) or int(pair.get("session_id", -1)) != media.session_id \
		or int(pair.get("generation", -1)) != media.generation or int(pair.get("pts_us", -1)) < 0: return {}
	var time := int(pair.pts_us) / 1000
	if time >= control.duration_ms: return {}
	return {"scope": bookmark_scope(), "position_ms": time}

func bookmarks_snapshot() -> Dictionary:
	if _bookmark_cache_revision != bookmark_store.revision:
		_bookmark_rows = bookmark_store.list_markers(_bookmark_media_id)
		_bookmark_cache_revision = bookmark_store.revision
	return {"bookmark_scope": bookmark_scope(), "bookmarks": _bookmark_rows,
		"bookmark_revision": bookmark_store.revision, "bookmark_undo": bookmark_store.can_undo(),
		"bookmark_ready": not bookmark_snapshot().is_empty(), "bookmark_seekable": bookmark_seekable(),
		"seek_mode": SeekPolicy.normalize(seek_mode), "bookmark_seek_mode": SeekPolicy.bookmark_override(bookmark_seek_mode),
		"bookmark_effective_seek_mode": SeekPolicy.effective(seek_mode, bookmark_seek_mode)}

func bookmark_action(operation: String, marker_id: String, scope: String) -> String:
	if scope != bookmark_scope(): return ""
	match operation:
		"add":
			var snapshot := bookmark_snapshot()
			if snapshot.is_empty(): return ""
			var item := bookmark_store.add(local_uri, str(_bookmark_metadata.get("basename", "")), _bookmark_metadata.get("size", -1), int(snapshot.position_ms))
			bookmark_last_added = item
			return "Bookmark added" if not item.is_empty() else bookmark_store.last_error
		"delete":
			return "Bookmark deleted" if bookmark_store.remove(_bookmark_media_id, marker_id) else "Bookmark save failed"
		"undo":
			return "Bookmark restored" if bookmark_store.restore() else "Bookmark save failed"
		"seek":
			if not bookmark_seekable(): return ""
			for marker in bookmark_store.list_markers(_bookmark_media_id):
				if marker.id == marker_id and int(marker.position_ms) < control.duration_ms:
					return "" if seek_absolute(int(marker.position_ms), SeekPolicy.effective(seek_mode, bookmark_seek_mode)) else "Bookmark jump failed"
	return ""

func set_subtitle_track(track_id: int, remember: bool = true) -> bool:
	if track_id < -1 or not platform or not media.accepts(media.session_id):
		return false
	if track_id > 0 and not subtitle_tracks().any(func(t): return int(t.id) == track_id):
		return false
	if not platform.set_mpv_subtitle(media.session_id, track_id):
		return false
	var track: Dictionary = {}
	for item in _raw_tracks("subtitle"):
		if int(item.get("id", 0)) == track_id: track = item; break
	var timing_key := SubtitleTiming.track_key(track)
	if not timing_key.is_empty() and timing_key != _subtitle_timing_key:
		var legacy := not remember and _subtitle_timing_key.is_empty() and _remember_file
		var seconds := subtitle_timing.for_track(local_uri, timing_key, legacy)
		_subtitle_timing_key = timing_key
		if not set_subtitle_delay(seconds):
			subtitle_delay = seconds; subtitles.set_delay(seconds); _subtitle_delay_pending = true
		if legacy and not subtitle_timing.lookup(local_uri).is_empty() and not subtitle_timing.lookup(local_uri).has("tracks"):
			if subtitle_timing.remember_track(local_uri, timing_key, seconds): subtitle_timing.save()
		elif remember and _remember_file:
			if subtitle_timing.remember_track(local_uri, timing_key, seconds): subtitle_timing.save()
	elif timing_key.is_empty(): _subtitle_timing_key = ""
	subtitles.select(track_id)
	bitmap_subtitles.clear(material)
	if _subtitle_surface: _subtitle_surface.visible = false
	if caption:
		caption.visible = false
	if projected_subtitles:
		projected_subtitles.clear(material)
	if remember:
		_subtitle_load_request = 0; _subtitle_loaded_track = 0; subtitle_file_loading = ""
		_remember_track("subtitle", track_id)
	if remember: _subtitle_auto_pending = false
	changed.emit()
	return true

func _reset_subtitle_files() -> void:
	subtitle_files_revision += 1
	subtitle_files.clear(); subtitle_files_state = "idle"; subtitle_file_error = ""; subtitle_file_loading = ""
	_subtitle_list_request = 0; _subtitle_load_request = 0; _subtitle_loaded_track = 0
	_subtitle_restore_attempted = false; _subtitle_files_session = media.session_id

func subtitle_files_available() -> bool:
	if not PlatformMethods.supports(platform, "list_mpv_subtitle_files") or not PlatformMethods.supports(platform, "load_mpv_subtitle_file"): return false
	return local_uri.begins_with("file://") or local_uri.begins_with("usb://") or local_uri.begins_with("smb://") or local_uri.begins_with("cloud://") \
		or (local_uri.begins_with("content://com.android.externalstorage.documents/tree/"))

func request_subtitle_files() -> void:
	if not subtitle_files_available() or not media.accepts(media.session_id) or _subtitle_list_request > 0: return
	_subtitle_file_sequence += 1; _subtitle_list_request = _subtitle_file_sequence
	_subtitle_files_session = media.session_id
	subtitle_files_state = "loading"; subtitle_file_error = ""
	if not platform.list_mpv_subtitle_files(media.session_id, _subtitle_list_request):
		_subtitle_list_request = 0; subtitle_files_state = "error"; subtitle_file_error = "Unable to list subtitle files"
	changed.emit()

func select_subtitle_file(filename: String, restoring: bool = false) -> bool:
	if not subtitle_files_available() or not TrackMemory.valid_file(filename) or not media.accepts(media.session_id) or _subtitle_load_request > 0: return false
	_subtitle_file_sequence += 1; _subtitle_load_request = _subtitle_file_sequence
	_subtitle_files_session = media.session_id
	_subtitle_loaded_track = 0; _subtitle_load_restore = restoring
	subtitle_file_loading = filename; subtitle_file_error = ""
	if not restoring:
		_track_restore.erase("subtitle"); _subtitle_auto_pending = false
	if not platform.load_mpv_subtitle_file(media.session_id, _subtitle_load_request, filename):
		_subtitle_load_request = 0; subtitle_file_loading = ""; subtitle_file_error = "Unable to load subtitle"
		changed.emit(); return false
	changed.emit(); return true

func select_subtitle_uri(uri: String, restoring: bool = false) -> bool:
	if not TrackMemory.SubtitleSources.valid_uri(uri) or not media.accepts(media.session_id) or _subtitle_load_request > 0 \
		or not PlatformMethods.supports(platform, "load_mpv_subtitle_uri"): return false
	_subtitle_file_sequence += 1; _subtitle_load_request = _subtitle_file_sequence
	_subtitle_files_session = media.session_id; _subtitle_loaded_track = 0; _subtitle_load_restore = restoring
	subtitle_file_loading = TrackMemory.SubtitleSources.filename(uri); subtitle_file_error = ""
	if not restoring:
		_track_restore.erase("subtitle"); _subtitle_auto_pending = false
	if not platform.load_mpv_subtitle_uri(media.session_id, _subtitle_load_request, uri):
		_subtitle_load_request = 0; subtitle_file_loading = ""; subtitle_file_error = "Unable to load subtitle"
		changed.emit(); return false
	changed.emit(); return true

func _on_subtitle_files(id: int, payload: String) -> void:
	if id != media.session_id or not media.accepts(id): return
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary: return
	var request := int(result.get("request", 0))
	if result.get("operation") == "list" and request > 0 and request == _subtitle_list_request:
		_subtitle_list_request = 0
		subtitle_files_state = str(result.get("state", "error"))
		subtitle_file_error = str(result.get("error", ""))
		if subtitle_files_state == "ready":
			subtitle_files_revision += 1
			subtitle_files.clear()
			for filename in result.get("files", []):
				if TrackMemory.valid_file(filename) and not subtitle_files.has(filename): subtitle_files.append(filename)
	elif result.get("operation") == "load" and request > 0 and request == _subtitle_load_request:
		if result.get("state") == "ready":
			_subtitle_loaded_track = int(result.get("track_id", 0))
			_finish_subtitle_file()
		else:
			_subtitle_load_request = 0; subtitle_file_loading = ""; subtitle_file_error = "Unable to load subtitle"
			# Cloud discovery may still add this file after the optional reload failed.
			# Retain its identity; the attempted flag prevents repeated downloads.
	changed.emit()

func _finish_subtitle_file() -> void:
	if _subtitle_load_request <= 0 or _subtitle_loaded_track <= 0: return
	if not subtitle_tracks().any(func(track): return int(track.id) == _subtitle_loaded_track): return
	var selected := _subtitle_loaded_track
	var restore := _subtitle_load_restore
	_subtitle_load_request = 0; _subtitle_loaded_track = 0; subtitle_file_loading = ""
	if set_subtitle_track(selected, not restore):
		if restore:
			_track_choices.subtitle = TrackMemory.describe(selected, _raw_tracks("subtitle"))
			_track_restore.erase("subtitle"); _subtitle_auto_pending = false
	else: subtitle_file_error = "Unable to load subtitle"

func subtitle_timing_key() -> String: return _subtitle_timing_key

func _raw_tracks(channel: String) -> Array:
	return media.playback.get("details", {}).get(channel + "_tracks", [])

func _remember_track(channel: String, id: int) -> void:
	_track_restore.erase(channel) # A manual choice cancels any delayed restore.
	var choice := TrackMemory.describe(id, _raw_tracks(channel))
	if choice.is_empty(): return
	_track_choices[channel] = choice
	if not _remember_file: return # Explicit diagnostic opens bypass per-file settings.
	var saved := track_memory.lookup(local_uri)
	saved[channel] = choice
	if track_memory.remember(local_uri, saved) and not track_memory.save():
		Log.record("file_track_save_failed", {"error": track_memory.last_error})

func _capture_track_choices() -> Dictionary:
	var choices := _track_choices.duplicate(true)
	choices.merge(_track_restore, true)
	for channel in TrackMemory.CHANNELS:
		if _track_restore.has(channel): continue
		# A still-pending automatic subtitle choice is not the user's "off".
		if channel == "subtitle" and _subtitle_auto_pending and not _track_choices.has("subtitle"): continue
		var id := audio_track_id if channel == "audio" else subtitles.requested_track
		var choice := TrackMemory.describe(id, _raw_tracks(channel))
		if not choice.is_empty(): choices[channel] = choice
	return choices

func _queue_track_restore(choices: Dictionary) -> void:
	_track_restore = choices.duplicate(true)
	_subtitle_restore_attempted = false
	_track_choices = choices.duplicate(true)
	if choices.has("audio"): _clone_applied = true # Per-file choice takes priority over global dubbing.

func _restore_tracks() -> void:
	if not platform or not media.accepts(media.session_id): return
	if _subtitle_files_session != media.session_id:
		_subtitle_files_session = media.session_id
		_subtitle_list_request = 0; _subtitle_load_request = 0; _subtitle_loaded_track = 0; subtitle_file_loading = ""
		_subtitle_restore_attempted = false
		if subtitle_files_state == "loading": subtitle_files_state = "idle"
	_finish_subtitle_file()
	_apply_subtitle_delay()
	for channel in _track_restore.keys():
		var id := TrackMemory.resolve(_track_restore[channel], _raw_tracks(channel))
		if id == TrackMemory.UNRESOLVED:
			# A remembered arbitrary sibling must be loaded again before its MPV id can resolve.
			var filename := str(_track_restore[channel].get("file", ""))
			var uri := str(_track_restore[channel].get("uri", ""))
			if channel == "subtitle" and (not filename.is_empty() or not uri.is_empty()) and not _subtitle_restore_attempted and media.playback.get("details", {}).has("subtitle_tracks"):
				_subtitle_restore_attempted = true
				if not uri.is_empty(): select_subtitle_uri(uri, true)
				else: select_subtitle_file(filename, true)
			continue # External tracks can arrive after FILE_LOADED.
		var accepted := set_audio_options(id, audio_volume, audio_muted) if channel == "audio" else set_subtitle_track(id, false)
		if accepted:
			_track_choices[channel] = TrackMemory.describe(id, _raw_tracks(channel))
			_track_restore.erase(channel)
			if channel == "subtitle":
				_subtitle_auto_pending = false
				subtitle_file_error = ""
	_auto_select_subtitle()

func audio_timing_key() -> String: return _audio_timing_key

func _sync_audio_timing() -> void:
	if not media.accepts(media.session_id): return
	var key := str(audio_track_id).sha256_text()
	if audio_track_id > 0:
		var tracks := _raw_tracks("audio").filter(func(track): return int(track.get("id", 0)) == audio_track_id)
		if tracks.is_empty(): return
		key = AudioTiming.track_key(tracks[0])
	if key != _audio_timing_key:
		_audio_timing_key = key
		audio_delay = audio_timing.for_track(local_uri, key) if _remember_file else 0.0
		_audio_delay_pending = true
	if _audio_delay_pending: set_audio_delay(audio_delay)

func set_audio_delay(seconds: float) -> bool:
	if not is_finite(seconds) or not media.accepts(media.session_id) or not PlatformMethods.supports(platform, "set_mpv_audio_delay"): return false
	var value := AudioTiming.delay(seconds)
	if not platform.set_mpv_audio_delay(media.session_id, value): return false
	audio_delay = value; _audio_delay_pending = false
	changed.emit()
	return true

func commit_audio_delay(seconds: float, uri: String, key: String) -> bool:
	if not is_finite(seconds) or uri.is_empty() or key.is_empty(): return false
	if uri == local_uri and key == _audio_timing_key and not set_audio_delay(seconds): return false
	if not _remember_file: return true
	return audio_timing.remember_track(uri, key, seconds) and audio_timing.save()

func _apply_subtitle_delay() -> bool:
	if not _subtitle_delay_pending: return true
	if not platform or not media.accepts(media.session_id): return false
	if not PlatformMethods.supports(platform, "set_mpv_subtitle_delay"):
		_subtitle_delay_pending = not is_zero_approx(subtitle_delay)
		return not _subtitle_delay_pending
	if not platform.set_mpv_subtitle_delay(media.session_id, subtitle_delay): return false
	_subtitle_delay_pending = false
	return true

func set_subtitle_delay(seconds: float) -> bool:
	if not is_finite(seconds): return false
	var value := SubtitleTiming.delay(seconds)
	if is_equal_approx(value, subtitle_delay): return _apply_subtitle_delay()
	if not platform or not media.accepts(media.session_id) or not PlatformMethods.supports(platform, "set_mpv_subtitle_delay"):
		return false
	if not platform.set_mpv_subtitle_delay(media.session_id, value): return false
	subtitle_delay = value
	_subtitle_delay_pending = false
	subtitles.set_delay(value)
	bitmap_subtitles.clear(material)
	if caption: caption.visible = false
	if projected_subtitles: projected_subtitles.clear(material)
	if _subtitle_surface: _subtitle_surface.visible = false
	_subtitle_poll_ms = 0
	changed.emit()
	return true

func commit_subtitle_delay(seconds: float, uri: String, key: String = "__current__") -> bool:
	if not is_finite(seconds) or uri.is_empty(): return false
	if key == "__current__": key = _subtitle_timing_key if uri == local_uri else ""
	# A release from a previous video's captured slider may save that video,
	# but must never shift whichever file has since opened.
	if uri == local_uri and key == _subtitle_timing_key and not set_subtitle_delay(seconds): return false
	if not _remember_file: return true
	if not subtitle_timing.remember_track(uri, key, seconds): return false
	if not subtitle_timing.save():
		Log.record("file_subtitle_timing_save_failed", {"error": subtitle_timing.last_error})
		return false
	return true

func set_subtitle_auto_load(enabled: bool) -> void:
	subtitle_auto_load = enabled
	_subtitle_auto_pending = enabled and subtitles.requested_track == 0 and not _track_choices.has("subtitle")
	_auto_select_subtitle()
	changed.emit()

func _auto_select_subtitle() -> void:
	if not subtitle_auto_load or not _subtitle_auto_pending or _track_restore.has("subtitle"): return
	var stems: Array[String] = [_layout_basename.get_basename().to_lower()]
	# DLNA display titles can differ from the media filename; history keeps the original URI.
	if local_uri.begins_with("http://") or local_uri.begins_with("https://") or local_uri.begins_with("smb://") \
		or local_uri.begins_with("file://") or local_uri.begins_with("cloud://"):
		var original := _subtitle_filename(local_uri).get_basename()
		if not original.is_empty() and not stems.has(original): stems.append(original)
	# Exact filenames win over language preferences; SRT, then ASS remain first.
	var extensions := ["srt", "ass", "ssa", "vtt", "smi", "sami", "sub"]
	for extension in extensions:
		for track in subtitle_tracks():
			# Language labels such as "zh · SRT" are for display, not filename matching.
			var filename := _subtitle_filename(str(track.get("filename", "")))
			if filename.is_empty(): filename = str(track.get("title", "")).to_lower()
			if bool(track.get("external", false)) and stems.any(func(stem): return not stem.is_empty() and filename == stem + "." + extension):
				if set_subtitle_track(int(track.id), false): _subtitle_auto_pending = false
				return
	# Server captions often have a generic display name instead of the video basename.
	# A sole supported external caption needs no filename or language guess.
	var external := subtitle_tracks().filter(func(track): return bool(track.get("external", false)))
	if external.size() == 1:
		if set_subtitle_track(int(external[0].id), false): _subtitle_auto_pending = false
		return
	# Unlabelled tracks stay available for manual selection. Prefer an explicit Chinese
	# script over generic zh, without treating Simplified and Traditional as equivalent.
	var target := "zh_Hans" if I18n.language == "zh" else I18n.language
	var selected := 0
	var best_rank := 0
	var best_format := extensions.size()
	for track in subtitle_tracks():
		if not bool(track.get("external", false)): continue
		var language := _subtitle_language(track)
		var rank := 2 if language == target else (1 if language == "zh" and target.begins_with("zh_") else 0)
		var filename := _subtitle_filename(str(track.get("filename", "")))
		if filename.is_empty(): filename = str(track.get("title", "")).to_lower()
		var format := extensions.find(filename.get_extension())
		if format < 0:
			format = extensions.find({"subrip": "srt", "ass": "ass", "ssa": "ssa", "webvtt": "vtt", "sami": "smi"}.get(str(track.get("codec", "")), ""))
		if format < 0: format = extensions.size()
		if rank > best_rank or (rank > 0 and rank == best_rank and format < best_format):
			selected = int(track.id); best_rank = rank; best_format = format
	if selected > 0 and set_subtitle_track(selected, false): _subtitle_auto_pending = false

static func _subtitle_filename(location: String) -> String:
	if location.contains("://"):
		return location.get_slice("?", 0).get_slice("#", 0).get_file().uri_decode().to_lower()
	return location.get_file().to_lower()

static func _subtitle_language(track: Dictionary) -> String:
	var declared := str(track.get("server_language", track.get("language", ""))).strip_edges().to_lower()
	var language := _subtitle_language_code(declared)
	if language.is_empty() and declared not in ["", "und", "unknown"]: return declared
	if not language.is_empty() and language != "zh": return language
	# DLNA resource language is also carried by its display label (e.g. "zh · SRT").
	var label := _subtitle_language_code(str(track.get("title", "")).get_slice("·", 0))
	if language.is_empty(): language = label
	if not language.is_empty() and language != "zh": return language
	var filename := _subtitle_filename(str(track.get("filename", "")))
	if filename.is_empty(): filename = str(track.get("title", "")).to_lower()
	var name := filename.get_basename()
	for suffix in ["hans", "hant", "cn", "sg", "tw", "hk", "mo"]:
		name = name.replace("zh_" + suffix, "zh-" + suffix)
	for separator in ["_", " ", "[", "]", "(", ")"]: name = name.replace(separator, ".")
	var parts := name.split(".", false)
	parts.reverse()
	# Read suffix tags, not words elsewhere in a movie title.
	for part in parts.slice(0, 3):
		var hint := _subtitle_language_code(part)
		if hint.is_empty() or (language == "zh" and not hint.begins_with("zh")): continue
		if hint != "zh": return hint
		language = hint
	return language

static func _subtitle_language_code(value: String) -> String:
	var tag := value.strip_edges().to_lower().replace("_", "-")
	if tag.begins_with("zh-"):
		var parts := tag.split("-")
		if "hant" in parts: return "zh_Hant"
		if "hans" in parts: return "zh_Hans"
		return "zh_Hant" if "tw" in parts or "hk" in parts or "mo" in parts else ("zh_Hans" if "cn" in parts or "sg" in parts else "zh")
	if tag in ["chs", "hans", "简体", "简体中文", "簡體中文"]: return "zh_Hans"
	if tag in ["cht", "hant", "繁体", "繁體", "繁体中文", "繁體中文"]: return "zh_Hant"
	if tag in ["zh", "zho", "chi", "cmn", "chinese", "中文"]: return "zh"
	if tag in ["en", "eng", "english"] or tag.begins_with("en-"): return "en"
	if tag in ["ja", "jpn", "jp", "japanese", "日本語", "日语", "日語"] or tag.begins_with("ja-"): return "ja"
	return ""

func subtitle_tracks() -> Array[Dictionary]:
	var tracks: Array[Dictionary] = []
	var details: Dictionary = media.playback.get("details", {})
	for track in details.get("subtitle_tracks", []):
		if track is Dictionary and int(track.get("id", 0)) > 0 and SubtitleState.supported_codec(str(track.get("codec", "")),
			geometry == Geometry.Geometry.FLAT, bool(details.get("pgs_supported", false))):
			tracks.append(track)
	return tracks

func cycle_subtitle_track(direction: int = 1) -> bool:
	var choices: Array[int] = [0]
	for track in subtitle_tracks():
		choices.append(int(track.id))
	if choices.size() == 1:
		return false
	return set_subtitle_track(choices[posmod(choices.find(subtitles.requested_track) + direction, choices.size())])

func _poll_subtitles() -> void:
	if not caption:
		return
	var ready := platform != null and media.accepts(media.session_id) and not media.last_pair.is_empty() \
		and not _waiting_first and _pending_revision.is_empty() and panel.visible
	if not ready:
		caption.visible = false
		projected_subtitles.clear(material)
		bitmap_subtitles.clear(material)
		if _subtitle_surface: _subtitle_surface.visible = false
		return
	var now := Time.get_ticks_msec()
	if now >= _subtitle_poll_ms:
		_subtitle_poll_ms = now + 50
		var payload: String = platform.get_mpv_subtitles(media.session_id, subtitles.sequence)
		var snapshot: Variant = JSON.parse_string(payload) if not payload.is_empty() else null
		if snapshot is Dictionary and subtitles.observe(snapshot, media.session_id, media.last_pair):
			_subtitle_received_ms = now
	if now - _subtitle_received_ms > 1000:
		subtitles.clear()
	# Keep the selected track and MPV text queue alive for narration.
	if narration.hides_display():
		caption.visible = false
		projected_subtitles.clear(material)
		bitmap_subtitles.clear(material)
		if _subtitle_surface: _subtitle_surface.visible = false
		return
	if geometry == Geometry.Geometry.FLAT and not subtitles.bitmap.is_empty():
		var handle := int(subtitles.cue.get("mpv_source_handle", 0))
		var pixels := PackedByteArray()
		if bitmap_subtitles.needs_pixels(subtitles.bitmap, handle):
			pixels = platform.get_mpv_subtitle_bitmap(media.session_id, int(subtitles.bitmap.version))
		bitmap_subtitles.apply(material, subtitles.bitmap, handle, pixels, subtitle_size, subtitle_flat_position)
	else:
		bitmap_subtitles.clear(material)
		if _subtitle_surface: _subtitle_surface.visible = false
	caption.text = subtitles.text
	caption.visible = not subtitles.text.is_empty()
	if caption.visible:
		_place_caption()
	else:
		projected_subtitles.clear(material)
	_sync_subtitle_surface()

func _place_caption() -> void:
	var appearance := SubtitleStyle.colors(subtitle_style)
	caption.modulate = appearance.text_color
	caption.outline_modulate = appearance.outline_color
	if geometry == Geometry.Geometry.FLAT:
		# Ordinary video captions stay on the screen, independent of immersive preferences.
		var pose := subtitle_transform()
		caption.font_size = roundi(40 * subtitle_size)
		caption.outline_size = maxi(2, roundi(8 * subtitle_size))
		var pixel_size := 0.0016 * screen_scale
		caption.pixel_size = pixel_size
		var margin := minf(0.06 * screen_scale, _flat.size.y * 0.1)
		# Include the actual multiline text height in the usable travel range.
		caption.width = _flat.size.x * 0.9 / pixel_size
		var text_height := minf(_flat.size.y - 2 * margin, caption.get_aabb().size.y)
		var y := lerpf(-_flat.size.y * 0.5 + margin, _flat.size.y * 0.5 - margin - maxf(0.064 * subtitle_size * screen_scale, text_height), subtitle_flat_position)
		var anchor := pose * Vector3(0, y, 0.01)
		caption.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		caption.layers = 1
		projected_subtitles.clear(material)
		caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		caption.global_transform = Transform3D(pose.basis, anchor)
		return
	# Anchor in the video's coordinates, like burned-in captions. Head pose never changes it.
	# Direction/recenter/zoom move captions with the video; roll is excluded by the independent surface.
	var anchor_basis := SubtitleDepth.anchor(subtitle_position, subtitle_direction == 1)
	caption.layers = 0 # The live text patch is drawn only by the video's shader.
	var pose := subtitle_transform()
	var viewer_position := view_camera.global_position if view_camera and view_camera.is_inside_tree() else pose.origin
	projected_subtitles.update_patch(caption, material, anchor_basis, subtitle_distance, subtitle_direction == 1, subtitle_size, subtitle_style, pose, viewer_position, XRServer.world_scale)

func seek_relative(delta_ms: int) -> bool:
	if not platform or not media.accepts(media.session_id):
		return false
	captures.stop()
	control.seek_relative(delta_ms)
	_request_revision(control.target_ms)
	return true

## A decoded source type, retained until the file is closed.
func is_spatial_video() -> bool:
	return _spatial_video

func spatial_metadata() -> Dictionary:
	return _spatial_metadata.duplicate()

func _accept_spatial_metadata(frame: Dictionary) -> void:
	if not is_spatial_video() or not frame.has("spatial_metadata"): return
	_spatial_metadata = SpatialMetadata.normalize(frame.spatial_metadata)

func set_spatial_auto_disparity(enabled: bool) -> bool:
	if not is_spatial_video(): return false
	spatial_auto_disparity = enabled
	_apply_stereo_view()
	_remember_mode()
	changed.emit()
	return true

## One-shot angular-size match at a centred viewpoint, not metric scene reconstruction.
func spatial_fov_scale() -> float:
	if not is_spatial_video() or not _spatial_metadata.has("horizontal_fov_degrees"): return -1.0
	return capture_fov_scale(float(_spatial_metadata.horizontal_fov_degrees), SCALE_LIMITS)

func match_spatial_fov() -> bool:
	var scale := spatial_fov_scale()
	if scale <= 0.0: return false
	set_screen_curve(0.0)
	set_screen_scale(scale)
	changed.emit()
	return true

func mode_action_allowed(operation: String) -> bool:
	if not is_spatial_video(): return true
	return operation not in ["stereo", "projection", "lock_mode", "depth", "depth_strength"] \
		and not operation.begins_with("stereo_") and not operation.begins_with("projection_") \
		and not operation.begins_with("fov_")

## Lock only projection/layout; generated 3D is remembered for the individual file.
func current_lock() -> Dictionary:
	return {"geometry": geometry, "layout": stereo_layout(), "depth": false, "fisheye_fov": fisheye_fov}

## Locks the current mode, or unlocks when it is the locked one.
func toggle_mode_lock() -> void:
	if is_spatial_video(): return
	var current := current_lock()
	mode_lock = {} if mode_lock == current else current
	mode_lock_changed.emit(mode_lock.duplicate())
	changed.emit()

## A stored lock, checked; anything malformed leaves the player unlocked.
func load_mode_lock(value: Variant) -> void:
	mode_lock = {}
	if not value is Dictionary:
		return
	var numbers := ["geometry", "layout", "fisheye_fov"].all(func(k): return value.get(k) is int or value.get(k) is float)
	if not numbers or not value.get("depth") is bool or int(value.geometry) not in [0, 1, 2, 3] 		or int(value.layout) not in [0, 1, 2, 3, 4] or int(value.fisheye_fov) not in FISHEYE_FOVS:
		return
	mode_lock = {"geometry": int(value.geometry), "layout": int(value.layout), "depth": false,
		"fisheye_fov": int(value.fisheye_fov)}

func toggle_loop() -> void:
	loop_enabled = not loop_enabled
	changed.emit()

## 2D -> side by side -> top-bottom -> 2D.
func toggle_stereo() -> void:
	set_stereo_layout(0 if stereo_sbs and top_bottom else (2 if stereo_sbs else 1))

## 0 mono, 1 full SBS, 2 full TB, 3 half SBS, 4 half TB.
func set_stereo_layout(layout: int) -> void:
	if is_spatial_video(): return
	if layout < 0 or layout > 4 or layout == stereo_layout():
		return
	_unlock_mode()
	_layout_pending = null # A manual choice before the first frame survives detection.
	var repack := (layout != 0) != stereo_sbs or (layout in [2, 4]) != top_bottom
	stereo_sbs = layout != 0
	top_bottom = layout in [2, 4]
	stereo_half = layout in [3, 4]
	var old_depth := depth_requested
	if stereo_sbs:
		depth_requested = false
	elif auto_depth and geometry == Geometry.Geometry.FLAT:
		depth_requested = true
		alpha_requested = false
	_remember_mode()
	if repack or old_depth != depth_requested: _request_revision()
	_apply_geometry()
	changed.emit()

func stereo_layout() -> int:
	return 0 if not stereo_sbs else ((4 if top_bottom else 3) if stereo_half else (2 if top_bottom else 1))

func set_fisheye_fov(value: int) -> void:
	if is_spatial_video(): return
	if not value in FISHEYE_FOVS or value == fisheye_fov:
		return
	_unlock_mode()
	fisheye_fov = value
	_apply_geometry()
	_remember_mode()
	changed.emit()

func cycle_projection() -> void:
	set_projection((geometry + 1) % 4)

func set_projection(value: int) -> void:
	if is_spatial_video(): return
	if value < 0 or value > 3:
		return
	if value != geometry: _unlock_mode()
	geometry = value
	if _layout_pending is Dictionary: _layout_pending.geometry = value
	# Fisheye is a projection, independent of mono/SBS/TB. Preserve the chosen eye layout.
	var stereo := stereo_sbs if geometry == Geometry.Geometry.FISHEYE else geometry == Geometry.Geometry.HALF_EQUIRECT
	var revise := false
	if geometry != Geometry.Geometry.FLAT and stereo != stereo_sbs:
		stereo_sbs = stereo
		revise = true
	# 2D -> 3D applies to the flat screen, Alpha to VR180 and fisheye: stop effects when switching
	# to an unsupported projection, where their persistent bar buttons are disabled.
	if geometry != Geometry.Geometry.FLAT and depth_requested:
		depth_requested = false
		revise = true
	if not stereo and alpha_requested:
		alpha_requested = false
		revise = true
	# The built-in mask belongs to the fisheye layout: other projections leave it.
	if geometry != Geometry.Geometry.FISHEYE and packed_file:
		packed_file = false
		packed_alpha = false
		_apply_packed()
	if geometry == Geometry.Geometry.FLAT and not stereo_sbs and auto_depth and not depth_requested:
		depth_requested = true
		revise = true
	if revise:
		_request_revision()
	_apply_geometry()
	_remember_mode()
	changed.emit()

func set_profile(value: String) -> void:
	if value == profile or not value in PROFILES:
		return
	profile = value
	_warm_rvm()
	_remember_mode()
	_request_revision()
	changed.emit()

## Quick switch (button / quick bar): only between compiled profiles. Cold ones are chosen in
## settings, which asks for a second press before starting a compile.
func cycle_profile() -> void:
	var start := PROFILES.find(profile)
	var next := profile
	for step in range(1, PROFILES.size()):
		var candidate: String = PROFILES[(start + step) % PROFILES.size()]
		if profile_ready(candidate):
			next = candidate
			break
	if next == profile:
		return
	profile = next
	_warm_rvm()
	_remember_mode()
	_request_revision()
	changed.emit()

func toggle_eye_order() -> bool:
	if not stereo_sbs:
		return false
	swap_eyes = not swap_eyes
	_apply_geometry()
	_remember_mode()
	changed.emit()
	return true

func set_viewing_eye(value: int) -> bool:
	if not stereo_sbs or value not in [0, 1, 2]: return false
	viewing_eye = value
	_apply_stereo_view()
	_remember_mode()
	changed.emit()
	return true

func set_stereo_alignment(key: String, value: float) -> bool:
	if not stereo_sbs or viewing_eye != 0 or not is_finite(value): return false
	if key not in ["stereo_horizontal", "stereo_vertical"]: return false
	set(key, clampf(snappedf(value, StereoView.STEP), -StereoView.LIMIT, StereoView.LIMIT))
	_stereo_view_dirty = true
	_mode_user_changed = true
	_apply_stereo_view()
	return true

func reset_stereo_alignment() -> void:
	stereo_horizontal = 0.0
	stereo_vertical = 0.0
	_stereo_view_dirty = true
	_apply_stereo_view()
	commit_stereo_view()
	changed.emit()

func commit_stereo_view() -> void:
	if not _stereo_view_dirty: return
	_stereo_view_dirty = false
	_remember_mode()

func _apply_stereo_view() -> void:
	if not material: return
	# Native stereo only: mono and generated 2D->3D never inherit these corrections.
	material.set_shader_parameter("swap_eyes", swap_eyes if stereo_sbs else false)
	material.set_shader_parameter("viewing_eye", viewing_eye if stereo_sbs else 0)
	material.set_shader_parameter("stereo_offset", stereo_offset_uv() if stereo_sbs else Vector2.ZERO)
	if _hole_material:
		# No extra full-surface pass during ordinary playback or mono viewing.
		_hole_material.next_pass = _alignment_border if stereo_sbs and viewing_eye == 0 and stereo_offset_uv() != Vector2.ZERO else null
		for target in [_hole_material, _alignment_border]:
			target.set_shader_parameter("stereo_sbs", stereo_sbs)
			target.set_shader_parameter("viewing_eye", viewing_eye if stereo_sbs else 0)
			target.set_shader_parameter("stereo_offset", stereo_offset_uv() if stereo_sbs else Vector2.ZERO)
			target.set_shader_parameter("video_geometry", geometry)

## The file name left the projection or the layout open: the frame's shape decides (once).
func _complete_layout() -> void:
	if _restore_capture_layout(): return
	_complete_source_layout()

func _restore_capture_layout() -> bool:
	if not _capture_layout_pending: return false
	var details: Dictionary = media.playback.get("details", {})
	if not details.has("capture_mode"): return false
	_capture_layout_pending = false
	var exported: Variant = JSON.parse_string(str(media.playback.get("details", {}).get("capture_mode", "")))
	var capture_mode: Dictionary = preload("res://scripts/capture_mode.gd").clean(exported)
	if not capture_mode.is_empty() and not _capture_preference_exists and not _mode_user_changed:
		geometry = int(capture_mode.geometry)
		stereo_sbs = bool(capture_mode.stereo_sbs)
		top_bottom = bool(capture_mode.top_bottom)
		stereo_half = bool(capture_mode.stereo_half)
		swap_eyes = bool(capture_mode.swap_eyes)
		fisheye_fov = int(capture_mode.fisheye_fov)
		_layout_pending = null
		depth_requested = false
		_request_revision()
		_apply_geometry()
		return true
	return false

func _complete_source_layout() -> void:
	if bool(media.format.get("spatial_video", false)): _spatial_video = true
	if is_spatial_video():
		_accept_spatial_metadata(media.format)
		_layout_pending = null
		var revise := not stereo_sbs or top_bottom or depth_requested
		geometry = Geometry.Geometry.FLAT
		stereo_sbs = true
		top_bottom = false
		stereo_half = false
		depth_requested = false
		if revise: _request_revision()
		_apply_geometry()
		return
	if _layout_pending == null:
		return
	var chosen := Naming.complete(_layout_pending, int(media.format.width), int(media.format.height), media.format, _layout_basename)
	_layout_pending = null
	swap_eyes = chosen.swap
	stereo_half = chosen.stereo_half
	var tb := bool(chosen.stereo) and bool(chosen.top_bottom)
	if int(chosen.geometry) != geometry or bool(chosen.stereo) != stereo_sbs or tb != top_bottom:
		geometry = int(chosen.geometry)
		var revise := bool(chosen.stereo) != stereo_sbs or tb != top_bottom
		stereo_sbs = chosen.stereo
		top_bottom = tb
		var wanted := auto_depth and geometry == Geometry.Geometry.FLAT and not stereo_sbs and not alpha_requested
		revise = revise or depth_requested != wanted
		depth_requested = wanted
		if revise: _request_revision()
	_apply_geometry()
	Log.record("auto_layout", {"geometry": geometry, "stereo_sbs": stereo_sbs, "swap_eyes": swap_eyes,
		"width": media.format.width, "height": media.format.height})

## Packed masks show only on the layout they were made for (fisheye side by side).
func _apply_packed() -> void:
	var shown := packed_file and packed_alpha and not media.last_pair.is_empty() 		and not top_bottom and not stereo_half and Geometry.legacy_compatible(media.format, stereo_sbs, geometry)
	material.set_shader_parameter("packed_alpha", shown)
	if shown:
		material.set_shader_parameter("packed_size", Vector2(Geometry.packed_dimensions(int(media.format.width), int(media.format.height))))
	alpha_enabled = _rvm_alpha or shown

func _restore_saved_mode(saved: Dictionary) -> void:
	geometry = int(saved.geometry)
	stereo_sbs = bool(saved.stereo_sbs)
	top_bottom = stereo_sbs and bool(saved.get("top_bottom", false))
	stereo_half = stereo_sbs and bool(saved.get("stereo_half", false))
	fisheye_fov = int(saved.get("fisheye_fov", 180)) if int(saved.get("fisheye_fov", 180)) in FISHEYE_FOVS else 180
	swap_eyes = bool(saved.swap_eyes)
	viewing_eye = int(saved.get("viewing_eye", 0))
	stereo_horizontal = float(saved.get("stereo_horizontal", 0.0))
	stereo_vertical = float(saved.get("stereo_vertical", 0.0))
	spatial_auto_disparity = bool(saved.get("spatial_auto_disparity", true))
	depth_requested = bool(saved.get("depth_requested", false)) and not stereo_sbs
	# Conversion On/Off is per file; legacy per-file strengths must not override the global choice.
	auto_depth = depth_requested
	# The user's own word on a built-in mask wins over the name (renamed official releases).
	if saved.has("packed_mask"):
		packed_file = bool(saved.packed_mask) and geometry == Geometry.Geometry.FISHEYE
		packed_alpha = packed_file

func _restore_usb_mode(identity: String) -> void:
	# USB connection URIs contain a random token. Android reports the stable
	# partition + path identity asynchronously, possibly after the first frame.
	if not local_uri.begins_with("usb://") or mode_memory.identity_aliases.get(local_uri, "") == identity: return
	var early := mode_memory.lookup(local_uri)
	if not mode_memory.register_usb_identity(local_uri, identity) or not _remember_file: return
	var saved := mode_memory.lookup(local_uri)
	if saved.is_empty(): saved = early # Migrate a reachable pre-fix record.
	if not saved.is_empty() and not _mode_user_changed and not _stereo_view_dirty:
		var backend := [stereo_sbs, top_bottom, depth_requested]
		_restore_saved_mode(saved)
		alpha_requested = alpha_requested and not packed_file
		depth_requested = auto_depth and geometry == Geometry.Geometry.FLAT and not stereo_sbs and not alpha_requested
		_layout_pending = null
		if is_spatial_video(): _complete_layout()
		if backend != [stereo_sbs, top_bottom, depth_requested]: _request_revision()
		_apply_geometry()
		_send_depth_view()
		_picture_refresh = 6
	if not saved.is_empty() or _mode_user_changed or _stereo_view_dirty or media.frame_counter > 0:
		_remember_mode(false)

func _remember_mode(user_change: bool = true) -> void:
	if not _remember_file or not media.accepts(media.session_id):
		return
	if not user_change and _mode_memory_cleared: return
	if user_change: _mode_memory_cleared = false
	_mode_user_changed = _mode_user_changed or user_change
	var mode := {"geometry": geometry, "stereo_sbs": stereo_sbs, "swap_eyes": swap_eyes,
		"viewing_eye": viewing_eye, "stereo_horizontal": stereo_horizontal, "stereo_vertical": stereo_vertical,
		"spatial_auto_disparity": spatial_auto_disparity,
		"alpha_requested": false, "profile": profile, "depth_requested": depth_requested,
		"top_bottom": stereo_sbs and top_bottom, "stereo_half": stereo_sbs and stereo_half, "fisheye_fov": fisheye_fov,
		"packed_mask": packed_mask_on()}
	if mode_memory.remember(local_uri, mode) and not mode_memory.save():
		Log.record("file_mode_save_failed", {"error": mode_memory.last_error})

func _on_pair(id: int, payload: String) -> void:
	if not media.accepts(id):
		return
	var pair: Variant = JSON.parse_string(payload)
	if pair is Dictionary:
		_pending_pair = pair
		if OS.is_debug_build() and media.frame_counter < 2:
			DiagnosticLog.record("mpv_pair_offered", {"slot_token": pair.get("slot_token"), "frame_id": pair.get("frame_id"),
				"layer": pair.get("color_target") == "layer", "pending_revision": not _pending_revision.is_empty(),
				"pixel_busy": _pixel_busy, "thumbnail_busy": _thumbnail_busy})

func _present_pending() -> void:
	if _pixel_busy or _thumbnail_busy or _pending_pair.is_empty() or not _pending_revision.is_empty():
		return
	var offered := _pending_pair
	_pending_pair = {}
	var claimed: Variant = JSON.parse_string(platform.claim_mpv_pair(media.session_id, int(offered.slot_token)))
	if not claimed is Dictionary:
		return
	_unbind()
	if not _binding.bind(material, claimed):
		platform.detach_mpv_pair(media.session_id, int(claimed.slot_token))
		picker_error = "Complete video frame could not be bound"
		changed.emit()
		return
	media.last_pair = claimed
	if _binding.layer: _layer_session = true
	# The decoder surface keeps a rotated source's coded orientation: the layer quad is turned.
	layer_rotation = int(claimed.get("surface_rotation_degrees", 0)) if _binding.layer else 0
	media.logical_session_id = int(claimed.logical_session_id)
	media.generation = int(claimed.generation)
	media.format_revision = int(claimed.format_revision)
	media.effect_revision = int(claimed.effect_revision)
	media.frame_counter += 1
	var par := float(claimed.get("pixel_aspect", 1.0))
	_spatial_video = _spatial_video or bool(claimed.get("spatial_video", false))
	_accept_spatial_metadata(claimed)
	media.format = {"width": int(claimed.width), "height": int(claimed.height),
		"spatial_video": _spatial_video,
		"spatial_metadata": spatial_metadata(),
		"pixel_aspect": par if is_finite(par) and par > 0.0 and par <= 16.0 else 1.0,
		"stereo_mode": str(claimed.get("stereo_mode", "")), "unapplied_rotation_degrees": 0,
		"source_rotation_degrees": int(claimed.get("source_rotation_degrees", claimed.get("surface_rotation_degrees", 0)))}
	_accept_source_rotation(int(media.format.source_rotation_degrees))
	_rvm_alpha = bool(claimed.alpha_requested) and bool(claimed.inference_ran)
	depth_enabled = bool(claimed.get("depth_requested", false)) and bool(claimed.get("depth_ran", false))
	_apply_packed()
	material.set_shader_parameter("alpha_enabled", _rvm_alpha)
	material.set_shader_parameter("alpha_edge", alpha_edge) # a bind may have switched the shader
	_send_depth_view()
	_apply_geometry()
	panel.visible = true
	if not platform.acknowledge_mpv_pair(media.session_id, int(claimed.slot_token)):
		_unbind()
		return
	if _waiting_first:
		if control.in_flight > 0: _seek_event("target_presented")
		_waiting_first = false
		_opening_deadline_ms = 0
		_output_deadline_ms = 0
		var actual_position_ms := int(int(claimed.pts_us) / 1000)
		if control.in_flight > 0:
			var seek_request := control.in_flight
			if control.first_frame(actual_position_ms): seek_presented.emit(seek_request, actual_position_ms)
		else:
			control.observe(actual_position_ms, control.duration_ms)
		platform.set_mpv_playing(media.session_id, requested_play)
	else:
		control.observe(int(int(claimed.pts_us) / 1000), control.duration_ms)
	if media.frame_counter == 1:
		_open_trace.append({"stage": "first_pair_bound", "time_ms": Time.get_ticks_msec(), "pts_us": int(claimed.pts_us)})
		_complete_layout()
		_remember_mode(false)
		Log.record("mpv_pair_bound", media.frame_identity())
	_record_history()
	if _debug_request > 0 and not _debug_benchmark and _debug_pairs.size() < 128:
		_debug_pairs.append(claimed.duplicate(true))
		_write_debug_report()
	changed.emit()

func _on_state(id: int, payload: String) -> void:
	if id != media.session_id or not media.error.is_empty():
		return
	var report: Variant = JSON.parse_string(payload)
	if not report is Dictionary:
		return
	if report.get("audio_focus_change", "") == "loss":
		requested_play = false
	media.playback = report
	if media.frame_counter > 0: _restore_capture_layout()
	var subtitle_identity := str(report.get("subtitle_memory_id", ""))
	if not subtitle_identity.is_empty(): _restore_usb_mode(subtitle_identity)
	if track_memory.register_usb_identity(local_uri, subtitle_identity):
		subtitle_timing.register_usb_identity(local_uri, subtitle_identity)
		audio_timing.register_usb_identity(local_uri, subtitle_identity)
		var early_narration := narration.memory.lookup(local_uri)
		narration.memory.register_usb_identity(local_uri, subtitle_identity)
		if not early_narration.is_empty() and narration.memory.remember(local_uri, early_narration): narration.memory.save()
		if _remember_file: narration.reset_source(); narration.reset_source(local_uri)
		# A user may confirm a choice before Android resolves the stable USB id.
		var early_whisper := whisper_memory.lookup(local_uri)
		whisper_memory.register_usb_identity(local_uri, subtitle_identity)
		if not early_whisper.is_empty() and whisper_memory.remember(local_uri, early_whisper): whisper_memory.save()
		if _remember_file:
			if _whisper_command == 0:
				var saved_whisper := whisper_memory.lookup(local_uri)
				audio_whisper = 1 if saved_whisper.get("enabled", false) else 0; audio_boost_saved = int(saved_whisper.get("boost", 0)); _whisper_restore_pending = audio_whisper > 0
			_queue_track_restore(track_memory.lookup(local_uri))
			if _subtitle_timing_key.is_empty():
				subtitle_delay = float(subtitle_timing.lookup(local_uri).get("delay_seconds", 0.0)); subtitles.set_delay(subtitle_delay); _subtitle_delay_pending = true
	_layer_session = bool(report.get("layer_active", false))
	_accept_source_rotation(int(report.get("source_rotation_degrees", 0)))
	var details: Dictionary = report.get("details", {})
	_confirm_audio_whisper(details)
	var size := str(details.get("file_size", ""))
	if not BookmarkStore.integer(_bookmark_metadata.get("size", -1), 1, 9007199254740991) and size.is_valid_int() and BookmarkStore.integer(int(size), 1, 9007199254740991):
		# Native metadata fills gaps for recent/SAF opens, without hashing or reading the video.
		_bookmark_metadata.size = int(size)
		_bookmark_resolve()
	if details.has("position_seconds"):
		var position_ms := int(float(details.position_seconds) * 1000)
		# MPV's time-pos may still be the requested time after a paused keyframe
		# seek. Keep the timeline and relative shortcuts on the displayed frame.
		var pair: Dictionary = media.last_pair
		if pair.get("source_pts_verified", false) and int(pair.get("session_id", -1)) == media.session_id:
			position_ms = int(int(pair.pts_us) / 1000)
		control.observe(position_ms, int(float(details.get("duration_seconds", "-1")) * 1000))
		media.decoder = str(details.get("codec", "")) + " / " + str(details.get("hwdec_current", ""))
	# A rejected software frame can reach END_FILE before the next display frame.
	# Consume its Surface incompatibility before marking this session failed; the
	# bridge may already have queued mpv_error, which must belong to the retired id.
	if _recover_layer_output(): return
	media.state = str(report.get("state", "opening"))
	_restore_tracks()
	if media.state == "ended":
		_record_history(true)
	if _debug_request > 0:
		_debug_status = report.duplicate(true)
		_write_debug_report()
	changed.emit()

func _on_error(id: int, payload: String) -> void:
	if id != media.session_id or (media.state == "failed" and not media.error.is_empty()):
		return
	var report: Variant = JSON.parse_string(payload)
	report = PlaybackErrors.clean(report) if report is Dictionary else {}
	if report.has("session_id") and int(report.session_id) != id: return
	if media.logical_session_id > 0 and (report.has("logical_session_id") or report.has("generation")):
		if int(report.get("logical_session_id", 0)) != media.logical_session_id or int(report.get("generation", 0)) != media.generation: return
	_thumbnail_sequence += 1
	var code := str(report.get("code", "")) if report is Dictionary else ""
	media.error = PlaybackErrors.message(report if report is Dictionary else {})
	media.error_report = report.duplicate(true) if report is Dictionary else {}
	media.state = "failed"
	_audio_pending = false
	_freeze_request = 0
	_pending_revision = {}
	_pending_pair = {}
	_waiting_first = false
	_opening_deadline_ms = 0
	_output_deadline_ms = 0
	_buffering_deadline_ms = 0
	control.reject()
	subtitles.clear()
	_recover = code == "MPV_GL_CONTEXT_RECREATED"
	_recover_ms = control.observed_position_ms
	_unbind()
	Log.record("mpv_error", {"session_id": id, "report": report})
	_write_debug_report()
	changed.emit()
	if not _recover: playback_failed.emit()

func _check_open_timeout(now_ms: int) -> void:
	if _opening_deadline_ms <= 0: return
	if not _waiting_first or media.state in ["closed", "failed"]:
		_opening_deadline_ms = 0
		return
	if now_ms < _opening_deadline_ms: return
	var id: int = media.session_id
	_on_error(id, JSON.stringify({"code": "MPV_OPEN_TIMEOUT", "stage": "opening"}))
	if platform and id > 0: platform.close_mpv_video(id)

func _on_detach(id: int, _payload: String) -> void:
	if int(_binding.ticket.get("session_id", 0)) == id and not _is_frozen():
		_unbind()

func _check_playback_timeout(now_ms: int) -> void:
	if not media.accepts(media.session_id):
		_output_deadline_ms = 0; _buffering_deadline_ms = 0
		return
	if not _waiting_first: _output_deadline_ms = 0
	var code := ""
	if _output_deadline_ms > 0 and now_ms >= _output_deadline_ms: code = "MPV_OUTPUT_TIMEOUT"
	var buffering := requested_play and media.frame_counter > 0 and not _waiting_first \
		and str(media.playback.get("details", {}).get("paused_for_cache", "no")) == "yes"
	if not buffering: _buffering_deadline_ms = 0
	elif _buffering_deadline_ms == 0: _buffering_deadline_ms = now_ms + OUTPUT_TIMEOUT_MS
	elif now_ms >= _buffering_deadline_ms: code = "MPV_BUFFER_TIMEOUT"
	if code.is_empty():
		_check_playback_stall(now_ms)
		return
	var id: int = media.session_id
	_on_error(id, JSON.stringify({"code": code, "stage": "reading" if code == "MPV_BUFFER_TIMEOUT" else "output"}))
	if platform: platform.close_mpv_video(id)

## Sound can keep playing while the picture and MPV's clock stand still (decoder or audio-clock
## stall). Reopen once at the shown position, keeping every choice, instead of freezing for good.
func _check_playback_stall(now_ms: int) -> void:
	var details: Dictionary = media.playback.get("details", {})
	var active := requested_play and media.state == "playing" and media.frame_counter > 0 and not _waiting_first \
		and _pending_revision.is_empty() and control.in_flight == 0 and not control.pending \
		and str(details.get("paused", "yes")) == "no" and str(details.get("paused_for_cache", "no")) != "yes" \
		and str(details.get("eof_reached", "no")) != "yes"
	var position := str(details.get("position_seconds", ""))
	if not _stall_watch.observe(active, float(position) if position.is_valid_float() else NAN, now_ms): return
	var at := int(float(position) * 1000.0)
	Log.record("mpv_playback_stall", {"session_id": media.session_id, "position_ms": at, "layer": _layer_session,
		"decoder": media.decoder, "audio_pts_us": details.get("audio_pts_us", null)})
	call_deferred("_reopen_at", at, _layer_session)

func _on_released(id: int, _payload: String) -> void:
	if id == media.session_id and _recover:
		_recover = false
		call_deferred("_reopen_after_context_loss", local_uri, display_name, _recover_ms, _remember_file, id)
	_write_debug_report()

func loading_caption() -> String:
	if not media.accepts(media.session_id) or not media.error.is_empty(): return ""
	if NarrationSettings.FEATURE_ENABLED and narration.enabled:
		var report: Dictionary = media.playback.get("narration", {})
		var stage := NarrationSettings.display_status(report)
		if (requested_play or bool(report.get("preview", false))) and stage in ["verifying", "model_loading", "preparing", "preview_buffering", "subtitle_loading"]:
			var text := I18n.t(NarrationSettings.status_label(stage))
			var progress := NarrationSettings.progress_percent(report)
			return text + (" · %d%%" % progress if progress >= 0 else "")
	if NarrationSettings.FEATURE_ENABLED and requested_play and bool(media.playback.get("narration", {}).get("startup_hold", false)):
		return I18n.t("Preparing narration…")
	var buffering := requested_play and str(media.playback.get("details", {}).get("paused_for_cache", "no")) == "yes"
	if not _waiting_first and not buffering: return ""
	var status: Dictionary = _loading_status.duplicate()
	status.elapsed_ms = Time.get_ticks_msec() - (_buffering_started_ms if buffering and not _waiting_first else _loading_started_ms)
	if buffering and not _waiting_first: status.phase = "buffering"
	elif _waiting_first and status.get("phase", "") == "reading" and not buffering and not str(media.playback.get("details", {}).get("codec", "")).is_empty():
		status.phase = "preparing"
	if not status.has("bytes_per_second"):
		var speed := str(media.playback.get("details", {}).get("cache_speed", ""))
		if speed.is_valid_float(): status.bytes_per_second = float(speed)
	return Loading.caption(status)

func _poll_loading(now_ms: int) -> void:
	var buffering := requested_play and str(media.playback.get("details", {}).get("paused_for_cache", "no")) == "yes"
	if not buffering: _buffering_started_ms = 0
	elif _buffering_started_ms == 0: _buffering_started_ms = now_ms
	if not media.accepts(media.session_id) or (not _waiting_first and not buffering) or now_ms < _loading_poll_ms: return
	_loading_poll_ms = now_ms + 500
	if PlatformMethods.supports(platform, "get_mpv_loading_status"):
		var report: Variant = JSON.parse_string(platform.get_mpv_loading_status(media.session_id))
		if report is Dictionary: _loading_status = report
	var bytes := int(_loading_status.get("bytes", -1))
	var progressing := bytes > 0 and bytes > _loading_bytes
	if not _loading_status.has("bytes"):
		var rate := str(media.playback.get("details", {}).get("cache_speed", ""))
		progressing = rate.is_valid_float() and float(rate) > 0
	_loading_bytes = bytes
	if progressing:
		if _opening_deadline_ms > 0: _opening_deadline_ms = now_ms + OPEN_TIMEOUT_MS
		if _output_deadline_ms > 0: _output_deadline_ms = now_ms + OUTPUT_TIMEOUT_MS
		if _buffering_deadline_ms > 0: _buffering_deadline_ms = now_ms + OUTPUT_TIMEOUT_MS

func _reopen_after_context_loss(uri: String, title: String, position_ms: int, remember_file: bool, expected_session: int = 0) -> void:
	if uri != local_uri or (expected_session > 0 and expected_session != media.session_id): return
	# Retain live user choices even if the last disk save failed.
	var persisted := _file_permission_persisted
	var mode_user_changed := _mode_user_changed
	var mode_memory_cleared := _mode_memory_cleared
	var eye := viewing_eye
	var alignment := Vector2(stereo_horizontal, stereo_vertical)
	var spatial := [_spatial_video, spatial_metadata(), spatial_auto_disparity]
	var tracks := _capture_track_choices()
	var narration_state := narration.capture_reopen()
	var timing := [_subtitle_timing_key, subtitle_delay]
	var whisper := audio_whisper
	var boost_mark := audio_boost_saved
	var whisper_save := _whisper_remember or _whisper_restore_remember
	var auto_subtitle := _subtitle_auto_pending # An internal reopen keeps an unfinished automatic choice.
	pip.reopening = true
	var reopened := open_local(uri, title, position_ms, false, alpha_wanted())
	pip.reopening = false
	if not reopened: pip.clear()
	if reopened:
		narration.restore_reopen(narration_state)
		_subtitle_auto_pending = auto_subtitle
		_queue_track_restore(tracks)
		_subtitle_timing_key = timing[0]; subtitle_delay = timing[1]; subtitles.set_delay(subtitle_delay); _subtitle_delay_pending = true
		_remember_file = remember_file
		_mode_user_changed = mode_user_changed
		_mode_memory_cleared = mode_memory_cleared
		audio_whisper = whisper; audio_boost_saved = boost_mark; _whisper_restore_pending = whisper > 0 or whisper_save; _whisper_restore_remember = whisper_save
		_file_permission_persisted = persisted
		viewing_eye = eye
		stereo_horizontal = alignment.x
		stereo_vertical = alignment.y
		_spatial_video = spatial[0]
		_spatial_metadata = spatial[1]
		spatial_auto_disparity = spatial[2]
		if is_spatial_video(): _complete_layout()
		_apply_stereo_view()

func _on_debug_command(id: int, payload: String) -> void:
	var command: Variant = JSON.parse_string(payload)
	if command is Dictionary and command.get("operation", "") in ["open", "seek"] and command.get("seek_mode", "") in [SeekPolicy.SPEED, SeekPolicy.EXACT]:
		seek_mode = command.seek_mode
	if not command is Dictionary:
		return
	_debug_request = id
	if command.operation == "open":
		_debug_benchmark = bool(command.get("benchmark", false))
		loop_enabled = bool(command.get("loop", false)) # long thermal runs replay a short fixture
		_debug_next_report_us = 0
		if _debug_benchmark:
			geometry = int(command.get("projection", 0))
		_debug_commands = []
		_debug_pairs = []
		stereo_sbs = bool(command.get("stereo", true))
		profile = str(command.profile)
		alpha_requested = bool(command.enabled)
		depth_requested = bool(command.get("depth", false))
		auto_depth = depth_requested
		requested_play = true
		layer_enabled = bool(command.get("layer", true))
		open_local(str(command.uri), str(command.title), maxi(int(command.position_ms), 0), false, alpha_requested)
	elif command.operation == "alpha":
		set_alpha(bool(command.enabled))
	elif command.operation == "depth":
		command["accepted"] = set_depth_strength(float(command.strength)) if command.has("strength") else set_depth(bool(command.enabled))
	elif command.operation == "audio":
		command["accepted"] = set_audio_options(int(command.track_id), audio_volume, audio_muted)
	elif command.operation == "audio_delay":
		command["accepted"] = local_uri.get_base_dir().ends_with("/files/fixtures") and set_audio_delay(float(command.get("seconds", NAN)))
	elif command.operation == "narration":
		command["accepted"] = true
		for key in command.get("options", {}):
			if not narration.set_option("narration_" + str(key), command.options[key]): command.accepted = false
	elif command.operation == "narration_status":
		command["health"] = platform.save_narration_test_status(media.session_id, str(command.request_key))
	elif command.operation == "subtitle":
		command["accepted"] = set_subtitle_track(int(command.track_id))
	elif command.operation == "playing":
		if requested_play != bool(command.enabled) or (bool(command.enabled) and media.state == "ended"):
			toggle_play()
	elif command.operation == "seek":
		_debug_seek_delay_until_ms = Time.get_ticks_msec() + clampi(int(command.get("hold_seek_ms", 0)), 0, 30000)
		seek_absolute(int(command.position_ms))
	elif command.operation == "hold_pixels":
		if _is_frozen() and not _pixel_busy:
			var held: Dictionary = _binding.ticket.duplicate(true)
			if _binding.warped: held.stereo_sbs = false
			var pinned: bool = platform.retain_mpv_frozen_frame(int(held.frozen_frame_id))
			if not pinned: return
			_pixel_busy = true
			_debug_pixels = await PixelProbe.capture(self, held, id)
			_debug_pixels["request_key"] = str(command.request_key)
			platform.release_mpv_frozen_frame(int(held.frozen_frame_id))
			_pixel_busy = false
	elif command.operation == "observe":
		pass
	elif command.operation == "stereo":
		if stereo_sbs != bool(command.enabled):
			toggle_stereo()
	elif command.operation == "profile":
		profile = str(command.profile)
		_warm_rvm() # as set_profile: a cold profile starts its background compile
		_request_revision()
	elif command.operation == "close":
		close_video()
	elif command.operation == "pixels":
		_debug_pixels = {"state": "failed", "request_id": id, "request_key": str(command.request_key)}
		if not _pixel_busy and not requested_play and not _binding.ticket.is_empty() and _pending_revision.is_empty():
			_pixel_busy = true
			_pixel_request = id
			_pixel_request_key = str(command.request_key)
			if platform.request_mpv_pixel_mask(id, int(_binding.ticket.session_id), int(_binding.ticket.slot_token)):
				_debug_pixels["state"] = "waiting_mask"
			else:
				_pixel_busy = false
				_debug_pixels["error"] = "Native pinned mask request rejected"
		else:
			_debug_pixels["error"] = "Paused immutable binding required"
	command["request_id"] = id
	_debug_commands.append(command)
	if _debug_commands.size() > 32:
		_debug_commands.pop_front()
	_write_debug_report()

func _on_pixel_mask(id: int, payload: String) -> void:
	if id != _pixel_request:
		return
	var mask: Variant = JSON.parse_string(payload)
	if not mask is Dictionary or mask.get("state") != "ready":
		_debug_pixels = {"state": "failed", "request_id": id, "error": "Native mask readback failed", "native": mask}
		_pixel_busy = false
		_write_debug_report()
		return
	var pair: Dictionary = mask.pair
	_debug_pixels = await PixelProbe.capture(self, pair, id)
	_debug_pixels["request_key"] = _pixel_request_key
	_debug_pixels["mask_reference"] = mask
	_debug_pixels["native_pin_released"] = platform.release_mpv_pixel_pin(int(pair.session_id), int(pair.slot_token))
	_pixel_busy = false
	_write_debug_report()

func _write_debug_report() -> void:
	if ModeMemory.Privacy.mode != ModeMemory.Privacy.ALL or (ModeMemory.Privacy.vault != null and ModeMemory.Privacy.vault.protected): return
	if _debug_request <= 0 or not platform:
		return
	var now := Time.get_ticks_usec()
	if _debug_benchmark and now < _debug_next_report_us:
		return
	_debug_next_report_us = now + 250000
	var progress: Dictionary = {}
	var host := get_parent()
	if host and host.has_method("_menu_state"):
		var menu: Node3D = host.player_menu
		if menu and menu.visible and is_instance_valid(menu._thumb):
			progress = {"visible": true, "position_ms": int(menu._state.get("position_ms", -1)),
				"preview_ms": menu._seek_preview, "elapsed": menu._elapsed.text,
				"thumb_x": menu._thumb.position.x, "bar_width": menu.BAR_SEEK,
				"duration_ms": int(menu._state.get("duration_ms", -1))}
	var report := {"schema_version": 1, "request_id": _debug_request, "commands": _debug_commands,
		"seek_policy_ui": host.seek_policy_probe_result if host and host.get("seek_policy_probe_result") is Dictionary else {},
		"pip_probe": host.pip_probe_result if host and host.get("pip_probe_result") is Dictionary else {},
		"open_trace": _open_trace.duplicate(true),
		"media": media.snapshot(), "layout": layout_snapshot(), "pairs": _debug_pairs,
		"native_status": _debug_status, "engine_fps": Engine.get_frames_per_second(),
		"sample_monotonic_us": now, "engine_drawn_frames": Engine.get_frames_drawn(),
		"benchmark": _debug_benchmark,
		"pixel_probe": _debug_pixels,
		"seek_trace": _seek_trace,
		"player_menu_progress": progress,
		"thumbnail": {"available": Thumbnails.has(local_uri), "capture": _thumbnail_result, "busy": _thumbnail_busy or _layer_thumbnail_busy},
		"diagnostic_2d": OS.get_cmdline_user_args().has("--mpv-diagnostic-2d"),
		"scope": "Production MPV/RVM/Godot ownership trace; independent pixel, audio and performance validation pending"}
	platform.save_mpv_player_report(_debug_request, JSON.stringify(report))

func _source_size() -> Vector2:
	return Vector2(float(media.format.width), float(media.format.height))

func _sync_subtitle_surface() -> void:
	if not _subtitle_surface or not material: return
	# The layer shows no shader overlays: subtitles go on their own surface above the hole.
	var separate := not is_zero_approx(screen_rotation) or _layer_session or video_layer_shown
	material.set_shader_parameter("separate_subtitles", separate)
	_subtitle_surface.visible = separate and panel.visible and not _subtitle_on_layer \
		and (material.get_shader_parameter("subtitle_enabled") == true or material.get_shader_parameter("bitmap_subtitle_enabled") == true)
	if not _subtitle_surface.visible: return
	if geometry == Geometry.Geometry.FLAT:
		_subtitle_surface.mesh = panel.mesh
		_subtitle_surface.global_transform = subtitle_transform()
	else:
		# Each eye's ray through the sphere meets the caption plane where it would meet the plane
		# itself, so drawing just the plane's patch is the same image. The whole VR180/360 sphere
		# ran this blended pass over most of each eye (a 10-20 FPS cost on XR2 Gen1 headsets).
		var extent: Variant = material.get_shader_parameter("subtitle_patch_half_extent")
		var half: float = extent if extent != null else 0.35
		var to_patch: Variant = material.get_shader_parameter("subtitle_world_to_patch")
		if not to_patch is Transform3D:
			_subtitle_surface.visible = false
			return
		if not _subtitle_patch or not is_equal_approx(_subtitle_patch.size.x, half * 2.0):
			_subtitle_patch = QuadMesh.new()
			_subtitle_patch.size = Vector2.ONE * half * 2.0
		_subtitle_surface.mesh = _subtitle_patch
		_subtitle_surface.global_transform = (to_patch as Transform3D).affine_inverse()
	for key in ["subtitle_texture", "subtitle_enabled", "subtitle_world_to_patch", "subtitle_patch_half_extent", "bitmap_subtitle_texture", "bitmap_subtitle_enabled", "bitmap_subtitle_rect", "rotation_degrees"]:
		_subtitle_material.set_shader_parameter(key, material.get_shader_parameter(key))

func _pixel_aspect() -> float:
	return float(media.format.get("pixel_aspect", 1.0))

func _apply_flat_pose() -> void:
	if cinema.active(self): screen_rotation = 0.0
	cinema.constrain(self)
	super._apply_flat_pose()
	if caption and caption.visible: _place_caption()
	_sync_subtitle_surface()

func set_flat_world_pose(pose: Transform3D) -> void:
	if cinema.active(self): cinema.capture(self, pose)
	super.set_flat_world_pose(pose)

func set_screen_scale(value: float) -> void:
	# Leaving a preset must not move the visible bottom edge before manual resizing.
	if not screen_preset.is_empty() and cinema.active(self) and cinema.bottom is Transform3D:
		cinema.height += (screen_frame_height() - _flat.size.y) * 0.5
		cinema.bottom = cinema.content_bottom(self)
	screen_preset = ""
	super.set_screen_scale(value)
	if cinema.active(self): _apply_flat_pose()

func screen_frame_height() -> float:
	var preset: Dictionary = ScreenPresets.find(screen_preset)
	return float(preset.size.y) if not preset.is_empty() else _flat.size.y

func corner_at(origin: Vector3, direction: Vector3) -> int:
	var corner := super.corner_at(origin, direction)
	return -1 if cinema.active(self) and corner >= 2 else corner

func _apply_geometry() -> void:
	super._apply_geometry()
	if geometry == Geometry.Geometry.FLAT and not ScreenPresets.find(screen_preset).is_empty():
		super.set_screen_scale(ScreenPresets.scale_for(screen_preset, _screen_base))
	# Metadata/aspect changes can alter height after the initial pose was applied.
	if cinema.active(self): _apply_flat_pose()
	_apply_stereo_view()
	if geometry != Geometry.Geometry.FLAT:
		bitmap_subtitles.clear(material)
		if _subtitle_surface: _subtitle_surface.visible = false
		for track in media.playback.get("details", {}).get("subtitle_tracks", []):
			if track is Dictionary and int(track.get("id", 0)) == subtitles.requested_track and str(track.get("codec", "")) == "hdmv_pgs_subtitle":
				var choice := TrackMemory.describe(subtitles.requested_track, _raw_tracks("subtitle"))
				if set_subtitle_track(0, false) and not choice.is_empty(): _track_restore.subtitle = choice
	_apply_packed()
	if caption and caption.visible: _place_caption()
	_sync_subtitle_surface()
	material.set_shader_parameter("stereo_sbs", stereo_sbs or _binding.warped)
	material.set_shader_parameter("depth_enabled", depth_enabled and not _binding.warped)
	material.set_shader_parameter("depth_shift", DEPTH_SHIFT * depth_strength if depth_requested else 0.0)

func layout_snapshot() -> Dictionary:
	var playback := control.snapshot()
	playback["seek_method"] = "mpv_absolute_" + ("exact" if _last_seek_mode == SeekPolicy.EXACT else "keyframes") + "_and_processing_generation"
	playback["seek_mode"] = SeekPolicy.normalize(seek_mode)
	playback["active_seek_mode"] = _last_seek_mode
	playback["bookmark_seek_mode"] = SeekPolicy.bookmark_override(bookmark_seek_mode)
	playback["source_frame_pts_verified"] = not media.last_pair.is_empty()
	return {"geometry": ["flat", "half_equirect_180", "fisheye_180", "equirect_360"][geometry], "stereo_sbs": stereo_sbs,
		"viewing_eye": viewing_eye, "stereo_horizontal": stereo_horizontal, "stereo_vertical": stereo_vertical,
		"spatial_video": is_spatial_video(), "spatial_metadata": spatial_metadata(), "spatial_auto_disparity": spatial_auto_disparity,
		"top_bottom": stereo_sbs and top_bottom, "stereo_half": stereo_sbs and stereo_half, "fisheye_fov": fisheye_fov,
		"alpha_requested": alpha_requested, "alpha_enabled": alpha_enabled, "profile": profile,
		"depth_requested": depth_requested, "depth_enabled": depth_enabled, "depth_strength": depth_strength, "auto_depth": auto_depth,
		"screen_rotation": screen_rotation, "playback_speed": playback_speed,
		"video_layer": {"shown": video_layer_shown, "surface": _layer_session, "picture_token": _picture_token,
			"warped": _binding.warped, "layers": video_layer.debug_layers() if video_layer else []},
		"pip": pip.compositor.snapshot(),
		"alpha_ready": alpha_ready(), "backend": "Android_libmpv", "loop_enabled": loop_enabled,
		"playback_control": playback, "subtitles": {"requested_track": subtitles.requested_track,
			"cue": subtitles.cue, "text": subtitles.text,
			"bitmap_ready": geometry == Geometry.Geometry.FLAT and bitmap_subtitles.texture != null \
				and bool(material.get_shader_parameter("bitmap_subtitle_enabled")),
			"bitmap_texture_version": bitmap_subtitles.version,
			"bitmap_texture_size": [bitmap_subtitles.texture.get_width(), bitmap_subtitles.texture.get_height()] if bitmap_subtitles.texture else [],
			"render_layer": "flat_PGS_bitmap_overlay" if bitmap_subtitles.texture and geometry == Geometry.Geometry.FLAT \
				else ("independent_Label3D" if geometry == Geometry.Geometry.FLAT else "video_projection_overlay"),
			"size": subtitle_size, "flat_position": subtitle_flat_position, "rotation_independent": true,
			"distance_m": subtitle_distance, "position": subtitle_position, "direction": subtitle_direction,
			"runtime_ipd_m": ProjectedSubtitles.runtime_ipd(),
			"projection": "flat_Label3D" if geometry == Geometry.Geometry.FLAT else "per_eye_ray_plane",
			"plane_center_world": [] if geometry == Geometry.Geometry.FLAT else [projected_subtitles.plane_pose.origin.x, projected_subtitles.plane_pose.origin.y, projected_subtitles.plane_pose.origin.z],
			"anchor_space": "screen" if geometry == Geometry.Geometry.FLAT else "video_local",
			"anchor_direction": _subtitle_anchor_direction(),
			"source_frame_sync_verified": false, "device_validation": "pending"},
		"frame_hold": {"visible": panel.visible, "frozen": _is_frozen(), "capture_pending": _freeze_request > 0,
			"frame_id": int(_binding.ticket.get("frame_id", -1)), "pts_us": int(_binding.ticket.get("pts_us", -1)),
			"frozen_frame_id": int(_binding.ticket.get("frozen_frame_id", 0)),
			"freeze_copy_us": int(_binding.ticket.get("freeze_copy_us", 0))}, "device_validation": "pending"}

func _subtitle_anchor_direction() -> Array:
	var anchor := SubtitleDepth.anchor(subtitle_position, subtitle_direction == 1) * Vector3.FORWARD
	return [anchor.x, anchor.y, anchor.z]

func _can_loop() -> bool:
	return loop_enabled and playback_end_ready()

## A natural EOF is actionable only after its final source frame was presented.
func playback_end_ready() -> bool:
	if not requested_play or media.state != "ended" or _waiting_first or not _pending_revision.is_empty() or control.pending or control.in_flight > 0 or not media.error.is_empty():
		return false
	var end: Dictionary = media.playback
	var final_pair: Dictionary = media.last_pair
	var target: Variant = end.get("eof_source_ticket")
	if not end.get("eof_source_resolved", false) or not end.get("eof_pair_post_draw", false) or not target is Dictionary or final_pair.is_empty():
		return false
	return int(end.get("eof_presented_slot", 0)) == int(final_pair.get("slot_token", -1)) \
		and int(target.source_epoch) == int(final_pair.get("source_epoch", -1)) \
		and int(target.frame_id) == int(final_pair.get("frame_id", -1)) \
		and int(target.pts_us) == int(final_pair.get("pts_us", -1)) \
		and (not alpha_requested or final_pair.get("inference_ran", false) or final_pair.get("color_target") == "layer")

func _process(_delta: float) -> void:
	system_volume.poll()
	narration.apply()
	_poll_loading(Time.get_ticks_msec())
	_check_open_timeout(Time.get_ticks_msec())
	_check_playback_timeout(Time.get_ticks_msec())
	_restore_tracks()
	_sync_audio_timing()
	if _whisper_restore_pending and PlatformMethods.supports(platform, "set_mpv_whisper"):
		set_audio_whisper(audio_whisper, _whisper_restore_remember)
	if _audio_pending:
		set_audio_options(audio_track_id, audio_volume, audio_muted)
	elif prefer_clone_voice and not _clone_applied and clone_voice_track() > 0:
		_clone_applied = set_audio_options(clone_voice_track(), audio_volume, audio_muted)
	if panel and geometry != Geometry.Geometry.FLAT:
		_center_on_view()
	if not _pending_revision.is_empty():
		_try_revision()
	_present_pending()
	pip.sync()
	_update_layer()
	_maybe_capture_thumbnail()
	_poll_subtitles()
	_process_playback_end()

func _process_playback_end() -> void:
	if not playback_end_ready(): return
	if loop_enabled:
		seek_absolute(0)
	else:
		var identity := str([media.session_id, control.sequence, media.last_pair.get("slot_token", 0)])
		if identity != _completed_end:
			_completed_end = identity
			playback_completed.emit()

## Video frames shown so far: presented pairs, or on the video layer (whose pairs only mark
## restarts and positions) the frames MPV released to the layer surface minus its drops. The layer
## copy (Alpha) counts what it drew itself: it drops frames above the Alpha rate and without masks.
func presented_frames() -> int:
	if not _binding.layer:
		return media.frame_counter
	var copy: Variant = media.playback.get("layer_copy")
	if copy is Dictionary and copy.has("drawn"):
		return int(copy.drawn)
	var details: Dictionary = media.playback.get("details", {})
	return maxi(0, str(details.get("estimated_frame_number", "0")).to_int() - str(details.get("vo_frame_drop_count", "0")).to_int())

## The displayed per-eye UV shift of the stereo alignment (as the shader's stereo_offset).
func stereo_offset_uv() -> Vector2:
	var offset := Vector2(stereo_horizontal, stereo_vertical) * 0.01
	if is_spatial_video() and spatial_auto_disparity:
		# Positive Apple disparity moves the left image left (positive sampling UV).
		# It follows the source eyes; the user's alignment follows the display eyes.
		offset.x -= float(_spatial_metadata.get("horizontal_disparity", 0.0)) * (-1.0 if swap_eyes else 1.0)
	return offset

## Presentation the compositor layer can show exactly: plain decoder colour on a supported shape.
## The configuration shows on the compositor layer (independent of a reopen in progress).
func layer_capable() -> bool:
	return _layer_presentation() or (pip.video_windows().is_empty() and _fisheye_layer_config())

## A native recording owns its decoder session. Do not silently end it to change outputs.
func pip_available(count: int = 1) -> bool:
	return media.frame_counter > 0 and (pip.compositor.direct_compatible(count) or not ((_layer_session or _layer_requested) and not captures.recording.is_empty()))

func set_pip_count(count: int, head: Transform3D) -> void:
	if local_uri.is_empty() or not media.accepts(media.session_id) or media.state == "failed": return
	if count > pip.windows.size() and not pip_available(count): return
	pip.set_count(count, head)

func toggle_pip_slot(slot: int, head: Transform3D) -> void:
	if slot < 1 or slot > 3 or local_uri.is_empty() or not media.accepts(media.session_id) or media.state == "failed": return
	if not pip.windows.has(slot) and not pip_available(pip.windows.size() + 1): return
	pip.toggle_slot(slot, head)

## Fisheye settings the remapped picture layer can show exactly (the layer applies eyes, alignment,
## grading and filters); anything else stays in the eye buffers.
func _fisheye_layer_config() -> bool:
	return geometry == Geometry.Geometry.FISHEYE and not _fisheye_failed and layer_enabled and video_layer != null 		and video_layer.available() and video_layer.supports(Geometry.Geometry.HALF_EQUIRECT, false) 		and not alpha_requested and not depth_requested and not packed_file and video_layer.grades(color_grade) 		and int(media.format.get("source_rotation_degrees", 0)) == 0 and PlatformMethods.supports(platform, "remap_layer_fisheye")

func _fisheye_picture_wanted() -> bool:
	var ticket := _binding.ticket
	if not _fisheye_layer_config() or ticket.is_empty() or _binding.layer or _binding.warped: return false
	if int(ticket.get("session_id", 0)) != media.session_id or media.state == "failed" or int(ticket.get("rotation_degrees", 0)) != 0: return false
	return _binding.color_texture().is_valid()

func _show_fisheye_picture(origin: XROrigin3D, extras: Array) -> bool:
	var ticket := _binding.ticket
	var size := Vector2i(int(ticket.width), int(ticket.height))
	var span := VideoLayer.fisheye_span(float(fisheye_fov))
	var picture := fisheye_picture_size(size, span, stereo_sbs, top_bottom, debug_fisheye_density if debug_fisheye_density > 0.0 else FISHEYE_PIXELS_PER_DEGREE)
	var token := int(ticket.get("slot_token", 0))
	var scale: Array = ticket.get("color_uv_scale", [1.0, 1.0])
	var layout := 0 if not stereo_sbs else (2 if top_bottom else 1)
	var params := PackedFloat32Array([layout, 1.0 if stereo_sbs and stereo_half else 0.0, float(fisheye_fov),
		span.x, span.y, size.x, size.y, float(scale[0]), float(scale[1])])
	if token != _picture_token or params != _fisheye_parameters or _fisheye_generation != video_layer.generation \
		or Vector2i(video_layer.picture_size) != picture:
		if not platform.create_layer_image(VideoLayer.PICTURE_SLOT, picture.x, picture.y, 1, false):
			return _fisheye_fail("create", picture)
		if Vector2i(video_layer.picture_size) != picture:
			video_layer.invalidate() # a new swapchain for this size
			video_layer.picture_size = Vector2(picture)
		if platform.acquire_layer_image(VideoLayer.PICTURE_SLOT) <= 0: return false
		var external := str(ticket.get("color_target", "")) == "external"
		var source := RenderingServer.texture_get_native_handle(_binding.color_texture())
		var drawn: bool = platform.remap_layer_fisheye(VideoLayer.PICTURE_SLOT, source, external, params)
		if not platform.release_layer_image(VideoLayer.PICTURE_SLOT, false) or not drawn: return _fisheye_fail("remap", picture)
		_picture_token = token
		_fisheye_parameters = params; _fisheye_generation = video_layer.generation
		if _fisheye_session != media.session_id:
			_fisheye_session = media.session_id
			DiagnosticLog.record("fisheye_picture", {"source": [size.x, size.y], "picture": [picture.x, picture.y], "fov": fisheye_fov, "external": external})
	# Until this session's first remap is on the layer, the eye buffers show the lens.
	if _fisheye_session != media.session_id: return false
	_check_fisheye_load()
	return video_layer.show(self, origin, VideoLayer.PICTURE, Vector2(picture), -1, Vector2.ZERO, Vector4(0, 0, 1, 1),
		VideoLayer.OPAQUE, extras)

## Remapped picture size: each view [span] radians at [density] pixels per degree, never denser than
## the source's own view, laid out as the source (side by side, above each other, or mono).
static func fisheye_picture_size(source: Vector2i, span: Vector2, sbs: bool, top_bottom: bool, density: float) -> Vector2i:
	return VideoLayer.fisheye_picture_size(source, span, sbs, top_bottom, density)

func _check_fisheye_load() -> void:
	var now := Time.get_ticks_msec()
	if fisheye_overloaded or now - _fisheye_checked_ms < 1000: return
	_fisheye_checked_ms = now
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	var rate := xr.display_refresh_rate if xr and xr.is_initialized() else 0.0
	if rate <= 90.5 or not requested_play: _fisheye_slow_seconds = 0; return
	_fisheye_slow_seconds = _fisheye_slow_seconds + 1 if Engine.get_frames_per_second() < rate * FISHEYE_SLOW_RATIO else 0
	if _fisheye_slow_seconds >= FISHEYE_SLOW_SECONDS:
		fisheye_overloaded = true; _fisheye_overloaded_uri = local_uri
		DiagnosticLog.record("fisheye_overloaded", {"refresh": rate, "fps": Engine.get_frames_per_second()})

func _fisheye_fail(stage: String, size: Vector2i) -> bool:
	_fisheye_failed = true
	DiagnosticLog.record("fisheye_picture_failed", {"stage": stage, "size": [size.x, size.y]})
	return false

func _layer_presentation() -> bool:
	return (pip.video_windows().is_empty() or pip.compositor.direct_compatible()) and layer_enabled and video_layer != null and (not alpha_requested or _layer_alpha()) and not depth_requested and not packed_file \
		and video_layer.capacity() >= (2 if stereo_sbs else 1) + 1 \
		and (local_uri.is_empty() or local_uri != _layer_blocked_uri) \
		and video_layer.grades(color_grade) and video_layer.supports(geometry, screen_curve > 0.0) \
		and (int(media.format.get("source_rotation_degrees", 0)) == 0 or _layer_turns())

## Alpha may stay on the layer: allowed by the platform, and the runtime blends layers by the mask
## (XR_FB_composition_layer_alpha_blend). Without that blend the video layer would show uncut, so
## Alpha uses the eye buffers instead.
func _layer_alpha() -> bool:
	return _layer_alpha_allowed and video_layer != null and video_layer.alpha_blend

## Short code for the FPS overlay: why playback is in the eye buffers ("" when on the layer).
func layer_block_reason() -> String:
	if video_layer_shown: return ""
	if not pip.video_windows().is_empty(): return "pip"
	if video_layer == null or not video_layer.available(): return "xr"
	# Alpha itself blocks the layer only where it may not use it; otherwise name the real blocker.
	if alpha_requested and not _layer_alpha_allowed: return "alpha"
	if alpha_requested and not video_layer.alpha_blend: return "blend" # runtime without XR_FB_composition_layer_alpha_blend
	if depth_requested: return "3d"
	if packed_file: return "packed"
	if not local_uri.is_empty() and local_uri == _layer_blocked_uri: return "decoder"
	if not video_layer.grades(color_grade): return "color"
	if not video_layer.supports(geometry, screen_curve > 0.0): return "shape"
	return "wait"

## RGBA frames already have their file orientation baked by MPV. Keep manual rotation as an
## extra adjustment. A flat, uncurved, mono screen shows a rotated source on the decoder surface by
## turning its quad; other shapes never reopen this file on the unnormalized surface.
func _accept_source_rotation(rotation: int) -> void:
	if rotation == 0 or _layer_turns(): return
	_layer_blocked_uri = local_uri
	_layer_return_uri = ""

## The compositor can turn only a quad: a rotated source keeps the layer on flat, uncurved, mono screens.
func _layer_turns() -> bool:
	return geometry == Geometry.Geometry.FLAT and screen_curve <= 0.0 and not stereo_sbs

func _layer_wanted() -> bool:
	if video_layer: video_layer.update_session()
	return video_layer != null and video_layer.available() and _layer_presentation()

func _origin() -> XROrigin3D:
	return view_camera.get_parent() as XROrigin3D if view_camera else null

func _recover_layer_output() -> bool:
	if not (_layer_session or _layer_requested) or not media.accepts(media.session_id) \
		or media.playback.get("layer_compatible", true) != false or local_uri.is_empty():
		return false
	_layer_blocked_uri = local_uri
	_reopen_on_eye_buffer(-1) # Profile 5, software decode or rotation: MPV must normalize.
	return true

## Keep the layer, the hole and the subtitles in step with the video surface every frame.
func _update_layer() -> void:
	if not video_layer:
		return
	video_layer.update_session()
	if _layer_session and media.accepts(media.session_id) and media.frame_counter > 0 and media.state != "failed" \
		and _pending_revision.is_empty() and not _layer_presentation():
		_reopen_on_eye_buffer(-1)
		return
	if _layer_session and video_layer.generation != _layer_generation and media.accepts(media.session_id) \
		and _pending_revision.is_empty():
		_reopen_at(-1, true) # a new XR session replaced the swapchain MPV decodes into
		return
	if media.accepts(media.session_id) and media.playback.get("network_interleave_retry", false):
		media.playback["network_interleave_retry"] = false # close_video updates the layer before retiring this session.
		_network_interleave_compat = true
		_reopen_at(int(media.playback.get("network_interleave_restart_ms", 0)), _layer_session or _layer_requested)
		return
	# Profile 5 and a software decoder are known before the surface shows anything (no frame would come).
	if _recover_layer_output(): return
	# Back from a temporary shader effect: the layer again, at the shown position.
	if not _layer_session and not _layer_return_uri.is_empty() and _layer_return_uri == local_uri \
		and media.accepts(media.session_id) and media.frame_counter > 0 and _pending_revision.is_empty() \
		and captures.recording.is_empty() \
		and _freeze_request == 0 and not _waiting_first and _thumb_after_ms < 0 and not _thumbnail_busy and _layer_wanted():
		_layer_return_uri = ""
		_reopen_at(-1, true)
		return
	var origin := _origin()
	if _layer_seek_hold and not _waiting_first: _layer_seek_hold = false
	var layer_size := Vector2(float(media.playback.get("layer_surface_width", VideoLayer.SURFACE_SIZE)), \
		float(media.playback.get("layer_surface_height", VideoLayer.SURFACE_SIZE)))
	var previous_processed := _processed_picture
	_processed_picture = pip.compositor.prepare_main() if origin != null else false
	if previous_processed and not _processed_picture:
		_picture_token = -1 # processed main owned slot 0; an older copy there no longer exists
		_fisheye_session = 0
		_apply_stereo_view()
	_frame_picture = not _processed_picture and not _layer_session and origin != null and _frame_picture_wanted()
	_fisheye_picture = not _processed_picture and not _layer_session and origin != null and not _frame_picture and _fisheye_picture_wanted()
	var extras := _subtitle_layer_extras(origin) if origin != null else []
	var masked := alpha_probe > 0 and origin != null and video_layer.alpha_blend and geometry == Geometry.Geometry.FLAT and _alpha_probe_layers(origin, layer_size, extras)
	if not masked and alpha_requested and _layer_session and origin != null and video_layer.alpha_blend:
		masked = _alpha_mask_layers(origin, layer_size, extras)
	# Reserve main eyes and subtitles/masks before allocating complete PiP eye pairs.
	var main_layers := 0
	if _layer_session or _layer_seek_hold or _frame_picture or _fisheye_picture or _binding.warped:
		main_layers = 2 if stereo_sbs or _binding.warped else 1
	if _processed_picture: main_layers = pip.compositor.main_eyes
	var pip_layers: Array = pip.compositor.prepare(origin, main_layers + extras.size()) if pip.active() else []
	extras.append_array(pip_layers)
	var shown := (_layer_session or _layer_seek_hold) and media.accepts(media.session_id) \
		and (media.frame_counter > 0 or _layer_seek_hold) \
		and media.state != "failed" and origin != null \
		and video_layer.show(self, origin, VideoLayer.SURFACE, layer_size, -1, Vector2.ZERO, Vector4(0, 0, 1, 1),
			VideoLayer.MASKED if masked else VideoLayer.OPAQUE, extras)
	if not shown and _processed_picture:
		shown = video_layer.show(self, origin, VideoLayer.PICTURE, Vector2(pip.compositor.main_size),
			1 if pip.compositor.main_eyes == 2 else 0, Vector2.ZERO, Vector4(0, 0, 1, 1), VideoLayer.SOURCE_ALPHA, extras, true)
	if not shown and _frame_picture: shown = _show_frame_picture(origin, extras)
	if not shown and _fisheye_picture: shown = _show_fisheye_picture(origin, extras)
	if not shown and not _layer_session and origin != null:
		shown = _show_depth_picture(origin, extras)
	var overlays_shown := false
	if not shown and not pip_layers.is_empty() and not pip.compositor.needs_main():
		overlays_shown = video_layer.show_overlays(self, pip_layers)
	pip.compositor.commit((shown or overlays_shown) and not pip_layers.is_empty())
	if not shown: _subtitle_on_layer = false
	video_layer_shown = shown
	if not shown and not overlays_shown:
		video_layer.hide(self)
	if shown:
		panel.visible = true
		if _processed_picture: _hole_material.next_pass = null # processed alpha borders already have the correct transparency
		panel.material_override = _hole_material
	elif panel.material_override == _hole_material:
		panel.material_override = material
	# A picture layer replaces the video shader too. Keep captions above its hole when
	# their own layer is unavailable, and restore the shader overlay on video-layer failure.
	_sync_subtitle_surface()

## Plan B: RVM's mask (drawn by the bridge over the frame layout into the mask slot) as layers of the
## video's own shape and eyes beneath it; their rects scale from the nominal surface to the mask's size.
func _alpha_mask_layers(origin: XROrigin3D, layer_size: Vector2, extras: Array) -> bool:
	var state := str(platform.video_layer_mask()).split(" ")
	if state.size() != 3 or int(state[0]) <= 0: return false
	var scale := Vector2(float(state[1]), float(state[2])) / layer_size
	var shape := video_layer.layer_values(self, origin, VideoLayer.SURFACE, layer_size)
	for start in range(0, shape.size(), VideoLayer.STRIDE):
		var values := shape.slice(start, start + VideoLayer.STRIDE)
		values[9] *= scale.x; values[10] *= scale.y; values[11] *= scale.x; values[12] *= scale.y
		values[17] = 1.0 # GL pictures are top-first
		values[18] = 0 # no compositor supersampling or sharpening: either widens the mask's soft edge into a halo
		values[19] = VideoLayer.PICTURE
		for i in 3: values[20 + i] = 1.0; values[23 + i] = 0.0
		values[26] = VideoLayer.MAGNIFIER_SLOT; values[27] = VideoLayer.MASK_WRITE | VideoLayer.SOURCE_ALPHA
		extras.append({"values": values, "order": VideoLayer.MASK_ORDER})
	return true

## Plan B prototype: the test mask (and backdrop) as layers of the video's own shape beneath it.
## Mask: the top half ramps alpha 0 -> 1 left to right, the bottom half is a solid disc.
func _alpha_probe_layers(origin: XROrigin3D, layer_size: Vector2, extras: Array) -> bool:
	if not _alpha_probe_uploaded:
		var mask := Image.create_empty(512, 256, false, Image.FORMAT_RGBA8)
		var backdrop := Image.create_empty(256, 256, false, Image.FORMAT_RGBA8)
		for y in 256:
			for x in 512:
				var m := float(x) / 511.0 if y < 128 else (1.0 if Vector2(x - 256, y - 192).length() < 56.0 else 0.0)
				mask.set_pixel(x, y, Color(m, m, m, m)) # premultiplied white
			for x in 256:
				backdrop.set_pixel(x, y, Color(0.9, 0.1, 0.1) if (x / 32 + y / 32) % 2 == 0 else Color(1.0, 0.85, 0.1))
		for job in [[VideoLayer.MAGNIFIER_SLOT, mask], [VideoLayer.PICTURE_SLOT, backdrop]]:
			var texture := ImageTexture.create_from_image(job[1])
			if not platform.create_layer_image(job[0], job[1].get_width(), job[1].get_height(), 1, true) \
				or platform.acquire_layer_image(job[0]) <= 0: return false
			var copied: bool = platform.copy_layer_texture(job[0], RenderingServer.texture_get_native_handle(texture.get_rid()))
			if not platform.release_layer_image(job[0], false) or not copied: return false
		_alpha_probe_uploaded = true
		video_layer.invalidate()
		DiagnosticLog.record("alpha_probe_uploaded", {"mode": alpha_probe})
	var shape := video_layer.layer_values(self, origin, VideoLayer.SURFACE, layer_size)
	if shape.size() != VideoLayer.STRIDE: return false # one flat mono layer only
	var layers := [[VideoLayer.MAGNIFIER_SLOT, Vector2(512, 256), VideoLayer.MASK_WRITE | VideoLayer.SOURCE_ALPHA, VideoLayer.MASK_ORDER]]
	if alpha_probe == 2: layers.append([VideoLayer.PICTURE_SLOT, Vector2(256, 256), VideoLayer.OPAQUE, VideoLayer.MASK_ORDER - 1])
	for layer in layers:
		var values := shape.duplicate()
		values[9] = 0; values[10] = 0; values[11] = layer[1].x; values[12] = layer[1].y
		values[17] = 1.0 # GL pictures are top-first
		values[19] = VideoLayer.PICTURE
		for i in 3: values[20 + i] = 1.0; values[23 + i] = 0.0
		values[26] = layer[0]; values[27] = layer[2]
		extras.append({"values": values, "order": layer[3]})
	return true

## Immersive (VR180/360) captions as their own quad layer: the projected caption plane is a quad in
## space, which the compositor draws from each eye exactly as the eye-buffer patch shader did. The
## canvas reaches the swapchain one frame after each redraw; the previous copy stays up meanwhile.
func _subtitle_layer_extras(origin: XROrigin3D) -> Array:
	_subtitle_on_layer = false
	if geometry == Geometry.Geometry.FLAT: return _bitmap_layer_extras(origin)
	if not (_layer_session or _frame_picture or _fisheye_picture or _processed_picture) or _subtitle_layer_failed \
		or material.get_shader_parameter("subtitle_enabled") != true or not projected_subtitles or not projected_subtitles.viewport \
		or not PlatformMethods.supports(platform, "copy_layer_texture"):
		return []
	var to_patch: Variant = material.get_shader_parameter("subtitle_world_to_patch")
	if not to_patch is Transform3D: return []
	_check_subtitle_generation()
	var canvas: SubViewport = projected_subtitles.viewport
	var version: int = projected_subtitles.version
	if version != _subtitle_layer_version:
		if _subtitle_copy_after < 0: _subtitle_copy_after = Engine.get_frames_drawn() + 1
		if Engine.get_frames_drawn() > _subtitle_copy_after:
			_subtitle_copy_after = -1
			if not _copy_subtitle_canvas(canvas):
				_subtitle_layer_failed = true
				DiagnosticLog.record("subtitle_layer_failed", {"version": version, "size": [canvas.size.x, canvas.size.y]})
				return []
			_subtitle_layer_version = version
	if _subtitle_layer_version < 0: return []
	var pose := (to_patch as Transform3D).affine_inverse()
	var extent: Variant = material.get_shader_parameter("subtitle_patch_half_extent")
	var half: float = extent if extent != null else 0.35
	var size := Vector2.ONE * half * 2.0 * pose.basis.x.length()
	_subtitle_on_layer = true
	return [{"values": video_layer.quad_values(origin, pose, size, VideoLayer.SUBTITLE_SLOT, Vector2(canvas.size)),
		"order": VideoLayer.OVERLAY_ORDER}]

func _check_subtitle_generation() -> void:
	if video_layer.generation != _subtitle_layer_generation:
		_subtitle_layer_generation = video_layer.generation # a new session dropped the swapchain
		_subtitle_layer_version = -1
		_bitmap_layer_texture = null
		_bitmap_layer_size = Vector2i.ZERO

## Flat-screen PGS: the cue's rectangle of the subtitle surface (the screen, kept upright when it
## rolls) as its own layer. The eye-buffer surface covered the whole screen for a strip of text.
func _bitmap_layer_extras(origin: XROrigin3D) -> Array:
	var texture: ImageTexture = bitmap_subtitles.texture
	var rect: Variant = material.get_shader_parameter("bitmap_subtitle_rect")
	if not (_layer_session or _frame_picture or _processed_picture or _binding.warped) or _subtitle_layer_failed or texture == null or not rect is Vector4 \
		or material.get_shader_parameter("bitmap_subtitle_enabled") != true or material.get_shader_parameter("rotation_degrees") not in [null, 0] \
		or not PlatformMethods.supports(platform, "copy_layer_texture"):
		return []
	_check_subtitle_generation()
	var size := Vector2i(texture.get_size())
	if texture != _bitmap_layer_texture:
		# Buckets of 256 x 64 pixels: most cues reuse the swapchain of the one before.
		var bucket := Vector2i(ceili(size.x / 256.0) * 256, ceili(size.y / 64.0) * 64).max(_bitmap_layer_size)
		if not _copy_bitmap_cue(bucket):
			_subtitle_layer_failed = true
			DiagnosticLog.record("subtitle_layer_failed", {"bitmap": [size.x, size.y], "bucket": [bucket.x, bucket.y]})
			return []
		_bitmap_layer_texture = texture
		_bitmap_layer_size = bucket
	# The cue's part of the surface, clipped to it as the surface clipped it.
	var cue := Rect2(rect.x, rect.y, rect.z, rect.w)
	var shown := cue.intersection(Rect2(0, 0, 1, 1))
	if not shown.has_area(): return []
	var start := ((shown.position - cue.position) / cue.size * Vector2(size)).round()
	var pixels := Rect2(start, ((shown.end - cue.position) / cue.size * Vector2(size)).round() - start)
	var pose := subtitle_transform()
	var scale := Vector2(pose.basis.x.length(), pose.basis.y.length())
	pose.basis = pose.basis.orthonormalized()
	var screen := _flat.size * scale
	var middle := (shown.get_center() - Vector2(0.5, 0.5)) * screen
	var extent := shown.size * screen
	var values: PackedFloat32Array
	var image := Vector2(_bitmap_layer_size)
	if screen_curve > 0.0:
		var radius := _curve_radius() * scale.x
		# The mesh bends towards the viewer from the panel origin; the cylinder centre sits on that axis.
		pose.origin += pose.basis * Vector3(0, -middle.y, radius)
		pose.basis = pose.basis * Basis(Vector3.UP, -middle.x / radius)
		values = video_layer.cylinder_values(origin, pose, radius, extent.x / radius, extent.x / extent.y,
			VideoLayer.SUBTITLE_SLOT, image, pixels)
	else:
		pose.origin += pose.basis * Vector3(middle.x, -middle.y, 0)
		values = video_layer.quad_values(origin, pose, extent, VideoLayer.SUBTITLE_SLOT, image, pixels)
	_subtitle_on_layer = true
	return [{"values": values, "order": VideoLayer.OVERLAY_ORDER}]

## The cue's premultiplied pixels at the top left of a transparent bucket-sized image, copied once.
func _copy_bitmap_cue(bucket: Vector2i) -> bool:
	_subtitle_layer_version = -1 # the immersive canvas no longer is in the swapchain
	var cue: Image = bitmap_subtitles.image
	if cue == null or cue.is_empty(): return false
	if cue.get_format() != Image.FORMAT_RGBA8: cue.convert(Image.FORMAT_RGBA8)
	var padded := Image.create_empty(bucket.x, bucket.y, false, Image.FORMAT_RGBA8)
	padded.blit_rect(cue, Rect2i(Vector2i.ZERO, cue.get_size()), Vector2i.ZERO)
	if _subtitle_texture and Vector2i(_subtitle_texture.get_size()) == bucket: _subtitle_texture.update(padded)
	else: _subtitle_texture = ImageTexture.create_from_image(padded)
	if not platform.create_layer_image(VideoLayer.SUBTITLE_SLOT, bucket.x, bucket.y, 1, false): return false
	if platform.acquire_layer_image(VideoLayer.SUBTITLE_SLOT) <= 0: return false
	var copied: bool = platform.copy_layer_texture(VideoLayer.SUBTITLE_SLOT, RenderingServer.texture_get_native_handle(_subtitle_texture.get_rid()))
	return platform.release_layer_image(VideoLayer.SUBTITLE_SLOT, false) and copied

func _copy_subtitle_canvas(canvas: SubViewport) -> bool:
	_bitmap_layer_texture = null; _bitmap_layer_size = Vector2i.ZERO # the PGS cue no longer is in the swapchain
	var size := Vector2i(canvas.size)
	if not platform.create_layer_image(VideoLayer.SUBTITLE_SLOT, size.x, size.y, 1, false): return false
	# A viewport texture has no GL texture of its own in this renderer: read the canvas back once per
	# cue into a plain texture (700 px square, on caption changes only) and copy that.
	var image := canvas.get_texture().get_image()
	if image == null or image.is_empty(): return false
	if image.get_format() != Image.FORMAT_RGBA8: image.convert(Image.FORMAT_RGBA8)
	if _subtitle_texture and Vector2i(_subtitle_texture.get_size()) == image.get_size(): _subtitle_texture.update(image)
	else: _subtitle_texture = ImageTexture.create_from_image(image)
	if platform.acquire_layer_image(VideoLayer.SUBTITLE_SLOT) <= 0: return false
	var copied: bool = platform.copy_layer_texture(VideoLayer.SUBTITLE_SLOT, RenderingServer.texture_get_native_handle(_subtitle_texture.get_rid()))
	return platform.release_layer_image(VideoLayer.SUBTITLE_SLOT, false) and copied

## 2D->3D: the bridge's stereo pair of each frame, copied into the picture layer once per pair.
## Until the model's first map (shader parallax) the frame stays in the eye buffers.
func _show_depth_picture(origin: XROrigin3D, extras: Array = []) -> bool:
	var ticket := _binding.ticket
	if not _binding.warped or geometry != Geometry.Geometry.FLAT or not video_layer.available() \
		or not video_layer.supports(geometry, screen_curve > 0.0) or not video_layer.grades(color_grade) \
		or not PlatformMethods.supports(platform, "copy_layer_texture"):
		return false
	var size := Vector2i(int(ticket.width) * 2, int(ticket.height))
	var token := int(ticket.get("slot_token", 0))
	if token != _picture_token or _picture_refresh > 0:
		_picture_refresh = maxi(0, _picture_refresh - 1)
		var warp := int(ticket.get("warp_texture_id", 0))
		var created: bool = warp > 0 and platform.create_layer_image(VideoLayer.PICTURE_SLOT, size.x, size.y, 1, false)
		if created and Vector2i(video_layer.picture_size) != size:
			video_layer.invalidate() # a new swapchain for this size
			video_layer.picture_size = Vector2(size)
		if not created or platform.acquire_layer_image(VideoLayer.PICTURE_SLOT) <= 0:
			return false
		var copied: bool = platform.copy_layer_texture(VideoLayer.PICTURE_SLOT, warp)
		if not platform.release_layer_image(VideoLayer.PICTURE_SLOT, false) or not copied:
			return false
		_picture_token = token
	return video_layer.show(self, origin, VideoLayer.PICTURE, Vector2(size), 1, Vector2.ZERO, Vector4(0, 0, 1, 1),
		VideoLayer.OPAQUE, extras)

## Profile 5 and software decode cannot use the decoder surface; MPV normalizes their colour and
## orientation into RGBA frames. Each new frame is copied into the picture layer once, instead of the
## frame being sampled into both eye buffers every display frame. Same presentation rules as the surface.
func _frame_picture_wanted() -> bool:
	var ticket := _binding.ticket
	return not _frame_picture_failed and not ticket.is_empty() and not _binding.layer and not _binding.warped \
		and int(ticket.get("session_id", 0)) == media.session_id and media.state != "failed" \
		and str(ticket.get("color_target", "")) != "external" and int(ticket.get("color_texture_id", 0)) > 0 \
		and not local_uri.is_empty() and local_uri == _layer_blocked_uri \
		and layer_enabled and video_layer.available() and not alpha_requested and not depth_requested and not packed_file \
		and video_layer.grades(color_grade) and video_layer.supports(geometry, screen_curve > 0.0) \
		and PlatformMethods.supports(platform, "copy_layer_texture")

func _show_frame_picture(origin: XROrigin3D, extras: Array) -> bool:
	var ticket := _binding.ticket
	var size := Vector2i(int(ticket.width), int(ticket.height))
	var token := int(ticket.get("slot_token", 0))
	if token != _picture_token:
		# A runtime may refuse a large swapchain (XR2 Gen 1 headsets): this file stays in the eye buffers.
		if not platform.create_layer_image(VideoLayer.PICTURE_SLOT, size.x, size.y, 1, false):
			_frame_picture_failed = true
			DiagnosticLog.record("frame_picture_failed", {"stage": "create", "size": [size.x, size.y]})
			return false
		if Vector2i(video_layer.picture_size) != size:
			video_layer.invalidate() # a new swapchain for this size
			video_layer.picture_size = Vector2(size)
		if platform.acquire_layer_image(VideoLayer.PICTURE_SLOT) <= 0:
			return false
		var copied: bool = platform.copy_layer_texture(VideoLayer.PICTURE_SLOT, int(ticket.color_texture_id))
		if not platform.release_layer_image(VideoLayer.PICTURE_SLOT, false) or not copied:
			_frame_picture_failed = true
			DiagnosticLog.record("frame_picture_failed", {"stage": "copy", "size": [size.x, size.y]})
			return false
		_picture_token = token
	return video_layer.show(self, origin, VideoLayer.PICTURE, Vector2(size), -1, Vector2.ZERO, Vector4(0, 0, 1, 1),
		VideoLayer.OPAQUE, extras)

## Same file and position, decoded for Godot's shader (Alpha, 2D->3D, fisheye, grading, Profile 5).
func _reopen_on_eye_buffer(position_ms: int) -> void:
	if local_uri != _layer_blocked_uri:
		_layer_return_uri = local_uri
	_reopen_at(position_ms, false)

## Reopen the shown file at its position (layer: may decode into the compositor layer).
func _reopen_at(position_ms: int, layer: bool) -> void:
	if local_uri.is_empty():
		return
	var position := position_ms if position_ms >= 0 else maxi(0, int(int(media.last_pair.get("pts_us", control.observed_position_ms * 1000)) / 1000))
	if position_ms < 0 and media.last_pair.is_empty(): position = maxi(position, int(media.playback.get("source_start_ms", 0)))
	var remember := _remember_file
	var mode_user_changed := _mode_user_changed
	var mode_memory_cleared := _mode_memory_cleared
	var persisted := _file_permission_persisted
	var eye := viewing_eye
	var alignment := Vector2(stereo_horizontal, stereo_vertical)
	var spatial := [_spatial_video, spatial_metadata(), spatial_auto_disparity]
	var view := [_view_basis, view_yaw, view_pitch, view_zoom]
	var rotation := screen_rotation
	var speed := playback_speed
	var tracks := _capture_track_choices()
	var narration_state := narration.capture_reopen()
	var timing := [_subtitle_timing_key, subtitle_delay]
	var whisper := audio_whisper
	var boost_mark := audio_boost_saved
	var whisper_save := _whisper_remember or _whisper_restore_remember
	Log.record("video_layer_reopen", {"layer": layer, "position_ms": position, "alpha": alpha_requested,
		"depth": depth_requested, "geometry": geometry, "compatible": media.playback.get("layer_compatible", true)})
	_eye_buffer_only = not layer
	var return_uri := _layer_return_uri
	var auto_subtitle := _subtitle_auto_pending # An internal reopen keeps an unfinished automatic choice.
	_network_interleave_next = _network_interleave_compat
	if _network_interleave_compat and PlatformMethods.supports(platform, "set_mpv_interleave_compat"):
		platform.set_mpv_interleave_compat(true)
	pip.reopening = true
	var capture_reopened := open_local(local_uri, display_name, position, false, alpha_wanted())
	pip.reopening = false
	if not capture_reopened: pip.clear()
	if not capture_reopened: captures.stop()
	if capture_reopened:
		narration.restore_reopen(narration_state)
		audio_whisper = whisper; audio_boost_saved = boost_mark; _whisper_restore_pending = whisper > 0 or whisper_save; _whisper_restore_remember = whisper_save
		_subtitle_auto_pending = auto_subtitle
		_queue_track_restore(tracks)
		_subtitle_timing_key = timing[0]; subtitle_delay = timing[1]; subtitles.set_delay(subtitle_delay); _subtitle_delay_pending = true
		_remember_file = remember
		_mode_user_changed = mode_user_changed
		_mode_memory_cleared = mode_memory_cleared
		_file_permission_persisted = persisted
		viewing_eye = eye
		stereo_horizontal = alignment.x
		stereo_vertical = alignment.y
		_spatial_video = spatial[0]
		_spatial_metadata = spatial[1]
		spatial_auto_disparity = spatial[2]
		if is_spatial_video(): _complete_layout()
		_view_basis = view[0]
		view_yaw = view[1]
		view_pitch = view[2]
		view_zoom = view[3]
		screen_rotation = rotation
		set_playback_speed(speed)
		_apply_stereo_view()
		_apply_geometry()
	_layer_return_uri = return_uri

func _exit_tree() -> void:
	close_video()
	if is_instance_valid(caption) and caption.get_parent() != self:
		caption.queue_free()
