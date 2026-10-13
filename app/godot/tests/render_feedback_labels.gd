extends SceneTree
const Menu := preload("res://scripts/ray_menu.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func run() -> void:
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 800); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 1.2
	viewport.add_child(camera)
	var menu := Menu.new(); viewport.add_child(menu); menu.visible = true
	var title := "【sivr307-01】みなみ羽琉_LR_180"
	menu._label(title, Vector3(0, 0.23, 0.01), 26)
	var labels: Array[Label3D] = []
	for i in 2: labels.append(menu._label("【" if i == 0 else "】", Vector3(-0.15 + i * 0.3, -0.1, 0.01), 48))
	for frame in 3: await process_frame; await RenderingServer.frame_post_draw
	var pixels := viewport.get_texture().get_image()
	for label in labels:
		var centre := Vector2i(camera.unproject_position(label.global_position))
		var lit := 0
		for y in range(centre.y - 45, centre.y + 45):
			for x in range(centre.x - 30, centre.x + 30):
				if pixels.get_pixel(x, y).r > 0.6: lit += 1
		check(lit > 60, "Bracket has visible ink: " + label.text)
	check(menu.text_snapshot().contains(title), "Shared file-title renderer preserves both literal brackets")
	var output := ProjectSettings.globalize_path("res://../../build/output/user-feedback-fixes")
	DirAccess.make_dir_recursive_absolute(output); pixels.save_png(output.path_join("bracket-labels.png"))
	print("Filename bracket rendering checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	viewport.queue_free(); await process_frame
	quit(0 if failures.is_empty() else 1)
