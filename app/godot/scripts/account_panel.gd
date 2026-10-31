extends RefCounted
## Account forms and web login share the existing VR library ray menu.
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Focus := preload("res://scripts/web_browser_focus.gd")
const PointerFilter := preload("res://scripts/web_pointer_filter.gd")
const BASE := 2000
const FIELD := 2100
const KEY := 2200
const CAPTCHA := 2300
const WEB := 2400
const WEB_SCROLL := 2401
var menu: Node
var view := ""
var kind := ""
var provider := ""
var session := 0
var data := {}
var items: Array = []
var fields: Array[String] = []
var field := ""
var shift := false
var symbols := false
var selected: Array[int] = []
var prompt: Texture2D
var choices: Texture2D
var web_texture: ImageTexture
var web_node: MeshInstance3D
var web_hand := ""
var web_drag_scroll := false
var web_point := Vector2.ZERO
var web_time := 0.0
var poll_time := 0.0
var revision := -1
var challenge_revision := -1
var paused := false
var license_lines: Array[String] = []
var title := ""
var web_focus := Focus.FULL
var web_selecting := false
var web_selection := Rect2()
var web_selection_start := Vector2.ZERO
var web_surface: Node3D
var web_filters := {}
var web_outline: Array[MeshInstance3D] = []
var _web_navigation := ""
var _web_surface_status := ""

func _init(owner: Node) -> void: menu = owner
func active() -> bool: return not view.is_empty()
func supported() -> bool: return Methods.supports(menu.platform, "account_open")

func close() -> void:
	if session > 0:
		preload("res://scripts/diagnostic_log.gd").record("account_session_closed", {"provider": provider, "view": view,
			"paused": paused, "source": get_stack().slice(0, 5).map(func(frame): return str(frame.get("function", "")))})
	if active(): menu.scroll = 0.0
	web_cancel()
	if session > 0 and menu.platform: menu.platform.account_cancel(session)
	session = 0; view = ""; data = {}; items = []; fields.clear(); field = ""
	shift = false; symbols = false
	prompt = null; choices = null; web_texture = null; web_node = null; selected.clear()
	license_lines.clear(); revision = -1; challenge_revision = -1; paused = false; _defaults = {}
	web_focus = Focus.FULL; web_selecting = false; web_selection = Rect2(); web_filters.clear(); _web_navigation = ""
	_web_surface_status = ""

func open(source: String, manage: bool = false) -> void:
	close()
	kind = source
	menu.server_browser.cancel(); menu._cancel_cloud()
	if not supported():
		menu.status = "Account settings unavailable"; menu.refresh(); return
	view = "accounts" if manage else "choose"
	title = "Cloud accounts" if source == "cloud" else "Media servers"
	if manage: load_accounts()
	menu.status = ""; menu._reset_navigation(); menu.refresh()

func load_accounts() -> void:
	var parsed: Variant = JSON.parse_string(menu.platform.account_list(kind))
	items = parsed if parsed is Array else []
	if not parsed is Array: menu.status = "Account settings unavailable"

func start(type: String, selected_provider: String = "", id: String = "", defaults: Dictionary = {}) -> void:
	shift = false; symbols = false
	menu.system_text_input.cancel()
	if session > 0: menu.platform.account_cancel(session)
	web_cancel(); web_texture = null; prompt = null; choices = null; selected.clear()
	provider = selected_provider
	session = menu.platform.account_open(type, provider, id, JSON.stringify(defaults))
	view = "discover" if type == "discover" else ("dav" if type == "dav" else "form")
	fields.assign(["name", "base", "username", "password"] if type == "server" or (type == "cloud" and provider == "webdav") else ["name", "username", "password"])
	if type == "server" and provider == "stash": fields.erase("username")
	if type == "server" and provider == "plex": fields.assign(["name", "base"])
	if type == "cloud" and provider not in ["115", "webdav"]: fields.assign(["name"])
	field = "base" if type == "server" or provider == "webdav" else "username"
	if not field in fields: field = "name"
	_defaults = {}
	data = {}; revision = -1; challenge_revision = -1; title = "WebDAV" if type == "dav" else ("Search local network" if type == "discover" else provider_name(provider))
	menu.scroll = 0.0; poll(); menu.refresh()

func provider_name(value: String) -> String:
	return {"115": "115", "115_open": "115", "onedrive": "OneDrive", "webdav": "WebDAV", "baidu": I18n.t("Baidu Netdisk"), "aliyun_open": I18n.t("Aliyun Drive"), "quark_open": I18n.t("Quark Netdisk"), "emby": "Emby", "jellyfin": "Jellyfin", "stash": "Stash", "xbvr": "XBVR", "plex": "Plex"}.get(value, value)

