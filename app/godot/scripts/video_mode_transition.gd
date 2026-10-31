extends RefCounted
## A display copy owns its textures independently of the decoder being replaced.
## Only 2D/3D revisions use this bridge; ordinary seek keeps its existing freeze path.
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const CAPTURE_TIMEOUT_MS := 3000
const PREPARE_TIMEOUT_MS := 60000
const MAX_EDGE := 2048

var video: Node3D
var stage := ""
var source_session := 0
var source_uri := ""
var source_layer := false
var source_mode := {}
var position_ms := 0
var request := 0
var copy_request := 0
var copy_size := Vector2i.ZERO
var deadline := 0
var armed_draw := 0
var ready_session := 0
var reopening := false
var rolling_back := false
var pending_reopen := {}
var overlay: MeshInstance3D
var hold_material: ShaderMaterial
var hold_binding := Binding.new()
var image: ImageTexture
var events: Array[Dictionary] = []

func _init(owner: Node3D) -> void:
	video = owner

func active() -> bool:
	return not stage.is_empty()

func snapshot() -> Dictionary:
	return {"stage": stage, "source_session": source_session, "ready_session": ready_session,
		"visible": is_instance_valid(overlay) and overlay.visible, "copy_size": [copy_size.x, copy_size.y],
		"rolling_back": rolling_back, "events": events.duplicate(true)}

func _event(value: String) -> void:
	events.append({"event": value, "time_ms": Time.get_ticks_msec(), "session_id": video.media.session_id})
	if events.size() > 32: events.pop_front()

func capturing() -> bool:
	return stage in ["capturing", "armed"]

func relevant() -> bool:
	return video.depth_requested or video.depth_enabled or bool(video._binding.ticket.get("depth_requested", false))

func guard_revision() -> bool:
	if capturing(): return true
	if stage == "preparing" and video._waiting_first: return true
	if active() or not relevant(): return false
	return _begin()

func guard_reopen(at: int, layer: bool) -> bool:
	if capturing():
		pending_reopen = {"position": at, "layer": layer}
		return true
	if active() or not relevant(): return false
	if not _begin(): return false
	if active(): pending_reopen = {"position": at, "layer": layer}
	return true

func _begin() -> bool:
	var pair: Dictionary = video._binding.ticket
	# Nothing has been displayed yet, or this is a different/XR-lost source.
	if pair.is_empty() or video.media.frame_counter <= 0 or not video.panel or not video.panel.visible \
			or video.local_uri.is_empty() or video.geometry != Geometry.Geometry.FLAT or not video.is_inside_tree(): return false
	if video._layer_session and video.video_layer and video.video_layer.generation != video._layer_generation: return false
	var method := "request_mpv_layer_snapshot" if video._binding.layer else "freeze_mpv_pair"
	source_uri = video.local_uri
	source_session = video.media.session_id
	source_layer = video._binding.layer
	source_mode = {"depth": bool(pair.get("depth_requested", false)), "alpha": bool(pair.get("alpha_requested", false)),
		"stereo": bool(pair.get("stereo_sbs", false)) and not video._binding.warped,
		"top_bottom": bool(pair.get("top_bottom", false)) and not video._binding.warped}
	position_ms = maxi(0, int(int(pair.get("pts_us", video.control.observed_position_ms * 1000)) / 1000))
	if not Methods.supports(video.platform, method):
		_capture_failed("Video frame preservation is unavailable")
		return true
	hold_material = video.material.duplicate()
	hold_material.next_pass = null
	overlay = MeshInstance3D.new()
	overlay.name = "VideoModeHold"
	overlay.mesh = video.panel.mesh.duplicate() if video.panel.mesh else null
	overlay.transform = video.panel.transform
	overlay.layers = video.panel.layers
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.material_override = hold_material
	overlay.visible = false
	video.add_child(overlay)
	stage = "capturing"
	events.clear()
	_event("capture_requested")
	deadline = Time.get_ticks_msec() + CAPTURE_TIMEOUT_MS
	video.platform.set_mpv_playing(source_session, false)
	if source_layer:
		var rotation := int(pair.get("surface_rotation_degrees", 0))
		var width := int(pair.width)
		var height := int(pair.height)
		# Capture the complete coded buffer, with both eyes and no thumbnail crop.
		var coded := Vector2i(height, width) if rotation % 180 != 0 else Vector2i(width, height)
		copy_size = snapshot_size(coded)
		copy_request = video.platform.request_mpv_layer_snapshot(source_session, copy_size.x, copy_size.y)
		Binding._use_shader(hold_material, Binding.PAIR_SHADER)
		hold_material.set_shader_parameter("rotation_degrees", rotation)
		hold_material.set_shader_parameter("alpha_enabled", false)
		hold_material.set_shader_parameter("depth_enabled", false)
		if copy_request <= 0: _capture_failed("Video frame copy was rejected")
	else:
		if int(pair.get("frozen_frame_id", 0)) > 0 and Methods.supports(video.platform, "retain_mpv_frozen_frame"):
			if video.platform.retain_mpv_frozen_frame(int(pair.frozen_frame_id)):
				if hold_binding.bind(hold_material, pair): _arm()
				else:
					_release_pair(pair)
					_capture_failed("Preserved video frame could not be bound")
				return true
		video._freeze_sequence += 1
		request = video._freeze_sequence
		if not video.platform.freeze_mpv_pair(source_session, int(pair.slot_token), request):
			_capture_failed("Video frame capture was rejected")
	return true

static func snapshot_size(coded: Vector2i) -> Vector2i:
	var scale := minf(1.0, float(MAX_EDGE) / maxf(1.0, maxi(coded.x, coded.y)))
	return Vector2i(maxi(1, roundi(coded.x * scale)), maxi(1, roundi(coded.y * scale)))

