extends RefCounted
const I18n := preload("res://scripts/i18n.gd")
const TOGGLE := 988201
const ACCEPT := 988202
const REJECT := 988203
const RETURN := 988204
const DISMISS := 988205
const CANCEL_AIRPLAY := 988206

static func action(target: int) -> String:
	return {TOGGLE: "toggle", ACCEPT: "accept", REJECT: "reject", RETURN: "return", DISMISS: "dismiss", CANCEL_AIRPLAY: "airplay_cancel"}.get(target, "")

static func draw_pairing(menu: Node3D, code: String) -> void:
	menu._label("AirPlay", Vector3(0, 0.10, 0.012), 20)
	menu._label(code, Vector3(0, 0.015, 0.012), 42)
	menu._button(CANCEL_AIRPLAY, I18n.t("Cancel"), Vector2(0, -0.10), Vector2(0.30, 0.065))

static func background(menu: Node3D, size: Vector2, y: float) -> void:
	var panel: MeshInstance3D = menu._quad(size, Vector3(0, y, 0.001), menu.PANEL, 10)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, size)

## A fixed footer in the existing navigation bounds; the whole row is one ray target.
static func draw_sidebar_toggle(menu: Node3D, state: Dictionary, parent: Node3D) -> void:
	var receiving: bool = state.get("enabled", false)
	var divider: MeshInstance3D = menu._quad(Vector2(0.34, 0.0015), Vector3(0, -0.41, 0.004), menu.UiTheme.color("divider"), 11)
	parent.add_child(divider); menu._decorations.append(divider)
	menu._button(TOGGLE, menu._fit_title(I18n.t("Receive video"), "", 0.183, menu.TEXT_BODY), Vector2(0, -0.49), Vector2(0.36, 0.09), true, "", false, parent)
	var button: Dictionary = menu._buttons.back()
	button.base_color = Color(menu.TILE, 0.0)
	button.node.material_override.set_shader_parameter("surface_color", button.base_color)
	var label: Label3D = button.node.get_child(0)
	label.position.x = -0.092
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._icon("cast", Vector3(-0.135, 0, 0.004), 0.045, button.foreground, button.node)
	var track: MeshInstance3D = menu._quad(Vector2(0.056, 0.029), Vector3(0.135, 0, 0.004), menu.SELECTED if receiving else menu.MUTED, 12)
	track.material_override.set_shader_parameter("corner_radius", 0.0145)
	button.node.add_child(track)
	var knob: MeshInstance3D = menu._quad(Vector2(0.021, 0.021), Vector3(0.148 if receiving else 0.122, 0, 0.006), menu.ACCENT if receiving else menu.TILE, 13)
	knob.material_override.set_shader_parameter("corner_radius", 0.0105)
	button.node.add_child(knob)
	menu._tips[TOGGLE] = receiver_tooltip(state)

static func receiver_tooltip(state: Dictionary) -> String:
	var receiving: bool = state.get("enabled", false)
	var airplay := str(state.get("airplay_state", "off"))
	var lines := PackedStringArray([
		"DLNA: " + I18n.t("On" if receiving else "Off"),
		"AirPlay: " + I18n.t("On" if receiving and airplay == "ready" else "Off")])
	var tip: String = I18n.t("Cast reception is on.\nChoose %s from your phone's cast list. Click to turn off." if receiving else "Enable cast reception, then choose %s from your phone's cast list.") % str(state.get("name", "Thru3D"))
	if not str(state.get("error", "")).is_empty(): tip = I18n.t(str(state.error))
	lines.append(tip)
	if receiving:
		if airplay == "starting": lines.append("AirPlay · " + I18n.t("Loading…"))
		if not str(state.get("airplay_error", "")).is_empty(): lines.append(I18n.t(str(state.airplay_error)))
		if not str(state.get("airplay_pin", "")).is_empty(): lines.append("PIN · " + str(state.airplay_pin))
	return "\n".join(lines)

## Idle receiver status appears only beside the receive toggle, never over playback.
static func draw(menu: Node3D, state: Dictionary, y: float, show_status: bool = true) -> void:
	if not state.get("pending", {}).is_empty():
		background(menu, Vector2(1.08, 0.19), y)
		menu._label(menu._fit_title(I18n.t("Cast request") + " · " + I18n.t(str(state.pending.get("title", ""))), "", 0.98, 18), Vector3(0, y + 0.045, 0.012), 18)
		menu._button(ACCEPT, I18n.t("Switch"), Vector2(-0.20, y - 0.035), Vector2(0.34, 0.065), true, "", true)
		menu._button(REJECT, I18n.t("Ignore"), Vector2(0.20, y - 0.035), Vector2(0.34, 0.065))
	elif state.get("return_available", false):
		background(menu, Vector2(1.08, 0.13), y)
		menu._button(RETURN, I18n.t("Return to previous media"), Vector2(-0.18, y), Vector2(0.65, 0.065))
		menu._button(DISMISS, I18n.t("Dismiss"), Vector2(0.36, y), Vector2(0.25, 0.065))
	elif show_status and state.get("enabled", false):
		var text: String = str(state.get("error", ""))
		if text.is_empty(): text = I18n.t("Receiving video") if state.get("active", false) else I18n.t("Waiting for cast") + " · " + str(state.get("name", "Thru3D"))
		else: text = I18n.t(text)
		menu._label(text, Vector3(0, y, 0.012), 16)
