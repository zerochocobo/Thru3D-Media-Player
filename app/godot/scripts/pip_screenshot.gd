extends RefCounted
## Immutable spatial recipe only. No texture readback, render target, or per-frame work.
const Subtitles := preload("res://scripts/projected_subtitles.gd")

static func vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

static func eyes(video: Node3D) -> Array[Vector3]:
	var camera: Camera3D = video.view_camera
	if not camera: return [video.panel.global_position, video.panel.global_position]
	var xr := XRServer.primary_interface
	if xr and xr.is_initialized() and xr.get_view_count() == 2:
		var origin: Transform3D = camera.get_parent().global_transform
		return [xr.get_transform_for_view(0, origin).origin, xr.get_transform_for_view(1, origin).origin]
	var offset := camera.global_basis.x * Subtitles.runtime_ipd() * XRServer.world_scale * 0.5
	return [camera.global_position - offset, camera.global_position + offset]

static func snapshot(video: Node3D) -> Dictionary:
	var result: Array = []
	if video.pip.windows.is_empty(): return {"version": 1, "windows": result}
	var positions := eyes(video)
	for slot in video.pip._stack:
		var window: Node3D = video.pip.windows[slot]
		if not window.visible or not window.frame.visible: continue
		var image: Dictionary = window.capture_image.duplicate(true) if window.image_mode else {}
		if window.image_mode and image.is_empty(): return {} # Never silently omit a visible image.
		var inverse: Transform3D = window.global_transform.affine_inverse()
		var basis: Basis = inverse.basis * video.panel.global_basis.scaled(Vector3.ONE * video.SPHERE_RADIUS)
		var selected: Variant = window.picture.get_shader_parameter("pip_viewing_eye")
		var eye := maxi(1, int(selected) if selected != null else 1) - 1
		if video.swap_eyes: eye = 1 - eye
		if not video.stereo_sbs: eye = 0
		var crop: Basis = window.crop_basis
		var forward: Vector3 = window.picture.get_shader_parameter("pip_forward") if window.picture.get_shader_parameter("pip_forward") != null else -crop.z
		var right: Vector3 = window.picture.get_shader_parameter("pip_right") if window.picture.get_shader_parameter("pip_right") != null else crop.x
		var up: Vector3 = window.picture.get_shader_parameter("pip_up") if window.picture.get_shader_parameter("pip_up") != null else crop.y
		var tangent: Vector2 = window.tangent()
		var feather: Vector2 = window.edge_feather()
		result.append({"axes": vector(basis.x) + vector(basis.y) + vector(basis.z),
			"anchor": vector(inverse * video.panel.global_position),
			"left": vector(inverse * positions[0]), "right": vector(inverse * positions[1]),
			"size": [window.size.x, window.size.y], "feather": [feather.x, feather.y],
			"crop": vector(forward) + vector(right) + vector(up),
			"tangent": [tangent.x, tangent.y], "source_eye": eye, "image": image})
	return {"version": 1, "windows": result}
