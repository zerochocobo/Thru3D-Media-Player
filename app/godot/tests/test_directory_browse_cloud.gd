extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Memory := preload("res://scripts/directory_browse_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []
var path := ""

class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var inserted := 0
	var count := 650
	var omit := -1
	var mixed := false
	func media_cloud_cancel(_id: int) -> void: pass
	func media_cloud_page_options(folder: String, offset: int, _force: bool, order: String, _folder_id: String, size: int, _subtitles: bool) -> int:
		calls.append({"path":folder,"offset":offset,"order":order,"page_size":size})
		return calls.size()
	func reply() -> void:
		var request: Dictionary = calls.back().duplicate(true)
		var entries: Array = []
		var total := count + inserted
		for i in range(int(request.offset), mini(total, int(request.offset) + int(request.page_size))):
			var identity := i - inserted
			if identity == omit: identity = -10000
			entries.append({"uri":"cloud://account/movie%d.mp4" % identity,"title":"Movie %d" % identity,"modified":identity})
			if mixed and i % 2 == 0: entries.back().merge({"uri":"cloud://account/image%d.jpg" % identity,"kind":"image"}, true)
		request.merge({"state":"ready","entries":entries,"raw_count":entries.size(),"raw_ids":entries.map(func(row):return row.uri),"total":total,"next_offset":int(request.offset) + int(request.page_size) if int(request.offset) + int(request.page_size) < total else -1})
		if int(request.offset) > total: request.merge({"state":"error","error":"Cloud request failed","error_detail":"list115.list\ninvalid directory page response; refresh the folder"}, true)
		media_list.emit(calls.size(), JSON.stringify(request))

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func fresh() -> RefCounted:
	var memory := Memory.new(); memory.load_file(path); return memory

func make_menu(memory: RefCounted, platform: RefCounted, account: String = "account") -> Node3D:
	var menu := Menu.new(); menu.browse_memory = memory
	root.add_child(menu); menu.set_process(false); menu.attach_platform(platform)
	menu.visible = true; menu.section = Menu.Section.CLOUD; menu.view_mode = "list"
	menu.cloud_pagination.preferences.path = path + ".paging"
	menu._cloud_stack = [{"id":"/" + account,"title":"Cloud","provider":"115_open","cloud_id":"123"}]
	return menu

func settle(menu: Node3D) -> void:
	for i in 30:
		if menu.cloud_pagination.queued: menu.cloud_pagination.queue_at = 0
		menu.cloud_pagination.tick()
		await process_frame

func load_saved(menu: Node3D, platform: RefCounted) -> void:
	menu._load_cloud()
	for i in 7:
		var before: int = platform.calls.size()
		platform.reply()
		await settle(menu)
		if platform.calls.size() == before: break

func _initialize() -> void: call_deferred("run")
func run() -> void:
	path = ProjectSettings.globalize_path("res://../../build/output/directory-resume/cloud-%d.cfg" % Time.get_ticks_usec()).simplify_path()
	Privacy.configure(Privacy.ALL); Privacy.vault = null
	var platform := Platform.new(); var memory := fresh()
	var menu := make_menu(memory, platform)
	await load_saved(menu, platform)
	menu.cloud_pagination.jump(1); platform.reply(); await settle(menu)
	menu._set_scroll(190.25); menu.checkpoint_browse()
	check(menu._cloud_page == 1 and menu.rows[190].uri == "cloud://account/movie390.mp4", "Seed near remote page boundary")
	menu.dismiss(); menu.free()
	platform.inserted = 20
	var rebooted := make_menu(fresh(), platform)
	var before: int = platform.calls.size()
	await load_saved(rebooted, platform)
	check(rebooted._cloud_page == 2 and is_equal_approx(rebooted.scroll, 10.25), "Restart finds original item on adjacent page after insertions")
	check(platform.calls.size() - before == 2, "Only original and neighboring page requested")
	rebooted.visible = false; rebooted.free() # Keep the original disk checkpoint for deletion case.
	var disabled := make_menu(fresh(), platform); disabled.restore_directory_position = false
	await load_saved(disabled, platform)
	check(disabled._cloud_page == 0 and is_zero_approx(disabled.scroll), "Disabled restore opens cloud at first page")
	disabled._browse_return_restore = true
	await load_saved(disabled, platform)
	check(disabled._cloud_page == 2 and is_equal_approx(disabled.scroll, 10.25), "Parent return still restores cloud page when global restore is off")
	disabled.visible = false; disabled.free()
	platform.omit = 390
	var removed := make_menu(fresh(), platform)
	before = platform.calls.size(); await load_saved(removed, platform)
	check(platform.calls.size() - before <= 5 and removed._cloud_page == 1, "Deleted item uses bounded search and original-page fallback")
	check(removed.status == "Previous item unavailable; showing nearby position", "Approximate restore is explicit")
	removed.visible = false; removed.free()
	platform.omit = -1; platform.count = 5; platform.inserted = 0
	var shrunk := make_menu(fresh(), platform)
	await load_saved(shrunk, platform)
	check(shrunk._cloud_page == 0 and shrunk.rows.size() == 5 and not shrunk.cloud_error.opened, "Expired page recovers after directory shrinks")
	shrunk.visible = false; shrunk.free()
	platform.count = 650
	var other := make_menu(fresh(), platform, "different-account")
	await load_saved(other, platform)
	check(other._cloud_page == 0 and is_zero_approx(other.scroll), "Same folder ID in another account does not reuse position")
	other.visible = false; other.free()
	var clearing := make_menu(fresh(), platform)
	clearing._load_cloud(); check(clearing.clear_browse_history(true), "Clear while remote restore is pending")
	platform.reply(); await settle(clearing); clearing.checkpoint_browse()
	check(clearing.browse_memory.session.is_empty() and fresh().persisted.is_empty() and is_zero_approx(clearing.scroll), "Late response cannot restore or rewrite cleared position")
	clearing.visible = false; clearing.free()
	Privacy.configure(Privacy.NONE)
	var private_memory := fresh(); var private_menu := make_menu(private_memory, platform)
	await load_saved(private_menu, platform)
	private_menu.cloud_pagination.jump(1); platform.reply(); await settle(private_menu)
	private_menu._set_scroll(12.25); private_menu.dismiss(); private_menu.free()
	var same_run := make_menu(private_memory, platform); await load_saved(same_run, platform)
	check(same_run._cloud_page == 1 and is_equal_approx(same_run.scroll, 12.25), "Private cloud positions survive menu recreation in same run")
	same_run.dismiss(); same_run.free()
	var new_run := make_menu(fresh(), platform); await load_saved(new_run, platform)
	check(new_run._cloud_page == 0 and is_zero_approx(new_run.scroll), "Private cloud positions disappear after restart")
	new_run.visible = false; new_run.free(); Privacy.configure(Privacy.ALL)
	var all_memory := fresh(); var all_menu := make_menu(all_memory, platform)
	await load_saved(all_menu, platform)
	all_menu.cloud_pagination.start_all()
	for i in 5:
		platform.reply(); await settle(all_menu)
		if all_menu.cloud_pagination.complete: break
	check(all_menu.rows.size() == 650 and all_menu.cloud_pagination.complete, "Fixture loads all pages through existing user-selected mode")
	all_menu._set_scroll(410.25); all_menu.dismiss(); all_menu.free()
	var all_return := make_menu(fresh(), platform)
	await load_saved(all_return, platform)
	check(all_return.cloud_pagination.complete and is_equal_approx(all_return.scroll, 410.25), "Remembered all-pages mode waits for the directory layout and anchor")
	all_return.visible = false; all_return.free()
	var cursor_seed := make_menu(fresh(), platform)
	cursor_seed.browse_memory.remember(cursor_seed._browse_scope(), true, {"page":3,"offset":600,"page_size":200,"order":"name_asc","filter":0,"position":{"key":"old-item","index":20}}, cursor_seed.browse_memory.revision)
	cursor_seed.browse_memory.flush(); cursor_seed.visible = false; cursor_seed.free()
	var cursor_menu := make_menu(fresh(), platform); cursor_menu._cloud_stack[0].provider = "aliyun_open"
	cursor_menu.cloud_pagination.preferences.path = path + ".cursor-paging"
	await load_saved(cursor_menu, platform)
	check(cursor_menu._cloud_page == 0 and is_zero_approx(cursor_menu.scroll) and cursor_menu.status == "Previous page expired; showing first page", "Cold cursor-based providers fall back explicitly instead of reusing expired cursors")
	cursor_menu.visible = false; cursor_menu.free()
	await filter_cases()
	print("Directory browse cloud: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func reply_filter(menu: Node3D, platform: RefCounted, filter: int) -> void:
	menu._activate(Menu.FILTER_BASE + filter)
	for i in 7:
		if not menu._cloud_busy: break
		var before: int = platform.calls.size()
		platform.reply(); await settle(menu)
		if before == platform.calls.size(): break

func filter_cases() -> void:
	path += ".filters"
	var platform := Platform.new(); platform.mixed = true
	var menu := make_menu(fresh(), platform)
	await load_saved(menu, platform)
	var pages := [1, 2, 0]; var positions := [32.25, 24.25, 16.25]
	var keys: Array = []
	for filter in 3:
		await reply_filter(menu, platform, filter)
		if menu._cloud_page != pages[filter]:
			menu.cloud_pagination.jump(pages[filter]); platform.reply(); await settle(menu)
		menu._set_scroll(positions[filter]); keys.append(menu.Presentation.browse_key(menu.rows[int(menu.scroll)]))
	for filter in [0, 2, 1]:
		await reply_filter(menu, platform, filter)
		check(menu._cloud_page == pages[filter] and is_equal_approx(menu.scroll, positions[filter]) and menu.Presentation.browse_key(menu.rows[int(menu.scroll)]) == keys[filter], "Cloud filter restores independent page and anchor / %d" % filter)
	menu.dismiss(); menu.toggle(); platform.reply(); await settle(menu)
	check(menu.media_filter == 0 and menu._cloud_page == 1 and is_equal_approx(menu.scroll, positions[0]), "Reopen cloud All loads its page instead of previous Video page")
	menu.dismiss(); menu.free()
	var rebooted := make_menu(fresh(), platform); await load_saved(rebooted, platform)
	for filter in 3:
		await reply_filter(rebooted, platform, filter)
		check(rebooted._cloud_page == pages[filter] and is_equal_approx(rebooted.scroll, positions[filter]), "Cloud filter resumes across restart / %d" % filter)
	await reply_filter(rebooted, platform, 0)
	rebooted.cloud_pagination.start_all()
	for i in 5:
		platform.reply(); await settle(rebooted)
		if rebooted.cloud_pagination.complete: break
	var all_positions := [410.25, 180.25, 120.25]
	for filter in 3:
		rebooted._activate(Menu.FILTER_BASE + filter); await settle(rebooted)
		rebooted._set_scroll(all_positions[filter])
	for filter in [0, 2, 1]:
		rebooted._activate(Menu.FILTER_BASE + filter); await settle(rebooted)
		check(is_equal_approx(rebooted.scroll, all_positions[filter]), "All-pages view restores each filter after asynchronous row rebuild / %d" % filter)
	rebooted._activate(Menu.FILTER_BASE + 2)
	rebooted.cloud_pagination.tick()
	rebooted._activate(Menu.FILTER_BASE + 0); await settle(rebooted)
	check(rebooted.rows.size() == 650 and is_equal_approx(rebooted.scroll, all_positions[0]), "Rapid filter switch replaces unfinished row rebuild")
	rebooted._activate(Menu.FILTER_BASE + 2); await settle(rebooted)
	check(is_equal_approx(rebooted.scroll, all_positions[2]) and rebooted.rows.all(func(row): return row.kind == "image"), "Unfinished filter cannot overwrite saved position or mix rows")
	rebooted.visible = false; rebooted.free()
