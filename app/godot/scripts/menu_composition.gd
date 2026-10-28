extends Node
## High-density menus on OpenXR quad layers. Every flat surface of the visible 3D menu (main panel,
## angled side column, raised popups) is captured orthographically into its own quad layer, so the
## compositor resolves stereo parallax and head motion: a surface re-renders only when its content
## changes, never because the head moved. Ray hit geometry and the 3D menu code stay unchanged.
##
## Swapchain rules (Godot 4.7.2, GLES3):
## - A layer viewport in UPDATE_ONCE creates a new *static* swapchain on every update. The submit
##   viewports switch between UPDATE_ALWAYS (repaint frames) and UPDATE_DISABLED instead, which
##   keeps one dynamic swapchain and lets the compositor reuse the last released image.
## - Freeing a swapchain while the viewport's render target is overridden with its image (hiding
##   the layer, detaching or resizing its viewport) corrupts the render target and crashed the
##   Quest GL thread. Each slot therefore has a fixed pixel size, is never hidden or detached, and
##   keeps its swapchain for the session; an idle slot shrinks to a sub-pixel quad instead.
## The compositor reads every pixel of a slot each frame, for each eye, whatever it shows, so the
## swapchains match the planes the menus actually have: main panel, tall side column, two popups,
## and the short playback/photo control bar (a square slot read 2.4x its area for it).
## Sizes in metres at the capture density below; a larger plane is captured less densely.
const SLOT_METRES := [Vector2(1.56, 1.36), Vector2(0.5, 1.2), Vector2(0.93, 0.93), Vector2(0.93, 0.93), Vector2(1.2, 0.66)]
## Use all five already-reserved providers: attached library, side column, transport,
## dropdown and its hover tip must stay sharp together. Godot render bits end at 19.
## A plane's bit follows its slot for the current page; band bits sit below this range.
const MAX_GROUPS := 5
const GROUP_BIT := 20 - MAX_GROUPS
const GROUP_MASK := ((1 << MAX_GROUPS) - 1) << GROUP_BIT
const SLOT_PREFERENCE := {"panel": [0, 2, 3, 4, 1], "tall": [1, 0, 2, 3, 4], "popup": [2, 3, 0, 4, 1], "bar": [4, 0, 2, 3, 1]}
## Capture pixels per metre: about 1.4x the display density of Quest 3 at the menu's distance,
## confirmed legible on the headset (2026-10-16). 1.7x (1650 px/m) cost the compositor 50% more
## reads for text the panel barely resolves.
const DENSITY := 1320.0
## XR2 Gen1 class headsets (Quest 2, PICO 4, PICO Neo3, ~20 PPD) capture at about 1.1x their own
## display density (~908 px/m). Above ~1.4x the compositor's reads multiply for text the panel
## cannot resolve.
const LOW_END_SCALE := 0.6875
const HIDDEN_SIZE := Vector2(0.0005, 0.0005)
## Video/pictures and ordered PiP pairs precede these menus; eye buffer is at 0.
const ORDER_BASE := -6
## Clear after shader video (-10) and subtitles (1), before the menu's eye-buffer UI (10+).
## Otherwise a nearby 2D->3D screen paints back into the hole over the compositor menu.
const HOLE_PRIORITY := 9 # after PiP pictures/frames (0..8), before ordinary menus (10+)
## Surfaces whose offsets along a shared normal differ less than this share one layer plane.
const PLANE_GAP := 0.015
## Popups draw with render priority 30+; they and their children never share a panel's layer.
const POPUP_PRIORITY := 30
const NORMAL_DOT := 0.9995
const MARGIN := 0.012
const GRID := 0.05
## A low-rate check catches visuals changed without a signal (late thumbnails, text). It compares
## a signature of the captured nodes and repaints only on a change: every repaint acquires the
## layer swapchains, and a blind 4 Hz repaint cost Quest 3 about two late frames a second, seen as
## a constant fine judder of the idle menu (2026-10-21).
const KEEPALIVE_MS := 250
## Debug A/B only (0 disables the keepalive); read every frame.
var keepalive_ms := KEEPALIVE_MS
var _signature := 0
## Shader uniform names, by shader instance id.
var _uniforms := {}
const HOLE_SHADER := preload("res://shaders/menu_layer_hole.gdshader")
const OVERLAY_HOLE_SHADER := preload("res://shaders/menu_layer_hole_overlay.gdshader")
const COPY_SHADER := preload("res://shaders/menu_layer_copy.gdshader")
const SURFACE_SHADER := preload("res://shaders/menu_surface.gdshader")
const SUPERSAMPLING_PROPERTY := "XR_FB_composition_layer_settings/manual/supersampling_mode"
const SHARPENING_PROPERTY := "XR_FB_composition_layer_settings/manual/sharpening_mode"
## Debug text-band prototype: the main panel and the tall side column keep their flat surfaces in
## the eye buffer; only horizontal bands holding text or icons go to fixed-size layers at the
## density of the slot they replace. Each plane kind has its own pool and render bit; the pools,
## the popup slots and the projection/passthrough layers stay under Quest's 16-layer limit.
## A dense stretch of rows that would need more bands than the pool holds merges into one block
## layer at the same density (the main panel only; the side column's rows always fit).
const BAND_POOLS := {
	"panel": {"pixels": Vector2i(2560, 160), "count": 7, "bit": 1 << (GROUP_BIT - 1), "slot": 0,
		"block": Vector2i(2560, 960)},
	"tall": {"pixels": Vector2i(1024, 480), "count": 4, "bit": 1 << (GROUP_BIT - 2), "slot": 1},
}
## Slots own bits 15-19; diagnostic band bits 13-14 are otherwise unused.
const BAND_MASK := 3 << (GROUP_BIT - 2)
## After the panel's own eye-buffer content (priority <= 18), before popups and pointers.
const BAND_HOLE_PRIORITY := 25
## Band holes skip the band's top and bottom strips and anything not fully opaque (panel edges,
## antialiased silhouettes): the eye-buffer panel covers the compositor's quad-edge blending there.
const BAND_INSET := 0.004
const BAND_COVERAGE := 0.95
var menus: Array = []
var origin: Node3D
var eye_camera: Camera3D
var display: RefCounted
var xr: XRInterface
var api: OpenXRAPIExtension
var enabled := false
## Host-only injection: captures the same textures without claiming a native XR result.
var force_capture := false
var low_end := false
var active: Node3D
var slots: Array[Dictionary] = []
var originals: Array[Dictionary] = []
var dirty := true
var geometry_dirty := true
var eye_mask := 0
var fallback_reason := "not_configured"
var repaints := 0
var _painted_ms := 0
var _last_menu: Node3D
var bands: Array[Dictionary] = []
## Planes captured as bands, by kind: {"relative", "rank", "nodes", "width", "overflow"}.
var banded: Dictionary = {}
var _peer_poses := []

