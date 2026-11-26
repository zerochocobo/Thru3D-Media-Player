extends SceneTree
## PairTextureBinding draws plain playback with the generated plain variant exactly while the pair
## shader's fast path conditions hold, and everyone else keeps seeing the pair shader.
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Facing := preload("res://scripts/surface_facing.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func plain_material(shader: Shader) -> ShaderMaterial:
	var material := ShaderMaterial.new(); material.shader = shader
	for name in Binding.PLAIN_OFF: material.set_shader_parameter(name, false)
	material.set_shader_parameter("plain_fast_path", true)
	material.set_shader_parameter("sharpness", 0.0)
	material.set_shader_parameter("grade_contrast", 1.3)
	return material

func _run() -> void:
	for canonical: Shader in [Binding.PAIR_SHADER, Binding.DECODER_SHADER]:
		var name := canonical.resource_path.get_file()
		var code := Binding.plain_code(canonical.code)
		check(not code.is_empty() and not code.contains("Full path") and code.contains("plain_rgb"), "Plain code not cut from " + name)
		var plain := Binding.plain_variant(canonical)
		check(plain != null and Binding.plain_variant(canonical) == plain, "Plain variant not cached for " + name)
		check(Binding.source_shader(plain) == canonical, "Plain variant hides its source " + name)
		var binding := Binding.new()
		var material := plain_material(canonical)
		binding.material = material
		binding.refresh_plain()
		check(material.shader == plain, "Plain conditions did not select the plain variant " + name)
		check(is_equal_approx(float(material.get_shader_parameter("grade_contrast")), 1.3), "Parameters lost on the swap " + name)
		check(Binding.full_shader(material) == canonical, "full_shader is not the pair shader " + name)
		for off in Binding.PLAIN_OFF:
			material.set_shader_parameter(off, true); binding.refresh_plain()
			# Mono parallax with nothing else on has a variant of its own.
			var expected := Binding.depth_variant(canonical) if off == "depth_enabled" else canonical
			check(material.shader == expected, "%s did not leave the plain variant for %s (%s)" % [off, expected.resource_name, name])
			material.set_shader_parameter(off, false); binding.refresh_plain()
			check(material.shader == plain, "%s off did not return to the plain variant (%s)" % [off, name])
		material.set_shader_parameter("sharpness", 0.2); binding.refresh_plain()
		check(material.shader == canonical, "Sharpening kept the plain variant " + name)
		material.set_shader_parameter("sharpness", 0.0)
		material.set_shader_parameter("plain_fast_path", false); binding.refresh_plain()
		check(material.shader == canonical, "Non-QIYU playback took the plain variant " + name)
		material.set_shader_parameter("plain_fast_path", true)
		Binding.plain_shader_enabled = false; binding.refresh_plain()
		check(material.shader == canonical, "perf_tune plain_shader=false kept the plain variant " + name)
		Binding.plain_shader_enabled = true; binding.refresh_plain()
		check(material.shader == plain, "Plain variant not restored " + name)
		# A consumer (PiP, portrait core) shares the pair shader, never the plain variant.
		var consumer := ShaderMaterial.new()
		binding.share_with(consumer)
		check(consumer.shader == canonical, "Consumer got the plain variant " + name)
		binding.unshare(consumer)
		# Front-faced (in-scene screens): the plain variant gets its own front-faced variant.
		Facing.apply(material, true); binding.refresh_plain()
		check(material.shader != plain and Facing.source(material.shader) == plain, "Front faces lost the plain variant " + name)
		check(Binding.source_shader(material.shader) == canonical and Binding.full_shader(material) == Facing.for_material(material, canonical), "Front-faced plain hides the pair shader " + name)
		material.set_shader_parameter("alpha_enabled", true); binding.refresh_plain()
		check(material.shader == Facing.for_material(material, canonical), "Front-faced pair shader not restored " + name)
		Facing.apply(material, false)
		# Another shader on the material (the passthrough globe, a portrait) is left alone.
		var other := Shader.new(); other.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
		material.shader = other; material.set_shader_parameter("alpha_enabled", false); binding.refresh_plain()
		check(material.shader == other, "refresh_plain replaced a foreign shader " + name)
		binding.material = null
	var empty := Binding.plain_code("shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }\n")
	check(empty.is_empty(), "Code without the markers produced a plain variant")
	check(Binding.depth_code("shader_type spatial;\nvoid fragment() { ALBEDO = vec3(1.0); }\n").is_empty(), "Code without the markers produced a depth variant")
	_run_depth()
	for failure in failures: push_error(failure)
	print("Plain shader switch: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

## Mono 2D->3D through the shader's parallax draws with the depth variant on every platform.
func _run_depth() -> void:
	for canonical: Shader in [Binding.PAIR_SHADER, Binding.DECODER_SHADER]:
		var name := canonical.resource_path.get_file()
		var code := Binding.depth_code(canonical.code)
		check(not code.is_empty() and not code.contains("Full path") and not code.contains("plain_rgb") and code.contains("depth_parallax(shown_uv"), "Depth code not cut from " + name)
		# The switched-off parts stay as text behind constant false conditions, for the compiler to drop.
		check(code.contains("if (false && !top_bottom && false)") or code.contains("if (false && false && !top_bottom)"), "Packed Alpha not behind a constant " + name)
		check(code.contains("if (false && !false) {\n\t\tvec2 step_uv"), "Sharpening not behind a constant " + name)
		for fixed in Binding.DEPTH_FIXED:
			check(code.substr(code.find("void fragment()")).find(fixed) < 0, "Depth code still reads %s (%s)" % [fixed, name])
		var depth := Binding.depth_variant(canonical)
		check(depth != null and Binding.depth_variant(canonical) == depth, "Depth variant not cached for " + name)
		check(Binding.source_shader(depth) == canonical, "Depth variant hides its source " + name)
		var binding := Binding.new()
		var material := plain_material(canonical)
		material.set_shader_parameter("stereo_sbs", false)
		material.set_shader_parameter("depth_enabled", true)
		binding.material = material
		binding.refresh_plain()
		check(material.shader == depth, "Depth conditions did not select the depth variant " + name)
		check(is_equal_approx(float(material.get_shader_parameter("grade_contrast")), 1.3), "Parameters lost on the depth swap " + name)
		check(Binding.full_shader(material) == canonical, "full_shader is not the pair shader under depth " + name)
		for off in Binding.PLAIN_OFF + ["stereo_sbs"]:
			if off == "depth_enabled": continue
			material.set_shader_parameter(off, true); binding.refresh_plain()
			check(material.shader == canonical, "%s did not return to the pair shader under depth (%s)" % [off, name])
			material.set_shader_parameter(off, false); binding.refresh_plain()
			check(material.shader == depth, "%s off did not return to the depth variant (%s)" % [off, name])
		material.set_shader_parameter("sharpness", 0.2); binding.refresh_plain()
		check(material.shader == canonical, "Sharpening kept the depth variant " + name)
		material.set_shader_parameter("sharpness", 0.0)
		material.set_shader_parameter("plain_fast_path", false); binding.refresh_plain()
		check(material.shader == depth, "The depth variant depends on plain_fast_path " + name)
		material.set_shader_parameter("plain_fast_path", true)
		Binding.depth_shader_enabled = false; binding.refresh_plain()
		check(material.shader == canonical, "perf_tune depth_shader=false kept the depth variant " + name)
		Binding.depth_shader_enabled = true; binding.refresh_plain()
		check(material.shader == depth, "Depth variant not restored " + name)
		material.set_shader_parameter("depth_enabled", false); binding.refresh_plain()
		check(material.shader == Binding.plain_variant(canonical), "Depth off did not go to the plain variant " + name)
		material.set_shader_parameter("depth_enabled", true); binding.refresh_plain()
		var consumer := ShaderMaterial.new()
		binding.share_with(consumer)
		check(consumer.shader == canonical, "Consumer got the depth variant " + name)
		binding.unshare(consumer)
		Facing.apply(material, true); binding.refresh_plain()
		check(material.shader != depth and Facing.source(material.shader) == depth, "Front faces lost the depth variant " + name)
		check(Binding.source_shader(material.shader) == canonical, "Front-faced depth hides the pair shader " + name)
		Facing.apply(material, false)
		binding.material = null
