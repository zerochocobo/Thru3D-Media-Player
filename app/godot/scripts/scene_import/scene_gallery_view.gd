extends RefCounted
## The scene gallery page of the scene menu: scenes to download, eight to a page. Drawn into
## the menu with the menu's own parts; the menu only branches here for this one view.
const I18n := preload("res://scripts/i18n.gd")
const Gallery := preload("res://scripts/scene_import/scene_gallery.gd")
const COLUMNS := 4
const ROWS := 2
const PER_PAGE := COLUMNS * ROWS
const HEIGHT := 0.83
const FIRST_ROW := 0.30

static func state(menu: Node) -> Dictionary:
	var gallery: Variant = menu._scene_state().get("gallery")
	return gallery if gallery is Dictionary else {}

## A scene's name in the viewer's language; English where the catalogue has none for it.
static func title(card: Dictionary) -> String:
	var local := str(card.get("title_" + I18n.language.to_lower(), ""))
	return local if not local.is_empty() else str(card.get("title", ""))

## The credit the licence asks for: the work, its author, the licence, and that it was changed.
static func credit(card: Dictionary) -> String:
	return "“%s” · %s · %s · %s" % [str(card.get("work", "")), str(card.get("author", "")), str(card.get("license", "")), I18n.t("Adapted")]

## The page holding a scene, so the viewer comes back to where they were.
static func page_of(rows: Array, slug: String) -> int:
	for index in rows.size():
		if str(rows[index].get("slug", "")) == slug: return index / PER_PAGE
	return 0

static func draw(menu: Node) -> void:
	var rows: Array = state(menu).get("rows", [])
	var pages := maxi(1, ceili(rows.size() / float(PER_PAGE)))
	if not menu.gallery_placed:
		# First visit since the app started: the page last left on, wherever its scene now sits;
		# with nothing noted yet, the page of the scene in use.
		menu.gallery_placed = true
		var noted := str(state(menu).get("anchor", ""))
		if noted.is_empty():
			var using: String = menu._chosen()
			for card in rows:
				if not using.is_empty() and str(card.get("id", "")) == using: noted = str(card.slug)
		menu.page = page_of(rows, noted)
	menu.page = clampi(menu.page, 0, pages - 1)
	menu.gallery_page = menu.page
	menu._cards.clear()
	var chosen: String = menu._chosen()
	var line := ""
	for index in range(menu.page * PER_PAGE, mini(rows.size(), menu.page * PER_PAGE + PER_PAGE)):
		var card: Dictionary = rows[index].duplicate()
		# `id` is what the menu's press handling compares; the library entry stays in `entry`.
		card["entry"] = str(card.get("id", ""))
		card["id"] = "gallery:" + str(card.slug)
		menu._cards.append(card)
		var slot: int = index - menu.page * PER_PAGE
		_card(menu, card, menu._cards.size() - 1, menu._scene_slot(slot % COLUMNS, menu._top - FIRST_ROW - (slot / COLUMNS) * menu.SCENE_PITCH.y), chosen)
		if str(card.state) == Gallery.WITHDRAWN and str(card.entry).is_empty() and line.is_empty(): line = I18n.t("Withdrawn for copyright or other reasons")
	menu._paging(pages, menu._bottom + 0.12)
	var first: String = str(menu._cards[0].slug) if not menu._cards.is_empty() else ""
	if first != menu.gallery_anchor:
		menu.gallery_anchor = first
		menu.command.emit("gallery_anchor", first)
	# Beside the paging: why a card is greyed. The credit of the scene in use is the menu's corner line.
	menu._left(line, Vector2(menu.LEFT + 0.40, menu._bottom + 0.12), menu.TEXT_AUX, 0.92, menu.MUTED)

