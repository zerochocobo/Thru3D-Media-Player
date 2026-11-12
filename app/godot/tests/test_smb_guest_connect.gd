extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends "res://tests/account_platform_fixture.gd":
	var next := 100
	var connects: Array = []
	var saves: Array = []
	var browses: Array = []
	var cancelled := 0
	func media_smb_cancel_browse() -> void: cancelled += 1
	func media_smb_connect(json: String) -> int:
		connects.append(JSON.parse_string(json)); next += 1; return next
	func media_smb_save(json: String) -> int:
		saves.append(JSON.parse_string(json)); next += 1; return next
	func media_smb_browse(server: String, path: String) -> int:
		browses.append([server, path]); next += 1; return next
	func media_smb_servers() -> int:
		next += 1; return next

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)
func reply(menu: Node, id: int, result: Dictionary) -> void:
	menu._on_media_list(id, JSON.stringify(result))
func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.platform = platform; menu.visible = true; menu.set_process(false)
	menu.section = Menu.Section.SMB
	var found := {"name": "Living room NAS", "host": "nas"}
	var saved := {"id": "guest", "name": found.name, "host": found.host, "user": "", "has_password": false}
	menu._choose({"smb_found": found})
	check(platform.connects == [found] and menu._editor.is_empty() and platform.saves.is_empty(), "Selecting discovery tries guest before opening or saving a login")
	reply(menu, platform.next, {"state": "ready", "server_id": "guest", "path": "", "servers": [saved], "entries": [{"id": "Movies", "title": "Movies", "container": true}]})
	check(menu._smb_server == "guest" and menu._smb_entries.size() == 1 and menu._editor.is_empty(), "Guest success opens the returned shares directly")
	menu._choose({"container": {"id": "Movies", "title": "Movies"}})
	reply(menu, platform.next, {"state": "error", "server_id": "guest", "path": "Movies", "auth_required": true})
	check(menu._editor.get("id") == "guest" and menu._editor.get("connect_path") == "Movies", "A restricted share prompts even when root enumeration was public")
	menu._editor.user = "viewer"; menu._editor.password = "fixture-only"
	menu._editor_input(Menu.SAVE)
	check(platform.saves.back().id == "guest" and menu._editor_busy(), "Credentials update the same server and wait for save")
	reply(menu, platform.next, {"state": "ready", "saved_id": "guest", "servers": [saved]})
	check(menu._editor.is_empty() and platform.browses.back() == ["guest", "Movies"], "Saving login retries the originally selected share")
	reply(menu, platform.next, {"state": "error", "server_id": "guest", "path": "Movies", "auth_required": false, "error": "Timed out"})
	check(menu._editor.is_empty() and menu.status == "Timed out", "Network failure reports the connection error without asking for a password")
	menu._smb_server = ""; menu._smb_path = ""; menu._smb_servers = []
	menu._choose({"smb_found": found})
	reply(menu, platform.next, {"state": "error", "auth_required": true})
	check(menu._editor.host == "nas" and menu._editor.user.is_empty() and menu._editor.has("connect_path"), "Guest rejection opens a prefilled login")
	menu._editor_input(Menu.CANCEL)
	menu._choose({"smb_found": found}); var old := platform.next
	menu._choose({"smb_found": {"name": "Other", "host": "other"}})
	reply(menu, old, {"state": "error", "auth_required": true})
	check(menu._editor.is_empty() and menu._smb_connect.server.host == "other", "A stale discovery result cannot open a login for the wrong server")
	old = platform.next; menu.section = Menu.Section.LOCAL; menu.section = Menu.Section.SMB
	reply(menu, old, {"state": "error", "auth_required": true})
	check(menu._editor.is_empty(), "Leaving and returning to SMB retires the previous probe")
	menu._choose({"smb_found": found}); old = platform.next
	menu.dismiss(); menu.visible = true
	reply(menu, old, {"state": "error", "auth_required": true})
	check(menu._editor.is_empty(), "Closing and reopening the library retires the previous probe")
	menu._choose({"smb_found": found}); old = platform.next
	menu._choose({"smb_server": "guest"})
	reply(menu, old, {"state": "error", "auth_required": true})
	check(menu._editor.is_empty() and platform.browses.back() == ["guest", ""], "Saved servers keep their existing authentication path")
	old = platform.next
	menu._choose({"container": {"id": "Public", "title": "Public"}})
	reply(menu, old, {"state": "error", "server_id": "guest", "path": "", "auth_required": true})
	check(menu._editor.is_empty(), "An old directory failure cannot interrupt a newer directory")
	old = platform.next
	menu.dismiss(); menu.toggle()
	reply(menu, old, {"state": "error", "server_id": "guest", "path": "Public", "auth_required": true, "error": "Access denied"})
	check(menu._editor.is_empty() and menu.status == "Access denied", "An in-flight directory can finish after hiding without reopening the login")
	menu._smb_servers = [saved]; menu._smb_server = ""; menu._smb_path = ""
	var probes := platform.connects.size()
	menu._choose({"smb_found": {"name": found.name, "host": "NAS"}})
	check(platform.connects.size() == probes and platform.browses.back() == ["guest", ""], "A stale discovery row reuses an existing account case-insensitively")
	reply(menu, platform.next, {"state": "error", "server_id": "guest", "path": "", "auth_required": true})
	menu._editor.user = "viewer"; menu._editor_input(Menu.SAVE)
	old = platform.next
	menu._editor_input(Menu.CANCEL)
	reply(menu, old, {"state": "ready", "saved_id": "guest", "servers": [saved]})
	check(menu._editor.is_empty() and not menu._pending.values().has("smb_browse"), "Cancelling credential submission cannot start a late browse")
	menu._smb_server = ""; menu._smb_servers = []
	menu._choose({"smb_found": found})
	reply(menu, platform.next, {"state": "error", "auth_required": false, "error": "SMB server not responding. Refresh to retry"})
	check(menu._editor.is_empty() and menu.status.begins_with("SMB server not responding"), "A discovery timeout does not request credentials")
	menu._choose({"smb_found": found})
	reply(menu, platform.next, {"state": "error", "auth_required": true})
	menu._editor.user = "viewer"; menu._editor_input(Menu.SAVE)
	reply(menu, platform.next, {"state": "error", "error": "Save failed"})
	check(not menu._editor.is_empty() and not menu._editor_busy() and menu.status == "Save failed", "A save failure keeps the editable login for retry")
	menu._editor_input(Menu.CANCEL)
	check(platform.cancelled > 0, "Abandoned discovery probes cancel their native request")
	menu.free(); platform.free()
	print("SMB guest connect: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
