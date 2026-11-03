extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Picker := preload("res://tests/test_subtitle_picker.gd")
const Filter := preload("res://scripts/subtitle_picker_filter.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Host extends Picker.Host:
	var searches: Array[Dictionary] = []
	func media_cloud_search(path: String, query: String, scope: String, kind: String, cursor: String, force: bool) -> int:
		sequence += 1
		searches.append({"id": sequence, "path": path, "query": query, "scope": scope, "kind": kind, "cursor": cursor, "force": force})
		return sequence
	func media_cloud_search_resolve(path: String, token: String) -> int:
		sequence += 1; searches.append({"id": sequence, "path": path, "token": token}); return sequence

class ModernHost extends Host:
	func media_cloud_page_options(path: String, offset: int, _force: bool, order: String, _folder: String, _size: int, subtitles: bool) -> int:
		assert(subtitles)
		return request("cloud", [path, offset, order])

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); print("FAILED: " + label)

func click(menu: Node3D, target: int) -> void:
	var buttons: Array = menu._buttons.filter(func(button): return button.target == target)
	check(buttons.size() == 1 and buttons[0].enabled, "One enabled ray target: %d" % target)
	if buttons.size() != 1: return
	var node: Node3D = buttons[0].node
	var origin := node.to_global(Vector3(0, 0, 1))
	var direction := -node.global_basis.z
	check(int(menu.ray_hit(origin, direction).get("target", -1)) == target, "Ray hits: %d" % target)
	menu.press_pointer("left_hand", origin, direction, true)
	menu.release_pointer("left_hand", origin, direction, true)

func subtitle(name: String, source: String = "file:///storage/Subtitles/") -> Dictionary:
	return {"title": name, "uri": source + name.uri_encode(), "container": false}

