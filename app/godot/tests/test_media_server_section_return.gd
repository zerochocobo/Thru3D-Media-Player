extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Data := preload("res://tests/test_media_server_browser.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Vault extends RefCounted:
	var protected := true
	var locked := false

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)

func _initialize() -> void: call_deferred("run")

func request_id(browser: RefCounted, action: String) -> int:
	for id in browser.pending:
		if browser.pending[id].action == action: return int(id)
	return -1

func page(start: int, count: int) -> Array:
	var result: Array = []
	for i in range(start, start + count): result.append({"id": str(i), "title": "Film %d" % i, "uri": "medialib://profile/scene/%d" % i, "duration_ms": 60000, "has_cover": false})
	return result

func open_library(menu: Node, platform: Object, provider: String) -> void:
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	platform.answer(platform.next, {"servers": [{"id": "profile", "name": "NAS", "provider": provider}]})
	menu._choose(menu.rows[0])
	platform.answer(platform.next, {"capabilities": Data.CAPS.merged({"home_layout": "libraries", "artwork": true}), "libraries": [{"id": "movies", "title": "Movies"}]})
	menu.server_browser.choose({"library": {"id": "movies", "title": "Movies"}})
	platform.answer(request_id(menu.server_browser, "browse"), {"entries": [{"id": "folder", "title": "Series", "container": true, "has_cover": false}], "total": 1})
	menu._choose(menu.rows[0])
	platform.answer(request_id(menu.server_browser, "browse"), {"entries": page(1, 48), "total": 96})
	menu.server_browser.more()
	platform.answer(request_id(menu.server_browser, "browse"), {"entries": page(49, 48), "total": 96})