func poll() -> void:
	if session <= 0 or not menu.platform: return
	var parsed: Variant = JSON.parse_string(menu.platform.account_snapshot(session))
	if not parsed is Dictionary or parsed.is_empty(): return
	var previous_wait := int(data.get("sms_wait", 0))
	var previous_pairing_expired := bool(data.get("pairing_expired", false))
	data = parsed
	var state := str(data.get("state", "form"))
	if state == "done":
		var source := kind
		close()
		if source == "cloud": menu.cloud_accounts.changed()
		else: menu.server_browser.load_servers(); menu.refresh()
		return
	if state in ["captcha", "sms", "web", "dav", "discover", "plex_link", "plex_servers"]: view = state
	if state == "captcha" and int(data.get("challenge_revision", 0)) != challenge_revision:
		prompt = decode(str(data.get("prompt", ""))); choices = decode(str(data.get("choices", ""))); selected.clear()
		challenge_revision = int(data.get("challenge_revision", 0))
	if view == "sms": fields.assign(["sms"]); field = "sms"
	if view == "discover": items = data.get("result", {}).get("servers", [])
	if view == "plex_servers": items = data.get("result", {}).get("servers", [])
	var changed := int(data.get("revision", 0)) != revision or previous_wait != int(data.get("sms_wait", 0)) or previous_pairing_expired != bool(data.get("pairing_expired", false))
	if view == "web": changed = changed or str(data.get("web", {})) != _web_status
	if web_gecko():
		var context := str([data.web.get("surface_id", ""), data.web.get("navigation", 0), data.web.get("desktop", false)])
		if context != _web_navigation:
			web_cancel(); web_focus = Focus.FULL; web_selecting = false; web_filters.clear(); _web_navigation = context
	_web_status = str(data.get("web", {}))
	revision = int(data.get("revision", 0))
	if changed: menu.refresh()

var _web_status := ""
func tick(delta: float) -> void:
	if not active() or paused: return
	if web_gecko():
		var next_status := str(web_surface.status) if is_instance_valid(web_surface) else ""
		if next_status != _web_surface_status:
			_web_surface_status = next_status; menu.refresh()
	poll_time += delta; web_time += delta
	if poll_time >= 0.2: poll_time = 0.0; poll()
	if view == "web" and not web_gecko() and web_time >= 0.2 and menu.visible:
		web_time = 0.0
		var bytes: PackedByteArray = menu.platform.account_web_frame(session)
		if not bytes.is_empty():
			var image := Image.new()
			if image.load_jpg_from_buffer(bytes) == OK:
				if web_texture == null: web_texture = ImageTexture.create_from_image(image)
				elif web_texture.get_height() != image.get_height(): web_texture.set_image(image)
				else: web_texture.update(image)
				if is_instance_valid(web_node): web_node.material_override.albedo_texture = web_texture
				menu.composition_changed.emit()

func lifecycle(state: String) -> void:
	paused = state == "pause"
	if paused: web_cancel()
	else: poll()
	if session > 0 and view == "web": preload("res://scripts/diagnostic_log.gd").record("account_session_lifecycle", {"provider": provider, "event": state, "view": view})

func decode(value: String) -> Texture2D:
	if value.length() > 1500000: return null
	var bytes := Marshalls.base64_to_raw(value)
	var image := Image.new()
	var error := image.load_png_from_buffer(bytes)
	if error != OK: error = image.load_jpg_from_buffer(bytes)
	if error != OK or image.get_width() > 2048 or image.get_height() > 2048: return null
	return ImageTexture.create_from_image(image)

func command(action: String, extra: Dictionary = {}) -> void:
	if session > 0: menu.platform.account_action(session, action, JSON.stringify(extra)); poll()

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if view == "choose":
		if kind == "cloud":
			for p in ["115_open", "baidu", "aliyun_open", "quark_open", "onedrive", "webdav"]: result.append({"title": provider_name(p), "icon": menu.Icons.provider(p), "account_provider": p})
		else:
			result.append({"title": I18n.t("Search local network"), "icon": "refresh", "account_discover": true})
			for p in ["emby", "jellyfin", "plex", "stash", "xbvr"]: result.append({"title": provider_name(p), "icon": menu.Icons.provider(p, "server"), "account_provider": p})
	elif view == "accounts":
		for item in items: result.append({"title": str(item.name), "detail": provider_name(str(item.provider)), "icon": menu.Icons.provider(str(item.provider), "server" if kind == "server" else "cloud"), "account_edit": item})
	elif view == "discover":
		for item in items: result.append({"title": str(item.name) if not str(item.name).is_empty() else I18n.t("Server"), "detail": str(item.base), "icon": menu.Icons.provider(str(item.get("provider", "")), "server"), "account_found": item})
	elif view == "plex_servers":
		for item in items: result.append({"title": str(item.name), "icon": menu.Icons.provider("plex", "server"), "plex_server": str(item.id)})
	elif view == "license":
		for i in range(0, license_lines.size(), 2):
			result.append({"title": license_lines[i], "detail": license_lines[i + 1] if i + 1 < license_lines.size() else "", "icon": "info", "about_info": true})
	return result

