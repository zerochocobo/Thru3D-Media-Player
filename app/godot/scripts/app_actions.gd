extends Node
## Shared footer popup and confirmation state for every production ray menu.
const I18n := preload("res://scripts/i18n.gd")
const Palette := preload("res://scripts/ui_theme.gd")
const Usage := preload("res://scripts/session_usage.gd")
const STATUS := -5601
const RESTART := -5602
const QUIT := -5603
const CANCEL := -5604
const CORRIDOR := -5605
const LEGACY_CANCEL := -5606
const ENTER_MS := 250
const LEAVE_MS := 700
const CONFIRM_MS := 5000
const SIZE := Vector2(0.36, 0.205)
const ACTIONS := {RESTART: "restart_app", QUIT: "quit_app"}
var host: Node3D
var expanded := false
var armed := ""
var busy := ""
var error := false
var now_provider: Callable = Time.get_ticks_msec
var _entered := {}
var _last_inside := 0
var _armed_at := 0
var _owner := ""
var _released := false
var _down := {}
var _panel: MeshInstance3D
var _caption: Label3D
var _duration: Label3D
var _arrow: MeshInstance3D
var _bindings := {}
var _minute := -1
var _hover_closed := false

func _init(menu: Node3D) -> void: host = menu

func _ready() -> void:
	host.visibility_changed.connect(func():
		if not host.is_visible_in_tree(): reset())

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT]: reset(true)

func reset(defer_visuals: bool = false) -> void:
	if not expanded and armed.is_empty() and busy.is_empty() and not error and _entered.is_empty() and _down.is_empty(): return
	expanded = false; armed = ""; busy = ""; error = false
	_entered.clear(); _down.clear(); _owner = ""; _released = false
	_hover_closed = false
	if defer_visuals: redraw.call_deferred()
	else: redraw()

func begin_layout() -> void:
	# A page change or rebuild must never carry a pending destructive action.
	expanded = false; armed = ""; error = false
	_hover_closed = false
	_entered.clear(); _bindings.clear(); _owner = ""; _released = false
	if is_instance_valid(_arrow): _arrow.free()
	_panel = null; _caption = null; _duration = null; _arrow = null

func draw_anchor() -> void:
	if is_instance_valid(_arrow): _arrow.free()
	var status: Node3D = host.device_status
	var width: float = status._pill.mesh.size.x
	host._text_button(STATUS, "", host._footer_centre, Vector2(width, status.HEIGHT))
	_arrow = host._icon("chevron_down", Vector3(width / 2 - 0.020, 0, 0.006), 0.018, Palette.color("muted"), status)
	refresh_visuals()

func bind_button(target: int, operation: String) -> void:
	_bindings[target] = operation
	refresh_visuals()

func is_action(target: int) -> bool:
	return ACTIONS.has(target) or _bindings.has(target)