static func _card(menu: Node, card: Dictionary, index: int, point: Vector2, chosen: String) -> void:
	var kind := str(card.state)
	var installed := not str(card.entry).is_empty()
	var active := installed and str(card.entry) == chosen
	var gone := kind == Gallery.WITHDRAWN and not installed
	var size: Vector2 = menu.SCENE_CARD
	menu._button(menu.CARD + index, "", point, size, not gone)
	var node: Node3D = menu._buttons.back().node
	var layout: Dictionary = menu._card_layout(size)
	if active:
		menu._buttons.back().base_color = menu.ACCENT
		node.material_override.set_shader_parameter("surface_color", menu.ACCENT)
		var inset: MeshInstance3D = menu._quad(size - Vector2.ONE * 0.005, Vector3(0, 0, 0.003), menu.TILE, 11)
		inset.material_override.set_shader_parameter("corner_radius", 0.012)
		node.add_child(inset)
	var texture: Texture2D = menu.scene_import.gallery_preview(str(card.slug)) if is_instance_valid(menu.scene_import) else null
	if texture:
		var image := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = layout.image
		image.mesh = mesh
		image.position = Vector3(0, layout.image_y, 0.006)
		image.material_override = menu._material(Color(1, 1, 1, 0.35) if gone else Color.WHITE, 12)
		image.material_override.albedo_texture = texture
		node.add_child(image)
	else: menu._icon("cube", Vector3(0, layout.image_y, 0.007), 0.065, menu.MUTED, node)
	var ink: Color = menu.MUTED if gone else menu.UiTheme.color("label")
	menu._left(title(card), layout.caption, menu.TEXT_AUX, layout.caption_width, ink, node)
	menu._tips[menu.CARD + index] = title(card) + " · " + credit(card)
	if kind == Gallery.LOADING:
		menu._loading_overlay(node, layout, "%d%%" % roundi(float(card.progress) * 100.0))
		menu._tips[menu.CARD + index] = I18n.t("Cancel download")
	elif kind in [Gallery.QUEUED, Gallery.READY]:
		var shade := MeshInstance3D.new()
		var cover := QuadMesh.new()
		cover.size = layout.image
		shade.mesh = cover
		shade.position = Vector3(0, layout.image_y, 0.008)
		shade.material_override = menu._material(Color(0, 0, 0, 0.45), 13)
		node.add_child(shade)
		menu._label(I18n.t("Queued") if kind == Gallery.QUEUED else "…", Vector3(0, layout.image_y, 0.012), menu.TEXT_AUX, node).render_priority = 15
		if kind == Gallery.QUEUED: menu._tips[menu.CARD + index] = I18n.t("Cancel download")
	elif gone:
		_chip(menu, node, size, layout, "info", "")
		menu._tips[menu.CARD + index] = I18n.t("Withdrawn for copyright or other reasons")
	elif installed:
		if active:
			var badge: MeshInstance3D = menu._quad(Vector2(0.035, 0.035), Vector3(layout.badge.x, layout.badge.y, 0.012), menu.ACCENT, 14)
			badge.material_override.set_shader_parameter("corner_radius", 0.0175)
			node.add_child(badge)
			menu._icon("check", Vector3(layout.badge.x, layout.badge.y, 0.015), 0.024, menu.UiTheme.color("scene_check"), node).material_override.render_priority = 16
		else: _chip(menu, node, size, layout, "check", "")
	else:
		# What a press will cost: megabytes, rounded up so a small scene never reads as nothing.
		var megabytes := "%d MB" % maxi(1, ceili(float(card.bytes) / 1048576.0))
		_chip(menu, node, size, layout, "info" if kind == Gallery.FAILED else "download", megabytes, kind == Gallery.FAILED)
		if kind == Gallery.FAILED: menu._tips[menu.CARD + index] = I18n.t(str(card.error)) + " · " + title(card)

## The small label in a card's top-left corner.
static func _chip(menu: Node, node: Node3D, size: Vector2, layout: Dictionary, icon: String, text: String, alarm: bool = false) -> void:
	var width: float = (menu.text_width(text, 14) + 0.066) if not text.is_empty() else 0.05
	var centre := Vector3(-size.x * 0.5 + 0.02 + width * 0.5, layout.badge.y + 0.002, 0.012)
	var chip: MeshInstance3D = menu._quad(Vector2(width, 0.042), centre, menu.PANEL, 14)
	chip.material_override.set_shader_parameter("corner_radius", 0.008)
	node.add_child(chip)
	var ink: Color = menu.UiTheme.color("remove_ink") if alarm else menu.UiTheme.color("label")
	menu._icon(icon, centre + Vector3(-width * 0.5 + 0.025 if not text.is_empty() else 0.0, 0, 0.003), 0.026, ink, node).material_override.render_priority = 16
	if not text.is_empty(): menu._label(text, centre + Vector3(0.015, 0, 0.003), 14, node).render_priority = 16

## A press on a card: get it, give up getting it, or open what is already here.
static func activate(menu: Node, card: Dictionary) -> void:
	var kind := str(card.state)
	if kind in [Gallery.QUEUED, Gallery.LOADING]: menu.command.emit("gallery_cancel", str(card.slug))
	elif kind == Gallery.READY: return
	elif not str(card.entry).is_empty(): menu.command.emit("scene_select", str(card.entry))
	elif kind != Gallery.WITHDRAWN: menu.command.emit("gallery_get", str(card.slug))
