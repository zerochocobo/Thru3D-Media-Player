extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Transition := preload("res://scripts/video_mode_transition.gd")
var checks := 0
var failures: Array[String] = []
var gl := false

class ProbeBinding extends "res://scripts/pair_texture_binding.gd":
	func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
		material = target
		ticket = pair.duplicate(true)
		layer = pair.get("color_target", "") == "layer"
		warped = int(pair.get("warp_texture_id", 0)) > 0
		return true

class Host extends RefCounted:
	var snapshots: Array = []
	var freezes: Array = []
	var cancelled: Array = []
	var released: Array = []
	var closed: Array = []
	var revisions: Array = []
	var plays: Array = []
	var status := "pending"
	var reject_capture := false
	var reject_ack := false
	var claim := {}
	var size := Vector2i.ZERO
	var shade := Color(0.8, 0.2, 0.1)
	func set_mpv_playing(id: int, play: bool) -> void: plays.append([id, play])
	func request_mpv_layer_snapshot(id: int, w: int, h: int) -> int:
		snapshots.append([id, w, h]); size = Vector2i(w, h)
		return 0 if reject_capture else snapshots.size()
	func get_mpv_layer_thumbnail_state(_id: int) -> String: return status
	func take_mpv_layer_thumbnail(_id: int) -> PackedByteArray:
		var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		image.fill(shade)
		return image.get_data()
	func cancel_mpv_layer_snapshot(id: int) -> void: cancelled.append(id)
	func freeze_mpv_pair(id: int, token: int, request: int) -> bool:
		freezes.append([id, token, request]); return not reject_capture
	func release_mpv_frozen_frame(id: int) -> void: released.append(id)
	func retain_mpv_frozen_frame(_id: int) -> bool: return true
	func close_mpv_video(id: int) -> void: closed.append(id)
	func detach_mpv_pair(_id: int, _token: int) -> void: pass
	func claim_mpv_pair(_id: int, _token: int) -> String: return JSON.stringify(claim)
	func acknowledge_mpv_pair(_id: int, _token: int) -> bool: return not reject_ack
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, _at: int, depth: bool, _tb: bool, _exact: bool) -> int:
		revisions.append([id, depth]); return id + 1

class Player extends "res://scripts/mpv_video_display.gd":
	var opens: Array = []
	var next_id := 20
	var reject_open := false
	func _ready() -> void:
		super._ready()
		set_process(false)
	func open_local(uri: String, _title: String, start_ms: int = 0, _restore_mode: bool = true,
			_alpha: bool = false, _basename: String = "", _metadata: Dictionary = {}) -> bool:
		opens.append({"uri": uri, "at": start_ms, "layer": not _eye_buffer_only,
			"held": mode_transition.overlay != null and mode_transition.overlay.visible})
		close_video()
		local_uri = uri
		next_id += 1
		media.begin(-1 if reject_open else next_id)
		_layer_requested = not _eye_buffer_only
		_waiting_first = not reject_open
		return not reject_open

class MissingCopyHost extends Host:
	func has_java_method(method: String) -> bool:
		return method != "request_mpv_layer_snapshot" and has_method(method)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func player(layer: bool = true, depth: bool = false) -> Player:
	var v := Player.new()
	root.add_child(v)
	v.platform = Host.new()
	v.local_uri = "file:///mode-switch.mp4"
	v.media.begin(7)
	v.media.state = "ready"
	v.media.frame_counter = 3
	v.media.format = {"width": 3840, "height": 2160}
	v._binding = ProbeBinding.new()
	v._binding.bind(v.material, {"session_id": 7, "slot_token": 2, "pts_us": 1500000,
		"width": 3840, "height": 2160, "color_target": "layer" if layer else "texture", "depth_requested": depth,
		"stereo_sbs": false, "alpha_requested": false})
	v.media.last_pair = v._binding.ticket.duplicate(true)
	v._layer_session = layer
	v._layer_requested = layer
	v.depth_requested = depth
	v.auto_depth = depth
	v.depth_enabled = depth
	v.panel.visible = true
	v.requested_play = false
	v.mode_transition.hold_binding = ProbeBinding.new()
	return v

func arm_snapshot(v: Player) -> void:
	v.platform.status = "ready"
	v.mode_transition.poll()
	check(v.mode_transition.stage == "armed", "The complete copied image is bound before teardown")
	if gl:
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	else:
		v.mode_transition.armed_draw = -1 # the dummy renderer has no submitted frames
	v.mode_transition.poll()

