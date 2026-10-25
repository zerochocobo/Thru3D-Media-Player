extends SceneTree
## Renders the wrist watch states for visual review and checks that each one draws.
const Watch := preload("res://scripts/wrist_watch.gd")
const Logic := preload("res://scripts/wrist_watch_logic.gd")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var watch: Node3D
var output := ""
var head := Transform3D.IDENTITY
var wrist := Transform3D.IDENTITY
var media := {"has_video": true, "playing": true, "position_ms": 2_310_000, "duration_ms": 6_480_000,
	"has_previous": true, "has_next": false, "has_subtitles": true, "subtitle_on": true, "subtitle_label": "简体中文",
	"bookmarks": [{"position_ms": 900_000}, {"position_ms": 4_100_000}, {"position_ms": 5_000_000}]}

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func frame(tip: Variant, steps: int = 1) -> void:
	for i in steps:
		watch.step({"head": head, "wrist": wrist, "tip": tip, "enabled": true, "media": media}, 1.0 / 72.0)

func shot(name: String, fov: float = 62.0, look: Variant = null) -> Image:
	camera.fov = fov
	camera.global_transform = head
	if look is Vector3: camera.look_at(look, Vector3.UP)
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(image.save_png(output.path_join(name + ".png")) == OK, "Save " + name)
	return image

