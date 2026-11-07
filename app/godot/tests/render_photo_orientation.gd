extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Rotation := preload("res://scripts/screen_rotation_control.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output:=ProjectSettings.globalize_path("res://../../build/output/photo-orientation/preview")
var view: SubViewport
var count:=0
var failures: Array[String]=[]

func _initialize() -> void: run.call_deferred()
func capture(name: String) -> void:
	await process_frame
	for frame in 3: await RenderingServer.frame_post_draw
	var pixels:=view.get_texture().get_image()
	if pixels.save_png(output.path_join(name+".png"))!=OK: failures.append("Could not save "+name)
	count+=1

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view=SubViewport.new(); view.size=Vector2i(1440,1100); view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera:=Camera3D.new(); camera.position=Vector3(0,1.6,0); camera.fov=70; view.add_child(camera)
	var image:=Image.create(640,400,false,Image.FORMAT_RGBA8)
	for y in 400:
		for x in 640:
			var color:=Color(.08,.30,.38).lerp(Color(.13,.48,.54),y/400.0)
			if x%80<3 or y%80<3: color=Color(.65,.86,.90)
			if y<16: color=Color(.98,.55,.20)
			if x<16: color=Color(.23,.75,.45)
			image.set_pixel(x,y,color)
	var photo:=Photo.new(); view.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	photo.view_camera=camera; photo.local_uri="file:///rotation-preview.png"; photo._size=Vector2(640,400)
	photo._texture=ImageTexture.create_from_image(image); photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo.set_flat_world_pose(Transform3D(Basis.IDENTITY,Vector3(0,1.6,-3)))
	photo._apply_geometry(); photo.set_screen_scale(.68); photo.panel.visible=true; photo.set_screen_curve(120.0)
	var rotation:=Rotation.new(); view.add_child(rotation)
	rotation.sync(photo,false); await capture("curve-0-idle")
	for angle in [0,90,180,270,45,132]:
		photo.set_screen_rotation(angle); rotation.sync(photo,true,angle in [45,132])
		await capture("curve-%d-hover"%angle)
	rotation.visible=false; photo.panel.visible=false
	var menu:=Menu.new(); view.add_child(menu); menu.set_process(false)
	var state: Dictionary={"has_image":true,"geometry":0,"count":12,"index":0,"ground_vertical":false,"screen_curve":.7}
	menu.state_provider=func(): return state.duplicate()
	menu.position=Vector3(0,1.95,-1.9); menu.section=1; menu.visible=true
	for language in ["zh","zh_Hant","en","ja"]:
		for enabled in [false,true]:
			I18n.use(language); state.ground_vertical=enabled; menu.refresh()
			var button: Dictionary=menu._buttons.filter(func(b): return b.target==(Menu.PHOTO_GROUND_VERTICAL_ON if enabled else Menu.PHOTO_GROUND_VERTICAL_OFF))[0]
			var label:=button.node.get_child(0) as Label3D
			var width: float=menu.ui_font().get_string_size(label.text,HORIZONTAL_ALIGNMENT_LEFT,-1,label.font_size).x*label.pixel_size
			if width>button.rect.size.x-.025: failures.append("Toggle label overflow "+language)
			var row: Rect2=button.rect
			var bounds: Vector2=menu._backdrop.mesh.size/2
			if row.position.y<menu._backdrop.position.y-bounds.y or row.end.y>menu._backdrop.position.y+bounds.y: failures.append("Toggle outside settings panel")
			await capture("settings-%s-%s"%[language,"on" if enabled else "off"])
			if language=="zh":
				menu.update_pointer("mouse",camera.global_position,(button.node.global_position-camera.global_position).normalized(),true)
				menu._hover["mouse"]=Menu.PHOTO_GROUND_VERTICAL_ON if enabled else Menu.PHOTO_GROUND_VERTICAL_OFF; menu._update_tooltip()
				await capture("tooltip-%s"%("on" if enabled else "off"))
	view.free()
	for failure in failures: push_error(failure)
	print("Photo orientation render: %d images, %d failures"%[count,failures.size()])
	quit(0 if failures.is_empty() else 1)
