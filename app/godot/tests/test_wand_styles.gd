extends SceneTree
## The modelled wands (2026-11-28): five styles chosen in the Wizard's Attic scene settings and in the
## reading settings. While the attic is on show a book read there uses the attic's wand, and choosing
## a wand from the book changes the attic's setting rather than the book's.
const Wand := preload("res://scripts/book_wand.gd")
const BookReader := preload("res://scripts/book_reader.gd")
const Workshop := preload("res://environments/magic_cottage/workshop.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: run.call_deferred()

## Normals point out of the shaft and every triangle faces the way its normals do (Godot's front faces
## wind clockwise). The first bake wound them inwards, so only the inside of the far wall was drawn.
func _check_solid(mesh: Mesh, style: String) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var rings := {}
	for point in points:
		var key := roundi(point.z * 2000.0)
		var ring: Array = rings.get(key, [Vector3.ZERO, 0])
		rings[key] = [ring[0] + point, ring[1] + 1]
	var outward := 0
	for i in points.size():
		var ring: Array = rings[roundi(points[i].z * 2000.0)]
		var away: Vector3 = points[i] - ring[0] / float(ring[1])
		away.z = 0.0
		if away.length() < 1e-5 or normals[i].dot(away) > 0.0: outward += 1
	var facing := 0
	for t in range(0, indices.size(), 3):
		var a := points[indices[t]]
		var winding := (points[indices[t + 1]] - a).cross(points[indices[t + 2]] - a)
		if winding.dot(normals[indices[t]] + normals[indices[t + 1]] + normals[indices[t + 2]]) < 0.0: facing += 1
	check(outward > points.size() * .98, style + " has its normals on the outside")
	check(facing > indices.size() / 3 * .98, style + " faces the way its normals do, so the outside is drawn")

func run() -> void:
	var wand := Wand.new()
	root.add_child(wand)
	check(wand.style == Wand.DEFAULT_STYLE and Wand.STYLES.size() == 5, "a new wand is the walnut one of five")
	for style in Wand.STYLES:
		wand.set_style(style)
		var body: MeshInstance3D = wand._body
		var box := body.mesh.get_aabb() if body.mesh else AABB()
		check(body.mesh != null and absf(box.position.z + Wand.LENGTH) < .002 and absf(box.end.z) < .002, style + " runs from the hand to the tip")
		check(Wand.picture(style) != null and Wand.NAMES.has(style), style + " has a menu picture and a name")
		if body.mesh: _check_solid(body.mesh, style)
	check(Wand.valid_style("sparkly") == Wand.DEFAULT_STYLE, "an unknown setting falls back to walnut")
	check(wand.tip.position.is_equal_approx(Vector3(0, 0, -Wand.LENGTH)), "spells still leave from the tip")

	var settings := ConfigFile.new()
	settings.set_value("book", "wand", "ash")
	var reader := BookReader.new()
	root.add_child(reader)
	reader.restore_settings(settings)
	check(reader.wand.style == "ash" and reader.shown_wand() == "ash", "the reading wand comes back from settings")
	var chosen: Array = []
	reader.scene_wand_chosen.connect(func(style: String): chosen.append(style))
	reader.set_scene_wand("ebony")
	check(reader.wand.style == "ebony", "in the attic the book uses the attic's wand")
	reader.set_wand("gnarled")
	check(chosen == ["gnarled"] and reader.wand.style == "gnarled" and reader.wand_style == "ash" and str(settings.get_value("book", "wand")) == "ash",
		"choosing in the attic changes the attic's wand and leaves the book's")
	reader.set_scene_wand("")
	check(reader.wand.style == "ash", "leaving the attic gives the book its own wand back")
	reader.set_wand("rosewood")
	check(chosen.size() == 1 and reader.wand.style == "rosewood" and str(settings.get_value("book", "wand")) == "rosewood", "outside the attic the book's own wand is chosen and saved")

	var room := Workshop.new()
	room.archive.directory = ""
	room.wand_style = "ebony"
	root.add_child(room)
	check(room.wands.values().all(func(each): return each.style == "ebony"), "the attic's wands start in its chosen style")
	room.set_wand_style("gnarled")
	check(room.wands.values().all(func(each): return each.style == "gnarled"), "changing the attic's wand changes both hands")
	room.set_wand_style("nonsense")
	check(room.wand_style == Wand.DEFAULT_STYLE, "an unknown attic setting falls back to walnut")
	for item in [wand, reader, room]: item.queue_free()
	await process_frame
	print("Wand styles: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: ", failure)
	quit(1 if failures else 0)
