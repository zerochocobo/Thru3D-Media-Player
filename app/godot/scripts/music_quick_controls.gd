extends RefCounted
## The entry stays in place when its compact transport opens beside it.
const PLAY := -5401
const ENTER_MS := 120
const LEAVE_MS := 650
const WIDTH := 0.66
var host: Node3D
var toggle_playback: Callable
var expanded := false
var active := false
var anchor := Vector2.ZERO
var open_target := 0
var _inside := {}
var _entered := {}
var _last_inside := 0

func _init(menu: Node3D, toggle_action: Callable) -> void:
	host = menu; toggle_playback = toggle_action

func reset() -> void:
	expanded = false; active = false; _inside.clear(); _entered.clear()

func begin_layout() -> void:
	active = false

func draw(target: int, point: Vector2, state: Dictionary) -> void:
	active = true; anchor = point; open_target = target
	if not expanded:
		host._round(target, "music", point, 0.08, true, false, host.I18n.t("Music"))
		if state.get("audio_active", false):
			host._buttons.back().base_color = Color(0.16, 0.31, 0.27)
			host._buttons.back().node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		return
	var centre := point - Vector2((WIDTH - 0.08) / 2, 0)
	var panel: MeshInstance3D = host._quad(Vector2(WIDTH, 0.115), Vector3(centre.x, centre.y, 0.004), host.PANEL, 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.035)
	host.add_child(panel); host._decorations.append(panel); host._block_rays(panel, Vector2(WIDTH, 0.115), 0.035)
	var title: String = host.I18n.t(str(state.get("audio_title", "Choose audio")))
	var label: Label3D = host._label(host._fit_title(title, "", 0.40, 20), Vector3(-WIDTH / 2 + 0.025, 0, 0.008), 20, panel)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.set_meta("music_text_width", 0.40)
	var paused: bool = state.get("audio_paused", true) or str(state.get("audio_current", "")).is_empty()
	host._round(PLAY, "play" if paused else "pause", point - Vector2(0.105, 0), 0.082, true, true, host.I18n.t("Play" if paused else "Pause"))
	host._buttons.back().node.position.z = 0.012
	host._round(target, "expand", point, 0.075, true, false, host.I18n.t("Manage music"))
	host._buttons.back().node.position.z = 0.012

func activate(target: int) -> bool:
	if not active or not expanded or target != PLAY: return false
	if toggle_playback.is_valid(): toggle_playback.call()
	return true

func update(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if not active or not host.visible:
		reset(); return
	var now := Time.get_ticks_msec()
	var hit: Dictionary = host.ray_hit(origin, direction) if tracked else {}
	var target := int(hit.get("target", host.NONE))
	var over := target == open_target or (expanded and target == PLAY)
	if expanded and not hit.is_empty() and target == host.NONE:
		var region := Rect2(anchor - Vector2(WIDTH - 0.04, 0.0575), Vector2(WIDTH, 0.115))
		over = region.has_point(Vector2(hit.point.x, hit.point.y))
	_inside[hand] = over
	if over:
		_last_inside = now
		if not _entered.has(hand): _entered[hand] = now
	else: _entered.erase(hand)
	var next := expanded
	if not expanded and over and now - int(_entered[hand]) >= ENTER_MS and not host.has_pointer_capture(): next = true
	elif expanded and not _inside.values().has(true) and now - _last_inside >= LEAVE_MS: next = false
	if next != expanded:
		expanded = next; host.refresh_music_quick_controls(); host.composition_layout_changed.emit()
