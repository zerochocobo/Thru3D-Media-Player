extends "res://scripts/ray_menu.gd"
## The reader's controls: a ring of runes the wand calls up where it points. Its rim is the reading
## position and can be pointed along to leap anywhere; the contents, bookmarks, search and the reading
## settings open in its place. Hidden while reading.

const Model := preload("res://scripts/book_model.gd")
## A band of light that fills clockwise from the top with the position through the book; [aim] marks
## where the wand points along it.
const ARC_SHADER := """
shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 colour : source_color = vec3(1.0, 0.80, 0.42);
uniform float filled = 0.0;
uniform float aim = -1.0;
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float turn = fract(atan(p.x, -p.y) / TAU);
	float band = smoothstep(0.035, 0.0, abs(r - 0.93));
	float lit = turn <= filled ? 1.5 : 0.22;
	// The stretch between here and where the wand points glows, so a leap reads before it is made.
	if (aim >= 0.0 && turn >= min(aim, filled) && turn <= max(aim, filled)) lit = max(lit, 0.8);
	float bead = aim >= 0.0 ? smoothstep(0.022, 0.0, length(p - vec2(sin(aim * TAU), -cos(aim * TAU)) * 0.93)) : 0.0;
	float here = smoothstep(0.016, 0.0, length(p - vec2(sin(filled * TAU), -cos(filled * TAU)) * 0.93));
	ALBEDO = colour * (band * lit + bead * 3.0 + here * 2.0);
	// Light adds to what is behind it, but must not make the eye buffer opaque: where the eye buffer is
	// cleared over a page or menu layer (or passthrough), additive blending wrote alpha 1 across the
	// whole quad and showed it as a black square. Coverage follows the light itself.
	ALPHA = clamp(max(ALBEDO.r, max(ALBEDO.g, ALBEDO.b)), 0.0, 1.0);
}
"""
const A_LETTER := "A"
const CONTENTS := 1
const SETTINGS := 2
const NIGHT := 4
const AUTO := 5
const RECENTER := 6
const LIBRARY := 7
const EXIT := 8
const BACK := 9
const UP := 10
const DOWN := 11
const RETURN := 12
const RIM := 13
const MARK := 14
const TAB_CONTENTS := 15
const TAB_MARKS := 16
const TAB_SEARCH := 17
const QUERY := 18
const MUSIC := 19
const FAVORITE := 20
const SCENE := 21
## A bookmark row's own remove button: REMOVE + its index.
const REMOVE := 100000
const LISTS := ["contents", "marks", "search", "settings"]
const TextInput := preload("res://scripts/system_text_input.gd")
const SIZE_BASE := 40
const PAPER_BASE := 60
## Above the twelve papers (60..71).
const LIGHT_BASE := 86
const ONE_PAGE := 80
const TWO_PAGES := 81
## The settings' rows, well clear of the list rows (ROW + index).
const WARM_BASE := 50000
const SPACING_BASE := 50010
const PARAGRAPH_BASE := 50020
const MEASURE_BASE := 50030
const BOOK_SIZE_BASE := 50040
const REACH_BASE := 50050
const AUTO_BASE := 50060
const TURN_BASE := 50070
const SECTION_BASE := 50080
const AUTO_SWITCH := 50090
const READ := 3
const READ_SWITCH := 50091
const SOUND_SWITCH := 50092
const STYLE_BASE := 50093
const PREVIEW := 50096
const CLONE_BASE := 50180
const WAND_BASE := 50190
const CLONES := 5
const PICTURE_SWITCH := 50097
const PICTURE_CHOOSE := 50098
const VOICE_BASE := 50100
const SPEED_BASE := 50120
const FONT_BASE := 50140
const FONT_REMOVE_BASE := 50160
const Narration := preload("res://scripts/narration_settings.gd")
## The settings' pages: [name, icon (empty: the letters Aa), tip].
const SECTIONS := [["look", "adjust", "Appearance"], ["type", "", "Text"], ["font", "", "Fonts"], ["book", "magazine", "Book"],
	["turn", "bolt", "Turning pages"], ["read", "voice", "Read aloud"], ["auto", "hourglass", "Auto page turn"]]
const ROW := 100
const ROWS := 8
const IDLE_MS := 6000
const RADIUS := 0.33
## The rim band in which the wand leaps through the book, from the centre of the ring.
const RIM_RADIUS := 0.445
const RIM_BAND := 0.04
const APPEAR_SECONDS := 0.22
var reader: Node3D
var mode := "bar"
## The background music, as the other menus show it: [audio_state] gives its state, [music_toggle]
## plays or pauses it, and [signal music_requested] asks for the full player.
signal music_requested
## The book goes into, or out of, the app's favourites.
signal favorite_requested
## The scene panel, as the library's Scene button calls it.
signal scene_requested
## {"enabled", "selected", "locked"} for the open book, from the app's favourites.
var favorite_state: Callable
var audio_state: Callable
var music_toggle: Callable
## The settings page on show.
var section := "look"
var first := 0
## Where to come back to after a leap through the rim or the contents ("chapter/block/character"), or "".
## A position, not a page: a fuller layout or new type settings renumber the pages.
var return_at := ""
var _touched := 0
var _scroll := 0.0
var _grown := 1.0
var _size := 1.0
var _arc: MeshInstance3D
var _lines: Array[Label3D] = []
var _aimed := {}
var _scrub := -1.0
var editor := TextInput.new(self)
## The search: what was asked, the hits that came back, and whether more were left out.
var query := ""
var _searching := 0
var _hits: Array = []
var _more := false
var _searched := ""
var _font_redraw := 0
## The cloned voices the read page last showed, to redraw it when the list arrives or changes.
var _cloned_ids: Array = []
var _audition_drawn := false

