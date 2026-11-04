extends SceneTree
const MainFixture := preload("res://tests/test_view_follow.gd")
const PlayerFixture := preload("res://tests/test_player_menu.gd")
const TransitionFixture := preload("res://tests/test_video_mode_transition.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
var checks := 0
var failures: Array[String] = []
var directory := ProjectSettings.globalize_path("res://../../build/output/vr-passthrough")

class Host extends PlayerFixture.Host:
	var status := "pending"
	var reject := false
	var snapshots: Array = []
	var cancelled: Array = []
	var released: Array = []
	var freezes: Array = []
	var narration_payloads: Array = []
	var size := Vector2i.ZERO
	func request_mpv_layer_snapshot(id: int, width: int, height: int) -> int:
		size = Vector2i(width, height); snapshots.append([id, width, height]); return 0 if reject else snapshots.size()
	func get_mpv_layer_thumbnail_state(_id: int) -> String: return status
	func take_mpv_layer_thumbnail(_id: int) -> PackedByteArray:
		var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.2, 0.6, 0.8)); return image.get_data()
	func cancel_mpv_layer_snapshot(id: int) -> void: cancelled.append(id)
	func freeze_mpv_pair(id: int, token: int, request: int) -> bool:
		freezes.append([id, token, request]); return not reject
	func release_mpv_frozen_frame(id: int) -> void: released.append(id)
	func detach_mpv_pair(_id: int, _token: int) -> void: pass
	func get_mpv_subtitles(_id: int, _sequence: int) -> String: return ""
	func set_mpv_narration(_id: int, payload: String) -> bool:
		narration_payloads.append(JSON.parse_string(payload)); return true

