extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const ExistingTests := preload("res://tests/test_file_mode_memory.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

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
	video.queue_free()
	await process_frame
	print("Stereo viewing lifecycle checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
