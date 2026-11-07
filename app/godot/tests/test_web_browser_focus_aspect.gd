extends SceneTree
const Menu:=preload("res://scripts/library_menu.gd")
const Fixture:=preload("res://tests/test_web_browser_windows.gd")
const Focus:=preload("res://scripts/web_browser_focus.gd")
var checks:=0
var failures: Array[String]=[]
func _initialize() -> void: run.call_deferred()
func check(ok: bool,message: String) -> void:
	checks+=1
	if not ok:failures.append(message)
func point(page: Dictionary,uv: Vector2,z: float=.6) -> Vector3:
	return page.pose*Vector3((uv.x-.5)*page.size.x,(.5-uv.y)*page.size.y,z)
func run() -> void:
	for start in [Vector2(.2,.2),Vector2(.8,.8),Vector2(.2,.8),Vector2(.8,.2),Vector2(.98,.5),Vector2(.5,.98),Vector2.ZERO,Vector2.ONE,Vector2(0,1),Vector2(1,0)]:
		for end in [Vector2(.3,.7),Vector2(.9,.3),Vector2(.1,.9),Vector2(-.3,.9),Vector2(1.5,1.5),Vector2(.5,0),start+Vector2(.1,0),start+Vector2(0,-.1)]:
			var rect:=Focus.selection(start,end)
			check(is_equal_approx(rect.size.x,rect.size.y),"Normalized selection uses equal page fractions")
			check(Focus.FULL.encloses(rect),"Dragging beyond an edge shrinks both axes inside the page")
			for frame in [Vector2(1.44,.9),Vector2(2.4,.65),Vector2(1.44,1.8)]:
				if not Focus.valid(rect):continue
				var physical: Vector2=rect.size*frame
				check(is_equal_approx(physical.x/physical.y,frame.x/frame.y),"Outline has the current wide/tall window's visible aspect")
				for low in [false,true]:
					var pixels:=Vector2(preload("res://scripts/web_browser_surface.gd").pixels_for(frame,low))
					check(Focus.fitted(frame,pixels,rect).is_equal_approx(frame),"Constrained crop fills exactly the same frame at either resolution tier")
	check(not Focus.selection(Vector2(NAN,.2),Vector2(.8,.8)).has_area(),"Invalid rays cannot create a selection")
	check(Focus.selection(Vector2(.2,.2),Vector2(.6,.201)).is_equal_approx(Focus.selection(Vector2(.2,.2),Vector2(.6,.199))),"Horizontal drag jitter does not flip the selected area")
	check(Focus.selection(Vector2(.8,.8),Vector2(.801,.3)).is_equal_approx(Focus.selection(Vector2(.8,.8),Vector2(.799,.3))),"Vertical drag jitter does not flip the selected area")
	var platform:=Fixture.Platform.new();platform.browser.merge({"tab_id":1,"navigation":1,"start_page":false,"loading":false},true)
	var menu:=Menu.new();root.add_child(menu);menu.attach_platform(platform);menu.toggle();menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted=menu.web_browser;browser.open();browser.tick();menu.set_process(false)
	var host: Node3D=browser.windows[1];host.set_process(false)
	browser.cinema_provider=func():return {"position":[0,3,-12],"width":10.0,"height":5.625}
	for cinema in [false,true]:
		for dimensions in [Vector2(1.44,.9),Vector2(2.4,.65),Vector2(1.44,1.8)]:
			host.page_size=dimensions;host.set_mode("cinema" if cinema else "floating");host.refresh()
			for low in [false,true]:
				browser.low_end=low
				for ends in [[Vector2(.2,.15),Vector2(.63,.32)],[Vector2(.8,.8),Vector2(.63,.2)],[Vector2(.03,.96),Vector2(.7,.3)]]:
					if host.is_focused():host.toggle_focus()
					host.toggle_focus()
					var full: Dictionary=host.full_page_layout()
					var direction: Vector3=-full.pose.basis.z
					host.press_pointer("left",point(full,ends[0]),direction,true)
					host.update_pointer("left",point(full,ends[1]),direction,true);host._update_feedback()
					var drawn: Rect2=host.selection
					check(Focus.valid(drawn),"Real pointer drag produces a valid fixed-aspect selection")
					var outline: Vector2=drawn.size*full.size
					check(is_equal_approx(outline.x/outline.y,full.size.x/full.size.y),"Live outline matches the current visible webpage aspect")
					host.release_pointer("left",point(full,ends[1]),direction,true)
					check(host.focus_crop().is_equal_approx(drawn),"Release commits exactly the previewed rectangle")
					var focused: Dictionary=host.page_layout()
					check(focused.size.is_equal_approx(full.size),"Final focused page fills the outlined target window without letterboxing")
					for uv in [Vector2(.001,.001),Vector2(.3,.7),Vector2(.999,.999)]:
						var ray_uv: Variant=host.page_point(point(focused,uv),-focused.pose.basis.z)
						check(ray_uv!=null and host.source_point(ray_uv).distance_to(drawn.position+uv*drawn.size)<.00001,"Final visible point and source crop use the same coordinates")
					check(platform.pointers.is_empty(),"Selection never clicks the webpage")
					host.page_size=Vector2(dimensions.x*1.1,dimensions.y*.9);host.refresh()
					check(host.focus_crop().is_equal_approx(drawn),"Resizing retains the same selected source region")
					check(host.page_layout().size.is_equal_approx(host.full_page_layout().size),"Resized focused page keeps filling the current window")
					host.page_size=dimensions;host.refresh()
					host.toggle_focus()
	menu.free();platform.free();await process_frame
	for failure in failures:push_error(failure)
	print("Browser focus aspect: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
