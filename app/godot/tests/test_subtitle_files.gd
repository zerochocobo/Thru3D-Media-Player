extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const Tracks := preload("res://scripts/file_track_memory.gd")
const Modes := preload("res://scripts/file_mode_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const URI := "file:///subtitle-files-test/film.mp4"
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var serial := 200
	var opens := 0
	var lists: Array = []
	var loads: Array = []
	var tracks: Array = []
	var delays: Array = []
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		serial += 1; opens += 1; return serial
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_subtitle(id: int, track: int) -> bool: tracks.append([id, track]); return true
	func set_mpv_subtitle_delay(id: int, seconds: float) -> bool: delays.append([id, seconds]); return true
	func list_mpv_subtitle_files(id: int, request: int) -> bool: lists.append([id, request]); return true
	func load_mpv_subtitle_file(id: int, request: int, filename: String) -> bool: loads.append([id, request, filename]); return true

func check(ok: bool, description: String) -> void:
	checks += 1
	if not ok: failures.append(description)

func track(id: int, filename: String) -> Dictionary:
	return {"id": id, "title": filename, "source_file": filename, "external": true, "codec": "ass" if filename.ends_with(".ass") else "subrip"}

func reply(video: Node, operation: String, request: int, values: Dictionary, id: int = -1) -> void:
	var result := values.duplicate(true); result.operation = operation; result.request = request
	video._on_subtitle_files(video.media.session_id if id < 0 else id, JSON.stringify(result))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	Privacy.configure(Privacy.ALL)
	var directory := "user://subtitle-files-%d" % Time.get_ticks_usec()
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.mode_memory = Modes.new(directory + "/modes")
	video.track_memory = Tracks.new(directory + "/tracks")
	video.subtitle_timing = Timing.new(directory + "/timing")
	var host := Host.new(); video.platform = host
	check(video.open_local(URI, "Film", 0, true, false, "film.mp4"), "Open a video without touching the actual media source")
	for uri in [URI, "usb://disk/film.mp4", "smb://server/share/film.mp4", "cloud://account/film.mp4", "content://com.android.externalstorage.documents/tree/ABCD%3AFilms/document/ABCD%3AFilms%2Ffilm.mp4"]:
		video.local_uri = uri; check(video.subtitle_files_available(), "Directory picker is available: " + uri)
	for uri in ["https://example.test/film.mp4", "dlna://server/123", "medialib://server/123", "content://media/external/video/42"]:
		video.local_uri = uri; check(not video.subtitle_files_available(), "A stream or single-document grant does not claim sibling access")
	video.local_uri = URI
	var main := Main.new(); main.video = video
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.subtitle_requested.connect(video.set_subtitle_track)
	menu.subtitle_files_requested.connect(video.request_subtitle_files)
	menu.subtitle_file_requested.connect(video.select_subtitle_file)
	menu.setting_requested.connect(main._on_player_setting)
	video.subtitle_auto_load = false
	menu.toggle(); menu._activate(110)
	check(not menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_FILES) and host.lists.size() == 1, "Opening the subtitle menu checks candidates before showing an entry")
	menu._activate(Menu.SUBTITLE_FILES)
	check(host.lists.size() == 1 and not menu._subtitle_files_open, "An unconfirmed entry stays hidden even with automatic subtitle loading disabled")
	var request: int = host.lists.back()[1]
	reply(video, "list", request + 1, {"state": "ready", "files": ["wrong.srt"]})
	check(video.subtitle_files.is_empty() and video.subtitle_files_state == "loading", "An older list request cannot replace current candidates")
	var files: Array = ["film.srt", "different.ass", "../escape.srt"]
	for index in 12: files.append("film.%02d.srt" % index)
	reply(video, "list", request, {"state": "ready", "files": files})
	check(video.subtitle_files.size() == 14 and video.subtitle_files.has("film.11.srt"), "The manual list includes nonmatching and ninth-or-later files, and rejects paths")
	video.media.playback = {"details": {"subtitle_tracks": [track(1, "film.srt")]}}
	video.subtitle_timing.remember(URI, {"delay_seconds": 0.9}); video.subtitle_timing.save()
	check(video.set_subtitle_track(1, false) and is_equal_approx(video.subtitle_delay, 0.9), "The restored matching track inherits the legacy per-video correction once")
	check(video.set_subtitle_track(1), "An already available subtitle can be selected")
	var first_key: String = video.subtitle_timing_key()
	check(video.commit_subtitle_delay(1.2, URI, first_key), "The matching subtitle has its own correction")
	menu.refresh()
	check(menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_FILES), "Confirmed other files expose the disclosure below existing subtitles")
	menu._activate(Menu.SUBTITLE_FILES)
	check(not menu._other_subtitle_files().has("film.srt"), "Already loaded subtitles do not duplicate the upper list")
	menu.stick_scroll(-1.0, 0.3)
	check(menu._subtitle_files_offset > 0 and menu._subtitle_offset == 0, "Stick scrolling moves the expanded file list")
	menu._subtitle_files_offset = 0; menu.refresh()
	var target: int = menu._subtitle_file_ids.keys().filter(func(k): return menu._subtitle_file_ids[k] == "different.ass")[0]
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == target)[0]
	var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
	menu.update_pointer("right", origin, -menu.global_basis.z, true)
	check(host.loads.is_empty(), "Hovering does not select a subtitle")
	menu.press_pointer("right", origin, -menu.global_basis.z, true)
	menu.release_pointer("right", origin, -menu.global_basis.z, true)
	check(host.loads.size() == 1 and video.subtitles.requested_track == 1, "The pointing hand's trigger starts one optional load while keeping the current subtitle")
	request = host.loads.back()[1]
	reply(video, "load", request, {"state": "error"})
	check(video.subtitles.requested_track == 1 and is_equal_approx(video.subtitle_delay, 1.2), "A failed optional subtitle preserves selection and timing")
	check(video.select_subtitle_file("different.ass"), "Retry the same file")
	request = host.loads.back()[1]
	video.control.observed_position_ms = 42000; video.playback_speed = 1.5; video.requested_play = false
	reply(video, "load", request, {"state": "ready", "track_id": 3})
	check(video.subtitles.requested_track == 1, "A load receipt waits until the actual track list is visible")
	video.media.playback = {"details": {"subtitle_tracks": [track(1, "film.srt"), track(3, "different.ass")]}}
	video._restore_tracks()
	var second_key: String = video.subtitle_timing_key()
	check(video.subtitles.requested_track == 3 and video.subtitle_delay == 0 and second_key != first_key, "The new file switches without inheriting another version's offset")
	check(host.opens == 1 and video.control.observed_position_ms == 42000 and video.playback_speed == 1.5 and not video.requested_play, "Switching does not reopen, seek, change rate, or resume the video")
	check(video.commit_subtitle_delay(-2.3, URI, second_key), "The second version saves a different correction")
	check(video.set_subtitle_track(1) and is_equal_approx(video.subtitle_delay, 1.2), "Switching back restores the first version's correction")
	check(video.commit_subtitle_delay(-2.8, URI, second_key) and is_equal_approx(video.subtitle_delay, 1.2), "A late slider commit saves its original pair without shifting the active pair")
	main._on_playback_adjustment("subtitle_delay", {"value": 9.0, "source_uri": URI, "subtitle_key": second_key})
	check(is_equal_approx(video.subtitle_delay, 1.2), "A stale slider preview cannot shift a newly selected subtitle")
	check(video.set_subtitle_track(3) and is_equal_approx(video.subtitle_delay, -2.8), "Returning to the second file restores its latest correction")
	var choice: Dictionary = video.track_memory.lookup(URI).subtitle
	check(choice.file == "different.ass" and Tracks.valid_choice(choice), "The chosen relative filename is saved with the existing track identity")
	var stored_tracks := Tracks.new(video.track_memory.directory); stored_tracks.load_saved(); video.track_memory = stored_tracks
	check(video.track_memory.lookup(URI).subtitle.file == "different.ass", "The optional source filename survives loading the actual saved track banks")
	var reloaded := Timing.new(video.subtitle_timing.directory); reloaded.load_saved()
	check(is_equal_approx(reloaded.for_track(URI, first_key), 1.2) and is_equal_approx(reloaded.for_track(URI, second_key), -2.8), "Both pair corrections survive a real two-bank reload")
	var old_session: int = video.media.session_id
	check(video.open_local(URI, "Film", 0, true, false, "film.mp4"), "Reopen the original video")
	video.media.playback = {"details": {"subtitle_tracks": []}}
	video._restore_tracks()
	check(host.loads.back()[0] == video.media.session_id and host.loads.back()[2] == "different.ass", "Remembered arbitrary files reload even with zero default tracks")
	request = host.loads.back()[1]
	reply(video, "load", request, {"state": "ready", "track_id": 9}, old_session)
	check(video.subtitles.requested_track == 0, "An old playback session cannot select a current track")
	video.media.playback = {"details": {"subtitle_tracks": [track(9, "different.ass")]}}
	reply(video, "load", request, {"state": "ready", "track_id": 9})
	check(video.subtitles.requested_track == 9 and is_equal_approx(video.subtitle_delay, -2.8), "A fresh MPV id restores the same file and its correction with auto-load off")
	check(video.set_subtitle_track(0), "Explicitly disable subtitles")
	var count: int = host.loads.size()
	video.open_local(URI, "Film", 0, true, false, "film.mp4"); video.media.playback = {"details": {"subtitle_tracks": []}}; video._restore_tracks()
	check(host.loads.size() == count and video.subtitles.requested_track == 0, "A remembered Off overrides the previous external file")
	video.track_memory.remember(URI, {"subtitle": choice}); video.track_memory.save()
	video.open_local(URI, "Film", 0, true, false, "film.mp4"); video.media.playback = {"details": {"subtitle_tracks": []}}; video._restore_tracks()
	reply(video, "load", host.loads.back()[1], {"state": "error"})
	check(video._track_restore.is_empty() and video.subtitles.requested_track == 0 and not video.subtitle_file_error.is_empty(), "An unavailable remembered file exits restoration without stopping playback")
	video.subtitle_files = ["different.ass"]; video.subtitle_files_state = "ready"
	video.media.playback = {"details": {"subtitle_tracks": [track(9, "different.ass")]}}
	menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_FILES), "A directory containing only already listed subtitles hides the entry")
	video.subtitle_files.clear(); menu.refresh()
	check(not menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_FILES), "A directory without subtitle candidates has no empty disclosure")
	for filename in ["../x.srt", "folder/x.srt", "folder\\x.srt", ".hidden.srt", "bad\n.srt", ""]:
		check(not Tracks.valid_file(filename), "Saved candidates cannot escape their original directory")
	check(not Modes.key_for("usb://disk/film.mp4").is_empty(), "Direct USB sources have durable per-video identity")
	var stable := "usb://stable/" + "1".repeat(64) + "/Movies/film.mp4"
	var usb_tracks := Tracks.new(directory + "/usb-tracks")
	var usb_timing := Timing.new(directory + "/usb-timing")
	check(usb_tracks.register_usb_identity("usb://first-session/lun/Movies/film.mp4", stable) and usb_timing.register_usb_identity("usb://first-session/lun/Movies/film.mp4", stable), "Playback URIs remain session scoped while memory can bind the filesystem identity")
	check(usb_tracks.remember("usb://first-session/lun/Movies/film.mp4", {"subtitle": choice}) and usb_tracks.save() and usb_timing.remember_track("usb://first-session/lun/Movies/film.mp4", second_key, -1.7) and usb_timing.save(), "USB selection and timing save under the persistent partition identity")
	usb_tracks = Tracks.new(directory + "/usb-tracks"); usb_tracks.load_saved()
	usb_timing = Timing.new(directory + "/usb-timing"); usb_timing.load_saved()
	usb_tracks.register_usb_identity("usb://second-session/lun/Movies/film.mp4", stable)
	usb_timing.register_usb_identity("usb://second-session/lun/Movies/film.mp4", stable)
	check(usb_tracks.lookup("usb://second-session/lun/Movies/film.mp4").subtitle.file == "different.ass" and is_equal_approx(usb_timing.for_track("usb://second-session/lun/Movies/film.mp4", second_key), -1.7), "A changed USB connection token restores the same file and correction after reloading stores")
	check(not usb_tracks.register_usb_identity(URI, stable), "A non-USB source cannot alias a disk's saved selection")
	video.track_memory = usb_tracks; video.subtitle_timing = usb_timing
	video.open_local("usb://third-session/lun/Movies/film.mp4", "Film", 0, true, false, "film.mp4")
	video._on_state(video.media.session_id, JSON.stringify({"state": "ready", "subtitle_memory_id": stable, "details": {"subtitle_tracks": []}}))
	check(host.loads.back()[0] == video.media.session_id and host.loads.back()[2] == "different.ass", "A native USB identity receipt restores the remembered external file before resolving its track")
	video.media.playback = {"details": {"subtitle_tracks": [track(19, "different.ass")]}}
	reply(video, "load", host.loads.back()[1], {"state": "ready", "track_id": 19})
	check(video.subtitles.requested_track == 19 and is_equal_approx(video.subtitle_delay, -1.7), "USB restoration uses the persistent pair correction with a new session and new track id")
	var capacity := Timing.new(directory + "/capacity")
	for movie in Modes.LIMIT:
		for variant in 32: capacity.remember_track("file:///capacity/%d.mp4" % movie, str(variant).sha256_text(), 0.1)
	check(capacity.save(), "All supported video and subtitle-pair slots fit the durable bank limit")
	var capacity_reload := Timing.new(directory + "/capacity"); capacity_reload.load_saved()
	check(capacity_reload.entries.size() == Modes.LIMIT and capacity_reload.lookup("file:///capacity/127.mp4").tracks.size() == 32, "A full bank restores every supported pair slot")
	Privacy.configure(Privacy.NONE)
	check(not video.subtitle_timing.remember_track(URI, first_key, 4.0), "Pair corrections follow the existing recording privacy policy")
	Privacy.configure(Privacy.ALL)
	video.close_video(); menu.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Subtitle files checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
