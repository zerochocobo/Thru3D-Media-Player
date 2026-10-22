extends RefCounted
## One ray-driven browser; native clients supply capabilities and normalized nodes.
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const ACTION := 1000
const KEY := 1400
const SORTS := ["created_at", "title", "date", "duration", "rating100"]
const SORT_NAMES := ["Date added", "Title", "Release date", "Duration", "Rating"]
const FILTER_NAMES := {"genres": "Genres", "tags": "Tags", "performers": "Performers", "studios": "Studios"}
const Gallery := preload("res://scripts/media_server_gallery.gd")
var gallery: RefCounted = Gallery.new(self)
var backdrop := preload("res://scripts/media_server_backdrop.gd").new(self)
var actor_name := ""
var menu: Node
var view := "servers"
var server := {}
var capabilities := {"navigation": [], "facets": [], "filters": ["watched"], "sorts": ["created_at", "title"], "favorite_scope": "local", "search": true}
var home_data := {}
var query := {"page": 1, "q": "", "all_tags": true}
var servers: Array = []
var entries: Array = []
var candidates: Array = []
var detail := {}
var kind := "tags"
var exclude := false
var candidate_page := 1
var candidate_q := ""
var candidate_total := 0
var total := 0
var loaded_page := 0
var generation := 0
var pending := {}
var labels := {}
var covers := {}
var textures := {}
var failed_covers := {}
var selection := {}
var keyboard := ""
var text := ""
var saved: Array = []
var favorites := {}
var setup := false
var busy := false
var chips: Array = []
var removing := {}
var history: Array = []
var folder_path: Array = []
var library_id := ""
var end_reached := false
var candidate_end := false
var display_preferences := {}
var folder_artwork := {}
var sort_query := {}
var sources_open := false
var display_preferences_path := "user://settings/server_views.cfg"
var _location_pending := {}

func open_location(location: Dictionary) -> void:
	cancel(); server = {"id": str(location.server_id)}
	_location_pending = location.duplicate(true)
	view = "home"; entries.clear(); detail.clear(); home_data.clear(); folder_path.clear()
	request("home", {"library_id": str(location.get("library_id", ""))})

func _init(owner: Node) -> void:
	menu = owner
	load_display_preferences()
	var config := ConfigFile.new()
	if config.load("user://settings/server_filters.cfg") == OK:
		var value: Variant = config.get_value("filters", "items", [])
		if value is Array: saved = value.slice(0, 100)
	if config.load("user://settings/server_favorites.cfg") == OK:
		for id in config.get_section_keys("favorites") if config.has_section("favorites") else []:
			var value: Variant = config.get_value("favorites", id, [])
			if value is Array: favorites[id] = value.filter(func(item): return item is Dictionary and str(item.get("uri", "")).begins_with("medialib://" + str(id) + "/scene/")).slice(0, 1000)

func cancel() -> void:
	menu.system_text_input.cancel("media_server_search")
	_location_pending.clear()
	sort_query.clear()
	gallery.capture.clear()
	generation += 1
	if menu.platform:
		for id in pending: menu.platform.media_server_cancel(int(id))
	pending.clear()
	busy = false

func load_servers() -> void:
	cancel(); view = "servers"; server = {}; history.clear(); keyboard = ""; sources_open = false
	menu._reset_navigation()
	request("servers")

func request(action_name: String, extra: Dictionary = {}) -> void:
	if not menu.platform:
		menu.status = "Headset only"; return
	var body := {"action": action_name, "server_id": str(server.get("id", "")), "generation": generation}
	body.merge(extra, true)
	var id: int = menu.platform.media_server_request(JSON.stringify(body))
	if id > 0:
		pending[id] = body
		if action_name not in ["cover", "folder_artwork"]: busy = true; menu.status = "Loading…"
	elif action_name == "folder_artwork": _cache_folder_artwork(str(extra.get("scene_id", "")), {})
	else: menu.status = "Server unavailable"

func open_home() -> void:
	cancel(); view = "home"; entries = []; home_data = {}; folder_path = []; history.clear()
	query = {"page": 1, "q": "", "all_tags": true}; labels.clear(); actor_name = ""; library_id = ""; gallery.library_start = 0; gallery.recent_start = 0; gallery.home_strip = "libraries"
	menu._reset_navigation(); request("home", {"library_id": library_id}); menu.refresh()

func browse(reset: bool = true) -> void:
	cancel()
	if not query.has("sort"): query.sort = str(_display_settings().get("sort", "created_at"))
	if str(query.sort) not in available_sorts(): query.sort = "created_at" if "created_at" in available_sorts() else available_sorts().front() if not available_sorts().is_empty() else "created_at"
	if not query.has("direction"): query.direction = str(_display_settings().get("direction", "ASC" if query.sort == "title" else "DESC"))
	if query.direction not in ["ASC", "DESC"]: query.direction = "DESC"
	if reset: query.page = 1
	query.library_id = "" if query.get("all_libraries", false) else library_id
	if not query.has("mode") and not library_id.is_empty() and not query.get("all_libraries", false) and capabilities.get("home_layout", "") == "libraries":
		query.mode = "library"
		for library in home_data.get("libraries", []):
			if str(library.id) == library_id: query.collection_type = str(library.get("collection_type", ""))
	view = "scenes"; entries = []; loaded_page = 0; end_reached = false
	if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server":
		entries = _local_favorites_query(); total = entries.size(); end_reached = true
		menu.status = ""; menu._reset_navigation(); menu.refresh(); return
	textures.clear(); failed_covers.clear()
	menu._reset_navigation(); request("browse", query); menu.refresh()

func _append_unique(target: Array, incoming: Array) -> int:
	var seen := {}
	for item in target: seen[str(item.get("id", ""))] = true
	var added := 0
	for item in incoming:
		if item is Dictionary and not seen.has(str(item.get("id", ""))):
			seen[str(item.get("id", ""))] = true; target.append(item); added += 1
	return added

func receive(id: int, payload: String) -> bool:
	if not pending.has(id): return false
	var expected: Dictionary = pending[id]; pending.erase(id)
	var data: Variant = JSON.parse_string(payload)
	if not data is Dictionary or int(data.get("generation", -1)) != generation or data.get("server_id", "") != expected.server_id: return true
	if expected.action not in ["cover", "folder_artwork"]: busy = false
	if data.get("state") != "ready":
		if expected.action == "cover": failed_covers[_request_image_key(expected)] = true
		elif expected.action == "folder_artwork": _cache_folder_artwork(str(expected.scene_id), {})
		else: menu.status = str(data.get("error", "Server unavailable"))
		menu.refresh(); return true
	if expected.action not in ["cover", "folder_artwork"]: menu.status = ""
	match expected.action:
		"servers": servers = data.get("servers", [])
		"home":
			home_data = data; capabilities = data.get("capabilities", capabilities); library_id = str(data.get("library_id", "")); total = int(data.get("total", 0))
			if not _location_pending.is_empty():
				var location: Dictionary = _location_pending.duplicate(true); _location_pending.clear()
				library_id = str(location.get("library_id", "")); folder_path = location.get("folder_path", []).duplicate(true)
				query = {"page": 1, "q": "", "mode": "library"}
				if not folder_path.is_empty(): query.parent_id = str(folder_path.back().id); query.mode = "folders"
				view = "scenes"; browse(); return true
			entries = []
			if gallery.home(): _append_unique(entries, home_recent_entries())
			else: _append_unique(entries, _resume_entries()); _append_unique(entries, home_data.get("recent", []))
		"browse":
			var incoming: Array = data.get("entries", [])
			var page := int(expected.get("page", 1))
			if page == 1: entries = []; total = int(data.get("total", 0))
			else: total = maxi(total, int(data.get("total", 0)))
			var added := _append_unique(entries, incoming)
			loaded_page = page; query.page = page
			end_reached = incoming.size() < 48 or entries.size() >= total or added == 0
			if page > 1 and not incoming.is_empty() and added == 0: menu.status = "Server query unsupported"
		"candidates":
			var incoming: Array = data.get("entries", [])
			if int(expected.get("page", 1)) == 1: candidates = []
			var added := _append_unique(candidates, incoming)
			candidate_total = int(data.get("total", 0)); candidate_page = int(expected.get("page", 1))
			candidate_end = incoming.size() < 48 or candidates.size() >= candidate_total or added == 0
		"detail":
			detail = data.get("detail", {}); view = "detail"
			gallery.image_start = 0; gallery.actor_start = 0; gallery.selected_image = 0
			gallery.part_start = 0; gallery.selected_part = 0
			gallery.detail_start = 0; gallery.tag_start = 0; gallery.overview_start = 0
			var resume_part := false
			var local_detail: Dictionary = menu.Presentation.local_record(menu.catalog, str(detail.get("uri", "")))
			if not local_detail.is_empty(): detail.position_ms = int(local_detail.get("position_ms", 0))
			for part in detail.get("parts", []):
				var local_part: Dictionary = menu.Presentation.local_record(menu.catalog, str(part.get("uri", "")))
				if not local_part.is_empty(): part.position_ms = int(local_part.get("position_ms", 0))
			for local in _local_resume():
				if local.id == detail.get("id"): detail.position_ms = local.position_ms
				for index in detail.get("parts", []).size():
					if local.id == detail.parts[index].get("id"):
						detail.parts[index].position_ms = local.position_ms
						if not resume_part:
							gallery.selected_part = index; gallery.part_start = mini((index / 2) * 2, maxi(0, detail.parts.size() - 2)); resume_part = true
			if expected.has("recent_position_ms"):
				if str(detail.get("id", "")) == str(expected.scene_id): detail.position_ms = int(expected.recent_position_ms)
				for index in detail.get("parts", []).size():
					if str(detail.parts[index].get("id", "")) == str(expected.scene_id):
						detail.parts[index].position_ms = int(expected.recent_position_ms)
						gallery.selected_part = index; gallery.part_start = mini((index / 2) * 2, maxi(0, detail.parts.size() - 2))
		"favorite":
			if str(detail.get("id", "")) == str(data.get("scene_id", "")):
				detail.favorite = bool(data.get("favorite", false))
				_favorite_changed(str(detail.id), detail.favorite)
		"cover": covers[_request_image_key(expected)] = str(data.get("path", ""))
		"folder_artwork": _cache_folder_artwork(str(expected.scene_id), data.get("image_variants", {}))
		"remove":
			var removed := str(expected.server_id)
			saved = saved.filter(func(item): return item is Dictionary and item.get("server_id") != removed)
			_save_filters(); favorites.erase(removed); _save_favorites()
			covers.clear(); textures.clear(); failed_covers.clear(); removing = {}; load_servers()
	if expected.action == "detail" and menu.compact: menu.set_compact(true)
	menu.refresh()
	return true

