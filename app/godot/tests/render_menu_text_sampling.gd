extends SceneTree
## Compare the production menu with the previous small, unmipmapped glyphs while the
## camera moves by fractions of an eye-buffer pixel. This measures sampling, not comfort.
const Menu := preload("res://scripts/ray_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const SIZES := [18, 18, 18, 18, 14, 24]
const TEXT := ["白色文字 清晰度 视频文件夹", "繁體中文 藍光電影 圖片資料庫",
	"日本語 字幕設定 映画 フォルダー", "Menu Settings Folder ABCDE 0123456789",
	"复杂笔画 噪点抖动 鉴别测试", "Playback Settings 0123456789"]
var output := ProjectSettings.globalize_path("res://../../build/output/menu-clarity/sampling")
var failures: Array[String] = []
var checks := 0
var linear := PackedFloat64Array()

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for i in 256:
		var s := float(i) / 255.0
		linear.append(s / 12.92 if s <= 0.04045 else pow((s + 0.055) / 1.055, 2.4))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1200, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 75
	viewport.add_child(camera)
	var evidence := []
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		var menu := Menu.new(); viewport.add_child(menu); menu.visible = true
		var font := menu.ui_font()
		# The menu font is the bracket font over the system font over the engine fallback; the
		# "before" chain is the same fonts without mipmaps.
		var old_font := font.duplicate() as FontFile
		old_font.generate_mipmaps = false
		var old_system := (font.fallbacks[0] as SystemFont).duplicate() as SystemFont
		old_system.generate_mipmaps = false
		var old_fallback := ThemeDB.fallback_font.duplicate() as FontFile
		old_fallback.generate_mipmaps = false
		old_system.fallbacks = [old_fallback]
		old_font.fallbacks = [old_system]
		var labels: Array[Label3D] = []
		for row in TEXT.size():
			var label := menu._label(TEXT[row], Vector3(-0.65, 0.34 - row * 0.11, 0.005), SIZES[row])
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			labels.append(label)
		var traces := {}
		for mode in ["before", "after"]:
			for row in labels.size():
				var label := labels[row]
				if mode == "before":
					label.font = old_font; label.font_size = SIZES[row]; label.pixel_size = 0.0012
				else:
					label.font = font; menu.set_label_size(label, SIZES[row])
				check(is_equal_approx(label.font_size * label.pixel_size, SIZES[row] * 0.0012), "Physical size: " + language + mode + str(row))
			var trace := []
			for frame in 8:
				camera.position.x = frame * (2.0 * tan(deg_to_rad(camera.fov * 0.5)) * 1.55 / viewport.size.y) / 8.0
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var image := viewport.get_texture().get_image()
				image.convert(Image.FORMAT_RGBA8)
				if frame == 0: image.save_png(output.path_join(language + "-" + mode + ".png"))
				trace.append(energy(image))
			traces[mode] = trace
		var before := coefficient(traces.before)
		var after := coefficient(traces.after)
		# Average the three CJK runs. Do not select one favourable glyph or phase.
		var old_cjk := (before[0] + before[1] + before[2]) / 3.0
		var new_cjk := (after[0] + after[1] + after[2]) / 3.0
		check(new_cjk < old_cjk * 0.75, "CJK sampling becomes steadier: " + language)
		for row in labels.size():
			var fitted := menu._fit_title(TEXT[row].repeat(3), "", 0.27, SIZES[row])
			check(menu.text_width(fitted, SIZES[row]) <= 0.27, "Elision measures rendered glyphs: " + language + str(row))
			check(traces.after[0][row] > 1.0, "Visible strokes: " + language + str(row))
		var icon := preload("res://scripts/menu_icons.gd").texture("folder").get_image()
		check(icon.has_mipmaps(), "Small folder icon is prefiltered: " + language)
		evidence.append({"language": language, "font": font.get_font_name(), "before_cv_percent": before,
			"after_cv_percent": after, "cjk_average_before": old_cjk, "cjk_average_after": new_cjk})
		menu.queue_free(); await process_frame
	viewport.queue_free(); await process_frame
	I18n.use("en")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"scope": "Desktop OpenGL glyph sampling only; headset optics and comfort unverified",
		"checks": checks, "cases": evidence, "failures": failures}, "\t"))
	for failure in failures: push_error(failure)
	print("Menu text sampling: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func energy(image: Image) -> PackedFloat64Array:
	var data := image.get_data()
	var background := linear[data[(300 * image.get_width() + 600) * 4]]
	var result := PackedFloat64Array()
	for y0 in [333, 375, 417, 459, 500, 543]:
		var total := 0.0
		for y in range(y0 - 18, y0 + 19):
			for x in range(345, 700):
				total += maxf(0, linear[data[(y * image.get_width() + x) * 4]] - background)
		result.append(total)
	return result

func coefficient(trace: Array) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	for row in TEXT.size():
		var mean := 0.0
		for frame in trace: mean += frame[row] / trace.size()
		var variance := 0.0
		for frame in trace: variance += pow(frame[row] - mean, 2) / trace.size()
		result.append(sqrt(variance) / maxf(mean, 0.0001) * 100.0)
	return result
