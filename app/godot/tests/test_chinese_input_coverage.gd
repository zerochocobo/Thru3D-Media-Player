extends SceneTree
const Chinese := preload("res://scripts/chinese_input.gd")
const I18n := preload("res://scripts/i18n.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Music := preload("res://scripts/music_menu.gd")
const Audio := preload("res://scripts/background_audio.gd")
const Scenery := preload("res://scripts/scenery_menu.gd")
const Backgrounds := preload("res://scripts/background_library.gd")
var checks := 0
var failures: Array[String] = []
var directory := ProjectSettings.globalize_path("res://../../build/output/quest-input-coverage-20261104/data-") + str(Time.get_ticks_usec())

class Platform extends "res://tests/account_platform_fixture.gd":
	var edits: Array = []
	var mutations: Array = []
	var passwords: Array = []
	func account_input(id: int, field: String, action: String, text: String) -> void:
		edits.append([id, field, action, text])
		if action == "replace" and account_sessions.has(id):
			account_sessions[id].fields[field] = text; account_sessions[id].revision += 1
		else: super(id, field, action, text)
	func media_file_rename_prepare(json: String) -> int:
		mutations.append(["prepare", JSON.parse_string(json)]); return mutations.size()
	func media_file_rename(json: String) -> int:
		mutations.append(["rename", JSON.parse_string(json)]); return mutations.size()
	func media_smb_save(json: String) -> int:
		mutations.append(["smb", JSON.parse_string(json)]); return mutations.size()
	func archive_passwords(operation: String, value: String) -> String:
		if operation == "add": passwords.append(value)
		return JSON.stringify({"passwords": passwords})

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); push_error(message)

func popup(expected: bool, label: String) -> void:
	check(Chinese.active() == expected, label + " popup platform gate")
	if expected: check(not Chinese.popup.ime.failed, label + " dictionary available")

func has_key(menu: Node3D, id: int) -> bool:
	return menu._buttons.any(func(item): return item.target == id)

func insert(editor: RefCounted, value: String, custom: bool) -> void:
	check(editor.custom == custom and editor.editor.virtual_keyboard_enabled != custom, "Correct input backend")
	if custom:
		editor.editor.select_all()
		check(Chinese.popup._send("text", value), "Popup commits Unicode")
	else:
		editor.editor.text = value; editor.editor.text_changed.emit(value)

func voice(custom: bool, global_manager: bool) -> void:
	var state := {"source_uri": "global-voice-manager" if global_manager else "file:///fixture.mp4", "global_voice_manager": global_manager,
		"has_video": true, "narration_clone_supported": true, "narration_personal_voices": [],
		"narration_clone_state": {"state": "ready", "source_ready": true, "duration": 1200, "audio_id": 1,
			"ready_key": "a", "revision": 1, "candidates": [{"key": "a", "start": 10.0, "end": 16.0, "text": "中文"}]}}
	var menu: Node3D = Library.new() if global_manager else Player.new()
	if global_manager: menu.settings_provider = func(): return {"voice_manager": state}
	else: menu.state_provider = func(): return state
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu._state = state
	if not global_manager: menu.refresh(); menu._subtitle_open = true
	var panel: RefCounted = menu.voice_manager if global_manager else menu.clone_panel
	var commands: Array = []
	if global_manager: menu.setting_changed.connect(func(_key, value): commands.append(value))
	else: menu.setting_requested.connect(func(_key, value): commands.append(value))
	panel.open(false)
	if global_manager: panel.sample.active = true; panel.sample.page = "results"; menu.refresh()
	for operation in ["save", "rename"]:
		panel.naming = {"operation": operation, "key": "a", "id": "personal-a", "apply": false}
		panel.draft = "Before"; panel.edit(); await process_frame
		popup(custom, "Voice " + operation)
		insert(panel.editor, "中文音色🙂", custom)
		state.narration_clone_state.revision += 1; menu.refresh()
		check(panel.draft == "中文音色🙂" and panel.editor.active(), "Voice redraw preserves draft")
		var count := commands.size()
		if custom: Chinese.popup._activate(6)
		else: panel.editor.editor.text_submitted.emit(panel.draft)
		check(commands.size() == count + 1 and commands.back().operation == operation and commands.back().name == "中文音色🙂", "Voice submit once")
		check(not panel.editor.active() and not Chinese.active(), "Voice submit closes editor")
		panel.saving = false
	panel.naming = {"operation": "save", "key": "a"}; panel.edit(); panel.close(); await process_frame
	check(not panel.editor.active() and not Chinese.active(), "Voice close cancels deferred focus")
	menu.free()

