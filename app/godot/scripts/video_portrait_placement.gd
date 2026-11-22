extends RefCounted
## A separate viewing context. The user's distance and size are persistent; ordinary screen
## preferences and the auditorium placement are restored when this context ends.
var active := false
var pending := false
var saved := {}
var entry_pose := Transform3D.IDENTITY
var entry_scale := 1.0
var entry_distance := 2.0
var last_distance := 2.0
var last_scale := 1.0
var scenery_rig := Transform3D.IDENTITY
var cinema_presented := false
## Whose remembered distance and size the cutout uses: "" for ordinary backgrounds and scenes,
## otherwise the auditorium chosen as background (see context()).
var place_context := ""

const SECTION := "portrait_screen"

## The auditorium screens stand tens of metres away. A cutout placed there keeps its own distance
## and size, so an ordinary room never receives a person standing outside its walls.
static func context(host: Node) -> String:
	var choice := str(host.background.choice) if host.get("background") != null else ""
	return choice if choice in ["cinema", "private_beach"] and host.environment_for_background(choice) != null else ""

static func keys(place: String) -> PackedStringArray:
	return PackedStringArray(["distance", "scale"] if place.is_empty() else [place + "_distance", place + "_scale"])

## Earlier versions kept one distance for every background, so an auditorium's tens of metres
## put the person outside every room afterwards. Those values cannot be told apart: drop them once.
static func migrate(settings: ConfigFile) -> bool:
	if settings.get_value(SECTION, "contexts", 0) == 1: return false
	for key in ["distance", "scale"]:
		if settings.has_section_key(SECTION, key): settings.erase_section_key(SECTION, key)
	settings.set_value(SECTION, "contexts", 1)
	return true

static func capture(video: Node3D, follow: bool) -> Dictionary:
	return {"screen_distance": video.screen_distance, "screen_scale": video.screen_scale,
		"screen_rotation": video.screen_rotation, "screen_curve": video.screen_curve,
		"screen_preset": video.screen_preset, "pose": video.flat_pose, "follow": follow,
		"cinema": {"enabled": video.cinema.enabled, "bottom": video.cinema.bottom, "height": video.cinema.height,
			"placed": video.cinema.placed, "free_rotation": video.cinema.free_rotation}}

static func restore(host: Node, state: Dictionary) -> void:
	for key in ["screen_distance", "screen_scale", "screen_rotation", "screen_curve", "screen_preset"]: host.video.set(key, state[key])
	for key in state.cinema: host.video.cinema.set(key, state.cinema[key])
	host.view_follow.set_enabled(state.follow)
	host.video.flat_pose = state.pose
	host.video.portrait.reset()
	host.video._apply_geometry()

func prepare(host: Node) -> void:
	var video: Node3D = host.video
	if active and not pending and host._cinema_scene_active() == cinema_presented:
		# Record any ordinary locomotion before a synchronous background switch.
		scenery_rig = host.xr_camera.get_parent().global_transform
	var wanted: bool = video != null and not host.photo_active and video.has_active_presentation() \
		and video.flat_passthrough_requested() and not (host.puzzle_game and host.puzzle_game.active)
	if wanted == active: return
	if wanted:
		var head: Variant = host._head_pose()
		if not head is Transform3D: return # Retry once tracking is available.
		var world: Transform3D = video.global_transform * video.flat_pose
		entry_pose = head.affine_inverse() * world
		entry_distance = (head.origin - world.origin).dot(world.basis.z.normalized())
		entry_scale = video.screen_scale
		saved = host._cinema_screen_saved.duplicate(true) if not host._cinema_screen_saved.is_empty() else capture(video, host.view_follow.enabled)
		active = true; pending = true
	else:
		active = false; pending = false
		restore(host, saved)
		saved = {}
	host.interface_move.cancel(); host._grab.clear(); host.stick_controls.suspend()
	host.interface_move.placements.erase(&"video_portrait")
	host.view_follow.forget(&"video_portrait")

