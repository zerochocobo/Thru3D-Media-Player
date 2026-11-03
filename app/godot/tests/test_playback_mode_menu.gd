extends SceneTree
## Real cycle actions from both hand rays keep the settings and transport in place.
const Player := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
var state := {"has_video": true, "playing": true, "playback_state": "playing", "source_uri": "file:///mode-menu.mp4",
	"duration_ms": 600000, "position_ms": 50000, "geometry": 0, "volume": 80, "audio_available": true}

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func mode_button(menu: Node3D) -> Dictionary:
	return menu._buttons.filter(func(b): return b.target == Player.SETTINGS_TILE + Player.OPERATIONS[1].find("loop"))[0]

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-auto-3d-20261103")
	DirAccess.make_dir_recursive_absolute(output)
	var main := Main.new(); var video := Video.new(); main.video = video
	main.settings_path = output.path_join("playback-mode.cfg")
	var events: Array = []
	for layout in ["local", "viewer", "cinema"]:
		var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.7, 0))
		var menu := Player.new(); root.add_child(menu); menu.set_process(false)
		menu.layout_head_provider = func(): return head
		menu.state_provider = func():
			var result := state.duplicate(); result.playback_mode = main.playback_mode; return result
		menu.action_requested.connect(func(operation): events.append(operation); main._on_menu_action(operation))
		menu.global_position = head.origin + Vector3(0, -0.45, -1.4)
		if layout != "local": menu.set_layout_viewer(head)
		menu.set_cinema_world_anchor(layout == "cinema"); menu.toggle()
		for language in ["zh", "zh_Hant", "en", "ja"]:
			I18n.use(language)
			for stereo in [false, true]:
				state.stereo = stereo
				for hand in ["left_hand", "right_hand"]:
					var origin := head.origin + Vector3(-0.22 if hand == "left_hand" else 0.22, -0.5, -0.3)
					for value in Main.PLAYBACK_MODES:
						for fraction in [0.15, 0.5, 0.85]:
							var name := str([layout, language, stereo, hand, value, fraction])
							main.playback_mode = value; menu._reset_navigation(); menu.section = 1; menu.refresh()
							var button := mode_button(menu)
							var mode_position: Vector3 = button.node.global_position
							var transport: Vector3 = menu._buttons.filter(func(b): return b.target == 102)[0].node.global_position
							check(menu.choices.targets.values().all(func(c): return c.get("key") != "playback_mode"), "No playback-mode select remains: " + name)
							check(menu._tips.get(button.target) == I18n.t(Player.PLAYBACK_MODE_TIPS[value]), "Tooltip explains only the current mode: " + name)
							var point: Vector3 = button.node.to_global(Vector3((fraction - 0.5) * button.rect.size.x, 0, 0))
							var direction: Vector3 = (point - origin).normalized()
							check(menu.ray_hit(origin, direction).get("target") == button.target, "Mode icon and tile have an unobstructed ray target: " + name)
							var before := events.size()
							menu.press_pointer(hand, origin, direction, true); menu.release_pointer(hand, origin, direction, true)
							var expected: String = Main.PLAYBACK_MODES[(Main.PLAYBACK_MODES.find(value) + 1) % Main.PLAYBACK_MODES.size()]
							check(events.size() == before + 1 and main.playback_mode == expected and video.loop_enabled == (expected == "repeat_one"), "One trigger click advances exactly one mode: " + name)
							check(menu.choices.opened.is_empty() and menu.section == 1 and mode_button(menu).node.global_position.is_equal_approx(mode_position)
								and menu._buttons.filter(func(b): return b.target == 102)[0].node.global_position.is_equal_approx(transport), "Cycling never raises settings or transport: " + name)
		# Cast sessions retain their existing two-mode policy and do not rewrite the global default.
		state.cast = {"seek": true}; video.cast_token = 1; video.cast_capability_cache = {"seek": true}
		main.playback_mode = "single"; menu.section = 1; menu.refresh()
		for expected in ["repeat_one", "single"]:
			menu._activate(mode_button(menu).target)
			check(main.playback_mode == expected and menu.choices.opened.is_empty(), "Seekable cast cycles only single and repeat-one")
		state.cast.seek = false; video.cast_capability_cache.seek = false; menu.refresh()
		check(not menu._enabled("loop") and menu._buttons.all(func(b): return b.target != Player.SETTINGS_TILE + Player.OPERATIONS[1].find("loop")), "Non-seekable cast retains its unavailable mode control")
		state.erase("cast"); video.cast_token = 0; menu.free()
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("video", "playback_mode", "missing") == "single", "Normal click cycle persists its selected mode")
	video.free(); main.free(); I18n.use("en")
	for failure in failures: push_error(failure)
	print("Playback mode cycle: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
