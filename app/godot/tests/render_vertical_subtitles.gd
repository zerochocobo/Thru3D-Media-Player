extends SceneTree
const Patch := preload("res://scripts/projected_subtitles.gd")
const Depth := preload("res://scripts/subtitle_depth.gd")
const Style := preload("res://scripts/subtitle_style.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("VERTICAL_SUBTITLE_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var patch := Patch.new()
	root.add_child(patch)
	var caption := Label3D.new()
	caption.visible = true
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	var samples := {"alignment_wrapped": "田".repeat(40), "alignment": "田田田田\n田田田田", "bilingual": "今天的风景很美。\nBeautiful scenery today.",
		"wrapped": "今天的风景很美，我们继续向前走，一起欣赏远处的群山和湖泊。\nWe keep walking and enjoy the mountains and the lake.",
		"punctuation": "你好（世界）！\nこんにちは、世界。\nVR 2026 😀 é", "empty_line": "第一列\n\n第三列"}
	var report := {"samples": {}, "checks": 0, "failures": failures}
	for key in samples:
		caption.text = samples[key]
		patch.update_patch(caption, material, Depth.anchor(0, true), 0.1, true)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := patch.viewport.get_texture().get_image()
		image.save_png(output.path_join(key + ".png"))
		var columns: Array = []
		var reconstructed := ""
		for column in patch.vertical_text.columns:
			columns.append({"text": column.text, "point": [column.point.x, column.point.y], "size": [column.size.x, column.size.y]})
			reconstructed += column.text
		check(reconstructed == str(samples[key]).replace("\n", ""), "All text preserved: " + key)
		check(not patch.label.visible and patch.vertical_text.visible, "Only vertical canvas visible")
		report.samples[key] = columns
		if key.begins_with("alignment"):
			check(columns.size() == 2 if key == "alignment" else columns.size() >= 3, "Explicit newline and automatic wrapping produce separate columns")
			for column in patch.vertical_text.columns:
				var centres: Array[float] = []
				for row in 4:
					var mass := 0.0
					var total := 0.0
					for y in range(int(column.point.y + row * 40), int(column.point.y + (row + 1) * 40)):
						for x in range(int(column.point.x - 28), int(column.point.x + 28)):
							var c := image.get_pixel(x, y)
							var w := minf(c.r, minf(c.g, c.b)) * c.a
							if w < 0.5: continue
							mass += w; total += x * w
					check(mass > 10, "Each glyph cell has visible text")
					centres.append(total / maxf(0.001, mass))
				check(absf(centres[0] - centres[1]) < 0.5 and absf(centres[0] - centres[3]) < 0.5,
					"First glyph shares subsequent glyph centres")
				report.samples[key].append({"glyph_centres": centres})
		if key == "bilingual":
			check(patch.vertical_text.columns.size() == 2 and not patch.vertical_text.columns[0].get("sideways", false)
				and patch.vertical_text.columns[1].get("sideways", false), "Chinese upright and English whole words sideways")
		if key == "wrapped": check(columns.size() > 2, "Long bilingual lines wrap into additional columns")
		if key == "empty_line": check(columns.size() == 3, "Blank lines retain separation")
	caption.text = samples.bilingual
	patch.update_patch(caption, material, Basis(), 5, false)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	patch.viewport.get_texture().get_image().save_png(output.path_join("horizontal.png"))
	check(patch.label.visible and not patch.vertical_text.visible, "Direction switch replaces same cue immediately")
	# Recolor the same cue without waiting for a new subtitle event in either orientation.
	caption.text = "田田\nABC"
	for vertical in [false, true]:
		for preset in Style.PRESETS:
			patch.update_patch(caption, material, Basis(), 5, vertical, 1.0, preset.value)
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := patch.viewport.get_texture().get_image()
			image.save_png(output.path_join("style_%s_%s.png" % [preset.value, "vertical" if vertical else "horizontal"]))
			var fill := 0; var outline := 0
			for y in image.get_height():
				for x in image.get_width():
					var color := image.get_pixel(x, y)
					if color.a < 0.98: continue
					if close_color(color, preset.text_color): fill += 1
					if close_color(color, preset.outline_color): outline += 1
			check(fill > 100 and outline > 100, "Rendered fill and outline match " + preset.value + (" vertical" if vertical else " horizontal"))
	# A size-only change must refresh the patch, while unchanged frames keep it cached.
	for vertical in [false, true]:
		for text_size in [0.5, 2.0]:
			patch.update_patch(caption, material, Basis(), 5, vertical, text_size, Style.DEFAULT)
			check(patch._size == text_size and (patch.vertical_text.font_scale == text_size if vertical else patch.label.get_theme_font_size("font_size") == roundi(40 * text_size)), "Projected size changes immediately")
			patch.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
			patch.update_patch(caption, material, Basis(), 5, vertical, text_size, Style.DEFAULT)
			check(patch.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Unchanged caption does not redraw")
	for angle in [-60.0, 0.0, 60.0]:
		var direction := Depth.anchor(angle, true) * Vector3.FORWARD
		check(is_equal_approx(direction.x, sin(deg_to_rad(angle))) and is_zero_approx(direction.y), "Vertical slider moves left to right")
	patch.update_patch(caption, material, Basis(), 0.1, false)
	var inverse: Transform3D = material.get_shader_parameter("subtitle_world_to_patch")
	check(is_equal_approx(inverse.affine_inverse().origin.length(), 0.1), "Direct nearest test input places the shared plane at 0.1m")
	caption.free()
	patch.queue_free()
	await process_frame
	report.checks = checks
	report.state = "passed" if failures.is_empty() else "failed"
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Vertical subtitle render checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)

func close_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.04 and absf(a.g - b.g) < 0.04 and absf(a.b - b.b) < 0.04