func redraw() -> void:
	if not is_instance_valid(host.device_status): return
	for index in range(host._buttons.size() - 1, -1, -1):
		var button: Dictionary = host._buttons[index]
		if button.target not in [RESTART, QUIT, CANCEL, CORRIDOR]: continue
		button.node.free(); host._buttons.remove_at(index)
	if is_instance_valid(_panel):
		host._decorations.erase(_panel)
		host._ray_blockers = host._ray_blockers.filter(func(item): return item.node != _panel)
		_panel.free()
	_panel = null; _caption = null; _duration = null
	if expanded:
		host._text_button(CORRIDOR, "", host._footer_centre - Vector2(0, 0.11), Vector2(SIZE.x, 0.31), false)
		host._buttons.back().node.position.z = 0.001
		host._buttons.back()["hover_disabled"] = true
		var centre: Vector2 = host._footer_centre - Vector2(0, host.device_status.HEIGHT / 2 + 0.012 + SIZE.y / 2)
		_panel = host._quad(SIZE, Vector3(centre.x, centre.y, 0.002), host.PANEL, 30)
		_panel.material_override.set_shader_parameter("corner_radius", 0.023)
		host.add_child(_panel); host._decorations.append(_panel); host._block_rays(_panel, SIZE, 0.023)
		_caption = host._label("", Vector3(-SIZE.x / 2 + 0.018, 0.061, 0.004), 18, _panel)
		_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; _caption.render_priority = 32
		_duration = host._label("", Vector3(SIZE.x / 2 - 0.018, 0.061, 0.004), 18, _panel)
		_duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; _duration.render_priority = 32
		for item in [{"target": RESTART, "x": -0.085, "icon": "refresh"}, {"target": QUIT, "x": 0.085, "icon": "close"}]:
			host._button(item.target, "", centre + Vector2(item.x, -0.031), Vector2(0.154, 0.090), busy.is_empty(), item.icon)
			var face: MeshInstance3D = host._buttons.back().node
			face.position.z = 0.008
			var label: Label3D = face.get_child(0)
			label.position = Vector3(0, -0.021, 0.004)
			host.set_label_size(label, 18)
			var icon: MeshInstance3D = face.get_child(1)
			icon.position = Vector3(0, 0.019, 0.004); icon.mesh.size = Vector2.ONE * 0.026
			popup_priority(face)
		if host.scene_overlay: host._apply_overlay_node(_panel)
	host._buttons_generation += 1
	refresh_visuals()
	host.composition_layout_changed.emit()

func popup_priority(node: Node, priority: int = 31) -> void:
	# Keep foreground above its tile, as RayMenu._button does (12 over 11).
	# Equal priorities let transparent sorting cover icons at oblique views.
	if node is GeometryInstance3D and node.material_override: node.material_override.render_priority = priority
	if node is Label3D: node.render_priority = priority
	for child in node.get_children(): popup_priority(child, priority + 1)

func title(operation: String) -> String:
	if busy == operation: return I18n.t("Restarting…" if operation == "restart_app" else "Exiting…")
	if armed == operation: return I18n.t("Restart?" if operation == "restart_app" else "Exit?")
	return I18n.t("Restart" if operation == "restart_app" else "Exit")

func refresh_visuals() -> void:
	if is_instance_valid(_arrow):
		_arrow.rotation.z = PI if expanded else 0.0
		_arrow.material_override.albedo_color = host.ACCENT if expanded or not _entered.is_empty() else Palette.color("muted")
	if is_instance_valid(host.device_status):
		var plate: MeshInstance3D = host.device_status._pill
		plate.material_override.set_shader_parameter("hovered", false)
		plate.material_override.set_shader_parameter("surface_color", Color(host.PANEL.lerp(host.TILE, 0.35 if not _entered.is_empty() else 0.0), 0.86))
	if is_instance_valid(_caption):
		var minutes := Usage.milliseconds() / 60000
		_minute = minutes
		var time := I18n.t("%dh %dm") % [minutes / 60, minutes % 60] if minutes >= 60 else I18n.t("%dm") % minutes
		_caption.text = I18n.t("Could not save. Try again.") if error else I18n.t("This session")
		_caption.modulate = Palette.color("danger") if error else Palette.color("muted")
		_duration.text = time; _duration.visible = not error
	for button in host._buttons:
		var target: int = button.target
		if target in [CANCEL, LEGACY_CANCEL]:
			button.node.visible = not armed.is_empty() and busy.is_empty()
			continue
		var operation: String = ACTIONS.get(target, _bindings.get(target, ""))
		if operation.is_empty(): continue
		button.enabled = busy.is_empty()
		var confirm := armed == operation
		var danger := confirm and operation == "quit_app"
		button.base_color = Palette.color("selected") if confirm and not danger else host.TILE
		button["hover_color"] = Palette.color("hover")
		button.foreground = Palette.color("text").lerp(Palette.color("danger"), 0.60) if danger else Palette.color("text")
		var material: ShaderMaterial = button.node.material_override
		material.set_shader_parameter("marker_outline", Color(button.foreground, 0.35) if confirm else Color.TRANSPARENT)
		for child in button.node.get_children():
			if child is Label3D:
				child.text = title(operation); child.modulate = button.foreground
				if target in [RESTART, QUIT]:
					var font_size := 18
					while font_size > 16 and host.text_width(child.text, font_size) > 0.138: font_size -= 1
					host.set_label_size(child, font_size)
			elif child is MeshInstance3D:
				child.material_override.albedo_color = button.foreground
				if not child.has_meta("app_action_icon"): child.set_meta("app_action_icon", child.material_override.albedo_texture)
				child.material_override.albedo_texture = host.Icons.texture("check") if confirm else child.get_meta("app_action_icon")
	host._update_highlights()
	host.composition_changed.emit()

