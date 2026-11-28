extends SceneTree
## A file-type switch redraws only the files in folders, recent files and cloud listings; the page
## must match a full redraw.
const Library := preload("res://scripts/library_menu.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	signal media_list(id: int, payload: String)
	func media_smb_browse(_server: String, _path: String) -> int: return 1

class Cloud extends Object:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	func media_cloud_page_options(path: String, offset: int, _force: bool, order: String, _folder: String, size: int, _subtitles: bool) -> int:
		calls.append({"path": path, "offset": offset, "order": order, "page_size": size}); return calls.size()
	func media_cloud_cancel(_id: int) -> void: pass
	func respond(entries: Array, next_offset: int = -1) -> void:
		var call: Dictionary = calls.back()
		media_list.emit(calls.size(), JSON.stringify({"state": "ready", "path": call.path, "offset": call.offset, "order": call.order,
			"page_size": call.page_size, "raw_count": entries.size(), "raw_ids": entries.map(func(entry): return entry.cloud_id),
			"entries": entries, "total": entries.size() if next_offset < 0 else -1, "next_offset": next_offset}))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); print("FAILED: " + message)

func _initialize() -> void: run.call_deferred()

## Every visible control and caption with its place, state and colours.
func page(menu: Node3D) -> Array:
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
	menu._update_highlights()
	var items: Array = []
	for button in menu._buttons:
		var node: Node3D = button.node
		if not is_instance_valid(node) or not node.is_visible_in_tree(): continue
		var texts := PackedStringArray()
		for label in node.find_children("*", "Label3D", true, false): texts.append(label.text + str(label.modulate))
		items.append(str([button.target, button.enabled, button.base_color, button.foreground,
			node.material_override.get_shader_parameter("surface_color") if node is GeometryInstance3D and node.material_override is ShaderMaterial else null, (menu.global_transform.affine_inverse() * node.global_position).snappedf(0.0001), texts]))
	var labels: Array = menu._labels.duplicate()
	if is_instance_valid(menu._list): labels.append_array(menu._list.get_children().filter(func(node): return node is Label3D))
	for label: Label3D in labels:
		if is_instance_valid(label) and label.is_visible_in_tree():
			items.append(str([label.text, label.modulate, (menu.global_transform.affine_inverse() * label.global_position).snappedf(0.0001)]))
	items.append(str(["clear tip", menu._tips.get(menu.CLEAR_HISTORY, "")]))
	items.sort()
	return items

func side_column(menu: Node3D) -> Node:
	return menu._side.get_child(0) if menu._side.get_child_count() > 0 else null

## Switches through [values]; each switch must draw what a full redraw draws. [settle] finishes
## work a switch leaves for later frames. Returns how many switches kept the navigation column.
func sweep(menu: Node3D, tag: String, values: Array, settle: Callable = Callable()) -> int:
	var kept := 0
	for value in values:
		if not menu._buttons.any(func(button): return button.target == Library.FILTER_BASE + value): continue
		var side := side_column(menu)
		click(menu, Library.FILTER_BASE + value)
		if settle.is_valid(): settle.call()
		check(menu.media_filter == value, "%s/filter %d switches the file type" % [tag, value])
		if is_instance_valid(side) and side_column(menu) == side: kept += 1
		var fast := page(menu)
		menu.refresh()
		var full := page(menu)
		check(fast == full, "%s/filter %d draws what a full redraw draws: %s vs %s" % [tag, value,
			fast.filter(func(item): return not full.has(item)).slice(0, 3), full.filter(func(item): return not fast.has(item)).slice(0, 3)])
	return kept

func click(menu: Node3D, target: int) -> void:
	var node: Node3D = menu._buttons.filter(func(button): return button.target == target)[0].node
	var origin := node.to_global(Vector3(0, 0, 1)); var direction := -node.global_basis.z
	menu.press_pointer("right_hand", origin, direction, true); menu.release_pointer("right_hand", origin, direction, true)