func choose(row: Dictionary) -> bool:
	if not active(): return false
	if row.has("account_provider"): start(kind, str(row.account_provider), "", _defaults)
	elif row.has("plex_server"): command("plex_select", {"server_id": str(row.plex_server)})
	elif row.has("account_edit"): start(kind, str(row.account_edit.provider), str(row.account_edit.id))
	elif row.has("account_dav"): start("dav")
	elif row.has("account_discover"): start("discover")
	elif row.has("account_found"):
		var found: Dictionary = row.account_found
		if str(found.provider).is_empty():
			_defaults = found; view = "choose"; menu.refresh()
		else: start("server", str(found.provider), "", found)
	return true

var _defaults := {}
func action(target: int) -> bool:
	if not active() or target < BASE: return false
	if paused: return true
	if target == BASE:
		close(); menu._load_section(); menu.refresh(); return true
	if target >= FIELD and target < FIELD + fields.size(): field = fields[target - FIELD]; menu.refresh(); return true
	if target >= CAPTCHA and target < CAPTCHA + 10:
		if not data.get("busy", false) and selected.size() < 4: selected.append(target - CAPTCHA); menu.refresh()
		return true
	if target >= KEY and target < KEY + 40:
		if data.get("busy", false): return true
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
		var value: String = layer[(target - KEY) / 10][(target - KEY) % 10]
		var uppercase := shift
		shift = false # poll() can redraw synchronously; publish the next state first.
		input("append", value.to_upper() if uppercase else value)
		if uppercase: menu.refresh() # Web input need not change the account snapshot.
		return true
	match target - BASE:
		1: shift = not shift; menu.refresh()
		2: symbols = not symbols; menu.refresh()
		3: input("append", " ")
		4: input("backspace", "")
		5: input("paste", "")
		6: command("save_server" if kind == "server" else ("save_webdav" if provider == "webdav" else "password"))
		7: command("web")
		8: command("rename")
		9: command("send_sms")
		10: command("verify_sms")
		11: selected.clear(); menu.refresh()
		12:
			var code := ""
			for i in selected: code += str(i)
			command("answer", {"code": code})
		13: choices = null; prompt = null; selected.clear(); command("captcha")
		14: command("dav_enable", {"enabled": not data.get("result", {}).get("enabled", false)})
		15: command("dav_reset")
		16: command("dav_show")
		17: web_action("back")
		18: web_action("reload")
		19: web_action("enter")
		20: web_action("keyboard_close")
		21: web_action("finish")
		22:
			if session > 0: menu.platform.account_cancel(session); session = 0
			view = "choose"; menu.scroll = 0.0; menu.refresh()
		23: web_action("zoom_in")
		24: web_action("zoom_out")
		25: web_action("scroll", Vector2(0, -1))
		26: web_action("scroll", Vector2(0, 1))
		27: command("plex_authorize")
		28: command("plex_confirm")
		29:
			if not web_hand.is_empty(): return true
			if web_selecting: web_selecting = false
			elif web_focus != Focus.FULL: web_focus = Focus.FULL
			else: web_selecting = true; web_selection = Rect2()
			web_filters.clear(); menu.refresh()
		30:
			if data.get("web", {}).get("desktop_only", false): return true
			if not web_hand.is_empty(): return true
			web_selecting = false; web_focus = Focus.FULL; web_filters.clear()
			web_action("mobile" if data.get("web", {}).get("desktop", false) else "desktop")
	return true

func input(action_name: String, text: String) -> void:
	if data.get("busy", false): return
	if view == "web": web_action("text" if action_name == "append" else action_name, Vector2.ZERO, text)
	else: menu.platform.account_input(session, field, action_name, text); poll()

