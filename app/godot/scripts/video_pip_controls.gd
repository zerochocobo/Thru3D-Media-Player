extends RefCounted
## Only existing windows are numbered; the next free identity is created with +.
const SLOT := 998010
const CLOSE := 998020
const ADD := 998030
const I18n := preload("res://scripts/i18n.gd")
var _menu: WeakRef
var _faces: Array[Dictionary] = []

func _init(menu: Node3D) -> void: _menu = weakref(menu)

static func active_slots(state: Dictionary) -> Array[int]:
	var slots: Array[int] = []
	for slot in [1, 2, 3]:
		if (state.get("pip_slots", []) as Array).has(slot) or (not state.has("pip_slots") and slot <= int(state.get("pip_count", 0))): slots.append(slot)
	return slots

static func next_slot(state: Dictionary) -> int:
	var slots := active_slots(state)
	for slot in [1, 2, 3]:
		if not slots.has(slot): return slot
	return 0

func hovered_slots() -> Array[int]:
	var menu: Node3D = _menu.get_ref()
	var result: Array[int] = []
	if not menu or not menu.visible or not menu._pip_open: return result
	for slot in active_slots(menu._state):
		if menu._hover.values().has(SLOT + slot) or menu._hover.values().has(CLOSE + slot): result.append(slot)
	return result

func update() -> void:
	var menu: Node3D = _menu.get_ref()
	if not menu: return
	var slots := hovered_slots()
	var changed := false
	for face in _faces:
		if not is_instance_valid(face.icon): continue
		var shown := slots.has(int(face.slot))
		if face.icon.visible != shown:
			face.icon.visible = shown; face.number.visible = not shown; changed = true
	if changed: menu.composition_changed.emit()

func draw() -> void:
	var menu: Node3D = _menu.get_ref()
	_faces.clear()
	var slots := active_slots(menu._state)
	var add := slots.size() < 3
	var count := slots.size() + int(add)
	var width := count * 0.105 + 0.025
	var panel: MeshInstance3D = menu._quad(Vector2(width, 0.098), Vector3(-0.28, 0.33, 0.001), menu.PANEL, 10)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, panel.mesh.size)
	for i in count:
		var centre := Vector2(-0.28 + (i - (count - 1) * 0.5) * 0.105, 0.33)
		if i >= slots.size():
			menu._round(ADD, "plus", centre, 0.072, true, false, I18n.t("Add picture in picture window"))
			continue
		var slot := slots[i]
		menu._button(SLOT + slot, str(slot), centre, Vector2.ONE * 0.072)
		var number: Dictionary = menu._buttons.back()
		var caption: Label3D = number.node.get_child(0)
		var icon: MeshInstance3D = menu._icon("close", Vector3(0, 0, 0.004), 0.048, Color.WHITE, number.node)
		icon.visible = false
		menu._tips[SLOT + slot] = I18n.t("Close window %d") % slot
		_faces.append({"slot": slot, "number": caption, "icon": icon})
	update()
