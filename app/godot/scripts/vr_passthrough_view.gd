extends RefCounted
## A session-only, paused single-eye preview. Never changes the source projection or saved view.
signal failed
signal exit_ready
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const Capture := preload("res://scripts/video_mode_transition.gd")
const RADIUS := 0.36
const UNAVAILABLE := "Temporary passthrough unavailable"
static var _globe_shaders := {}
static var _fade_shaders := {}
const DISTANCE := 2.0
const ROLL_SECONDS := 0.24
var video: Node3D
var stage := ""
var source_uri := ""
var source_session := 0
var was_playing := false
var panel_layers := 1
var request := 0
var snapshot_request := 0
var snapshot_size := Vector2i.ZERO
var deadline := 0
var preview: MeshInstance3D
var material: ShaderMaterial
var binding := Binding.new()
var image: ImageTexture
var crop_basis := Basis.IDENTITY
var preview_pose := Transform3D.IDENTITY
var window_visibility := {}
var motion := ""
var motion_elapsed := 0.0
var motion_from := 0.0
var exit_opacity := 1.0
var roll := 1.0
var skip_open_animation := false
var release_surface: MeshInstance3D
var release_material: ShaderMaterial

func _init(owner: Node3D) -> void: video = owner
func active() -> bool: return not stage.is_empty()
func held() -> bool: return stage == "held"

func available() -> bool:
	return not active() and video.geometry != Geometry.Geometry.FLAT and video.has_active_presentation() \
		and video.panel != null and video.panel.visible and not video._binding.ticket.is_empty() \
		and not video.alpha_wanted() and not video.alpha_enabled and not video._waiting_first \
		and video._pending_revision.is_empty() and not video.mode_transition.active() \
		and video.captures.recording.is_empty()

func begin(head: Transform3D) -> bool:
	if not available(): return false
	var pair: Dictionary = video._binding.ticket
	var method := "request_mpv_layer_snapshot" if video._binding.layer else "freeze_mpv_pair"
	if not Methods.supports(video.platform, method): return false
	source_uri = video.local_uri; source_session = video.media.session_id
	skip_open_animation = false
	was_playing = video.requested_play
	panel_layers = video.panel.layers
	# Preserve the actual direction at the centre of the current view, including zoom/offset.
	var local_head: Vector3 = video.panel.to_local(head.origin)
	var forward: Vector3 = video.panel.global_basis.inverse() * -head.basis.z
	forward = forward.normalized()
	var b := local_head.dot(forward)
	var discriminant: float = b * b - local_head.length_squared() + video.SPHERE_RADIUS * video.SPHERE_RADIUS
	var direction := (local_head + forward * (-b + sqrt(maxf(0, discriminant)))).normalized()
	var up: Vector3 = video.panel.global_basis.inverse() * head.basis.y
	crop_basis = Basis.looking_at(direction, up)
	preview_pose = head * Transform3D(Basis.IDENTITY, Vector3(0, 0.12, -DISTANCE))
	material = video.material.duplicate()
	material.next_pass = null
	preview = MeshInstance3D.new()
	preview.name = "PausedVrPreview"
	preview.mesh = globe_mesh(video._stream_mesh if video._stream_mesh_active() else null, crop_basis)
	var extent := Vector3(3.2, 1.9, 1.0) * RADIUS
	preview.custom_aabb = AABB(-extent, extent * 2.0)
	preview.material_override = material
	preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	preview.visible = false
	video.add_child(preview)
	preview.global_transform = preview_pose
	stage = "capturing"
	window_visibility.clear()
	for window in video.pip.windows.values():
		window_visibility[window] = window.visible
		window.visible = false
	deadline = Time.get_ticks_msec() + Capture.CAPTURE_TIMEOUT_MS
	video.pause_playback()
	video.narration.apply()
	if video._binding.layer:
		var rotation := int(pair.get("surface_rotation_degrees", 0))
		var coded := Vector2i(int(pair.width), int(pair.height))
		if rotation % 180 != 0: coded = Vector2i(coded.y, coded.x)
		snapshot_size = Capture.snapshot_size(coded)
		Binding._use_shader(material, Binding.PAIR_SHADER)
		material.set_shader_parameter("rotation_degrees", rotation)
		snapshot_request = video.platform.request_mpv_layer_snapshot(source_session, snapshot_size.x, snapshot_size.y)
		if snapshot_request <= 0: finish(true); return false
	else:
		video._freeze_sequence += 1
		request = video._freeze_sequence
		if not video.platform.freeze_mpv_pair(source_session, int(pair.slot_token), request):
			finish(true); return false
	# Expose reality immediately; copying the paused frame must not delay passthrough.
	video._update_layer()
	return true

