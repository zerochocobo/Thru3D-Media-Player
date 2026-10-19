extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const ExistingTests := preload("res://tests/test_file_mode_memory.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func usb_state(video: Node, identity: String) -> void:
	video._on_state(video.media.session_id, JSON.stringify({"state": "ready", "subtitle_memory_id": identity}))

func drag_alignment(menu: Node, key: String, fraction: float) -> void:
	var row: Dictionary = menu._adjust_rows[Menu.ALIGNMENT_HORIZONTAL if key == "stereo_horizontal" else Menu.ALIGNMENT_VERTICAL]
	var point: Vector3 = row.knob.position
	point.x = row.left + fraction * row.width; point.z += 1
	var origin: Vector3 = row.knob.get_parent().to_global(point)
	var direction: Vector3 = -row.knob.global_basis.z
	check(menu.press_pointer("right", origin, direction, true), "Production menu captures the alignment slider")
	menu.release_pointer("right", origin, direction, true)

func check_persistence(video: Node, path: String) -> void:
	video.mode_memory = Memory.new(path)
	var main := Main.new(); main.video = video; main.settings_path = path.path_join("settings.cfg")
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.visible = true; menu.section = 1; menu._adjustment = "stereo_view"
	for prefix in ["file:///", "cloud://account/", "smb://server/share/", "medialib://server/"]:
		var uri: String = prefix + "saved_LR.mp4"
		video.open_library(uri, "saved_LR.mp4"); menu.refresh()
		drag_alignment(menu, "stereo_horizontal", 0.7)
		drag_alignment(menu, "stereo_vertical", 0.4)
		var reloaded := Memory.new(path); reloaded.load_saved()
		check(is_equal_approx(float(reloaded.lookup(uri).get("stereo_horizontal", 0)), 2.0)
			and is_equal_approx(float(reloaded.lookup(uri).get("stereo_vertical", 0)), -1.0), "Real slider release saves both axes: " + prefix)
		video.close_video(); video.mode_memory = reloaded
		video.open_library(prefix + "other_TB.mp4", "other_TB.mp4")
		check(video.stereo_horizontal == 0 and video.stereo_vertical == 0, "Different movie starts neutral: " + prefix)
		video.open_library(uri, "saved_LR.mp4")
		check(is_equal_approx(video.stereo_horizontal, 2.0) and is_equal_approx(video.stereo_vertical, -1.0), "Fresh memory reader restores the movie's own adjustments: " + prefix)
		video.close_video()
	menu.free()
	# Backgrounding can happen while the trigger is held, before a release event.
	video.open_local("file:///background_LR.mp4", "background_LR.mp4")
	video.set_stereo_alignment("stereo_horizontal", 1.25)
	video.set_stereo_alignment("stereo_vertical", -0.75)
	main._notification(NOTIFICATION_APPLICATION_PAUSED)
	var fresh := Memory.new(path); fresh.load_saved()
	check(fresh.lookup(video.local_uri).get("stereo_horizontal") == 1.25 and fresh.lookup(video.local_uri).get("stereo_vertical") == -0.75,
		"Background checkpoint commits a held alignment slider before process loss")
	video.close_video()
	var identity := "usb://stable/" + "b".repeat(64) + "/movie.mp4"
	video.open_local("usb://connection-a/partition/movie.mp4", "movie_LR.mp4")
	usb_state(video, identity)
	video.set_stereo_alignment("stereo_horizontal", 2.5)
	video.set_stereo_alignment("stereo_vertical", -1.5)
	video.commit_stereo_view()
	video.close_video()
	fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
	video.open_local("usb://connection-b/partition/movie.mp4", "movie_LR.mp4")
	usb_state(video, identity)
	check(video.stereo_horizontal == 2.5 and video.stereo_vertical == -1.5,
		"Fresh reader restores USB alignment after its connection URI changes")
	check(video.material.get_shader_parameter("stereo_offset").is_equal_approx(Vector2(0.025, -0.015)),
		"Restored USB alignment reaches the rendering material")
	check(fresh.lookup(identity).get("stereo_horizontal") == 2.5,
		"USB corrections are persisted against the stable partition and file identity")
	var sequence: int = fresh.sequence
	usb_state(video, identity)
	check(fresh.sequence == sequence, "Repeated USB status does not rewrite the mode store")
	video.close_video()
	# A different movie on that disk starts neutral and has independent corrections.
	video.open_local("usb://connection-b/partition/other.mp4", "other_LR.mp4")
	usb_state(video, identity.replace("movie.mp4", "other.mp4"))
	check(video.stereo_horizontal == 0 and video.stereo_vertical == 0, "Another USB movie does not inherit alignment")
	video.set_stereo_alignment("stereo_horizontal", -0.5); video.commit_stereo_view(); video.close_video()
	video.open_local("usb://connection-c/partition/movie.mp4", "movie_LR.mp4")
	# The first frame can be displayed before Android reports the stable identity.
	video._remember_mode(false)
	usb_state(video, identity)
	check(video.stereo_horizontal == 2.5 and video.stereo_vertical == -1.5,
		"A first-frame default cannot replace saved USB corrections before identity arrives")
	video.close_video()
	# A user's newer preview takes precedence over a late identity report.
	video.open_local("usb://connection-d/partition/movie.mp4", "movie_LR.mp4")
	video.set_stereo_alignment("stereo_horizontal", 0.75)
	video.set_stereo_alignment("stereo_vertical", 0.25)
	usb_state(video, identity)
	video.commit_stereo_view(); video.close_video()
	fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
	video.open_local("usb://connection-e/partition/movie.mp4", "movie_LR.mp4")
	usb_state(video, identity)
	check(video.stereo_horizontal == 0.75 and video.stereo_vertical == 0.25,
		"Early user adjustment survives a late USB identity and the next restart")
	video.reset_stereo_alignment(); video.close_video()
	fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
	video.open_local("usb://connection-f/partition/movie.mp4", "movie_LR.mp4"); usb_state(video, identity)
	check(video.stereo_horizontal == 0 and video.stereo_vertical == 0, "Explicit alignment reset survives USB reconnect")
	video.close_video()
	var tb_identity := identity.replace("movie.mp4", "top-bottom.mp4")
	var tb := {"geometry": 1, "stereo_sbs": true, "top_bottom": true, "stereo_half": true,
		"swap_eyes": false, "alpha_requested": false, "profile": "320x320", "stereo_vertical": 1.25}
	check(fresh.remember(tb_identity, tb) and fresh.save(), "Save a USB top-bottom mode")
	video.open_local("usb://connection-f/partition/top-bottom.mp4", "unmarked.mp4"); usb_state(video, tb_identity)
	check(video.geometry == 1 and video.stereo_sbs and video.top_bottom and video.stereo_half and video.stereo_vertical == 1.25
		and video._pending_revision.get("stereo", false) and video._pending_revision.get("top_bottom", false),
		"Late restoration revises the decoder when the saved stereo packing differs")
	video.close_video()
	# Recover an old record if the current connection URI is still available.
	var legacy := {"geometry": 1, "stereo_sbs": true, "swap_eyes": true, "alpha_requested": false, "profile": "320x320",
		"stereo_horizontal": -2.0, "stereo_vertical": 1.0, "viewing_eye": 2}
	var legacy_uri := "usb://legacy-connection/partition/legacy.mp4"
	check(fresh.remember(legacy_uri, legacy) and fresh.save(), "Write legacy USB record under its old connection URI")
	video.open_local(legacy_uri, "legacy_LR.mp4")
	usb_state(video, identity.replace("movie.mp4", "legacy.mp4")); video.close_video()
	fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
	video.open_local("usb://new-connection/partition/legacy.mp4", "legacy_LR.mp4")
	usb_state(video, identity.replace("movie.mp4", "legacy.mp4"))
	check(video.stereo_horizontal == -2.0 and video.stereo_vertical == 1.0 and video.viewing_eye == 2 and video.swap_eyes and video.geometry == 1,
		"A reachable legacy USB record migrates with its projection, eye choice and alignment")
	video.close_video()
	# Diagnostics never load or overwrite user modes, even after identity is resolved.
	video.open_local("usb://diagnostic/partition/movie.mp4", "movie_LR.mp4", 0, false)
	sequence = fresh.sequence; usb_state(video, identity)
	check(video.stereo_horizontal == 0 and video.stereo_vertical == 0 and fresh.sequence == sequence,
		"Diagnostic USB open bypasses stored corrections and preserves user records")
	video.close_video()
	# A late callback from a retired session must not bind the new movie to that disk.
	video.open_local("usb://current/partition/movie.mp4", "movie_LR.mp4")
	video._on_state(video.media.session_id + 1, JSON.stringify({"state": "ready", "subtitle_memory_id": identity}))
	check(not fresh.identity_aliases.has(video.local_uri), "Stale session cannot register a USB file identity")
	usb_state(video, "usb://stable/" + "c".repeat(64) + "/movie.mp4")
	check(video.stereo_horizontal == 0 and video.stereo_vertical == 0, "Same file path on a different USB disk stays independent")
	video.close_video()
	var privacy_mode: String = Memory.Privacy.file_settings; Memory.Privacy.configure_file_settings(Memory.Privacy.NONE)
	sequence = fresh.sequence
	video.open_local("usb://private/partition/private.mp4", "private_LR.mp4")
	usb_state(video, identity.replace("movie.mp4", "private.mp4"))
	video.set_stereo_alignment("stereo_horizontal", 1.0); video.commit_stereo_view(); video.close_video()
	check(fresh.sequence == sequence, "Disabled settings memory prevents USB alignment persistence")
	Memory.Privacy.configure_file_settings(privacy_mode)
	main.free()

func _run() -> void:
	var path := ProjectSettings.globalize_path("res://../../build/output/stereo-view/memory-" + str(Time.get_ticks_usec()))
	var memory := Memory.new(path)
	var base := {"geometry": 0, "stereo_sbs": true, "swap_eyes": false, "alpha_requested": false, "profile": "320x320"}
	check(Memory.valid_mode(base), "Old saved modes without new fields remain readable")
	for bad in [{"viewing_eye": 3}, {"viewing_eye": 0.5}, {"viewing_eye": "1"}, {"stereo_horizontal": NAN}, {"stereo_vertical": INF}, {"stereo_horizontal": 5.01}, {"stereo_vertical": "0"}]:
		var invalid := base.duplicate(); invalid.merge(bad, true)
		check(not Memory.valid_mode(invalid), "Reject malformed display state " + str(bad))
	var host := ExistingTests.Host.new()
	var video := Video.new()
	video.mode_memory = memory
	video.recent_files.directory = path.path_join("recent")
	video.bookmark_store.directory = path.path_join("bookmarks")
	root.add_child(video)
	video.platform = host
	video.history_enabled = false
	check(video.open_local("file:///a_LR.mp4", "a_LR.mp4"), "Open SBS through actual controller")
	check(video._hole_material.next_pass == null, "Neutral alignment adds no extra surface draw pass")
	var calls := host.calls.size()
	var session := video.media.session_id
	check(video.set_stereo_alignment("stereo_horizontal", 2.03) and is_equal_approx(video.stereo_horizontal, 2.05), "Alignment rounds to 0.05 percent")
	check(video.set_stereo_alignment("stereo_vertical", -99) and video.stereo_vertical == -5, "Clamp excessive alignment")
	check(video._hole_material.next_pass == video._alignment_border, "Nonzero alignment enables the black-edge pass")
	check(not video.set_stereo_alignment("stereo_horizontal", NAN) and not video.set_stereo_alignment("unrelated", 1), "Reject nonfinite and unknown adjustments")
	check(memory.lookup(video.local_uri).is_empty(), "Pointer previews do not write file settings on every motion")
	video.commit_stereo_view()
	check(memory.lookup(video.local_uri).stereo_vertical == -5, "Pointer release saves this file")
	check(video.set_viewing_eye(1) and not video.set_stereo_alignment("stereo_horizontal", 1), "Mono mode suspends alignment without erasing it")
	check(video._hole_material.next_pass == null, "Mono viewing removes the unused black-edge pass")
	check(video.set_viewing_eye(2) and video.material.get_shader_parameter("viewing_eye") == 2, "Right-eye uniform applies immediately")
	check(video.toggle_eye_order() and video.swap_eyes, "Eye order remains independent of mono selection")
	check(host.calls.size() == calls and video.media.session_id == session, "Viewing changes do not reopen or revise decoding")
	var stored := Memory.new(path); stored.load_saved()
	check(stored.lookup(video.local_uri).viewing_eye == 2 and stored.lookup(video.local_uri).swap_eyes, "Eye selection and swap survive a fresh memory reader")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 2000, true)
	check(video.viewing_eye == 2 and is_equal_approx(video.stereo_horizontal, 2.05), "Graphics context recovery keeps current viewing choice")
	check(video.open_local("file:///b_TB.mp4", "b_TB.mp4") and video.viewing_eye == 0 and video.stereo_horizontal == 0 and video.stereo_vertical == 0, "Unseen next video starts without prior correction")
	check(video.open_local("file:///a_LR.mp4", "a_LR.mp4") and video.viewing_eye == 2 and video.stereo_vertical == -5, "Reopening the original file restores its own correction")
	video.set_viewing_eye(0)
	video.reset_stereo_alignment()
	check(video.stereo_horizontal == 0 and video.stereo_vertical == 0 and video.viewing_eye == 0 and video.swap_eyes, "Reset changes only alignment")
	video.media.format = {"width": 1600, "height": 400, "spatial_video": true}
	video._complete_layout()
	check(video.set_viewing_eye(1) and video.is_spatial_video() and not video.mode_action_allowed("stereo_2d"), "Spatial format remains locked while mono viewing works")
	video.set_viewing_eye(0)
	check(video.set_stereo_alignment("stereo_vertical", 0.5), "Spatial video permits alignment")
	video.close_video()
	check(video.viewing_eye == 0 and video.stereo_vertical == 0, "Close clears runtime viewing state")
	video.open_local("file:///ordinary_2D.mp4", "ordinary_2D.mp4")
	check(not video.set_viewing_eye(1) and not video.set_stereo_alignment("stereo_vertical", 1), "Ordinary 2D has no stereo controls")
	check(video.material.get_shader_parameter("stereo_offset") == Vector2.ZERO, "Ordinary 2D receives neutral alignment")
	video.close_video()
	# Legacy schema-1 saves had legal nonzero offsets but produced illegal native
	# rectangles. A fresh reader/controller must reopen them without deleting history.
	var layer := preload("res://scripts/video_layer.gd").new(null)
	var origin := Node3D.new(); root.add_child(origin)
	var legacy_uri := "cloud://old-account/previously-unopenable_LR_180.mp4"
	for offset in [Vector2(-5, 0), Vector2(5, 0), Vector2(0, -5), Vector2(0, 5), Vector2(2.5, -1.5)]:
		var legacy := base.duplicate(true)
		legacy.merge({"geometry": 1, "stereo_horizontal": offset.x, "stereo_vertical": offset.y, "viewing_eye": 0}, true)
		check(memory.remember(legacy_uri, legacy) and memory.save(), "Write old schema-1 alignment save")
		var fresh := Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
		check(video.open_local(legacy_uri, "previously-unopenable_LR_180.mp4") and video.geometry == 1
			and video.stereo_horizontal == offset.x and video.stereo_vertical == offset.y, "Previously broken file opens with its saved correction after restart")
		var values: PackedFloat32Array = layer.layer_values(video, origin)
		for eye in 2:
			var start := eye * layer.STRIDE
			var rect := Rect2(values[start + 9], values[start + 10], values[start + 11], values[start + 12])
			check(Rect2(eye * 2048, 0, 2048, 4096).encloses(rect) and rect.has_area(), "Restored correction cannot poison xrEndFrame")
		check(video.set_stereo_alignment("stereo_horizontal", 0.5), "Restored video remains adjustable")
		video.close_video()
	# A checksummed legacy record may contain malformed alignment; repair only those
	# display fields rather than throwing away its otherwise valid VR projection.
	var corrupt := base.duplicate(true)
	corrupt.merge({"geometry": 1, "swap_eyes": true, "stereo_horizontal": "bad", "stereo_vertical": 6.0, "viewing_eye": 8}, true)
	memory.entries[Memory.key_for(legacy_uri)] = {"mode": corrupt, "updated": memory.sequence + 1}; memory.dirty = true
	check(memory.save(), "Create checksummed malformed legacy record")
	var recovered := Memory.new(path); recovered.load_saved(); video.mode_memory = recovered
	check(video.open_local(legacy_uri, "previously-unopenable_LR_180.mp4") and video.geometry == 1 and video.swap_eyes
		and video.stereo_horizontal == 0 and video.stereo_vertical == 0 and video.viewing_eye == 0, "Malformed alignment recovers with VR layout and eye order intact")
	video.close_video(); origin.queue_free()
	check_persistence(video, path.path_join("persistence"))
	video.queue_free()
	await process_frame
	print("Stereo viewing lifecycle checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
