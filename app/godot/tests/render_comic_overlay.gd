extends SceneTree
## Desktop rendering regression: Chinese OCR rectangles -> longer English, then ray peek.
const Overlay := preload("res://scripts/comic_translation_overlay.gd")
const Fonts := preload("res://scripts/ray_menu.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/comic-overlay-fix-20261025")
var failures := []
class SourceCanvas extends Control:
	var boxes := [Rect2(80,100,150,260), Rect2(490,100,340,145), Rect2(530,450,320,200)]
	var texts := ["等一下！\n我们现在\n逃走的话，\n以后就没脸\n面对朋友了。", "你真的觉得这样就可以了吗？\n我可不会就这么放弃的！", "为什么我的心跳突然变快了？\n只是看着你，就说不出话来。"]
	func _draw() -> void:
		draw_rect(Rect2(0,0,1000,750), Color("f1ede5"))
		draw_rect(Rect2(20,20,360,710), Color("abc1ce"))
		draw_rect(Rect2(420,20,560,370), Color("d1c1a2"))
		draw_rect(Rect2(420,410,560,320), Color("afc7ba"))
		for i in boxes.size():
			draw_rect(boxes[i].grow(20),Color.WHITE)
			var text := Overlay.paragraph(texts[i],Fonts.ui_font(),25,boxes[i].size.x,"zh")
			text.draw(get_canvas_item(),boxes[i].position,Color.BLACK)
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message); push_error(message)
func capture(view: SubViewport, name: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image
func opaque(image: Image, rect: Rect2, alpha: float) -> bool:
	for y in range(ceili(rect.position.y),floori(rect.end.y)):
		for x in range(ceili(rect.position.x),floori(rect.end.x)):
			if absf(image.get_pixel(x,y).a-alpha) > .01: return false
	return true
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var source := SubViewport.new(); source.size = Vector2i(1000,750); source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(source)
	source.add_child(SourceCanvas.new())
	var picture := await capture(source,"source-zh")
	var view := SubViewport.new(); view.size = Vector2i(1400,1100); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.position.z = 3.1; camera.fov = 50; view.add_child(camera)
	var photo := preload("res://scripts/photo_display.gd").new(); view.add_child(photo); photo.set_process(false)
	photo._size = Vector2(1000,750); photo.screen_curve = 0; photo._texture = ImageTexture.create_from_image(picture)
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._apply_geometry(); photo.panel.position = Vector3.ZERO; photo.panel.visible = true
	await capture(view,"original")
	var bounds := [[80,100,230,360],[90,100,430,245],[130,450,450,650]]
	var english := ["Wait! If we run away now, we will never be able to face our friends again.", "Do you really think this is enough?\nI am not going to give up that easily!", "Why is my heart suddenly beating so fast? Just looking at you leaves me speechless."]
	var entries := []; var cache := {}
	for i in 3:
		entries.append({"key":str(i),"page":0 if i==0 else 1,"id":i,"target":"en","block":{"rect":bounds[i],"hit_rect":[0,0,400,750],"hit_rows":[]},"size":Vector2(400 if i==0 else 600,750),"region":Rect2(0 if i==0 else .4,0,.4 if i==0 else .6,1)})
		cache[str(i)] = {"text":english[i],"provider":"Bing"}
	var overlay := Overlay.new(photo); overlay.update(entries,cache,1.0)
	await capture(view,"translated-en")
	var mask := await capture(overlay.viewport,"overlay-en")
	for item: Dictionary in overlay.canvas.items:
		check(opaque(mask,item.cover,1.0),"Every pixel of the OCR rectangle is opaque: " + item.id)
		check(item.cover.encloses(Rect2(item.position,item.size)),"Complete paragraph lies inside its opaque mask: " + item.id)
	check(overlay.shown == 3,"All translated bubbles are visible")
	overlay.peek([Vector2(.15,.25)])
	await capture(view,"hover-original")
	mask = await capture(overlay.viewport,"overlay-hover")
	for item: Dictionary in overlay.canvas.items:
		check(opaque(mask,item.cover,0.0 if item.id == "0:0" else 1.0),"Ray peek removes exactly the selected translation and mask: " + item.id)
	overlay.peek([])
	var restored := await capture(view,"hover-exit")
	var translated := Image.load_from_file(output.path_join("translated-en.png"))
	check(restored.get_data() == translated.get_data(),"Leaving the bubble restores the identical translated image")
	check(mask.get_pixelv(Vector2i(overlay.canvas.items[1].cover.position + Vector2(3,3))).r > .95,"Default mask has a white background")
	overlay.update(entries,cache,1.0,"dark"); await capture(view,"translated-dark")
	var dark_mask := await capture(overlay.viewport,"overlay-dark")
	check(dark_mask.get_pixelv(Vector2i(overlay.canvas.items[1].cover.position + Vector2(3,3))).r < .2,"Optional dark background is drawn")
	overlay.update(entries,cache,1.0,"light")
	photo.screen_curve = .6; photo._shape_screen(); overlay.sync(true)
	await capture(view,"curved-en")
	camera.position = Vector3(.25,.05,2.7); camera.look_at(Vector3.ZERO)
	await capture(view,"curved-oblique-en")
	# Match the XR eye buffer: transparent background, MSAA, a compositor hole,
	# and text touching the photograph's feathered outer rim.
	photo.screen_curve = 0; photo._shape_screen(); camera.position = Vector3(0,0,3.1); camera.rotation = Vector3.ZERO
	view.transparent_bg = true; view.msaa_3d = Viewport.MSAA_4X
	var edge_boxes := [Rect2(0,650,200,100),Rect2(800,0,200,100),Rect2(0,200,200,100),Rect2(800,450,200,100)]
	entries.clear(); cache.clear()
	for i in edge_boxes.size():
		var box: Rect2 = edge_boxes[i]
		entries.append({"key":str(i),"id":i,"page":0,"target":"en","block":{"rect":[box.position.x,box.position.y,box.end.x,box.end.y]},"size":Vector2(1000,750),"region":Rect2(0,0,1,1)})
		cache[str(i)] = {"text":"Keep this whole text box opaque.","provider":"Bing"}
	overlay.update(entries,cache,1.0)
	var keep: Vector2 = Vector2.ONE * (photo.SOFT_EDGE_METRES + photo.LAYER_OVERLAP_METRES) / photo._flat.size
	var cut := Vector4(keep.x,keep.y,1-keep.x*2,1-keep.y*2)
	photo.material.set_shader_parameter("layer_cut",cut)
	photo._hole.mesh = photo.panel.mesh; photo._hole.transform = photo.panel.transform
	photo._hole_material.set_shader_parameter("keep_rect",cut); photo._hole.visible = true
	var edges := await capture(view,"edge-eye-buffer")
	var minimum := 1.0
	for box: Rect2 in edge_boxes:
		for y in range(4,int(box.size.y)-4,4):
			for x in range(4,int(box.size.x)-4,4):
				var uv := (box.position + Vector2(x,y))/Vector2(1000,750)
				var point := camera.unproject_position(photo.panel.to_global(Vector3((uv.x-.5)*photo._flat.size.x,(.5-uv.y)*photo._flat.size.y,0)))
				minimum = minf(minimum,edges.get_pixelv(Vector2i(point)).a)
	check(minimum > .99,"Photo edge translation remains opaque in the compositor eye buffer (minimum alpha %.3f)" % minimum)
	print("Edge eye-buffer minimum alpha: ",minimum)
	# Conversion completes while translation is already visible. Supply a synthetic
	# shifted stereo pair and exercise both eyes through the production photo shader.
	var pair := Image.create(2000,750,false,Image.FORMAT_RGBA8)
	pair.blit_rect(picture,Rect2i(0,0,985,750),Vector2i(15,0))
	pair.blit_rect(picture,Rect2i(15,0,985,750),Vector2i(1000,0))
	photo._stereo_texture = ImageTexture.create_from_image(pair)
	photo.depth_requested = true; photo.depth_enabled = true
	photo._apply_geometry(); photo.panel.position = Vector3.ZERO; overlay.sync(true)
	check(photo.material.get_shader_parameter("comic_overlay_enabled") == true,"Completing 3D conversion leaves translation active")
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		var stereo_frame := await capture(view,"edge-stereo-eye-%d" % eye)
		for box: Rect2 in edge_boxes:
			var uv := box.get_center()/Vector2(1000,750)
			var point := camera.unproject_position(photo.panel.to_global(Vector3((uv.x-.5)*photo._flat.size.x,(.5-uv.y)*photo._flat.size.y,0)))
			check(stereo_frame.get_pixelv(Vector2i(point)).a > .99,"Each eye keeps the translation opaque after 3D conversion")
	mask = await capture(overlay.viewport,"edge-stereo-mask")
	for item: Dictionary in overlay.canvas.items:
		check(opaque(mask,item.mask,1.0),"Stereo margin covers both eyes' displaced original ink: " + item.id)
	photo.depth_requested = false; photo.depth_enabled = false
	photo._apply_geometry(); overlay.sync(true)
	check(photo.material.get_shader_parameter("comic_overlay_enabled") == true,"Returning to 2D keeps translation active")
	view.transparent_bg = false; photo._hole.visible = false
	photo.material.set_shader_parameter("layer_cut",Vector4.ZERO); photo.panel.position = Vector3.ZERO
	var multilingual := ["انتظر! لم ننته من الحديث بعد.","صبر کن! هنوز حرفمان تمام نشده است.","잠깐만! 아직 이야기가 끝나지 않았어."]
	var codes := ["ar","fa","ko"]
	for i in 3:
		entries[i].block.rect = [100,60+i*220,900,230+i*220]
		entries[i].target = codes[i]; cache[str(i)].text = multilingual[i]
	entries.resize(3); overlay.update(entries,cache,1.0)
	await capture(view,"multilingual-light")
	print("Comic overlay render: 3 English bubbles, full mask alpha / layout / selective hover / restoration; %d failures" % failures.size())
	overlay.close(); photo.free(); source.free(); view.free(); quit(0 if failures.is_empty() else 1)