func lit_pixels(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var pixel := image.get_pixel(x, y)
			if pixel.g > 0.45 and pixel.g > pixel.r + 0.08: count += 1
	return count

func run() -> void:
	output = OS.get_environment("THRU3D_TEST_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/wrist-watch")
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var environment := Environment.new(); environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.16, 0.15, 0.14)
	var world := WorldEnvironment.new(); world.environment = environment; viewport.add_child(world)
	camera = Camera3D.new(); camera.near = 0.01; viewport.add_child(camera)
	# A video-like backdrop: a warm bright frame so contrast over real content is visible.
	var screen := MeshInstance3D.new(); var quad := QuadMesh.new(); quad.size = Vector2(4.8, 2.7); screen.mesh = quad
	screen.position = Vector3(0, 1.3, -2.4)
	var backdrop := StandardMaterial3D.new(); backdrop.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var gradient := GradientTexture2D.new(); var colors := Gradient.new()
	colors.set_color(0, Color(0.85, 0.62, 0.42)); colors.set_color(1, Color(0.12, 0.18, 0.28))
	gradient.gradient = colors; gradient.fill_from = Vector2(0, 0); gradient.fill_to = Vector2(1, 1)
	backdrop.albedo_texture = gradient; screen.material_override = backdrop; viewport.add_child(screen)
	watch = Watch.new()
	watch.status_provider = func() -> Dictionary: return {"level": 76, "charging": false, "clock24": true}
	watch.clock_provider = func() -> Dictionary: return {"hour": 21, "minute": 47}
	viewport.add_child(watch)
	head = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	# Checking the watch: forearm level in front, back of the hand up, the face tipped a little
	# toward the eyes.
	var face_origin := Vector3(-0.09, 1.25, -0.3)
	var to_eye := (head.origin - face_origin).normalized()
	var normal := Vector3.UP.slerp(to_eye, 0.15).normalized()
	var forearm := Vector3(-1, 0, 0.35).normalized()
	forearm = (forearm - normal * forearm.dot(normal)).normalized()
	var side := normal.cross(forearm).normalized()
	wrist = Transform3D(Basis(side, normal, forearm), face_origin)
	head = head.looking_at(face_origin + Vector3(0, 0.06, 0), Vector3.UP)
	# Stand-in forearm and hand, as the hand-tracking mesh would draw them.
	var skin := StandardMaterial3D.new(); skin.albedo_color = Color(0.72, 0.79, 0.85)
	var arm := MeshInstance3D.new(); var capsule := CapsuleMesh.new(); capsule.radius = 0.024; capsule.height = 0.3
	arm.mesh = capsule; arm.material_override = skin; viewport.add_child(arm)
	arm.global_transform = Transform3D(Basis(side, forearm, -normal).orthonormalized(), face_origin - normal * 0.028 + forearm * 0.12)
	var palm := MeshInstance3D.new(); var box := BoxMesh.new(); box.size = Vector3(0.085, 0.1, 0.03)
	palm.mesh = box; palm.material_override = skin; viewport.add_child(palm)
	palm.global_transform = Transform3D(Basis(side, -forearm, normal).orthonormalized(), face_origin - normal * 0.028 - forearm * 0.08)
	var light := DirectionalLight3D.new(); light.rotation_degrees = Vector3(-50, 30, 0); viewport.add_child(light)
	frame(null, 20)
	check(watch.logic.phase == Logic.Phase.GLANCE, "Looking at the wrist shows the face")
	frame(null, 40)
	var image := await shot("face-closeup", 14.0, face_origin)
	check(lit_pixels(image) > 300, "Face draws its rings")
	await shot("glance", 70.0)
	# Raise the wrist toward the eyes: the face charges up, then projects.
	var home := wrist
	wrist = Transform3D(home.basis, head.origin + (face_origin - head.origin).normalized() * 0.3)
	frame(null, 12)
	await shot("charging", 40.0, wrist.origin)
	wrist = Transform3D(home.basis, head.origin + (face_origin - head.origin).normalized() * 0.25)
	frame(null, 30)
	check(watch.logic.expanded(), "Raising the wrist projects the disc")
	wrist = home
	var holo: Transform3D = watch.logic.holo
	var view := holo.origin - holo.basis.z * 0.03
	var away := face_origin + Vector3(0.35, -0.25, 0.1)
	frame(away, 10)
	await shot("unfold-1", 70.0, view)
	frame(away, 12)
	await shot("unfold-2", 70.0, view)
	frame(away, 40)
	holo = watch.logic.holo
	view = holo.origin - holo.basis.z * 0.03
	image = await shot("expanded", 70.0, view)
	check(lit_pixels(image) > 300, "Projection draws its cone, ring and keys")
	await shot("expanded-wide", 90.0, view)
	for option in Watch.Palette.OPTIONS:
		watch.set_color(option.value)
		await shot("color-" + option.value, 70.0, view)
	watch.set_color(Watch.Palette.DEFAULT)
	var eye := head
	head = Transform3D(Basis.IDENTITY, face_origin + side * 0.45 + Vector3.UP * 0.12 + to_eye * 0.1)
	await shot("side", 50.0, face_origin + normal * 0.07)
	head = eye
	# Hover close to play.
	frame(holo * Vector3(0.006, 0.014, 0.022), 20)
	await shot("hover-play", 70.0, view)
	# Scrub forward around the ring.
	var start := deg_to_rad(50.0)
	var ring := Logic.PROGRESS_RING
	frame(holo * Vector3(sin(start) * ring, cos(start) * ring, 0.045), 12)
	frame(holo * Vector3(sin(start) * ring, cos(start) * ring, 0.004), 12)
	check(not watch.logic.scrub.is_empty(), "Touching the ring grabs the timeline")
	for i in 30:
		var a := deg_to_rad(lerpf(50.0, 100.0, i / 29.0))
		frame(holo * Vector3(sin(a) * ring, cos(a) * ring, 0.004))
	await shot("scrub", 70.0, view)
	var r := ring + Logic.FINE_ZONE + 0.02
	for i in 10:
		var a := deg_to_rad(100.0 + i * 0.5)
		frame(holo * Vector3(sin(a) * r, cos(a) * r, 0.004))
	await shot("scrub-fine", 70.0, view)
	frame(holo * Vector3(0, 0.3, 0.06), 12)
	# Hold fast-forward: the marker sits on the key and the run total shows.
	var key := Logic.button_position("forward")
	frame(holo * Vector3(key.x + 0.008, key.y + 0.01, 0.045), 12)
	frame(holo * Vector3(key.x + 0.008, key.y + 0.01, 0.006), 110)
	check(watch.logic.skip_total >= 40, "Holding forward keeps skipping")
	await shot("skip", 70.0, view)
	frame(holo * Vector3(key.x, key.y, 0.05), 20)
	for failure in failures: push_error(failure)
	print("Wrist watch render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
