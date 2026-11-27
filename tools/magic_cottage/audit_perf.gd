extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _mesh_stats(m: Mesh) -> Dictionary:
	if m == null:
		return {"surfaces": 0, "verts": 0, "tris": 0}
	var verts := 0
	var tris := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		verts += v.size()
		if arr[Mesh.ARRAY_INDEX] != null and (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() > 0:
			tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		else:
			tris += v.size() / 3
	return {"surfaces": m.get_surface_count(), "verts": verts, "tris": tris}

func _run() -> void:
	var root_vp := get_root()
	root_vp.size = Vector2i(1680, 1760)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.15, 1.82)
	root_vp.add_child(cam)
	cam.current = true

	# main.gd preloads the room script at startup, so entry cost excludes compiling it.
	var Workshop := load("res://environments/magic_cottage/workshop.gd")
	var t0 := Time.get_ticks_usec()
	var cottage: Node3D = Workshop.new()
	var args := OS.get_cmdline_user_args()
	cottage.archive.directory = args[0] if args.size() > 0 else OS.get_temp_dir().path_join("cottage-audit")
	root_vp.add_child(cottage)
	var t_ready := Time.get_ticks_usec() - t0
	print("=== INIT COST ===")
	print("workshop._ready() usec: ", t_ready)

	print("\n=== WORKSHOP.RES MESH BREAKDOWN ===")
	var total_verts := 0
	var total_tris := 0
	var total_surfaces := 0
	var tex_seen := {}
	for child in cottage.models.get_children():
		if child is MeshInstance3D:
			var st := _mesh_stats(child.mesh)
			total_verts += st.verts
			total_tris += st.tris
			total_surfaces += st.surfaces
			print("Node %-12s surfaces=%d verts=%6d tris=%6d cast_shadow=%d" % [child.name, st.surfaces, st.verts, st.tris, child.cast_shadow])
			for s in child.mesh.get_surface_count():
				var mat: Material = child.get_active_material(s)
				if mat is BaseMaterial3D:
					var bm := mat as BaseMaterial3D
					if s == 0 or child.name == "Shell":
						print("   mat[%d] name=%s shading=%d cull=%d transp=%d tex=%s" % [
							s, bm.resource_name, bm.shading_mode, bm.cull_mode, bm.transparency,
							str(bm.albedo_texture.get_size() if bm.albedo_texture else Vector2i.ZERO)
						])
					if bm.albedo_texture and not tex_seen.has(bm.albedo_texture.get_rid()):
						var img := bm.albedo_texture.get_image()
						tex_seen[bm.albedo_texture.get_rid()] = true
						print("   TEX: class=%s size=%s mipmaps=%s fmt=%s" % [
							bm.albedo_texture.get_class(),
							str(bm.albedo_texture.get_size()),
							str(img.has_mipmaps() if img else false),
							str(img.get_format() if img else -1)
						])
	print("TOTAL workshop.res: nodes=%d surfaces=%d verts=%d tris=%d unique_duplicated_mats=%d" % [
		cottage.models.get_child_count(), total_surfaces, total_verts, total_tris, cottage.room_materials.size()
	])

	print("\n=== OTHER ASSETS ===")
	for p in ["res://environments/magic_cottage/star-atlas.jpg", "res://environments/magic_cottage/ingredients.png"]:
		var tx: Texture2D = load(p)
		var im := tx.get_image()
		print("Tex %s class=%s size=%s mipmaps=%s fmt=%d" % [p, tx.get_class(), str(tx.get_size()), str(im.has_mipmaps() if im else false), im.get_format() if im else -1])

	var ivy_mesh: Mesh = load("res://environments/magic_cottage/wall_ivy.res")
	print("wall_ivy.res: ", _mesh_stats(ivy_mesh))

	var props_lib: MeshLibrary = load("res://environments/magic_cottage/apparition_props.res")
	for id in props_lib.get_item_list():
		print("apparition_props[%d]: %s" % [id, str(_mesh_stats(props_lib.get_item_mesh(id)))])

	print("\n=== FLORA MESH STATS ===")
	for sp in 10:
		var lib: MeshLibrary = load("res://environments/magic_cottage/flora/species-%02d.res" % sp)
		var s0 := _mesh_stats(lib.get_item_mesh(0))
		var s1 := _mesh_stats(lib.get_item_mesh(1))
		var s2 := _mesh_stats(lib.get_item_mesh(2))
		print("species-%02d: stage0=%d tris | stage1=%d tris | stage2=%d tris (verts=%d)" % [sp, s0.tris, s1.tris, s2.tris, s2.verts])

	print("\n=== SPELL SURFACES BVH STATS ===")
	var bvh_boxes := 0
	var bvh_verts := 0
	for k in cottage.spell_surfaces.groups:
		var g: Dictionary = cottage.spell_surfaces.groups[k]
		bvh_boxes += (g.boxes as Array).size()
		bvh_verts += (g.vertices as PackedVector3Array).size()
		print("BVH %-12s boxes=%5d tris=%5d" % [str(k), (g.boxes as Array).size(), (g.vertices as PackedVector3Array).size() / 3])
	print("BVH TOTAL boxes=%d tris=%d" % [bvh_boxes, bvh_verts / 3])

	print("\n=== CPU MICROBENCHMARKS ===")
	var pose := Transform3D(Basis.IDENTITY, Vector3(0, 1.15, 1.82))
	cottage.align_to(pose)

	# 1. Idle tick + dual hand aim
	var ray_l := [Vector3(-0.25, 1.0, 1.6), Vector3(-0.5, 0.1, -0.86).normalized()]
	var ray_r := [Vector3(0.25, 1.0, 1.6), Vector3(0.5, 0.1, -0.86).normalized()]
	var t1 := Time.get_ticks_usec()
	for i in 1000:
		cottage.tick(1.0 / 72.0, i * 14, pose)
		cottage.aim("left_hand", ray_l, 1.0 / 72.0)
		cottage.aim("right_hand", ray_r, 1.0 / 72.0)
	print("Idle tick + 2x aim avg usec: %.2f" % ((Time.get_ticks_usec() - t1) / 1000.0))

	# 2. fade_lights per-frame cost while dimming
	var t_fade := Time.get_ticks_usec()
	for i in 200:
		cottage.light_fraction = 1.0 if (i % 2 == 0) else 0.5
		cottage.fade_lights(0.25, 1.0 / 72.0)
	print("fade_lights (apply_room_light) avg usec: %.2f" % ((Time.get_ticks_usec() - t_fade) / 200.0))

	# 3. Book open + page turn + rebuild
	var t_book_open := Time.get_ticks_usec()
	cottage.volume.open("Herbal", pose, 10000)
	print("folio.open('Herbal') first open usec: ", Time.get_ticks_usec() - t_book_open)
	cottage.archive.herbs = {0:true, 1:true, 2:true, 3:true, 4:true, 5:true}
	var t_book_rebuild := Time.get_ticks_usec()
	cottage.volume.rebuild(10000)
	print("folio.rebuild('Herbal' with specimen) usec: ", Time.get_ticks_usec() - t_book_rebuild)
	var t_lift := Time.get_ticks_usec()
	cottage.volume.lift(1, "right_hand", true)
	print("folio.lift() second Spread alloc+paint usec: ", Time.get_ticks_usec() - t_lift)
	var t_turn := Time.get_ticks_usec()
	for i in 200:
		cottage.volume.model.turn(clampf(float(i % 98 + 1) / 100.0, 0.02, 0.98))
	print("book_model.turn() mesh regen avg usec: %.2f" % ((Time.get_ticks_usec() - t_turn) / 200.0))
	cottage.volume.close()
	var t_reopen := Time.get_ticks_usec()
	cottage.volume.open("Atlas", pose, 10000)
	print("folio.open('Atlas') after closing usec: ", Time.get_ticks_usec() - t_reopen)
	cottage.volume.close()

	# 4. Each room apparition step cost & MultiMesh instance counts
	cottage.display_spell(0)
	for sp_id in 10:
		cottage.display_spell(sp_id)
		var t_sp := Time.get_ticks_usec()
		for i in 200:
			cottage.age = 3.5
			cottage.tick(1.0 / 72.0, 20000 + i * 14, pose)
		var avg_sp := (Time.get_ticks_usec() - t_sp) / 200.0
		var mm_counts: PackedInt32Array = cottage.show_fx.counts.duplicate()
		var prop_cnt: int = cottage.show_fx.art.multimesh.visible_instance_count
		print("Apparition[%d] %-10s tick avg usec: %6.2f | brush=%s | props=%d" % [sp_id, cottage.archive.EFFECTS[sp_id], avg_sp, str(mm_counts), prop_cnt])
	cottage.reset_spell()

	await process_frame
	await process_frame
	print("\n=== RENDER MONITORS: IDLE ROOM ===")
	print("IDLE -> objs=%d prims=%d draws=%d vram=%.2fMB tex=%.2fMB buf=%.2fMB" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / (1024.0 * 1024.0),
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / (1024.0 * 1024.0),
	])

	cottage.volume.open("Herbal", pose, 10000)
	cottage.volume.lift(1, "right_hand", true)
	cottage.volume.model.turn(0.45)
	cottage.aim("left_hand", ray_l, 0.016)
	cottage.aim("right_hand", ray_r, 0.016)
	await process_frame
	await process_frame
	print("BOOK OPEN+TURN -> objs=%d prims=%d draws=%d vram=%.2fMB tex=%.2fMB" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / (1024.0 * 1024.0),
	])
	cottage.volume.close()

	cottage.display_spell(4) # Moths
	cottage.age = 3.5
	cottage.tick(0.016, 30000, pose)
	await process_frame
	await process_frame
	print("MOTHS (60) -> objs=%d prims=%d draws=%d" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])
	cottage.reset_spell()

	# 5. WandSpells first activation + cast raycast + raid step
	var t_act := Time.get_ticks_usec()
	cottage.display_spell(10) # FIRE
	print("First display_spell(FIRE) init usec: ", Time.get_ticks_usec() - t_act)

	var t_cast := Time.get_ticks_usec()
	for i in 100:
		cottage.magic.ready_at = 0.0
		var angle := float(i) * 0.06 - 3.0
		var dir := Vector3(sin(angle) * 0.6, 0.1 * cos(i), -cos(angle)).normalized()
		cottage.magic.cast("right_hand", Vector3(0.2, 1.0, 1.5), dir, cottage.models)
	print("WandSpells.cast(FIRE + BVH contact) avg usec: %.2f" % ((Time.get_ticks_usec() - t_cast) / 100.0))

	var t_raid := Time.get_ticks_usec()
	for i in 300:
		cottage.tick(1.0 / 72.0, 50000 + i * 14, pose)
	print("Combat raid + 6 fireballs tick avg usec: %.2f | brush=%s" % [
		(Time.get_ticks_usec() - t_raid) / 300.0, str(cottage.magic.counts)
	])

	await process_frame
	await process_frame
	print("COMBAT RAID -> objs=%d prims=%d draws=%d" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
	])

	cottage.free()
	await process_frame
	print("AFTER FREE -> vram=%.2fMB tex=%.2fMB orphan_nodes=%d" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0),
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / (1024.0 * 1024.0),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	])
	quit(0)
