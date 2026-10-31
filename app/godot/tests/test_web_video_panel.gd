extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
class Platform extends Fixture.Platform:
	var web_id := 0
	var web_state := {}
	var web_cancelled := 0
	func web_video_resolve(url: String) -> int:
		web_id += 1; web_state = {"id": web_id, "state": "resolving", "uri": url}; return web_id
	func web_video_status() -> String: return JSON.stringify(web_state)
	func web_video_cancel() -> void: web_cancelled += 1
var checks := 0
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	check(not menu._grid(), "URL and playback actions remain a readable list")
	check(menu.rows.size() == 3, "Initial video page provides URL/paste/open")
	check(not bool(menu.rows[2].enabled), "Empty URL cannot resolve")
	menu.web_video._changed("https://www.youtube.com/watch?v=BaW_jenozKc")
	menu.web_video.resolve()
	check(menu.web_video.pending == 1, "URL enters asynchronous resolver")
	platform.web_state = {"id": 0, "state": "ready", "uri": "https://old.test", "title": "Old"}
	menu.web_video.tick()
	check(menu.web_video.result.is_empty(), "Stale resolver result cannot replace current video")
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	check(platform.web_cancelled == 1 and menu.web_video.pending == 0, "Leaving web videos cancels extraction")
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.web_video.resolve()
	platform.web_state = {"id": 2, "state": "ready", "uri": "https://www.youtube.com/watch?v=BaW_jenozKc", "title": "测试视频", "height": 1080}
	menu.web_video.tick()
	check(menu.rows.size() == 4 and menu.rows[3].web_video == "play", "Resolved stream has a separate explicit play action")
	var chosen: Array = []
	menu.chosen.connect(func(uri, title): chosen.append([uri, title]))
	menu._choose(menu.rows[3])
	check(chosen == [[platform.web_state.uri, "测试视频"]], "Playback uses existing chosen signal and stable page identity")
	check(not menu.visible, "Library closes when handing off to the existing player")
	menu.web_video.result = {"state": "error", "error_code": "site_rejected"}
	check(menu.web_video.error_hint() == "网站拒绝视频请求，请重试",
		"A website rejection explains the cause")
	for entry in [["browser_video_identity_unavailable", "未取得当前视频信息"], ["browser_audio_missing", "未采集到音轨"], ["browser_pause_timeout", "无法暂停网页视频"], ["protected_content", "加密视频"]]:
		menu.web_video.result = {"error_code": entry[0]}
		check(menu.web_video.error_hint().begins_with(entry[1]), "Specific capture failure has an actionable localized cause")
	menu.free(); platform.free()
	print("Web video panel: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
