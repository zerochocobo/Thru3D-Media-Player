extends Node3D
## Independent source; reuses PiP ray movement/resizing, without joining the movie's decoder or lifetime.
const Windows := preload("res://scripts/video_pip.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Layer := preload("res://scripts/web_browser_layer.gd")
var geometry := 0
var stereo_sbs := false
var top_bottom := false
var stereo_half := false
var _flat := QuadMesh.new()
var _binding := Binding.new()
var panel := MeshInstance3D.new()
var pip := Windows.new(self)
var host: Node
var platform: Object
var status := {}
var pairing_code := ""
var epoch := 0
var dismissed_epoch := 0
var texture: ExternalTexture
var retained := {}
var _last_pin := ""
var _state_key := ""
var layer: RefCounted
var pending_layer: RefCounted
var ending := false
var _presenting := true
var _display_attached := false
var _display_stopping := false
var _attached_at := 0
var _display_diagnostic_key := ""
var _display_diagnostic_at := 0
var player_mode := false
var _player_opening := false
var _player_deadline := 0

func player_uri() -> String:
	return "airplayvideo://" + str(epoch)

func layer_reservation() -> int:
	return 1 if layer else 0

func bind(owner_node: Node, bridge: Object) -> void:
	host = owner_node; platform = bridge
	Layer.initialize()
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr and xr.is_initialized():
		_presenting = false
		xr.session_stopping.connect(_suspend_display)
		xr.session_synchronized.connect(_suspend_display)
		xr.session_loss_pending.connect(_suspend_display)
		xr.instance_exiting.connect(_suspend_display)
		xr.session_visible.connect(_resume_display)
		xr.session_focussed.connect(_resume_display)
	_flat.size = Vector2(16.0 / 9.0, 1.0)
	add_child(panel); panel.visible = false
	pip.window_opened.connect(func(window):
		if host.menu_composition: host.menu_composition.register_companion(window)
		window.requested.connect(_live_action))
	pip.changed.connect(func():
		if epoch > 0 and pip.windows.is_empty(): disconnect_sender())

func supported() -> bool:
	return Methods.supports(platform, "airplay_receiver_poll")

func tick() -> void:
	if not supported(): return
	var data: Variant = JSON.parse_string(platform.airplay_receiver_poll())
	if not data is Dictionary: return
	status = data
	for released in data.get("released", []): retained.erase(int(released))
	if ending and not _clear(): return
	if _display_stopping and not _park_display(): return
	var active := int(data.get("active", 0))
	if player_mode:
		# A local/DLNA selection may replace the player before the next mirror poll.
		# Never let a late sender failure close that newer ordinary source.
		if host.video.local_uri != player_uri():
			return_to_pip()
			return
		if active != epoch or not data.get("foreground", true) or not data.get("player_active", false):
			host._close_current_media()
			return
		if host.video.media.state == "failed" or host.video.media.state == "ended" or not host.video.requested_play or (_player_opening and Time.get_ticks_msec() >= _player_deadline):
			host._close_current_media()
		elif host.video.media.frame_counter > 0: _player_opening = false
		return
	if epoch > 0 and active != epoch and not _clear(): return
	if _display_attached and (not data.get("foreground", true) or (data.get("suspended", false) and Time.get_ticks_msec() - _attached_at > 500)):
		_display_stopping = true
		if not _park_display(): return
	if not _presenting or not data.get("foreground", true): return
	if active > 0 and active != dismissed_epoch and (epoch == 0 or not _display_attached) and retained.size() < 2 and data.get("video_ready", false):
		epoch = active
		if not _attach_display(data): return
		if not pip.windows.has(1):
			pip._open(1, host._head_pose())
			_place_new_window(pip.windows[1])
		var window: Node3D = pip.windows[1]
		window.image_mode = true; window.live_source = true; window.panorama = false
		window.image_material.shader = load("res://shaders/airplay_mirror.gdshader")
		window.image_material.set_shader_parameter("video_texture", texture)
		window.source_muted = bool(data.get("muted", false))
		window.set_compositor(layer != null); window.frame.visible = false; window.refresh()
	if epoch > 0 and pip.windows.has(1):
		var window: Node3D = pip.windows[1]
		_present_window(window, data)
		if window.source_muted != bool(data.get("muted", false)):
			window.source_muted = bool(data.get("muted", false)); window.refresh()
		var values: Array = data.get("transform", [])
		if values.size() == 16:
			window.image_material.set_shader_parameter("surface_transform", Projection(Vector4(values[0], values[1], values[2], values[3]), Vector4(values[4], values[5], values[6], values[7]), Vector4(values[8], values[9], values[10], values[11]), Vector4(values[12], values[13], values[14], values[15])))
	var pin: String = str(data.get("pin", ""))
	var can_prompt: bool = not host.cast_session._typing() and not host.recent_menu.has_pointer_capture() \
		and not (host.player_menu and host.player_menu.has_pointer_capture()) \
		and not host.recent_menu.voice_manager.opened and not (host.puzzle_game and host.puzzle_game.active)
	if not pin.is_empty() and pin != _last_pin and can_prompt:
		_last_pin = pin; pairing_code = pin; host._show_full_library()
	if pin.is_empty(): _last_pin = ""; pairing_code = ""
	var key := str([data.get("state", ""), pairing_code, data.get("receiver_error", ""), data.get("error", ""), data.get("audio_error", "")])
	if key != _state_key:
		_state_key = key; host.cast_session.refresh()

func _present_window(window: Node3D, data: Dictionary) -> void:
	var target := _target_size(data)
	var output := Vector2i(int(data.get("width", 0)), int(data.get("height", 0)))
	fit_source(window, target.x, target.y)
	var reason := "visible"
	if layer:
		var synced := _sync_layer(data)
		if not str(data.get("error", "")).is_empty(): reason = "decoder_error"
		elif not synced: reason = "producer_pending"
		elif output != target: reason = "size_mismatch"
		# Rendered notifications are diagnostic timing samples. Waiting for one before
		# submitting the XR layer can leave the Surface consumer and this window waiting.
		elif int(data.get("submitted_frames", 0)) <= 0: reason = "waiting_decoder_output"
		else:
			layer.sort_order = _layer_order(window)
			if not layer.resize_decoder_producer(output): reason = "producer_resize_failed"
			elif not layer.present(window.global_transform, window.size, Rect2(0, 0, 1, 1)): reason = "layer_present_failed"
		if reason != "visible": layer.hide()
	else:
		if not str(data.get("error", "")).is_empty(): reason = "decoder_error"
		elif int(data.get("frames", 0)) <= 0: reason = "waiting_texture_frame"
	window.frame.visible = reason == "visible"
	_diagnose_display(data, reason)

func _diagnose_display(data: Dictionary, reason: String) -> void:
	var slot := int(data.get("layer_slot", 0))
	var expected := int(layer.id) if layer else 0
	var pending := int(pending_layer.id) if pending_layer else 0
	var output := Vector2i(int(data.get("width", 0)), int(data.get("height", 0)))
	var key := str([epoch, reason, _target_size(data), output, slot, expected, pending])
	var now := Time.get_ticks_msec()
	if key == _display_diagnostic_key and now < _display_diagnostic_at: return
	_display_diagnostic_key = key; _display_diagnostic_at = now + 5000
	# Numeric stream state and fixed reason codes only; no sender identity or payload.
	print("AirPlay display epoch=%d reason=%s target=%s output=%s slot=%d expected_slot=%d pending_slot=%d submitted_frames=%d frames=%d" % [
		epoch, reason, _target_size(data), output, slot, expected, pending,
		int(data.get("submitted_frames", 0)), int(data.get("frames", 0))])

func _attach_layer(data: Dictionary) -> bool:
	if not Methods.supports(platform, "airplay_receiver_attach_layer") or not Methods.supports(platform, "airplay_receiver_detach_layer"): return false
	var candidate := _make_layer(6, _target_size(data))
	if not candidate: return false
	if not _bind_layer(candidate): candidate.destroy(); return false
	layer = candidate
	return true

static func _target_size(data: Dictionary) -> Vector2i:
	return Vector2i(int(data.get("target_width", data.get("width", 1920))), int(data.get("target_height", data.get("height", 1080))))

func _make_layer(slot: int, size: Vector2i) -> RefCounted:
	var candidate := Layer.new()
	if not candidate.create(slot, size): return null
	return candidate

func _bind_layer(candidate: RefCounted) -> bool:
	return platform.airplay_receiver_attach_layer(epoch, candidate.id, candidate.source_pixels.x, candidate.source_pixels.y)

func _sync_layer(data: Dictionary) -> bool:
	# Recreate only AirPlay's producer on rotation: some runtimes keep the original
	# Surface geometry even when MediaCodec announces a different output crop.
	if pending_layer and int(data.get("layer_slot", 0)) == pending_layer.id:
		layer.hide(); layer.destroy(); layer = pending_layer; pending_layer = null
	var target := _target_size(data)
	if not pending_layer and target != layer.source_pixels and data.get("video_ready", false):
		var candidate := _make_layer(7 if layer.id == 6 else 6, target)
		if candidate:
			if _bind_layer(candidate): pending_layer = candidate
			else: candidate.destroy()
	var ready: bool = not pending_layer and target == layer.source_pixels and int(data.get("layer_slot", 0)) == layer.id
	if not ready: layer.hide()
	return ready

func _place_new_window(window: Node3D) -> void:
	var head: Transform3D = host._head_pose()
	var distance := 0.85
	var menu: Node3D = host._active_menu()
	if menu: distance = minf(distance, maxf(0.42, head.origin.distance_to(menu.to_global(menu.panel_centre())) * 0.72))
	var point := Windows.level_head(head) * (Vector3(0.32, 0.15, -1).normalized() * distance)
	window.global_transform = Transform3D(Windows.Move.face_viewer(point, head), point)

func _layer_order(window: Node3D) -> int:
	var menu: Node3D = host._active_menu()
	var eye: Vector3 = host._head_pose().origin
	# Menu quads are -6..-3. Match their physical depth when these surfaces overlap.
	return -2 if menu and eye.distance_squared_to(window.global_position) < eye.distance_squared_to(menu.to_global(menu.panel_centre())) else -23

func _attach_display(data: Dictionary) -> bool:
	if not retained.is_empty(): return false # Old GL consumers must release before either output path can reopen.
	if not _attach_layer(data):
		texture = ExternalTexture.new(); texture.size = Vector2i(int(data.get("width", 1920)), int(data.get("height", 1080)))
		retained[epoch] = texture
		if not platform.airplay_receiver_attach(epoch, texture.get_external_texture_id()):
			retained.erase(epoch); texture = null; return false
	_display_attached = true
	_attached_at = Time.get_ticks_msec()
	return true

static func fit_source(window: Node3D, width: int, height: int) -> void:
	if width < 16 or height < 16 or width > 1920 or height > 1920: return
	var ratio := float(width) / maxf(1.0, float(height))
	if not is_equal_approx(window.source_aspect, ratio):
		window.source_aspect = ratio
		var extent: float = maxf(window.size.x, window.size.y)
		window.set_size(Vector2(extent, extent / ratio) if ratio >= 1 else Vector2(extent * ratio, extent))

func _clear() -> bool:
	ending = true
	if layer or pending_layer:
		if layer: layer.hide()
		if pending_layer: pending_layer.hide()
		# Producer stop acknowledgement precedes swapchain destruction (same as browser surfaces).
		if not platform.airplay_receiver_detach_layer(epoch): return false
		_destroy_layers()
	epoch = 0; texture = null
	_display_attached = false; _display_stopping = false
	for window in pip.windows.values(): window.image_material.set_shader_parameter("video_texture", null)
	pip.clear()
	ending = false
	return true

func _live_action(_slot: int, operation: String, value: float) -> void:
	if operation == "mute" and supported(): platform.airplay_receiver_muted(value > 0.5)
	if operation == "player": _open_player.call_deferred()

func _open_player() -> void:
	if player_mode or epoch <= 0 or not Methods.supports(platform, "airplay_receiver_open_player"): return
	if host.cast_session.busy_editor(): return
	# Stop the PiP producer before the ordinary player claims the same sender's stream.
	if not _park_display(): return
	if not platform.airplay_receiver_open_player(epoch): return
	player_mode = true; _player_opening = true; _player_deadline = Time.get_ticks_msec() + 15000
	pip.cancel_interaction()
	for window in pip.windows.values(): window.visible = false
	host.cast_session.open_mirror(player_uri(), epoch)

func return_to_pip() -> void:
	if not player_mode: return
	player_mode = false; _player_opening = false
	if Methods.supports(platform, "airplay_receiver_captions"): platform.airplay_receiver_captions(epoch, "")
	platform.airplay_receiver_suspend(epoch)
	for window in pip.windows.values(): window.visible = true

func disconnect_sender() -> void:
	var old := epoch; dismissed_epoch = old; pairing_code = ""
	if old > 0 and supported(): platform.airplay_receiver_disconnect(old)
	_clear()

func _suspend_display() -> void:
	_presenting = false
	if epoch <= 0: return
	_display_stopping = true
	_park_display()

func _park_display() -> bool:
	if layer: layer.hide()
	if pending_layer: pending_layer.hide()
	if Methods.supports(platform, "airplay_receiver_suspend") and not platform.airplay_receiver_suspend(epoch): return false
	_destroy_layers()
	texture = null; _display_attached = false; _display_stopping = false
	for window in pip.windows.values():
		window.image_material.set_shader_parameter("video_texture", null); window.set_compositor(false); window.frame.visible = false
	return true

func _destroy_layers() -> void:
	if pending_layer: pending_layer.destroy(); pending_layer = null
	if layer: layer.destroy(); layer = null

func _resume_display() -> void:
	_presenting = true

func close() -> void:
	return_to_pip()
	if epoch > 0 and supported(): platform.airplay_receiver_disconnect(epoch)
	_clear()

func input_enabled() -> bool:
	return not player_mode and host._input_focused() and host._grab.is_empty() and host.interface_move.capture.is_empty()

func adjust_distance(left: Vector2, right: Vector2, delta: float) -> bool:
	var capture: Dictionary = pip.movement.capture
	if capture.is_empty() or not input_enabled(): return false
	var hand: String = capture.hand
	return pip.adjust_distance(hand, left if hand == "left_hand" else right, delta, host._pip_move_pose(hand), host._head_pose())

func press(hand: String, action: String) -> bool:
	if not pip.active() or not input_enabled(): return false
	var menu: Node3D = host._active_menu()
	if menu and menu.has_pointer_capture(): return false
	var ray: Variant = host._ray(hand)
	if _menu_blocks(menu, ray): return false
	return pip.press(hand, action, ray, host._pip_move_pose(hand), host._head_pose(), host._pip_hand_pointer(hand))

func update_input() -> void:
	if not pip.active(): return
	var rays := {}; var poses := {}
	var enabled := input_enabled()
	var menu: Node3D = host._active_menu()
	if not enabled or (menu and menu.has_pointer_capture()): pip.cancel_interaction(); return
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = host._ray(hand)
		if not pip.capturing() and _menu_blocks(menu, ray): ray = null
		rays[hand] = ray; poses[hand] = host._pip_move_pose(hand)
	pip.update_input(rays, poses, host._head_pose(), Time.get_ticks_msec())

func _menu_blocks(menu: Node3D, ray: Variant) -> bool:
	if not menu or ray == null: return false
	var menu_hit: Dictionary = menu.ray_hit(ray[0], ray[1])
	if menu_hit.is_empty(): return false
	var mirror_hit := pip.hit(ray[0], ray[1])
	return mirror_hit.is_empty() or float(menu_hit.distance) <= float(mirror_hit.distance)
