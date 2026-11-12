extends SceneTree
## A screen that shows several source texels per eye pixel (beach, cinema hall) must average them,
## not alias one-texel stripes into bands; a 1:1 screen must keep its single sharp tap.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func stripes(width: int) -> ImageTexture:
	var image := Image.create(width, 16, false, Image.FORMAT_RGB8)
	for x in width:
		for y in 16: image.set_pixel(x, y, Color.WHITE if x % 2 == 0 else Color.BLACK)
	return ImageTexture.create_from_image(image)

func row(viewport: SubViewport) -> PackedFloat32Array:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var values := PackedFloat32Array()
	for x in range(4, 60): values.append(image.get_pixel(x, 32).r)
	return values

func spread(values: PackedFloat32Array) -> float:
	var low := 1.0
	var high := 0.0
	for value in values:
		low = minf(low, value); high = maxf(high, value)
	return high - low

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 2
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2, 2)
	viewport.add_child(quad)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	quad.material_override = material
	var mask := Image.create(4, 2, false, Image.FORMAT_R8)
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("alpha_enabled", false)
	# Odd ratios keep pixel centres off texel boundaries, where even an unfiltered tap reads gray.
	for width in [109, 163, 237, 339, 505]:
		material.set_shader_parameter("color_texture", stripes(width))
		material.set_shader_parameter("source_size", Vector2(width, 16))
		var minified := spread(await row(viewport))
		if minified > 0.15: failures.append("%.1f:1 stripes still alias, spread %.3f" % [width / 64.0, minified])
	# At or below one texel per pixel the single sharp tap stays.
	for width in [64, 31]:
		material.set_shader_parameter("color_texture", stripes(width))
		material.set_shader_parameter("source_size", Vector2(width, 16))
		var sharp := spread(await row(viewport))
		if sharp < 0.8: failures.append("%.1f:1 stripes lost contrast, spread %.3f" % [width / 64.0, sharp])
	for failure in failures: push_error(failure)
	print("Video minify desktop pixels: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
