extends SceneTree
const PipWindow := preload("res://scripts/video_pip_window.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/pdf")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size=Vector2i(1200,1000); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position.z=1.4; camera.fov=65; viewport.add_child(camera)
	var window := PipWindow.new(); viewport.add_child(window); window.controls=true
	var image := Image.create(400,600,false,Image.FORMAT_RGBA8); image.fill(Color(0.96,0.95,0.91))
	image.fill_rect(Rect2i(25,25,350,180),Color(0.23,0.4,0.6)); image.fill_rect(Rect2i(25,225,165,350),Color(0.75,0.48,0.3)); image.fill_rect(Rect2i(210,225,165,350),Color(0.3,0.55,0.4))
	window.show_image(ImageTexture.create_from_image(image)); window.set_size(Vector2(0.48,0.72))
	window.pdf_document={"session":"preview","page":8,"pages":123}; window.position.y=.12
	for language in ["en","zh","zh_Hant","ja"]:
		I18n.use(language); window.refresh(); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("pip-%s.png"%language))
		check(window._buttons.size()==5,"PDF toolbar has only close, mode, replace and page arrows")
		for i in window._buttons.size():
			var button: Dictionary=window._buttons[i]
			for j in range(i+1,window._buttons.size()): check(not button.rect.intersects(window._buttons[j].rect),"PDF controls do not overlap")
			var origin: Vector3=button.node.global_position+window.global_basis.z
			check(not window.window_hit(origin,-window.global_basis.z).is_empty(),"PDF toolbar remains within pointer surface")
		check(window._labels.any(func(label):return label.text=="9 / 123"),"Page counter remains concise and readable")
	window.queue_free(); await process_frame
	var library := Library.new(); viewport.add_child(library); library.visible=true; library.set_process(false)
	library.collections.store=preload("res://scripts/favorite_store.gd").new(output.path_join("render-favorites-"+str(Time.get_ticks_usec())))
	library.section=Library.Section.LOCAL; library.media_filter=2
	library.archives.pdf=true; library.archives._browsing=true; library.archives.browser_section=Library.Section.LOCAL
	library.archives.target={"uri":"file:///comic.pdf","title":"comic.pdf"}; library.archives.session="preview"
	for i in 12: library.archives.entries.append({"title":"%05d.png"%(i+1),"kind":"image","uri":"pdfpage://preview/%d"%i,"pdf_page":i,"pdf_pages":12})
	camera.position=Vector3(0.10,0,1.1); camera.fov=52
	for language in ["en","zh","zh_Hant","ja"]:
		I18n.use(language); library.refresh(); await frames()
		var pixels := viewport.get_texture().get_image()
		pixels.save_png(output.path_join("directory-%s.png"%language))
		var ink := 0
		for y in range(0,pixels.get_height(),2):
			for x in range(0,pixels.get_width(),2):
				if pixels.get_pixel(x,y).r>.35: ink+=1
		check(ink>200,"Directory screenshot contains visible icons and labels")
		check(library.rows.size()==12 and library.rows[0].title==I18n.t("Page %d")%1,"Directory labels show localized page numbers")
	library.archives.pdf=false; library.archives.directory="Volume 2"
	library.archives.target={"uri":"file:///Manga.cbz","title":"Manga.cbz"}
	library.archives.entries=[{"path":"Volume 2/001.png","title":"Volume 2/001.png","kind":"image","uri":"comic://preview/0"}]
	var recent := preload("res://scripts/recent_files.gd").new(output.path_join("render-recent-"+str(Time.get_ticks_usec())))
	library.catalog=recent; recent.opened_container(library.archives.history_entry())
	for folder in ["Volume 1","Volume 2"]:
		var location: Dictionary=library.archives.favorite_location(); location.path=folder
		var key := preload("res://scripts/media_location.gd").folder_uri(location)
		library.collections.store.toggle(key,"Manga.cbz / "+folder,"folder",location)
	for language in ["en","zh","zh_Hant","ja"]:
		I18n.use(language)
		for compact in [false,true]:
			library.set_compact(compact); library.refresh(); await frames()
			viewport.get_texture().get_image().save_png(output.path_join("volume-%s-%s.png"%[language,"compact" if compact else "full"]))
			var stars: Array=library._buttons.filter(func(b):return b.target==library.Collections.FAVORITE_FOLDER)
			check(stars.size()==1 and stars[0].enabled,"Volume favorite is available in both layouts")
			if not stars.is_empty():
				for button in library._buttons:
					if button.target!=stars[0].target: check(not stars[0].rect.intersects(button.rect),"Favorite control does not overlap another control")
	library.archives._browsing=false; library.set_compact(false); library.section=Library.Section.RECENT
	for tab in [0,1]:
		library.collections.home_tab=tab; library.refresh(); await frames()
		viewport.get_texture().get_image().save_png(output.path_join("volume-%s.png"%["recent" if tab==0 else "favorites"]))
		check(library.rows.size()==(1 if tab==0 else 2),"Recent keeps last volume; favorites keep independent volumes")
	viewport.queue_free(); await process_frame
	I18n.use("en")
	for failure in failures: push_error(failure)
	print("PDF UI render: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
