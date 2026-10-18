extends SceneTree
const Main := preload("res://scripts/main.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Source := preload("res://scripts/puzzle/puzzle_source.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-history/run-")+str(Time.get_ticks_usec())

class PhotoHost extends RefCounted:
	var ready: Callable
	var request := 100
	var model_calls := 0
	func open_photo(uri: String) -> int:
		request+=1
		ready.call_deferred(request,JSON.stringify({"state":"ready","path":uri.trim_prefix("file://")}))
		return request
	func prepare_photo_3d(_id: int,_strength: float) -> bool: model_calls+=1; return false
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func _initialize() -> void: call_deferred("_run")
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func wait_picture(host: Node,photo: Node) -> void:
	var deadline := Time.get_ticks_msec()+10000
	while (host.active or photo.loading) and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	photo.finish_transition()
func source(index: int) -> Dictionary:
	var image := Image.create(160,80,false,Image.FORMAT_RGBA8); image.fill(Color(0.2+index*0.04,0.4,0.6))
	var value := {"image":image,"texture":ImageTexture.create_from_image(image),"size":Vector2(160,80),
		"uri":"smb://offline/folder-%d/same.png" % index,"title":"same.png","kind":"flat","projection":"flat"}
	match index:
		1:
			var depth := Image.create(252,140,false,Image.FORMAT_RF); depth.fill(Color(0.7,0,0))
			value.kind="relief"; value.depth=depth; value.relief=0.02; value.depth_rect=Vector4(0,0,1,1)
		2: value.kind="stereo"; value.layout=1; value.swap_eyes=true; value.spatial_disparity=0.02; value.size.x=80
		3: value.projection="sphere"
	return value
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var app := Main.new(); app.settings_path=output.path_join("settings.cfg"); root.add_child(app); app.set_process(false)
	app.photo.history_enabled=false; app.photo.mode_memory=Memory.new(output.path_join("modes"))
	var decoder := PhotoHost.new(); decoder.ready=app.photo._on_ready; app.photo.platform=decoder
	var host: Node=app.puzzle_game; host.store=Store.new(output.path_join("saved"))
	var ids: Array[String]=[]; var unfinished := ""
	for i in 9:
		var picture := source(i); var descriptor: Dictionary=host.store.cache_source(picture)
		var session := Session.new(); root.add_child(session); session.configure(picture,Session.grid_for_source(picture,24))
		if i==0: unfinished=host.store.create_game(descriptor,session.snapshot())
		for piece in session.pieces: piece.placed=true; piece.transform=piece.goal
		ids.append(host.store.create_game(descriptor,session.snapshot())); session.queue_free()
	check(host.store.history().size()==9 and host.store.unfinished().size()==1,"Completed history and unfinished games are separate across nine images")
	var unchanged := FileAccess.get_file_as_bytes(host.store._path(unfinished))
	var restarted := Store.new(host.store.directory)
	check(restarted.history().size()==9,"History is reconstructed after restart without a separate mutable index")
	host.open_hub()
	check(not host.panel.history_mode and host.panel.records.size()==1,"Puzzle entry always opens unfinished games first")
	host.panel._activate(26)
	check(host.panel.history_mode and host.panel.records.size()==9 and host.panel.page==0,"A secondary history button opens the review page")
	check(host.panel._buttons.any(func(b):return b.target==100) and host.store.thumbnail(host.panel.records[0].source)!=null,"History cards have an image action and retained thumbnail")
	host.panel._activate(21); host.panel._activate(21)
	check(host.panel.page==2 and host.panel._buttons.filter(func(b):return b.target in range(200,204)).size()==1,"History paginates to the final partial page")
	host.panel.scroll_axis(0); host.panel.scroll_axis(0.9)
	check(host.panel.page==1,"The joystick scrolls history pages")
	var deleted: String=host.panel.records[4].id; host.panel._activate(200)
	check(host.panel.deleting==deleted,"Deleting history requires its record confirmation")
	host.panel._activate(30)
	check(host.panel.history_mode and host.panel.records.size()==8 and host.store.get_game(deleted).is_empty(),"Confirmed deletion stays in history and hides only that game")
	check(host.store.get_game(unfinished).snapshot.pieces.size()==24 and FileAccess.get_file_as_bytes(host.store._path(unfinished))==unchanged,"Deleting completed history never rewrites unfinished progress")
	host.panel._activate(22)
	check(host.panel.history_mode and host.panel.records.size()==9 and not host.store.get_game(deleted).is_empty(),"Undo restores history without switching back to unfinished")
	host.panel._activate(27)
	check(not host.panel.history_mode and host.panel.records.size()==1 and host.panel.page==0,"Back returns from history to unfinished games")
	host._action("mode_off"); host._action("history")
	check(host.panel.records.size()==9 and not host.is_mode_enabled(),"Disabling puzzle mode preserves access to history")
	host.finish()
	app.recent_menu.media_filter=0
	for i in 4:
		host.open_hub(true)
		var index: int=host.panel.records.find_custom(func(record):return record.id==ids[i])
		host.panel.page=index/host.panel.ROWS; host.panel.refresh()
		app.photo.auto_depth=true
		host.panel._activate(100+index%host.panel.ROWS)
		await wait_picture(host,app.photo)
		check(not host.active and app.photo_active and app.photo.error.is_empty() and app.photo._texture!=null,"History card opens its cached photo even when original SMB source is offline: %d" % i)
		check(app.photo.queue.size()==1 and app.photo.local_uri==host.store.image_uri(host.store.get_game(ids[i]).source),"History image has an isolated photo queue: %d" % i)
		check(app.recent_menu.media_filter==0 and app.photo.auto_depth,"History access does not activate a picture filter or change automatic 3D preference: %d" % i)
		var retained: Dictionary=Source.from_photo(app.photo)
		check(retained.get("kind")==["flat","relief","stereo","flat"][i] and retained.get("projection")==("sphere" if i==3 else "flat"),"History preserves ordinary, relief, spatial or 360 presentation: %d" % i)
		if i==1: check(app.photo.depth_enabled and app.photo._display_depth_data.has("image"),"Relief history reuses its retained depth without running the model")
		if i==2: check(app.photo.swap_eyes and is_equal_approx(app.photo._metadata.spatial_disparity,0.02),"Spatial history preserves eye order and disparity")
		if i==0:
			host.store.set_mode_enabled(true); host._preference_store=null; host.open_setup()
			var ready_until := Time.get_ticks_msec()+10000
			while host.panel.preparing and Time.get_ticks_msec()<ready_until: await create_timer(0.01).timeout
			check(host.game_id==unfinished and host.store.unfinished().size()==1,"Entering from a retained history picture continues the original image's unfinished game")
			host.finish()
			unchanged=FileAccess.get_file_as_bytes(host.store._path(unfinished))
	check(decoder.model_calls==0,"No history picture triggers an automatic depth inference")
	check(host.store.history().size()==9 and FileAccess.get_file_as_bytes(host.store._path(unfinished))==unchanged,"Further picture reviews leave the explicitly resumed game's migrated checkpoint unchanged")
	# A missing retained asset keeps the review page open, without deleting progress.
	var broken: Dictionary=host.store.get_game(ids[4]); var asset: String=host.store.image_uri(broken.source).trim_prefix("file://")
	DirAccess.rename_absolute(asset,asset+".missing")
	host.open_hub(true); host.open_history_image(ids[4])
	var deadline := Time.get_ticks_msec()+10000
	while host.panel.preparing and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	check(host.active and host.panel.history_mode and host.panel.status=="Saved image unavailable" and host.store.history().size()==9,"Unavailable history image reports failure without losing the review page or records")
	DirAccess.rename_absolute(asset+".missing",asset)
	host.finish(); app.photo.close_image(); app.queue_free(); await process_frame; await process_frame
	print("Puzzle history: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
