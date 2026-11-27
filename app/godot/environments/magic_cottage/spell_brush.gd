extends Node3D
## All strokes of one shape share a single XR draw, including across both hands.
enum { JEWEL, ROD, RING, PAPER, BELL, MEMBRANE, GLOW }
const LIMITS := [320, 384, 72, 96, 8, 96, 96]
var batches: Array[MultiMesh] = []
var counts := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
var inks: Array[ShaderMaterial] = []

func set_room_light(level: float) -> void:
	for ink in inks: ink.set_shader_parameter("room_light",level)

func _ready() -> void:
	var crystal := SphereMesh.new()
	crystal.radius = 1.
	crystal.height = 2.
	crystal.radial_segments = 10
	crystal.rings = 3
	var rod := CylinderMesh.new()
	rod.top_radius = 1.
	rod.bottom_radius = 1.
	rod.height = 1.
	rod.radial_segments = 6
	rod.rings = 0
	var ring := TorusMesh.new()
	ring.inner_radius = .90
	ring.outer_radius = 1.
	ring.rings = 32
	ring.ring_segments = 6
	var page := BoxMesh.new()
	page.size = Vector3(1., 1., .07)
	var material := ShaderMaterial.new()
	material.shader = preload("spell_ink.gdshader")
	var triangle := SurfaceTool.new()
	triangle.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vertex in [Vector3.ZERO,Vector3.RIGHT,Vector3.UP]:
		triangle.set_normal(Vector3.BACK)
		triangle.add_vertex(vertex)
	var haze := ShaderMaterial.new()
	haze.shader = preload("spell_glow.gdshader")
	inks.assign([material,haze])
	for shape in [crystal, rod, ring, page, bell_mesh(), triangle.commit(), QuadMesh.new()]:
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = true
		batch.mesh = shape
		batch.instance_count = LIMITS[batches.size()]
		batch.visible_instance_count = 0
		batch.custom_aabb = AABB(Vector3(-7., -2., -8.), Vector3(14., 10., 14.))
		var node := MultiMeshInstance3D.new()
		node.multimesh = batch
		node.material_override = haze if batches.size()==GLOW else material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		batches.append(batch)

func bell_mesh() -> ArrayMesh:
	var profile := [Vector2(.14,.88),Vector2(.46,.75),Vector2(.53,.24),Vector2(.69,-.24),Vector2(.9,-.47),Vector2(.78,-.48),Vector2(.47,.04)]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in range(profile.size()-1):
		for side in 16:
			for corner: Vector2i in [Vector2i(0,0),Vector2i(1,0),Vector2i(0,1),Vector2i(1,0),Vector2i(1,1),Vector2i(0,1)]:
				var p: Vector2 = profile[row+corner.x]
				var angle := TAU*(side+corner.y)/16.
				surface.add_vertex(Vector3(p.x*cos(angle),p.y,p.x*sin(angle)))
	surface.generate_normals()
	return surface.commit()

func begin() -> void:
	counts.fill(0)

func finish() -> void:
	for i in batches.size():
		batches[i].visible_instance_count = counts[i]

func form(kind: int, p: Vector3, axes: Basis, size: Vector3, color: Color) -> void:
	var index := counts[kind]
	if index >= LIMITS[kind]: return
	batches[kind].set_instance_transform(index, Transform3D(axes.scaled_local(size), p))
	batches[kind].set_instance_color(index, color)
	counts[kind] += 1

func jewel(p: Vector3, scale_xyz: Vector3, color: Color, axes := Basis.IDENTITY) -> void:
	form(JEWEL, p, axes, scale_xyz, color)

func bead(p: Vector3, radius: float, color: Color) -> void:
	jewel(p, Vector3.ONE*radius, color)

func line(a: Vector3, b: Vector3, width: float, color: Color) -> void:
	var d := b-a
	var length := d.length()
	if length < .0001: return
	form(ROD, (a+b)*.5, Basis(Quaternion(Vector3.UP,d/length)), Vector3(width,length,width), color)

func hoop(p: Vector3, normal: Vector3, radius: float, color: Color) -> void:
	form(RING, p, Basis(Quaternion(Vector3.UP,normal)), Vector3.ONE*radius, color)

func wing(a: Vector3,b: Vector3,c: Vector3,color: Color) -> void:
	var normal := (b-a).cross(c-a)
	if normal.length_squared()>.00000001:
		form(MEMBRANE,a,Basis(b-a,c-a,normal.normalized()),Vector3.ONE,color)

func halo(p: Vector3,diameter: float,color: Color) -> void:
	form(GLOW,p,Basis.IDENTITY,Vector3.ONE*diameter,color)
