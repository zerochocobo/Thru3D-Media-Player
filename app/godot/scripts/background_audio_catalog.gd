extends RefCounted
## Stable IDs are independent of translated titles and download URLs.
const MUSIC := [
	{"id": "yunhai", "label": "Cloud Sea", "style": "Calm"},
	{"id": "xingmian", "label": "Starlit Rest", "style": "Calm"},
	{"id": "chenguang", "label": "Morning Light", "style": "Joyful"},
	{"id": "weifeng", "label": "Breeze", "style": "Joyful"},
	{"id": "shiguang", "label": "Quiet Moments", "style": "Focus"},
	{"id": "manyou", "label": "Wander", "style": "Focus"}]
const AMBIENCE := [
	{"id": "mountain_stream", "label": "Mountain stream"},
	{"id": "ocean_waves", "label": "Ocean waves"},
	{"id": "forest_wind", "label": "Forest breeze"},
	{"id": "gentle_rain", "label": "Gentle rain"},
	{"id": "summer_night", "label": "Night crickets"},
	{"id": "distant_city", "label": "Distant city"}]
const EXTENSIONS := ["mp3", "ogg", "wav", "flac", "dts", "dtshd"]
const MAX_BYTES := 64 * 1024 * 1024

static func extension(name: String) -> String:
	return name.get_extension().to_lower()

static func supported(name: String) -> bool:
	return extension(name) in EXTENSIONS

static func entries(kind: String) -> Array:
	return MUSIC if kind == "music" else AMBIENCE

static func builtin(id: String, kind: String) -> Dictionary:
	for row in entries(kind):
		if row.id == id: return {"id": id, "label": row.label, "path": "res://assets/audio/%s.ogg" % id, "kind": kind}
	return {}

static func load_audio(path: String) -> AudioStream:
	if path.begins_with("res://"): return ResourceLoader.load(path, "AudioStream", ResourceLoader.CACHE_MODE_IGNORE) as AudioStream
	var stream: AudioStream
	match extension(path):
		"mp3": stream = AudioStreamMP3.load_from_file(path)
		"ogg": stream = AudioStreamOggVorbis.load_from_file(path)
		"wav": stream = AudioStreamWAV.load_from_file(path, {"force/max_rate": true, "force/max_rate_hz": 44100})
	# The global transport owns loop boundaries, including embedded WAV sample loops.
	if stream is AudioStreamWAV: stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	elif stream is AudioStreamOggVorbis or stream is AudioStreamMP3: stream.loop = false
	return stream
