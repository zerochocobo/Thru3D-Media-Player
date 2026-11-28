extends SceneTree
## The five wands as the headset draws them: side by side, close up on the handles, and from above and below
## (a hand tilts the wand toward and away from the eye; faces wound the wrong way show as a hollow shell).
## godot --xr-mode off --path app/godot --script ../../tools/wands/render_wands.gd -- <png>
const Wand := preload("res://scripts/book_wand.gd")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#2b2522")
	var world := WorldEnvironment.new(); world.environment = environment
	root.add_child(world)
	root.size = Vector2i(1400, 900)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position = Vector3(0, .01, .62)
	camera.fov = 40
	for i in Wand.STYLES.size():
		var wand := Wand.new()
		root.add_child(wand)
		wand.set_style(Wand.STYLES[i])
		# Upright, pommel low, each turned a little toward the camera like a hand holding it out.
		wand.global_transform = Transform3D(Basis(Vector3.RIGHT, PI * .5).rotated(Vector3.UP, .4 - .2 * i), Vector3(-.18 + .09 * i, -.16, 0))
		wand.visible = true
	for f in 6: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out)
	camera.position = Vector3(0, -.10, .30)
	for f in 3: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.get_basename() + "-handles.png")
	for view in [["above", Vector3(0, .40, .32)], ["below", Vector3(0, -.50, .26)]]:
		camera.position = view[1]
		camera.look_at(Vector3(0, -.02, 0), Vector3.UP)
		for f in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.get_basename() + "-" + view[0] + ".png")
	quit()