func layer_reservation() -> int:
	if not enabled: return 0
	# Normal slots may be attached later in the same frame. Extra diagnostic bands
	# already own viewports, so include those providers even while their quad is tiny.
	var browser_layers := 0
	for menu in menus:
		if is_instance_valid(menu) and menu.get_meta("menu_browser_layer", false): browser_layers += 1
	return SLOT_METRES.size() + bands.size() + browser_layers

func configure(target_origin: Node3D, target_camera: Camera3D, target_display: RefCounted,
		target_menus: Array, is_low_end: bool, host_capture: bool = false) -> void:
	origin = target_origin; eye_camera = target_camera; display = target_display
	menus = target_menus.duplicate(); low_end = is_low_end; force_capture = host_capture
	xr = XRServer.find_interface("OpenXR")
	var probe := OpenXRCompositionLayerQuad.new()
	enabled = host_capture or (xr != null and xr.is_initialized() and xr.get_view_count() == 2 and probe.is_natively_supported())
	probe.free()
	if not enabled:
		fallback_reason = "native_quad_unavailable"
		set_process(false)
		return
	if not host_capture:
		api = OpenXRAPIExtension.new()
		xr.session_begun.connect(invalidate)
	process_priority = 100 # after scrolling, hover, controller moves and gesture animation
	eye_mask = eye_camera.cull_mask
	eye_camera.cull_mask &= ~GROUP_MASK
	for index in SLOT_METRES.size():
		slots.append(_make_slot(index))
	if debug_bands:
		for kind in BAND_POOLS:
			var pool: Dictionary = BAND_POOLS[kind]
			for index in pool.count + int(pool.has("block")):
				var block: bool = index == pool.count
				var band := _make_capture(_scaled(pool.block if block else pool.pixels), pool.bit,
					"MenuBand_%s%s" % [kind, "Block" if block else str(index)], BAND_HOLE_PRIORITY)
				band.hole.material_override.set_shader_parameter("coverage_min", BAND_COVERAGE)
				band.kind = kind; band.block = block
				bands.append(band)
	get_tree().node_added.connect(_node_added)
	for menu in menus:
		menu.composition_changed.connect(repaint)
		menu.composition_layout_changed.connect(invalidate)
		_watch_children(menu)
	fallback_reason = ""

func _scaled(pixels: Vector2i) -> Vector2i:
	var scale := _scale()
	if scale == 1.0: return pixels
	return Vector2i(ceili(pixels.x * scale / 16) * 16, ceili(pixels.y * scale / 16) * 16)

func _scale() -> float:
	return debug_pixel_scale if debug_pixel_scale > 0.0 else (LOW_END_SCALE if low_end else 1.0)

static func slot_pixels(metres: Vector2, scale: float) -> Vector2i:
	return Vector2i(ceili(metres.x * DENSITY * scale / 16) * 16, ceili(metres.y * DENSITY * scale / 16) * 16)

func _make_slot(index: int) -> Dictionary:
	# The band prototype replaces the panel and tall slots: tiny, and never submitted.
	var replaced := debug_bands and BAND_POOLS.values().any(func(pool): return pool.slot == index)
	var pixels := Vector2i(16, 16) if replaced else slot_pixels(SLOT_METRES[index], _scale())
	# A layer joins the layer list (and allocates its swapchain) only once a plane first uses it.
	var slot := _make_capture(pixels, 0, "Menu%d" % index, HOLE_PRIORITY, false)
	slot.index = index
	return slot

