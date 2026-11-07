extends SceneTree
## Render the projection buffer, including the real browser frame and HD alpha holes.
## A clear pixel here exposes the independent XR popup; raw capture screenshots alone
## cannot detect a frame painted back over it.
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func _initialize() -> void: run.call_deferred()
func settle(capture: Node) -> void:
	for frame in 8:
		capture.update(); await process_frame; await RenderingServer.frame_post_draw
func alpha_at(viewport: SubViewport, camera: Camera3D, point: Vector3) -> float:
	var pixel := Vector2i(camera.unproject_position(point))
	return viewport.get_texture().get_image().get_pixelv(pixel).a
func run() -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(1200,1200)
	viewport.transparent_bg = true; viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var world := Node3D.new(); viewport.add_child(world)
	var camera := Camera3D.new(); world.add_child(camera)
	camera.environment = Capture.clear_environment(); camera.fov = 65
	var menu := Menu.new(); world.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB); menu.set_process(false)
	var capture := Capture.new(); world.add_child(capture)
	capture.configure(world,camera,null,[menu],false,true); capture.set_process(false)
	var browser: RefCounted = menu.web_browser; browser.window_created = capture.register_companion
	browser.open("https://example.com/page"); browser.tick()
	var host: Node3D = browser.windows[1]; host.set_process(false)
	host.reparent(world)
	capture.register_companion(host)
	host.global_transform = Transform3D(Basis.IDENTITY,Vector3(-.13,.2,-1.5))
	var footer: Node3D = host.effect_controls
	host.depth.enabled = true; host.depth.state = "ready"; host.refresh()
	footer.sync(1000); footer.visible = true; footer.set_strength_open(true)
	for boosted in [false,true]:
		footer.boosted = boosted; footer.refresh(); capture.invalidate(); await settle(capture)
		# The real lower frame intersects the rail at local y=.27 (0.28 below page).
		var point: Vector3 = host.to_global(Vector3(host.CENTRE.x + footer.SLIDER_X,host.page_rect().position.y-.01,0))
		var outside: Vector3 = point + host.global_basis.x*.18
		var popup: Dictionary = {}
		for slot in capture.slots:
			if slot.used and slot.nodes.has(footer.knob): popup = slot; break
		check(not popup.is_empty(),"Strength popup uses the real HD capture")
		if popup.is_empty(): continue
		for offset in [Vector3.ZERO,Vector3(.23,-.14,.25)]:
			camera.position = offset; camera.look_at(point)
			popup.hole.visible = false; await settle(capture)
			check(alpha_at(viewport,camera,point)>.9,"Fixture renders an opaque browser frame behind the rail")
			popup.hole.visible = true; await settle(capture)
			var covered := alpha_at(viewport,camera,point)
			print("Strength/frame projection alpha (boost=%s, offset=%s): %.4f"%[boosted,offset,covered])
			check(covered<.02,"HD strength popup clears the lower frame from the eye buffer")
			check(alpha_at(viewport,camera,outside)>.9,"Frame outside the popup remains intact")
			var ray := point + (camera.global_position-point).normalized()*.5
			var hit: Dictionary = host.ray_hit(ray,point-ray)
			check(hit.get("footer",false) and hit.get("target",-1)==footer.STRENGTH,"The exposed rail receives the trigger over the frame")
	footer.set_strength_open(false); capture.update()
	check(capture.slots.filter(func(s): return s.used).all(func(s): return s.hole.material_override.render_priority==Capture.HOLE_PRIORITY),"Closing the popup resets reused capture holes to the ordinary menu order")
	viewport.free(); platform.free(); await process_frame
	print("Browser strength overlap: %d checks, %d failures"%[checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
