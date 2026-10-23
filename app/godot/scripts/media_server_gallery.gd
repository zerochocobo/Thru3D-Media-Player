extends RefCounted
## Fixed library and detail carousels, operated by rays and scroll input.
const I18n := preload("res://scripts/i18n.gd")
const BUTTON_OUTLINE := preload("res://shaders/menu_outline.gdshader")
const HOVER_PICTURE := preload("res://shaders/media_picture.gdshader")
const FAVORITE_COLOR := Color(1.0, 0.23, 0.30)
const ACTORS_VISIBLE := 5
const DETAIL_TITLE_SIZE := 30
const OVERVIEW_SIZE := 28
const OVERVIEW_LINE_SPACING := 8
const OVERVIEW_PAGE_LINES := 10
const LIBRARY := 4000
const PHOTO := 6000
const ACTOR := 8000
const PART := 10000
const RECENT := 12000
const TAG := 14000
var _owner: WeakRef
var browser: RefCounted:
	get: return _owner.get_ref()
var library_start := 0
var recent_start := 0
var home_strip := "libraries"
var image_start := 0
var actor_start := 0
var selected_image := 0
var part_start := 0
var selected_part := 0
var detail_start := 0
var tag_start := 0
var overview_start := 0
var detail_strip := "parts"
var _overview_text := ""
var _overview_language := ""
var _overview_lines: Array[String] = []
var capture := {}
var stick_at := 0

func _init(owner: RefCounted) -> void: _owner = weakref(owner)
func home() -> bool: return browser.view == "home" and browser.capabilities.get("home_layout", "") == "libraries"
func rich_detail() -> bool: return browser.view == "detail" and browser.capabilities.get("artwork", false)
func fixed() -> bool: return home() or rich_detail() or browser.view in ["picture", "overview"]
func state() -> Dictionary: return {"library_start": library_start, "recent_start": recent_start, "home_strip": home_strip, "image_start": image_start, "actor_start": actor_start, "selected_image": selected_image, "part_start": part_start, "selected_part": selected_part, "detail_start": detail_start, "tag_start": tag_start, "overview_start": overview_start}
func restore(value: Dictionary) -> void:
	library_start = int(value.get("library_start", 0)); image_start = int(value.get("image_start", 0))
	recent_start = int(value.get("recent_start", 0)); home_strip = str(value.get("home_strip", "libraries"))
	actor_start = int(value.get("actor_start", 0)); selected_image = int(value.get("selected_image", 0))
	part_start = int(value.get("part_start", 0)); selected_part = int(value.get("selected_part", 0))
	detail_start = int(value.get("detail_start", 0)); tag_start = int(value.get("tag_start", 0)); overview_start = int(value.get("overview_start", 0))
func libraries() -> Array: return browser.home_data.get("libraries", [])
func recent() -> Array: return browser.home_recent_entries()
func images() -> Array: return browser.detail.get("images", [])
func actors() -> Array: return browser.detail.get("actors", [])
func parts() -> Array: return browser.detail.get("parts", [])
func playback_node() -> Dictionary:
	return parts()[clampi(selected_part, 0, parts().size() - 1)] if parts().size() > 1 else browser.detail
func part_picture(part: Dictionary) -> Dictionary:
	return part.merged({"cover_image": part.get("part_image", part.get("cover_image", {}))}, true)

