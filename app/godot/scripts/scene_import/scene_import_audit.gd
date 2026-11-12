extends RefCounted
## Cost summary of a loaded scene tree. Works on detached trees (no global transforms).

static func to_root(node: Node3D, root: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var current: Node = node
	while current != null:
		if current is Node3D: xform = (current as Node3D).transform * xform
		if current == root: break
		current = current.get_parent()
	return xform

static func mesh_triangles(mesh: Mesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		var count := 0
		if mesh is ArrayMesh:
			if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
			count = mesh.surface_get_array_index_len(surface)
			if count == 0: count = mesh.surface_get_array_len(surface)
		else:
			var arrays := mesh.surface_get_arrays(surface)
			var indices: Variant = arrays[Mesh.ARRAY_INDEX]
			count = indices.size() if indices != null and not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size()
		total += count / 3
	return total

## Every drawable in the tree: {node, mesh, triangles, batches, bounds (root space)}.
static func drawables(root: Node) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		var mesh: Mesh = null
		var copies := 1
		if node is MeshInstance3D: mesh = node.mesh
		elif node is MultiMeshInstance3D and node.multimesh:
			mesh = node.multimesh.mesh
			copies = maxi(node.multimesh.instance_count, 0)
		if mesh == null or not (node as Node3D).visible: continue
		found.append({"node": node, "mesh": mesh, "triangles": mesh_triangles(mesh) * copies,
			"batches": mesh.get_surface_count(),
			"bounds": to_root(node, root) * (node as VisualInstance3D).get_aabb()})
	return found

static func materials(items: Array[Dictionary]) -> Array[Material]:
	var seen := {}
	for item in items:
		var node: Node = item.node
		if node is MeshInstance3D and node.material_override: seen[node.material_override] = true
		for surface in item.mesh.get_surface_count():
			var material: Material = item.mesh.surface_get_material(surface)
			if node is MeshInstance3D and node.get_surface_override_material(surface):
				material = node.get_surface_override_material(surface)
			if material: seen[material] = true
	var list: Array[Material] = []
	list.assign(seen.keys())
	return list

static func textures(items: Array[Dictionary]) -> Array[Texture2D]:
	var seen := {}
	for material in materials(items):
		if material is BaseMaterial3D:
			for slot in BaseMaterial3D.TEXTURE_MAX:
				var texture: Texture2D = material.get_texture(slot)
				if texture: seen[texture] = true
		elif material is ShaderMaterial and material.shader:
			for uniform in material.shader.get_shader_uniform_list():
				var value: Variant = material.get_shader_parameter(uniform.name)
				if value is Texture2D: seen[value] = true
	var list: Array[Texture2D] = []
	list.assign(seen.keys())
	return list

static func texture_bytes(texture: Texture2D) -> int:
	var pixels := texture.get_width() * texture.get_height()
	var bits := 32
	var mipmaps := true
	if texture is ImageTexture:
		var format: int = texture.get_format()
		if format in [Image.FORMAT_ETC, Image.FORMAT_ETC2_RGB8, Image.FORMAT_DXT1, Image.FORMAT_ETC2_R11]: bits = 4
		elif format in [Image.FORMAT_ETC2_RGBA8, Image.FORMAT_DXT5, Image.FORMAT_ASTC_4x4, Image.FORMAT_BPTC_RGBA, Image.FORMAT_ETC2_RG11]: bits = 8
		elif format in [Image.FORMAT_ASTC_8x8]: bits = 2
		elif format in [Image.FORMAT_L8, Image.FORMAT_R8]: bits = 8
		elif format in [Image.FORMAT_RGB8]: bits = 24
		elif format in [Image.FORMAT_RGBAH]: bits = 64
		elif format in [Image.FORMAT_RGBAF]: bits = 128
	var size := pixels * bits / 8
	return size * 4 / 3 if mipmaps else size

static func audit(root: Node) -> Dictionary:
	var items := drawables(root)
	var stats := {"meshes": items.size(), "triangles": 0, "batches": 0, "texture_bytes": 0,
		"textures": 0, "largest_texture": 0, "lights": 0, "bounds": AABB()}
	var first := true
	for item in items:
		stats.triangles += item.triangles
		stats.batches += item.batches
		stats.bounds = item.bounds if first else stats.bounds.merge(item.bounds)
		first = false
	for texture in textures(items):
		stats.textures += 1
		stats.texture_bytes += texture_bytes(texture)
		stats.largest_texture = maxi(stats.largest_texture, maxi(texture.get_width(), texture.get_height()))
	stats.lights = root.find_children("*", "Light3D", true, false).size()
	return stats
