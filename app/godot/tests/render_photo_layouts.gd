extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var viewport: SubViewport
var photo: Node3D
var camera: Camera3D
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/photo-layouts/render")
var entries: Array[Dictionary] = []

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frame(name: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	result.save_png(output.path_join(name + ".png")); return result

func previews() -> void:
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		photo.gallery._process(0.02)
		if photo.gallery.cards.keys().all(func(index): return photo.gallery.previews.texture(str(entries[index].uri)) != null): break
		await create_timer(0.01).timeout
	check(photo.gallery.cards.keys().all(func(index): return photo.gallery.previews.texture(str(entries[index].uri)) != null), "Rendered layouts have actual preview content")

func expanded() -> void:
	var deadline := Time.get_ticks_msec()+5000
	while photo.loading and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(), "Expanded render source reloads after overview resource release")
	photo.finish_transition(); photo.gallery._process(1)

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for i in 64:
		var size := Vector2i(320, 180) if i % 3 == 0 else (Vector2i(150, 230) if i % 3 == 1 else Vector2i(220, 220))
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
		image.fill(Color.from_hsv(i / 64.0, 0.65, 0.8))
		image.fill_rect(Rect2i(0, 0, size.x / 4, size.y), Color(0.9, 0.15, 0.1))
		image.fill_rect(Rect2i(size.x * 3 / 4, 0, size.x / 4, size.y), Color(0.1, 0.3, 0.9))
		image.fill_rect(Rect2i(size.x / 3, size.y / 3, size.x / 3, size.y / 3), Color(0.9, 0.9, 0.8))
		var path := output.path_join("source-%02d.png" % i); image.save_png(path)
		entries.append({"uri": "file://" + path, "title": "%02d.png" % i, "kind": "image"})
	viewport = SubViewport.new(); viewport.size = Vector2i(1280, 720); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := WorldEnvironment.new(); world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR; world.environment.background_color = Color(0.012, 0.025, 0.035)
	viewport.add_child(world)
	camera = Camera3D.new(); camera.position.y = 1.6; camera.fov = 70; viewport.add_child(camera)
	photo = Photo.new(); photo.history_enabled = false; photo.mode_memory = Memory.new("user://layout_render_modes")
	viewport.add_child(photo); photo.view_camera = camera; photo.flat_pose.origin = Vector3(0, 1.6, -3)
	photo.open_image(str(entries[0].uri), "00.png", entries)
	var deadline := Time.get_ticks_msec() + 5000
	while photo.loading and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	check(photo.error.is_empty() and not photo.loading, "Render fixture loads through production photo path")
	photo.finish_transition(); photo.gallery.set_process(false)
	var single: Image = await frame("01-single")
	check(single.get_pixel(640, 360).r > 0.5, "Single photo remains visible")
	photo.set_target_feedback(1)
	var target_single: Image = await frame("01b-single-targeted")
	check(target_single.get_data() == single.get_data(), "Full photo keeps the same feathered edge when targeted")
	photo.set_target_feedback(0)
	photo.set_layout_mode(1); await previews()
	var sides: Image = await frame("02-sides")
	check(sides.get_data() != single.get_data(), "Side layout draws previews around the same central photo")
	photo.set_screen_scale(3); await previews()
	var enlarged: Image = await frame("02b-sides-enlarged")
	check(photo.gallery.cards.values().all(func(card): return card.node.visible), "Enlarged hero retains all rendered thumbnails")
	await side_separation()
	photo.set_screen_scale(1)
	photo.set_layout_mode(2); await previews()
	var wall: Image = await frame("03-wall")
	check(wall.get_data() != sides.get_data(), "Wall is visually distinct from side previews")
	await wall_feather()
	for row_count in [2, 3]:
		photo.gallery.set_wall_rows(row_count); await previews()
		var multi: Image = await frame("03-wall-%d-rows" % row_count)
		check(multi.get_data() != wall.get_data(), "Selected wall rows change the rendered arrangement")
	photo.gallery.set_wall_rows(1); await previews()
	photo.gallery.activate(0); await expanded()
	var wall_opened: Image = await frame("03b-wall-focused")
	await foreground_overlap(wall_opened,"03-wall")
	photo.gallery.return_focus(); photo.gallery._process(1)
	var wall_returned: Image = await frame("03c-wall-returned")
	check(wall_returned.get_data() == wall.get_data(), "Closing restores all wall feathering and removes the selection rim")
	photo.gallery.set_view_scale(1.6); await previews(); await frame("04-wall-large")
	photo.gallery.set_view_scale(1); photo.set_layout_mode(3); await previews()
	var memories: Image = await frame("05-fragments")
	check(memories.get_data() != wall.get_data(), "Memory view renders different silhouettes and upper-space positions")
	var first: Dictionary = photo.gallery.cards[0]
	var ray_origin := camera.global_position + Vector3(-0.2, -0.25, 0)
	photo.gallery.update_pointer("left_hand", ray_origin, (first.pose.origin - ray_origin).normalized())
	var pointed: Image = await frame("05b-fragment-targeted")
	check(pointed.get_data() != memories.get_data() and photo.gallery._pointers.left_hand.dot.visible, "Targeted fragment renders a traced rim and pointer endpoint")
	photo.gallery.cancel_pointer("left_hand"); photo.gallery._refresh_visibility()
	var polygon := PackedVector2Array(first.shape)
	var corner := Vector2.ZERO
	for point in [Vector2(-0.48,0.48),Vector2(0.48,0.48),Vector2(0.48,-0.48),Vector2(-0.48,-0.48)]:
		if not Geometry2D.is_point_in_polygon(point, polygon): corner = point; break
	check(corner != Vector2.ZERO, "Fixture probes an actual missing corner of the fragment")
	# Isolate the silhouette probe so another randomized background memory cannot cover it.
	for index in photo.gallery.cards:
		if index == 0: continue
		var card: Dictionary = photo.gallery.cards[index]
		card.node.visible = false; card.rim.visible = false; card.echo.visible = false
	var isolated: Image = await frame("05c-fragment-silhouette")
	var pixel: Vector2 = camera.unproject_position(first.pose * Vector3(corner.x * first.size.x, corner.y * first.size.y, 0))
	if Rect2(Vector2.ZERO, Vector2(viewport.size)).has_point(pixel):
		var color := isolated.get_pixelv(Vector2i(pixel))
		check(maxf(color.r, maxf(color.g, color.b)) < 0.25, "Fragment mesh leaves its clipped corner as background")
	photo.gallery._refresh_visibility()
	photo.gallery.activate(0); photo.gallery._process(0.17); await frame("06-fragment-opening")
	await expanded()
	var opened: Image = await frame("07-fragment-complete")
	check(photo.panel.visible and opened.get_pixel(640, 360).r > 0.5, "Open fragment exposes the full photo at eye height")
	await foreground_overlap(opened,"07-fragments")
	photo.gallery.return_focus(); photo.gallery._process(0.17); await frame("08-fragment-returning")
	photo.gallery._process(1.0)
	var returned: Image = await frame("09-fragments-restored")
	check(returned.get_data() == memories.get_data(), "Return restores the exact rendered scene, including crop and other fragments")
	check(photo.gallery.shuffle_fragments(), "Rendered memory batch can be exchanged")
	photo.gallery._process(0.11); var fading: Image = await frame("09b-fragments-fading")
	check(fading.get_data() != returned.get_data(), "Memory swap has a visible disappearance transition")
	photo.gallery._process(0.12); await previews(); photo.gallery._process(0.15); await frame("09c-fragments-appearing")
	photo.gallery._process(1); await frame("09d-fragments-new-batch")
	camera.rotation.y = PI
	await frame("10-fragments-rear"); camera.rotation.y = 0
	var menu := Menu.new(); menu.state_provider = photo.snapshot; menu.queue_provider = func(): return photo.queue
	viewport.add_child(menu); menu.global_position = Vector3(0, 1.15, -1.5)
	menu.toggle(); menu._activate(menu.PHOTO_LAYOUT); await frame("11-layout-menu")
	menu._activate(menu.PHOTO_LAYOUT_BASE + 2); await frame("11b-wall-rows-menu")
	check(menu._buttons.filter(func(button): return button.target > menu.PHOTO_WALL_ROWS and button.target <= menu.PHOTO_WALL_ROWS + 3).size() == 3, "Wall row sub-menu renders all three choices")
	photo.queue_free(); menu.queue_free(); await process_frame; viewport.queue_free()
	for failure in failures: push_error(failure)
	print("Photo layout render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func side_separation() -> void:
	var saved_pose: Transform3D = photo.flat_pose
	var saved_distance: float = photo.screen_distance
	var sky := Image.new()
	if sky.load("res://backgrounds/belfast_sunset_puresky.jpg") == OK:
		sky.resize(960,480,Image.INTERPOLATE_LANCZOS)
		var texture := ImageTexture.create_from_image(sky)
		photo.material.set_shader_parameter("photo_texture",texture)
		photo.set_screen_scale(1.3); camera.fov = 90
		await previews()
		for card in photo.gallery.cards.values(): card.node.material_override.set_shader_parameter("picture",texture)
		photo.gallery.update_pointer("right_hand",camera.global_position,(photo.gallery.cards[2].pose.origin-camera.global_position).normalized())
		await frame("demo-sides-whole-layout")
		photo.gallery.cancel_pointer("right_hand"); photo.gallery._refresh_visibility()
		photo.material.set_shader_parameter("photo_texture",photo._texture)
		photo.gallery._refresh_textures(); camera.fov = 70
	for values in [Vector2(3,3),Vector2(3,.7)]:
		photo.set_screen_scale(values.x); photo.set_screen_distance(values.y)
		photo.set_flat_world_pose(Transform3D(Basis.IDENTITY,camera.global_position+Vector3(0,0,-values.y)))
		await previews()
		var main_frame: Transform3D = photo.global_transform * photo.flat_pose
		var edge: Vector3 = photo.screen_corner(1)
		for index in photo.gallery.cards:
			var card: Dictionary = photo.gallery.cards[index]
			var local: Transform3D = photo.gallery.anchor.affine_inverse() * card.pose
			var half := atan(card.size.x*.5/Vector2(local.origin.x,local.origin.z).length())
			check(absf(atan2(local.origin.x,-local.origin.z))-half > atan2(absf(edge.x),photo.screen_distance-edge.z),"Zoomed/near photo and every thumbnail have a gap in the user's view")
			check(photo.gallery.ray_hit(camera.global_position,(card.pose.origin-camera.global_position).normalized()).get("index",-1)==index,"Every zoomed/near side thumbnail remains independently clickable")
		var target: Dictionary = photo.gallery.cards[2]
		camera.look_at(target.pose.origin,Vector3.UP)
		var prefix := "demo-sides-enlarged" if values.y>1 else "demo-sides-near"
		var together: Image = await frame(prefix)
		var pixel := Vector2i(camera.unproject_position(target.pose.origin))
		photo.panel.visible = false
		var without_main: Image = await frame(prefix+"-without-main")
		check(together.get_pixelv(pixel).is_equal_approx(without_main.get_pixelv(pixel)),"The main photo does not cover the side preview in actual rendered pixels")
		photo.panel.visible = true
		for card in photo.gallery.cards.values(): card.node.visible = false; card.rim.visible = false; card.echo.visible = false
		var main_only: Image = await frame(prefix+"-main-only")
		var near_edge: Vector3 = main_frame * Vector3(edge.x*.92,0,edge.z*.9)
		var main_pixel := Vector2i(camera.unproject_position(near_edge))
		check(together.get_pixelv(main_pixel).is_equal_approx(main_only.get_pixelv(main_pixel)),"The side previews do not cover the main photo in actual rendered pixels")
		photo.gallery._refresh_visibility()
		var before: Transform3D = photo.flat_pose
		photo.gallery.activate(2)
		var deadline := Time.get_ticks_msec()+5000
		while photo.loading and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
		photo.finish_transition(); await previews()
		check(photo.index==2 and photo.flat_pose.is_equal_approx(before),"A side thumbnail switches the photo without moving the main viewing position")
		photo.gallery.activate(0)
		deadline = Time.get_ticks_msec()+5000
		while photo.loading and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
		photo.finish_transition(); await previews()
		camera.rotation = Vector3.ZERO
	photo.set_screen_scale(1); photo.set_screen_distance(saved_distance); photo.set_flat_world_pose(photo.global_transform*saved_pose)
	await previews()

func wall_feather() -> void:
	var card: Dictionary = photo.gallery.cards[0]
	for index in photo.gallery.cards:
		if index != 0: photo.gallery.cards[index].node.visible = false
	var feathered: Image = await frame("03d-wall-soft-edge")
	var feather: Vector2 = card.node.material_override.get_shader_parameter("edge_feather")
	card.node.material_override.set_shader_parameter("edge_feather",Vector2.ZERO)
	var hard: Image = await frame("03e-wall-hard-edge-reference")
	check(feathered.get_pixel(640,360) == hard.get_pixel(640,360), "Wall feathering retains the original photo centre")
	var background := Vector3(.012,.025,.035)
	for local in [Vector3(-card.size.x*.5+.025,0,0),Vector3(card.size.x*.5-.025,0,0),Vector3(0,card.size.y*.5-.025,0),Vector3(0,-card.size.y*.5+.025,0)]:
		var pixel := Vector2i(camera.unproject_position(card.pose * local))
		var soft := feathered.get_pixelv(pixel); var sharp := hard.get_pixelv(pixel)
		check(Vector3(soft.r,soft.g,soft.b).distance_to(background) < Vector3(sharp.r,sharp.g,sharp.b).distance_to(background)*.85, "Each wall edge fades into the environment in actual rendered pixels")
	card.node.material_override.set_shader_parameter("edge_feather",feather)
	photo.gallery._refresh_visibility()
	photo.gallery.update_pointer("left_hand",camera.global_position,(card.pose.origin-camera.global_position).normalized())
	check(card.rim.visible and photo.gallery.cards.values().filter(func(item): return item.rim.visible).size() == 1, "Only the pointed wall photo shows its selection rim")
	await frame("03f-wall-selected")
	photo.gallery.cancel_pointer("left_hand"); photo.gallery._refresh_visibility()

func foreground_overlap(reference: Image, prefix: String) -> void:
	# A moved viewing position can put an original album card physically in front of the full photo.
	# It must still stay behind in both shader and OpenXR underlay/eye-buffer rendering.
	var foreground_index: int = photo.gallery.cards.keys().filter(func(index):return index != photo.gallery.focus)[0]
	var foreground: Dictionary = photo.gallery.cards[foreground_index]
	var green := Image.create(32,32,false,Image.FORMAT_RGB8); green.fill(Color.GREEN)
	foreground.node.material_override.set_shader_parameter("picture",ImageTexture.create_from_image(green))
	foreground.node.material_override.set_shader_parameter("has_picture",true)
	foreground.node.material_override.set_shader_parameter("geometry",0)
	var position: Transform3D = photo.gallery.focus_pose
	position.origin = camera.global_position+(position.origin-camera.global_position).normalized()*.7
	foreground.node.global_transform = position; photo.gallery._refresh_visibility()
	var overlapped: Image = await frame(prefix+"-shader-covered")
	check(overlapped.get_pixel(640,360).is_equal_approx(reference.get_pixel(640,360)), "A physically nearer album card cannot penetrate the shader photo")
	check(photo.gallery.ray_hit(camera.global_position,(photo.gallery.focus_pose.origin-camera.global_position).normalized()).get("index") == photo.gallery.focus, "Clicking the full photo cannot select an overlapping background card")
	viewport.transparent_bg = true
	photo.set_process(false) # Desktop's unavailable compositor must not hide the simulated hole.
	var cut := Vector4(.03,.03,.94,.94)
	photo._hole.mesh = photo.panel.mesh; photo._hole.transform = photo.panel.transform
	photo._hole_material.set_shader_parameter("keep_rect",cut); photo._hole.visible = true
	photo.material.set_shader_parameter("layer_cut",cut)
	var cleared: Image = await frame(prefix+"-compositor-hole")
	check(cleared.get_pixel(640,360).a<.01 and maxf(cleared.get_pixel(640,360).r,cleared.get_pixel(640,360).g)<.01, "Compositor hole clears the foreground card after it renders, leaving the underlay photo unobstructed")
	photo._hole.visible = false; photo.material.set_shader_parameter("layer_cut",Vector4.ZERO)
	viewport.transparent_bg = false; foreground.node.global_transform = foreground.pose
	photo.set_process(true)
	photo.gallery._refresh_textures(); photo.gallery._refresh_visibility()
