extends SceneTree
const I18n := preload("res://scripts/i18n.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var player_settings: String = preload("res://scripts/main.gd").SETTINGS_PATH
	var player_preferences_before := FileAccess.get_sha256(player_settings) if FileAccess.file_exists(player_settings) else ""
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu)
	menu.attach_platform(platform); menu.toggle(); menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.com/shorts")
	browser.next_poll = 0; browser.tick()
	var host: Node3D = browser.windows[1]
	host.depth.config_path = "user://browser_depth_test_%d.cfg" % OS.get_process_id()
	var original_url: String = platform.browser.url
	host._activate(browser.BASE + 16)
	check(host.depth.enabled, "Whole-page conversion can be enabled without video readiness or fullscreen")
	var tools: Array = browser.toolbar_tools(host, browser.window_state(1))
	check(browser.BASE + 16 not in tools and browser.BASE + 21 not in tools, "Effect toggles leave the top toolbar")
	var footer: Node3D = host.effect_controls
	host._process(0)
	var page: Dictionary = host.page_layout()
	var page_origin: Vector3 = page.pose * Vector3(0,0,0.4)
	var page_direction: Vector3 = -page.pose.basis.z
	footer.observe_ray("right",page_origin,page_direction,true,1000)
	footer.observe_ray("right",page_origin,page_direction,true,1125)
	check(footer.visible, "Looking at the page reveals its separate effect controls")
	footer._activate(footer.DEPTH) # first hidden sync already folded the requested popup
	var depth_button: Dictionary = footer._buttons.filter(func(b): return b.target==footer.DEPTH)[0]
	var depth_ray: Vector3 = depth_button.node.global_position+footer.global_basis.z.normalized()*.2
	footer.observe_ray("right",depth_ray,-footer.global_basis.z.normalized(),true,1150)
	check(footer.busy_ring.visible and footer._tooltip.visible and footer._tooltip.get_child(0).text==footer.I18n.t("Starting 3D"), "Cold startup uses the shared rotating icon and the actual hover tooltip")
	host.depth.state="ready";footer.sync(1150)
	check(not footer.busy_ring.visible and footer._tooltip.get_child(0).text==footer.I18n.t("2D to 3D effect"), "Preparation completion removes the busy ring and refreshes a stationary ray's tooltip")
	check(footer.RAIL.x>0 and footer.strength_bounds().position.y>0, "The video-style strength rail rises above its 2D to 3D icon")
	check(footer.strength_bounds().position.y>depth_button.rect.end.y, "The complete strength popup clears the 2D to 3D button")
	var off_button: Dictionary = footer._buttons.filter(func(b): return b.target==footer.OFF)[0]
	check(off_button.rect.position.y>depth_button.rect.end.y and off_button.rect.end.y<footer.RAIL.x, "The power-off button has its own clear space below the rail")
	footer.observe_ray("right",page_origin,page_direction,false,1800)
	check(not footer.visible, "Moving the ray away hides controls after the picture-style grace period")
	footer.observe_ray("right",page_origin,page_direction,true,2000); footer.observe_ray("right",page_origin,page_direction,true,2125)
	var effect_buttons: Array = footer._buttons.filter(func(b): return b.target in [footer.FOCUS,footer.MATTE,footer.DEPTH])
	check(effect_buttons.map(func(b): return b.target) == [footer.FOCUS,footer.MATTE,footer.DEPTH], "Focus, person passthrough and 2D to 3D share the lower controls in order")
	check(host.to_local(footer.global_position).y + 0.06 < host.page_rect().position.y - 0.16, "Effect icons remain below the bottom resize target")
	footer.observe_ray("left",page_origin,page_direction,true,2200)
	footer.observe_ray("right",page_origin,page_direction,false,3000)
	check(footer.visible, "Either tracked hand can keep the controls visible")
	footer.observe_ray("left",page_origin,page_direction,false,3700)
	check(not footer.visible, "The last hand leaving hides the controls")
	footer.visible = true
	var resize: Dictionary = host._buttons.filter(func(b): return b.target == host.RESIZE_BOTTOM)[0]
	var resize_start: Vector3 = resize.node.global_position + host.global_basis.z.normalized() * .3
	var old_size: Vector2 = host.page_size
	var old_pose: Transform3D = host.global_transform
	host.press_pointer("left",resize_start,page_direction,true)
	check(host.drag.get("kind",-1)==host.RESIZE_BOTTOM, "The original bottom height handle remains reachable above the effect controls")
	host.update_pointer("left",resize_start-host.global_basis.y*.4,page_direction,true)
	check(host.page_size.y>old_size.y+.3 and not footer.has_pointer_capture(), "Dragging the height handle past the effect controls preserves its original capture")
	host.release_pointer("left",resize_start,page_direction,true)
	host.page_size=old_size;host.global_transform=old_pose;host.refresh();footer.sync()
	host._activate(browser.BASE + 17)
	check(host.depth_settings and host.depth_choices.sliders.size() == 1, "Settings retain position; strength lives outside")
	var dialog_close: Dictionary = host._buttons.filter(func(b): return b.target == browser.BASE + 17 and b.node.position.z > 0.03)[0]
	var close_icon: MeshInstance3D = dialog_close.node.get_children().filter(func(n): return n is MeshInstance3D)[0]
	check(close_icon.material_override.render_priority > dialog_close.node.material_override.render_priority, "Settings X draws above its button surface")
	var strength_target: int = -1
	for target in host.depth_choices.sliders:
		if host.depth_choices.targets[target].key == "position": strength_target = target
	check(strength_target >= 0, "Position rail has a live input target")
	var drawn_slider: Dictionary = host.depth_choices.sliders[strength_target]
	check(drawn_slider.knob.material_override.render_priority > drawn_slider.fill.material_override.render_priority and drawn_slider.fill.material_override.render_priority > drawn_slider.node.material_override.render_priority,
		"Raised strength slider keeps its knob and fill visible above the field")
	var button: Dictionary = host._buttons.filter(func(b): return b.target == strength_target)[0]
	var pose: Transform3D = button.node.global_transform
	var origin := pose * Vector3(-0.08, 0, 0.2)
	var direction := -pose.basis.z.normalized()
	host.press_pointer("left", origin, direction, true)
	check(host.has_pointer_capture(), "Slider captures the trigger instead of sending a click to Gecko")
	host.update_pointer("left", origin + pose.basis.x * 0.12, direction, true)
	host.release_pointer("left", origin + pose.basis.x * 0.12, direction, true)
	check(not host.has_pointer_capture(), "Slider release clears capture")
	check(host.depth.position > 0.0 and host.depth.position <= 100.0, "Dragging the production rail changes position")
	check(platform.browser.url == original_url, "Adjustments preserve the browser page")
	var fill_target := -1
	for target in host.depth_choices.targets:
		var item: Dictionary = host.depth_choices.targets[target]
		if item.get("key", "") == "render_mode" and item.kind == "choose" and item.value == "fill": fill_target = target
	check(fill_target >= 0, "Settings expose the player's fill/stretch options")
	var fill_button: Dictionary = host._buttons.filter(func(b): return b.target == fill_target)[0]
	var fill_ray: Vector3 = fill_button.node.global_position + host.global_basis.z.normalized() * .2
	check(host.ray_hit(fill_ray, -host.global_basis.z.normalized()).get("target", -1) == fill_target, "Rendering choice has an unobstructed ray target")
	host.press_pointer("left", fill_ray, -host.global_basis.z.normalized(), true)
	host.release_pointer("left", fill_ray, -host.global_basis.z.normalized(), true)
	check(host.depth.render_mode == "fill", "Rendering choice commits")
	host._activate(browser.BASE + 17)
	footer._activate(footer.DEPTH) # reopen the popup after the earlier automatic hide
	footer.sync(); footer.visible = true
	var rail_origin: Vector3 = footer.to_global(Vector3(footer.SLIDER_X,footer.RAIL.x+0.04,0.2))
	var rail_end: Vector3 = footer.to_global(Vector3(footer.SLIDER_X,footer.RAIL.y-0.03,0.2))
	var rail_direction: Vector3 = -footer.global_basis.z.normalized()
	host.press_pointer("left",rail_origin,rail_direction,true)
	check(host.has_pointer_capture(), "External strength slider owns its trigger")
	host.update_pointer("left",rail_end,rail_direction,true)
	check(footer.knob.position.y > footer.RAIL.x + 0.15, "External strength knob visibly follows dragging")
	host.release_pointer("left",rail_end,rail_direction,true)
	check(not host.has_pointer_capture() and host.depth.strength > 0.8 and host.depth.strength<=1.0, "The normal video-style rail covers 0 to 100 percent")
	var boost_button: Dictionary = footer._buttons.filter(func(b): return b.target==footer.BOOST)[0]
	var boost_ray: Vector3 = boost_button.node.global_position+footer.global_basis.z.normalized()*.2
	host.press_pointer("left",boost_ray,rail_direction,true);host.release_pointer("left",boost_ray,rail_direction,true)
	check(footer.boosted and footer.boost_fill!=null, "The actual Boost button extends the rail with the video player's amber segment")
	rail_end=footer.to_global(Vector3(footer.SLIDER_X,footer.RAIL.y+footer.BOOST_HEIGHT*.75,.2))
	host.press_pointer("left",rail_origin,rail_direction,true);host.update_pointer("left",rail_end,rail_direction,true);host.release_pointer("left",rail_end,rail_direction,true)
	check(host.depth.strength>1.7 and host.depth.strength<1.8 and footer.knob.position.y>footer.RAIL.y, "The added upper segment reaches enhanced strength beyond 100 percent")
	footer._activate(footer.BOOST)
	check(not footer.boosted and is_equal_approx(host.depth.strength,1.0), "Disabling Boost returns enhanced strength to 100 percent like the video player")
	var off_ray: Vector3 = footer._buttons.filter(func(b): return b.target==footer.OFF)[0].node.global_position+footer.global_basis.z.normalized()*.2
	var saved_strength: float = host.depth.strength
	host.press_pointer("left",off_ray,rail_direction,true);host.release_pointer("left",off_ray,rail_direction,true);footer.sync()
	check(not host.depth.enabled and is_equal_approx(host.depth.strength,saved_strength), "The actual power-off control disables conversion and preserves its remembered strength")
	host._activate(footer.DEPTH);footer.sync();footer.visible=true
	var matte_button: Dictionary = footer._buttons.filter(func(b): return b.target == footer.MATTE)[0]
	var matte_ray: Vector3 = matte_button.node.global_position + footer.global_basis.z.normalized() * .2
	check(host.ray_hit(matte_ray, -footer.global_basis.z.normalized()).get("target", -1) == footer.MATTE, "Bottom passthrough icon remains a real ray target")
	host.press_pointer("left", matte_ray, -footer.global_basis.z.normalized(), true)
	host.release_pointer("left", matte_ray, -footer.global_basis.z.normalized(), true)
	check(host.depth.matte and browser.person_passthrough_active(), "Ray click enables browser person passthrough")
	check(not host._backdrop.visible and host._buttons.is_empty() and not host._feedback.visible, "Passthrough removes frame, toolbar and page hit surface")
	var pointers_before: int = platform.pointers.size()
	host.press_pointer("right",page_origin,page_direction,true); host.release_pointer("right",page_origin,page_direction,true); host.stick_scroll(1,0.1)
	check(platform.pointers.size() == pointers_before, "Passthrough blocks page clicks and scrolling")
	check(host.ray_hit(matte_ray,-footer.global_basis.z.normalized()).get("target",-1) == footer.MATTE, "Borderless passthrough retains its exit icon")
	platform.browser.url="about:blank";browser.next_poll=0;browser.tick();footer.sync()
	check(footer._buttons.any(func(b): return b.target==footer.MATTE), "Active effects retain their exit controls if navigation reaches the start page")
	platform.browser.url=original_url;browser.next_poll=0;browser.tick()
	host.depth.enabled = false
	check(browser.person_passthrough_active(), "Person passthrough can run independently of 2D to 3D")
	host.depth.enabled = true
	var saved := preload("res://scripts/web_browser_depth.gd").new()
	saved.config_path = host.depth.config_path; saved.load_preferences()
	check(is_equal_approx(saved.strength, host.depth.strength), "Browser strength persists separately")
	check(is_equal_approx(saved.position,host.depth.position) and saved.position>0.0, "Browser 3D position restores its own saved value")
	var isolated := ConfigFile.new();isolated.load(host.depth.config_path)
	check(isolated.has_section("depth") and not isolated.has_section("video") and not isolated.has_section("photo"), "Browser preferences use their own file and section")
	var player_preferences_after := FileAccess.get_sha256(player_settings) if FileAccess.file_exists(player_settings) else ""
	check(player_preferences_before==player_preferences_after, "Saving browser strength and position leaves video and photo preferences unchanged")
	check(saved.render_mode == "fill", "Rendering preference persists")
	check(not saved.enabled, "Reopening a browser does not silently enable a heavy processing mode")
	check(not saved.matte, "Person processing is session-only rather than silently persisted")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(host.depth.config_path))
	host._activate(footer.MATTE)
	check(not host.chrome_hidden() and host._buttons.any(func(b): return b.target == browser.BASE + 17) and not host._decorations.is_empty(), "Turning passthrough off restores website controls")
	browser.focus_regions[host.focus_tab()] = Rect2(.3, .1, .4, .8)
	check(host.focus_crop() == Rect2(.3, .1, .4, .8) and host.depth.enabled, "Focusing changes the region without disabling conversion")
	host._activate(browser.BASE + 19)
	check(host.focus_crop() == host.Focus.FULL and host.depth.enabled, "Leaving focus restores full-page conversion")
	host.toggle_focus()
	check(not browser.person_passthrough_active(), "Region selection temporarily restores the source page")
	host.toggle_focus()
	host._activate(footer.MATTE)
	check(browser.person_passthrough_active(), "Completing selection resumes the same person mode")
	host.depth.enabled=false; host.depth.matte=false; host.depth.state="failed"; host.depth.error="3D unavailable"
	footer.near_hands.clear(); footer.capture_hand=""
	footer.sync(10000); footer.sync(10130)
	check(footer.visible and footer._labels.any(func(label): return label.text==I18n.t("3D unavailable")), "Failed preparation shows a concise error without needing hover")
	check(not footer.depth_preparing() and footer._tips[footer.DEPTH]==I18n.t("3D unavailable"), "Failed effect stops the spinner and retains its error tooltip")
	footer.sync(17000)
	check(not footer.visible, "Error feedback uses a bounded display interval")
	host._activate(browser.BASE+16); footer.sync(18000)
	check(host.depth.error.is_empty() and footer.depth_preparing(), "Explicit retry clears the old error and starts preparing")
	host.dismiss()
	check(not browser.person_passthrough_active(), "Closing the browser releases its camera request")
	menu.free(); platform.free(); await process_frame
	print("Browser depth: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
