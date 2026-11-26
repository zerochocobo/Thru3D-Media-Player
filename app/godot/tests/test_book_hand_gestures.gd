extends SceneTree
## Bare-hand page turning in reading mode: a palm wave across the book turns a leaf through the
## production hand sampling, and is held back while a page is pinched, a menu is up or it is turned off.
const Hand := preload("res://scripts/hand_pointer.gd")
const Main := preload("res://scripts/main.gd")
const Swipe := preload("res://scripts/memory_swipe.gd")
const HEAD := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
const START := Vector3(0.18, 1.25, -0.5)
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func tracker(point: Vector3) -> XRHandTracker:
	var result := XRHandTracker.new(); result.name = "/user/hand_tracker/right"
	result.has_tracking_data = true; result.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	result.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, Hand.POSITION_FLAGS)
	result.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, point))
	return result

func _initialize() -> void: call_deferred("_run")

## Sweeps the right palm sideways (negative: leftwards, the next page) and returns the leaf in the air.
func wave(app: Node, optical: XRHandTracker, direction: float) -> Dictionary:
	app.book._turn = {}; app.book_swipe = Swipe.new()
	optical.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, START))
	app._update_hand_input(1.0 / 36)
	for frame in range(1, 12):
		optical.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, START + Vector3(direction * frame * 0.025, 0, 0)))
		app._update_hand_input(1.0 / 36)
	return app.book._turn.duplicate()

func _run() -> void:
	var optical := tracker(START)
	var head := XRPositionalTracker.new(); head.name = "head"; head.set_pose("default", HEAD, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	var app := Main.new(); app.settings_path = "user://book_hands_%d.cfg" % Time.get_ticks_usec()
	root.add_child(app); app.set_process(false); app.input_visuals.free(); app.input_visuals = null
	for item in [optical, head]: XRServer.add_tracker(item)
	app.recent_menu.dismiss(); app.photo_menu.dismiss(); app.video_menu.dismiss()
	app.xr_camera.global_transform = HEAD
	# An open book of ten pages at the second spread; no platform is needed to turn a leaf.
	var book: Node3D = app.book
	book.active = true; book.visible = true; book.count = 10; book.page = 2; book.single = false
	var turned := wave(app, optical, -1.0)
	check(int(turned.get("direction", 0)) == 1, "A palm swept leftwards across the book turns to the next page")
	turned = wave(app, optical, 1.0)
	check(int(turned.get("direction", 0)) == -1, "A palm swept rightwards turns back")
	book.set_turn("palm", false)
	check(wave(app, optical, -1.0).is_empty(), "Turned off in the page-turning settings, a wave does nothing")
	book.set_turn("palm", true)
	app._book_trigger["right_hand"] = true
	check(wave(app, optical, -1.0).is_empty(), "A hand pinching a page is carrying it, not waving")
	app._book_trigger.clear()
	book.bar.open()
	check(wave(app, optical, -1.0).is_empty(), "With the book's controls up, a wave does not turn the page")
	book.bar.dismiss()
	check(int(wave(app, optical, -1.0).get("direction", 0)) == 1, "Waving turns pages again once the controls are put away")
	book.active = false
	check(wave(app, optical, -1.0).is_empty() and not app._book_waving(), "With no book open, waves are left to the photos")
	for item in [optical, head]: XRServer.remove_tracker(item)
	app.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Book hand gestures: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