func composition_root() -> Node3D: return self
func has_pointer_capture() -> bool: return false
func release_pointer(_hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> void: pass
func grab_hit(_origin: Vector3, _direction: Vector3) -> Dictionary: return {}
## The headset's battery and the time go in the ring's centre, not in a footer of their own.
func _place_device_status(_centre: Vector2) -> void: pass

func _ready() -> void:
	super._ready()
	top_level = true
	reader.found.connect(_on_found)

## The contents, the bookmarks or the search are showing in place of the ring.
func listing() -> bool: return mode in LISTS
func text_entry_active() -> bool: return editor.active()

## Appears where the wand points, facing the reader, and stays there until dismissed.
func open(next: String = "bar") -> void:
	mode = next
	if mode == "contents": first = clampi(_current_row() - 2, 0, maxi(0, _rows().size() - _visible_rows()))
	elif listing(): first = 0
	if not visible:
		var pose: Variant = reader.menu_pose()
		if pose is Transform3D:
			_size = pose.basis.get_scale().x
			global_transform = pose
		_grown = 0.0
	visible = true
	touch()
	refresh()

func _toggle_music() -> void:
	if music_toggle.is_valid(): music_toggle.call()

func dismiss() -> void:
	editor.cancel()
	_aimed.clear(); _scrub = -1.0
	super.dismiss()

func touch() -> void: _touched = Time.get_ticks_msec()

## B steps back one level: a list or the settings, the ring, then nothing.
func back() -> void:
	if editor.active(): editor.cancel(); refresh()
	elif listing(): open("bar")
	else: dismiss()

## Leaps to a page and offers the way back to where the reader was.
func leap(index: int) -> void:
	var here: int = reader.first_page()
	if absi(index - here) > 2: return_at = reader.place_of(here)
	reader.leap(index)

## A new book: nothing of the last one's way back or search carries over.
func forget() -> void:
	return_at = ""
	query = ""; _hits = []; _more = false; _searched = ""; _searching = 0
	if editor.active(): editor.cancel()

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super.update_pointer(hand, origin, direction, tracked)
	if tracked and not pointer_hit(origin, direction).is_empty(): touch()
	# The small player reaches past the ring; while it is open the ring stays.
	if music_quick and music_quick.expanded: touch()
	var along := _rim(origin, direction) if tracked and mode == "bar" and ray_hit(origin, direction).is_empty() else -1.0
	if along >= 0.0: _aimed[hand] = along; touch()
	else: _aimed.erase(hand)
	var scrub: float = _aimed.values().back() if not _aimed.is_empty() else -1.0
	if not is_equal_approx(scrub, _scrub):
		_scrub = scrub
		_show_position()

## The trigger on the rim leaps there; anywhere else it works the runes.
func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if tracked and mode == "bar" and reader.count > 0 and ray_hit(origin, direction).is_empty():
		var along := _rim(origin, direction)
		if along >= 0.0:
			leap(_rim_page(along))
			_aimed.clear(); _scrub = -1.0
			refresh()
			return true
	return super.press_pointer(hand, origin, direction, tracked)

## Where the ray crosses the rim, as a fraction clockwise from the top, or -1.
func _rim(origin: Vector3, direction: Vector3) -> float:
	if not visible or reader == null: return -1.0
	var inverse := global_transform.affine_inverse()
	var start: Vector3 = inverse * origin
	var ray: Vector3 = inverse.basis * direction
	if ray.z >= -0.00001 or start.z <= 0.0: return -1.0
	var point: Vector3 = start + ray * (-start.z / ray.z)
	var flat := Vector2(point.x, point.y)
	if absf(flat.length() - RIM_RADIUS) > RIM_BAND: return -1.0
	return fposmod(atan2(flat.x, flat.y) / TAU, 1.0)

func _rim_page(along: float) -> int:
	return clampi(roundi(along * (reader.count - 1)), 0, reader.count - 1)

func _process(delta: float) -> void:
	if not visible: return
	if _grown < 1.0:
		# The ring unfurls from the wand's tip instead of popping into place.
		_grown = minf(1.0, _grown + delta / APPEAR_SECONDS)
		var eased := 1.0 - pow(1.0 - _grown, 3.0)
		global_transform = Transform3D(global_basis.orthonormalized().scaled(Vector3.ONE * _size * lerpf(0.35, 1.0, eased)), global_position)
		# The compositor measures the ring when it repaints: it repaints as the ring grows.
		composition_changed.emit()
	if mode == "bar" and Time.get_ticks_msec() - _touched > IDLE_MS: dismiss()
	if mode == "settings" and section == "read" and Time.get_ticks_msec() > _font_redraw:
		_font_redraw = Time.get_ticks_msec() + 400
		if reader.narration.cloned().map(func(item): return str(item.id)) != _cloned_ids or reader.narration.audition != _audition_drawn: refresh()
	if mode == "settings" and section == "font" and Time.get_ticks_msec() > _font_redraw:
		_font_redraw = Time.get_ticks_msec() + 500
		if reader.fonts.rows.any(func(item): return reader.fonts.state_of(str(item.slug)) in ["loading", "queued"]): refresh()

func stick_scroll(value: float, delta: float) -> void:
	if not listing() or absf(value) < 0.2: return
	touch()
	_scroll += -value * delta * 9.0
	var step := int(_scroll)
	if step == 0: return
	_scroll -= step
	_move(step)

func _move(rows: int) -> void:
	var next := clampi(first + rows, 0, maxi(0, _rows().size() - _visible_rows()))
	if next != first: first = next; refresh()

func _current_row() -> int:
	var row := 0
	for i in reader.contents.size():
		var at := int(reader.contents[i].page)
		if at >= 0 and at <= reader.first_page(): row = i
	return row

func _light(code: String, size: float, depth: float, values: Dictionary) -> MeshInstance3D:
	var shader := Shader.new(); shader.code = code
	var material := ShaderMaterial.new(); material.shader = shader; material.render_priority = 10
	for key in values: material.set_shader_parameter(key, values[key])
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new(); quad.size = Vector2.ONE * size
	node.mesh = quad; node.material_override = material; node.position = Vector3(0, 0, depth)
	add_child(node); _decorations.append(node)
	# The ring itself goes to the compositor with the other menus; its lights turn and follow the
	# wand, so they stay in the eye buffer and glow over it rather than freeze in a captured image.
	node.set_meta("menu_eye_buffer", true)
	return node

func _draw() -> void:
	_clear_layout()
	_arc = null; _lines.clear()
	if not is_instance_valid(reader): return
	if mode == "settings": _draw_settings(); return
	if listing(): _draw_list(); return
	# A dark disc keeps the runes legible wherever the ring is called up, even across a page.
	_set_backdrop(Vector2.ONE * RADIUS * 2.75); _backdrop.visible = true
	_backdrop.material_override.set_shader_parameter("corner_radius", RADIUS * 1.375)
	_backdrop.material_override.set_shader_parameter("solid", true)
	var ready: bool = reader.count > 0
	_light(Model.CIRCLE_SHADER, RADIUS * 2.2, 0.001, {"strength": 0.22})
	_arc = _light(ARC_SHADER, RIM_RADIUS * 2.0 / 0.93, 0.0015, {"filled": clampf(reader.fraction(), 0.0, 1.0) if ready else 0.0})
	# Chapter, page, how far through the book, and the time with the headset's battery.
	_lines.append(_label("", Vector3(0, 0.085, 0.004), 20))
	_lines.append(_label("", Vector3(0, 0.03, 0.004), 28))
	_lines.append(_label("", Vector3(0, -0.025, 0.004), 22))
	_lines.append(_label("", Vector3(0, -0.08, 0.004), 20))
	_lines[2].modulate = ACCENT
	_lines[3].modulate = MUTED
	_show_position()
	# Clockwise from the top: contents, then the settings, day or night, the favourite star, reading
	# aloud and the pages turning by themselves on the right, every 30 degrees as on the left.
	var liked: Dictionary = favorite_state.call() if favorite_state.is_valid() else {}
	var runes := [
		[CONTENTS, "list", 90.0, ready and not reader.contents.is_empty(), "Contents"],
		[SETTINGS, "settings", 60.0, true, "Reading settings"],
		[NIGHT, "light" if reader.night() else "night", 30.0, true, "Day" if reader.night() else "Night"],
		[FAVORITE, "lock" if liked.get("locked", false) else "star_filled" if liked.get("selected", false) else "star", 0.0,
			liked.get("enabled", false), "Remove favorite" if liked.get("selected", false) else "Add favorite"],
		[READ, "stop" if reader.narration.on else "voice", -30.0, ready and reader.narration.supported(),
			"Stop reading aloud" if reader.narration.on else "Read aloud"],
		# Its own sign, not a play button: the music entry on the left has the play button.
		[AUTO, "auto_turn", -60.0, ready, "Stop turning pages" if reader.auto else "Turn pages by themselves"],
		[EXIT, "close", -90.0, true, "Close book"],
		# The left half every 30 degrees, the music in the leftmost place as in the other menus.
		[LIBRARY, "media_library", -150.0, true, "Library"],
		# Not the framing corners of recentre elsewhere: beside the music player's expand button they read alike.
		[RECENTER, "book_here", 150.0, true, "Bring the book here"],
		[MARK, "bookmark" if reader.mark_here() >= 0 else "bookmark_add", 120.0, ready,
			"Remove bookmark" if reader.mark_here() >= 0 else "Add bookmark"],
		# Beside the library, low on the left, as Scene sits at the foot of the library.
		[SCENE, "panorama", -120.0, true, "Scene"]]
	for rune in runes:
		var angle := deg_to_rad(float(rune[2]))
		var lit: bool = (rune[0] == MARK and reader.mark_here() >= 0) or (rune[0] == AUTO and reader.auto) or (rune[0] == READ and reader.narration.on) 			or (rune[0] == FAVORITE and liked.get("selected", false))
		_round(int(rune[0]), str(rune[1]), Vector2(cos(angle), sin(angle)) * RADIUS, 0.115, bool(rune[3]), lit, I18n.t(str(rune[4])))
		_buttons.back()["tip_below"] = sin(angle) < 0.1
	# After a leap, the way back sits under the position it returns from.
	if not return_at.is_empty() and ready and reader.locate(return_at) >= 0:
		_round(RETURN, "undo", Vector2(0, -0.17), 0.1, true, false, I18n.t("Back to where I was"))
		_buttons.back()["tip_below"] = true
	# Pointed at, it opens leftwards into a small player; its button opens the full one.
	if not music_quick: music_quick = preload("res://scripts/music_quick_controls.gd").new(self, _toggle_music)
	music_quick.draw(MUSIC, Vector2(-RADIUS, 0.0), audio_state.call() if audio_state.is_valid() else {}, 0.115)

## Chapter, page and progress in the middle of the ring; while the wand runs along the rim, the
## chapter and page it would leap to.
func _show_position() -> void:
	if _lines.size() < 4 or not is_instance_valid(_lines[0]): return
	var ready: bool = reader.count > 0
	if is_instance_valid(_arc): _arc.material_override.set_shader_parameter("aim", _scrub if ready else -1.0)
	if not ready:
		_lines[0].text = ""; _lines[1].text = _fit_title(reader.status_text(), "", 0.40, 20); _lines[2].text = ""; _lines[3].text = _clock()
		return
	var index: int = _rim_page(_scrub) if _scrub >= 0.0 else reader.first_page()
	_lines[0].text = _fit_title(reader.chapter_name(index), "", 0.40, 20)
	_lines[1].text = "%d / %s" % [index + 1, "…" if reader.partial() else str(reader.count)]
	var spent: String = reader.reading_time()
	_lines[2].text = "" if reader.partial() else I18n.t("Read %d%%") % roundi(100.0 * index / maxf(reader.count - 1, 1.0))
	# How long this book has been read, beside how far.
	if not spent.is_empty() and _scrub < 0.0: _lines[2].text = spent if _lines[2].text.is_empty() else _lines[2].text + " · " + spent
	_lines[3].text = _clock()
	_lines[1].modulate = ACCENT if _scrub >= 0.0 else UiTheme.color("label")
	_lines[2].modulate = ACCENT if _scrub < 0.0 else MUTED
	composition_changed.emit()

## The time, and the headset's battery when the platform reports it: a reader loses track of both.
func _clock() -> String:
	var now := Time.get_time_dict_from_system()
	var text := "%02d:%02d" % [int(now.hour), int(now.minute)]
	var platform: Object = reader.platform
	if is_instance_valid(platform) and platform.has_method("device_status"):
		var status: Variant = JSON.parse_string(str(platform.device_status()))
		if status is Dictionary and int(status.get("level", -1)) >= 0:
			text += "   " + I18n.t("Battery %d%%") % int(status.level) + ("+" if status.get("charging", false) else "")
	return text

## The reading settings in place of the ring, a page per kind: how the page looks, the type, the
## book itself, the ways of turning pages, and turning by themselves.
func _draw_settings() -> void:
	# Just tall enough for four rows under the tabs.
	_set_backdrop(Vector2(1.16, 0.84), Vector2(0, 0.10)); _backdrop.visible = true
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.028)
	_backdrop.material_override.set_shader_parameter("solid", true)
	_glyph(BACK, "back", Vector2(-0.51, 0.455), 0.075, true, I18n.t("Back"))
	_row_step = 0.13 if section in ["look", "book"] else ROW_STEP
	var fixed: bool = reader.info.get("fixed", false)
	for i in SECTIONS.size():
		var item: Array = SECTIONS[i]
		var centre := Vector2(-0.22 + i * 0.115, 0.455)
		var chosen: bool = section == item[0]
		_round(SECTION_BASE + i, str(item[1]), centre, 0.085, not (fixed and item[0] in ["type", "font", "read"]), chosen, I18n.t(str(item[2])))
		if str(item[1]).is_empty():
			var letters := _label("Aa" if item[0] == "type" else "文", Vector3(0, 0, 0.004), 18, _buttons.back().node)
			letters.modulate = UiTheme.color("primary_ink") if chosen else UiTheme.color("text")
	match section:
		"look": _draw_look()
		"type": _draw_type()
		"book": _draw_book()
		"turn": _draw_turns()
		"read": _draw_read()
		"font": _draw_fonts()
		"auto": _draw_auto()

