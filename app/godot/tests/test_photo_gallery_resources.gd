extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const PreloadFixture := preload("res://tests/test_photo_preload.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var folder := "user://gallery_resources_%d" % Time.get_ticks_usec()
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func settle(photo: Node, host: RefCounted) -> void:
	var deadline := Time.get_ticks_msec()+5000
	while photo.loading and Time.get_ticks_msec()<deadline:
		for id in host.depth_pending.keys(): host.complete_depth(int(id))
		await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(), "Expanded image finishes decoding and conversion")
	photo.finish_transition(); photo.gallery._process(1)
	if photo.spatial_preferred:
		photo._maybe_start_spatial()
		while photo.spatial_requested and not photo._spatial.prepared and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
		check(photo._spatial.prepared, "Expanded spatial comic builds its real scene")

func empty_full_resources(photo: Node, host: RefCounted, context: String) -> void:
	check(photo._texture==null and photo._full_image==null and photo._depth_texture==null and photo._stereo_texture==null, context+": no full-size GPU/CPU pictures")
	check(photo._display_result.is_empty() and photo._display_depth_data.is_empty() and photo._pending_display.is_empty() and photo._upload.is_empty(), context+": no decoded pairs retained by caches or uploads")
	check(photo._prefetched.is_empty() and photo._recent_files.is_empty() and host.held.is_empty(), context+": no neighboring full-image leases")
	check(not photo.loading and not photo.depth_enabled and not photo.spatial_requested and photo._spatial.surfaces.is_empty(), context+": no invisible 3D scene or conversion")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var image := Image.create(160,320,false,Image.FORMAT_RGB8); image.fill(Color(.2,.5,.8))
	var path := ProjectSettings.globalize_path(folder.path_join("comic.png")); image.save_png(path)
	var entries: Array[Dictionary] = []
	for index in 120: entries.append({"uri":"file://"+path+"#"+str(index),"title":"comic_%d.png"%index,"kind":"image"})
	# Keep distinct album identities while using ordinary local PNG fixtures.
	for entry in entries: entry.uri="file://"+path.get_base_dir().path_join(str(entry.title)); DirAccess.copy_absolute(path,str(entry.uri).trim_prefix("file://"))
	var photo := Photo.new(); photo.history_enabled=false; photo.auto_depth=true
	photo.mode_memory=Memory.new(folder.path_join("modes")); root.add_child(photo)
	var host := PreloadFixture.Host.new(); host.folder=ProjectSettings.globalize_path(folder); host.use_stereo=true
	host.ready=photo._on_ready; host.depth=photo._on_depth; host.preload_depth=photo._on_prefetch_depth; photo.platform=host
	for layout in [2,3]:
		photo.set_layout_mode(layout)
		var opens: int=host.opens; var conversions: int=host.depth_calls
		photo.open_image(entries[0].uri,entries[0].title,entries)
		var runtime_releases: int=host.runtime_releases
		photo.gallery._process(.01)
		check(host.opens==opens and host.depth_calls==conversions, "Opening an album overview does not decode or convert a hidden main image")
		empty_full_resources(photo,host,"New overview %d"%layout)
		var count: int=photo.gallery.cards.size()
		for repeat in 8:
			photo.spatial_preferred=repeat%2==0
			var target: int=photo.gallery.cards.keys()[repeat%count]
			photo.gallery.activate(target); await settle(photo,host)
			check(photo.index==target and photo.depth_enabled and photo._stereo_texture!=null, "Only the expanded comic receives its generated stereo pair")
			if repeat==0:
				target=photo.gallery.cards.keys()[1]
				photo.gallery.activate(target)
				check(photo._texture==null and photo._stereo_texture==null and host.held.size()==1,"Switching directly between expanded comics releases the outgoing full image first")
				await settle(photo,host)
			photo._pump_prefetch()
			check(host.held.size()==1 and host.preloads==0, "Expanded static/spatial comic never starts neighboring 3D jobs")
			photo.gallery.return_focus(); photo.gallery._process(1); await process_frame
			empty_full_resources(photo,host,"Returned overview %d/%d"%[layout,repeat])
			check(photo.queue.size()==120 and photo.local_uri==entries[target].uri and photo.gallery.cards.has(target), "Releasing full resources preserves album, selection and preview cards")
			photo.gallery.activate(target); await settle(photo,host)
			check(photo.index==target and photo.panel.visible, "The same comic can reopen after its full resources were released")
			photo.gallery.return_focus(); photo.gallery._process(1)
		# Return while conversion is pending; its eventual result cannot resurrect the picture.
		photo.gallery.activate(photo.gallery.cards.keys()[0])
		var deadline := Time.get_ticks_msec()+3000
		while photo._pending_display.is_empty() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
		var late: int=photo._request
		photo.gallery.return_focus(); photo.gallery._process(1)
		photo._on_depth(late,'{"state":"error"}')
		empty_full_resources(photo,host,"Cancelled conversion %d"%layout)
		# Both a missing thumbnail and a failed full-image decode must allow explicit retry.
		var bad: int=photo.gallery.cards.keys()[0]
		var uri: String=entries[bad].uri
		photo.gallery.previews._failed[uri]=true
		var original := FileAccess.get_file_as_bytes(uri.trim_prefix("file://"))
		FileAccess.open(uri.trim_prefix("file://"),FileAccess.WRITE).store_string("broken")
		photo.gallery.activate(bad)
		check(not photo.gallery.previews._failed.has(uri), "Selecting a blank card permits its thumbnail to retry")
		deadline=Time.get_ticks_msec()+3000
		while photo.loading and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
		check(not photo.loading and not photo.error.is_empty(), "A bad comic leaves an error instead of indefinite loading")
		photo.gallery.return_focus(); photo.gallery._process(1)
		FileAccess.open(uri.trim_prefix("file://"),FileAccess.WRITE).store_buffer(original)
		photo.gallery.activate(bad); await settle(photo,host)
		check(photo.panel.visible and photo.index==bad and photo.error.is_empty(), "Explicit retry recovers the same previously unreadable comic")
		photo.gallery.return_focus(); photo.gallery._process(1)
		check(host.runtime_releases==runtime_releases,"Gallery selections reuse one model session instead of forcing cold reloads")
		photo.set_layout_mode(0); await settle(photo,host)
		check(photo.panel.visible and photo.gallery.cards.is_empty(), "Returning to single mode reloads the selected comic")
		photo.close_image()
	photo.free(); await process_frame
	var arguments := OS.get_cmdline_user_args()
	if arguments.size()==2 and arguments[0]=="--manifest": await check_originals(arguments[1])
	for failure in failures: push_error(failure)
	print("Photo gallery resources: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_originals(manifest: String) -> void:
	# User fixtures stay outside the repository and are always read-only. The platform double
	# copies a selected source into the isolated test cache; it does not run Android inference.
	var parsed: Variant=JSON.parse_string(FileAccess.get_file_as_string(manifest))
	if not parsed is Array or parsed.is_empty(): check(false,"Original-image manifest is readable"); return
	var entries: Array[Dictionary]=[]
	for entry in parsed: entries.append(entry)
	var largest := 0
	var largest_pixels := 0
	for index in entries.size():
		var entry: Dictionary=entries[index]
		var header: Dictionary=preload("res://scripts/image_info.gd").read_header(str(entry.path))
		var pixels := int(header.get("width",0))*int(header.get("height",0))
		if pixels>largest_pixels: largest=index; largest_pixels=pixels
		var decoded: Dictionary=Photo._decode({"info":{"path":entry.path}})
		check(decoded.has("image") and not decoded.has("error"),"Original full decode %d"%index)
		decoded={}
		var preview: Dictionary=preload("res://scripts/photo_preview_cache.gd")._decode({"uri":entry.uri,"info":{"path":entry.path}})
		check(preview.has("image") and maxi(preview.image.get_width(),preview.image.get_height())<=384,"Original sampled preview %d"%index)
		if index%8==0: print("Original JPEG/PNG decode progress %d/%d"%[index+1,entries.size()])
		await process_frame
	var photo:=Photo.new(); photo.history_enabled=false; photo.auto_depth=true
	photo.mode_memory=Memory.new(folder.path_join("original_modes")); root.add_child(photo)
	var host:=PreloadFixture.Host.new(); host.folder=ProjectSettings.globalize_path(folder); host.use_stereo=true
	host.ready=photo._on_ready; host.depth=photo._on_depth; host.preload_depth=photo._on_prefetch_depth; photo.platform=host
	var overview_texture_limit := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)+32*1024*1024
	for layout in [2,3]:
		photo.set_layout_mode(layout); photo.open_image(entries[0].uri,entries[0].title,entries); photo.gallery._process(.01)
		for repeat in 4:
			photo.spatial_preferred=repeat%2==0
			var target: int=[largest,largest,0,entries.size()-1][repeat]
			photo.gallery.new_window(target); photo.gallery._process(.01)
			photo.gallery.activate(target); await settle(photo,host)
			check(photo.panel.visible and photo.index==target,"Original image expands in layout %d"%layout)
			photo.gallery.return_focus(); photo.gallery._process(1); await process_frame
			empty_full_resources(photo,host,"Original returned %d/%d"%[layout,repeat])
			if DisplayServer.get_name()!="headless":
				await RenderingServer.frame_post_draw
				var texture_bytes := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
				check(texture_bytes<=overview_texture_limit,"Original 8K texture allocation returns within the overview budget")
				print("Original overview texture bytes: %d"%texture_bytes)
		photo.close_image()
	photo.free(); await process_frame
	print("Read-only original images checked: %d; Android inference is not part of this desktop fixture"%entries.size())
