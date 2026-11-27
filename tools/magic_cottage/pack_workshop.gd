extends SceneTree
## Packs the exported workshop for the player.
## Args: <workshop.glb | existing workshop.res> <destination .res>
## Either input goes through the same finishing pass, so the shipped resource can be
## refreshed without Blender as well as rebuilt from the master.
##
## The finishing pass lets the fixed room cull back faces. Some Blender pieces (window
## reveals, ridge boards) face away from the seat and only showed because every material
## was double sided. Those triangles are found by occlusion rays from around the seat,
## and turned to face it. Hand-held props and the settle around the viewer stay double sided.

# The source scans are already imported for the beach with mipmaps and VRAM
# compression. Sharing them keeps distant stone from shimmering in the headset.
const TEXTURES := {
	"rock": "res://environments/private_beach/rock_boulder_dry_diff_2k.jpg",
	"oak": "res://environments/private_beach/wood_table_001_diff_2k.jpg",
	"cloth": "res://environments/magic_cottage/coverlet.jpg",
}
# The settle wraps the viewer, so it keeps both sides and never blocks the occlusion rays.
# export_workshop.py stores baked light at half strength (8-bit corner colours keep headroom);
# unshaded room materials lift it back. Flames and the brew draw a little brighter than lit stone.
const LIGHT_LIFT := 2.0
const EMBER_LIFT := 3.0
# The brew glows teal on its own; glass, brass and glaze use the sheen shader.
const BREW_LIFT := 1.8
const SHEEN := preload("res://environments/magic_cottage/room_sheen.gdshader")
const HELD := ["Settle", "Jug", "Dose0", "Dose1", "Dose2", "Dose3", "Dose4", "Dose5"]
const SEAT := Vector3(0, 1.15, 1.82)
# Seated head room: lean, turn and look up from the cushion.
const HEAD := [Vector3.ZERO, Vector3(-.3, 0, 0), Vector3(.3, 0, 0), Vector3(0, .25, 0), Vector3(0, -.2, 0),
	Vector3(0, .1, -.4), Vector3(-.25, .1, -.3), Vector3(.25, .1, -.3)]
# "Weightless tide" lifts the furniture up to about 0.9 m and lowers the room.
const LIFT := Vector3(0, -.95, 0)

var hall: Node3D
var space: PhysicsDirectSpaceState3D

func _initialize() -> void:
	var paths := OS.get_cmdline_user_args()
	if paths[0].ends_with(".res") or paths[0].ends_with(".tres"):
		hall = (load(paths[0]) as PackedScene).instantiate()
	else:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(paths[0], state) != OK:
			quit(1)
			return
		hall = doc.generate_scene(state)
	get_root().add_child(hall)
	for node in hall.get_children():
		if node is MeshInstance3D and str(node.name) != "Settle":
			var body := StaticBody3D.new()
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(node.mesh.get_faces())
			var holder := CollisionShape3D.new()
			holder.shape = shape
			body.add_child(holder)
			body.transform = node.transform
			get_root().add_child(body)
	_pack.call_deferred(paths[1])

func _pack(destination: String) -> void:
	await physics_frame
	await physics_frame
	space = get_root().world_3d.direct_space_state
	var turned := 0
	var materials := {}
	for node in hall.get_children():
		if node is MeshInstance3D:
			turned += finish(node, materials)
	hall.get_parent().remove_child(hall)
	var packed := PackedScene.new()
	var err := packed.pack(hall)
	if err == OK:
		err = ResourceSaver.save(packed, destination, ResourceSaver.FLAG_COMPRESS)
	print("WORKSHOP PACK ", error_string(err), " ", hall.get_child_count(), " nodes, ", turned, " triangles turned to the seat")
	hall.free()
	quit(err)

func seen(from: Vector3, point: Vector3) -> bool:
	var direction := (point - from).normalized()
	var query := PhysicsRayQueryParameters3D.create(from, point - direction * .004)
	query.hit_back_faces = true
	return space.intersect_ray(query).is_empty()

