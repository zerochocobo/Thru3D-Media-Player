extends SceneTree
const Favorites := preload("res://scripts/favorite_store.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Location := preload("res://scripts/media_location.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
var checks := 0
var failures: Array[String] = []

class Vault extends RefCounted:
	var data := ""
	var is_locked := false
	var can_save := true
	func favorites_vault_save(_path: String, text: String) -> bool:
		if not can_save: return false
		data = text; return true
	func favorites_vault_lock() -> void: is_locked = true

class Platform extends RefCounted:
	signal media_list(id: int, json: String)
	var calls := []
	func media_local_browse(path: String) -> int: calls.append(["local", path]); return 1
	func media_smb_browse(id: String, path: String) -> int: calls.append(["smb", id, path]); return 2
	func media_dlna_browse(id: String, path: String) -> int: calls.append(["dlna", id, path]); return 3

class NarrationMemory extends RefCounted:
	var memory := preload("res://scripts/file_narration_memory.gd").new()

class ListeningMemory extends RefCounted:
	var memory := preload("res://scripts/file_listening_memory.gd").new()

class MigrationViewer extends Node3D:
	var recent_files: RefCounted
	var mode_memory := Memory.new()
	var track_memory := Memory.new()
	var subtitle_timing := Memory.new()
	var subtitle_encoding := preload("res://scripts/file_subtitle_encoding.gd").new()
	var whisper_memory := preload("res://scripts/file_whisper_memory.gd").new()
	var narration := NarrationMemory.new()
	var listening := ListeningMemory.new()

func _legacy_recent(uri: String) -> Dictionary:
	return {"uri":uri,"title":"Older playback","kind":"video","persisted":false,"opened":1,"opened_at":100.0,"position_ms":1234,"duration_ms":60000}

func _check_history_independence(directory: String) -> void:
	var store := Favorites.new(directory.path_join("separate-favorites")); store.platform = Vault.new(); store.protected = true
	var recent := Recent.new(directory.path_join("separate-recent"))
	var a := "file:///Series/favorite.mp4"; var b := "smb://nas/Series/ordinary.mp4"
	store.toggle(a, "Favorite", "video"); Privacy.vault = store; Privacy.configure("all")
	var saved := store.entries.duplicate(true); store.lock()
	check(recent.opened(a, "Favorite", false) and recent.progress(a, 2222, 60000) and recent.opened(b, "Ordinary", false) and recent.save(), "A locked favorite list cannot block favorite or ordinary playback history")
	var reloaded := Recent.new(recent.directory); reloaded.load_saved()
	check(reloaded.resume_position(a) == 2222 and reloaded.list_recent().size() == 2, "Recent names and resume positions survive restart while favorites remain locked")
	reloaded.set_location(a, Location.infer(a)); check(reloaded.set_cover(a, "https://example.invalid/cover.jpg") and reloaded.save(), "A locked favorite list cannot block recent directory and cover metadata")
	Privacy.configure("local")
	check(not reloaded.opened("https://example.invalid/network.mp4", "Network", false) and reloaded.opened("file:///ordinary.jpg", "Image", false, "image"), "Independent recent recording still honors local-only privacy")
	Privacy.configure("none")
	check(not reloaded.opened("file:///blocked.mp4", "Blocked", false) and not reloaded.progress(a, 9999, 60000) and reloaded.resume_position(a) == 2222, "Do-not-record blocks new opens and progress independently of the favorite lock")
	Privacy.configure("all"); store.entries = saved; store.locked = false
	store.private_remember(a, "recent", _legacy_recent(a))
	var legacy_uri := "file:///Series/legacy.mp4"; store.toggle(legacy_uri, "Legacy", "video"); store.private_remember(legacy_uri, "recent", _legacy_recent(legacy_uri))
	var unwritable := Recent.new(directory.path_join("cannot-migrate")); unwritable.read_only = true
	check(not unwritable.import_legacy(store) and not store.private_lookup(legacy_uri, "recent").is_empty(), "A failed recent-bank write preserves encrypted legacy history for retry")
	store.platform.can_save = false
	check(not reloaded.import_legacy(store) and not store.private_lookup(a, "recent").is_empty() and not store.private_lookup(legacy_uri, "recent").is_empty(), "A failed vault cleanup retains all legacy records without a partial batch")
	store.platform.can_save = true
	check(reloaded.import_legacy(store) and reloaded.resume_position(a) == 2222 and reloaded.resume_position(legacy_uri) == 1234, "Unlock imports old encrypted history without replacing newer independent progress")
	check(store.private_lookup(a, "recent").is_empty() and store.private_lookup(legacy_uri, "recent").is_empty() and store.contains(a), "Successful import removes legacy copies without removing favorites")
	var main := preload("res://scripts/main.gd").new(); var viewer := MigrationViewer.new(); var photo := MigrationViewer.new()
	viewer.recent_files = reloaded
	for memory in [viewer.mode_memory, viewer.track_memory, viewer.subtitle_timing, viewer.whisper_memory, photo.mode_memory]: memory.directory = directory.path_join(str(memory.get_instance_id()))
	viewer.mode_memory.entries[Memory.key_for(a)] = {"mode":{"geometry":0},"updated":1}
	viewer.whisper_memory.entries[Memory.key_for(a)] = {"whisper":{"level":2},"updated":1}
	main.video = viewer; main.photo = photo; main.favorites = store
	main._migrate_protected_favorites()
	check(reloaded.resume_position(a) == 2222 and not reloaded.entries.is_empty() and store.private_lookup(a, "recent").is_empty(), "Main's favorite migration never drains independent recent banks")
	check(viewer.whisper_memory.entries.is_empty() and store.private_lookup(a, viewer.whisper_memory.directory.get_file() + "/whisper") == {"level":2}, "Whisper preference migrates into the protected favorite vault")
	main.free(); viewer.free(); photo.free()
	store.private_remember(a, "recent", _legacy_recent(a)); store.private_remember(legacy_uri, "recent", _legacy_recent(legacy_uri))
	var deletions := Recent.new(directory.path_join("deleted-before-unlock")); deletions.opened(a, "Favorite", false); deletions.save()
	saved = store.entries.duplicate(true); store.lock()
	check(deletions.forget(a) and deletions.purge_keys([]), "Recent deletion remains available while favorites are locked")
	var after_delete := Recent.new(deletions.directory); after_delete.load_saved(); store.entries = saved; store.locked = false
	check(after_delete.import_legacy(store) and after_delete.lookup(a).is_empty() and not after_delete.lookup(legacy_uri).is_empty(), "Restart and unlock cannot resurrect an individually deleted recent item during legacy import")
	store.private_remember(a, "recent", _legacy_recent(a)); saved = store.entries.duplicate(true); store.lock()
	check(after_delete.clear_all() and after_delete.purge_keys([]), "Recent clear-all needs no favorite password")
	var after_clear := Recent.new(after_delete.directory); after_clear.load_saved(); store.entries = saved; store.locked = false
	check(after_clear.import_legacy(store) and after_clear.list_recent().is_empty() and store.contains(a), "Unlock after clear-all cannot restore old history or erase favorites")
	Privacy.vault = null; Privacy.configure("all")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _check_popup_layers() -> void:
	for mode in ["video", "photo-static", "photo-spatial", "native-static", "native-spatial", "photo-portrait"]:
		var script: GDScript = Player if mode == "video" else PhotoMenu
		var control: Node3D = script.new(); root.add_child(control); control.set_process(false); control.visible = true
		var native: bool = mode.begins_with("native-")
		var spatial: bool = mode.ends_with("spatial")
		var rail: bool = not native and not spatial
		control.state_provider = func():return {"has_video":mode == "video","has_image":mode != "video","geometry":0,"depth_available":not native,
			"depth_requested":not native,"depth_enabled":not native,"depth_strength":1.0,"layout":0,
			"native_stereo":native,"spatial_preferred":spatial,"portrait_requested":mode == "photo-portrait"}
		var favorite := {"enabled":true,"selected":false,"locked":false}
		control.favorite_provider = func():return favorite
		var stars := []; var strengths := []; var actions := []
		control.favorite_requested.connect(func():stars.append(true))
		control.depth_strength_requested.connect(func(value):strengths.append(value))
		control.action_requested.connect(func(value):actions.append(value))
		for selected in [false, true]:
			favorite.selected = selected
			for angled in [false, true]:
				var context := "%s/selected=%s/angled=%s" % [mode, selected, angled]
				control.rotation = Vector3(-0.15, 0.2, 0.03) if angled else Vector3.ZERO
				control.scale = Vector3.ONE * (1.15 if angled else 1.0)
				control._depth_open = false; control._icon_tap.clear(); control.refresh()
				var icons: Array = control._buttons.filter(func(button):return button.target == control._depth_icon_target())
				check(icons.size() == 1 and icons[0].enabled, "Depth/viewing entry is available for the current mode: " + context)
				if icons.size() != 1: continue
				var icon: Dictionary = icons[0]
				var icon_ray: Vector3 = icon.node.to_global(Vector3(0, 0, 0.7))
				control.press_pointer("right_hand", icon_ray, -icon.node.global_basis.z, true)
				control.release_pointer("right_hand", icon_ray, -control.global_basis.z, true)
				check(control._depth_open, "Production ray opens the current depth/viewing popup: " + context)
				var target: int = control.DEPTH if rail else PhotoMenu.PHOTO_SPATIAL
				var sliders: Array = control._buttons.filter(func(button):return button.target == target)
				check(sliders.size() == 1 and sliders[0].enabled, "Current mode provides its enabled popup control: " + context)
				if sliders.size() != 1: continue
				check(control._buttons.any(func(button):return button.target == control.DEPTH) == rail, "Only adjustable modes expose a depth rail: " + context)
				var slider: Dictionary = sliders[0]
				var favorites: Array = control._buttons.filter(func(button):return button.target == control.FAVORITE)
				check(favorites.size() == 1 and favorites[0].enabled, "Favorite remains present beneath the popup: " + context)
				if favorites.size() != 1: continue
				var star: Dictionary = favorites[0]
				var overlap: Rect2 = slider.rect.intersection(star.rect)
				check(overlap.has_area(), "Fixture exercises real popup/favorite overlap: " + context)
				var origin: Vector3 = control.to_global(Vector3(overlap.get_center().x, overlap.get_center().y, 0.7))
				var direction: Vector3 = -control.global_basis.z
				check(control.ray_hit(origin, direction).get("target") == target, "Popup control wins over the overlapping favorite: " + context)
				check(slider.node.position.z > star.node.position.z and slider.node.material_override.render_priority > star.node.material_override.render_priority, "Popup is in front for both pixels and ray hits: " + context)
				var blank: Variant = null
				for y in range(1, 10):
					for x in range(1, 10):
						var point: Vector2 = star.rect.position + star.rect.size * Vector2(x, y) / 10
						var candidate: Vector3 = control.to_global(Vector3(point.x, point.y, 0.7))
						if control.ray_hit(candidate, direction).get("target", -999) == control.NONE: blank = candidate; break
					if blank != null: break
				check(blank != null, "Popup background blocks the favorite outside its controls: " + context)
				var popup_z: float = slider.node.position.z
				strengths.clear(); actions.clear()
				control.press_pointer("right_hand", origin, direction, true)
				if rail:
					check(stars.is_empty() and not strengths.is_empty(), "Pressing the overlap adjusts depth without changing favorite state: " + context)
					var span: Vector2 = control._depth_span()
					# Avoid a 1% rounding midpoint: oblique ray transforms introduce float noise.
					var drag_y := lerpf(span.x, span.y, 0.6)
					var endpoint: Vector3 = control.to_global(Vector3(control.DEPTH_X, drag_y, popup_z))
					var drag_origin: Vector3 = endpoint + control.global_basis * Vector3(0.16, 0.12, 0.7)
					control.update_pointer("right_hand", drag_origin, endpoint - drag_origin, true)
					check(not strengths.is_empty() and is_equal_approx(float(strengths.back()), control.DepthStrength.from_fraction(0.6, control._depth_track_maximum())), "Oblique dragging uses the current mode's raised slider and actual range: " + context)
					control.release_pointer("right_hand", drag_origin, endpoint - drag_origin, true)
				else:
					control.release_pointer("right_hand", origin, direction, true)
					check(stars.is_empty() and strengths.is_empty() and actions == ["photo_spatial_on"], "Viewing option consumes overlap without changing favorites or depth: " + context)
				control._depth_open = false; control.refresh()
				check(control.ray_hit(origin, direction).get("target") == control.FAVORITE, "Closing the popup makes the previously covered favorite reachable: " + context)
				if blank != null: check(control.ray_hit(blank, direction).get("target") == control.FAVORITE, "Closing the popup removes its background blocker over the favorite: " + context)
		control.free()

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	Privacy.vault = null; Privacy.configure("all")
	var directory := ProjectSettings.globalize_path("res://../../build/output/collection-tests/" + str(Time.get_ticks_usec()))
	var store := Favorites.new(directory)
	var first := "file:///storage/emulated/0/Series/01.mp4"
	for i in 48: check(store.toggle("file:///movies/%d.mp4" % i, "Movie %d" % i, "video"), "Favorite saves without recent-history eviction")
	check(store.list_favorites().size() == 48, "Favorites survive the 32-item history limit")
	check(store.toggle(first, "First episode", "video", Location.infer(first)), "Favorite stores source location")
	var restored := Favorites.new(directory)
	check(restored.contains(first) and restored.lookup(first).location.path == "/storage/emulated/0/Series", "Restart restores stable source and identity")
	check(store.remove(first) and not store.contains(first) and store.restore() and store.contains(first), "Single removal can be undone")
	check(store.relocate(first, "file:///storage/emulated/0/Series/001.mp4", "Renamed") and not store.contains(first), "Rename migrates favorite identity")
	check(Location.infer("https://example.invalid/01.mp4").is_empty(), "An arbitrary web URL has no invented parent browser")
	check(Location.infer("smb://server/Series/01.mp4").path == "Series", "SMB parent retains server identity")
	check(Location.infer("cloud://account/Series/01.mp4").path == "/account/Series", "Cloud parent uses the native browser's mount path")
	check(Location.infer("cloud://account/%E5%89%A7%E9%9B%86/01.mp4").path == "/account/剧集", "Cloud parent decodes path components once")
	check(Location.clean({"type":"smb","server_id":"a","path":"p","password":"secret","token":"private"}) == {"type":"smb","server_id":"a","path":"p"}, "Source location excludes credentials")
	var cloud_location := Location.clean({"type":"cloud", "path":"/account/Movies", "stack":[{"id":"/account/Movies", "title":"Movies", "cloud_id":"9007199254740993", "token":"private"}]})
	var cloud_restored := Location.clean(JSON.parse_string(JSON.stringify(cloud_location)))
	check(cloud_restored.stack.back().get("cloud_id") == "9007199254740993" and not cloud_restored.stack.back().has("token"), "Cloud folder IDs survive persisted location cleaning without credentials")
	for bad_id in ["", "x".repeat(2049), "bad\nid", "https://example.invalid/?token=private", 123]:
		check(not Location.clean({"type":"cloud", "path":"/account/Movies", "stack":[{"id":"/account/Movies", "title":"Movies", "cloud_id":bad_id}]}).stack.back().has("cloud_id"), "Malformed cloud identity stays out of saved locations")
	check(Location.folder_uri({"type":"local","path":"/Series","stack":[{"id":"/Series","title":"Old name"}]}) == Location.folder_uri({"type":"local","path":"/Series","stack":[{"id":"/Series","title":"New display name"}]}), "Directory favorite identity ignores display labels")
	check(Location.folder_title({"type":"local","path":"/Movies/Series","stack":[{"id":"/Movies","title":"Movies"},{"id":"/Movies/Series","title":"Series"}]}, "Local files") == "Series", "Directory names use the current folder rather than a source label or full breadcrumb")
	check(Location.folder_title({"type":"smb","server_id":"nas","path":"Movies/Series"}, "SMB") == "Series", "A directory without a saved breadcrumb derives its real name from the path")
	check(Location.folder_title({"type":"dlna","server_id":"nas","stack":[{"id":"id7","title":"Series"}]}, "DLNA") == "Series", "Opaque network directory identifiers retain their display names")
	var favorite_info: Dictionary = Library.Presentation.info({"title":"Series","kind":"folder","uri":"folder://opaque","location":{"type":"local","path":"/Movies/Series"},"position_ms":5000,"duration_ms":10000}, null, true)
	check(favorite_info.folder and favorite_info.subtitle == "/Movies/Series" and favorite_info.status.is_empty() and favorite_info.badge.is_empty() and favorite_info.ratio < 0, "Folder favorites display their path without fake media source, duration or progress")
	check(Library.Presentation.info({"title":"Unlock favorites","icon":"lock","unlock_favorites":true}, null, true).subtitle.is_empty(), "A locked-collection prompt has no invented Local files subtitle")
	check(Location.folder_path({"type":"local","path":"content://provider/tree/opaque","stack":[{"id":"opaque","title":"USB drive"},{"id":"opaque-child","title":"Series"}]}) == "USB drive / Series", "USB and document directories show readable breadcrumbs instead of opaque provider URIs")
	var damaged_path := directory.path_join("damaged")
	DirAccess.make_dir_recursive_absolute(damaged_path)
	FileAccess.open(damaged_path.path_join("favorites.json"), FileAccess.WRITE).store_string("{broken")
	var damaged := Favorites.new(damaged_path)
	check(damaged.read_only and not damaged.toggle(first, "Replacement", "video") and FileAccess.get_file_as_string(damaged_path.path_join("favorites.json")) == "{broken", "Damaged favorites are preserved without silent replacement")
	check(damaged.begin_password("enable", "1234") < 0 and damaged.last_error == "Favorites unavailable", "Enabling protection cannot overwrite a damaged plaintext collection")
	var reset_path := directory.path_join("reset")
	DirAccess.make_dir_recursive_absolute(reset_path)
	FileAccess.open(reset_path.path_join("favorites.vault"), FileAccess.WRITE).store_string("damaged vault")
	FileAccess.open(reset_path.path_join("favorites.json"), FileAccess.WRITE).store_string("{broken")
	FileAccess.open(reset_path.path_join("original.mp4"), FileAccess.WRITE).store_string("fixture")
	var reset_store := Favorites.new(reset_path)
	check(reset_store.locked and reset_store.entries.is_empty(), "An encrypted collection never falls back to a remaining plaintext copy")
	check(reset_store.reset_locked() and not FileAccess.file_exists(reset_path.path_join("favorites.vault")) and FileAccess.file_exists(reset_path.path_join("original.mp4")), "Explicit reset clears locked collection while preserving source files")
	Privacy.configure("local")
	check(Privacy.record_allowed(first) and not Privacy.record_allowed("smb://server/01.mp4"), "Local-only policy gates network sources")
	check(Privacy.record_allowed("usb://session/0-2048/movie.mkv") and not Privacy.record_allowed("usb://session/0-2048/movie.strm"), "USB videos are local while USB shortcuts retain the target-source policy")
	check(not Privacy.record_allowed("file:///storage/movie.strm") and not Privacy.record_allowed("content://remote.provider/1"), "Shortcuts and unknown content providers cannot bypass local-only policy")
	Privacy.configure("none")
	var memory := Memory.new(directory.path_join("settings"))
	var file_mode := {"geometry":0,"stereo_sbs":false,"swap_eyes":false,"alpha_requested":false,"profile":"320x320"}
	check(memory.remember(first, file_mode) and memory.save(), "Disabled history still permits independent per-file preferences")
	Privacy.configure_file_settings("none")
	check(not memory.remember(first, file_mode) and memory.lookup(first).is_empty(), "Independent memory switch disables settings reads and writes")
	Privacy.configure_file_settings("all")
	var recent := Recent.new(directory.path_join("recent"))
	check(not recent.opened(first, "Episode", false), "No-record policy covers recent catalog")
	Privacy.configure("all")
	check(recent.opened(first, "Episode", false) and recent.save(), "History writes remain enabled by default")
	recent.set_location(first, Location.infer(first)); recent.save()
	check(recent.lookup(first).location.path == "/storage/emulated/0/Series", "Recent item retains parent across writes")
	check(recent.forget(first) and recent.purge_keys([]) and recent.suppressed.has(Memory.key_for(first)), "Removal suppresses automatic progress re-insertion")
	check(recent.restore() and not recent.suppressed.has(Memory.key_for(first)), "History undo restores progress and recording")
	var vault := Vault.new()
	store.platform = vault; store.protected = true; Privacy.vault = store
	var private_uri := "file:///private/secret.mp4"
	check(store.toggle(private_uri, "Private", "video"), "Unlocked protected favorite uses encrypted backend")
	check(not Privacy.persist_allowed(private_uri), "Protected file cannot enter plaintext storage")
	check(recent.opened(private_uri, "Private", false) and recent.progress(private_uri, 1234, 60000), "Recent playback records favorite media independently")
	check(recent.entries.has(Memory.key_for(private_uri)) and store.private_lookup(private_uri, "recent").is_empty(), "Recent progress lives in its own banks instead of the favorites vault")
	store.private_remember(private_uri, "view", {"geometry":0})
	check(store.remove(private_uri) and not store.contains(private_uri) and recent.lookup(private_uri).position_ms == 1234, "Removing a favorite preserves independent playback history")
	check(Privacy.protected_uri(private_uri), "Unfavorited encrypted per-file preferences remain protected")
	store.restore()
	check(store.remove(private_uri) and store.clear_private_records(false) and not store.restore(), "Privacy clear invalidates undo that could resurrect private history")
	check(store.restore_favorite({"uri":private_uri,"title":"Private","kind":"video","added":1,"location":{},"private":{"recent":{"uri":private_uri}}}) and store.private_lookup(private_uri, "recent").is_empty(), "Restoring a toggled favorite cannot revive cleared private history")
	store.toggle(private_uri, "Private", "video")
	store.focus_changed(false, 1000); store.tick(5000); store.focus_changed(true, 5000)
	check(not store.locked, "Default relaxed lock tolerates briefly removing the headset")
	store.focus_changed(false, 10000); store.tick(10000 + 15 * 60000)
	check(store.locked and store.entries.is_empty() and vault.is_locked, "Relaxed timeout clears decrypted collection and native key")
	check(not store.contains(private_uri) and not Privacy.persist_allowed(first), "Locking clears favorite membership and keeps per-file preferences protected")
	store.locked = false; store.lock_level = "manual"; store.focus_changed(false, 0); store.tick(9999999)
	check(not store.locked, "Manual lock level keeps one unlocked process session")
	store.away_since = -1; store.lock_level = "balanced"; store.focus_changed(false, 0); store.tick(119999)
	check(not store.locked, "Standard lock allows a two-minute grace period")
	store.tick(120000); check(store.locked, "Standard grace expires at two minutes")
	store.locked = false; store.lock_level = "strict"; store.focus_changed(false, 0)
	check(store.locked, "Strict lock remains available as an explicit choice")
	Privacy.vault = null; Privacy.configure("all")
	var menu := Library.new(); root.add_child(menu)
	_check_history_independence(directory)
	menu.catalog = recent; menu.collections.store = restored
	menu.refresh()
	check(menu._buttons.any(func(b):return b.target == menu.collections.HOME_TAB), "Home renders recent and favorite tabs")
	menu.collections.switch_tab(1)
	check(menu.rows.size() > 0 and not menu._buttons.any(func(b):return b.target == menu.CLEAR_HISTORY), "Favorites has no clear-all button")
	menu.load_view_mode("list"); menu.refresh()
	for button in menu._buttons:
		if menu.collections.row_target(button.target):
			check(button.has("list_row"), "Row actions share scrolling and visibility with their row")
	menu._set_scroll(1.0)
	check(menu._buttons.filter(func(button):return menu.collections.row_target(button.target)).size() <= menu._drawn_slots() * 3, "Scrolling replaces management actions without retaining freed nodes")
	menu.ray_hit(menu.to_global(Vector3(0, 0, 1)), -menu.global_basis.z)
	menu.collections.open_password("enable")
	for digit in [0, 1, 2, 3, 4]: menu.collections.action(menu.collections.KEY + digit)
	check(menu.collections.text == "0123", "PIN entry accepts exactly four digits and preserves leading zero")
	check(menu._buttons.filter(func(b):return b.target >= menu.collections.KEY and b.target < menu.collections.KEY + 10).size() == 10, "PIN dialog has ten numeric keys")
	check(not menu.text_snapshot().contains("0123"), "PIN remains masked in the UI text snapshot")
	menu.collections.action(menu.collections.SUBMIT)
	check(menu.collections.stage == "confirm" and menu.collections.text.is_empty(), "Setting a PIN requires confirmation")
	menu.collections.close()
	var host := Platform.new(); menu.attach_platform(host)
	menu.collections.open_location({"uri":first,"location":Location.infer(first)})
	check(menu.section == menu.Section.LOCAL and host.calls.back() == ["local","/storage/emulated/0/Series"], "Source action opens original local directory")
	menu.collections.action(menu.collections.RETURN_HOME)
	check(menu.section == menu.Section.RECENT and menu.collections.home_tab == 1, "Returning from source restores favorite tab")
	menu.collections.open_location({"uri":"smb://server/Series/01.mp4"})
	check(host.calls.back() == ["smb","server","Series"], "Source action restores SMB server and parent")
	menu.section = menu.Section.MEDIA_SERVER; menu.server_browser.server = {"id":"demo"}; menu.server_browser.folder_path = []
	var episode_location := Location.capture(menu, {"id":"episode1","parent_id":"season1","series_title":"Series"})
	check(episode_location.folder_path.back().id == "season1", "An episode opened from server home returns to its season")
	var player := Player.new(); root.add_child(player)
	player.favorite_provider = func():return {"enabled":true,"selected":true,"locked":false}
	player.refresh()
	check(player._buttons.any(func(b):return b.target == player.FAVORITE and b.enabled), "Video control bar exposes favorite action")
	var photo := PhotoMenu.new(); root.add_child(photo)
	photo.favorite_provider = func():return {"enabled":false,"selected":false,"locked":false}
	photo.refresh()
	check(photo._buttons.any(func(b):return b.target == photo.FAVORITE and not b.enabled), "Photo overview can disable ambiguous favorite target")
	var photo_actions := []
	photo.favorite_requested.connect(func():photo_actions.append(true))
	photo._activate(photo.FAVORITE)
	check(photo_actions.size() == 1, "Photo favorite action reaches its own handler")
	menu.free(); player.free(); photo.free()
	_check_popup_layers()
	Privacy.vault = null; Privacy.configure("all")
	print("Collections: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