static func search_reply(menu: Node, host: Host, entries: Array, next: String = "", override: Dictionary = {}) -> void:
	var data: Dictionary = host.searches.back().duplicate()
	var id := int(data.id)
	data.merge({"state": "ready", "source": "cloud_search", "entries": entries, "next_cursor": next}, true)
	data.merge(override, true)
	menu._on_media_list(id, JSON.stringify(data))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	for pair in [["Spider.Man.2026.mkv", "Spider.Man.2026"], ["电影.2026.1080p.MP4", "电影.2026.1080p"], ["Spider.Man", "Spider.Man"], ["无扩展名", "无扩展名"], ["  Film.iso  ", "Film"], ["", ""], ["https://host/private/token.mp4", ""]]:
		check(Filter.default_query(pair[0]) == pair[1], "Only remove the final known video extension: " + pair[0])
	var video := Video.new()
	video.display_name = "Display title"; video.local_uri = "cloud://saved/Spider.Man.mkv"
	check(video.subtitle_picker_filename() == "Spider.Man.mkv", "Stable filename precedes display title")
	video._bookmark_metadata = {"basename": "Real.Movie.MKV"}
	check(video.subtitle_picker_filename() == "Real.Movie.MKV", "Real metadata filename takes precedence")
	video._bookmark_metadata = {}; video.local_uri = "medialib://saved/scene/7"
	check(video.subtitle_picker_filename() == "Display title", "Opaque media ID is never a filename")
	video.free()
	var host := Host.new()
	var menu := Library.new(); menu.platform = host; root.add_child(menu); menu.set_process(false)
	menu.visible = true
	menu.begin_subtitle_picker({"source": "local", "local": [{"id": "/storage/Subtitles", "title": "Subtitles"}]}, "Spider.Man.mkv")
	var folder := {"id": "/storage/Subtitles/中文", "title": "中文", "container": true}
	var files: Array = [folder, subtitle("Spider.Man.zh.SRT"), subtitle("spider.man.en.ass"), subtitle("Other.srt"), subtitle("Spider.Man.mp4")]
	Picker.reply(menu, host, files)
	check(menu.rows.size() == 4, "Normal subtitle browser keeps folders and supported subtitles")
	click(menu, Filter.OPEN)
	check(menu.subtitle_filter.query == "Spider.Man" and menu.rows.size() == 3, "Default query filters case insensitively and preserves folders")
	check(not menu.system_text_input.active(), "Default query requires no keyboard")
	check(menu._lines() == 6 and not menu._grid(), "Small input leaves six list rows")
	check(host.searches.is_empty(), "Local filtering sends no search")
	click(menu, Filter.INPUT); await process_frame
	check(menu.system_text_input.active("subtitle_filter"), "Ray input opens the shared system editor")
	menu.system_text_input.set_text("subtitle_filter", "Other")
	check(menu.subtitle_filter.query == "Spider.Man", "Unsubmitted draft does not filter or send requests")
	menu.system_text_input._submitted("Other")
	check(menu.rows.size() == 2 and menu.rows[1].title == "Other.srt", "Keyboard completion applies the edited query")
	click(menu, Filter.CLEAR)
	check(menu.rows.size() == 4 and menu.subtitle_filter.query.is_empty(), "Clear restores all subtitles")
	menu.subtitle_filter.apply("*Spider*")
	check(menu.rows.size() == 1 and menu.subtitle_filter.status_text() == "No matching files", "Wildcard text is literal and folders are not counted as matches")
	check(menu.navigate_back() and not menu.subtitle_filter.enabled and menu.subtitle_picker_mode, "Back closes filtering before leaving the picker")
	# Opening/closing a filter restores its original unfiltered list anchor.
	var many: Array = []
	for index in 20: many.append(subtitle("Film.%02d.srt" % index))
	menu._load_section()
	Picker.reply(menu, host, many)
	menu.scroll = 8; menu.refresh(); var anchor := menu.capture_position()
	click(menu, Filter.OPEN); click(menu, Filter.OPEN)
	check(menu.Presentation.position(menu.rows, anchor, 1) == menu.scroll, "Closing restores the unfiltered anchor")
	menu.dismiss()
	menu.visible = true
	menu.begin_subtitle_picker({"source": "smb", "server": "saved", "path": "share/Subtitles"}, "Film.mp4")
	Picker.reply(menu, host, [subtitle("Film.zh.srt", "smb://saved/share/Subtitles/"), subtitle("Other.srt", "smb://saved/share/Subtitles/")])
	click(menu, Filter.OPEN)
	check(menu.rows.size() == 1 and host.searches.is_empty(), "SMB filters its complete listing without cloud requests")
	menu.dismiss()
	var cloud := {"source": "cloud", "cloud": [{"id": "/saved", "title": "Drive"}, {"id": "/saved/Subtitles", "title": "Subtitles"}]}
	menu.visible = true
	menu.begin_subtitle_picker(cloud, "Film.mp4")
	var captions: Array = [subtitle("Film.zh.srt", "cloud://saved/Subtitles/"), subtitle("Other.srt", "cloud://saved/Subtitles/")]
	Picker.reply(menu, host, captions, {"offset": 0, "next_offset": -1, "total": 30, "raw_count": 30, "page_size": 48})
	click(menu, Filter.OPEN); await process_frame
	check(menu.rows.size() == 1 and host.searches.is_empty(), "A complete raw cloud page filters locally even with fewer visible subtitles")
	check(menu.subtitle_filter.cloud_complete(), "Explicit first and last raw page is complete")
	var complete_page: Dictionary = menu._subtitle_cloud_listing.duplicate(true)
	for invalid in [{"next_offset": -2}, {"raw_count": 49, "total": 49}, {"raw_count": 1, "total": 1}, {"total": 31}, {"limited": true}, {"truncated": true}]:
		menu._subtitle_cloud_listing = complete_page.duplicate(true)
		menu._subtitle_cloud_listing.merge(invalid, true)
		check(not menu.subtitle_filter.cloud_complete(), "Invalid or partial raw page cannot claim completeness: " + str(invalid))
	menu._subtitle_cloud_listing = {}
	check(not menu.subtitle_filter.cloud_complete(), "Ordinary cached rows without a subtitle listing cannot claim completeness")
	menu._subtitle_cloud_listing = complete_page
	menu.subtitle_filter.close()
	# A sparse subtitle page with continuation is not a complete directory.
	menu._load_cloud(true)
	Picker.reply(menu, host, captions, {"offset": 0, "next_offset": 48, "total": 96, "raw_count": 48, "page_size": 48})
	click(menu, Filter.OPEN); await process_frame; await process_frame
	check(host.searches.size() == 1 and host.searches.back().query == "Film" and host.searches.back().kind == "subtitle" and host.searches.back().scope == "current", "Incomplete cloud directory uses standard subtitle search")
	check(not menu._buttons.any(func(button): return button.target >= menu.CloudSearch.KIND and button.target < menu.CloudSearch.KIND + 4), "Subtitle search does not expose video/photo type choices")
	search_reply(menu, host, [], "opaque:1")
	check(menu.status == "" and menu.cloud_search.next_cursor == "opaque:1", "Empty search page retains continuation")
	click(menu, menu.CloudSearch.NEXT)
	check(host.searches.back().cursor == "opaque:1", "Standard search paging uses its opaque cursor")
	search_reply(menu, host, [{"title": "Film.en.ass", "container": false, "kind": "subtitle", "search_token": "found:1", "relative_path": "/Subtitles/Film.en.ass"}])
	check(menu.rows.size() == 1 and menu.rows[0].kind == "subtitle", "Standard search results remain subtitle rows")
	var selected: Array = []
	menu.subtitle_selected.connect(func(uri, title, location): selected.append([uri, title, location]))
	click(menu, Library.ROW_BASE)
	check(host.searches.back().token == "found:1", "Selecting a search result uses standard resolve")
	menu._on_media_list(host.searches.back().id, JSON.stringify({"state": "ready", "source": "cloud_search_resolve", "path": "/saved/Subtitles", "token": "found:1", "entry": {"id": "/saved/Subtitles/Film.en.ass", "uri": "cloud://saved/Subtitles/Film.en.ass", "title": "Film.en.ass", "container": false}}))
	check(selected.size() == 1 and selected[0][0] == "cloud://saved/Subtitles/Film.en.ass" and not menu.subtitle_picker_mode and host.opens == 0, "Resolved result selects the exact subtitle without opening a video")
	# Last page alone and unknown continuation must use standard search too.
	for report in [{"offset": 48, "next_offset": -1, "total": 96, "raw_count": 48}, {"offset": 0, "total": -1}]:
		menu._cloud_positions.clear()
		menu.visible = true
		menu.begin_subtitle_picker(cloud, "Next.mp4")
		if report.offset == 48:
			menu._cloud_offsets.assign([0, 48]); menu._load_cloud(false, false, 1)
		Picker.reply(menu, host, captions, report)
		var before := host.searches.size()
		click(menu, Filter.OPEN); await process_frame; await process_frame
		check(host.searches.size() == before + 1, "Last page or unknown completeness must search: " + str(report))
		var request: Dictionary = host.searches.back().duplicate()
		click(menu, Filter.OPEN)
		check(host.cancellations.has(request.id), "Closing cancels the outstanding standard search")
		request.merge({"state": "ready", "source": "cloud_search", "entries": [{"title": "late.srt", "search_token": "late"}]}, true)
		menu._on_media_list(request.id, JSON.stringify(request))
		check(not menu.rows.any(func(row): return row.title == "late.srt"), "Closed search cannot insert late results")
		menu.dismiss()
	# A new query cancels the old request; changing sources cancels the replacement.
	menu._cloud_positions.clear(); menu.visible = true; menu.begin_subtitle_picker(cloud, "Film.mp4")
	Picker.reply(menu, host, captions, {"next_offset": 48, "total": 96, "raw_count": 48})
	click(menu, Filter.OPEN); await process_frame; await process_frame
	var obsolete: Dictionary = host.searches.back().duplicate()
	menu.subtitle_filter.apply("Different"); await process_frame; await process_frame
	check(host.cancellations.has(obsolete.id) and host.searches.back().query == "Different", "Applying a new query cancels the previous request")
	var pending: Dictionary = host.searches.back().duplicate()
	menu._activate(Library.NAV_BASE + Library.Section.LOCAL)
	check(host.cancellations.has(pending.id) and not menu.cloud_search.active, "Changing source cancels standard search")
	obsolete.merge({"state": "ready", "source": "cloud_search", "entries": [{"title": "late.srt", "search_token": "late"}]}, true)
	menu._on_media_list(obsolete.id, JSON.stringify(obsolete))
	check(not menu.rows.any(func(row): return row.title == "late.srt"), "Obsolete query cannot enter a different source")
	menu.dismiss()
	menu.visible = true
	menu.begin_subtitle_picker({}, "Different.Movie.MKV")
	check(not menu.subtitle_filter.enabled and menu.subtitle_filter.seed == "Different.Movie", "New picker regenerates the seed and clears temporary filtering")
	check(not menu._buttons.any(func(button): return button.target == Filter.OPEN), "Storage roots have no subtitle filter")
	menu.dismiss(); menu.free()
	# Large native pages and already-complete multi-page listings use the same filter.
	var modern := ModernHost.new()
	var big := Library.new(); big.platform = modern; root.add_child(big); big.visible = true; big.set_process(false)
	big.cloud_pagination.preferences.path = ProjectSettings.globalize_path("res://../../build/output/subtitle-picker-filter-20261103/paging-%d.cfg" % Time.get_ticks_usec())
	big.begin_subtitle_picker(cloud, "Film.mkv")
	var large: Array = []
	for index in 240: large.append(subtitle(("Film" if index % 2 == 0 else "Other") + ".%03d.srt" % index, "cloud://saved/Subtitles/"))
	Picker.reply(big, modern, large.slice(0, 70), {"next_offset": -1, "raw_count": 70, "total": 70, "page_size": 200})
	check(big._cloud_busy, "Large single page is initially constructed within frame budgets")
	click(big, Filter.OPEN)
	for _index in 10: big.cloud_pagination.tick()
	await process_frame
	check(big.rows.size() == 35 and modern.searches.is_empty(), "Native large-page fast path applies local filtering without search")
	click(big, Filter.CLEAR)
	check(big.rows.size() == 70, "Fast path clear restores the whole raw subtitle page")
	big.subtitle_filter.close()
	big.cloud_pagination.start_all()
	var identities: Array = []
	for index in 200: identities.append(str(index))
	Picker.reply(big, modern, large.slice(0, 200), {"next_offset": 200, "raw_count": 200, "raw_ids": identities, "total": 240, "page_size": 200})
	for _index in 12: big.cloud_pagination.tick()
	big.cloud_pagination.queue_at = 0; big.cloud_pagination.tick()
	identities = []
	for index in range(200, 240): identities.append(str(index))
	Picker.reply(big, modern, large.slice(200), {"next_offset": -1, "raw_count": 40, "raw_ids": identities, "total": 240, "page_size": 200})
	for _index in 10: big.cloud_pagination.tick()
	check(big.cloud_pagination.mode == "all" and big.rows.size() == 240, "Fixture loads the existing multi-page complete-directory path")
	var preference := FileAccess.get_file_as_string(big.cloud_pagination.preferences.path)
	click(big, Filter.OPEN); await process_frame
	check(big.rows.size() == 120 and modern.searches.is_empty(), "Already-complete multi-page directory filters locally")
	click(big, Filter.OPEN)
	check(big.rows.size() == 240 and FileAccess.get_file_as_string(big.cloud_pagination.preferences.path) == preference, "Closing local filtering preserves complete-list preference and contents")
	big.dismiss(); big.free()
	for failure in failures: push_error(failure)
	print("Subtitle picker filter checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
