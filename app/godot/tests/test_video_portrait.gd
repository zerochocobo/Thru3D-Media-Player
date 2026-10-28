extends SceneTree
const Portrait := preload("res://scripts/video_portrait.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
var checks := 0
var failures: Array[String] = []
class DepthBridge:
	extends RefCounted
	var requests: Array = []
	func set_mpv_portrait_depth(id: int, enabled: bool) -> bool:
		requests.append([id,enabled]); return true
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func packet(frame: int, bounds: Array, subjects: int = 1, cropped: bool = false) -> Dictionary:
	return {"frame_id": frame, "pts_us": frame * 333333, "portrait_observation": {
		"frame_id": frame, "pts_us": frame * 333333, "bounds": bounds, "subjects": subjects, "cropped": cropped}}
func run() -> void:
	var p := Portrait.new()
	check(not p.automatic, "Default portrait retains the source plane distance")
	p.automatic = true
	var eye := Vector3(.15, .1, 2.0)
	var size := Vector2(1.9, 1.07)
	for depth in [1.02, 2.0, 6.0]:
		for uv in [Vector2.ZERO, Vector2(0.2, .7), Vector2.ONE]:
			var a := Portrait.point(uv, eye, size, depth) - eye
			var b := Portrait.point(uv, eye, size, 2.0) - eye
			check(a.normalized().is_equal_approx(b.normalized()), "Reference ray remains fixed across anchor and relief")
	check(Portrait.scene(Rect2(.3,.1,.3,.8),1,false) == "full", "Full body prior")
	check(Portrait.scene(Rect2(.3,.1,.3,.9),1,false) == "half", "Half body prior")
	check(Portrait.scene(Rect2(.3,0,.3,1),1,false) == "close", "Close-up holds")
	check(Portrait.scene(Rect2(.0,.1,.3,.8),1,false) == "unknown", "Lateral clipping holds")
	check(Portrait.scene(Rect2(.3,.1,.3,.8),2,false) == "unknown", "Multiple components hold")
	check(Portrait.scene(Rect2(.3,.1,.3,.8),1,true) == "unknown", "ROI clipping holds")
	p.calibrate(eye)
	p.observe(packet(1,[.3,.1,.6,.9]),size)
	check(is_equal_approx(p.distance,2.0), "Two observations required")
	p.observe(packet(2,[.3,.1,.6,.9]),size)
	check(p.distance > 2.0 and absf(1.0/p.distance-.5) <= Portrait.CUT_STEP+.00001, "Initial distance change bounded in inverse metres")
	var before := p.distance
	p.observe(packet(3,[.3,0,.6,1]),size)
	check(is_equal_approx(before,p.distance), "Close-up does not force nearest anchor")
	var stale := packet(4,[.3,.1,.6,.9]); stale.portrait_observation.frame_id = 3
	p.observe(stale,size)
	check(is_equal_approx(before,p.distance), "Stale observation rejected")
	p.automatic = false
	p.observe(packet(5,[.3,.1,.6,1]),size)
	check(is_equal_approx(before,p.distance), "Manual override persists")
	var grid := p.geometry(size)
	check(grid.surface_get_array_index_len(0) == 96*54*6, "96 longest-edge indexed mesh")
	check(p.geometry(size) == grid, "No per-frame mesh rebuild")
	check(Portrait.oriented_bounds([.2,.1,.4,.9],90).is_equal_approx(Rect2(.1,.2,.8,.2)), "Portrait observation follows source rotation")
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.geometry = 0; video.stereo_sbs = false; video.alpha_requested = true
	video._remember_file = false
	check(video.portrait_requested() and not video._layer_alpha(), "Mono Alpha uses eye-buffer mesh")
	check(video.set_depth_strength(.4) and video.alpha_requested and not video.depth_requested and is_equal_approx(video.portrait.strength,.4), "Strength updates relief without restarting inference")
	check(video.set_depth(false) and video.alpha_requested and is_zero_approx(video.portrait.strength), "Flat portrait retains Alpha")
	video.set_portrait_auto(false)
	check(not video.portrait.automatic, "Automatic distance has explicit override")
	check(video.toggle_depth() and video.portrait.strength > 0.0 and video.toggle_depth() and is_zero_approx(video.portrait.strength), "Toolbar double-click toggles relief both ways")
	video.portrait.automatic = true; video.portrait.distance = 3.5
	video.manual_portrait_pose()
	check(not video.portrait.automatic and is_equal_approx(video.portrait.distance,3.5), "Manual interaction preserves displayed anchor")
	var cut := Portrait.new(); cut.automatic = true; cut.calibrate(Vector3(0,0,6))
	cut.observe(packet(1,[.3,.1,.6,1]),Vector2(14,10))
	cut.observe(packet(2,[.3,.1,.6,1]),Vector2(14,10))
	check(is_equal_approx(cut.distance,1.0/(1.0/6.0+.3)), "6m to 1.2m target first stops at 2.14m")
	var inverse := 1.0/cut.distance
	cut.advance(2*333333+33333)
	check(1.0/cut.distance-inverse <= Portrait.SLEW/30.0+.00001, "Subsequent display frames slew within the inverse-distance limit")
	before = cut.distance
	cut.advance(2*333333+33333)
	check(is_equal_approx(before,cut.distance), "Repeated XR view or pause cannot move the anchor")
	var shot := Portrait.new(); shot.automatic = true; shot.calibrate(Vector3(0,0,6))
	var first := packet(1,[.3,.1,.6,1]); first.portrait_shot_id = 1
	shot.observe(first,Vector2(14,10))
	check(is_equal_approx(shot.distance,1.0/(1.0/6.0+.3)), "RGB shot uses its first matching Alpha for a bounded same-frame anchor")
	before = shot.distance
	var missing := {"frame_id":2,"pts_us":666666,"portrait_shot_id":2}
	shot.observe(missing,size); shot.advance(700000)
	check(is_equal_approx(shot.distance,before) and is_equal_approx(shot.target,before), "New shot without Alpha cannot continue the previous shot's distance slew")
	var delayed := packet(3,[.3,.1,.6,1]); delayed.portrait_shot_id = 2
	shot.observe(delayed,Vector2(14,10))
	var delayed2 := packet(4,[.3,.1,.6,1]); delayed2.portrait_shot_id = 2
	shot.observe(delayed2,Vector2(14,10))
	check(is_equal_approx(shot.distance,before), "Delayed confidence inside a shot cannot cause a late cut jump")
	var same_bounds := packet(5,[.3,.1,.6,1]); same_bounds.portrait_shot_id = 3
	shot.observe(same_bounds,Vector2(14,10))
	check(shot.distance < before and absf(1.0/shot.distance-1.0/before) <= Portrait.CUT_STEP+.00001, "Cut with identical person bounds changes the shot atomically and within the limit")
	video.set_portrait_enhanced(true)
	check(video.portrait.enhanced and video.alpha_requested and not video.depth_requested, "DA2 request keeps mono RVM and mesh presentation")
	var bridge := DepthBridge.new(); video.platform = bridge; video.media.session_id = 3
	video.portrait.strength = 1.0; video._sync_portrait(); video._sync_portrait()
	check(bridge.requests == [[3,true]], "Enable DA2 once per session, without per-frame bridge calls")
	video.portrait.fallback = ""; video.portrait.enhancement = {"active":false,"reason":"device_base_only"}
	check(video.portrait_error().is_empty() and not video.portrait_depth_status().is_empty(), "Base fallback is a quality status, not a 3D failure")
	video.set_depth_strength(0.0)
	check(bridge.requests.back() == [3,false], "Turning off relief releases the second model")
	video.platform = null; video.media.session_id = 0
	video.stereo_sbs = true
	check(not video.portrait_requested(), "Native stereo is unchanged")
	var menu := Menu.new(); root.add_child(menu)
	menu._state = {"has_video":true,"geometry":0,"stereo":false}
	check(menu._enabled("alpha"), "Alpha offered on ordinary 2D")
	menu._state.stereo = true
	check(not menu._enabled("alpha"), "Flat stereo eligibility unchanged")
	var mode := {"profile":"320x320","geometry":0,"stereo_sbs":false,"swap_eyes":false,"alpha_requested":false,
		"portrait_auto":false,"portrait_strength":.4,"portrait_enhanced":true}
	check(Memory.valid_mode(mode), "Portrait preferences accepted")
	mode.portrait_auto = true
	video._restore_saved_mode(mode)
	check(not video.portrait.automatic, "Legacy default-auto record cannot pull the cinema portrait nearer")
	mode.portrait_auto_explicit = true
	video._restore_saved_mode(mode)
	check(video.portrait.automatic and Memory.valid_mode(mode), "Explicit automatic-distance choice remains restorable")
	mode.portrait_auto_explicit = "true"
	check(not Memory.valid_mode(mode), "Malformed automatic-distance provenance rejected")
	mode.erase("portrait_auto_explicit")
	mode.portrait_strength = NAN
	check(not Memory.valid_mode(mode), "Invalid strength rejected")
	var camera := Camera3D.new(); root.add_child(camera); video.view_camera = camera
	video.stereo_sbs = false; video.geometry = 0; video.alpha_requested = true
	video.media.format = {"width":1920,"height":1080}
	video.portrait.automatic = false; video.screen_scale = 10.0
	video.set_flat_world_pose(Transform3D(Basis.IDENTITY,Vector3(0,0,-20))); video._apply_geometry()
	video.portrait.reference = Vector3(0,0,20); video.portrait.distance = 4.0
	video.portrait.active = true; video.portrait.automatic = true
	var visible_pose := video.portrait_world_pose()
	var visible_width := video._flat.size.x * .2
	video.set_portrait_auto(false)
	check((video.global_transform * video.flat_pose).is_equal_approx(visible_pose) and is_equal_approx(video._flat.size.x,visible_width), "Leaving automatic anchoring bakes the visible depth and size without a jump")
	check(is_equal_approx(video.screen_distance,4.0), "Manual distance begins at the displayed anchor")
	camera.free()
	menu.free(); video.free()
	print("Video portrait checks=%d failures=%d" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
