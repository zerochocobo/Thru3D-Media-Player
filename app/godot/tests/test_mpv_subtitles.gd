extends SceneTree

const State := preload("res://scripts/mpv_subtitle_state.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	var accepted := true
	var calls: Array = []
	func set_mpv_subtitle(id: int, track: int) -> bool:
		calls.append([id, track])
		return accepted
	func set_mpv_playing(_id: int, _playing: bool) -> void:
		pass
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		return 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _initialize() -> void:
	I18n.use("en")
	var state := State.new()
	var pair := {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	var sample := {"session_id": 7, "sequence": 1, "generation": 3, "source_epoch": 2,
		"mpv_source_handle": 55, "command_id": 4, "required_command_id": 4, "track_id": "9",
		"timeline_valid": true, "age_ms": 20, "start_seconds": "1.0", "end_seconds": "2.0",
		"position_seconds": "1.5", "text": "中文字幕 😀\nSecond line"}
	state.select(9)
	check(state.observe(sample, 7, pair) and state.text == sample.text, "Unicode and line breaks must survive the current cue")
	var old := sample.duplicate(true)
	old.session_id = 6
	old.sequence = 99
	check(not state.observe(old, 7, pair) and state.text == sample.text, "Late old-session cue cannot erase current text")
	check(not state.observe(sample, 7, pair), "Duplicate/out-of-order sequence must be ignored")
	for mutation in [{"generation": 2}, {"source_epoch": 1}, {"mpv_source_handle": 54},
		{"command_id": 3}, {"track_id": "8"}, {"timeline_valid": false}, {"age_ms": 1001},
		{"start_seconds": ""}, {"end_seconds": ""}, {"position_seconds": "nan"},
		{"position_seconds": "0.99"}, {"position_seconds": "2.0"}]:
		state.clear(true)
		var invalid := sample.duplicate(true)
		invalid.merge(mutation, true)
		check(state.observe(invalid, 7, pair) and state.text.is_empty(), "Reject stale/invalid cue %s" % str(mutation))
	state.clear(true)
	var wrong_pair := pair.duplicate(true)
	wrong_pair.session_id = 6
	check(state.observe(sample, 7, wrong_pair) and state.text.is_empty(), "Bound frame must belong to the requested session")
	state.clear(true)
	check(state.observe(sample, 7, {}) and state.text.is_empty(), "No cue before a complete current video binding")
	state.select(0)
	state.clear(true)
	check(state.observe(sample, 7, pair) and state.text.is_empty(), "Disabled subtitles cannot show late text")
	state.select(-1)
	state.clear(true)
	check(state.observe(sample, 7, pair) and state.text == sample.text, "Automatic text track selection accepts actual MPV id")
	for seconds in [-10.0, -0.1, 0.1, 10.0]:
		state.set_delay(seconds); state.clear(true)
		var shifted := sample.duplicate(true)
		shifted.delay_seconds = seconds
		shifted.start_seconds = "20.0"; shifted.end_seconds = "21.0"
		shifted.position_seconds = str(20.5 + seconds)
		check(state.observe(shifted, 7, pair) and state.text == sample.text, "Text timing fence uses source time after delay: %s" % seconds)
		state.clear(true); shifted.position_seconds = str(21.0 + seconds)
		check(state.observe(shifted, 7, pair) and state.text.is_empty(), "Shifted cue disappears at its delayed end boundary")
		state.clear(true); shifted.position_seconds = str(20.5 + seconds); shifted.delay_seconds = 0.0
		check(state.observe(shifted, 7, pair) and state.text.is_empty(), "Old delay snapshot cannot bring back a stale cue")
	state.set_delay(0.0); state.clear(true)
	state.observe(sample, 7, pair)
	state.clear()
	check(state.text.is_empty() and state.sequence == 1, "Seek clears text and retains same-source sequence fence")
	state.clear(true)
	check(state.sequence == 0, "A fresh native source resets sequence")
	for codec in ["subrip", "webvtt", "ass", "ssa", "sami", "microdvd", "subviewer", "mov_text"]:
		check(State.text_codec(codec), "CC accepts common text codec " + codec)
	for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", ""]:
		check(not State.text_codec(codec), "CC excludes bitmap/unknown codec " + codec)
	check(State.supported_codec("hdmv_pgs_subtitle", true, true), "Flat video offers decoded PGS")
	check(not State.supported_codec("hdmv_pgs_subtitle", false, true), "VR hides PGS")
	check(not State.supported_codec("hdmv_pgs_subtitle", true, false), "Old native library cannot advertise PGS")
	check(State.supported_codec("ass", false, false), "VR retains text control without the PGS extension")
	state.select(9)
	state.clear(true)
	var pgs := sample.duplicate(true)
	pgs.text = ""
	pgs.start_seconds = ""
	pgs.end_seconds = ""
	pgs.bitmap = {"visible": true, "version": 2, "x": 10, "y": 80, "width": 50, "height": 10, "canvas_width": 100, "canvas_height": 100}
	check(state.observe(pgs, 7, pair) and not state.bitmap.is_empty() and state.text.is_empty(), "PGS uses native active-cue status even without a known end time")
	state.set_delay(2.0); state.clear(true)
	var delayed_pgs := pgs.duplicate(true); delayed_pgs.delay_seconds = 2.0
	check(state.observe(delayed_pgs, 7, pair) and not state.bitmap.is_empty(), "PGS accepts the native cue with its currently requested delay")
	state.clear(true); delayed_pgs.delay_seconds = 0.0
	check(state.observe(delayed_pgs, 7, pair) and state.bitmap.is_empty(), "Changing PGS timing cannot redisplay an old-delay bitmap")
	state.set_delay(0.0)
	for mutation in [{"generation": 2}, {"source_epoch": 1}, {"command_id": 3}, {"track_id": "8"}, {"age_ms": 1001}, {"timeline_valid": false}]:
		state.clear(true)
		var bad := pgs.duplicate(true)
		bad.merge(mutation, true)
		check(state.observe(bad, 7, pair) and state.bitmap.is_empty(), "PGS rejects stale state " + str(mutation))
	state.clear(true)
	var gap := pgs.duplicate(true)
	gap.bitmap.visible = false
	check(state.observe(gap, 7, pair) and state.bitmap.is_empty(), "PGS gap clears the old crop")
	state.clear(true)
	var overflow := pgs.duplicate(true)
	overflow.bitmap.width = 101
	check(state.observe(overflow, 7, pair) and state.bitmap.is_empty(), "PGS crop must fit its canvas")
	var video := Video.new()
	var host := Host.new()
	video.platform = host
	video.media.begin(7)
	video.media.generation = 3
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 5, "codec": "hdmv_pgs_subtitle"},
		{"id": 9, "codec": "ass"}, {"id": 12, "codec": "subrip"}]}}
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 9], "Cycle actual text ids and skip unsupported bitmap tracks")
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 12], "Next actual text track")
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 0], "Cycle includes subtitles off")
	check(video.cycle_subtitle_track(-1) and host.calls.back() == [7, 12], "Reverse cycle uses real ids")
	check(video.media.session_id == 7 and video.media.generation == 3, "Selecting subtitles preserves RVM/video processing generation")
	video.media.playback.details.pgs_supported = true
	check(video.subtitle_tracks().size() == 3, "Flat subtitle list includes PGS and both text tracks")
	check(video.set_subtitle_track(5) and host.calls.back() == [7, 5], "Flat PGS selection uses its actual MPV id")
	for mode in [1, 2, 3]:
		video.geometry = mode
		check(video.subtitle_tracks().size() == 2, "Immersive subtitle list hides PGS in mode " + str(mode))
		var before := host.calls.size()
		check(not video.set_subtitle_track(5) and host.calls.size() == before, "Stale PGS menu selection cannot reach native in VR")
	video.geometry = 0
	check(video.set_subtitle_track(12), "Restore selected text track for remaining controls")
	host.accepted = false
	check(not video.set_subtitle_track(9) and video.subtitles.requested_track == 12, "Rejected native choice preserves desired track")
	var count := host.calls.size()
	check(not video.set_subtitle_track(-2) and host.calls.size() == count, "Invalid track cannot reach native host")
	video.subtitles.text = "old cue"
	video.subtitles.sequence = 10
	check(video.seek_absolute(2000) and video.subtitles.text.is_empty() and video.subtitles.sequence == 10,
		"Seek immediately clears text while replacement processing is pending")
	video.subtitles.text = "old cue"
	video.set_alpha(true)
	check(video.subtitles.text.is_empty() and video.subtitles.requested_track == 12, "Alpha switch clears old cue and retains selected native track")
	video.media.playback = {"details": {"subtitle_tracks": []}}
	check(not video.cycle_subtitle_track(), "Source without text subtitles cannot advertise a track")
	# External tracks arrive after FILE_LOADED. CC must become available using the
	# actual codec/id without reopening playback (including WebVTT and SSA).
	for codec in ["subrip", "webvtt", "ass", "ssa", "sami", "microdvd"]:
		host.accepted = true
		video.subtitles.select(0)
		video.media.playback = {"details": {"subtitle_tracks": [{"id": 25, "codec": codec}]}}
		check(video.cycle_subtitle_track() and host.calls.back() == [7, 25], "Late external track enables CC: " + codec)
	video._layout_basename = "Movie.MKV"
	var ass := {"id": 31, "title": "Movie.ASS", "codec": "ass", "external": true}
	var srt := {"id": 32, "title": "movie.srt", "codec": "subrip", "external": true}
	video.media.playback = {"details": {"subtitle_tracks": [ass, srt]}}
	video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
	video._restore_tracks()
	check(video.subtitles.requested_track == 32 and not video._subtitle_auto_pending and video._track_choices.is_empty(), "Automatic selection prefers exact SRT over ASS without recording a manual choice")
	video.set_subtitle_track(31)
	video._restore_tracks()
	check(video.subtitles.requested_track == 31 and not video._subtitle_auto_pending, "Manual ASS selection survives future polls")
	video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
	video.media.playback.details.subtitle_tracks = [ass]
	video._restore_tracks()
	check(video.subtitles.requested_track == 31, "Missing SRT falls back to exact ASS")
	video.subtitles.select(0); video._queue_track_restore({"subtitle": {"id": 0}}); video._subtitle_auto_pending = true
	video._restore_tracks()
	check(video.subtitles.requested_track == 0 and not video._subtitle_auto_pending, "Remembered subtitles off takes priority over global automatic selection")
	video.subtitles.select(0); video._queue_track_restore({}); video.set_subtitle_auto_load(false)
	video._restore_tracks()
	check(video.subtitles.requested_track == 0 and not video._subtitle_auto_pending, "Disabled automatic selection leaves manual tracks available")
	video.media.playback.details.subtitle_tracks = [{"id": 33, "title": "movie.en.srt", "codec": "subrip", "external": true}, {"id": 34, "title": "movie.srt", "codec": "subrip", "external": false}]
	video.set_subtitle_auto_load(true)
	check(video.subtitles.requested_track == 33 and not video._subtitle_auto_pending, "Without an exact filename, automatic selection chooses the interface-language variant")
	video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
	video.media.playback.details.subtitle_tracks.append(srt)
	host.accepted = false; video._restore_tracks()
	check(video.subtitles.requested_track == 0 and video._subtitle_auto_pending, "Rejected native automatic choice remains pending")
	host.accepted = true; video._restore_tracks()
	check(video.subtitles.requested_track == 32 and not video._subtitle_auto_pending, "Late exact SRT is selected once the native bridge accepts it")
	# DLNA display labels need not be filenames, and its video title may omit the extension.
	for source in ["http://nas/media/%E5%BD%B1%E7%89%87%20%40SBS.mp4?token=fixture", "smb://saved-id/Movies/影片 @SBS.mp4"]:
		video.local_uri = source
		video._layout_basename = "影片 @SBS" if source.begins_with("smb:") else "Server display title"
		var dlna_ass := {"id": 41, "title": "zh · ASS", "codec": "ass", "external": true, "filename": "http://127.0.0.1:1234/session/%E5%BD%B1%E7%89%87%20%40SBS.ass"}
		var dlna_srt := {"id": 42, "title": "zh · SRT", "codec": "subrip", "external": true, "filename": "http://127.0.0.1:1234/session/%E5%BD%B1%E7%89%87%20%40SBS.srt"}
		video.media.playback.details.subtitle_tracks = [dlna_ass, dlna_srt]
		video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
		video._restore_tracks()
		check(video.subtitles.requested_track == 42, "Original external filename auto-selects SRT despite DLNA language/display labels: " + source)
		video.subtitles.select(0); video._queue_track_restore({"subtitle": {"id": 0}}); video._subtitle_auto_pending = true
		video._restore_tracks()
		check(video.subtitles.requested_track == 0 and not video._subtitle_auto_pending, "Remembered off still wins over original network filenames")
		video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
		video.media.playback.details.subtitle_tracks = [dlna_ass]
		video._restore_tracks()
		check(video.subtitles.requested_track == 41, "Original filename falls back to ASS")
		video.set_subtitle_track(41)
		video.media.playback.details.subtitle_tracks.append(dlna_srt)
		video._restore_tracks()
		check(video.subtitles.requested_track == 41, "Manual selection wins when a matching network SRT arrives later")
	video.local_uri = "http://nas/media/movie.mp4"
	video._layout_basename = "Movie.mp4"
	var language_tracks := [
		{"id": 51, "title": "movie.zh-TW.srt", "codec": "subrip", "external": true},
		{"id": 52, "title": "movie.chs.ass", "codec": "ass", "external": true},
		{"id": 53, "title": "ja · SRT", "codec": "subrip", "external": true},
		{"id": 54, "title": "English", "language": "eng", "codec": "subrip", "external": true},
		{"id": 55, "title": "zh · SRT", "codec": "subrip", "external": true}]
	for rule in [{"ui": "zh", "expected": 52}, {"ui": "zh_Hant", "expected": 51}, {"ui": "ja", "expected": 53}, {"ui": "en", "expected": 54}]:
		I18n.use(rule.ui)
		video.media.playback.details.subtitle_tracks = language_tracks.duplicate(true)
		video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
		video._restore_tracks()
		check(video.subtitles.requested_track == rule.expected and video._track_choices.is_empty(), "Interface-language fallback respects language and Chinese script: " + rule.ui)
		video.media.playback.details.subtitle_tracks.append(srt)
		video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
		video._restore_tracks()
		check(video.subtitles.requested_track == 32, "Exact filename takes priority over interface language: " + rule.ui)
	I18n.use("zh")
	for rule in [
		{"tracks": [language_tracks[0]], "expected": 0},
		{"tracks": [language_tracks[4]], "expected": 55},
		{"tracks": [{"id": 56, "title": "movie.chs.srt", "language": "eng", "codec": "subrip", "external": true}], "expected": 0},
		{"tracks": [{"id": 57, "title": "movie.zh-Hans.srt", "codec": "subrip", "external": false}], "expected": 0},
		{"tracks": [{"id": 58, "title": "Unknown subtitle", "codec": "subrip", "external": true}], "expected": 0},
		{"tracks": [{"id": 59, "title": "zh · ASS", "filename": "http://127.0.0.1/session/movie.zh_Hant.ass", "codec": "ass", "external": true}], "expected": 0},
		{"tracks": [{"id": 60, "title": "movie.zh_CN.srt", "codec": "subrip", "external": true}], "expected": 60},
		{"tracks": [{"id": 61, "title": "movie.zh-Hans-TW.srt", "codec": "subrip", "external": true}], "expected": 61},
		{"tracks": [{"id": 62, "title": "movie.chs.srt", "language": "fra", "codec": "subrip", "external": true}], "expected": 0}]:
		video.media.playback.details.subtitle_tracks = rule.tracks
		video.subtitles.select(0); video._queue_track_restore({}); video._subtitle_auto_pending = true
		video._restore_tracks()
		check(video.subtitles.requested_track == rule.expected, "Language fallback rejects conflicting scripts, embedded and unknown languages: " + str(rule))
	video.media.playback.details.subtitle_tracks = [language_tracks[1]]
	video.subtitles.select(0); video._queue_track_restore({}); video.set_subtitle_auto_load(false)
	video._restore_tracks()
	check(video.subtitles.requested_track == 0, "Disabled automatic loading also suppresses language fallback")
	video.subtitles.select(0); video._queue_track_restore({"subtitle": {"id": 0}}); video.set_subtitle_auto_load(true)
	video._restore_tracks()
	check(video.subtitles.requested_track == 0, "Remembered off takes priority over a matching interface language")
	I18n.use("en")
	video.free()
	if failures.is_empty():
		print("MPV subtitle host checks passed: %d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
