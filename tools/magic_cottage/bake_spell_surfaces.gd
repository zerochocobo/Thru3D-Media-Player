extends SceneTree
## Bake spatial picking from the shipped room so a VR trigger never builds a triangle tree.
const Surfaces := preload("res://environments/magic_cottage/spell_surfaces.gd")
const ROOM := "res://environments/magic_cottage/workshop.res"
const DEST := "res://environments/magic_cottage/spell_surfaces.res"

class Builder:
	var boxes: Array[AABB] = []
	var escape := PackedInt32Array()
	var first := PackedInt32Array()
	var count := PackedInt32Array()
	var vertices := PackedVector3Array()
	var source: PackedVector3Array
	var centers := PackedVector3Array()

	func divide(indices: Array) -> void:
		var box := AABB(source[indices[0]],Vector3.ZERO)
		for face: int in indices:
			for i in 3: box=box.expand(source[face+i])
		var slot := boxes.size()
		boxes.append(box.grow(.0001))
		escape.append(0)
		first.append(vertices.size())
		count.append(0)
		if indices.size()<=12:
			count[slot]=indices.size()*3
			for face: int in indices:
				for i in 3: vertices.append(source[face+i])
		else:
			var axis := box.get_longest_axis_index()
			indices.sort_custom(func(a: int,b: int): return centers[a/3][axis]<centers[b/3][axis])
			var middle := indices.size()/2
			divide(indices.slice(0,middle))
			divide(indices.slice(middle))
		escape[slot]=boxes.size()

	func bake(mesh: Mesh) -> Dictionary:
		source=mesh.get_faces()
		var indices := []
		for i in range(0,source.size(),3):
			indices.append(i)
			centers.append((source[i]+source[i+1]+source[i+2])/3.)
		divide(indices)
		return {"boxes":boxes,"escape":escape,"first":first,"count":count,"vertices":vertices}

func _initialize() -> void:
	var room: Node3D = load(ROOM).instantiate()
	var data := Surfaces.new()
	for item: MeshInstance3D in room.get_children():
		data.groups[item.name]=Builder.new().bake(item.mesh)
	var error := ResourceSaver.save(data,DEST,ResourceSaver.FLAG_COMPRESS)
	print("Workshop picking ",data.groups.size()," meshes, ",error_string(error))
	room.free()
	quit(error)