func run() -> void:
	var menu: Node3D = Library.new(); menu.platform = Host.new()
	menu.collections.store = Favorites.new("user://library-filter-redraw")
	root.add_child(menu); menu.set_process(false); menu.visible = true
	var files: Array = []
	for i in 4: files.append({"id": "share/f%d" % i, "title": "Folder %d" % i, "container": true})
	for i in 14: files.append({"uri": "smb://s/share/v%d.mp4" % i, "title": "Video %d.mp4" % i, "kind": "video"})
	for i in 9: files.append({"uri": "smb://s/share/p%d.jpg" % i, "title": "Photo %d.jpg" % i, "kind": "image"})
	for i in 3: files.append({"uri": "smb://s/share/b%d.epub" % i, "title": "Book %d.epub" % i, "kind": "book"})
	for i in 2: files.append({"uri": "smb://s/share/m%d.mp3" % i, "title": "Song %d.mp3" % i, "kind": "audio"})
	var no_books := files.filter(func(entry): return entry.get("kind", "") != "book")
	for listing in [files, no_books]:
		for view in ["grid", "list"]:
			menu.section = Library.Section.SMB; menu._smb_server = "s"; menu._smb_path = "share"
			menu._smb_entries = listing; menu.view_mode = view; menu.media_filter = 0; menu.refresh()
			var previous := 0
			for value in [1, 2, Library.BOOK_FILTER, Library.MUSIC_FILTER, 0, 2, 1, Library.BOOK_FILTER, 0]:
				var tag := "%s/%d entries/filter %d" % [view, listing.size(), value]
				var side: Node = menu._side.get_child(0) if menu._side.get_child_count() > 0 else null
				click(menu, Library.FILTER_BASE + value)
				check(menu.media_filter == value, tag + " switches the file type")
				var fast := page(menu)
				var kept: bool = side != null and is_instance_valid(side) and menu._side.get_child(0) == side
				menu.refresh()
				var full := page(menu)
				check(fast == full, tag + " draws what a full redraw draws: " + str(fast.filter(func(item): return not full.has(item)).slice(0, 3)) + " vs " + str(full.filter(func(item): return not fast.has(item)).slice(0, 3)))
				# Song selection comes and goes with music, so that switch redraws the page; images
				# and an empty book shelf only change the files.
				if value != Library.MUSIC_FILTER and previous != Library.MUSIC_FILTER: check(kept, tag + " keeps the navigation column")
				if menu.rows.is_empty(): check(menu.text_snapshot().contains("—") or menu._list.get_children().any(func(node): return node is Label3D and node.text == "—"), tag + " marks the empty type")
				previous = value
				if value == Library.MUSIC_FILTER: check(menu.text_snapshot().contains(menu.I18n.t("Select music")), tag + " offers song selection")
	# Reused rows follow a listing patched in place and the folder they belong to.
	menu.media_filter = 0; menu.view_mode = "list"; menu._smb_entries = files; menu.refresh()
	files[5].title = "Renamed.mp4"; menu.refresh()
	check(menu.rows.any(func(row): return row.title == "Renamed.mp4"), "A renamed file shows its new name")
	menu.rows[0].title = "Scribbled"; menu.refresh()
	check(not menu.rows.any(func(row): return row.title == "Scribbled"), "Drawn rows never write into the reused ones")
	var before: String = str(menu.rows[6].location)
	menu._smb_path = "share/other"; menu.refresh()
	check(str(menu.rows[6].location) != before, "Rows of the same listing in another folder carry that folder")
	recent_and_cloud()
	for failure in failures: push_error(failure)
	print("Library filter redraw: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func recent_and_cloud() -> void:
	preload("res://scripts/i18n.gd").use("en")
	Privacy.vault = null; Privacy.configure("all")
	var recent := Recent.new("user://library-filter-redraw-recent/%d" % Time.get_ticks_usec())
	for i in 9: recent.opened("file:///Clips/video%d.mp4" % i, "Video %d" % i, false)
	for i in 5: recent.opened("smb://nas/Photos/photo%d.jpg" % i, "Photo %d" % i, false, "image")
	for view in ["grid", "list"]:
		var menu: Node3D = Library.new(); menu.collections.store = Favorites.new("user://library-filter-redraw-favorites")
		root.add_child(menu); menu.set_process(false); menu.visible = true
		menu.catalog = recent; menu.section = Library.Section.RECENT; menu.view_mode = view; menu.refresh()
		var kept := sweep(menu, "recent/" + view, [1, 2, 0, 2, 1, 0])
		check(kept == 6, "recent/%s switches keep the navigation column: %d of 6" % [view, kept])
		check(str(menu._tips.get(menu.CLEAR_HISTORY, "")) == "Clear history", "recent/%s clear tip follows the type" % view)
		click(menu, Library.FILTER_BASE + 2)
		check(str(menu._tips.get(menu.CLEAR_HISTORY, "")) == "Clear image history", "recent/%s clear tip names images" % view)
		menu.free()
	card_actions(recent)
	var cloud := Cloud.new()
	var menu: Node3D = Library.new(); menu.collections.store = Favorites.new("user://library-filter-redraw-favorites")
	root.add_child(menu); menu.set_process(false); menu.attach_platform(cloud); menu.visible = true
	menu.section = Library.Section.CLOUD; menu.view_mode = "grid"
	var paging: RefCounted = menu.cloud_pagination
	paging.preferences.path = "user://library-filter-redraw-paging-%d.cfg" % Time.get_ticks_usec()
	menu._cloud_stack = [{"id": "/account", "title": "115", "provider": "115_open"}]
	var entries: Array = []
	for i in 60:
		var image := i % 3 == 0
		entries.append({"title": "%d.%s" % [i, "jpg" if image else "mp4"], "uri": "cloud://account/%d.%s" % [i, "jpg" if image else "mp4"],
			"cloud_id": str(i), "kind": "image" if image else "video"})
	# Paged: a type switch asks the provider again; the page still matches a full redraw.
	menu._load_cloud(); cloud.respond(entries.slice(0, 30), 30)
	var requests := cloud.calls.size()
	var side := side_column(menu)
	click(menu, Library.FILTER_BASE + 1)
	check(cloud.calls.size() == requests + 1, "cloud paged switch reloads the page")
	check(side_column(menu) == side, "cloud paged switch keeps the navigation column while loading")
	check(menu._labels.any(func(label): return label.text == menu.I18n.t("Loading…") and label.visible), "cloud paged loading shows Loading in the header")
	check(menu._buttons.filter(func(button): return button.target in [Library.CLOUD_NEXT, menu.CloudSearch.OPEN, menu.FileActions.SORT]).all(func(button): return not button.enabled),
		"cloud paged loading disables paging, search and sort")
	var loading := page(menu)
	menu.refresh()
	var loading_full := page(menu)
	check(loading == loading_full, "cloud paged loading draws what a full redraw draws: %s vs %s" % [loading.filter(func(item): return not loading_full.has(item)).slice(0, 3), loading_full.filter(func(item): return not loading.has(item)).slice(0, 3)])
	side = side_column(menu)
	cloud.respond(entries.slice(0, 30).filter(func(entry): return entry.kind == "video"), 30)
	check(side_column(menu) == side, "cloud paged page arriving keeps the navigation column")
	check(not menu._labels.any(func(label): return label.text == menu.I18n.t("Loading…") and label.visible), "cloud paged arrival hides Loading")
	var arrived := page(menu)
	menu.refresh()
	var arrived_full := page(menu)
	check(arrived == arrived_full, "cloud paged arrival draws what a full redraw draws: %s vs %s" % [arrived.filter(func(item): return not arrived_full.has(item)).slice(0, 3), arrived_full.filter(func(item): return not arrived.has(item)).slice(0, 3)])
	var kept_paged := sweep(menu, "cloud paged", [0, 1], func(): cloud.respond(entries.slice(0, 30).filter(func(entry): return menu.media_filter == 0 or entry.kind == "video"), 30))
	check(kept_paged == 2, "cloud paged switches keep the navigation column: %d of 2" % kept_paged)
	# Everything loaded: the type is filtered here, over frames, and only the list redraws.
	menu.media_filter = 0; menu.refresh()
	paging.start_all(); cloud.respond(entries)
	while not paging.batch.is_empty(): paging.tick()
	check(paging.mode == "all" and menu.rows.size() == 60, "cloud all loads every row")
	requests = cloud.calls.size()
	var settle := func():
		while not paging.batch.is_empty(): paging.tick()
	var kept := sweep(menu, "cloud all", [1, 2, 0, 1, 0], settle)
	check(kept == 5, "cloud all switches keep the navigation column: %d of 5" % kept)
	check(cloud.calls.size() == requests, "cloud all switches need no provider calls")
	check(menu.rows.size() == 60, "cloud all shows every row again")
	menu.free(); cloud.free()

## Recent cards make their hover actions when first pointed at, into the capture they belong to.
func card_actions(recent: RefCounted) -> void:
	var world := Node3D.new(); root.add_child(world)
	var camera := Camera3D.new(); world.add_child(camera)
	var menu: Node3D = Library.new(); menu.collections.store = Favorites.new("user://library-filter-redraw-favorites")
	world.add_child(menu); menu.set_process(false); menu.visible = true; menu.position.z = -1.4
	menu.catalog = recent; menu.section = Library.Section.RECENT; menu.view_mode = "grid"; menu.refresh()
	var capture := Capture.new(); world.add_child(capture)
	capture.configure(world, camera, null, [menu], false, true); capture.set_process(false)
	capture.update()
	var actions := func(slot: int) -> Array: return menu._buttons.filter(func(button): return button.get("collection_hover", -1) == Library.ROW_BASE + slot)
	check(menu._buttons.all(func(button): return not button.has("collection_hover")), "Recent cards draw without their hover actions")
	check(str(menu._tips.get(menu.collections.REMOVE_ROW, "")) == "Remove from recent", "Hover action tooltips are ready before the actions")
	# The first hover also makes the tooltip; settle that before watching the second card.
	var first: Node3D = menu._buttons.filter(func(button): return button.target == Library.ROW_BASE)[0].node
	menu.update_pointer("right_hand", first.to_global(Vector3(0, -0.08, 0.6)), -first.global_basis.z, true)
	capture.update()
	var tile: Node3D = menu._buttons.filter(func(button): return button.target == Library.ROW_BASE + 1)[0].node
	menu.update_pointer("right_hand", tile.to_global(Vector3(0, -0.08, 0.6)), -tile.global_basis.z, true)
	var made: Array = actions.call(1)
	check(made.size() == 3 and made.all(func(button): return button.node.visible), "Pointing at a card makes and shows its three actions")
	check(actions.call(2).is_empty(), "Other cards still owe theirs")
	check(not capture.geometry_dirty and made.all(func(button): return button.node.layers & capture.eye_camera.cull_mask == 0),
		"New actions join the list's capture without regrouping the menu")
	menu.update_pointer("right_hand", tile.to_global(Vector3(0, -0.08, 0.6)), -tile.global_basis.z, true)
	check(actions.call(1).size() == 3, "Pointing again makes nothing twice")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.FORWARD, false)
	check(actions.call(1).all(func(button): return not button.node.visible), "Leaving the card hides its actions")
	# Scrolling the card away frees its actions with it.
	menu._set_scroll(menu._max_scroll())
	if menu._recycled() and menu._first_line() > 0:
		check(actions.call(1).is_empty() or not menu._row_records.has(1), "A recycled card takes its actions along")
	capture.shutdown("test_complete"); capture.queue_free(); world.queue_free()
