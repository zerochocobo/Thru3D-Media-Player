extends SceneTree
## Desktop look at an imported scene: godot --path app/godot --script res://tests/render_scene_import.gd -- <scene> [tier] [capped|uncapped] [exposure bake_strength]
## Writes views from the spawn point and from above to build/output/scene-import/render.
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/scene-import/render")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <scene> [low|high] [uncapped]")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(output)
	Unity.unpacker_executable = ProjectSettings.globalize_path("res://../../build/unity-scene/windows/unity_scene_unpack.exe")
	var tier: String = args[1] if args.size() > 1 else Budget.HIGH
	var suffix := "_%s_%s" % [tier, "_".join(args.slice(2))] if args.size() > 2 else "_%s" % tier
	var options := {"use_cache": false, "cache_dir": output.path_join("work")}
	if args.size() > 2 and args[2] == "uncapped":
		var limits := Budget.limits(tier).duplicate()
		limits.triangles = 100000000
		limits.batches = 100000
		options.limits = limits
	var started := Time.get_ticks_msec()
	var result := Loader.new().load_scene(args[0], tier, options)
	if result.has("error"):
		push_error(result.error)
		quit(1)
		return
	var info: Dictionary = result.info
	print("Loaded in %d ms: %d meshes, %d triangles, %d batches, layout %s" % [Time.get_ticks_msec() - started, info.stats.meshes, info.stats.triangles, info.stats.batches, info.layout.source])
	root.add_child(result.root)
	if args.size() > 4: Unity.set_look(result.root, float(args[3]), float(args[4]))
	var environment := Environment.new()
	if info.get("sky") is Sky:
		environment.background_mode = Environment.BG_SKY
		environment.sky = info.sky
	else:
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(0.05, 0.05, 0.07)
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color.WHITE
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)
	var camera := Camera3D.new()
	camera.far = 4000.0
	root.add_child(camera)
	camera.make_current()
	var spawn: Transform3D = info.layout.spawn
	var bounds: AABB = info.stats.bounds
	var eye := spawn.origin + Vector3.UP * 1.6
	if OS.get_environment("THRU3D_SCENE_LIGHT") != "":
		# A warm screen a few metres ahead of the viewer, to see what reflected light does.
		var screen := Transform3D(spawn.basis, eye - spawn.basis.z * 5.0 + Vector3.UP * 0.6)
		Unity.set_screen_light(screen.origin, screen.basis.z, Vector3(1.0, 0.62, 0.3), 30.0)
		var lamp := SpotLight3D.new()
		lamp.shadow_enabled = false
		lamp.spot_angle = 80.0
		lamp.spot_range = 30.0
		lamp.light_color = Color(1.0, 0.38, 0.09)
		lamp.light_energy = 3.0
		root.add_child(lamp)
		lamp.global_transform = Transform3D(Basis.looking_at(screen.basis.z, Vector3.UP), screen.origin)
		suffix += "_light"
		environment.ambient_light_energy = 0.75
	var views := {
		"spawn_forward": [eye, eye - spawn.basis.z],
		"spawn_back": [eye, eye + spawn.basis.z],
		"spawn_left": [eye, eye - spawn.basis.x],
		"spawn_up": [eye, eye - spawn.basis.z + Vector3.UP * 0.8],
		"overview": [bounds.get_center() + Vector3(0.55, 0.45, 0.7) * bounds.size.length() * 0.75, bounds.get_center()],
	}
	for name in views:
		camera.look_at_from_position(views[name][0], views[name][1], Vector3.UP)
		for frame in 4: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("%s%s.png" % [name, suffix]))
	print("Rendered %d views" % views.size())
	quit(0)
