extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var folder := "res://../../build/output/photo-magazine/fixtures"
var entries: Array[Dictionary] = []

class InputApp extends Main:
	var test_rays := {}
	func _ray(hand: String) -> Variant: return test_rays.get(hand)

class Host extends RefCounted:
	signal photo_ready(id: int, payload: String)
	var requests: Array[String] = []
	var paths: Array[String] = []
	var released: Array[int] = []
	var held := false
	var reject := false
	var pending := {}
	func open_photo(uri: String) -> int:
		requests.append(uri)
		var id := requests.size()
		pending[id] = uri
		if not held: deliver.call_deferred(id)
		return id
	func deliver(id: int) -> void:
		var at := int(str(pending[id]).get_file())
		photo_ready.emit(id, JSON.stringify({"state":"error"} if reject else {"state":"ready", "path":paths[at]}))
	func cancel_photo(id: int) -> void: released.append(id)
	func release_photo(id: int) -> void: released.append(id)
	func archive_close(_key: String) -> void: pass
	func pdf_retain(_key: String) -> bool: return true
	func pdf_close(_key: String) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func settle(photo: Node3D) -> void:
	var until := Time.get_ticks_msec() + 5000
	while photo.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(), "Production load completes: " + photo.error)
	photo.finish_transition()
	photo._reveal_seconds = 0
	photo._placeholder.visible = false
	photo.material.set_shader_parameter("reveal_progress", 1.0)

func button(menu: Node3D, target: int) -> Dictionary:
	for b in menu._buttons:
		if b.target == target: return b
	return {}

func tap(menu: Node3D, target: int) -> void:
	var b := button(menu, target)
	check(not b.is_empty() and b.enabled, "Ray control available: %d" % target)
	if b.is_empty() or not b.enabled: return
	var origin: Vector3 = b.node.to_global(Vector3(0,0,1))
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)