static func globe_mesh(source: Mesh = null, orientation := Basis.IDENTITY) -> Mesh:
	if source:
		# SV3D carries authored UVs and separate eye topologies. Keep them intact while
		# wrapping its directions onto the outside of the same small sphere.
		var result := ArrayMesh.new()
		for surface in source.get_surface_count():
			var arrays := source.surface_get_arrays(surface).duplicate(true)
			var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in points.size():
				var point := orientation.inverse() * points[i].normalized()
				points[i] = Vector3(point.x, point.y, -point.z) * RADIUS
			arrays[Mesh.ARRAY_VERTEX] = points
			arrays[Mesh.ARRAY_NORMAL] = null; arrays[Mesh.ARRAY_TANGENT] = null
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if indices.is_empty(): indices = PackedInt32Array(range(points.size()))
			for i in range(0, indices.size(), 3):
				var a := points[indices[i]]; var b := points[indices[i+1]]; var c := points[indices[i+2]]
				# Godot front faces wind clockwise. Stream meshes previously drew both sides.
				if (b-a).cross(c-a).dot(a+b+c) > 0.0:
					var next := indices[i+1]; indices[i+1] = indices[i+2]; indices[i+2] = next
			arrays[Mesh.ARRAY_INDEX] = indices
			result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		return result
	var mesh := SphereMesh.new()
	mesh.radius = RADIUS; mesh.height = RADIUS * 2.0
	mesh.radial_segments = 96; mesh.rings = 48
	return mesh

## Reuse the source shader's projection, eye packing, colour and lens mapping. The
## outside front (+Z) must show the original inside front (-Z), without mirroring X.
## Keep this variant private: normal video/PiP and the native atlas ABI are unchanged.
static func globe_shader(source: Shader) -> Shader:
	var key := source.get_instance_id()
	if not _globe_shaders.has(key):
		var shader := Shader.new()
		shader.code = fade_shader(source).code.replace("cull_disabled", "cull_back").replace("depth_draw_never", "depth_draw_opaque") \
			.replace("void vertex() {", "uniform float temporary_roll = 1.0;\nvoid vertex() {") \
			.replace("media_direction = VERTEX;", "media_direction = pip_right * VERTEX.x + pip_up * VERTEX.y + pip_forward * VERTEX.z;\n\tVERTEX *= mix(vec3(3.2, 1.9, 0.24), vec3(1.0), temporary_roll);") \
			.replace("outside_lens(sample_direction) ?", "(outside_lens(sample_direction) || (!projection_mesh && video_geometry == 1 && sample_direction.z > 0.0)) ?")
		_globe_shaders[key] = shader
	return _globe_shaders[key]

static func fade_shader(source: Shader) -> Shader:
	var key := source.get_instance_id()
	if not _fade_shaders.has(key):
		var shader := Shader.new()
		var code := source.code.replace("void fragment() {", "uniform float temporary_opacity = 1.0;\nvoid fragment() {")
		shader.code = code.insert(code.rfind("}"), "\n\tALPHA *= temporary_opacity;\n")
		_fade_shaders[key] = shader
	return _fade_shaders[key]

