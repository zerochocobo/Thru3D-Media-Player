extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Recent := preload("res://scripts/recent_files.gd")
var checks := 0
var failures: Array[String] = []

class PlaybackMain extends "res://scripts/main.gd":
	func _show_player_menu() -> void: pass
class Viewer extends Node3D:
	var source_location := {}
	var calls := []
	func dismiss() -> void: pass
	func close_image() -> void: pass
	func close_video() -> void: pass
	func open_library(uri: String, title: String, metadata: Dictionary) -> bool:
		calls.append([uri, title, metadata]); return true
	func open_image(uri: String, title: String, queue: Array[Dictionary], location: Dictionary) -> void:
		calls.append([uri, title, queue, location])
	func start_directory(_value: Dictionary) -> void: pass
class NativeVault extends RefCounted:
	var payload := ""
	var pin := ""
	var available := true
	var stall := false
	var malformed := false
	var pending := {}
	var polls := 0
	func has_java_method(method: String) -> bool:
		return available and method in ["favorites_vault_begin", "favorites_vault_result", "favorites_vault_save", "favorites_vault_lock"]
	func favorites_vault_begin(operation: String, path: String, password: String, data: String) -> int:
		pending = {"operation":operation,"path":path,"password":password,"data":data}; polls = 0; return 1
	func favorites_vault_result(_id: int) -> String:
		polls += 1
		if stall or polls < 3: return '{"pending":true}'
		if malformed: return "broken reply"
		return favorites_vault_create(pending.path, pending.password, pending.data) if pending.operation == "create" else favorites_vault_open(pending.path, pending.password)
	func favorites_vault_create(path: String, password: String, data: String) -> String:
		payload = data; pin = password
		FileAccess.open(path, FileAccess.WRITE).store_string("encrypted test fixture")
		return JSON.stringify({"ok":true,"data":payload})
	func favorites_vault_open(_path: String, password: String) -> String:
		return JSON.stringify({"ok":true,"data":payload}) if password == pin else JSON.stringify({"error":"Incorrect password"})
	func favorites_vault_save(_path: String, data: String) -> bool: payload = data; return true
	func favorites_vault_lock() -> void: pass
class Source extends RefCounted:
	signal media_list(id: int, payload: String)
	var calls := []
	func media_local_browse(path: String) -> int: calls.append(path); return 1

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void: call_deferred("run")
func tap(menu: Node3D, id: int) -> void:
	var matches: Array = menu._buttons.filter(func(b):return b.target == id and b.node.visible)
	check(matches.size() == 1, "Target exists and is visible: " + str(id))
	if matches.size() != 1: return
	var button: Dictionary = matches[0]
	var origin: Vector3 = button.node.to_global(Vector3(0, 0, 0.6))
	var direction: Vector3 = -button.node.global_basis.z
	var target: int = int(menu.ray_hit(origin, direction).get("target", -999))
	check(target == id, "Ray reaches intended control: %d (hit %d)" % [id, target])
	if target != id: return
	menu.press_pointer("right_controller", origin, direction, true)
	menu.release_pointer("right_controller", origin, direction, true)
func enter_pin(menu: Node3D, pin: String) -> void:
	for digit in pin: tap(menu, menu.collections.KEY + int(digit))
	tap(menu, menu.collections.SUBMIT)
func settle_job(menu: Node3D) -> void:
	for frame in 300:
		if menu.collections.task < 0: return
		await process_frame
		menu.collections.poll()
	check(false, "Password task completes")