func _draw_server_choices() -> void:
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	for i in range(1, menu.rows.size()):
		var k := i - 1; var row: Dictionary = menu.rows[i]
		menu._button(menu.ROW_BASE + i, str(row.title), Vector2(-0.17 + (k % 2) * 0.65, 0.24 - (k / 2) * 0.19), Vector2(0.60, 0.16), true, "", false, menu._list)
		var card: MeshInstance3D = menu._buttons.back().node
		card.get_child(0).position.y = -0.048
		menu._icon(str(row.icon), Vector3(0, 0.028, 0.004), 0.078, Color(0.9, 0.9, 0.9), card)
	if not menu.rows.is_empty():
		menu._button(menu.ROW_BASE, str(menu.rows[0].title), Vector2(0.155, -0.36), Vector2(1.25, 0.095), true, "", false, menu._list)

func draw() -> void:
	if view == "web":
		draw_web(); return
	menu._button(BASE, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), true, "up")
	menu._label(I18n.t(title), Vector3(0.13, 0.46, 0.004), 24)
	var enabled := not bool(data.get("busy", false))
	if view in ["choose", "accounts", "discover", "license", "plex_servers"]:
		if view == "choose" and kind == "server": _draw_server_choices()
		else: menu._draw_rows()
		if view == "accounts": menu._button(BASE + 22, "", Vector2(0.8, 0.46), Vector2(0.09, 0.07), true, "plus")
		if view == "discover": menu._button(BASE + 22, I18n.t("Add manually"), Vector2(0.15, -0.51), Vector2(0.38, 0.07))
	elif view == "form" or view == "sms":
		draw_fields(enabled); draw_keyboard(enabled)
		if view == "sms":
			var wait := int(data.get("sms_wait", 0))
			menu._button(BASE + 9, str(wait) + "s" if wait > 0 else I18n.t("Send SMS code"), Vector2(-0.14, 0.15), Vector2(0.42, 0.07), enabled and wait == 0)
			menu._button(BASE + 10, I18n.t("Verify and sign in"), Vector2(0.4, 0.15), Vector2(0.48, 0.07), enabled and bool(data.get("sms_sent", false)))
		else:
			if kind == "server" and provider == "plex":
				menu._button(BASE + 27, I18n.t("Authorize"), Vector2(0.17, 0.012), Vector2(0.7, 0.077), enabled, "", true)
				if _editing_id(): menu._button(BASE + 6, I18n.t("Test and save"), Vector2(0.3, -0.51), Vector2(0.4, 0.07), enabled)
			elif kind == "server" or provider == "webdav": menu._button(BASE + 6, I18n.t("Test and save"), Vector2(0.3, -0.51), Vector2(0.4, 0.07), enabled, "", true)
			else:
				if provider == "115":
					menu._button(BASE + 7, I18n.t("Sign in on website"), Vector2(-0.15, 0.012), Vector2(0.54, 0.077), enabled)
					menu._button(BASE + 6, I18n.t("Sign in"), Vector2(0.46, 0.012), Vector2(0.54, 0.077), enabled and not str(data.get("fields", {}).get("username", "")).is_empty() and int(data.get("password_length", 0)) > 0, "", true)
				else: menu._button(BASE + 7, I18n.t("Authorize" if provider in ["115_open", "baidu", "aliyun_open", "quark_open", "onedrive"] else "Sign in on website"), Vector2(0.17, 0.012), Vector2(0.7, 0.077), enabled, "", true)
				if _editing_id():
					menu._button(BASE + 8, "", Vector2(0.73, -0.51), Vector2(0.1, 0.07), enabled and not str(data.get("fields", {}).get("name", "")).strip_edges().is_empty(), "check")
					menu._tips[BASE + 8] = I18n.t("Save name")
	elif view == "plex_link":
		menu._label("plex.tv/link", Vector3(0.15, 0.22, 0.008), 30)
		menu._label(str(data.get("result", {}).get("code", "")), Vector3(0.15, 0.05, 0.008), 56)
		menu._label(I18n.t("Pair on phone or computer"), Vector3(0.15, -0.065, 0.008), 17)
		menu._button(BASE + 28, I18n.t("Confirm pairing" if enabled else "Checking…"), Vector2(0.15, -0.21), Vector2(0.72, 0.09), enabled and data.get("result", {}).has("code") and not bool(data.get("pairing_expired", false)) and str(data.get("error", "")) != "Pairing code expired", "", true)
		menu._button(BASE + 27, "", Vector2(0.15, -0.34), Vector2(0.12, 0.08), enabled, "refresh")
	elif view == "captcha": draw_captcha(enabled)
	elif view == "dav":
		var result: Dictionary = data.get("result", {})
		var on: bool = result.get("enabled", false)
		menu._button(BASE + 14, I18n.t("Turn off" if on else "Turn on"), Vector2(0.1, 0.29), Vector2(0.43, 0.09), enabled)
		var y := 0.15
		for address in result.get("addresses", []): menu._label(str(address), Vector3(0.1, y, 0.004), 20); y -= 0.06
		if on:
			menu._label(I18n.t("Username: quest"), Vector3(0.1, y - 0.06, 0.004), 21)
			menu._label(str(result.get("password", "••••••••••••")), Vector3(0.1, y - 0.13, 0.004), 20)
			menu._button(BASE + 16, I18n.t("Show password"), Vector2(-0.15, -0.3), Vector2(0.4, 0.08), enabled)
			menu._button(BASE + 15, I18n.t("Reset password"), Vector2(0.4, -0.3), Vector2(0.4, 0.08), enabled)
	elif view == "web": draw_web()
	var error := str(data.get("error", ""))
	if error.begins_with("Sign-in declined ("):
		error = I18n.t("Sign-in declined (%s).").replace("%s", error.trim_prefix("Sign-in declined (").trim_suffix(")."))
	else: error = I18n.t(error)
	if bool(data.get("busy", false)) and view != "plex_link": error = I18n.t("Connecting…")
	if not error.is_empty(): menu._label(error, Vector3(0.15, 0.375, 0.006), 17)