func priority_nodes() -> Array:
	var nodes: Array = []
	if home():
		library_start = clampi(library_start, 0, maxi(0, libraries().size() - 4))
		recent_start = clampi(recent_start, 0, maxi(0, recent().size() - 4))
		return libraries().slice(library_start, library_start + 4) + recent().slice(recent_start, recent_start + 4)
	if rich_detail():
		nodes.append(browser.display_node(browser.detail, "poster"))
		nodes.append_array(browser.backdrop.nodes())
		if "parts" in visible_sections():
			for part in parts().slice(part_start, part_start + 2): nodes.append(part_picture(part))
		if "images" in visible_sections():
			for item in images().slice(image_start, image_start + 3): nodes.append({"cover_image": item.merged({"max_width": 512})})
		if "actors" in visible_sections():
			for actor in actors().slice(actor_start, actor_start + ACTORS_VISIBLE): nodes.append(actor)
	elif browser.view == "picture" and not images().is_empty():
		selected_image = clampi(selected_image, 0, images().size() - 1)
		nodes.append({"cover_image": images()[selected_image].merged({"max_width": 1024})})
	return nodes

func action(target: int) -> bool:
	if rich_detail() and target >= TAG and target < TAG + tags().size():
		var value: Dictionary = tags()[target - TAG]
		browser._remember(); browser.labels.clear(); browser.folder_path.clear()
		browser.query = {"page": 1, "q": "", value.category: [str(value.item.id)]}
		browser.labels[str(value.category) + "/" + str(value.item.id)] = str(value.item.name)
		browser.browse(); return true
	var extra: int = target - browser.ACTION
	if rich_detail() and extra in [52, 53, 54, 55, 56]:
		match extra:
			52: tag_start = maxi(0, tag_start - 4)
			53: tag_start = mini(maxi(0, tags().size() - 4), tag_start + 4)
			54: detail_start = maxi(0, detail_start - 1)
			55: detail_start = mini(maxi(0, sections().size() - 2), detail_start + 1)
			56: browser._remember(); browser.cancel(); browser.view = "overview"; overview_start = 0; browser.menu._reset_navigation()
		browser.menu.refresh(); return true
	if browser.view == "overview" and extra in [57, 58]:
		overview_start = clampi(overview_start + (-OVERVIEW_PAGE_LINES if extra == 57 else OVERVIEW_PAGE_LINES), 0, maxi(0, overview_lines().size() - OVERVIEW_PAGE_LINES))
		browser.menu.refresh(); return true
	if home() and target >= LIBRARY and target < LIBRARY + libraries().size():
		browser.choose({"library": libraries()[target - LIBRARY]}); return true
	if home() and target >= RECENT and target < RECENT + recent().size():
		home_strip = "recent"; browser.choose({"scene": recent()[target - RECENT], "recent_opened": true}); return true
	if rich_detail() and target >= ACTOR and target < ACTOR + actors().size():
		browser.open_actor(actors()[target - ACTOR]); return true
	if rich_detail() and target >= PART and target < PART + parts().size():
		selected_part = target - PART; browser.menu.refresh(); return true
	if rich_detail() and target >= PHOTO and target < PHOTO + images().size():
		browser._remember(); browser.cancel(); selected_image = target - PHOTO
		browser.view = "picture"; browser.menu._reset_navigation(); browser.menu.refresh(); return true
	if not fixed(): return false
	var operation: int = target - browser.ACTION
	if operation in [30, 31, 32, 33, 34, 35, 38, 41, 42] and not rich_detail(): return false
	if operation in [36, 37, 43, 44] and not home(): return false
	if operation in [39, 40] and browser.view != "picture": return false
	match target - browser.ACTION:
		30: browser._play(playback_node(), int(playback_node().get("position_ms", -1)))
		31: browser._toggle_favorite()
		32: image_start = maxi(0, image_start - 3)
		33: image_start = mini(maxi(0, images().size() - 3), image_start + 3)
		34: actor_start = maxi(0, actor_start - ACTORS_VISIBLE)
		35: actor_start = mini(maxi(0, actors().size() - ACTORS_VISIBLE), actor_start + ACTORS_VISIBLE)
		36: home_strip = "libraries"; library_start = maxi(0, library_start - 1)
		37: home_strip = "libraries"; library_start = mini(maxi(0, libraries().size() - 4), library_start + 1)
		38: browser._remember(); browser.cancel(); browser.view = "metadata"; browser.menu._reset_navigation()
		39: selected_image = maxi(0, selected_image - 1)
		40: selected_image = mini(images().size() - 1, selected_image + 1)
		41: part_start = maxi(0, part_start - 2)
		42: part_start = mini(maxi(0, parts().size() - 2), part_start + 2)
		43: home_strip = "recent"; recent_start = maxi(0, recent_start - 1)
		44: home_strip = "recent"; recent_start = mini(maxi(0, recent().size() - 4), recent_start + 1)
		_: return false
	browser.menu.refresh(); return true