func layout_checks(menu: Node3D, store: RefCounted, recent: RefCounted) -> void:
	var source := Source.new(); menu.attach_platform(source)
	for compact in [false, true]:
		menu.set_compact(compact); menu.visible = true; menu.section = menu.Section.RECENT; menu.collections.home_tab = 1
		menu.rotation = Vector3(-0.12, 0.18, 0.03); menu.scale = Vector3.ONE * 1.07
		menu.load_view_mode("list"); menu.refresh()
		var controls: Array = menu._buttons.filter(func(b):return b.target in [menu.ROW_BASE, menu.collections.SELECT_ROW, menu.collections.DIRECTORY_ROW, menu.collections.REMOVE_ROW])
		check(not menu._buttons.any(func(b):return b.target == menu.collections.MORE), "The obsolete item-management button is gone")
		for i in controls.size():
			for j in range(i + 1, controls.size()): check(not controls[i].rect.intersects(controls[j].rect), "List body and direct actions have separate hit regions")
		tap(menu, menu.collections.DIRECTORY_ROW)
		check(menu.section == menu.Section.LOCAL and source.calls.back() == "/Series", "Dedicated directory button opens the source in either layout")
		menu.collections.action(menu.collections.RETURN_HOME)
		var checkbox: Dictionary = menu._buttons.filter(func(b):return b.target == menu.collections.SELECT_ROW)[0]
		var drag_origin: Vector3 = checkbox.node.to_global(Vector3(0, 0, 0.6))
		var drag_direction: Vector3 = -checkbox.node.global_basis.z
		menu.press_pointer("right_controller", drag_origin, drag_direction, true)
		menu.update_pointer("right_controller", drag_origin + menu.global_basis.y * 0.07, drag_direction, true)
		menu.release_pointer("right_controller", drag_origin + menu.global_basis.y * 0.07, drag_direction, true)
		check(menu.collections.selection.is_empty(), "Dragging over a checkbox scrolls without selecting")
		tap(menu, menu.collections.SELECT_ROW)
		tap(menu, menu.ROW_BASE)
		check(not menu.visible and menu.collections.selection.is_empty(), "Row body keeps opening media independently of batch checkboxes")
		menu.visible = true; menu.refresh()
		tap(menu, menu.collections.SELECT_ROW); tap(menu, menu.collections.SELECT_ROW + 1)
		check(menu.collections.selection.size() == 2, "List checkboxes support multiple favorites")
		tap(menu, menu.collections.BATCH_REMOVE)
		check(store.list_favorites().size() == 2 and menu.collections.modal == "batch_remove", "Batch opener waits for a separate confirmation")
		tap(menu, menu.collections.CANCEL)
		check(store.list_favorites().size() == 2, "Canceling a batch preserves entries")
		tap(menu, menu.collections.BATCH_REMOVE); tap(menu, menu.collections.CONFIRM_BATCH)
		check(store.list_favorites().is_empty(), "Confirmed batch removes exactly the selected favorites")
		store.restore(); menu.refresh()
		check(store.list_favorites().size() == 2, "Batch undo restores all favorites")
		menu.load_view_mode("grid"); menu.refresh()
		check(menu._buttons.filter(func(b):return b.has("collection_hover")).all(func(b):return not b.node.visible), "Grid actions stay hidden before hover")
		var tile: Dictionary = menu._buttons.filter(func(b):return b.target == menu.ROW_BASE)[0]
		var origin: Vector3 = tile.node.to_global(Vector3(0, -0.08, 0.6))
		menu.update_pointer("left_controller", origin, -tile.node.global_basis.z, true)
		menu.update_pointer("right_controller", Vector3.ZERO, Vector3.ZERO, false)
		check(menu._buttons.filter(func(b):return b.has("collection_hover") and b.collection_hover == menu.ROW_BASE).all(func(b):return b.node.visible), "Other hand leaving cannot hide the active card's controls")
		tap(menu, menu.collections.DIRECTORY_ROW)
		check(menu.section == menu.Section.LOCAL, "Hover directory action receives the ray in either layout")
		menu.collections.action(menu.collections.RETURN_HOME)
	menu.rotation = Vector3.ZERO; menu.scale = Vector3.ONE
	menu.set_compact(false); menu.collections.switch_tab(0); menu.load_view_mode("list")
	for i in 2: recent.opened("file:///Series/%d.mp4" % i, "Recent %d" % i, false)
	recent.save(); menu.refresh()
	tap(menu, menu.collections.SELECT_ROW); tap(menu, menu.collections.SELECT_ROW + 1)
	tap(menu, menu.collections.BATCH_REMOVE)
	check(not menu.collections.active(), "Recent bulk removal uses undo without a full-screen confirmation")
	check(recent.list_recent().is_empty() and store.list_favorites().size() == 2, "Batch recent removal preserves favorites")
	tap(menu, menu.collections.UNDO)
	check(recent.list_recent().size() == 2, "Recent batch undo restores every selected record")
	menu.load_view_mode("grid"); menu.refresh()
	var recent_tile: Dictionary = menu._buttons.filter(func(b):return b.target == menu.ROW_BASE)[0]
	menu.update_pointer("right_controller", recent_tile.node.to_global(Vector3(0, -0.08, 0.6)), -recent_tile.node.global_basis.z, true)
	check(menu._tips[menu.collections.REMOVE_ROW] == "Remove from recent", "Recent hover action is labeled as removing a record")
	tap(menu, menu.collections.REMOVE_ROW)
	check(recent.list_recent().size() == 1 and store.list_favorites().size() == 2, "Recent hover deletion affects history alone")
	tap(menu, menu.collections.UNDO)
	check(recent.list_recent().size() == 2, "Recent hover deletion can be undone")
	menu.load_view_mode("list"); menu.refresh()
	tap(menu, menu.collections.SELECT_ROW)
	check(menu.navigate_back() and menu.collections.selection.is_empty(), "Back clears selection before navigating away")
	tap(menu, menu.collections.SELECT_ROW); menu._activate(menu.FILTER_BASE + 1)
	check(menu.collections.selection.is_empty(), "Changing filters clears the previous selection")
	menu._activate(menu.NAV_BASE + menu.Section.SETTINGS)
	check(not menu.SETTING_TABS.has("Privacy") and menu.SETTING_ORDER.size() == 6, "Privacy does not occupy a top tab")
	check(menu.rows.size() == 4 and not menu.rows.any(func(row):return row.get("key") == "privacy_mode"), "General starts with a collapsed Privacy group")
	for compact in [false, true]:
		menu.set_compact(compact); menu.collections.privacy_expanded = false; menu.scroll = 0; menu.refresh()
		var privacy_index: int = menu.rows.find(menu.rows.filter(func(row):return row.get("group_header", false))[0])
		tap(menu, menu.ROW_BASE + privacy_index)
		check(menu.rows[privacy_index + 1].get("key") == "privacy_mode" and menu.rows[privacy_index + 2].get("privacy_action") == "enable", "Password is the second function in the expanded Privacy group")
		var password_slot: int = privacy_index + 2 - menu._first_line()
		check(password_slot >= 0 and password_slot < menu._lines(), "Expanding Privacy reveals the password action without extra scrolling")
		tap(menu, menu.ROW_BASE + password_slot)
		check(menu.collections.stage == "new" and menu.collections.active(), "The visible password action opens PIN setup")
		tap(menu, menu.collections.CANCEL)
		check(menu.text_snapshot().contains("Set favorites password"), "Cancel returns to the visible password setting")
	menu.set_compact(false)
	menu.attach_platform(null)

