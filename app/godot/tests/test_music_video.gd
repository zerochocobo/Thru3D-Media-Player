extends SceneTree
const Audio := preload("res://scripts/background_audio.gd")
const Player := preload("res://scripts/player_menu.gd")
const Music := preload("res://scripts/music_menu.gd")
const Quick := preload("res://scripts/music_quick_controls.gd")
var checks := 0
var failures := 0
class TestMain extends "res://scripts/main.gd":
	func _place_menu(_menu: Node3D, _recenter: bool = false) -> void: pass
class Video extends Node3D:
	var local_uri := "tutorial.mp4"
	var media := {"state": "playing"}
	var requested_play := true
	var audio_volume := 67.0
	var audio_muted := false
class Platform extends RefCounted:
	var commands: Array = []
	var preview_commands: Array = []
	var preview_stops := 0
	func control_background_audio(id: int, playing: bool, gain: float, seek: float) -> bool:
		commands.append([id, playing, gain, seek]); return true
	func preview_background_audio(_uri: String) -> int: return 1
	func control_audio_preview(id: int, playing: bool, gain: float) -> bool:
		preview_commands.append([id, playing, gain]); return true
	func stop_audio_preview() -> void: preview_stops += 1
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1; push_error(message)
func control(menu: Node, target: int) -> Dictionary:
	for button in menu._buttons:
		if button.target == target: return button
	return {}
func ray(menu: Node3D, target: int) -> Vector3:
	return control(menu, target).node.global_position.normalized()
func switch_target(music: Node) -> int:
	for id in music.choices.targets:
		if music.choices.targets[id].get("key", "") == "audio_play_during_video": return id
	return -1
func click(menu: Node3D, target: int, hand: String = "left_hand") -> void:
	var direction := ray(menu, target)
	menu.press_pointer(hand, Vector3.ZERO, direction, true)
	menu.release_pointer(hand, Vector3.ZERO, direction, true)