func single_to_magazine_checks(app: Node3D, source: String) -> void:
	var menu: Node3D = app.photo_menu
	menu.visible = true; menu.section = 0
	for remembered in [false, true]:
		for selected in [false, true]:
			app._on_photo_action("photo_layout_0"); await settle(app.photo)
			app.photo.magazine.right_to_left = remembered
			menu.refresh()
			tap(menu, Menu.PHOTO_LAYOUT); tap(menu, Menu.PHOTO_LAYOUT_BASE + 4)
			await settle(app.photo)
			check(app.photo.gallery.mode == 4 and menu._magazine_order_open, source + ": magazine choice applies before the optional direction selection")
			var default_pixel: Color = app.photo._texture.get_image().get_pixel(30, 100)
			check(app.photo.magazine.right_to_left == remembered and (default_pixel.b > .9 if remembered else default_pixel.r > .9), source + ": immediate spread uses the remembered direction")
			tap(menu, Menu.PHOTO_MAGAZINE_ORDER + int(selected)); await settle(app.photo)
			var context := "%s: remembered RTL=%s, selected RTL=%s" % [source, remembered, selected]
			check(app.photo.magazine.active() and app.photo._size == Vector2(220, 200), context + " enters a full two-page spread on the first click")
			var pixel: Color = app.photo._texture.get_image().get_pixel(30, 100)
			check(app.photo.magazine.right_to_left == selected and (pixel.b > .9 if selected else pixel.r > .9), context + " composes the selected page order")
			check(not menu._layout_open and not menu._magazine_order_open, context + " closes the picker")
			var saved := ConfigFile.new(); saved.load(app.settings_path)
			check(saved.get_value("photo_screen", "magazine_rtl") == selected and saved.get_value("photo_screen", "reading_layout" if app.photo.archive_mode else "layout") == 4, context + " persists both direction and layout")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	for i in 7:
		var image := Image.create(100 + 20 * i, 200, false, Image.FORMAT_RGBA8)
		image.fill(Color.RED if i % 2 == 0 else Color.BLUE)
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % i))
		image.save_png(path)
		entries.append({"uri":"file://" + path, "title":"%d.png" % i, "kind":"image"})
	var photo := Photo.new(); photo.history_enabled = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(folder.path_join("memory.json"))
	root.add_child(photo)
	var source_job := {"image":Image.create(4,4,false,Image.FORMAT_RGBA8)}
	photo.magazine.first = source_job
	var worker_job := {}; photo.magazine.decorate(worker_job); photo.magazine.cancel()
	check(worker_job.magazine_first.get("image") is Image, "Cancelling a spread cannot erase a running decoder's source snapshot")
	photo.open_image(entries[0].uri, entries[0].title, entries); await settle(photo)
	check(photo.material.get_shader_parameter("edge_feather") != Vector2.ZERO, "Ordinary photographs retain their soft edge")
	photo.set_layout_mode(4); await settle(photo)
	check_page_edges(photo)
	check(photo.index == 0 and photo._size == Vector2(220,200), "Two full sources join at equal height without stretching")
	var pixels: Image = photo._texture.get_image()
	check(pixels.get_pixel(30,100).r > .9 and pixels.get_pixel(190,100).b > .9, "Left and right source pixels survive composition")
	check(photo.gallery.cards.is_empty() and photo.panel.visible and photo.geometry == 0, "Magazine uses the full photo surface, not preview cards")
	check(not photo.set_depth(true) and not photo.can_portrait() and not photo.can_spatial(), "Desktop-only spread cannot request native conversion before registration")
	check(photo.snapshot().magazine_pages == 2 and not photo.snapshot().can_previous, "Spread count and first boundary")
	photo.navigate(1); await settle(photo); check(photo.index == 2, "Next advances two images")
	photo.navigate(-1); await settle(photo); check(photo.index == 0, "Previous reverses a full spread")
	photo.magazine.toggle_single(); await settle(photo)
	check(photo._size == Vector2(100,200) and photo.snapshot().magazine_single, "Cover can be shown alone")
	check_page_edges(photo)
	photo.navigate(1); await settle(photo); check(photo.index == 1, "Turn after a single cover starts a new pair")
	photo.navigate(1); await settle(photo); check(photo.index == 3, "Following turns continue by pairs")
	photo.navigate(-1); await settle(photo); check(photo.index == 1, "Back navigation preserves cover pairing")
	photo.navigate(-1); await settle(photo); check(photo.index == 0 and photo.magazine.count(0) == 1, "Returning to the cover retains its standalone setting")
	photo.magazine.toggle_single(); await settle(photo)
	photo.magazine.shift(1); await settle(photo); check(photo.index == 1, "One-image correction changes the pair origin")
	photo.magazine.shift(-1); await settle(photo); check(photo.index == 0, "One-image correction works in both directions")
	photo.magazine.right_to_left = true; photo.magazine.reload(); await settle(photo)
	pixels = photo._texture.get_image()
	check(pixels.get_pixel(30,100).b > .9 and pixels.get_pixel(190,100).r > .9, "Right-to-left swaps pages without changing reading progress")
	photo.select_image(6); await settle(photo)
	check(photo.snapshot().magazine_pages == 1 and not photo.navigate(1) and not photo.snapshot().can_next, "Odd last image stands alone and does not wrap to the cover")
	photo.set_layout_mode(0); await settle(photo)
	check(photo._size == Vector2(220,200) and photo.gallery.mode == 0, "Leaving magazine reloads the original source")
	check(photo.material.get_shader_parameter("edge_feather") != Vector2.ZERO, "Leaving ordinary magazine mode restores the photographic edge")
	photo.select_image(0); await settle(photo); check(photo._size == Vector2(100,200), "Single view never retains composed pixels")
	photo.close_image()
	await archive_checks(photo)
	photo.free()
	await app_checks()
	await reading_preference_checks()
	print("Photo magazine: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func check_page_edges(photo: Node3D, full_page: bool = true) -> void:
	var feather: Vector2 = photo.material.get_shader_parameter("edge_feather")
	check(feather == Vector2.ZERO if full_page else feather.x > 0 and feather.y > 0, "Only Magazine / Comics disables edge feathering")
	check(photo.material.get_shader_parameter("content_zoom") == 1.0 and photo.material.get_shader_parameter("crop_center") == Vector2(.5,.5), "Reading shows the complete original at 100% content zoom")
	var layer := Photo.VideoLayer.new(null)
	var values := layer.layer_values(photo, photo, Photo.VideoLayer.PICTURE, photo._size, 0, photo._edge_feather())
	var rect := Rect2(values[9],values[10],values[11],values[12])
	if full_page:
		check(rect.position == Vector2.ZERO and rect.size.is_equal_approx(photo._size), "Magazine compositor source rectangle includes the entire page")
	else:
		check(rect.position.x > 0 and rect.position.y > 0 and rect.end.x < photo._size.x and rect.end.y < photo._size.y, "Single-page compositor leaves the feathered edge in the eye buffers")

func archive_checks(photo: Node3D) -> void:
	photo.auto_depth = false # The archive fixture implements 2D decoding, not the native depth service.
	var host := Host.new()
	for entry in entries: host.paths.append(str(entry.uri).trim_prefix("file://"))
	var pages: Array[Dictionary] = []
	for i in entries.size(): pages.append({"uri":"comic://test/%d" % i, "title":"%d.png" % i, "kind":"image"})
	photo.platform = host; host.photo_ready.connect(photo._on_ready)
	photo.open_image(pages[0].uri, pages[0].title, pages); await settle(photo)
	photo.set_layout_mode(0); await settle(photo)
	check_page_edges(photo, false)
	photo.set_layout_mode(4); await settle(photo)
	check_page_edges(photo)
	check(photo.archive_mode and photo.gallery.mode == 4 and photo._size == Vector2(220,200), "Archive pages use the same full-resolution composition")
	check(not photo.snapshot().depth_available, "A spread without native registration never exposes conversion of an individual page")
	check(host.requests.slice(-2) == ["comic://test/0", "comic://test/1"], "Only the selected two pages are requested in order")
	photo.set_layout_mode(2); check(photo.gallery.mode == 4, "Archive still rejects unrelated wall layouts")
	photo.navigate(1); await settle(photo)
	check(photo.index == 2 and host.requests.slice(-2) == ["comic://test/2", "comic://test/3"], "Archive turn reads exactly the next spread")
	host.held = true
	photo.navigate(1)
	var old := host.requests.size()
	photo.navigate(-1)
	var latest := host.requests.size()
	host.deliver(old); host.deliver(latest)
	host.held = false
	await settle(photo)
	check(photo.index == 2 and photo._size == Vector2(300,200), "Late archive result cannot replace the latest requested spread")
	host.held = true; photo.navigate(1)
	host.deliver(host.requests.size())
	var until := Time.get_ticks_msec() + 5000
	while photo.magazine.first.is_empty() and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	host.reject = true; host.deliver(host.requests.size())
	check(not photo.loading and photo.error == "Image unavailable" and photo.index == 2, "Failed second page does not accept a mismatched or partial spread")
	check(photo.magazine.first.is_empty(), "Failure releases the waiting first page")
	host.held = false; host.reject = false
	photo.set_layout_mode(0); await settle(photo)
	check(photo._size == Vector2(180,200), "Switching layout after failure loads the requested original")
	photo.close_image()
	check(photo.magazine.first.is_empty() and photo.magazine.single_pages.is_empty(), "Closing an archive clears page buffers and session corrections")

func app_checks() -> void:
	I18n.use("en")
	var app := InputApp.new(); app.settings_path = folder.path_join("app.cfg")
	var config := ConfigFile.new(); config.set_value("appearance","background","dark"); config.save(app.settings_path)
	root.add_child(app); app.set_process(false); I18n.use("en"); await process_frame
	app.photo_active = true; app.player_menu = app.photo_menu
	app._on_photo_action("photo_scenery_morning")
	app._on_photo_action("photo_scenery_yaw")
	app._on_photo_action("photo_scenery_brightness")
	app._on_photo_action("photo_scenery_cinema")
	check(app.photo_background.choice == "morning" and "cinema" not in Menu.SCENERIES, "Photo background excludes cinema in both picker and action handler")
	var yaw: float = app.photo_background.yaw
	var brightness: float = app.photo_background.brightness
	check(app.background.choice == "dark" and app.photo_background.choice == "morning", "Photo picker changes only the independent photo background")
	app._on_setting_changed("background", "belfast")
	app._on_setting_changed("background_yaw", 180.0)
	check(app.photo_background.choice == "morning" and app.photo_background.yaw == yaw and app.photo_background.brightness == brightness, "Global scenery settings cannot change photo type, rotation or brightness")
	check(app._active_background() == app.photo_background, "Photos render their own selected scenery")
	app.photo_active = false
	check(app._active_background() == app.background, "Video returns to global scenery")
	config.load(app.settings_path)
	check(config.get_value("photo_background","background") == "morning" and config.get_value("appearance","background") == "belfast", "Independent background choices both persist on disk")
	app.photo_active = true
	app.photo_background.directory = ProjectSettings.globalize_path(folder.path_join("photo-backgrounds"))
	app.background.directory = ProjectSettings.globalize_path(folder.path_join("global-backgrounds"))
	var sky := Image.create(512,256,false,Image.FORMAT_RGB8); sky.fill(Color(.2,.4,.7))
	var sky_path := ProjectSettings.globalize_path(folder.path_join("sky_360_2D.png")); sky.save_png(sky_path)
	app.photo.open_image("file://"+sky_path,"sky_360_2D.png"); await settle(app.photo)
	app.photo_menu.visible = true; app.photo_menu.section = 1; app.photo_menu.refresh()
	tap(app.photo_menu, Menu.PHOTO_BACKGROUND)
	check(not button(app.photo_menu, Menu.PHOTO_BACKGROUND).enabled and button(app.photo_menu, Menu.PHOTO_BACKGROUND).node.get_child(0).text == "Saving…", "Import disables repeat clicks while saving")
	var until := Time.get_ticks_msec() + 5000
	while app.photo_background.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	var photo_copy: String = app.photo_background.custom_path
	check(app.photo_background.choice == "custom" and FileAccess.file_exists(photo_copy) and photo_copy != sky_path, "Photo panorama uses its own private persistent copy")
	check(app.background.choice == "belfast" and app.photo_active and app.photo.panel.visible, "Importing photo scenery leaves the current image usable and global scenery unchanged")
	check(not button(app.photo_menu, Menu.PHOTO_BACKGROUND).enabled and button(app.photo_menu, Menu.PHOTO_BACKGROUND).node.get_child(0).text == "Background set", "Successful save refreshes the visible button and disables it")
	app._on_photo_action("photo_background")
	check(not app.photo_background.loading and app.photo_background.custom_path == photo_copy, "Repeated action cannot create another copy after success")
	app.photo_menu.section = 0; app.photo_menu._scenery_open = true; app.photo_menu.refresh()
	check(not button(app.photo_menu, Menu.PHOTO_SCENERY_IMPORT).enabled and button(app.photo_menu, Menu.PHOTO_SCENERY_IMPORT).node.get_child(0).text == "Background set", "Photo scenery import shares the completed state")
	app._on_photo_action("photo_scenery_dark")
	check(button(app.photo_menu, Menu.PHOTO_SCENERY_IMPORT).enabled, "Changing scenery permits setting the current photo again")
	app._on_photo_action("photo_scenery_custom")
	app.photo_menu._scenery_open = false; app.photo_menu.section = 1; app.photo_menu.refresh()
	var other_source: Dictionary = app.photo.background_source(); other_source.swap_eyes = not other_source.swap_eyes
	check(not app.photo_background.matches_photo(other_source), "Changed source eye selection is not mistaken for the applied panorama")
	app.photo_background.import_photo({"path":folder.path_join("missing-panorama.png")}, "Missing")
	check(button(app.photo_menu, Menu.PHOTO_BACKGROUND).enabled and app.photo_menu._status.text == "Background unavailable", "A failed import shows an error and permits retry rather than claiming success")
	tap(app.photo_menu, Menu.PHOTO_BACKGROUND)
	until = Time.get_ticks_msec() + 5000
	while app.photo_background.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	photo_copy = app.photo_background.custom_path
	check(not button(app.photo_menu, Menu.PHOTO_BACKGROUND).enabled and app.photo_background.matches_photo(app.photo.background_source()), "Retry reaches the completed state only after saving")
	app.recent_menu.dismiss()
	var viewing_uri: String = app.photo.local_uri
	var viewing_serial: int = app.photo._serial
	var viewing_index: int = app.photo.index
	var viewing_queue: Array = app.photo.queue.duplicate(true)
	var panorama_bytes := FileAccess.get_file_as_bytes(sky_path)
	FileAccess.open(sky_path, FileAccess.WRITE).store_string("broken")
	tap(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND)
	until = Time.get_ticks_msec() + 5000
	while app.background.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	check(app.photo_active and app.photo_menu.visible and not app.recent_menu.visible and app.photo.local_uri == viewing_uri,
		"Failed global import keeps the same photo and menu open")
	check(button(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND).enabled and app.photo_menu._status.text == "Global background unavailable",
		"Global import failure is visible in place and allows retry")
	FileAccess.open(sky_path, FileAccess.WRITE).store_buffer(panorama_bytes)
	app.background.set_process(false)
	tap(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND)
	check(not button(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND).enabled and app.photo_menu._status.text == "Saving global background…",
		"Global background shows saving in place and disables repeated clicks")
	var pending_copy: String = app.background._job.path
	app._on_photo_action("global_background")
	check(app.background._job.path == pending_copy, "Repeated global action cannot start another pending copy")
	app.background.set_process(true)
	until = Time.get_ticks_msec() + 5000
	while app.background.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	check(app.background.choice == "custom" and app.background.custom_path != photo_copy and app.photo_active and app.photo.panel.visible,
		"Global import saves its separate copy while keeping the photo open")
	check(app.photo.local_uri == viewing_uri and app.photo._serial == viewing_serial and app.photo.queue == viewing_queue and app.photo.index == viewing_index,
		"Global import preserves the current photo link, session and navigation queue")
	check(app.photo_menu.visible and app.player_menu == app.photo_menu and not app.recent_menu.visible,
		"Global import does not navigate to the library or settings")
	check(not button(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND).enabled and button(app.photo_menu, Menu.PHOTO_GLOBAL_BACKGROUND).node.get_child(0).text == "Background set"
		and app.photo_menu._status.text == "Global background set. Change it in Settings → Background.", "Successful global import confirms the result and its settings location")
	app._on_photo_action("global_background")
	check(not app.background.loading and app.background.custom_path == pending_copy, "Setting an already applied global panorama is idempotent")
	app.photo_active = true; app.player_menu = app.photo_menu
	var global_copy: String = app.background.custom_path
	var background_menu: Node3D = app.photo_menu
	background_menu.visible = true; background_menu.section = 0; background_menu._scenery_open = true; background_menu.refresh()
	var global_custom_target := Menu.PHOTO_SCENERY_BASE + Menu.SCENERIES.find("global_custom")
	check(not button(background_menu, global_custom_target).is_empty(), "Photo chooser includes the user's existing global custom background")
	tap(background_menu, global_custom_target)
	until = Time.get_ticks_msec() + 5000
	while app.photo_background.loading and Time.get_ticks_msec() < until: await create_timer(.01).timeout
	photo_copy = app.photo_background.custom_path
	check(app.photo_background.choice == "custom" and FileAccess.file_exists(photo_copy) and photo_copy != global_copy, "Choosing existing custom scenery creates a separately owned photo copy")
	app._on_setting_changed("background_remove",true)
	check(FileAccess.file_exists(photo_copy) and app.photo_background.has_custom(), "Deleting the global custom sky cannot delete the photo sky")
	app.photo_active = true; app.player_menu = app.photo_menu
	app.photo.open_image(entries[0].uri,entries[0].title,entries); await settle(app.photo)
	var menu: Node3D = app.photo_menu; menu.visible = true; menu.section = 0; menu._scenery_open = false; menu.refresh()
	tap(menu, Menu.PHOTO_LAYOUT)
	check(button(menu, Menu.PHOTO_LAYOUT_BASE + 4).rect.position.x > button(menu, Menu.PHOTO_LAYOUT_BASE).rect.position.x and button(menu, Menu.PHOTO_LAYOUT_BASE + 4).rect.position.x < button(menu, Menu.PHOTO_LAYOUT_BASE + 1).rect.position.x, "Magazine follows Single image in the picker")
	tap(menu, Menu.PHOTO_LAYOUT_BASE + 4)
	check(menu._magazine_order_open and app.photo.gallery.mode == 4, "Magazine switches layouts immediately and offers reading-order adjustment")
	check(button(menu, Menu.PHOTO_MAGAZINE_ORDER).base_color == menu.SELECTED, "Default left-to-right preference is selected")
	tap(menu, Menu.PHOTO_MAGAZINE_ORDER + 1); await settle(app.photo)
	check(app.photo.magazine.active(), "Real ray activation enters magazine mode")
	check(app.photo.magazine.right_to_left and app.photo._texture.get_image().get_pixel(30,100).b > .9, "Reading-order selection controls the actual composed pages")
	config.load(app.settings_path)
	check(config.get_value("photo_screen", "magazine_rtl", false), "Reading order is saved as a global photo preference")
	menu.refresh()
	check(menu.find_children("*","Label3D",true,false).any(func(label):return label.text == "Magazine / Comics · Right to left"), "Magazine caption always shows the selected reading order")
	tap(menu, Menu.PHOTO_LAYOUT); tap(menu, Menu.PHOTO_LAYOUT_BASE)
	await settle(app.photo)
	tap(menu, Menu.PHOTO_LAYOUT); tap(menu, Menu.PHOTO_LAYOUT_BASE + 4)
	check(button(menu, Menu.PHOTO_MAGAZINE_ORDER + 1).base_color == menu.SELECTED, "Reopening the second-stage picker inherits the saved reading habit")
	check(menu.navigate_back() and not menu._magazine_order_open and menu._layout_open, "Back from reading order returns to layouts without changing the preference")
	check(menu.navigate_back(), "Close layouts before repeated single-to-magazine transitions")
	await single_to_magazine_checks(app, "Photo album")
	tap(menu, Menu.PHOTO_LAYOUT)
	tap(menu, Menu.PHOTO_LAYOUT_BASE + 4); tap(menu, Menu.PHOTO_MAGAZINE_ORDER); await settle(app.photo)
	check(not app.photo.magazine.right_to_left and app.photo._texture.get_image().get_pixel(30,100).r > .9, "Explicit left-to-right selection replaces the saved preference")
	app._on_photo_action("photo_magazine_rtl"); await settle(app.photo)
	app.favorites.protected = true
	app.favorites.entries[app.favorites.key_for(entries[1].uri)] = {"uri":entries[1].uri}
	app._update_favorite_session()
	check(app._playing_protected, "The second page participates in the protected-favorite lock boundary")
	app.photo.pending_index = 4
	app._update_favorite_session()
	check(app._playing_protected, "The previous second page remains protected while a new spread loads")
	app.photo.pending_index = -1
	app.favorites.protected = false; app.favorites.entries.clear()
	app._update_favorite_session()
	menu.dismiss(); app.recent_menu.dismiss(); app.photo_magazine_controls.sync(); tap(app.photo_magazine_controls, 2); await settle(app.photo)
	check(app.photo.magazine.single(0), "Real ray activation toggles standalone page")
	await inline_checks(app)
	menu.visible = true; menu.refresh(); tap(menu, Menu.PHOTO_SCENERY)
	check(button(menu, Menu.PHOTO_NEXT).is_empty() and not button(menu, Menu.PHOTO_SCENERY_BACK).is_empty(), "Background opens in a standalone panel with a return control")
	check(Menu.SCENERIES[2] == "night", "Milky Way panorama is the third photo background choice")
	tap(menu, Menu.PHOTO_SCENERY_BASE + 2)
	var night_deadline := Time.get_ticks_msec() + 15000
	while app.photo_background.loading and Time.get_ticks_msec() < night_deadline: await create_timer(.01).timeout
	check(app.photo_background.choice == "night" and app.photo_background.error.is_empty() and app.photo_background._builtin != null and
		app.photo_background._builtin.get_size() == Vector2(6000,3000) and app.background.choice == "belfast", "Photo ray selects the original 6K Milky Way independently of global scenery")
	check(menu._status.text.contains("ESO/S. Brunier"), "Photo Milky Way panel visibly credits the photographer")
	check(not button(menu, Menu.PHOTO_SCENERY_YAW).is_empty() and not button(menu, Menu.PHOTO_SCENERY_LIGHT).is_empty(), "Photo night panorama retains direction and brightness controls")
	tap(menu, Menu.PHOTO_SCENERY_YAW); tap(menu, Menu.PHOTO_SCENERY_LIGHT)
	var night_saved := ConfigFile.new(); night_saved.load(app.settings_path)
	check(night_saved.get_value("photo_background", "background") == "night" and
		night_saved.get_value("photo_background", "background_yaw") == app.photo_background.yaw and
		night_saved.get_value("photo_background", "background_brightness") == app.photo_background.brightness, "Photo night choice, direction and brightness persist")
	app.photo_background.set_yaw(yaw); app.photo_background.set_brightness(brightness)
	tap(menu, Menu.PHOTO_SCENERY_BASE + Menu.SCENERIES.find("dark"))
	check(app.photo_background.choice == "dark" and app.background.choice == "belfast", "Real photo background ray action stays independent")
	app.photo.archive_mode = true; menu._scenery_open = false; menu._layout_open = true; menu.refresh()
	check(not button(menu, Menu.PHOTO_LAYOUT_BASE + 4).is_empty() and button(menu, Menu.PHOTO_LAYOUT_BASE + 2).is_empty(), "Archive picker contains Single and Magazine")
	app.photo.archive_mode = false
	app.photo.set_layout_mode(2); app.photo.gallery.set_wall_rows(3); menu._layout_open = false; menu.refresh()
	check(menu.find_children("*","Label3D",true,false).any(func(label):return label.text == "Photo wall · 3 rows"), "Current wall rows are visible without opening the picker")
	var top := [107,100,108,Menu.FAVORITE,Menu.PHOTO_SCENERY,Menu.PHOTO_SHUFFLE]
	for i in range(1,top.size()):
		check(is_equal_approx(button(menu,top[i]).node.position.x-button(menu,top[i-1]).node.position.x,.11), "Top actions and conditional batch button use equal spacing")
	app.photo.close_image(); app.free(); await process_frame
	var restored := Main.new(); restored.settings_path = folder.path_join("app.cfg"); root.add_child(restored); restored.set_process(false)
	check(restored.photo_background.choice == "dark" and restored.background.choice == "belfast" and restored.photo_background.yaw == yaw, "Photo scenery survives a fresh application instance")
	check(restored.photo.magazine.right_to_left, "Global reading habit survives a fresh application instance")
	await archive_checks(restored.photo)
	check(restored.photo.magazine.right_to_left, "Archive changes and session cleanup preserve the global reading habit")
	restored.free(); await process_frame
	config.load(app_settings_path())
	config.set_value("photo_background","background","cinema"); config.save(app_settings_path())
	var invalid := Main.new(); invalid.settings_path = app_settings_path(); root.add_child(invalid); invalid.set_process(false)
	check(invalid.photo_background.choice == "belfast" and invalid.background.choice == "belfast", "A stale cinema choice cannot enter photo background after restart")
	invalid.free(); await process_frame

func app_settings_path() -> String:
	return folder.path_join("app.cfg")

func inline_checks(app: Node3D) -> void:
	var controls: Node3D = app.photo_magazine_controls
	controls.set_process(false); controls.sync()
	check(controls.visible and not app.photo_menu.visible, "Magazine controls are available without summoning the main menu")
	check(app.menu_composition.menus.has(controls) and controls.get_meta("menu_companion",false), "Inline controls share the native high-resolution menu pool")
	check(not button(controls,0).enabled, "First image cannot shift to a previous pairing")
	var before: Transform3D = app.photo.panel.global_transform.affine_inverse() * controls.global_transform
	app.photo.set_screen_scale(2.0); controls.sync()
	var enlarged: Transform3D = app.photo.panel.global_transform.affine_inverse() * controls.global_transform
	check(enlarged.basis.get_scale().is_equal_approx(before.basis.get_scale()*2.0), "Button and tooltip scale doubles with the image")
	check(is_equal_approx(enlarged.origin.y,before.origin.y*2.0), "Bottom gap and row position scale with the image")
	var far_pose := Transform3D(Basis.from_euler(Vector3(.12,.3,.15)),Vector3(1,.4,-12))
	app.photo.set_flat_world_pose(far_pose); controls.sync()
	check((app.photo.panel.global_transform.affine_inverse()*controls.global_transform).is_equal_approx(enlarged), "Moving, rotating and pushing the image far away keeps the same attachment")
	var target: Vector3 = button(controls,1).node.global_position
	var ray := [app.xr_camera.global_position,(target-app.xr_camera.global_position).normalized()]
	app.test_rays = {"right_hand":ray}
	check(app._active_menu() == controls, "The actual main input router reserves distant inline button hits")
	app.photo_hands.owners = {"right_hand":{}}; controls.sync()
	check(controls.input_menu() == null and controls.visible, "Moving the photo keeps the row visible without stealing gesture input")
	app.photo_hands.owners.clear(); controls.sync()
	app.photo_menu.visible = true; app.photo_menu.online.hand = "left_hand"
	check(app._active_menu() == app.photo_menu, "An existing menu pointer capture takes priority over floating actions")
	app.photo_menu.online.hand = ""; app.photo_menu.dismiss()
	check(not controls.press_pointer("left_hand",Vector3.ZERO,Vector3.UP,true), "The other hand cannot activate stale hover")
	check(app._update_menu_pointer("right_hand",true), "Main trigger routing activates the distant next-pair button")
	await settle(app.photo); controls.sync()
	check(app.photo.index == 1, "Next pairing shifts by one original image")
	tap(controls,0); await settle(app.photo); controls.sync()
	check(app.photo.index == 0, "Previous pairing shifts back by one original image")
	var single_button := button(controls,2)
	controls.update_pointer("right_hand",single_button.node.to_global(Vector3(0,0,1)),-controls.global_basis.z,true)
	check(controls._tooltip != null and controls._tooltip.visible, "Hover exposes the action tooltip without opening the menu")
	var label: Label3D = controls._tooltip.get_child(0)
	check(label.font_size == controls.TEXT_BODY*2 and is_equal_approx(label.pixel_size, controls.TEXT_PIXEL_SIZE), "Tooltip retains the shared 2x text rasterization")
	var icons: Array = single_button.node.find_children("*","MeshInstance3D",true,false)
	check(icons.any(func(icon):return icon.material_override is StandardMaterial3D and icon.material_override.albedo_texture.get_width()==256), "Action icons use a 256px vector raster")
	app.puzzle_game._sync_mode()
	var puzzle_enabled: bool = app.puzzle_game.mode_enabled
	app.puzzle_game.mode_enabled = true; app.puzzle_game._update_photo_entry()
	var entry: Node3D = app.puzzle_game.photo_entry
	check(entry.visible and controls.to_local(entry.global_position).y < controls._tooltip.position.y - controls._tooltip.mesh.size.y*.5, "Optional puzzle entry remains below the magazine row and tooltip")
	check(not entry.ray_hit(app.xr_camera.global_position,(entry.global_position-app.xr_camera.global_position).normalized()).is_empty(), "Moving the optional puzzle entry with the distant image retains its ray reach")
	app.puzzle_game.mode_enabled = puzzle_enabled; app.puzzle_game._update_photo_entry()
	app.photo.loading = true; controls.sync()
	check(controls._buttons.all(func(b):return not b.enabled), "All adjustments disable during an in-flight decode")
	app.photo.loading = false
	app.test_rays.clear(); controls.sync()
	check(controls.input_menu() == null, "Unrelated rays leave photo gestures available")
	app.recent_menu.visible = true; controls.sync()
	check(not controls.visible, "Library modal hides attached controls")
	app.recent_menu.dismiss(); app.photo_active = false; controls.sync()
	check(not controls.visible, "Inline controls cannot leak into video mode")
	app.photo_active = true; app.photo.set_screen_scale(1.0)
	app.photo.set_flat_world_pose(Transform3D(Basis.IDENTITY,Vector3(0,0,-2)))
	controls.sync(); controls.set_process(true)

func reading_preference_checks() -> void:
	var path := folder.path_join("reading-settings.cfg")
	var config := ConfigFile.new()
	config.set_value("photo_screen", "layout", 2); config.save(path)
	var app := Main.new(); app.settings_path = path; root.add_child(app); app.set_process(false)
	app.photo_active = true; app.player_menu = app.photo_menu; app.photo.auto_depth = false
	var host := Host.new()
	for entry in entries: host.paths.append(str(entry.uri).trim_prefix("file://"))
	app.photo.platform = host; host.photo_ready.connect(app.photo._on_ready)
	var pages: Array[Dictionary] = []
	for i in entries.size(): pages.append({"uri":"comic://first/%d" % i,"title":"%d.png" % i,"kind":"image"})
	app.photo.open_image(pages[0].uri,pages[0].title,pages); await settle(app.photo)
	check(app.photo.gallery.mode == 0, "First container read migrates unsupported photo-wall preference to single page")
	await single_to_magazine_checks(app, "Comic archive")
	app._on_photo_action("photo_magazine_rtl"); await settle(app.photo)
	config.load(path)
	check(config.get_value("photo_screen","reading_layout",-1) == 4 and config.get_value("photo_screen","layout",-1) == 2, "Magazine selection immediately saves reading mode without overwriting the ordinary wall")
	app.photo.open_image(pages[2].uri,pages[2].title,pages); await settle(app.photo)
	check(app.photo.gallery.mode == 4 and app.photo.snapshot().magazine_pages == 2, "Selecting another page from the archive browser retains magazine mode")
	app.photo.close_image(); app._save_photo_adjustments()
	check(app.photo.gallery.mode == 2 and app.photo.reading_layout == 4, "Closing restores ordinary photos but keeps the reading preference")
	app.free(); await process_frame
	app = Main.new(); app.settings_path = path; root.add_child(app); app.set_process(false)
	app.photo_active = true; app.player_menu = app.photo_menu; app.photo.auto_depth = false
	app.photo.platform = host; host.photo_ready.connect(app.photo._on_ready)
	check(app.photo.gallery.mode == 2 and app.photo.reading_layout == 4 and app.photo.magazine.right_to_left, "Fresh application restores ordinary layout, reading mode and reading direction independently")
	for page in pages: page.uri = str(page.uri).replace("comic://first/", "pdfpage://second/")
	app.photo.open_image(pages[0].uri,pages[0].title,pages); await settle(app.photo)
	check(app.photo.gallery.mode == 4 and app.photo._size == Vector2(220,200), "A different PDF inherits the saved archive mode and actually composes two pages")
	check_page_edges(app.photo)
	await single_to_magazine_checks(app, "PDF magazine")
	app._on_photo_action("photo_layout_0"); await settle(app.photo)
	check_page_edges(app.photo, false)
	config.load(path)
	check(config.get_value("photo_screen","reading_layout",-1) == 0 and config.get_value("photo_screen","layout",-1) == 2, "Selecting single-page PDF mode persists immediately without changing ordinary photos")
	app.photo.close_image(); app._on_photo_action("photo_magazine_ltr")
	config.load(path)
	check(config.get_value("photo_screen","reading_layout",-1) == 0 and config.get_value("photo_screen","layout",-1) == 4, "Changing ordinary photos to magazine cannot overwrite the saved single-page reading mode")
	app.free(); await process_frame
	app = Main.new(); app.settings_path = path; root.add_child(app); app.set_process(false)
	app.photo_active = true; app.photo.auto_depth = false
	app.photo.platform = host; host.photo_ready.connect(app.photo._on_ready)
	for page in pages: page.uri = str(page.uri).replace("pdfpage://second/", "comic://third/")
	app.photo.open_image(pages[0].uri,pages[0].title,pages); await settle(app.photo)
	check(app.photo.gallery.mode == 0 and app.photo._size == Vector2(100,200), "After restart, a new archive inherits the PDF's single-page choice instead of the ordinary magazine layout")
	app.photo.close_image()
	check(app.photo.gallery.mode == 4, "Leaving the reader still restores ordinary magazine mode")
	app.photo.open_image(pages[0].uri,pages[0].title,pages); await settle(app.photo)
	app._on_photo_action("photo_magazine_ltr"); await settle(app.photo)
	app.photo.platform = null
	app._on_library_chosen(entries[0].uri, entries[0].title, {"projection":"flat", "layout":0})
	await settle(app.photo); app._save_photo_adjustments()
	check(not app.photo.archive_mode and app.photo.gallery.mode == 0 and app.photo.reading_layout == 4, "Opening a retained ordinary image does not mistake its forced single layout for a reading preference")
	app.photo.platform = host
	app.photo.open_image(pages[0].uri,pages[0].title,pages); await settle(app.photo)
	app.photo.platform = null
	app._open_online_panorama({"uri":entries[0].uri,"title":entries[0].title},false)
	await settle(app.photo); app._save_photo_adjustments()
	check(not app.photo.archive_mode and app.photo.reading_layout == 4, "Online photo single-view initialization preserves the container reading mode")
	app.free(); await process_frame
	var legacy := Photo.new(); root.add_child(legacy)
	config = ConfigFile.new(); config.set_value("photo_screen","layout",4)
	legacy.restore_view_settings(config); legacy.platform = host
	legacy.open_image(pages[0].uri,pages[0].title,pages)
	check(legacy.gallery.mode == 4, "Older settings without a reading key inherit an existing magazine preference")
	legacy.close_image(); config.set_value("photo_screen","reading_layout",2); config.set_value("photo_screen","layout",3)
	legacy.restore_view_settings(config); legacy.open_image(pages[0].uri,pages[0].title,pages)
	check(legacy.gallery.mode == 0, "Invalid saved reading layouts cannot enter wall or memories inside a container")
	legacy.close_image(); legacy.free(); await process_frame
