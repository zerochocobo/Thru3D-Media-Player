extends RefCounted
## Presentation-only adapter: existing slider/choice code and numeric ranges stay unchanged.
const Guard := preload("res://scripts/screen_edit_lock.gd")
const TOGGLE := 998100
const SAVE := 998101
const TIP := "Unlock to adjust"
var menu: Node3D
var flash_until := 0

func _init(owner: Node3D) -> void: menu = owner

func row(y: float) -> void:
	var label: Label3D = menu._label(menu.I18n.t("Lock screen"), Vector3(-0.50, y, 0.004), menu.TEXT_BODY)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var locked: bool = menu._state.get("screen_edit_locked", false)
	menu._button(TOGGLE, menu.I18n.t("Locked" if locked else "Unlocked"), Vector2(0.16, y), Vector2(0.646, 0.055))
	menu._icon("lock" if locked else "unlock", Vector3(-0.27, 0, 0.004), 0.026, menu.UiTheme.color("label"), menu._buttons.back().node)
	menu.set_label_size(menu._buttons.back().node.get_child(0), menu.TEXT_BODY)
	menu._buttons.back().base_color = menu.SELECTED if locked else menu.TILE
	menu._tips[TOGGLE] = menu.I18n.t("Unlock screen" if locked else "Lock screen")

func protected_target(target: int) -> bool:
	if target in [menu.SCREEN_SET_DEFAULT, menu.SCREEN_AUTO_DEFAULT, SAVE, menu.SCREEN_CINEMA, menu.SCREEN_CINEMA_OFF, menu.ROTATION_RESET, menu.SPATIAL_FOV]: return true
	if target >= menu.ROTATION_PRESET and target < menu.ROTATION_PRESET + menu.ROTATION_ANGLES.size(): return true
	if target >= menu.SCREEN_PRESET and target < menu.SCREEN_PRESET + menu.ScreenPresets.ITEMS.size(): return true
	if target >= menu.SCREEN_EYE_LEVEL and target < menu.SCREEN_EYE_LEVEL + menu.EYE_LEVELS.size(): return true
	if menu._adjust_rows.has(target): return menu._adjust_rows[target].key in Guard.KEYS
	if menu._adjust_rows.has(target - menu.SLIDER_RESET_BASE): return menu._adjust_rows[target - menu.SLIDER_RESET_BASE].key in Guard.KEYS
	return str(menu.choices.targets.get(target, {}).get("key", "")) in Guard.KEYS

func blocked(target: int, hand: String = "", feedback: bool = true) -> bool:
	if not menu._state.get("screen_edit_locked", false) or not protected_target(target): return false
	if feedback: menu.screen_lock_blocked.emit(hand); flash_until = Time.get_ticks_msec() + 1500
	return true

func apply() -> void:
	if not menu._state.get("screen_edit_locked", false): return
	for button in menu._buttons:
		if int(button.target) == TOGGLE: button.base_color = menu.ACCENT if Time.get_ticks_msec() < flash_until else menu.SELECTED
		if not protected_target(int(button.target)): continue
		button.enabled = false; button["hover_disabled"] = true
		menu._tips[button.target] = menu.I18n.t(TIP)
		for child in button.node.get_children():
			if child is Label3D: child.modulate = menu.UiTheme.color("disabled_ink")
			elif child is MeshInstance3D and child.material_override is StandardMaterial3D: child.material_override.albedo_color = menu.MUTED
	for row in menu._adjust_rows.values():
		if row.key not in Guard.KEYS: continue
		row.label.modulate = menu.UiTheme.color("disabled_ink")
		row.fill.material_override.set_shader_parameter("surface_color", menu.UiTheme.color("disabled"))
		row.knob.material_override.set_shader_parameter("surface_color", menu.MUTED)

func activate(target: int) -> bool:
	if target == TOGGLE:
		menu.setting_requested.emit("screen_edit_locked", not menu._state.get("screen_edit_locked", false)); return true
	if blocked(target): return true
	if target == SAVE:
		menu.adjustment_requested.emit("screen_set_default", true); menu.refresh_values(); return true
	return false