const ROW_TOP := 0.29
const ROW_STEP := 0.165
const CELL := 0.085

## The looks page holds five rows; the others four.
var _row_step := ROW_STEP

func _row_y(row: int) -> float: return ROW_TOP - row * _row_step

func _cell(row: int, index: int) -> Vector2: return Vector2(-0.2 + index * 0.1, _row_y(row))

func _row_label(text: String, row: int) -> void:
	var words := _label(_fit_title(I18n.t(text), "", 0.3, 20), Vector3(-0.53, _row_y(row), 0.004), 20)
	words.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	words.modulate = MUTED

## A round cell in a row of choices; the chosen one is lit.
func _choice(target: int, text: String, centre: Vector2, chosen: bool, enabled: bool = true, icon: String = "", tip: String = "") -> void:
	_round(target, icon, centre, CELL, enabled, chosen, tip)
	if text.is_empty(): return
	var words := _label(text, Vector3(0, 0, 0.004), 15, _buttons.back().node)
	words.modulate = UiTheme.color("primary_ink") if chosen else UiTheme.color("text") if enabled else MUTED

## A cell painted in the colour it would give the page, with a ring of light round the chosen one.
func _swatch(target: int, colour: Color, ink: Color, centre: Vector2, chosen: bool, glyph: String = "文") -> void:
	if chosen:
		# Above the opaque panel's priority; the swatch itself is drawn over it.
		var halo := _quad(Vector2.ONE * (CELL + 0.022), Vector3(centre.x, centre.y, 0.0015), ACCENT, 11)
		halo.material_override.set_shader_parameter("corner_radius", (CELL + 0.022) * 0.5)
		add_child(halo); _decorations.append(halo)
	_round(target, "", centre, CELL, true)
	var button: Dictionary = _buttons.back()
	colour.a = 1.0
	button.base_color = colour; button.hover_color = colour.lightened(0.18)
	button.node.material_override.set_shader_parameter("surface_color", colour)
	if not glyph.is_empty():
		var words := _label(glyph, Vector3(0, 0, 0.004), 18, button.node)
		words.modulate = ink