func _local_resume() -> Array:
	var result: Array = []
	if not menu.catalog: return result
	var prefix := "medialib://" + str(server.get("id", "")) + "/scene/"
	for item in menu.catalog.list_recent():
		if str(item.get("uri", "")).begins_with(prefix) and int(item.get("position_ms", 0)) > 0 and (int(item.get("duration_ms", 0)) <= 0 or int(item.position_ms) < int(item.duration_ms) - 1000):
			var node: Dictionary = item.duplicate(true); node.id = str(item.uri).trim_prefix(prefix); node.resume_source = "local"; node.kind = "video"
			result.append(node)
	return result

func _resume_entries() -> Array:
	var result: Array = []; _append_unique(result, _local_resume()); _append_unique(result, home_data.get("resume", []))
	return result.slice(0, 1)

func home_recent_entries() -> Array:
	var result: Array = []
	var prefix := "medialib://" + str(server.get("id", "")) + "/scene/"
	var remote: Array = home_data.get("recent_opened", home_data.get("resume", []))
	var metadata := {}
	for node in remote:
		if node is Dictionary and str(node.get("uri", "")).begins_with(prefix): metadata[str(node.get("id", ""))] = node
	if menu.catalog:
		for local in menu.catalog.list_recent():
			var uri := str(local.get("uri", ""))
			if not uri.begins_with(prefix) or local.get("kind", "video") == "image": continue
			var id := uri.trim_prefix(prefix)
			var node: Dictionary = metadata.get(id, {}).duplicate(true)
			node.merge(local, true); node.id = id; node.kind = "video"; node.recent_source = "local"
			_append_unique(result, [node])
	_append_unique(result, remote.filter(func(node): return node is Dictionary and str(node.get("uri", "")).begins_with(prefix) and not node.get("container", false)))
	return result.slice(0, 32)

func context_state() -> Dictionary:
	return {"view": view, "query": query.duplicate(true), "entries": entries.duplicate(true), "candidates": candidates.duplicate(true), "detail": detail.duplicate(true), "kind": kind,
		"total": total, "loaded_page": loaded_page, "candidate_page": candidate_page, "candidate_total": candidate_total, "candidate_q": candidate_q, "labels": labels.duplicate(true), "folder_path": folder_path.duplicate(true), "scroll": menu.scroll, "end": end_reached, "candidate_end": candidate_end,
		"position": menu.capture_position(), "library_id": library_id, "actor_name": actor_name, "gallery": gallery.state()}

func restore_context(previous: Dictionary) -> void:
	view = previous.view; query = previous.query; entries = previous.entries; candidates = previous.candidates; detail = previous.detail; kind = previous.kind
	total = previous.total; loaded_page = previous.loaded_page; candidate_page = previous.candidate_page; candidate_total = previous.candidate_total; candidate_q = previous.candidate_q
	labels = previous.labels; folder_path = previous.folder_path; end_reached = previous.end; candidate_end = previous.candidate_end
	library_id = str(previous.get("library_id", "")); actor_name = str(previous.get("actor_name", "")); gallery.restore(previous.get("gallery", {}))
	menu.scroll = previous.scroll; menu._position_to_restore = previous.get("position", {})

func _remember() -> void:
	history.append(context_state())
	if history.size() > 12: history.pop_front()

func back() -> void:
	if sorting(): sort_query.clear(); menu.refresh(); return
	cancel(); keyboard = ""
	if not history.is_empty():
		var previous: Dictionary = history.pop_back()
		menu._reset_navigation(); restore_context(previous); menu.status = ""; menu.refresh()
	elif view == "home": load_servers()
	elif view in ["remove_servers", "confirm_remove"]: removing = {}; load_servers()
	else: open_home()

func grid() -> bool:
	if media_content(): return scene_view() != "list"
	if view == "scenes": return menu.view_mode == "grid" and keyboard.is_empty()
	return view in ["servers", "home", "scenes", "facets", "libraries"] and keyboard.is_empty()

func visible_lines() -> int:
	if media_content(): return (1 if tile_mode() == "poster" and scene_size() == 2 else (3 if tile_mode() == "thumb" and scene_size() < 2 else 2)) if grid() else 6
	return 2 if grid() else (4 if view == "filters" else 5)

func pitch() -> float:
	if media_content(): return tile_size().y + 0.025 if grid() else 0.12
	return 0.29 if grid() else (0.10 if view == "filters" else 0.105)

func list_top() -> float:
	if focused(): return 0.29 if grid() else 0.25
	return 0.18 if grid() else 0.15

func bar_span() -> Vector2:
	return Vector2(list_top() + (0.035 if not grid() else 0.0), visible_lines() * pitch() - 0.015)

func media_content() -> bool:
	return not menu.compact and view == "scenes" and keyboard.is_empty() and capabilities.get("artwork", false)

func focused() -> bool:
	return not menu.compact and not server.is_empty() and capabilities.get("artwork", false) and view not in ["servers", "remove_servers", "confirm_remove"]

func scene_view() -> String:
	var value := str(_display_settings().get("mode", "poster"))
	return value if value in ["poster", "thumb", "list"] else "poster"

func scene_size() -> int:
	var value: Variant = _display_settings().get("size", 1)
	return value if value is int and value >= 0 and value <= 2 else 1

func _display_settings() -> Dictionary:
	var value: Variant = display_preferences.get(str(server.get("id", "")), {})
	return value if value is Dictionary else {}

func load_display_preferences() -> void:
	var config := ConfigFile.new()
	display_preferences = {}
	if config.load(display_preferences_path) == OK:
		var value: Variant = config.get_value("views", "items", {})
		if value is Dictionary: display_preferences = value

func columns() -> int:
	return [5, 4, 3][scene_size()] if media_content() and grid() else menu.COLS

func tile_size() -> Vector2:
	var width: float = (1.38 - (columns() - 1) * 0.025) / columns()
	return Vector2(width, width * 1.05 + 0.055 if tile_mode() == "poster" else width * 0.5625 + 0.07)

func movie_folders() -> bool:
	if not media_content() or query.get("mode", "") != "folders": return false
	if query.get("collection_type", "") == "movies": return true
	return home_data.get("libraries", []).any(func(item): return str(item.get("id", "")) == library_id and item.get("collection_type", "") == "movies")

func tile_mode() -> String:
	return "thumb" if movie_folders() and scene_view() != "list" else scene_view()

func _folder_key(id: String) -> String: return str(server.get("id", "")) + "/" + id

