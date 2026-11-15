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
const Panorama := preload("res://scripts/app_background.gd")
## The card that stands for a file still being copied in.
const ADDING := "adding"
const SECTION := "scene_import"
const BAKE_STEPS := [1.0, 0.5, 0.0]
const THUMBNAIL_SIZE := Vector2i(384, 216)
## A render layer of its own, so the thumbnail camera sees the scene and nothing else in the world.
const THUMBNAIL_LAYER := 1 << 19
const EYE_HEIGHT := 1.6
## Watching in place takes one of these; each is an eye height above the level the viewer is on.
const POSTURES := ["stand", "sit", "lie"]
const BODY_HEIGHT_KEY := "body_height"
## Centimetres: the range of the setting and its default.
const BODY_HEIGHT := Vector3(140, 200, 170)
## A head this low above the floor is a headset that is not tracking yet.
const TRACKED_HEAD := 0.2
const FilmLight := preload("res://scripts/environments/cinema_film_light.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
## Reflected screen light, as with the built-in scenes: medium by default, then high, off, low.
const SCREEN_LIGHT_STEPS := [0.7, 1.0, 0.0, 0.35]
## Imported glTF scenes carry no light of their own once realtime lights are dropped.
const AMBIENT := 0.75
const SLOW_SAMPLE_MS := 1000
const SLOW_SETTLE := 0.35
const SLOW_COLLECT_MS := 150
## How long the scene takes to dim for a film and come back, and how often the fade is applied.
const DIM_SECONDS := 0.8
const DIM_APPLY_SECONDS := 0.1
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
## Counts card pictures taken, so the menu notices one that replaced another.
var _shots := 0
var screen_light := 0.7
## The scene's brightness while a film plays, as a share of its own; 1 leaves it alone.
var play_dim := 1.0
var _dimmed := 1.0
var _dim_wait := 0.0
var _sky_tint: Variant
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
## Loads the panorama a viewer puts behind a scene that came without a sky.
var _panorama: Node = Panorama.new()
var posture := "stand"
var body_height := BODY_HEIGHT.z
## How far the scene is raised from where its level meets the real floor.
var _raised := 0.0
var _calibrated := false

func setup(owner: Node) -> void:
	app = owner
	Platform.configure()
	if Engine.has_singleton("QuestPlayer"): library.platform = Engine.get_singleton("QuestPlayer")
	add_child(library)
	library.load_catalog()
	library.added.connect(_added)
	add_child(motion)
	_panorama.choice = "dark"
	add_child(_panorama)
	_panorama.changed.connect(func() -> void:
		if _root and not _panorama.loading: app._update_background())
	bake = clampf(float(app.settings.get_value(SECTION, "bake", 1.0)), 0.0, 1.0)
	screen_light = clampf(float(app.settings.get_value(SECTION, "screen_light", 0.7)), 0.0, 1.0)
	play_dim = clampf(float(app.settings.get_value(SECTION, "play_dim", 1.0)), 0.05, 1.0)
	body_height = clampf(float(app.settings.get_value(SECTION, BODY_HEIGHT_KEY, BODY_HEIGHT.z)), BODY_HEIGHT.x, BODY_HEIGHT.y)
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
		"baked": _source == "unity" and _root != null, "movement": motion.mode, "posture": posture, "play_dim": play_dim, "own_sky": _sky != null, "backdrop": library.backdrop(active_id), "shots": _shots, "floor_ready": motion.prepared or motion.mode == Motion.FIXED}

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
	# A place the viewer picked for this scene comes before the one the scene or its layout gives.
	var chosen: Variant = library.entry(id)
	_spawn = chosen if chosen is Transform3D else (info.layout.spawn as Transform3D).orthonormalized()
	_root.transform = facing * _spawn.affine_inverse()
	_root.visible = false
	app.add_child(_root)
	_sky_tint = (_sky.sky_material as ShaderMaterial).get_shader_parameter("tint") if _sky and _sky.sky_material is ShaderMaterial else null
	if _source == "unity": Unity.set_look(_root, 1.0, bake)
	motion.attach(_root, info.stats.bounds)
	_enter_pose(id)
	_load_backdrop(library.backdrop(id) if _sky == null else "")
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
	# The sky and the panorama outlive the scene: hand them back at full brightness.
	_dimmed = 1.0
	_apply_dim()
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
	_raised = 0.0

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

## What the viewer is doing in the scene: a posture while watching, else the way of moving.
func stance() -> String:
	return motion.mode if motion.moving() else posture

