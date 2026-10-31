extends SceneTree
const Fixture:=preload("res://tests/test_photo_spatial_controls.gd")
const Menu:=preload("res://scripts/photo_menu.gd")
const I18n:=preload("res://scripts/i18n.gd")
var checks:=0
var failures: Array[String]=[]
var output:="res://../../build/output/photo-spatial-controls/previews"

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var view:=SubViewport.new(); view.size=Vector2i(1100,950); view.own_world_3d=true
	view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; view.msaa_3d=Viewport.MSAA_2X; root.add_child(view)
	var world:=WorldEnvironment.new(); var environment:=Environment.new()
	environment.background_mode=Environment.BG_COLOR; environment.background_color=Color("10151c")
	world.environment=environment; view.add_child(world)
	var camera:=Camera3D.new(); camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=1.3; camera.position=Vector3(0,.25,2); view.add_child(camera); camera.current=true
	for lang in ["en","zh","zh_Hant","ja"]:
		I18n.use(lang)
		for entry in [["converted-spatial",false,true],["converted-stereo",false,false],["apple-spatial",true,true],["apple-static",true,false]]:
			var state:=Fixture.state(entry[1],entry[2])
			var menu:=Menu.new(); view.add_child(menu); menu.position=Vector3.ZERO; menu.set_process(false)
			menu.state_provider=func():return state
			menu.visible=true; menu._depth_open=true; menu.refresh()
			var has_rail: bool=not entry[1] and not entry[2]
			check(is_instance_valid(menu._depth_knob)==has_rail,"Rendered rail visibility: %s/%s"%[lang,entry[0]])
			var switches:=menu._buttons.filter(func(b):return b.target in [Menu.PHOTO_SPATIAL,Menu.PHOTO_STATIC])
			check(switches.size()==2,"Both photo sources have two viewing-mode radio rows")
			check(switches.filter(func(b):return b.get("photo_mode_selected",false)).size()==1,"Exactly one rendered viewing mode is selected")
			check(menu._buttons.any(func(b):return b.target==Menu.PHOTO_DEPTH and b.enabled),"2D-to-3D viewing entry is enabled for both photo sources")
			var icon: Dictionary=menu._buttons.filter(func(b):return b.target==Menu.PHOTO_DEPTH)[0]
			var lower_row: Dictionary=switches.filter(func(b):return b.target==Menu.PHOTO_STATIC)[0]
			var mode_bottom: float=lower_row.rect.position.y-.0275
			var popup_bottom: float=menu._depth_span().x-.095 if has_rail else mode_bottom
			var gap: float=popup_bottom-icon.rect.end.y
			check(gap>=0 and gap<.02,"Popup stays within 2cm of its source icon in both modes")
			if has_rail:
				check(mode_bottom>menu._depth_span().y+.095,"Viewing mode choices sit above the slider panel without overlapping")
			for button in switches:
				var caption: Label3D=button.node.get_child(0)
				check(caption.text.length()>0 and caption.font_size==menu.TEXT_BODY*menu.TEXT_RASTER_SCALE,"Top button uses the shared body size")
				check(button.rect.size.is_equal_approx(Vector2(.29,.065)) and caption.horizontal_alignment==HORIZONTAL_ALIGNMENT_LEFT,"Mode option follows the two-row reference layout")
				var lower:=camera.unproject_position(button.node.to_global(Vector3(-.145,-.033,0)))
				var upper:=camera.unproject_position(button.node.to_global(Vector3(.145,.033,0)))
				check(lower.x>=0 and upper.x<view.size.x and upper.y>=0 and lower.y<view.size.y,"Switch fits the viewport")
			if has_rail:
				check(menu._buttons.any(func(b):return b.target==Menu.DEPTH_OFF),"Original-mode 3D Off is present")
			else: check(menu._buttons.all(func(b):return b.target!=Menu.DEPTH_OFF),"Spatial/native modes contain no inactive depth Off control")
			for frame in 3: await RenderingServer.frame_post_draw
			view.get_texture().get_image().save_png(output.path_join(lang+"-"+entry[0]+".png"))
			menu.free()
	view.free(); await process_frame
	for failure in failures: push_error(failure)
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"layouts":16,"scope":"Desktop OpenGL production PhotoMenu, not headset ray/comfort validation"},"\t"))
	print("Photo spatial controls render: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
