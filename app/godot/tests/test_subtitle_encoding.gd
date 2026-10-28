extends SceneTree
const Encoding := preload("res://scripts/file_subtitle_encoding.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const URI := "file:///subtitle-encoding/movie.mkv"
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var calls: Array = []
	var narration_calls: Array = []
	func set_mpv_subtitle_encoding(id: int, request: int, track: int, encoding: String) -> bool:
		calls.append([id, request, track, encoding]); return true
	func set_mpv_subtitle(_id: int, _track: int) -> bool: return true
	func set_mpv_subtitle_delay(_id: int, _delay: float) -> bool: return true
	func set_mpv_narration(_id: int, payload: String) -> bool: narration_calls.append(JSON.parse_string(payload)); return true
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/subtitle-encoding/memory-%d" % Time.get_ticks_usec())
	var track := {"id": 1, "external": true, "source_file": "movie.ko.smi", "title": "movie.ko.smi", "codec": "sami", "encoding": "auto"}
	var key := Encoding.Timing.track_key(track)
	var memory := Encoding.new(directory)
	check(memory.remember_track(URI, key, "windows-949") and memory.save(), "Manual encoding saves")
	var restored := Encoding.new(directory); restored.load_saved()
	check(restored.for_track(URI, key) == "windows-949", "Encoding survives reload")
	check(restored.for_track(URI, "other".sha256_text()) == "auto", "Other subtitle remains automatic")
	check(restored.for_track("file:///other.mkv", key) == "auto", "Other movie remains automatic")
	Privacy.configure_file_settings(Privacy.NONE)
	check(restored.for_track(URI, key) == "auto" and not restored.remember_track(URI, key, "Big5"), "No memory while file settings are disabled")
	Privacy.configure_file_settings(Privacy.ALL)
	check(restored.for_track(URI, key) == "windows-949", "Disabling memory does not erase it")
	check(not memory.remember_track(URI, key, "invalid"), "Unknown codecs are rejected")
	var row := Encoding.row(track, URI)
	check(row.value.encoding == "auto" and row.dropdown and row.choices.size() == 9, "Default automatic uses one dropdown")
	check(Encoding.row({"id": 2, "codec": "subrip", "external": false}, URI).is_empty(), "Embedded subtitles have no encoding control")
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	var state := {"has_video": true, "source_uri": URI, "subtitle_track": 1, "subtitle_options": [track], "subtitle_encoding_row": row}
	menu.state_provider = func(): return state
	menu._state = state
	check(not menu._subtitle_controls().any(func(r): return r.get("title") == "Subtitle encoding"), "Encoding is hidden in collapsed adjustments")
	menu._subtitle_appearance_open = true
	check(menu._subtitle_controls().filter(func(r): return r.get("title") == "Subtitle encoding").size() == 1, "Expanded adjustments have one encoding row")
	state.listening_enabled = true
	check(not menu._subtitle_controls().any(func(r): return r.get("title") == "Subtitle encoding"), "Live subtitles omit encoding")
	var video := Video.new(); root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host; video.local_uri = URI; video._remember_file = true
	video.subtitle_encoding = Encoding.new(directory + "-session")
	video.subtitle_timing.directory = directory + "-timing"
	video.media.begin(31); video.media.playback = {"details": {"subtitle_tracks": [track]}}
	var old_metadata := track.duplicate(true); old_metadata.erase("source_file"); old_metadata.erase("encoding")
	video.subtitle_timing.remember_track(URI, Encoding.Timing.track_key(old_metadata), 1.3)
	check(video.set_subtitle_track(1, false) and is_equal_approx(video.subtitle_delay, 1.3), "Existing server timing migrates to stable subtitle identity")
	video.subtitles.select(1)
	check(video.set_subtitle_encoding(row.choices[1].value), "Manual choice queues conversion")
	check(not video.set_subtitle_encoding(row.choices[2].value), "Concurrent changes are rejected")
	var request: int = host.calls.back()[1]
	var result := {"operation": "encoding", "request": request, "state": "ready", "old_track_id": 1, "track_id": 4, "encoding": "windows-949"}
	video._on_subtitle_files(31, JSON.stringify(result))
	check(video.subtitles.requested_track == 1 and not video._encoding_pending.is_empty(), "Wait for replacement metadata before selecting")
	var replacement := track.duplicate(true); replacement.id = 4; replacement.encoding = "windows-949"
	video.media.playback.details.subtitle_tracks = [replacement]
	video.narration.source = 1
	video._finish_subtitle_encoding()
	check(video.subtitles.requested_track == 4 and video.narration.source == 4, "Display and explicit narration follow replacement")
	check(video.subtitle_encoding.for_track(URI, key) == "windows-949", "Save only after native success")
	var stale: Dictionary = row.choices[2].value
	check(not video.set_subtitle_encoding(stale), "Stale track selection is rejected")
	var next := Encoding.row(replacement, URI).choices[2].value as Dictionary
	check(video.set_subtitle_encoding(next), "Second manual change accepted")
	video.subtitles.select(9)
	var newer := replacement.duplicate(true); newer.id = 5; newer.encoding = "GB18030"
	video.media.playback.details.subtitle_tracks = [newer, {"id": 9, "codec": "subrip"}]
	result.request = host.calls.back()[1]; result.old_track_id = 4; result.track_id = 5
	video._on_subtitle_files(31, JSON.stringify(result))
	check(video.subtitles.requested_track == 9, "Late encoding completion does not steal a new selection")
	check(video.narration.source == 5, "Explicit narration remaps independently")
	check(video.subtitle_encoding.for_track(URI, key) == "GB18030", "Independent correction retains stable identity")
	# Encoding choices made without permission to remember must not be backfilled.
	Privacy.configure_file_settings(Privacy.NONE)
	check(video.set_subtitle_encoding(Encoding.row(newer, URI).choices[3].value), "Private encoding choice accepted")
	Privacy.configure_file_settings(Privacy.ALL)
	var private_track := newer.duplicate(true); private_track.id = 6; private_track.encoding = "Big5"
	video.media.playback.details.subtitle_tracks = [private_track]
	result.request = host.calls.back()[1]; result.old_track_id = 5; result.track_id = 6
	video._on_subtitle_files(31, JSON.stringify(result))
	check(video.subtitle_encoding.for_track(URI, key) == "GB18030", "Enabling memory cannot backfill an in-flight private choice")
	check(video.set_subtitle_encoding(Encoding.row(private_track, URI).choices[1].value, true), "Remembered override can be restored")
	check(not video.set_subtitle_track(6, false), "Restoration waits for encoding before display or narration can select it")
	var restored_track := private_track.duplicate(true); restored_track.id = 7; restored_track.encoding = "windows-949"
	video.media.playback.details.subtitle_tracks = [restored_track]
	result.request = host.calls.back()[1]; result.old_track_id = 6; result.track_id = 7
	video._on_subtitle_files(31, JSON.stringify(result))
	check(video.set_subtitle_track(7, false), "Restored track becomes selectable after conversion")
	check(video.set_subtitle_encoding(Encoding.row(restored_track, URI).choices[3].value), "Manual correction before clear accepted")
	video.discard_file_settings()
	check(not video._encoding_pending.persist, "Clearing settings prevents pending choice from writing back")
	video._encoding_pending.clear(); video._encoding_choices.clear(); video._encoding_attempts.clear()
	video.media.playback.details.subtitle_tracks = [track]
	video.subtitles.select(0)
	video.subtitle_encoding.remember_track(URI, key, "windows-949")
	check(not video.subtitle_encoding_ready(1), "Saved encoding is required even before the restore request is dispatched")
	video.narration.enabled = true; video.narration.source = 1; video.subtitles.select(1)
	video.narration.apply()
	check(not host.narration_calls.back().enabled, "Explicit narration waits for saved encoding")
	video.subtitles.select(0)
	video._subtitle_load_request = 99; video._subtitle_loaded_track = 1; video._subtitle_load_restore = true
	video._finish_subtitle_file()
	check(video.subtitles.requested_track == 0 and video._subtitle_loaded_track == 1 and not video._encoding_pending.is_empty(), "Arbitrary restored file waits for its saved encoding")
	video.media.playback.details.subtitle_tracks = [replacement]
	result.request = host.calls.back()[1]; result.old_track_id = 1; result.track_id = 4
	video._on_subtitle_files(31, JSON.stringify(result))
	video._finish_subtitle_file()
	check(video.subtitles.requested_track == 4 and video._subtitle_load_request == 0, "Arbitrary file selects corrected replacement after restoration")
	video.narration.apply()
	check(host.narration_calls.back().enabled and int(host.narration_calls.back().source) == 4, "Narration starts on the same corrected track")
	video._remember_file = false; video.platform = null; video.free(); menu.free()
	for failure in failures: push_error(failure)
	print("Subtitle encoding checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