func files(menu: Node3D, platform: Object, custom: bool) -> void:
	menu.section = Library.Section.LOCAL; menu._local_stack = [{"id": "/fixture", "title": "Files"}]
	menu.file_actions.enabled = true
	var rename: RefCounted = menu.file_actions.rename
	for folder in [false, true]:
		rename.open({"uri": "file:///fixture/original", "title": "Original.folder" if folder else "Original.mp4", "folder": folder, "kind": "folder" if folder else "video"})
		await process_frame; popup(custom, "File/folder rename")
		check(has_key(menu, Library.KEY_BASE) != custom, "Rename shows only the selected keyboard")
		var count: int = platform.mutations.size()
		if custom:
			Chinese.popup.english = false
			for letter in "dianying": Chinese.popup.type_key(letter)
			check(rename.name.begins_with("Original") and platform.mutations.size() == count, "Pinyin composition does not rename files")
			Chinese.popup._activate(6)
			check(rename.name == "电影" and platform.mutations.size() == count, "First Enter commits only candidate")
			Chinese.popup._activate(6)
		else:
			rename.action(9190); rename.action(Library.KEY_BASE + 10); rename.action(rename.PREVIEW)
		check(platform.mutations.size() == count + 1 and platform.mutations.back()[0] == "prepare", "Enter/preview only prepares rename")
		check(platform.mutations.back()[1].new_name == ("电影" if custom else "q"), "Rename preserves requested basename")
		check(not Chinese.active(), "Rename preview releases keyboard")
		var prepared: Dictionary = platform.mutations.back()[1]
		rename.receive(rename.request_id, JSON.stringify({"state": "ready", "uri": prepared.uri, "preview": true, "plan": "test-plan", "moves": []}))
		check(rename.phase == "preview" and platform.mutations.size() == count + 1, "Preview awaits explicit apply")
		rename.action(rename.APPLY)
		check(platform.mutations.size() == count + 2 and platform.mutations.back()[0] == "rename", "Explicit apply dispatches once")
		rename.action(rename.APPLY)
		check(platform.mutations.size() == count + 2, "Pending rename rejects repeated apply")
		rename.receive(rename.request_id, JSON.stringify({"state": "error", "uri": prepared.uri}))
		rename.action(menu.file_actions.CANCEL)
	menu.file_actions.reset()
	if custom:
		rename.open({"uri": "file:///fixture/last.mp4", "title": "Last.mp4"}); await process_frame
		var stale: Callable = Chinese.popup.dispatch
		menu.file_actions.reset()
		check(not stale.call("text", "旧名字") and not Chinese.active(), "Reset revokes file editor")

func accounts(menu: Node3D, platform: Object, custom: bool) -> void:
	var panel: RefCounted = menu.account_panel
	panel.kind = "server"; panel.start("server", "emby")
	panel.action(panel.FIELD); await process_frame; popup(custom, "Server name")
	check(has_key(menu, panel.KEY) != custom, "Account field has one keyboard")
	var stale: Callable
	if custom:
		insert(menu.system_text_input, "客厅服务器", true)
		check(panel.data.fields.name == "客厅服务器", "Native account name receives Chinese")
		stale = Chinese.popup.dispatch
	else:
		panel.action(panel.KEY + 10)
		check(str(panel.data.fields.name).ends_with("q"), "Original account ray keyboard remains usable")
	panel.action(panel.FIELD + 2); await process_frame
	if custom:
		var count: int = platform.edits.size()
		check(not stale.call("text", "串字段") and platform.edits.size() == count, "Old name callback cannot write to username")
		check(Chinese.popup.english, "Username starts in English")
		insert(menu.system_text_input, "中文用户", true)
		check(panel.data.fields.username == "中文用户", "Chinese username reaches native input")
		stale = Chinese.popup.dispatch
	panel.action(panel.FIELD + 1); await process_frame
	check(not Chinese.active() and has_key(menu, panel.KEY), "Server address retains original keyboard")
	if custom: check(not stale.call("text", "旧字段"), "Switch to address revokes custom editor")
	panel.action(panel.FIELD + 3); await process_frame
	check(not Chinese.active() and has_key(menu, panel.KEY), "Account password retains existing private input path")
	panel.close()
	panel.kind = "cloud"; panel.start("cloud", "baidu", "saved-account"); await process_frame
	popup(custom, "Cloud account name")
	if custom:
		insert(menu.system_text_input, "我的网盘", true)
		stale = Chinese.popup.dispatch
		platform.account_sessions[panel.session].busy = true; panel.poll()
		check(not Chinese.active() and not stale.call("text", "忙碌"), "Native busy state revokes input")
		platform.account_sessions[panel.session].busy = false; panel.poll(); panel.action(panel.FIELD); await process_frame
		platform.account_sessions[panel.session].state = "web"; panel.poll()
		check(not Chinese.active() and not menu.system_text_input.active(), "Authorization page keeps its original separate input path")
	panel.close()
	menu.section = Library.Section.SMB; menu._open_editor({"id": "s", "host": "nas", "name": "NAS", "user": "user"})
	menu._editor_input(Library.FIELD_BASE); await process_frame; popup(custom, "SMB name")
	check(has_key(menu, Library.KEY_BASE) != custom, "SMB name has one keyboard")
	if custom:
		insert(menu.system_text_input, "家里的硬盘", true); stale = Chinese.popup.dispatch
	else:
		menu._editor_input(Library.KEY_BASE + 10)
		check(menu._editor.name == "NASq", "SMB original keyboard unchanged")
	menu._editor_input(Library.FIELD_BASE + 2); await process_frame
	if custom:
		check(not stale.call("text", "串字段"), "SMB old field callback rejected")
		insert(menu.system_text_input, "共享用户", true)
	menu._editor_input(Library.FIELD_BASE + 1); await process_frame
	check(not Chinese.active() and has_key(menu, Library.KEY_BASE), "SMB address retains original input")
	menu._editor_input(Library.SAVE)
	check(platform.mutations.back()[0] == "smb" and platform.mutations.back()[1].host == "nas", "SMB save uses unchanged address")
	if custom: check(platform.mutations.back()[1].name == "家里的硬盘" and platform.mutations.back()[1].user == "共享用户", "SMB save includes Chinese name and username")
	menu.section = Library.Section.DLNA; menu._open_editor({}); await process_frame
	check(not Chinese.active() and has_key(menu, Library.KEY_BASE), "DLNA IP and port retain original keyboard")
	menu._editor_input(Library.CANCEL)

