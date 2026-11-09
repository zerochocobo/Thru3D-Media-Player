extends Node3D
## Reusable scene host; no camera, XR initialization, input or global environment
## side effects. The app presents background_environment only while selected.
signal changed
## A handheld firework needs a controller pulse: on taking it and on each candle shot.
signal handheld_pulse(hand: String,strength: float)
const Bundle := preload("res://scripts/environments/private_beach_bundle.gd")
const Navigation := preload("res://scripts/environments/private_beach_navigation.gd")
const Movement := preload("res://scripts/environments/private_beach_locomotion.gd")
const Screen := preload("res://scripts/environments/private_beach_screen.gd")
const BUNDLE_PATH := "res://environments/private_beach/beach_bundle.res"
const Water := preload("res://scripts/environments/private_beach_water.gd")
const TimeOfDay := preload("res://scripts/environments/private_beach_time.gd")
const Clouds := preload("res://scripts/environments/private_beach_clouds.gd")
const Shadow := preload("res://scripts/environments/private_beach_shadow.gd")
const Fireworks := preload("res://scripts/environments/private_beach_fireworks.gd")
const FireworkControl := preload("res://scripts/environments/private_beach_fireworks_control.gd")
const Drag := preload("res://scripts/environments/private_beach_drag.gd")
const NightProps := preload("res://scripts/environments/private_beach_night_props.gd")
const ShoreProps := preload("res://scripts/environments/private_beach_shore_props.gd")
const Handheld := preload("res://scripts/environments/private_beach_handheld.gd")
const Crabs := preload("res://scripts/environments/private_beach_crabs.gd")
const CelestialEggs := preload("res://scripts/environments/private_beach_celestial_easter_eggs.gd")
const HALO := preload("res://shaders/private_beach/body_halo.gdshader")
const SAND := preload("res://shaders/private_beach/sand.gdshader")
const GROUND_VISIBILITY := preload("res://shaders/private_beach/sand_visibility.gdshader")
const ROCK := preload("res://shaders/private_beach/rock.gdshader")
const WATER := preload("res://shaders/private_beach/water.gdshader")
const PROPS := preload("res://shaders/private_beach/props.gdshader")
const FOLIAGE := preload("res://shaders/private_beach/foliage.gdshader")
const GRILL := preload("res://shaders/private_beach/grill.gdshader")
const SKY := preload("res://shaders/private_beach/time_sky.gdshader")
const BACKDROP := preload("res://shaders/private_beach/time_backdrop.gdshader")
## Adreno 6xx only (tools/beach/mobile_shaders.py low_outputs): same uniforms, cheaper fragments.
const LOW_SHADERS := {
	SAND: preload("res://shaders/private_beach/sand_low.gdshader"),
	WATER: preload("res://shaders/private_beach/water_low.gdshader"),
	PROPS: preload("res://shaders/private_beach/props_low.gdshader"),
	FOLIAGE: preload("res://shaders/private_beach/foliage_low.gdshader"),
	GRILL: preload("res://shaders/private_beach/grill_low.gdshader"),
}
const DAY_HOURS := 9.0
const NIGHT_HOURS := 21.0
const DRAG_HIT_DEGREES := 6.0
const SURF_PATH := "res://environments/private_beach/surf.wav"
## A bed under the scene, not a soundtrack: quiet, and gone while anything else plays.
const SURF_VOLUME_DB := -24.0
const SURF_FADE_SECONDS := 1.5
const HALO_DISTANCE := 300.0
const CONTROL_RAY_MARGIN := .008
const CENTER_CHAIR := Vector2(0,9)
## Eye of an upright sitter over the rear of the flat seat (cushion z -.87…+.39,
## top ≈.5, hinge +.4), relative to the lounger's authored centre. The real body
## is upright, so an eye over the reclined back reads as sitting on the backrest.
const LOUNGER_EYE := Vector3(0,1.2,.16)
const CHAIR_CONTACT_SIZE := Vector2(1.5,2.7)
## The grill stands under the string of lights, near the loungers.
const GRILL_SPOT := Vector2(-2.3,12.5)
const NEAR_ROCK_SPOT := Vector2(-22,-3.8)
const SCREEN_GRIP_MARGIN := .3
## Cloud drift is imperceptible per frame; each update also redraws the sky radiance.
const CLOUD_UPDATE_SECONDS := 1.0

var is_ready := false
var loading := false
var error := ""
var hours := DAY_HOURS
var night: bool:
	get: return float(TimeOfDay.state(hours).daylight)<.5
var presented := false
var elapsed := 0.0
var background_environment: Environment
var backdrop_material: ShaderMaterial
var navigation: RefCounted
var bundle: Resource
var _content: Node3D
var _surfaces: Array[ShaderMaterial] = []
var _animated: Array[ShaderMaterial] = []
var _sky_material: ShaderMaterial
var _sun: DirectionalLight3D
var _wanted := ""
var _requested := ""
var movement: RefCounted
var movement_loading := false
var _movement_thread: Thread
var _scene_generation := 0
var _movement_generation := 0
var _movement_wanted := false
var screen_layout: Dictionary = {}
var screen_loading := false
var screen_error := ""
## Optional live tracked eye in scene coordinates. Invalid tracking rejects
## a screen edit; navigation's fixed standing anchor is not the actual head.
var viewer_position_provider: Callable
var viewer_mouth_provider: Callable
## Viewer-chosen gain for the screen's light on the surrounding scene.
var screen_light := 1.0
var _film_source := Vector3(.10,.16,.25)
var _film_color := Vector3(.10,.16,.25)
var _screen_node: Node3D
var _screen_thread: Thread
var _screen_revision := 0
var _screen_work_revision := 0
var _screen_candidate: Dictionary = {}
var _screen_pending: Dictionary = {}
var _clouds := Clouds.new()
var _cloud_image: Image
var _cloud_elapsed := 0.0
var _shadow: RefCounted
var _shadow_stale := false
var _screen_casters: Array = []
var fireworks: Node3D
var _control: Dictionary = {}
var _drag := Drag.new()
var _halo: MeshInstance3D
var _control_lit := false
var _busy_flash := 0.0
var _control_pressed := false
var _control_pulse := 0.0
var low_end := false
var viewer_seated := false
var night_props: Dictionary = {}
var shore_props: Dictionary = {}
var handheld: Dictionary = {}
var crabs: Dictionary = {}
var celestial_eggs: Node3D
var _fire_light := Vector3.ZERO
## hand -> Transform3D grip pose, refreshed by the app every frame while presented.
var handheld_poses: Dictionary = {}
var _night_mix := 0.0
var surf_wanted := false
var _surf: AudioStreamPlayer
var _surf_level := 0.0
var seats: Dictionary = {}
var _screen_marks: Array[MeshInstance3D] = []
var _screen_mark_material: StandardMaterial3D
var _screen_solids: Array = []

func _ready() -> void:
	visible=presented and is_ready
	_update_processing()

func prepare(path := BUNDLE_PATH) -> void:
	if path==_wanted and (loading or (is_ready and error.is_empty())): return
	_wanted=path; error=""
	if _requested.is_empty(): _begin_request()
	_update_processing()

func _begin_request() -> void:
	if _wanted.is_empty(): return
	if not ResourceLoader.exists(_wanted):
		error="Beach resources unavailable"; loading=false; changed.emit(); return
	var result := ResourceLoader.load_threaded_request(_wanted,"Resource",true)
	if result!=OK:
		error="Beach resources could not be requested"; loading=false; changed.emit(); return
	_requested=_wanted; loading=true

