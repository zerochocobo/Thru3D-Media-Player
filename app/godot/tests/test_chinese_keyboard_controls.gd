extends SceneTree
const Chinese := preload("res://scripts/chinese_input.gd")
const Editor := preload("res://scripts/system_text_input.gd")
const I18n := preload("res://scripts/i18n.gd")
const Capture := preload("res://scripts/menu_composition.gd")
class HookOwner extends Node:
	func head() -> Transform3D: return Transform3D.IDENTITY
	func opened() -> void: pass
class InputMain extends "res://scripts/main.gd":
	var aim: Variant = null
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _notification(_what: int) -> void: pass
	func _controller_allowed(_hand: String) -> bool: return true
	func _ray(_hand: String) -> Variant: return aim
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func point(main: Node, target: int) -> void:
	var button: Dictionary = Chinese.popup._buttons.filter(func(item): return item.target == target)[0]
	main.aim = [button.node.global_position + Chinese.popup.global_basis.z, -Chinese.popup.global_basis.z]
func run() -> void:
	Chinese.quest = true; I18n.use("zh"); Chinese.configure(true)
	Chinese.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	Chinese.Keyboard.Pinyin.load_lexicon()
	var main := InputMain.new(); root.add_child(main)
	var host := Node3D.new(); root.add_child(host); host.position.z = -1.5
	var camera := Camera3D.new(); host.add_child(camera)
	var capture := Capture.new(); host.add_child(capture)
	capture.configure(host, camera, null, [], false, true); capture.set_process(false)
	capture.register_companion(Chinese.ensure(host))
	capture.update()
	check(capture.menus.has(Chinese.popup) and capture.slots.all(func(slot): return not slot.used), "Closed keyboard registers without allocating an active capture")
	var editor := Editor.new(host)
	editor.begin("cloud_search", "电影字幕", 128, Callable(), Callable()); await process_frame
	capture.update()
	check(capture.active == Chinese.popup, "Open keyboard becomes the compositor root")
	check(Chinese.popup._buttons.all(func(button): return capture.slots.any(func(slot): return slot.used and slot.nodes.has(button.node))), "Every visible key belongs to a captured keyboard plane")
	check(capture.layer_reservation() == 5, "Keyboard reuses the five existing composition providers")
	check(main._active_menu() == Chinese.popup, "Popup owns the actual main input router")
	check(not Chinese.popup._buttons.any(func(item): return item.target < 0), "Keyboard has no scene or follow controls")
	check(Chinese.popup.global_basis.get_scale().is_equal_approx(Vector3.ONE * 0.5), "Keyboard width and height are half their original size")
	check((Chinese.popup._backdrop.mesh.size * 0.5).is_equal_approx(Vector2(0.64, 0.45)), "Compact panel includes the system input button in its 64 by 45 cm footprint")
	point(main, Chinese.Keyboard.MOVE)
	var initial: Transform3D = Chinese.popup.global_transform
	main._on_controller_button("trigger_click", "right_hand")
	check(Chinese.popup.has_pointer_capture(), "Header trigger begins keyboard movement")
	point(main, 4); main._on_controller_button("trigger_click", "left_hand")
	main._on_controller_release("trigger_click", "left_hand")
	check(Chinese.popup.has_pointer_capture() and editor.editor.text == "电影字幕", "Other hand cannot type or steal an active header drag")
	point(main, Chinese.Keyboard.MOVE); main.aim[0] += Vector3(0.18, -0.07, 0)
	main._update_menu_pointer("right_hand")
	check(not Chinese.popup.global_transform.is_equal_approx(initial), "Actual main pointer update moves the keyboard")
	check(Chinese.popup.global_basis.get_scale().is_equal_approx(Vector3.ONE * 0.5), "Dragging preserves the compact physical size")
	capture.update()
	var plane: Dictionary = capture.slots.filter(func(slot): return slot.used and slot.nodes.has(Chinese.popup._backdrop))[0]
	var header: Vector3 = plane.layer.global_transform.affine_inverse() * Chinese.popup._buttons[0].node.global_position
	check(absf(header.x) < plane.layer.quad_size.x * 0.5 and absf(header.y) < plane.layer.quad_size.y * 0.5, "Captured keyboard plane follows the scaled drag pose")
	main._on_controller_release("trigger_click", "right_hand")
	check(not Chinese.popup.has_pointer_capture() and editor.editor.text == "电影字幕", "Drag release stops movement without typing")
	var moved: Transform3D = Chinese.popup.global_transform
	editor.begin("cloud_search", "电影字幕", 128, Callable(), Callable()); await process_frame
	check(Chinese.popup.global_transform.is_equal_approx(moved), "Changing input session retains the user keyboard placement")
	point(main, Chinese.Keyboard.MOVE); main._on_controller_button("trigger_click", "right_hand")
	main._cancel_pointer("right_hand")
	check(not Chinese.popup.has_pointer_capture(), "Tracking cancellation ends header drag")
	main._on_controller_release("trigger_click", "right_hand")
	point(main, Chinese.Keyboard.MOVE); main._on_controller_button("trigger_click", "right_hand")
	main.aim = null; main._update_menu_pointer("right_hand")
	check(not Chinese.popup.has_pointer_capture(), "Invalid ray ends header drag without moving the panel")
	main._on_controller_release("trigger_click", "right_hand")
	point(main, 4)
	main._on_controller_button("trigger_click", "right_hand")
	check(editor.editor.text == "电影字" and Chinese.popup.has_pointer_capture(), "Actual controller press starts backspace capture")
	main._on_controller_release("trigger_click", "right_hand")
	check(not Chinese.popup.has_pointer_capture(), "Consumed controller release stops repeat")
	main._on_controller_button("trigger_click", "right_hand")
	main._cancel_pointer("right_hand")
	check(not Chinese.popup.has_pointer_capture(), "Tracking loss stops repeat")
	main._on_controller_release("trigger_click", "right_hand")
	main.aim = null
	main._process_stick_input(Vector2.UP, Vector2.RIGHT, 0.1)
	check(main.stick_controls.left_latched and main.stick_controls.right_latched, "Keyboard blocks playback sticks until recentered")
	main._on_controller_button("ax_button", "right_hand")
	check(Chinese.active(), "Other playback shortcuts cannot dismiss or activate media")
	main._on_controller_release("ax_button", "right_hand")
	main._on_pointer_button("menu_button", "right_hand")
	check(not Chinese.active() and not editor.active(), "Menu button closes only the keyboard")
	capture.update()
	check(capture.slots.all(func(slot): return not slot.used), "Closing the keyboard retires its captured planes")
	check(main.stick_controls.poll(Vector2.UP, Vector2.RIGHT).is_empty(), "Held sticks remain blocked after keyboard closes")
	for target in [2, 4, 6, 9, 10, 11, 12, 13]:
		var button: Dictionary = Chinese.popup._buttons.filter(func(item): return item.target == target)[0]
		var glyphs: Array = button.node.get_children().filter(func(node): return node is MeshInstance3D)
		check(glyphs.size() == 1 and is_equal_approx(glyphs[0].mesh.size.x, Chinese.Keyboard.KEY_ICON_SIZE), "Function key uses the same vector size: %d" % target)
	check(Chinese.popup.find_children("*", "Label3D", true, false).all(func(label): return label.font_size == Chinese.Keyboard.KEY_FONT_SIZE * Chinese.popup.TEXT_RASTER_SCALE), "Latin, Hanzi and preedit share one font size")
	var old_owner := HookOwner.new(); var new_owner := HookOwner.new()
	Chinese.head_provider=new_owner.head; Chinese.on_open=new_owner.opened
	Chinese.popup.head_provider=old_owner.head
	Chinese.release_host(old_owner)
	check(Chinese.head_provider==new_owner.head and Chinese.on_open==new_owner.opened,"Disposing an older host preserves the newer host's static hooks")
	check(not Chinese.popup.head_provider.is_valid(),"Popup releases its old host's head callback")
	Chinese.popup.head_provider=new_owner.head
	Chinese.release_host(new_owner)
	check(not Chinese.head_provider.is_valid() and not Chinese.on_open.is_valid() and not Chinese.popup.head_provider.is_valid(),"Disposing the current host clears all owned callbacks")
	old_owner.free(); new_owner.free()
	Chinese.configure(false); Chinese.popup.free()
	check(capture.menus.is_empty(), "Freeing the keyboard unregisters its composition callbacks")
	host.queue_free(); main.queue_free(); await process_frame
	print("Chinese keyboard controls checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
