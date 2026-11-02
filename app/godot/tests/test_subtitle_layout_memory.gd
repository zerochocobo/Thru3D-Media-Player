extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_subtitle_layout_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Existing := preload("res://tests/test_subtitle_effect_recovery.gd")
const LOCAL := "file:///subtitle-layout/A.mp4"
const NETWORK := "smb://server/films/B.mp4"
class Host extends Existing.Host:
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int,
		_depth: bool = false, _tb: bool = false, _exact: bool = false) -> int: return 1
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/depth-subtitles/memory-%d" % Time.get_ticks_usec())
	var main := preload("res://scripts/main.gd").new()
	var video := Video.new(); main.video = video
	for memory in [video.mode_memory, video.track_memory, video.subtitle_layout_memory, video.subtitle_timing,
		video.subtitle_encoding, video.audio_timing, video.whisper_memory, video.narration.memory, video.listening.memory,
		video.recent_files, video.bookmark_store]: memory.directory = directory.path_join(str(memory.get_instance_id()))
	video.history_enabled = false; video.layer_enabled = false
	root.add_child(video); video.set_process(false); video.platform = Host.new()
	Privacy.configure("none"); Privacy.configure_file_settings("all"); Privacy.vault = null
	main.settings.set_value("subtitles", "below_screen_3d", true) # Obsolete global opt-in must not spread.
	main.settings.set_value("subtitles", "flat_position", 0.67)
	main._restore_subtitle_settings()
	check(not video.subtitle_below_screen, "Legacy global flag is ignored")
	check(video.open_local(LOCAL, "A.mp4") and not video.subtitle_below_screen, "Unseen file defaults off")
	main._on_player_setting("subtitle_below_screen", true)
	check(video.subtitle_below_screen and video.subtitle_layout_memory.lookup(LOCAL) == {"below_screen": true}, "Player menu saves only the current file")
	check(video.subtitle_flat_position == 0.67 and main.settings.get_value("subtitles", "flat_position") == 0.67, "Per-file toggle preserves original global vertical position")
	check(video.open_local(NETWORK, "B.mp4") and not video.subtitle_below_screen, "A different file does not inherit the choice")
	check(video.open_local(LOCAL, "A.mp4") and video.subtitle_below_screen, "Returning to the selected file restores it with history off")
	var restored := Memory.new(video.subtitle_layout_memory.directory); restored.load_saved()
	check(restored.lookup(LOCAL) == {"below_screen": true} and restored.lookup(NETWORK).is_empty(), "Only selected file survives storage reload")
	main._on_player_setting("subtitle_below_screen", false)
	video.open_local(NETWORK, "B.mp4"); video.open_local(LOCAL, "A.mp4")
	check(not video.subtitle_below_screen and video.subtitle_layout_memory.lookup(LOCAL) == {"below_screen": false}, "Explicit off is remembered per file")
	Privacy.configure_file_settings("none")
	main._on_player_setting("subtitle_below_screen", true)
	check(video.subtitle_below_screen, "Memory-off still allows a live choice")
	video._reopen_at(1000, false)
	check(video.subtitle_below_screen, "Internal output reopen preserves live choice without persistence")
	var cast_view := video.capture_cast_view()
	video.open_local(NETWORK, "B.mp4"); video.open_local(LOCAL, "A.mp4")
	video.restore_cast_view(cast_view)
	check(video.subtitle_below_screen and video._subtitle_layout_user_changed, "Returning from casting restores the interrupted file's live choice")
	video.open_local(NETWORK, "B.mp4"); video.open_local(LOCAL, "A.mp4")
	check(not video.subtitle_below_screen, "New file session resets when memory is disabled")
	Privacy.configure_file_settings("all")
	check(video.subtitle_layout_memory.lookup(LOCAL) == {"below_screen": false}, "Re-enabling memory never backfills a private live choice")
	Privacy.configure_file_settings("local")
	video.open_local(NETWORK, "B.mp4"); main._on_player_setting("subtitle_below_screen", true)
	check(video.subtitle_below_screen and video.subtitle_layout_memory.lookup(NETWORK).is_empty(), "Local-only policy never persists a network preference")
	video.open_local(LOCAL, "A.mp4"); main._on_player_setting("subtitle_below_screen", true)
	check(video.subtitle_layout_memory.lookup(LOCAL) == {"below_screen": true}, "Local-only policy persists a local file")
	Privacy.configure_file_settings("all")
	# Late USB identity can restore a previous choice, but cannot override a fresh user decision.
	var stable := "usb://stable/" + "a".repeat(64) + "/Movie.mp4"
	var usb := "usb://mount-one/Movie.mp4"
	video.subtitle_layout_memory.remember(stable, {"below_screen": true}); video.subtitle_layout_memory.save()
	video.open_local(usb, "Movie.mp4")
	check(not video.subtitle_below_screen, "Unresolved USB identity starts off")
	video._restore_usb_subtitle_layout(stable)
	check(video.subtitle_below_screen, "Late stable USB identity restores only that file")
	usb = "usb://mount-two/Movie.mp4"; video.open_local(usb, "Movie.mp4")
	main._on_player_setting("subtitle_below_screen", false); video._restore_usb_subtitle_layout(stable)
	check(not video.subtitle_below_screen and video.subtitle_layout_memory.lookup(stable) == {"below_screen": false}, "Explicit early USB off wins over saved on")
	video.subtitle_layout_memory.remember(stable, {"below_screen": true}); video.subtitle_layout_memory.save()
	usb = "usb://mount-three/Movie.mp4"; video.open_local(usb, "Movie.mp4")
	video.discard_file_settings(); video._restore_usb_subtitle_layout(stable)
	check(not video.subtitle_below_screen, "Late identity cannot reactivate an explicitly cleared live preference")
	restored.load_saved() # Reload the latest generation before acting as the only writer.
	var renamed := "file:///subtitle-layout/Renamed.mp4"
	check(restored.relocate(LOCAL, renamed) and restored.save(), "File rename migrates the isolated layout store")
	var cold := Memory.new(restored.directory); cold.load_saved()
	check(cold.lookup(LOCAL).is_empty() and cold.lookup(renamed) == {"below_screen": true}, "Renamed layout survives restart without leaking to old path")
	check(not cold.remember(LOCAL, {"below_screen": "true"}) and not cold.remember(LOCAL, {"below_screen": true, "track": 9}), "Store rejects malformed values and unrelated subtitle settings")
	video.open_local(NETWORK, "Temporary cast", 0, false)
	main._on_player_setting("subtitle_below_screen", true)
	check(video.subtitle_below_screen and video.subtitle_layout_memory.lookup(NETWORK).is_empty(), "Temporary cast playback can opt in without creating durable file settings")
	video.close_video()
	check(not video.subtitle_below_screen, "Closing video clears the active preference")
	Privacy.configure("all"); Privacy.configure_file_settings("all")
	video.free(); main.free()
	for failure in failures: print("FAIL: " + failure)
	print("Subtitle layout memory: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