func run() -> void:
	var audio := Audio.new(); var platform := Platform.new(); audio.importer.platform = platform
	audio.player = AudioStreamPlayer.new(); audio.current = "yunhai"; audio._loaded = "yunhai"; audio.queue.assign(["yunhai"])
	audio._native_token = 7; audio._entry_gain = 1; audio._remembered_duration = 120; audio._resume_position = 12; audio.paused = false
	var old_settings := ConfigFile.new(); old_settings.set_value("audio_player", "volume", 45)
	var migrated := Audio.new(); migrated.load_settings(old_settings)
	check(not migrated.play_during_video, "Existing installations retain video priority")
	migrated.importer.free(); migrated.free()
	audio.set_context(true, true)
	check(audio.blocked() and not platform.commands.back()[1] and not audio.paused, "Video suspends music while preserving its play intent by default")
	var player := Player.new(); root.add_child(player)
	player.state_provider = func():
		var state: Dictionary = audio.snapshot(); state.merge({"has_video": true, "playing": true, "playback_state": "playing", "source_uri": "tutorial.mp4", "title": "Tutorial", "volume": 67, "audio_available": true}); return state
	player.visible = true; player.refresh()
	check(control(player, Player.MUSIC_OPEN).is_empty(), "Disabled option leaves the original video bar intact")
	var main := TestMain.new(); var video := Video.new(); var music := Music.new(); music.audio = audio; root.add_child(music)
	main.video = video; main.video_menu = player; main.player_menu = player; main.background_audio = audio; main.music_menu = music
	player.action_requested.connect(main._on_menu_action); audio.changed.connect(main._on_background_audio_changed)
	music.open(true)
	check(switch_target(music) == -1 and music._storage_labels.is_empty(), "Compact playback keeps settings and capacity out of its footer")
	click(music, Music.SETTINGS)
	check(music.modal == "settings" and music._storage_labels.size() == 3, "Top-left settings opens the option and storage information")
	var target := switch_target(music); var direction := ray(music, target)
	music.press_pointer("left_hand", Vector3.ZERO, direction, true)
	music.release_pointer("right_hand", Vector3.ZERO, direction, true)
	check(not audio.play_during_video and music.has_pointer_capture(), "Only the capturing hand can commit the switch")
	music.release_pointer("left_hand", Vector3.ZERO, direction, true)
	check(audio.play_during_video and not audio.blocked() and platform.commands.back()[1], "Opting in resumes the same music stream during video")
	check(audio._native_token == 7 and audio.position() == 12 and video.requested_play, "Enabling coexistence preserves both transports and music position")
	click(music, Music.BACK)
	check(music.compact and music.modal.is_empty() and switch_target(music) == -1 and music._storage_labels.is_empty(), "Settings back restores clean compact playback")
	music.dismiss(); player.refresh()
	check(not control(player, Player.MUSIC_OPEN).is_empty() and control(player, Player.MUSIC_OPEN).node.position.x < control(player, 107).node.position.x, "Video music entry appears at the far left")
	direction = ray(player, Player.MUSIC_OPEN); player.update_pointer("left_hand", Vector3.ZERO, direction, true)
	player.music_quick._entered.left_hand = Time.get_ticks_msec() - Quick.ENTER_MS - 1
	player.update_pointer("left_hand", Vector3.ZERO, direction, true)
	check(player.music_quick.expanded and not control(player, Quick.PLAY).is_empty(), "Video uses the photo hover transport")
	click(player, Quick.PLAY, "right_hand")
	check(audio.paused and not platform.commands.back()[1] and video.requested_play and player.visible, "Quick pause affects only music and keeps video controls visible")
	click(player, Quick.PLAY)
	check(not audio.paused and platform.commands.back()[1] and video.requested_play, "Either hand can resume music independently")
	click(player, Player.MUSIC_OPEN)
	check(music.visible and not music.compact and not player.visible and main._music_return_video, "Management remembers the video entry context")
	click(music, Music.DOCK); click(music, Music.VOLUME)
	check(music._volume_open, "Music retains its own volume slider")
	click(music, Music.SETTINGS)
	check(music.modal == "settings" and not music._volume_open and not audio.paused, "Settings opens directly from the volume popup without changing playback")
	click(music, Music.BACK); click(music, Music.VOLUME)
	music._choice_changed("audio_volume", 23.0)
	check(audio.volume == 23 and is_equal_approx(platform.commands.back()[2], 23.0) and video.audio_volume == 67 and not video.audio_muted, "Music gain does not change video or system volume")
	click(music, Music.MUTE)
	check(audio.volume == 0 and video.requested_play and not video.audio_muted, "Music mute leaves tutorial audio playing")
	click(music, Music.MUTE)
	check(audio.volume == 23, "Music unmute restores its independent gain")
	main._close_music_menu()
	check(player.visible and not music.visible, "Closing music management restores video controls")
	audio.set_context(false, true); audio.set_context(true, true)
	check(not audio.blocked() and platform.commands.back()[1], "Switching videos keeps opted-in music running")
	audio.set_context(true, false)
	check(audio.blocked() and not platform.commands.back()[1], "Focus loss still silences simultaneous music")
	audio.set_context(true, true); audio.toggle_pause(); audio.set_play_during_video(false); audio.set_play_during_video(true)
	check(audio.paused and not platform.commands.back()[1], "Changing the option never overrides a manual music pause")
	audio.toggle_pause()
	check(audio.preview_audio("file:///preview.flac", "Preview") and platform.preview_commands.back()[1], "Opted-in music import preview also works during video")
	audio.set_play_during_video(false)
	check(audio._preview_token == 0 and platform.preview_stops == 1 and not platform.commands.back()[1] and not audio.paused, "Disabling coexistence closes preview and restores video priority")
	check(control(player, Player.MUSIC_OPEN).is_empty() and not player.music_quick.expanded, "Disabling removes and folds the video shortcut immediately")
	check(not audio.preview_audio("file:///preview.flac", "Preview"), "Video priority blocks new auditions when the option is off")
	audio.set_play_during_video(true)
	var saved := ConfigFile.new(); audio.save_settings(saved)
	var restored := Audio.new(); restored.load_settings(saved)
	check(restored.play_during_video and restored.volume == 23 and restored.paused, "Preference and separate gain persist while startup stays silent")
	restored.importer.free(); restored.free()
	music.open(false); music.compact = false; music.view = "tracks"; music.playlist_id = "ambience"; music.offset = 1; music.refresh()
	check(switch_target(music) == -1 and music._storage_labels.is_empty(), "Full management also keeps its footer clear")
	click(music, Music.SETTINGS); click(music, switch_target(music), "right_hand")
	check(not audio.play_during_video, "Full management settings exposes the same ray-operated switch")
	click(music, Music.BACK)
	check(not music.compact and music.modal.is_empty() and music.view == "tracks" and music.playlist_id == "ambience" and music.offset == 1, "Settings restores the prior playlist and scroll position")
	main.background_audio = null; main.music_menu = null; main.player_menu = null; main.video_menu = null; main.video = null; main.free(); video.free()
	music.free(); player.free(); audio.player.free(); audio.player = null; audio.importer.free(); audio.free()
	await process_frame
	print("Music with video: %d checks, %d failures" % [checks, failures]); quit(1 if failures else 0)
