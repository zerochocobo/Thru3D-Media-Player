extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const HostTest := preload("res://tests/test_file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/filename-passthrough/" + str(Time.get_ticks_usec()))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

func layout(video: Node3D) -> Array:
	return [video.geometry, video.stereo_sbs, video.top_bottom, video.stereo_half, video.fisheye_fov, video.swap_eyes]

func open(video: Node3D, name: String) -> void:
	check(video.open_local("file:///" + name, name), "Open " + name)
	video.media.format = {"width": 8192, "height": 4096}
	video._complete_layout()

func choose(menu: Node3D, value: bool) -> bool:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("key") != "alpha_auto_from_filename" or item.get("kind") != "choose" or item.value != value: continue
		for button in menu._buttons:
			if button.target != target: continue
			var point: Vector3 = button.node.global_position + menu.global_basis.z
			if not menu.press_pointer("right_hand", point, -menu.global_basis.z, true): return false
			menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
			return true
	return false

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var video := Video.new()
	video.mode_memory = Memory.new(output.path_join("modes"))
	root.add_child(video); video.set_process(false)
	var host := HostTest.Host.new(); video.platform = host; video.history_enabled = false
	check(video.auto_passthrough_from_filename, "Missing global choice defaults on")
	for name in ["clip_180_SBS_alpha.mp4", "clip_360_TB_passthrough.mp4", "clip_flat_ALPHA.mp4", "clip_FISHEYE190_LR_alpha.mp4"]:
		video.auto_passthrough_from_filename = true
		open(video, name)
		var original := layout(video)
		check(video.alpha_wanted(), "Default keeps existing opt-in: " + name)
		video.auto_passthrough_from_filename = false
		open(video, name)
		check(not video.alpha_wanted() and not host.calls.back()[4], "Disabled opens without AI or packed Alpha: " + name)
		check(layout(video) == original, "Disabling passthrough retains format: " + name)
		video._remember_mode(false)
		if video.packed_file:
			check(video.mode_memory.lookup(video.local_uri).packed_mask, "Passive save preserves the suppressed packed choice")
		video.auto_passthrough_from_filename = true
		open(video, name)
		check(video.alpha_wanted(), "Re-enabling restores original opt-in: " + name)
	video.auto_passthrough_from_filename = false
	open(video, "manual_180_SBS_passthrough.mp4")
	check(video.set_alpha(true) and video.alpha_requested, "Manual AI remains available")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 1234, true)
	check(video.alpha_requested and host.calls.back()[4], "Context recovery retains manual AI")
	video._reopen_at(2345, false)
	check(video.alpha_requested and host.calls.back()[4], "Render-path recovery retains manual AI")
	open(video, "manual_180_SBS_passthrough.mp4")
	check(not video.alpha_wanted(), "Opening again does not inherit manual AI")
	open(video, "unmarked.mp4")
	check(not video.alpha_wanted(), "Another file starts without passthrough")
	# A basename can differ from the displayed title, as on media servers.
	check(video.open_local("file:///renamed.mp4", "Display title", 0, true, false, "clip_FISHEYE190_LR_alpha.mp4"), "Open packed source by basename")
	check(video.packed_file and not video.packed_mask_on(), "Source identity survives suppressed startup")
	video._remember_mode(false)
	video.auto_passthrough_from_filename = true # Applies only to the next new open.
	video._reopen_at(1000, false)
	check(video.packed_file and not video.alpha_wanted() and not host.calls.back()[4], "Changing preference then recovering keeps current mask off")
	video._remember_mode(false)
	check(video.mode_memory.lookup(video.local_uri).packed_mask, "Recovery does not overwrite suppressed preference")
	check(video.set_alpha(true) and video.packed_mask_on() and not video.alpha_requested, "Toolbar enables the source mask without AI")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 1000, true)
	check(video.packed_mask_on() and not video.alpha_requested and not host.calls.back()[4], "Renamed packed mask remains a mask after context recovery")
	video._reopen_at(2000, false)
	check(video.packed_mask_on() and not host.calls.back()[4], "Renamed packed mask remains a mask after render recovery")
	video.auto_passthrough_from_filename = false
	open(video, "renamed.mp4")
	check(video.packed_file and not video.alpha_wanted(), "Old saved mask cannot bypass disabled startup")
	video.set_packed_mask(true)
	check(video.packed_mask_on() and not video.alpha_requested, "Fisheye mode mask action still works")
	video.set_packed_mask(false)
	check(not video.packed_file and not video.mode_memory.lookup(video.local_uri).packed_mask, "Explicit mask off updates its own preference")
	video.auto_passthrough_from_filename = true
	open(video, "renamed.mp4")
	check(not video.alpha_wanted(), "Explicit mask off survives automatic opt-in being re-enabled")
	# Late USB identity restoration must use the policy from this open, not a later toggle.
	video.auto_passthrough_from_filename = false
	video.open_local("usb://mount/late", "clip_FISHEYE190_LR_alpha.mp4")
	var saved := {"geometry": 2, "stereo_sbs": true, "swap_eyes": false, "alpha_requested": false, "profile": "320x320", "packed_mask": true}
	var identity := "usb://stable/" + "a".repeat(64) + "/late"
	check(video.mode_memory.remember(identity, saved), "Seed a prior USB packed preference")
	video.auto_passthrough_from_filename = true
	video._restore_usb_mode(identity)
	check(video.packed_file and not video.alpha_wanted(), "Late identity cannot activate a suppressed mask")
	check(video.mode_memory.lookup(video.local_uri).get("packed_mask", false), "Late identity retains original packed preference")
	video.set_packed_mask(true)
	check(video.packed_mask_on(), "Manual mask works after USB identity restoration")
	video.auto_passthrough_from_filename = false
	open(video, "leave_FISHEYE190_LR_alpha.mp4")
	video.set_projection(0)
	check(not video.mode_memory.lookup(video.local_uri).packed_mask, "Explicitly leaving fisheye clears its mask preference")
	video.free()
	await test_settings()
	print("Filename passthrough checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func test_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "zh")
	var path := output.path_join("settings.cfg"); config.save(path)
	var main := Main.new(); main.settings_path = path; root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	check(main.video.auto_passthrough_from_filename and main._library_settings().alpha_auto_from_filename, "Old config retains enabled default")
	main.video.alpha_requested = true
	var menu: Node3D = main.recent_menu
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.VIDEO_TAB; menu.visible = true; menu.refresh()
	var index := -1
	for i in menu.rows.size():
		if menu.rows[i].get("key") == "alpha_auto_from_filename": index = i
	check(index >= 0 and menu.rows[index + 1].get("key") == "alpha_keep_background", "Choice sits directly above background retention")
	if index >= 0:
		menu._set_scroll(float(index))
		check(choose(menu, false), "Ray press/release can disable the global choice")
	check(not main.video.auto_passthrough_from_filename and main.video.alpha_requested, "Global change leaves the current effect running")
	config.load(path)
	check(not config.get_value("alpha", "auto_from_filename", true), "Choice persists to disk")
	check(config.get_value("appearance", "background", "") == "dark" and not config.has_section_key("alpha", "keep_background"), "Background preferences stay intact")
	for language in ["zh", "zh_Hant", "en", "ja"]:
		menu.I18n.use(language); menu.refresh(); menu._set_scroll(float(index))
		var tip: String = menu.I18n.t(Menu.AUTO_PASSTHROUGH_HINT)
		check(not tip.is_empty() and (language == "en" or tip != Menu.AUTO_PASSTHROUGH_HINT), "Localized tooltip: " + language)
		check(menu._tips.values().has(tip), "Ray-hover tooltip is reachable: " + language)
		check(str(menu.rows[index].get("hint", "")).is_empty(), "No permanent explanatory text: " + language)
	main.free(); await process_frame
	var restored := Main.new(); restored.settings_path = path; root.add_child(restored)
	restored.set_process(false); restored.video.set_process(false); restored.photo.set_process(false); restored.report_timer.stop()
	check(not restored.video.auto_passthrough_from_filename and not restored._library_settings().alpha_auto_from_filename, "Fresh player reloads the disabled choice")
	restored._on_setting_changed("alpha_auto_from_filename", true)
	check(restored.video.auto_passthrough_from_filename, "User can re-enable automatic passthrough")
	restored.free(); await process_frame
