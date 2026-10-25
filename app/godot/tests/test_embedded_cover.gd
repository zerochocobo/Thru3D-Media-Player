extends SceneTree
const Fixtures := preload("res://tests/test_layer_thumbnail.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var failures: Array[String] = []
var checks := 0

class Bridge extends Fixtures.BridgeProbe:
	var covers := 0
	var cancelled := 0
	var cover_state := "pending"
	var cover_bytes := PackedByteArray()
	func request_embedded_cover(_uri: String) -> int: covers += 1; return covers
	func embedded_cover_state(_id: int) -> String: return cover_state
	func take_embedded_cover(_id: int) -> PackedByteArray: return cover_bytes
	func cancel_embedded_cover(_id: int) -> void: cancelled += 1

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func make_video(bridge: Bridge, name: String) -> Video:
	var video := Video.new(); video.platform = bridge
	root.add_child(video)
	video.material = ShaderMaterial.new(); video._binding = Fixtures.BindingProbe.new()
	var pair := {"session_id": 3, "slot_token": 9, "color_target": "layer", "pts_us": 12000000,
		"source_epoch": 1, "width": 1920, "height": 1080}
	video._binding.bind(video.material, pair); video.media.begin(3)
	video.media.state = "playing"; video.media.last_pair = pair
	video.local_uri = "smb://fixture/" + name; video.display_name = name
	video.video_layer_shown = true; video._thumb_after_ms = 0
	return video

func _initialize() -> void:
	await process_frame
	var previous: String = Privacy.mode; Privacy.mode = Privacy.NONE
	var bridge := Bridge.new(); var video := make_video(bridge, "embedded-present.MKV")
	video._maybe_capture_thumbnail(); video._maybe_capture_thumbnail()
	check(bridge.covers == 1 and bridge.requests.is_empty(), "Await the cover once before reading a playback surface")
	var image := Image.create(16, 24, false, Image.FORMAT_RGB8); image.fill(Color.DARK_RED)
	bridge.cover_bytes = image.save_png_to_buffer(); bridge.cover_state = "ready"
	video._maybe_capture_thumbnail()
	check(Thumbnails.has(video.local_uri) and video._thumbnail_result.get("source") == "embedded_cover", "Use the embedded image as the thumbnail")
	check(not FileAccess.file_exists(Thumbnails.path_for(video.local_uri)), "Private viewing keeps artwork in memory")
	check(video._thumb_after_ms < 0 and bridge.requests.is_empty() and bridge.pins == 0, "An embedded cover avoids both GPU readback paths")
	video.free()
	bridge = Bridge.new(); bridge.cover_state = "ready"; bridge.pending = 0
	video = make_video(bridge, "embedded-absent.mkv"); video._maybe_capture_thumbnail()
	while video._layer_thumbnail_busy: await process_frame
	check(bridge.covers == 1 and bridge.requests.size() == 1 and Thumbnails.has(video.local_uri), "No cover falls back to the existing frame capture")
	video.free()
	bridge = Bridge.new(); bridge.pending = 0
	video = make_video(bridge, "embedded-timeout.mkv"); video._maybe_capture_thumbnail()
	video._cover_deadline = 0; video._maybe_capture_thumbnail()
	while video._layer_thumbnail_busy: await process_frame
	check(bridge.cancelled == 1 and bridge.requests.size() == 1, "A slow cover read cancels and falls back")
	video.free()
	bridge = Bridge.new(); video = make_video(bridge, "embedded-close.mkv")
	video._maybe_capture_thumbnail(); video.close_video()
	check(bridge.cancelled == 1 and video._cover_request == 0, "Closing a video releases a pending cover reader")
	video.free()
	bridge = Bridge.new(); bridge.pending = 0
	video = make_video(bridge, "ordinary.mp4"); video._maybe_capture_thumbnail()
	while video._layer_thumbnail_busy: await process_frame
	check(bridge.covers == 0 and bridge.requests.size() == 1, "Ordinary video keeps its existing thumbnail path")
	video.free(); Thumbnails._private_images.clear(); Privacy.mode = previous
	print("Embedded cover checks: %s (%d)" % ["passed" if failures.is_empty() else "FAILED", checks])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
