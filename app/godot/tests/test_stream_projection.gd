extends SceneTree
const StreamProjection := preload("res://scripts/stream_projection.gd")
class Platform extends RefCounted:
	var payload := '{"version":1,"geometry":1,"kind":"mesh","stereo_mode":2,"meshes":[]}'
	func web_video_projection(_uri: String) -> String:
		return payload
func _initialize() -> void:
	var platform := Platform.new()
	var data := StreamProjection.read(platform,"https://www.youtube.com/watch?v=9r6NI9m_IxM")
	if data.is_empty():
		push_error("Native JSON integer metadata rejected by Godot numeric conversion")
		quit(1); return
	assert(StreamProjection.stereo(data))
	for file in ["youtube-vr180-avc.mp4", "youtube-vr180-av1.mp4", "youtube-vr180-vp9.webm", "youtube-eac-vp9.webm", "youtube-360-tb.mp4"]:
		platform.payload = FileAccess.get_file_as_string("res://../../android/player-plugin/build/test-projection/"+file+".json")
		data = StreamProjection.read(platform,"fixture")
		assert(not data.is_empty(),file)
		var mesh := StreamProjection.mesh(data)
		assert((mesh == null) == file.contains("360-tb"),file)
	platform.payload = '{"version":2,"geometry":1}'
	assert(StreamProjection.read(platform,"fixture").is_empty())
	platform.payload = '{"version":1,"geometry":99}'
	assert(StreamProjection.read(platform,"fixture").is_empty())
	print("Native projection JSON bridge passed")
	quit(0)
