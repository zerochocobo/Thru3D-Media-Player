extends SceneTree
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_panel.gd")
const Capture:=preload("res://scripts/menu_composition.gd")
var checks:=0
var failures:Array[String]=[]
func check(value:bool,message:String)->void:
	checks+=1
	if not value:failures.append(message)
func slot_for(capture:Node,node:Node)->Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node):return slot
	return {}
func verify_hd(capture:Node,footer:Node3D,tag:String)->void:
	capture.update()
	var items:Array[Dictionary]=[]
	capture._gather(footer,items,capture._root_pose().affine_inverse(),false)
	var missing:=0
	for item in items:
		if item.shown and slot_for(capture,item.node).is_empty():missing+=1
	check(missing==0,tag+": every visible button, glyph, rail and tooltip has HD capture (%d missed)"%missing)
	var slots:Array=[]
	for item in items:
		if not item.shown:continue
		var slot:=slot_for(capture,item.node)
		if slot.is_empty() or slots.has(slot):continue
		slots.append(slot)
		check(float(slot.raw.size.x)/slot.layer.quad_size.x*footer.global_basis.get_scale().x>=900.0,tag+": logical control capture stays above 900 px/m")
	check(capture.slots.size()==Capture.MAX_GROUPS,tag+": reuses the existing fixed five XR providers")
func _initialize()->void:run.call_deferred()
func run()->void:
	await fixture(false)
	await fixture(true)
	print("Browser effect controls: %d checks, %d failures"%[checks,failures.size()])
	for failure in failures:push_error(failure)
	quit(0 if failures.is_empty() else 1)
func render_captures(capture:Node,footer:Node3D,tag:String)->void:
	if not "--render" in OS.get_cmdline_user_args():return
	for frame in 4:await process_frame;await RenderingServer.frame_post_draw;capture.update()
	for frame in 6:footer.sync(1300+frame);capture.update();await process_frame;await RenderingServer.frame_post_draw
	var paints:int=capture.repaints
	for frame in 6:footer.sync(1400+frame);capture.update();await process_frame;await RenderingServer.frame_post_draw
	check(capture.repaints==paints,"Idle controls leave HD swapchains parked after the settling frames")
	var output:=ProjectSettings.globalize_path("res://../../build/output/browser-effects/sharp-captures")
	DirAccess.make_dir_recursive_absolute(output)
	var items:Array[Dictionary]=[];capture._gather(footer,items,capture._root_pose().affine_inverse(),false)
	for slot in capture.slots:
		if not slot.used or slot.empty or not items.any(func(item):return slot.nodes.has(item.node)):continue
		var pixels:Image=slot.raw.get_texture().get_image()
		check(pixels.save_png(output.path_join("%s-plane-%d.png"%[tag,slot.index]))==OK,"Saved actual HD control texture")
		check(pixels.get_data()==slot.submit.get_texture().get_image().get_data(),"Submission copy preserves control texture detail")
		var ink:=0
		for y in range(0,pixels.get_height(),3):
			for x in range(0,pixels.get_width(),3):
				var color:=pixels.get_pixel(x,y)
				if color.a>.5 and color.r>.6 and color.g>.6:ink+=1
		check(ink>5,"Actual control texture contains readable ink: %d samples"%ink)