func _make_capture(pixels: Vector2i, cull: int, layer_name: String, hole_priority: int, submitted: bool = true) -> Dictionary:
	# Child viewports render before their parent: the capture is complete before the copy.
	var submit := SubViewport.new(); submit.size = pixels
	submit.transparent_bg = true; submit.disable_3d = true; submit.world_2d = World2D.new()
	submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(submit)
	var raw := SubViewport.new(); raw.size = pixels; raw.transparent_bg = true
	raw.world_3d = origin.get_viewport().world_3d
	raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	submit.add_child(raw)
	var camera := Camera3D.new(); camera.cull_mask = cull
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.05; camera.far = 0.5
	camera.environment = clear_environment(); raw.add_child(camera)
	# The swapchain image cannot be sampled by the eye-buffer mask, so it gets a copy.
	var copy := ColorRect.new(); copy.size = Vector2(pixels)
	var copy_material := ShaderMaterial.new(); copy_material.shader = COPY_SHADER
	copy_material.set_shader_parameter("menu_texture", raw.get_texture())
	copy.material = copy_material; submit.add_child(copy)
	var layer := OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.alpha_blend = true
	# The mask follows actual menu coverage instead of clearing the whole rectangle.
	# Visible for the whole session; without an acquired image Godot skips it.
	layer.enable_hole_punch = false; layer.visible = not force_capture
	layer.quad_size = HIDDEN_SIZE
	origin.add_child(layer)
	# A layer without a viewport acquires no image and is never submitted.
	if submitted: layer.layer_viewport = submit
	_apply_filter(layer)
	var hole := MeshInstance3D.new(); hole.mesh = QuadMesh.new()
	hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new(); material.shader = HOLE_SHADER
	# Clear shader video before exposing the menu layer. Bands also clear panel content
	# that stays in the eye buffer; opaque input models in front retain depth protection.
	material.render_priority = hole_priority
	material.set_shader_parameter("menu_texture", raw.get_texture())
	hole.material_override = material; hole.visible = false
	origin.add_child(hole)
	return {"index": -1, "raw": raw, "camera": camera, "submit": submit, "copy": copy, "layer": layer,
		"hole": hole, "key": "", "used": false, "relative": Transform3D.IDENTITY, "rect": Rect2(),
		"nodes": [], "rank": Vector2.ZERO, "tail": 0, "empty": false}

## Compositor filtering of the menu layers (0 off, 1 normal, 2 quality). Normal supersampling:
## the capture is denser than the display.
var supersampling := 1
var sharpening := 0
## Debug cost split only: skips the eye-buffer coverage pass (the menu then shows behind scene content).
var debug_hide_holes := false
## Debug capture-density override (0 = automatic); read before configure().
var debug_pixel_scale := 0.0
## Debug text-band prototype for the main panel; read before configure().
var debug_bands := false

func _apply_filter(layer: OpenXRCompositionLayer) -> void:
	for property in layer.get_property_list():
		if property.name == SUPERSAMPLING_PROPERTY: layer.set(property.name, supersampling)
		elif property.name == SHARPENING_PROPERTY: layer.set(property.name, sharpening)

## Debug comparison of filter cost and legibility; takes effect on the next frame.
func set_filter(supersampling_mode: int, sharpening_mode: int) -> void:
	supersampling = clampi(supersampling_mode, 0, 2); sharpening = clampi(sharpening_mode, 0, 2)
	for slot in slots + bands: _apply_filter(slot.layer)

func set_debug_holes(visible: bool) -> void:
	debug_hide_holes = not visible
	for slot in slots + bands: slot.hole.visible = visible and slot.used and not slot.empty and slot.rect.has_area()

static func clear_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	return environment

func invalidate() -> void:
	dirty = true; geometry_dirty = true

func repaint() -> void:
	dirty = true

## Short-lived game panels share the existing fixed swapchains and capture policy.
func register_menu(menu: Node3D) -> void:
	if not is_instance_valid(menu) or menus.has(menu): return
	menus.append(menu)
	menu.composition_changed.connect(repaint)
	menu.composition_layout_changed.connect(invalidate)
	menu.tree_exiting.connect(unregister_menu.bind(menu))
	_watch_children(menu); invalidate()

## Floating video controls share the existing five providers, never extra XR layers.
func register_companion(menu: Node3D) -> void:
	menu.set_meta("menu_companion", true)
	menu.composition_root().set_meta("menu_companion", true)
	register_menu(menu)

func _menu_visible(menu: Node3D) -> bool:
	return menu.is_visible_in_tree() and (not menu.has_method("composition_visible") or menu.composition_visible())