func finish(item: MeshInstance3D, materials: Dictionary) -> int:
	var held := str(item.name) in HELD
	var source := item.mesh as ArrayMesh
	var mesh := ArrayMesh.new()
	var turned := 0
	var eyes: Array[Vector3] = []
	for offset in HEAD:
		eyes.append(item.transform.affine_inverse() * (SEAT + offset))
		if str(item.name) not in ["Shell", "Lead", "MirrorSeal"]:
			eyes.append(item.transform.affine_inverse() * (SEAT + offset + LIFT))
	for s in source.get_surface_count():
		var arrays := source.surface_get_arrays(s)
		if not held: turned += face_seat(item, arrays, eyes)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_name(s, source.surface_get_name(s))
		mesh.surface_set_material(s, room_material(source.surface_get_material(s), held, materials))
	item.mesh = mesh
	return turned

## Gives each seen back face its own vertices, wound and lit toward the viewer,
## which is how the double-sided material used to draw it.
func face_seat(item: MeshInstance3D, arrays: Array, eyes: Array[Vector3]) -> int:
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var to_room := item.transform
	var copies := PackedInt32Array()
	for t in index.size() / 3:
		var a := index[t * 3]; var b := index[t * 3 + 1]; var c := index[t * 3 + 2]
		var centre := (points[a] + points[b] + points[c]) / 3.
		var face := normals[a] + normals[b] + normals[c]
		var visible := false
		for eye in eyes:
			if face.dot(eye - centre) >= 0.: continue
			for corner in [centre, centre.lerp(points[a], .7), centre.lerp(points[b], .7), centre.lerp(points[c], .7)]:
				if seen(to_room * eye, to_room * Vector3(corner)):
					visible = true
					break
			if visible: break
		if not visible: continue
		var start := points.size() + copies.size()
		copies.append_array([a, c, b])
		index[t * 3] = start; index[t * 3 + 1] = start + 1; index[t * 3 + 2] = start + 2
	for slot in arrays.size():
		var data: Variant = arrays[slot]
		if slot == Mesh.ARRAY_INDEX or data == null or copies.is_empty(): continue
		if slot == Mesh.ARRAY_TANGENT:
			for v in copies: data.append_array([-data[v * 4], -data[v * 4 + 1], -data[v * 4 + 2], data[v * 4 + 3]])
		elif slot == Mesh.ARRAY_NORMAL:
			for v in copies: data.append(-normals[v])
		else:
			for v in copies: data.append(data[v])
		arrays[slot] = data
	arrays[Mesh.ARRAY_INDEX] = index
	return copies.size() / 3

func room_material(material: Material, held: bool, materials: Dictionary) -> Material:
	var base := material as BaseMaterial3D
	if base == null: return material
	var key := base.resource_name + ("/held" if held else "")
	if materials.has(key): return materials[key]
	if base.resource_name == "sheen":
		var sheen := ShaderMaterial.new()
		sheen.shader = SHEEN
		sheen.resource_name = "sheen"
		sheen.set_shader_parameter("lift", LIGHT_LIFT)
		materials[key] = sheen
		return sheen
	var copy := base.duplicate() as BaseMaterial3D
	copy.cull_mode = BaseMaterial3D.CULL_DISABLED if held else BaseMaterial3D.CULL_BACK
	copy.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# The importer turns this on for some materials only; every surface carries baked light now.
	copy.vertex_color_use_as_albedo = true
	var lift := srgb(EMBER_LIFT if copy.resource_name == "ember" else BREW_LIFT if copy.resource_name == "brew" else LIGHT_LIFT)
	copy.albedo_color = Color(copy.albedo_color.r * lift, copy.albedo_color.g * lift, copy.albedo_color.b * lift, copy.albedo_color.a)
	if TEXTURES.has(copy.resource_name): copy.albedo_texture = load(TEXTURES[copy.resource_name])
	materials[key] = copy
	return copy

## Material colours are sRGB; this is the value whose linear brightness is the given gain.
static func srgb(linear: float) -> float:
	return 1.055 * pow(linear, 1. / 2.4) - .055