func _cache_folder_artwork(id: String, images: Dictionary) -> void:
	var key := _folder_key(id)
	folder_artwork.erase(key)
	folder_artwork[key] = images
	while folder_artwork.size() > 256: folder_artwork.erase(folder_artwork.keys()[0])

func _folder_image_variants(node: Dictionary) -> Dictionary:
	var variants: Dictionary = node.get("image_variants", {}).duplicate()
	var inherited: Dictionary = folder_artwork.get(_folder_key(str(node.get("id", ""))), {})
	for type in ["Thumb", "Backdrop"]:
		if not variants.has(type) and inherited.has(type): variants[type] = inherited[type]
	return variants

func _request_folder_artwork(node: Dictionary) -> void:
	if not movie_folders() or not node.get("container", false) or node.get("type", "") != "Folder": return
	if node.get("image_variants", {}).has("Thumb") or folder_artwork.has(_folder_key(str(node.id))): return
	if int(node.get("child_count", -1)) == 0 or int(node.get("child_count", -1)) > 1: return
	var active: Array = pending.values().filter(func(p): return p.action == "folder_artwork")
	if menu.visible and active.size() < 2 and not active.any(func(p): return p.scene_id == node.id): request("folder_artwork", {"scene_id": str(node.id)})

func set_display(mode: String, size: int = -1) -> void:
	if not media_content() or mode not in ["poster", "thumb", "list"]: return
	var anchor: Dictionary = menu.capture_position()
	display_preferences[str(server.id)] = _display_settings().merged({"mode": mode, "size": scene_size() if size < 0 else clampi(size, 0, 2)}, true)
	_save_display_preferences()
	menu._drag = {}; menu._fling = 0.0; menu._hover.clear(); menu._hide_tooltip()
	menu._position_to_restore = anchor; menu.refresh()

func _save_display_preferences() -> void:
	var config := ConfigFile.new(); config.set_value("views", "items", display_preferences)
	DirAccess.make_dir_recursive_absolute(display_preferences_path.get_base_dir())
	if config.save(display_preferences_path) != OK: menu.status = "Unable to save display preferences"

func available_sorts() -> Array:
	var result: Array = capabilities.get("sorts", SORTS).filter(func(value): return value in SORTS)
	if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server": result.erase("date")
	return result

func sort_caption(short: bool = false) -> String:
	var name := I18n.t(SORT_NAMES[maxi(0, SORTS.find(str(query.get("sort", "created_at"))))])
	return (menu._fit_title(name, "", 0.28, 17) if short else name) + (" ↑" if query.get("direction", "DESC") == "ASC" else " ↓")

func sorting() -> bool:
	return not sort_query.is_empty() and view == "scenes" and not menu.compact and keyboard.is_empty()

func _apply_sort() -> void:
	var sort := str(sort_query.get("sort", "created_at")); var direction := str(sort_query.get("direction", "DESC"))
	sort_query.clear()
	query.sort = sort; query.direction = direction
	display_preferences[str(server.id)] = _display_settings().merged({"sort": sort, "direction": direction}, true)
	_save_display_preferences(); browse()

func display_node(node: Dictionary, mode: String = "") -> Dictionary:
	if mode.is_empty(): mode = tile_mode()
	var variants: Dictionary = _folder_image_variants(node) if movie_folders() and node.get("container", false) else node.get("image_variants", {})
	var image: Dictionary = node.get("cover_image", {})
	for type in (["Primary", "Thumb", "Backdrop"] if mode == "poster" else ["Thumb", "Backdrop", "Primary"]):
		if not variants.has(type): continue
		var candidate: Dictionary = variants[type].merged({"max_width": 128 if mode == "list" else 512})
		if failed_covers.has(_request_image_key(_image_request({"cover_image": candidate}))): continue
		image = candidate; break
	if not image.is_empty(): image = image.merged({"max_width": 128 if mode == "list" else 512})
	return node.merged({"cover_image": image, "has_cover": not image.is_empty() or node.get("has_cover", false)}, true)

func filename(row: Dictionary) -> String:
	var node: Dictionary = row.get("scene", row.get("container_node", {}))
	return str(node.get("basename", "")) if not str(node.get("basename", "")).is_empty() else str(row.title)

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not keyboard.is_empty(): return result
	match view:
		"servers":
			for item in servers: result.append({"title": str(item.name), "detail": str(item.get("provider", "")).capitalize(), "icon": "media_library", "server_account": item})
		"remove_servers":
			for item in servers: result.append({"title": str(item.name), "detail": menu.account_panel.provider_name(str(item.get("provider", ""))), "icon": "trash", "remove_server": item})
		"confirm_remove":
			result.append({"title": I18n.t("Remove server") + ": " + str(removing.get("name", "")), "detail": menu.account_panel.provider_name(str(removing.get("provider", ""))), "icon": "trash", "confirm_remove": true})
			result.append({"title": I18n.t("Cancel"), "icon": "up", "cancel_remove": true})
		"home":
			if gallery.home():
				for item in home_data.get("libraries", []): result.append({"title": str(item.title), "library": item})
				for item in home_recent_entries(): result.append(_node_row(item).merged({"recent_opened": true}))
			else:
				for item in _resume_entries(): result.append(_node_row(item).merged({"resume": true}))
				for item in home_data.get("recent", []).slice(0, 4): result.append(_node_row(item))
		"scenes":
			for item in entries: result.append(_node_row(item))
		"libraries":
			for item in home_data.get("libraries", []): result.append({"title": str(item.title), "detail": "", "icon": "library", "library": item})
		"facets":
			if kind in capabilities.get("unclassified", []): result.append({"title": I18n.t("Uncategorized"), "detail": "", "icon": "folder", "unclassified": kind})
			for item in candidates: result.append({"title": str(item.name), "detail": str(item.count) if int(item.get("count", -1)) >= 0 else "", "icon": "list", "facet": item})
		"filters":
			for category in capabilities.get("facets", []): result.append({"title": I18n.t(FILTER_NAMES.get(category, category)), "detail": str(query.get(category, []).size() + query.get("exclude_" + category, []).size()), "icon": "list", "category": category})
			if capabilities.get("descendants", false) and not query.get("favorites", false): result.append({"title": I18n.t("Include child tags"), "detail": "", "icon": "check" if query.get("descendants", false) else "circle", "toggle": "descendants"})
			for flag in capabilities.get("filters", []):
				if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server":
					if flag in ["watched", "resolution"]: continue
				var caption := ""
				match flag:
					"watched": caption = I18n.t("Watched") + ": " + I18n.t("All" if not query.has(flag) else ("Yes" if query[flag] else "No"))
					"min_rating": caption = I18n.t("Minimum rating") + ": " + str(query.get(flag, "—"))
					"min_duration": caption = I18n.t("Minimum duration") + ": " + ("—" if not query.has(flag) else "%d min" % (int(query[flag]) / 60))
					"resolution": caption = I18n.t("Resolution") + ": " + str(query.get(flag, "—")).replace("FOUR_K", "4K").replace("SIX_K", "6K").replace("EIGHT_K", "8K")
				if not caption.is_empty(): result.append({"title": caption, "icon": "history" if flag == "watched" else "info", "toggle": flag})
			result.append({"title": I18n.t("Clear filters"), "icon": "trash", "reset": true})
		"candidates":
			for item in candidates:
				var id := str(item.id); var included: bool = id in query.get(kind, []); var excluded: bool = id in query.get("exclude_" + kind, [])
				result.append({"title": str(item.name), "detail": "−" if excluded else ("+" if included else ""), "icon": "check" if included else ("minus" if excluded else "circle"), "selected": included or excluded, "candidate": item})
		"detail", "metadata":
			if not detail.is_empty():
				result.append({"title": I18n.t("Continue watching" if int(detail.get("position_ms", 0)) > 0 else "Play / resume"), "icon": "play", "play_scene": detail})
				result.append({"title": I18n.t("Favorited" if _is_favorite(detail) else "Favorite"), "icon": "heart", "favorite": true})
				for category in capabilities.get("facets", []):
					for item in detail.get(category, []): result.append({"title": str(item.name), "detail": I18n.t(FILTER_NAMES.get(category, category)), "icon": "plus", "detail_filter": item, "category": category})
				for marker in gallery.playback_node().get("markers", []): result.append({"title": _time(int(marker.position_ms)) + "  " + str(marker.title), "icon": "seek_forward", "marker": marker})
		"saved":
			for item in saved:
				if item is Dictionary and item.get("server_id") == server.get("id") and item.get("query") is Dictionary: result.append({"title": str(item.get("name", "")), "icon": "list", "saved_filter": item})
		"options":
			if home_data.get("libraries", []).size() > 1: result.append({"title": I18n.t("Libraries"), "icon": "library", "open_libraries": true})
			result.append({"title": I18n.t("Refresh"), "icon": "refresh", "refresh_server": true})
			result.append({"title": I18n.t("Saved searches"), "icon": "list", "open_saved": true})
			result.append({"title": I18n.t("Edit"), "icon": "edit", "edit_server": true})
	return result