func frozen(id: int, report: Dictionary) -> bool:
	if request <= 0 or int(report.get("request_id", 0)) != request: return false
	request = 0
	var pair: Dictionary = report.get("pair", {})
	if stage != "capturing" or id != source_session or video.local_uri != source_uri \
		or report.get("state") != "ready" or int(pair.get("frozen_frame_id", 0)) <= 0:
		_release(pair); _fail(); return true
	if not binding.bind(material, pair):
		_release(pair); _fail(); return true
	_show()
	return true

func poll(delta: float = 0.0) -> void:
	if not active(): return
	if source_uri != video.local_uri: finish(false); return
	if source_session != video.media.session_id and video.media.accepts(video.media.session_id) and not video._waiting_first and video.media.frame_counter > 0:
		if motion == "closing": exit_ready.emit(); return
		# An internal GL recovery keeps the modal pause, but its old native frame is invalid.
		var saved_play := was_playing
		var saved_pose := preview_pose
		var saved_crop := crop_basis
		finish(false)
		if not begin(video.view_camera.global_transform):
			failed.emit(); return
		was_playing = saved_play; preview_pose = saved_pose; crop_basis = saved_crop
		skip_open_animation = true
		preview.mesh = globe_mesh(video._stream_mesh if video._stream_mesh_active() else null, crop_basis)
		preview.global_transform = preview_pose
	if stage == "capturing" and snapshot_request > 0:
		var state: String = video.platform.get_mpv_layer_thumbnail_state(snapshot_request)
		if state == "ready":
			var pixels: PackedByteArray = video.platform.take_mpv_layer_thumbnail(snapshot_request)
			snapshot_request = 0
			if pixels.size() != snapshot_size.x * snapshot_size.y * 4: _fail(); return
			image = ImageTexture.create_from_image(Image.create_from_data(snapshot_size.x, snapshot_size.y, false, Image.FORMAT_RGBA8, pixels))
			material.set_shader_parameter("color_texture", image)
			material.set_shader_parameter("source_size", Vector2(snapshot_size))
			_show()
		elif state != "pending": _fail(); return
	if stage == "capturing" and Time.get_ticks_msec() >= deadline: _fail(); return
	if held():
		hide_source()
		animate(delta)

func context_lost() -> void:
	# CPU snapshot textures can be recreated by Godot. Native frozen GL names cannot.
	if active() and image == null:
		if preview: preview.visible = false
		if release_surface: release_surface.visible = false

func _show() -> void:
	# Both surfaces borrow the same paused frame; only the exit briefly draws a panorama.
	release_material = material.duplicate()
	Binding._use_shader(release_material, fade_shader(material.shader))
	_bind_color(release_material)
	release_material.set_shader_parameter("separate_subtitles", true)
	release_material.set_shader_parameter("temporary_opacity", 0.0)
	Binding._use_shader(material, globe_shader(material.shader))
	_bind_color(material)
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("depth_enabled", false)
	material.set_shader_parameter("packed_alpha", false)
	# projection_mesh/UV packing remain as authored for stream-specific projections.
	material.set_shader_parameter("pip_enabled", false)
	# Like PiP, show one source eye to both eyes on the small physical surface.
	# Keep eye packing/swap intact; the release panorama retains the original stereo view.
	var eye: Variant = material.get_shader_parameter("viewing_eye")
	material.set_shader_parameter("pip_viewing_eye", maxi(1, int(eye) if eye != null else 0))
	material.set_shader_parameter("pip_forward", -crop_basis.z)
	material.set_shader_parameter("pip_right", crop_basis.x)
	material.set_shader_parameter("pip_up", crop_basis.y)
	material.set_shader_parameter("separate_subtitles", true)

	stage = "held"; preview.visible = true
	roll = 1.0 if skip_open_animation else 0.0
	motion = "" if skip_open_animation else "opening"
	motion_elapsed = 0.0
	material.set_shader_parameter("temporary_roll", roll)
	material.set_shader_parameter("temporary_opacity", 1.0 if skip_open_animation else 0.35)
	hide_source()
	video._update_layer()
	video.changed.emit()

