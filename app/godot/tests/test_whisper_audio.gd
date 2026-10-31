extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Memory := preload("res://scripts/file_whisper_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var calls: Array = []
	var serial := 0
	var session := 0
	var accepted := true
	var percent := 40.0
	var volume_serial := 0
	var applied_serial := 0
	var requested := 40.0
	var writable := true
	var available := true
	var write_ok := true
	var writes: Array = []
	func mpv_supported() -> bool: return true
	func open_mpv_video(_uri: String, _start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _tb: bool = false, _exact: bool = false) -> int:
		session += 1; return session
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_audio(id: int, track: int, volume: float, muted: bool) -> bool:
		calls.append(["audio", id, track, volume, muted]); return true
	func set_mpv_whisper(id: int, level: int) -> int:
		calls.append(["whisper", id, level]); serial += 1; return serial if accepted else 0
	func system_media_volume() -> String:
		return JSON.stringify({"available":available, "writable":writable, "percent":percent, "muted":percent == 0, "write_serial":applied_serial, "write_ok":write_ok})
	func set_system_media_volume(value: float, show_ui: bool) -> int:
		volume_serial += 1; requested = value; writes.append([value, show_ui]); return volume_serial
	func finish_write() -> void:
		applied_serial = volume_serial
		if write_ok and writable: percent = snappedf(requested, 5.0)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func ack(video: Node, host: RefCounted, level: int, error: String = "") -> void:
	video._confirm_audio_whisper({"whisper_serial": host.serial, "whisper_level": level, "whisper_error": error})

func tap(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target: continue
		var point: Vector3 = button.node.global_position + menu.global_basis.z * 0.3
		var result: bool = menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
		menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
		return result
	return false

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/system-volume-boost/godot-%d" % Time.get_ticks_usec())
	var video := Video.new()
	video.whisper_memory = Memory.new(directory)
	video.mode_memory.directory = directory.path_join("modes")
	video.track_memory.directory = directory.path_join("tracks")
	video.recent_files.directory = directory.path_join("recent")
	video.subtitle_timing.directory = directory.path_join("subtitles")
	video.audio_timing.directory = directory.path_join("audio")
	video.bookmark_store = preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host
	var main := Main.new(); main.video = video
	main.settings.set_value("audio", "volume", 13.0); main.settings.set_value("audio", "muted", true)
	var global_before := main.settings.encode_to_text()
	main._restore_audio_preferences()
	check(video.audio_volume == 40 and not video.audio_muted and host.writes.is_empty(), "Startup reads real system volume instead of old application preferences")
	check(video.open_local("smb://server/Movies/quiet.mp4", "quiet.mp4"), "Open production video controller")
	check(video.set_audio_options(-1, 40, false) and host.calls.back() == ["audio", video.media.session_id, -1, 100.0, false], "MPV always uses unity gain; track setup cannot set system volume")
	check(host.writes.is_empty() and video.audio_whisper == 0, "Opening a video neither writes system volume nor enables boost")
	check(video.set_volume_level(37), "Slider queues system volume change")
	check(video.audio_volume == 40 and host.writes.back() == [37.0,true], "Request uses system overlay and waits for actual quantized observation")
	host.finish_write(); video.system_volume.poll(true)
	check(video.audio_volume == 35, "Slider reads actual supported system steps")
	var writes := host.writes.size(); host.percent = 70; video.system_volume.poll(true)
	check(video.audio_volume == 70 and host.writes.size() == writes, "Headset buttons/system panel update slider without feedback writes")
	var menu := Menu.new()
	menu.state_provider = func(): return {"has_video":true, "source_uri":video.local_uri, "audio_available":true, "whisper_available":true, "audio_whisper":video.audio_whisper, "volume":video.system_volume.level(), "volume_writable":video.system_volume.writable, "boost_saved":video.audio_boost_saved, "muted":video.audio_muted, "playing":false}
	menu.whisper_requested.connect(main._on_menu_whisper); menu.volume_requested.connect(main._on_menu_volume)
	video.changed.connect(menu.refresh_values)
	root.add_child(menu); menu.toggle(); menu._volume_open = true; menu.refresh()
	var normal_span: Vector2 = menu.VOLUME_SPAN
	check(menu._buttons.filter(func(b): return b.target == Menu.WHISPER).size() == 1, "Only one enhancement button; no small preset targets")
	for button in menu._buttons:
		if button.target == Menu.WHISPER: check(button.rect.size.y < 0.08 and button.rect.size.x < 0.085 and button.rect.size.x <= 0.1 - 0.02, "Compact enhancement stays within the slim popup with side margins")
	check(tap(menu, Menu.WHISPER) and video.audio_whisper == 1 and host.writes.size() == writes, "Enhance expands rail at current volume without changing system volume")
	check(menu.VOLUME_SPAN == normal_span and is_instance_valid(menu._boost_fill), "Expansion adds a yellow segment without rescaling the original rail")
	check(video.whisper_memory.lookup(video.local_uri).is_empty(), "Do not save before native confirmation")
	var report := JSON.stringify({"state":"playing", "details":{"whisper_serial":host.serial, "whisper_level":1, "whisper_error":""}})
	video._on_state(video.media.session_id + 1, report)
	check(video.whisper_memory.lookup(video.local_uri).is_empty(), "Old source cannot confirm enhancement")
	video._on_state(video.media.session_id, report)
	check(video.whisper_memory.lookup(video.local_uri) == {"enabled":true,"boost":0}, "Confirmed mode is saved independently per video")
	var point: Vector3 = menu.to_global(Vector3(Menu.VOLUME_X, normal_span.y, 0.3))
	check(menu.press_pointer("left_hand", point, -menu.global_basis.z, true), "Real trigger captures continuous rail")
	menu.update_pointer("left_hand", point + Vector3(0, Menu.BOOST_HEIGHT, 0), -menu.global_basis.z, true)
	check(host.writes.back() == [100.0,true] and video.audio_whisper == 1, "Yellow segment first requests real system maximum, deferring software boost")
	host.finish_write(); video.system_volume.poll(true)
	check(video.audio_whisper == 51 and video.system_volume.level() == 150, "At confirmed maximum the same slider reaches 150 percent")
	ack(video, host, 51)
	check(video.whisper_memory.lookup(video.local_uri) == {"enabled":true,"boost":50}, "Save continuous boost only after native confirmation")
	check(menu._volume_label.text == "150%" and menu._volume_knob.position.y > normal_span.y, "Single knob and percentage move into yellow segment")
	menu.update_pointer("left_hand", point + Vector3(0, Menu.BOOST_HEIGHT * 0.6, 0), -menu.global_basis.z, true)
	host.finish_write(); video.system_volume.poll(true); ack(video, host, 31)
	check(video.audio_whisper == 31 and menu._volume_label.text == "130%", "Continuous intermediate value replaces presets")
	menu.update_pointer("left_hand", point - Vector3(0, (normal_span.y-normal_span.x)*0.2, 0), -menu.global_basis.z, true)
	host.finish_write(); video.system_volume.poll(true); ack(video, host, 1)
	check(video.audio_volume == 80 and video.audio_whisper == 1 and video.audio_boost_saved == 30, "Dragging below 100 removes makeup while retaining compressor and recall position")
	menu.update_pointer("left_hand", point, -menu.global_basis.z, false)
	check(not menu.has_pointer_capture(), "Tracking loss releases the expanded rail")
	video.set_volume_level(145); host.finish_write(); video.system_volume.poll(true); ack(video, host, 46)
	writes = host.writes.size(); host.percent = 60; video.system_volume.poll(true); ack(video, host, 1)
	check(video.audio_volume == 60 and video.audio_whisper == 1 and video.audio_boost_saved == 45 and host.writes.size() == writes, "Physical decrease exits added gain without removing compressor or rewriting system volume")
	check(video.toggle_mute(), "Mute controls actual media stream")
	host.finish_write(); video.system_volume.poll(true)
	check(video.audio_muted and video.audio_volume == 0 and video.audio_whisper == 1, "System mute preserves enhancement mode")
	video.toggle_mute(); host.finish_write(); video.system_volume.poll(true)
	check(video.audio_volume == 60 and not video.audio_muted and video.audio_whisper == 1, "Unmute restores last observed system step without reapplying extra gain")
	var old := video.local_uri; writes = host.writes.size()
	video.open_local("file:///other.mp4", "other.mp4")
	check(video.audio_whisper == 0 and host.writes.size() == writes and video.audio_volume == 60, "Different video has independent boost and keeps real system volume")
	video.open_local(old, "quiet.mp4")
	check(video.audio_whisper == 1 and video.audio_boost_saved == 45 and host.writes.size() == writes, "Reopen restores compressor/recall mark, never pushes system to maximum")
	video.set_audio_whisper(1, false); ack(video, host, 1)
	video.set_volume_level(135); host.finish_write(); video.system_volume.poll(true); ack(video, host, 36)
	video._reopen_at(0, false)
	check(video.audio_whisper == 36 and video.audio_boost_saved == 35 and video._whisper_restore_pending, "Internal display-path reopen preserves current active gain")
	video.set_audio_whisper(36, false); ack(video, host, 36)
	video._remember_file = true
	video.set_audio_whisper(12)
	video._confirm_audio_whisper({"whisper_serial":host.serial-1, "whisper_level":36})
	check(video.audio_whisper == 12 and video._whisper_command > 0, "Older native ack cannot overwrite latest continuous target")
	ack(video, host, 0, "whisper_filter_unavailable")
	check(video.audio_whisper == 0 and video.whisper_memory.lookup(video.local_uri) == {"enabled":true,"boost":35}, "Filter failure does not save false success")
	host.accepted = false
	check(not video.set_audio_whisper(1) and video.audio_whisper == 0, "Immediate native rejection preserves state")
	host.accepted = true
	check(not video.set_audio_whisper(-1) and not video.set_audio_whisper(52), "Reject strengths outside the continuous range")
	check(not video.set_volume_level(151) and not video.set_volume_level(NAN), "Reject invalid system/boost input")
	video.set_audio_whisper(1); ack(video, host, 1)
	host.write_ok = false
	video.set_volume_level(140); host.finish_write(); video.system_volume.poll(true)
	check(video.audio_whisper == 1, "Failed system maximum request cannot enable deferred boost")
	host.write_ok = true
	video.set_volume_level(150); video.set_volume_level(55); host.finish_write(); video.system_volume.poll(true)
	check(video.audio_whisper == 1 and video.audio_volume == 55, "Latest downward drag cancels older deferred boost")
	video.set_volume_level(150); video.open_local("file:///new-source.mp4", "new-source.mp4")
	host.finish_write(); video.system_volume.poll(true)
	check(video.audio_whisper == 0, "A deferred boost cannot cross source/session boundaries")
	writes = host.writes.size(); host.writable = false; video.system_volume.poll(true)
	check(not video.set_volume_level(30) and host.writes.size() == writes, "Read-only/fixed system volume cannot pretend to change")
	host.writable = true; host.available = false; video.system_volume.poll(true)
	check(not video.set_volume_level(30), "Unavailable system backend disables volume writes")
	host.available = true; video.system_volume.poll(true)
	check(main.settings.encode_to_text() == global_before and main._audio_save_after == 0, "System volume and per-video boost never overwrite legacy default configuration")
	var store := Memory.new(directory); store.load_saved()
	check(store.lookup(old) == {"enabled":true,"boost":35}, "Continuous preference survives store restart")
	check(store.remember("file:///legacy.mp4", {"level":2}) and store.lookup("file:///legacy.mp4") == {"enabled":true,"boost":50}, "Legacy strong preset migrates to recall-only boost")
	check(not store.remember("file:///bad.mp4", {"enabled":true,"boost":NAN}) and not store.remember("file:///bad.mp4", {"enabled":true,"boost":51}), "Reject malformed persisted boost")
	Privacy.configure(Privacy.NONE)
	check(store.remember("file:///private.mp4", {"enabled":true,"boost":12}), "Disabling history leaves enhancement memory independent")
	Privacy.configure_file_settings(Privacy.NONE)
	check(not store.remember("file:///private.mp4", {"enabled":true,"boost":13}), "Enhancement persistence honors the per-file settings policy")
	Privacy.configure_file_settings(Privacy.ALL)
	Privacy.configure(Privacy.ALL)
	menu.free(); video.free(); main.free()
	print("Whisper audio: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