func _node_row(item: Dictionary) -> Dictionary:
	if item.get("container", false): return {"title": str(item.title), "detail": str(item.get("child_count", "")) if int(item.get("child_count", -1)) >= 0 else "", "icon": "folder", "container_node": item}
	return {"title": str(item.get("title", "Video")), "detail": _time(int(item.get("duration_ms", 0))) if int(item.get("duration_ms", 0)) > 0 else "", "icon": "video", "scene": item}

func _time(ms: int) -> String:
	var seconds := maxi(0, ms / 1000)
	return "%d:%02d" % [seconds / 60, seconds % 60]

func choose(row: Dictionary) -> void:
	if row.has("remove_server"): removing = row.remove_server.duplicate(true); view = "confirm_remove"; menu._reset_navigation()
	elif row.has("confirm_remove"):
		if busy: return
		cancel(); server = removing.duplicate(true); request("remove")
	elif row.has("cancel_remove"): removing = {}; view = "remove_servers"; menu._reset_navigation()
	elif row.has("server_account"):
		server = row.server_account.duplicate(true); capabilities = server.get("capabilities", {"navigation": [], "facets": [], "filters": [], "sorts": ["created_at", "title"], "favorite_scope": "local", "search": true}); library_id = ""; textures.clear(); failed_covers.clear(); open_home()
	elif row.has("resume"): _play(row.scene, int(row.scene.get("position_ms", -1)))
	elif row.has("container_node"):
		_remember(); folder_path.append(row.container_node); query.parent_id = row.container_node.id; query.mode = "folders"; browse()
	elif row.has("library"):
		_remember(); library_id = str(row.library.id); actor_name = ""; labels.clear(); folder_path.clear()
		query = {"page": 1, "q": "", "mode": "library", "collection_type": str(row.library.get("collection_type", ""))}; browse()
	elif row.has("facet") or row.has("detail_filter") or row.has("unclassified"):
		if row.get("category", "") == "performers" and capabilities.get("artwork", false):
			open_actor(row.get("detail_filter", row.get("facet", {}))); return
		_remember()
		if row.has("unclassified"): query.unclassified = row.unclassified
		else:
			var category := str(row.get("category", kind)); var item: Dictionary = row.get("facet", row.get("detail_filter", {}))
			query[category] = [str(item.id)]; query.erase("exclude_" + category); query.erase("unclassified"); labels[category + "/" + str(item.id)] = str(item.name)
		query.erase("mode"); query.erase("parent_id"); folder_path.clear(); browse()
	elif row.has("scene"):
		var args := {"scene_id": str(row.scene.id)}
		if row.get("recent_opened", false):
			args.recent_position_ms = int(row.scene.get("position_ms", 0)); entries = home_recent_entries()
		_remember(); cancel(); detail = {}; view = "detail"; menu._reset_navigation(); request("detail", args)
	elif row.has("category"):
		_remember(); cancel(); kind = str(row.category); exclude = false; view = "candidates"; candidate_q = ""; candidate_page = 1; get_candidates()
	elif row.has("candidate"): set_filter(kind, row.candidate, exclude)
	elif row.has("play_scene") or row.has("marker"):
		var node: Dictionary = gallery.playback_node()
		_play(node, int(row.marker.position_ms) if row.has("marker") else int(node.get("position_ms", -1)))
	elif row.has("favorite"): _toggle_favorite()
	elif row.has("saved_filter"):
		_remember(); query = row.saved_filter.query.duplicate(true); library_id = str(query.get("library_id", library_id)); labels = row.saved_filter.get("labels", {}).duplicate(true); browse()
	elif row.has("reset"):
		var context := {}
		for key in ["mode", "parent_id", "favorites"]:
			if query.has(key): context[key] = query[key]
		query = {"page": 1, "q": "", "all_tags": true}; query.merge(context); labels.clear()
	elif row.has("toggle"):
		var key: String = row.toggle
		match key:
			"descendants": query[key] = not query.get(key, false)
			"watched":
				if not query.has(key): query[key] = true
				elif query[key]: query[key] = false
				else: query.erase(key)
			_: cycle(key, {"min_duration": [0, 600, 1200, 1800, 3600], "min_rating": [0, 20, 40, 60, 80], "resolution": ["", "FOUR_K", "SIX_K", "EIGHT_K"]}[key])
	elif row.has("open_libraries"): _remember(); cancel(); view = "libraries"; menu._reset_navigation()
	elif row.has("refresh_server"): folder_artwork.clear(); open_home()
	elif row.has("open_saved"): _remember(); cancel(); view = "saved"; menu._reset_navigation()
	elif row.has("edit_server"): cancel(); menu.account_panel.open("server", true)
	menu.refresh()

func _play(node: Dictionary, position: int) -> void:
	menu.collections.selected_location = preload("res://scripts/media_location.gd").capture(menu, node)
	menu.collections.selected_entry = node.duplicate(true)
	selection = node.duplicate(true); selection.start_ms = position
	menu.remember_playback_context()
	menu.dismiss(); menu.chosen.emit(str(node.uri), str(node.get("title", "Video")))

func open_actor(actor: Dictionary) -> void:
	_remember(); actor_name = str(actor.get("name", "")); labels.clear(); folder_path.clear()
	query = {"page": 1, "q": "", "performers": [str(actor.id)], "all_libraries": true}
	labels["performers/" + str(actor.id)] = actor_name
	browse()

func playback_entries() -> Array:
	var parts: Array = detail.get("parts", [])
	var uri := str(selection.get("uri", ""))
	if uri.is_empty() and (view == "detail" or menu.compact) and menu.current_file_provider.is_valid(): uri = str(menu.current_file_provider.call())
	if parts.any(func(part): return part.get("uri", "") == uri): return parts
	return entries

func _is_favorite(node: Dictionary) -> bool:
	if capabilities.get("favorite_scope", "local") == "server": return bool(node.get("favorite", false))
	return favorites.get(str(server.get("id", "")), []).any(func(item): return str(item.id) == str(node.get("id", "")))

func _toggle_favorite() -> void:
	if detail.is_empty() or busy: return
	var selected := not _is_favorite(detail)
	if capabilities.get("favorite_scope", "local") == "server": request("favorite", {"scene_id": detail.id, "favorite": selected}); return
	var id := str(server.get("id", "")); var current: Array = favorites.get(id, []).duplicate(true)
	if selected:
		var item := {}
		for key in ["id", "uri", "title", "basename", "duration_ms", "width", "height", "year", "rating", "watched", "genres", "tags", "performers", "studios"]:
			if detail.has(key): item[key] = detail[key]
		current.append(item)
	else: current = current.filter(func(item): return str(item.id) != str(detail.id))
	var previous: Array = favorites.get(id, []).duplicate(true)
	favorites[id] = current.slice(0, 1000)
	if _save_favorites(): _favorite_changed(str(detail.id), selected)
	else: favorites[id] = previous

func _local_favorites_query() -> Array:
	var result: Array = favorites.get(str(server.get("id", "")), []).duplicate(true)
	result = result.filter(func(item):
		if not str(query.get("q", "")).is_empty() and not str(item.get("title", "")).containsn(str(query.q)): return false
		if int(item.get("duration_ms", 0)) < int(query.get("min_duration", 0)) * 1000 or int(item.get("rating", 0)) < int(query.get("min_rating", 0)): return false
		if query.has("watched") and (not item.has("watched") or bool(item.watched) != bool(query.watched)): return false
		for category in FILTER_NAMES:
			var ids: Array = item.get(category, []).map(func(facet): return str(facet.get("id", "")))
			var include: Array = query.get(category, []); var exclude_ids: Array = query.get("exclude_" + category, [])
			if not include.is_empty() and (not include.all(func(id): return id in ids) if category == "tags" and query.get("all_tags", true) else not include.any(func(id): return id in ids)): return false
			if exclude_ids.any(func(id): return id in ids): return false
		return true)
	var sort_key := str(query.get("sort", "created_at"))
	if sort_key == "title": result.sort_custom(func(a, b): return str(a.title).naturalnocasecmp_to(str(b.title)) < 0)
	elif sort_key in ["duration", "rating100", "date"]:
		var key: String = {"duration": "duration_ms", "rating100": "rating", "date": "year"}[sort_key]
		result.sort_custom(func(a, b): return int(a.get(key, 0)) > int(b.get(key, 0)))
	if (sort_key == "title" and query.get("direction", "ASC") == "DESC") or (sort_key != "title" and query.get("direction", "DESC") == "ASC"): result.reverse()
	return result