func _bind_color(target: ShaderMaterial) -> void:
	if image: target.set_shader_parameter("color_texture", image)
	elif binding.material:
		RenderingServer.material_set_param(target.get_rid(), "color_texture", binding.color_texture())

func request_exit() -> void:
	if not active(): return
	# A second press, an unfinished copy or lost native frame never traps the user in a tween.
	if not held() or not preview.visible or motion == "closing":
		exit_ready.emit(); return
	motion_from = roll; motion_elapsed = 0.0; motion = "closing"
	exit_opacity = float(material.get_shader_parameter("temporary_opacity"))
	release_surface = MeshInstance3D.new()
	release_surface.name = "UnfoldingVrPreview"
	release_surface.mesh = video.panel.mesh
	release_surface.material_override = release_material
	release_surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	video.add_child(release_surface)
	_sync_release_pose()

func _sync_release_pose() -> void:
	video._center_on_view()
	release_surface.global_transform = video.panel.global_transform

func animate(delta: float) -> void:
	if motion.is_empty(): return
	motion_elapsed += maxf(0.0, delta)
	var duration := ROLL_SECONDS if motion == "opening" else ROLL_SECONDS * maxf(0.25, motion_from)
	var progress := clampf(motion_elapsed / duration, 0.0, 1.0)
	var eased := smoothstep(0.0, 1.0, progress)
	if motion == "opening":
		roll = eased
		material.set_shader_parameter("temporary_opacity", lerpf(0.35, 1.0, smoothstep(0.0, 0.2, progress)))
	else:
		roll = lerpf(motion_from, 0.0, eased)
		var blend := smoothstep(0.15, 1.0, progress)
		material.set_shader_parameter("temporary_opacity", exit_opacity * (1.0 - blend))
		release_material.set_shader_parameter("temporary_opacity", blend)
		_sync_release_pose()
	material.set_shader_parameter("temporary_roll", roll)
	if progress >= 1.0:
		if motion == "closing": exit_ready.emit()
		else: motion = ""

func hide_source() -> void:
	video.panel.layers = 0
	video.caption.visible = false
	if video._subtitle_surface: video._subtitle_surface.visible = false

func _fail() -> void:
	finish(true)
	failed.emit()

func _release(pair: Dictionary) -> void:
	if int(pair.get("frozen_frame_id", 0)) > 0: video.platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))

func finish(restore: bool) -> void:
	if not active(): return
	var resume := was_playing
	var valid: bool = source_uri == video.local_uri and video.media.accepts(video.media.session_id) and video.media.state != "failed"
	stage = ""
	motion = ""; motion_elapsed = 0.0
	for window in window_visibility:
		if is_instance_valid(window): window.visible = window_visibility[window]
	window_visibility.clear()
	if snapshot_request > 0 and Methods.supports(video.platform, "cancel_mpv_layer_snapshot"):
		video.platform.cancel_mpv_layer_snapshot(snapshot_request)
	snapshot_request = 0; request = 0
	video.panel.layers = panel_layers
	var old := preview
	var old_binding := binding
	var resources := [material, release_material, image]
	var platform: Object = video.platform
	preview = null; material = null; image = null; binding = Binding.new()
	if release_surface: release_surface.visible = false; release_surface.queue_free()
	release_surface = null; release_material = null
	if old: old.visible = false; old.queue_free()
	var release := func():
		var pair: Dictionary = old_binding.unbind()
		if is_instance_valid(platform) and int(pair.get("frozen_frame_id", 0)) > 0: platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		resources.clear()
	if video.is_inside_tree() and Engine.get_frames_drawn() > 0: RenderingServer.frame_post_draw.connect(release, CONNECT_ONE_SHOT)
	else: release.call()
	if restore and valid:
		video._center_on_view()
		video._poll_subtitles()
		video._update_layer()
		video.requested_play = resume
		video._set_backend_playing(video.media.session_id, resume and not video._waiting_first)
		video.narration.apply()