func _draw_look() -> void:
	_row_label("Day", 0)
	for i in reader.DAY_PAPERS.size():
		var index: int = reader.DAY_PAPERS[i]
		_swatch(PAPER_BASE + index, Color(str(reader.PAPERS[index].paper)), Color(str(reader.PAPERS[index].ink)), _cell(0, i), index == reader.paper)
	_row_label("Night", 1)
	for i in reader.NIGHT_PAPERS.size():
		var index: int = reader.NIGHT_PAPERS[i]
		_swatch(PAPER_BASE + index, Color(str(reader.PAPERS[index].paper)), Color(str(reader.PAPERS[index].ink)), _cell(1, i), index == reader.paper)
	var paper := Color(str(reader.PAPERS[reader.paper].paper))
	var ink := Color(str(reader.PAPERS[reader.paper].ink))
	# A picture of the reader's own under the words: on or off, and another one from the library.
	_row_label("Paper picture", 2)
	var printed: bool = reader.info.get("fixed", false)
	_choice(PICTURE_SWITCH, "", _cell(2, 0), reader.picture, not printed, "image",
		I18n.t("Plain paper" if reader.picture else "Paper picture"))
	_choice(PICTURE_CHOOSE, "", _cell(2, 1), false, not printed and not reader.pictures.busy, "hourglass" if reader.pictures.busy else "folder",
		I18n.t("Choose a picture"))
	_row_label("Brightness", 3)
	for i in reader.LIGHTS.size():
		var shade: Color = reader.tint(i, reader.warmth)
		_swatch(LIGHT_BASE + i, paper * shade, ink * shade, _cell(3, i), i == reader.light, "")
	_row_label("Warmth", 4)
	for i in reader.WARMTHS.size():
		var shade: Color = reader.tint(reader.light, i)
		_swatch(WARM_BASE + i, paper * shade, ink * shade, _cell(4, i), i == reader.warmth, "")