func set_presented(value: bool) -> void:
	if value and not presented and not shore_props.is_empty(): ShoreProps.repaint(shore_props)
	presented=value
	visible=value and is_ready
	if not handheld.is_empty() and not value: Handheld.clear(handheld)
	if not value: _stop_surf()
	if not value and celestial_eggs: celestial_eggs.cancel()
	if fireworks!=null:
		fireworks.release_all()
		fireworks.set_enabled(value and _fireworks_available())
	if not value: end_drag(); set_scene_highlight(false,false)
	_update_processing()

func set_night(value: bool) -> void:
	if night!=value: set_hours(NIGHT_HOURS if value else DAY_HOURS)

func set_hours(value: float,notify := true) -> void:
	var next := fposmod(value,24.0)
	if is_equal_approx(hours,next): return
	_clouds.scrub(hours,next)
	hours=next
	_apply_lighting()
	if notify: changed.emit()

func _fireworks_available() -> bool:
	return TimeOfDay.sun_direction(hours).y<-.05

func firework_hit(origin: Vector3,direction: Vector3) -> bool:
	if _control.is_empty() or not _control.root.visible: return false
	# Only the visible cap/ring is clickable, never the case or a distance-scaled
	# area that overlaps handheld stock on the same table.
	var half := Vector3(.043,.012,.043)
	var bounds := AABB((_control.point as Vector3)-half,half*2.0)
	return bounds.grow(CONTROL_RAY_MARGIN).intersects_ray(origin,direction)!=null

func press_firework(source: String) -> bool:
	var accepted: bool=fireworks.press(source)
	if not accepted and fireworks.enabled and fireworks.queue.size()>=Fireworks.QUEUE_LIMIT: _busy_flash=.25
	_control_pressed=accepted
	_update_control_indicator()
	return accepted

func release_firework(source: String) -> void:
	fireworks.release(source)
	_control_pressed=false
	_update_control_indicator()

func celestial_hit(direction: Vector3) -> bool:
	return is_ready and _drag.hit(direction,hours)

## A consumed target stays consumed during cooldown; it must not pause the film.
func celestial_easter_egg(direction: Vector3, activate: bool = true) -> bool:
	if not presented or not celestial_hit(direction) or dragging() or not celestial_eggs: return false
	celestial_eggs.low_end = low_end
	celestial_eggs.set_view_context(screen_layout,bundle.config.shore.points)
	var solar := TimeOfDay.sun_direction(hours)
	if activate: celestial_eggs.trigger("moon" if solar.y < 0.0 else "sun", _viewer_eye(), -solar if solar.y < 0.0 else solar)
	return true

func begin_drag(direction: Vector3) -> bool:
	return is_ready and _drag.begin(direction,hours)

func drag_to(direction: Vector3) -> void:
	var value: float=_drag.move(direction)
	# Viewers watch the sky move; settings and observers update once on release.
	if is_finite(value): set_hours(value,false)

func dragging() -> bool:
	return _drag.active

func end_drag() -> void:
	if not _drag.active: return
	_drag.end()
	changed.emit()

func set_scene_highlight(body: bool,control: bool) -> void:
	if _halo!=null: _halo.visible=body and presented
	_control_lit=control
	_update_control_indicator()

func _update_control_indicator() -> void:
	if _control.is_empty(): return
	FireworkControl.show_state(_control,"pressed" if _control_pressed else "hover" if _control_lit else "idle",.5+.5*sin(_control_pulse))
	if _busy_flash>0.0: (_control.ring as StandardMaterial3D).albedo_color=Color(1,.07,.015,1)

func _place_halo() -> void:
	var solar: Vector3=TimeOfDay.sun_direction(hours)
	var body: Vector3=-solar if solar.y<0.0 else solar
	var eye := _viewer_eye()
	_halo.global_position=eye+body*HALO_DISTANCE
	_halo.look_at(eye,Vector3.UP if absf(body.y)<.98 else Vector3.FORWARD)

func _optional_stream(file: String) -> AudioStream:
	var path := "res://environments/private_beach/"+file
	return load(path) if ResourceLoader.exists(path) else null

func _play_pop(at: Vector3) -> void:
	var pops: Array=handheld.get("sounds",{}).get("pops",[]).filter(func(stream): return stream!=null)
	if pops.is_empty(): return
	var player := AudioStreamPlayer3D.new(); player.stream=pops.pick_random(); player.volume_db=-6.0
	player.pitch_scale=randf_range(.94,1.06); _content.add_child(player); player.global_position=at
	player.finished.connect(player.queue_free); player.play()

## A hand takes the item its fingers reach, else the one its ray points at.
func grab_handheld(hand: String,point: Variant,ray: Variant) -> bool:
	if handheld.is_empty(): return false
	if handheld.held.has(hand): return false
	var index := -1
	if point is Vector3: index=Handheld.near(handheld,point)
	# The launch button sits beside the table and keeps its own ray.
	if index<0 and ray is Array and ray.size()==2 and not firework_hit(ray[0],ray[1]): index=Handheld.ray_hit(handheld,ray[0],ray[1])
	if not Handheld.take(handheld,index,hand): return false
	handheld_pulse.emit(hand,.35)
	return true

func return_handheld(hand: String) -> bool:
	if handheld.is_empty() or not Handheld.put_back(handheld,hand): return false
	handheld_pulse.emit(hand,.18)
	return true

func handheld_ray_hit(origin: Vector3,direction: Vector3) -> bool:
	return not handheld.is_empty() and Handheld.ray_hit(handheld,origin,direction)>=0

## Items a hand could take right now, by reach or ray; empty when that hand already holds one.
var _handheld_aim := {}
func aim_handheld(hand: String,point: Variant,ray: Variant) -> bool:
	var index := -1
	if not handheld.is_empty() and not handheld.held.has(hand):
		if point is Vector3: index=Handheld.near(handheld,point)
		if index<0 and ray is Array and ray.size()==2 and not firework_hit(ray[0],ray[1]): index=Handheld.ray_hit(handheld,ray[0],ray[1])
	var entered: bool=index>=0 and _handheld_aim.get(hand,-1)!=index
	_handheld_aim[hand]=index
	Handheld.highlight(handheld,_handheld_aim.values())
	if entered: handheld_pulse.emit(hand,.6)
	return entered

func _update_night_props(delta := 0.0) -> void:
	if night_props.is_empty(): return
	ShoreProps.show(shore_props,_night_mix,_viewer_eye())
	var mouth: Vector3=viewer_mouth_provider.call() if viewer_mouth_provider.is_valid() else Vector3.INF
	for event in Handheld.advance(handheld,delta,handheld_poses,_viewer_eye(),_night_mix,mouth):
		handheld_pulse.emit(event.hand,event.strength)
		if event.get("sound","")=="pop" and handheld_poses.has(event.hand): _play_pop(handheld_poses[event.hand].origin)
	ShoreProps.fly(shore_props,_night_mix,elapsed)
	if not crabs.is_empty(): Crabs.advance(crabs,_night_mix,elapsed)
	var light: Vector3=NightProps.show(night_props,_night_mix,elapsed)
	if light.is_equal_approx(_fire_light): return
	_fire_light=light
	for material in _surfaces: material.set_shader_parameter("fire_light",light)

func _stop_surf() -> void:
	_surf_level=0.0
	if is_instance_valid(_surf): _surf.stop()

