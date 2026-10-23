extends RefCounted
const I18n := preload("res://scripts/i18n.gd")
const TOGGLE := 988201
const ACCEPT := 988202
const REJECT := 988203
const RETURN := 988204
const DISMISS := 988205

static func action(target: int) -> String:
	return {TOGGLE: "toggle", ACCEPT: "accept", REJECT: "reject", RETURN: "return", DISMISS: "dismiss"}.get(target, "")

static func background(menu: Node3D, size: Vector2, y: float) -> void:
	var panel: MeshInstance3D = menu._quad(size, Vector3(0, y, 0.001), menu.PANEL, 10)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, size)

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