func stick_scroll(x: float, delta: float) -> void:
	if browser.view == "picture":
		if not capture.is_empty() or browser.menu.has_pointer_capture() or not browser.keyboard.is_empty() or browser.modal_open(): return
		if images().size() < 2 or not is_finite(x) or absf(x) < 0.55 or Time.get_ticks_msec() < stick_at: return
		stick_at = Time.get_ticks_msec() + 300
		var next_image := clampi(selected_image + (1 if x > 0 else -1), 0, images().size() - 1)
		if next_image != selected_image: action(browser.ACTION + (40 if x > 0 else 39))
		return
	if rich_detail():
		if capture.is_empty() and is_finite(x) and absf(x) >= 0.55 and Time.get_ticks_msec() >= stick_at:
			stick_at = Time.get_ticks_msec() + 220
			var actions: Array = {"parts": [41, 42], "actors": [34, 35], "images": [32, 33], "tags": [52, 53]}.get(detail_strip, [41, 42])
			action(browser.ACTION + int(actions[1 if x > 0 else 0]))
		return
	if (not home() and not rich_detail()) or not capture.is_empty() or not is_finite(x) or absf(x) < 0.55: return
	if Time.get_ticks_msec() < stick_at: return
	stick_at = Time.get_ticks_msec() + 220
	var strip := home_strip
	if home() and libraries().size() <= 4 and recent().size() > 4: strip = "recent"
	var operation := (44 if x > 0 else 43) if strip == "recent" else (37 if x > 0 else 36)
	action(browser.ACTION + (operation if home() else (42 if x > 0 else 41)))

func _home_strip_at(point: Vector3) -> String:
	if point.x < -0.5 or point.x > 0.81: return ""
	if point.y <= 0.19 and point.y >= -0.15: return "libraries"
	if not recent().is_empty() and point.y <= -0.22 and point.y >= -0.50: return "recent"
	return ""

