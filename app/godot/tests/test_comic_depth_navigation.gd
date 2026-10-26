extends "res://tests/test_photo_preload.gd"
## Regression for 3D persistence during comic page turns. Uses the existing native photo/depth mock;
## OCR/translation flags exercise the production navigation gates without network requests.

func finish_page(photo: Node3D, host: RefCounted) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		for id in host.depth_pending.keys(): host.complete_depth(int(id))
		if not photo.loading and not photo._depth_busy and photo._depth_queue.is_empty() and not photo._depth_thread: break
		await create_timer(.01).timeout
	check(not photo.loading and not photo._depth_busy, "Page and depth requests settle")
	photo.finish_transition()

func _run() -> void:
	folder = "res://../../build/output/comic-depth-navigation"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var entries: Array[Dictionary] = []
	for i in 4:
		var source := Image.create(100, 200, false, Image.FORMAT_RGB8)
		source.fill(Color(.2 * i, .3, .5))
		var path := ProjectSettings.globalize_path(folder.path_join("source-%d.png" % i))
		source.save_png(path)
		entries.append({"uri": "file://" + path, "title": "%d.png" % i, "kind": "image"})
	var rows := []
	for layout in [0, 4]:
		for feature in ["off", "speech", "translation", "both"]:
			var photo := Photo.new(); photo.history_enabled = false
			photo.mode_memory = Memory.new(folder.path_join("modes.json")); root.add_child(photo)
			var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
			host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth
			photo.platform = host; photo.set_layout_mode(layout)
			photo.open_image(entries[0].uri, entries[0].title, entries); await finish_page(photo, host)
			photo.comic.enabled = feature in ["speech", "both"]
			photo.comic.translation.enabled = feature in ["translation", "both"]
			check(photo.set_depth(true), "Current page accepts manual 3D")
			await finish_page(photo, host)
			check(photo.depth_enabled and photo.depth_requested, "Current page renders 3D")
			var before := host.depth_calls
			check(photo.navigate(1), "Next page is available")
			await finish_page(photo, host)
			var row := {"layout": layout, "feature": feature, "index": photo.index, "auto_depth": photo.auto_depth,
				"requested": photo.depth_requested, "enabled": photo.depth_enabled, "depth_calls_after_turn": host.depth_calls - before,
				"depth_error": photo.depth_error, "size": str(photo._size)}
			rows.append(row)
			check(photo.auto_depth and photo.error.is_empty(), "Turn retains user preference and a valid colour image")
			check(photo.depth_requested and photo.depth_enabled and host.depth_calls == before + 1, "%s / layout %d: next page restores 3D exactly once" % [feature, layout])
			check(photo.index == (2 if layout == 4 else 1) and photo._size == Vector2(200 if layout == 4 else 100, 200), "Turn preserves the expected page count and composition")
			if layout == 0:
				await warm(photo, host)
				check(photo._prefetched.has(0), "Return path includes a cached colour page")
			before = host.depth_calls
			check(photo.navigate(-1), "Previous page is available")
			await finish_page(photo, host)
			check(photo.depth_requested and photo.depth_enabled and host.depth_calls == before + 1, "%s / layout %d: returning to a page restores its own 3D" % [feature, layout])
			check(photo.set_depth(false), "User can disable 3D while comic features remain active")
			before = host.depth_calls
			check(photo.navigate(1), "Next page after disabling 3D is available")
			await finish_page(photo, host)
			check(not photo.auto_depth and not photo.depth_requested and not photo.depth_enabled and host.depth_calls == before, "Explicit Off stays Off after turning the page")
			check(photo.comic.enabled == (feature in ["speech", "both"]) and photo.comic.translation.enabled == (feature in ["translation", "both"]), "Navigation preserves independent comic feature switches")
			photo.close_image(); photo.free(); await process_frame
	FileAccess.open(folder.path_join("result.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t") + "\n")
	print("Comic depth navigation: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
