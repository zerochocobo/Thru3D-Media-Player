extends SceneTree
const Menu:=preload("res://scripts/photo_menu.gd")
const I18n:=preload("res://scripts/i18n.gd")
var output:=ProjectSettings.globalize_path("res://../../build/output/photo-autoplay/preview")
var view: SubViewport
var failures: Array[String]=[]
var count:=0
func _initialize() -> void: run.call_deferred()
func capture(name: String) -> void:
	for frame in 3: await process_frame; await RenderingServer.frame_post_draw
	var pixels:=view.get_texture().get_image()
	if pixels.save_png(output.path_join(name+".png"))!=OK:failures.append(name)
	var ink:=0
	for y in range(0,pixels.get_height(),4):
		for x in range(0,pixels.get_width(),4):
			var color:=pixels.get_pixel(x,y)
			if maxf(color.r,maxf(color.g,color.b))>.65:ink+=1
	if ink<20:failures.append("Blank UI capture "+name)
	count+=1
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var icon:=preload("res://scripts/menu_icons.gd").texture("photo_autoplay",256).get_image()
	if icon.save_png(output.path_join("autoplay-icon.png"))!=OK:failures.append("Icon save failed")
	var used:=icon.get_used_rect()
	if used.position.x<8 or used.position.y<8 or used.end.x>248 or used.end.y>248:failures.append("Clipped icon strokes")
	view=SubViewport.new();view.size=Vector2i(1440,1100);view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(view)
	var camera:=Camera3D.new();camera.fov=58;camera.position=Vector3(0,-.25,0);view.add_child(camera)
	var menu:=Menu.new();view.add_child(menu);menu.set_process(false);menu.position.z=-1.8
	var state: Dictionary={"title":"相册 · Photo album","has_image":true,"geometry":0,"count":12,"index":2,
		"can_previous":true,"can_next":true,"autoplay_enabled":false,"autoplay_interval":5.0,"screen_curve":30.0}
	menu.state_provider=func():return state.duplicate()
	menu.visible=true
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language);menu.section=0;state.autoplay_enabled=true;menu.refresh()
		await capture("bar-"+language+"-on")
		if language=="zh":
			state.autoplay_enabled=false;menu.refresh();await capture("bar-zh-off")
		for interval in [3,5,30]:
			menu.section=1;state.autoplay_interval=interval;menu.refresh()
			var target: int=menu.choices.targets.keys().filter(func(id):return menu.choices.targets[id].get("key")=="autoplay_interval" and menu.choices.targets[id].get("kind")=="slider")[0]
			var slider: Dictionary=menu.choices.sliders[target]
			if slider.span!=Vector3(3,30,1) or slider.label.text!=str(interval)+"s":failures.append("Wrong interval slider "+language)
			var half: Vector2=menu._backdrop.mesh.size/2
			for button in menu._buttons:
				if menu.choices.targets.get(button.target,{}).get("key")!="autoplay_interval":continue
				if button.rect.position.y<menu._backdrop.position.y-half.y or button.rect.end.x>half.x:failures.append("Slider outside settings "+language)
			await capture("settings-%s-%d"%[language,interval])
	menu.free();view.free()
	for failure in failures:push_error(failure)
	print("Photo autoplay render: %d images, %d failures"%[count,failures.size()])
	quit(0 if failures.is_empty() else 1)
