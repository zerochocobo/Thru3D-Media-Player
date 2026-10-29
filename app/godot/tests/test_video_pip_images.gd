extends SceneTree
const Core := preload("res://tests/test_video_pip.gd")
const Surface := preload("res://tests/test_video_pip_compositor.gd").Surface
const Library := preload("res://scripts/puzzle/puzzle_library_menu.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	signal pip_image_ready(id: int, payload: String)
	var serial := 0
	var released: Array = []
	var cancelled: Array = []
	var uris: Array = []
	func open_pip_image(uri: String) -> int: serial += 1; uris.append(uri); return serial
	func cancel_pip_image(id: int) -> void: cancelled.append(id)
	func release_pip_image(id: int) -> void: released.append(id)
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func ray_to(window: Node3D, point: Vector2) -> Array:
	return [window.to_global(Vector3(point.x,point.y,0.8)), -window.global_basis.z]
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var video := Surface.new(); var host := Host.new(); video.platform = host; root.add_child(video)
	var pip: RefCounted = video.pip
	var head := Transform3D(Basis.IDENTITY, Vector3(0,1.5,0))
	pip.set_count(3, head)
	var window: Node3D = pip.windows[1]
	window.set_aspect(2); window.zoom = 4; window.crop_center = Vector2(0.3,0.7)
	window.controls = true; window.refresh()
	var size: Vector2 = window.size; var pose: Transform3D = window.global_transform
	var mode_position: Vector2 = window._buttons.filter(func(b): return b.target == 5)[0].rect.get_center()
	var image := Image.create(320, 640, false, Image.FORMAT_RGBA8); image.fill(Color(0.9,0.2,0.1))
	var path := ProjectSettings.globalize_path("res://../../build/output/video-pip/image-fixture.png")
	image.save_png(path)
	pip.load_image(window, "cloud://account/reference.png"); await create_timer(0.05).timeout
	check(window.image_loading and not window.image_mode and host.uris.size() == 1, "Loading retains the original video until the picture is ready")
	host.pip_image_ready.emit(host.serial, JSON.stringify({"state":"ready", "path":path, "orientation":6}))
	for i in 100:
		await create_timer(0.01).timeout
		if not window.image_loading: break
	check(window.image_mode and window.size == Vector2(0.48,0.24), "EXIF orientation and full-image aspect are honored")
	check(window.global_transform == pose and window.zoom == 4, "Image replacement preserves position and video zoom")
	check(not host.released.has(1) and window.capture_image == {"id":1,"orientation":6}, "Displayed image retains its local preview for asynchronous screenshots")
	window.controls = true; window.refresh()
	check(window._buttons.all(func(b): return b.target in [1,5,6]), "Image controls contain only close, choose image, and return to video")
	check(is_equal_approx(window._buttons.filter(func(b): return b.target == 6)[0].rect.get_center().x, mode_position.x), "The mode switch retains its horizontal position after selecting an image")
	check(window._tips[6] == window.I18n.t("Switch to video mode") and window._tips[5] == window.I18n.t("Replace image"), "Mode switching and replacing an image have distinct labels")
	var still_size: Vector2 = window.size
	window.set_aspect(4); pip._action(1,"zoom",8); pip._action(1,"select",0)
	check(window.size == still_size and window.zoom == 4 and pip.selecting == 0, "Image mode rejects aspect presets, content zoom, and crop actions")
	for dimensions in [Vector2i(640,320),Vector2i(320,640)]:
		var texture := ImageTexture.create_from_image(Image.create(dimensions.x,dimensions.y,false,Image.FORMAT_RGBA8))
		for corner in [3]:
			for requested_scale in [0.05,1.6,10.0]:
				window.show_image(texture); window.global_transform = pose
				var before: Vector2 = window.size
				var point: Vector2 = window.corner_point(corner)
				var anchor: Vector3 = window.to_global(Vector3(-point.x,-point.y,0))
				check(pip.press("right_hand","trigger_click",ray_to(window,point),null,head) and not pip.resize.is_empty(), "The bottom-right image corner captures the trigger")
				var drag := ray_to(window,point + 2 * point * (requested_scale - 1))
				pip.update_input({"right_hand":drag},{},head,1000)
				check(is_equal_approx(window.size.x / window.size.y, before.x / before.y) and maxf(window.size.x,window.size.y) >= 0.2199 and maxf(window.size.x,window.size.y) <= 1.2001, "Portrait and landscape corner resizing preserve aspect and bound the long edge")
				var opposite: Vector2 = -window.corner_point(corner)
				check(window.to_global(Vector3(opposite.x,opposite.y,0)).distance_to(anchor) < 0.0001, "The opposite corner stays fixed during image resizing")
				pip.release("right_hand","trigger_click")
		for edge in 4:
			check(window.window_hit.callv(ray_to(window,window.edge_point(edge))).get("edge",-1) == -1, "Images never expose free-aspect edge targets")
		for corner in [0, 1, 2]:
			check(window.window_hit.callv(ray_to(window,window.corner_point(corner))).get("corner",-1) == -1, "Removed image corners have no resize target")
	var ray := ray_to(window,Vector2.ZERO)
	check(pip.press("right_hand","grip_click",ray,head,head), "Image frames can still be moved")
	pip.release("right_hand","grip_click")
	pip.sync(); pip.compositor.commit(true)
	check(not window.on_compositor and window.frame.material_override == window.image_material and pip.video_windows().size() == 2, "Static images remain visible and are excluded from video sampling")
	window._activate(6)
	check(host.released.count(1) == 1 and window.capture_image.is_empty(), "Switching back to video releases the displayed image lease once")
	check(not window.image_mode and window.size == size and window.zoom == 4 and window.crop_center == Vector2(0.3,0.7), "The explicit video button restores the exact previous crop, zoom, and size")
	pip.load_image(window,"smb://saved/reference.png"); await create_timer(0.05).timeout
	var stale := host.serial
	pip.close(1); pip.toggle_slot(1,head); await create_timer(0.05).timeout
	host.pip_image_ready.emit(stale,JSON.stringify({"state":"ready","path":path}))
	await process_frame
	check(host.cancelled.has(stale) and not pip.windows[1].image_mode, "A late load cannot replace a newly reused slot")
	window = pip.windows[1]
	pip.load_image(window,"file:///missing.png"); await create_timer(0.05).timeout
	host.pip_image_ready.emit(host.serial,'{"state":"error"}')
	check(window.image_error and not window.image_mode and not window.image_loading, "A failed load keeps the video usable with retry feedback")
	window.show_image(ImageTexture.create_from_image(image)); window._activate(1)
	check(not pip.windows.has(1), "X closes the entire window in image mode, exactly as in video mode")
	var library := Library.new(); root.add_child(library); library.set_process(false)
	var puzzles: Array = []
	library.puzzle_requested.connect(func(): puzzles.append(true))
	library.puzzle_progress_provider = func(): return true
	library.media_filter = 2; library.refresh()
	check(library._buttons.any(func(b):return b.target==Library.PUZZLE_OPEN), "Normal image browsing retains its puzzle shortcut")
	library._activate(Library.PUZZLE_OPEN)
	check(puzzles.size()==1, "Normal image browsing can still open puzzle mode")
	library.section = Library.Section.LOCAL; library._local_stack = [{"id":"/original","title":"Original"}]
	var selected: Array = []; var opened: Array = []; var cancellations: Array = []
	library.image_selected.connect(func(uri,title):selected.append([uri,title]))
	library.chosen.connect(func(uri,title):opened.append([uri,title]))
	library.image_picker_cancelled.connect(func():cancellations.append(true))
	for source in [Library.Section.LOCAL,Library.Section.SMB,Library.Section.DLNA,Library.Section.CLOUD]:
		library.visible = true; library.begin_image_picker(); library.section = source
		library._smb_server = "saved"; library._dlna_server = "saved"; library._cloud_stack = [{"id":"/saved","title":"Saved"}]
		var entries: Array = [{"title":"folder","id":"child","container":true}, {"title":"reference.png","uri":"https://fixture/image","kind":"image"}, {"title":"movie.mp4","uri":"https://fixture/video","kind":"video"}]
		library._local_entries = entries; library._smb_entries = entries; library._dlna_entries = entries; library._cloud_entries = entries
		library.refresh()
		check(not library._buttons.any(func(b):return b.target==Library.PUZZLE_OPEN), "Image picker hides puzzle even with unfinished progress for source %d" % source)
		library._activate(Library.PUZZLE_OPEN)
		check(puzzles.size()==1 and library.image_picker_mode, "A stale puzzle action cannot leave the image picker")
		check(library.media_filter == 2 and library.rows.any(func(row):return row.get("kind","")=="image") and not library.rows.any(func(row):return row.get("kind","")=="video"), "Picker retains only images and folders for source %d" % source)
		check(library._buttons.any(func(b):return b.target==Library.NAV_BASE+Library.Section.DLNA), "DLNA remains available in the image picker")
		library._choose(library.rows.filter(func(row):return row.get("kind","")=="image")[0])
		check(not library.image_picker_mode and library.section == Library.Section.LOCAL and library._local_stack[0].id == "/original", "Selection restores the original browser context")
	check(selected.size()==4 and opened.is_empty(), "Every source selects into the frame without opening the main photo player")
	for source in [Library.Section.LOCAL,Library.Section.SMB,Library.Section.DLNA,Library.Section.CLOUD]:
		library.visible=true; library.begin_image_picker(); library.section=source; library.refresh()
		var close: Dictionary = library._buttons.filter(func(b):return b.target==Library.CLOSE)[0]
		check(close.rect.get_center().y < -0.6 and close.rect.size.x >= 0.30, "Every image source has an accessible bottom close button")
		var origin: Vector3 = close.node.to_global(Vector3(0,0,0.5))
		var direction: Vector3 = -close.node.global_basis.z
		library.press_pointer("right_hand",origin,direction,true); library.release_pointer("right_hand",origin,direction,true)
		check(not library.image_picker_mode and not library.visible and library._local_stack[0].id == "/original", "Triggering footer Close cancels the picker and restores browser context")
	check(cancellations.size()==4 and selected.size()==4, "Closing never selects a replacement image")
	pip.clear(); video.queue_free(); library.queue_free(); await create_timer(0.05).timeout
	for failure in failures: push_error(failure)
	print("Video PiP images: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