func _initialize() -> void: run.call_deferred()
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func prepare(main: Node3D, geometry := 1, stereo := true, tb := false, playing := true, layer := true) -> void:
	var v: Node3D = main.video
	v.close_video()
	v.local_uri = "file:///temporary-vr-" + str(checks) + ".mp4"
	v.media.begin(7); v.media.state = "paused"; v.media.frame_counter = 2
	v.media.format = {"width": 3840, "height": 2160}
	v._waiting_first = false; v._pending_revision.clear()
	v._binding = TransitionFixture.ProbeBinding.new()
	v._binding.bind(v.material, {"session_id": 7, "slot_token": 8, "width": 3840, "height": 2160,
		"stereo_sbs": stereo, "top_bottom": tb, "color_target": "layer" if layer else "texture"})
	v.media.last_pair = v._binding.ticket.duplicate(true)
	v.geometry = geometry; v.stereo_sbs = stereo; v.top_bottom = tb
	v.viewing_eye = 0; v.swap_eyes = false
	v.alpha_requested = false; v.alpha_enabled = false; v.packed_alpha = false; v.packed_file = false
	v._layer_session = layer; v._layer_requested = layer; v.requested_play = playing
	v._apply_geometry(); v.panel.visible = true
	v.view_yaw = 0.3; v.view_pitch = 0.1; v.view_zoom = 0.08
	v.view_horizontal = 0.03; v._center_on_view()
	v.vr_passthrough.binding = TransitionFixture.ProbeBinding.new()
	v.platform.status = "pending"; v.platform.reject = false
	main._on_video_changed(); main._show_player_menu()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	var config := ConfigFile.new(); config.set_value("appearance", "background", "dark")
	config.save(directory.path_join("settings.cfg"))
	var main := MainFixture.FollowMain.new()
	main.settings_path = directory.path_join("settings.cfg")
	main.display = MainFixture.SupportedDisplay.new()
	root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	main.video.platform = Host.new()
	main.video.mode_memory = Memory.new(directory.path_join("modes.cfg"))
	main.video.recent_files = Catalog.new(directory.path_join("recent.cfg"))
	var v: Node3D = main.video
	var host: Host = v.platform
	for geometry in [1, 2, 3]:
		for eyes in [0, 1, 2]:
			for playing in [false, true]:
				prepare(main, geometry, eyes != 0, eyes == 2, playing)
				var original := [v.geometry, v.view_yaw, v.view_pitch, v.view_zoom, v.view_horizontal, v._view_basis, v.stereo_sbs, v.top_bottom]
				var stored: Dictionary = v.mode_memory.lookup(v.local_uri).duplicate(true)
				main._on_session_control("temporary_passthrough")
				check(main._vr_passthrough_active() and main.temporary_passthrough and main.display.applied_passthrough, "VR entry creates a temporary camera state")
				check(not v.requested_play and host.calls.back() == ["play", 7, false], "Entry always pauses the backend")
				check(v.panel.layers == 0 and not v.video_layer_shown, "Reality is exposed while the frozen frame is still being copied")
				check(main._active_menu() == main.vr_passthrough_menu and main.vr_passthrough_menu._buttons.size() == 1 and not main.video_menu.visible and not main.recent_menu.visible, "Only the single exit control remains")
				host.status = "ready"; v.vr_passthrough.poll()
				check(v.vr_passthrough.motion == "opening" and is_zero_approx(v.vr_passthrough.roll), "A ready picture begins as the wide curved surface")
				v.vr_passthrough.poll(0.12)
				check(v.vr_passthrough.roll > 0 and v.vr_passthrough.roll < 1 and not v.requested_play, "The surface visibly rolls inward while playback stays paused")
				v.vr_passthrough.poll(0.12)
				check(v.vr_passthrough.motion.is_empty() and is_equal_approx(v.vr_passthrough.roll, 1.0), "The short roll finishes at the stationary globe")
				check(v.vr_passthrough.held() and v.vr_passthrough.preview.visible and v.panel.layers == 0 and not v.video_layer_shown, "The frozen preview replaces both the eye-buffer surface and native video layer")
				check(v.vr_passthrough.preview.mesh is SphereMesh and is_equal_approx(v.vr_passthrough.preview.mesh.radius, 0.36), "The paused picture wraps onto a compact exterior globe")
				check(v.vr_passthrough.material.get_shader_parameter("pip_viewing_eye") == 1 and v.vr_passthrough.material.get_shader_parameter("stereo_sbs") == (eyes != 0) and v.vr_passthrough.material.get_shader_parameter("top_bottom") == (eyes == 2), "Preview selects one source eye while preserving mono/SBS/TB packing")
				var preview_pose: Transform3D = v.vr_passthrough.preview.global_transform
				main.xr_camera.global_transform = Transform3D(Basis.from_euler(Vector3(0.6, 1.2, -0.4)), Vector3(5, 1.1, 3))
				main._sync_vr_passthrough_menu()
				check((main.xr_camera.global_transform.affine_inverse() * main.vr_passthrough_menu.global_transform).origin.is_equal_approx(main.vr_passthrough_menu.OFFSET), "Exit control follows head translation, yaw, pitch and roll")
				check(v.vr_passthrough.preview.global_transform.is_equal_approx(preview_pose), "Preview stays in place instead of following every head turn")
				v.toggle_play(); v.requested_play = true; v._set_backend_playing(7, true)
				check(not v.requested_play and host.calls.back() == ["play", 7, false], "Both requested and internal backend playback are gated")
				check(not v.seek_absolute(50000) and not v.playback_end_ready(), "Seeking and queued end-of-file progression are blocked")
				main._execute_shortcut("play"); main._execute_shortcut("projection_video"); main._on_menu_action("stop")
				main._show_player_menu(); main._show_full_library(); main._navigate_back()
				check(main._vr_passthrough_active() and not main.video_menu.visible and not main.recent_menu.visible, "Shortcuts and menu reopening cannot bypass the modal state")
				check(not v.open_library("file:///other.mp4", "Other") and v.geometry == geometry, "An external replacement does not mutate the active source")
				var item: Dictionary = main.vr_passthrough_menu._buttons[0]
				main.test_ray = [item.node.global_position + item.node.global_basis.z * 0.3, -item.node.global_basis.z]
				main._on_pointer_button("trigger_click", "right_hand")
				main._on_pointer_release("trigger_click", "right_hand")
				check(main._vr_passthrough_active() and not v.requested_play and not main.video_menu.visible, "Unfolding keeps playback and other controls locked")
				v.vr_passthrough.poll(1.0)
				check(not main._vr_passthrough_active() and not main.temporary_passthrough and main.video_menu.visible, "Ray selection exits without release reopening/dismissing another menu")
				check(v.requested_play == playing and v.panel.layers == 1, "Exit restores the original pause state and render visibility")
				check(original == [v.geometry, v.view_yaw, v.view_pitch, v.view_zoom, v.view_horizontal, v._view_basis, v.stereo_sbs, v.top_bottom] and stored == v.mode_memory.lookup(v.local_uri), "Original view and file preferences remain unchanged")
				main.test_ray = null
				await process_frame
	# The globe override is private, including frozen-texture and native-layer snapshots.
	for layer in [false, true]:
		for selected in [0, 1, 2]:
			for swapped in [false, true]:
				prepare(main, 3, true, false, true, layer)
				v.viewing_eye = selected; v.swap_eyes = swapped; v._apply_geometry()
				var original_override: Variant = v.material.get_shader_parameter("pip_viewing_eye")
				main._on_session_control("temporary_passthrough")
				if layer:
					host.status = "ready"; v.vr_passthrough.poll()
				else:
					v._on_frozen_pair(7, JSON.stringify({"request_id": v.vr_passthrough.request, "state": "ready", "pair": {"frozen_frame_id": 400 + checks, "stereo_sbs": true}}))
				check(v.vr_passthrough.material.get_shader_parameter("pip_viewing_eye") == maxi(1, selected) and v.vr_passthrough.material.get_shader_parameter("swap_eyes") == swapped, "Globe uses the selected logical eye and honours eye swap")
				check(v.vr_passthrough.release_material.get_shader_parameter("pip_viewing_eye") == original_override and v.vr_passthrough.release_material.get_shader_parameter("viewing_eye") == selected, "Unfolding panorama retains the source viewing mode")
				main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
				check(v.viewing_eye == selected and v.swap_eyes == swapped and v.material.get_shader_parameter("pip_viewing_eye") == original_override and v.requested_play, "Exit restores playback without changing the main eye selection")
	# Default camera background still exposes a non-selected collapse button.
	prepare(main); main.background.select("passthrough"); main._update_background()
	check(main._session_controls_state().passthrough_visible and not main._session_controls_state().passthrough, "Saved passthrough does not hide the VR collapse control")
	main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll(); main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	check(main.display.applied_passthrough and main.background.choice == "passthrough", "Exit preserves a saved camera background")
	main.background.select("dark"); main._update_background()
	# Failure and cancellation leave neither a false success nor an orphaned frame request.
	prepare(main); main.display.reject = true; main._on_session_control("temporary_passthrough")
	check(not main._vr_passthrough_active() and v.requested_play and not main.temporary_passthrough, "Runtime camera rejection keeps playing state unchanged")
	main.display.reject = false
	prepare(main); host.reject = true; main._on_session_control("temporary_passthrough")
	check(not main._vr_passthrough_active() and v.requested_play and not main.temporary_passthrough, "Rejected snapshot rolls back pause and background")
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "failed"; v.vr_passthrough.poll()
	check(not main._vr_passthrough_active() and v.requested_play and not main.temporary_passthrough, "Asynchronous snapshot failure restores source and controls")
	prepare(main); main._on_session_control("temporary_passthrough"); v.vr_passthrough.deadline = 1; v.vr_passthrough.poll()
	check(not main._vr_passthrough_active() and v.requested_play and not main.temporary_passthrough, "Capture timeout restores source and controls")
	prepare(main); main._on_session_control("temporary_passthrough"); var pending: int = v.vr_passthrough.snapshot_request; main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	check(host.cancelled.has(pending) and not main._vr_passthrough_active(), "Exit during capture cancels that exact snapshot")
	# Texture path and a late frozen result use the existing native frame ownership contract.
	prepare(main, 3, true, false, false, false); main._on_session_control("temporary_passthrough")
	var request: int = v.vr_passthrough.request
	v._on_frozen_pair(7, JSON.stringify({"request_id": request, "state": "ready", "pair": {"frozen_frame_id": 321, "stereo_sbs": true}}))
	check(v.vr_passthrough.held(), "Eye-buffer path accepts the matching frozen frame")
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0); await process_frame
	check(host.released.has(321), "Frozen frame lease releases after preview teardown")
	prepare(main, 1, true, false, true, false); main._on_session_control("temporary_passthrough"); request = v.vr_passthrough.request
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	v._on_frozen_pair(7, JSON.stringify({"request_id": request, "state": "ready", "pair": {"frozen_frame_id": 322}}))
	check(host.released.has(322) and not main._vr_passthrough_active(), "Late frozen result cannot revive a cancelled preview")
	# A recovered session must remain paused and put its replacement globe at the original anchor.
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll()
	var old_pose: Transform3D = v.vr_passthrough.preview.global_transform
	v.media.begin(8); v.media.state = "paused"; v.media.frame_counter = 2; v._waiting_first = false
	main.xr_camera.position += Vector3(1, 0, 1)
	v.vr_passthrough.poll()
	check(v.vr_passthrough.held() and v.vr_passthrough.source_session == 8 and not v.requested_play and v.vr_passthrough.preview.global_transform.is_equal_approx(old_pose), "Recovery keeps the globe anchor and the modal pause")
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	check(v.requested_play and host.calls.back() == ["play", 8, true], "Exiting after recovery restores the pre-passthrough playback state")
	prepare(main, 3)
	v._stream_projection = {"kind": "equirectangular", "geometry": 3, "pose": [25, 5, 2], "stereo_mode": 1}
	v._stream_mesh = v.StreamProjection.mesh(v._stream_projection); v._apply_geometry()
	main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll()
	var wrapped: Array = v.vr_passthrough.preview.mesh.surface_get_arrays(0)
	var authored: Array = v._stream_mesh.surface_get_arrays(0)
	check(v.vr_passthrough.held() and v.vr_passthrough.material.get_shader_parameter("projection_mesh") == true, "Stream-authored projection also enters the paused globe")
	check(wrapped[Mesh.ARRAY_TEX_UV] == authored[Mesh.ARRAY_TEX_UV] and wrapped[Mesh.ARRAY_COLOR] == authored[Mesh.ARRAY_COLOR], "Wrapping preserves authored UVs and eye identity")
	var sphere := true
	for point in wrapped[Mesh.ARRAY_VERTEX]: sphere = sphere and is_equal_approx(point.length(), 0.36)
	check(sphere, "Every authored direction wraps onto the same compact radius")
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	prepare(main)
	v.media.playback = {"details": {"subtitle_tracks": [{"id": 1, "codec": "subrip", "language": "eng"}]}}
	v.subtitles.select(1); v.narration.enabled = true; v.narration.apply()
	check(host.narration_payloads.back().enabled, "Narration fixture starts with active speech output")
	main._on_session_control("temporary_passthrough")
	check(v.narration.enabled and not host.narration_payloads.back().enabled, "Temporary passthrough stops speech output without changing its preference")
	main._leave_vr_passthrough(); v.vr_passthrough.poll(1.0)
	check(v.narration.enabled and host.narration_payloads.back().enabled, "Exit restores narration output")
	prepare(main); main._on_session_control("temporary_passthrough"); v.close_video()
	check(not main._vr_passthrough_active() and main.temporary_passthrough and main.display.applied_passthrough, "Closing media retains temporary camera without resurrecting playback")
	prepare(main); main.temporary_passthrough = true; main._vr_source_key = ""; main._on_video_changed()
	check(not main.temporary_passthrough, "Entering a new ready VR source clears an earlier temporary request")
	# Reversing/cancelling an in-flight animation cannot resume early or revive closed media.
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"
	v._process(1.0)
	check(v.vr_passthrough.motion == "opening" and v.vr_passthrough.roll < 1.0 and not v.requested_play, "A slow first render frame cannot skip the whole roll")
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll(0.08)
	var partial: float = v.vr_passthrough.roll
	main._leave_vr_passthrough()
	check(v.vr_passthrough.motion == "closing" and is_equal_approx(partial, v.vr_passthrough.roll) and not v.requested_play, "Early exit reverses the current shape without snapping or resuming")
	v.vr_passthrough.poll(0.01)
	check(v.vr_passthrough.roll < partial and not v.requested_play and main.vr_passthrough_menu.visible, "Reversed roll keeps a visible exit and stays paused")
	main._leave_vr_passthrough()
	check(not v.vr_passthrough.active() and v.requested_play, "A second exit immediately completes an unfolding transition")
	v.vr_passthrough.poll(1.0)
	check(not v.vr_passthrough.active() and not main.temporary_passthrough, "No delayed animation can reopen passthrough")
	for closing in [false, true]:
		prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll(0.08)
		if closing: main._leave_vr_passthrough()
		v.close_video(); v.vr_passthrough.poll(1.0)
		check(not v.vr_passthrough.active() and v.vr_passthrough.release_surface == null and main.temporary_passthrough, "Close cancels either roll direction and retains reality")
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll(1.0)
	main._leave_vr_passthrough(); v.vr_passthrough.poll(0.12)
	check(v.vr_passthrough.release_surface.visible and not v.requested_play and main.temporary_passthrough, "Halfway out, the frozen panorama fades in while reality and pause remain active")
	main.xr_camera.position += Vector3(2, 0.4, -1)
	v.vr_passthrough.poll(0.02)
	check(v.vr_passthrough.release_surface.global_transform.is_equal_approx(v.panel.global_transform), "The releasing panorama follows the current viewing position")
	v.vr_passthrough.poll(0.10)
	check(not v.vr_passthrough.active() and v.requested_play, "Playback resumes only when the full transition completes")
	prepare(main); main._on_session_control("temporary_passthrough"); host.status = "ready"; v.vr_passthrough.poll(1.0)
	main._leave_vr_passthrough()
	v.media.begin(9); v.media.state = "paused"; v.media.frame_counter = 2; v._waiting_first = false
	v.vr_passthrough.poll(0.01)
	check(not v.vr_passthrough.active() and v.requested_play and not main.temporary_passthrough, "A recovered session during unfolding honours the exit instead of starting a new roll")
	prepare(main, 0); main._on_session_control("temporary_passthrough")
	check(main.temporary_passthrough and not main._vr_passthrough_active() and v.requested_play, "Flat video retains the existing background-only behavior")
	main.free(); await process_frame
	for failure in failures: push_error(failure)
	print("VR temporary passthrough: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
