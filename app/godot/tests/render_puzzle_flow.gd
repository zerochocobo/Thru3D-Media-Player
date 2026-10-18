extends SceneTree
const PuzzlePanel := preload("res://scripts/puzzle/puzzle_panel.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
const I18n := preload("res://scripts/i18n.gd")
const Composition := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
const PhotoMenu := preload("res://scripts/puzzle/puzzle_photo_menu.gd")
const LibraryMenu := preload("res://scripts/puzzle/puzzle_library_menu.gd")
const PhotoEntry := preload("res://scripts/puzzle/puzzle_photo_entry.gd")
const Reference := preload("res://scripts/puzzle/puzzle_reference.gd")
const Dock := preload("res://scripts/puzzle/puzzle_dock.gd")
class HintHost extends "res://scripts/puzzle/puzzle_host.gd":
	func _ready() -> void: set_process(false)
class HintApp extends Node:
	var xr_camera: Camera3D
	var hand_pointers := {"right_hand":{"source":"controller"},"left_hand":{"source":"controller"}}
var viewport: SubViewport
var panel: Node3D
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p1/render")
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func capture(name_value: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name_value+".png"))
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new(); viewport.size=Vector2i(1280,1000); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment=Environment.new()
	world.environment.background_mode=Environment.BG_COLOR; world.environment.background_color=Color(0.025,0.035,0.05); viewport.add_child(world)
	var camera := Camera3D.new(); viewport.add_child(camera); camera.position.z=2.0; camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=1.12
	var image := Image.create(240,160,false,Image.FORMAT_RGBA8)
	for y in 160:
		for x in 240: image.set_pixel(x,y,Color(0.15+float(x)/300,0.25+float(y)/300,0.5))
	var source := {"image":image,"texture":ImageTexture.create_from_image(image),"size":Vector2(240,160),"uri":"fixture://puzzle-flow","title":"海边的午后.png"}
	var session := Session.new(); viewport.add_child(session); session.configure(source,Session.grid_for_source(source,24)); session.visible=false
	var store := Store.new(output.path_join("saved")); var descriptor := store.cache_source(source)
	var snapshot: Dictionary=session.snapshot(); snapshot.pieces[0].placed=true; snapshot.pieces[5].placed=true
	panel=PuzzlePanel.new(); viewport.add_child(panel); panel.position=Vector3.ZERO; panel.visible=true; panel.mode="hub"; panel.can_start=true
	panel.has_game=true; panel.can_undo=true; panel.status="Saved"; panel.thumbnail_provider=store.thumbnail
	for i in 7:
		var record := {"id":"%032x" % (i+1),"source":descriptor.duplicate(),"snapshot":snapshot.duplicate(true),"done":i+1,"total":24,"updated":Time.get_unix_time_from_system()-i*3600}
		record.source.title=["海边的午后.png","森林小径.jpg","空间照片.heic","周末旅行.jpg"][i%4]
		record.snapshot.standing=i%2==1; panel.records.append(record)
	for language in ["zh","en","ja"]:
		I18n.use(language); panel.refresh(); await capture("01-hub-"+language)
		check(panel._buttons.all(func(b):return b.rect.size.x>0 and b.rect.size.y>0),language+" hub has valid ray targets")
	I18n.use("zh"); panel.page=1; panel.refresh(); await capture("02-hub-page-two")
	panel.history_mode=true; panel.page=0; panel.refresh(); await capture("02-history")
	check(panel._buttons.any(func(b):return b.target==27) and not panel._buttons.any(func(b):return b.target==26),"History is a secondary page with a Back action")
	panel.page=1; panel.refresh(); await capture("02-history-page-two"); panel.history_mode=false
	panel.page=0; panel.mode_enabled=true; panel.refresh(); await capture("02-mode-on")
	var saved_records: Array=panel.records.duplicate(); panel.records.clear(); panel.can_start=false; panel.refresh(); await capture("02-mode-empty")
	check(not panel._buttons.any(func(b):return b.target==14),"Default hub has no link that changes library filters")
	panel.records.assign(saved_records); panel.can_start=true
	panel.mode="setup"; panel.refresh(); await capture("02-start-popup")
	check(is_equal_approx(panel._backdrop.mesh.size.x,0.60) and panel._buttons.size()==9 and panel._buttons.any(func(b):return b.target==61),"Compact start popup offers original or random quarter turns with posture and difficulty")
	panel._activate(61); await capture("02-start-random"); panel._activate(60)
	panel.mode="complete"; panel.count=24; panel.total=24; panel.refresh(); await capture("02-completed")
	panel.mode="hub"
	panel.deleting=panel.records[4].id; panel.refresh(); await capture("03-delete")
	panel.deleting=""; panel.mode="game"; panel.count=5; panel.total=24; panel.refresh(); await capture("04-game-panel")
	check(panel._buttons.size()==7 and not panel._buttons.any(func(b):return b.target in [2,7]),"Independent game surface includes posture, help and music with batch actions outside")
	panel.mode="help"; panel.refresh(); await capture("05-help")
	panel.visible=false; session.visible=true; session.position=Vector3(0,0.30,-0.25); camera.projection=Camera3D.PROJECTION_PERSPECTIVE; camera.fov=72; camera.position=Vector3(0,0,1.55)
	session.viewer_position=session.to_local(camera.global_position); session.set_posture(false); await capture("06-seated")
	camera.position=Vector3(0,0.30,1.9); camera.look_at(session.position); session.viewer_position=session.to_local(camera.global_position); session.set_posture(true); await capture("07-standing-overview")
	var standing_view := camera.transform
	camera.rotation.y=deg_to_rad(65); await capture("07-standing-left-arc")
	camera.rotation.y=deg_to_rad(-65); await capture("07-standing-right-arc"); camera.transform=standing_view
	var adjusted := Transform3D(Basis(Vector3.UP,0.08).scaled(Vector3.ONE*1.12),Vector3(0.08,0.12,0))
	session.set_frame_pose(adjusted)
	session.pieces[0].placed=true; session.pieces[0].transform=session.pieces[0].goal
	panel.visible=true; session.set_paused(true); panel.mode="game"; panel.count=1; panel.refresh(); panel.global_transform=session.menu_anchor(panel.layout_height()*0.5+0.08)
	camera.position=Vector3(0,0.15,2.3); camera.look_at(Vector3(0,0.10,-0.25)); await capture("07-moved-frame-menu")
	check(panel.global_position.y+panel.layout_height()*0.5<session.board.global_position.y-session.board_size.y*session.frame_scale()*0.5,"The moved and resized frame keeps its game panel below the picture")
	panel.visible=false; panel.transform=Transform3D.IDENTITY; session.set_paused(false)
	session.visible=false
	var dense := Session.new(); viewport.add_child(dense); dense.configure(source,Session.grid_for_source(source,96)); dense.position=session.position; dense.viewer_position=dense.to_local(camera.global_position); dense.set_posture(true)
	camera.position=Vector3(0,0.30,1.9); camera.look_at(dense.position)
	await capture("07-standing-96")
	var frame_pixel := viewport.get_texture().get_image().get_pixelv(camera.unproject_position(dense.board.global_position))
	check(frame_pixel.r>0.2 and frame_pixel.g>0.2,"96-piece standing view retains its frosted target frame")
	var front_view := camera.transform
	camera.position=Vector3(0,5,0.8); camera.look_at(Vector3(0,0.3,0.6),Vector3.FORWARD); camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=4.8
	await capture("07-standing-96-arc-plan"); camera.transform=front_view; camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.rotation.y=deg_to_rad(75); await capture("07-standing-96-close-side"); camera.transform=front_view
	var held: MeshInstance3D=dense.pieces.filter(func(p):return p.visible)[0]
	var hand := camera.global_position+Vector3(-0.16,-0.20,-0.30)
	check(dense.grab("right_hand",hand,(held.global_position-hand).normalized(),Transform3D.IDENTITY,false,false,true),"A visible dense fragment can be brought to the player for rendering")
	if dense.captures.has("right_hand"):
		dense.update_grab("right_hand",hand,(dense.frame_world_pose().origin-hand).normalized())
		await capture("07-held-piece-on-frame-unsnapped")
		check(held.global_position.distance_to(hand)>0.5 and not dense.captures.right_hand.candidate,"The actual thick fragment moves to the frame before magnetic alignment")
		var target: Vector3=dense.to_global(held.goal*dense.captures.right_hand.anchor)
		dense.update_grab("right_hand",hand,(target-hand).normalized())
		await capture("07-held-piece-on-frame-snapped")
		check(held.transform.is_equal_approx(held.goal) and dense.hint.visible,"The actual fragment attaches to the frame with its magnetic feedback")
		dense.random_rotation=true
		var fixture := HintApp.new(); fixture.xr_camera=camera
		var hint_host := HintHost.new(); hint_host.app=fixture; hint_host.session=dense; viewport.add_child(hint_host)
		hint_host._update_rotation_hint("right_hand",[hand,(target-hand).normalized()])
		await capture("07-held-near-rotation-hint")
		check(hint_host.rotation_hints.right_hand.visible and hint_host.rotation_hints.right_hand.text.begins_with("A"),"The real controller A rotation cue is rendered near the held fragment")
		hint_host.queue_free(); fixture.free(); dense.cancel("right_hand")
	dense.visible=false
	session.visible=false; camera.position=Vector3(0,0,2); camera.basis=Basis.IDENTITY; camera.projection=Camera3D.PROJECTION_ORTHOGONAL; camera.size=1.35
	var photo := PhotoMenu.new(); viewport.add_child(photo); photo.position=Vector3.ZERO; photo.visible=true
	var photo_state := {"has_image":true,"count":3,"index":0,"title":"海边的午后.png","can_next":true,"can_previous":true,"layout":0}
	photo.state_provider=func(): return photo_state.duplicate(true)
	photo.refresh_values(); await capture("08-photo-entries")
	photo_state.layout=2; photo_state.gallery_focus=0; photo.refresh_values(); await capture("09-photo-focused-entries")
	photo.music_quick.expanded=true; photo.refresh_music_quick_controls(); camera.position.x=-0.2; camera.size=1.6; await capture("10-photo-music-expanded")
	photo.dismiss()
	var library := LibraryMenu.new(); viewport.add_child(library); library.position=Vector3.ZERO; library.visible=true; library.refresh()
	camera.position.x=-0.13; camera.size=1.7; await capture("11-library-entries"); library.dismiss(); camera.position.x=0
	library.visible=true; library.media_filter=2; library.refresh(); await capture("11-images-mode-entries")
	library.media_filter=0; library.puzzle_progress_provider=func():return true; library.refresh(); await capture("11-home-progress-entry"); library.dismiss()
	photo.queue_free(); library.queue_free(); await process_frame
	var entry := PhotoEntry.new(); viewport.add_child(entry); entry.position=Vector3(0,-0.25,0); entry.visible=true; entry.refresh()
	var picture_surface := MeshInstance3D.new(); picture_surface.mesh=QuadMesh.new(); picture_surface.mesh.size=Vector2(0.7,0.46); picture_surface.position=Vector3(0,0.10,0)
	var picture := StandardMaterial3D.new(); picture.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED; picture.albedo_texture=source.texture
	picture_surface.material_override=picture; viewport.add_child(picture_surface)
	camera.position=Vector3(0,0,2); camera.size=0.85; await capture("11-large-image-entry"); picture_surface.visible=false; entry.visible=false
	var origin := Node3D.new(); viewport.add_child(origin)
	var display := Display.new(); display.configure(viewport,world.environment,null,true)
	for low_end in [false,true]:
		var layers := Composition.new(); viewport.add_child(layers)
		layers.configure(origin,camera,display,[],low_end,true); layers.set_process(false)
		var swapchains := layers.slots.map(func(slot):return slot.submit.get_instance_id())
		layers.register_menu(panel); layers.register_menu(panel)
		check(layers.menus.size()==1,"Repeated game registration is idempotent")
		panel.visible=true; panel.position=Vector3.ZERO; panel.page=0; panel.deleting=""
		for language in (["zh"] if low_end else ["zh","zh_Hant","en","ja"]):
			I18n.use(language)
			for mode_value in ["hub","history","setup","complete","game","game_standing","exit_confirm","help","help_flat","help_random","help_random_flat","sky"]:
				panel.history_mode=mode_value=="history"
				panel.mode="hub" if panel.history_mode else ("game" if mode_value=="game_standing" else ("help" if mode_value.begins_with("help") else mode_value))
				panel.standing=mode_value=="game_standing"
				panel.spherical=not mode_value.ends_with("flat"); panel.random_rotation=mode_value.begins_with("help_random"); panel.refresh(); layers.update()
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				layers.update()
				var slot := {}
				for candidate in layers.slots:
					if candidate.used and candidate.nodes.has(panel._backdrop): slot=candidate; break
				check(not slot.is_empty() and slot.nodes.has(panel._labels[0]),"Actual game labels join the captured panel: "+language+mode_value)
				if slot.is_empty(): continue
				var rendered: Image=slot.raw.get_texture().get_image()
				var name_value: String="12-hd-"+("low-" if low_end else "standard-")+language+"-"+mode_value
				rendered.save_png(output.path_join(name_value+".png"))
				var ink := 0
				for y in range(0,rendered.get_height(),3):
					for x in range(0,rendered.get_width(),3):
						var pixel := rendered.get_pixel(x,y)
						if pixel.a>0.5 and minf(pixel.r,minf(pixel.g,pixel.b))>0.65: ink+=1
				check(ink>100,"Captured page contains visible text strokes: "+name_value)
				var density: float=slot.raw.size.y/slot.layer.quad_size.y
				check(density>=Composition.DENSITY*(Composition.LOW_END_SCALE if low_end else 1.0)*0.9,"Game menu retains the normal capture density")
		check(layers.slots.map(func(slot):return slot.submit.get_instance_id())==swapchains,"Page/language changes reuse fixed compositor swapchains")
		layers.unregister_menu(panel)
		check(layers.menus.is_empty() and layers.active==null and panel._backdrop.layers==1 and layers.slots.all(func(slot):return not slot.used),"Exit restores mesh masks and parks captured layers before detaching the game")
		I18n.use("zh"); entry.refresh(); entry.visible=true; layers.register_menu(entry); layers.update()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var entry_slot := {}
		for candidate in layers.slots:
			if candidate.used and candidate.nodes.has(entry._labels.back()): entry_slot=candidate; break
		check(not entry_slot.is_empty(),"Enter puzzle game caption is captured at the normal menu density")
		if not entry_slot.is_empty(): entry_slot.raw.get_texture().get_image().save_png(output.path_join("13-image-entry-"+("low" if low_end else "standard")+".png"))
		layers.unregister_menu(entry); entry.visible=false
		var peer_photo := PhotoMenu.new(); viewport.add_child(peer_photo)
		peer_photo.state_provider=func():return photo_state
		peer_photo.visible=true; peer_photo.refresh_values()
		entry.companion=peer_photo; entry.visible=true
		layers.register_menu(peer_photo); layers.register_menu(entry); layers.update()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var pair_slot := {}
		for candidate in layers.slots:
			if candidate.used and candidate.nodes.has(entry._labels.back()): pair_slot=candidate; break
		check(layers.active==peer_photo and not pair_slot.is_empty(),"Photo controls and the large-image game entry are captured together")
		if not pair_slot.is_empty(): pair_slot.raw.get_texture().get_image().save_png(output.path_join("15-entry-and-controls-"+("low" if low_end else "standard")+".png"))
		var before_peer: Transform3D=entry.global_transform; entry.position.x+=0.08; layers.update()
		check(not layers.geometry_dirty and entry.global_transform!=before_peer,"Moving a companion entry updates its captured planes without a new swapchain")
		entry.global_transform=before_peer; layers.unregister_menu(entry); layers.unregister_menu(peer_photo); entry.companion=null; entry.visible=false; peer_photo.queue_free()
		var reference := Reference.new(); viewport.add_child(reference); reference.source=source; reference.refresh(); reference.visible=true
		layers.register_menu(reference); layers.update()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		var reference_slot := {}
		for candidate in layers.slots:
			if candidate.used and candidate.nodes.has(reference.picture): reference_slot=candidate; break
		check(not reference_slot.is_empty() and reference.device_status==null,"The reference image remains HD without a wrist-mounted status footer")
		if not reference_slot.is_empty(): reference_slot.raw.get_texture().get_image().save_png(output.path_join("14-reference-"+("low" if low_end else "standard")+".png"))
		layers.unregister_menu(reference)
		var handle := Dock.new(); viewport.add_child(handle); handle.visible=true; handle.refresh(); handle.position=Vector3(0,-0.2,0.1)
		handle.spherical=true; handle.refresh()
		handle.device_status.status_provider=func():return {"level":82,"charging":false,"clock24":true}
		handle.device_status.clock_provider=func():return {"hour":23,"minute":58}
		handle.device_status.refresh(true)
		reference.companion=handle; reference.position=Vector3(-0.3,0.18,-0.2)
		layers.register_menu(handle); layers.register_menu(reference); layers.update()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(layers.active==handle and layers.slots.any(func(slot):return slot.used and slot.nodes.has(handle._buttons[0].node) and slot.nodes.has(handle.device_status._label)) and layers.slots.any(func(slot):return slot.used and slot.nodes.has(reference.picture)),"Menu, batch/reset shortcuts and front status are HD alongside the separate palm reference")
		for i in layers.slots.size():
			var slot: Dictionary=layers.slots[i]
			if slot.used: slot.raw.get_texture().get_image().save_png(output.path_join("16-game-hud-"+("low" if low_end else "standard")+"-%d.png" % i))
		handle.audio_provider=func():return {"audio_title":"海边的午后","audio_current":"yunhai","audio_paused":false,"audio_active":true}
		handle.music_quick.expanded=true; handle.refresh(); layers.update()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(handle._buttons.any(func(b):return b.target==handle.music_quick.PLAY) and layers.slots.any(func(slot):return slot.used and slot.nodes.has(handle.device_status._label)),"Expanded leftmost music controls preserve front status in the HD toolbar")
		for i in layers.slots.size():
			var slot: Dictionary=layers.slots[i]
			if slot.used: slot.raw.get_texture().get_image().save_png(output.path_join("17-game-music-"+("low" if low_end else "standard")+"-%d.png" % i))
		layers.unregister_menu(reference); layers.unregister_menu(handle); handle.queue_free(); reference.queue_free(); await process_frame
		var temporary := PuzzlePanel.new(); viewport.add_child(temporary); temporary.visible=true; temporary.refresh()
		layers.register_menu(temporary); layers.update(); temporary.free()
		check(layers.menus.is_empty() and layers.active==null,"A freed game panel automatically unregisters without stale capture references")
		layers.queue_free(); await process_frame
	viewport.queue_free(); await process_frame
	print("Puzzle flow render: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
