extends SceneTree
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
const Depth := preload("res://scripts/playback_menu_depth.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")

# Aim the visible end of the existing controller beam at the displayed button.
# At zero disparity, both eyes see the button in this centre-eye direction.
static func aim(menu: Node3D, head: Vector3, hand: Vector3, point: Vector3) -> Vector3:
	var direction := (point-head).normalized()
	var offset := head-hand
	var along := offset.dot(direction)
	var distance := -along + sqrt(along*along + menu.ray_max_distance*menu.ray_max_distance-offset.length_squared())
	return (head+direction*distance-hand).normalized()

func run() -> void:
	var path := "user://mono_pointer_%d.cfg" % Time.get_ticks_usec()
	var settings := ConfigFile.new(); settings.set_value("appearance", "background", "dark"); settings.save(path)
	var main := InputMain.new(); main.settings_path = path; root.add_child(main); main.set_process(false)
	main.xr_camera.global_transform = main.head_pose
	main.video.local_uri = "file:///pointer-fixture.mp4"; main.video.media.begin(1); main.video.media.state = "playing"
	main.video.geometry = 1
	main.video.control.observe(120000,600000)
	main._show_player_menu(); main._on_setting_changed(Depth.KEY, Depth.MONO)
	var menu: Node3D = main.video_menu
	var initial_head: Transform3D = main.head_pose
	for motion in [Transform3D.IDENTITY,Transform3D(Basis(Vector3.UP,0.25),Vector3(0.12,0.08,0.1))]:
		main.head_pose = initial_head * motion; main.xr_camera.global_transform = main.head_pose
		for section in [0,1]:
			menu.section = section; menu.refresh(); main.mono_menu_capture.update()
			for target in ([107,100,108,102] if section == 0 else [menu.SETTINGS_CLOSE]):
				var buttons: Array = menu._buttons.filter(func(button): return button.target == target)
				if buttons.is_empty(): check(false,"Visible close/control exists"); continue
				var point: Vector3 = buttons[0].node.global_position
				for side in [-1,1]:
					var hand := "left_hand" if side < 0 else "right_hand"
					var origin: Vector3 = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
					var direction := aim(menu,main.head_pose.origin,origin,point)
					menu.update_pointer(hand,origin,direction,true)
					check(menu._hover.get(hand) == target,"Visible mono beam endpoint hits %d with %s after head motion" % [target,hand])
					var hit: Dictionary = menu.ray_hit(origin,direction)
					check(hit.get("target") == target,"Trigger hit agrees with rendered pointer for %d/%s" % [target,hand])
	for side in [-1,1]:
		menu.section = 1; menu.refresh(); main.mono_menu_capture.update()
		var close: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SETTINGS_CLOSE)[0]
		var hand := "left_hand" if side < 0 else "right_hand"
		var origin: Vector3 = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
		main.rays[hand] = [origin,aim(menu,main.head_pose.origin,origin,close.node.global_position)]
		main._on_controller_button("trigger_click",hand); main._on_controller_release("trigger_click",hand)
		check(menu.section == 0 and menu.visible,"Visible popup close returns to transport with " + hand)
	# Capture and drag must use the same ray projection as hover and trigger hits.
	menu.section = 0; menu.refresh(); main.mono_menu_capture.update()
	var start: Vector3 = main.head_pose * Vector3(0.25,-0.2,-0.3)
	var timeline: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SEEK)[0]
	var centre: Vector3 = timeline.node.global_position
	var direction := aim(menu,main.head_pose.origin,start,centre)
	menu.press_pointer("right_hand",start,direction,true)
	check(menu.has_pointer_capture(),"Visible timeline starts pointer capture")
	var expected: Vector3 = menu._input_point(menu.ray_hit(start,direction))
	var projected: Variant = menu._plane_point(start,direction,menu.SEEK)
	check(projected != null and absf(projected.x-expected.x) < 0.002,"Captured slider projection agrees with initial hit")
	menu.update_pointer("right_hand",start,aim(menu,main.head_pose.origin,start,centre+menu.global_basis.x*0.15),true)
	check(menu._seek_preview > menu._seek_start,"Mono drag moves the seek preview along the visible timeline")
	menu.cancel_pointer("right_hand")
	# Attached browser uses the projection of its captured parent.
	main._show_recent_menu()
	main.mono_menu_capture.update()
	var browser: Node3D = main.recent_menu
	var browser_close: Dictionary = browser._buttons.filter(func(button): return button.target == browser.CLOSE)[0]
	direction = aim(menu,main.head_pose.origin,start,browser_close.node.global_position)
	check(browser.ray_hit(start,direction).get("target") == browser.CLOSE,"Attached browser close inherits the mono cursor")
	main.rays.right_hand = [start,direction]
	main._on_controller_button("trigger_click","right_hand"); main._on_controller_release("trigger_click","right_hand")
	check(not browser.visible and menu.visible,"Closing the attached browser through its visible button keeps the transport open")
	main._on_setting_changed(Depth.KEY,Depth.DEFAULT)
	check(not menu.has_meta("menu_mono_pointer"),"Changing depth restores ordinary picking immediately")
	# Both hands close media through the production controller route.
	for side in [-1,1]:
		main.video.local_uri = "file:///pointer-fixture.mp4"; main.video.media.begin(2); main.video.media.state = "playing"
		main.video.geometry = 1
		main._show_player_menu(); main._on_setting_changed(Depth.KEY,Depth.MONO); main.mono_menu_capture.update()
		var close: Dictionary = menu._buttons.filter(func(button): return button.target == 107)[0]
		var hand := "left_hand" if side < 0 else "right_hand"
		start = main.head_pose * Vector3(side*0.25,-0.2,-0.3)
		main.rays[hand] = [start,aim(menu,main.head_pose.origin,start,close.node.global_position)]
		main._on_controller_button("trigger_click",hand); main._on_controller_release("trigger_click",hand)
		check(main.video.media.state == "closed" and not menu.visible and main.recent_menu.visible,"Mono close button closes media and returns to library with " + hand)
		main.mono_menu_capture.update()
		check(not menu.has_meta("menu_mono_pointer"),"Closing removes the mono projection")
	# The independent library retains its finite hand-origin ray.
	var library_button: Dictionary = main.recent_menu._buttons.filter(func(button): return button.enabled and button.node.is_visible_in_tree())[0]
	check(main.recent_menu.ray_hit(start,library_button.node.global_position-start).get("target") == library_button.target,"Independent library restores ordinary controller picking")
	# A stored mono preference must not leak onto the separate picture controls.
	main.photo_active = true; main.player_menu = main.photo_menu
	main.photo.local_uri = "file:///pointer-photo.jpg"
	main.photo_menu.state_provider = func(): return {"has_image":true,"geometry":0,"count":1,"index":0}
	main._show_player_menu(); main.mono_menu_capture.update()
	var picture: Node3D = main.photo_menu
	var picture_close: Dictionary = picture._buttons.filter(func(button): return button.target == 107)[0]
	direction = picture_close.node.global_position-start
	check(not picture.has_meta("menu_mono_pointer") and picture.ray_hit(start,direction).get("target") == 107,"Picture close keeps ordinary picking after leaving mono video")
	main.rays.right_hand = [start,direction]
	main._on_controller_button("trigger_click","right_hand"); main._on_controller_release("trigger_click","right_hand")
	check(main.photo.local_uri.is_empty() and not picture.visible,"Picture close action still closes its image")
	menu.dismiss(); main.queue_free(); await process_frame
	DirAccess.remove_absolute(path)
	for failure in failures: push_error(failure)
	print("Mono menu pointer: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
