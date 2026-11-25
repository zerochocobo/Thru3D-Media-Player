extends RefCounted
## Frame interpolation for 2D->3D's stereo pairs: which two pairs, and how far between them, each display
## refresh shows. Godot draws the picture layer once a refresh for a display time the runtime predicts;
## a pair's source time (PTS) says where between two pairs that moment lies. When pairs are claimed only
## tells how the source's clock stands against the display's, followed slowly: a pair held a little longer
## for its depth map does not move the picture.
##
## Every pair shows `delay_ns` later than it was claimed (a source frame and a margin for late pairs), so
## the pair after it is there when the picture leaves it; MPV delays the audio as long.

## Sources of 10 to 33 frames a second, as the layer copy's interpolation (LayerCopy.kt).
const MIN_STEP_US := 30_000
const MAX_STEP_US := 100_000
## Refreshes a pair may come late by: claims fall on Godot's frames, and a pair taken for a depth map
## waits for it (Quest 3: 26 to 30 ms).
const MARGIN_PERIODS := 2.0
## A pause or a stall moves every claim after it: the clocks are matched afresh rather than caught up.
const OFFSET_RESET_NS := 30_000_000.0
const OFFSET_FOLLOW := 0.05
## Next to a pair the picture is the pair itself: sharper than one moved a few percent of the way.
const PHASE_SNAP := 0.04
## Pairs the native side keeps copies of (frame_interp.cpp's kFrames).
const KEPT := 4
## Two seconds of refreshes at 72 Hz; a quarter of them missed, two such windows running, is past what a
## busy moment explains. The first refreshes after a start are not counted: the textures are made and
## the shaders built then, and the headset's GPU clock has yet to follow the new load.
const OVERLOAD_REFRESHES := 144
const OVERLOAD_SHARE := 4
const OVERLOAD_WARMUP := 216

## The depth model shares the GPU with the pictures in between. With too little of it left, its maps come
## slower than the frames and the pairs are drawn with the map of a frame or two before: over DEPTH_FRAMES
## source frames fewer than DEPTH_SHARE of them got a new map, two such windows running (Quest 3, a 4K film:
## 69% with the pictures in between, every frame without them). The first window after a start is not judged.
const DEPTH_FRAMES := 48
const DEPTH_SHARE := 0.85

## [id, pts_us] of the pairs not yet left behind, oldest first.
var frames: Array = []
## 0 until two pairs a source frame apart have come.
var delay_ns := 0
## Godot missed too many refreshes while it drew the pictures in between, or the depth maps fell behind
## the frames (depth_starved says which).
var overloaded := false
var depth_starved := false
var _depth_mark := Vector2i(-1, -1) # the bridge's counts of maps and frames where the window began
var _depth_windows := -1 # slow windows running; -1: the window after a start
## For the debug report: the last window's share of frames with a new map.
var depth_share := 1.0
var _offset_ns := 0.0 # display time minus source time
var _last_pts := -1
var _next_id := 0
var _paced := 0
var _missed := 0
var _last_display := 0
var _warmup := OVERLOAD_WARMUP
var _slow_windows := 0
## For the debug report: refreshes missed of those counted since the start, and the last window's.
var missed_total := 0
var paced_total := 0
var last_window := 0

func clear() -> void:
	frames = []; delay_ns = 0; _last_pts = -1
	_paced = 0; _missed = 0; _last_display = 0; _warmup = OVERLOAD_WARMUP; _slow_windows = 0
	_depth_mark = Vector2i(-1, -1); _depth_windows = -1

## A pair claimed for the refresh shown at display_ns. Returns its id and the id of the pair it follows
## (-1: none, the picture starts again from this pair: the first one, a seek, a source too fast or slow).
func push(pts_us: int, display_ns: int, period_ns: int, speed: float) -> Vector2i:
	var rate := speed if speed > 0.0 else 1.0
	var step := int((pts_us - _last_pts) / rate) if _last_pts >= 0 else 0
	_last_pts = pts_us
	var observed := display_ns - pts_us * 1000.0 / rate
	var id := _next_id
	_next_id += 1
	if frames.is_empty() or step < MIN_STEP_US or step > MAX_STEP_US:
		frames = [[id, pts_us]]
		_offset_ns = observed
		return Vector2i(id, -1)
	if delay_ns <= 0: delay_ns = step * 1000 + int(MARGIN_PERIODS * period_ns)
	_offset_ns = observed if absf(observed - _offset_ns) > OFFSET_RESET_NS else _offset_ns + (observed - _offset_ns) * OFFSET_FOLLOW
	var before: int = frames.back()[0]
	if frames.size() >= KEPT: frames.pop_front()
	frames.append([id, pts_us])
	return Vector2i(id, before)

## Pairs taken so far.
func pushed() -> int:
	return _next_id

## What the refresh at display_ns shows: the pictures `before` and `after` (-1: none yet) and how far
## between them (0: `before` itself, 1: `after` itself). `settled`: the newest pair has been reached and
## nothing follows, so the picture is that pair until the next comes. Empty without a pair.
func pick(display_ns: int, speed: float) -> Dictionary:
	if frames.is_empty(): return {}
	var rate := speed if speed > 0.0 else 1.0
	var moment := (display_ns - delay_ns - _offset_ns) * rate / 1000.0
	while frames.size() >= 2 and moment >= frames[1][1]: frames.pop_front()
	var first: Array = frames[0]
	if frames.size() < 2: return {"before": first[0], "after": -1, "phase": 0.0, "settled": moment >= first[1]}
	return {"before": first[0], "after": frames[1][0], "phase": phase_between(moment, first[1], frames[1][1]), "settled": false}

static func phase_between(moment: float, first: int, second: int) -> float:
	if second <= first or moment <= first: return 0.0
	var phase := (moment - first) / float(second - first)
	return 0.0 if phase < PHASE_SNAP else 1.0 if phase > 1.0 - PHASE_SNAP else phase

## The bridge's running counts of depth maps made and frames taken, as its status reports them (a few
## times a second; the same numbers again change nothing).
func depth_counts(maps: int, taken: int) -> void:
	if _depth_mark.x < 0 or maps < _depth_mark.x or taken < _depth_mark.y:
		_depth_mark = Vector2i(maps, taken) # the first report, or the counts began again (another generation)
		return
	if taken - _depth_mark.y < DEPTH_FRAMES: return
	depth_share = float(maps - _depth_mark.x) / float(taken - _depth_mark.y)
	_depth_mark = Vector2i(maps, taken)
	if _depth_windows < 0:
		_depth_windows = 0
		return
	_depth_windows = _depth_windows + 1 if depth_share < DEPTH_SHARE else 0
	if _depth_windows >= 2:
		overloaded = true; depth_starved = true

## A refresh drawn with a picture in between. Display times more than a refresh and a half apart are a
## refresh Godot missed (a long gap is a pause, not a miss).
func paced(display_ns: int, period_ns: int) -> void:
	var gap := display_ns - _last_display
	var missed := _last_display > 0 and gap > period_ns * 3 / 2 and gap < period_ns * 20
	_last_display = display_ns
	if _warmup > 0:
		_warmup -= 1
		return
	_paced += 1; paced_total += 1
	if missed: _missed += 1; missed_total += 1
	if _paced < OVERLOAD_REFRESHES: return
	last_window = _missed
	_slow_windows = _slow_windows + 1 if _missed * OVERLOAD_SHARE > _paced else 0
	if _slow_windows >= 2: overloaded = true
	_paced = 0; _missed = 0
