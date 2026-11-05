extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const States := preload("res://tests/render_ui_theme_states.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Disc := preload("res://scripts/disc_menu_bar.gd")
const Capture := preload("res://scripts/capture_overlay.gd")
const Main := preload("res://scripts/main.gd")
const Logo := preload("res://scripts/main_logo.gd")
const BrowserFixture := preload("res://tests/test_web_browser_windows.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
const PuzzleEntry := preload("res://scripts/puzzle/puzzle_photo_entry.gd")
const SeekOverlay := preload("res://scripts/seek_overlay.gd")
const ImmersiveOverlay := preload("res://scripts/immersive_adjustment_overlay.gd")
const Providers := preload("res://scripts/provider_icons.gd")
const WatchPalette := preload("res://scripts/watch_palette.gd")
var checks := 0
var failures: Array[String] = []

class HeldMenu extends "res://scripts/ray_menu.gd":
	var held := false
	var draws := 0
	func has_pointer_capture() -> bool: return held
	func _draw() -> void:
		draws += 1
		_clear_layout(); _button(1, "Held", Vector2.ZERO, Vector2(0.3, 0.1))

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func frames(count: int = 3) -> void:
	for index in count: await process_frame

func luminance(color: Color) -> float:
	var linear := color.srgb_to_linear()
	return linear.r * 0.2126 + linear.g * 0.7152 + linear.b * 0.0722

func contrast(a: Color, b: Color) -> float:
	var first := luminance(a); var second := luminance(b)
	return (maxf(first, second) + 0.05) / (minf(first, second) + 0.05)

func snapshot(node: Node) -> Array:
	var result: Array = [node.get_class()]
	if node is Node3D: result.append(str(node.transform))
	if node is Label3D:
		result.append([node.text, node.font_size, node.pixel_size, node.outline_size, node.modulate, node.outline_modulate, node.render_priority])
	elif node is MeshInstance3D:
		if node.mesh is QuadMesh: result.append(node.mesh.size)
		var material = node.material_override
		if material is ShaderMaterial:
			result.append([material.shader.resource_path, material.render_priority, material.get_shader_parameter("surface_color"), material.get_shader_parameter("corner_radius")])
		elif material is StandardMaterial3D:
			result.append([material.albedo_color, material.render_priority, material.transparency, material.no_depth_test])
	for child in node.get_children():
		# The tooltip is on demand; pointer meshes retain their independent hand colors.
		if child.get_meta("menu_tooltip", false): continue
		result.append(snapshot(child))
	return result

func tap(menu: Node3D, target: int) -> void:
	var candidates: Array = menu._buttons.filter(func(button): return button.target == target)
	check(not candidates.is_empty(), "Ray target exists: %d" % target)
	if candidates.is_empty(): return
	var node: Node3D = candidates[0].node
	var origin := node.to_global(Vector3(0, 0, 0.4))
	var direction := -node.global_basis.z.normalized()
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)

func _run() -> void:
	Palette.use("default")
	check(Palette.OPTIONS.size() == 6 and Palette.SCHEMES.size() == 5, "Original plus five named schemes")
	check(Palette.color("panel") == Color(0.065, 0.075, 0.095, 0.98), "Original panel float values are unchanged")
	check(Palette.color("tile") == Color(0.105, 0.12, 0.15, 1.0), "Original button float values are unchanged")
	check(Palette.color("accent") == Color(0.54, 0.93, 0.77), "Original accent float values are unchanged")
	check(Palette.color("label") == Color.WHITE and Palette.color("knob") == Color.WHITE, "Original label and knob white unchanged")
	var covered: Array = []
	for family in Palette.FAMILIES:
		for role in Palette.FAMILIES[family]:
			check(not covered.has(role), "Role has one semantic family: " + role)
			covered.append(role)
	check(covered.size() == Palette.ORIGINAL.size(), "Every original role has an explicit palette or fixed-content policy")
	for option in Palette.OPTIONS:
		var colors := Palette.palette(option.value)
		check(colors.size() == Palette.ORIGINAL.size(), "Palette completeness: " + option.value)
		for role in colors:
			check(is_equal_approx(colors[role].a, Palette.ORIGINAL[role].a), option.value + " preserves alpha for " + role)
		if option.value == "default": continue
		for surface in ["panel", "tile", "selected", "hover", "web_input", "web_card", "tooltip"]:
			check(contrast(colors.text, colors[surface]) >= 4.5, option.value + " text contrast on " + surface)
		check(contrast(colors.muted, colors.panel) >= 4.5, option.value + " secondary text contrast")
		check(contrast(colors.primary_ink, colors.accent) >= 4.5 and contrast(colors.primary_ink, colors.primary_hover) >= 4.5, option.value + " primary text contrast")
		var rim: Color = colors.text if Palette.SCHEMES[option.value].light else colors.primary_ink
		check(colors.knob != colors.accent and contrast(colors.knob, rim) >= 3.0, option.value + " knob has distinct fill and contrasting outline")
		for surface in ["tile", "track", "accent", "primary_hover"]:
			check(maxf(contrast(colors.knob, colors[surface]), contrast(rim, colors[surface])) >= 3.0, option.value + " marker boundary visible on " + surface)
		for role in Palette.FAMILIES.fixed:
			check(colors[role] == Palette.ORIGINAL[role], option.value + " keeps content overlay semantics: " + role)
	for option in Palette.row("default").choices:
		var colors := Palette.palette(option.value)
		check(option.swatch == Color(colors.panel, 1.0) and option.swatch_accent == Color(colors.accent, 1.0), "Theme sample contains panel and accent: " + option.value)
	for invalid in [null, {}, [], 4, "", "../bad", "PEARL"]:
		check(Palette.normalize(invalid) == "default", "Invalid stored value falls back to original")
	for option in Palette.OPTIONS:
		Palette.use(option.value)
		check(Palette.light() == bool(Palette.SCHEMES.get(option.value, {}).get("light", false)), option.value + " uses scheme light metadata")
		var logo := Logo.new(0.16); logo.align_navigation(-0.13, -0.08)
		check(logo.material_override.albedo_color == Color.WHITE, option.value + " retains original colored brand mark")
		check(logo.get_node("Wordmark").material_override.albedo_color == (Palette.color("brand_ink") if Palette.light() else Color.WHITE), option.value + " brand wordmark uses readable ink")
		for icon in ["site_appletv", "site_niconico"]:
			var pale := Color("d7dde3")
			check(Palette.site_icon_color(icon, pale) == (Palette.color("text") if Palette.light() else pale), option.value + " monochrome site mark stays visible")
		for site in Sites.FEATURED:
			var ink := Palette.site_icon_color(site.icon, site.color)
			if Palette.light():
				for surface in ["web_card", "web_card_hover", "tile", "hover", "selected"]:
					check(contrast(ink, Palette.color(surface)) >= 3.0, option.value + " readable site glyph on " + surface + ": " + site.name)
				if site.icon not in ["site_appletv", "site_niconico"]:
					check(is_equal_approx(ink.h, site.color.h) and ink.a == site.color.a, option.value + " site hue/alpha retained: " + site.name)
					var original_min := INF; var adjusted_min := INF
					for surface in ["web_card", "web_card_hover", "tile", "hover", "selected"]:
						original_min = minf(original_min, contrast(site.color, Palette.color(surface)))
						adjusted_min = minf(adjusted_min, contrast(ink, Palette.color(surface)))
					check(ink == site.color if original_min >= 3.0 else adjusted_min < 3.01, option.value + " brand color receives only necessary darkening: " + site.name)
			else: check(ink == site.color, option.value + " original/dark site glyph unchanged: " + site.name)
		logo.free()
	Palette.use("default")
	var entry := PuzzleEntry.new(); root.add_child(entry); entry.toggle()
	var overlay := SeekOverlay.new()
	overlay.source = func(): return {"phase": "preview", "origin_ms": 1000, "target_ms": 2000, "duration_ms": 10000, "delta_ms": 1000, "alpha": 1.0}
	root.add_child(overlay); overlay.set_process(false)
	var gauge := ImmersiveOverlay.Gauge.new(); root.add_child(gauge); gauge.set_process(false)
	gauge.sample = {"span": Vector2(-100, 100), "value": 50, "title": "Horizontal", "key": "view_horizontal", "alpha": 1.0}
	for option in Palette.OPTIONS:
		Palette.use(option.value); await frames(); overlay.refresh(); gauge.refresh()
		for key in Providers.TEXTURES:
			var mark: MeshInstance3D = entry._icon(key, Vector3.ZERO, 0.05, Palette.color("provider_ink"))
			var ink: Color = mark.material_override.albedo_color
			if key in Providers.COLORED:
				check(ink == Color.WHITE, option.value + " retains existing multicolor provider artwork: " + key)
			elif Palette.light():
				check(not is_equal_approx(ink.r, ink.b) and contrast(ink, Palette.color("tile")) >= 3.0, option.value + " readable colored cloud mark: " + key)
			else:
				var original: Color = Palette.color("provider_ink")
				var gray := maxf(original.r, maxf(original.g, original.b))
				check(ink == Color(gray, gray, gray, original.a), option.value + " original/dark cloud mark unchanged: " + key)
			entry._decorations.erase(mark); mark.free()
		check(entry._decorations[0].material_override.albedo_color == Palette.color("text"), option.value + " puzzle entry uses readable foreground")
		for hud in [overlay, gauge]:
			check(hud._colors[0] == Palette.ORIGINAL.seek_panel and hud.clock.modulate == Palette.ORIGINAL.hud_text, option.value + " live playback HUD stays dark with light ink")
			check(hud.fill.material_override.albedo_color == Palette.ORIGINAL.accent, option.value + " live playback fill retains dark-HUD contrast")
			check(hud.thumb.material_override.albedo_color == (Palette.ORIGINAL.accent if option.value == "default" else Color.WHITE), option.value + " playback marker preserves classic and separates new-theme fill")
	entry.free(); overlay.free(); gauge.free(); Palette.use("default")

	var menu := States.Widgets.new(); root.add_child(menu); menu.toggle()
	menu.device_status.clock_provider = func(): return {"hour": 10, "minute": 8}
	menu.device_status.refresh(true)
	menu._hover = {"right_hand": 1}; menu._update_highlights()
	var original := snapshot(menu)
	var pose := menu.transform
	var repaints := [0]
	menu.composition_layout_changed.connect(func(): repaints[0] += 1)
	for option in Palette.OPTIONS:
		Palette.use(option.value); await frames()
		var first: Dictionary = menu._buttons.filter(func(button): return button.target == 1)[0]
		var disabled: Dictionary = menu._buttons.filter(func(button): return button.target == 3)[0]
		check(menu.transform == pose, option.value + " preserves menu placement")
		check(first.node.material_override.get_shader_parameter("surface_color") == Palette.color("hover"), option.value + " updates hovered plate")
		check(first.node.get_child(0).modulate == Palette.color("text"), option.value + " updates existing button caption")
		check(menu.device_status._label.modulate == Palette.color("label"), option.value + " updates persistent clock")
		check(menu.device_status._pill.material_override.get_shader_parameter("surface_color") == Color(Palette.color("panel"), 0.86), option.value + " updates persistent footer")
		check(disabled.node.material_override.get_shader_parameter("surface_color") == Palette.color("disabled"), option.value + " updates disabled plate")
		var primary_button: Dictionary = menu._buttons.filter(func(button): return button.target == 2)[0]
		primary_button.base_color = Palette.color("selected")
		menu._hover = {"right_hand": 2}; menu._update_highlights()
		check(primary_button.node.material_override.get_shader_parameter("surface_color") == Palette.color("hover"), option.value + " respects a caller replacing a primary surface")
		primary_button.base_color = Palette.color("accent")
		menu._hover = {"right_hand": 1}; menu._update_highlights()
	Palette.use("default"); await frames()
	check(snapshot(menu) == original, "Switching through all themes returns the complete widget tree to the original appearance")
	check(repaints[0] > 0, "Theme updates invalidate the compositor")
	menu._hover = {"right_hand": 6}; menu._update_highlights()
	menu._tooltip.free()
	Palette.use("jade"); await frames()
	check(is_instance_valid(menu._tooltip) and menu._tooltip.get_child(0).modulate == Palette.color("label"), "Theme safely replaces a tooltip whose former surface was already retired")

	menu.dismiss(); Palette.use("sand"); await frames()
	check(menu._theme_pending, "Hidden menus defer repaint")
	menu.toggle(); await frames()
	check(not menu._theme_pending and menu._backdrop.material_override.get_shader_parameter("surface_color") == Palette.color("panel"), "Reopening hidden menu uses current theme")
	var fresh := States.Widgets.new(); root.add_child(fresh); fresh.toggle()
	check(fresh._buttons[0].node.get_child(0).modulate == Palette.color("text"), "New windows inherit current theme")
	fresh.free(); menu.free()

	var held := HeldMenu.new(); root.add_child(held); held.toggle(); held.held = true
	var before := held.draws
	Palette.use("pearl"); await frames()
	check(held.draws == before and held._theme_pending, "Theme cannot rebuild a captured slider/control")
	held.held = false; await frames(5)
	check(held.draws == before + 1 and not held._theme_pending, "Capture release applies exactly one pending redraw")
	held.free()

	var disc := Disc.new(); root.add_child(disc); disc.sync(true)
	var capture := Capture.new(); root.add_child(capture); capture.sync({"recording": true, "duration_ms": 1234})
	Palette.use("ocean"); await frames()
	check(disc._buttons[0].node.get_child(1).material_override.albedo_color == Palette.color("text"), "Disc bar redraws despite custom sync lifecycle")
	check(capture._buttons[0].node.get_child(1).material_override.albedo_color == Palette.color("record"), "Recording overlay retains recording state while recoloring")
	disc.free(); capture.free()

	var platform := BrowserFixture.Platform.new()
	platform.browser.merge({"tab_id": 1, "loading": false, "start_page": false}, true)
	var web := Library.new(); root.add_child(web); web.attach_platform(platform); web.toggle()
	web._activate(Library.NAV_BASE + Library.Section.WEB)
	for option in Palette.OPTIONS:
		Palette.use(option.value); await frames()
		for page in 2:
			web.web_video.home.site_page = page; web.refresh()
			for card in web._buttons:
				var site_index: int = card.target - web.web_video.home.SITE_BASE
				if site_index < 0 or site_index >= Sites.FEATURED.size(): continue
				var site: Dictionary = Sites.FEATURED[site_index]
				var ink: Color = card.node.get_child(1).material_override.albedo_color
				check(ink == Palette.site_icon_color(site.icon, site.color), option.value + " home actually applies the corrected glyph: " + site.name)
				if Palette.light():
					check(contrast(ink, card.base_color) >= 3.0 and contrast(ink, card.get("hover_color", Palette.color("hover"))) >= 3.0, option.value + " production home glyph contrast: " + site.name)
	web.web_browser.open(); web.web_browser.tick()
	var host: Node3D = web.web_browser.windows[1]
	host.selecting = true; host.selection = Rect2(0.2, 0.2, 0.5, 0.5)
	host._selection_context = Vector2i(host.focus_tab(), int(web.web_browser.window_state(1).get("navigation", 0)))
	host._update_feedback()
	var feedback_id: int = host._feedback.get_instance_id()
	var web_pose := host.transform
	for option in Palette.OPTIONS:
		Palette.use(option.value); await frames(5)
		check(host._feedback.get_instance_id() == feedback_id, option.value + " browser retains its live feedback nodes")
		check(host._feedback.get_node("background").material_override.get_shader_parameter("surface_color") == Palette.color("browser_feedback"), option.value + " browser recolors persistent focus backing")
		check(host._feedback.get_node("selection0").material_override.get_shader_parameter("surface_color") == Palette.color("browser_rim"), option.value + " browser recolors persistent selection shade")
		check(host._feedback.get_node("selection4").material_override.get_shader_parameter("surface_color") == Palette.color("accent"), option.value + " browser recolors persistent selection border")
		check(host.selecting and host.selection == Rect2(0.2, 0.2, 0.5, 0.5) and host.transform == web_pose, option.value + " browser preserves selection and placement")
	web.free(); platform.free(); await frames()
	Palette.use("default")

	var path := ProjectSettings.globalize_path("res://../../build/output/ui-themes/settings.cfg")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var app := Main.new(); app.settings_path = path
	var library := Library.new(); library.settings_provider = func(): return {Palette.KEY: Palette.current}
	library.setting_changed.connect(app._on_setting_changed)
	root.add_child(library); library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB; library.refresh()
	library._set_scroll(0); library.refresh()
	check(library.rows[0].key == Palette.KEY and library.rows[1].key == "watch_color" and library.rows[2].setting[0] == "bar_transparency", "Theme and watch swatches lead Display before control bar transparency")
	var theme_targets := 0; var watch_targets := 0
	var target := -1
	for key in library.choices.targets:
		var item: Dictionary = library.choices.targets[key]
		if item.get("key") == Palette.KEY:
			theme_targets += 1
			check(item.kind == "choose", "Theme swatches select directly without opening a dropdown")
			for option in Palette.OPTIONS:
				if item.value == option.value:
					check(library._tips[key] == library.I18n.t(option.label), "Theme tooltip names its color: " + option.value)
					var colors := Palette.palette(option.value)
					check(contrast(Palette.swatch_ink(colors.panel), colors.panel) >= 4.5, "Selected theme check stays readable: " + option.value)
			if item.value == "jade": target = key
		elif item.get("key") == "watch_color":
			watch_targets += 1
			check(item.kind == "choose" and library._tips[key].contains(library.I18n.t(WatchPalette.USAGE)), "Watch color tooltip explains video hand-tracking left wrist use")
	check(theme_targets == 7 and watch_targets == 5 and target >= 0, "All built-in/custom/watch swatches are reachable at initial scroll position")
	check(library._tips.get(Library.ROW_BASE + 1) == library.I18n.t(WatchPalette.USAGE), "Watch title also explains its purpose on hover")
	if target >= 0:
		await tap(library, target)
	await frames()
	check(Palette.current == "jade", "Controller ray selects a theme")
	var restored := ConfigFile.new()
	check(restored.load(path) == OK and Palette.load_choice(restored) == "jade", "Theme persists through production settings handler")
	Palette.use("default"); Palette.use(Palette.load_choice(restored))
	check(Palette.current == "jade", "Startup restores saved theme")
	check(restored.get_sections() == PackedStringArray(["ui"]), "Theme persistence does not alter playback or subtitle settings")
	library.free(); app.free()
	Palette.use("default"); await frames()
	for failure in failures: push_error(failure)
	print("UI themes: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
