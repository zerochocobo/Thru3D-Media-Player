extends "res://tests/test_photo_magazine.gd"
## Real library lifecycle and Main ray routing, with only the native PDF bridge mocked.
const PdfTests := preload("res://tests/test_pdf_reading.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
var actions: Array[String] = []

class PdfHost extends PdfTests.Host:
	var window := {}
	func reading_page_window(payload: String) -> void:
		window = JSON.parse_string(payload)

func routed_tap(app: Node3D, target: int) -> void:
	var menu: Node3D = app.photo_menu
	var control := button(menu, target)
	check(not control.is_empty() and control.enabled, "PDF menu target available: %d" % target)
	if control.is_empty() or not control.enabled: return
	var origin: Vector3 = control.node.to_global(Vector3(0, 0, 1))
	app.test_rays = {"right_hand": [origin, -menu.global_basis.z]}
	app._on_pointer_button("trigger_click", "right_hand")
	app._on_pointer_release("trigger_click", "right_hand")
	app.test_rays.clear()

func idle(app: Node3D) -> void:
	var until := Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < until:
		app._process(.02)
		await create_timer(.02).timeout

func run() -> void:
	folder = "res://../../build/output/pdf-layout-menu"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	Log.path = folder.path_join("events.jsonl"); Log.rotated_path = folder.path_join("events.1.jsonl")
	var app := InputApp.new(); app.settings_path = folder.path_join("settings.cfg")
	var config := ConfigFile.new(); config.set_value("appearance", "background", "dark"); config.save(app.settings_path)
	root.add_child(app); app.set_process(false)
	I18n.use("en"); await process_frame
	app.photo.auto_depth = false
	var host := PdfHost.new(); app.photo.platform = host; app.recent_menu.platform = host
	host.photo_ready.connect(app.photo._on_ready)
	for i in 8:
		var source := Image.create(100, 200, false, Image.FORMAT_RGB8)
		source.fill(Color.RED if i % 2 == 0 else Color.BLUE)
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % i)); source.save_png(path)
		host.paths.append(path)
	var library: Node3D = app.recent_menu
	library.section = library.Section.LOCAL
	library._local_entries = [{"title": "book.PDF", "uri": "file:///book.PDF", "kind": "pdf"}]
	library.refresh(); library._choose(library.rows[0])
	await process_frame; await process_frame; library.archives.tick()
	check(library.archives.browsing and library.rows.size() == 8, "Main opens the PDF browser")
	library._choose(library.rows[0]); await settle(app.photo)
	check(app.photo_active and app.photo.archive_mode and app.photo.gallery.mode == 0, "Library selection opens PDF in the saved single mode")
	app.photo_menu.action_requested.connect(func(action): actions.append(action))
	for direction in [false, true]:
		app.photo.magazine.right_to_left = direction
		app.photo_menu.refresh()
		routed_tap(app, Menu.PHOTO_LAYOUT); routed_tap(app, Menu.PHOTO_LAYOUT_BASE + 4)
		await settle(app.photo)
		check(app.photo.gallery.mode == 4 and app.photo_menu._magazine_order_open, "First click enters Magazine before optional direction choice")
		var pixel: Color = app.photo._texture.get_image().get_pixel(30, 100)
		check((pixel.b > .9 if direction else pixel.r > .9), "Immediate spread uses remembered reading direction")
		app._toggle_player_menu(); app._show_player_menu()
		check(app.photo.gallery.mode == 4 and app.photo_menu._state.layout == 4, "Dismiss and reopen without choosing a direction retains Magazine")
		app._toggle_player_menu()
		for step in [1, 1, 1, -1, -1, -1]:
			check(app.photo.navigate(step), "PDF spread navigation succeeds")
			await settle(app.photo); await idle(app)
			check(app.photo.gallery.mode == 4 and app.photo._size == Vector2(200, 200), "Navigation and idle prefetch retain a real two-page spread")
			check(host.window.keep.size() >= 4 and host.window.keep.size() <= 6, "Native reading cache window follows adjacent spreads")
		app._show_player_menu()
		check(app.photo_menu._state.layout == 4, "Menu still reports Magazine after multiple spreads")
		config.load(app.settings_path)
		check(config.get_value("photo_screen", "reading_layout") == 4, "Idle settings save retains PDF Magazine preference")
		# Selecting another page through the still-open document browser closes/reopens the reader.
		library.show(); library.refresh(); library._choose(library.rows[0]); await settle(app.photo)
		check(app.photo.gallery.mode == 4 and app.photo._size == Vector2(200, 200), "PDF page selection through library preserves the independent reading layout")
		routed_tap(app, Menu.PHOTO_LAYOUT); routed_tap(app, Menu.PHOTO_LAYOUT_BASE); await settle(app.photo)
		check(app.photo.gallery.mode == 0, "Explicit Single selection still works")
	check(actions.count("photo_layout_4") == 2 and actions.count("photo_layout_0") == 2, "Each ray selection dispatches exactly one layout action")
	library.archives.close(); app.free(); await process_frame; await process_frame
	check(host.refs.is_empty(), "All native PDF session references are released")
	print("PDF layout menu: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
