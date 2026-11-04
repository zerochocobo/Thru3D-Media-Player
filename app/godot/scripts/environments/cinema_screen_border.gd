extends MeshInstance3D
## Black border hugging a curved cinema picture. The hall's frame is baked flat on the wall, so a
## bent picture would otherwise float with bare edges in front of it. Lives in the picture panel's
## space and bends with the same arc (centre on the wall, edges towards the seats).

## As wide as the wall frame (SCREEN_FRAME in tools/cinema/build_hall.py).
const WIDTH := 0.22
## The hall's masking black (linear), so the border reads as part of the screen surround.
const COLOR := Color(0.0035, 0.0035, 0.004)
const COLUMNS := 48
var _key := Vector3.ZERO

func _init() -> void:
	name = "CinemaScreenBorder"
	visible = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = COLOR.linear_to_srgb()
	material_override = material

## Shows the border round a picture of [size] bent to [radius]; a flat picture (radius 0) hides it.
func update(size: Vector2, radius: float) -> void:
	visible = radius > 0.0 and size.x > 0.0 and size.y > 0.0
	if not visible: return
	var key := Vector3(size.x, size.y, radius)
	if key == _key: return
	_key = key
	mesh = build(size, radius)

static func build(size: Vector2, radius: float) -> ArrayMesh:
	var inner := size.x * 0.5 / radius
	var outer := inner + WIDTH / radius
	var top := size.y * 0.5
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_band(surface, radius, -outer, outer, top, top + WIDTH, COLUMNS)
	_band(surface, radius, -outer, outer, -top - WIDTH, -top, COLUMNS)
	_band(surface, radius, -outer, -inner, -top, top, 2)
	_band(surface, radius, inner, outer, -top, top, 2)
	return surface.commit()

static func _band(surface: SurfaceTool, radius: float, from: float, to: float, bottom: float, top: float, columns: int) -> void:
	for column in columns:
		var a := lerpf(from, to, float(column) / columns)
		var b := lerpf(from, to, float(column + 1) / columns)
		var corners := [at(radius, a, bottom), at(radius, b, bottom), at(radius, b, top), at(radius, a, top)]
		for index in [0, 1, 2, 0, 2, 3]: surface.add_vertex(corners[index])

## A point on the arc, matching the picture mesh (media_surface.gd _cylinder).
static func at(radius: float, angle: float, y: float) -> Vector3:
	return Vector3(sin(angle) * radius, y, (1.0 - cos(angle)) * radius)
