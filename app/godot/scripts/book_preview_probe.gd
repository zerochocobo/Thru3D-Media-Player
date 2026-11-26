extends SceneTree
## Desktop look at the reading mode without a headset or the Android plugin:
##   godot --path app/godot --xr-mode off -s res://scripts/book_preview_probe.gd -- <pages folder> <output folder>
## The pages folder holds book.json (a book_ready payload) and page-N.jpg stand-ins.
## A scripted wand points, carries a leaf across and lets go.

class Pages extends Node:
	signal book_ready(id: int, payload: String)
	signal book_page(id: int, page: int, path: String)
	signal book_found(id: int, token: int, payload: String)
	var folder := ""
	func book_open(_uri: String, _style: String) -> int:
		_ready_later.call_deferred()
		return 1
	func _ready_later() -> void:
		var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("book.json")))
		info["session"] = 1
		info["variant"] = "zh"
		book_ready.emit(1, JSON.stringify(info))
	func book_render(session: int, page: int, _edge: int) -> bool:
		book_page.emit.call_deferred(session, page, folder.path_join("page-%d.jpg" % page))
		return true
	func book_discard(_path: String) -> void: pass
	func book_close(_session: int) -> void: pass
	func book_excerpt(_session: int, _at: String) -> String: return "他说：走吧，天就要亮了。"
	func book_search(session: int, query: String, token: int) -> bool:
		var hits := []
		for i in 9: hits.append({"at": "%d/2/%d" % [mini(i, 3), i * 10], "chapter": "第%d章" % (i + 1),
			"text": "…前面的句子，%s，后面还有一些文字" % query, "mark": [7, query.length()]})
		book_found.emit.call_deferred(session, token, JSON.stringify({"hits": hits, "more": true, "query": query}))
		return true

var reader: Node3D
var camera := Camera3D.new()
var output := ""
var step := 0
var frames := 0
## Where the scripted wand points on the book, in page widths from the spine and page heights from the centre.
var target := Vector2(0.7, -0.1)
var pressed := false
var pointing := false
var side := 0.0

func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	var pages := Pages.new(); pages.folder = arguments[0]; output = arguments[1]
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(1440, 1080); DisplayServer.window_set_size(Vector2i(1440, 1080))
	var world := WorldEnvironment.new(); world.environment = Environment.new()
	var sky := ProceduralSkyMaterial.new()
	sky.sky_top_color = Color(0.015, 0.02, 0.06); sky.sky_horizon_color = Color(0.10, 0.07, 0.16)
	sky.ground_bottom_color = Color(0.01, 0.01, 0.02); sky.ground_horizon_color = Color(0.09, 0.06, 0.14); sky.sun_angle_max = 0.0
	world.environment.sky = Sky.new(); world.environment.sky.sky_material = sky
	world.environment.background_mode = Environment.BG_SKY
	root.add_child(world); root.add_child(pages)
	camera.position = Vector3(0, 1.5, 0); camera.fov = 80; root.add_child(camera)
	# An optional third argument views the tome from one side, to check what the gutter hides.
	if arguments.size() > 2: side = float(arguments[2])
	reader = preload("res://scripts/book_reader.gd").new()
	reader.platform = pages
	reader.head_provider = func() -> Variant: return camera.global_transform
	root.add_child(reader)

func _shot(name: String) -> void:
	root.get_texture().get_image().save_jpg(output.path_join(name + ".jpg"), 0.93)

func _process(delta: float) -> bool:
	frames += 1
	if pointing:
		var origin: Vector3 = camera.global_transform * Vector3(0.20, -0.20, -0.42)
		var size: Vector2 = reader.model.page_size
		var aim: Vector3 = reader.model.to_global(Vector3(target.x * size.x, target.y * size.y, 0))
		reader.aim(origin, (aim - origin).normalized(), pressed, delta)
	match step:
		0:
			if frames == 2: reader.open("file:///preview.txt", "preview.txt")
			if frames == 4: camera.rotation_degrees.x = 4.0
			if frames == 30: _shot("0_arriving")
			if frames > 120: reader.go_to(6); pointing = true; step = 1; frames = 0
		1:
			if frames == 20 and side != 0.0:
				camera.position.x = side; camera.look_at(reader.global_position)
			if frames > 40: _shot("1_tome"); pressed = true; step = 2; frames = 0
		2:
			# Carry the right-hand leaf across with the trigger held.
			target.x = lerpf(0.7, -0.75, clampf((frames - 20) / 70.0, 0.0, 1.0))
			if frames == 45: _shot("2_carry_a")
			if frames == 60: _shot("2_carry_b")
			if frames == 78: _shot("2_carry_c")
			if frames > 92: pressed = false; step = 3; frames = 0
		3:
			if frames > 50: target = Vector2(-0.5, 0.2); _shot("3_landed"); reader.bar.open(); step = 4; frames = 0
		4:
			if frames > 30: _shot("4_ring"); reader.bar.section = "look"; reader.bar.open("settings"); step = 7; frames = 0
		7:
			# Each page of the settings in turn, then back to the ring.
			var pages := ["look", "type", "font", "book", "turn", "read", "auto"]
			if frames % 10 == 9:
				_shot("7_settings_" + reader.bar.section)
				var next := pages.find(reader.bar.section) + 1
				if next < pages.size(): reader.bar.section = pages[next]; reader.bar.refresh()
				else: reader.bar.open(); step = 8; frames = 0
		8:
			if frames > 10: step = 9; frames = 0
		9:
			# Point the wand along the rim, three fifths of the way round, then leap there.
			var angle := 0.6 * TAU
			var spot: Vector3 = reader.bar.global_transform * (Vector3(sin(angle), cos(angle), 0) * reader.bar.RIM_RADIUS)
			var from: Vector3 = camera.global_transform * Vector3(0.20, -0.20, -0.42)
			reader.bar.update_pointer("right_hand", from, (spot - from).normalized(), true)
			if frames == 10: _shot("4_rim")
			if frames == 12: reader.bar.press_pointer("right_hand", from, (spot - from).normalized(), true); step = 10; frames = 0
		10:
			if frames == 8: _shot("4_riffle")
			if frames > 60: _shot("4_leapt"); reader.bar.open(); step = 11; frames = 0
		11:
			if frames > 20: _shot("4_return"); reader.bar.open("contents"); step = 6; frames = 0
		6:
			if frames > 12: _shot("4_contents"); reader.bar.dismiss(); reader.toggle_mark(); step = 12; frames = 0
		12:
			if frames > 12: _shot("6_marked"); reader.bar.open("marks"); step = 13; frames = 0
		13:
			if frames > 12: _shot("6_marks"); reader.bar.open("search"); reader.bar.editor.cancel(); reader.bar.query = "天亮"; reader.bar._run_search(); step = 14; frames = 0
		14:
			if frames > 12: _shot("6_search"); reader.bar.dismiss(); reader.set_night(true); reader.set_warmth(3); step = 5; frames = 0
		5:
			if frames > 50: _shot("5_night"); return true
	return false
