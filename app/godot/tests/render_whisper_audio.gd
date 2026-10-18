extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
var state := {"has_video": true, "source_uri": "file:///whisper.mp4", "title": "Whisper",
	"geometry": 1, "stereo": true, "projection": "VR180", "playing": true,
	"audio_available": true, "volume": 37, "muted": false, "audio_whisper": 0,
	"whisper_available": true, "position_ms": 32000, "duration_ms": 180000}
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/system-volume-boost/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -0.30; menu.toggle(); menu._volume_open = true
	for language in ["en", "zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for level in [0, 1, 26, 51]:
			state.audio_whisper = level; state.volume = 100 + level - 1 if level > 1 else 37
			state.boost_saved = 35; menu.refresh()
			for target in [Menu.WHISPER, Menu.VOLUME, 109]:
				var found := false
				for button in menu._buttons:
					if button.target != target: continue
					var point: Vector3 = button.node.global_position + menu.global_basis.z * 0.3
					if target == Menu.WHISPER: check(button.rect.size.y >= 0.08, "Full-sized enhancement hit area")
					found = int(menu.ray_hit(point, -menu.global_basis.z).get("target", -1)) == target
				check(found, "Raised popup target is reachable: %s/%d/%d" % [language, level, target])
			check(menu._volume_label.text == "%d%%" % int(state.volume), "Actual continuous percentage label")
			check((menu._boost_fill != null) == (level > 0), "Yellow segment exists only when expanded")
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			check(image.save_png(output.path_join("%s-%d.png" % [language, level])) == OK, "Save visual")
	menu.free(); viewport.queue_free()
	print("Whisper visuals: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
