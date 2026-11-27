extends RefCounted
## Placement is relative to the seated room. Screen size is a fraction of the
## picture fitted into the stone arch, so changing films preserves its proportions.
const SECTION := "magic_cottage"
const HOME := Transform3D(Basis.IDENTITY, Vector3(0, 1.75, -4.725))
const SEAT := Vector3(0, 1.15, 1.82)
const DEFAULTS := {"near":1.2, "far":6.6, "minimum":35., "maximum":135., "play_dim":.25}
const RANGES := {"near":Vector3(.6, 4., .1), "far":Vector3(2., 6.6, .1),
	"minimum":Vector3(20., 100., 5.), "maximum":Vector3(100., 160., 5.)}
var attached := false
var dirty := false
var changed_at := 0
var local_pose := HOME
var factor := 1.
var angle := 0.
var last_world := Transform3D.IDENTITY
var last_frame := Transform3D.IDENTITY
var last_scale := 1.
var last_angle := 0.
var last_uri := ""
var last_session := -1
var limits := DEFAULTS.duplicate()

static func option(config: ConfigFile, key: String) -> float:
	var value: Variant = config.get_value(SECTION, key, DEFAULTS[key])
	if not (value is float or value is int) or not is_finite(float(value)): return DEFAULTS[key]
	if key == "play_dim": return value if float(value) in [1., .5, .25, .1] else DEFAULTS[key]
	var span: Vector3 = RANGES[key]
	return clampf(value, span.x, span.y)

func load_options(config: ConfigFile) -> void:
	for key in DEFAULTS: limits[key] = option(config, key)
	limits.far = maxf(limits.far, limits.near + .1)

func attach(config: ConfigFile) -> void:
	load_options(config)
	var saved: Variant = config.get_value(SECTION, "pose", HOME)
	local_pose = HOME
	if saved is Transform3D and saved.is_finite() and saved.basis.determinant() > .001:
		local_pose = saved.orthonormalized()
	var size: Variant = config.get_value(SECTION, "scale", 1.)
	factor = float(size) if (size is float or size is int) and is_finite(float(size)) else 1.
	var roll: Variant = config.get_value(SECTION, "rotation", 0.)
	angle = float(roll) if (roll is float or roll is int) and is_finite(float(roll)) else 0.

func mark_changed() -> void:
	dirty = true
	changed_at = Time.get_ticks_msec()

func sync(video: Node3D, frame: Transform3D, config: ConfigFile) -> void:
	if not attached: attach(config)
	var world: Transform3D = video.global_transform * video.flat_pose
	if attached and last_uri == video.local_uri and last_session == video.media.session_id:
		if not world.is_equal_approx(last_world):
			local_pose = (last_frame.affine_inverse() * world).orthonormalized()
			mark_changed()
		if not is_equal_approx(video.screen_scale, last_scale):
			factor *= video.screen_scale / last_scale
			mark_changed()
		if not is_equal_approx(video.screen_rotation, last_angle):
			angle = video.screen_rotation
			mark_changed()
	var base: Vector2 = video._screen_base
	var fit := minf(4.5 / maxf(.01, base.x), 2.55 / maxf(.01, base.y))
	var oriented := local_pose.basis * Basis(Vector3.FORWARD, deg_to_rad(angle))
	var half_extents := (oriented.x.abs() * base.x + oriented.y.abs() * base.y) * (.5 * fit)
	# All four corners stay above the floor and inside the stone walls, even after a quarter turn.
	var room_limit := minf(4.55 / maxf(.01, half_extents.x), 2.28 / maxf(.01, half_extents.y))
	var largest := minf(room_limit, limits.maximum / 100.)
	factor = clampf(factor, minf(limits.minimum / 100., largest), largest)
	var extents := half_extents * factor
	var pos := local_pose.origin
	pos.x = clampf(pos.x, -4.55 + extents.x, 4.55 - extents.x)
	pos.y = clampf(pos.y, .08 + extents.y, 4.64 - extents.y)
	var wall_z := -4.87 + extents.z
	pos.z = maxf(wall_z, clampf(pos.z, SEAT.z - limits.far, SEAT.z - limits.near))
	local_pose.origin = pos
	last_world = frame * local_pose
	last_frame = frame
	last_uri = video.local_uri
	last_session = video.media.session_id
	last_scale = fit * factor
	last_angle = angle
	video.cinema.enabled = false
	video.screen_preset = ""
	if not is_equal_approx(video.screen_scale, last_scale) or not is_equal_approx(video.screen_rotation, angle) or video.screen_curve != 0. or video.curve_radius != 0.:
		video.screen_scale = last_scale
		video.screen_rotation = angle
		video.screen_curve = 0.
		video.curve_radius = 0.
		video._apply_geometry()
	if not world.is_equal_approx(last_world): video.set_flat_world_pose(last_world)
	video.screen_distance = pos.distance_to(SEAT)
	attached = true
	if dirty:
		config.set_value(SECTION, "pose", local_pose)
		config.set_value(SECTION, "scale", factor)
		config.set_value(SECTION, "rotation", angle)

func flush(config: ConfigFile, path: String, force: bool = false) -> void:
	if dirty and (force or Time.get_ticks_msec() - changed_at >= 650):
		if config.save(path) == OK: dirty = false

func detach(config: ConfigFile, path: String) -> void:
	flush(config, path, true)
	attached = false

func change(config: ConfigFile, key: String, value: Variant) -> bool:
	if key == "reset":
		for field in ["pose", "scale", "rotation"]:
			if config.has_section_key(SECTION, field): config.erase_section_key(SECTION, field)
		dirty = false
		attached = false
		return true
	if not DEFAULTS.has(key) or not (value is int or value is float) or not is_finite(float(value)): return false
	if key == "play_dim":
		if float(value) not in [1., .5, .25, .1]: return false
	else:
		var range_value: Vector3 = RANGES[key]
		value = clampf(snappedf(value, range_value.z), range_value.x, range_value.y)
		if key == "near": value = minf(value, option(config, "far") - .1)
		if key == "far": value = maxf(value, option(config, "near") + .1)
	config.set_value(SECTION, key, value)
	load_options(config)
	if attached and key != "play_dim": mark_changed()
	return true