func _draw_type() -> void:
	_row_label("Text size", 0)
	var count: int = reader.COLUMNS.size()
	for i in count:
		var level := count - 1 - i # largest type is font 0
		_choice(SIZE_BASE + level, "", _cell(0, i), level == reader.font)
		var letter := _label(A_LETTER, Vector3(0, 0, 0.004), 11 + i * 3, _buttons.back().node)
		letter.modulate = UiTheme.color("primary_ink") if level == reader.font else UiTheme.color("text")
	_row_label("Line spacing", 1)
	for i in reader.SPACINGS.size():
		_choice(SPACING_BASE + i, str(reader.SPACINGS[i]), _cell(1, i), i == reader.spacing)
	_row_label("Paragraph spacing", 2)
	for i in reader.PARAGRAPHS.size():
		_choice(PARAGRAPH_BASE + i, str(reader.PARAGRAPHS[i]), _cell(2, i), i == reader.paragraph)
	_row_label("Margins", 3)
	for i in reader.MEASURES.size():
		_choice(MEASURE_BASE + i, str(i + 1), _cell(3, i), i == reader.measure)

func _draw_book() -> void:
	_row_label("Page layout", 0)
	_choice(ONE_PAGE, "", _cell(0, 0), reader.single, true, "single_page", I18n.t("One page"))
	_choice(TWO_PAGES, "", _cell(0, 1), not reader.single, true, "magazine", I18n.t("Two-page spread"))
	_row_label("Book size", 1)
	for i in reader.SIZES.size():
		_choice(BOOK_SIZE_BASE + i, str(i + 1), _cell(1, i), i == reader.size_step)
	_row_label("Distance", 2)
	for i in reader.REACHES.size():
		_choice(REACH_BASE + i, str(i + 1), _cell(2, i), i == reader.reach_step)
	# Bringing the book here is on the ring; this row says how a page goes over.
	_row_label("Page turn animation", 3)
	for i in TURN_STYLES.size():
		_choice(STYLE_BASE + i, "", _cell(3, i), i == reader.turn_style, true, str(TURN_STYLES[i][0]), I18n.t(str(TURN_STYLES[i][1])))
	# In the Wizard's Attic this is the attic's own wand: the scene setting wins over the book's.
	_row_label("Wand", 4)
	for i in reader.Wand.STYLES.size():
		var style: String = reader.Wand.STYLES[i]
		_choice(WAND_BASE + i, "", _cell(4, i), style == reader.shown_wand(), true, "", I18n.t(str(reader.Wand.NAMES[style])))
		var picture := _icon("info", Vector3(0, 0, 0.004), CELL * 0.82, Color.WHITE, _buttons.back().node)
		picture.material_override.albedo_texture = reader.Wand.picture(style)

const TURN_ROWS := [["swish", "bolt", "Swish the wand"], ["drag", "single_page", "Pull a page with the trigger"],
	["buttons", "gamepad", "A / X buttons"], ["stick", "forward", "Thumbstick"], ["palm", "hand_unlocked", "Wave a hand across the book"]]

const TURN_STYLES := [["turn_curl", "Page curl"], ["turn_low", "Low page turn"], ["turn_instant", "No animation"]]

## Each way of turning pages is a switch; at least one stays on. Under them, the sound of the paper.
func _draw_turns() -> void:
	for i in TURN_ROWS.size() + 1:
		var sound := i == TURN_ROWS.size()
		var item: Array = ["", "sound" if reader.page_sound else "mute", "Page turn sound"] if sound else TURN_ROWS[i]
		var on: bool = reader.page_sound if sound else reader.turns.get(item[0], false)
		var y := ROW_TOP + 0.01 - i * 0.113
		_button(SOUND_SWITCH if sound else TURN_BASE + i, "", Vector2(0.0, y), Vector2(1.04, 0.1), true)
		var node: Node3D = _buttons.back().node
		var ink := UiTheme.color("text") if on else MUTED
		_icon(str(item[1]), Vector3(-0.46, 0, 0.004), 0.05, ink, node)
		var words := _label(_fit_title(I18n.t(str(item[2])), "", 0.7, 20), Vector3(-0.4, 0, 0.004), 20, node)
		words.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; words.modulate = ink
		_icon("check" if on else "circle", Vector3(0.46, 0, 0.004), 0.05, ACCENT if on else MUTED, node)

## Reading aloud: on or off with a short audition, the voice for the book's language (a preset or one
## of the reader's own cloned voices) and how fast it reads.
func _draw_read() -> void:
	var narration: RefCounted = reader.narration
	var can: bool = reader.count > 0 and narration.supported()
	var reading: bool = narration.on and not narration.audition
	_audition_drawn = narration.audition
	_row_label("Read aloud", 0)
	_choice(READ_SWITCH, "", _cell(0, 0), reading, can, "stop" if reading else "voice",
		I18n.t("Stop reading aloud" if reading else "Read aloud"))
	# Reading aloud already speaks in a newly chosen voice; the audition is for choosing before.
	_choice(PREVIEW, "", _cell(0, 1), narration.audition, can and not reading, "stop" if narration.audition else "play",
		I18n.t("Stop preview" if narration.audition else "Preview voice"))
	_row_label("Voice", 1)
	var voices: Array = Narration.VOICES[narration.language()]
	for i in voices.size():
		var info: Array = Narration.VOICE_INFO.get(voices[i], ["Female", i + 1])
		var chosen: bool = voices[i] == narration.voice()
		_button(VOICE_BASE + i, "", Vector2(-0.16 + i * 0.15, _row_y(1)), Vector2(0.14, 0.085), true, "", chosen)
		var words := _label(I18n.t(str(info[0])) + str(int(info[1])), Vector3(0, 0, 0.004), 16, _buttons.back().node)
		words.modulate = UiTheme.color("primary_ink") if chosen else UiTheme.color("text")
	var cloned: Array = narration.cloned()
	_cloned_ids = cloned.map(func(item): return str(item.id))
	var row := 2
	if not cloned.is_empty():
		_row_label("My cloned voices", row)
		for i in mini(cloned.size(), CLONES):
			var chosen: bool = str(cloned[i].id) == narration.voice()
			_button(CLONE_BASE + i, "", Vector2(-0.16 + i * 0.15, _row_y(row)), Vector2(0.14, 0.085), true, "", chosen)
			var words := _label(_fit_title(str(cloned[i].get("name", "")), "", 0.125, 15), Vector3(0, 0, 0.004), 15, _buttons.back().node)
			words.modulate = UiTheme.color("primary_ink") if chosen else UiTheme.color("text")
		row += 1
	_row_label("Reading speed", row)
	for i in narration.SPEEDS.size():
		_choice(SPEED_BASE + i, str(narration.SPEEDS[i]), _cell(row, i), i == narration.speed)