func _editing_id() -> bool: return bool(data.get("editing_account", false))
func draw_fields(enabled: bool) -> void:
	var names := {"name": "Name", "base": "Server address", "username": "Username", "password": "Password", "sms": "SMS code"}
	if provider == "115": names.username = "115 account / phone number"
	if provider == "stash": names.password = "API Key"
	if provider == "plex": names.base = "Server address (optional)"
	for i in fields.size():
		var key: String = fields[i]
		var value := str(data.get("fields", {}).get(key, ""))
		if key in ["password", "sms"]:
			value = "•".repeat(mini(int(data.get(key + "_length", 0)), 32))
			if key == "password" and value.is_empty() and data.get("has_password", false): value = I18n.t("Keep saved login")
		var y := 0.30 - i * 0.087
		menu._button(FIELD + i, "", Vector2(0.17, y), Vector2(1.2, 0.077), enabled, "", key == field)
		var node: MeshInstance3D = menu._buttons.back().node
		var label: Label3D = node.get_child(0)
		label.text = I18n.t(names[key]); menu.set_label_size(label, 16); label.position = Vector3(-0.57, 0.012, 0.004); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var detail: Label3D = menu._label(menu._fit_title(value, "", 1.1, 19), Vector3(-0.57, -0.018, 0.004), 19, node)
		detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		detail.modulate = Color(0.04, 0.10, 0.08) if key == field else Color.WHITE

func draw_keyboard(enabled: bool, offset: Vector2 = Vector2.ZERO) -> void:
	preload("res://scripts/ray_keyboard_layout.gd").draw(menu, BASE, KEY, enabled, shift, symbols, offset)

func texture_node(texture: Texture2D, centre: Vector2, size: Vector2) -> MeshInstance3D:
	var node := MeshInstance3D.new(); var mesh := QuadMesh.new(); mesh.size = size; node.mesh = mesh
	node.position = Vector3(centre.x, centre.y, 0.007)
	var material: StandardMaterial3D = menu._material(Color.WHITE, 13); material.albedo_texture = texture
	node.material_override = material; menu.add_child(node); menu._decorations.append(node)
	return node

func draw_captcha(enabled: bool) -> void:
	if prompt: texture_node(prompt, Vector2(0.12, 0.26), Vector2(0.85, 0.13))
	for i in 10:
		var centre := Vector2(-0.34 + (i % 5) * 0.23, 0.02 - (i / 5) * 0.18)
		menu._button(CAPTCHA + i, "", centre, Vector2(0.19, 0.15), enabled and selected.size() < 4)
		if choices:
			var tile := AtlasTexture.new(); tile.atlas = choices
			tile.region = Rect2((i % 5) * choices.get_width() / 5.0, (i / 5) * choices.get_height() / 2.0, choices.get_width() / 5.0, choices.get_height() / 2.0)
			texture_node(tile, centre, Vector2(0.14, 0.12))
	menu._label("%d / 4" % selected.size(), Vector3(0.1, -0.29, 0.008), 22)
	for i in selected.size():
		menu._label(str(i + 1), Vector3(-0.34 + (selected[i] % 5) * 0.23, 0.085 - (selected[i] / 5) * 0.18, 0.01), 25)
	menu._button(BASE + 11, I18n.t("Clear selection"), Vector2(-0.24, -0.43), Vector2(0.32, 0.08), enabled)
	menu._button(BASE + 13, "", Vector2(0.13, -0.43), Vector2(0.12, 0.08), enabled, "refresh")
	menu._button(BASE + 12, I18n.t("Continue"), Vector2(0.49, -0.43), Vector2(0.34, 0.08), enabled and selected.size() == 4, "", true)

