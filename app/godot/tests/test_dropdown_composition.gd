extends SceneTree
## Real ray interactions, with host capture only; no headset, media or saved settings.
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const I18n := preload("res://scripts/i18n.gd")
# Keep the original raised-list reproducer even though the production render-scale
# row is now inline. This exercises the shared capture fix independently of that UI change.
class RaisedChoiceLibrary extends Library:
	func _rebuild_rows() -> void:
		super()
		for row in rows:
			if row.get("key", "") == "display_quality": row.compact = false
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func slot_for(capture: Node, node: Node) -> Dictionary:
	for slot in capture.slots:
		if slot.used and slot.nodes.has(node): return slot
	return {}

func verify(capture: Node, library: Node3D, tag: String, fixed_sizes: Array) -> void:
	capture.update()
	var items: Array[Dictionary] = []
	capture._gather(capture.active, items, capture._root_pose().affine_inverse(), false)
	var missed: Array[String] = []
	for item in items:
		if not item.shown: continue
		var slot := slot_for(capture, item.node)
		if slot.is_empty() or item.node.layers & capture.eye_camera.cull_mask != 0:
			missed.append(item.node.text if item.node is Label3D else str(item.node.get_class()))
	check(missed.is_empty(), tag + " captures ALL visible library, side column, transport, dropdown and tooltip content: " + str(missed))
	var dense := true
	for slot in capture.slots:
		if not slot.used or slot.empty: continue
		dense = dense and float(slot.raw.size.x) / slot.layer.quad_size.x >= Capture.DENSITY * capture._scale() * 0.9
		check(slot.camera.cull_mask > 0 and slot.camera.cull_mask < (1 << 20), tag + " uses a supported camera render bit")
	check(dense, tag + " retains capture density on every visible plane")
	check(capture.slots.map(func(slot): return slot.raw.size) == fixed_sizes and capture.layer_reservation() == 5,
		tag + " preserves existing swapchain sizes and five-provider budget")
	var options: Array = library._buttons.filter(func(button):
		var item: Dictionary = library.choices.targets.get(button.target, {})
		return item.get("kind", "") == "choose" and item.get("key", "") == "display_quality")
	check(options.size() == 4, tag + " has all render scale choices")

func render_captures(capture: Node, folder: String = "captures") -> void:
	# Optional actual OpenGL texture check; headless CI still checks the full interaction matrix.
	for frame in 3:
		await process_frame; await RenderingServer.frame_post_draw; capture.update()
	var output := ProjectSettings.globalize_path("res://../../build/output/dropdown-blur/" + folder)
	DirAccess.make_dir_recursive_absolute(output)
	for slot in capture.slots:
		if not slot.used or slot.empty: continue
		var pixels: Image = slot.raw.get_texture().get_image()
		check(pixels.save_png(output.path_join("plane-%d.png" % slot.index)) == OK, "Save simultaneous HD plane " + str(slot.index))
		var ink := 0
		for y in range(0,pixels.get_height(),3):
			for x in range(0,pixels.get_width(),3):
				var color := pixels.get_pixel(x,y)
				if color.a > 0.5 and color.r > 0.7 and color.g > 0.7 and color.b > 0.7: ink += 1
		check(ink > 20, "Actual HD texture contains text/icons on plane %d: %d samples" % [slot.index,ink])

