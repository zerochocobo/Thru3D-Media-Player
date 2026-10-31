extends SceneTree
## Video 3D strength rescale (100% = the former 50%): saved values keep their parallax, once;
## and the player bar's video 2D-to-3D view choice.
const DepthStrength := preload("res://scripts/depth_strength.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok: failures.append(what)

func _initialize() -> void:
	var saved := ConfigFile.new()
	saved.set_value("video", "depth_strength", 0.23)
	saved.set_value("photo", "depth_strength", 1.5)
	check(DepthStrength.migrate_video_scale(saved), "Old-scale video strength is migrated")
	check(is_equal_approx(float(saved.get_value("video", "depth_strength")), 0.46), "Old 23% becomes new 46% (same parallax)")
	check(is_equal_approx(float(saved.get_value("photo", "depth_strength")), 1.5), "Photo strength is untouched")
	check(not DepthStrength.migrate_video_scale(saved) and is_equal_approx(float(saved.get_value("video", "depth_strength")), 0.46),
		"Migration runs only once")
	var strong := ConfigFile.new()
	strong.set_value("video", "depth_strength", 0.8)
	DepthStrength.migrate_video_scale(strong)
	check(is_equal_approx(float(strong.get_value("video", "depth_strength")), 1.0), "Old values above 50% stop at the new 100%")
	var fresh := ConfigFile.new()
	check(DepthStrength.migrate_video_scale(fresh) and not fresh.has_section_key("video", "depth_strength")
		and is_equal_approx(DepthStrength.load_preference(fresh, false), 0.5), "A new install starts at the new 50%")
	var boosted := ConfigFile.new()
	boosted.set_value("video", "depth_strength_scale", 2)
	boosted.set_value("video", "depth_strength", 1.8)
	boosted.set_value("photo", "depth_strength", 1.5)
	check(not DepthStrength.migrate_video_scale(boosted) and is_equal_approx(DepthStrength.load_preference(boosted, false), 1.8), "Boosted video strength survives restart without another migration")
	check(is_equal_approx(DepthStrength.load_preference(boosted, true), 1.5), "Photo preference remains independent of video boost")
	boosted.set_value("video", "depth_strength", 3.0)
	check(DepthStrength.load_preference(boosted, false) == 2.0, "Video preference clamps at 200%")
	# The player bar's Settings page offers the same global video choice, edge stretching by default.
	var menu: Node = load("res://scripts/player_menu.gd").new()
	menu._state = {"has_video": true}
	var choice: Dictionary = menu._setting_choices("depth_render")
	check("depth_render" in menu.OPERATIONS[1] and choice.get("key", "") == "depth_render" and choice.get("value", "") == "stretch"
		and choice.choices.map(func(o): return o.value) == ["fill", "stretch"], "Player settings offer the video 2D-to-3D view")
	menu._state = {"has_video": false}
	check(menu._setting_choices("depth_render").is_empty(), "Without a video the choice is not offered")
	menu.free()
	print("Depth strength scale checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
