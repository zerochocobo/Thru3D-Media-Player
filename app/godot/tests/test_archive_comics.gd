extends SceneTree
const ArchivePanel := preload("res://scripts/archive_panel.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Library := preload("res://scripts/library_menu.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Main := preload("res://scripts/main.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var failures: Array[String] = []
var checks := 0
class Host extends RefCounted:
	signal archive_ready(id: int, payload: String)
	var values: Array[String] = []
	var persisted := false
	var closes: Array[String] = []
	var photos: Array[String] = []
	var opens := 0
	var cloud_reads := 0
	func open_photo(uri: String) -> int: photos.append(uri); return 100 + photos.size()
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func archive_open(_uri: String, _title: String, _password: String, persist: bool) -> int:
		opens += 1; persisted = persist; return 7
	func archive_close(key: String) -> void: closes.append(key)
	func media_cloud_page(_path: String, _cursor: int, _force: bool) -> int: cloud_reads += 1; return 999
	func archive_passwords(operation: String, value: String) -> String:
		if operation == "add": values.erase(value); values.push_front(value)
		if operation == "delete": values.erase(value)
		return JSON.stringify({"passwords":values})
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	for ext in ["ZIP","cbz","rar","cbr","7z","tar"]: check(ArchivePanel.named("", "Comic."+ext), "archive recognition "+ext)
	check(not ArchivePanel.named("file:///photo.png"), "ordinary image unaffected")
	var host := Host.new()
	var library := Library.new(); library.platform = host
	root.add_child(library); await process_frame
	check(library._entry_row({"uri":"file:///book.zip","title":"book.zip"}).kind == "archive", "archive row stays distinct from image and video")
	library._choose({"uri":"file:///book.zip","title":"book.zip","enabled":false})
	check(not library.archives.opened, "disabled archive row cannot bypass navigation checks")
	library.archives.manage()
	check(library.archives.opened and library.archives.managing, "password book opens")
	library.archives.password = "same password"; library.archives.submit()
	library.archives.password = "second password"; library.archives.submit()
	check(host.values == ["second password", "same password"], "password book add and order")
	library.archives.action(ArchivePanel.SELECT+1)
	check(library.archives.password == "same password", "history selects exact plaintext")
	library.archives.action(ArchivePanel.DELETE)
	check(host.values == ["same password"], "password book deletion")
	library.archives.open({"uri":"file:///book.zip","title":"book.zip"})
	check(not host.persisted, "unlock persistence is opt in")
	library.archives.receive(7,JSON.stringify({"state":"error","error":"Archive password required or incorrect"}));await process_frame;library.archives.tick()
	library.archives.password = "same password";library.archives.action(ArchivePanel.SAVE);library.archives.submit()
	check(host.persisted, "explicit persistence reaches bridge")
	library.archives.close()
	library.archives.receive(7,JSON.stringify({"state":"ready","entries":[]}));await process_frame;library.archives.tick()
	check(not library.archives.opened, "late unlock result ignored")
	var chosen: Array[String] = []
	library.chosen.connect(func(uri,_title): chosen.append(uri))
	library.archives.open({"uri":"file:///book.zip","title":"book.zip"})
	library.archives.receive(7,JSON.stringify({"state":"ready","password_save_error":true,"entries":[{"uri":"comic://key/0","title":"1.png"}]}))
	await process_frame;library.archives.tick()
	check(library.archives.opened and chosen.is_empty() and not library.archives.ready_data.is_empty(), "failed persistence remains visible before reading")
	library.archives.action(ArchivePanel.SUBMIT)
	check(chosen.is_empty() and library.archives.browsing and not library.archives.opened, "verified archive enters browser without opening first image")
	library._choose(library.rows[0])
	check(chosen == ["comic://key/0"] and library.archives.browsing, "only explicit file selection starts reading and retains browser")
	library.archives.close(); chosen.clear()
	library.section = Library.Section.CLOUD
	library.archives.open({"uri":"cloud://account/book.zip","title":"book.zip"})
	library.archives.receive(7, JSON.stringify({"state":"ready","session":"tree","entries":[
		{"path":"10章/10.png","title":"10章/10.png","kind":"image","uri":"comic://tree/3"},
		{"path":"2章/10.png","title":"2章/10.png","kind":"image","uri":"comic://tree/2"},
		{"path":"2章/2.png","title":"2章/2.png","kind":"image","uri":"comic://tree/1"},
		{"path":"2章/附录/1.png","title":"2章/附录/1.png","kind":"image","uri":"comic://tree/4"},
		{"path":"空目录","title":"空目录","kind":"folder"},
		{"path":"cover.png","title":"cover.png","kind":"image","uri":"comic://tree/0"},
		{"path":"readme.txt","title":"readme.txt","kind":"file"}]}))
	await process_frame; library.archives.tick()
	check(chosen.is_empty() and library.rows.map(func(row):return row.title) == ["2章","10章","空目录","cover.png","readme.txt"], "root preserves natural folder order and hides descendants")
	check(library.Presentation.info(library.rows[3], null, true).subtitle.is_empty(), "archive image does not inherit local recent source metadata")
	check(library._side.visible and library._buttons.any(func(button):return button.target == library.FileActions.SORT), "archive uses ordinary browser sidebar and folder sort controls")
	library.archives.action(library.FileActions.SORT)
	check(library.file_actions.modal == "sort", "archive uses existing folder sort popup")
	library.file_actions.choose_order("name_desc")
	check(library.rows[0].title == "空目录" and host.cloud_reads == 0, "cloud archive sorting is local and uses selected order")
	library.file_actions.choose_order("name_asc")
	library._activate(library.FILTER_BASE+2)
	check(library.rows.size() == 4 and host.cloud_reads == 0, "ordinary image filter keeps archive folders and images without requests")
	library._activate(library.FILTER_BASE)
	var opens := host.opens; var closes := host.closes.size()
	library._choose(library.rows[0])
	check(library.archives.directory == "2章" and library.rows.map(func(row):return row.title) == ["附录","2.png","10.png"], "nested directory shows immediate children with leaf names")
	check(library.archives.image_queue().map(func(row):return row.uri) == ["comic://tree/1","comic://tree/2"], "page queue includes only current folder images")
	library._choose(library.rows[2])
	check(chosen == ["comic://tree/2"] and library.archives.browsing and host.closes.size() == closes, "selected page does not release archive when browser hides")
	library.archives.open({"uri":"cloud://account/book.zip","title":"book.zip"})
	check(host.opens == opens and library.archives.directory == "2章", "reentering current archive reuses unlocked index")
	library._choose(library.rows[0]); library.navigate_back()
	check(library.archives.directory == "2章" and host.opens == opens, "back from nested folder does not contact archive service")
	library.archives.action(ArchivePanel.CRUMB)
	check(library.archives.directory.is_empty() and library.rows.size() == 5, "archive breadcrumb jumps to root")
	library._choose(library.rows[2])
	check(library.rows.is_empty() and library.archives.browsing, "explicit empty directory remains accessible")
	library._cloud_stack.assign([{"id":"cloud://account/root","title":"Cloud"}])
	library.show_playback_files(false, {"path":"cloud://account/root","order":"name_asc","offset":0})
	check(host.cloud_reads == 0 and library.archives.browsing, "compact empty archive folder never loads original cloud directory")
	library.set_compact(false)
	library._activate(library.NAV_BASE + Library.Section.SETTINGS)
	check(not library.archives.browsing and library.archives.session == "tree", "settings remain available while unlocked archive session is retained")
	library.current_file_provider = func(): return "comic://tree/2"
	library._playback_context = {"section": Library.Section.LOCAL}
	library.show_playback_files(true)
	check(library.archives.browsing and library.section == Library.Section.CLOUD and library.archives.directory == "空目录" and host.cloud_reads == 0, "returning from settings restores archive without old video context or provider reads")
	library.set_compact(false)
	library.navigate_back(); library._choose(library.rows.back())
	check(chosen == ["comic://tree/2"], "unsupported file cannot be played")
	library.section = Library.Section.RECENT; library.archives.browser_section = Library.Section.RECENT; library.set_view_mode("list")
	check(library._buttons.all(func(button):return not library.collections.row_target(int(button.target))), "archive opened from recent does not inherit recent delete and favorite actions")
	library.navigate_back()
	check(not library.archives.browsing and host.closes.size() == closes+1, "back at archive root releases foreground session")
	library.archives.open({"uri":"file:///empty.zip","title":"empty.zip"})
	library.archives.receive(7, JSON.stringify({"state":"ready","session":"empty","entries":[]}))
	await process_frame; library.archives.tick()
	check(library.archives.browsing and library.rows.is_empty(), "empty archive opens as an ordinary empty folder")
	library.archives.close()
	library.archives.open({"uri":"file:///mixed.zip","title":"mixed.zip"})
	library.archives.receive(7, JSON.stringify({"state":"ready","session":"mixed","entries":[{"path":"clip.mp4","kind":"video"},{"path":"page.png","kind":"image","uri":"comic://mixed/0"}]}))
	await process_frame; library.archives.tick(); chosen.clear()
	library._choose(library.rows[0])
	check(chosen.is_empty() and not library.rows[0].enabled, "archive video is visible but cannot be opened")
	library._activate(library.FILTER_BASE+1)
	check(library.rows.size() == 1 and library.rows[0].kind == "video" and not library.rows[0].enabled, "ordinary video filter never makes archive video playable")
	library._activate(library.FILTER_BASE+2); library._choose(library.rows[0])
	check(chosen == ["comic://mixed/0"], "ordinary image filter still opens selected comic image")
	library.archives.close()
	var photo := Photo.new();root.add_child(photo);await process_frame
	photo.archive_mode = true;photo.set_layout_mode(2)
	check(photo.gallery.mode == 0, "comic cannot enter photo wall")
	photo._pump_prefetch();check(photo._prefetched.is_empty(), "comic no speculative page preload")
	check(not Privacy.record_allowed("comic://session/1") and not Privacy.settings_allowed("comic://session/1"), "ephemeral comic capabilities never persist in history")
	photo.archive_mode = false; photo.platform = host; photo.gallery.set_mode(2)
	var pages := [{"uri":"comic://test/0","title":"1.png"},{"uri":"comic://test/1","title":"2.png"},{"uri":"comic://test/2","title":"3.png"}]
	photo.open_image("comic://test/0","1.png",pages)
	check(photo.archive_mode and photo.gallery.mode == 0, "opening archive replaces previous photo wall with single image")
	photo.gallery.set_mode(3);check(photo.gallery.mode == 0, "direct gallery mode change also blocked")
	photo.navigate(1);photo.navigate(1);photo.navigate(-1)
	check(host.photos == ["comic://test/0","comic://test/1","comic://test/2","comic://test/1"], "rapid next/previous requests only selected pages")
	photo.close_image()
	check(host.closes.back() == "test" and photo.gallery.mode == 2 and photo.queue.is_empty(), "close invalidates exact session and restores normal layout without comic previews")
	photo.open_image("comic://tree/1","2.png",pages); photo.archive_browser_session = true
	closes = host.closes.size(); photo.close_image()
	check(host.closes.size() == closes, "closing browser-owned image retains unlocked directory session")
	photo.queue_free();library.queue_free();await process_frame
	print("Archive comics: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