func fixture(low:bool)->void:
	var world:=Node3D.new();root.add_child(world)
	var camera:=Camera3D.new();world.add_child(camera)
	var menu:=Menu.new();world.add_child(menu)
	var platform:=Fixture.Platform.new();menu.attach_platform(platform);menu.toggle();menu._activate(Menu.NAV_BASE+Menu.Section.WEB);menu.set_process(false)
	var capture:=Capture.new();world.add_child(capture);capture.configure(world,camera,null,[menu],low,true);capture.set_process(false)
	var browser:RefCounted=menu.web_browser;browser.window_created=capture.register_companion
	browser.open("https://example.com/page");browser.tick()
	var host:Node3D=browser.windows[1];host.set_process(false)
	host.depth.config_path="user://browser_effects_sharp_%d_%d.cfg"%[OS.get_process_id(),int(low)]
	var footer:Node3D=host.effect_controls
	host._activate(footer.DEPTH);host.depth.state="ready"
	var page:Dictionary=host.page_layout();var origin:Vector3=page.pose*Vector3(0,0,.4);var direction:Vector3=-page.pose.basis.z
	footer.observe_ray("right",origin,direction,true,1000);footer.observe_ray("right",origin,direction,true,1125)
	capture.update()
	for button in footer._buttons:
		check(not slot_for(capture,button.node).is_empty(),"Visible effect target %d joins the existing HD capture"%button.target)
	check(not slot_for(capture,footer.knob).is_empty() and not slot_for(capture,footer.value_label).is_empty(),"Slider knob and percentage use the HD menu path")
	check(slot_for(capture,footer.busy_ring).is_empty(),"The shader-clock busy ring keeps animating independently of parked HD textures")
	verify_hd(capture,footer,"normal")
	var mesh_changes:=[0]
	footer.fill.mesh.changed.connect(func():mesh_changes[0]+=1)
	for frame in 10:footer.sync(1200+frame)
	check(mesh_changes[0]==0,"An idle HD strength rail does not rebuild meshes and repaint the compositor every frame")
	await render_captures(capture,footer,"low" if low else "normal")
	for height in [1.8,3.2,.9]:
		host.page_size=Vector2(1.44,height);host.refresh();footer.sync(1125);capture.update()
		verify_hd(capture,footer,"height %.1f"%height)
		var bar:=slot_for(capture,footer._buttons[0].node)
		check(not bar.is_empty() and bar.rect.size.y<.3,"Resizing does not accumulate old footer positions into a blurred tall texture")
	var enabled:bool=host.depth.enabled;var strength:float=host.depth.strength
	footer.observe_ray("right",origin,direction,false,1800);capture.update()
	check(not footer.visible and not footer._buttons.any(func(b):return b.target==footer.STRENGTH),"Hiding the controls closes the strength popup")
	check(host.depth.enabled==enabled and is_equal_approx(host.depth.strength,strength),"Auto-close keeps the effect and preferred strength")
	footer.observe_ray("right",origin,direction,true,2000);footer.observe_ray("right",origin,direction,true,2125);capture.update()
	check(footer.visible and footer._buttons.size()==5 and not footer._buttons.any(func(b):return b.target==footer.STRENGTH),"Returning to the page reveals the five icons including the keyboard")
	# Reopening the rail must not toggle an already enabled effect off.
	var depth:Dictionary=footer._buttons.filter(func(b):return b.target==footer.DEPTH)[0]
	var ray:Vector3=depth.node.global_position+footer.global_basis.z.normalized()*.2
	host.press_pointer("right",ray,-footer.global_basis.z.normalized(),true);host.release_pointer("right",ray,-footer.global_basis.z.normalized(),true);footer.sync(2125);capture.update()
	check(host.depth.enabled and footer._buttons.any(func(b):return b.target==footer.STRENGTH),"Clicking the active 3D icon reopens its rail")
	verify_hd(capture,footer,"reopened")
	# Drag capture must outlive the normal hide timeout, including a ray leaving the panel.
	var start:Vector3=footer.to_global(Vector3(footer.SLIDER_X,lerpf(footer.RAIL.x,footer.RAIL.y,.7),.3))
	var outside:Vector3=footer.to_global(Vector3(2,lerpf(footer.RAIL.x,footer.RAIL.y,.7),.3))
	var drag_direction:Vector3=-footer.global_basis.z.normalized()
	host.press_pointer("left",start,drag_direction,true)
	check(footer.has_pointer_capture(),"The real strength slider captures its trigger")
	footer.observe_ray("right",outside,drag_direction,false,3000)
	host.update_pointer("left",outside,drag_direction,true);footer.sync(1000000000)
	check(footer.visible and footer.strength_open,"Dragging keeps both controls and popup alive beyond the idle timeout")
	host.release_pointer("left",outside,drag_direction,true)
	footer.observe_ray("left",outside,drag_direction,false,1000000700)
	check(not footer.visible and not footer.strength_open and host.depth.enabled,"Releasing away from the page permits automatic folding while 3D stays active")
	footer.observe_ray("right",origin,direction,true,1000000800);footer.observe_ray("right",origin,direction,true,1000001000)
	footer._activate(footer.DEPTH)
	for count in ([2] if low else [2,4]):
		platform.browser.tab_list=[];platform.browser.windows=[]
		for id in range(1,count+1):
			platform.browser.tab_list.append({"id":id,"window":id,"url":"https://example.com/"+str(id)})
			platform.browser.windows.append({"id":id,"tab_id":id,"url":"https://example.com/"+str(id)})
		browser.next_poll=0;browser.tick()
		for peer in browser.windows.values():
			peer.set_process(false)
			if peer!=host:peer.effect_controls.sync(2500)
		footer.observe_ray("right",ray,-footer.global_basis.z.normalized(),true,1000001100);capture.update()
		verify_hd(capture,footer,"%d windows"%count)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(host.depth.config_path))
	world.free();platform.free();await process_frame
