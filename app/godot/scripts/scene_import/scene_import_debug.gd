extends Node
## Debug-only bench hook (operation "scene_import"): shows a user scene file in place of the
## background so import time and frame cost can be measured on a headset. Nothing here is
## reachable from the menus. It never selects a background itself (selecting one makes the
## built-in scenes save their state): the bench sets a plain background before launching.
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
const Platform := preload("res://scripts/scene_import/scene_import_platform.gd")
var _host: Node
var _root: Node3D
var _busy := false

func run(host: Node, command: Dictionary) -> void:
	_host = host
	var label := str(command.get("label", "scene")).validate_filename()
	match str(command.get("action", "load")):
		"clear":
			_clear()
			_report(label, {"cleared": true})
		"cycle":
			if not _busy: _cycle(label, command)
		"library":
			_library(label, command)
		"look":
			if _root: Unity.set_look(_root, float(command.get("exposure", 1.0)), float(command.get("bake", 1.0)))
			_report(label, {"look": _root != null})
		_:
			if _busy: return
			_busy = true
			Platform.configure()
			var tier := str(command.get("tier", Budget.LOW if host.get("low_end_gpu") else Budget.HIGH))
			var loader := Loader.new()
			var started := Time.get_ticks_msec()
			loader.finished.connect(func(result: Dictionary) -> void: _loaded(result, label, tier, started))
			loader.start(str(command.get("path", "")), tier, {"use_cache": command.get("cache", true) == true})

## Drives the viewer-facing scene library the way the menu does: step = add | use | off | remove | state.
func _library(label: String, command: Dictionary) -> void:
	var scenes: Node = _host.get("scene_import")
	if scenes == null:
		_report(label, {"error": "scene library is off"})
		return
	var wanted := str(command.get("title", ""))
	var id := ""
	for row in scenes.library.rows():
		if str(row.title) == wanted: id = str(row.id)
	match str(command.get("step", "state")):
		"add": scenes.add(str(command.get("uri", "")), str(command.get("name", "")))
		"use": scenes.activate(id)
		"off": scenes.deactivate()
		"light":
			while not is_equal_approx(scenes.screen_light, float(command.get("level", 0.7))): scenes.cycle_screen_light()
		"remove": scenes.remove([id])
	# Let a copy or a load finish before reporting, within a bound.
	var deadline := Time.get_ticks_msec() + int(command.get("wait_ms", 120000))
	await get_tree().process_frame
	while (scenes.library.busy or not str(scenes.pending_id).is_empty()) and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	for frame in 5: await get_tree().process_frame
	var state: Dictionary = scenes.snapshot()
	state["memory"] = _memory()
	state["background"] = str(_host.background.choice)
	state["natives"] = {"unity": Unity.unpacker.is_valid(), "etc2": Loader.texture_encoder.is_valid()}
	_report(label, state)

func _clear() -> void:
	if _root:
		_root.queue_free()
		_root = null
		_host._update_background()

static func _memory() -> Dictionary:
	return {"video": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)), "texture": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		"static": OS.get_static_memory_usage(), "objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)), "resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))}

## Loads and frees one scene repeatedly to see which load path gives memory back.
## mode: "import" (worker, no cache), "async" (cached, engine loader), "sync" (cached, main thread).
func _cycle(label: String, command: Dictionary) -> void:
	_busy = true
	_clear()
	var path := str(command.get("path", ""))
	var tier := str(command.get("tier", Budget.HIGH))
	var mode := str(command.get("mode", "async"))
	var rows := [{"phase": "start", "memory": _memory()}]
	for round in clampi(int(command.get("rounds", 4)), 1, 12):
		var result: Dictionary
		if mode == "sync":
			result = Loader.new().load_scene(path, tier, {})
		else:
			var loader := Loader.new()
			loader.start(path, tier, {"use_cache": mode == "async"})
			result = await loader.finished
		if result.has("error"):
			rows.append({"phase": "error", "error": result.error})
			break
		var scene: Node3D = result.root
		var cached: bool = result.cached
		result = {}
		_host.add_child(scene)
		for frame in 5: await get_tree().process_frame
		var held := _memory()
		scene.queue_free()
		scene = null
		for frame in 10: await get_tree().process_frame
		rows.append({"phase": "round %d" % round, "cached": cached, "held": held, "freed": _memory()})
	_busy = false
	_report(label, {"mode": mode, "rows": rows})

func _loaded(result: Dictionary, label: String, tier: String, started: int) -> void:
	_busy = false
	var load_ms := Time.get_ticks_msec() - started
	if result.has("error"):
		_report(label, {"error": result.error, "load_ms": load_ms, "tier": tier})
		return
	_clear()
	var attach := Time.get_ticks_msec()
	var info: Dictionary = result.info
	_root = result.root
	# The viewer's floor origin lands on the scene's spawn point, and whatever the spawn faces
	# is turned to where the headset points now (it may be lying on a desk).
	var origin := (_host.xr_origin as Node3D).global_transform
	var head := (_host.xr_camera as Node3D).global_transform
	var ahead := -head.basis.z
	ahead.y = 0.0
	var facing := Transform3D(Basis.looking_at(ahead.normalized()) if ahead.length() > 0.2 else Basis.IDENTITY, Vector3(head.origin.x, origin.origin.y, head.origin.z))
	_root.transform = facing * (info.layout.spawn as Transform3D).orthonormalized().affine_inverse()
	_host.add_child(_root)
	if info.get("sky") is Sky: _host.display.set_scenery(info.sky, 0.0)
	for frame in 3: await get_tree().process_frame
	var probe := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var stats: Dictionary = info.stats
	_report(label, {"tier": tier, "cached": result.cached, "source": info.get("source", ""), "load_ms": load_ms,
		"attach_ms": Time.get_ticks_msec() - attach, "meshes": stats.meshes, "triangles": stats.triangles, "batches": stats.batches,
		"texture_bytes": stats.texture_bytes, "textures": stats.textures, "largest_texture": stats.largest_texture,
		"actions": info.actions, "over_budget": info.over_budget, "layout": info.layout.source, "warnings": info.get("warnings", []),
		"video_memory": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		"texture_memory": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		"static_memory": OS.get_static_memory_usage(),
		# Whether decoded glTF textures could be GPU-compressed on this device at import time.
		"etc2_compress": error_string(probe.compress(Image.COMPRESS_ETC2))})

func _report(label: String, report: Dictionary) -> void:
	report.label = label
	print("[SCENE_IMPORT] ", JSON.stringify(report))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open("user://diagnostics/scene_import_%s.json" % label, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report))