func _favorite_changed(id: String, selected: bool) -> void:
	for item in entries:
		if str(item.get("id", "")) == id: item.favorite = selected
	for previous in history:
		for item in previous.entries:
			if str(item.get("id", "")) == id: item.favorite = selected
		if previous.query.get("favorites", false) and not selected:
			var before: int = previous.entries.size()
			previous.entries = previous.entries.filter(func(item): return str(item.get("id", "")) != id)
			previous.total = maxi(0, int(previous.total) - before + previous.entries.size())

func _save_favorites() -> bool:
	var config := ConfigFile.new()
	for id in favorites: config.set_value("favorites", str(id), favorites[id])
	DirAccess.make_dir_recursive_absolute("user://settings")
	if config.save("user://settings/server_favorites.cfg") != OK:
		menu.status = "Unable to save favorites"; return false
	return true

func _save_filters() -> void:
	var config := ConfigFile.new(); config.set_value("filters", "items", saved)
	DirAccess.make_dir_recursive_absolute("user://settings")
	if config.save("user://settings/server_filters.cfg") != OK: menu.status = "Unable to save filters"

func cycle(key: String, values: Array) -> void:
	var at: int = values.find(query.get(key, values[0])); var next: Variant = values[(at + 1) % values.size()]
	if next == values[0]: query.erase(key)
	else: query[key] = next

func set_filter(category: String, item: Dictionary, negative: bool) -> void:
	var key := ("exclude_" if negative else "") + category; var other := ("" if negative else "exclude_") + category
	var ids: Array = query.get(key, []).duplicate(); var id := str(item.id)
	if id in ids: ids.erase(id)
	else: ids.append(id)
	query[key] = ids; var opposite: Array = query.get(other, []).duplicate(); opposite.erase(id); query[other] = opposite
	labels[category + "/" + id] = str(item.name)

func get_candidates(append: bool = false) -> void:
	if not append: cancel(); candidates = []; candidate_page = 1; candidate_end = false; menu._reset_navigation()
	request("candidates", {"kind": kind, "q": candidate_q, "page": candidate_page + 1 if append else 1, "library_id": library_id})

func more() -> void:
	if busy: return
	if view == "scenes" and not end_reached and entries.size() < total:
		var next := query.duplicate(true); next.page = loaded_page + 1; request("browse", next)
	elif view in ["facets", "candidates"] and not candidate_end and candidates.size() < candidate_total: get_candidates(true)

func scroll_changed() -> void:
	if view not in ["scenes", "facets", "candidates"] or busy or menu._max_scroll() <= 0: return
	if menu.scroll >= menu._max_scroll() - 2.0: more()

func _navigate(section: String) -> void:
	history.clear(); labels.clear(); folder_path.clear(); keyboard = ""; candidate_q = ""; actor_name = ""
	query = {"page": 1, "q": "", "all_tags": true}
	if section == "home": open_home()
	elif section in FILTER_NAMES:
		cancel(); kind = section; view = "facets"; get_candidates(); menu.refresh()
	else:
		if section == "folders": query.mode = "folders"
		if section == "favorites":
			query.favorites = true
			if capabilities.get("favorite_scope", "local") != "server":
				cancel(); view = "scenes"; entries = favorites.get(str(server.id), []).duplicate(true); total = entries.size(); end_reached = true; menu._reset_navigation(); menu.refresh(); return
		browse()

func action(target: int) -> bool:
	if target < ACTION: return false
	if sorting():
		if target >= ACTION + 170 and target < ACTION + 170 + SORTS.size():
			var sort: String = SORTS[target - ACTION - 170]
			if sort in available_sorts(): sort_query.sort = sort
		elif target in [ACTION + 175, ACTION + 176]: sort_query.direction = "ASC" if target == ACTION + 175 else "DESC"
		elif target == ACTION + 11: _apply_sort(); return true
		elif target in [ACTION, ACTION + 4, ACTION + 177]: sort_query.clear()
		menu.refresh(); return true
	if target == ACTION + 19 and focused():
		sources_open = not sources_open; menu.refresh(); return true
	if media_content() and target in [ACTION + 160, ACTION + 161, ACTION + 162, ACTION + 163]:
		if target == ACTION + 163: set_display(scene_view(), (scene_size() + 1) % 3)
		else: set_display(["poster", "thumb", "list"][target - ACTION - 160])
		return true
	if not keyboard.is_empty(): return _keyboard_action(target)
	if gallery.action(target): return true
	if target >= ACTION + 200 and target < ACTION + 200 + chips.size():
		var chip: Dictionary = chips[target - ACTION - 200]
		if chip.key == "unclassified": query.erase("unclassified")
		else: var ids: Array = query.get(chip.key, []).duplicate(); ids.erase(chip.id); query[chip.key] = ids
		browse(); return true
	if target >= ACTION + 100 and target < ACTION + 100 + _navigation().size():
		_navigate(_navigation()[target - ACTION - 100]); return true
	match target - ACTION:
		0: back()
		1, 14: cancel(); menu.account_panel.open("server", target == ACTION + 14)
		2: _remember(); keyboard = "search"; text = candidate_q if view in ["candidates", "facets"] else str(query.get("q", ""))
		3: _remember(); cancel(); view = "filters"; menu._reset_navigation()
		4:
			if view != "scenes" or busy or available_sorts().is_empty(): return true
			sort_query = {"sort": str(query.get("sort", "created_at")), "direction": str(query.get("direction", "DESC"))}
			menu._drag.clear(); menu._fling = 0.0
		6: more()
		7:
			if kind in capabilities.get("exclude_facets", []): exclude = not exclude
		8:
			if capabilities.get("tag_match_all", false): query.all_tags = not query.get("all_tags", true)
		9: keyboard = "save"; text = ""
		10: _remember(); cancel(); view = "saved"; menu._reset_navigation()
		11: browse()
		12:
			if busy: return true
			if view == "servers": load_servers()
			elif view == "home": open_home()
			elif view in ["facets", "candidates"]: get_candidates()
			elif loaded_page > 0 and entries.size() < total and not end_reached: more()
			else: browse()
		13: cancel(); view = "remove_servers"; menu._reset_navigation()
		15: _remember(); cancel(); view = "options"; menu._reset_navigation()
		17: _navigate("favorites")
		18:
			cancel(); menu.account_panel.close(); menu.account_panel.kind = "server"; menu.account_panel.start("server", str(server.get("provider", "")), str(server.get("id", "")))
	if target in [ACTION + 2, ACTION + 9]: _begin_text_input()
	menu.refresh(); return true

func _begin_text_input() -> void:
	menu.system_text_input.begin("media_server_search", text, 200, _draft_changed, _input_submitted, _input_cancelled)

func _draft_changed(value: String) -> void:
	if keyboard.is_empty(): return
	text = value; menu.refresh()

func _input_submitted(value: String) -> void:
	if keyboard.is_empty(): return
	text = value; _keyboard_action(ACTION + 26)

func _input_cancelled(value: String) -> void:
	if not keyboard.is_empty(): text = value; menu.refresh()

func _keyboard_action(target: int) -> bool:
	match target - ACTION:
		27: _begin_text_input()
		28, 29:
			var value := ""
			if target == ACTION + 28:
				value = text + (menu.platform.media_clipboard_text() if Methods.supports(menu.platform, "media_clipboard_text") else DisplayServer.clipboard_get())
			text = menu.SystemTextInput.clean(value, 200)
			if menu.system_text_input.active("media_server_search"): menu.system_text_input.set_text("media_server_search", text)
			else: _begin_text_input()
		25: keyboard = ""; if not history.is_empty(): history.pop_back()
		26:
			text = menu.system_text_input.finish("media_server_search", text)
			var purpose := keyboard; keyboard = ""
			if purpose == "save":
				if not text.strip_edges().is_empty():
					saved = saved.filter(func(item): return not (item is Dictionary and item.get("server_id") == server.get("id") and item.get("name") == text.strip_edges()))
					saved.append({"server_id": server.id, "name": text.strip_edges(), "query": query.duplicate(true), "labels": labels.duplicate(true)})
					if saved.size() > 100: saved.pop_front()
					_save_filters()
			elif view in ["candidates", "facets"]: candidate_q = text; get_candidates()
			else: query.q = text; query.erase("mode"); query.erase("parent_id"); folder_path.clear(); browse()
	if target == ACTION + 25: menu.system_text_input.cancel("media_server_search")
	menu.refresh(); return true

