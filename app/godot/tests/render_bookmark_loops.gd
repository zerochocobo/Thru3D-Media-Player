extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/bookmark-loops/single-page")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 1250); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 56; viewport.add_child(camera)
	var markers := [{"id": "a", "position_ms": 600000}, {"id": "inside", "position_ms": 1200000}, {"id": "b", "position_ms": 1800000}, {"id": "c", "position_ms": 3600000}, {"id": "d", "position_ms": 5400000}]
	var segments := [{"id": "one", "a": "a", "b": "b", "a_ms": 600000, "b_ms": 1800000}, {"id": "two", "a": "c", "b": "d", "a_ms": 3600000, "b_ms": 5400000}]
	var state := {"has_video": true, "playing": true, "title": "Sample.mp4", "duration_ms": 7200000, "position_ms": 1200000,
		"bookmark_scope": "render", "bookmarks": markers, "bookmark_ready": true, "bookmark_seekable": true,
		"bookmark_revision": 1, "bookmark_loops": segments, "bookmark_loop": segments[0], "bookmark_loop_active": true}
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		var menu := Menu.new(); menu.state_provider = func(): return state
		camera.add_child(menu); menu.toggle(); menu.set_process(false)
		for mode in ["active", "hover", "wide", "disabled", "seeking", "bookmarks", "create", "edit", "picker", "shared", "dense", "empty", "paged"]:
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
			menu.bookmarks.reset()
			state.bookmark_loop_active = mode not in ["disabled", "empty"]
			state.bookmarks = markers
			state.seek_feedback = {"origin_ms": 1200000, "target_ms": 600000, "delta_ms": -600000, "alpha": 1.0, "phase": "waiting"} if mode == "seeking" else {}
			state.bookmark_loop = segments[1] if mode == "wide" else segments[0]
			state.bookmark_loops = [] if mode == "empty" else segments
			if mode not in ["active", "hover", "wide", "disabled", "dense", "seeking"]: menu.bookmarks.opened = true
			if mode == "create": menu.bookmarks.editing = {"id": "", "a": "", "b": ""}; menu.bookmarks.picker = "a"
			if mode == "shared":
				state.bookmark_loops = [segments[0], {"id": "adjacent", "a": "b", "b": "d", "a_ms": 1800000, "b_ms": 5400000}]
				if mode == "shared": menu.bookmarks.subset = ["b"]
			if mode == "dense":
				state.bookmarks = [{"id": "a", "position_ms": 3740000}, {"id": "b", "position_ms": 3845000}, {"id": "c", "position_ms": 4420000}]
				state.bookmark_loops = [{"id": "one", "a": "a", "b": "b", "a_ms": 3740000, "b_ms": 3845000}, {"id": "two", "a": "b", "b": "c", "a_ms": 3845000, "b_ms": 4420000}]
				state.bookmark_loop = state.bookmark_loops[0]
			if mode == "edit": menu.bookmarks.editing = segments[0].duplicate(true); menu.bookmarks.picker = "b"
			if mode == "picker": menu.bookmarks.editing = {"id": "", "a": "inside", "b": ""}; menu.bookmarks.picker = "b"
			if mode == "paged":
				state.bookmarks = []; state.bookmark_loops = []
				for index in 14: state.bookmarks.append({"id": str(index), "position_ms": 300000 * (index + 1)})
				for index in 7: state.bookmark_loops.append({"id": "loop" + str(index), "a": str(index * 2), "b": str(index * 2 + 1), "a_ms": 300000 * (index * 2 + 1), "b_ms": 300000 * (index * 2 + 2)})
				menu.bookmarks.editing = state.bookmark_loops[2].duplicate(true); menu.bookmarks.picker = "b"
				menu.bookmarks.offset = 9; menu.bookmarks.loop_offset = 2
			# Frame the actual UI in the rendering camera, without cropping screenshots.
			var bar_only: bool = mode in ["active", "hover", "wide", "disabled", "dense", "seeking"]
			viewport.size = Vector2i(1400, 760 if bar_only else 1250)
			camera.fov = 28 if bar_only else 56
			menu.position.y = 0.04 if bar_only else -0.13
			menu.refresh()
			if mode == "hover":
				var band: Dictionary = menu._buttons.filter(func(button): return button.node.get_meta("bookmark_loop_id", "") == "two")[0]
				var pointer_origin: Vector3 = menu.to_global(Vector3(band.rect.get_center().x, band.rect.get_center().y, 1))
				menu.update_pointer("right_hand", pointer_origin, -menu.global_basis.z, true)
			for frame in 8:
				await process_frame; await RenderingServer.frame_post_draw
			for button in menu._buttons:
				if not menu.bookmarks._belongs(int(button.target)): continue
				var label: Label3D = button.node.get_child(0)
				if not label.text.is_empty():
					var width: float = label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
					check(width <= button.rect.size.x - 0.012, language + "/" + mode + " text exceeds button: " + label.text)
			var seek: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.SEEK)[0]
			var point := menu.to_global(Vector3(seek.rect.get_center().x, seek.rect.get_center().y, 1))
			check(menu.ray_hit(point, -menu.global_basis.z).get("target") == Menu.SEEK, language + "/" + mode + " range cannot cover slider")
			var frame_image := viewport.get_texture().get_image()
			var visible_pixels := 0
			for x in range(0, frame_image.get_width(), 20):
				for y in range(0, frame_image.get_height(), 20):
					var pixel := frame_image.get_pixel(x, y)
					if pixel.r + pixel.g + pixel.b > 0.8: visible_pixels += 1
			check(visible_pixels > 20, language + "/" + mode + " must contain rendered controls")
			frame_image.save_png(output.path_join(language + "-" + mode + ".png"))
		menu.free()
	viewport.free()
	print("Bookmark loops render: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