func unregister_menu(menu: Node3D) -> void:
	if not menus.has(menu): return
	if active==menu or (is_instance_valid(active) and menu.is_ancestor_of(active)):
		# Restore render masks before a captured panel is detached or freed.
		_restore(); _hide(); active=null
	if _last_menu==menu: _last_menu=null
	menus.erase(menu)
	if menu.composition_changed.is_connected(repaint): menu.composition_changed.disconnect(repaint)
	if menu.composition_layout_changed.is_connected(invalidate): menu.composition_layout_changed.disconnect(invalidate)
	var exiting := unregister_menu.bind(menu)
	if menu.tree_exiting.is_connected(exiting): menu.tree_exiting.disconnect(exiting)
	_unwatch_children(menu); invalidate()

func _unwatch_children(node: Node) -> void:
	if node.has_signal("visual_changed") and node.is_connected("visual_changed",repaint): node.disconnect("visual_changed",repaint)
	for child in node.get_children(): _unwatch_children(child)

func _watch_children(node: Node) -> void:
	if node.has_meta("menu_eye_buffer"): return
	if node.has_signal("visual_changed") and not node.is_connected("visual_changed", repaint):
		node.connect("visual_changed", repaint)
	for child in node.get_children(): _watch_children(child)

func _node_added(node: Node) -> void:
	for menu in menus:
		if menu.is_ancestor_of(node):
			_watch_children(node)
			if menu == active: invalidate()
			return

func _process(_delta: float) -> void:
	# Frame rate cannot identify menu-layer faults; playback and style edits can also stall.
	# Keep the fixed swapchains and capture density through slow frames.
	update()

## Debug comparison: pauses the layers and restores the eye-buffer menu without freeing them.
func set_active(on: bool) -> void:
	if not enabled or not is_instance_valid(eye_camera): return
	if on:
		eye_camera.cull_mask = eye_mask & ~GROUP_MASK
		active = null; set_process(true); invalidate()
	else:
		_restore(); _hide(); active = null
		set_process(false); eye_camera.cull_mask = eye_mask
		fallback_reason = "debug_paused"

## Explicit lifecycle cleanup; frame timing never invokes this.
func shutdown(reason: String) -> void:
	# Layers stay allocated (sub-pixel, not rendering): freeing them is the unsafe path above.
	_restore(); _hide()
	enabled = false; set_process(false)
	if is_instance_valid(eye_camera): eye_camera.cull_mask = eye_mask
	fallback_reason = reason

func update() -> void:
	if not enabled: return
	if not force_capture and (not xr.is_initialized() or not api.is_running()):
		_restore(); _hide(); fallback_reason = "session_not_running"; return
	var wanted: Node3D
	for menu in menus:
		if _menu_visible(menu):
			wanted = menu.composition_root() if menu.has_method("composition_root") else menu
			break
	if wanted != active:
		_restore(); _hide(); active = wanted
		# Reopening the same menu keeps its slots and swapchain sizes.
		if active and active != _last_menu:
			for slot in slots: slot.key = ""; slot.rect = Rect2()
			_last_menu = active
		invalidate()
	if not active:
		return
	var peer_poses := []
	for peer in _visible_peers(): peer_poses.append([peer.get_instance_id(),active.global_transform.affine_inverse()*peer.global_transform])
	if peer_poses!=_peer_poses: _peer_poses=peer_poses; geometry_dirty=true
	if geometry_dirty:
		_collect(); geometry_dirty = false; dirty = true
	var now := Time.get_ticks_msec()
	if not dirty and keepalive_ms > 0 and now - _painted_ms >= keepalive_ms:
		_painted_ms = now
		dirty = _visual_signature() != _signature
	if dirty:
		for slot in slots:
			if slot.used: _measure(slot)
		for kind in banded: _measure_bands(kind)
		dirty = false; _painted_ms = now; repaints += 1
		_signature = _visual_signature()
	var root := _root_pose()
	var any := false
	for slot in slots + bands:
		_place(slot, root)
		any = any or (slot.used and not slot.empty)
	if display: display.set_menu_layers(any and not force_capture)
	fallback_reason = "" if any else "no_planar_surfaces"

## Everything a capture shows of its nodes: visibility, pose in the menu, text, colours, textures
## and shader parameters. Equal signatures mean an identical repaint.
func _visual_signature() -> int:
	var inverse := _root_pose().affine_inverse()
	var values := []
	for slot in slots:
		if slot.used: _sign_nodes(slot.nodes, inverse, values)
	for kind in banded: _sign_nodes(banded[kind].nodes, inverse, values)
	return hash(values)

func _sign_nodes(nodes: Array, inverse: Transform3D, values: Array) -> void:
	for node in nodes:
		if not is_instance_valid(node): values.append(0); continue
		var visual := node as VisualInstance3D
		var shown := visual.is_visible_in_tree()
		values.append(shown)
		if not shown: continue
		values.append(inverse * visual.global_transform)
		if visual is Label3D:
			var label := visual as Label3D
			values.append_array([label.text, label.modulate, label.outline_modulate, label.font_size, label.width])
		elif visual is SpriteBase3D:
			values.append_array([visual.get("texture"), (visual as SpriteBase3D).modulate])
		if visual is MeshInstance3D:
			var mesh := (visual as MeshInstance3D).mesh
			values.append(mesh)
			if mesh is PrimitiveMesh: values.append(mesh.get("size"))
		if visual is GeometryInstance3D:
			var material := (visual as GeometryInstance3D).material_override
			values.append(material)
			if material is StandardMaterial3D:
				values.append_array([material.albedo_color, material.albedo_texture])
			elif material is ShaderMaterial and material.shader:
				var key: int = material.shader.get_instance_id()
				if not _uniforms.has(key):
					_uniforms[key] = material.shader.get_shader_uniform_list().map(func(uniform): return uniform.name)
				for uniform in _uniforms[key]: values.append(material.get_shader_parameter(uniform))

