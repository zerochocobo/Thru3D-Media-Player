extends SceneTree
const Sphere := preload("res://scripts/puzzle/puzzle_sphere.gd")
const Session := preload("res://scripts/puzzle/puzzle_session.gd")
const Store := preload("res://scripts/puzzle/puzzle_store.gd")
var checks := 0
var failures: Array[String]=[]
var output := ProjectSettings.globalize_path("res://../../build/output/puzzle-p2/core-")+str(Time.get_ticks_usec())
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message); push_error(message)
func key(p: Vector3) -> String: return "%d,%d,%d" % [roundi(p.x*100000),roundi(p.y*100000),roundi(p.z*100000)]
func edge_key(a: Vector3,b: Vector3) -> String:
	var ka := key(a); var kb := key(b)
	return ka+"/"+kb if ka<kb else kb+"/"+ka
func verify_patch(result: Dictionary) -> Dictionary:
	var data: Array=result.mesh.surface_get_arrays(0)
	var v: PackedVector3Array=data[Mesh.ARRAY_VERTEX]; var n: PackedVector3Array=data[Mesh.ARRAY_NORMAL]; var c: PackedColorArray=data[Mesh.ARRAY_COLOR]
	var uv: PackedVector2Array=data[Mesh.ARRAY_TEX_UV]
	var finite := true; var clockwise := true; var radii := true; var facing := true; var directions := true
	var edges := {}; var area := 0.0
	for i in range(0,v.size(),3):
		clockwise=clockwise and (v[i+1]-v[i]).cross(v[i+2]-v[i]).dot(n[i])<0
		for j in 3:
			finite=finite and v[i+j].is_finite()
			var e := edge_key(v[i+j],v[i+(j+1)%3]); edges[e]=int(edges.get(e,0))+1
			var root_point: Vector3=result.goal*v[i+j]
			var encoded := Sphere.point(int(result.face),uv[i+j])
			directions=directions and encoded.normalized().distance_to(root_point.normalized())<0.00001
			var r := root_point.length()
			radii=radii and (absf(r-Sphere.RADIUS)<0.00001 or absf(r-Sphere.RADIUS-Sphere.THICKNESS)<0.00001)
		if c[i].a>0.5:
			var a: Vector3=(result.goal*v[i]).normalized(); var b: Vector3=(result.goal*v[i+1]).normalized(); var d: Vector3=(result.goal*v[i+2]).normalized()
			area+=2*atan2(absf(a.dot(b.cross(d))),1+a.dot(b)+b.dot(d)+d.dot(a))
			facing=facing and (result.goal.basis*n[i]).dot(a)<-0.95
	var closed := edges.values().all(func(count):return count==2)
	if not (finite and clockwise and radii and facing and directions and closed): print("Patch details ",[finite,clockwise,radii,facing,directions,closed])
	return {"solid":finite and clockwise and radii and facing and directions and closed,"area":area}
