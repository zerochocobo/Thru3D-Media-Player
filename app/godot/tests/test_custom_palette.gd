extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const Generator := preload("res://scripts/custom_palette.gd")
const Sites := preload("res://scripts/web_video_sites.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	Palette.use(Palette.DEFAULT); Palette.set_custom({})
	check(Palette.palette(Palette.CUSTOM) == Palette.ORIGINAL, "Unconfigured custom palette exactly retains original float values and alpha")
	Palette.use(Palette.CUSTOM)
	check(Palette.original() and not Palette.light() and Palette.playback_color("knob") == Palette.ORIGINAL.accent, "Unconfigured custom keeps classic marker semantics")
	for bad in [null, "#123456", [], {"background": "garbage", "accent": "ffffff"}, {"background": Color(NAN, 0, 0), "accent": Color.WHITE}, {"background": Color.WHITE, "accent": Color.RED, "text": 4}]:
		check(Generator.normalize(bad).is_empty(), "Invalid saved color data fails closed to original")
	check(Generator.normalize({"background": Color(-1, 2, 0, 0), "accent": "#ff0088"}).background == Color(0, 1, 0), "Saved RGB clamps and alpha is kept out of user palette data")
	var backgrounds: Array[Color] = [Color.BLACK, Color.WHITE, Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW, Color.CYAN, Color.MAGENTA]
	for index in 33: backgrounds.append(Color(float(index) / 32, float(index) / 32, float(index) / 32))
	var random := RandomNumberGenerator.new(); random.seed = 604113
	for index in 64: backgrounds.append(Color(random.randf(), random.randf(), random.randf()))
	for background in backgrounds:
		for seed in [background, Color("828282"), Color("79e2b3"), Color("bd30fa")]:
			for ink in ["auto", background]:
				var data := {"background": background, "accent": seed, "text": ink}
				var colors := Palette.custom_palette(data)
				check(Color(colors.panel, 1) == background, "Background seed is retained")
				for role in Palette.ORIGINAL:
					check(colors.has(role) and colors[role].a == Palette.ORIGINAL[role].a and is_finite(colors[role].r) and is_finite(colors[role].g) and is_finite(colors[role].b), "Custom role complete/finite and original alpha retained: " + role)
				for role in ["panel", "tile", "hover", "selected", "web_card", "web_card_hover", "web_input", "tooltip", "danger_surface"]:
					check(Generator.contrast(colors.text, colors[role]) >= 4.5, "Custom body text contrast: " + role)
				for role in ["panel", "tile", "hover", "selected"]:
					check(Generator.contrast(colors.muted, colors[role]) >= 4.5, "Custom secondary text contrast: " + role)
					check(Generator.contrast(colors.accent, colors[role]) >= 4.5, "Custom accent labels distinguish control states: " + role)
				check(Generator.contrast(colors.primary_ink, colors.accent) >= 4.5 and Generator.contrast(colors.primary_ink, colors.primary_hover) >= 4.5, "Custom primary button text contrast in both states")
				for role in Palette.FAMILIES.fixed: check(colors[role] == Palette.ORIGINAL[role], "Custom preserves playback HUD/content shade: " + role)
	# Saved custom edits can change while the selected ID stays custom.
	var before := Palette.revision
	Palette.set_custom({"background": Color("f0f4f6"), "accent": Color("397fbf"), "text": "auto"})
	check(Palette.current == Palette.CUSTOM and Palette.light() and Palette.revision == before + 1, "Updating active custom data invalidates live UI without changing ID")
	check(Color(Palette.color("panel"), 1) == Color("f0f4f6"), "Active custom palette actually changes")
	for suggestion in Generator.accents(Color("efefef")):
		var scheme := Generator.make({"background": Color("efefef"), "accent": suggestion, "text": "auto"})
		check(Generator.minimum(suggestion, [scheme.panel, scheme.tile, scheme.hover, scheme.selected]) >= 4.5, "Suggested accent remains readable after it generates its own selection surface")
	for background in backgrounds:
		Palette.set_custom({"background": background, "accent": Color("000001"), "text": "auto"})
		for site in Sites.FEATURED:
			var ink := Palette.site_icon_color(site.icon, site.color)
			for role in ["web_card", "web_card_hover", "tile", "hover", "selected"]:
				check(Generator.contrast(ink, Palette.color(role)) >= 3.0, "Custom site glyph remains readable on arbitrary backgrounds: " + site.name)
			check(ink.a == site.color.a, "Custom site glyph retains source alpha")
		for role in ["track", "accent", "tile"]:
			check(maxf(Generator.contrast(Color.WHITE, Palette.color(role)), Generator.contrast(Palette.slider_outline(), Palette.color(role))) >= 3.0, "Custom white slider marker or its rim remains visible: " + role)
	Palette.use(Palette.DEFAULT); Palette.set_custom({})
	for failure in failures: push_error(failure)
	print("Custom palette: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