func dispose(v: Player) -> void:
	v.close_video()
	v.free()
	if gl: await RenderingServer.frame_post_draw
	else: await process_frame

func run() -> void:
	gl = DisplayServer.get_name() != "headless"
	check(Transition.snapshot_size(Vector2i(8192, 4096)) == Vector2i(2048, 1024), "8K snapshots have a bounded independent allocation")
	check(Transition.snapshot_size(Vector2i(1080, 1920)) == Vector2i(1080, 1920), "Portrait buffers keep their aspect without upscaling")
	check(Transition.snapshot_size(Vector2i(128, 64)) == Vector2i(128, 64), "Small frames retain all pixels")
	var v := player()
	v.depth_requested = true; v.auto_depth = true
	v._request_revision()
	check(v.platform.snapshots == [[7, 2048, 1152]] and v.opens.is_empty() and v.panel.visible, "Switching from the Surface keeps its original picture during full-frame capture")
	v._try_revision()
	check(v.platform.snapshots.size() == 1, "Repeated requests do not start more copies")
	v._present_pending()
	check(v._binding.layer, "A queued source frame cannot replace the capture source")
	await arm_snapshot(v)
	check(v.opens.is_empty() and v.mode_transition.stage == "held", "A rendered hold is required before reopening the decoder")
	v._try_revision()
	check(v.opens.size() == 1 and v.opens[0].held and not v.opens[0].layer, "The decoder reopens only beneath a visible independent image")
	check(v.mode_transition.overlay.visible and not v.panel.visible and v.mode_transition.stage == "preparing", "Closing the old session cannot hide the held picture")
	check(not v.requested_play, "Reopen preserves the original pause state")
	v.mode_transition.finish_frame()
	check(v.mode_transition.active(), "No image or effect-ready event can end the hold before a bound first frame")
	v._binding.bind(v.material, {"session_id": v.media.session_id, "slot_token": 99})
	v.panel.visible = true; v._waiting_first = false
	v.mode_transition.target_ready(v.media.session_id)
	v.mode_transition.finish_frame()
	check(not v.mode_transition.active() and v.platform.plays.back() == [v.media.session_id, false], "A valid first frame commits and restores pause")
	await dispose(v)

	v = player()
	v.requested_play = true
	v.depth_requested = true; v.auto_depth = true; v._request_revision()
	await arm_snapshot(v)
	v._try_revision()
	v.toggle_play(); v.toggle_play()
	check(v.requested_play and not bool(v.platform.plays.back()[1]), "Play intent changes do not start audio while the preserved picture is covering preparation")
	v._binding.bind(v.material, {"session_id": v.media.session_id, "slot_token": 98, "color_target": "layer"})
	v.panel.visible = true; v._waiting_first = false
	v.mode_transition.target_ready(v.media.session_id)
	v.video_layer_shown = false; v.mode_transition.finish_frame()
	check(v.mode_transition.active(), "A Surface frame is not committed before its layer and hole are submitted")
	v.video_layer_shown = true; v.mode_transition.finish_frame()
	check(not v.mode_transition.active() and v.platform.plays.back() == [v.media.session_id, true], "The committed frame restores the latest playing intent")
	await dispose(v)

	# Capture rejection preserves the old session and rolls the desired mode back.
	for outcome in ["rejected", "failed", "timeout"]:
		v = player()
		v.platform.reject_capture = outcome == "rejected"
		v.depth_requested = true; v.auto_depth = true
		v._request_revision()
		if outcome == "failed": v.platform.status = "failed:pixel_copy_3"
		if outcome == "timeout": v.mode_transition.deadline = 0
		v.mode_transition.poll()
		check(not v.mode_transition.active() and v.opens.is_empty() and v.panel.visible and v._binding.layer, "Capture %s preserves the original visible decoder" % outcome)
		check(not v.depth_requested and not v._waiting_first and v._pending_revision.is_empty(), "Capture %s restores the original 2D choice" % outcome)
		await dispose(v)
	v = player()
	v.platform = MissingCopyHost.new()
	v.depth_requested = true; v.auto_depth = true; v._request_revision()
	check(v.opens.is_empty() and v.panel.visible and not v.depth_requested and not v.mode_transition.active(), "A missing copy capability cancels the change instead of falling back to a black transition")
	await dispose(v)

	# Leaving AI 3D uses the existing independent GPU freeze, never another decoder.
	v = player(false, true)
	v.depth_requested = false; v.auto_depth = false
	v._request_revision()
	check(v.platform.freezes.size() == 1 and v.platform.revisions.is_empty(), "Disabling 3D freezes its last image before revising")
	var request: int = v.platform.freezes[0][2]
	v._on_frozen_pair(7, JSON.stringify({"request_id": request, "state": "ready", "pair": {
		"session_id": 7, "slot_token": 2, "pts_us": 1500000, "frozen_frame_id": 700, "depth_requested": true}}))
	check(v.mode_transition.overlay.visible and v.platform.revisions.is_empty(), "GPU freeze is visible before processing resources retire")
	if gl:
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
	else: v.mode_transition.armed_draw = -1
	v.mode_transition.poll(); v._try_revision()
	check(v.platform.revisions == [[7, false]] and v.mode_transition.stage == "preparing", "The existing decoder revises under the independent frame")
	v.depth_requested = true; v.auto_depth = true
	v._request_revision()
	check(v.platform.revisions.size() == 1, "Rapid toggling waits for the current pending first frame")
	check(v.mode_transition.overlay.visible and v.platform.freezes.size() == 1, "Rapid toggling reuses one preserved image")
	v.seek_absolute(5000)
	check(v.platform.freezes.size() == 1 and v.platform.revisions.size() == 1, "Seek during preparation waits without asking for a second GPU snapshot")
	v.close_video()
	if gl: await RenderingServer.frame_post_draw
	else: await process_frame
	check(v.platform.released == [700], "Closing releases the frozen image exactly once")
	v._on_frozen_pair(7, JSON.stringify({"request_id": request, "state": "ready", "pair": {"frozen_frame_id": 701}}))
	check(v.platform.released == [700, 701], "Late frozen results cannot revive closed playback")
	v.free()
	v = player(false, true)
	v._binding.warped = true
	v._binding.ticket.stereo_sbs = true # Binding labels the generated atlas SBS; the source is still mono.
	v.depth_requested = false; v.auto_depth = false; v._request_revision()
	check(not bool(v.mode_transition.source_mode.stereo) and bool(v.mode_transition.source_mode.depth), "A generated stereo atlas rolls back to mono AI 3D, not a native SBS source")
	request = int(v.platform.freezes.back()[2])
	v.close_video()
	v._on_frozen_pair(7, JSON.stringify({"request_id": request, "state": "ready", "pair": {"frozen_frame_id": 702}}))
	check(v.platform.released == [702], "Cancellation during GPU capture releases the late result")
	v.free()

	# A failure in the replacement gets a single rollback, keeping the snapshot throughout.
	v = player()
	v.depth_requested = true; v.auto_depth = true; v._request_revision()
	await arm_snapshot(v)
	v._try_revision()
	v._on_error(v.media.session_id, JSON.stringify({"code": "MPV_OUTPUT_TIMEOUT"}))
	check(v.mode_transition.overlay.visible and v.mode_transition.rolling_back and not v.depth_requested, "A failed replacement restores the old mode behind the snapshot")
	await process_frame
	check(v.opens.size() == 2 and v.opens.back().layer and v.opens.back().held, "Rollback reopens the old route with the picture still visible")
	v._on_error(v.media.session_id, JSON.stringify({"code": "MPV_OUTPUT_TIMEOUT"}))
	check(not v.mode_transition.active() and v.media.state == "failed" and v.opens.size() == 2, "Rollback failure exits with an error rather than freezing indefinitely")
	await dispose(v)

	v = player()
	v.depth_requested = true; v.auto_depth = true; v._request_revision()
	await arm_snapshot(v)
	v.reject_open = true; v._try_revision()
	await process_frame
	check(v.opens.size() == 2 and not v.mode_transition.active(), "An immediately rejected replacement and rollback also end without an infinite hold")
	await dispose(v)

	v = player()
	v.depth_requested = true; v._request_revision()
	v.close_video()
	check(v.platform.cancelled == [1] and not v.mode_transition.active(), "Exit cancels a pending Surface copy")
	v.platform.status = "ready"; v.mode_transition.poll()
	check(v.opens.is_empty(), "A cancelled Surface callback cannot reopen a video")
	v.free()
	if gl: await pixels()
	for failure in failures: push_error(failure)
	print("Video mode transition: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func pixels() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(96, 96); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new(); camera.position = Vector3(0, 1.5, 0)
	view.add_child(camera)
	var v := Player.new(); view.add_child(v)
	v.platform = Host.new(); v.local_uri = "file:///pixels.mp4"
	v.media.begin(7); v.media.frame_counter = 1; v.media.state = "ready"
	v._binding.bind(v.material, {"session_id":7,"logical_session_id":7,"generation":1,"frame_id":2,
		"pts_us":1500000,"slot_token":2,"width":128,"height":128,"source_pts_verified":true,"color_target":"layer"})
	v.panel.visible = true; v._layer_session = true
	v.depth_requested = true; v.auto_depth = true
	v._request_revision()
	await arm_snapshot(v)
	v._try_revision()
	for frame in 5:
		await RenderingServer.frame_post_draw
		var sample := view.get_texture().get_image().get_pixel(48,48)
		check(sample.r > 0.6 and sample.g < 0.3 and sample.b < 0.2, "Held source remains visible while the new decoder has no frame: %s" % sample)
	view.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../../build/output/video-mode-transition/held-surface.png"))
	# Bind a genuine GPU frame through the production PairTextureBinding and presentation path.
	var color := Image.create_empty(32,32,false,Image.FORMAT_RGBA8); color.fill(Color(.1,.8,.2))
	var alpha := Image.create_empty(64,32,false,Image.FORMAT_R8); alpha.fill(Color.WHITE)
	var textures := [ImageTexture.create_from_image(color), ImageTexture.create_from_image(alpha)]
	var id: int = v.media.session_id
	var pair := {"session_id":id,"logical_session_id":id,"generation":1,"frame_id":3,"pts_us":1500000,
		"slot_token":3,"width":32,"height":32,"input_width":32,"input_height":32,"alpha_width":64,"alpha_height":32,
		"format_revision":1,"effect_revision":1,"model_generation":1,"source_pts_verified":true,"immutable_color_frame":true,
		"pair_identity_verified":true,"alpha_fence_ready":true,"alpha_gpu_uploaded":true,"alpha_texture_format":"GL_R8_numeric",
		"color_texture_id":RenderingServer.texture_get_native_handle(textures[0].get_rid()),
		"alpha_texture_id":RenderingServer.texture_get_native_handle(textures[1].get_rid()),
		"alpha_slot_token":3,"alpha_frame_id":3,"alpha_pts_us":1500000,"rotation_degrees":0,
		"model_content_rect":[0,0,1,1],"stereo_sbs":false,"alpha_requested":false,"inference_ran":false,"depth_requested":true}
	v.platform.claim = pair
	v._pending_pair = pair
	v.platform.reject_ack = true
	v._present_pending(); v._update_layer(); v.mode_transition.finish_frame()
	check(v.mode_transition.active(), "Rejected presentation acknowledgement cannot remove the hold")
	await RenderingServer.frame_post_draw
	check(view.get_texture().get_image().get_pixel(48,48).r > .6, "Rejected new frame still shows the old pixels")
	v.platform.reject_ack = false
	v._pending_pair = pair
	v._present_pending(); v._update_layer(); v.mode_transition.finish_frame()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var shown := view.get_texture().get_image().get_pixel(48,48)
	check(not v.mode_transition.active() and shown.g > .6 and shown.r < .3, "The accepted first frame replaces the hold without an empty submission: %s" % shown)
	view.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../../build/output/video-mode-transition/accepted-frame.png"))
	# The reverse direction uses a genuine GPU-texture binding for the preserved copy.
	v.depth_enabled = true; v.depth_requested = false; v.auto_depth = false
	v._request_revision()
	var frozen := pair.duplicate(true)
	frozen.frozen_frame_id = 900
	var request: int = v.platform.freezes.back()[2]
	v._on_frozen_pair(id, JSON.stringify({"request_id": request, "state": "ready", "pair": frozen}))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	v.mode_transition.poll()
	v._reopen_at(-1, true)
	check(v.opens.back().layer and v.opens.back().held, "Returning to the Surface prepares it under the independent GPU frame")
	for frame in 5:
		await RenderingServer.frame_post_draw
		var kept := view.get_texture().get_image().get_pixel(48,48)
		check(kept.g > .6 and kept.r < .3, "The GPU copy remains visible after its old source is closed: %s" % kept)
	view.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../../build/output/video-mode-transition/held-gpu-frame.png"))
	var host: Host = v.platform
	v.close_video(); v.free()
	await RenderingServer.frame_post_draw
	check(host.released == [900], "Deferred GPU cleanup releases exactly once after the player is destroyed")
	view.free()
