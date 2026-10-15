extends SceneTree
## The Alpha model size chosen in the settings: every file opens with it, and a size still compiling
## (~40 s on first use) never stalls a playing Alpha session; it takes over once it is ready.
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Probe extends "res://scripts/mpv_video_display.gd":
	var cold: Array = []
	var switched: Array = []
	func profile_ready(value: String) -> bool: return not value in cold
	func set_profile(value: String) -> void:
		switched.append(value)
		profile = value

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var video := Probe.new()
	root.add_child(video)
	video.set_process(false)
	check(video.default_profile == "320x320" and video.profile == "320x320", "320 x 320 by default")
	video.select_profile("384x384")
	check(video.profile == "384x384" and video.default_profile == "384x384" and video.switched.is_empty(),
		"Without a video the size is simply taken for the next open")
	video.select_profile("1024x1024")
	check(video.default_profile == "384x384", "Only the offered sizes are accepted")
	video.local_uri = "file:///alpha.mp4"
	video.alpha_requested = true
	video.select_profile("256x256")
	check(video.switched == ["256x256"], "A compiled size switches a playing Alpha session at once")
	video.cold = ["512x512"]
	video.select_profile("512x512")
	check(video.profile == "256x256" and video.default_profile == "512x512" and video._profile_pending == "512x512",
		"A cold size keeps the playing session on its current size while it compiles")
	video._on_rvm_warmup(JSON.stringify({"profile_key": "512x512", "state": "warming"}))
	check(video.profile == "256x256" and video.warming.has("512x512"), "Still compiling: no switch")
	video._on_rvm_warmup(JSON.stringify({"profile_key": "512x512", "state": "ready"}))
	check(video.switched == ["256x256", "512x512"] and video._profile_pending.is_empty() and not video.warming.has("512x512"),
		"The session switches once the new size is ready")
	video.cold = ["384x384"]
	video.select_profile("384x384")
	video.select_profile("320x320")
	check(video._profile_pending.is_empty() and video.profile == "320x320", "A later choice replaces a pending one")
	video._on_rvm_warmup(JSON.stringify({"profile_key": "384x384", "state": "ready"}))
	check(video.profile == "320x320", "A warmup that finishes after another choice changes nothing")
	video.free()
	print("Alpha profile checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
