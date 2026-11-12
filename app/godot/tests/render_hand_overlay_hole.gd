extends SceneTree
## Desktop renderer only. A cinema/beach overlay menu hole ignores depth so scene geometry cannot
## hide the menu; the eye buffer must still stay solid (alpha 1) where a hand model is in front.
const Visuals := preload("res://scripts/input_visuals.gd")
const OVERLAY_HOLE := preload("res://shaders/menu_layer_hole_overlay.gdshader")
const OLD_HAND := "shader_type spatial; render_mode unshaded; void fragment(){ ALBEDO=vec3(0.7); }"
var output := ProjectSettings.globalize_path("res://../../build/output/hand-overlay-hole")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func box(parent: Node, x: float, z: float, material: Material) -> void:
	var mesh := MeshInstance3D.new(); mesh.mesh = BoxMesh.new(); mesh.mesh.size = Vector3.ONE * 0.2
	mesh.position = Vector3(x, 0, z); mesh.material_override = material; parent.add_child(mesh)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1280, 800); view.own_world_3d = true
	view.transparent_bg = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var environment := Environment.new(); environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.2, 0.25, 0.3, 1.0)
	var world := WorldEnvironment.new(); world.environment = environment; view.add_child(world)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 1.5
	camera.near = 0.01; view.add_child(camera)
	# A fully covered overlay menu hole over the whole view, at the menu's distance.
	var coverage := Image.create(4, 4, false, Image.FORMAT_RGBA8); coverage.fill(Color.WHITE)
	var hole := ShaderMaterial.new(); hole.shader = OVERLAY_HOLE; hole.render_priority = 9
	hole.set_shader_parameter("menu_texture", ImageTexture.create_from_image(coverage))
	var plane := MeshInstance3D.new(); plane.mesh = QuadMesh.new(); plane.mesh.size = Vector2(4, 4)
	plane.position.z = -1.0; plane.material_override = hole; view.add_child(plane)
	var visuals := Visuals.new(); visuals.use_runtime_models = false; view.add_child(visuals)
	var old := ShaderMaterial.new(); old.shader = Shader.new(); old.shader.code = OLD_HAND
	var seat := StandardMaterial3D.new(); seat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box(view, -0.6, -0.5, visuals._material)  # current hand material
	box(view, 0.6, -0.5, old)                 # pre-fix opaque hand material
	box(view, 0.0, -0.7, seat)                # opaque scene geometry in front of the menu
	for i in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	image.save_png(output.path_join("overlay-hole.png"))
	var at := func(x: float) -> float: return image.get_pixel(int(640 + x / 1.2 * 640), 400).a
	check(at.call(-0.6) > 0.99, "Hand model stays solid in front of an overlay menu hole")
	check(at.call(0.6) < 0.01, "Control: the old opaque hand material is cut out by the hole")
	check(at.call(0.0) < 0.01, "Scene geometry still cannot hide an overlay menu")
	check(at.call(-1.0) < 0.01, "Hole clears the eye buffer where nothing is in front")
	view.free()
	for failure in failures: push_error(failure)
	print("Hand overlay hole render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
