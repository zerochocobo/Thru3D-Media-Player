extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Fakes := preload("res://tests/test_photo_animation.gd")
var failures: Array[String] = []
var checks := 0

class Platform extends Fakes.Platform:
	var depth_config: Array[bool] = []
	var depth_reads := 0
	var depth_report := {"state":"ready", "token":1, "frame_id":1, "loop":0, "width":2, "height":2, "rect":[0,0,2,2]}
	func set_photo_animation_depth(_id: int, enabled: bool) -> bool:
		depth_config.append(enabled); return true
	func photo_animation_depth_pixels(_id: int, _token: int) -> PackedByteArray:
		depth_reads += 1; return PackedFloat32Array([0,1,0,1]).to_byte_array()
	func get_photo_animation_frame(_id: int) -> String:
		return JSON.stringify(report.merged({"depth":depth_report, "frame_id":report.get("token",1), "loop":report.get("loop",0)}, true))
	func prepare_photo_3d(_id: int, _strength: float) -> bool: return true

class Subject extends Photo:
	var still_preparations := 0
	func _prepare_depth(_id: int, _background: bool = false) -> bool:
		still_preparations += 1; return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var photo := Subject.new(); root.add_child(photo); photo.set_process(false); photo.gallery.set_process(false)
	var platform := Platform.new(); photo.platform = platform
	photo._metadata = {"animated":true}; photo._display_request = 1; photo._request = 1
	photo.queue = [{"uri":"file://motion.gif", "title":"Motion.gif"}]; photo.index = 0
	photo.auto_portrait = false; photo.spatial_preferred = false
	var image := Image.create(2,2,false,Image.FORMAT_RGBA8); image.fill(Color.BLUE); image.generate_mipmaps()
	photo._full_image = image; photo._display_result = {"image":image}; photo._texture = ImageTexture.create_from_image(image)
	photo._texture_full = true; photo._size = Vector2(2,2); photo.panel.visible = true
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo.animation.app_focused = func(): return true
	photo.animation.activate()
	check(photo.set_depth(true), "Motion conversion accepted")
	check(not photo.animation.paused, "Conversion does not freeze motion")
	photo.animation.tick()
	check(photo.depth_enabled and photo._depth_texture != null, "Realtime near map reaches the existing photo shader")
	check(photo.still_preparations == 0 and photo._display_depth_data.is_empty(), "Motion bypasses still inference and cache")
	check(not platform.pauses.back(), "Motion decoder continues while 3D is active")
	check(photo._stereo_texture == null, "Motion never reuses a still stereo pair")
	photo.animation.tick(); check(platform.depth_reads == 1, "Unchanged depth is not transferred again")
	photo.animation.toggle(); photo.animation.tick()
	check(photo.animation.paused and photo.depth_enabled, "Pause keeps current 3D frame")
	check(not photo._depth_source_allowed(1), "Paused motion rejects stale still-depth callbacks")
	photo.animation.toggle(); photo.animation.tick()
	check(not photo.animation.paused and photo.depth_requested and photo.depth_enabled, "Resume keeps moving 3D active")
	photo.set_depth_strength(1.5); photo.set_depth_position(25)
	check(photo._depth_rebuild_seconds == 0 and photo.still_preparations == 0, "Motion sliders never schedule still generation")
	check(not photo._spatial_auto_due, "Motion sliders never start static spatial processing")
	photo.set_screen_rotation(90)
	var axis: Vector2 = photo.material.get_shader_parameter("depth_shift_axis")
	check(absf(axis.x) < 0.001 and absf(axis.y + 1) < 0.001, "Rotated motion keeps horizontal eye separation")
	check(not photo._presentation_pending, "Motion rotation does not introduce a still loading cover")
	platform.report.loop = 1; platform.report.token = 2
	photo.animation.tick(); check(not photo.depth_enabled, "Loop clears the previous scene map")
	platform.depth_report.loop = 1; platform.depth_report.token = 2; platform.depth_report.frame_id = 2
	photo.animation.tick(); check(photo.depth_enabled, "New loop accepts its own depth")
	platform.depth_report.token = 3; platform.depth_report.frame_id = 99
	photo.animation.tick(); check(platform.depth_reads == 2, "Future color frame cannot lend depth to the current frame")
	platform.depth_report.frame_id = 2; platform.depth_report.rect = [0,0,99,2]
	photo.animation.tick(); check(platform.depth_reads == 2, "Malformed model rect is rejected before pixel transfer")
	photo.animation.app_focused = func(): return false
	photo.animation.tick()
	check(not photo.depth_enabled and not platform.depth_config.back(), "Focus loss releases dynamic work and clears its map")
	platform.depth_report.rect = [0,0,2,2]
	photo.animation.app_focused = func(): return true
	photo.animation.tick()
	check(photo.depth_enabled and platform.depth_config.back(), "Focus return starts a new dynamic map without still work")
	platform.report.ended = true; photo.animation.tick(); photo.animation.toggle()
	platform.report.ended = false; photo.animation.tick()
	check(platform.restarts == 1 and photo.depth_requested and photo.depth_enabled, "Finite replay preserves 3D and rebuilds its dynamic session")
	platform.depth_report.state = "failed"; photo.animation.tick()
	check(not photo.depth_enabled and photo.depth_error == "3D unavailable" and not platform.pauses.back(), "Depth failure preserves animated playback")
	photo.set_depth(false)
	check(not photo.depth_requested and not photo.animation.paused and not platform.depth_config.back(), "Off releases dynamic depth without pausing animation")
	photo.animation.close(); photo._metadata = {}; photo._display_depth_data = {}
	photo.set_depth(true)
	check(photo.still_preparations == 1 and not photo.animation.depth_mode, "Still image retains original photo preparation")
	photo.set_depth_strength(0.5)
	check(photo._depth_rebuild_seconds == 0.15, "Still strength retains original coalesced stereo rebuild")
	check(photo.material.get_shader_parameter("depth_shift_axis") == Vector2.RIGHT, "Still shader retains its original horizontal warp")
	check(not photo.material.get_shader_parameter("motion_depth"), "Moving-image shader branch is off for still photos")
	photo.set_depth(false)
	photo.platform = null; photo.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo animation depth: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
