extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
const Fixtures := preload("res://tests/test_compact_library.gd")
var failures: Array[String] = []
var checks := 0
var output := OS.get_environment("THRU3D_COMPACT_PREVIEW_DIR")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frames() -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw

func _initialize() -> void: call_deferred("run")

func run() -> void:
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.position = Vector3(0, 0.38, 1.8); camera.fov = 60; viewport.add_child(camera)
	var state := {"has_video": true, "source_uri": "file:///disk/4.mp4", "title": "[VR] 测试影片 — Sample video.mp4", "playing": true,
		"position_ms": 90000, "duration_ms": 180000, "seekable": true, "has_previous_video": true, "has_next_video": true}
	var player := Player.new(); origin.add_child(player); player.set_process(false); player.state_provider = func(): return state
	var photo := PhotoMenu.new(); origin.add_child(photo); photo.set_process(false)
	player.position = Vector3.ZERO; photo.position = Vector3.ZERO
	photo.state_provider = func(): return {"has_image": true, "title": "旅行照片 Photo.jpg", "count": 12, "index": 4, "geometry": 0}
	var library := Library.new(); origin.add_child(library)
	library.section = Library.Section.LOCAL; library._local_stack = [{"id": "/disk", "title": "电影 / Movies"}]
	library._local_entries = Fixtures.Platform.files(); library.current_file_provider = func(): return state.source_uri
	player.expanded_library = library; photo.expanded_library = library
	for language in ["zh", "en", "ja", "ko"]:
		preload("res://scripts/i18n.gd").use(language)
		for kind in ["video-grid", "video-grid-hover", "video-list", "photo-grid", "video-full", "photo-full", "cloud-grid", "server-list", "full"]:
			player.dismiss(); photo.dismiss(); library.dismiss()
			library.playback_expanded = false
			camera.position = Vector3(0, 0.6, 2.15) if kind in ["video-full", "photo-full"] else Vector3(0, 0.38, 1.8)
			library.section = Library.Section.LOCAL; state.source_uri = "file:///disk/4.mp4"
			if kind == "cloud-grid":
				library.section = Library.Section.CLOUD; library._cloud_stack = [{"id": "/115/Movies", "title": "Movies"}]
				library._cloud_entries = Fixtures.Platform.files(); library._cloud_total = 96; library._cloud_page = 1; library._cloud_next = -1
			elif kind == "server-list":
				library.section = Library.Section.MEDIA_SERVER; library.server_browser.view = "scenes"; library.server_browser.entries = []
				for i in 8: library.server_browser.entries.append({"uri": "medialib://test/scene/%d" % i, "id": str(i), "title": "电影 Movie %d" % i, "year": 2026, "duration_ms": 5400000})
				state.source_uri = "medialib://test/scene/2"
			if kind == "full":
				library.reparent(origin, false); library.position = Vector3(0.18, 0.34, 0)
				library.set_compact(false); library.view_mode = "grid"; library.refresh(); library.visible = true
			else:
				var host: Node3D = photo if kind in ["photo-grid", "photo-full"] else player
				host.visible = true; host._reset_navigation(); host.refresh()
				library.reparent(host, false); library.position = Vector3(0, 0.72, 0)
				library.playback_expanded = kind in ["video-full", "photo-full"]
				library.set_compact(not library.playback_expanded); library.view_mode = "list" if kind in ["video-list", "server-list"] else "grid"; library.scroll = 0; library.refresh(); library.visible = true
				if library.compact:
					for item in library._buttons:
						if not item.node.visible: continue
						var centre: Vector3 = library.to_local(item.node.global_position)
						check(absf(centre.x) + item.rect.size.x * 0.5 <= 0.581 and absf(centre.y) + item.rect.size.y * 0.5 <= 0.421, "%s %s target %d fits" % [language, kind, item.target])
					check(library._side.get_child_count() == 0 and not library._side.visible, "Compact side column has no geometry")
				else:
					check(host.visible and host.has_expanded_library() and library.composition_root() == host, "Full browser retains the visible transport and compositor root")
					check(library.to_global(Vector3(0, library._backdrop.position.y - library._backdrop.mesh.size.y / 2 - 0.14, 0)).y > host._backdrop.global_position.y + host._backdrop.mesh.size.y / 2, "Expanded footer stays clear of playback controls")
				if kind == "video-grid-hover":
					var node: Node3D = library._buttons.filter(func(item): return item.target == Library.EXPAND_LIBRARY)[0].node
					host.update_pointer("right_hand", node.global_position + node.global_basis.z * 0.3, -node.global_basis.z, true)
					check(library._tooltip.visible, "Expand purpose is visible on ray hover")
			await frames()
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + kind + ".png"))
	# Capture the production nested geometry through the compositor's host path.
	library.dismiss(); library.playback_expanded = false; library.section = Library.Section.LOCAL; library.reparent(player, false); library.position = Vector3(0, 0.72, 0); library.set_compact(true)
	player.visible = true; player.refresh(); library.visible = true
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, Display.new(), [library, player, photo], false, true); capture.set_process(false)
	capture.update(); await frames(); capture.update()
	check(capture.active == player, "Compositor selects the transport root for an expanded library")
	check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(player._backdrop)), "Compositor includes the transport backdrop")
	check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(library._backdrop)), "Compositor includes the file backdrop")
	for slot in capture.slots:
		if slot.used: slot.raw.get_texture().get_image().save_png(output.path_join("composition-%d.png" % slot.index))
	library.dismiss(); capture.update(); await frames(); capture.update()
	check(capture.active == player and capture.slots.all(func(slot): return not slot.used or not slot.nodes.has(library._backdrop) or not library._backdrop.is_visible_in_tree()), "Folding files leaves transport composition active")
	for host in [player, photo]:
		player.dismiss(); photo.dismiss(); library.dismiss()
		host.visible = true; host.refresh()
		library.reparent(host, false); library.playback_expanded = true; library.set_compact(false); library.visible = true; library.refresh()
		capture.invalidate(); capture.update(); await frames(); capture.update()
		check(capture.active == host, "Full browsing selects the visible video or photo transport root")
		check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(host._backdrop)) and capture.slots.any(func(slot): return slot.used and slot.nodes.has(library._backdrop)), "Full browsing captures both the library and playback bar")
		check(capture.slots.any(func(slot): return slot.used and slot.nodes.any(func(node): return node.get_parent() == library._side)), "Full browsing still captures the angled side navigation")
	capture.shutdown("test_complete"); viewport.queue_free(); await process_frame
	var report := {"state": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures,
		"scope": "Desktop production menu geometry and host compositor capture; headset binocular pixels and physical input remain unverified"}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Compact library render checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