func _navigation() -> Array:
	return ["home", "all"] + capabilities.get("navigation", []).slice(0, 3)

func cover(row: Dictionary) -> Texture2D:
	var node: Dictionary = row.get("scene", row.get("container_node", {}))
	if media_content(): node = display_node(node)
	return image_texture(node)

func _image_request(node: Dictionary) -> Dictionary:
	var image: Dictionary = node.get("cover_image", {})
	if image.is_empty(): return {"scene_id": str(node.get("id", ""))}
	return {"scene_id": str(image.get("id", "")), "image_type": str(image.get("image_type", "Primary")), "image_index": int(image.get("image_index", 0)), "image_tag": str(image.get("image_tag", "")), "max_width": int(image.get("max_width", 512))}

func _request_image_key(value: Dictionary) -> String:
	var key := str(value.get("server_id", server.get("id", ""))) + "/" + str(value.get("scene_id", ""))
	if value.has("image_type"): key += "/" + JSON.stringify([value.image_type, value.get("image_index", 0), value.get("image_tag", ""), value.get("max_width", 512)])
	return key

func image_texture(node: Dictionary) -> Texture2D:
	if node.is_empty() or not node.get("has_cover", true): return null
	var req := _image_request(node)
	if str(req.scene_id).is_empty(): return null
	var key := _request_image_key(req)
	if textures.has(key): return textures[key]
	if covers.has(key):
		var image := Image.new()
		if image.load(str(covers[key])) == OK:
			var texture := ImageTexture.create_from_image(image)
			var pixels := texture.get_width() * texture.get_height()
			for held in textures.values(): pixels += held.get_width() * held.get_height()
			while not textures.is_empty() and (textures.size() >= 24 or pixels > 24 * 512 * 512):
				var oldest: Variant = textures.keys()[0]
				pixels -= textures[oldest].get_width() * textures[oldest].get_height(); textures.erase(oldest)
			textures[key] = texture; return texture
		covers.erase(key)
	var active: Array = pending.values().filter(func(p): return p.action == "cover")
	if menu.visible and not failed_covers.has(key) and active.size() < 2 and not active.any(func(p): return _request_image_key(p) == key): request("cover", req)
	return null

func prioritize_covers() -> void:
	var nodes: Array = []
	if gallery.fixed(): nodes = gallery.priority_nodes()
	elif view == "home" or (view == "scenes" and (grid() or media_content())):
		var first: int = menu._first_line() * menu._cols()
		for row in menu.rows.slice(first, first + menu._drawn_slots()):
			var node: Dictionary = row.get("scene", row.get("container_node", {}))
			if not node.is_empty(): nodes.append(node)
	elif view in ["detail", "metadata"] and not detail.is_empty(): nodes.append(detail)
	var visible_keys: Array = nodes.map(func(node): return _request_image_key(_image_request(display_node(node) if media_content() else node)))
	var visible_folders: Array = nodes.map(func(node): return str(node.get("id", ""))) if movie_folders() else []
	for id in pending.keys():
		var req: Dictionary = pending[id]
		if (req.action == "cover" and _request_image_key(req) not in visible_keys) or (req.action == "folder_artwork" and str(req.scene_id) not in visible_folders):
			if menu.platform: menu.platform.media_server_cancel(int(id))
			pending.erase(id)
	for node in nodes: _request_folder_artwork(node)

func _fit_picture(picture: MeshInstance3D, texture: Texture2D, area: Vector2) -> void:
	var size := texture.get_size()
	if size.x > 0 and size.y > 0: picture.mesh.size = size * minf(area.x / size.x, area.y / size.y)

func tile(target: int, row: Dictionary, center: Vector2) -> void:
	if media_content():
		_media_tile(target, row, center); return
	menu._button(target, "", center, Vector2(0.30, 0.27), true, "", false, menu._list)
	var node: MeshInstance3D = menu._buttons.back().node
	var picture: MeshInstance3D = menu._quad(Vector2(0.278, 0.192), Vector3(0, 0.026, 0.003), menu.TILE, 12); node.add_child(picture)
	var texture := cover(row)
	if texture:
		var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; picture.material_override = material; _fit_picture(picture, texture, Vector2(0.278, 0.192))
		gallery.style_hover_picture(picture)
	else: menu._icon(str(row.get("icon", "video")), Vector3(0, 0.026, 0.006), 0.064, menu.MUTED, node)
	var title: Label3D = menu._label(menu._fit_title(str(row.title), "", 0.265, 22), Vector3(0, -0.087, 0.006), 22, node)
	if title.text != str(row.title): menu._tips[target] = str(row.title)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var info: Dictionary = menu.Presentation.info(row, menu.catalog)
	var metadata := str(row.get("detail", ""))
	if view == "scenes": metadata = str(info.card_detail)
	var meta: Label3D = menu._label(menu._fit_title(metadata, "", 0.265, 16), Vector3(0, -0.119, 0.006), 16, node); meta.modulate = menu.MUTED
	menu._progress_on(node, float(info.ratio), Vector2(0, -0.068), 0.265)

func _media_tile(target: int, row: Dictionary, center: Vector2) -> void:
	var size := tile_size()
	menu._button(target, "", center, size, true, "", false, menu._list)
	var card: MeshInstance3D = menu._buttons.back().node
	var area := size - Vector2(0.016, 0.065)
	var picture: MeshInstance3D = menu._quad(area, Vector3(0, 0.026, 0.004), menu.TILE, 12); card.add_child(picture)
	var texture := cover(row)
	if texture:
		var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; picture.material_override = material; _fit_picture(picture, texture, area)
		gallery.style_hover_picture(picture)
	else: menu._icon(str(row.get("icon", "video")), Vector3(0, 0.026, 0.006), 0.055, menu.MUTED, card)
	var title: Label3D = menu._label(menu._fit_title(str(row.title), "", size.x - 0.025, 20), Vector3(0, -size.y / 2 + 0.034, 0.006), 20, card)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var info: Dictionary = menu.Presentation.info(row, menu.catalog)
	var meta: Label3D = menu._label(menu._fit_title(str(info.card_detail), "", size.x - 0.025, 14), Vector3(0, -size.y / 2 + 0.012, 0.006), 14, card); meta.modulate = menu.MUTED
	menu._progress_on(card, float(info.ratio), Vector2(0, -size.y / 2 + 0.05), size.x - 0.024)
	if title.text != str(row.title): menu._tips[target] = str(row.title)

func wrapped_lines(value: String, width: float, size: int) -> Array[String]:
	var result: Array[String] = []; var line := ""; var length := 0.0; var widths := {}
	for character in value.replace("\r", ""):
		if character == "\n": result.append(line); line = ""; length = 0; continue
		if not widths.has(character): widths[character] = menu.text_width(character, size)
		var advance: float = widths[character]
		if length + advance > width and not line.is_empty(): result.append(line); line = ""; length = 0
		line += character; length += advance
	result.append(line)
	return result

func media_row(target: int, row: Dictionary, center: Vector2) -> void:
	menu._button(target, "", center, Vector2(1.38, 0.112), true, "", false, menu._list)
	var card: MeshInstance3D = menu._buttons.back().node
	gallery._picture(display_node(row.get("scene", row.get("container_node", {})), "list"), Vector2(-0.62, 0), Vector2(0.085, 0.098), card)
	var name := str(row.get("title", "")).strip_edges()
	if name.is_empty(): name = filename(row)
	var lines := wrapped_lines(name, 1.19, 20)
	if lines.size() > 2: lines[1] = menu._fit_title(lines[1] + "…", "", 1.19, 20)
	var title: Label3D = menu._label("\n".join(lines.slice(0, 2)), Vector3(-0.555, 0.044, 0.007), 20, card)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	var info: Dictionary = menu.Presentation.info(row, menu.catalog)
	var meta: Label3D = menu._label(menu._fit_title(str(info.subtitle), "", 1.18, 14), Vector3(-0.555, -0.039, 0.007), 14, card)
	meta.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; meta.modulate = menu.MUTED
	menu._progress_on(card, float(info.ratio), Vector2(0.04, -0.052), 1.22)
	if lines.size() > 2:
		var original := filename(row)
		menu._tips[target] = name + ("\n" + original if not original.is_empty() and original != name else "")

