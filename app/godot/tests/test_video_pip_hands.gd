extends SceneTree
const Core := preload("res://tests/test_video_pip.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Pointer := preload("res://scripts/hand_pointer.gd")
var checks := 0
var failures: Array[String] = []
class HandMain extends Core.RoutingMain:
	var focused := true
	func _input_focused() -> bool: return focused
	func _move_pose(_hand: String) -> Variant: return null
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func ray_to(window: Node3D, point: Vector2 = Vector2.ZERO) -> Array:
	return [window.to_global(Vector3(point.x,point.y,0.8)), -window.global_basis.z]
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var video := Core.Surface.new(); root.add_child(video)
	var main := HandMain.new(); root.add_child(main); main.video=video
	var menu := Menu.new(); menu.state_provider=func():return {"has_video":true,"pip_slots":[1],"pip_count":1}
	root.add_child(menu); main.player_menu=menu
	var pip: RefCounted = video.pip
	pip.set_count(1,main._head_pose())
	var window: Node3D = pip.windows[1]
	var start: Transform3D = window.global_transform
	var picture := ImageTexture.create_from_image(Image.create(320,160,false,Image.FORMAT_RGB8))
	for hand in ["left_hand","right_hand"]:
		for provider in ["meta_aim","hand_profile","joints"]:
			for image_mode in [false,true]:
				if image_mode: window.show_image(picture)
				else: window.restore_video()
				window.global_transform=start
				var pointer := Pointer.new(); pointer.source="hand"; pointer.provider=provider
				main.hand_pointers={hand:pointer}; main.test_ray=ray_to(window)
				var size: Vector2 = window.size; var zoom: float = window.zoom
				main._dispatch_hand_input({hand:{"pressed":true,"source":"hand","tracked":true,"down":true}},0.016)
				check(pip.movement.capture.get("input","")=="trigger_click" and pip.movement.capture.get("hand","")==hand, "A body pinch captures movement without a controller pose")
				main.test_ray=[main.test_ray[0]+Vector3(0.12,0.08,0),main.test_ray[1]]
				main._update_pip_input()
				check(window.global_position.distance_to(start.origin)>0.03 and pip.movement.capture.get("moved",false), "Held pinch moves video and image windows through production updates")
				check(absf(window.global_basis.x.y)<0.00001 and window.global_basis.z.dot((main._head_pose().origin-window.global_position).normalized())>0.999, "Hand dragging remains upright and faces the headset")
				check(window.size==size and window.zoom==zoom, "Body dragging preserves size and magnification")
				main._dispatch_hand_input({hand:{"released":true,"source":"hand","tracked":true,"down":false}},0.016)
				var released: Transform3D = window.global_transform
				main.test_ray=[main.test_ray[0]+Vector3(0.2,0,0),main.test_ray[1]]; main._update_pip_input()
				check(pip.movement.capture.is_empty() and window.global_transform.is_equal_approx(released), "Pinch release stops movement without a playback tap")
	main.hand_pointers={"right_hand":Pointer.new()}; main.hand_pointers.right_hand.source="hand"
	window.global_transform=start; window.controls=true; window.refresh()
	main.test_ray=ray_to(window,window.corner_point(0)); main._pip_pointer_press("trigger_click","right_hand")
	check(not pip.resize.is_empty() and pip.movement.capture.is_empty(), "Corner pinch resizes rather than moving the body")
	main._on_pointer_release("trigger_click","right_hand")
	var mode: Dictionary = window._buttons.filter(func(b):return b.target==6)[0]
	main.test_ray=[mode.node.to_global(Vector3(0,0,0.8)),-mode.node.global_basis.z]
	main._pip_pointer_press("trigger_click","right_hand")
	check(pip.movement.capture.is_empty() and pip.resize.is_empty(), "Toolbar pinch remains a button click")
	main._on_pointer_release("trigger_click","right_hand")
	check(not window.image_mode, "The video mode button still switches content")
	menu.toggle(); menu._activate(Menu.PIP); main.test_menu=menu
	main.test_ray=ray_to(window); main._pip_pointer_press("trigger_click","right_hand")
	check(not pip.movement.capture.is_empty(), "The PiP picker does not block hand dragging outside its controls")
	main.test_ray=null; main._update_pip_input()
	check(pip.movement.capture.is_empty(), "Lost hand ray cancels the drag")
	main.test_ray=ray_to(window); main._pip_pointer_press("trigger_click","right_hand")
	main.focused=false; main._update_pip_input()
	check(pip.movement.capture.is_empty(), "Lost session focus cancels the drag")
	main.focused=true
	var button: Dictionary = menu._buttons.filter(func(b):return b.target==Menu.PIP)[0]
	main.test_ray=[button.node.to_global(Vector3(0,0,0.8)),-button.node.global_basis.z]
	check(not main._pip_pointer_press("trigger_click","right_hand") and pip.movement.capture.is_empty(), "Actual playback-menu buttons retain priority over PiP")
	main.test_menu=null; main.hand_pointers.right_hand.source="controller"; main.test_ray=ray_to(window)
	main._pip_pointer_press("trigger_click","right_hand")
	check(pip.movement.capture.is_empty(), "A physical trigger does not become a hand drag")
	main.hand_pointers.right_hand.source="hand"; main._pip_pointer_press("trigger_click","right_hand")
	main._cancel_pointer("right_hand")
	check(pip.movement.capture.is_empty(), "Provider/source cancellation clears PiP ownership")
	pip.clear(); main.video=null; main.player_menu=null; main.queue_free(); menu.queue_free(); video.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP hands: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