func fixture(attached: bool, low: bool, language: String, dropdown: bool = true) -> void:
	I18n.use(language)
	var world := Node3D.new(); root.add_child(world)
	var camera := Camera3D.new(); world.add_child(camera)
	var player := Player.new(); world.add_child(player); player.set_process(false)
	player.state_provider = func(): return {"has_video":true,"playing":true,"playback_state":"playing",
		"source_uri":"file:///probe.mp4","duration_ms":600000,"position_ms":50000,"geometry":0,"volume":80,"audio_available":true}
	player.position = Vector3(0,-0.45,-1.4)
	player.set_layout_viewer(Transform3D.IDENTITY, false); player.visible = attached; player.refresh()
	var library: Node3D = RaisedChoiceLibrary.new() if dropdown else Library.new()
	if attached: player.add_child(library)
	else: world.add_child(library); library.position.z = -1.4
	library.set_process(false); library.visible = true; library.playback_expanded = attached
	player.expanded_library = library
	library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB; library.refresh()
	var capture := Capture.new(); world.add_child(capture)
	capture.configure(world, camera, null, [library,player], low, true); capture.set_process(false)
	var fixed_sizes: Array = capture.slots.map(func(slot): return slot.raw.size)
	var tag := "%s/attached=%s/low=%s" % [language, attached, low]
	if not dropdown:
		var settings := {"display_quality": -1}
		var events := []
		library.settings_provider = func(): return settings
		library.setting_changed.connect(func(key, value): settings[key] = value; events.append([key,value]))
		library.refresh()
		check(not library.choices.targets.values().any(func(item): return item.get("key", "") == "display_quality" and item.kind == "open"),tag+" render scale has no dropdown")
		for value in [-1,0,1,2]:
			var options: Array = library._buttons.filter(func(button):
				var item: Dictionary = library.choices.targets.get(button.target,{})
				return item.get("key", "") == "display_quality" and item.get("value", -99) == value)
			check(options.size() == 1,tag+" exposes inline scale "+str(value))
			if options.is_empty(): continue
			var button: Dictionary = options[0]
			var caption: String = I18n.t("Auto" if value == -1 else library.Quality.NAMES[value])
			check(button.node.get_child(0).text == caption,tag+" keeps the complete inline label "+caption)
			var p: Vector3 = button.node.global_position + button.node.global_basis.z * 0.3
			var d: Vector3 = -button.node.global_basis.z
			var before := events.size()
			library.press_pointer("right_hand",p,d,true)
			check(events.size() == before,tag+" inline selection waits for release")
			library.release_pointer("left_hand",p,d,true)
			check(events.size() == before,tag+" other hand cannot commit inline selection")
			library.release_pointer("right_hand",p,d,true)
			check(events.size() == before+1 and events.back() == ["display_quality",value],tag+" inline ray selects requested value")
			verify(capture,library,tag+" inline="+str(value),fixed_sizes)
			check(library.choices.opened.is_empty(),tag+" inline selection never opens a popup")
		if attached and language in ["zh","en","zh_Hant","ja"] and OS.get_cmdline_user_args().has("--render"):
			await render_captures(capture,"inline-"+language)
		capture.queue_free(); await process_frame
		world.queue_free(); await process_frame
		return
	for cycle in 2:
		for button in library._buttons:
			var item: Dictionary = library.choices.targets.get(button.target,{})
			if item.get("kind", "") != "open" or item.get("key", "") != "display_quality": continue
			var p: Vector3 = button.node.global_position + button.node.global_basis.z * 0.3
			var d: Vector3 = -button.node.global_basis.z
			library.press_pointer("right_hand",p,d,true); library.release_pointer("right_hand",p,d,true)
			break
		library.update_pointer("right_hand",Vector3.ZERO,Vector3.FORWARD,false)
		await process_frame
		verify(capture,library,tag+" opened",fixed_sizes)
		for button in library._buttons:
			var item: Dictionary = library.choices.targets.get(button.target,{})
			if item.get("kind", "") != "choose" or item.get("key", "") != "display_quality": continue
			library.update_pointer("right_hand",button.node.global_position + button.node.global_basis.z * 0.3,-button.node.global_basis.z,true)
			check(library._tooltip != null and library._tooltip.visible, tag+" actual ray shows the choice hint")
			verify(capture,library,tag+" hover="+str(item.value),fixed_sizes)
			check(capture.snapshot().layers == (5 if attached else 4), tag+" all simultaneous surfaces are HD")
		if cycle == 0 and attached and not low and language == "zh" and OS.get_cmdline_user_args().has("--render"):
			await render_captures(capture)
		library.update_pointer("right_hand",Vector3.ZERO,Vector3.FORWARD,false)
		verify(capture,library,tag+" hint hidden",fixed_sizes)
		check(capture.snapshot().layers == (4 if attached else 3), tag+" hidden hint parks without retaining its old picture")
		library.choices.reset(); library.refresh(); capture.update()
		check(capture.snapshot().layers == (3 if attached else 2), tag+" closed dropdown releases its visible plane")
	# Verify bits do not collide with the optional diagnostic bands or world content.
	check((Capture.GROUP_MASK & Capture.BAND_MASK) == 0 and (Capture.GROUP_MASK & 1) == 0, tag+" capture masks do not overlap bands or scene")
	capture.shutdown("test_complete")
	check(camera.cull_mask == 1048575, tag+" shutdown restores camera visibility")
	capture.queue_free(); await process_frame
	world.queue_free(); await process_frame

func run() -> void:
	for language in ["zh", "en", "zh_Hant", "ja"]:
		for low in [false, true]:
			for attached in [false, true]: await fixture(attached,low,language)
		for attached in [false,true]: await fixture(attached,false,language,false)
	for failure in failures: push_error(failure)
	print("Dropdown composition: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
