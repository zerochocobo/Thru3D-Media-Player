extends SceneTree
const Reader := preload("res://scripts/photo_comic_reader.gd")

# Real native fixtures, not synthetic blocks. The Python driver verifies pixels,
# annotations and every native contour field before producing this input.
func _initialize() -> void: call_deferred("run")

func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Expected fixture.json and report.json"); quit(1); return
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var checks := 0
	var failures: Array = []
	for case: Dictionary in fixture.cases:
		var original: Dictionary = fixture.pages[case.page]
		for target_page in [0, 1]:
			var page := original.duplicate(true)
			page["page"] = target_page
			var regions: Array = [Rect2(0, 0, 1, 1)] if target_page == 0 else [Rect2(0, 0, 0.37, 1), Rect2(0.37, 0, 0.63, 1)]
			var region: Rect2 = regions[target_page]
			var size := Vector2(page.page_size[0], page.page_size[1])
			for negative in [false, true]:
				for point: Array in case.negative if negative else case.points:
					var uv := region.position + Vector2(point[0], point[1]) / size * region.size
					var result := Reader.hit([page], regions, uv)
					checks += 1
					var correct: bool = result.is_empty() if negative else result.get("key", "") == "%d:%d" % [target_page, case.block_id]
					if not correct and failures.size() < 20:
						failures.append({"page": case.page, "annotation_id": case.annotation_id, "point": point, "negative": negative, "spread_page": target_page, "actual": str(result)})
	var report := {"checks": checks, "balloons": fixture.cases.size(), "failures": failures, "single_page_and_unequal_spread": true, "debug_build": OS.is_debug_build()}
	var file := FileAccess.open(args[1], FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ")); file.close()
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