func _root_pose() -> Transform3D:
	var pose := active.global_transform
	pose.basis = pose.basis.orthonormalized()
	return pose

## Groups visible menu geometry by plane. Each group keeps its slot (and swapchain size)
## across rebuilds of the same page, so hover tips and page redraws do not reallocate.
func _collect() -> void:
	_restore()
	var root := _root_pose()
	var inverse := root.affine_inverse()
	var items: Array[Dictionary] = []
	_gather(active, items, inverse, false)
	for item in items: item["owner"]=active.get_instance_id()
	var owners := [active.get_instance_id()]
	for peer in _visible_peers():
		var start := items.size(); _gather(peer,items,inverse,false); owners.append(peer.get_instance_id())
		for i in range(start,items.size()): items[i]["owner"]=peer.get_instance_id()
	var groups: Array[Dictionary] = []
	items.sort_custom(func(a, b): return a.offset < b.offset)
	for item in items:
		var joined := false
		for group in groups:
			if group.region == item.region and group.tooltip == item.tooltip and group.popup == item.popup and group.normal.dot(item.normal) > NORMAL_DOT and item.offset - group.last <= PLANE_GAP:
				group.nodes.append(item); group.last = item.offset
				group.shown += int(item.shown)
				group.owners[item.owner]=true
				joined = true; break
		if not joined:
			groups.append({"normal": item.normal, "basis": item.basis, "first": item.offset, "last": item.offset,
				"nodes": [item], "region": item.region, "popup": item.popup, "tooltip": item.tooltip, "shown": int(item.shown),"owners":{item.owner:true}})
	# Visible, larger groups claim slots first; any surplus geometry stays in the eye buffer.
	groups.sort_custom(func(a, b): return a.shown > b.shown or (a.shown == b.shown and a.nodes.size() > b.nodes.size()))
	# A small companion caption must not lose all HD slots to a large menu's
	# extra planes. Reserve its main visible plane, then fill remaining slots.
	var selected: Array[Dictionary]=[]
	# Hover text must not drop to the lower-density eye buffer when a page uses
	# several angled planes. Reserve one existing slot; never add XR layers.
	for group in groups:
		if group.tooltip and group.shown > 0: selected.append(group); break
	for owner in owners:
		for group in groups:
			if group.shown>0 and group.owners.has(owner):
				if not selected.has(group) and selected.size()<MAX_GROUPS: selected.append(group)
				break
	for group in groups:
		if selected.size()==MAX_GROUPS: break
		if not selected.has(group): selected.append(group)
	groups=selected
	for group in groups.slice(0, MAX_GROUPS):
		var key := "%s:%d:%d:%d:%d:%d:%d" % [group.region, int(group.popup), int(group.tooltip), roundi(group.normal.x * 50), roundi(group.normal.y * 50), roundi(group.normal.z * 50), roundi(group.first / PLANE_GAP)]
		group["key"] = key
	for slot in slots: slot.used = false; slot.nodes = []
	banded = {}
	# Slot pixel sizes are fixed, so each surface takes the free slot whose shape fits it best.
	# Each plane on the page has its own render bit, whichever slot captures it.
	for position in mini(groups.size(), MAX_GROUPS):
		var group: Dictionary = groups[position]
		var kind := _kind(group, inverse)
		if debug_bands and BAND_POOLS.has(kind) and not banded.has(kind):
			_assign_bands(kind, group); continue
		for index in SLOT_PREFERENCE[kind]:
			if debug_bands and BAND_POOLS.values().any(func(pool): return pool.slot == index): continue
			var slot: Dictionary = slots[index]
			if slot.used: continue
			if slot.key != group.key: slot.key = group.key; slot.rect = Rect2()
			_assign(slot, group, root, 1 << (GROUP_BIT + position)); break
	# Back to front: popups over panels, then nearer planes.
	var ordered := slots.filter(func(s): return s.used)
	for band in bands: band.used = false
	# A plane's bands never overlap, so they share one order and the menu stays between video and
	# eye buffer.
	for kind in banded: ordered.append({"rank": banded[kind].rank, "bands": kind})
	ordered.sort_custom(func(a, b): return a.rank.x < b.rank.x or (a.rank.x == b.rank.x and a.rank.y < b.rank.y))
	for index in ordered.size():
		if ordered[index].has("bands"):
			for band in bands:
				if band.kind == ordered[index].bands: band.layer.sort_order = ORDER_BASE + index
		else: ordered[index].layer.sort_order = ORDER_BASE + index
	for slot in slots + bands:
		if not slot.used: _hide_slot(slot)

