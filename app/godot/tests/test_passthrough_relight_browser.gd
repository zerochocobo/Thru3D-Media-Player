extends SceneTree
## Browser windows drive passthrough relighting like a video: the halo wraps the shown page
## (the focus-selected region when focused) behind the window frame, and everything fades out
## when the page is no longer presented.

const Runtime := preload("res://scripts/passthrough_relight.gd")
const Model := preload("res://scripts/passthrough_relight_model.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

func _script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script

func _initialize() -> void:
	var page_script := _script("extends Node\nvar hole: MeshInstance3D\nvar layer: RefCounted = RefCounted.new()\nvar pixels := Vector2i(1536, 864)\n")
	var window_script := _script("extends Node\nvar surface: Node\nvar pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.2))\n" +
		"var size := Vector2(0.6, 0.9)\nfunc page_layout() -> Dictionary: return {\"pose\": pose, \"size\": size}\n" +
		"func focus_crop() -> Rect2: return Rect2(0.2, 0.1, 0.3, 0.8)\n")
	var page: Node = page_script.new()
	page.hole = MeshInstance3D.new()
	page.hole.visible = true
	page.add_child(page.hole)
	var window: Node = window_script.new()
	window.surface = page
	window.add_child(page)
	root.add_child(window)
	var relight: Node = Runtime.new()
	root.add_child(relight)
	await process_frame # the tree starts after _initialize; global transforms need it
	relight.set_enabled(true)

	# A red page frame arrives (on a headset this comes from PixelCopy of the page surface).
	relight.update_browser(0.0, window, true, 0.0)
	var image := Image.create(Model.SAMPLE_SIZE.x, Model.SAMPLE_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 0.1, 0.1))
	relight._accept(image, "browser")
	for frame in 30: relight.update_browser(1.0 / 30.0, window, true, 0.0)
	var glow: MeshInstance3D = relight._glow
	check(glow != null and glow.visible, "The page has a halo")
	if glow:
		check(glow.global_position.is_equal_approx(Vector3(0, 1.4, -1.2 + Runtime.BROWSER_GLOW_Z)), "The halo sits behind the window frame", glow.global_position)
		var unit: float = 0.9 / Runtime.UNIT_SCREEN_HEIGHT
		var expected := Vector2(0.6, 0.9) + Vector2.ONE * Runtime.GLOW_MARGIN_UNITS * 2.0 * unit
		check((glow.mesh as QuadMesh).size.is_equal_approx(expected), "The halo wraps the drawn (tall) page size", (glow.mesh as QuadMesh).size)
		check(is_equal_approx(float(relight._glow_material.get_shader_parameter("half_height")) / float(relight._glow_material.get_shader_parameter("half_width")), 1.5),
			"The halo rectangle keeps the page aspect")
	check(relight.scale.r > relight.scale.g * 1.5, "A red page tints the room red", relight.scale)
	check(relight._floor != null and relight._floor.visible, "The floor shadow is shown under the window")
	check(relight.snapshot().path == "browser", "The sample came from the browser", relight.snapshot())

	# The page stops being presented (window hidden, surface switching): the effect fades out.
	page.hole.visible = false
	for frame in 30: relight.update_browser(1.0 / 30.0, window, true, 0.0)
	check(not glow.visible, "The halo fades out when the page is not shown")
	check(relight.scale.r > relight.scale.g, "The room returns to white gradually, not at once", relight.scale)
	for frame in 600: relight.update_browser(1.0 / 30.0, window, true, 0.0)
	check(relight.scale.is_equal_approx(Color.WHITE) or relight.scale.g > 0.99, "The room returns to white", relight.scale)

	# Switching back to a video source does not crash and leaves nothing behind.
	relight.update(1.0 / 30.0, null, false, 0.0)
	check(not glow.visible, "No video, no halo")

	if failures.is_empty(): print("Passthrough relight browser checks passed: %d" % checks)
	else:
		for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