func frozen(id: int, report: Dictionary) -> bool:
	if request <= 0 or int(report.get("request_id", 0)) != request: return false
	request = 0
	var pair: Dictionary = report.get("pair", {})
	if stage != "capturing" or id != source_session or video.local_uri != source_uri:
		_release_pair(pair)
		return true
	if report.get("state") != "ready" or int(pair.get("frozen_frame_id", 0)) <= 0:
		_release_pair(pair)
		_capture_failed(str(report.get("error", "Video frame capture failed")))
		return true
	if not hold_binding.bind(hold_material, pair):
		_release_pair(pair)
		_capture_failed("Preserved video frame could not be bound")
		return true
	_arm()
	return true

func _arm() -> void:
	overlay.visible = true
	armed_draw = Engine.get_frames_drawn()
	stage = "armed"
	_event("hold_bound")

func poll() -> void:
	if not active(): return
	if source_uri != video.local_uri:
		cancel()
		return
	if stage == "capturing" and copy_request > 0:
		var state: String = video.platform.get_mpv_layer_thumbnail_state(copy_request)
		if state == "ready":
			var pixels: PackedByteArray = video.platform.take_mpv_layer_thumbnail(copy_request)
			copy_request = 0
			if pixels.size() != copy_size.x * copy_size.y * 4:
				_capture_failed("Preserved video frame has an invalid size")
				return
			image = ImageTexture.create_from_image(Image.create_from_data(copy_size.x, copy_size.y, false, Image.FORMAT_RGBA8, pixels))
			hold_material.set_shader_parameter("color_texture", image)
			hold_material.set_shader_parameter("source_size", Vector2(copy_size))
			_arm()
		elif state != "pending":
			_capture_failed("Video frame copy failed: " + state)
			return
	if stage == "armed" and Engine.get_frames_drawn() > armed_draw:
		stage = "held"
		_event("hold_drawn")
		if not pending_reopen.is_empty():
			var next := pending_reopen
			pending_reopen = {}
			video._reopen_at(int(next.position), bool(next.layer))
		return
	if stage == "capturing" and Time.get_ticks_msec() >= deadline:
		_capture_failed("Video frame capture timed out")
	elif stage == "preparing" and Time.get_ticks_msec() >= deadline:
		video._on_error(video.media.session_id, JSON.stringify({"code": "MPV_OUTPUT_TIMEOUT", "stage": "output"}))

func preparing() -> void:
	if not active(): return
	stage = "preparing"
	ready_session = 0
	deadline = Time.get_ticks_msec() + PREPARE_TIMEOUT_MS
	_event("preparing")

func target_ready(id: int) -> void:
	if stage == "preparing":
		ready_session = id
		_event("first_frame_acknowledged")

func finish_frame() -> void:
	if stage != "preparing" or ready_session != video.media.session_id or video._waiting_first \
			or not video._pending_revision.is_empty() or video._binding.ticket.is_empty() or not video.panel.visible: return
	# A Surface identity is not enough: the layer and its matching hole must both exist.
	if video._binding.layer and not video.video_layer_shown: return
	var id: int = video.media.session_id
	_event("committed")
	cancel()
	video.platform.set_mpv_playing(id, video.requested_play)

func recover() -> bool:
	if stage == "held" and rolling_back: return true
	if stage != "preparing" or rolling_back or video.local_uri != source_uri: return false
	rolling_back = true
	_event("rollback")
	_restore_mode()
	video._pending_revision = {}
	video._pending_pair = {}
	video._waiting_first = false
	stage = "held"
	call_deferred("_rollback")
	return true

func _rollback() -> void:
	if stage != "held" or video.local_uri != source_uri: return
	video._reopen_at(position_ms, source_layer)

func _restore_mode() -> void:
	video.depth_requested = bool(source_mode.get("depth", false))
	video.auto_depth = video.depth_requested
	video.alpha_requested = bool(source_mode.get("alpha", false))
	video.stereo_sbs = bool(source_mode.get("stereo", false))
	video.top_bottom = bool(source_mode.get("top_bottom", false))
	video._remember_mode()

func _capture_failed(reason: String) -> void:
	_event("capture_failed")
	_restore_mode()
	video._pending_revision = {}
	video._waiting_first = false
	video._output_deadline_ms = 0
	video.picker_error = reason
	var id := source_session
	cancel()
	video.platform.set_mpv_playing(id, video.requested_play)
	video.changed.emit()

func _release_pair(pair: Dictionary) -> void:
	if int(pair.get("frozen_frame_id", 0)) > 0:
		video.platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))

func cancel() -> void:
	if copy_request > 0 and Methods.supports(video.platform, "cancel_mpv_layer_snapshot"):
		video.platform.cancel_mpv_layer_snapshot(copy_request)
	copy_request = 0
	request = 0 # late frozen results are released by the normal stale-result handler
	stage = ""
	pending_reopen = {}
	ready_session = 0
	rolling_back = false
	var old_binding := hold_binding
	var old_overlay := overlay
	var held_resources := [hold_material, image]
	var host: Object = video.platform
	hold_binding = Binding.new()
	overlay = null
	hold_material = null
	image = null
	if not old_overlay: return
	old_overlay.visible = false
	old_overlay.queue_free()
	var release := func() -> void:
		var pair := old_binding.unbind()
		if is_instance_valid(host) and int(pair.get("frozen_frame_id", 0)) > 0:
			host.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		# Resource references survive owner/mesh teardown until the last submitted draw finishes.
		held_resources.clear()
	if video.is_inside_tree() and Engine.get_frames_drawn() > 0:
		RenderingServer.frame_post_draw.connect(release, CONNECT_ONE_SHOT)
	else: release.call()