func _notification(what: int) -> void:
	# Leaving the app pauses the main loop: no later frame would fade the loop out.
	if what in [NOTIFICATION_APPLICATION_PAUSED,NOTIFICATION_APPLICATION_FOCUS_OUT,NOTIFICATION_WM_CLOSE_REQUEST,NOTIFICATION_PREDELETE]: _stop_surf()

func _update_surf(delta: float) -> void:
	if _surf==null: return
	var target := 1.0 if surf_wanted and presented else 0.0
	_surf_level=move_toward(_surf_level,target,delta/SURF_FADE_SECONDS)
	if _surf_level<=0.0:
		if _surf.playing: _surf.stream_paused=true
		return
	if not _surf.playing: _surf.play()
	_surf.stream_paused=false
	_surf.volume_db=SURF_VOLUME_DB+linear_to_db(_surf_level)

func set_film_color(value: Color) -> void:
	# Linear-light input, ready for the existing low-frequency film sampler.
	_film_source=Vector3(clampf(value.r,0,1),clampf(value.g,0,1),clampf(value.b,0,1))
	_apply_film()

func set_screen_light(strength: float) -> void:
	screen_light=clampf(strength,0,2)
	_apply_film()

func _apply_film() -> void:
	_film_color=_film_source*screen_light
	for material in _surfaces: material.set_shader_parameter("film_color",_film_color)

func release() -> void:
	_wanted=""
	_clear_content()
	error=""; elapsed=0
	# Drain a pending threaded request without ever resurrecting a released scene.
	_update_processing()
	changed.emit()

func _clear_content() -> void:
	_scene_generation+=1
	_screen_revision+=1; _screen_pending.clear(); screen_layout.clear()
	screen_loading=false; screen_error=""; _screen_node=null
	_movement_wanted=false; movement=null
	if is_instance_valid(_content):
		remove_child(_content); _content.free()
	_content=null; _sun=null; _sky_material=null
	_surfaces.clear(); _animated.clear()
	_shadow=null; _shadow_stale=false; _screen_casters.clear(); _cloud_image=null
	fireworks=null; _control={}; _halo=null; _drag.end(); _control_lit=false; _busy_flash=0.0
	celestial_eggs=null
	bundle=null; navigation=null; background_environment=null; backdrop_material=null
	_surf=null; _surf_level=0.0; night_props={}; shore_props={}; handheld={}; crabs={}; handheld_poses={}; _fire_light=Vector3.ZERO
	seats.clear(); _screen_marks.clear(); _screen_solids.clear(); _control_pressed=false
	is_ready=false; visible=false

func _update_processing() -> void:
	set_process(not _requested.is_empty() or _movement_thread!=null or _screen_thread!=null or not _screen_pending.is_empty() or (is_ready and presented))

func _process(delta: float) -> void:
	_poll_screen()
	if _movement_thread!=null and not _movement_thread.is_alive():
		var prepared: RefCounted = _movement_thread.wait_to_finish()
		_movement_thread=null; movement_loading=false
		if _movement_generation==_scene_generation and is_ready and _movement_wanted:
			if prepared.navigation_ready: movement=prepared
			else: error="Beach navigation unavailable"
			changed.emit()
		elif _movement_wanted: prepare_movement()
		_update_processing()
	if not _requested.is_empty():
		var status := ResourceLoader.load_threaded_get_status(_requested)
		if status!=ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var path := _requested
			var loaded: Resource = ResourceLoader.load_threaded_get(path) if status==ResourceLoader.THREAD_LOAD_LOADED else null
			_requested=""; loading=false
			if path==_wanted:
				if loaded is Bundle:
					error=loaded.validate()
					if error.is_empty(): _install(loaded)
				else: error="Beach bundle could not be loaded"
				changed.emit()
			elif not _wanted.is_empty(): _begin_request()
			_update_processing()
	if not is_ready or not presented: return
	elapsed+=delta
	for material in _animated: material.set_shader_parameter("study_time",elapsed)
	_cloud_elapsed+=delta
	if _cloud_elapsed>=CLOUD_UPDATE_SECONDS:
		_clouds.advance(_cloud_elapsed); _cloud_elapsed=0.0
		_apply_cloud_light()
	_sync_shadow()
	fireworks.advance(delta)
	if celestial_eggs: celestial_eggs.advance(delta, _viewer_eye())
	if _busy_flash>0.0:
		_busy_flash=maxf(0.0,_busy_flash-delta)
		if _busy_flash==0.0: _update_control_indicator()
	_update_surf(delta)
	_update_night_props(delta)
	if _control.root.visible:
		_control_pulse=fposmod(_control_pulse+delta*2.2,TAU)
		if not _control_lit and not _control_pressed: _update_control_indicator()
	if _halo.visible: _place_halo()

func _sync_shadow() -> void:
	if _shadow_stale:
		_shadow_stale=false
		var light: Dictionary=TimeOfDay.direct_light(hours)
		if light.shadow_enabled: _shadow.update(light.direction)
	var eye := _viewer_eye()
	_shadow.set_focus(Vector3(eye.x,navigation.ground(eye.x,eye.z)+.5,eye.z))

func _viewer_eye() -> Vector3:
	if viewer_position_provider.is_valid():
		var tracked: Variant=viewer_position_provider.call()
		if tracked is Vector3 and tracked.is_finite(): return tracked
	if movement!=null: return movement.eye_position
	return Vector3(bundle.config.viewer.x,0,bundle.config.viewer.z)

func _exit_tree() -> void:
	_stop_surf()
	if _screen_thread!=null:
		_screen_thread.wait_to_finish(); _screen_thread=null
	if _movement_thread!=null:
		_movement_thread.wait_to_finish(); _movement_thread=null
	# Normal release drains asynchronously. Destruction during a load must still
	# consume the request so the loader does not retain its result indefinitely.
	if not _requested.is_empty():
		ResourceLoader.load_threaded_get(_requested)
		_requested=""
	_clear_content()

func prepare_movement() -> void:
	if not is_ready: return
	_movement_wanted=true
	if movement!=null or _movement_thread!=null: return
	if _screen_thread!=null: movement_loading=true; return
	var colliders := _collider_snapshot()
	_movement_generation=_scene_generation
	_movement_thread=Thread.new()
	var result := _movement_thread.start(_prepare_movement.bind(bundle.navigation.duplicate(true),bundle.config.duplicate(true),colliders))
	if result!=OK:
		_movement_thread=null; error="Beach navigation worker unavailable"
	else: movement_loading=true
	_update_processing()

func _collider_snapshot(exclude_screen := false) -> Array:
	var colliders: Array = []
	# Snapshot actual authored model bounds on the main thread. The worker reads
	# only dictionaries and arrays; it never touches scene nodes or rendering.
	for node in _content.find_children("*","MeshInstance3D",true,false):
		var name_ := str(node.name)
		if not (name_.begins_with("Study_") or name_.begins_with("Table_") or name_.begins_with("Support_") or name_.begins_with("Foot_") or name_.begins_with("Screen_") or name_.begins_with("BayRock_") or name_=="Lamp"): continue
		if name_.begins_with("Support_") or name_.begins_with("Foot_") or name_.begins_with("Screen_"):
			if exclude_screen or _screen_node!=null: continue
		var box: AABB = global_transform.affine_inverse()*node.global_transform*node.get_aabb()
		# Thin front faces get a minimal volume; exact back/feet remain separate.
		box=box.grow(.002)
		colliders.append({"id":name_,"min":[box.position.x,box.position.y,box.position.z],"max":[box.end.x,box.end.y,box.end.z]})
	if not exclude_screen and _screen_node!=null:
		_append_boxes(colliders,Screen.collider_boxes(screen_layout,_screen_node))
	return colliders