func update(hand: String, hit: Dictionary, tracked: bool = true) -> void:
	if not tracked: cancel_hand(hand)
	var now: int = now_provider.call()
	var target := int(hit.get("target", host.NONE))
	var over := target == STATUS or (expanded and target in [RESTART, QUIT, CANCEL])
	if expanded and not hit.is_empty():
		# Continuous corridor from the status card through the gap to the whole popup.
		var top: Vector2 = host._footer_centre + Vector2(-SIZE.x / 2, host.device_status.HEIGHT / 2)
		over = over or Rect2(Vector2(top.x, top.y - 0.31), Vector2(SIZE.x, 0.31)).has_point(Vector2(hit.point.x, hit.point.y))
	if over:
		_last_inside = now
		if not _entered.has(hand): _entered[hand] = now; refresh_visuals()
		if not expanded and not _hover_closed and now - int(_entered[hand]) >= ENTER_MS and not captured():
			expanded = true; redraw()
	else:
		if _entered.has(hand): _entered.erase(hand); refresh_visuals()
		if _entered.is_empty(): _hover_closed = false
	tick(now)

func captured() -> bool:
	return host.has_method("has_pointer_capture") and host.has_pointer_capture()

func _process(_delta: float) -> void:
	if not host.is_visible_in_tree(): return
	tick(now_provider.call())
	if expanded and Usage.milliseconds() / 60000 != _minute: refresh_visuals()

func tick(now: int) -> void:
	if not armed.is_empty() and now - _armed_at >= CONFIRM_MS:
		armed = ""; _owner = ""; refresh_visuals()
	if expanded and busy.is_empty() and now - _last_inside >= (CONFIRM_MS if error else LEAVE_MS):
		expanded = false; armed = ""; _entered.clear(); redraw()

func activate(target: int, hand: String) -> bool:
	var operation: String = ACTIONS.get(target, _bindings.get(target, ""))
	if target not in [STATUS, CANCEL, LEGACY_CANCEL] and operation.is_empty():
		if not armed.is_empty(): armed = ""; refresh_visuals()
		return false
	if not busy.is_empty(): return true
	var now: int = now_provider.call()
	tick(now)
	if target == STATUS:
		expanded = not expanded; _hover_closed = not expanded
		armed = ""; _last_inside = now; redraw(); return true
	if target in [CANCEL, LEGACY_CANCEL]:
		armed = ""; error = false; refresh_visuals(); return true
	if hand.is_empty() or _down.has(hand): return true
	_down[hand] = true
	if armed == operation and hand == _owner and _released:
		busy = operation; armed = ""; refresh_visuals()
		host.app_action_requested.emit(operation)
	else:
		armed = operation; _armed_at = now; _owner = hand; _released = false; error = false
		refresh_visuals()
	host.app_action_feedback.emit(hand)
	return true

func release(hand: String) -> void:
	_down.erase(hand)
	if hand == _owner: _released = true

func cancel_hand(hand: String) -> void:
	if not _down.has(hand) and not _entered.has(hand) and hand != _owner: return
	_down.erase(hand); _entered.erase(hand)
	if hand == _owner: armed = ""; _owner = ""; _released = false
	refresh_visuals()

func failed() -> void:
	busy = ""; armed = ""; error = true; expanded = true
	_last_inside = now_provider.call()
	redraw()