## Picks one of the five: stand, sit or lie stops where the viewer is; walk and fly start moving.
func set_stance(value: String) -> void:
	if not _shown: return
	if value in POSTURES:
		posture = value
		motion.set_mode(Motion.FIXED)
		_settle()
	elif value in [Motion.WALK, Motion.FLY]: motion.set_mode(value)

## Eye height above the level the viewer is on, from their body height.
func eye_height(pose: String = posture) -> float:
	var standing := body_height / 100.0 - 0.1
	return 0.4 if pose == "lie" else standing * 0.6875 if pose == "sit" else standing

func set_body_height(centimetres: float) -> void:
	body_height = clampf(centimetres, BODY_HEIGHT.x, BODY_HEIGHT.y)
	app.settings.set_value(SECTION, BODY_HEIGHT_KEY, body_height)
	app.settings.save(app.settings_path)
	if _root: _settle()

## Puts the eyes at the posture's height whatever the viewer's real posture is: the scene is raised
## by the difference between the real head height and the wanted one. Measured when called; real
## movement afterwards is followed as usual.
func _settle() -> void:
	if _root == null: return
	var head := (app.xr_camera as Node3D).global_position.y - (app.xr_origin as Node3D).global_position.y
	_calibrated = head >= TRACKED_HEAD
	var wanted := (head if _calibrated else eye_height("stand")) - eye_height()
	_root.global_position.y += wanted - _raised
	_raised = wanted
	_place_screen()

## The posture a scene is entered with: the one saved with its entry point, else standing.
func _enter_pose(id: String) -> void:
	posture = POSTURES[library.entry_pose(id) % POSTURES.size()]
	_raised = 0.0
	_settle()

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
	if not before.is_equal_approx(_root.transform):
		# A landing puts the new spot at the real floor; the posture's height is taken again from there.
		_raised = 0.0
		_settle()
	return handled

func update_pointer(hand: String, origin: Vector3, direction: Vector3, valid: bool = true) -> void:
	motion.update_pointer(hand, origin, direction, valid and _shown, (app.xr_camera as Node3D).global_position)

func cancel_pointer(hand: String) -> void:
	motion.cancel_pointer(hand)

func suspend() -> void:
	motion.suspend()

func home() -> void:
	motion.home()
	if _root: _enter_pose(active_id)

## Where the viewer stands and faces now becomes where this scene is entered from then on,
## and the scene's card is photographed again from there.
func set_entry() -> bool:
	if not _shown or not library.entries.has(active_id): return false
	var ahead := -(app.xr_camera as Node3D).global_transform.basis.z
	ahead.y = 0.0
	# Looking straight up or down gives no heading: keep the one the scene is entered with now.
	var heading := Basis.looking_at(ahead.normalized()) if ahead.length() > 0.2 else (_root.global_transform * _spawn).basis.orthonormalized()
	# The point saved is on the level the viewer is on, without the rise that gives the posture its height.
	var level := Vector3.UP * _raised
	var place := (_root.global_transform.affine_inverse() * Transform3D(heading, _feet() + level)).orthonormalized()
	if not library.set_entry(active_id, place, POSTURES.find(posture)):
		error = "Could not save scene library"
		return false
	error = ""
	_spawn = library.entry(active_id)
	motion.mark_home(-level)
	_capture_thumbnail(active_id, true)
	return true

func _ambient(wanted: bool) -> void:
	var display: Variant = app.get("display")
	var surroundings: Environment = display.environment if display else null
	if surroundings == null: return
	if wanted and _ambient_saved.is_empty():
		for key in ["ambient_light_source", "ambient_light_color", "ambient_light_energy"]: _ambient_saved[key] = surroundings.get(key)
		surroundings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		surroundings.ambient_light_color = Color.WHITE
		surroundings.ambient_light_energy = AMBIENT * _dimmed
	elif not wanted and not _ambient_saved.is_empty():
		for key in _ambient_saved: surroundings.set(key, _ambient_saved[key])
		_ambient_saved.clear()

func set_play_dim(level: float) -> void:
	play_dim = clampf(level, 0.05, 1.0)
	app.settings.set_value(SECTION, "play_dim", play_dim)
	app.settings.save(app.settings_path)

## Down while a film really plays and up again a moment after it stops, as the hall's lights do.
func _fade(delta: float) -> void:
	var video: Node = app.get("video")
	var showing: bool = video != null and not app.get("photo_active") and video.geometry == Geometry.Geometry.FLAT and video.has_active_presentation()
	var wanted := play_dim if showing and (not app.has_method("_film_dark") or app._film_dark()) else 1.0
	_dim_wait -= delta
	if is_equal_approx(_dimmed, wanted) or _dim_wait > 0.0: return
	_dim_wait = DIM_APPLY_SECONDS
	_dimmed = move_toward(_dimmed, wanted, DIM_APPLY_SECONDS / DIM_SECONDS)
	_apply_dim()