static func _append_boxes(colliders: Array,boxes: Array[AABB]) -> void:
	for box in boxes:
		colliders.append({"id":"screen_dynamic","min":[box.position.x,box.position.y,box.position.z],"max":[box.end.x,box.end.y,box.end.z]})

func request_screen(changes: Dictionary,restore_view: Dictionary = {}) -> bool:
	# Discrete edit/drag-release API. Keep the old complete layout while preparing
	# connectivity, then swap geometry, uniforms and movement in one main-loop step.
	if not is_ready: screen_error="Beach is not ready"; return false
	if not restore_view.is_empty() and (presented or not Movement.valid_view_record(restore_view)):
		screen_error="Saved viewing position is unavailable"; return false
	var settings: Dictionary = bundle.config.duplicate(true)
	settings.screen=desired_screen_parameters()
	var candidate := Screen.solve(settings,navigation.ground,changes)
	if candidate.has("error"): screen_error=candidate.error; return false
	var node := Screen.geometry(candidate,navigation.ground)
	var boxes := Screen.collider_boxes(candidate,node); node.free()
	var colliders := _collider_snapshot(true)
	for box in boxes:
		for collider in colliders:
			var low := _vector(collider.min); var high := _vector(collider.max)
			if box.intersects(AABB(low,high-low)):
				screen_error="Screen or support intersects a prop"; return false
	var conflict := _screen_viewer_conflict(boxes,restore_view)
	if not conflict.is_empty(): screen_error=conflict; return false
	_append_boxes(colliders,boxes)
	_screen_revision+=1; screen_error=""; screen_loading=true
	_screen_pending={"layout":candidate,"colliders":colliders,"boxes":boxes,"restore_view":restore_view.duplicate(true)}
	_start_screen_worker(); changed.emit()
	return true

## Live drag: the candidate replaces the visible screen immediately. Navigation and
## shadow proxies stay on the last committed layout until request_screen on release.
func begin_screen_preview() -> void:
	_screen_solids=_collider_snapshot(true)

func preview_screen(changes: Dictionary) -> bool:
	if not is_ready or screen_loading: return false
	var settings: Dictionary=bundle.config.duplicate(true)
	settings.screen=screen_layout.parameters.duplicate(true)
	var candidate := Screen.solve(settings,navigation.ground,changes)
	if candidate.has("error"): return false
	var node := Screen.geometry(candidate,navigation.ground)
	var boxes := Screen.collider_boxes(candidate,node); node.free()
	for box in boxes:
		for collider in _screen_solids:
			var low := _vector(collider.min); var high := _vector(collider.max)
			if box.intersects(AABB(low,high-low)): return false
	if not _screen_viewer_conflict(boxes).is_empty(): return false
	_commit_screen(candidate,false)
	return true

## Where a ray meets the panel, and whether that is one of its corners; {} on a miss.
func screen_hit(origin: Vector3,direction: Vector3) -> Dictionary:
	if screen_layout.is_empty(): return {}
	var normal: Vector3=screen_layout.normal
	var facing := direction.dot(normal)
	if absf(facing)<.0001: return {}
	var t: float=(screen_layout.center-origin).dot(normal)/facing
	if t<=0.0: return {}
	var point: Vector3=origin+direction*t
	var delta: Vector3=point-screen_layout.center
	var local := Vector2(delta.dot(screen_layout.right),delta.dot(screen_layout.up))
	var half: Vector2=screen_layout.half_size
	var margin := maxf(SCREEN_GRIP_MARGIN,t*.07)
	if absf(local.x)>half.x+margin or absf(local.y)>half.y+margin: return {}
	var corner := absf(absf(local.x)-half.x)<=margin and absf(absf(local.y)-half.y)<=margin
	return {"point":point,"corner":corner,"distance":t,"sign":Vector2(signf(local.x),signf(local.y))}

## Corner brackets answer the ray: all four while aiming at the panel, the one under a corner lit.
func show_screen_marks(hit: Dictionary) -> void:
	for mark in _screen_marks: mark.visible=false
	if hit.is_empty() or screen_layout.is_empty(): return
	if _screen_marks.is_empty(): _build_screen_marks()
	var half: Vector2=screen_layout.half_size
	var arm: float=clampf(float(hit.distance)*.035,.05,.6)
	var thickness: float=arm*.16
	var right: Vector3=screen_layout.right; var up: Vector3=screen_layout.up; var normal: Vector3=screen_layout.normal
	var center: Vector3=screen_layout.center+normal*.06
	var index := 0
	for sx in [-1.0,1.0]:
		for sy in [-1.0,1.0]:
			var lit: bool=hit.corner and hit.sign==Vector2(sx,sy)
			var tip: Vector3=center+right*half.x*sx+up*half.y*sy
			for along in [true,false]:
				var mark: MeshInstance3D=_screen_marks[index]; index+=1
				var size := Vector3(arm,thickness,.01) if along else Vector3(thickness,arm,.01)
				var offset: Vector3=(right*-sx*arm*.5) if along else (up*-sy*arm*.5)
				mark.global_transform=Transform3D(Basis(right*size.x,up*size.y,normal*size.z),tip+offset)
				mark.visible=not hit.corner or lit
	_screen_mark_material.albedo_color=Color(1,.76,.22,1) if hit.corner else Color(1,1,1,.62)

func _build_screen_marks() -> void:
	_screen_mark_material=StandardMaterial3D.new(); _screen_mark_material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	_screen_mark_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	var box := BoxMesh.new()
	for index in 8:
		var mark := MeshInstance3D.new(); mark.name="ScreenMark"+str(index); mark.mesh=box
		mark.material_override=_screen_mark_material; mark.visible=false; _content.add_child(mark)
		_screen_marks.append(mark)

func desired_screen_parameters() -> Dictionary:
	if not _screen_pending.is_empty(): return _screen_pending.layout.parameters.duplicate(true)
	if _screen_thread!=null and _screen_work_revision==_screen_revision: return _screen_candidate.layout.parameters.duplicate(true)
	return screen_layout.get("parameters",{}).duplicate(true)

func _screen_hits_viewer(boxes: Array[AABB]) -> bool:
	return not _screen_viewer_conflict(boxes).is_empty()

func _screen_viewer_conflict(boxes: Array[AABB],restore_view: Dictionary = {}) -> String:
	var eye := Vector3(bundle.config.viewer.x,0,bundle.config.viewer.z)
	eye.y=navigation.ground(eye.x,eye.z)+bundle.config.viewer.eye_height
	if movement!=null: eye=movement.eye_position
	if not restore_view.is_empty():
		eye=Vector3(float(restore_view.x),0,float(restore_view.z))
		eye.y=navigation.ground(eye.x,eye.z)+float(restore_view.eye_height)
	elif viewer_position_provider.is_valid():
		var tracked: Variant = viewer_position_provider.call()
		if not tracked is Vector3 or not tracked.is_finite(): return "Head tracking unavailable"
		eye=tracked
	var bottom: float = navigation.ground(eye.x,eye.z)
	for box in boxes:
		if box.end.y<bottom+.03 or box.position.y>maxf(eye.y,bottom+Movement.EYE_HEIGHT)+Movement.HEAD_CLEARANCE: continue
		var closest := Vector2(clampf(eye.x,box.position.x,box.end.x),clampf(eye.z,box.position.z,box.end.z))
		if closest.distance_to(Vector2(eye.x,eye.z))<=Movement.BODY_RADIUS: return "Screen or support intersects the current viewer"
	return ""

