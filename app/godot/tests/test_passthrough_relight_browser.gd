# Originally contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
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

func _covers(mesh: Mesh, point: Vector3) -> bool:
	var faces := mesh.get_faces()
	for index in range(0, faces.size(), 3):
		if Geometry3D.ray_intersects_triangle(point + Vector3(0, 0, 1), Vector3(0, 0, -1), faces[index], faces[index + 1], faces[index + 2]) != null: return true
	return false

func _script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script

func _initialize() -> void:
	var page_script := _script("extends Node\nvar hole: MeshInstance3D\nvar layer: RefCounted = RefCounted.new()\nvar pixels := Vector2i(1536, 864)\n")
	var window_script := _script("extends Node\nvar surface: Node\nvar pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.2))\n" +
		"var size := Vector2(0.6, 0.9)\nfunc page_layout() -> Dictionary: return {\"pose\": pose, \"size\": size}\n" +
		"func focus_crop() -> Rect2: return Rect2(0.2, 0.1, 0.3, 0.8)\nvar depth: RefCounted\nvar selecting := false\n")
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
		var expected := Vector2(0.6, 0.9) + Vector2.ONE * Model.halo_margin(relight.reach) * 2.0 * 0.9
		check(relight.glow_size.is_equal_approx(expected), "The halo wraps the drawn (tall) page size", relight.glow_size)
		check(glow.mesh.get_aabb().size.x < expected.x + 0.001 and not _covers(glow.mesh, Vector3.ZERO), "The halo leaves the page itself uncovered")
		check(is_equal_approx(0.5 / float(relight._glow_material.get_shader_parameter("half_width")), 1.5),
			"The halo rectangle keeps the page aspect")
	check(relight.scale.r > relight.scale.g * 1.5, "A red page tints the room red", relight.scale)
	check(relight._floor != null and relight._floor.visible, "The floor shadow is shown under the window")
	check(relight._edge != null and not relight._edge.visible, "A page keeps a hard edge")
	# A video keeps its hard edge too, unless the viewer asks for the dissolve.
	var video_frame := {"transform": Transform3D.IDENTITY, "size": Vector2(1.6, 0.9), "flat": true, "glow_z": Runtime.VIDEO_GLOW_Z, "edge_priority": Runtime.VIDEO_EDGE_PRIORITY}
	relight._place(video_frame, 0.0)
	check(not relight._edge.visible and is_zero_approx(float(relight._glow_material.get_shader_parameter("band"))), "A video's picture keeps a hard edge by default")
	relight.soft_edge = true
	relight._place(video_frame, 0.0)
	check(relight._edge.visible and is_equal_approx(float(relight._glow_material.get_shader_parameter("band")), Model.EDGE_BAND), "The soft edge option dissolves a video's border into the halo")
	# A cut-out person (Alpha, or a page's person matte) has no rectangle to glow around.
	relight.soft_edge = true
	relight._place(video_frame.merged({"cutout": true}), 0.0)
	check(not relight._glow.visible and not relight._edge.visible and not relight._floor.visible, "A cut-out person gets no halo, edge or floor shadow")
	relight.soft_edge = false
	relight._place(video_frame, 0.0)
	check(relight._glow.visible, "The halo returns with the whole picture")
	window.depth = _script("extends RefCounted\nvar matte := true\n").new()
	relight.update_browser(1.0 / 30.0, window, true, 0.0)
	check(not relight._glow.visible and not relight._floor.visible, "A page cut to its person gets no halo")
	window.selecting = true
	relight.update_browser(1.0 / 30.0, window, true, 0.0)
	check(relight._glow.visible, "Choosing a region shows the whole page, halo included")
	window.selecting = false
	window.depth = null
	relight.update_browser(1.0 / 30.0, window, true, 0.0)
	# The two controls: a short reach needs a much smaller quad, and low brightness tints less.
	check(Model.halo_margin(0.0) < Model.halo_margin(1.0) * 0.5, "A tight halo covers far less than a wide one")
	check(Model.halo_strength(0.0) < Model.halo_strength(1.0), "Brightness scales the halo")
	check(Model.room_tint(Color(0.2, 0.2, 0.2), 0.0).r > Model.room_tint(Color(0.2, 0.2, 0.2), 1.0).r, "Low brightness leaves the room lighter")
	var wide: Vector2 = relight.glow_size
	relight.set_look(0.0, 0.2)
	relight.update_browser(1.0 / 30.0, window, true, 0.0)
	check(relight.glow_size.x < wide.x, "A shorter reach shrinks the halo")
	check(is_equal_approx(glow.mesh.get_aabb().size.x, relight.glow_size.x) and _covers(glow.mesh, Vector3(relight.glow_size.x * 0.49, 0, 0)),
		"The halo mesh reaches its outer edge", glow.mesh.get_aabb().size)
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

	# Headset samples are analysed on a worker; the result matches the direct path.
	var light: Dictionary = await relight._analyse(image)
	check(light.get("average") == Runtime._light(image).average and light.get("bar", PackedVector3Array()).size() == Model.BAR_SIZE,
		"The worker analysis returns the same light", light.get("average"))
	check((await relight._analyse(null)).is_empty(), "No picture, no light")

	if failures.is_empty(): print("Passthrough relight browser checks passed: %d" % checks)
	else:
		for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