func _visible_peers() -> Array:
	var peers := []
	for menu in menus:
		if menu.get_meta("menu_companion", false):
			if _menu_visible(menu):
				var root: Node3D = menu.composition_root()
				if root != active and not active.is_ancestor_of(root): peers.append(root)
			continue
		if menu!=active and not active.is_ancestor_of(menu) and menu.is_visible_in_tree() and menu.has_method("composition_root") and menu.composition_root()==active: peers.append(menu)
	return peers

static func _kind(group: Dictionary, root_inverse: Transform3D) -> String:
	if group.popup: return "popup"
	var frame_inverse := Basis(group.basis).inverse()
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	for item in group.nodes:
		var node: VisualInstance3D = item.node
		if not node.is_visible_in_tree(): continue
		var box := node.get_aabb()
		var to_frame := Transform3D(frame_inverse, Vector3.ZERO) * root_inverse * node.global_transform
		for corner in 8:
			var point: Vector3 = to_frame * box.get_endpoint(corner)
			lo = lo.min(Vector2(point.x, point.y)); hi = hi.max(Vector2(point.x, point.y))
	if not lo.is_finite(): return "panel"
	var size := hi - lo
	if size.y > size.x * 1.6: return "tall"
	return "bar" if size.x > size.y * 1.6 else "panel"

func _assign(slot: Dictionary, group: Dictionary, root: Transform3D, bit: int) -> void:
	slot.used = true
	var overlay: bool = group.owners.keys().any(func(id):
		var owner: Object = instance_from_id(id)
		return is_instance_valid(owner) and owner.get("scene_overlay") == true)
	slot.hole.material_override.shader = OVERLAY_HOLE_SHADER if overlay else HOLE_SHADER
	slot["companion"] = group.owners.keys().any(func(id):
		var node: Object = instance_from_id(id)
		return is_instance_valid(node) and node.get_meta("menu_companion", false))
	slot["tooltip"] = group.tooltip
	slot.camera.cull_mask = bit
	if slot.layer.layer_viewport == null: slot.layer.layer_viewport = slot.submit
	var plane := (float(group.first) + float(group.last)) * 0.5
	var basis: Basis = group.basis
	var local_normal: Vector3 = basis.z
	# The plane frame lives in the menu root's space; the menu may move every frame.
	var relative := Transform3D(basis, local_normal * plane)
	if slot.rect.has_area() and not slot.relative.basis.is_equal_approx(basis):
		slot.rect = Rect2()
	slot.relative = relative
	slot.rank = Vector2(2 if group.tooltip else int(group.popup), relative.origin.z)
	for item in group.nodes:
		var node: VisualInstance3D = item.node
		originals.append({"node": node, "layers": node.layers})
		node.layers = bit
		slot.nodes.append(node)

func _assign_bands(kind: String, group: Dictionary) -> void:
	var plane := (float(group.first) + float(group.last)) * 0.5
	var basis: Basis = group.basis
	var relative := Transform3D(basis, basis.z * plane)
	var state := {"relative": relative, "rank": Vector2(int(group.popup), relative.origin.z), "nodes": [],
		"width": 0.0, "overflow": 0}
	banded[kind] = state
	for item in group.nodes:
		var node: VisualInstance3D = item.node
		var surface: ShaderMaterial = node.material_override if node.material_override is ShaderMaterial else null
		var solid: bool = surface != null and surface.shader == SURFACE_SHADER
		originals.append({"node": node, "layers": node.layers, "surface": surface if solid else null})
		# Drawn in both: the eye buffer keeps the flat panel, the bands capture text rows.
		node.layers = node.layers | int(BAND_POOLS[kind].bit)
		if solid: surface.set_shader_parameter("solid", true)
		state.nodes.append(node)

## Text and icons need the layer density; flat shader surfaces render fine in the eye buffer.
static func _is_detail(node: VisualInstance3D) -> bool:
	if node is Label3D: return not (node as Label3D).text.strip_edges().is_empty()
	if node is GeometryInstance3D and node.material_override is StandardMaterial3D:
		return (node.material_override as StandardMaterial3D).albedo_texture != null
	return false