## The fonts for the open book's language: the system's, then free ones fetched when first chosen.
func _draw_fonts() -> void:
	var fonts: Node = reader.fonts
	var lang: String = reader.variant()
	var rows: Array = [""] + fonts.fonts_for(lang).map(func(item): return str(item.slug))
	var chosen: String = reader.font_choice()
	for i in rows.size():
		var id: String = rows[i]
		var y := ROW_TOP + 0.01 - i * 0.17
		var state: String = "installed" if id.is_empty() else fonts.state_of(id)
		var picked := id == chosen
		_button(FONT_BASE + i, "", Vector2(-0.04 if state == "installed" and not id.is_empty() else 0.0, y),
			Vector2(0.96 if state == "installed" and not id.is_empty() else 1.04, 0.15), not lang.is_empty())
		var node: Node3D = _buttons.back().node
		var name: String = I18n.t("System font") if id.is_empty() else fonts.display_name(id, I18n.language)
		var words := _label(_fit_title(name, "", 0.5, 15), Vector3(-0.47, 0.045, 0.004), 15, node)
		words.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; words.modulate = MUTED
		# What the font looks like, before it is fetched: a line set in it, shipped with the app.
		_font_sample(id, lang, node)
		var note := ""
		match state:
			"installed": note = ""
			"loading": note = "%d%%" % roundi(fonts.progress(id) * 100.0)
			"queued": note = I18n.t("Waiting")
			"failed": note = I18n.t("Download failed")
			"withdrawn": note = I18n.t("Unavailable")
			_: note = "%.1f MB" % (float(fonts.file_of(id).get("bytes", 0)) / 1048576.0)
		var side := _label(note, Vector3(0.33 if state == "installed" and not id.is_empty() else 0.37, 0, 0.004), 16, node)
		side.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; side.modulate = MUTED
		var mark := "check" if picked and state == "installed" else ("download" if state in ["", "failed"] else ("hourglass" if state in ["loading", "queued"] else "circle"))
		if not (state == "installed" and not picked):
			_icon(mark, Vector3(0.42 if not (state == "installed" and not id.is_empty()) else 0.38, 0, 0.004), 0.045, ACCENT if picked else MUTED, node)
		if state == "installed" and not id.is_empty():
			_glyph(FONT_REMOVE_BASE + i, "trash", Vector2(0.52, y), 0.06, true, I18n.t("Delete font"))
	if lang.is_empty():
		_label(I18n.t("Open a book to choose its font"), Vector3(0, -0.3, 0.004), 16).modulate = MUTED

## A sample line in the font: its shipped picture, or for the system's font the same words as text.
func _font_sample(id: String, lang: String, parent: Node3D) -> void:
	var picture: Texture2D = reader.fonts.preview(id) if not id.is_empty() else null
	if picture == null:
		var line := _label(str(reader.fonts.SAMPLES.get(lang, reader.fonts.SAMPLES.en)), Vector3(-0.47, -0.02, 0.004), 30, parent)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; line.modulate = UiTheme.color("text")
		return
	var height := 0.06
	var width := height * float(picture.get_width()) / float(picture.get_height())
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new(); mesh.size = Vector2(width, height); quad.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = picture; material.albedo_color = UiTheme.color("text")
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material.no_depth_test = true; material.render_priority = 12
	quad.material_override = material
	quad.position = Vector3(-0.47 + width * 0.5, -0.02, 0.004)
	parent.add_child(quad)

func _draw_auto() -> void:
	_row_label("Auto page turn", 0)
	_choice(AUTO_SWITCH, "", _cell(0, 0), reader.auto, reader.count > 0, "pause" if reader.auto else "play",
		I18n.t("Stop turning pages" if reader.auto else "Turn pages by themselves"))
	_row_label("Seconds per page", 1)
	for i in reader.AUTO_SECONDS.size():
		_choice(AUTO_BASE + i, str(reader.AUTO_SECONDS[i]), _cell(1, i), i == reader.auto_step)

