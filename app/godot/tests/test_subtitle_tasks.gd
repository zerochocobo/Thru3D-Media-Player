extends SceneTree
const Tasks := preload("res://scripts/subtitle_tasks.gd")
const Gate := preload("res://scripts/translation_work_gate.gd")
const Rows := preload("res://scripts/subtitle_task_rows.gd")
const Live := preload("res://scripts/live_interpretation.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
class Platform extends RefCounted:
	var commands := []
	var writes := []
	func subtitle_tasks_request(json: String) -> bool: commands.append(JSON.parse_string(json)); return true
	func subtitle_tasks_status() -> String: return '{"jobs":[],"loaded":true}'
	func subtitle_translation_work() -> String: return '{}'
	func subtitle_translation_store(json: String) -> bool: writes.append(JSON.parse_string(json)); return true
	func set_mpv_listening(_id: int, _json: String) -> bool: return true
class Video extends Node3D:
	var platform := Platform.new()
	var media := {"session_id": 1, "playback": {"details": {"audio_tracks": [{"id": 1, "stream_index": 2}], "audio_track_id": "1"}}}
	var cast_token := 0
	var disc := {"menu_session": false, "playing": -1}
	var local_uri := "file:///test.mp4"
	var display_name := "Test film"
	var listening: RefCounted
var failures := []
var checks := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)
func tap(menu: Node3D, target: int) -> bool:
	for button: Dictionary in menu._buttons:
		if button.target != target: continue
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
		menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
		return true
	return false
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var video := Video.new(); root.add_child(video); video.listening = Live.new(video)
	var tasks := Tasks.new(video); var settings := ConfigFile.new()
	tasks.load_settings(settings)
	check(tasks.mode == "original" and tasks.policy == "playback", "Conservative defaults")
	check(tasks.option("subtitle_task_mode", "translated", settings), "Save translated mode")
	check(not tasks.option("subtitle_task_policy", "unlimited", settings), "Invalid concurrency option rejected")
	video.listening.target = "zh-Hans"; video.listening.source = "ja"
	check(tasks.enqueue(), "Enqueue current audio")
	var request: Dictionary = video.platform.commands.back()
	check(request.language == "ja" and request.target == "zh-Hans" and request.title == video.display_name, "Explicit language snapshot")
	video.listening.source = "en"; video.local_uri = "file:///other.mp4"
	check(request.language == "ja" and request.media != Tasks.Memory.key_for(video.local_uri), "Changing film/defaults does not mutate queued request")
	tasks.tick(); check(video.platform.commands.back().operation == "context", "App-wide context follows current film")
	var a := RefCounted.new(); var b := RefCounted.new()
	Gate.owner = null; Gate.next_at = 0; Gate.demand.clear()
	check(Gate.acquire(a, 2) and not Gate.acquire(b, 0), "Single translation owner")
	Gate.release(a); check(Gate.acquire(b, 0), "Slot released after cancellation")
	check(not Gate.acquire(a, 2), "Foreground never overlaps an active HTTP batch")
	Gate.release(b); check(not Gate.acquire(b, 0) and Gate.acquire(a, 2), "Waiting foreground work takes priority")
	Gate.release(a)
	var cues := [{"text": "hello", "translation": "你好"}]
	var client: RefCounted = video.listening.translator
	Tasks.seed(cues, client, "en", "zh-Hans")
	client.observe_sentences(cues, "en", "zh-Hans")
	check(client.jobs.is_empty(), "Persisted translation makes no new request")
	var sent := {}; var identity := {"cache_key": "key", "cache_instance": 19}
	cues[0].translation = ""
	Tasks.store(video.platform, identity, cues, client, sent); Tasks.store(video.platform, identity, cues, client, sent)
	check(video.platform.writes.size() == 1 and video.platform.writes[0].rows[0].text == "hello", "Translated raw original is stored once with cache generation")
	var job := {"id": "job", "media": "test", "title": "日本語映画", "language": "ja", "target": "zh-Hans", "state": "listening", "progress": 35, "speed": 8.5, "persistent": true}
	var queue := {"jobs": [job], "paused": false}
	var rows := Rows.rows(queue)
	check(rows.size() == 3 and is_equal_approx(float(rows[1].task_progress), .35), "Queue progress and global controls")
	check(not rows[1].has("choices") and rows[1].task_actions.any(func(action): return action.operation == "cancel") and rows[1].task_actions.any(func(action): return action.operation == "first"), "Cancel and priority are direct buttons")
	var library := Library.new(); root.add_child(library); library.set_process(false)
	library.settings_provider = func(): return {"subtitle_defaults": {"subtitle_tasks": queue}}
	library.section = library.Section.SETTINGS; library.tab = library.VIDEO_TAB; library.subtitle_queue_open = true
	library.visible = true; library.refresh()
	check(library.rows.size() == 3, "Queue uses global settings list")
	var emitted := []
	library.setting_changed.connect(func(key, value): emitted.append([key, value]))
	var cancel_ids: Array = library._subtitle_task_buttons.keys().filter(func(id): return library._subtitle_task_buttons[id].operation == "cancel")
	check(cancel_ids.size() == 1 and tap(library, cancel_ids[0]) and emitted.back() == ["subtitle_task_command", {"operation": "cancel", "id": "job"}], "Ray taps a task's cancel button directly")
	check(not str(library._tips.get(cancel_ids[0], "")).is_empty(), "Task button names itself on hover")
	check(library.navigate_back() and not library.subtitle_queue_open, "Back returns to subtitle settings")
	var actions := []
	var state := {"has_video": true, "title": "Film", "subtitle_options": [], "subtitle_track": 0, "listening_available": true, "listening_enabled": true,
		"subtitle_task_supported": true, "subtitle_task_mode": "original", "subtitle_task": job}
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = func(): return state
	menu.setting_requested.connect(func(key, value): actions.append([key, value]))
	menu.toggle(); menu._subtitle_open = true; menu.refresh(); menu._activate(menu.SUBTITLE_LISTENING)
	check(tap(menu, menu.SUBTITLE_TASK_CANCEL) and actions.back() == ["listening_cancel", "job"], "Ray cancels correct task")
	check(tap(menu, menu.SUBTITLE_TASKS) and actions.back()[0] == "subtitle_tasks_open", "Ray opens global queue")
	state.subtitle_task = {}; menu.refresh()
	var generate: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SUBTITLE_GENERATE)[0]
	var queue_button: Dictionary = menu._buttons.filter(func(button): return button.target == menu.SUBTITLE_TASKS)[0]
	check(menu.choices.targets.keys().all(func(id): return menu._buttons.filter(func(button): return button.target == id)[0].node.position.y > generate.node.position.y), "Pregeneration follows every listening option")
	check(is_equal_approx(generate.node.position.y, menu._subtitle_panel_bounds.position.y + 0.06) and is_equal_approx(queue_button.node.position.y, generate.node.position.y), "Generate and management share the bottom row")
	check(tap(menu, menu.SUBTITLE_GENERATE) and actions.back()[0] == "listening_generate", "Ray starts pregeneration")
	check(not str(menu._tips.get(menu.SUBTITLE_GENERATE, "")).is_empty(), "Generation tooltip supplied")
	state.listening_cache_complete = true; state.listening_cache_persistent = true; menu.refresh()
	check(menu._buttons.filter(func(button): return button.target == menu.SUBTITLE_GENERATE).all(func(button): return not button.enabled), "Complete cached original disables duplicate work")
	menu.free(); library.free(); tasks.translator.close(); client.close(); video.free()
	print("Subtitle tasks: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
