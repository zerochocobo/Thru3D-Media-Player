extends Node
## Debug-only menu frame timing: scripted open/close, navigation, tabs, scrolling and ray
## hover, recorded per phase from the engine's frame deltas. Results go to the diagnostics
## directory as menu_bench_<label>.json; nothing is saved to user settings.
const Menu := preload("res://scripts/library_menu.gd")
const PHASE_SECONDS := 3.0
var main: Node
var label := ""
var phases: Array[Dictionary] = []
var _phase := -1
var _elapsed := 0.0
var _step := 0.0
var _deltas := PackedFloat32Array()
var _results: Array[Dictionary] = []
var _repaints := 0

func start(target_main: Node, run_label: String) -> void:
	main = target_main; label = run_label
	phases = [
		{"name": "idle_menu", "setup": "recent"},
		{"name": "head_motion_only", "setup": "recent"},
		{"name": "ray_hover_sweep", "setup": "recent"},
		{"name": "scroll_list", "setup": "local"},
		{"name": "switch_sections", "setup": "recent"},
		{"name": "switch_settings_tabs", "setup": "settings"},
		{"name": "open_close_menu", "setup": "recent"},
		{"name": "player_menu", "setup": "player"},
	]
	_next()

func _next() -> void:
	if _phase >= 0: _finish_phase()
	_phase += 1; _elapsed = 0.0; _step = 0.0; _deltas.clear()
	if _phase >= phases.size():
		_write(); queue_free(); return
	var menu: Node = main.recent_menu
	match str(phases[_phase].setup):
		"player": main._show_player_menu()
		_:
			main._show_recent_menu()
			var section: int = {"recent": Menu.Section.RECENT, "local": Menu.Section.LOCAL, "settings": Menu.Section.SETTINGS}[phases[_phase].setup]
			menu._activate(Menu.NAV_BASE + section)
	_repaints = main.menu_composition.repaints if main.menu_composition else 0

func _process(delta: float) -> void:
	if _phase < 0 or _phase >= phases.size(): return
	_elapsed += delta; _step += delta
	# The first half second settles the setup; only the remainder is measured.
	if _elapsed > 0.5: _deltas.append(delta)
	var menu: Node = main.recent_menu
	var t := _elapsed
	match str(phases[_phase].name):
		"head_motion_only":
			# Small origin sway moves the head relative to the menu, like natural head motion.
			main.xr_origin.position.x = sin(t * 3.0) * 0.03
		"ray_hover_sweep":
			var target: Vector3 = menu.to_global(Vector3(sin(t * 2.2) * 0.65, cos(t * 1.7) * 0.4, 0))
			var eye: Vector3 = main.xr_camera.global_position
			menu.update_pointer("right_hand", eye, target - eye, true)
		"scroll_list":
			menu.stick_scroll(1.0 if fmod(t, 2.0) < 1.0 else -1.0, delta)
		"switch_sections":
			if _step >= 0.35:
				_step = 0.0
				var order: Array = Menu.NAV_ORDER
				menu._activate(Menu.NAV_BASE + order[int(t / 0.35) % order.size()])
		"switch_settings_tabs":
			if _step >= 0.35:
				_step = 0.0
				var tabs := [Menu.VIDEO_TAB, Menu.SUBTITLES_TAB, Menu.DISPLAY_TAB, Menu.CONTROLS_TAB, Menu.GENERAL_TAB, Menu.BACKGROUND_TAB, Menu.ABOUT_TAB]
				menu._activate(Menu.TAB_BASE + tabs[int(t / 0.35) % tabs.size()])
		"open_close_menu":
			if _step >= 0.4:
				_step = 0.0
				if menu.visible: menu.dismiss()
				else: main._show_recent_menu()
	if _elapsed >= PHASE_SECONDS: _next()

func _finish_phase() -> void:
	main.xr_origin.position.x = 0.0
	main.recent_menu.cancel_pointer("right_hand")
	var sorted := _deltas.duplicate(); sorted.sort()
	var count := sorted.size()
	var total := 0.0
	for d in sorted: total += d
	var refresh := 72.0
	var xr := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr and xr.is_initialized() and xr.display_refresh_rate > 0.0: refresh = xr.display_refresh_rate
	var late := 0
	for d in sorted:
		if d > 1.5 / refresh: late += 1
	_results.append({"phase": phases[_phase].name, "frames": count,
		"fps": snappedf(count / total, 0.1) if total > 0.0 else 0.0,
		"p50_ms": snappedf(sorted[count / 2] * 1000.0, 0.01) if count else 0.0,
		"p95_ms": snappedf(sorted[mini(count - 1, int(count * 0.95))] * 1000.0, 0.01) if count else 0.0,
		"max_ms": snappedf(sorted[count - 1] * 1000.0, 0.01) if count else 0.0,
		"late_frames": late, "refresh": refresh,
		"repaints": (main.menu_composition.repaints - _repaints) if main.menu_composition else 0})

func _write() -> void:
	main.recent_menu.dismiss()
	var report := {"label": label, "menu_composition": main.menu_composition.snapshot() if main.menu_composition else {},
		"phases": _results, "unix_seconds": Time.get_unix_time_from_system()}
	var path := OS.get_user_data_dir().path_join("diagnostics/menu_bench_%s.json" % label)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report, "\t"))
	DiagnosticLog.record("menu_bench_done", {"label": label})
