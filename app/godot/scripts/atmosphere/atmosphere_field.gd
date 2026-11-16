extends Node3D
## The particles of one atmosphere theme: a MultiMesh per layer whose motion lives in the shader.
## Per frame only a handful of uniforms change.
const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const SHADER := preload("res://shaders/atmosphere_particles.gdshader")
## After the video hole (-128) and the screen halo (-126), before menu holes (9) and menus (10+):
## the picture's keep-out is the shader's own, and menus always draw over the particles.
const PRIORITY := -100
const FADE_SECONDS := 1.5
## Long sessions keep float precision in the shader; the jump lands once every four hours.
const CLOCK_WRAP := 14400.0
## How far under the floor a box may reach; particles fade out just above it.
const FLOOR_SINK := 0.2
var theme := ""
var amount := Catalog.DEFAULT_AMOUNT
var low_end := false
var clock := 0.0
var opacity := 0.0
var layers: Array = []

func build(id: String, amount_choice: int, low_end_gpu: bool) -> void:
	if id == theme and amount_choice == amount and low_end_gpu == low_end and (id.is_empty() or not layers.is_empty()): return
	clear()
	theme = Catalog.clean(id); amount = Catalog.clean_amount(amount_choice); low_end = low_end_gpu
	var row := Catalog.theme(theme)
	if row.is_empty(): return
	var quad := QuadMesh.new(); quad.size = Vector2.ONE
	var random := RandomNumberGenerator.new()
	for index in row.layers.size():
		var layer: Dictionary = row.layers[index]
		var material := ShaderMaterial.new(); material.shader = SHADER; material.render_priority = PRIORITY
		for key in ["shape", "size", "spread", "box", "velocity", "sway", "sway_rate", "tumble", "pulse", "glow", "tint_a", "tint_b"]:
			if layer.has(key): material.set_shader_parameter(key, layer[key])
		material.set_shader_parameter("opacity", 0.0)
		var mesh := MultiMesh.new()
		mesh.transform_format = MultiMesh.TRANSFORM_3D; mesh.use_custom_data = true
		mesh.mesh = quad; mesh.instance_count = Catalog.instances(layer, amount, low_end)
		# The same places every time a theme is shown.
		random.seed = hash(theme) + index * 7919
		for instance in mesh.instance_count:
			mesh.set_instance_transform(instance, Transform3D.IDENTITY)
			mesh.set_instance_custom_data(instance, Color(random.randf(), random.randf(), random.randf(), random.randf()))
		var node := MultiMeshInstance3D.new(); node.multimesh = mesh; node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# The shader places every particle; the mesh's own bounds mean nothing.
		node.custom_aabb = AABB(Vector3.ONE * -10000.0, Vector3.ONE * 20000.0)
		node.visible = false
		add_child(node)
		layers.append({"node": node, "material": material, "lift": float(layer.get("lift", 0.0)), "height": float((layer.box as Vector3).y)})

func clear() -> void:
	for layer in layers: layer.node.queue_free()
	layers.clear(); theme = ""; opacity = 0.0

## `screen`: {"transform": Transform3D, "size": Vector2} of the flat picture to keep clear, or empty.
func step(delta: float, shown: bool, head: Vector3, floor_y: float, screen: Dictionary, display_referred: bool) -> void:
	if layers.is_empty(): return
	opacity = move_toward(opacity, 1.0 if shown else 0.0, delta / FADE_SECONDS)
	var visible_now := opacity > 0.0
	if visible_now: clock = fmod(clock + delta, CLOCK_WRAP)
	var inverse := Transform3D.IDENTITY
	var half := Vector2.ZERO
	if not screen.is_empty():
		inverse = (screen.transform as Transform3D).affine_inverse(); half = (screen.size as Vector2) * 0.5
	for layer in layers:
		layer.node.visible = visible_now
		if not visible_now: continue
		var material: ShaderMaterial = layer.material
		# The box stands on the floor rather than half under it.
		material.set_shader_parameter("centre", Vector3(head.x, maxf(head.y + float(layer.lift), floor_y + float(layer.height) * 0.5 - FLOOR_SINK), head.z))
		material.set_shader_parameter("head", head)
		material.set_shader_parameter("clock", clock)
		material.set_shader_parameter("opacity", opacity)
		material.set_shader_parameter("floor_y", floor_y)
		material.set_shader_parameter("screen_inverse", Projection(inverse))
		material.set_shader_parameter("screen_half", half)
		material.set_shader_parameter("display_referred", display_referred)

func particle_count() -> int:
	var total := 0
	for layer in layers: total += layer.node.multimesh.instance_count
	return total
