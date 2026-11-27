extends Resource
## Depth-first bounds over the exact Blender triangles. Escape indices skip whole subtrees.
@export var groups: Dictionary = {}

func nearest(id: StringName, origin: Vector3, direction: Vector3, reach: float) -> Dictionary:
	var group: Dictionary = groups[id]
	var boxes: Array = group.boxes
	var escape: PackedInt32Array = group.escape
	var first: PackedInt32Array = group.first
	var count: PackedInt32Array = group.count
	var vertices: PackedVector3Array = group.vertices
	var closest := reach
	var result := {}
	var i := 0
	while i < boxes.size():
		var box: AABB = boxes[i]
		if box.intersects_segment(origin,origin+direction*closest)==null:
			i = escape[i]
			continue
		for k in range(first[i],first[i]+count[i],3):
			var p: Variant = Geometry3D.ray_intersects_triangle(origin,direction,vertices[k],vertices[k+1],vertices[k+2])
			if p==null: continue
			var distance := (Vector3(p)-origin).dot(direction)
			if distance < .02 or distance >= closest: continue
			closest = distance
			var normal := (vertices[k+1]-vertices[k]).cross(vertices[k+2]-vertices[k]).normalized()
			result = {"position":p,"normal":normal}
		i += 1
	return result