func _start_screen_worker() -> void:
	if _screen_pending.is_empty() or _screen_thread!=null or _movement_thread!=null: return
	_screen_candidate=_screen_pending; _screen_pending={}
	_screen_work_revision=_screen_revision
	_screen_thread=Thread.new()
	var result := _screen_thread.start(_prepare_movement.bind(bundle.navigation.duplicate(true),bundle.config.duplicate(true),_screen_candidate.colliders))
	if result!=OK:
		_screen_thread=null; _screen_candidate.clear(); screen_loading=false; screen_error="Screen navigation worker unavailable"
	_update_processing()

func _poll_screen() -> void:
	var notify := false
	if _screen_thread!=null and not _screen_thread.is_alive():
		var prepared: RefCounted = _screen_thread.wait_to_finish(); _screen_thread=null
		if _screen_work_revision==_screen_revision and is_ready:
			screen_loading=false
			var restore_view: Dictionary = _screen_candidate.get("restore_view",{})
			var conflict := _screen_viewer_conflict(_screen_candidate.boxes,restore_view)
			# The viewer can move during preparation. Validate their latest position.
			if not prepared.navigation_ready: screen_error="Screen navigation unavailable"
			elif not conflict.is_empty(): screen_error=conflict
			elif not restore_view.is_empty() and (presented or not prepared.restore_view(restore_view)): screen_error="Saved viewing position is unavailable"
			elif restore_view.is_empty() and movement!=null and not prepared.adopt_view(movement,viewer_seated): screen_error="Current viewing position is no longer reachable"
			else:
				_commit_screen(_screen_candidate.layout)
				if movement!=null or _movement_wanted: movement=prepared; movement_loading=false
			notify=true
		_screen_candidate={}
		if not is_ready: movement_loading=false
	_start_screen_worker()
	if _screen_thread==null and _movement_wanted and movement==null and is_ready: prepare_movement()
	_update_processing()
	# Observers may queue another edit. Clear the finished candidate before emit.
	if notify: changed.emit()

func _commit_screen(layout: Dictionary,final := true) -> void:
	var node := Screen.geometry(layout,navigation.ground)
	# Remove authored screen pieces only once; subsequent edits own one subtree.
	if _screen_node!=null: _screen_node.free()
	else:
		for mesh in _content.find_children("*","MeshInstance3D",true,false):
			var name_ := str(mesh.name)
			if name_.begins_with("Screen_") or name_.begins_with("Support_") or name_.begins_with("Foot_"): mesh.free()
	_screen_node=node; _content.add_child(node); screen_layout=layout
	if final: _sync_screen_casters()
	for material in _surfaces:
		material.set_shader_parameter("screen_origin",layout.center)
		material.set_shader_parameter("screen_right",layout.right)
		material.set_shader_parameter("screen_up",layout.up)
		material.set_shader_parameter("screen_normal",layout.normal)
		material.set_shader_parameter("screen_half_size",layout.half_size)

func _sync_screen_casters() -> void:
	# The panel keeps its analytic projection; supports and feet cast real shadows.
	if _shadow==null: return
	var parts: Array=[]
	var root_: Node=_screen_node if _screen_node!=null else _content
	for mesh in root_.find_children("*","MeshInstance3D",true,false):
		var name_ := str(mesh.name)
		if name_.begins_with("Support_") or name_.begins_with("Foot_"): parts.append(mesh)
	_screen_casters=_shadow.replace_casters(_screen_casters,parts)
	_shadow_stale=true

static func _prepare_movement(description: Dictionary,config: Dictionary,colliders: Array) -> RefCounted:
	var prepared := Movement.new()
	prepared.configure_beach(description,config,colliders)
	return prepared

func _vector(value: Array) -> Vector3:
	return Vector3(value[0],value[1],value[2])

func _material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new(); material.shader=quality_shader(shader,low_end)
	var config: Dictionary = bundle.config
	var layout: Dictionary = bundle.layout
	var coast := PackedVector2Array()
	for point in config.shore.points: coast.append(Vector2(point[0],point[1]))
	material.set_shader_parameter("coast_count",coast.size())
	while coast.size()<32: coast.append(coast[-1])
	material.set_shader_parameter("coast",coast)
	material.set_shader_parameter("sea_level",config.shore.sea_level)
	material.set_shader_parameter("land_slope",config.terrain.land_slope)
	material.set_shader_parameter("uprush_offset",config.shore.uprush_offset)
	material.set_shader_parameter("sun_direction",_vector(layout.sun_direction))
	material.set_shader_parameter("film_color",_film_color)
	material.set_shader_parameter("screen_origin",_vector(layout.screen.center))
	material.set_shader_parameter("screen_half_size",Vector2(config.screen.width,config.screen.width/config.screen.aspect)*.5)
	var corners: Array = layout.screen.corners
	var right := (_vector(corners[1])-_vector(corners[0])).normalized()
	var up := (_vector(corners[3])-_vector(corners[0])).normalized()
	material.set_shader_parameter("screen_right",right); material.set_shader_parameter("screen_up",up)
	material.set_shader_parameter("screen_normal",right.cross(up).normalized())
	var lx := float(config.furniture.lamp[0]); var lz := float(config.furniture.lamp[1])
	material.set_shader_parameter("lamp_position",Vector3(lx,navigation.ground(lx,lz)+.8,lz))
	var authored_rock: Dictionary=bundle.config.study.near_rock
	material.set_shader_parameter("relocated_rock",Vector4(authored_rock.x,authored_rock.z,NEAR_ROCK_SPOT.x,NEAR_ROCK_SPOT.y))
	_surfaces.append(material)
	return material

