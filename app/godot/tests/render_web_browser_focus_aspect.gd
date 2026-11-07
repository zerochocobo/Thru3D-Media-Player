extends SceneTree
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_windows.gd")
const Focus:=preload("res://scripts/web_browser_focus.gd")
var output:=ProjectSettings.globalize_path("res://../../build/output/browser-focus-aspect/preview")
var view: SubViewport
var camera: Camera3D
var image: Image
var checks:=0
var failures: Array[String]=[]
var count:=0
func _initialize() -> void: run.call_deferred()
func point(page: Dictionary,uv: Vector2,z: float=0) -> Vector3:
	return page.pose*Vector3((uv.x-.5)*page.size.x,(.5-uv.y)*page.size.y,z)
func signature(color: Color) -> Vector3i: return Vector3i(int(color.r>.5),int(color.g>.5),int(color.b>.5))
func capture(host: Node3D,texture: ImageTexture,shader: Shader,name: String,crop: Rect2,samples: Array) -> void:
	# The desktop fixture supplies a synthetic webpage on the production page hit
	# mesh; real focus geometry, feedback, gestures and source crop remain in use.
	var tile: Node3D=host._buttons.filter(func(button):return button.target==host.WEB)[0].node
	var material:=ShaderMaterial.new();material.shader=shader
	material.set_shader_parameter("page",texture);material.set_shader_parameter("crop",Vector4(crop.position.x,crop.position.y,crop.size.x,crop.size.y))
	tile.material_override=material;host._update_feedback()
	for frame in 3:await process_frame;await RenderingServer.frame_post_draw
	var pixels:=view.get_texture().get_image();pixels.save_png(output.path_join(name+".png"));count+=1
	var page: Dictionary=host.page_layout()
	for pair in samples:
		var screen:=Vector2i(camera.unproject_position(point(page,pair[0])))
		var source: Vector2i=Vector2i(Vector2(image.get_size())*pair[1])
		checks+=1
		if signature(pixels.get_pixelv(screen))!=signature(image.get_pixelv(source)):failures.append("Different source content "+name+" "+str(pair))
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view=SubViewport.new();view.size=Vector2i(1440,1100);view.own_world_3d=true;view.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(view)
	camera=Camera3D.new();camera.fov=65;view.add_child(camera)
	image=Image.create(1000,800,false,Image.FORMAT_RGBA8)
	var palette: Array[Color]=[Color.RED,Color.GREEN,Color.BLUE,Color.CYAN,Color.MAGENTA,Color.YELLOW]
	for y in 8:
		for x in 10:image.fill_rect(Rect2i(x*100,y*100,100,100),palette[posmod(x+2*y,6)])
	var texture:=ImageTexture.create_from_image(image)
	var shader:=Shader.new();shader.code="shader_type spatial; render_mode unshaded,cull_disabled; uniform sampler2D page:source_color,filter_nearest; uniform vec4 crop; void fragment(){ALBEDO=texture(page,crop.xy+UV*crop.zw).rgb;}"
	var platform:=Fixture.Platform.new();platform.browser.merge({"tab_id":1,"navigation":1,"start_page":false,"loading":false},true)
	var menu:=Menu.new();view.add_child(menu);menu.attach_platform(platform);menu.toggle();menu.set_process(false);menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted=menu.web_browser;browser.open();browser.tick()
	var host: Node3D=browser.windows[1];host.reparent(view);host.set_process(false)
	host.global_transform=Transform3D(Basis.IDENTITY,Vector3(-.13,0,-2))
	browser.cinema_provider=func():return {"position":[0,3,-12],"width":10.0,"height":5.625}
	for cinema in [false,true]:
		for index in 3:
			host.page_size=[Vector2(1.44,.9),Vector2(2.4,.65),Vector2(1.44,1.8)][index]
			host.set_mode("cinema" if cinema else "floating");host.refresh()
			if host.is_focused():host.toggle_focus()
			host.toggle_focus()
			var full: Dictionary=host.full_page_layout()
			camera.global_transform=full.pose;camera.global_position+=full.pose.basis.z*maxf(full.size.x,full.size.y)*1.2
			var a:=Vector2(.2,.15);var b:=Vector2(.7,.35);var direction: Vector3=-full.pose.basis.z
			host.press_pointer("right",point(full,a,.5),direction,true);host.update_pointer("right",point(full,b,.5),direction,true)
			var selected: Rect2=host.selection
			var samples: Array=[]
			for uv in [Vector2(.13,.17),Vector2(.43,.59),Vector2(.81,.87)]:samples.append([Focus.map_point(uv,selected),Focus.map_point(uv,selected)])
			var name: String=("cinema" if cinema else "floating")+"-"+str(index)
			await capture(host,texture,shader,name+"-select",Focus.FULL,samples)
			host.release_pointer("right",point(full,b,.5),direction,true)
			samples=[]
			for uv in [Vector2(.13,.17),Vector2(.43,.59),Vector2(.81,.87)]:samples.append([uv,Focus.map_point(uv,selected)])
			await capture(host,texture,shader,name+"-focused",host.focus_crop(),samples)
	menu.free();platform.free();view.free()
	for failure in failures:push_error(failure)
	print("Browser focus render: %d checks, %d images, %d failures"%[checks,count,failures.size()])
	quit(0 if failures.is_empty() else 1)
