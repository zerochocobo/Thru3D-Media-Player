extends SceneTree
## Monochrome film next to plain zero saturation on colour pictures, through the eye buffers' shader
## (native/xr-layer/picture_glsl.h draws the same arithmetic). QUEST_PLAYER_MENU_PREVIEW_DIR receives
## compare_<picture>.png: original, zero saturation, then the three styles, each with low grain.
const Grade := preload("res://scripts/color_grade.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const PICTURES := ["res://backgrounds/previews/magic_cottage.jpg", "res://backgrounds/previews/belfast.jpg", "res://backgrounds/previews/cinema.jpg"]

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("QUEST_PLAYER_MENU_PREVIEW_DIR")
	if output.is_empty():
		push_error("Set QUEST_PLAYER_MENU_PREVIEW_DIR")
		quit(1)
		return
	for path in PICTURES:
		var picture: Image = (load(path) as Texture2D).get_image()
		picture.convert(Image.FORMAT_RGB8)
		var size := picture.get_size()
		var viewport := SubViewport.new()
		viewport.size = size
		viewport.own_world_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 1.0
		camera.keep_aspect = Camera3D.KEEP_HEIGHT
		camera.position.z = 1
		viewport.add_child(camera)
		var quad := MeshInstance3D.new()
		quad.mesh = QuadMesh.new()
		quad.mesh.size = Vector2(float(size.x) / size.y, 1.0)
		viewport.add_child(quad)
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/video_rvm_pair.gdshader")
		quad.material_override = material
		material.set_shader_parameter("color_texture", ImageTexture.create_from_image(picture))
		var mask := Image.create(4, 2, false, Image.FORMAT_R8)
		mask.fill(Color(1, 0, 0))
		material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(mask))
		material.set_shader_parameter("model_size", Vector2(size))
		material.set_shader_parameter("source_size", Vector2(size))
		material.set_shader_parameter("alpha_enabled", false)
		var panels: Array[Image] = []
		var grade := Grade.new()
		grade.apply(material)
		panels.append(await _shot(viewport))
		grade.adjust("saturation", 0.0)
		grade.apply(material)
		panels.append(await _shot(viewport))
		grade = Grade.new()
		for style in Video.MONO_STYLES:
			var grain: Vector2 = Video.MONO_GRAIN[1]
			grade.mono = PackedFloat32Array([1.0] + style + [grain.x, grain.y])
			grade.apply(material)
			panels.append(await _shot(viewport))
		var sheet := Image.create(size.x * 3, size.y * 2, false, Image.FORMAT_RGB8)
		sheet.fill(Color.BLACK)
		for index in panels.size():
			sheet.blit_rect(panels[index], Rect2i(Vector2i.ZERO, size), Vector2i((index % 3) * size.x, (index / 3) * size.y))
		sheet.save_png(output.path_join("compare_%s.png" % path.get_file().get_basename()))
		viewport.queue_free()
	quit(0)

func _shot(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	return image
