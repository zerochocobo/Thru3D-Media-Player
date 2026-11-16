extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Recent := preload("res://scripts/recent_files.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")
func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func kinds(recent: RefCounted) -> Array:
	var result: Array = recent.list_recent().map(func(entry): return str(entry.get("kind", "video")))
	result.sort()
	return result

func tip(menu: Node) -> String: return str(menu._tips.get(menu.CLEAR_HISTORY, ""))

func run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	Privacy.vault = null; Privacy.configure("all")
	var recent := Recent.new("user://test_recent_filtered_clear/%d" % Time.get_ticks_usec())
	for i in 3: recent.opened("file:///Clips/video%d.mp4" % i, "Video %d" % i, false)
	for i in 2: recent.opened("smb://nas/Photos/photo%d.jpg" % i, "Photo %d" % i, false, "image")
	var menu := Library.new(); root.add_child(menu)
	menu.catalog = recent; menu.section = Library.Section.RECENT; menu.visible = true; menu.refresh()
	check(tip(menu) == "Clear history", "No filter keeps the clear-all tooltip")
	menu._change_media_filter(2)
	check(menu.rows.size() == 2 and tip(menu) == "Clear image history", "The image filter names its narrower clear")
	menu._activate(menu.CLEAR_HISTORY)
	check(kinds(recent) == ["video", "video", "video"], "Images filter clears only image history: %s" % [kinds(recent)])
	check(menu.rows.is_empty() and menu.media_filter == 2, "The emptied image list stays on its filter")
	menu._activate(menu.collections.UNDO)
	check(recent.list_recent().size() == 5, "A filtered clear restores every removed entry on undo")
	menu._change_media_filter(1)
	check(menu.rows.size() == 3 and tip(menu) == "Clear video history", "The video filter names its narrower clear")
	menu._activate(menu.CLEAR_HISTORY)
	check(kinds(recent) == ["image", "image"], "Video filter clears only video history: %s" % [kinds(recent)])
	menu._change_media_filter(0)
	check(menu.rows.size() == 2, "Remaining images still list without a filter")
	menu._activate(menu.CLEAR_HISTORY)
	check(recent.list_recent().is_empty(), "Without a filter the button still clears everything")
	menu.free()
	print("Recent filtered clear: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
