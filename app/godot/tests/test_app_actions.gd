extends SceneTree
const Actions := preload("res://scripts/app_actions.gd")
const Usage := preload("res://scripts/session_usage.gd")
const Palette := preload("res://scripts/ui_theme.gd")
const I18n := preload("res://scripts/i18n.gd")
const Library := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
var requests: Array[String] = []
var now := 10000

class FinishHost extends "res://scripts/main.gd":
	func _ready() -> void: pass
	func _save_playback_adjustments() -> void: pass
class Media extends Node3D:
	var closed := false
	func close_video() -> void: closed = true
	func close_image() -> void: closed = true
class Platform extends RefCounted:
	var calls: Array[bool] = []
	func finish_app(restart: bool) -> void: calls.append(restart)

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func ray(menu: Node3D, target: int) -> Array:
	var node: Node3D = button(menu, target).node
	return [node.global_position + menu.global_basis.z * 0.3, -menu.global_basis.z]
func press(menu: Node3D, target: int, hand: String = "right_hand") -> void:
	var input := ray(menu, target)
	check(menu.press_pointer(hand, input[0], input[1], true), "Production press consumes target %d" % target)
func release(menu: Node3D, hand: String = "right_hand") -> void:
	menu.release_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
func open(menu: Node3D) -> void:
	press(menu, Actions.STATUS); release(menu)
	check(menu.app_actions.expanded, "Click opens footer popup")

func mono_direction(menu: Node3D, eye: Vector3, hand: Vector3, point: Vector3) -> Vector3:
	var direction := (point - eye).normalized()
	var offset := eye - hand
	var along := offset.dot(direction)
	var distance := -along + sqrt(along * along + menu.ray_max_distance * menu.ray_max_distance - offset.length_squared())
	return (eye + direction * distance - hand).normalized()

