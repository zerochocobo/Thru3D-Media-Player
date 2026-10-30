extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Main := preload("res://scripts/main.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://photo_portrait_%d" % Time.get_ticks_usec()

class Host extends RefCounted:
	var requests := []
	var cancelled := []
	var depth_requests := []
	var fail_depth := false
	var next_id := 1
	func prepare_photo_portrait(id: int, token: int, strength: float) -> bool:
		requests.append({"id":id,"token":token,"strength":strength}); return true
	func cancel_photo_portrait(token: int) -> void: cancelled.append(token)
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func prepare_photo_3d(id: int,strength: float) -> bool:
		depth_requests.append({"id":id,"strength":strength}); return not fail_depth
	func open_photo(_uri: String) -> int:
		next_id += 1; return next_id

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var app := Main.new(); app.settings_path = folder.path_join("app.cfg"); root.add_child(app); app.set_process(false)
	app.recent_menu.dismiss(); app.photo_active = true; app.player_menu = app.photo_menu
	app._update_background() # as opening a photo does: ends the flat-screen cinema presentation
	app.photo.history_enabled = false; app.photo.mode_memory = Memory.new(folder.path_join("modes"))
	var photo: Node3D = app.photo; var host := Host.new(); photo.platform = host
	var image := Image.create(160,100,false,Image.FORMAT_RGBA8); image.fill(Color.WHITE)
	var source := folder.path_join("source.png"); image.save_png(source)
	photo.queue.assign([{"uri":"file://"+ProjectSettings.globalize_path(source),"title":"source.png"},{"uri":"file://second.png","title":"second.png"}])
	photo.auto_depth = false
	var pair := Image.create(320,100,false,Image.FORMAT_RGBA8); pair.fill(Color.WHITE)
	var near := Image.create(518,518,false,Image.FORMAT_RF); near.fill(Color(0.8,0,0))
	var depth_data := {"image":near,"rect":Vector4(0,0,1,1),"stereo_image":pair,"strength":1.0}
	photo._accept({"image":image,"thumbnail":image,"info":{}}, {"id":1,"index":0})
	photo.finish_transition(); photo.set_layout_mode(2); photo.gallery._process(0.01)
	check(not photo.can_portrait(), "Unselected wall overview cannot start a multi-photo portrait effect")
	photo.gallery.activate(0)
	# Wall layouts keep only previews (6f1b985b): selecting reloads the full photo; deliver it.
	photo._accept({"image":image,"thumbnail":image,"info":{}}, {"id":1,"index":0}); photo.finish_transition()
	photo.gallery._process(1)
	check(photo.can_portrait() and not photo.depth_requested, "A selected ordinary photo can enter portrait without manually enabling 3D")
	app.photo_menu.toggle()
	var button: Dictionary = app.photo_menu._buttons.filter(func(b):return b.target == app.photo_menu.PHOTO_PORTRAIT)[0]
	check(button.enabled, "The photo portrait control is available before any 3D conversion")
	app.video_menu._state = {"has_video":true,"geometry":1,"alpha_requested":false}
	app.video_menu._draw()
	var video_button: Dictionary = app.video_menu._buttons.filter(func(b):return b.target == 104)[0]
	check(button.rect == video_button.rect and button.base_color == video_button.base_color and button.node.get_child(1).material_override.albedo_texture == video_button.node.get_child(1).material_override.albedo_texture, "Photo/video portrait controls share their position, size, surface and icon")
	app.photo_menu.dismiss()
	var old_curve: float = photo.screen_curve; var old_pose: Transform3D = photo.flat_pose
	var poses := {}
	for index in photo.gallery.cards: poses[index] = photo.gallery.cards[index].pose
	app._on_photo_action("photo_portrait")
	check(photo.depth_requested and photo.auto_depth and host.depth_requests.size() == 1 and host.requests.is_empty(), "One click enables 3D and waits for its colour pair before requesting a matte")
	photo._finish_depth(1,depth_data,false)
	check(photo.portrait_requested and not photo.portrait_enabled and host.requests.size() == 1, "Portrait is an explicit pending request until its own matching mask arrives")
	photo.gallery._process(0.1)
	check(photo.panel.visible and not photo.gallery.visible and photo.screen_curve == 0, "Portrait temporarily presents one flat photo and hides surrounding cards")
	check(photo.snapshot().can_previous and photo.snapshot().can_next and not photo.gallery.change_batch(1), "Portrait allows image navigation while overview batch gestures remain blocked")
	check(not photo.select_image(0) and photo.portrait_requested, "Selecting the already displayed menu image keeps the portrait intact")
	check(not photo._select(-1) and photo.portrait_requested, "An invalid selection cannot cancel the portrait")
	photo.toggle_inspect(); check(not photo.inspect, "Portrait cannot open a second magnifier")
	app.photo_menu.toggle()
	var disabled := [app.photo_menu.PHOTO_LAYOUT,app.photo_menu.MODE]
	check(app.photo_menu._buttons.filter(func(button):return button.target in disabled).all(func(button):return not button.enabled), "Menus keep incompatible layout and source-mode changes disabled during portrait")
	check(app.photo_menu._buttons.filter(func(button):return button.target in [app.photo_menu.PHOTO_NEXT,app.photo_menu.PHOTO_PREVIOUS]).all(func(button):return button.enabled), "Previous and next image controls remain enabled during portrait preparation")
	check(app.photo_menu._buttons.any(func(button): return button.target == app.photo_menu.PHOTO_PORTRAIT and button.enabled), "The portrait button always remains available as an exit")
	app._save_photo_adjustments()
	check(is_equal_approx(float(app.settings.get_value("photo_screen","curve")),old_curve) and app.settings.get_value("photo_screen","layout") == 2, "Temporary flat portrait view never overwrites saved curve or layout")
	var mask := Image.create(320,100,false,Image.FORMAT_R8); mask.fill(Color.WHITE)
	var path := folder.path_join("mask.r8"); FileAccess.open(path,FileAccess.WRITE).store_buffer(mask.get_data())
	var payload := {"state":"ready","token":photo._portrait_epoch,"path":path,"width":320,"height":100,"format":"r8_sbs","strategy":"video_soft_shift_gpu","strength":1.0}
	photo._on_portrait(2,JSON.stringify(payload)); check(photo._portrait_next.is_empty(), "Wrong source cannot supply a portrait mask")
	var stale := payload.duplicate(); stale.token -= 1
	photo._on_portrait(1,JSON.stringify(stale)); check(photo._portrait_next.is_empty(), "Old toggle results never enable a new portrait request")
	photo._on_portrait(1,JSON.stringify(payload))
	var deadline := Time.get_ticks_msec()+4000
	while not photo.portrait_enabled and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	check(photo.portrait_enabled and photo._portrait_texture.get_width() == 320, "Matching bounded per-eye matte enables transparent 3D photo rendering")
	check(photo.material.get_shader_parameter("portrait_enabled") and photo.material.get_shader_parameter("photo_stereo"), "Portrait preserves the original generated stereo colour")
	app.photo_menu.refresh_values(); app.photo_menu._toggle_depth_slider()
	check(app.photo_menu._can_depth() and app.photo_menu._buttons.any(func(b):return b.target == app.photo_menu.DEPTH and b.enabled), "The normal 3D slider remains usable inside portrait")
	var back: Dictionary = app.photo_menu._buttons.filter(func(b):return b.target == app.photo_menu.PHOTO_RETURN)[0]
	check(back.enabled and back.rect.end.x < 0, "Return stays on the left and remains accessible while adjusting 3D")
	var slider_origin: Vector3 = app.photo_menu.to_global(Vector3(app.photo_menu.DEPTH_X,0.215,0.2))
	var slider_hit: Dictionary = app.photo_menu.ray_hit(slider_origin,-app.photo_menu.global_basis.z)
	check(slider_hit.get("target") == app.photo_menu.DEPTH, "The depth track wins its ray area without competing with the left-side return button")
	app.photo_menu._depth_hand = "right_hand"
	var knob: MeshInstance3D = app.photo_menu._depth_knob
	var shown_pair: ImageTexture = photo._stereo_texture
	var shown_mask: ImageTexture = photo._portrait_texture
	check(photo.set_depth_strength(1.25), "Portrait accepts live 3D adjustment")
	var obsolete := payload.duplicate(); obsolete.token = photo._portrait_epoch; obsolete.strength = 1.25
	check(photo.set_depth_strength(1.5), "A rapid second adjustment supersedes the first")
	photo._on_portrait(1,JSON.stringify(obsolete))
	check(photo._portrait_next.is_empty(), "The superseded strength cannot supply a late mask")
	var stale_depth := depth_data.duplicate(); stale_depth.strength = 1.25
	photo._finish_depth(1,stale_depth,false)
	check(photo._stereo_texture == shown_pair and photo._portrait_texture == shown_mask and photo.portrait_enabled, "Intermediate colour keeps the complete visible portrait unchanged")
	var latest := depth_data.duplicate(); latest.strength = 1.5
	latest.stereo_image = pair.duplicate(); latest.stereo_image.fill(Color.RED)
	photo._finish_depth(1,latest,false)
	app.photo_menu.refresh_values()
	check(photo._stereo_texture == shown_pair and photo._portrait_texture == shown_mask and float(photo.snapshot().render_strength) == 1.0, "The new colour waits for its corresponding matte instead of exposing misaligned edges")
	check(app.photo_menu._depth_hand == "right_hand" and app.photo_menu._depth_knob == knob and app.photo_menu._depth_label.text == "150%", "Async conversion cannot replace the slider or interrupt the captured hand")
	var replacement := payload.duplicate(); replacement.token = photo._portrait_epoch; replacement.strength = 1.5
	photo._on_portrait(1,JSON.stringify(replacement))
	deadline = Time.get_ticks_msec()+4000
	while not is_equal_approx(photo._portrait_strength,1.5) and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	app.photo_menu.refresh_values()
	check(photo.portrait_enabled and photo._stereo_texture != shown_pair and photo._portrait_texture != shown_mask and float(photo.snapshot().render_strength) == 1.5, "The newest colour and matte replace the old pair in the same frame")
	check(app.photo_menu._depth_hand == "right_hand" and app.photo_menu._depth_knob == knob, "Matte completion preserves the active slider")
	app.photo_menu._finish_depth_drag()
	var warm_requests := host.requests.size()
	app._on_photo_action("photo_return")
	check(not photo.portrait_requested and is_equal_approx(photo.screen_curve,old_curve) and photo.flat_pose.is_equal_approx(old_pose), "Back restores the prior 3D photo shape and placement")
	photo.gallery._process(0.01)
	for index in poses: check(photo.gallery.cards[index].pose.is_equal_approx(poses[index]), "Surrounding photographs retain their exact original slots")
	check(photo.set_portrait(true) and photo.portrait_enabled and host.requests.size() == warm_requests, "Reopening the same portrait reuses its mask without another inference")
	check(photo.set_depth_strength(0) and photo.depth_requested and photo.portrait_requested, "Zero strength keeps the cutout active with no disparity")
	var zero := depth_data.duplicate(); zero.strength = 0.0
	photo._finish_depth(1,zero,false)
	var zero_payload := payload.duplicate(); zero_payload.token = photo._portrait_epoch; zero_payload.strength = 0.0
	photo._on_portrait(1,JSON.stringify(zero_payload))
	deadline = Time.get_ticks_msec()+4000
	while not is_equal_approx(photo._portrait_strength,0) and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	check(photo.portrait_enabled and float(photo.snapshot().render_strength) == 0.0, "The zero-disparity colour/matte pair also commits together")
	photo.select_image(1)
	check(not photo.portrait_requested and not photo.portrait_enabled and photo.auto_portrait and photo.pending_index == 1, "Menu image selection clears the source mask and preserves portrait continuation")
	photo._on_portrait(1,JSON.stringify(payload)); check(not photo.portrait_enabled, "Late completion after image change cannot cut out the next photo")
	var new_id: int = photo._request
	photo._accept({"image":image,"thumbnail":image,"info":{},"depth_data":zero},{"id":new_id,"index":1})
	photo.finish_transition(); photo.gallery._process(1); photo._maybe_start_portrait()
	check(photo.portrait_requested and not photo.portrait_enabled and photo.depth_strength == 0.0 and host.requests.back().id == new_id, "The next focused wall photo automatically requests its own portrait and preserves zero disparity")
	check(photo._portrait_texture == null and photo._portrait_mask.is_empty(), "The next source starts without the departing photo's matte")
	photo._on_portrait(1,JSON.stringify(payload))
	var next_payload := zero_payload.duplicate(); next_payload.token = photo._portrait_epoch
	var next_stale := next_payload.duplicate(); next_stale.token -= 1
	photo._on_portrait(new_id,JSON.stringify(next_stale))
	check(photo._portrait_next.is_empty(), "Neither the old source nor an old generation can supply the new photo's matte")
	photo._on_portrait(new_id,JSON.stringify(next_payload))
	deadline = Time.get_ticks_msec()+4000
	while not photo.portrait_enabled and Time.get_ticks_msec()<deadline: await create_timer(0.01).timeout
	check(photo.portrait_enabled and host.requests.back().id == new_id, "The next photo becomes transparent after its own matching matte arrives")
	app.photo_menu._toggle_depth_slider(); app.photo_menu.refresh_values()
	var next_button: Dictionary = app.photo_menu._buttons.filter(func(b):return b.target == app.photo_menu.PHOTO_NEXT)[0]
	var ray_origin: Vector3 = next_button.node.global_position + next_button.node.global_basis.z
	app.photo_menu.press_pointer("right_hand",ray_origin,-app.photo_menu.global_basis.z,true)
	app.photo_menu.release_pointer("right_hand",ray_origin,-app.photo_menu.global_basis.z,true)
	check(photo.loading and photo.pending_index == 0 and photo.auto_portrait, "The enabled next-image ray button switches directly from a finished portrait and wraps the album")
	check(photo.navigate(1) and photo.pending_index == 1 and photo.navigate(-1) and photo.pending_index == 0, "Rapid next/previous requests follow the pending image while retaining portrait continuation")
	new_id = photo._request
	photo._on_portrait(2,JSON.stringify(next_payload))
	photo._accept({"image":image,"thumbnail":image,"info":{},"depth_data":zero},{"id":new_id,"index":0})
	photo.finish_transition(); photo.gallery._process(1); photo._maybe_start_portrait()
	check(photo.portrait_requested and host.requests.back().id == new_id, "Only the final rapidly selected photo starts a new portrait inference")
	photo._on_portrait(new_id,JSON.stringify({"state":"error","error":"PHOTO_NO_PERSON","token":photo._portrait_epoch}))
	var failed_requests := host.requests.size()
	photo._maybe_start_portrait(); photo._maybe_start_portrait()
	check(not photo.portrait_requested and photo.auto_portrait and photo.portrait_error == "No person detected" and host.requests.size() == failed_requests, "A photo with no person remains readable without retrying and preserves continuation for later photos")
	check(photo.navigate(1), "A no-person result does not block navigation")
	new_id = photo._request
	photo._accept({"image":image,"thumbnail":image,"info":{"native_stereo":true,"stereo_sbs":true}},{"id":new_id,"index":1})
	photo.finish_transition(); photo.gallery._process(1); photo._maybe_start_portrait()
	check(not photo.portrait_requested and photo.auto_portrait and host.requests.size() == failed_requests, "An incompatible native stereo source skips portrait inference without forgetting the album choice")
	check(photo.navigate(-1), "Previous image remains available from an incompatible source")
	new_id = photo._request
	photo._accept({"image":image,"thumbnail":image,"info":{},"depth_data":zero},{"id":new_id,"index":0})
	photo.finish_transition(); photo.gallery._process(1); photo._maybe_start_portrait()
	check(photo.portrait_requested and host.requests.back().id == new_id, "Returning to a compatible photo automatically resumes portrait after no-person and incompatible photos")
	photo.set_portrait(false)
	check(photo.navigate(1), "Explicitly exiting portrait still allows image navigation")
	new_id = photo._request
	photo._accept({"image":image,"thumbnail":image,"info":{},"depth_data":zero},{"id":new_id,"index":1})
	photo.finish_transition(); photo.gallery._process(1); photo._maybe_start_portrait()
	check(not photo.auto_portrait and not photo.portrait_requested, "An explicit exit prevents the next photo from automatically enabling portrait")
	photo.set_layout_mode(0); photo.set_portrait(true)
	check(photo.navigate(-1) and photo.loading, "Single-photo layout also permits navigation during portrait preparation")
	photo.set_portrait(false) # The request is already suspended for navigation; this still cancels the choice.
	new_id = photo._request
	photo._accept({"image":image,"thumbnail":image,"info":{},"depth_data":zero},{"id":new_id,"index":0})
	photo.finish_transition(); photo._maybe_start_portrait()
	check(not photo.portrait_requested and not photo.auto_portrait, "Turning portrait off during loading prevents delayed automatic activation")
	photo.set_portrait(true); photo.close_image()
	check(not photo.auto_portrait and not photo._portrait_auto_due and not photo.portrait_requested, "Closing the album clears automatic portrait continuation")
	var pending := Photo.new(); root.add_child(pending); pending.platform = host; pending.history_enabled = false
	pending.mode_memory = Memory.new(folder.path_join("pending-modes")); pending.auto_depth = false
	pending.queue.assign([{"uri":"file://"+ProjectSettings.globalize_path(source),"title":"source.png"}])
	pending._accept({"image":image,"thumbnail":image,"info":{}},{"id":99,"index":0}); pending.finish_transition()
	check(pending.set_portrait(true) and pending.depth_requested and not pending.portrait_enabled, "3D preparation can precede the initial portrait matte")
	var cancelled_epoch: int = pending._portrait_epoch
	pending.set_portrait(false); pending._finish_depth(99,depth_data,false)
	var cancelled_payload := payload.duplicate(); cancelled_payload.token = cancelled_epoch
	pending._on_portrait(99,JSON.stringify(cancelled_payload))
	check(not pending.portrait_requested and not pending.portrait_enabled and pending._portrait_next.is_empty(), "Exiting during initial 3D preparation prevents late portrait activation")
	pending.set_depth(false); pending._display_depth_data = {}; pending._depth_texture = null; pending._stereo_texture = null
	host.fail_depth = true
	check(not pending.set_portrait(true) and not pending.portrait_requested and pending.portrait_error == "3D unavailable", "Unavailable 3D returns to the photo instead of leaving portrait stuck preparing")
	host.fail_depth = false; pending.free()
	for bad in [{"width":8194},{"width":319},{"format":"rgba"},{"strength":3},{"height":5000}]:
		var invalid := payload.duplicate(); invalid.merge(bad,true)
		check(Photo._read_portrait(invalid).is_empty(), "Malformed mask metadata is rejected")
	FileAccess.open(path,FileAccess.WRITE).store_8(0)
	check(Photo._read_portrait(payload).is_empty(), "Truncated mask payload cannot become a texture")
	app.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo portrait: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