func press(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if browser.modal_open(): return false
	if rich_detail() or browser.view == "overview": return detail_press(hand, origin, direction, tracked)
	if not home() and not rich_detail(): return false
	if not capture.is_empty(): return true
	var point: Variant = browser.menu._plane_point(origin, direction) if tracked else null
	if point == null: return false
	var strip := _home_strip_at(point) if home() else "parts"
	if strip.is_empty(): return false
	if strip == "parts" and (parts().size() < 2 or point.y > 0.035 or point.y < -0.17 or point.x < 0.0 or point.x > 0.80): return false
	var hit: Dictionary = browser.menu.ray_hit(origin, direction)
	var target := int(hit.get("target", -1))
	var minimum := RECENT if strip == "recent" else (LIBRARY if strip == "libraries" else PART)
	if target >= 0 and target < minimum: return false
	if home(): home_strip = strip
	var start := recent_start if strip == "recent" else (library_start if strip == "libraries" else part_start)
	capture = {"hand": hand, "x": float(point.x), "start": start, "target": target, "moved": false, "strip": strip}
	return true

func move(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if rich_detail() or browser.view == "overview":
		detail_move(hand, origin, direction, tracked); return
	if home() and capture.is_empty() and tracked:
		var hover: Variant = browser.menu._plane_point(origin, direction)
		if hover != null:
			var strip := _home_strip_at(hover)
			if not strip.is_empty(): home_strip = strip
	if capture.get("hand", "") != hand: return
	if not tracked: capture.clear(); return
	var point: Variant = browser.menu._plane_point(origin, direction)
	if point == null: return
	var travel := float(capture.x) - float(point.x)
	if absf(travel) > 0.015: capture.moved = true
	var limit := recent().size() - 4 if capture.strip == "recent" else (libraries().size() - 4 if capture.strip == "libraries" else parts().size() - 2)
	var next := clampi(int(capture.start) + roundi(travel / 0.30), 0, maxi(0, limit))
	if capture.strip == "libraries":
		if library_start != next: library_start = next; browser.menu.refresh()
	elif capture.strip == "recent":
		if recent_start != next: recent_start = next; browser.menu.refresh()
	elif part_start != next: part_start = next; browser.menu.refresh()

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if capture.get("hand", "") != hand: return false
	var held := capture.duplicate(); capture.clear()
	if tracked and not held.moved:
		var hit: Dictionary = browser.menu.ray_hit(origin, direction)
		if int(hit.get("target", -2)) == int(held.target): action(int(held.target))
	return true

func _label(text: String, position: Vector2, size: int = 17) -> Label3D:
	var label: Label3D = browser.menu._label(text, Vector3(position.x, position.y, 0.007), size)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label

func _picture(node: Dictionary, center: Vector2, area: Vector2, parent: Node3D = null) -> void:
	var menu: Node = browser.menu
	var picture: MeshInstance3D = menu._quad(area, Vector3(center.x, center.y, 0.005), menu.TILE, 12)
	if parent: parent.add_child(picture)
	else: menu.add_child(picture); menu._decorations.append(picture)
	var texture: Texture2D = browser.image_texture(node)
	if texture:
		var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture
		picture.material_override = material; browser._fit_picture(picture, texture, area)
		if parent: style_hover_picture(picture)
	else:
		menu._icon("image", Vector3(center.x, center.y, 0.008), minf(area.x, area.y) * 0.4, menu.MUTED, parent if parent else menu)

func style_hover_picture(picture: MeshInstance3D) -> void:
	var menu: Node = browser.menu
	if menu._buttons.is_empty(): return
	var button: Dictionary = menu._buttons.back()
	# Compact list thumbnails keep row feedback; image-led cards lift only the picture.
	if picture.get_parent() != button.node or button.rect.size.y < 0.20: return
	var image_size: Vector2 = picture.mesh.size
	var material := ShaderMaterial.new(); material.shader = HOVER_PICTURE; material.render_priority = 12
	material.set_shader_parameter("picture", picture.material_override.albedo_texture)
	material.set_shader_parameter("image_size", image_size)
	# Fixed bounds contain the enlarged image/shadow; hovering never resizes capture textures.
	picture.mesh.size = image_size * 1.025 + Vector2(0.02, 0.02)
	material.set_shader_parameter("surface_size", picture.mesh.size)
	picture.material_override = material
	if picture.has_meta("menu_original_shader"): picture.remove_meta("menu_original_shader")
	menu._apply_overlay_node(picture)
	button["hover_picture"] = picture

func _arrows(previous: int, next: int, y: float, start: int, total: int, count: int) -> void:
	browser.menu._button(browser.ACTION + previous, "‹", Vector2(-0.525, y), Vector2(0.06, 0.065), start > 0)
	browser.menu._button(browser.ACTION + next, "›", Vector2(0.845, y), Vector2(0.06, 0.065), start + count < total)

func draw_home() -> void:
	var menu: Node = browser.menu
	_label(I18n.t("Libraries"), Vector2(-0.46, 0.19), 21)
	for i in range(library_start, mini(libraries().size(), library_start + 4)):
		var item: Dictionary = libraries()[i]; var x := -0.36 + (i - library_start) * 0.333
		menu._button(LIBRARY + i, "", Vector2(x, 0.015), Vector2(0.30, 0.265))
		var card: MeshInstance3D = menu._buttons.back().node
		_picture(item, Vector2(0, 0.028), Vector2(0.278, 0.16), card)
		var title: Label3D = menu._label(menu._fit_title(str(item.title), "", 0.27, 20), Vector3(0, -0.087, 0.008), 20, card)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; menu._tips[LIBRARY + i] = str(item.title)
	_arrows(36, 37, 0.015, library_start, libraries().size(), 4)
	if libraries().is_empty() and not browser.busy and menu.status.is_empty(): _label(I18n.t("No items"), Vector2(0.07, -0.05), 18)
	var history := recent()
	if not history.is_empty():
		_label(I18n.t("Recently opened"), Vector2(-0.46, -0.185), 20)
		for i in range(recent_start, mini(history.size(), recent_start + 4)):
			var item: Dictionary = history[i]; var x := -0.36 + (i - recent_start) * 0.333
			menu._button(RECENT + i, "", Vector2(x, -0.355), Vector2(0.30, 0.265))
			var card: MeshInstance3D = menu._buttons.back().node
			_picture(item, Vector2(0, 0.028), Vector2(0.278, 0.16), card)
			var title: Label3D = menu._label(menu._fit_title(str(item.get("title", "Video")), "", 0.27, 20), Vector3(0, -0.087, 0.008), 20, card)
			title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; menu._tips[RECENT + i] = str(item.get("title", "Video"))
			var duration := int(item.get("duration_ms", 0)); var position := int(item.get("position_ms", 0))
			if duration > 0 and position > 0:
				var progress := clampf(float(position) / duration, 0, 1)
				card.add_child(menu._quad(Vector2(0.268 * progress, 0.005), Vector3(-0.134 + 0.134 * progress, -0.12, 0.009), menu.ACCENT, 14))
		_arrows(43, 44, -0.355, recent_start, history.size(), 4)
	elif not str(browser.home_data.get("recent_error", "")).is_empty():
		_label(I18n.t(str(browser.home_data.recent_error)), Vector2(-0.46, -0.185), 16).modulate = menu.MUTED

func draw_detail() -> void:
	var menu: Node = browser.menu; var detail: Dictionary = browser.detail
	browser.backdrop.draw()
	if detail_strip not in visible_sections() and (detail_strip != "tags" or tags().is_empty()):
		detail_strip = str(visible_sections()[0]) if not visible_sections().is_empty() else "tags"
	_picture(browser.display_node(detail, "poster"), Vector2(-0.335, 0.33), Vector2(0.28, 0.41))
	var title_lines: Array[String] = browser.wrapped_lines(str(detail.get("title", "")), 0.80, DETAIL_TITLE_SIZE)
	var title := _label("\n".join(title_lines.slice(0, 2)), Vector2(-0.015, 0.52), DETAIL_TITLE_SIZE)
	title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var playback := playback_node(); var meta: Array[String] = []
	if int(detail.get("year", 0)) > 0: meta.append(str(detail.year))
	if int(playback.get("duration_ms", 0)) > 0: meta.append(browser._time(int(playback.duration_ms)))
	var width := int(playback.get("width", 0)); var height := int(playback.get("height", 0))
	if width > 0 and height > 0:
		var resolution := "8K" if width >= 7680 else ("6K" if width >= 6000 else ("4K" if width >= 3840 else ""))
		meta.append((resolution + " · " if not resolution.is_empty() else "") + "%d × %d" % [width, height])
	_label(" · ".join(meta), Vector2(-0.015, 0.385), 16).modulate = menu.MUTED
	var lines: Array[String] = browser.wrapped_lines(str(detail.get("description", "")), 0.78, 18)
	var overview := _label("\n".join(lines.slice(0, 3)), Vector2(-0.015, 0.34), 18)
	overview.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if lines.size() > 3: menu._button(browser.ACTION + 56, I18n.t("More"), Vector2(0.65, 0.215), Vector2(0.19, 0.06))
	var play_label := I18n.t("Continue watching" if int(playback.get("position_ms", 0)) > 0 else "Play / resume")
	if parts().size() > 1: play_label += " · " + str(playback.get("part_label", ""))
	menu._button(browser.ACTION + 30, play_label, Vector2(0.19, 0.135), Vector2(0.48, 0.075), not browser.busy, "play")
	# Replace the existing plate with one hollow outline; no extra surface or capture.
	var play_button: Dictionary = menu._buttons.back()
	play_button.node.material_override.shader = BUTTON_OUTLINE
	play_button.node.material_override.render_priority = 12
	play_button.base_color = Color(0.72, 0.79, 0.82, 0.85)
	play_button.node.material_override.set_shader_parameter("surface_color", play_button.base_color)
	if play_button.node.has_meta("menu_original_shader"): play_button.node.remove_meta("menu_original_shader")
	menu._apply_overlay_node(play_button.node)
	var favorite: bool = browser._is_favorite(detail)
	menu._button(browser.ACTION + 31, "", Vector2(0.51, 0.135), Vector2(0.09, 0.075), not browser.busy, "heart_filled" if favorite else "heart")
	menu._tips[browser.ACTION + 31] = I18n.t("Favorited" if favorite else "Favorite")
	if favorite:
		var favorite_button: Dictionary = menu._buttons.back()
		favorite_button.node.get_child(1).material_override.albedo_color = FAVORITE_COLOR
		var caption: Label3D = menu._label(I18n.t("Favorited"), Vector3(0, -0.05, 0.004), 16, favorite_button.node)
		caption.modulate = Color(0.93, 0.95, 0.98)
	menu._button(browser.ACTION + 38, "", Vector2(0.64, 0.135), Vector2(0.09, 0.075), true, "info")
	for strip in visible_sections():
		var y := section_y(strip)
		_label(I18n.t({"parts": "Parts", "actors": "Performers", "images": "Images"}[strip]), Vector2(-0.46, y + 0.145), 18)
		match strip:
			"parts":
				for i in range(part_start, mini(parts().size(), part_start + 2)):
					menu._button(PART + i, "", Vector2(0.18 + (i - part_start) * 0.36, y), Vector2(0.33, 0.255))
					menu._lit(i == selected_part)
					var card: MeshInstance3D = menu._buttons.back().node
					_picture(part_picture(parts()[i]), Vector2(0, 0.014), Vector2(0.31, 0.207), card)
					var caption: Label3D = menu._label(str(parts()[i].get("part_label", "#%d" % (i + 1))), Vector3(0, -0.108, 0.009), 16, card)
					caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; caption.modulate = menu.ACCENT if i == selected_part else Color.WHITE
					menu._tips[PART + i] = str(parts()[i].get("title", ""))
				if parts().size() > 2:
					menu._button(browser.ACTION + 41, "‹", Vector2(-0.027, y), Vector2(0.04, 0.06), part_start > 0)
					menu._button(browser.ACTION + 42, "›", Vector2(0.755, y), Vector2(0.04, 0.06), part_start + 2 < parts().size())
			"actors":
				for i in range(actor_start, mini(actors().size(), actor_start + ACTORS_VISIBLE)):
					var actor: Dictionary = actors()[i]; var x := -0.37 + (i - actor_start) * 0.265
					menu._button(ACTOR + i, "", Vector2(x, y), Vector2(0.23, 0.255))
					var card: MeshInstance3D = menu._buttons.back().node
					_picture(actor, Vector2(0, 0.014), Vector2(0.14, 0.21), card)
					var label: Label3D = menu._label(menu._fit_title(str(actor.name), "", 0.22, 17), Vector3(0, -0.108, 0.008), 17, card)
					label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; menu._tips[ACTOR + i] = str(actor.name)
					_arrows(34, 35, y, actor_start, actors().size(), ACTORS_VISIBLE)
			"images":
				for i in range(image_start, mini(images().size(), image_start + 3)):
					menu._button(PHOTO + i, "", Vector2(-0.28 + (i - image_start) * 0.43, y), Vector2(0.39, 0.235))
					_picture({"cover_image": images()[i].merged({"max_width": 512})}, Vector2.ZERO, Vector2(0.315, 0.21), menu._buttons.back().node)
				_arrows(32, 33, y, image_start, images().size(), 3)
	if sections().size() > 2:
		menu._button(browser.ACTION + 54, "", Vector2(0.925, -0.055), Vector2(0.075, 0.065), detail_start > 0, "scroll_up")
		menu._button(browser.ACTION + 55, "", Vector2(0.925, -0.405), Vector2(0.075, 0.065), detail_start + 2 < sections().size(), "scroll_down")
	var values := tags(); tag_start = clampi(tag_start, 0, maxi(0, values.size() - 4))
	for i in range(tag_start, mini(values.size(), tag_start + 4)):
		var name := str(values[i].item.name)
		menu._button(TAG + i, menu._fit_title(name, "", 0.27, 17), Vector2(-0.36 + (i - tag_start) * 0.333, -0.565), Vector2(0.30, 0.065))
		menu._tips[TAG + i] = name
	if values.size() > 4: _arrows(52, 53, -0.565, tag_start, values.size(), 4)

func draw_picture() -> void:
	if images().is_empty(): return
	_picture({"cover_image": images()[selected_image].merged({"max_width": 1024})}, Vector2(0.16, -0.1), Vector2(1.24, 0.58))
	_arrows(39, 40, -0.1, selected_image, images().size(), 1)
	_label("%d / %d" % [selected_image + 1, images().size()], Vector2(0.08, -0.46), 17)

func sections() -> Array:
	var result: Array = []
	if parts().size() > 1: result.append("parts")
	if not actors().is_empty(): result.append("actors")
	if not images().is_empty(): result.append("images")
	return result

func visible_sections() -> Array:
	detail_start = clampi(detail_start, 0, maxi(0, sections().size() - 2))
	return sections().slice(detail_start, detail_start + 2)

func section_y(strip: String) -> float:
	return -0.10 - visible_sections().find(strip) * 0.29

func tags() -> Array:
	var result: Array = []; var seen := {}
	for category in ["tags", "genres"]:
		for item in browser.detail.get(category, []):
			var name := str(item.get("name", ""))
			if name.is_empty() or seen.has(name): continue
			seen[name] = true; result.append({"category": category, "item": item})
	return result

func overview_lines() -> Array[String]:
	var text := str(browser.detail.get("description", ""))
	if text != _overview_text or _overview_language != I18n.language:
		_overview_text = text; _overview_language = I18n.language
		_overview_lines = browser.wrapped_lines(text, 1.25, OVERVIEW_SIZE)
	return _overview_lines

func overview_line_height() -> float:
	var menu: Node = browser.menu
	return (menu.ui_font().get_height(OVERVIEW_SIZE * menu.TEXT_RASTER_SCALE) + OVERVIEW_LINE_SPACING * menu.TEXT_RASTER_SCALE) * menu.TEXT_PIXEL_SIZE

func draw_overview() -> void:
	_label(I18n.t("Synopsis"), Vector2(-0.46, 0.45), DETAIL_TITLE_SIZE)
	var lines := overview_lines(); overview_start = clampi(overview_start, 0, maxi(0, lines.size() - OVERVIEW_PAGE_LINES))
	var text := _label("\n".join(lines.slice(overview_start, overview_start + OVERVIEW_PAGE_LINES)), Vector2(-0.46, 0.32), OVERVIEW_SIZE)
	text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	text.line_spacing = OVERVIEW_LINE_SPACING * browser.menu.TEXT_RASTER_SCALE
	if lines.size() > OVERVIEW_PAGE_LINES:
		browser.menu._button(browser.ACTION + 57, "", Vector2(0.925, 0.25), Vector2(0.075, 0.065), overview_start > 0, "scroll_up")
		browser.menu._button(browser.ACTION + 58, "", Vector2(0.925, -0.45), Vector2(0.075, 0.065), overview_start + OVERVIEW_PAGE_LINES < lines.size(), "scroll_down")

func vertical_scroll(y: float, _delta: float) -> void:
	if not rich_detail() and browser.view != "overview": return
	if not capture.is_empty() or not is_finite(y) or absf(y) < 0.55 or Time.get_ticks_msec() < stick_at: return
	stick_at = Time.get_ticks_msec() + 220
	if rich_detail(): action(browser.ACTION + (54 if y > 0 else 55))
	elif browser.view == "overview": action(browser.ACTION + (57 if y > 0 else 58))

func detail_strip_at(point: Vector3) -> String:
	if point.x < -0.5 or point.x > 0.81: return ""
	if browser.view == "overview": return "overview" if point.y <= 0.32 and point.y >= -0.48 else ""
	if not tags().is_empty() and absf(point.y + 0.565) < 0.05: return "tags"
	for strip in visible_sections():
		if absf(point.y - section_y(strip)) < 0.13: return strip
	return "body" if point.y <= 0.065 and point.y >= -0.52 else ""

func detail_press(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not capture.is_empty(): return true
	var point: Variant = browser.menu._plane_point(origin, direction) if tracked else null
	if point == null: return false
	var strip := detail_strip_at(point)
	if strip.is_empty(): return false
	var hit: Dictionary = browser.menu.ray_hit(origin, direction); var target := int(hit.get("target", -1))
	var minimum: int = {"parts": PART, "actors": ACTOR, "images": PHOTO, "tags": TAG}.get(strip, 99999)
	if target >= 0 and target < minimum: return false
	var start: int = {"parts": part_start, "actors": actor_start, "images": image_start, "tags": tag_start}.get(strip, 0)
	capture = {"hand": hand, "x": float(point.x), "y": float(point.y), "start": start, "vertical_start": overview_start if browser.view == "overview" else detail_start, "target": target, "moved": false, "strip": strip, "axis": ""}
	return true

func detail_move(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	var point: Variant = browser.menu._plane_point(origin, direction) if tracked else null
	if capture.is_empty():
		if point != null:
			var strip := detail_strip_at(point)
			if strip in ["parts", "actors", "images", "tags"]: detail_strip = strip
		return
	if capture.get("hand", "") != hand: return
	if not tracked: capture.clear(); return
	if point == null: return
	var travel := float(capture.x) - float(point.x); var vertical := float(point.y) - float(capture.y)
	if not capture.moved and maxf(absf(travel), absf(vertical)) > 0.015:
		capture.moved = true; capture.axis = "vertical" if absf(vertical) > absf(travel) or capture.strip in ["body", "overview"] else "horizontal"
	if not capture.moved: return
	if capture.axis == "vertical":
		if browser.view == "overview": overview_start = clampi(int(capture.vertical_start) + roundi(vertical / overview_line_height()), 0, maxi(0, overview_lines().size() - OVERVIEW_PAGE_LINES))
		else: detail_start = clampi(int(capture.vertical_start) + roundi(vertical / 0.18), 0, maxi(0, sections().size() - 2))
	else:
		var limits := {"parts": parts().size() - 2, "actors": actors().size() - ACTORS_VISIBLE, "images": images().size() - 3, "tags": tags().size() - 4}
		var next := clampi(int(capture.start) + roundi(travel / (0.265 if capture.strip == "actors" else 0.30)), 0, maxi(0, int(limits.get(capture.strip, 0))))
		match capture.strip:
			"parts": part_start = next
			"actors": actor_start = next
			"images": image_start = next
			"tags": tag_start = next
	browser.menu.refresh()
