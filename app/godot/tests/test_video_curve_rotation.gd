extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Layer := preload("res://scripts/video_layer.gd")
var checks := 0
var failures: Array[String] = []

class Layers extends "res://scripts/video_layer.gd":
	func _init() -> void: super(null)
	func update_session() -> void: pass
	func available() -> bool: return true
	func capacity() -> int: return 16
	func supports(_geometry: int, _curve: bool) -> bool: return true

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	var origin := XROrigin3D.new(); root.add_child(origin)
	var video := Video.new(); origin.add_child(video); video.set_process(false)
	video.video_layer = Layers.new()
	video.local_uri = "file:///curve-rotation.mp4"
	video.media.begin(1)
	video.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)))
	video.panel.visible = true
	var cue := {"version": 1, "width": 8, "height": 2, "x": 0, "y": 0, "canvas_width": 16, "canvas_height": 9}
	var pixels := PackedByteArray(); pixels.resize(8 * 2 * 4); pixels.fill(255)
	for dimensions in [Vector2(1920, 1080), Vector2(1080, 1920)]:
		video.media.format = {"width": dimensions.x, "height": dimensions.y}
		for layout in [[false, false, false], [true, false, false], [true, true, false], [true, false, true], [true, true, true]]:
			video.stereo_sbs = layout[0]; video.top_bottom = layout[1]; video.stereo_half = layout[2]
			for curve in [60.0, 160.0]:
				video.set_screen_curve(curve)
				for angle in [0.0, 90.0, -90.0, 180.0, 45.0, -135.0]:
					video.set_screen_rotation(angle)
					var size: Vector2 = video._flat.size
					var roll := Basis(Vector3.FORWARD, deg_to_rad(angle))
					var radius: float = video._curve_radius()
					var arrays: Array = video.panel.mesh.surface_get_arrays(0)
					var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
					var correct := true
					for index in vertices.size():
						var rotated := roll * Vector3((uvs[index].x - 0.5) * size.x, (0.5 - uvs[index].y) * size.y, 0)
						var expected := Vector3(sin(rotated.x / radius) * radius, rotated.y, (1 - cos(rotated.x / radius)) * radius)
						correct = correct and (roll * vertices[index]).distance_to(expected) < 0.00001
					check(correct, "Video bends left/right after content rotation: %s / %s / %s / %s" % [dimensions, layout, curve, angle])
					check(vertices.size() < 700, "Rotated video retains the existing mobile mesh budget")
					for uv in [Vector2(0.25, 0.3), Vector2(0.5, 0.5), Vector2(0.75, 0.7)]:
						var point := video.surface_point(Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0))
						var world := video.panel.to_global(point)
						var direction := world.normalized()
						var actual: Variant = video.screen_uv(Vector3.ZERO, direction)
						check(actual != null and actual.distance_to(uv) < 0.0001, "Disc/menu ray samples the rotated curved source pixel")
						var pip: Dictionary = video.pip.source_hit(Vector3.ZERO, direction)
						check(not pip.is_empty() and (pip.center as Vector2).distance_to(uv) < 0.0001, "PiP ray samples the same rotated curved source pixel")
					var compatible: bool = angle in [0.0, 180.0]
					check(video.video_layer.supports_surface(video) == compatible, "Native cylinder only serves an equivalent horizontal mesh")
					check(video._layer_presentation() == compatible, "Decoder Surface follows the same curved rotation policy")
					check(video.video_layer.layer_values(video, origin).is_empty() != compatible, "Native layer boundary rejects an incorrectly oriented cylinder")
					if angle != 0.0:
						video.bitmap_subtitles.apply(video.material, cue, 1, pixels)
						video._sync_subtitle_surface()
						var caption_vertices: PackedVector3Array = video._subtitle_surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
						var aligned := caption_vertices.size() == vertices.size()
						for index in mini(caption_vertices.size(), vertices.size()):
							var point: Vector3 = video._subtitle_surface.to_global(caption_vertices[index])
							# A half turn gives an equivalent symmetric surface with reversed vertex order.
							if absf(angle) != 180.0: aligned = aligned and point.distance_to(video.panel.to_global(vertices[index])) < 0.00001
						check(video._subtitle_surface.visible and aligned, "Bitmap cues stay on the rotated curved picture by default")
						video.bitmap_subtitles.clear(video.material)
					if not compatible:
						check(video.layer_block_reason() == "shape", "Fallback identifies the unsupported shape")
						var corner: Vector3 = video.screen_corner(1)
						video.set_screen_distance(15)
						check(video.screen_corner(1).is_equal_approx(corner), "Distance changes preserve the rotated curved shape")
	video.set_screen_curve(0)
	video.set_screen_rotation(90)
	check(video.video_layer.supports_surface(video), "Uncurved rotated videos keep the native quad path")
	origin.free()
	for failure in failures: push_error(failure)
	print("Video curve rotation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