func web_gecko() -> bool: return view == "web" and data.get("web", {}).get("renderer", "") == "gecko"
func web_frame_rect() -> Rect2:
	if data.get("web", {}).get("desktop", false): return Rect2(-0.90, -0.54, 1.80, 1.08)
	# Keep the phone layout independent of a comfortable physical interaction surface.
	var info: Dictionary = data.get("web", {})
	var size := Vector2(1.20, 1.20 * float(info.get("height", 600)) / maxf(1.0, float(info.get("width", 440))))
	return Rect2(-size * 0.5, size)
func web_rect() -> Rect2:
	if not web_gecko(): return Rect2(-0.87, -0.38, 1.72, 1.032)
	var frame := web_frame_rect()
	var info: Dictionary = data.get("web", {})
	var size := Focus.fitted(frame.size, Vector2(info.get("width", 440), info.get("height", 600)), web_focus)
	return Rect2(frame.get_center() - size * 0.5, size)
func draw_web() -> void:
	if web_gecko(): draw_gecko(); return
	var editing: bool = data.get("web", {}).get("editing", false)
	menu._set_backdrop(Vector2(1.94, 1.94 if editing else 1.38), Vector2(0, -0.12 if editing else 0.16))
	menu._button(BASE, "", Vector2(-0.85, 0.75), Vector2(0.1, 0.08), true, "up")
	menu._button(BASE + 17, "", Vector2(-0.70, 0.75), Vector2(0.1, 0.08), true, "back")
	menu._button(BASE + 18, "", Vector2(-0.55, 0.75), Vector2(0.1, 0.08), true, "refresh")
	menu._label(provider_name(provider), Vector3(-0.05, 0.75, 0.009), 24)
	menu._button(BASE + 24, "", Vector2(0.51, 0.75), Vector2(0.1, 0.08), true, "minus")
	menu._button(BASE + 23, "", Vector2(0.66, 0.75), Vector2(0.1, 0.08), true, "plus")
	menu._button(menu.CLOSE, "", Vector2(0.85, 0.75), Vector2(0.1, 0.08), true, "close")
	var rect := web_rect()
	menu._button(WEB, "", rect.get_center(), rect.size)
	web_node = texture_node(web_texture, rect.get_center(), rect.size)
	var info: Dictionary = data.get("web", {})
	var range_px := maxf(1.0, float(info.get("scroll_range", 720)))
	var page_px := float(info.get("height", 720))
	var can_scroll := range_px > page_px + 1
	menu._button(WEB_SCROLL, "", Vector2(0.91, 0.135), Vector2(0.045, 0.92), can_scroll)
	var thumb := clampf(page_px / range_px, 0.08, 1.0) * 0.92
	var fraction := clampf(float(info.get("scroll_y", 0)) / maxf(1.0, range_px - page_px), 0, 1)
	menu._decoration(Vector2(0.025, thumb), Vector2(0.91, 0.595 - thumb * 0.5 - fraction * (0.92 - thumb)), menu.ACCENT if can_scroll else Color(0.4, 0.45, 0.5))
	menu._button(BASE + 25, "", Vector2(0.91, 0.63), Vector2(0.06, 0.06), can_scroll, "arrow_up")
	menu._button(BASE + 26, "", Vector2(0.91, -0.36), Vector2(0.06, 0.06), can_scroll, "arrow_down")
	menu._button(BASE + 21, I18n.t("Finish sign-in"), Vector2(0, -0.48), Vector2(0.45, 0.08), true, "", true)
	if editing:
		draw_keyboard(true, Vector2(-0.17, -0.53))
		menu._button(BASE + 20, "", Vector2(-0.42, -0.48), Vector2(0.12, 0.08), true, "keyboard_hide")
		menu._button(BASE + 19, "", Vector2(0.42, -0.48), Vector2(0.12, 0.08), true, "check")
	menu._place_device_status(Vector2(0, -1.17 if editing else -0.66))
	var status: String = data.get("web", {}).get("status", "")
	var error := str(data.get("error", ""))
	if data.get("busy", false): status = "Connecting…"
	elif not error.is_empty(): status = error
	if not status.is_empty(): menu._label(I18n.t(status), Vector3(0, -0.56, 0.009), 17)

