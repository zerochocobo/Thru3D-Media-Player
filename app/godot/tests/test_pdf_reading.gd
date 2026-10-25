extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Surface extends "res://scripts/media_surface.gd":
	var platform: RefCounted
	var _binding := preload("res://scripts/pair_texture_binding.gd").new()
	var pip := preload("res://scripts/video_pip.gd").new(self)
	func _ready() -> void:
		initialize_surface(preload("res://shaders/video_rvm_pair.gdshader"))
		_binding.material = material
		_flat.size = Vector2(1.6, 0.9); panel.visible = true

class Host extends RefCounted:
	signal archive_ready(id: int, payload: String)
	signal photo_ready(id: int, payload: String)
	signal pip_image_ready(id: int, payload: String)
	var serial := 0
	var refs := {}
	var paths: Array[String] = []
	var reads: Array[String] = []
	var held := false
	var pending := {}
	var identity := {}
	var request_identity := {}
	func pdf_open_at(uri: String, hint: String) -> int:
		request_identity = JSON.parse_string(hint)
		identity = {"uri":uri, "id":"9007199254740994", "size":3145925, "modified":1234567890000} if uri.begins_with("cloud://") else {}
		return pdf_open(uri)
	func pdf_open(_uri: String) -> int:
		serial += 1; refs[str(serial)] = 1; opened.call_deferred(serial); return serial
	func opened(id: int) -> void:
		if not refs.has(str(id)): return
		var pages := []
		for i in paths.size(): pages.append({"title":"%05d.png" % (i+1),"kind":"image","uri":"pdfpage://%d/%d" % [id,i],"pdf_page":i,"pdf_pages":paths.size()})
		archive_ready.emit(id,JSON.stringify({"state":"ready","session":str(id),"entries":pages,"source_file":identity}))
	func pdf_retain(key: String) -> bool:
		if not refs.has(key): return false
		refs[key] += 1; return true
	func pdf_close(key: String) -> void:
		if not refs.has(key): return
		refs[key] -= 1
		if refs[key] == 0: refs.erase(key)
	func open_photo(uri: String) -> int: return request(uri,false)
	func open_pip_image(uri: String) -> int: return request(uri,true)
	func request(uri: String, pip: bool) -> int:
		serial += 1; reads.append(uri); pending[serial] = {"uri":uri,"pip":pip}
		if not held: deliver.call_deferred(serial)
		return serial
	func deliver(id: int, success := true) -> void:
		if not pending.has(id): return
		var job: Dictionary = pending[id]; pending.erase(id)
		var key: String = job.uri.get_slice("/",2)
		var payload := {"state":"ready","path":paths[int(job.uri.get_file())]} if success and refs.has(key) else {"state":"error"}
		if job.pip: pip_image_ready.emit(id,JSON.stringify(payload))
		else: photo_ready.emit(id,JSON.stringify(payload))
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func cancel_pip_image(_id: int) -> void: pass
	func release_pip_image(_id: int) -> void: pass
	func media_local_browse(_uri: String) -> int: return -1
	func media_local_roots() -> int: return -1
	func media_cloud_browse(_path: String, _force: bool) -> int: return -1

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("run")
func settle(photo: Node3D) -> void:
	var until := Time.get_ticks_msec()+5000
	while photo.loading and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(),"PDF page goes through production photo decoder")
func pip_settle(window: Node3D) -> void:
	var until := Time.get_ticks_msec()+5000
	while window.image_loading and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not window.image_loading and not window.image_error,"PDF page goes through production PiP decoder")
func opened(library: Node) -> void:
	await process_frame; await process_frame; library.archives.tick()
func tap(window: Node3D, target: int) -> void:
	var matches: Array = window._buttons.filter(func(b):return b.target==target)
	check(matches.size()==1 and matches[0].enabled,"PDF ray control enabled: %d" % target)
	if matches.is_empty() or not matches[0].enabled: return
	var origin: Vector3 = matches[0].node.global_position + window.global_basis.z
	check(window.get_parent().pip.press("right_hand","trigger_click",[origin,-window.global_basis.z],null,null),"PiP routing accepts page arrow")
	window.get_parent().pip.cancel_pointer("right_hand")

