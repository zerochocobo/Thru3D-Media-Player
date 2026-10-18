extends MeshInstance3D
const SHADER := preload("res://shaders/puzzle_piece.gdshader")
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
var piece_id := -1
var goal := Transform3D.IDENTITY
var base_goal := Transform3D.IDENTITY
var parked := Transform3D.IDENTITY
var parked_turn := 0.0
var tray_visible := true
var returning := false
var rotation_initialized := false
var placed := false
var width := 0.25
var triangles := PackedVector3Array()
var content_kind := "flat"
var turn_angle := 0.0
var motion: Tween

func configure(id: int, geometry: Dictionary, source: Dictionary) -> void:
	piece_id = id; mesh = geometry.mesh; triangles = geometry.triangles
	width = float(geometry.get("width",0.25)); content_kind = str(source.get("kind","flat"))
	var material := ShaderMaterial.new(); material.shader = SHADER
	material.set_shader_parameter("image_texture",source.texture)
	material.set_shader_parameter("panorama_texture",source.texture)
	material.set_shader_parameter("panorama",source.get("projection","flat")=="sphere")
	if geometry.has("face"):
		material.set_shader_parameter("cube_centre",Sphere.CENTRES[int(geometry.face)])
		material.set_shader_parameter("cube_right",Sphere.RIGHTS[int(geometry.face)])
		material.set_shader_parameter("cube_up",Sphere.UPS[int(geometry.face)])
	material.set_shader_parameter("stereo_layout",int(source.get("layout",0)))
	material.set_shader_parameter("swap_eyes",bool(source.get("swap_eyes",false)))
	material.set_shader_parameter("spatial_disparity",float(source.get("spatial_disparity",0)))
	material_override = material

func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if placed or not visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.1: return {}
	var inverse := global_transform.affine_inverse()
	var start: Vector3 = inverse * origin
	var ray: Vector3 = (inverse.basis * direction).normalized()
	if mesh.get_aabb().grow(0.002).intersects_ray(start,ray) == null: return {}
	var nearest := INF
	var hit := Vector3.ZERO
	for i in range(0,triangles.size(),3):
		var point: Variant = Geometry3D.ray_intersects_triangle(start,ray,triangles[i],triangles[i+1],triangles[i+2])
		if point == null: continue
		var world_point: Vector3 = global_transform * point
		var distance := origin.distance_to(world_point)
		if distance < nearest:
			nearest = distance; hit = world_point
	return {"piece":self,"point":hit,"distance":nearest} if nearest < INF else {}

func settle() -> void:
	placed = true; turn_angle=0.0; returning=false
	if motion != null and motion.is_valid(): motion.kill()
	motion = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	motion.tween_property(self,"transform",goal,0.14)

func stop_motion() -> void:
	if motion != null and motion.is_valid(): motion.kill()
	returning=false

func return_to_tray(animate: bool = true) -> void:
	stop_motion()
	parked.basis=parked.basis*Basis(Vector3.BACK,turn_angle-parked_turn)
	parked_turn=turn_angle
	if not animate: transform=parked; return
	returning=true
	motion=create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	motion.tween_property(self,"transform",parked,0.16)
	motion.tween_callback(func(): returning=false)