func settings_and_back(menu: Node) -> void:
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu._activate(Menu.TAB_BASE + menu.BACKGROUND_TAB)
	menu.dismiss(); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	for provider in ["emby", "jellyfin"]:
		for detail in [false, true]:
			var platform := Fixture.Platform.new()
			var menu := Menu.new()
			open_library(menu, platform, provider)
			var b: RefCounted = menu.server_browser
			menu._set_scroll(8.25)
			var list_position: Dictionary = menu.capture_position()
			if detail:
				menu._choose({"scene": b.entries[52]})
				platform.answer(request_id(b, "detail"), {"detail": page(53, 1)[0].merged({"overview": "Film overview", "parts": [{"id": "ep1", "title": "Episode 1"}, {"id": "ep2", "title": "Episode 2"}]})})
				b.gallery.selected_part = 1; b.gallery.overview_start = 2
			var previous: Dictionary = b.context_state()
			var history: Array = b.history.duplicate(true)
			var requests: int = platform.next
			settings_and_back(menu)
			var label := "%s %s: " % [provider, "detail" if detail else "folder"]
			check(b.view == previous.view and b.server.get("id") == "profile", label + "settings returns to the current server page")
			check(b.query == previous.query and b.library_id == "movies" and b.folder_path == previous.folder_path, label + "library, directory and query survive")
			check(b.entries == previous.entries and b.loaded_page == 2 and b.end_reached, label + "both loaded pages survive")
			check(b.history == history, label + "Back history survives")
			check(platform.requests.keys().filter(func(id): return id > requests).all(func(id): return platform.requests[id].action in ["cover", "folder_artwork"]), label + "return needs no root or library reload")
			if detail:
				check(b.detail == previous.detail and b.gallery.selected_part == 1 and b.gallery.overview_start == 2, label + "video and episode selection survive")
				b.back()
				check(b.view == "scenes" and menu.capture_position() == list_position, label + "Back returns to the loaded list at its previous position")
			else:
				check(menu.capture_position() == list_position, label + "fractional list position survives")
				b.back()
				check(b.view == "scenes" and b.folder_path.is_empty() and b.entries.size() == 1, label + "Back returns to the library parent")
			menu.free(); platform.free()
	test_pending_reads()
	test_direct_settings()
	test_invalidations()
	test_pending_root()
	test_mutations()
	test_privacy_and_layout()
	for failure in failures: push_error(failure)
	print("Media server section return: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func test_pending_reads() -> void:
	for action in ["home", "browse", "detail", "candidates"]:
		var platform := Fixture.Platform.new()
		var menu := Menu.new()
		open_library(menu, platform, "emby")
		var b: RefCounted = menu.server_browser
		match action:
			"home": b.open_home()
			"browse": b.query.q = "new search"; b.browse()
			"detail": b.choose({"scene": b.entries[52]})
			"candidates": b.kind = "genres"; b.view = "facets"; b.get_candidates()
		var old := request_id(b, action)
		var expected: Dictionary = platform.requests[old].duplicate(true)
		menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
		check(old in platform.cancelled and b.pending.is_empty(), action + ": leaving cancels the old request")
		platform.answer(old, {"entries": page(999, 1), "detail": page(999, 1)[0], "total": 1})
		check(menu.section == Menu.Section.SETTINGS and not b.entries.any(func(item): return item.id == "999"), action + ": late response cannot affect settings")
		menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
		var resumed := request_id(b, action)
		check(resumed > old and b.busy, action + ": return restarts the interrupted read")
		if resumed > 0:
			var actual: Dictionary = platform.requests[resumed].duplicate(true)
			check(actual.generation != expected.generation, action + ": resumed read uses a new generation")
			actual.erase("generation"); expected.erase("generation")
			check(actual == expected, action + ": resumed read keeps its original server and query")
			var response := {"entries": page(500, 1), "detail": page(53, 1)[0], "total": 1}
			if action == "home": response = {"capabilities": Data.CAPS, "recent": page(500, 1), "libraries": [{"id": "movies", "title": "Movies"}]}
			if action == "candidates": response.entries = [{"id": "genre", "name": "Drama"}]
			platform.answer(resumed, response)
			check(not b.busy and menu.status.is_empty(), action + ": replacement response finishes loading")
			platform.answer(old, {"entries": page(999, 1), "detail": page(999, 1)[0], "total": 1})
			check(not b.entries.any(func(item): return item.id == "999") and b.detail.get("id", "") != "999", action + ": late original response remains rejected after return")
		menu.free(); platform.free()

func test_direct_settings() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new()
	open_library(menu, platform, "emby")
	menu._set_scroll(8.25)
	var previous: Dictionary = menu.server_browser.context_state()
	# Main also opens some settings by assigning the section directly.
	menu.section = Menu.Section.SETTINGS; menu.tab = menu.BACKGROUND_TAB
	menu._reset_navigation(); menu.refresh()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(menu.server_browser.view == "scenes" and menu.capture_position() == previous.position, "Direct settings entry preserves the current server folder and position")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu.restore_directory_position = false
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(menu.server_browser.folder_path == previous.folder_path and is_zero_approx(menu.scroll), "Disabled position restore keeps the folder and opens it at the top")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(menu.server_browser.entries == previous.entries, "Repeated settings visits retain loaded media")
	menu.server_browser.open_home()
	platform.answer(request_id(menu.server_browser, "home"), {"capabilities": Data.CAPS, "recent": [], "libraries": []})
	menu.server_browser.back()
	check(menu.server_browser.view == "servers" and request_id(menu.server_browser, "servers") > 0, "Explicit Back from the server home still opens server selection")
	menu.free(); platform.free()

func test_invalidations() -> void:
	for reason in ["accounts", "clear", "clear_network"]:
		var platform := Fixture.Platform.new()
		var menu := Menu.new()
		open_library(menu, platform, "emby")
		menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
		var requests: int = platform.next
		if reason == "accounts": platform.accounts_changed()
		else: menu.clear_browse_history(reason == "clear_network")
		check(menu.section == Menu.Section.SETTINGS and platform.next == requests, reason + ": invalidation leaves settings open")
		menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
		check(menu.server_browser.view == "servers" and request_id(menu.server_browser, "servers") > 0 and menu.server_browser.history.is_empty(), reason + ": invalidated pages cannot be restored")
		menu.free(); platform.free()

func test_pending_root() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new()
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	var old: int = platform.next
	settings_and_back(menu)
	var resumed := request_id(menu.server_browser, "servers")
	check(resumed > old and menu.server_browser.busy, "Leaving before the server list loads still reloads accounts on return")
	if resumed > 0:
		platform.answer(resumed, {"servers": [{"id": "new", "name": "New NAS", "provider": "emby"}]})
		check(menu.rows.size() == 1 and menu.rows[0].server_account.id == "new", "Root receives the current accounts after return")
	menu.free(); platform.free()

func test_mutations() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new()
	open_library(menu, platform, "emby")
	var b: RefCounted = menu.server_browser
	b.choose({"scene": b.entries[0]})
	platform.answer(request_id(b, "detail"), {"detail": page(1, 1)[0].merged({"favorite": false})})
	b.choose({"favorite": true})
	var mutations: int = platform.requests.values().filter(func(body): return body.action == "favorite").size()
	settings_and_back(menu)
	check(platform.requests.values().filter(func(body): return body.action == "favorite").size() == mutations, "Returning from settings never repeats a favorite mutation")
	check(not b.busy and menu.status != "Loading…", "Cancelled mutation does not leave the restored detail stuck loading")
	menu.free(); platform.free()

func test_privacy_and_layout() -> void:
	for policy in [Privacy.ALL, Privacy.LOCAL, Privacy.NONE]:
		Privacy.configure(policy)
		var platform := Fixture.Platform.new()
		var menu := Menu.new()
		open_library(menu, platform, "emby")
		var previous: Dictionary = menu.server_browser.context_state()
		settings_and_back(menu)
		check(menu.server_browser.view == previous.view and menu.server_browser.entries == previous.entries, policy + ": same-run return works under every history policy")
		menu.free(); platform.free()
	Privacy.configure(Privacy.ALL)
	var platform := Fixture.Platform.new()
	var menu := Menu.new()
	open_library(menu, platform, "emby")
	var b: RefCounted = menu.server_browser
	b.choose({"scene": b.entries[52]})
	platform.answer(request_id(b, "detail"), {"detail": page(53, 1)[0]})
	menu.set_compact(true)
	check(b.view == "scenes", "Playback compact layout continues to show the media list")
	menu.set_compact(false)
	check(b.view == "detail" and b.detail.id == "53", "Expanding the playback library still restores the video detail")
	settings_and_back(menu)
	check(b.view == "detail" and b.detail.id == "53", "Settings after expanding playback returns to the same video")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	Privacy.vault = Vault.new(); Privacy.vault.locked = true
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(b.view == "servers" and request_id(b, "servers") > 0, "Locking protected history prevents restoring a suspended page")
	Privacy.vault = null
	menu.free(); platform.free()
	platform = Fixture.Platform.new(); menu = Menu.new()
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(menu.server_browser.view == "servers" and request_id(menu.server_browser, "servers") > 0, "A new menu starts at account selection rather than restoring a previous run")
	menu.free(); platform.free()