func folder_checks(menu: Node3D, store: RefCounted) -> void:
	var source := Source.new(); menu.attach_platform(source)
	for compact in [false, true]:
		menu.set_compact(compact); menu.section = menu.Section.LOCAL; menu.visible = true
		menu._local_stack = [{"id":"/Series","title":"Series"}]
		menu._local_volumes = [{"id":"/usb","title":"USB drive","removable":true}]
		menu.refresh()
		var location: Dictionary = menu.collections.Location.capture(menu, {})
		var uri: String = menu.collections.Location.folder_uri(location)
		var star: Dictionary = menu._buttons.filter(func(button):return button.target == menu.collections.FAVORITE_FOLDER)[0]
		for button in menu._buttons:
			if button.target in [menu.USB_STORAGE, menu.EJECT_STORAGE, menu.REFRESH, menu.file_actions.SORT, menu.CLOSE]:
				check(not star.rect.intersects(button.rect), "Folder favorite avoids USB and other toolbar controls")
		tap(menu, menu.collections.FAVORITE_FOLDER)
		check(store.contains(uri) and Favorites.new(store.directory).contains(uri), "Folder favorite saves and survives restart")
		check(store.lookup(uri).title == "Series", "Folder favorites persist their actual directory name")
		check(menu._tips[menu.collections.FAVORITE_FOLDER] == "Remove favorite", "Folder favorite reflects its selected state")
		tap(menu, menu.collections.FAVORITE_FOLDER)
		check(not store.contains(uri), "Folder favorite can be toggled off")
		tap(menu, menu.collections.FAVORITE_FOLDER)
		menu.section = menu.Section.RECENT; menu.collections.home_tab = 1; menu.media_filter = 0; menu.refresh()
		store.entries[store.key_for(uri)].title = "Local files"
		for mode in ["list", "grid"]:
			menu.load_view_mode(mode); menu.refresh()
			var index: int = menu.rows.find(menu.rows.filter(func(row):return row.get("uri") == uri)[0])
			check(menu.rows[index].title == "Series" and menu.Presentation.info(menu.rows[index], menu.catalog, true).subtitle == "/Series", "Existing folder favorites recover a useful name and path from their stored location")
			check(not menu._buttons.any(func(button):return button.target == menu.collections.DIRECTORY_ROW + index), "Folder favorites omit the duplicate directory action in either view")
			if mode == "grid":
				var tile: Dictionary = menu._buttons.filter(func(button):return button.target == menu.ROW_BASE + index)[0]
				menu.update_pointer("right_controller", tile.node.to_global(Vector3(0, -0.08, 0.6)), -tile.node.global_basis.z, true)
				check(menu._buttons.filter(func(button):return button.get("collection_hover", -1) == menu.ROW_BASE + index and button.node.visible).size() == 2, "Folder hover offers only Open and Remove favorite")
				tap(menu, menu.collections.PLAY_ROW + index)
			else:
				var controls: Array = menu._buttons.filter(func(button):return button.target in [menu.ROW_BASE + index, menu.collections.SELECT_ROW + index, menu.collections.REMOVE_ROW + index])
				for i in controls.size():
					for j in range(i + 1, controls.size()): check(not controls[i].rect.intersects(controls[j].rect), "Wider folder rows keep independent checkbox and star hit regions")
				tap(menu, menu.ROW_BASE + index)
			check(menu.section == menu.Section.LOCAL and source.calls.back() == "/Series", "Folder body and the remaining hover action open the saved directory")
			menu.collections.action(menu.collections.RETURN_HOME)
		store.remove(uri)
	menu._local_volumes = []; menu.set_compact(false); menu.attach_platform(null)
	menu.section = menu.Section.RECENT; menu.collections.home_tab = 1; menu.visible = true; menu.refresh()