## The settings' own controls; false when [target] is not one of them.
func _setting(target: int) -> bool:
	if target >= SECTION_BASE and target < SECTION_BASE + SECTIONS.size():
		section = str(SECTIONS[target - SECTION_BASE][0])
	elif target >= WARM_BASE and target < WARM_BASE + reader.WARMTHS.size(): reader.set_warmth(target - WARM_BASE)
	elif target >= SPACING_BASE and target < SPACING_BASE + reader.SPACINGS.size(): reader.set_spacing(target - SPACING_BASE)
	elif target >= PARAGRAPH_BASE and target < PARAGRAPH_BASE + reader.PARAGRAPHS.size(): reader.set_paragraph(target - PARAGRAPH_BASE)
	elif target >= MEASURE_BASE and target < MEASURE_BASE + reader.MEASURES.size(): reader.set_measure(target - MEASURE_BASE)
	elif target >= BOOK_SIZE_BASE and target < BOOK_SIZE_BASE + reader.SIZES.size(): reader.set_size_step(target - BOOK_SIZE_BASE)
	elif target >= REACH_BASE and target < REACH_BASE + reader.REACHES.size(): reader.set_reach_step(target - REACH_BASE)
	elif target >= AUTO_BASE and target < AUTO_BASE + reader.AUTO_SECONDS.size(): reader.set_auto_step(target - AUTO_BASE)
	elif target >= TURN_BASE and target < TURN_BASE + TURN_ROWS.size():
		var way := str(TURN_ROWS[target - TURN_BASE][0])
		reader.set_turn(way, not reader.turns.get(way, false))
	elif target == AUTO_SWITCH: reader.set_auto(not reader.auto)
	elif target == SOUND_SWITCH: reader.set_page_sound(not reader.page_sound)
	elif target == PICTURE_SWITCH: reader.set_picture(not reader.picture)
	elif target == PICTURE_CHOOSE: reader.picture_wanted.emit()
	elif target >= STYLE_BASE and target < STYLE_BASE + TURN_STYLES.size(): reader.set_turn_style(target - STYLE_BASE)
	elif target >= WAND_BASE and target < WAND_BASE + reader.Wand.STYLES.size(): reader.set_wand(reader.Wand.STYLES[target - WAND_BASE])
	elif target >= FONT_REMOVE_BASE and target < FONT_REMOVE_BASE + 12:
		var ids: Array = [""] + reader.fonts.fonts_for(reader.variant()).map(func(item): return str(item.slug))
		if target - FONT_REMOVE_BASE < ids.size(): reader.remove_font(str(ids[target - FONT_REMOVE_BASE]))
	elif target >= FONT_BASE and target < FONT_BASE + 12:
		var ids: Array = [""] + reader.fonts.fonts_for(reader.variant()).map(func(item): return str(item.slug))
		if target - FONT_BASE < ids.size(): reader.set_font_choice(str(ids[target - FONT_BASE]))
	elif target == READ_SWITCH: reader.set_reading_aloud(not reader.narration.on)
	elif target >= VOICE_BASE and target < VOICE_BASE + 8:
		var voices: Array = Narration.VOICES[reader.narration.language()]
		if target - VOICE_BASE < voices.size(): reader.narration.set_voice(str(voices[target - VOICE_BASE])); reader.save_reading()
	elif target >= SPEED_BASE and target < SPEED_BASE + 8: reader.narration.set_speed(target - SPEED_BASE); reader.save_reading()
	elif target == PREVIEW: reader.narration.preview()
	elif target >= CLONE_BASE and target < CLONE_BASE + CLONES:
		if target - CLONE_BASE < _cloned_ids.size(): reader.narration.set_voice(str(_cloned_ids[target - CLONE_BASE])); reader.save_reading()
	else: return false
	refresh()
	return true

## The rows the open list shows: {"title", "side" (muted, on the right), "page" (-1: not laid out yet),
## "depth", "remove" (a bookmark's index)}.
func _rows() -> Array:
	var rows := []
	match mode:
		"contents":
			for row in reader.contents:
				rows.append({"title": str(row.get("title", "")), "page": int(row.get("page", 0)), "depth": int(row.get("depth", 0))})
		"marks":
			for index in reader.marks.size():
				var mark: Dictionary = reader.marks[index]
				var at: int = reader.locate(str(mark.at))
				var words := str(mark.get("text", ""))
				rows.append({"title": words if not words.is_empty() else I18n.t("Page %d") % (at + 1), "side": str(mark.get("chapter", "")),
					"page": at, "remove": index})
		"search":
			var wanted := query.strip_edges().to_lower()
			if not wanted.is_empty():
				for row in reader.contents:
					if str(row.get("title", "")).to_lower().contains(wanted):
						rows.append({"title": str(row.title), "side": I18n.t("Chapter"), "page": int(row.get("page", 0))})
			for hit in _hits:
				var text := str(hit.get("text", ""))
				var marked: Array = hit.get("mark", [])
				# The match stands in brackets: a line of 3D text has one colour.
				if marked.size() == 2 and int(marked[0]) >= 0 and int(marked[0]) + int(marked[1]) <= text.length():
					text = text.left(int(marked[0])) + "【" + text.substr(int(marked[0]), int(marked[1])) + "】" + text.substr(int(marked[0]) + int(marked[1]))
				var at: int = reader.locate(str(hit.get("at", "")))
				rows.append({"title": text, "side": reader.section_name(at) if at >= 0 else str(hit.get("chapter", "")), "page": at})
	return rows

## The search list gives its first row to the query.
func _visible_rows() -> int: return ROWS - 1 if mode == "search" else ROWS

