extends SceneTree
## Movie Maker: --fixed-fps 24 --write-movie <file.avi> --script <this file> -- <output dir>
## Append --stills to check the framing of all ten shots without recording a movie.
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
const Menu := preload("res://scripts/ray_menu.gd")
const FPS := 24
const PREFACE := 8
const FRAMES := 204
const VIEWS := [
	[Vector3(3.75,1.77,-2.30),46.], [Vector3(3.50,1.99,-5.18),26.],
	[Workshop.ARCH,47.], [Vector3(.55,2.15,-4.97),49.],
	[Vector3(.80,2.03,-2.0),63.], [Vector3(.10,1.55,-3.8),58.],
	[Vector3(.28,2.19,-4.97),48.], [Workshop.ARCH,44.],
	[Vector3(0,2.,-4.5),52.], [Vector3(.40,2.47,-1.72),66.]
]
var stage := Workshop.new()
var camera := Camera3D.new()
var title := Label.new()
var recipe := Label.new()

func _initialize() -> void:
	run.call_deferred()

func setup() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#fce5cf")
	environment.ambient_light_energy = .48
	root.world_3d.environment = environment
	stage.archive.directory = ""
	root.add_child(stage)
	root.add_child(camera)
	camera.position = Workshop.SEAT
	stage.align_to(Transform3D(Basis.IDENTITY,Workshop.SEAT))
	var caption := VBoxContainer.new()
	root.add_child(caption)
	caption.position = Vector2(24,15)
	caption.add_theme_constant_override("separation",0)
	for line in [title,recipe]:
		line.add_theme_font_override("font",Menu.ui_font())
		line.add_theme_font_size_override("font_size",28 if line==title else 17)
		line.add_theme_color_override("font_color",Color("#fff3d1"))
		line.add_theme_color_override("font_outline_color",Color("#211a21"))
		line.add_theme_constant_override("outline_size",5)
		caption.add_child(line)

func run() -> void:
	setup()
	var args := OS.get_cmdline_user_args()
	var folder := args[0]
	DirAccess.make_dir_recursive_absolute(folder)
	var stills := args.has("--stills")
	var chapters := FileAccess.open(folder.path_join("chapters.ffmeta"),FileAccess.WRITE)
	chapters.store_line(";FFMETADATA1")
	for id in VIEWS.size():
		var key: String = Workshop.Discovery.FORMULAS.find_key(id)
		var names := PackedStringArray()
		for letter in key: names.append(Workshop.Discovery.MATERIALS[int(letter)])
		title.text = Workshop.Discovery.EFFECTS[id]
		recipe.text = " · ".join(names)
		chapters.store_line("[CHAPTER]\nTIMEBASE=1/%d\nSTART=%d\nEND=%d\ntitle=%s"%[FPS,id*FRAMES,(id+1)*FRAMES,title.text])
		camera.look_at(VIEWS[id][0])
		camera.fov = VIEWS[id][1]
		for frame in FRAMES:
			if frame in [0,4]: stage.deposit(int(key[frame/4]))
			if frame==PREFACE:
				stage.deposit(int(key[2]))
				if stage.spell==-1:
					for ch in key: stage.deposit(int(ch))
				if stage.spell!=id:
					push_error("Recipe %s returned %d"%[key,stage.spell])
					quit(1)
					return
			stage.tick(1./FPS,stage.archive.last_ms,camera.global_transform)
			if stills and frame==PREFACE+3*FPS:
				await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_jpg(folder.path_join("room-%02d.jpg"%id),.9)
			elif not stills: await process_frame
		if stage.spell!=-2:
			push_error("Room did not return after "+key)
			quit(1)
			return
		print("Captured ",key," ",title.text)
	chapters.close()
	stage.queue_free()
	await process_frame
	quit()
