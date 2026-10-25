extends SceneTree
const Capture := preload("res://scripts/video_capture.gd")
const Recipe := preload("res://scripts/pip_screenshot.gd")
const Pip := preload("res://scripts/video_pip.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends RefCounted:
	var requests: Array = []
	var samples: Array = []
	var stops: Array = []
	func original_capture_supported() -> bool: return true
	func original_capture_request(value: String) -> int:
		requests.append(JSON.parse_string(value)); return requests.size()
	func original_capture_stop(id: int, end_us: int) -> bool:
		stops.append([id, end_us]); return true
	func original_capture_clock(_id: int, _position: int, _playing: bool) -> void: pass
	func original_capture_pip(id: int, position: int, value: String) -> void:
		samples.append([id, position, JSON.parse_string(value)])
	func original_capture_status(_id: int) -> String: return "{}"
class Binding extends RefCounted:
	func unshare(_material: ShaderMaterial) -> void: pass
class Video extends Node3D:
	const SPHERE_RADIUS := 50.0
	var platform := Platform.new()
	var geometry := 1
	var packed_file := false
	var stereo_sbs := true
	var top_bottom := false
	var stereo_half := false
	var swap_eyes := false
	var fisheye_fov := 180
	var local_uri := "cloud://test/film.mp4"
	var media := {"state": "paused", "session_id": 7, "playback": {}}
	var requested_play := false
	var playback_speed := 1.0
	var view_camera: Camera3D
	var panel: MeshInstance3D
	var pip: RefCounted
	var _binding := Binding.new()
	func bookmark_snapshot() -> Dictionary: return {"position_ms": 12345}
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var video := Video.new(); root.add_child(video)
	video.view_camera = Camera3D.new(); video.add_child(video.view_camera)
	video.panel = MeshInstance3D.new(); video.add_child(video.panel)
	video.pip = Pip.new(video)
	var capture := Capture.new(video)
	check(capture.screenshot() and not video.platform.requests[-1].has("pip"), "No PiP keeps the original screenshot request")
	capture.jobs.clear()
	video.pip.set_count(2, Transform3D.IDENTITY)
	for window in video.pip.windows.values(): window.frame.visible = true
	var first: Node3D = video.pip.windows[1]
	first.global_transform = Transform3D(Basis.IDENTITY, Vector3(0,0,-2))
	first.crop_parameters()
	check(capture.screenshot(), "Visible PiP automatically selects composition on the same button")
	var request: Dictionary = video.platform.requests[-1]
	check(request.kind == "screenshot" and request.position_us == 12345000 and request.mode.geometry == 1 and request.mode.stereo_sbs, "Composition preserves source PTS and complete VR stereo metadata")
	check(request.pip.windows.size() == 2, "Every visible window is snapshotted in stack order")
	var window: Dictionary = request.pip.windows[0]
	check(window.axes == [50.0,0.0,0.0,0.0,50.0,0.0,0.0,0.0,50.0] and window.anchor == [0.0,0.0,2.0], "Recipe maps source sphere points into the actual window plane")
	check(window.left[0] < 0 and window.right[0] > 0 and is_equal_approx(window.left[2], 2), "Separate eye origins preserve the window's spatial disparity")
	check(window.source_eye == 0 and window.tangent[0] > 0 and window.feather[0] > 0, "Fixed 2D PiP source eye, crop and feather are preserved")
	first.global_position.x = 3; first.zoom = 8; video.swap_eyes = true; first.crop_parameters()
	check(window.anchor == [0.0,0.0,2.0] and window.tangent[0] > first.tangent().x, "Moving or zooming after the click cannot mutate the submitted snapshot")
	check(Recipe.snapshot(video).windows[0].source_eye == 1, "Swapped eyes select the same PiP source as the live renderer")
	first.crop_parameters({"basis": Basis(Vector3.UP, 0.4)})
	check(is_equal_approx(float(Recipe.snapshot(video).windows[0].crop[0]), -sin(0.4)), "An active crop preview uses the displayed shader direction, not the old committed crop")
	first.image_mode = true; first.capture_image = {"id": 8, "orientation": 6}
	check(Recipe.snapshot(video).windows[0].image == {"id":8,"orientation":6}, "Static image composition refers only to an existing local preview lease")
	first.capture_image.clear()
	check(Recipe.snapshot(video).is_empty(), "A visible image without pixels fails instead of silently exporting an incomplete screenshot")
	capture.jobs.clear()
	var queued: int = video.platform.requests.size()
	check(not capture.screenshot() and not capture.notice.is_empty() and video.platform.requests.size() == queued, "An incomplete PiP snapshot is reported without queuing a source-only substitute")
	first.image_mode = false; first.visible = false
	check(Recipe.snapshot(video).windows.size() == 1, "Hidden windows are omitted")
	video.pip.clear(); capture.jobs.clear()
	check(capture.screenshot() and not video.platform.requests[-1].has("pip"), "Closing the windows immediately restores the original path")
	capture.jobs.clear()
	check(capture.start() and not video.platform.requests[-1].has("pip"), "No PiP recording keeps the packet path")
	video.pip.set_count(1, Transform3D.IDENTITY)
	video.pip.windows[1].frame.visible = true
	capture.tick()
	check(video.platform.samples.size() == 1 and video.platform.samples[-1][2].windows.size() == 1, "Opening PiP mid-recording promotes the local export with source-time samples")
	video.pip.windows[1].global_position.x = 0.5
	capture._pip_after = 0; capture.tick()
	check(video.platform.samples.size() == 2 and video.platform.samples[0][2] != video.platform.samples[1][2], "Window motion updates the recorded recipe")
	video.pip.clear(); capture._pip_after = 0; capture.tick()
	check(video.platform.samples[-1][2].windows.is_empty(), "Closing all windows records an empty layout")
	check(capture.stop() and video.platform.stops.size() == 1, "Composed recording uses the existing stop path")
	capture.jobs.clear(); video.pip.set_count(1, Transform3D.IDENTITY)
	video.pip.windows[1].frame.visible = true
	check(capture.start() and video.platform.requests[-1].pip.windows.size() == 1, "Starting with PiP pins an initial layout")
	video.geometry = 3; capture.tick()
	check(capture.recording.is_empty(), "Projection changes finish the clip before inconsistent metadata is recorded")
	video.free()
	print("PiP screenshot checks: %d, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