func run() -> void:
	Usage.start(1000)
	Usage.suspend("focus", true, 61000)
	Usage.suspend("pause", true, 62000)
	Usage.suspend("focus", false, 63000)
	check(Usage.milliseconds(70000) == 60000, "Overlapping lifecycle suspensions never count background time")
	Usage.suspend("pause", false, 71000)
	check(Usage.milliseconds(131000) == 120000, "Foreground usage resumes once all suspension reasons clear")
	Usage.start()
	# The production exit path must preserve media when saving fails and call finish only once.
	var finish := FinishHost.new()
	finish.video = Media.new(); finish.photo = Media.new(); finish.platform_plugin = Platform.new()
	finish.settings_path = "res://../../build/output/app-actions/missing-%d/settings.cfg" % Time.get_ticks_usec()
	check(not finish._finish_app(false), "Save failure rejects exit")
	check(not finish.video.closed and not finish.photo.closed and not finish._finishing_app, "Failed save preserves the running media and allows retry")
	finish.settings_path = "res://../../build/output/app-actions/finish-settings.cfg"
	check(finish._finish_app(true), "Successful save permits restart")
	check(finish.video.closed and finish.photo.closed and finish.platform_plugin.calls == [true], "Restart saves and closes media before invoking the platform")
	finish._finish_app(false)
	check(finish.platform_plugin.calls == [true], "Production finish rejects repeated execution")
	finish.video.free(); finish.photo.free(); finish.free()
	I18n.use("zh")
	# Exercise the real menu subclasses and their trigger/release overrides.
	for script in ["library_menu", "player_menu", "photo_menu", "music_menu", "scenery_menu", "puzzle/puzzle_dock"]:
		print("Testing app actions in ", script)
		var menu: Node3D = load("res://scripts/" + script + ".gd").new()
		var auxiliary: Node
		if script == "music_menu":
			auxiliary = preload("res://scripts/background_audio.gd").new(); menu.audio = auxiliary
			auxiliary.add_child(auxiliary.importer)
		elif script == "scenery_menu":
			auxiliary = preload("res://scripts/background_library.gd").new(); menu.library = auxiliary
		root.add_child(menu); menu.toggle(); menu.set_process(false)
		var actions: Node = menu.app_actions
		actions.now_provider = func(): return now
		menu.app_action_requested.connect(func(operation): requests.append(operation))
		var anchor: Vector3 = menu.device_status.position
		var point: Vector3 = button(menu, Actions.STATUS).node.global_position
		var origin: Vector3 = point + menu.global_basis.z * 0.3
		menu.update_pointer("right_hand", origin, -menu.global_basis.z, true)
		now += 249; menu.update_pointer("right_hand", origin, -menu.global_basis.z, true)
		check(not actions.expanded, script + " ignores a brief sweep over the clock")
		now += 1; menu.update_pointer("right_hand", origin, -menu.global_basis.z, true)
		check(actions.expanded, script + " opens on deliberate hover")
		check(menu.device_status.position == anchor, "Opening never moves the status card")
		check(not menu.device_status._pill.material_override.get_shader_parameter("hovered"), "Clock card never draws a colored outline")
		check(button(menu, Actions.CANCEL).is_empty(), "Popup header has no cancel button")
		check(actions._caption.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT and actions._duration.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "Session label and duration align to opposite sides")
		for target in [Actions.RESTART, Actions.QUIT]:
			var face: MeshInstance3D = button(menu, target).node
			var icon: MeshInstance3D = face.get_child(1)
			check(icon.material_override.render_priority > face.material_override.render_priority, script + " draws action icons above their button backgrounds")
		# The tiny gap has its own hit blocker, so a downward ray never drops through.
		var gap: Vector3 = menu.to_global(Vector3(menu._footer_centre.x, menu._footer_centre.y - 0.050, 0.3))
		var gap_hit: Dictionary = menu.ray_hit(gap, -menu.global_basis.z)
		check(gap_hit.get("target") == Actions.CORRIDOR, "Gap belongs to the continuous hit corridor")
		now += 650; menu.update_pointer("right_hand", gap, -menu.global_basis.z, true)
		check(actions.expanded, "Moving down through the gap keeps the popup open")
		var before := requests.size()
		press(menu, Actions.QUIT)
		check(actions.armed == "quit_app" and requests.size() == before, "First exit press only arms")
		press(menu, Actions.QUIT)
		check(requests.size() == before, "Repeated press while held cannot confirm")
		release(menu)
		press(menu, Actions.QUIT)
		check(requests.size() == before + 1 and requests.back() == "quit_app", script + " confirms only after release and second press")
		release(menu); press(menu, Actions.QUIT)
		check(requests.size() == before + 1, "Executing state rejects duplicate submissions")
		actions.failed(); release(menu)
		check(actions.busy.is_empty() and actions.error, "Save failure restores usable controls with an error")
		press(menu, Actions.RESTART); release(menu)
		press(menu, Actions.STATUS); release(menu); open(menu)
		check(actions.armed.is_empty(), "Collapsing the status card clears restart confirmation")
		press(menu, Actions.RESTART); release(menu)
		press(menu, Actions.RESTART, "left_hand")
		check(requests.size() == before + 1, "Other hand cannot supply the confirming press")
		release(menu, "left_hand")
		press(menu, Actions.QUIT); release(menu)
		check(actions.armed == "quit_app", "Changing action requires a fresh confirmation")
		now += Actions.CONFIRM_MS; actions.tick(now)
		check(actions.armed.is_empty(), "Confirmation expires after five seconds")
		check(not actions.expanded, "Leaving closes the popup with hysteresis")
		open(menu)
		press(menu, Actions.RESTART); release(menu)
		menu.refresh()
		check(actions.armed.is_empty() and not actions.expanded, "Page redraw clears pending actions")
		open(menu); press(menu, Actions.QUIT); release(menu)
		menu.cancel_pointer("right_hand")
		check(actions.armed.is_empty(), "Pointer cancellation clears confirmation ownership")
		press(menu, Actions.QUIT)
		menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
		check(actions.armed.is_empty(), "Tracking loss cancels confirmation and releases a stuck trigger")
		# The same newly displayed controls must agree with zero-disparity ray projection.
		var eye := Node3D.new(); root.add_child(eye); eye.position = Vector3(0.1, 0.1, 0.2)
		menu.set_meta("menu_mono_pointer", {"eye": eye, "distance": menu.ray_max_distance})
		for hand in ["left_hand", "right_hand"]:
			var hand_origin := eye.position + Vector3(-0.25 if hand == "left_hand" else 0.25, -0.15, -0.10)
			for target in [Actions.STATUS, Actions.RESTART, Actions.QUIT]:
				var direction := mono_direction(menu, eye.position, hand_origin, button(menu, target).node.global_position)
				check(menu.ray_hit(hand_origin, direction).get("target") == target, script + " mono hover and trigger agree for " + hand)
		menu.remove_meta("menu_mono_pointer"); eye.free()
		press(menu, Actions.QUIT); release(menu)
		actions.notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
		check(actions.armed.is_empty() and not actions.expanded, "App focus loss clears pending confirmation immediately")
		menu.dismiss()
		check(not actions.expanded and actions.armed.is_empty(), "Dismiss clears the footer popup")
		menu.free()
		if auxiliary: auxiliary.free()
	# Legacy settings buttons use the same state and the actual library press path.
	var menu := Library.new(); root.add_child(menu); menu.toggle(); menu.set_process(false)
	menu.section = menu.Section.SETTINGS; menu.refresh()
	menu.app_actions.now_provider = func(): return now
	menu.app_action_requested.connect(func(operation): requests.append(operation))
	for target in [menu.RESTART_APP, menu.QUIT_APP]:
		var before := requests.size()
		press(menu, target); release(menu)
		check(requests.size() == before and not menu.app_actions.armed.is_empty(), "Legacy settings action arms before executing")
		check(button(menu, Actions.LEGACY_CANCEL).node.visible, "Legacy settings have an explicit cancel")
		press(menu, Actions.LEGACY_CANCEL)
		check(menu.app_actions.armed.is_empty(), "Legacy cancel restores action")
		press(menu, target); release(menu); press(menu, target)
		check(requests.size() == before + 1, "Legacy settings second press confirms once")
		menu.app_actions.failed(); release(menu)
	# Actual render widths in all supported languages and both light/dark palettes.
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for theme in ["default", "pearl"]:
			Palette.use(theme); menu.refresh(); menu.app_actions.now_provider = func(): return now
			menu.app_actions.reset(); open(menu)
			for target in [Actions.RESTART, Actions.QUIT]:
				press(menu, target); release(menu)
				var item := button(menu, target)
				var label: Label3D = item.node.get_child(0)
				var width := label.font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				check(width <= 0.138, language + "/" + theme + " confirmation fits the compact button")
				if target == Actions.QUIT:
					check(item.base_color == menu.TILE and item.hover_color == Palette.color("hover"), "Exit confirmation keeps a neutral surface at rest and on hover")
				press(menu, Actions.STATUS); release(menu); open(menu)
	menu.free(); Palette.use("default"); I18n.use("auto")
	await process_frame
	for failure in failures: push_error(failure)
	print("App actions: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