func web_action(action_name: String, point: Vector2 = Vector2.ZERO, text: String = "") -> void:
	if web_gecko() and action_name in ["back", "reload", "desktop", "mobile", "legacy"]:
		if not web_hand.is_empty(): return
		web_selecting = false; web_focus = Focus.FULL; web_filters.clear()
	if session > 0 and menu.platform: menu.platform.account_web_action(session, action_name, point.x, point.y, text)

func draw_gecko() -> void:
	var info: Dictionary = data.get("web", {})
	var frame := web_frame_rect()
	var rect := web_rect()
	var top := frame.end.y
	var chrome_width := 1.98 if info.get("desktop", false) else 1.68
	var pitch := 0.27 if info.get("desktop", false) else 0.23
	menu._set_backdrop(Vector2(chrome_width, frame.size.y + 0.65), Vector2(0, 0.06))
	# The account chrome is captured by MenuComposition, whose centre must stay transparent.
	menu._backdrop.material_override.set_shader_parameter("surface_color", Color(0, 0, 0, 0))
	for bounds in [Rect2(-chrome_width * 0.5, top + 0.02, chrome_width, 0.32), Rect2(-chrome_width * 0.5, frame.position.y - 0.27, chrome_width, 0.25)]:
		var centre: Vector2 = bounds.get_center()
		var background: MeshInstance3D = menu._quad(bounds.size, Vector3(centre.x, centre.y, 0), menu.PANEL, 10)
		menu.add_child(background); menu._decorations.append(background); menu._pointer_panels.append(background)
	menu._label(provider_name(provider), Vector3(0, top + 0.27, 0.009), 24)
	var actions := [
		[BASE, "up", "Back"], [BASE + 17, "back", "Back"], [BASE + 18, "refresh", "Reload"],
		[BASE + 29, "close" if web_selecting else "expand" if web_focus != Focus.FULL else "region_focus", "Cancel selection" if web_selecting else "Exit focus" if web_focus != Focus.FULL else "Focus region"]]
	if not info.get("desktop_only", false): actions.append([BASE + 30, "phone" if info.get("desktop", false) else "desktop", "Mobile site" if info.get("desktop", false) else "Desktop site"])
	actions.append([menu.CLOSE, "close", "Close"])
	for i in actions.size():
		var item: Array = actions[i]
		var focused: bool = item[0] == BASE + 29 and (web_selecting or web_focus != Focus.FULL)
		menu._button(item[0], "", Vector2((i - (actions.size() - 1) * 0.5) * pitch, top + 0.115), Vector2(0.15, 0.15), web_hand.is_empty(), item[1], focused)
		menu._tips[item[0]] = I18n.t(item[2])
	menu._button(WEB, "", rect.get_center(), rect.size, not bool(info.get("failed", false)))
	menu._buttons.back().node.set_meta("menu_eye_buffer", true)
	menu._buttons.back().node.position.z = 0.007
	if info.get("editing", false):
		menu._button(BASE + 20, "", Vector2(chrome_width * 0.5 - 0.19, frame.position.y - 0.12), Vector2(0.15, 0.15), true, "keyboard_hide")
	var message := str(info.get("status", ""))
	if data.get("busy", false): message = "Connecting…"
	elif not str(data.get("error", "")).is_empty(): message = str(data.error)
	elif info.get("failed", false) and message.is_empty(): message = "Page unavailable. Try reloading."
	elif not _web_surface_status.is_empty(): message = "Web sign-in is unavailable on this device."
	if not message.is_empty(): menu._label(I18n.t(message), Vector3(0, frame.position.y - 0.12, 0.009), 18)
	if info.get("loading", false):
		var length := frame.size.x * clampf(float(info.get("progress", 0)) / 100, 0.02, 1.0)
		menu._decoration(Vector2(length, 0.007), Vector2(frame.position.x + length * 0.5, frame.position.y - 0.012), menu.ACCENT)
	menu._place_device_status(Vector2(0, frame.position.y - 0.36))
	web_outline.clear()
	for i in 4:
		var line := MeshInstance3D.new(); line.mesh = QuadMesh.new()
		line.material_override = menu._material(menu.ACCENT, 28); line.set_meta("menu_eye_buffer", true)
		menu.add_child(line); menu._decorations.append(line); web_outline.append(line)
	update_web_outline()
	if not is_instance_valid(web_surface) and menu.is_inside_tree():
		web_surface = preload("res://scripts/account_login_surface.gd").new(); web_surface.configure(menu)
		menu.get_tree().root.add_child(web_surface)

