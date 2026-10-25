extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Location := preload("res://scripts/media_location.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	signal archive_ready(id: int, payload: String)
	signal photo_ready(id: int, payload: String)
	var serial := 0
	var path := ""
	var fail := false
	var reads := 0
	var entries := [
		{"path":"卷一/001.png","title":"卷一/001.png","kind":"image","uri":"comic://book/0"},
		{"path":"卷一/002.png","title":"卷一/002.png","kind":"image","uri":"comic://book/1"},
		{"path":"卷二/001.png","title":"卷二/001.png","kind":"image","uri":"comic://book/2"}]
	func archive_open(_uri: String, _title: String, _password: String, _persist: bool) -> int:
		serial+=1; deliver.call_deferred(serial); return serial
	func deliver(id: int) -> void: archive_ready.emit(id,JSON.stringify({"state":"ready","session":"book","entries":entries}))
	func archive_close(_key: String) -> void: pass
	func open_photo(_uri: String) -> int:
		serial+=1; reads+=1; image_ready.call_deferred(serial); return serial
	func image_ready(id: int) -> void: photo_ready.emit(id,JSON.stringify({"state":"error"} if fail else {"state":"ready","path":path}))
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func check(value: bool, label: String) -> void:
	checks+=1
	if not value: failures.append(label)
func _initialize() -> void: run.call_deferred()
func opened(menu: Node) -> void:
	await process_frame; await process_frame; menu.archives.tick()
func settled(photo: Node) -> void:
	var until := Time.get_ticks_msec()+5000
	while photo.loading and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not photo.loading,"Reader finishes request")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/container-locations/"+str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(output)
	var host := Host.new(); host.path=output.path_join("page.png")
	var image := Image.create(32,48,false,Image.FORMAT_RGB8); image.fill(Color.CORNFLOWER_BLUE); image.save_png(host.path)
	var catalog := Recent.new(output.path_join("recent"))
	var favorites := Favorites.new(output.path_join("favorites"))
	var menu := Library.new(); menu.platform=host; menu.catalog=catalog; menu.collections.store=favorites; root.add_child(menu); menu.set_process(false)
	menu.section=Library.Section.LOCAL; menu.media_filter=2
	var source := {"uri":"content://com.android.externalstorage.documents/document/opaque","title":"漫画.cbz"}
	menu.archives.open(source); await opened(menu)
	check(catalog.list_recent().is_empty(),"Opening archive index does not record reading")
	menu.archives.change_directory("卷一",false)
	var first: Dictionary=menu.archives.history_entry()
	var favorite: Dictionary=menu.archives.favorite_location()
	menu._activate(menu.Collections.FAVORITE_FOLDER)
	check(favorites.contains(Location.folder_uri(favorite)),"Real directory favorite action saves an archive subdirectory")
	check(not menu.archives.action(menu.Collections.FAVORITE_FOLDER),"Archive router delegates favorite action")
	var restored := Favorites.new(favorites.directory)
	check(restored.list_favorites().size()==1 and restored.list_favorites()[0].location.path=="卷一","Favorite survives reload with opaque source and exact internal path")
	var photo := Photo.new(); photo.platform=host; photo.catalog=catalog; root.add_child(photo); host.photo_ready.connect(photo._on_ready)
	var queue: Array[Dictionary]=menu.archives.image_queue()
	host.fail=true; photo.open_image(queue[0].uri,queue[0].title,queue,{}, {},first); await settled(photo)
	check(catalog.list_recent().is_empty(),"Failed page does not add container history")
	host.fail=false; photo.open_image(queue[0].uri,queue[0].title,queue,{}, {},first); await settled(photo)
	check(catalog.list_recent().size()==1 and catalog.lookup(source.uri).location.path=="卷一","Successful archive image records containing volume")
	var main := Main.new(); main.photo=photo; main.photo_active=true; main.favorites=favorites
	check(main._favorite_state().enabled and main._favorite_state().selected and main._favorite_target().location.path=="卷一","Reader favorite button targets the current volume")
	main._toggle_favorite(); check(not favorites.contains(Location.folder_uri(favorite)),"Reader can remove current volume favorite")
	main._toggle_favorite(); check(favorites.contains(Location.folder_uri(favorite)),"Reader can restore current volume favorite")
	main.free()
	photo.navigate(1); await settled(photo)
	check(catalog.list_recent().size()==1 and catalog.lookup(queue[0].uri).is_empty(),"Pages never become individual history entries")
	photo.close_image()
	menu.archives.change_directory("卷二",false)
	var second: Dictionary=menu.archives.history_entry()
	menu._activate(menu.Collections.FAVORITE_FOLDER)
	check(favorites.list_favorites().size()==2,"Two volumes can be pinned independently")
	queue=menu.archives.image_queue(); photo.open_image(queue[0].uri,queue[0].title,queue,{}, {},second); await settled(photo); photo.close_image()
	check(catalog.list_recent().size()==1 and catalog.lookup(source.uri).location.path=="卷二","Reading another volume updates the same book's recent destination")
	check(catalog.save(),"Container history saves")
	var recent := Recent.new(catalog.directory); recent.load_saved(); menu.catalog=recent
	check(recent.lookup(source.uri).location.path=="卷二","Last volume survives restart")
	menu.archives.close(); menu.section=Library.Section.RECENT; menu.collections.home_tab=0; menu.refresh()
	check(menu.rows.size()==1 and menu.rows[0].icon=="folder" and menu.rows[0].title.contains("卷二") and menu.video_queue().is_empty(),"Recent shows a container destination and never queues it as video")
	menu._choose(menu.rows[0]); await opened(menu)
	check(menu.archives.directory=="卷二" and menu.archives.target.title=="漫画.cbz","Recent directly reopens last volume even with opaque URI")
	var before := host.reads; menu.archives.close(); menu.section=Library.Section.RECENT; menu.collections.home_tab=1; menu.refresh()
	var saved: Dictionary=favorites.lookup(Location.folder_uri(favorite))
	menu._choose(saved); await opened(menu)
	check(menu.archives.directory=="卷一" and host.reads==before,"Favorite opens its exact volume without reading an image")
	menu.archives.close(); host.entries=host.entries.filter(func(row): return not str(row.path).begins_with("卷一/"))
	menu.collections.open_location(saved); await opened(menu)
	check(menu.archives.directory=="" and menu.status=="Folder no longer exists","Missing favorite volume reports failure and shows archive root")
	var malformed := favorite.duplicate(true); malformed.path="../secret"
	check(Location.clean(malformed).is_empty(),"Internal traversal path cannot become a stored location")
	check(Location.folder_uri(favorite)!=Location.folder_uri(second.location),"Different internal paths have different favorite identities")
	Privacy.configure(Privacy.NONE); catalog.clear_all()
	check(not catalog.opened_container(first) and catalog.list_recent().is_empty(),"No-history mode rejects container visit")
	Privacy.configure(Privacy.LOCAL)
	var network := second.duplicate(true); network.uri="cloud://account/book.cbz"
	check(not catalog.opened_container(network) and catalog.opened_container(first),"Local-only history applies to container source")
	Privacy.configure(Privacy.ALL)
	check(catalog.list_recent().size()==1,"Enabling history never backfills suppressed network visits")
	check(favorites.relocate(source.uri,"file:///renamed.cbz","renamed.cbz"),"Rename migrates volume favorites")
	check(favorites.list_favorites().size()==2 and favorites.list_favorites().all(func(row):return row.location.source_uri=="file:///renamed.cbz"),"Both volume favorites keep internal paths after rename")
	check(catalog.relocate(source.uri,"file:///renamed.cbz","renamed.cbz") and catalog.lookup("file:///renamed.cbz").location.source_uri=="file:///renamed.cbz","Recent destination follows renamed original")
	favorites.protected=true
	check(favorites.has_container_record("file:///renamed.cbz"),"Subdirectory favorite identifies its protected source")
	favorites.lock(); check(not favorites.has_container_record("file:///renamed.cbz") and favorites.list_favorites().is_empty(),"Locked store exposes no internal destinations")
	photo.queue_free(); menu.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Container locations: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