func draw() -> void:
	if focused(): _draw_sources_button()
	if not keyboard.is_empty(): _draw_keyboard(); return
	prioritize_covers()
	var top: float = 0.62 if focused() else 0.46
	menu._button(ACTION, "", Vector2(-0.40 if focused() else -0.52, top), Vector2(0.09, 0.07), view != "servers", "up")
	var management := view in ["servers", "remove_servers", "confirm_remove"]
	var caption := I18n.t("Remove server") if view in ["remove_servers", "confirm_remove"] else str(server.get("name", I18n.t("Media servers")))
	var heading: Label3D = menu._label(menu._fit_title(caption, "", 0.73 if focused() else 0.77, 22), Vector3(-0.32 if focused() else -0.43, top, 0.004), 22); heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if view == "servers":
		for item in [[1, "plus"], [14, "edit"], [12, "refresh"], [13, "trash"]]: menu._button(ACTION + item[0], "", Vector2(0.43 + (0.12 * ([1, 14, 12, 13].find(item[0]))), 0.46), Vector2(0.09, 0.07), not busy or int(item[0]) in [1, 14], item[1])
	elif not management:
		if capabilities.get("search", true) or query.get("favorites", false) or view in ["facets", "candidates"]: menu._button(ACTION + 2, "", Vector2(0.55, top), Vector2(0.09, 0.07), view != "filters", "search")
		menu._button(ACTION + 17, "", Vector2(0.67, top), Vector2(0.09, 0.07), not busy and view != "filters", "heart"); menu._tips[ACTION + 17] = I18n.t("Favorites" if capabilities.get("favorite_scope", "local") == "server" else "On-device favorites")
		menu._button(ACTION + 15, "", Vector2(0.79, top), Vector2(0.09, 0.07), view != "filters", "more"); menu._tips[ACTION + 15] = I18n.t("Server options")
		var tabs: Array = [] if view in ["detail", "picture", "overview"] and capabilities.get("artwork", false) else _navigation()
		for i in tabs.size():
			var name: String = {"home": "Home", "all": "All", "folders": "Folders"}.get(tabs[i], FILTER_NAMES.get(tabs[i], tabs[i]))
			menu._button(ACTION + 100 + i, I18n.t(name), Vector2(-0.37 + i * 0.263, 0.49 if focused() else 0.345), Vector2(0.25, 0.063), view != "filters")
			menu._lit((view == "home" and tabs[i] == "home") or (view == "scenes" and tabs[i] == ("folders" if query.get("mode", "") == "folders" else "all")) or (view == "facets" and tabs[i] == kind))
		if view not in ["detail", "overview"] or not capabilities.get("artwork", false): _draw_context()
	chips = []
	for category in FILTER_NAMES:
		for prefix in ["", "exclude_"]:
			for id in query.get(prefix + category, []): chips.append({"key": prefix + category, "id": id, "label": ("− " if prefix != "" else "") + str(labels.get(category + "/" + id, id))})
	if query.has("unclassified"): chips.append({"key": "unclassified", "id": "", "label": I18n.t("Uncategorized")})
	if view == "scenes":
		if media_content():
			for i in 3:
				menu._button(ACTION + 160 + i, "", Vector2(0.33 + i * 0.1, 0.365), Vector2(0.085, 0.065), true, ["poster", "image", "list"][i]); menu._lit(scene_view() == ["poster", "thumb", "list"][i]); menu._tips[ACTION + 160 + i] = I18n.t(["Poster view", "Thumbnail view", "List view"][i])
				if scene_view() == ["poster", "thumb", "list"][i]:
					var node: MeshInstance3D = menu._buttons.back().node
					node.material_override.set_shader_parameter("surface_color", menu.SELECTED)
					node.add_child(menu._quad(Vector2(0.028, 0.003), Vector3(0, -0.025, 0.006), menu.ACCENT, 14))
			menu._button(ACTION + 163, I18n.t(["Small", "Medium", "Large"][scene_size()]), Vector2(0.655, 0.365), Vector2(0.14, 0.065), scene_view() != "list")
			menu._tips[ACTION + 163] = I18n.t("Poster size")
		else: menu.draw_view_modes(0.245, 0.44)
		menu._button(ACTION + 3, "", Vector2(0.81 if media_content() else 0.79, 0.365 if media_content() else 0.245), Vector2(0.08, 0.06), not busy, "filter"); menu._tips[ACTION + 3] = I18n.t("Filters")
		menu._button(ACTION + 4, sort_caption(true) if media_content() else "", Vector2(0.045 if media_content() else 0.68, 0.365 if media_content() else 0.245), Vector2(0.37, 0.065) if media_content() else Vector2(0.08, 0.06), not busy and not available_sorts().is_empty(), "" if media_content() else "sort")
		if media_content(): menu.set_label_size(menu._buttons.back().node.get_child(0), 17)
		menu._tips[ACTION + 4] = I18n.t("Sort") + " · " + sort_caption()
		for i in mini(3, chips.size()): menu._button(ACTION + 200 + i, menu._fit_title(str(chips[i].label), "", 0.32, 14) + " ×", Vector2(-0.27 + i * 0.42, -0.595 if media_content() else -0.435), Vector2(0.40, 0.055))
	if view == "candidates":
		if kind in capabilities.get("exclude_facets", []): menu._button(ACTION + 7, I18n.t("Exclude" if exclude else "Include"), Vector2(0.1, -0.44), Vector2(0.24, 0.065))
		if kind == "tags" and capabilities.get("tag_match_all", false): menu._button(ACTION + 8, I18n.t("Match all" if query.get("all_tags", true) else "Match any"), Vector2(0.40, -0.44), Vector2(0.30, 0.065))
	if view in ["scenes", "facets", "candidates"]:
		var count := candidate_total if view in ["facets", "candidates"] else total; var loaded := candidates.size() if view in ["facets", "candidates"] else entries.size()
		var bottom: float = -0.655 if media_content() else -0.515
		menu._label("%d / %d" % [loaded, count], Vector3(-0.36, bottom, 0.004), 15)
		var has_more := not candidate_end if view in ["facets", "candidates"] else not end_reached
		if loaded < count and has_more: menu._button(ACTION + 6, I18n.t("More"), Vector2(0.73, bottom), Vector2(0.18, 0.065), not busy)
		if view == "scenes": menu._button(ACTION + 9, "", Vector2(0.52, bottom), Vector2(0.08, 0.065), not busy, "bookmark_add"); menu._tips[ACTION + 9] = I18n.t("Save search")
	elif view == "filters": menu._button(ACTION + 11, I18n.t("Apply"), Vector2(0.55, -0.345), Vector2(0.30, 0.065))
	if not menu.status.is_empty() and menu.status != "Server authentication required":
		menu._label(I18n.t(menu.status), Vector3(0.15, -0.57, 0.004), 15)
		if not busy: menu._button(ACTION + 12, "", Vector2(0.79, -0.565), Vector2(0.08, 0.06), true, "refresh")
	if menu.status == "Server authentication required" and not management:
		_draw_sign_in_required()
	elif gallery.home(): gallery.draw_home()
	elif gallery.rich_detail() and not detail.is_empty(): gallery.draw_detail()
	elif view == "picture": gallery.draw_picture()
	elif view == "overview": gallery.draw_overview()
	elif view == "home": _draw_home()
	elif view == "filters": _draw_filters()
	elif view in ["detail", "metadata"] and not detail.is_empty(): _draw_detail()
	else: menu._draw_rows()
	if sorting(): _draw_sort()

func _draw_sources_button() -> void:
	menu._button(ACTION + 19, "", Vector2(-0.59, 0.62), Vector2(0.16, 0.07), true, "menu")
	menu._lit(sources_open); menu._tips[ACTION + 19] = I18n.t("Main menu")
	if sources_open: menu._buttons.back().node.material_override.set_shader_parameter("surface_color", menu.SELECTED)

func _draw_sort() -> void:
	for button in menu._buttons: button.enabled = false
	var dim: MeshInstance3D = menu._quad(menu._backdrop.mesh.size, menu._backdrop.position + Vector3(0, 0, 0.02), Color(0, 0, 0, 0.15), 24)
	# UI plates become opaque in compositor captures; the dimmer must retain its alpha.
	dim.material_override = menu._material(Color(0, 0, 0, 0.15), 24)
	menu.add_child(dim); menu._decorations.append(dim)
	menu._text_button(ACTION + 177, "", Vector2(menu._backdrop.position.x, menu._backdrop.position.y), menu._backdrop.mesh.size)
	menu._buttons.back().node.position.z = 0.026
	var sorts := available_sorts(); var rows := ceili(sorts.size() / 2.0)
	var direction_y := 0.16 - rows * 0.09 - 0.035; var apply_y := direction_y - 0.13
	var size := Vector2(1.02, 0.31 - apply_y + 0.065)
	var panel: MeshInstance3D = menu._quad(size, Vector3(0.12, 0.31 - size.y / 2, 0.032), menu.PANEL, 30)
	menu.add_child(panel); menu._decorations.append(panel); menu._block_rays(panel, size)
	var label: Label3D = menu._label(I18n.t("Sort"), Vector3(-0.325, 0.25, 0.043), 21); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.render_priority = 32
	_sort_button(ACTION + 177, "", Vector2(0.56, 0.25), Vector2(0.06, 0.06), false, "close")
	for index in sorts.size():
		var i: int = SORTS.find(sorts[index])
		_sort_button(ACTION + 170 + i, I18n.t(SORT_NAMES[i]), Vector2(-0.115 + (index % 2) * 0.46, 0.16 - (index / 2) * 0.09), Vector2(0.42, 0.065), sort_query.sort == SORTS[i])
	for i in 2:
		_sort_button(ACTION + 175 + i, I18n.t("Ascending" if i == 0 else "Descending") + (" ↑" if i == 0 else " ↓"), Vector2(-0.115 + i * 0.46, direction_y), Vector2(0.42, 0.065), sort_query.direction == ("ASC" if i == 0 else "DESC"))
	_sort_button(ACTION + 11, I18n.t("Apply"), Vector2(0.12, apply_y), Vector2(0.30, 0.065))

