extends RefCounted
## Detail artwork only. Two textures and one outstanding next-image request are enough.
const SHADER := preload("res://shaders/library_backdrop.gdshader")
const INTERVAL := 12.0
const FADE := 0.7
var _owner: WeakRef
var mode := "slideshow"
var key := ""
var pictures: Array = []
var index := 0
var elapsed := 0.0
var progress := 0.0
var current: Texture2D
var next: Texture2D
var surface: MeshInstance3D
var _panel_material: Material

func _init(browser: RefCounted) -> void: _owner = weakref(browser)

func active() -> bool:
	var browser = _owner.get_ref()
	return browser != null and mode != "off" and browser.menu.is_visible_in_tree() and browser.menu.section == browser.menu.Section.MEDIA_SERVER \
		and browser.gallery.rich_detail() and browser.keyboard.is_empty()

func sync() -> void:
	var browser = _owner.get_ref()
	var incoming := str([browser.server.get("id", ""), browser.detail.get("id", ""), mode, browser.detail.get("backdrops", [])])
	if incoming == key: return
	key = incoming; index = 0; elapsed = 0; progress = 0; current = null; next = null
	pictures = browser.detail.get("backdrops", []).filter(func(item): return item is Dictionary and item.get("image_type", "") in ["Backdrop", "Thumb", "Screenshot"]).slice(0, 12)

func nodes() -> Array:
	sync()
	if not active() or pictures.is_empty(): return []
	var result := [{"cover_image": pictures[index].merged({"max_width": 1024})}]
	if mode == "slideshow" and pictures.size() > 1 and elapsed >= INTERVAL - 2.0:
		result.append({"cover_image": pictures[(index + 1) % pictures.size()].merged({"max_width": 1024})})
	return result

func clear_surface() -> void:
	if is_instance_valid(surface) and _panel_material != null:
		surface.material_override = _panel_material
		if surface.has_meta("menu_original_shader"): surface.remove_meta("menu_original_shader")
		var browser = _owner.get_ref()
		if browser != null: browser.menu._apply_overlay_node(surface)
	_panel_material = null
	surface = null

func draw() -> void:
	clear_surface()
	var wanted := nodes()
	if wanted.is_empty(): return
	var browser = _owner.get_ref()
	current = browser.image_texture(wanted[0])
	if current == null: return
	var menu = browser.menu
	var area: Vector2 = menu._backdrop.mesh.size
	# Use the panel itself: equal-priority transparent quads can reverse order in XR.
	# Buttons stay above artwork without an extra quad or competing opaque panel fill.
	surface = menu._backdrop
	_panel_material = surface.material_override
	if surface.has_meta("menu_original_shader"):
		_panel_material.shader = surface.get_meta("menu_original_shader")
		surface.remove_meta("menu_original_shader")
	var material := ShaderMaterial.new(); material.shader = SHADER; material.render_priority = 10
	material.set_shader_parameter("picture", current)
	material.set_shader_parameter("upcoming", next if next else current)
	material.set_shader_parameter("transition", progress / FADE)
	material.set_shader_parameter("surface_size", area)
	material.set_shader_parameter("corner_radius", _panel_material.get_shader_parameter("corner_radius"))
	surface.material_override = material
	menu._apply_overlay_node(surface)

func tick(delta: float) -> void:
	if not active():
		elapsed = 0; progress = 0; current = null; next = null
		return
	# Page/image callbacks redraw the surface. A loaded still needs no per-frame
	# metadata serialization, cache lookups, texture requests or repaint signals.
	if mode == "static" and current != null: return
	sync()
	var browser = _owner.get_ref()
	var menu = browser.menu
	if not pictures.is_empty():
		var request: Dictionary = browser._image_request({"cover_image": pictures[index].merged({"max_width": 1024})})
		if browser.failed_covers.has(browser._request_image_key(request)):
			pictures.remove_at(index); index = mini(index, maxi(0, pictures.size() - 1))
			current = null; next = null; elapsed = 0; progress = 0
			menu.refresh()
			return
	if mode != "slideshow" or pictures.size() < 2: return
	if menu.has_pointer_capture() or not browser.gallery.capture.is_empty() or absf(menu._fling) > 0.4 \
		or Time.get_ticks_msec() - menu._stick_ms < 250 or (is_instance_valid(menu._tooltip) and menu._tooltip.visible): return
	elapsed += minf(delta, 0.1)
	var wanted := nodes()
	if current == null: current = browser.image_texture(wanted[0])
	if wanted.size() > 1 and next == null:
		var request: Dictionary = browser._image_request(wanted[1])
		if browser.failed_covers.has(browser._request_image_key(request)):
			pictures.remove_at((index + 1) % pictures.size())
			index = mini(index, pictures.size() - 1); elapsed = 0; return
		next = browser.image_texture(wanted[1])
	if elapsed < INTERVAL or next == null or current == null or not is_instance_valid(surface): return
	progress = minf(FADE, progress + delta)
	surface.material_override.set_shader_parameter("upcoming", next)
	surface.material_override.set_shader_parameter("transition", progress / FADE)
	menu.composition_changed.emit()
	if progress >= FADE:
		index = (index + 1) % pictures.size(); current = next; next = null; elapsed = 0; progress = 0
		surface.material_override.set_shader_parameter("picture", current)
		surface.material_override.set_shader_parameter("upcoming", current)
		surface.material_override.set_shader_parameter("transition", 0.0)
