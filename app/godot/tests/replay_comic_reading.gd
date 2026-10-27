extends SceneTree
const Reader := preload("res://scripts/photo_comic_reader.gd")

class Platform extends RefCounted:
	var pages := []
	var reads := []
	var now := 0
	func comic_reader_stop() -> void: pass
	func comic_reader_prepare(_epoch: int, _page: int, _id: int) -> bool: return true
	func comic_reader_read(epoch: int, page: int, id: int, voice: String, volume: float) -> bool:
		for source: Dictionary in pages:
			if int(source.page) != page: continue
			for block: Dictionary in source.blocks:
				if int(block.id) != id or not block.eligible: continue
				if str(block.text).strip_edges().is_empty() or voice.is_empty() or volume <= 0: return false
				reads.append({"epoch": epoch, "page": page, "block": id, "text": block.text, "at_ms": now})
				return true
		return false

class Photo extends Node3D:
	var platform := Platform.new()
	var panel := Node3D.new()
	var _flat := QuadMesh.new()
	var screen_curve := 0.0
	func _init() -> void:
		add_child(panel)
		_flat.size = Vector2(1.0, 1.4)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2: quit(2); return
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var owner := Photo.new()
	root.add_child(owner)
	var reader := Reader.new(owner)
	reader.epoch = 1
	var rows := []
	var failures := []
	for case: Dictionary in fixture.cases:
		var page: Dictionary = fixture.pages[case.page].duplicate(true)
		page.page = 0
		reader.pages = [page]
		owner.platform.pages = reader.pages
		var size := Vector2(page.page_size[0], page.page_size[1])
		var attempts := []
		for layout in ["single", "spread"]:
			var regions := [Rect2(0, 0, 1, 1)] if layout == "single" else [Rect2(0.37, 0, 0.63, 1)]
			var region: Rect2 = regions[0]
			for point_index in case.points.size():
				for trace in ["steady", "jitter"]:
					reader.stop()
					owner.platform.reads = []
					for frame in 76:
						var now := frame * 14 # approximately 72 Hz; never a stalled-frame jump
						var point := Vector2(case.points[point_index][0], case.points[point_index][1])
						if trace == "jitter": point += Vector2(sin(frame * 0.7), cos(frame * 0.6)) * 3.0
						var selected := Reader.hit(reader.pages, regions, region.position + point / size * region.size)
						owner.platform.now = now
						reader.update_selection(selected, now, "Xiaoyu", 0.8)
					var reads: Array = owner.platform.reads.duplicate(true)
					if reads.size() > 1 or (not reads.is_empty() and int(reads[0].at_ms) < 600):
						failures.append({"page": case.page, "id": case.id, "reads": reads})
					attempts.append({"point": point_index, "layout": layout, "trace": trace, "reads": reads})
		rows.append({"page": case.page, "id": case.id, "negative": case.get("negative", false), "attempts": attempts})
	var output := FileAccess.open(args[1], FileAccess.WRITE)
	output.store_string(JSON.stringify({"cases": rows, "invariant_failures": failures,
		"scope": "Actual Reader.hit, Dwell.update and Reader.update_selection. Speech bridge is captured, not Android audio playback."}, "  "))
	output.close()
	reader.close()
	owner.free()
	print("comic reading replay: %d cases; %d timing/duplicate failures" % [rows.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
