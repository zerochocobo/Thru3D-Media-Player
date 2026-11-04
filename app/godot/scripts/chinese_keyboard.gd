extends "res://scripts/ray_menu.gd"
const Pinyin := preload("res://scripts/chinese_pinyin.gd")
const Move := preload("res://scripts/interface_move.gd")
const WINDOW_SCALE := 0.5
const MOVE := 20
const KEY := 100
const CANDIDATE := 200
const KEY_FONT_SIZE := 20
const KEY_ICON_SIZE := 0.036
const LETTERS := ["1234567890", "qwertyuiop", "asdfghjkl'", "zxcvbnm,."]
const SYMBOLS := ["1234567890", "@#$%&*()[]", "+-=/:;!?_\"", "\\<>~`{}|."]
var ime := Pinyin.new()
var owner_id := ""
var dispatch: Callable
var alive: Callable
var english := false
var shift := false
var symbols := false
var preview: Callable
var _repeat_hand := ""
var _repeat_at := 0
var _lexicon_ready := false
var title_move := Move.new()
var head_provider: Callable
var placement: Variant = null

func _ready() -> void:
	super._ready()
	scale = Vector3.ONE * WINDOW_SCALE

func head() -> Variant:
	var value: Variant = head_provider.call() if head_provider.is_valid() else null
	return value if value is Transform3D and value.is_finite() else null

func _remember_placement() -> void:
	var viewer: Variant = head()
	if viewer is Transform3D: placement = Move.menu_head(viewer).affine_inverse() * global_transform

func _end_move() -> void:
	if not title_move.capture.is_empty() and title_move.capture.moved: _remember_placement()
	title_move.cancel()

func present(id: String, action: Callable, valid: Callable, text: Callable, latin: bool) -> void:
	close(false)
	owner_id = id; dispatch = action; alive = valid; preview = text
	english = latin; shift = false; symbols = false
	visible = true; refresh()

func close(notify: bool = true) -> void:
	var callback := dispatch
	var was_open := visible and not owner_id.is_empty()
	owner_id = ""; dispatch = Callable(); alive = Callable(); preview = Callable()
	ime.clear(); _repeat_hand = ""; _end_move(); super.dismiss()
	if notify and was_open and callback.is_valid(): callback.call("close", "")

func dismiss() -> void: close()

func navigate_back() -> bool:
	if not ime.composing.is_empty(): ime.clear(); refresh()
	else: close()
	return true

func _process(_delta: float) -> void:
	Pinyin.poll_lexicon()
	if not _lexicon_ready and (not Pinyin.keys.is_empty() or Pinyin.failed):
		_lexicon_ready = true
		if visible: refresh()
	if not visible: return
	if not alive.is_valid() or not alive.call(): close(false); return
	if not _repeat_hand.is_empty() and Time.get_ticks_msec() >= _repeat_at:
		_repeat_at = Time.get_ticks_msec() + 95
		_activate(4)

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if has_pointer_capture(): return true
	var hit := ray_hit(origin, direction) if tracked else {}
	if int(hit.get("target", NONE)) == MOVE:
		title_move.begin(hand, "trigger", Move.ray_pose(origin, direction),
			[{"node": self, "kind": "detail", "key": "keyboard", "pose": global_transform,
			"upright_facing": true, "face_center": Vector3.ZERO}], to_global(hit.point), head())
		return true
	if int(hit.get("target", NONE)) == 4:
		_repeat_hand = hand; _repeat_at = Time.get_ticks_msec() + 500
	return super.press_pointer(hand, origin, direction, tracked)

