extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Host := preload("res://tests/test_player_menu.gd").Host
var checks := 0
var failures: Array[String] = []

class Harness extends "res://scripts/main.gd":
	var rays := {}
	var move_pose := Transform3D.IDENTITY
	func _ready() -> void: set_process(false)
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _head_pose() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	func _move_pose(_hand: String) -> Variant: return move_pose

class Platform extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 0
	func media_local_browse(path: String) -> int:
		sequence += 1
		var id := sequence
		var entries: Array = [{"uri": "file:///child/a.mp4", "title": "Child video.mp4"}] if path != "/disk" else files()
		(func(): media_list.emit(id, JSON.stringify({"state": "ready", "path": path, "entries": entries}))).call_deferred()
		return id
	static func files() -> Array:
		var result: Array = [{"id": "/disk/child", "title": "Child folder", "container": true}]
		for i in 35: result.append({"uri": "file:///disk/%d.mp4" % i, "title": "[VR] 视频 %02d - A long file name.mp4" % i, "size": 12345678})
		return result

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if int(item.target) == target: return item
	return {}

func ray(menu: Node3D, target: int) -> Array:
	var node: Node3D = button(menu, target).node
	return [node.global_position + node.global_basis.z * 0.3, -node.global_basis.z]

func check_group_grips(main: Node3D, controls: Node3D, library: Node3D, kind: String) -> void:
	var initial_pose: Transform3D = controls.global_transform
	var relative_pose: Transform3D = library.transform
	var previous_view: String = library.view_mode
	var previous_scope: String = main.controller_bindings.move_scope
	var surface_pose: Transform3D = main._viewer().flat_pose
	main.controller_bindings.move_scope = "panel"
	for mode in ["grid", "list"]:
		library.set_view_mode(mode); library._set_scroll(0)
		for hand in ["left_hand", "right_hand"]:
			for region in ["file title", "file gap", "file row", "file edge", "controls gap", "controls button"]:
				controls.global_transform = initial_pose
				var aim: Array
				match region:
					"file title": aim = [library.to_global(Vector3(-0.15, 0.36, 0.3)), -library.global_basis.z]
					"file gap": aim = [library.to_global(Vector3(0.17, 0.30, 0.3)), -library.global_basis.z]
					"file row": aim = ray(library, Library.ROW_BASE)
					"file edge": aim = [library.to_global(Vector3(0.579, 0.419, 0.3)), -library.global_basis.z]
					"controls gap":
						var half: Vector2 = controls._backdrop.mesh.size / 2
						aim = [controls._backdrop.to_global(Vector3(half.x * 0.85, -half.y + 0.015, 0.3)), -controls.global_basis.z]
					_: aim = ray(controls, PhotoMenu.PHOTO_PREVIOUS if kind == "photo" else 102)
				var label := "%s/%s/%s/%s" % [kind, mode, hand, region]
				main.rays[hand] = aim
				var start := Transform3D(controls.global_basis, aim[0])
				main.move_pose = start
				main._begin_interface_move(hand, "grip_click")
				var targets: Array = main.interface_move.capture.get("targets", [])
				var grouped: bool = targets.size() == 1 and targets[0].node == controls
				check(grouped, "Either panel captures only the shared controls root: " + label)
				if not grouped:
					main.interface_move.cancel(); continue
				var anchor: Vector3 = main.interface_move.capture.anchor
				var files_before: Vector3 = library.global_position
				var head: Vector3 = main._head_pose().origin
				main.move_pose = start * Transform3D(Basis.from_euler(Vector3(0.07, -0.11, 0)), Vector3(0.1, 0.05, -0.025))
				main._update_interface_move()
				check(controls.global_position.distance_to(initial_pose.origin) > 0.01 and absf(controls.global_position.distance_to(head) - initial_pose.origin.distance_to(head)) < 0.0001 and absf(library.global_position.distance_to(head) - files_before.distance_to(head)) < 0.0001 and main._viewer().flat_pose.is_equal_approx(surface_pose), "Both panels move together at their original head distances: " + label)
				check(library.transform.is_equal_approx(relative_pose) and library.global_basis.is_equal_approx(controls.global_basis), "Dragging either panel preserves their relative pose and shared plane: " + label)
				var stopped_pose: Transform3D = controls.global_transform
				main._on_controller_release("grip_click", hand)
				main.move_pose.origin += Vector3(0.1, 0, 0); main._update_interface_move()
				check(main.interface_move.capture.is_empty() and controls.global_transform.is_equal_approx(stopped_pose), "Grip release stops both panels together: " + label)
	library.set_view_mode(previous_view)
	main.controller_bindings.move_scope = previous_scope

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main := Harness.new(); root.add_child(main)
	var video := Video.new(); main.add_child(video); video.set_process(false); main.video = video
	video.platform = Host.new()
	var photo := Photo.new(); main.add_child(photo); photo.set_process(false); main.photo = photo
	var player := Player.new(); main.add_child(player); player.set_process(false)
	main.video_menu = player; main.player_menu = player; player.state_provider = main._menu_state
	var photo_menu := PhotoMenu.new(); main.add_child(photo_menu); photo_menu.set_process(false); main.photo_menu = photo_menu
	photo_menu.state_provider = photo.snapshot; photo_menu.queue_provider = func(): return photo.queue
	var library := Library.new(); main.add_child(library); main.recent_menu = library
	library.catalog = video.recent_files; library.current_file_provider = func(): return main._viewer().local_uri
	library.attach_platform(Platform.new()); library.chosen.connect(main._on_library_chosen)
	library.layout_requested.connect(main._toggle_library_layout)
	player.action_requested.connect(main._on_menu_action); photo_menu.action_requested.connect(main._on_photo_action)
	player.recent_requested.connect(main._show_recent_menu); photo_menu.recent_requested.connect(main._show_recent_menu)
	player.seek_requested.connect(main._on_menu_seek)
	player.expanded_library = library; photo_menu.expanded_library = library
	main._show_recent_menu()
	check(library.visible and not library.compact and library._side.visible and not player.visible, "Without media the full library is shown")
	library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/disk", "title": "Disk"}]
	library._local_entries = Platform.files(); library.refresh(); library._set_scroll(4)
	library.remember_playback_context()
	video.open_local("file:///disk/18.mp4", "Video 18.mp4")
	video.media.state = "playing"; video._waiting_first = false; video.control.observe(30000, 120000)
	main._show_player_menu()
	player.global_transform = Transform3D(Basis.from_euler(Vector3(-0.18, 0.13, 0.08)), Vector3(0.2, 1.05, -1.4))
	var pose := player.global_transform
	# A full library was placed in the headset's previous orientation, not identity.
	library.transform = Transform3D(Basis.from_euler(Vector3(-0.35, 0.28, 0.1)).scaled(Vector3(1.2, 0.9, 1.1)), Vector3(-0.4, 1.4, -1.55))
	main._show_recent_menu()
	check(library.transform.basis.is_equal_approx(Basis.IDENTITY) and library.global_basis.is_equal_approx(player.global_basis), "Expansion discards the old full-menu rotation and scale and inherits the current transport basis")
	check(library.global_basis.z.normalized().dot(player.global_basis.z.normalized()) > 0.999999 and absf((library._backdrop.global_position - player._backdrop.global_position).dot(player.global_basis.z.normalized())) < 0.00001, "Expanded file and transport backdrops are coplanar at a tilted headset pose")
	check(player.visible and library.visible and library.compact and library.get_parent() == player, "Folder expands the shared library under the transport")
	check(main._active_menu() == player and library.composition_root() == player, "Input and compositor use the whole transport group")
	check(player.global_transform.is_equal_approx(pose) and library.position.is_equal_approx(Vector3(0, 0.72, 0)), "Expansion preserves the moved transport pose")
	check(not library._side.visible and library._cols() == 3 and library._lines() == 2, "Compact grid has three columns, two rows and no side navigation")
	check(library._buttons.all(func(item): return item.target < Library.NAV_BASE or item.target >= Library.NAV_BASE + Library.NAV.size()), "Hidden navigation has no ray targets")
	check(library._buttons.all(func(item): return item.target not in [Library.FOLLOW, Library.TEMP_PASSTHROUGH, Library.CLOSE_MENU]), "Compact browser does not duplicate the transport footer")
	check(library.rows.slice(library._first_line() * library._cols(), (library._first_line() + 1) * library._cols()).any(func(row): return row.get("uri", "") == "file:///disk/15.mp4"), "Layout conversion keeps the prior first item in the first visible grid row")
	check(not player.allows_playback_sticks(), "Expanded files isolate playback sticks")
	var playing_before: bool = video.requested_play
	var calls_before: int = video.platform.calls.size()
	var location_before: String = str(library._local_stack.back().id)
	var anchor_before: Dictionary = library.capture_position()
	var visible_before: Array = library.rows.slice(library._first_line() * library._cols(), (library._first_line() + 1) * library._cols()).map(func(row): return Library.Presentation.key(row))
	library._activate(Library.EXPAND_LIBRARY)
	check(not library.compact and library.playback_expanded and library.get_parent() == player and library.visible and player.visible, "Expand keeps full browsing and video controls visible together")
	check(main._active_menu() == player and library.composition_root() == player and player.has_expanded_library(), "Full browsing retains one input and compositor root with the video controls")
	main._menu_touched_ms = -10000; main._update_controls_visibility(player)
	check(player.visible and library.visible and not player.allows_playback_sticks(), "Expanded full browsing keeps the video transport visible and isolates playback sticks")
	check(video.requested_play == playing_before and video.platform.calls.size() == calls_before, "Expand never pauses, reopens or seeks the video")
	check(library._local_stack.back().id == location_before and library.rows.slice(library._first_line() * library._cols(), (library._first_line() + 1) * library._cols()).any(func(row): return Library.Presentation.key(row) in visible_before), "Expand retains the directory and visible position")
	check(not button(library, Library.EXPAND_LIBRARY).is_empty(), "Full browsing exposes collapse")
	library._activate(Library.EXPAND_LIBRARY)
	check(library.compact and library.visible and player.visible and library.get_parent() == player and not library.playback_expanded, "Collapse returns to the compact browser")
	check(player.global_transform.is_equal_approx(pose) and video.requested_play == playing_before and video.platform.calls.size() == calls_before, "Collapse preserves controls placement and playback state")
	check(library.capture_position().key == anchor_before.key, "Repeated layout changes do not drift backwards through the directory")
	video.requested_play = false
	main._toggle_library_layout(); main._toggle_library_layout()
	check(not video.requested_play and video.platform.calls.size() == calls_before, "A paused video stays paused through expand and collapse")
	video.requested_play = playing_before
	main._toggle_library_layout()
	var expanded_pose := player.global_transform
	var expanded_relative := library.transform
	var full_scroll: float = library.scroll
	var full_calls: int = video.platform.calls.size()
	main._process_sticks(Vector2(0, -0.99), Vector2(0.99, 0), 0.3)
	check(library.scroll > full_scroll and video.platform.calls.size() == full_calls, "The full browser scrolls through the transport without seeking or changing volume")
	var pause_ray := ray(player, 102)
	player.press_pointer("right_hand", pause_ray[0], pause_ray[1], true)
	check(not video.requested_play and library.visible and player.visible, "Video pause remains usable below the full browser")
	player.press_pointer("right_hand", pause_ray[0], pause_ray[1], true)
	check(video.requested_play and library.visible, "Video resume keeps the full browser available")
	main.controller_bindings.move_scope = "panel"; main.rays.left_hand = ray(library, Library.ROW_BASE)
	main.move_pose = Transform3D(Basis.IDENTITY, Vector3.ZERO); main._begin_interface_move("left_hand", "grip_click")
	check(main.interface_move.capture.targets.size() == 1 and main.interface_move.capture.targets[0].node == player, "Grip from the full browser captures the shared video transport root")
	main.move_pose.origin += Vector3(0.08, 0.05, 0); main._update_interface_move(); main.interface_move.cancel()
	check(not player.global_transform.is_equal_approx(expanded_pose) and library.transform.is_equal_approx(expanded_relative), "The full browser moves with video controls and preserves its local pose")
	var moved_expanded_pose := player.global_transform
	main._toggle_library_layout()
	check(player.global_transform.is_equal_approx(moved_expanded_pose) and library.global_basis.is_equal_approx(player.global_basis), "Collapse retains the visible, dragged transport pose and shared plane")
	main._menu_touched_ms = -10000; main._update_controls_visibility(player)
	check(player.visible and library.visible, "Expanded files defeat the idle hide timer")
	var calls: int = video.platform.calls.size()
	main._process_sticks(Vector2(0, -0.99), Vector2(0.99, 0), 0.3)
	check(library.scroll > 5 and video.platform.calls.size() == calls, "Sticks scroll without seeking or changing playback")
	library.set_view_mode("list")
	check(library._cols() == 1 and library._lines() == 5 and library._buttons.any(func(item): return item.target == Library.VIEW_GRID), "Compact list keeps the existing view preference and switch")
	for item in library._buttons:
		if not item.node.visible: continue
		var centre: Vector3 = library.to_local(item.node.global_position)
		check(absf(centre.x) + item.rect.size.x / 2 <= 0.581 and absf(centre.y) + item.rect.size.y / 2 <= 0.421, "Visible compact target stays inside the panel: %d" % item.target)
	library._set_scroll(0)
	var row_ray := ray(library, Library.ROW_BASE)
	check(player.ray_hit(row_ray[0], row_ray[1]).get("library", false), "Transport detects a nested browser ray in world space")
	check(player.press_pointer("left_hand", row_ray[0], row_ray[1], true) and player.has_pointer_capture(), "A file row captures on press and waits for release")
	check(player.press_pointer("right_hand", ray(player, 102)[0], ray(player, 102)[1], true) and video.platform.calls.size() == calls, "Other hand cannot interrupt a browser capture with transport")
	var moved_origin: Vector3 = row_ray[0] + library.global_basis.y * 0.18
	player.update_pointer("left_hand", moved_origin, row_ray[1], true)
	player.release_pointer("left_hand", moved_origin, row_ray[1], true)
	check(library.visible and library.scroll > 0 and video.local_uri == "file:///disk/18.mp4", "Ray drag scrolls without opening a file")
	library.set_view_mode("grid"); library._set_scroll(0)
	var gap_origin := library.to_global(Vector3(0.17, 0.13, 0.3))
	check(int(library.ray_hit(gap_origin, -library.global_basis.z).target) == Library.NONE, "Grid gap is protected by the file panel surface")
	player.press_pointer("left_hand", gap_origin, -library.global_basis.z, true)
	player.update_pointer("left_hand", gap_origin + library.global_basis.y * 0.1, -library.global_basis.z, true)
	player.release_pointer("left_hand", gap_origin + library.global_basis.y * 0.1, -library.global_basis.z, true)
	check(library.scroll > 0 and video.local_uri == "file:///disk/18.mp4", "Dragging a grid gap scrolls and cannot click through to playback")
	library._set_scroll(0); row_ray = ray(library, Library.ROW_BASE)
	player.press_pointer("left_hand", row_ray[0], row_ray[1], true); player.update_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(not player.has_pointer_capture() and library.visible, "Tracking loss cancels the nested file capture")
	library._set_scroll(0)
	library._choose(library.rows[0]); await process_frame
	check(library.rows.size() == 1 and library._local_stack.size() == 2, "Compact folder navigation uses the production directory request")
	library._go_back(); await process_frame
	check(library.rows.size() == 36 and library._local_stack.size() == 1, "Returning up keeps the shared browse context")
	check_group_grips(main, player, library, "video")
	var before_follow := library.transform
	main.view_follow.set_enabled(true); main._update_view_follow()
	check(library.transform.is_equal_approx(before_follow), "Head follow does not move the nested browser independently")
	var transport_ray := ray(player, 102)
	player.press_pointer("right_hand", transport_ray[0], transport_ray[1], true)
	check(library.visible and not video.requested_play, "Pause remains available while the files are expanded")
	main.rays.left_hand = ray(player, Player.SEEK)
	check(main._update_menu_pointer("left_hand", true) and player._seek_hand == "left_hand", "Main routes the timeline through the expanded transport")
	var before_scroll := library.scroll
	main._process_sticks(Vector2(0, -0.99), Vector2(0.99, 0), 0.2)
	check(library.scroll == before_scroll, "Timeline capture blocks file scrolling as well as playback sticks")
	main._on_pointer_release("trigger_click", "left_hand")
	check(player._seek_hand.is_empty() and library.visible, "Timeline release keeps the expanded files available")
	main._show_recent_menu()
	library.set_view_mode("list")
	check(player.visible and not library.visible and not player.has_expanded_library(), "Second folder press folds files and retains transport")
	var target: int = video.control.target_ms
	main._process_sticks(Vector2.ZERO, Vector2(0.99, 0), 0.1)
	check(video.control.target_ms == target, "Held stick stays blocked after folding files")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._show_recent_menu()
	var chosen_pose := player.global_transform
	check(library.global_basis.is_equal_approx(player.global_basis), "Reopening after moving and head follow keeps the current transport orientation")
	library._choose(library.rows[2])
	check(video.local_uri == "file:///disk/1.mp4" and player.visible and not library.visible and player.global_transform.is_equal_approx(chosen_pose), "Selecting another video folds files and preserves transport placement")
	main._show_recent_menu()
	check(library._buttons.any(func(item): return item.target >= Library.ROW_BASE and item.base_color == Library.SELECTED), "Current file has a visual selection marker")
	player.press_pointer("right_hand", ray(player, 11)[0], ray(player, 11)[1], true)
	check(not library.visible and player.section == 1, "Opening transport settings folds the file panel")
	main._show_recent_menu(); main._toggle_library_layout()
	main._close_current_media()
	check(library.get_parent() == main and library.visible and not library.compact and library._side.visible and not player.visible, "Closing video from expanded browsing detaches and restores the standalone full library")
	check(library.view_mode == "list" and library._local_stack.size() == 1, "Closing preserves view preference and current folder")
	library.remember_playback_context()
	video.open_local("file:///disk/ordinary.mp4", "Ordinary video.mp4"); video.media.state = "playing"
	main._show_player_menu(); main._show_recent_menu()
	var failed_folder: Array = library._local_stack.duplicate(true)
	var failed_calls: int = video.platform.calls.size()
	video.media.state = "failed"
	library._activate(Library.EXPAND_LIBRARY)
	check(library.visible and not library.compact and library._side.visible and not player.visible and library.get_parent() == main, "The explicit full-menu button recovers after playback failure")
	check(library._local_stack == failed_folder and video.platform.calls.size() == failed_calls, "Failure recovery preserves the folder and does not retry the failed video")
	library.dismiss(); main._show_recent_menu()
	check(library.visible and not library.compact and library._side.visible, "The folder action after failure opens the full menu")
	main._close_current_media()
	# Exercise the actual image selection branch, including control ownership changes.
	var image_path := ProjectSettings.globalize_path("user://compact-library-photo.png")
	var image := Image.create(8, 4, false, Image.FORMAT_RGB8); image.fill(Color(0.4, 0.6, 0.8)); image.save_png(image_path)
	library._local_entries = [{"uri": "file://" + image_path, "title": "Photo.png", "kind": "image"}]; library.refresh()
	library._choose(library.rows[0]); await process_frame
	check(main.photo_active and main.player_menu == photo_menu and photo_menu.visible, "Full browser image selection uses photo controls")
	photo_menu._gallery_open = true; photo_menu.refresh()
	photo_menu.global_transform = Transform3D(Basis.from_euler(Vector3(0.22, -0.3, -0.15)), Vector3(-0.2, 1.2, -1.4))
	library.transform = Transform3D(Basis.from_euler(Vector3(0.4, 0.25, 0.2)), Vector3(0, 1.4, -1.55))
	main._show_recent_menu()
	check(library.global_basis.is_equal_approx(photo_menu.global_basis), "Opening under photo controls resets the former full-menu orientation")
	check(library.get_parent() == photo_menu and photo_menu.has_expanded_library() and not photo_menu._gallery_open, "Image files expand under photo controls without the old thumbnail strip: uri=%s parent=%s visible=%s compact=%s gallery=%s" % [photo.local_uri, library.get_parent(), str(library.visible), str(library.compact), str(photo_menu._gallery_open)])
	main._toggle_library_layout()
	check(not library.compact and library.playback_expanded and library.get_parent() == photo_menu and library.visible and photo_menu.visible and main._active_menu() == photo_menu and library.composition_root() == photo_menu, "Full browsing keeps photo controls visible with shared input and composition")
	main._menu_touched_ms = -10000; main._update_controls_visibility(photo_menu)
	var photo_reset_ray := ray(photo_menu, 108)
	photo_menu.update_pointer("right_hand", photo_reset_ray[0], photo_reset_ray[1], true)
	check(photo_menu.visible and library.visible and photo_menu._hover.right_hand == 108, "Photo controls remain visible and receive rays below the full browser")
	var full_photo_relative := library.transform
	main.rays.right_hand = ray(photo_menu, PhotoMenu.PHOTO_PREVIOUS)
	main.move_pose = Transform3D.IDENTITY; main._begin_interface_move("right_hand", "grip_click")
	check(main.interface_move.capture.targets.size() == 1 and main.interface_move.capture.targets[0].node == photo_menu, "Grip from photo controls captures the full browser too")
	main.move_pose.origin += Vector3(-0.09, 0.04, 0); main._update_interface_move(); main.interface_move.cancel()
	check(library.transform.is_equal_approx(full_photo_relative) and library.global_basis.is_equal_approx(photo_menu.global_basis), "Dragging expanded photo controls preserves the attached full browser plane")
	main._toggle_library_layout()
	check_group_grips(main, photo_menu, library, "photo")
	var photo_uri_before: String = photo.local_uri
	var photo_queue_before: Array = photo.queue.duplicate(true)
	var photo_loading_before: bool = photo.loading
	var photo_controls_pose: Transform3D = photo_menu.global_transform
	main._toggle_library_layout(); main._toggle_library_layout()
	check(main.photo_active and main.player_menu == photo_menu and library.compact and library.get_parent() == photo_menu and photo.local_uri == photo_uri_before and photo.queue == photo_queue_before and photo.loading == photo_loading_before, "Photo expansion preserves the image, queue and loading state")
	check(photo_menu.global_transform.is_equal_approx(photo_controls_pose), "Photo collapse returns to the original controls placement")
	var image_controls_pose := photo_menu.global_transform
	library._local_entries.append({"uri": "file:///disk/switch.mp4", "title": "Switch.mp4"}); library.refresh()
	main._toggle_library_layout()
	library._choose(library.rows[1])
	check(not main.photo_active and player.visible and not photo_menu.visible and player.global_transform.is_equal_approx(image_controls_pose), "Full image-to-video selection preserves the current controls placement")
	main._show_recent_menu(); main._toggle_library_layout(); library._choose(library.rows[0])
	check(main.photo_active and photo_menu.visible and not library.visible and photo_menu.global_transform.is_equal_approx(image_controls_pose) and not main._photo_open_hide_controls, "Full video-to-image selection keeps photo controls visible during loading")
	main._show_recent_menu(); main._toggle_library_layout()
	main._close_current_media()
	check(not main.photo_active and not photo_menu.visible and library.visible and not library.compact and library._side.visible and library.get_parent() == main, "Closing an image from expanded browsing restores the detached full library")
	# Paged cloud responses retain the existing request and failure boundaries in compact mode.
	var cloud := preload("res://tests/test_cloud_pagination.gd").Platform.new()
	library.attach_platform(cloud); library.section = Library.Section.CLOUD; library._cloud_stack = [{"id": "/mount1", "title": "115"}]
	library._cloud_entries = []; library._cloud_page = 0; library._cloud_offsets.assign([0]); library._cloud_location = "/mount1"
	library.reparent(player, false); library.position = Vector3(0, 0.72, 0); player.visible = true; library.visible = true
	library.set_compact(true)
	check(cloud.requests.size() == 1 and cloud.requests[0].offset == 0, "An unlisted cloud playback folder loads on expansion")
	cloud.respond(1)
	check(library.rows.size() == 48 and button(library, Library.CLOUD_NEXT).enabled, "Compact cloud browser exposes page navigation")
	library._activate(Library.CLOUD_NEXT)
	check(cloud.requests.size() == 2 and cloud.requests[1].offset == 48 and not button(library, Library.CLOUD_NEXT).enabled, "Compact next page uses bounded asynchronous paging")
	cloud.respond(2, 3001, true)
	check(library._cloud_page == 0 and library.rows.size() == 48 and button(library, Library.REFRESH).enabled, "Cloud page failure preserves entries and permits refresh")
	library._activate(Library.CLOUD_NEXT); cloud.respond(3)
	check(library._cloud_page == 1 and library.rows[0].title == "目录 48", "Successful cloud page updates the compact rows")
	library.dismiss(); library.attach_platform(null); cloud.free()
	# Server details become a directly playable list, with metadata retained for playback.
	library.section = Library.Section.MEDIA_SERVER; library.server_browser.view = "detail"
	library.server_browser.entries = [{"uri": "medialib://test/scene/7", "title": "Server video", "id": "7", "basename": "test_SBS.mp4"}]
	library.server_browser.selection = {}; library.set_compact(true); library.visible = true
	check(library.server_browser.view == "scenes" and library.rows.size() == 1, "Server detail context expands as a compact file list")
	library.server_browser.detail = {"title": "Server film", "parts": [{"id": "7", "uri": "medialib://test/scene/7", "title": "cd1", "basename": "test_SBS.mp4"}, {"id": "8", "uri": "medialib://test/scene/8", "title": "cd2"}]}
	library.server_browser.view = "detail"; library.server_browser.gallery.selected_part = 1
	library.set_compact(true); library.set_compact(false)
	check(library.server_browser.view == "detail" and library.server_browser.gallery.selected_part == 1, "Expand restores server detail and selected part")
	video.local_uri = "medialib://test/scene/7"
	library.set_compact(true)
	check(library.rows.size() == 2 and library.rows[1].scene.uri == "medialib://test/scene/8", "Compact browsing retains every part even after playback selection metadata is consumed")
	video.local_uri = "medialib://test/scene/7"; main.photo_active = false; main.player_menu = player; library.refresh()
	check(button(library, Library.ROW_BASE).base_color == Library.SELECTED, "Server scene URI marks the current compact item")
	var selected: Array[Dictionary] = []
	library.chosen.disconnect(main._on_library_chosen)
	library.chosen.connect(func(uri, _title): selected.append({"uri": uri, "metadata": library.server_browser.selection.duplicate(true)}))
	library._choose(library.rows[0])
	check(selected.size() == 1 and selected[0].uri == video.local_uri and selected[0].metadata.basename == "test_SBS.mp4" and not library.visible, "Compact server row plays directly and preserves its source metadata")
	main.queue_free(); await process_frame
	print("Compact library checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