func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var folder := ProjectSettings.globalize_path("res://../../build/output/collection-interactions/" + str(Time.get_ticks_usec()))
	var store := Favorites.new(folder)
	var recent := Recent.new(folder.path_join("recent"))
	for item in [["file:///Series/episode.mp4", "Episode", "video"], ["file:///Series/photo.jpg", "Photo", "image"]]:
		store.toggle(item[0], item[1], item[2])
	var menu := Library.new(); root.add_child(menu); menu.visible = true
	menu.collections.store = store; menu.catalog = recent; menu.collections.home_tab = 1
	var main := PlaybackMain.new(); main.recent_menu = menu
	var video := Viewer.new(); var photo := Viewer.new(); var controls := Viewer.new()
	main.video = video; main.photo = photo; main.video_menu = controls; main.photo_menu = controls
	menu.chosen.connect(main._on_library_chosen)
	for mode in ["list", "grid"]:
		for uri in ["file:///Series/episode.mp4", "file:///Series/photo.jpg"]:
			menu.visible = true; menu.load_view_mode(mode); menu.refresh()
			var index: int = menu.rows.find(menu.rows.filter(func(row):return row.get("uri") == uri)[0])
			var viewer: Node3D = photo if uri.ends_with("jpg") else video
			var before: int = viewer.calls.size()
			tap(menu, menu.ROW_BASE + index)
			check(viewer.calls.size() == before + 1 and viewer.calls.back()[0] == uri, "Favorite click dispatches media: " + mode + "/" + uri)
	menu.visible = true; menu.load_view_mode("grid"); menu.refresh()
	var tile: Dictionary = menu._buttons.filter(func(b):return b.target == menu.ROW_BASE)[0]
	menu.update_pointer("right_controller", tile.node.to_global(Vector3(0, -0.08, 0.6)), -tile.node.global_basis.z, true)
	check(menu._buttons.any(func(b):return b.target == menu.collections.REMOVE_ROW and b.node.visible), "Hover exposes grid actions")
	var actions: Array = [menu.collections.PLAY_ROW, menu.collections.DIRECTORY_ROW, menu.collections.REMOVE_ROW].map(func(id):return menu._buttons.filter(func(b):return b.target == id)[0])
	check(actions[0].rect.get_center().x < actions[1].rect.get_center().x and actions[1].rect.get_center().x < actions[2].rect.get_center().x, "Hover actions are ordered Play, Directory, Remove")
	check(actions.all(func(button):return not str(menu._tips.get(button.target, "")).is_empty()), "Every hover action has a tooltip")
	var toggled_uri: String = str(menu.rows[0].uri)
	var added: float = float(menu.rows[0].added)
	tap(menu, menu.collections.REMOVE_ROW)
	check(store.list_favorites().size() == 1, "Grid removal works through a real ray click")
	check(menu.rows.size() == 2 and menu.rows[0].get("pending_unfavorite", false), "Unfavorited card remains briefly for an immediate toggle back")
	check(menu._tips[menu.collections.REMOVE_ROW] == "Restore favorite", "Empty-star tooltip offers to restore the favorite")
	var toggle_button: Dictionary = menu._buttons.filter(func(b):return b.target == menu.collections.REMOVE_ROW)[0]
	menu.update_pointer("right_controller", toggle_button.node.to_global(Vector3(0, 0, 0.6)), -toggle_button.node.global_basis.z, true)
	tap(menu, menu.collections.REMOVE_ROW)
	check(store.contains(toggled_uri) and float(store.lookup(toggled_uri).added) == added, "Clicking the empty star restores the original favorite and ordering")
	check(not store.can_undo(), "Toggling back clears the now-redundant removal undo")
	toggle_button = menu._buttons.filter(func(b):return b.target == menu.collections.REMOVE_ROW)[0]
	menu.update_pointer("right_controller", toggle_button.node.to_global(Vector3(0, 0, 0.6)), -toggle_button.node.global_basis.z, true)
	tap(menu, menu.collections.REMOVE_ROW)
	toggle_button = menu._buttons.filter(func(b):return b.target == menu.collections.REMOVE_ROW)[0]
	var stale_origin: Vector3 = toggle_button.node.to_global(Vector3(0, 0, 0.6))
	var stale_direction: Vector3 = -toggle_button.node.global_basis.z
	menu.press_pointer("right_controller", stale_origin, stale_direction, true)
	menu.collections._expire_pending(Time.get_ticks_msec() + 8001); menu.refresh()
	menu.release_pointer("right_controller", stale_origin, stale_direction, true)
	check(store.list_favorites().size() == 1, "Expiring a recovery card during a press cannot remove the next card")
	check(menu.rows.size() == 1 and not Favorites.new(folder).contains(toggled_uri), "Expired recovery card disappears while the removal was already persisted")
	store.restore(); menu.refresh()
	layout_checks(menu, store, recent)
	folder_checks(menu, store)
	menu.section = menu.Section.RECENT; menu.collections.switch_tab(1); menu.media_filter = 0
	store.toggle("https://example.invalid/stream", "Stream", "video"); menu.load_view_mode("grid"); menu.refresh()
	var web_index: int = menu.rows.find(menu.rows.filter(func(row):return row.get("uri") == "https://example.invalid/stream")[0])
	var web_tile: Dictionary = menu._buttons.filter(func(b):return b.target == menu.ROW_BASE + web_index)[0]
	menu.update_pointer("right_controller", web_tile.node.to_global(Vector3(0, -0.08, 0.6)), -web_tile.node.global_basis.z, true)
	var before_web: int = video.calls.size()
	tap(menu, menu.collections.DIRECTORY_ROW + web_index)
	check(menu.visible and video.calls.size() == before_web, "Disabled directory action blocks click-through to Play")
	store.remove("https://example.invalid/stream")
	var folder_location := {"type":"local", "path":"/Series"}
	var folder_uri: String = menu.collections.Location.folder_uri(folder_location)
	store.toggle(folder_uri, "Series", "folder", folder_location)
	menu.media_filter = 2; menu.refresh()
	check(menu.rows.any(func(row):return row.get("kind") == "folder"), "Media filters keep favorite folder shortcuts")
	store.remove(folder_uri); menu.media_filter = 0; menu.refresh()
	var backend := NativeVault.new(); store.platform = backend
	menu.collections.open_password("enable")
	check(menu.text_snapshot().contains("1/2") and menu.text_snapshot().contains("Next step"), "PIN setup first explains that another step follows")
	enter_pin(menu, "0123")
	check(menu.collections.stage == "confirm" and menu.collections.text.is_empty() and not store.busy and backend.pending.is_empty(), "The first step only requests the same PIN again without starting a background task")
	check(menu.text_snapshot().contains("Enter PIN again") and menu.text_snapshot().contains("2/2") and menu.text_snapshot().contains("Save password"), "The second step clearly requests PIN re-entry before saving")
	check(menu._buttons.filter(func(button):return button.target >= menu.collections.KEY and button.target < menu.collections.KEY + 10).all(func(button):return button.enabled), "The second-step keypad remains usable after clearing the first PIN")
	enter_pin(menu, "9999")
	check(menu.collections.stage == "new" and menu.collections.message == "Passwords do not match" and backend.pending.is_empty(), "A mismatch explains the retry and never saves a different PIN")
	enter_pin(menu, "0123"); enter_pin(menu, "0123"); await settle_job(menu)
	check(store.protected and not store.locked and not menu.collections.active(), "Confirmed PIN saves protection and closes the dialog")
	check(not FileAccess.file_exists(folder.path_join("favorites.json")), "Success removes plaintext catalog")
	menu.load_view_mode("list"); menu.refresh(); tap(menu, menu.collections.SELECT_ROW)
	tap(menu, menu.collections.BATCH_REMOVE); store.lock()
	check(menu.collections.selection.is_empty() and menu.collections.batch.is_empty() and not menu.collections.active(), "Lock clears pending batch data and closes its dialog")
	for compact in [false, true]:
		menu.set_compact(compact)
		for mode in ["list", "grid"]:
			menu.load_view_mode(mode); menu.refresh()
			check(menu.rows.size() == 1 and menu.rows[0].get("unlock_favorites", false) and not menu.rows[0].has("uri"), "Locked favorites expose only an unlock prompt without private entries")
			check(menu.Presentation.info(menu.rows[0], menu.catalog, true).subtitle.is_empty() and not menu._buttons.any(func(button):return menu.collections.row_target(button.target)), "Locked favorites have neither a fake Local files source nor item actions")
			var prompt: Dictionary = menu._buttons.filter(func(button):return button.target == menu.ROW_BASE)[0]
			check(prompt.node.get_children().filter(func(child):return child is Label3D).all(func(label):return label.text != "Local files"), "The rendered unlock prompt omits Local files in every layout")
			tap(menu, menu.ROW_BASE)
			check(menu.collections.operation == "unlock" and menu.collections.active(), "The locked prompt opens the PIN dialog through a real ray click")
			tap(menu, menu.collections.CANCEL)
	menu.set_compact(false); menu.load_view_mode("list"); menu.refresh()
	menu.collections.open_password("unlock")
	FileAccess.open(folder.path_join("favorites.json"), FileAccess.WRITE).store_string("interrupted plaintext fixture")
	enter_pin(menu, "9999"); await settle_job(menu)
	check(store.locked and menu.collections.active() and not menu.collections.message.is_empty(), "Wrong PIN remains locked with retry feedback")
	enter_pin(menu, "0123"); await settle_job(menu)
	check(not store.locked and not menu.collections.active(), "Correct retry unlocks and closes without Cancel")
	check(not FileAccess.file_exists(folder.path_join("favorites.json")), "Unlock cleans a plaintext remnant from an interrupted enable")
	menu.collections.open_password("change_verify"); enter_pin(menu, "0123"); await settle_job(menu)
	check(menu.collections.stage == "new", "Changing PIN first verifies the previous PIN")
	enter_pin(menu, "9876"); enter_pin(menu, "9876"); await settle_job(menu)
	check(backend.pin == "9876" and not menu.collections.active(), "Changing PIN saves and closes")
	menu.collections.open_password("disable"); enter_pin(menu, "9876"); await settle_job(menu)
	check(not store.protected and FileAccess.file_exists(folder.path_join("favorites.json")) and not menu.collections.active(), "Disabling PIN closes after writing the unprotected catalog")
	backend.stall = true
	var callbacks := []
	menu.collections.open_password("enable", func():callbacks.append(true))
	enter_pin(menu, "0123"); enter_pin(menu, "0123")
	menu.collections.task_started -= 16000; menu.collections.poll()
	check(store.busy and menu.collections.message == "Still processing. You can return.", "A slow native task has visible recovery feedback")
	tap(menu, menu.collections.CANCEL)
	check(not menu.collections.active() and menu.collections.task >= 0, "Return remains usable while native derivation is pending")
	backend.stall = false; await settle_job(menu)
	check(store.protected and not store.busy and not menu.collections.active() and callbacks.is_empty(), "A late result settles safely without reopening a dismissed dialog or invoking its callback")
	store.lock(); backend.malformed = true; menu.collections.open_password("unlock")
	enter_pin(menu, "0123"); await settle_job(menu)
	check(not store.busy and store.locked and menu.collections.active(), "Malformed native results restore an interactive locked dialog")
	backend.malformed = false; enter_pin(menu, "0123"); await settle_job(menu)
	check(not store.locked and not menu.collections.active(), "Retry after a malformed result succeeds")
	backend.available = false
	check(store.begin_password("unlock", "0123") < 0 and not store.busy, "An unavailable JNI service never traps the dialog in busy state")
	menu.queue_free(); main.free(); video.free(); photo.free(); controls.free()
	await process_frame
	print("Collection interactions: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
