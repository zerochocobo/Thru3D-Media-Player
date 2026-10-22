extends SceneTree
## The filename must remain painted on its translucent plate, including when native menu captures run.
const Menu := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/player-title")

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func layer_alpha(slot: Dictionary, image: Image, camera: Camera3D, pixel: Vector2) -> float:
	var normal: Vector3 = slot.layer.global_basis.z
	var plane := Plane(normal, normal.dot(slot.layer.global_position))
	var point = plane.intersects_ray(camera.project_ray_origin(pixel), camera.project_ray_normal(pixel))
	if point == null: return 0.0
	var uv: Vector2 = slot.camera.unproject_position(point) - Vector2(0.5, 0.5)
	if uv.x < 0 or uv.y < 0 or uv.x >= image.get_width()-1 or uv.y >= image.get_height()-1: return 0.0
	var p := Vector2i(uv.floor()); var fraction := uv - Vector2(p)
	return lerpf(lerpf(image.get_pixelv(p).a, image.get_pixelv(p+Vector2i(1, 0)).a, fraction.x),
		lerpf(image.get_pixelv(p+Vector2i(0, 1)).a, image.get_pixelv(p+Vector2i(1, 1)).a, fraction.x), fraction.y)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1800, 1100)
	viewport.own_world_3d = true; viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 65; camera.environment = Capture.clear_environment(); origin.add_child(camera)
	var video := MeshInstance3D.new(); video.mesh = QuadMesh.new(); video.mesh.size = Vector2(8, 8); video.position.z = -3
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	video.material_override = material; viewport.add_child(video)
	var menu := Menu.new(); viewport.add_child(menu); menu.set_process(false)
	menu.state_provider = func(): return {"has_video": true, "title": "远山来信 · Movie_180_SBS_2160p.mp4", "playing": true, "position_ms": 25000, "duration_ms": 60000}
	menu.visible = true; menu.refresh()
	var capture := Capture.new(); viewport.add_child(capture)
	capture.configure(origin, camera, Display.new(), [menu], false, true); capture.set_process(false)
	var metrics: Array = []
	for angle in [0.0, 0.18]:
		menu.rotation.y = angle
		for transparency in [0, 55, 80]:
			menu.set_bar_transparency(transparency)
			for background in ["clear", "red", "blue"]:
				video.visible = background != "clear"
				material.albedo_color = Color(0.9, 0.1, 0.1) if background == "red" else Color(0.1, 0.2, 0.9)
				capture.set_active(false); await frames()
				var reference := viewport.get_texture().get_image()
				var title: Label3D = menu._title; var box := title.get_aabb()
				var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
				for x in [box.position.x, box.end.x]:
					for y in [box.position.y, box.end.y]:
						var pixel := camera.unproject_position(title.to_global(Vector3(x, y, 0)))
						lo = lo.min(pixel); hi = hi.max(pixel)
				var area := Rect2i(Vector2i(lo.floor()), Vector2i((hi - lo).ceil()))
				capture.set_active(true); capture.set_process(false); capture.update(); await frames(); capture.update(); await frames()
				var actual := viewport.get_texture().get_image()
				var layers: Array = capture.slots.filter(func(slot): return slot.used and not slot.empty)
				check(layers.any(func(slot): return slot.nodes.has(title)), "Filename uses the HD menu layer: %s/%d" % [background, transparency])
				var plate: MeshInstance3D = title.get_meta("filename_plate")
				check(layers.any(func(slot): return slot.nodes.has(title) and slot.nodes.has(plate)), "Filename and backing share one capture")
				var images: Array = layers.map(func(slot): return slot.raw.get_texture().get_image())
				var changed := 0; var worst := 0.0; var ink := 0
				for y in range(area.position.y, area.end.y):
					for x in range(area.position.x, area.end.x):
						var a := actual.get_pixel(x, y); var r := reference.get_pixel(x, y)
						# Simulate the native underlays below projection, including both coverage stages.
						var underlay := 0.0
						for index in layers.size():
							var coverage := layer_alpha(layers[index], images[index], camera, Vector2(x+0.5, y+0.5))
							underlay = coverage + underlay * (1.0-coverage)
						var composed_alpha := a.a + underlay * (1.0-a.a)
						var difference := absf(composed_alpha-r.a)
						worst = maxf(worst, difference)
						if difference > 0.03: changed += 1
						if r.r > 0.35 and r.g > 0.35 and r.b > 0.35: ink += 1
				var name := "%s-%d-%.2f" % [background, transparency, angle]
				check(ink > 30, "Reference contains readable filename strokes: " + name)
				check(changed == 0, "Composed filename cannot leak extra background through its strokes: " + name)
				metrics.append({"case": name, "changed_pixels": changed, "worst_delta": worst})
				if transparency == 55 and angle == 0:
					reference.save_png(output.path_join(name + "-reference.png"))
					actual.save_png(output.path_join(name + "-projection.png"))
					for slot in layers:
						if slot.nodes.has(title): slot.raw.get_texture().get_image().save_png(output.path_join(name + "-hd.png"))
	check(capture.slots.any(func(slot): return slot.used), "Other player controls retain native menu captures")
	var old_text := menu._title.text
	menu.refresh_values()
	check(menu._title.text == old_text, "Value updates preserve filename fitting and backing bounds")
	menu.visible = false
	var photo := Photo.new(); viewport.add_child(photo); photo.set_process(false)
	photo.state_provider = func(): return {"has_image": true, "title": "照片 · Panorama_180_SBS.jpg"}
	photo.visible = true; photo.refresh(); capture.register_menu(photo); capture.update(); await frames(); capture.update(); await frames()
	check(capture.slots.any(func(slot): return slot.used and slot.nodes.has(photo._title) and slot.nodes.has(photo._title.get_meta("filename_plate"))), "Photo filename and backing retain the same HD path")
	capture.shutdown("test_complete"); capture.free(); menu.free(); photo.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "cases": metrics, "scope": "Host projection and production menu capture; headset verification pending"}, "\t"))
	for failure in failures: printerr(failure)
	print("Player title: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