## Covers the text rows of the banded plane with fixed-size bands, top to bottom.
func _measure_bands(kind: String) -> void:
	var state: Dictionary = banded[kind]
	var pool := bands.filter(func(b): return b.kind == kind and not b.block)
	var blocks := bands.filter(func(b): return b.kind == kind and b.block)
	var root_inverse := _root_pose().affine_inverse()
	var frame_inverse: Transform3D = state.relative.affine_inverse()
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	var spans: Array[Vector2] = []
	for node: VisualInstance3D in state.nodes:
		if not is_instance_valid(node) or not node.is_visible_in_tree(): continue
		var box := node.get_aabb()
		if box.size.x <= 0 and box.size.y <= 0: continue
		var to_frame: Transform3D = frame_inverse * root_inverse * node.global_transform
		var node_lo := Vector2(INF, INF); var node_hi := Vector2(-INF, -INF)
		for corner in 8:
			var point: Vector3 = to_frame * box.get_endpoint(corner)
			node_lo = node_lo.min(Vector2(point.x, point.y)); node_hi = node_hi.max(Vector2(point.x, point.y))
		lo = lo.min(node_lo); hi = hi.max(node_hi)
		if _is_detail(node): spans.append(Vector2(node_lo.y - MARGIN, node_hi.y + MARGIN))
	if not lo.is_finite(): return
	lo = ((lo - Vector2.ONE * MARGIN) / GRID).floor() * GRID
	hi = ((hi + Vector2.ONE * MARGIN) / GRID).ceil() * GRID
	var width: float = maxf(hi.x - lo.x, state.width)
	state.width = width
	var pixels := Vector2(pool[0].raw.size)
	var height := width * pixels.y / pixels.x
	spans.sort_custom(func(a, b): return a.y > b.y)
	var tops := _pack(spans, height)
	var block_top := INF
	var block_height := 0.0
	if tops.size() > pool.size() and not blocks.is_empty():
		# Merge a dense stretch: among block positions that leave few enough bands, take the one
		# capturing the fewest pixels; if none fits, the one leaving the fewest bands.
		block_height = width * float(blocks[0].raw.size.y) / float(blocks[0].raw.size.x)
		var block_cost := float(blocks[0].raw.size.x * blocks[0].raw.size.y)
		var band_cost := float(pool[0].raw.size.x * pool[0].raw.size.y)
		var best := tops
		var best_cost := INF
		for candidate in spans:
			var top: float = candidate.y
			var rest := spans.filter(func(s): return not (s.y <= top and s.x >= top - block_height))
			var packed := _pack(rest, height)
			var cost := block_cost + packed.size() * band_cost
			if packed.size() > pool.size(): cost = INF
			if cost < best_cost or (best_cost == INF and packed.size() < best.size()):
				best = packed; best_cost = cost; block_top = top
		tops = best
	state.overflow = maxi(tops.size() - pool.size(), 0)
	for block in blocks:
		block.used = block_top != INF
		block.relative = state.relative
		if block.used:
			_capture_band(block, Rect2(Vector2(lo.x, block_top - block_height), Vector2(width, block_height)))
	for index in pool.size():
		var band: Dictionary = pool[index]
		band.used = index < tops.size()
		band.relative = state.relative
		if band.used: _capture_band(band, Rect2(Vector2(lo.x, tops[index] - height), Vector2(width, height)))

## Fixed-height bands top to bottom. A row the previous band cuts starts its own band at its top;
## the overlap keeps the inset strip of the band edge off text.
static func _pack(spans: Array, height: float) -> Array[float]:
	var tops: Array[float] = []
	var covered := INF
	for span: Vector2 in spans:
		if span.x >= covered: continue
		var top := span.y
		while top > span.x:
			tops.append(top); top -= height
		covered = top
	return tops

func _capture_band(band: Dictionary, rect: Rect2) -> void:
	band.rect = rect
	band.hole.material_override.set_shader_parameter("inset_v", BAND_INSET / rect.size.y)
	band.hole.material_override.set_shader_parameter("erode", Vector2(BAND_INSET / rect.size.x, BAND_INSET / rect.size.y))
	band.raw.render_target_update_mode = SubViewport.UPDATE_ONCE
	band.submit.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	band.tail = 2

func _gather(node: Node, items: Array[Dictionary], inverse: Transform3D, popup: bool, tooltip: bool = false, region: String = "") -> void:
	# Wide subtitle plates opt into per-column captures without adding XR providers.
	region = str(node.get_meta("menu_capture_region", region))
	tooltip = tooltip or node.get_meta("menu_tooltip", false)
	if node.has_meta("menu_pointer") or node.has_meta("menu_eye_buffer"): return
	if node is CanvasItem or node is Viewport: return
	# A folded attached browser is a separate menu, not a hidden row of the transport.
	# Drop its whole subtree so its old plane and capture cannot outlive selection/dismissal.
	if node != active and menus.has(node) and not node.is_visible_in_tree(): return
	# Hidden rows, tips and popups join their plane now; they may appear without a rebuild.
	if node is VisualInstance3D:
		var local: Transform3D = inverse * node.global_transform
		var basis := local.basis.orthonormalized()
		var normal := basis.z
		popup = popup or _priority(node) >= POPUP_PRIORITY
		items.append({"node": node, "normal": normal, "basis": basis, "offset": normal.dot(local.origin), "popup": popup,
			"region": region, "tooltip": tooltip, "shown": node.is_visible_in_tree()})
	for child in node.get_children(): _gather(child, items, inverse, popup, tooltip, region)

static func _priority(node: VisualInstance3D) -> int:
	if node is Label3D: return node.render_priority
	if node is GeometryInstance3D and node.material_override: return node.material_override.render_priority
	return 0

