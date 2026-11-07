extends "res://scripts/ray_menu.gd"
## Independent HD controls, below the page and clear of its resize handles.
const MATTE := 986021
const DEPTH := 986016
const STRENGTH := 986022
const FOCUS := 986019
const BOOST := 986023
const OFF := 986024
const CHROME := 986025
const KEYBOARD := 986026
const SLIDER_X := 0.15
const ENTER_MS := 120
const LEAVE_MS := 650
# PlayerMenu._draw_depth: the normal 0–100% rail rises from the icon;
# Boost adds the separate amber 100–200% segment above it.
const RAIL := Vector2(0.16, 0.40)
const BOOST_HEIGHT := 0.14
const BOOST_BUTTON_SIZE := Vector2(0.078, 0.052)
var window_ref: WeakRef
var near_hands := {}
var entered := -1
var last_near := -1
var capture_hand := ""
var state_key: Array = []
var fill: MeshInstance3D
var knob: MeshInstance3D
var value_label: Label3D
var boost_fill: MeshInstance3D
var boosted := false
var busy_ring: MeshInstance3D
var strength_open := false
var host: Node3D:
	get: return window_ref.get_ref() if window_ref else null

func configure(window: Node3D) -> void:
	window_ref = weakref(window)
	set_meta("browser_world_pointer", true)
	set_meta("menu_capture_region", "browser_effects_%d" % window.window_id)
	set_meta("menu_capture_tight", true)
	set_meta("menu_capture_priority", 1)
	ray_max_distance = 100.0

func _ready() -> void:
	super(); _backdrop.visible = false; refresh()

func sync(now: int = -1) -> void:
	if not host or not host.visible or (host.browser.start_page.active(host.window_id) and host.toolbar_shown and not host.depth.enabled and not host.depth.matte):
		finish_drag(); _hide_controls(); near_hands.clear(); entered = -1; last_near = -1; return
	var layout: Dictionary = host.full_page_layout()
	var factor: float = float(layout.size.x) / host.page_size.x
	var pose: Transform3D = layout.pose * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * factor), Vector3(0, -layout.size.y / 2 - 0.28 * factor, 0.03 * factor))
	if not global_transform.is_equal_approx(pose):
		global_transform = pose; composition_layout_changed.emit()
	if not host.depth.enabled: strength_open = false
	if host.depth.strength > host.depth.Strength.MAX: boosted = true
	var next := _state()
	if next != state_key: state_key = next; refresh()
	_refresh_strength()
	if busy_ring: busy_ring.visible=depth_preparing()
	_tips[DEPTH]=I18n.t("Starting 3D" if depth_preparing() else "2D to 3D effect")
	_update_tooltip()
	if now < 0: now = Time.get_ticks_msec()
	var near := not capture_hand.is_empty() or near_hands.values().has(true)
	if near:
		last_near = now
		if entered < 0: entered = now
		if now - entered >= ENTER_MS or not capture_hand.is_empty():
			if not visible: visible = true; composition_layout_changed.emit()
	else:
		entered = -1
		if last_near < 0 or now - last_near >= LEAVE_MS: _hide_controls()

func _state() -> Array:
	return [host.toolbar_shown,host.depth.enabled,host.depth.matte,host.selecting,host.is_focused(),host.browser.keyboard_visible(host.window_id),boosted,strength_open,I18n.language] if host else []

func set_strength_open(value: bool) -> void:
	if strength_open == value: return
	strength_open=value; refresh()

func _hide_controls() -> void:
	var shown:=visible
	visible=false; set_strength_open(false); clear_pointer_visuals()
	if shown: composition_layout_changed.emit()

func observe_ray(hand: String, origin: Vector3, direction: Vector3, tracked: bool, now: int = -1) -> void:
	var near := false
	if tracked and host and host.visible:
		var uv: Variant = host.page_point(origin, direction)
		near = uv != null and Rect2(0,0,1,1).has_point(uv)
		var point: Variant = project_pointer(origin, direction, Transform3D.IDENTITY, false)
		if point != null:
			near = near or Rect2(-0.38,-0.065,0.76,0.13).has_point(Vector2(point.x,point.y))
			if host.depth.enabled and strength_open: near = near or strength_bounds().has_point(Vector2(point.x,point.y))
	near_hands[hand] = near
	sync(now)
	var hit: Dictionary = host.ray_hit(origin,direction) if tracked and host else {}
	_hover[hand]=int(hit.target) if hit.get("footer",false) and int(hit.get("window",0))==host.window_id else NONE
	_update_highlights()

func depth_preparing() -> bool:
	return host and host.depth.enabled and host.depth.state!="ready" and host.depth.error.is_empty()

