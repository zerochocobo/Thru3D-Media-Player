extends SceneTree
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	var main := Main.new()
	var directory := ProjectSettings.globalize_path("res://../../build/output/focus-in-deferred")
	DirAccess.make_dir_recursive_absolute(directory)
	main.settings_path = directory.path_join("settings.cfg"); main.settings.save(main.settings_path)
	root.add_child(main); main.set_process(false)
	await process_frame
	# Godot sends FOCUS_IN from the render thread's queue before the EGL context is current again.
	main._background_app_paused = true
	main._notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	check(main._background_app_paused, "FOCUS_IN work waits for the next frame")
	await process_frame
	check(not main._background_app_paused, "Deferred FOCUS_IN work runs")
	check(not main._focus_in_deferred, "Deferred FOCUS_IN guard is cleared")
	main._background_app_paused = false
	main._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(main._background_app_paused, "FOCUS_OUT still runs at once")
	main.queue_free()
	print("test_focus_in_deferred checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: printerr(failure)
	quit(1 if failures.size() else 0)