func finish(host: Node) -> void:
	if not active: return
	var rig: Transform3D = host.xr_camera.get_parent().global_transform
	var cinema: bool = host._cinema_scene_active()
	if not pending:
		var place := context(host)
		var head_now: Variant = host._head_pose()
		if place.is_empty() and not place_context.is_empty() and head_now is Transform3D:
			# Leaving an auditorium: carrying its tens of metres would put the person outside the
			# new room. Start again in front, from the ordinary screen this session began with.
			_enter_ahead(host, head_now)
		else:
			# Showing/hiding the hall seats/restores the XR rig, also after async loading.
			# Carry the cutout into that coordinate system without changing its viewed pose.
			if cinema != cinema_presented or not rig.is_equal_approx(scenery_rig):
				host.video.set_flat_world_pose(rig * scenery_rig.affine_inverse() * host.video.global_transform * host.video.flat_pose)
			scenery_rig = rig; cinema_presented = cinema; place_context = place
			return
	var head: Variant = host._head_pose()
	if not head is Transform3D: return
	pending = false
	scenery_rig = rig; cinema_presented = cinema
	place_context = context(host)
	var names := keys(place_context)
	var video: Node3D = host.video
	var value: Variant = host.settings.get_value(SECTION, names[0], entry_distance)
	var distance := entry_distance
	if (value is float or value is int) and is_finite(float(value)) and float(value) >= video.DISTANCE_LIMITS.x and float(value) <= video.DISTANCE_LIMITS.y:
		distance = float(value)
	distance = clampf(distance, video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y)
	var scale_value: Variant = host.settings.get_value(SECTION, names[1], entry_scale)
	var scale := entry_scale
	if (scale_value is float or scale_value is int) and is_finite(float(scale_value)) and float(scale_value) >= video.SCALE_LIMITS.x and float(scale_value) <= video.SCALE_LIMITS.y:
		scale = float(scale_value)
	var pose: Transform3D = head * entry_pose
	if cinema and host._alpha_keep_background() and entry_distance > 0.001:
		# The auditorium screen is elevated. Restoring a nearby, smaller portrait
		# along its normal would leave it overhead and outside the field of view.
		pose.origin = head.origin + (pose.origin - head.origin) * (distance / entry_distance)
	else:
		pose.origin += pose.basis.z.normalized() * (entry_distance - distance)
	video.cinema.enabled = false; video.cinema.bottom = null
	video.screen_preset = ""; video.screen_curve = 0.0
	video.screen_scale = scale; video.screen_distance = distance
	last_distance = distance; last_scale = scale
	host.view_follow.set_enabled(false)
	video.portrait.reset()
	video.set_flat_world_pose(pose)
	video._apply_geometry()

func remember(host: Node) -> void:
	if not active or pending or (host.video.portrait_requested() and host.video.portrait.automatic): return
	# Each dimension is independent: changing one must not pin the other's inherited value.
	# Saving sound/colour or moving one's head creates neither preference.
	var names := keys(place_context)
	var value: float = host.video.screen_distance
	if is_finite(value) and not is_equal_approx(value, last_distance):
		last_distance = value
		host.settings.set_value(SECTION, names[0], clampf(value, host.video.DISTANCE_LIMITS.x, host.video.DISTANCE_LIMITS.y))
	var scale: float = host.video.screen_scale
	if is_finite(scale) and not is_equal_approx(scale, last_scale):
		last_scale = scale
		host.settings.set_value(SECTION, names[1], clampf(scale, host.video.SCALE_LIMITS.x, host.video.SCALE_LIMITS.y))

## A new placement straight ahead at the ordinary screen's distance and size; finish() then
## applies the ordinary remembered values over them, as on a fresh entry.
func _enter_ahead(host: Node, head: Transform3D) -> void:
	var distance := float(saved.get("screen_distance", 2.0)) if saved.get("screen_distance") is float else 2.0
	var scale := float(saved.get("screen_scale", 1.0)) if saved.get("screen_scale") is float else 1.0
	entry_distance = clampf(distance, host.video.DISTANCE_LIMITS.x, host.video.DISTANCE_LIMITS.y)
	entry_scale = clampf(scale, host.video.SCALE_LIMITS.x, host.video.SCALE_LIMITS.y)
	var ahead: Variant = host._view_pose(entry_distance, 0.0)
	entry_pose = head.affine_inverse() * ahead if ahead is Transform3D else Transform3D(Basis.IDENTITY, Vector3(0, 0, -entry_distance))
	pending = true