func _install(loaded: Resource) -> void:
	var model := loaded.terrain.instantiate() as Node3D
	var props := loaded.props.instantiate() as Node3D
	var plants := loaded.vegetation.instantiate() as Node3D
	var grill := loaded.grill.instantiate() as Node3D
	error=_validate_scene(model,props)
	var ground_at := Navigation.new(loaded.navigation,loaded.config)
	if error.is_empty(): _add_center_chair(props,loaded.config.furniture.chairs[0],ground_at)
	if error.is_empty() and (plants==null or grill==null): error="Beach study geometry has no spatial root"
	if not error.is_empty():
		for scene in [model,props,plants,grill]:
			if scene: scene.free()
		return
	_clear_content()
	bundle=loaded
	navigation=Navigation.new(bundle.navigation,bundle.config)
	screen_layout=Screen.solve(bundle.config,navigation.ground,{})
	_content=Node3D.new(); _content.name="BeachContent"; add_child(_content)
	_content.add_child(model); _content.add_child(props); _content.add_child(plants); _content.add_child(grill)
	var near_rock := props.find_child("Study_NearRock",true,false) as Node3D
	var authored_rock: Dictionary=bundle.config.study.near_rock
	near_rock.position+=Vector3(NEAR_ROCK_SPOT.x-float(authored_rock.x),navigation.ground(NEAR_ROCK_SPOT.x,NEAR_ROCK_SPOT.y)-navigation.ground(authored_rock.x,authored_rock.z),NEAR_ROCK_SPOT.y-float(authored_rock.z))
	var sand := _material(SAND); var water := _material(WATER)
	_animated.assign([sand,water])
	water.set_shader_parameter("wave_slopes",bundle.textures.wave_slopes)
	water.set_shader_parameter("wave_slope_range",float(bundle.study.wave_slope_range))
	sand.set_shader_parameter("groundcover_color",bundle.textures.groundcover_color)
	sand.set_shader_parameter("groundcover_normal",bundle.textures.groundcover_normal)
	sand.set_shader_parameter("groundcover_tile",float(bundle.study.groundcover_tile))
	sand.set_shader_parameter("vegetation_contact",bundle.textures.vegetation_contact)
	sand.set_shader_parameter("vegetation_contact_rect",_rect(bundle.study.vegetation_contact_rect))
	var grill_shift := _grill_shift()
	sand.set_shader_parameter("grill_shadow_center",_vector(bundle.study.grill_shadow_center)+grill_shift)
	sand.set_shader_parameter("grill_ground_contact",bundle.textures.grill_contact)
	sand.set_shader_parameter("grill_contact_world",_rect(bundle.study.grill_contact_rect)+Vector4(grill_shift.x,grill_shift.z,0,0))
	for key in ["micro_color","micro_normal","macro_color","cliff_color","cliff_normal"]: sand.set_shader_parameter(key,bundle.textures[key])
	sand.set_shader_parameter("sand_surface",bundle.textures.sand_surface)
	var sand_bounds: Array=bundle.sand_surface.bounds_xz_size
	sand.set_shader_parameter("sand_surface_world",Vector4(sand_bounds[0],sand_bounds[1],sand_bounds[2],sand_bounds[3]))
	sand.set_shader_parameter("sand_slope_range",bundle.sand_surface.slope_range)
	sand.set_shader_parameter("sand_compaction_range",bundle.sand_surface.compaction_range)
	sand.set_shader_parameter("cliff_tile",bundle.config.perimeter.rock_tile_metres)
	sand.set_shader_parameter("cliff_saturation",bundle.config.perimeter.rock_saturation)
	sand.set_shader_parameter("cliff_tint",_vector(bundle.config.perimeter.rock_tint_linear))
	water.set_shader_parameter("beach_micro_color",bundle.textures.micro_color)
	water.set_shader_parameter("beach_macro_color",bundle.textures.macro_color)
	var worlds := PackedVector4Array(); var atlas := PackedVector4Array()
	for tile in bundle.mask_tiles:
		worlds.append(Vector4(tile.world[0],tile.world[1],tile.world[2],tile.world[3]))
		atlas.append(Vector4(tile.pixels[0],tile.pixels[1],tile.pixels[2],tile.pixels[3])/1024)
	for material in [sand,water]:
		material.set_shader_parameter("use_static_mask",true)
		material.set_shader_parameter("static_mask",bundle.textures.static_mask)
		material.set_shader_parameter("mask_count",worlds.size())
		material.set_shader_parameter("mask_world",worlds); material.set_shader_parameter("mask_atlas",atlas)
	# Ground visibility is an X/Z projection, not lighting for the rock above
	# it. Otherwise a boulder's own footprint shadow is painted onto its top.
	var rock_surface:=_material(ROCK)
	for key in ["micro_color","micro_normal","macro_color","cliff_color","cliff_normal"]: rock_surface.set_shader_parameter(key,bundle.textures[key])
	rock_surface.set_shader_parameter("sand_surface",bundle.textures.sand_surface)
	rock_surface.set_shader_parameter("sand_surface_world",Vector4(sand_bounds[0],sand_bounds[1],sand_bounds[2],sand_bounds[3]))
	rock_surface.set_shader_parameter("sand_slope_range",bundle.sand_surface.slope_range)
	rock_surface.set_shader_parameter("sand_compaction_range",bundle.sand_surface.compaction_range)
	rock_surface.set_shader_parameter("cliff_tile",bundle.config.perimeter.rock_tile_metres)
	rock_surface.set_shader_parameter("cliff_saturation",bundle.config.perimeter.rock_saturation)
	rock_surface.set_shader_parameter("cliff_tint",_vector(bundle.config.perimeter.rock_tint_linear))
	rock_surface.set_shader_parameter("use_static_mask",false)
	for node in model.find_children("*","MeshInstance3D",true,false):
		if node.name=="Beach_Terrain" or str(node.name).begins_with("Beach_Perimeter_"): node.material_override=sand
		if str(node.name).begins_with("BayRock_"): node.material_override=rock_surface
		if node.name=="Sea_P0_FiniteProxy" or str(node.name).begins_with("Chair_") or str(node.name).begins_with("Table_") or node.name=="Lamp":
			node.get_parent().remove_child(node); node.free()
		elif node.name=="Screen_Front":
			var neutral := StandardMaterial3D.new()
			neutral.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
			neutral.albedo_color=Color(.42,.52,.63); neutral.cull_mode=BaseMaterial3D.CULL_BACK
			node.material_override=neutral
	var prop_materials: Array[ShaderMaterial] = []
	for kind in range(5):
		var material := _material(PROPS); material.set_shader_parameter("surface_kind",kind)
		for key in ["wood_color","rock_color","rock_normal","rock_arm"]: material.set_shader_parameter(key,bundle.textures[key])
		prop_materials.append(material)
	for node in props.find_children("*","MeshInstance3D",true,false):
		for index in node.mesh.get_surface_count():
			var source: Material = node.mesh.surface_get_material(index)
			var kind := ["P1_Wood","P1_Cloth","P1_Metal","P1_Rock","P2_Diffuser"].find(source.resource_name)
			if kind<0:
				error="Unknown beach material: "+source.resource_name; _clear_content(); return
			node.set_surface_override_material(index,prop_materials[kind])
	_build_seats()
	_install_plants(plants)
	_install_grill(grill)
	grill.position+=_grill_shift()
	night_props=NightProps.build(_content,navigation.ground,prop_materials[0],prop_materials[3],prop_materials[2])
	handheld=Handheld.build(_content,props.find_child("Study_Table",true,false),func(color: Vector3,roughness: float) -> ShaderMaterial:
		var material := _material(GRILL)
		material.set_shader_parameter("base_color",color); material.set_shader_parameter("surface_roughness",roughness)
		material.set_shader_parameter("wood_color",bundle.textures.wood_color)
		return material,navigation.ground)
	crabs=Crabs.build(_content,navigation.ground)
	Handheld.Refreshments.add_skewers(handheld,Vector3(GRILL_SPOT.x,navigation.ground(GRILL_SPOT.x,GRILL_SPOT.y)+.955,GRILL_SPOT.y))
	handheld.sounds={"fizz":_optional_stream("sparkler-fizz.wav"),"pops":["candle-pop-0.wav","candle-pop-1.wav","candle-pop-2.wav"].map(_optional_stream)}
	for material in _surfaces: material.set_shader_parameter("fire_position",night_props.fire)
	shore_props=ShoreProps.build(_content,navigation.ground,float(bundle.config.shore.sea_level),func(color: Vector3,roughness: float,wooden: bool) -> ShaderMaterial:
		var material := _material(GRILL)
		material.set_shader_parameter("base_color",color); material.set_shader_parameter("surface_roughness",roughness)
		material.set_shader_parameter("wooden_surface",wooden); material.set_shader_parameter("wood_color",bundle.textures.wood_color)
		return material)
	var sea := MeshInstance3D.new(); sea.name="Beach_Water"
	sea.mesh=Water.mesh(bundle.config); sea.material_override=water; _content.add_child(sea)
	_sky_material=ShaderMaterial.new(); _sky_material.shader=SKY
	backdrop_material=ShaderMaterial.new(); backdrop_material.shader=BACKDROP
	_cloud_image=Image.create_from_data(bundle.cloud_width,bundle.cloud_height,false,Image.FORMAT_R8,bundle.cloud_data)
	for material in [water,_sky_material,backdrop_material]:
		material.set_shader_parameter("cloud_coverage",bundle.textures.cloud_coverage)
		material.set_shader_parameter("moon_albedo",bundle.textures.moon_albedo)
	_shadow=Shadow.new()
	var casters: Array=[]
	for node in _content.find_children("*","MeshInstance3D",true,false):
		var name_ := str(node.name)
		# Water and the screen panel use their own analytic surfaces.
		# The contact decal lies on the sand; as a caster it would shadow the sand under itself.
		if node!=sea and name_!="ChairContact" and name_!="LightWire" and not name_.begins_with("Glow_") and not name_.begins_with("Shell_") and not name_.begins_with("Study_Fireworks") and not name_.begins_with("Screen_") and not name_.begins_with("Support_") and not name_.begins_with("Foot_"): casters.append(node)
	_shadow.create(_content,casters)
	var ground_bake := _material(GROUND_VISIBILITY)
	for key in ["use_static_mask","static_mask","mask_count","mask_world","mask_atlas"]: ground_bake.set_shader_parameter(key,sand.get_shader_parameter(key))
	_shadow.create_receiver(_content,model.find_child("Beach_Terrain",true,false),ground_bake)
	# The night-only controller is added after the casters are chosen, so its
	# shadow never lingers on the table by day; it still receives scene light.
	_control=FireworkControl.build(_content,navigation.ground(5.2,8.0),func() -> ShaderMaterial:
		var material := _material(GRILL)
		material.set_shader_parameter("wood_color",bundle.textures.wood_color)
		return material,handheld.top)
	_surf=AudioStreamPlayer.new(); _surf.name="Surf"; _content.add_child(_surf)
	if ResourceLoader.exists(SURF_PATH): _surf.stream=load(SURF_PATH)
	_surf_level=0.0
	fireworks=Fireworks.new(); fireworks.name="Fireworks"; _content.add_child(fireworks)
	fireworks.configure(func(x: float,_z: float) -> float: return float(bundle.study.firework_launch_heights[0 if x<0 else 1]))
	fireworks.configure_audio_streams(null,bundle.firework_streams)
	celestial_eggs=CelestialEggs.new(); celestial_eggs.name="CelestialEasterEggs"; _content.add_child(celestial_eggs)
	celestial_eggs.configure(float(bundle.config.shore.sea_level),_optional_stream("sea-monster-roar.wav"))
	_drag.hit_degrees=DRAG_HIT_DEGREES
	_halo=MeshInstance3D.new(); _halo.name="CelestialHalo"; _halo.visible=false
	var halo_mesh := QuadMesh.new()
	halo_mesh.size=Vector2.ONE*2.0*HALO_DISTANCE*tan(deg_to_rad(DRAG_HIT_DEGREES))
	_halo.mesh=halo_mesh
	var halo_material := ShaderMaterial.new(); halo_material.shader=HALO
	_halo.material_override=halo_material; _content.add_child(_halo)
	for material in _surfaces: _shadow.bind(material)
	_shadow.bind_receiver(sand)
	_sync_screen_casters()
	var eye := _viewer_eye()
	_shadow.focus=Vector3(roundf(eye.x),navigation.ground(eye.x,eye.z)+.5,roundf(eye.z))
	var sky := Sky.new(); sky.sky_material=_sky_material; sky.radiance_size=Sky.RADIANCE_SIZE_32
	background_environment=Environment.new()
	background_environment.background_mode=Environment.BG_SKY; background_environment.sky=sky
	background_environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	background_environment.ambient_light_color=Color(.55,.65,.78)
	_sun=DirectionalLight3D.new(); _content.add_child(_sun)
	_sun.look_at(-_vector(bundle.layout.sun_direction),Vector3.UP)
	_sun.light_color=Color(1,.94,.85); _sun.shadow_enabled=false
	is_ready=true; visible=presented
	_apply_lighting()
	_apply_quality()
	_update_processing()

