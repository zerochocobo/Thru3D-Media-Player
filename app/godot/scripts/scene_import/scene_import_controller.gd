extends Node
## Imported scenes as a viewing environment. An active scene sits on top of the plain dark
## background, so the built-in scenes and their logic never see it: choosing any background
## in the scene menu simply turns the imported scene off.
const Library := preload("res://scripts/scene_import/scene_import_library.gd")
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
const Platform := preload("res://scripts/scene_import/scene_import_platform.gd")
const Motion := preload("res://scripts/scene_import/scene_import_motion.gd")
## The card that stands for a file still being copied in.
const ADDING := "adding"
const SECTION := "scene_import"
const BAKE_STEPS := [1.0, 0.5, 0.0]
const THUMBNAIL_SIZE := Vector2i(384, 216)
## A render layer of its own, so the thumbnail camera sees the scene and nothing else in the world.
const THUMBNAIL_LAYER := 1 << 19
const EYE_HEIGHT := 1.6
const FilmLight := preload("res://scripts/environments/cinema_film_light.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
## Reflected screen light, as with the built-in scenes: medium by default, then high, off, low.
const SCREEN_LIGHT_STEPS := [0.7, 1.0, 0.0, 0.35]
## Imported glTF scenes carry no light of their own once realtime lights are dropped.
const AMBIENT := 0.75
const SLOW_SAMPLE_MS := 1000
const SLOW_SETTLE := 0.35
const SLOW_COLLECT_MS := 150
var app: Node
var library := Library.new()
var active_id := ""
var pending_id := ""
var error := ""
var bake := 1.0
var _root: Node3D
var _sky: Sky
var _source := ""
var _shown := false
var _selecting := false
var _spawn := Transform3D.IDENTITY
var _thumbnails := {}
var screen_light := 0.7
var _film: Node = FilmLight.new()
var _lamp := SpotLight3D.new()
var _ambient_saved := {}
var _sampled_ms := 0
var _thrown := Color.BLACK
var _settle_due := false
var _backdrop: ShaderMaterial
var _loader: RefCounted
var _layout := {}
var motion := Motion.new()

func setup(owner: Node) -> void:
	app = owner
	Platform.configure()
	if Engine.has_singleton("QuestPlayer"): library.platform = Engine.get_singleton("QuestPlayer")
	add_child(library)
	library.load_catalog()
	library.added.connect(_added)
	add_child(motion)
	bake = clampf(float(app.settings.get_value(SECTION, "bake", 1.0)), 0.0, 1.0)
	screen_light = clampf(float(app.settings.get_value(SECTION, "screen_light", 0.7)), 0.0, 1.0)
	Unity.ensure_globals()
	add_child(_film)
	_lamp.shadow_enabled = false
	_lamp.light_specular = 0.0
	_lamp.spot_angle = 80.0
	_lamp.spot_angle_attenuation = 0.6
	_lamp.visible = false
	add_child(_lamp)
	var saved := str(app.settings.get_value(SECTION, "active", ""))
	# Back to the scene the viewer left on, when the plain background it sits on is still chosen.
	if library.entries.has(saved) and app.background.choice == "dark": activate.call_deferred(saved)

func tier() -> String:
	return Budget.LOW if app.get("low_end_gpu") else Budget.HIGH

func snapshot() -> Dictionary:
	var rows := library.rows()
	# What is happening to the scene being brought in, for its card: copying first, then each import stage.
	var stage := ""
	var fraction := -1.0
	if library.busy:
		rows.append({"id": ADDING, "title": library.adding.get_basename(), "added": int(Time.get_unix_time_from_system()) + 1, "summary": {}, "thumb": false})
		stage = "Copying file"
		fraction = library.progress()
	elif not pending_id.is_empty() and _loader:
		var state: Dictionary = _loader.progress()
		stage = str(state.stage)
		fraction = float(state.fraction)
	return {"rows": rows, "active": active_id, "pending": ADDING if library.busy else pending_id, "busy": library.busy,
		"stage": stage, "stage_progress": snappedf(fraction, 0.01) if fraction >= 0.0 else -1.0,
		"error": error if not error.is_empty() else library.error, "bake": bake, "tier": tier(), "screen_light": screen_light,
		"baked": _source == "unity" and _root != null, "movement": motion.mode, "floor_ready": motion.prepared or motion.mode == Motion.FIXED}

func add(uri: String, title: String, bytes: int = -1) -> void:
	error = ""
	library.add(uri, title, bytes)

## A picked file is in the library: go straight on to showing it, so one choice reads as one action.
func _added(id: String, fresh: bool) -> void:
	activate(id)
	if not fresh: error = "Already in My scenes"

func remove(ids: Array) -> void:
	if ids.has(active_id) or ids.has(pending_id): deactivate()
	for id in ids: _thumbnails.erase(str(id))
	library.remove(ids)

func activate(id: String) -> void:
	if not library.entries.has(id) or not pending_id.is_empty(): return
	if id == active_id and _root != null: return
	error = ""
	pending_id = id
	if app.background.choice != "dark":
		_selecting = true
		app.scenery.select("global", "dark")
		_selecting = false
	_loader = Loader.new()
	_loader.finished.connect(func(result: Dictionary) -> void: _loaded(result, id), CONNECT_ONE_SHOT)
	_loader.start(library.source_path(id), tier(), {"cache_dir": library.directory})

func _loaded(result: Dictionary, id: String) -> void:
	var wanted := pending_id == id and library.entries.has(id)
	if wanted: _loader = null
	pending_id = "" if wanted else pending_id
	if not wanted or result.has("error"):
		if result.has("root"): result.root.free()
		if wanted: error = str(result.get("error", "Scene could not be read")).left(120)
		return
	_release()
	var info: Dictionary = result.info
	_root = result.root
	_sky = info.get("sky") as Sky
	_backdrop = Unity.sky_backdrop(_sky)
	_layout = info.layout
	_source = str(info.get("source", ""))
	# The viewer's floor position lands on the scene's spawn point, facing what the spawn faces.
	var origin := (app.xr_origin as Node3D).global_transform
	var head := (app.xr_camera as Node3D).global_transform
	var ahead := -head.basis.z
	ahead.y = 0.0
	var facing := Transform3D(Basis.looking_at(ahead.normalized()) if ahead.length() > 0.2 else Basis.IDENTITY, Vector3(head.origin.x, origin.origin.y, head.origin.z))
	_spawn = (info.layout.spawn as Transform3D).orthonormalized()
	_root.transform = facing * _spawn.affine_inverse()
	_root.visible = false
	app.add_child(_root)
	if _source == "unity": Unity.set_look(_root, 1.0, bake)
	motion.attach(_root, info.stats.bounds)
	_place_screen()
	active_id = id
	app.settings.set_value(SECTION, "active", id)
	app.settings.save(app.settings_path)
	if not result.get("cached", false): library.note_summary(id, tier(), info)
	app._update_background()
	_capture_thumbnail(id)

## The scene menu chose a background: an imported scene only lives on the dark one it set itself.
func background_selected() -> void:
	if not _selecting: deactivate()

func deactivate() -> void:
	if _root == null and active_id.is_empty() and pending_id.is_empty(): return
	pending_id = ""
	_release()
	active_id = ""
	app.settings.set_value(SECTION, "active", "")
	app.settings.save(app.settings_path)
	app._update_background()

func _release() -> void:
	_ambient(false)
	_throw(Color.BLACK, Transform3D.IDENTITY, Vector2.ONE)
	motion.detach()
	if _root: _root.queue_free()
	_root = null
	_sky = null
	_backdrop = null
	_layout = {}
	_source = ""
	_shown = false

## Called by the background update with whether scenery may show right now; returns whether the scene does.
func present(allowed: bool) -> bool:
	_shown = allowed and _root != null
	if _root: _root.visible = _shown
	_ambient(_shown and _source != "unity")
	if not _shown:
		_throw(Color.BLACK, Transform3D.IDENTITY, Vector2.ONE)
		motion.suspend()
	return _shown

## A scene that names its screen gets the picture there; otherwise the ordinary screen stays in front.
func _place_screen() -> void:
	var video: Node = app.get("video")
	if video == null or app.get("photo_active") or _layout.get("source", "") not in ["marker", "sidecar"] or not _layout.get("screen") is Transform3D: return
	if video.geometry != Geometry.Geometry.FLAT or not video.has_method("set_flat_world_pose"): return
	video.set_flat_world_pose(_root.transform * (_layout.screen as Transform3D))

# Free movement, to the player, is the same thing here as in the built-in scenes: the members
# below are the ones it drives on whichever scene is showing.

## Whether there is a scene on show to move through.
func movable() -> bool:
	return _shown

## "watch" while the viewer stays put, "move" while walking or flying.
var interaction: String:
	get: return "move" if _shown and motion.moving() else "watch"

func set_interaction(value: String) -> bool:
	if not _shown: return false
	motion.set_mode(motion.resume_mode() if value == "move" else Motion.FIXED)
	return true

## Stay in place, then walk, then fly.
func cycle_movement() -> void:
	if _shown: motion.set_mode(Motion.MODES[(Motion.MODES.find(motion.mode) + 1) % Motion.MODES.size()])

func _feet() -> Vector3:
	var head := (app.xr_camera as Node3D).global_position
	return Vector3(head.x, (app.xr_origin as Node3D).global_position.y, head.z)

func poll_sticks(stick: Vector2, turn: Vector2, delta: float, _blocked: bool = false) -> bool:
	if not _shown or not motion.moving(): return false
	var before := _root.transform
	motion.poll_sticks(stick, turn, delta, (app.xr_camera as Node3D).global_transform, _feet())
	# A screen the scene placed goes with the scene.
	if not before.is_equal_approx(_root.transform): _place_screen()
	return true

func pointer_press(hand: String, origin: Vector3, direction: Vector3) -> bool:
	return _shown and motion.pointer_press(hand, origin, direction)

func pointer_release(hand: String, origin: Vector3, direction: Vector3, valid: bool) -> bool:
	if not _shown: return false
	var before := _root.transform
	var handled := motion.pointer_release(hand, origin, direction, valid, _feet())
	if not before.is_equal_approx(_root.transform): _place_screen()
	return handled

func update_pointer(hand: String, origin: Vector3, direction: Vector3, valid: bool = true) -> void:
	motion.update_pointer(hand, origin, direction, valid and _shown, (app.xr_camera as Node3D).global_position)

func cancel_pointer(hand: String) -> void:
	motion.cancel_pointer(hand)

func suspend() -> void:
	motion.suspend()

func home() -> void:
	motion.home()
	if _root: _place_screen()

func _ambient(wanted: bool) -> void:
	var display: Variant = app.get("display")
	var surroundings: Environment = display.environment if display else null
	if surroundings == null: return
	if wanted and _ambient_saved.is_empty():
		for key in ["ambient_light_source", "ambient_light_color", "ambient_light_energy"]: _ambient_saved[key] = surroundings.get(key)
		surroundings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		surroundings.ambient_light_color = Color.WHITE
		surroundings.ambient_light_energy = AMBIENT
	elif not wanted and not _ambient_saved.is_empty():
		for key in _ambient_saved: surroundings.set(key, _ambient_saved[key])
		_ambient_saved.clear()

func _process(delta: float) -> void:
	if not _shown or screen_light <= 0.0: return
	var video: Node = app.get("video")
	var playing: bool = video != null and not app.get("photo_active") and video.geometry == Geometry.Geometry.FLAT and video.has_active_presentation()
	if not playing:
		_throw(Color.BLACK, Transform3D.IDENTITY, Vector2.ONE)
		return
	# Reading a frame back from the eye buffer stalls a frame (measured: 4 samples a second cost
	# about 4 fps), so that path is sampled once a second and smoothed here. Compositor-layer
	# playback copies asynchronously and keeps the sampler's own pace.
	var binding: Variant = video.get("_binding")
	var slow: bool = binding == null or not binding.layer
	var now := Time.get_ticks_msec()
	if not slow:
		_film.update(delta, video, true, 1.0)
	elif now - _sampled_ms >= SLOW_SAMPLE_MS:
		_film.update(1.0, video, true, 1.0)
		_sampled_ms = now
		_settle_due = true
	elif _settle_due and now - _sampled_ms >= SLOW_COLLECT_MS:
		# The sample asked for above has arrived by now; take it without asking for another.
		_film.update(1.0, video, true, 1.0)
		_settle_due = false
	var target: Color = (_film.colors[0] + _film.colors[1] + _film.colors[2]) / 3.0
	_thrown = _thrown.lerp(target, 1.0 - exp(-delta / SLOW_SETTLE)) if slow else target
	_throw(_thrown * screen_light, video.global_transform * video.flat_pose, video._flat.size)

## One light for both kinds of scene: a real lamp for lit glTF materials, and the same
## position and colour handed to the unlit Unity surfaces through global uniforms.
func _throw(colour: Color, pose: Transform3D, size: Vector2) -> void:
	var lit := maxf(colour.r, maxf(colour.g, colour.b)) > 0.004
	_lamp.visible = lit
	if not lit:
		Unity.set_screen_light(Vector3.ZERO, Vector3(0, 0, 1), Vector3.ZERO, 10.0)
		return
	var normal := pose.basis.z.normalized()
	var reach := clampf(maxf(size.x, size.y) * 4.0, 8.0, 60.0)
	var spread := clampf(size.x * size.y / 6.0, 0.4, 3.0)
	_lamp.global_transform = Transform3D(Basis.looking_at(normal, pose.basis.y.normalized()), pose.origin + normal * 0.15)
	_lamp.light_color = colour
	_lamp.light_energy = 2.0 * spread
	_lamp.spot_range = reach
	# The Unity surfaces work in display space, where the same light is its square root.
	var shown := Vector3(sqrt(maxf(colour.r, 0.0)), sqrt(maxf(colour.g, 0.0)), sqrt(maxf(colour.b, 0.0))) * spread
	Unity.set_screen_light(pose.origin + normal * 0.15, normal, shown, reach)

func cycle_screen_light() -> void:
	set_screen_light(SCREEN_LIGHT_STEPS[(SCREEN_LIGHT_STEPS.find(screen_light) + 1) % SCREEN_LIGHT_STEPS.size()])

func set_screen_light(level: float) -> void:
	screen_light = clampf(level, 0.0, 1.0)
	app.settings.set_value(SECTION, "screen_light", screen_light)
	app.settings.save(app.settings_path)
	if screen_light <= 0.0: _throw(Color.BLACK, Transform3D.IDENTITY, Vector2.ONE)

func sky() -> Sky:
	return _sky if _shown else null

## The scene's sky for the display's layer backdrop; null when the display can show the sky itself.
func backdrop() -> ShaderMaterial:
	return _backdrop if _shown else null

## The picture on a scene's card; null until the scene has been shown once.
func thumbnail(id: String) -> Texture2D:
	if _thumbnails.has(id): return _thumbnails[id]
	var path: String = library.thumbnail_path(id)
	if not FileAccess.file_exists(path): return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty(): return null
	_thumbnails[id] = ImageTexture.create_from_image(image)
	return _thumbnails[id]

## Photographs the scene from where the viewer stands, the first time it is on show.
func _capture_thumbnail(id: String) -> void:
	if not _shown or DisplayServer.get_name() == "headless" or FileAccess.file_exists(library.thumbnail_path(id)): return
	var scene := _root
	for node in scene.find_children("*", "VisualInstance3D", true, false): (node as VisualInstance3D).layers |= THUMBNAIL_LAYER
	var viewport := SubViewport.new()
	viewport.size = THUMBNAIL_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var camera := Camera3D.new()
	camera.cull_mask = THUMBNAIL_LAYER
	camera.fov = 80.0
	camera.far = 4000.0
	var surroundings := Environment.new()
	if _sky:
		surroundings.background_mode = Environment.BG_SKY
		surroundings.sky = _sky
	else:
		surroundings.background_mode = Environment.BG_COLOR
		surroundings.background_color = Color(0.03, 0.03, 0.04)
	surroundings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	surroundings.ambient_light_color = Color.WHITE
	camera.environment = surroundings
	viewport.add_child(camera)
	app.add_child(viewport)
	camera.global_transform = scene.global_transform * _spawn * Transform3D(Basis.IDENTITY, Vector3(0, EYE_HEIGHT, 0))
	camera.current = true
	for frame in 3: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	if image == null or image.is_empty() or not is_instance_valid(scene) or scene != _root: return
	DirAccess.make_dir_recursive_absolute(library.thumbnail_path(id).get_base_dir())
	if image.save_jpg(library.thumbnail_path(id), 0.85) == OK: library.changed.emit()

func cycle_bake() -> void:
	set_bake(BAKE_STEPS[(BAKE_STEPS.find(bake) + 1) % BAKE_STEPS.size()])

func set_bake(strength: float) -> void:
	bake = clampf(strength, 0.0, 1.0)
	app.settings.set_value(SECTION, "bake", bake)
	app.settings.save(app.settings_path)
	if _root and _source == "unity": Unity.set_look(_root, 1.0, bake)
