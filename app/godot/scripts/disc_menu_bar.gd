extends "res://scripts/ray_menu.gd"
## Under the screen while a disc menu plays: the remote's keys the menu itself lacks.
## It never becomes the active playback menu; main routes its pointer separately.
signal action_requested(action: String)
const TOP_MENU := 1
const RESUME := 2
const RESTART := 3
const EJECT := 4
const ACTIONS := {TOP_MENU: "top_menu", RESUME: "resume", RESTART: "restart", EJECT: "eject"}
var _key := ""

func _ready() -> void:
	super()
	ray_max_distance = 60.0 # it follows the screen, however far away
	visible = false

func _set_backdrop(size: Vector2, centre: Vector2 = Vector2.ZERO) -> void:
	_backdrop.mesh.size = size
	_backdrop.position = Vector3(centre.x, centre.y, 0)
	_backdrop.material_override.set_shader_parameter("surface_size", size)

func sync(shown: bool) -> void:
	visible = shown
	if not shown: return
	var key := str([I18n.language])
	if key == _key: return
	_key = key
	_clear_layout()
	_set_backdrop(Vector2(0.44, 0.10), Vector2.ZERO)
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	_round(TOP_MENU, "menu", Vector2(-0.15, 0), 0.075, true, false, I18n.t("Disc top menu · B"))
	_round(RESUME, "play", Vector2(-0.05, 0), 0.075, true, false, I18n.t("Continue watching"))
	_round(RESTART, "restart", Vector2(0.05, 0), 0.075, true, false, I18n.t("Play from the start"))
	_round(EJECT, "eject", Vector2(0.15, 0), 0.075, true, false, I18n.t("Eject disc"))

## Captured into its own sharp compositor plane like the other ray panels.
func composition_root() -> Node3D:
	return self

func _activate(target: int) -> void:
	if ACTIONS.has(target): action_requested.emit(ACTIONS[target])

## Seen just under the screen's bottom edge but kept at arm's length and real size,
## like the other ray panels: scaling it to the screen's distance would stretch its
## layer spacing past the sharp compositor planes (blurred tooltips in the cinema).
const REACH := 1.1
const DROP := 0.075
func place(panel: Node3D, screen: Vector2, head: Vector3) -> void:
	var up := panel.global_basis.y.normalized()
	var edge: Vector3 = panel.to_global(Vector3(0, -screen.y * 0.5, 0))
	var toward := edge - head
	if toward.length_squared() < 0.0001: return
	var reach := minf(toward.length(), REACH)
	var centre := head + toward.normalized() * reach - up * DROP
	var back := head - centre
	back -= up * back.dot(up)
	if back.length_squared() < 0.0001: back = panel.global_basis.z
	global_transform = Transform3D(Basis.looking_at(-back.normalized(), up), centre)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	# Pointing at the menu must not draw a second ray through this bar.
	super(hand, origin, direction, tracked and not pointer_hit(origin, direction).is_empty())