func _draw() -> void:
	state_key = _state()
	_clear_layout(); fill = null; knob = null; value_label = null; boost_fill = null; busy_ring = null
	_backdrop.visible = false
	if not host: return
	var focus_icon := "close" if host.selecting else "expand" if host.is_focused() else "region_focus"
	var focus_tip := "Cancel selection" if host.selecting else "Exit focus" if host.is_focused() else "Focus region"
	for item in [[CHROME,"browser_frame",-0.30,not host.toolbar_shown,"Hide browser frame" if host.toolbar_shown else "Show browser frame"],[FOCUS,focus_icon,-0.15,host.selecting or host.is_focused(),focus_tip],[MATTE,"alpha",0.0,host.depth.matte,"Person passthrough"],[DEPTH,"depth",0.15,host.depth.enabled,"2D to 3D effect"]]:
		_button(item[0],"",Vector2(item[2],0),Vector2.ONE*0.12,not host.page_input_blocked() if item[0]==FOCUS else true,item[1],item[3])
		_tips[item[0]] = I18n.t(item[4])
		if item[0]==DEPTH:
			busy_ring=preload("res://scripts/ui_busy_ring.gd").create(_buttons.back().node,0.12,ACCENT)
			busy_ring.set_meta("menu_eye_buffer",true) # shader-clock animation stays live
			busy_ring.visible=depth_preparing()
			_tips[DEPTH]=I18n.t("Starting 3D" if depth_preparing() else "2D to 3D effect")
	var keyboard_shown: bool = host.browser.keyboard_visible(host.window_id)
	_button(KEYBOARD,"",Vector2(0.30,0),Vector2.ONE*0.12,true,"keyboard_hide" if keyboard_shown else "keyboard",keyboard_shown)
	_tips[KEYBOARD] = I18n.t("Close keyboard" if keyboard_shown else "Show keyboard")
	if not host.depth.enabled or not strength_open: return
	var before := get_children()
	var top := RAIL.y + (BOOST_HEIGHT if boosted else 0.0)
	var cap_y := top + 0.09
	var bounds := strength_bounds()
	var panel := _quad(bounds.size,Vector3(bounds.get_center().x,bounds.get_center().y,0.001),Color(PANEL,1.0),10)
	panel.material_override.set_shader_parameter("corner_radius",0.05)
	add_child(panel); _decorations.append(panel); _block_rays(panel,panel.mesh.size,0.04)
	_button(STRENGTH,"",Vector2(SLIDER_X,(RAIL.x+top)/2),Vector2(0.11,top-RAIL.x+0.04))
	var button: Dictionary = _buttons.back()
	button.base_color = Color(TILE,0); button.node.material_override.set_shader_parameter("surface_color",button.base_color)
	var rail := _quad(Vector2(0.012,RAIL.y-RAIL.x),Vector3(SLIDER_X,(RAIL.x+RAIL.y)/2,0.004),UiTheme.color("track"),14)
	add_child(rail); _decorations.append(rail)
	_decoration(Vector2(0.035,0.003),Vector2(SLIDER_X,RAIL.y),MUTED)
	var recommended := lerpf(RAIL.x,RAIL.y,host.depth.Strength.VIDEO_DEFAULT)
	_decoration(Vector2(0.05,0.004),Vector2(SLIDER_X,recommended),ACCENT)
	_icon("star_filled",Vector3(SLIDER_X-0.048,recommended,0.004),0.022,ACCENT)
	fill = _quad(rail.mesh.size,rail.position,ACCENT,15); add_child(fill); _decorations.append(fill)
	if boosted:
		_decoration(Vector2(0.012,BOOST_HEIGHT),Vector2(SLIDER_X,RAIL.y+BOOST_HEIGHT/2),Color(UiTheme.color("warning"),0.35))
		boost_fill = _quad(Vector2(0.012,BOOST_HEIGHT),Vector3(SLIDER_X,RAIL.y+BOOST_HEIGHT/2,0.004),UiTheme.color("warning"),15)
		add_child(boost_fill); _decorations.append(boost_fill)
		_decoration(Vector2(0.08,0.004),Vector2(SLIDER_X,RAIL.y),UiTheme.color("track_tick"))
	knob = _quad(Vector2.ONE*0.03,Vector3(SLIDER_X,RAIL.x,0.006),UiTheme.color("knob"),17)
	_style_slider_marker(knob); knob.material_override.set_shader_parameter("corner_radius",0.015); add_child(knob); _decorations.append(knob)
	value_label = _label("",Vector3(SLIDER_X,top+0.038,0.006),16)
	_button(BOOST,I18n.t("Boost"),Vector2(SLIDER_X,cap_y),BOOST_BUTTON_SIZE,true,"",boosted)
	var caption: Label3D = _buttons.back().node.get_child(0)
	var font_size := 13
	while font_size>10 and text_width(caption.text,font_size)>BOOST_BUTTON_SIZE.x-0.014: font_size -= 1
	set_label_size(caption,font_size)
	caption.modulate = UiTheme.color("warning") if boosted else UiTheme.color("label")
	_round(OFF,"power",Vector2(SLIDER_X,RAIL.x-0.055),0.075,true,false,I18n.t("Turn off 3D"))
	var power: Dictionary = _buttons.back()
	power.base_color=UiTheme.color("danger_surface");power.foreground=UiTheme.color("danger")
	power.node.material_override.set_shader_parameter("surface_color",power.base_color)
	power.node.get_child(1).material_override.albedo_color=power.foreground
	for child in get_children():
		if child is Node3D and not before.has(child):
			child.position.z += 0.02
			_raise_rail(child)
	_refresh_strength()