func _add_center_chair(props: Node3D,model_chair: Array,ground_at: RefCounted) -> void:
	# Same lounger, squarely facing the default screen. Its baked visibility still
	# holds on open sand; _add_chair_contact supplies the ground contact.
	var source: MeshInstance3D=props.find_child("Study_Chair_0",true,false)
	var chair := MeshInstance3D.new(); chair.name="Study_Chair_2"; chair.mesh=source.mesh
	source.get_parent().add_child(chair)
	var height: float=ground_at.ground(CENTER_CHAIR.x,CENTER_CHAIR.y)-ground_at.ground(model_chair[0],model_chair[1])
	chair.transform=source.transform.translated(Vector3(CENTER_CHAIR.x-model_chair[0],height,CENTER_CHAIR.y-model_chair[1]))

func _build_seats() -> void:
	seats.clear()
	var points: Array=bundle.config.furniture.chairs.duplicate()
	points.append([CENTER_CHAIR.x,CENTER_CHAIR.y])
	for index in points.size():
		var x: float=points[index][0]; var z: float=points[index][1]; var y: float=navigation.ground(x,z)
		seats["lounger_"+str(index)]={"eye":Vector3(x,y,z)+LOUNGER_EYE,"marker":Vector3(x,y+.5,z-.1),
			"box":AABB(Vector3(x-.48,y+.1,z-1.0),Vector3(.96,1.05,2.15))}
	var contact := MeshInstance3D.new(); contact.name="ChairContact"
	var quad := PlaneMesh.new(); quad.size=CHAIR_CONTACT_SIZE; contact.mesh=quad
	var material := StandardMaterial3D.new(); material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA; material.albedo_color=Color(0,0,0,.34)
	var gradient := Gradient.new(); gradient.set_color(0,Color(1,1,1,1)); gradient.set_color(1,Color(1,1,1,0))
	var texture := GradientTexture2D.new(); texture.gradient=gradient; texture.width=64; texture.height=64
	texture.fill=GradientTexture2D.FILL_RADIAL; texture.fill_from=Vector2(.5,.5); texture.fill_to=Vector2(1,.5)
	material.albedo_texture=texture; contact.material_override=material
	contact.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_content.add_child(contact)
	contact.position=Vector3(CENTER_CHAIR.x,navigation.ground(CENTER_CHAIR.x,CENTER_CHAIR.y)+.02,CENTER_CHAIR.y+.05)

## Minimum-spec headsets give up the dynamic shadow and surface detail, not the scene.
func set_low_end(value: bool) -> void:
	low_end=value
	if is_ready: _apply_quality()

