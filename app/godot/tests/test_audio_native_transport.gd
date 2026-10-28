extends SceneTree
const Audio := preload("res://scripts/background_audio.gd")
var checks := 0
var failures := 0
class Platform extends RefCounted:
	signal background_audio_imported(id: int, payload: String)
	var generation := 0
	var value := {}
	var commands: Array = []
	var stops := 0
	var imports: Array = []
	var paths: Array[String] = []
	func import_background_audio(uri: String, title: String) -> int:
		imports.append([uri, title]); return imports.size()
	func load_background_audio(path: String, position: float) -> int:
		paths.append(path)
		generation += 1; value = {"generation": generation, "state": "loading", "position": position, "duration": 6.0}; return generation
	func control_background_audio(id: int, playing: bool, volume: float, seek: float) -> bool:
		commands.append([id, playing, volume, seek]); return true
	func stop_background_audio() -> void: stops += 1
	func background_audio_status() -> String: return JSON.stringify(value)
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1; push_error(message)
func run() -> void:
	var audio := Audio.new(); var platform := Platform.new()
	audio.directory = "user://native_audio_transport_test"; audio.importer.platform = platform
	root.add_child(audio); audio.set_process(false)
	audio.library.imports.assign([{"id": "import_a", "path": "/private/a.flac", "label": "FLAC"}, {"id": "import_b", "path": "/private/b.dts", "label": "DTS"}])
	check(audio.play_tracks(["import_a", "import_b"], "import_a"), "Native FLAC starts")
	check(audio.snapshot().audio_loading and audio.player.stream == null, "Streaming backend allocates no Godot PCM stream")
	platform.value.state = "ready"; audio._process(0.1)
	check(audio._loaded == "import_a" and audio.duration() == 6, "Decoded metadata becomes ready")
	audio.set_context(true, true)
	check(not platform.commands[-1][1], "Video pauses independent music transport")
	audio.set_context(false, false)
	check(not platform.commands[-1][1], "Focus loss holds music paused")
	audio.set_context(false, true); audio.set_volume(32); audio._process(1.0)
	check(platform.commands[-1][1] and is_equal_approx(platform.commands[-1][2], 32.0), "Resume applies music volume")
	audio.toggle_pause(); audio.seek(2)
	check(not platform.commands[-1][1] and platform.commands[-1][3] == 2, "Paused seek stays paused")
	audio.toggle_pause(); audio.set_play_during_video(true); audio.set_context(true, true)
	check(platform.commands.back()[1] and not audio.blocked(), "Native import plays concurrently after explicit opt-in")
	audio.set_mode("sequence"); platform.value.state = "ended"; audio._process(0.1)
	check(audio.current == "import_b" and platform.stops == 1, "EOF advances FLAC to DTS once")
	var current_token := audio._native_token
	platform.value = {"generation": current_token - 1, "state": "ended"}; audio._process(0.1)
	check(audio.current == "import_b" and audio._native_loading, "Superseded native results cannot change track")
	platform.value = {"generation": current_token, "state": "ready", "position": 1, "duration": 6}; audio._process(0.1)
	check(platform.commands.back()[1] and audio.video_active, "Next imported track starts while the video remains active")
	platform.value.state = "ended"; audio._process(0.1)
	check(audio.paused and audio._queue_finished and audio.position() == 6, "Sequence ends at final duration")
	audio._process(0.1); check(audio.position() == 6, "Repeated EOF does not overwrite terminal position")
	audio.seek(2); check(audio._native_token != current_token and audio.paused, "Seeking ended native track reloads silently")
	audio.toggle_pause(); audio.set_mode("single"); platform.value.state = "ready"; audio._process(0.1)
	current_token = audio._native_token; platform.value.state = "ended"; audio._process(0.1)
	check(audio.current == "import_b" and audio._native_token != current_token, "Single repeat reopens native decoder")
	platform.value.state = "failed"; audio._process(0.1)
	check(audio.paused and audio._native_token == 0 and not audio.error.is_empty(), "Decode failure stops without advancing")
	var before_import: String = audio.current
	audio.import_tracks([{"uri": "cloud:///Recording.M4A", "title": "Recording.M4A"}])
	check(audio.importer.busy and platform.imports.back() == ["cloud:///Recording.M4A", "Recording.m4a"], "M4A import uses the native importer with a normalized extension")
	platform.background_audio_imported.emit(1, JSON.stringify({"state": "ready", "id": "import_m4a", "path": "/private/recording.m4a", "label": "Recording.m4a", "decoded": true, "created": true, "bytes": 12000}))
	check(not audio.importer.busy and audio.library.resolve("import_m4a").path == "/private/recording.m4a" and audio.current == before_import, "Validated M4A is saved without changing the playing track")
	check(audio.play_tracks(["import_m4a"], "import_m4a") and platform.paths.back() == "/private/recording.m4a" and audio.player.stream == null, "M4A playback uses the existing native transport")
	platform.value.state = "ready"; audio._process(0.1)
	audio.toggle_pause(); audio.seek(2)
	check(audio._loaded == "import_m4a" and not platform.commands.back()[1] and platform.commands.back()[3] == 2, "M4A reaches ready and supports paused seeking")
	audio.play_tracks(["import_a"], "import_a"); audio.select_track("yunhai")
	check(audio._native_token == 0, "Switch to built-in audio closes native transport")
	audio.queue_free(); await process_frame
	print("Native music transport: %d checks, %d failures" % [checks, failures]); quit(1 if failures else 0)
