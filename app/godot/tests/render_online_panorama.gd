extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Tiles := preload("res://scripts/panorama_tiles.gd")
const Online := preload("res://scripts/online_panorama_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
const Host := preload("res://tests/test_online_panorama.gd").Host
var viewport: SubViewport
var failures: Array[String]=[]
var output:=ProjectSettings.globalize_path("res://../../build/output/online-panorama")
func _initialize() -> void: call_deferred("_run")
func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
func check_green(image: Image, label: String) -> void:
	var pixel:=image.get_pixel(640,400)
	if pixel.g<0.8 or pixel.r>0.1: failures.append(label+": "+str(pixel))
func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new(); viewport.size=Vector2i(1280,800)
	viewport.own_world_3d=true; viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera:=Camera3D.new(); camera.fov=75; viewport.add_child(camera)
	var menu:=Menu.new(); viewport.add_child(menu); menu.position=Vector3(0,0,-1.7); menu.visible=true
	menu.online.platform=Host.new(); I18n.use("zh"); menu.online.open()
	var directory: Image=await frame(); directory.save_png(output.path_join("directory-zh.png"))
	menu.online.activate(Online.BASE+3)
	var chinese: Image=await frame(); chinese.save_png(output.path_join("directory-chinese.png"))
	menu.online.activate(Online.BASE+13)
	menu.online.platform.report={"download":{"state":"ready","width":8192,"height":4096}}
	menu.online.data=menu.online.platform.report
	menu.refresh()
	var browser: Image=await frame(); browser.save_png(output.path_join("browser-ready.png"))
	menu.free()
	# The red base intentionally differs from the original green region: rendering must use the tile.
	var photo:=Photo.new(); photo.history_enabled=false; viewport.add_child(photo); photo.view_camera=camera
	var base:=Image.create(512,256,false,Image.FORMAT_RGB8); base.fill(Color.RED)
	photo._texture=ImageTexture.create_from_image(base); photo._size=Vector2(512,256)
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._detail_material.set_shader_parameter("photo_texture",photo._texture)
	photo.set_projection(3); photo.panel.visible=true
	photo.panorama_tiles.set_process(false); photo.panorama_tiles.visible=true
	photo.panorama_tiles.dimensions=Vector2i(20778,10389)
	var cell:=Vector2i(10,5); var rect:=Tiles.core_rect(Vector2i(20778,10389),cell).grow(2)
	var original:=Image.create(rect.size.x,rect.size.y,false,Image.FORMAT_RGB8); original.fill(Color.GREEN); original.generate_mipmaps()
	photo.panorama_tiles._install(cell,original,{"x":rect.position.x,"y":rect.position.y,"width":rect.size.x,"height":rect.size.y})
	var panorama: Image=await frame(); panorama.save_png(output.path_join("original-tile.png")); check_green(panorama,"Sphere must show original pixels over red preview")
	photo.inspect=true; photo._detail_direction=Vector3.FORWARD; photo._update_inspect()
	# Isolate the magnifier at screen centre so the same pixel oracle verifies its sampling path.
	photo._detail.transform=Transform3D(Basis.IDENTITY,Vector3(0,0,-1.4))
	photo.panorama_tiles._update_materials()
	var detail: Image=await frame(); detail.save_png(output.path_join("original-magnifier.png")); check_green(detail,"Magnifier must use original tile rather than red preview")
	photo.panorama_tiles.clear(); photo.inspect=false; photo._detail.visible=false
	var cleared: Image=await frame(); cleared.save_png(output.path_join("cleared.png"))
	if cleared.get_pixel(640,400).r<0.8: failures.append("Clearing regions must restore the red base without stale tiles")
	photo.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Online panorama render: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
