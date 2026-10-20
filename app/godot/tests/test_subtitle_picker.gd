extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Sources := preload("res://scripts/subtitle_sources.gd")
const Tracks := preload("res://scripts/file_track_memory.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const VIDEO_URI := "medialib://saved-server/scene/7"
var checks := 0
var failures: Array[String] = []

class Coordinator extends "res://scripts/main.gd":
	var returns := 0
	func _show_full_library() -> void: recent_menu.visible = true
	func _return_from_subtitle_picker() -> void: returns += 1

class Host extends RefCounted:
	signal media_list(id: int, payload: String)
	var sequence := 100
	var browses: Array = []
	var loads: Array = []
	var selected: Array = []
	var opens := 0
	var cancellations: Array = []
	func request(kind: String, args: Array) -> int:
		sequence += 1; browses.append([sequence, kind] + args); return sequence
	func media_subtitle_local_browse(path: String) -> int: return request("local", [path])
	func media_subtitle_smb_browse(server: String, path: String) -> int: return request("smb", [server, path])
	func media_subtitle_cloud_page(path: String, offset: int, _refresh: bool, order: String, _folder: String) -> int: return request("cloud", [path, offset, order])
	func media_smb_servers() -> int: return request("servers", [])
	func media_cloud_cancel(id: int) -> void: cancellations.append(id)
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		opens += 1; sequence += 1; return sequence
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_subtitle(id: int, track: int) -> bool: selected.append([id, track]); return true
	func set_mpv_subtitle_delay(_id: int, _seconds: float) -> bool: return true
	func load_mpv_subtitle_uri(id: int, request_id: int, uri: String) -> bool: loads.append([id, request_id, uri]); return true

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func click(menu: Node3D, target: int) -> void:
	var buttons: Array = menu._buttons.filter(func(button): return button.target == target)
	check(not buttons.is_empty() and buttons[0].enabled, "Enabled pointer target %d" % target)
	if buttons.is_empty(): return
	var node: Node3D = buttons[0].node
	var origin := node.to_global(Vector3(0, 0, 1))
	menu.press_pointer("right_hand", origin, -node.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -node.global_basis.z, true)

static func reply(menu: Node, host: Host, entries: Array, extra: Dictionary = {}) -> void:
	var call: Array = host.browses.back()
	var report := {"state": "ready", "entries": entries}
	match call[1]:
		"local": report.path = call[2]
		"smb": report.server_id = call[2]; report.path = call[3]
		"cloud": report.path = call[2]; report.offset = call[3]; report.order = call[4]
	report.merge(extra, true)
	menu._on_media_list(call[0], JSON.stringify(report))

func load_reply(video: Node, request_id: int, track: int) -> void:
	video._on_subtitle_files(video.media.session_id, JSON.stringify({"operation": "load", "request": request_id, "state": "ready" if track > 0 else "error", "track_id": track}))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	for uri in ["file:///storage/emulated/0/Subtitles/字幕.srt", "smb://saved/share/Film%20%40SBS.ass", "cloud://saved/Subtitles/film.vtt", "content://com.android.externalstorage.documents/tree/ABCD%3A/document/ABCD%3Afilm.srt"]:
		check(Sources.valid_uri(uri), "Supported subtitle URI: " + uri)
	for uri in ["https://server/file.srt", "smb://user:secret@server/file.srt", "cloud://saved/../file.srt", "cloud://saved/%2e%2e/file.srt", "cloud://saved/file.mp4", "file:///storage/file.sup", "cloud://saved/file.srt?token=secret", "cloud://saved", "content://foreign/file.srt"]:
		check(not Sources.valid_uri(uri), "Unsupported or unstable fixture source is rejected: " + uri)
	check(Sources.filename("smb://saved/share/%e5%ad%97%e5%b9%95%20%231.srt") == "字幕 #1.srt", "Lowercase URI escapes retain Unicode, spaces and hash characters")
	Privacy.configure(Privacy.ALL); Privacy.configure_file_settings(Privacy.ALL)
	var folder := ProjectSettings.globalize_path("res://../../build/output/subtitle-recovery/picker-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(folder)
	var host := Host.new()
	var library := Library.new(); library.platform = host; root.add_child(library); library.set_process(false)
	var video := Video.new(); video.platform = host
	video.track_memory = Tracks.new(folder + "/tracks"); video.subtitle_timing = Timing.new(folder + "/timing")
	video.mode_memory = video.ModeMemory.new(folder + "/modes")
	root.add_child(video); video.set_process(false)
	video.local_uri = VIDEO_URI; video.media.begin(7); video._remember_file = true
	video.media.playback = {"details": {"subtitle_tracks": []}}
	video.control.observed_position_ms = 42000; video.playback_speed = 1.5; video.requested_play = false
	var main := Coordinator.new(); main.video = video; main.recent_menu = library; main.settings_path = folder + "/settings.cfg"
	library.subtitle_selected.connect(main._on_subtitle_selected); library.subtitle_picker_cancelled.connect(main._on_subtitle_picker_cancelled)
	main._begin_subtitle_browse()
	check(library.subtitle_picker_mode and not library.audio_import_mode and not library._grid(), "Subtitle picker reuses the list browser independently of music import")
	check(library._buttons.filter(func(button): return button.target >= Library.NAV_BASE and button.target < Library.NAV_BASE + Library.NAV.size()).size() == 3, "Only Local, SMB and Cloud navigation is visible")
	reply(library, host, [{"id": "/storage/emulated/0/Subtitles", "title": "Subtitles", "container": true}])
	click(library, Library.ROW_BASE)
	var external_uri := "file:///storage/emulated/0/Subtitles/Film%20%40SBS.srt"
	reply(library, host, [{"uri": external_uri, "title": "Film @SBS.srt", "container": false}, {"uri": "file:///storage/movie.mp4", "title": "movie.mp4"}, {"uri": "file:///storage/movie.sup", "title": "movie.sup"}])
	check(library.rows.size() == 1 and library.rows[0].kind == "subtitle", "Only supported subtitle files survive the picker filter")
	click(library, Library.ROW_BASE)
	check(host.loads.size() == 1 and host.loads[0][2] == external_uri and main.returns == 1 and not library.subtitle_picker_mode, "The ray trigger loads a subtitle and returns without opening a video")
	check(host.opens == 0 and video.control.observed_position_ms == 42000 and video.playback_speed == 1.5 and not video.requested_play, "Choosing a subtitle preserves playback position, speed and pause")
	var settings_reload := ConfigFile.new(); check(settings_reload.load(main.settings_path) == OK, "Global directory memory is saved")
	var location: Dictionary = settings_reload.get_value("subtitles", "browse_location", {})
	check(location.source == "local" and location.local.back().id == "/storage/emulated/0/Subtitles", "Global memory stores the last selected subtitle directory")
	main.settings = settings_reload
	var track := {"id": 77, "title": "Film @SBS.srt", "codec": "subrip", "external": true, "source_uri": external_uri}
	load_reply(video, host.loads.back()[1], 77)
	check(video.subtitles.requested_track == 0, "The load receipt waits for the actual track list")
	video.media.playback.details.subtitle_tracks = [track]; video._restore_tracks()
	check(video.subtitles.requested_track == 77 and video.track_memory.lookup(VIDEO_URI).subtitle.uri == external_uri, "The external source is remembered per video, including opaque Emby video URIs")
	var timing_key := video.subtitle_timing_key()
	check(video.commit_subtitle_delay(1.3, VIDEO_URI, timing_key), "The selected external subtitle has an independent correction")
	var different := track.duplicate(true); different.source_uri = "smb://saved/share/Film%20%40SBS.srt"
	check(Timing.track_key(different) != timing_key, "Identical basenames in different locations have different timing identities")
	video.track_memory = Tracks.new(folder + "/tracks"); video.track_memory.load_saved()
	video.subtitle_timing = Timing.new(folder + "/timing"); video.subtitle_timing.load_saved()
	check(video.open_local(VIDEO_URI, "Film", 0, true, false, "film.mp4"), "Reopen the original video from its stable history identity")
	video.media.playback = {"details": {"subtitle_tracks": []}}; video._restore_tracks()
	check(host.loads.back()[2] == external_uri, "History restoration reloads the explicitly selected cross-directory subtitle")
	var old_request: int = host.loads.back()[1]
	track.id = 88; video.media.playback.details.subtitle_tracks = [track]; load_reply(video, old_request, 88)
	check(video.subtitles.requested_track == 88 and is_equal_approx(video.subtitle_delay, 1.3), "A new MPV track ID restores the same external file and its correction")
	check(video.select_subtitle_uri("cloud://saved/Subtitles/missing.srt"), "Start another optional subtitle load")
	load_reply(video, host.loads.back()[1], 0)
	check(video.subtitles.requested_track == 88 and is_equal_approx(video.subtitle_delay, 1.3), "A failed optional source preserves the existing subtitle and correction")
	check(video.track_memory.lookup(VIDEO_URI).subtitle.uri == external_uri, "A failed optional source never overwrites the saved subtitle choice")
	main._begin_subtitle_browse()
	check(host.browses.back()[2] == "/storage/emulated/0/Subtitles", "The next picker starts at the saved global directory")
	library._on_media_list(host.browses.back()[0], JSON.stringify({"state": "error", "path": "/storage/emulated/0/Subtitles", "error": "Subtitle folder access denied"}))
	check(library.subtitle_picker_mode and library._buttons.any(func(button): return button.target == Library.BACK), "An unavailable remembered directory keeps the picker and parent navigation usable")
	library.dismiss(); check(main.returns == 2, "Cancel returns to the subtitle menu without selecting a file")
	main.settings.set_value("subtitles", "browse_location", {"source": "smb", "server": "saved", "path": "share/Subtitles"})
	main._begin_subtitle_browse()
	check(host.browses.back().slice(1) == ["smb", "saved", "share/Subtitles"], "SMB directory memory restores the account and path")
	reply(library, host, [{"uri": "smb://saved/share/Subtitles/%e5%ad%97%e5%b9%95%20%231.ass", "title": "字幕 #1.ass"}]); click(library, Library.ROW_BASE)
	check(host.loads.back()[2] == "smb://saved/share/Subtitles/%e5%ad%97%e5%b9%95%20%231.ass", "SMB selection keeps its stable URI with Unicode, spaces and hashes")
	load_reply(video, host.loads.back()[1], 0)
	main.settings.set_value("subtitles", "browse_location", {"source": "cloud", "cloud": [{"id": "/saved", "title": "Drive"}, {"id": "/saved/Subtitles", "title": "Subtitles"}]})
	main._begin_subtitle_browse()
	reply(library, host, [], {"next_offset": 48, "total": 49, "page_size": 48})
	library._turn_cloud_page(1)
	check(host.browses.back()[3] == 48, "Cloud subtitles beyond the first raw page remain reachable")
	reply(library, host, [{"uri": "cloud://saved/Subtitles/caption.vtt", "title": "caption.vtt"}], {"next_offset": -1, "total": 49})
	click(library, Library.ROW_BASE)
	check(host.loads.back()[2] == "cloud://saved/Subtitles/caption.vtt", "Cloud selection loads the selected subtitle rather than the current video directory")
	load_reply(video, host.loads.back()[1], 0)
	# Media and subtitle views contain different files and therefore different pages.
	library.section = Library.Section.CLOUD
	library._cloud_stack.assign([{"id": "/saved", "title": "Drive"}, {"id": "/saved/Subtitles", "title": "Subtitles"}])
	library._cloud_location = "/saved/Subtitles"
	library._cloud_positions.clear()
	library._cloud_page = 3; library._cloud_offsets.assign([0, 48, 96, 144])
	library._cloud_busy = false
	library._save_folder_position()
	library.begin_subtitle_picker({"source": "cloud", "cloud": library._cloud_stack.duplicate(true)})
	check(host.browses.back()[3] == 0, "Subtitle picker starts at its own first page instead of a later media page")
	reply(library, host, [], {"next_offset": 48, "total": 49, "page_size": 48})
	library._turn_cloud_page(1)
	reply(library, host, [], {"next_offset": -1, "total": 49})
	library._save_folder_position()
	check(library._cloud_positions["/saved/Subtitles"].page == 3, "Subtitle paging preserves the media directory position")
	check(library._cloud_positions["subtitle:/saved/Subtitles"].page == 1, "Subtitle paging has a separate remembered position")
	library.dismiss()
	check(library._cloud_page == 3, "Leaving subtitle selection restores the original media page")
	library.begin_subtitle_picker({"source": "cloud", "cloud": library._cloud_stack.duplicate(true)})
	check(host.browses.back()[3] == 48, "Reopening subtitles restores the subtitle page instead of the media page")
	reply(library, host, [], {"next_offset": -1, "total": 49})
	library.dismiss()
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	var state := {"has_video": true, "source_uri": VIDEO_URI, "subtitle_options": [], "subtitle_browse_available": true}
	menu.state_provider = func(): return state
	var events: Array = []
	menu.subtitle_browse_requested.connect(func(): events.append("browse"))
	menu.subtitle_requested.connect(func(id): events.append(id))
	menu.toggle(); menu._activate(110)
	check(menu._buttons.any(func(button): return button.target == Menu.SUBTITLE_BROWSE), "The folder icon is present even when Off is the only subtitle row")
	check(not menu._buttons.any(func(button): return button.target == Menu.SUBTITLE_FILES), "Empty same-directory candidates add no disclosure row")
	var folder_button: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.SUBTITLE_BROWSE)[0]
	var close_button: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.SUBTITLE_CLOSE)[0]
	check(is_equal_approx(folder_button.node.position.y, close_button.node.position.y), "The folder icon shares the existing subtitle title row")
	click(menu, Menu.SUBTITLE_ROW)
	check(events == [0], "Off remains a distinct subtitle action and never opens the browser")
	click(menu, Menu.SUBTITLE_BROWSE)
	check(events == [0, "browse"], "The folder icon has its own distinct ray action")
	menu.free(); main.free(); library.free(); video.free()
	for failure in failures: push_error(failure)
	print("Subtitle picker checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