## The scene's own brightness: baked surfaces through their exposure, lit ones through the ambient
## light, and the sky behind either. The screen's reflected light is not part of it.
func _apply_dim() -> void:
	if _root == null: return
	if _source == "unity": Unity.set_look(_root, _dimmed, bake)
	elif not _ambient_saved.is_empty(): (app.get("display").environment as Environment).ambient_light_energy = AMBIENT * _dimmed
	if _sky:
		if _sky_tint is Vector3:
			for material in [_sky.sky_material, _backdrop]:
				if material: (material as ShaderMaterial).set_shader_parameter("tint", (_sky_tint as Vector3) * _dimmed)
	elif _panorama.choice != "dark":
		_panorama._material.energy_multiplier = _dimmed
		# The display copies a panorama's brightness when it is handed the sky.
		app._update_background()

func _process(delta: float) -> void:
	if _shown: _fade(delta)
	# A scene restored before the headset tracks takes its height once the head is known.
	if _shown and not _calibrated and not motion.moving(): _settle()
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
	# Those surfaces dim through their exposure, which would take the screen's light down with them.
	var shown := Vector3(sqrt(maxf(colour.r, 0.0)), sqrt(maxf(colour.g, 0.0)), sqrt(maxf(colour.b, 0.0))) * spread / maxf(_dimmed, 0.05)
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

## The viewer's panorama for a scene without a sky; null when there is none or the scene has its own.
func panorama() -> Sky:
	return _panorama.ready_sky() if _shown and _sky == null and _panorama.choice != "dark" else null

## Puts a panorama behind the scene on show: a built-in one, one of the viewer's, or none ("").
func set_backdrop(id: String) -> void:
	if _root == null or _sky != null or not library.set_backdrop(active_id, id): return
	_load_backdrop(id)
	app._update_background()

func _load_backdrop(id: String) -> void:
	var scenery: Variant = app.get("scenery")
	var panoramas: Variant = scenery.get("library") if scenery else null
	if id in Panorama.BUILTINS: _panorama.select(id)
	elif panoramas and panoramas.assets.has(id) and FileAccess.file_exists(panoramas.image_path(id)):
		var asset: Dictionary = panoramas.assets[id]
		_panorama.set_library_asset(panoramas.image_path(id), str(asset.title), int(asset.orientation))
		_panorama.select("custom")
	# One that is gone, or none: the plain dark background the scene sits on.
	else: _panorama.select("dark")

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

## Photographs the scene from where it is entered: the first time it is on show, and again
## (`retake`) when the viewer moves the entry point.
func _capture_thumbnail(id: String, retake: bool = false) -> void:
	if not _shown or DisplayServer.get_name() == "headless" or (not retake and FileAccess.file_exists(library.thumbnail_path(id))): return
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
	elif panorama():
		# Turned as the display turns a panorama: its centre faces forward.
		surroundings.background_mode = Environment.BG_SKY
		surroundings.sky = panorama()
		surroundings.sky_rotation = Vector3(0, PI, 0)
	else:
		surroundings.background_mode = Environment.BG_COLOR
		surroundings.background_color = Color(0.03, 0.03, 0.04)
	surroundings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	surroundings.ambient_light_color = Color.WHITE
	camera.environment = surroundings
	viewport.add_child(camera)
	app.add_child(viewport)
	var eyes := eye_height(POSTURES[library.entry_pose(id) % POSTURES.size()]) if library.entry(id) is Transform3D else EYE_HEIGHT
	# The scene may be raised for the viewer's posture; the picture is taken from the entry point itself.
	camera.global_transform = scene.global_transform * _spawn * Transform3D(Basis.IDENTITY, Vector3(0, eyes, 0))
	camera.current = true
	for frame in 3: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	if image == null or image.is_empty() or not is_instance_valid(scene) or scene != _root: return
	DirAccess.make_dir_recursive_absolute(library.thumbnail_path(id).get_base_dir())
	if image.save_jpg(library.thumbnail_path(id), 0.85) != OK: return
	_thumbnails.erase(id)
	_shots += 1
	library.changed.emit()

func cycle_bake() -> void:
	set_bake(BAKE_STEPS[(BAKE_STEPS.find(bake) + 1) % BAKE_STEPS.size()])

func set_bake(strength: float) -> void:
	bake = clampf(strength, 0.0, 1.0)
	app.settings.set_value(SECTION, "bake", bake)
	app.settings.save(app.settings_path)
	if _root and _source == "unity": Unity.set_look(_root, _dimmed, bake)