func update_web_outline() -> void:
	var frame := web_rect()
	var selection := Rect2(frame.position + Vector2(web_selection.position.x, 1.0 - web_selection.end.y) * frame.size, web_selection.size * frame.size)
	for i in web_outline.size():
		var node: MeshInstance3D = web_outline[i]
		if not is_instance_valid(node): continue
		node.visible = web_selecting and not web_hand.is_empty() and web_selection.has_area()
		var horizontal := i < 2
		node.mesh.size = Vector2(selection.size.x, 0.005) if horizontal else Vector2(0.005, selection.size.y)
		var point := Vector2(selection.get_center().x, selection.position.y if i == 0 else selection.end.y) if horizontal else Vector2(selection.position.x if i == 2 else selection.end.x, selection.get_center().y)
		node.position = Vector3(point.x, point.y, 0.025)

func web_ray(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> Array:
	if not web_gecko(): return [origin, direction]
	if not tracked:
		web_filters.erase(hand); return [origin, direction]
	var hit: Dictionary = menu.ray_hit(origin, direction)
	if web_hand != hand and int(hit.get("target", -1)) != WEB:
		web_filters.erase(hand); return [origin, direction]
	# The menu's optional mono projection already defines the shared angular reticle.
	if not menu._mono_pointer_projection().is_empty(): return [origin, direction]
	var point: Variant = web_project(origin, direction)
	if point == null: web_filters.erase(hand); return [origin, direction]
	if not web_filters.has(hand): web_filters[hand] = PointerFilter.new()
	var stable: Vector2 = web_filters[hand].sample(Vector2(point.x, point.y), Time.get_ticks_usec())
	if web_hand == hand: stable = stable.clamp(web_rect().position, web_rect().end)
	var endpoint: Vector3 = menu.to_global(Vector3(stable.x, stable.y, point.z))
	return [origin, (endpoint - origin).normalized()]

func web_project(origin: Vector3, direction: Vector3) -> Variant:
	if not web_gecko(): return menu._plane_point(origin, direction)
	var plane := Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.007))
	var point: Variant = menu.project_pointer(origin, direction, plane)
	return plane * Vector3(point) if point != null else null
func web_uv(point: Vector3) -> Vector2:
	var rect := web_rect()
	var uv := Vector2((point.x - rect.position.x) / rect.size.x, 1.0 - (point.y - rect.position.y) / rect.size.y)
	return Focus.map_point(uv.clamp(Vector2.ZERO, Vector2.ONE), web_focus) if web_gecko() else uv
func web_press(hand: String, point: Vector3, scrolling: bool = false) -> void:
	if not web_hand.is_empty(): return
	web_hand = hand; web_drag_scroll = scrolling
	if web_gecko() and web_selecting:
		web_selection_start = web_uv(point); web_selection = Rect2(web_selection_start, Vector2.ZERO); return
	if scrolling: web_scroll_to(point)
	else: web_point = web_uv(point); web_action("down", web_point)
func web_move(hand: String, point: Vector3) -> void:
	if web_hand != hand: return
	if web_gecko() and web_selecting:
		web_selection = Focus.selection(web_selection_start, web_uv(point)); update_web_outline(); return
	if web_drag_scroll: web_scroll_to(point)
	else: web_point = web_uv(point); web_action("move", web_point)
func web_release(hand: String, point: Variant) -> void:
	if web_hand != hand: return
	if web_gecko() and web_selecting:
		if point != null:
			web_selection = Focus.selection(web_selection_start, web_uv(point))
			if Focus.valid(web_selection): web_focus = web_selection
			else: web_focus = Rect2((web_selection_start - Vector2(0.25, 0.25)).clamp(Vector2.ZERO, Vector2(0.5, 0.5)), Vector2(0.5, 0.5))
		web_hand = ""; web_selecting = false; web_filters.clear(); menu.refresh(); return
	if web_drag_scroll:
		if point != null: web_scroll_to(point)
	elif point == null: web_action("cancel", web_point)
	else: web_action("up", web_uv(point))
	web_hand = ""; web_drag_scroll = false
func web_cancel() -> void:
	if not web_hand.is_empty() and not web_drag_scroll and not web_selecting: web_action("cancel", web_point)
	web_hand = ""; web_drag_scroll = false
	web_filters.clear()
	update_web_outline()

func web_scroll_to(point: Vector3) -> void:
	web_action("scroll_to", Vector2(0, clampf((0.595 - point.y) / 0.92, 0, 1)))

func show_license(name: String, text: String) -> void:
	close(); view = "license"; title = name
	for original in text.split("\n"):
		var line := ""
		for c in original:
			if menu.text_width(line + c, 19) > 1.12:
				license_lines.append(line); line = ""
			line += c
		license_lines.append(line)
	menu._reset_navigation(); menu.refresh()
