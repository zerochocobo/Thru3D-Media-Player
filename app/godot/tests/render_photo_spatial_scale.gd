extends "res://tests/preview_photo_spatial_real.gd"
## Exercise the production PhotoDisplay lifecycle with real resolution variants.
var checks:=0
var failures: Array[String]=[]
var groups: Dictionary={}

func check(ok: bool, message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

func mesh_hash(bytes: PackedByteArray) -> String:
	var hash:=HashingContext.new(); hash.start(HashingContext.HASH_SHA256); hash.update(bytes)
	return hash.finish().hex_encode()

func start() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.is_empty(): push_error("Pass scale-review inputs.json"); quit(1); return
	inputs=JSON.parse_string(FileAccess.get_file_as_string(args[0])); output=inputs.output
	for entry in inputs.cases:
		await load_case(entry)
		var arrays: Array=photo._spatial.surfaces[0].mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var digest:=mesh_hash(vertices.to_byte_array())
		var original_mesh_id: int=photo._spatial.surfaces[0].mesh.get_instance_id()
		var original_pose: Transform3D=photo._spatial.transform
		var max_z:=0.0
		for p in vertices: max_z=maxf(max_z,p.z)
		if groups.has(entry.source_group):
			check(digest==groups[entry.source_group],"Real-photo geometry is byte-identical across resolutions: "+entry.id)
		else: groups[entry.source_group]=digest
		check(photo._spatial.report.depth_scale=="display_short_edge_reference_distance","Production scene reports physical scaling: "+entry.id)
		check(bool(entry.native_stereo) or photo.depth_enabled,"Ordinary photo completes its existing conversion before spatial viewing: "+entry.id)
		var folder:=output.path_join(entry.id).path_join("render")
		DirAccess.make_dir_recursive_absolute(folder)
		await picture(source_view,folder.path_join("static-left.png"))
		for view in [["centre",0.0,0.0],["right12",12.0,0.0],["up8",0.0,8.0]]:
			move_head(view[1],view[2]); await picture(spatial_view,folder.path_join(view[0]+".png"))
			var active_mesh: ArrayMesh=photo._spatial.surfaces[0].mesh
			check(photo._spatial.coverage==1 and active_mesh.get_instance_id()==original_mesh_id and photo._spatial.transform.is_equal_approx(original_pose) \
				and mesh_hash(active_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].to_byte_array())==digest,"Head translation keeps one fixed scene: "+entry.id+"/"+view[0])
		results.append({"id":entry.id,"source_group":entry.source_group,"level":entry.level,"native_stereo":entry.native_stereo,
			"eye_width":int(entry.width)/(2 if entry.native_stereo else 1),"eye_height":entry.height,"mesh_sha256":digest,
			"peak_relief_m":max_z,"display_size_m":str(photo._flat.size),"resources":photo._spatial.report})
		print("Scale review captured ",entry.id," ",digest)
		await unload()
	FileAccess.open(output.path_join("render-results.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"cases":results,
		"scope":"Desktop production PhotoDisplay/GL with real ordinary/native pixels and common normalized depth; isolated source-resolution geometry check, no Android/XR"},"\t"))
	for failure in failures: push_error(failure)
	print("Photo spatial real scale render: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