## Grow-only bounds in the plane frame, snapped to a grid; pixel sizes stay stable.
func _measure(slot: Dictionary) -> void:
	var root_inverse := _root_pose().affine_inverse()
	var frame_inverse: Transform3D = slot.relative.affine_inverse()
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	for node: VisualInstance3D in slot.nodes:
		if not is_instance_valid(node) or not node.is_visible_in_tree(): continue
		var box: AABB = node.get_meta("menu_capture_bounds", node.get_aabb())
		if box.size.x <= 0 and box.size.y <= 0: continue
		var to_frame: Transform3D = frame_inverse * root_inverse * node.global_transform
		for corner in 8:
			var point: Vector3 = to_frame * box.get_endpoint(corner)
			lo = lo.min(Vector2(point.x, point.y)); hi = hi.max(Vector2(point.x, point.y))
	# A plane with nothing showing (a closed popup surface) parks its slot: the compositor would
	# still read every pixel of it, and its last capture would linger.
	slot.empty = not lo.is_finite()
	if slot.empty: return
	lo = ((lo - Vector2.ONE * MARGIN) / GRID).floor() * GRID
	hi = ((hi + Vector2.ONE * MARGIN) / GRID).ceil() * GRID
	var rect := Rect2(lo, hi - lo)
	var previous: Rect2 = slot.rect
	# A moving tooltip replaces its bounds. Unioning every hovered card position
	# spreads fixed capture pixels across an ever larger, mostly empty rectangle.
	slot.rect = rect if slot.get("tooltip", false) or not previous.has_area() else previous.merge(rect)
	slot.raw.render_target_update_mode = SubViewport.UPDATE_ONCE
	slot.submit.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# New floating controls change render masks immediately after creating glyphs.
	# One follow-up capture lets those render resources settle before parking it.
	slot.tail = 3 if slot.get("companion", false) else 2

func _place(slot: Dictionary, root: Transform3D) -> void:
	if not slot.used or slot.empty or not slot.rect.has_area():
		_hide_slot(slot); return
	var rect: Rect2 = slot.rect
	# The pixel grid is rounded up; widen the captured rectangle to the exact pixel aspect.
	var pixels: Vector2 = Vector2(slot.raw.size)
	var size := rect.size
	if size.x / size.y < pixels.x / pixels.y: size.x = size.y * pixels.x / pixels.y
	else: size.y = size.x * pixels.y / pixels.x
	var pose: Transform3D = root * slot.relative * Transform3D(Basis.IDENTITY, Vector3(rect.get_center().x, rect.get_center().y, 0))
	var camera: Camera3D = slot.camera
	camera.size = size.y
	camera.global_transform = pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.25))
	slot.layer.quad_size = size
	slot.layer.global_transform = pose
	# A primitive mesh rebuilds its arrays on every size assignment.
	if slot.hole.mesh.size != size: slot.hole.mesh.size = size
	slot.hole.global_transform = pose
	slot.hole.visible = not debug_hide_holes
	if slot.tail > 0:
		if slot.get("companion", false) and slot.tail > 1:
			slot.raw.render_target_update_mode = SubViewport.UPDATE_ONCE
		slot.tail -= 1
		if slot.tail == 0:
			slot.raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
			slot.submit.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _restore() -> void:
	for item in originals:
		if is_instance_valid(item.node): item.node.layers = item.layers
		if item.get("surface"): item.surface.set_shader_parameter("solid", false)
	originals.clear()

func _hide_slot(slot: Dictionary) -> void:
	slot.layer.quad_size = HIDDEN_SIZE
	slot.hole.visible = false
	slot.raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	slot.submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	slot.tail = 0

func _hide() -> void:
	banded = {}
	for slot in slots + bands:
		slot.used = false; slot.nodes = []
		_hide_slot(slot)
	if display: display.set_menu_layers(false)

func snapshot() -> Dictionary:
	var sizes := []
	var rects := []
	for slot in slots:
		if slot.used and not slot.empty:
			sizes.append([slot.raw.size.x, slot.raw.size.y])
			rects.append([slot.index, snappedf(slot.layer.quad_size.x, 0.01), snappedf(slot.layer.quad_size.y, 0.01)])
	return {"enabled": enabled, "active": not sizes.is_empty(), "native": enabled and not force_capture,
		"fallback": fallback_reason, "layers": sizes.size(), "pixels": sizes, "quads": rects,
		"repaints": repaints, "filter": [supersampling, sharpening],
		"bands": bands.filter(func(b): return b.used).size() if debug_bands else -1,
		"band_use": BAND_POOLS.keys().map(func(kind): return bands.filter(func(b): return b.kind == kind and b.used and not b.block).size()) if debug_bands else [],
		"band_block": bands.any(func(b): return b.block and b.used),
		"band_overflow": banded.values().reduce(func(total, state): return total + int(state.overflow), 0)}

func _exit_tree() -> void:
	_restore()
	if enabled and is_instance_valid(eye_camera): eye_camera.cull_mask = eye_mask
	for slot in slots + bands:
		if is_instance_valid(slot.layer): slot.layer.queue_free()
		if is_instance_valid(slot.hole): slot.hole.queue_free()
	if display: display.set_menu_layers(false)