func archive(menu: Node3D, platform: Object, custom: bool) -> void:
	menu.archives.manage(); menu.archives.action(menu.archives.INPUT); await process_frame
	popup(custom, "Archive password")
	if custom: check(Chinese.popup.english, "Archive password starts in English")
	insert(menu.system_text_input, "中文密码123", custom)
	if custom: Chinese.popup._activate(6)
	else: menu.archives.action(menu.archives.SUBMIT)
	check(platform.passwords.back() == "中文密码123" and not menu.system_text_input.active(), "Password book receives exact Unicode password")
	menu.archives.close()

func playlists(custom: bool, label: String) -> void:
	var audio := Audio.new(); audio.directory = directory.path_join(label + "/audio"); root.add_child(audio)
	var music := Music.new(); music.audio = audio; root.add_child(music); music.open(false)
	music._activate(Music.NEW_LIST); await process_frame; popup(custom, "New playlist")
	check(has_key(music, Music.KEY) != custom, "Playlist shows one keyboard")
	if custom:
		insert(music.editor, "夜晚音乐", true); music.refresh()
		check(music.editor.active() and music.name_text == "夜晚音乐", "Music refresh retains name draft")
		Chinese.popup._activate(6)
	else:
		music._activate(Music.KEY + 10); music._activate(Music.SAVE_NAME)
	var id: String = music.playlist_id
	check(not id.is_empty() and music.modal.is_empty(), "Playlist saved")
	if custom: check(audio.library.playlist(id).label == "夜晚音乐", "Playlist Chinese name persisted")
	music.target_playlist = id; music._open_modal("playlist"); music._activate(Music.RENAME); await process_frame
	popup(custom, "Rename playlist")
	if custom: insert(music.editor, "清晨音乐", true)
	else: music._activate(Music.KEY + 11)
	music._activate(Music.SAVE_NAME)
	check(not music.editor.active() and not Chinese.active(), "Ray save closes playlist editor")
	if custom: check(audio.library.playlist(id).label == "清晨音乐", "Playlist rename persists")
	music._activate(Music.NEW_LIST); music.dismiss(); await process_frame
	check(not Chinese.active() and not music.editor.active(), "Music dismiss cancels deferred input")
	music.free(); audio.free()

func backgrounds(custom: bool, label: String) -> void:
	var library := Backgrounds.new(); library.directory = directory.path_join(label + "/backgrounds"); root.add_child(library)
	library.assets["fixture"] = {"title": "Before", "added": 1, "geometry": 3}
	var menu := Scenery.new(); menu.library = library; root.add_child(menu); menu.open("image")
	menu.view = "manage"; menu.refresh(); menu._activate(Scenery.RENAMES); await process_frame
	popup(custom, "Background rename")
	insert(menu.editor, "日落全景", custom)
	if custom: Chinese.popup._activate(6)
	else: menu._activate(Scenery.SAVE)
	check(library.assets.fixture.title == "日落全景" and menu.modal.is_empty(), "Background Chinese rename saved")
	menu.free(); library.free()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	for profile in [[true, "zh", true, "quest"], [false, "zh", true, "pico"], [true, "zh", false, "off"], [true, "en", true, "english"]]:
		Chinese.quest = profile[0]; I18n.use(profile[1]); Chinese.configure(profile[2])
		var custom: bool = profile[3] == "quest"
		await voice(custom, true); await voice(custom, false)
		var platform := Platform.new(); var menu := Library.new(); root.add_child(menu); menu.platform = platform; menu.visible = true; menu.set_process(false)
		await files(menu, platform, custom)
		await accounts(menu, platform, custom)
		await archive(menu, platform, custom)
		menu.free(); platform.free()
		await playlists(custom, profile[3])
		await backgrounds(custom, profile[3])
		check(not Chinese.active(), "All input closed after profile " + profile[3])
	Chinese.configure(false)
	if is_instance_valid(Chinese.popup): Chinese.popup.free()
	print("Chinese input coverage checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