func _draw_list() -> void:
	_set_backdrop(Vector2(1.16, 1.04)); _backdrop.visible = true
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.028)
	# Opaque: the sharp page layer beneath would show its words through a translucent panel.
	_backdrop.material_override.set_shader_parameter("solid", true)
	_glyph(BACK, "back", Vector2(-0.51, 0.455), 0.075, true, I18n.t("Back"))
	var tabs := [[TAB_CONTENTS, "Contents", "contents", not reader.contents.is_empty()], [TAB_MARKS, "Bookmarks", "marks", true],
		[TAB_SEARCH, "Search", "search", not reader.info.get("fixed", false)]]
	for i in tabs.size():
		_button(int(tabs[i][0]), I18n.t(str(tabs[i][1])), Vector2(-0.22 + i * 0.22, 0.455), Vector2(0.2, 0.075), bool(tabs[i][3]), "", mode == tabs[i][2])
	var rows := _rows()
	var top := 0.335
	if mode == "search":
		_text_button(QUERY, "", Vector2(-0.03, top), Vector2(1.0, 0.085))
		var field: Node3D = _buttons.back().node
		var shown := query if not query.is_empty() else I18n.t("Search the book")
		var words := _label(_fit_title(shown, "", 0.78, 18), Vector3(-0.47, 0, 0.002), 18, field)
		words.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		words.modulate = UiTheme.color("text") if not query.is_empty() else MUTED
		var state := ""
		if _searching > 0: state = I18n.t("Searching…")
		elif not _searched.is_empty(): state = I18n.t("No matches") if rows.is_empty() else ("%d" % rows.size()) + ("+" if _more else "")
		var tally := _label(state, Vector3(0.47, 0, 0.002), 15, field)
		tally.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; tally.modulate = MUTED
		top -= 0.105
	elif rows.is_empty() and mode == "marks":
		_label(I18n.t("No bookmarks yet"), Vector3(0, 0.1, 0.004), 18).modulate = MUTED
	var current := _current_row() if mode == "contents" else -1
	for i in _visible_rows():
		var index := first + i
		if index >= rows.size(): break
		var row: Dictionary = rows[index]
		var centre := Vector2(-0.03, top - i * 0.105)
		var indent := clampi(int(row.get("depth", 0)), 0, 3) * 0.035
		var removable := row.has("remove")
		_text_button(ROW + index, "", centre - Vector2(0.05 if removable else 0.0, 0.0), Vector2(0.9 if removable else 1.0, 0.095))
		var node: Node3D = _buttons.back().node
		if index == current:
			var marker := _quad(Vector2(1.0, 0.095), Vector3(0, 0, -0.002), TILE, 11)
			marker.material_override.set_shader_parameter("corner_radius", 0.02)
			node.add_child(marker)
		var side := str(row.get("side", ""))
		var half := 0.45 if removable else 0.5
		var width := (0.80 if side.is_empty() else 0.56) - indent - (0.1 if removable else 0.0)
		var name := _label(_fit_title(str(row.title), "", width, 18), Vector3(-half + 0.03 + indent, 0, 0.002), 18, node)
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name.modulate = ACCENT if index == current else UiTheme.color("text")
		if not side.is_empty():
			var chapter := _label(_fit_title(side, "", 0.2, 14), Vector3(half - 0.14, 0, 0.002), 14, node)
			chapter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; chapter.modulate = MUTED
		# A chapter beyond the pages laid out so far has no page number yet.
		var at := int(row.get("page", 0))
		var number := _label(str(at + 1) if at >= 0 else "…", Vector3(half - 0.03, 0, 0.002), 15, node)
		number.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		number.modulate = MUTED
		_buttons.back().hover_labels = [name] as Array[Label3D]
		if removable: _glyph(REMOVE + int(row.remove), "close", Vector2(0.48, centre.y), 0.06, true, I18n.t("Remove bookmark"))
	if first > 0: _glyph(UP, "chevron_up", Vector2(0.53, 0.30), 0.07)
	if first + _visible_rows() < rows.size(): _glyph(DOWN, "chevron_down", Vector2(0.53, -0.40), 0.07)

## Types the search; it runs once the query is entered.
func _edit_query() -> void:
	editor.begin("book_search", query, 64, func(value: String) -> void: query = value; refresh(),
		func(value: String) -> void: query = TextInput.clean(value, 64); editor.cancel(); _run_search(),
		Callable(), func() -> bool: return visible and mode == "search")

func _run_search() -> void:
	_hits = []; _more = false; first = 0
	_searched = query.strip_edges()
	_searching = reader.search(_searched) if not _searched.is_empty() else 0
	refresh()

func _on_found(token: int, result: Dictionary) -> void:
	if token != _searching: return
	_searching = 0
	_hits = result.get("hits", []); _more = bool(result.get("more", false))
	if visible and mode == "search": refresh()

func _activate(target: int) -> void:
	touch()
	if _setting(target): return
	if target >= REMOVE:
		reader.remove_mark(target - REMOVE)
		first = clampi(first, 0, maxi(0, _rows().size() - _visible_rows())); refresh(); return
	if target >= ROW:
		var rows := _rows()
		var index := target - ROW
		if index < rows.size():
			var at := int(rows[index].page)
			if at < 0: reader.tell_partial(); return
			leap(at)
			dismiss()
		return
	if target >= LIGHT_BASE and target < LIGHT_BASE + reader.LIGHTS.size():
		reader.set_light(target - LIGHT_BASE); refresh(); return
	if target >= PAPER_BASE and target < PAPER_BASE + reader.PAPERS.size():
		reader.set_paper(target - PAPER_BASE); refresh(); return
	if target >= SIZE_BASE and target < SIZE_BASE + reader.COLUMNS.size():
		reader.set_font(target - SIZE_BASE); refresh(); return
	match target:
		CONTENTS: open("contents")
		TAB_CONTENTS: open("contents")
		TAB_MARKS: open("marks")
		TAB_SEARCH:
			open("search")
			if query.is_empty(): _edit_query()
		QUERY: _edit_query()
		MARK: reader.toggle_mark(); refresh()
		BACK: open("bar")
		UP: _move(-ROWS + 1)
		DOWN: _move(ROWS - 1)
		SETTINGS: open("settings")
		NIGHT: reader.set_night(not reader.night()); refresh()
		READ:
			reader.set_reading_aloud(not reader.narration.on)
			# Started from the ring, the ring makes way for the page being read.
			if reader.narration.on: dismiss()
			else: refresh()
		AUTO:
			reader.set_auto(not reader.auto)
			# Started from the ring, the pages begin turning as soon as the ring is put away.
			if reader.auto: dismiss()
			else: refresh()
		ONE_PAGE: reader.set_single(true); refresh()
		TWO_PAGES: reader.set_single(false); refresh()
		RECENTER: reader.recenter()
		LIBRARY: dismiss(); reader.library_requested.emit()
		MUSIC: music_requested.emit()
		FAVORITE: favorite_requested.emit(); refresh()
		SCENE: dismiss(); scene_requested.emit()
		EXIT: reader.close_book()
		RETURN:
			var back_to: int = reader.locate(return_at)
			return_at = reader.place_of(reader.first_page())
			if back_to >= 0: reader.leap(back_to)
			refresh()
