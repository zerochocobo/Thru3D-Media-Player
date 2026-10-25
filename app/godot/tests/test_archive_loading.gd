extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Archive := preload("res://scripts/archive_panel.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	signal archive_ready(id: int, payload: String)
	var closes := 0
	func archive_open(_uri: String, _title: String, _password: String, _persist: bool) -> int: return 42
	func archive_close(_key: String) -> void: closes += 1
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label); push_error(label)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var privacy := preload("res://scripts/media_privacy.gd")
	var previous := privacy.mode; privacy.configure(privacy.NONE)
	for compact in [false, true]:
		var host := Host.new(); var library := Library.new(); library.platform = host
		root.add_child(library); library.visible = true; library.set_process(false); library.set_compact(compact)
		library._set_backdrop(Vector2(1.68, 1.44), Vector2(0.13, 0.015))
		library.archives.open({"uri":"cloud://account/book.rar", "title":"book.rar"})
		var panel: MeshInstance3D = library._backdrop
		check(panel.position == Vector3.ZERO, "archive modal replaces stale panel centre")
		check(panel.mesh.size == Vector2(1.36, 1.18), "archive modal owns consistent geometry")
		var label: Label3D = library.archives.progress_label
		var redraws := [0]
		library.composition_changed.connect(func(): redraws[0] += 1)
		check(Vector2(label.position.x, label.position.y) == Vector2(panel.position.x, panel.position.y), "loading text is at actual panel centre")
		var close: Dictionary = library._buttons.filter(func(b): return b.target == Archive.CLOSE)[0]
		var edge: Vector2 = panel.mesh.size * 0.5
		check(is_equal_approx(edge.x - close.rect.end.x, 0.06) and is_equal_approx(edge.y - close.rect.end.y, 0.06), "close button is inset from top-right corner")
		var hit: Dictionary = library.pointer_hit(close.node.global_position + Vector3(0,0,1), Vector3(0,0,-1))
		check(hit.get("target", -1) == Archive.CLOSE, "top-right close button keeps real ray target")
		for percent in [1, 37, 99, 100]:
			var before := int(redraws[0])
			host.archive_ready.emit(42, JSON.stringify({"state":"loading", "received":percent, "total":100}))
			await process_frame; library.archives.tick()
			check(library.archives.pending == 42 and library.archives.opened, "progress keeps request alive")
			var current_close: Dictionary = library._buttons.filter(func(b): return b.target == Archive.CLOSE)[0]
			check(library.archives.progress_label == label and close.node == current_close.node, "progress updates text without rebuilding close target")
			check(label.text.ends_with(" %d%%" % percent), "progress percent is visible")
			check(redraws[0] > before, "progress invalidates the high-resolution composition texture")
		var before := int(redraws[0])
		host.archive_ready.emit(42, JSON.stringify({"state":"loading", "received":100, "total":100}))
		await process_frame; library.archives.tick()
		check(redraws[0] == before, "duplicate progress does not redraw unchanged text")
		library.archives.action(Archive.CLOSE)
		check(not library.archives.opened and library.archives.progress < 0 and host.closes > 0, "close cancels modal and clears progress")
		host.archive_ready.emit(42, JSON.stringify({"state":"loading", "received":50, "total":100}))
		await process_frame; library.archives.tick()
		check(not library.archives.opened and library.archives.pending == 0, "late progress cannot reopen dismissed dialog")
		library.archives.open({"uri":"cloud://account/next.rar", "title":"next.rar"})
		check(library.archives.progress < 0, "next open starts without stale percent")
		host.archive_ready.emit(42, JSON.stringify({"state":"ready", "session":"ready", "entries":[]}))
		await process_frame; library.archives.tick()
		check(library.archives.browsing and not library.archives.opened, "final ready result enters browser after progress")
		library.archives.close(); library.queue_free(); await process_frame
	privacy.configure(previous)
	print("Archive loading: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