func run() -> void:
	check(preload("res://scripts/pdf_pages.gd").error_text("PDF_LOCATION_EXPIRED")=="Archive location expired; refresh the folder","Expired cloud document location has an actionable existing translation")
	var host := Host.new()
	var folder := ProjectSettings.globalize_path("res://../../build/output/pdf")
	DirAccess.make_dir_recursive_absolute(folder)
	for i in 3:
		var image := Image.create(120+20*i,200,false,Image.FORMAT_RGBA8)
		image.fill([Color.RED,Color.BLUE,Color.GREEN][i])
		var path := folder.path_join("page-%d.png"%i); image.save_png(path); host.paths.append(path)
	var library := Library.new(); library.platform=host; root.add_child(library); library.set_process(false)
	var catalog := preload("res://scripts/recent_files.gd").new(folder.path_join("recent-" + str(Time.get_ticks_usec())))
	library.catalog = catalog
	library.section=Library.Section.LOCAL; library.media_filter=2
	library._local_entries=[{"title":"book.PDF","uri":"file:///book.PDF","kind":"pdf"},{"title":"movie.mp4","uri":"file:///movie.mp4"}]
	library.refresh()
	check(library.rows.size()==1 and library.rows[0].kind=="pdf" and library.rows[0].icon=="folder","PDF remains visible as container in image filter")
	library._choose(library.rows[0]); await opened(library)
	check(library.archives.browsing and library.rows.size()==3 and host.reads.is_empty(),"Directory opens without rasterizing all pages")
	check(catalog.list_recent().is_empty(),"Browsing PDF without reading does not add history")
	check(library.rows[0].pdf_page==0 and library.rows[2].pdf_page==2,"PDF follows page order")
	var key: String=library.archives.session
	var pages: Array[Dictionary]=library.archives.image_queue()
	check(not pages[0].has("thumbnail_key") and library._picture(pages[0]) == null,"PDF directory has no generated thumbnail")
	var decoded := Photo._decode({"id":0,"serial":0,"index":0,"info":{"path":host.paths[0]},"skip_thumbnail":true})
	check(decoded.has("image") and not decoded.has("thumbnail") and not decoded.has("thumbnail_jpg"),"PDF decode does not resize or encode a directory thumbnail")
	var photo := Photo.new(); photo.platform=host; photo.catalog=catalog; root.add_child(photo)
	host.photo_ready.connect(photo._on_ready)
	check(photo.open_image(pages[0].uri,pages[0].title,pages,{}, {},library.archives.history_entry()),"Open PDF page using shared reader")
	await settle(photo)
	check(photo.archive_mode and photo._size==Vector2(120,200) and host.refs[key]==2,"Reader owns its reference and displays complete first page")
	check(catalog.list_recent().size()==1 and catalog.lookup("file:///book.PDF").kind=="pdf","Successful page records the PDF container")
	var read_count := host.reads.size(); library.refresh()
	check(library._picture(pages[0]) == null and host.reads.size()==read_count,"Reading and refreshing PDF directory never generates or fetches thumbnails")
	photo.navigate(1); await settle(photo)
	check(photo.index==1 and photo._texture.get_image().get_pixel(30,30).b>.9,"Single page next displays the requested page")
	photo.set_layout_mode(4); await settle(photo)
	check(photo._size==Vector2(300,200) and photo.snapshot().magazine_pages==2,"Existing magazine joins the second and third PDF pages")
	photo.magazine.right_to_left=true; photo.magazine.reload(); await settle(photo)
	check(photo._texture.get_image().get_pixel(30,30).g>.9,"Existing RTL reading reverses page presentation")
	photo.magazine.shift(1); await settle(photo)
	check(photo.index==2 and photo.snapshot().magazine_pages==1,"Odd last page displays alone")
	photo.set_layout_mode(0); await settle(photo)
	photo.set_layout_mode(2); check(photo.gallery.mode==0,"PDF does not accidentally start a thumbnail wall")
	library.archives.close()
	photo.navigate(-1); await settle(photo)
	check(photo.index==1 and host.refs[key]==1,"Closing directory leaves retained reader usable")
	photo.close_image(); check(not host.refs.has(key),"Reader releases final document reference")
	check(catalog.list_recent().size()==1,"Reading many pages still keeps one PDF history entry")
	check(not Privacy.record_allowed(pages[0].uri) and not Privacy.settings_allowed(pages[0].uri),"Runtime page capabilities do not enter persistent media records")
	var cloud_uri := "cloud://account/comics/book.PDF"
	library.section=Library.Section.CLOUD
	library._cloud_stack=[{"id":"account","title":"Drive"}]
	library._cloud_entries=[{"title":"book.PDF","uri":cloud_uri,"kind":"pdf"}]
	library.refresh()
	check(library.rows.size()==1 and library.rows[0].kind=="pdf","Cloud PDF is visible in image filter")
	library._choose(library.rows[0]); await opened(library)
	key=library.archives.session; pages=library.archives.image_queue()
	check(library.archives.history_entry().uri==cloud_uri,"Cloud PDF retains original account-bound container URI")
	Privacy.configure(Privacy.LOCAL)
	check(photo.open_image(pages[0].uri,pages[0].title,pages,{}, {},library.archives.history_entry()),"Cloud pages use shared single-page reader")
	await settle(photo)
	check(catalog.lookup(cloud_uri).is_empty(),"Local-only history excludes cloud PDF")
	Privacy.configure(Privacy.ALL)
	photo.set_layout_mode(4); await settle(photo)
	check(photo.snapshot().magazine_pages==2,"Cloud PDF supports shared double-page reading")
	check(catalog.lookup(cloud_uri).kind=="pdf" and catalog.lookup(cloud_uri).location.source_uri==cloud_uri,"Cloud reading records stable PDF container location")
	var CloudLocation := preload("res://scripts/media_location.gd")
	var cloud_favorites := preload("res://scripts/favorite_store.gd").new(folder.path_join("cloud_favorites-" + str(Time.get_ticks_usec())))
	var saved: Dictionary = library.archives.favorite_location()
	check(saved.source_file.id=="9007199254740994", "Verified file ID survives without numeric rounding")
	check(cloud_favorites.toggle(CloudLocation.folder_uri(saved), "book.PDF", "folder", saved), "PDF favorite saves verified identity")
	check(catalog.save(), "PDF recent identity saves")
	photo.close_image(); library.archives.close()
	check(not host.refs.has(key),"Cloud reader and browser release their independent references")
	var restored := preload("res://scripts/recent_files.gd").new(catalog.directory); restored.load_saved()
	library.section=Library.Section.RECENT
	library._choose(restored.lookup(cloud_uri)); await opened(library)
	check(CloudLocation.cloud_file(host.request_identity,cloud_uri)==saved.source_file, "Recent after restart passes durable file ID directly to PDF open")
	library.archives.close()
	var restored_cloud_favorites := preload("res://scripts/favorite_store.gd").new(cloud_favorites.directory)
	library.collections.open_location(restored_cloud_favorites.list_favorites()[0]); await opened(library)
	check(CloudLocation.cloud_file(host.request_identity,cloud_uri)==saved.source_file, "Favorite after restart passes durable file ID directly to PDF open")
	library.archives.close()
	var dirty: Dictionary = saved.source_file.duplicate(); dirty.download_url="https://secret.invalid/ticket"; dirty.token="secret"
	check(CloudLocation.cloud_file(dirty,cloud_uri)==saved.source_file, "Persistent identity strips download tickets and tokens")
	check(CloudLocation.cloud_file(dirty,"cloud://another/book.PDF").is_empty(), "Identity cannot cross accounts or files")
	var old: Dictionary=saved.duplicate(true); old.erase("source_file")
	check(cloud_favorites.remove(CloudLocation.folder_uri(saved)) and cloud_favorites.toggle(CloudLocation.folder_uri(old), "book.PDF", "folder", old), "Prepare legacy favorite")
	check(cloud_favorites.refresh_container_identity(cloud_uri,saved.source_file) and cloud_favorites.lookup(CloudLocation.folder_uri(old)).location.source_file==saved.source_file,"Opening an old favorite upgrades its identity without toggling it")
	cloud_favorites.protected=true; cloud_favorites.lock()
	check(not cloud_favorites.refresh_container_identity(cloud_uri,saved.source_file),"Locked favorite identities cannot be updated outside the vault")
	library.section=Library.Section.CLOUD
	var video := Surface.new(); video.platform=host; root.add_child(video)
	video.pip.container_opened.connect(func(entry): catalog.opened_container(entry))
	catalog.clear_all()
	video.pip.set_count(2,Transform3D.IDENTITY)
	var window: Node3D=video.pip.windows[1]
	library.image_selected.connect(func(uri,_title): video.pip.load_image(window,uri,library.selected_pdf.duplicate()))
	library.begin_image_picker()
	library._cloud_entries=[{"title":"book.PDF","uri":cloud_uri,"kind":"pdf"},{"title":"book.zip","uri":"cloud://account/book.zip","kind":"archive"}]
	library.refresh()
	check(library.rows.size()==1 and library.rows[0].kind=="pdf","PiP picker admits PDF without enabling unrelated archive reading")
	library._choose(library.rows[0]); await opened(library)
	key=library.archives.session
	library._choose(library.rows[0]); await pip_settle(window)
	check(not library.image_picker_mode and not library.archives.browsing and host.refs[key]==1,"Picker transfers exactly one lease to PiP before closing")
	check(window.image_mode and window.pdf_document.page==0 and video.pip.windows.size()==2,"PDF becomes an image window while other video slot remains")
	check(catalog.list_recent().size()==1 and catalog.lookup(cloud_uri).location.path=="","PiP success records cloud PDF directory")
	window.controls=true; window.set_size(window.size*1.7); window.refresh()
	var extent := maxf(window.size.x,window.size.y); var pose: Transform3D=window.global_transform
	tap(window,8); await pip_settle(window)
	check(window.pdf_document.page==1 and is_equal_approx(maxf(window.size.x,window.size.y),extent) and window.global_transform==pose,"Real ray next preserves user scale and pose")
	var second: Node3D=video.pip.windows[2]
	video.pip.load_image(second,"pdfpage://%s/1"%key,window.pdf_document); await pip_settle(second)
	check(host.refs[key]==2,"Two windows independently retain one document")
	video.pip.close(1)
	second.controls=true; second.refresh(); tap(second,8); await pip_settle(second)
	check(second.pdf_document.page==2 and host.refs[key]==1,"Closing first window does not revoke second window")
	var reads := host.reads.size(); second._activate(8); await process_frame
	check(host.reads.size()==reads,"End boundary never requests an invalid page")
	host.held=true; tap(second,7); await create_timer(.05).timeout
	var failed := host.serial; host.deliver(failed,false); await process_frame
	check(second.image_error and second.pdf_document.page==2 and host.refs[key]==1,"Failed turn preserves displayed page and its lease")
	tap(second,7); await create_timer(.05).timeout
	var late := host.serial; video.pip._action(2,"video",0); host.deliver(late); await process_frame
	check(not second.image_mode and second.pdf_document.is_empty() and not host.refs.has(key),"Return to video cancels pending page and rejects late result")
	host.held=false
	library.begin_image_picker(); library.archives.open({"uri":"file:///cancel.pdf","title":"cancel.pdf"}); await opened(library)
	key=library.archives.session; library.dismiss()
	check(not host.refs.has(key) and not library.image_picker_mode,"Cancelling document picker closes its browser lease")
	library.archives.open({"uri":"file:///book.PDF","title":"book.PDF"}); await opened(library)
	key=library.archives.session
	var protected_source: Dictionary=library.archives.history_entry()
	video.pip.load_image(second,"pdfpage://%s/0"%key,{"session":key,"page":0,"pages":3,"source":protected_source})
	await pip_settle(second); library.archives.close()
	var favorites := preload("res://scripts/favorite_store.gd").new(folder.path_join("favorites-"+str(Time.get_ticks_usec())))
	var location: Dictionary=protected_source.location
	favorites.toggle(preload("res://scripts/media_location.gd").folder_uri(location),"book.PDF","folder",location)
	video.pip.close_protected_documents(favorites)
	check(not video.pip.windows.has(2) and not host.refs.has(key),"Lock preparation closes PDF belonging to a protected container favorite")
	video.pip.clear(); video.queue_free(); photo.queue_free(); library.queue_free(); await process_frame
	check(host.refs.is_empty(),"All document references released at teardown")
	for failure in failures: push_error(failure)
	print("PDF reading: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
