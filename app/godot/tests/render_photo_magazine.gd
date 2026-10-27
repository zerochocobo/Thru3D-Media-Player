extends SceneTree
const Menu := preload("res://scripts/puzzle/puzzle_photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
class InlineHost extends Node3D:
	var photo: Node3D
	var xr_camera: Camera3D
	var photo_menu: Node3D
	var recent_menu: Node3D
	var music_menu: Node3D
	var puzzle_game: Node3D
	var photo_active := true
	var _background_app_paused := false
	var _grab := {}
	var interface_move := {"capture":{}}
	var photo_hands := {"owners":{}}
	var display := {"preview":false}
	func _input_focused() -> bool: return true
	func _ray(_hand: String) -> Variant: return null

var output := "res://../../build/output/photo-magazine/previews"
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var view := SubViewport.new(); view.size = Vector2i(1600,950); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; view.msaa_3d = Viewport.MSAA_2X; root.add_child(view)
	var world := WorldEnvironment.new(); var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR; environment.background_color = Color("10151c")
	world.environment = environment; view.add_child(world)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.9; camera.position = Vector3(0,.20,2); view.add_child(camera); camera.current = true
	for language in ["en","zh","zh_Hant","ja"]:
		I18n.use(language)
		for scene in ["wall","layouts","rows","background","background-import","background-actions","background-actions-saving","background-actions-set","background-actions-error","background-set","magazine","archive","reading-order","magazine-rtl","magazine-depth","magazine-portrait","failed"]:
			var state := {"has_image":scene != "failed","count":168,"index":16,"title":"Magazine / 017.png", "layout":4 if scene in ["magazine","archive","reading-order","magazine-rtl","magazine-depth","magazine-portrait"] else 2,
				"depth_available":scene in ["magazine","magazine-depth"], "portrait_available":scene == "magazine", "depth_requested":scene in ["magazine-depth","magazine-portrait"],
				"depth_enabled":scene in ["magazine-depth","magazine-portrait"], "depth_strength":1.0, "portrait_requested":scene == "magazine-portrait", "portrait_enabled":scene == "magazine-portrait", "render_strength":1.0,
				"error":"Image unavailable" if scene == "failed" else "",
				"magazine_rtl":scene in ["reading-order","magazine-rtl"],
				"geometry":0,"wall_rows":3,"can_previous":true,"can_next":true,"gallery_focus":-1,
				"gallery_overview":scene == "wall", "archive_mode":scene == "archive", "magazine_pages":2 if scene == "magazine" else 1,
				"photo_background":"morning","photo_background_yaw":45,"photo_background_brightness":.75,
				"photo_global_custom":scene in ["background", "background-import"], "photo_background_custom":scene in ["background", "background-import"], "can_background":scene in ["background-import", "background-actions"], "audio_title":"", "source_size":"3000 × 2000"}
			if scene.begins_with("background-actions") or scene == "background-set":
				state.can_background = true
				state["photo_background_applied"] = scene.ends_with("-set")
				state["photo_background_saving"] = scene.ends_with("-saving")
				state["photo_background_loading"] = scene.ends_with("-saving")
				state["photo_background_error"] = "Background unavailable" if scene.ends_with("-error") else ""
			var menu := Menu.new(); view.add_child(menu); menu.set_process(false); menu.state_provider = func(): return state
			menu.favorite_provider = func(): return {"enabled":true,"favorite":false}
			menu.visible = true; menu._layout_open = scene in ["layouts","rows","archive","reading-order"]; menu._wall_rows_open = scene == "rows"
			menu._magazine_order_open = scene == "reading-order"
			menu._depth_open = scene == "magazine-depth"
			if scene.begins_with("background-actions"): menu.section = 1
			menu._scenery_open = scene in ["background", "background-import", "background-set"]; menu.refresh()
			for b in menu._buttons:
				var a := camera.unproject_position(b.node.to_global(Vector3(-b.rect.size.x*.5,-b.rect.size.y*.5,0)))
				var z := camera.unproject_position(b.node.to_global(Vector3(b.rect.size.x*.5,b.rect.size.y*.5,0)))
				check(a.x>=0 and z.x<view.size.x and z.y>=0 and a.y<view.size.y, language+"/"+scene+" button fits viewport")
				for other in menu._buttons:
					if other.target <= b.target: continue
					if b.rect.intersects(other.rect) and not is_equal_approx(b.node.position.z, other.node.position.z):
						# Existing quick sliders intentionally cover toolbar actions; verify ray ownership.
						var centre: Vector2 = b.rect.intersection(other.rect).get_center()
						var front: int = b.target if b.node.position.z > other.node.position.z else other.target
						check(menu.ray_hit(menu.to_global(Vector3(centre.x,centre.y,1)),-menu.global_basis.z).get("target",-1)==front,language+"/"+scene+" raised popup owns overlapping ray")
						continue
					check(not b.rect.intersects(other.rect), language+"/"+scene+" controls do not overlap: %s/%s" % [b.target,other.target])
			for frame in 3: await RenderingServer.frame_post_draw
			view.get_texture().get_image().save_png(output.path_join(language+"-"+scene+".png"))
			menu.free()
	print("Photo menu renders complete; rendering spread")
	await render_spread(view,camera)
	view.free(); await process_frame
	print("Photo magazine renders: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func render_spread(view: SubViewport, camera: Camera3D) -> void:
	const Photo := preload("res://scripts/photo_display.gd")
	var photo := Photo.new(); photo.history_enabled = false; view.add_child(photo)
	photo.view_camera = camera; camera.position = Vector3(0,0,5); camera.size = 5.0
	var entries: Array[Dictionary] = []
	for i in 2:
		var pixels := Image.create(600,800,false,Image.FORMAT_RGB8)
		pixels.fill(Color("ebe6db"))
		# Full-bleed border and marks in the page-number margin expose unwanted edge fading.
		for rect in [Rect2i(0,0,600,16),Rect2i(0,784,600,16),Rect2i(0,0,16,800),Rect2i(584,0,16,800)]:
			pixels.fill_rect(rect,Color.WHITE)
		pixels.fill_rect(Rect2i(40,780,20,8),Color.BLACK)
		pixels.fill_rect(Rect2i(540,780,20,8),Color.BLACK)
		pixels.fill_rect(Rect2i(40,40,520,300), Color("d25440") if i == 0 else Color("3489ad"))
		for line in 11: pixels.fill_rect(Rect2i(40,380+line*30,450 if line%3 else 350,10),Color("43505a"))
		var path := ProjectSettings.globalize_path(output.path_join("page-%d.png" % i)); pixels.save_png(path)
		entries.append({"uri":"file://"+path,"title":"Page %d" % (i+1),"kind":"image"})
	photo.gallery.set_mode(4); photo.open_image(entries[0].uri,entries[0].title,entries)
	print("Spread requested")
	var until := Time.get_ticks_msec()+5000
	while photo.loading and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(),"Full magazine fixture loads through production decoder")
	print("Spread loaded")
	photo.finish_transition(); photo._reveal_seconds = 0; photo._placeholder.visible = false
	photo.material.set_shader_parameter("reveal_progress",1.0)
	photo.set_flat_world_pose(Transform3D.IDENTITY)
	for frame in 4: await RenderingServer.frame_post_draw
	var spread := view.get_texture().get_image()
	spread.save_png(output.path_join("spread.png"))
	var dimensions: Vector2 = photo._flat.size
	var left := camera.unproject_position(photo.panel.to_global(Vector3(-dimensions.x*.25,dimensions.y*.23,0)))
	var right := camera.unproject_position(photo.panel.to_global(Vector3(dimensions.x*.25,dimensions.y*.23,0)))
	var lc := spread.get_pixelv(Vector2i(left)); var rc := spread.get_pixelv(Vector2i(right))
	check(lc.r > lc.b and rc.b > rc.r,"Actual rendered spread preserves both colored page headers in reading order")
	for uv in [Vector2(.005,.5),Vector2(.995,.5),Vector2(.25,.005),Vector2(.75,.995),Vector2(.005,.005),Vector2(.995,.995)]:
		var point := Vector3((uv.x-.5)*dimensions.x,(.5-uv.y)*dimensions.y,0)
		if photo.screen_curve > 0:
			var radius: float = photo._curve_radius()
			var angle := point.x / radius
			point.x = sin(angle)*radius; point.z = radius*(1.0-cos(angle))
		var pixel := spread.get_pixelv(Vector2i(camera.unproject_position(photo.panel.to_global(point))))
		check(minf(pixel.r,minf(pixel.g,pixel.b)) > .95,"Full-bleed edge remains opaque at %s" % uv)
	await render_inline_controls(view,camera,photo)
	photo.toggle_inspect()
	check(photo.inspect,"The existing magnifier remains available for magazine reading")
	photo.close_image(); photo.free()

func render_inline_controls(view: SubViewport, camera: Camera3D, photo: Node3D) -> void:
	var host := InlineHost.new(); view.add_child(host)
	host.photo = photo; host.xr_camera = camera
	for field in ["photo_menu","recent_menu","music_menu"]:
		var panel := Node3D.new(); host.add_child(panel); panel.visible = false; host.set(field,panel)
	var controls := preload("res://scripts/photo_magazine_controls.gd").new()
	host.add_child(controls); controls.setup(host); controls.set_process(false)
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE; camera.fov = 55; camera.position = Vector3(0,-.2,4)
	for language in ["en","zh","zh_Hant","ja"]:
		I18n.use(language)
		for variant in ["normal","large","far"]:
			photo.set_screen_scale(1.5 if variant == "large" else 1.0)
			photo.set_flat_world_pose(Transform3D(Basis.from_euler(Vector3(0,.18,.08)) if variant == "far" else Basis.IDENTITY,Vector3(0,0,-2 if variant == "far" else 0)))
			controls.sync()
			var b: Dictionary = controls._buttons[2]
			controls.update_pointer("right_hand",b.node.to_global(Vector3(0,0,1)),-controls.global_basis.z,true)
			for frame in 3: await RenderingServer.frame_post_draw
			view.get_texture().get_image().save_png(output.path_join(language+"-inline-"+variant+".png"))
			check(controls._tooltip.visible,language+"/"+variant+" shows a translated tooltip below the icons")
			check(controls._tooltip.position.y + controls._tooltip.mesh.size.y*.5 < -.06, "Tooltip stays below the image and button row")
	# Exercise the production high-resolution capture pool as well as the eye-buffer fallback.
	var composition := preload("res://scripts/menu_composition.gd").new(); host.add_child(composition)
	composition.configure(host,camera,null,[controls],false,true); composition.set_process(false)
	composition.update()
	for frame in 3: await RenderingServer.frame_post_draw
	check(composition.active == controls and composition.slots.any(func(slot):return slot.used and not slot.empty), "Detached inline row receives a native composition slot with the main menu hidden")
	check(composition.slots.any(func(slot):return slot.used and slot.nodes.any(func(item):return item == controls._tooltip)), "Tooltip shares the existing high-resolution capture pool")
	for i in composition.slots.size():
		var slot: Dictionary = composition.slots[i]
		if slot.used: slot.raw.get_texture().get_image().save_png(output.path_join("inline-layer-%d.png" % i))
	photo.set_screen_scale(.65); controls.sync(); composition.update()
	check(not composition.geometry_dirty and composition.active == controls, "Changing picture scale rebuilds native capture bounds")
	composition.shutdown("fixture_complete")
	host.free(); photo.set_screen_scale(1.0)