var _probe_hidden: Array[Node3D] = []
## Debug A/B only (perf_tune beach_probe): hides node patterns and overrides shader
## parameters until the next probe; nothing is saved. Prints the scene inventory.
func debug_probe(probe: Dictionary) -> void:
	if not is_ready: return
	for node in _probe_hidden:
		if is_instance_valid(node): node.visible=true
	_probe_hidden.clear()
	for pattern in probe.get("hide",[]):
		for node in _content.find_children(str(pattern),"Node3D",true,false):
			if node.visible: node.visible=false; _probe_hidden.append(node)
	var overrides: Dictionary=probe.get("params",{})
	for material in _surfaces:
		for key in overrides: material.set_shader_parameter(key,overrides[key])
	for key in probe.get("sky_params",{}): _sky_material.set_shader_parameter(key,probe.sky_params[key])
	if probe.has("reflections"):
		background_environment.reflected_light_source=Environment.REFLECTION_SOURCE_BG if bool(probe.reflections) else Environment.REFLECTION_SOURCE_DISABLED
	if probe.has("sky_mode"): background_environment.sky.process_mode=int(probe.sky_mode)
	if bool(probe.get("dump",false)):
		var inventory := {}
		for mesh in _content.find_children("*","MeshInstance3D",true,false):
			var top: Node=mesh
			while top.get_parent()!=_content: top=top.get_parent()
			var entry: Dictionary=inventory.get_or_add(str(top.name),{"meshes":0,"triangle_vertices":0,"names":[]})
			entry.meshes+=1
			if mesh.mesh:
				entry.triangle_vertices+=mesh.mesh.get_faces().size()
			if entry.names.size()<12: entry.names.append(str(mesh.name))
		print("[BEACH_PROBE] ",JSON.stringify({"inventory":inventory,"hidden":_probe_hidden.size()}))
	else: print("[BEACH_PROBE] ",JSON.stringify({"hidden":_probe_hidden.size()}))

func _apply_quality() -> void:
	for material in _surfaces: material.set_shader_parameter("moving_shadow_enabled",not low_end)
	for material in _surfaces+[backdrop_material]:
		if material: material.shader=quality_shader(material.shader,low_end)

static func quality_shader(shader: Shader,low: bool) -> Shader:
	for high: Shader in LOW_SHADERS:
		if shader==high or shader==LOW_SHADERS[high]: return LOW_SHADERS[high] if low else high
	return shader

func _rect(value: Array) -> Vector4:
	return Vector4(value[0],value[1],value[2],value[3])

func _install_plants(plants: Node3D) -> void:
	var canopy := _material(FOLIAGE); var near := _material(FOLIAGE)
	for kind in ["color","alpha","normal"]:
		var image: Image=bundle.canopy_images[kind]
		if not OS.has_feature("etc2"):
			# Desktop GL cannot upload ETC2; decode the same data the headset uses.
			image=image.duplicate() as Image
			image.decompress()
		canopy.set_shader_parameter("leaf_"+kind,ImageTexture.create_from_image(image))
		near.set_shader_parameter("leaf_"+kind,bundle.textures["near_leaf_"+kind])
	near.set_shader_parameter("crown_volume_normals",false)
	for node in plants.find_children("*","MeshInstance3D",true,false):
		node.material_override=near if str(node.name).begins_with("Vegetation_NearLeaves") else canopy

func _grill_shift() -> Vector3:
	var authored: Vector3=_vector(bundle.study.grill_shadow_center)
	return Vector3(GRILL_SPOT.x-authored.x,navigation.ground(GRILL_SPOT.x,GRILL_SPOT.y)-navigation.ground(authored.x,authored.z),GRILL_SPOT.y-authored.z)

func _install_grill(grill: Node3D) -> void:
	var palette: Dictionary=bundle.study.grill_palette
	for node in grill.find_children("*","MeshInstance3D",true,false):
		for index in node.mesh.get_surface_count():
			var kind: String=node.mesh.surface_get_material(index).resource_name.trim_prefix("Grill_")
			var material := _material(GRILL)
			material.set_shader_parameter("base_color",_vector(palette[kind][0]))
			material.set_shader_parameter("surface_roughness",float(palette[kind][1]))
			material.set_shader_parameter("wooden_surface",kind=="Wood")
			material.set_shader_parameter("charcoal_surface",kind=="Coal")
			material.set_shader_parameter("wood_color",bundle.textures.wood_color)
			node.set_surface_override_material(index,material)

func _validate_scene(model: Node3D,props: Node3D) -> String:
	if model==null or props==null: return "Beach geometry has no spatial root"
	for scene in [model,props]:
		if not scene.find_children("*","Camera3D",true,false).is_empty() or not scene.find_children("*","Light3D",true,false).is_empty():
			return "Beach geometry must not carry cameras or lights"
	for name_ in ["Beach_Terrain","Screen_Front","Beach_Perimeter_Sea","Beach_Perimeter_Right","Beach_Perimeter_Rear","Beach_Perimeter_Left"]:
		if model.find_children(name_,"MeshInstance3D",true,false).size()!=1: return "Beach mesh missing: "+name_
	var meshes := props.find_children("*","MeshInstance3D",true,false)
	for required in ["Study_Chair_0","Study_Chair_1","Study_NearRock","Study_Table","Study_Lantern"]:
		if props.find_children(required,"MeshInstance3D",true,false).size()!=1: return "Beach prop missing: "+required
	for node in meshes:
		for index in node.mesh.get_surface_count():
			var material: Material = node.mesh.surface_get_material(index)
			if material==null or material.resource_name not in ["P1_Wood","P1_Cloth","P1_Metal","P1_Rock","P2_Diffuser"]:
				return "Unknown beach prop material"
	return ""

func _apply_lighting() -> void:
	if not is_ready: return
	var state: Dictionary=TimeOfDay.state(hours)
	var light: Dictionary=TimeOfDay.direct_light(hours)
	var direct: Color=light.color
	var ambient: Color=Color(.035,.055,.10).lerp(Color(.24,.32,.43),float(state.daylight))
	_night_mix=1.0-clampf(float(state.daylight),0.0,1.0)
	for material in _surfaces:
		material.set_shader_parameter("day_mix",state.daylight)
		material.set_shader_parameter("sun_direction",state.sun_direction)
		material.set_shader_parameter("moving_light_direction",light.direction)
		material.set_shader_parameter("moving_specular_tint",light.specular_tint)
		material.set_shader_parameter("moving_sun_color",Vector3(direct.r,direct.g,direct.b))
		material.set_shader_parameter("moving_ambient_color",Vector3(ambient.r,ambient.g,ambient.b))
		material.set_shader_parameter("moving_shadow_enabled",light.shadow_enabled and not low_end)
	for material in _sky_materials():
		material.set_shader_parameter("time_sun_direction",state.sun_direction)
		material.set_shader_parameter("time_moon_direction",-state.sun_direction)
	_sun.look_at(-(light.direction as Vector3),Vector3.UP)
	_sun.light_color=direct
	background_environment.ambient_light_energy=lerpf(.06,.4,float(state.daylight))
	_shadow_stale=true
	var available := _fireworks_available()
	_control.root.visible=available
	fireworks.set_enabled(available and presented)
	_apply_cloud_light()

func _sky_materials() -> Array:
	# Sky, its mesh backdrop and water reflections read one cloud and body state.
	var result: Array=[_sky_material,backdrop_material]
	for material in _animated:
		if quality_shader(material.shader,false)==WATER: result.append(material)
	return result

func _apply_cloud_light() -> void:
	_clouds.apply(_sky_materials())
	var light: Dictionary=TimeOfDay.direct_light(hours)
	var mix_: float=float(light.gain)*_clouds.transmission(light.direction,_cloud_image)
	for material in _surfaces: material.set_shader_parameter("moving_direct_mix",mix_)
	_sun.light_energy=mix_