func _sort_button(target: int, text_value: String, center: Vector2, size: Vector2, selected: bool = false, icon: String = "") -> void:
	menu._button(target, text_value, center, size, true, icon)
	menu._lit(selected)
	var node: MeshInstance3D = menu._buttons.back().node
	node.position.z = 0.04; node.material_override.render_priority = 31
	node.material_override.set_shader_parameter("surface_color", menu._buttons.back().base_color)
	for child in node.get_children():
		if child is MeshInstance3D and child.material_override: child.material_override.render_priority = 32
	menu.set_label_size(node.get_child(0), 18)
	(node.get_child(0) as Label3D).render_priority = 32

func _draw_sign_in_required() -> void:
	menu._label(I18n.t("Server authentication required"), Vector3(0.16, 0.045, 0.009), 26)
	menu._button(ACTION + 18, I18n.t("Sign in again"), Vector2(0.16, -0.08), Vector2(0.46, 0.10), not busy, "", true)

func _draw_context() -> void:
	var context := ""
	for library in home_data.get("libraries", []):
		if str(library.id) == library_id: context = str(library.title)
	if view in ["facets", "candidates"]: context = I18n.t(FILTER_NAMES.get(kind, kind))
	elif view in ["detail", "metadata", "picture"]: context = str(detail.get("title", "…"))
	elif view == "filters": context = I18n.t("Filters")
	elif view == "saved": context = I18n.t("Saved searches")
	elif query.get("favorites", false): context = I18n.t("Favorites" if capabilities.get("favorite_scope", "local") == "server" else "On-device favorites")
	elif query.get("all_libraries", false): context = actor_name
	if not folder_path.is_empty(): context += " / " + " / ".join(folder_path.map(func(node): return str(node.title)))
	var label: Label3D = menu._label(menu._fit_title(context, "", 0.30 if media_content() else (0.84 if view == "scenes" else 1.0), 15), Vector3(-0.48, 0.365 if media_content() else (0.395 if focused() else 0.245), 0.004), 15); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = menu.MUTED

func _draw_home() -> void:
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var resume := _resume_entries(); var row_offset := 0
	var latest_y := 0.11
	if not resume.is_empty():
		menu._label(I18n.t("Continue watching"), Vector3(-0.25, 0.195, 0.004), 21)
		var item: Dictionary = resume[0]; var row := _node_row(item)
		menu._button(menu.ROW_BASE, "", Vector2(0.16, 0.065), Vector2(1.24, 0.18), true, "", false, menu._list)
		var node: MeshInstance3D = menu._buttons.back().node
		var frame: MeshInstance3D = menu._quad(Vector2(0.18, 0.14), Vector3(-0.50, 0, 0.004), menu.TILE, 12); node.add_child(frame)
		var texture := cover(row)
		if texture: var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; frame.material_override = material; _fit_picture(frame, texture, Vector2(0.18, 0.14))
		else: menu._icon("video", Vector3(-0.5, 0, 0.005), 0.055, menu.MUTED, node)
		var title: Label3D = menu._label(menu._fit_title(str(item.get("title", "Video")), "", 0.70, 23), Vector3(-0.37, 0.041, 0.005), 23, node); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var duration := int(item.get("duration_ms", 0)); var position := int(item.get("position_ms", 0))
		var caption: Label3D = menu._label(_time(position) + (" / " + _time(duration) if duration > 0 else ""), Vector3(-0.37, -0.008, 0.005), 17, node); caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; caption.modulate = menu.MUTED
		menu._icon("play", Vector3(0.51, 0.0, 0.006), 0.047, menu.ACCENT, node)
		if duration > 0: node.add_child(menu._quad(Vector2(0.68 * clampf(float(position) / duration, 0, 1), 0.008), Vector3(-0.37 + 0.34 * clampf(float(position) / duration, 0, 1), -0.05, 0.006), menu.ACCENT, 14))
		row_offset = 1; latest_y = -0.085
	menu._label(I18n.t("Recently added"), Vector3(-0.27, latest_y, 0.004), 21)
	menu._button(ACTION + 101, I18n.t("All") + " · " + str(total) + " ›", Vector2(0.64, latest_y), Vector2(0.34, 0.05))
	for i in mini(4, home_data.get("recent", []).size()): tile(menu.ROW_BASE + i + row_offset, menu.rows[i + row_offset], Vector2(-0.36 + i * 0.333, latest_y - 0.16))
	if menu.rows.is_empty() and not busy and menu.status.is_empty(): menu._label(I18n.t("No items"), Vector3(0.16, -0.05, 0.004), 18)

func _draw_filters() -> void:
	var background: MeshInstance3D = menu._decoration(Vector2(1.16, 0.68), Vector2(0.16, -0.03), menu.PANEL)
	background.position.z = -0.001
	background.material_override.render_priority = 9
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var first: int = menu._first_line()
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var row: Dictionary = menu.rows[i]; var k := i - first
		menu._button(menu.ROW_BASE + k, "", Vector2(0.16, list_top() - k * pitch()), Vector2(1.04, 0.088), true, "", false, menu._list)
		var node: MeshInstance3D = menu._buttons.back().node
		var caption: Label3D = menu._label(menu._fit_title(str(row.title), "", 0.88, 22), Vector3(-0.47, 0, 0.006), 22, node); caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if not str(row.get("detail", "")).is_empty():
			var count: Label3D = menu._label(str(row.detail), Vector3(0.47, 0, 0.006), 17, node); count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; count.modulate = menu.MUTED
	_draw_bar(); menu._place_list()

func _draw_detail() -> void:
	var texture := cover({"scene": detail})
	var panel: MeshInstance3D = menu._decoration(Vector2(0.32, 0.38), Vector2(-0.30, -0.035), menu.TILE)
	if texture: var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; panel.material_override = material; _fit_picture(panel, texture, Vector2(0.32, 0.38))
	var description: Label3D = menu._label(str(detail.get("description", "")).left(100), Vector3(-0.3, -0.265, 0.004), 14)
	description.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY; description.width = 0.33 / description.pixel_size; description.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var first: int = menu._first_line()
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var row: Dictionary = menu.rows[i]; var k := i - first
		menu._button(menu.ROW_BASE + k, menu._fit_title(str(row.title), "", 0.67, 18), Vector2(0.40, list_top() - k * pitch()), Vector2(0.73, 0.082), not busy, "", false, menu._list)
	_draw_bar(); menu._place_list()

func _draw_bar() -> void:
	if menu._max_scroll() > 0:
		var span := bar_span(); var x := 0.75 if view == "filters" else 0.835
		menu._button(menu.SCROLLBAR, "", Vector2(x, span.x - span.y * 0.5), Vector2(0.04, span.y))
		var thumb: float = span.y * visible_lines() / menu._line_count(); menu._bar_thumb = menu._decoration(Vector2(0.012, thumb), Vector2(x, span.x - thumb * 0.5), menu.MUTED)

func _draw_keyboard() -> void:
	menu._label(I18n.t("Save search" if keyboard == "save" else "Search"), Vector3(0.15, 0.46, 0.004), 23)
	menu._button(ACTION + 27, text.right(60) + "│", Vector2(0.15, 0.33), Vector2(1.24, 0.09))
	for item in [[25, "Cancel"], [28, "Paste"], [29, "Clear"], [26, "Save" if keyboard == "save" else "Search"]]:
		menu._button(ACTION + item[0], I18n.t(item[1]), Vector2(-0.36 + [25,28,29,26].find(item[0]) * 0.33, 0.12), Vector2(0.30, 0.08))
