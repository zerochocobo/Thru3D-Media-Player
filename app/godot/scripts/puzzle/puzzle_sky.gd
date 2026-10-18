extends Node3D
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const BACKDROPS := ["night","slate","light"]
var reference: MeshInstance3D
var guide: MeshInstance3D
var background: MeshInstance3D

func configure(source: Dictionary, grid: Vector2i, seed_value: int = 731) -> void:
	var mesh := inside_mesh(1.0,64,32)
	background=MeshInstance3D.new(); background.mesh=mesh; add_child(background)
	background.scale=Vector3.ONE*(Sphere.RADIUS+0.16)
	var material := ShaderMaterial.new(); material.shader=preload("res://shaders/puzzle_sky.gdshader"); background.material_override=material
	reference=MeshInstance3D.new(); reference.mesh=mesh; reference.scale=Vector3.ONE*(Sphere.RADIUS+0.075); add_child(reference)
	var photo := ShaderMaterial.new(); photo.shader=preload("res://shaders/puzzle_sky_reference.gdshader")
	photo.set_shader_parameter("image_texture",source.texture); reference.material_override=photo; reference.visible=false
	guide=MeshInstance3D.new(); add_child(guide)
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var seen := {}
	for y in grid.y:
		for x in grid.x:
			var contour := Sphere.outline(Vector2i(x,y),grid,seed_value)
			for i in contour.size():
				var a := contour[i]; var b := contour[(i+1)%contour.size()]
				var key_a := Sphere._key(a); var key_b := Sphere._key(b)
				var key := key_a+"/"+key_b if key_a<key_b else key_b+"/"+key_a
				if seen.has(key): continue
				seen[key]=true
				var mid := (a+b).normalized()
				for p in [a,mid,mid,b]: vertices.append(p*(Sphere.RADIUS+0.055))
	arrays[Mesh.ARRAY_VERTEX]=vertices
	var lines := ArrayMesh.new(); lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES,arrays); guide.mesh=lines
	var ink := StandardMaterial3D.new(); ink.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	guide.material_override=ink; set_backdrop("night")

static func inside_mesh(radius: float, columns: int, rows: int) -> ArrayMesh:
	# The media sphere is used with a two-sided shader; this game culls its outside.
	var arrays := Geometry.hemisphere(radius,columns,rows,TAU).surface_get_arrays(0)
	var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
	for i in range(0,indices.size(),3):
		var value := indices[i+1]; indices[i+1]=indices[i+2]; indices[i+2]=value
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays); return mesh

func set_backdrop(value: String) -> void:
	background.material_override.set_shader_parameter("backdrop",BACKDROPS.find(value))
	guide.material_override.albedo_color=Color(0.15,0.20,0.23) if value=="light" else Color(0.18,0.25,0.29)

func set_view(basis: Basis) -> void:
	reference.basis=basis.scaled(Vector3.ONE*(Sphere.RADIUS+0.075)); guide.basis=basis

func dim(value: float) -> void:
	reference.material_override.set_shader_parameter("turn_light",value)
	guide.visible=value>0.5
