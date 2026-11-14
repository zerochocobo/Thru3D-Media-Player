extends SceneTree
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
const Depth := preload("res://scripts/playback_menu_depth.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")

# Aim the visible end of the existing controller beam at the displayed button.
# At zero disparity, both eyes see the button in this centre-eye direction.
static func aim(menu: Node3D, head: Vector3, hand: Vector3, point: Vector3) -> Vector3:
	var direction := (point-head).normalized()
	var offset := head-hand
	var along := offset.dot(direction)
	var distance := -along + sqrt(along*along + menu.ray_max_distance*menu.ray_max_distance-offset.length_squared())
	return (head+direction*distance-hand).normalized()

func run() -> void:
	var path := "user://mono_pointer_%d.cfg" % Time.get_ticks_usec()
	var settings := ConfigFile.new(); settings.set_value("appearance", "background", "dark"); settings.save(path)
	var main := InputMain.new(); main.settings_path = path; root.add_child(main); main.set_process(false)
	main.xr_camera.global_transform = main.head_pose
	main.video.local_uri = "file:///pointer-fixture.mp4"; main.video.media.begin(1); main.video.media.state = "playing"
	main.video.geometry = 1
	main.video.control.observe(120000,600000)
	main._show_player_menu(); main._on_setting_changed(Depth.KEY, Depth.MONO)
	var menu: Node3D = main.video_menu
	var initial_head: Transform3D = main.head_pose
	for motion in [Transform3D.IDENTITY,Transform3D(Basis(Vector3.UP,0.25),Vector3(0.12,0.08,0.1))]:
		main.head_pose = initial_head * motion; main.xr_camera.global_transform = main.head_pose
		for section in [0,1]:
			menu.section = section; menu.refresh(); main.mono_menu_capture.update()
			for target in ([107,100,108,102] if section == 0 else [menu.SETTINGS_CLOSE]):
				var buttons: Array = menu._buttons.filter(func(button): return button.target == target)
				if buttons.is_empty(): check(false,"Visible close/control exists"); continue
				var point: Vector3 = buttons[0].node.global_position
				for side in [-1,1]:
					var hand := "left_hand" if side < 0 else "right_hand"
					var origin: Vector3 = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
					var direction := aim(menu,main.head_pose.origin,origin,point)
					menu.update_pointer(hand,origin,direction,true)
					check(menu._hover.get(hand) == target,"Visible mono beam endpoint hits %d with %s after head motion" % [target,hand])
					var hit: Dictionary = menu.ray_hit(origin,direction)
					check(hit.get("target") == target,"Trigger hit agrees with rendered pointer for %d/%s" % [target,hand])
					var pointer: Dictionary = menu._pointers[hand]
					var vertices: PackedVector3Array = pointer.line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
					var line_tip: Vector3 = pointer.line.to_global(vertices[1])
					check(pointer.line.to_global(vertices[0]).is_equal_approx(origin),"Mono ray starts at the tracked hand")
					var weights: PackedColorArray = pointer.line.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
					check(weights[0].a==0.0 and weights[1].a==1.0,"Full mono ray keeps the hand and reticle stereo projection weights")
					check(line_tip.is_equal_approx(pointer.dot.global_position),"Mono line ends at the dot centre for %d/%s" % [target,hand])
					check((pointer.dot.global_position-main.head_pose.origin).normalized().is_equal_approx((menu.to_global(hit.point)-main.head_pose.origin).normalized()),"Reticle keeps the hit's exact centre-eye direction")
	for side in [-1,1]:
		menu.section = 1; menu.refresh(); main.mono_menu_capture.update()
		var close: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SETTINGS_CLOSE)[0]
		var hand := "left_hand" if side < 0 else "right_hand"
		var origin: Vector3 = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
		main.rays[hand] = [origin,aim(menu,main.head_pose.origin,origin,close.node.global_position)]
		main._on_controller_button("trigger_click",hand); main._on_controller_release("trigger_click",hand)
		check(menu.section == 0 and menu.visible,"Visible popup close returns to transport with " + hand)
	# Capture and drag must use the same ray projection as hover and trigger hits.
	menu.section = 0; menu.refresh(); main.mono_menu_capture.update()
	var start: Vector3 = main.head_pose * Vector3(0.25,-0.2,-0.3)
	var timeline: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SEEK)[0]
	var centre: Vector3 = timeline.node.global_position
	var direction := aim(menu,main.head_pose.origin,start,centre)
	menu.press_pointer("right_hand",start,direction,true)
	check(menu.has_pointer_capture(),"Visible timeline starts pointer capture")
	var expected: Vector3 = menu._input_point(menu.ray_hit(start,direction))
	var projected: Variant = menu._plane_point(start,direction,menu.SEEK)
	check(projected != null and absf(projected.x-expected.x) < 0.002,"Captured slider projection agrees with initial hit")
	menu.update_pointer("right_hand",start,aim(menu,main.head_pose.origin,start,centre+menu.global_basis.x*0.15),true)
	check(menu._seek_preview > menu._seek_start,"Mono drag moves the seek preview along the visible timeline")
	var drag_pointer: Dictionary = menu._pointers.right_hand
	var drag_vertices: PackedVector3Array = drag_pointer.line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(drag_pointer.line.to_global(drag_vertices[1]).is_equal_approx(drag_pointer.dot.global_position),"Seeking keeps the line joined to the reticle")
	menu.cancel_pointer("right_hand")
	# Attached browser uses the projection of its captured parent.
	main._show_recent_menu()
	main.mono_menu_capture.update()
	var browser: Node3D = main.recent_menu
	var browser_close: Dictionary = browser._buttons.filter(func(button): return button.target == browser.CLOSE)[0]
	direction = aim(menu,main.head_pose.origin,start,browser_close.node.global_position)
	check(browser.ray_hit(start,direction).get("target") == browser.CLOSE,"Attached browser close inherits the mono cursor")
	browser.update_pointer("right_hand",start,direction,true)
	var browser_pointer: Dictionary = browser._pointers.right_hand
	var browser_vertices: PackedVector3Array = browser_pointer.line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(browser_pointer.line.to_global(browser_vertices[1]).is_equal_approx(browser_pointer.dot.global_position),"Attached browser also joins its mono line to its dot")
	main.rays.right_hand = [start,direction]
	main._on_controller_button("trigger_click","right_hand"); main._on_controller_release("trigger_click","right_hand")
	check(not browser.visible and menu.visible,"Closing the attached browser through its visible button keeps the transport open")
	check_library_gestures(main)
	check_popup_gestures(main.xr_camera)
	check_library_auxiliary(main.xr_camera)
	main._on_setting_changed(Depth.KEY,Depth.DEFAULT)
	check(not menu.has_meta("menu_mono_pointer"),"Changing depth restores ordinary picking immediately")
	for mode in [Depth.DEFAULT,Depth.MEDIUM]:
		main._on_setting_changed(Depth.KEY,mode)
		var finite_close: Dictionary = menu._buttons.filter(func(button): return button.target == 107)[0]
		direction = finite_close.node.global_position-start
		menu.update_pointer("right_hand",start,direction,true)
		var finite_hit: Dictionary = menu.ray_hit(start,direction)
		var finite_pointer: Dictionary = menu._pointers.right_hand
		var finite_vertices: PackedVector3Array = finite_pointer.line.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		check(finite_vertices[1].is_equal_approx(Vector3(finite_hit.point)+Vector3(0,0,0.006)),"Finite-depth line keeps its existing surface bias")
		check(finite_pointer.dot.position.is_equal_approx(Vector3(finite_hit.point)+Vector3(0,0,0.008)),"Finite-depth dot keeps its existing surface bias")
	# Both hands close media through the production controller route.
	for side in [-1,1]:
		main.video.local_uri = "file:///pointer-fixture.mp4"; main.video.media.begin(2); main.video.media.state = "playing"
		main.video.geometry = 1
		main._show_player_menu(); main._on_setting_changed(Depth.KEY,Depth.MONO); main.mono_menu_capture.update()
		var close: Dictionary = menu._buttons.filter(func(button): return button.target == 107)[0]
		var hand := "left_hand" if side < 0 else "right_hand"
		start = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
		main.rays[hand] = [start,aim(menu,main.head_pose.origin,start,close.node.global_position)]
		main._on_controller_button("trigger_click",hand); main._on_controller_release("trigger_click",hand)
		check(main.video.media.state == "closed" and not menu.visible and main.recent_menu.visible,"Mono close button closes media and returns to library with " + hand)
		main.mono_menu_capture.update()
		check(not menu.has_meta("menu_mono_pointer"),"Closing removes the mono projection")
	# The independent library retains its finite hand-origin ray.
	var library_button: Dictionary = main.recent_menu._buttons.filter(func(button): return button.enabled and button.node.is_visible_in_tree())[0]
	check(main.recent_menu.ray_hit(start,library_button.node.global_position-start).get("target") == library_button.target,"Independent library restores ordinary controller picking")
	# A stored mono preference must not leak onto the separate picture controls.
	main.photo_active = true; main.player_menu = main.photo_menu
	main.photo.local_uri = "file:///pointer-photo.jpg"
	main.photo_menu.state_provider = func(): return {"has_image":true,"geometry":0,"count":1,"index":0}
	main._show_player_menu(); main.mono_menu_capture.update()
	var picture: Node3D = main.photo_menu
	var picture_close: Dictionary = picture._buttons.filter(func(button): return button.target == 107)[0]
	direction = picture_close.node.global_position-start
	check(not picture.has_meta("menu_mono_pointer") and picture.ray_hit(start,direction).get("target") == 107,"Picture close keeps ordinary picking after leaving mono video")
	main.rays.right_hand = [start,direction]
	main._on_controller_button("trigger_click","right_hand"); main._on_controller_release("trigger_click","right_hand")
	check(main.photo.local_uri.is_empty() and not picture.visible,"Picture close action still closes its image")
	menu.dismiss(); main.queue_free(); await process_frame
	DirAccess.remove_absolute(path)
	for failure in failures: push_error(failure)
	print("Mono menu pointer: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_library_gestures(main: Node3D) -> void:
	var library: Node3D = main.recent_menu
	var menu: Node3D = main.video_menu
	var selected: Array[String] = []
	var record := func(uri: String, _title: String): selected.append(uri)
	library.chosen.disconnect(main._on_library_chosen)
	library.chosen.connect(record)
	library.platform = null
	library.section = library.Section.LOCAL
	library._local_stack = [{"id": "/pointer", "title": "Pointer"}]
	library._local_entries.clear()
	for i in 90:
		library._local_entries.append({"uri": "file:///pointer/%03d.mp4" % i, "title": "%03d.mp4" % i})
	library.refresh()
	library.remember_playback_context()
	for mode in [Depth.MONO, Depth.DEFAULT, Depth.MEDIUM]:
		main._on_setting_changed(Depth.KEY, mode)
		main._show_recent_menu()
		for compact in [true, false]:
			if library.compact != compact: main._toggle_library_layout()
			for view in ["list", "grid"]:
				library.set_view_mode(view)
				for side in [-1, 1]:
					var hand := "left_hand" if side < 0 else "right_hand"
					var other := "right_hand" if side < 0 else "left_hand"
					var label := "%s/%s/%s/%s" % [mode, compact, view, hand]
					library.visible = true
					library._set_scroll(6.25)
					main.mono_menu_capture.update()
					var visible_rows: Array = library._buttons.filter(func(button): return library._row_target(button.target) and button.node.is_visible_in_tree())
					check(not visible_rows.is_empty(), "Playback folder has visible files: " + label)
					if visible_rows.is_empty(): continue
					var row: Dictionary = visible_rows[0]
					var uri: String = library.rows[library._row_index(row.target - library.ROW_BASE)].uri
					var centre: Vector3 = row.node.global_position
					var origin: Vector3 = main.head_pose * Vector3(side * 0.25, -0.2, -0.3)
					var direction := aim(menu, main.head_pose.origin, origin, centre) if mode == Depth.MONO else (centre - origin).normalized()
					main.rays[hand] = [origin, direction]
					var before := selected.size()
					main._on_controller_button("trigger_click", hand)
					check(library.has_pointer_capture() and selected.size() == before, "Row waits for release: " + label)
					for frame in 3: main._update_menu_pointer(hand)
					check(is_equal_approx(library.scroll, 6.25) and not library._drag.get("moved", true), "Stationary held trigger keeps a scrolled row: " + label)
					var jitter: Vector3 = centre + library.global_basis.y * 0.018
					main.rays[hand] = [origin, aim(menu, main.head_pose.origin, origin, jitter) if mode == Depth.MONO else (jitter - origin).normalized()]
					main._update_menu_pointer(hand)
					check(is_equal_approx(library.scroll, 6.25), "Small pointer motion remains a tap: " + label)
					main._on_controller_release("trigger_click", hand)
					check(selected.size() == before + 1 and selected.back() == uri, "Tap selects the originally visible file once: " + label)
					library.visible = true
					main.rays[hand] = [origin, direction]
					main._on_controller_button("trigger_click", hand)
					var end: Vector3 = centre + library.global_basis.y * library._pitch() * 2.0
					var drag_direction := aim(menu, main.head_pose.origin, origin, end) if mode == Depth.MONO else (end - origin).normalized()
					menu.update_pointer(other, origin, drag_direction, true)
					menu.release_pointer(other, origin, drag_direction, true)
					check(library.has_pointer_capture() and is_equal_approx(library.scroll, 6.25), "Other hand cannot move or release the row: " + label)
					main.rays[hand] = [origin, drag_direction]
					main._update_menu_pointer(hand)
					check(absf(library.scroll - 8.25) < 0.01, "Deliberate two-row drag follows the visible ray: " + label)
					main._on_controller_release("trigger_click", hand)
					check(selected.size() == before + 1, "Drag does not select a file: " + label)
					library._fling = 0.0
					var bar: Dictionary = library._buttons.filter(func(button): return button.target == library.SCROLLBAR)[0]
					var bar_point: Vector3 = bar.node.global_position
					var bar_direction := aim(menu, main.head_pose.origin, origin, bar_point) if mode == Depth.MONO else (bar_point - origin).normalized()
					menu.press_pointer(hand, origin, bar_direction, true)
					var bar_scroll: float = library.scroll
					menu.update_pointer(hand, origin, bar_direction, true)
					check(is_equal_approx(library.scroll, bar_scroll), "Held scrollbar stays at its press position: " + label)
					menu.update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
					check(not library.has_pointer_capture(), "Tracking loss cancels the scrollbar: " + label)
					menu.release_pointer(hand, origin, bar_direction, true)
					if compact and view == "grid":
						library._set_scroll(6.0)
						var gap: Vector3 = library.to_global(Vector3(0.17, 0.13, 0))
						var gap_ray := aim(menu, main.head_pose.origin, origin, gap) if mode == Depth.MONO else (gap - origin).normalized()
						menu.press_pointer(hand, origin, gap_ray, true)
						menu.update_pointer(hand, origin, gap_ray, true)
						check(library.has_pointer_capture() and is_equal_approx(library.scroll, 6.0), "Grid gap captures without moving: " + label)
						gap += library.global_basis.y * library._pitch()
						gap_ray = aim(menu, main.head_pose.origin, origin, gap) if mode == Depth.MONO else (gap - origin).normalized()
						menu.update_pointer(hand, origin, gap_ray, true)
						menu.release_pointer(hand, origin, gap_ray, true)
						check(absf(library.scroll - 7.0) < 0.01 and selected.size() == before + 1, "Grid gap drag scrolls one row without selecting: " + label)
						library._fling = 0.0
			library.dismiss()
	library.chosen.disconnect(record)
	library.chosen.connect(main._on_library_chosen)

func check_popup_gestures(eye: Camera3D) -> void:
	var menu := preload("res://scripts/player_menu.gd").new()
	var state := {"has_video": true, "geometry": 1, "source_uri": "file:///popup.mp4", "duration_ms": 600000,
		"audio_options": [], "subtitle_options": [], "bookmarks": [], "bookmark_scope": "popup", "bookmark_ready": true, "bookmark_seekable": true}
	for i in 12:
		state.audio_options.append({"value": i + 1, "label": "Audio %d" % i})
		state.subtitle_options.append({"id": i + 1, "title": "Subtitle %d" % i, "codec": "subrip"})
		state.bookmarks.append({"id": str(i), "position_ms": i * 10000})
	menu.state_provider = func(): return state
	root.add_child(menu)
	menu.set_process(false)
	menu.global_transform = Transform3D(Basis.from_euler(Vector3(-0.15, 0.2, 0.05)), eye.global_position + Vector3(0, -0.4, -1.4))
	menu.set_layout_viewer(eye.global_transform, false)
	menu.set_meta("menu_mono_pointer", {"eye": eye, "distance": menu.ray_max_distance})
	var selected: Array = []
	menu.setting_requested.connect(func(key, value): selected.append([key, value]))
	menu.subtitle_requested.connect(func(id): selected.append(id))
	menu.bookmark_requested.connect(func(operation, id, _scope): selected.append([operation, id]))
	for kind in ["audio", "subtitle", "bookmark"]:
		for side in [-1, 1]:
			menu._reset_navigation()
			menu.visible = true
			menu._audio_open = kind == "audio"
			menu._audio_source = state.source_uri
			menu._subtitle_open = kind == "subtitle"
			menu.bookmarks.opened = kind == "bookmark"
			menu._audio_offset = 3
			menu._subtitle_offset = 3
			menu.bookmarks.offset = 3
			menu.refresh()
			var offsets := Vector3i(menu._audio_offset, menu._subtitle_offset, menu.bookmarks.offset)
			var target: int = menu._audio_ids.keys()[0] if kind == "audio" else (menu._subtitle_ids.keys()[0] if kind == "subtitle" else menu.BookmarkMenu.ROW)
			var row: Dictionary = menu._buttons.filter(func(button): return button.target == target)[0]
			var origin: Vector3 = eye.global_transform * Vector3(side * 0.25, -0.2, -0.3)
			var direction := aim(menu, eye.global_position, origin, row.node.global_position)
			var hand := "left_hand" if side < 0 else "right_hand"
			var before := selected.size()
			menu.press_pointer(hand, origin, direction, true)
			menu.update_pointer(hand, origin, direction, true)
			check(menu.has_pointer_capture() and not menu._track_drag.get("moved", false) and not menu.bookmarks.capture.get("moved", false), "Static mono popup row remains a click: " + kind)
			check(Vector3i(menu._audio_offset, menu._subtitle_offset, menu.bookmarks.offset) == offsets, "Static mono popup preserves list offsets: " + kind)
			menu.release_pointer(hand, origin, direction, true)
			check(selected.size() == before + 1, "Mono popup row selects once: " + kind)
			row = menu._buttons.filter(func(button): return button.target == target)[0]
			direction = aim(menu, eye.global_position, origin, row.node.global_position)
			menu.press_pointer(hand, origin, direction, true)
			var end: Vector3 = row.node.global_position + row.node.global_basis.y * 0.15
			direction = aim(menu, eye.global_position, origin, end)
			menu.update_pointer(hand, origin, direction, true)
			menu.release_pointer(hand, origin, direction, true)
			var offset: int = menu._audio_offset if kind == "audio" else (menu._subtitle_offset if kind == "subtitle" else menu.bookmarks.offset)
			check(offset > 3 and selected.size() == before + 1, "Mono popup drag scrolls without selecting: " + kind)
	menu._reset_navigation()
	menu._subtitle_open = true
	menu._subtitle_appearance_open = true
	menu.refresh()
	check(not menu.choices.sliders.is_empty(), "Mono subtitle appearance exposes its sliders")
	for target in menu.choices.sliders.keys():
		var slider: Dictionary = menu.choices.sliders[target]
		var origin: Vector3 = eye.global_transform * Vector3(0.25, -0.2, -0.3)
		var point: Vector3 = slider.node.to_global(Vector3(slider.left + slider.width * 0.5, 0, 0))
		var direction := aim(menu, eye.global_position, origin, point)
		menu.press_pointer("right_hand", origin, direction, true)
		var value: Variant = menu.choices.capture.get("value")
		menu.update_pointer("right_hand", origin, direction, true)
		check(value != null and menu.choices.same(value, menu.choices.capture.get("value")), "Static mono subtitle slider keeps its value: " + str(target))
		point = slider.node.to_global(Vector3(slider.left + slider.width, 0, 0))
		direction = aim(menu, eye.global_position, origin, point)
		menu.update_pointer("right_hand", origin, direction, true)
		check(is_equal_approx(float(menu.choices.capture.get("value", NAN)), slider.span.y), "Mono subtitle slider reaches the visible end: " + str(target))
		menu.release_pointer("right_hand", origin, direction, true)
	menu._reset_navigation()
	state.audio_available = true
	menu._volume_open = true
	menu.refresh()
	var volume: Dictionary = menu._buttons.filter(func(button): return button.target == menu.VOLUME)[0]
	var origin: Vector3 = eye.global_transform * Vector3(-0.25, -0.2, -0.3)
	var direction := aim(menu, eye.global_position, origin, volume.node.global_position)
	menu.press_pointer("left_hand", origin, direction, true)
	var level: float = menu._volume_sent
	menu.update_pointer("left_hand", origin, direction, true)
	check(menu.has_pointer_capture() and is_equal_approx(menu._volume_sent, level), "Static mono volume rail keeps the pressed value")
	direction = aim(menu, eye.global_position, origin, volume.node.global_position + volume.node.global_basis.y * 0.05)
	menu.update_pointer("left_hand", origin, direction, true)
	check(menu._volume_sent > level, "Mono volume drag follows the visible rail")
	menu.release_pointer("left_hand", origin, direction, true)
	menu.free()

func check_library_auxiliary(eye: Camera3D) -> void:
	var library := preload("res://scripts/library_menu.gd").new()
	root.add_child(library)
	library.set_process(false)
	library.global_position = eye.global_position + Vector3(0, 0.15, -1.5)
	library.visible = true
	library.set_meta("menu_mono_pointer", {"eye": eye, "distance": library.ray_max_distance})
	library.section = library.Section.MEDIA_SERVER
	var browser: RefCounted = library.server_browser
	browser.server = {"id": "pointer", "name": "Pointer", "provider": "plex"}
	browser.view = "home"
	browser.capabilities = {"home_layout": "libraries"}
	browser.home_data = {"libraries": []}
	for i in 8: browser.home_data.libraries.append({"id": str(i), "title": "Library %d" % i, "has_cover": false})
	library.refresh()
	var origin: Vector3 = eye.global_transform * Vector3(0.25, -0.2, -0.3)
	var row: Dictionary = library._buttons.filter(func(button): return button.target == browser.gallery.LIBRARY)[0]
	var centre: Vector3 = row.node.global_position
	var direction := aim(library, eye.global_position, origin, centre)
	library.press_pointer("right_hand", origin, direction, true)
	check(browser.gallery.capture.get("strip") == "libraries", "Mono server card captures its visible carousel")
	library.update_pointer("right_hand", origin, direction, true)
	check(not browser.gallery.capture.get("moved", true) and browser.gallery.library_start == 0, "Static mono server card keeps its carousel position")
	direction = aim(library, eye.global_position, origin, centre - library.global_basis.x * 0.31)
	library.update_pointer("right_hand", origin, direction, true)
	library.release_pointer("right_hand", origin, direction, true)
	check(browser.gallery.library_start == 1 and browser.view == "home", "Mono server carousel drag advances without opening a library")
	library.section = library.Section.SETTINGS
	library.tab = library.GENERAL_TAB
	library.refresh()
	var target: int = library.choices.targets.keys().filter(func(id): return library.choices.targets[id].get("key") == "language" and library.choices.targets[id].get("kind") == "open")[0]
	row = library._buttons.filter(func(button): return button.target == target)[0]
	direction = aim(library, eye.global_position, origin, row.node.global_position)
	library.press_pointer("right_hand", origin, direction, true)
	library.update_pointer("right_hand", origin, direction, true)
	check(not library.choices.capture.get("moved", true), "Static mono dropdown remains a click")
	library.release_pointer("right_hand", origin, direction, true)
	check(library.choices.opened == "language", "Mono dropdown opens on release")
	var selected: Array = []
	library.setting_changed.connect(func(key, value): selected.append([key, value]))
	target = library.choices.targets.keys().filter(func(id): return library.choices.targets[id].get("key") == "language" and library.choices.targets[id].get("kind") == "choose")[0]
	row = library._buttons.filter(func(button): return button.target == target)[0]
	direction = aim(library, eye.global_position, origin, row.node.global_position)
	library.press_pointer("right_hand", origin, direction, true)
	library.update_pointer("right_hand", origin, direction, true)
	library.release_pointer("right_hand", origin, direction, true)
	check(selected.size() == 1 and library.choices.opened.is_empty(), "Mono dropdown chooses once and closes")
	library.free()
