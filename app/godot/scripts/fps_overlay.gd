extends Label3D
## Head-locked frame-rate readout: presented video frames (with the Alpha cap) and the headset's render rate.

const WINDOW := 0.5 # seconds per sample
## Shared upper-left anchor for passive playback feedback, in camera-local metres.
const HUD_POSITION := Vector3(-0.42, 0.30, -0.75)

## Returns {"frames": int presented-pair count, "target": int Alpha cap or 0, "active": bool}.
var source: Callable
var _elapsed := 0.0
var _frames := -1
## Previous decoder drops, VO drops and late frames, for per-window increments.
var _counters := [-1, -1, -1]

func _ready() -> void:
	position = HUD_POSITION
	pixel_size = 0.0007
	font_size = 32
	outline_size = 8
	horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	no_depth_test = true
	render_priority = 120
	outline_render_priority = 119
	modulate = Color(0.75, 1.0, 0.8)

func _process(delta: float) -> void:
	if not visible: return
	_elapsed += delta
	if _elapsed < WINDOW: return
	var sample: Dictionary = source.call() if source.is_valid() else {}
	var frames := int(sample.get("frames", 0))
	var video := float(frames - _frames) / _elapsed if _frames >= 0 and frames >= _frames else 0.0
	_frames = frames
	_elapsed = 0.0
	var render := "XR %d" % roundi(Engine.get_frames_per_second())
	if not sample.get("active", false):
		text = render + " FPS"
		return
	var target := int(sample.get("target", 0))
	text = "%s %.1f%s · %s FPS" % ["Alpha" if target > 0 else "Video", video, " / %d" % target if target > 0 else "", render]
	# Compositor layer (L) or eye buffers (E): the path decides most of the GPU cost.
	if sample.has("path"): text += " " + str(sample.path)
	# Second line: decoder drops / VO drops / late frames in this window, A/V offset, cache wait.
	if sample.has("vo_drops"):
		var now := [int(sample.decoder_drops), int(sample.vo_drops), int(sample.vo_late)]
		var added := []
		for i in now.size(): added.append(maxi(0, now[i] - _counters[i]) if _counters[i] >= 0 else 0)
		_counters = now
		var avsync: String = str(sample.get("avsync", ""))
		var offset := "%+d ms" % roundi(avsync.to_float() * 1000.0) if avsync.is_valid_float() else "-"
		text += "\nD%d V%d L%d · AV %s%s" % [added[0], added[1], added[2], offset, " · CACHE" if sample.get("cache", false) else ""]

func set_shown(shown: bool) -> void:
	visible = shown
	_elapsed = 0.0
	_frames = -1
	_counters = [-1, -1, -1]
	text = ""
