extends SceneTree
## Hand model setting: auto hides the hand meshes over passthrough; show/hide are absolute.
const Main := preload("res://scripts/main.gd")
const Library := preload("res://scripts/library_menu.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/hand-model-setting")

func _initialize() -> void: run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var main := Main.new(); main.settings_path = output.path_join("settings-%d.cfg" % Time.get_ticks_usec())
	main.display.applied_passthrough = false
	check(main._hand_models_visible(), "Auto shows hand models over a rendered background")
	main.display.applied_passthrough = true
	check(not main._hand_models_visible(), "Auto hides hand models over passthrough")
	main._on_setting_changed("hand_model", "show")
	check(main._hand_models_visible(), "On keeps hand models over passthrough")
	main.display.applied_passthrough = false
	main._on_setting_changed("hand_model", "hide")
	check(not main._hand_models_visible(), "Off hides hand models everywhere")
	var saved := ConfigFile.new()
	check(saved.load(main.settings_path) == OK and saved.get_value("ui", "hand_model", "") == "hide", "Choice persists to disk")
	main._on_setting_changed("hand_model", "bogus")
	check(str(main.settings.get_value("ui", "hand_model", "")) == "auto", "Unknown value falls back to auto")
	var library := Library.new(); root.add_child(library); library.set_process(false)
	library.settings_provider = func(): return {"hand_model": "hide"}
	library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB
	library.show(); library.refresh()
	var row: Dictionary = {}
	for item in library.rows:
		if item.get("key", "") == "hand_model": row = item
	check(not row.is_empty() and row.value == "hide" and row.choices.map(func(c): return c.value) == ["auto", "show", "hide"], "Display settings offer auto/on/off with the saved value")
	library.free(); main.free()
	for failure in failures: push_error(failure)
	print("Hand model setting: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