func strength_bounds() -> Rect2:
	var bottom := RAIL.x-0.095
	var top := RAIL.y+(BOOST_HEIGHT if boosted else 0.0)+0.128
	return Rect2(SLIDER_X-0.065,bottom,0.13,top-bottom)

func _raise_rail(node: Node) -> void:
	# The independent XR texture is behind the eye buffer. Its coverage mask
	# must also clear the browser frame (10), page hole (25) and near chrome (26).
	node.set_meta("menu_hole_priority",29)
	if node is MeshInstance3D and node.material_override: node.material_override.render_priority += 20
	elif node is Label3D: node.render_priority += 20
	for child in node.get_children(): _raise_rail(child)

func _refresh_strength() -> void:
	if not knob or not host: return
	var value: float = host.depth.Strength.to_fraction(host.depth.strength)
	var extra: float = clampf(host.depth.strength-1.0,0,1) if boosted else 0.0
	knob.position.y = RAIL.y+BOOST_HEIGHT*extra if extra>0 else lerpf(RAIL.x,RAIL.y,value)
	knob.material_override.set_shader_parameter("surface_color",UiTheme.color("warning") if extra>0 else UiTheme.color("knob"))
	fill.mesh.size.y = maxf(0.001,(RAIL.y-RAIL.x)*value)
	fill.position.y = RAIL.x+fill.mesh.size.y/2
	fill.material_override.set_shader_parameter("surface_size",fill.mesh.size)
	value_label.text = "%d%%" % roundi(host.depth.strength*100)
	value_label.modulate = UiTheme.color("warning") if extra>0 else UiTheme.color("label")
	if boost_fill:
		boost_fill.visible = extra>0
		boost_fill.mesh.size.y = maxf(0.001,BOOST_HEIGHT*extra)
		boost_fill.position.y = RAIL.y+boost_fill.mesh.size.y/2
		boost_fill.material_override.set_shader_parameter("surface_size",boost_fill.mesh.size)

func _activate(target: int) -> void:
	if target in [CHROME,FOCUS,MATTE,KEYBOARD]: host._activate(target)
	elif target == DEPTH:
		if host.depth.enabled: set_strength_open(not strength_open)
		else: host._activate(DEPTH)
	elif target == OFF:
		if host.depth.enabled: host._activate(DEPTH)
	elif target == BOOST:
		boosted = not boosted
		if not boosted and host.depth.strength>1.0: host._depth_changed("strength",100.0)
		refresh()

func has_pointer_capture() -> bool: return not capture_hand.is_empty()
func drag_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture_hand != hand: return
	if not tracked: finish_drag(); return
	var point: Variant = project_pointer(origin,direction,Transform3D.IDENTITY,false)
	if point == null: return
	var fraction: float = inverse_lerp(RAIL.x,RAIL.y,point.y)
	host.depth.strength = host.depth.Strength.from_fraction(fraction)
	if boosted and point.y>RAIL.y:
		host.depth.strength = host.depth.Strength.clamp_value(1.0+(point.y-RAIL.y)/BOOST_HEIGHT,2.0)
	if fraction<0.02: host.depth.strength=0.0
	_refresh_strength()
func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	var hit := ray_hit(origin,direction) if tracked else {}
	if hit.is_empty(): return false
	if hit.target == STRENGTH:
		capture_hand = hand; drag_pointer(hand,origin,direction,tracked)
	else: _activate_hit(hit)
	return true
func finish_drag() -> void:
	if capture_hand.is_empty(): return
	capture_hand = ""
	if host: host._depth_changed("strength",host.depth.strength*100.0)
func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture_hand == hand: drag_pointer(hand,origin,direction,tracked); finish_drag()
func cancel_pointer(hand: String) -> void:
	if capture_hand == hand: finish_drag()