func release_pointer(hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> bool:
	if hand == _repeat_hand: _repeat_hand = ""
	if title_move.capture.get("hand", "") == hand: _end_move()
	return true

func cancel_pointer(hand: String) -> void:
	if hand == _repeat_hand: _repeat_hand = ""
	if title_move.capture.get("hand", "") == hand: _end_move()
	super.cancel_pointer(hand)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if title_move.capture.get("hand", "") == hand:
		if not tracked or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.00001:
			_end_move(); super.update_pointer(hand, origin, direction, false); return
		if title_move.update(Move.ray_pose(origin, direction), head(), null):
			_remember_placement()
		if not title_move.capture.is_empty():
			update_move_pointer(hand, origin, title_move.capture.anchor, true)
		return
	if hand == _repeat_hand and (not tracked or int(ray_hit(origin, direction).get("target", NONE)) != 4): _repeat_hand = ""
	super.update_pointer(hand, origin, direction, tracked)

func _exit_tree() -> void:
	if Pinyin.loader != null: Pinyin.load_lexicon()
	close(false)

func has_pointer_capture() -> bool: return not _repeat_hand.is_empty() or not title_move.capture.is_empty()

func composition_root() -> Node3D: return self

func _place_device_status(_centre: Vector2) -> void:
	pass # Keyboard is a modal editor, without scene/follow controls beneath it.

func refresh() -> void:
	_clear_layout()
	_set_backdrop(Vector2(1.28, 0.78))
	_block_rays(_backdrop, Vector2(1.28, 0.78))
	_button(MOVE, "", Vector2(-0.04, 0.333), Vector2(1.07, 0.102))
	var handle: Dictionary = _buttons.back()
	handle.base_color = Color(TILE, 0)
	handle.node.material_override.set_shader_parameter("surface_color", handle.base_color)
	var mark := _quad(Vector2(0.16, 0.009), Vector3(0.04, 0.034, 0.006), MUTED, 12)
	handle.node.add_child(mark)
	var value := str(preview.call()) if preview.is_valid() else ""
	_label(_fit_title(value, "", 1.07, KEY_FONT_SIZE), Vector3(-0.02, 0.325, 0.012), KEY_FONT_SIZE)
	_icon_key(9, "keyboard_close", Vector2(0.575, 0.325), Vector2(0.09, 0.08))
	_label(ime.composing, Vector3(0, 0.253, 0.012), KEY_FONT_SIZE).modulate = ACCENT
	if not english and Pinyin.keys.is_empty():
		_label("词库加载失败" if Pinyin.failed else "…", Vector3(0, 0.18, 0.012), KEY_FONT_SIZE)
	_icon_key(10, "keyboard_previous", Vector2(-0.58, 0.18), Vector2(0.075, 0.08), ime.page > 0)
	var items := ime.page_items()
	for index in items.size():
		_button(CANDIDATE + index, _fit_title(str(items[index].text), "", 0.154, KEY_FONT_SIZE), Vector2(-0.455 + index * 0.182, 0.18), Vector2(0.172, 0.075))
	_icon_key(11, "keyboard_next", Vector2(0.58, 0.18), Vector2(0.075, 0.08), (ime.page + 1) * Pinyin.PAGE_SIZE < ime.candidates.size())
	var rows: Array = SYMBOLS if symbols else LETTERS
	for row in rows.size():
		var letters: String = rows[row]
		for column in letters.length():
			var letter := letters[column].to_upper() if shift else letters[column]
			_button(KEY + row * 10 + column, letter, Vector2((column - (letters.length() - 1) / 2.0) * 0.121, 0.077 - row * 0.085), Vector2(0.111, 0.075))
	for item in [[1, "EN" if english else "中", -0.555, 0.11], [2, "⇧", -0.435, 0.11],
		[3, "ABC" if symbols else "123", -0.315, 0.11], [12, "◀", -0.195, 0.10],
		[5, "空格", 0.005, 0.28], [13, "▶", 0.205, 0.10], [4, "⌫", 0.33, 0.13], [6, "↵", 0.505, 0.20]]:
		var icons := {2: "keyboard_shift", 4: "keyboard_backspace", 6: "keyboard_enter", 12: "keyboard_previous", 13: "keyboard_next"}
		var target := int(item[0])
		var centre := Vector2(float(item[2]), -0.30)
		var size := Vector2(float(item[3]), 0.085)
		if icons.has(target): _icon_key(target, icons[target], centre, size, true, target == 6 or (target == 2 and shift))
		else: _button(target, str(item[1]), centre, size)
	for button in _buttons:
		for child in button.node.get_children():
			if child is Label3D: set_label_size(child, KEY_FONT_SIZE)
	composition_changed.emit()

func _icon_key(target: int, icon: String, centre: Vector2, size: Vector2, enabled: bool = true, selected: bool = false) -> void:
	_button(target, "", centre, size, enabled, "", selected)
	var button: Dictionary = _buttons.back()
	var color: Color = button.foreground if enabled else MUTED
	_icon(icon, Vector3(0, 0, 0.006), KEY_ICON_SIZE, color, button.node)

func _send(operation: String, value: String = "") -> bool:
	if not alive.is_valid() or not alive.call(): close(false); return false
	return dispatch.is_valid() and bool(dispatch.call(operation, value))

func _pick(index: int) -> void:
	if index < 0 or index >= ime.candidates.size(): return
	if _send("text", str(ime.candidates[index].text)): ime.choose(index)

func type_key(letter: String) -> void:
	if not english and not symbols and (letter.to_lower() >= "a" and letter.to_lower() <= "z" or letter == "'"):
		if Pinyin.keys.is_empty(): return
		ime.type_letter(letter)
	elif not ime.composing.is_empty():
		if letter == " ": _pick(ime.page * Pinyin.PAGE_SIZE)
		elif letter in ["1", "2", "3", "4", "5", "6"]: _pick(ime.page * Pinyin.PAGE_SIZE + int(letter) - 1)
	else: _send("text", letter)
	if visible: refresh()

func _activate(target: int) -> void:
	if target != 4: _repeat_hand = ""
	if target >= CANDIDATE and target < CANDIDATE + Pinyin.PAGE_SIZE:
		_pick(ime.page * Pinyin.PAGE_SIZE + target - CANDIDATE)
	elif target >= KEY and target < KEY + 40:
		var rows: Array = SYMBOLS if symbols else LETTERS
		var row := (target - KEY) / 10
		var column := (target - KEY) % 10
		if column < rows[row].length(): type_key(rows[row][column].to_upper() if shift else rows[row][column])
		return
	else:
		match target:
			1, 3:
				if not ime.composing.is_empty():
					if not _send("text", ime.composing): return
					ime.clear()
				if target == 1: english = not english
				else: symbols = not symbols
			2: shift = not shift
			4:
				if not ime.composing.is_empty(): ime.backspace()
				else: _send("backspace")
			5: type_key(" "); return
			6:
				if not ime.composing.is_empty(): _pick(ime.page * Pinyin.PAGE_SIZE)
				else: _send("enter")
			9: close(); return
			10: ime.page_by(-1)
			11: ime.page_by(1)
			12, 13:
				if ime.composing.is_empty(): _send("left" if target == 12 else "right")
	if visible: refresh()

func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed: return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed: return
	if event.keycode == KEY_ESCAPE: navigate_back()
	elif event.keycode == KEY_BACKSPACE: _activate(4)
	elif event.keycode in [KEY_ENTER, KEY_KP_ENTER]: _activate(6)
	elif event.keycode == KEY_LEFT: _activate(12)
	elif event.keycode == KEY_RIGHT: _activate(13)
	elif event.unicode > 0: type_key(String.chr(event.unicode))
	else: return
	get_viewport().set_input_as_handled()