func _run() -> void:
	var grid := Vector2i(12,2); var boundaries := {}; var area := 0.0; var areas := []
	for y in grid.y:
		for x in grid.x:
			var result := Sphere.patch(Vector2i(x,y),grid)
			var verified := verify_patch(result); area+=float(verified.area); areas.append(verified.area)
			check(verified.solid,"Cube patch %d,%d is closed, thick, inward-facing, finite and correctly encoded" % [x,y])
			for i in result.outline3d.size():
				var e := edge_key(result.outline3d[i],result.outline3d[(i+1)%result.outline3d.size()]); boundaries[e]=int(boundaries.get(e,0))+1
	check(absf(area-4*PI)<0.00005,"All 24 inner patches cover the complete sphere exactly once")
	check(boundaries.values().all(func(count):return count==2),"All face and intra-face edges meet, including seam and poles")
	check(float(areas.max())/float(areas.min())<1.8,"Tabbed polar patches retain comparable area to horizon patches")
	var profile := Sphere.joint_profile(); var reentrant := false; var bulge := 0.0
	for i in range(1,profile.size()):
		reentrant=reentrant or profile[i].x<profile[i-1].x; bulge=maxf(bulge,profile[i].y)
	check(reentrant and bulge>0.17,"Traditional joints have rounded heads and re-entrant narrow necks, rather than simple bumps")
	var edge_a := Sphere.edge(Vector3.FORWARD,Vector3.RIGHT,731)
	var edge_b := Sphere.edge(Vector3.RIGHT,Vector3.FORWARD,731); edge_b.reverse()
	check(edge_a==edge_b,"Opposite traversals share exactly the same tab and socket samples")
	check(Sphere.outline(Vector2i.ZERO,grid,731)!=Sphere.outline(Vector2i.ZERO,grid,732),"Saved seeds deterministically regenerate different joint layouts")
	var variants_ok := true
	for seed_id in [1,732,2147483647]:
		for face in 6:
			var variant := Sphere.patch(Vector2i(face,0),Vector2i(6,1),false,seed_id)
			variants_ok=variants_ok and not variant.is_empty() and verify_patch(variant).solid
	check(variants_ok,"Coarse six-piece shells remain closed and correctly faced for different joint seeds")
	var dense_grid := Vector2i(18,3); var dense_ok := true; var dense_area := 0.0; var dense_edges := {}
	for y in dense_grid.y:
		for x in dense_grid.x:
			var patch := Sphere.patch(Vector2i(x,y),dense_grid)
			var verified := verify_patch(patch); dense_ok=dense_ok and verified.solid; dense_area+=float(verified.area)
			for i in patch.outline3d.size():
				var e := edge_key(patch.outline3d[i],patch.outline3d[(i+1)%patch.outline3d.size()]); dense_edges[e]=int(dense_edges.get(e,0))+1
	check(dense_ok,"54-piece difficulty retains thick closed traditional joints with correct facing")
	check(absf(dense_area-4*PI)<0.00005,"54-piece difficulty covers the sky once without polar holes")
	check(dense_edges.values().all(func(count):return count==2),"54-piece joints match across all cube-face seams")
	var cpu := Sphere.patch(Vector2i.ZERO,grid,true)
	check(cpu.has("arrays") and not cpu.has("mesh"),"Background preparation returns CPU arrays without renderer resources")
	check(Sphere.patch(Vector2i.ZERO,Vector2i(4,3)).is_empty(),"A flat grid cannot be interpreted as cube-sphere pieces")
	for face in 6: check((Sphere.view_basis(face)*Sphere.CENTRES[face]).distance_to(Vector3.FORWARD)<0.00001,"Sky sector %d can be brought to the front" % face)
	var image := Image.create(256,128,false,Image.FORMAT_RGBA8); image.fill(Color(0.2,0.55,0.7))
	var source := {"image":image,"texture":ImageTexture.create_from_image(image),"size":Vector2(256,128),"uri":"fixture://full-panorama","title":"360.png","projection":"sphere"}
	var session := Session.new(); root.add_child(session)
	check(session.configure(source,grid,7489),"Production session configures a full inner panorama")
	check(session.spherical and session.sky!=null and session.pieces.size()==24,"Full dome environment and 24 thick pieces are present")
	check(session.pieces.filter(func(p):return p.visible).size()==12,"Seated panorama exposes 12 compact front pieces")
	session.set_posture(true)
	check(session.pieces.filter(func(p):return p.visible).size()==16,"Standing panorama exposes 16 surrounding pieces")
	session.set_posture(false)
	var piece: MeshInstance3D=session.pieces.filter(func(p):return p.visible)[0]
	for other in session.pieces:
		if other!=piece: other.visible=false
	piece.transform=Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*0.14),Vector3(0,-0.2,-1.1))
	check(session.grab("hand",Vector3.ZERO,piece.position.normalized()),"Ray can acquire a scaled curved tray piece from inside")
	var capture: Dictionary=session.captures.hand
	var target: Vector3=piece.goal*capture.anchor
	var moved_eye := Vector3(0.18,0.08,0.04)
	session.update_grab("hand",moved_eye,(target-moved_eye).normalized())
	check(session.can_snap(piece) and session.hint.visible,"Ray delivery from an offset eye previews the correct sky slot")
	check(session.release("hand"),"Release magnetically commits an inner-to-outer placement")
	await piece.motion.finished
	check(piece.transform.is_equal_approx(piece.goal) and session.completed()==1,"Placement restores exact full-scale shell coordinates")
	var done := piece.transform
	session.set_posture(true)
	check(piece.transform==done and piece.visible,"Posture switch preserves the completed sky patch")
	session.set_view_face(4)
	await session.turn_tween.finished
	check(piece.transform==piece.goal and piece.goal!=done and not session.turning,"Sky turn moves solved geometry with the target and completes the fade")
	check(session.sky.background.basis.orthonormalized()==Basis.IDENTITY,"The backdrop remains stable when the photo sky turns")
	session.cycle_backdrop(); session.cycle_backdrop()
	var snapshot: Dictionary=session.snapshot()
	check(snapshot.projection=="sphere" and snapshot.view_face==4 and snapshot.backdrop=="light","Sphere model, sky orientation and backdrop are checkpointed")
	var store := Store.new(output); var descriptor := store.cache_source(source)
	var id := store.create_game(descriptor,snapshot)
	check(not id.is_empty() and store.unfinished().size()==1,"Panorama uses the same independent global game store")
	var restored_source := store.load_source(Store.new(output).get_game(id).source)
	var restored := Session.new(); root.add_child(restored); restored.configure(restored_source,grid,7489)
	check(restored.restore(store.get_game(id).snapshot) and restored.completed()==1,"A fresh session resumes the panorama progress")
	check(restored.pieces[0].triangles==session.pieces[0].triangles,"Saved non-default seeds restore the identical physical joints")
	check(restored.view_face==4 and restored.backdrop=="light" and restored.pieces[piece.piece_id].transform==restored.pieces[piece.piece_id].goal,"Restored completed patches agree with restored turned sky")
	var wrong := snapshot.duplicate(true); wrong.projection="flat"
	check(not store.save_game(id,wrong) and not restored.restore(wrong),"Projection mismatch cannot overwrite or reinterpret a panorama")
	var old_flat := Session.new(); root.add_child(old_flat)
	var flat_source := source.duplicate(); flat_source.erase("projection"); old_flat.configure(flat_source)
	var old_state: Dictionary=old_flat.snapshot(); old_state.erase("projection"); old_state.erase("view_face"); old_state.erase("backdrop")
	check(old_flat.restore(old_state),"Existing P1 checkpoints without sphere fields still restore as flat puzzles")
	var loose: MeshInstance3D=restored.pieces.filter(func(p):return not p.placed)[0]
	loose.transform=restored.pieces[piece.piece_id].goal
	check(not restored.can_snap(loose),"A wrong panorama piece cannot occupy another patch's slot")
	loose.transform=loose.goal; loose.scale=Vector3.ONE*0.2
	check(not restored.can_snap(loose),"A thumbnail-sized patch cannot count as a completed shell")
	for other in restored.pieces: other.visible=other==loose
	loose.transform=loose.goal
	restored.grab("hand",Vector3.ZERO,loose.position.normalized())
	restored.update_grab("hand",Vector3.ZERO,loose.goal.origin.normalized())
	restored.update_grab("hand",Vector3(2.48,0,0),Vector3.FORWARD)
	check(not restored.release("hand") and not loose.placed,"Invalid latest ray cannot commit a previously valid spherical candidate")
	restored.grab("hand",Vector3.ZERO,loose.position.normalized())
	restored.update_grab("hand",Vector3.ZERO,loose.goal.origin.normalized()); restored.cancel("hand")
	check(not restored.release("hand") and restored.completed()==1,"Tracking cancellation at a correct spherical slot does not commit")
	check(Sphere.ray_surface(Vector3(2.48,0,0),Vector3.FORWARD)==null,"Near-wall rays do not throw pieces beyond the valid inner workspace")
	check(store.delete_game(id) and not store.save_game(id,snapshot),"Deleting a panorama blocks late saves as for flat games")
	check(store.undo_delete() and store.get_game(id).source.projection=="sphere","Undo preserves the panorama source type")
	session.queue_free(); restored.queue_free(); old_flat.queue_free(); await process_frame
	print("Puzzle panorama: %d checks, %d failures" % [checks,failures.size()]); quit(0 if failures.is_empty() else 1)
