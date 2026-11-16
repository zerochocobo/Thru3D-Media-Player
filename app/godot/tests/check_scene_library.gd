extends SceneTree
## Imports every optimised scene library file the way the player would and reports what the
## importer still had to do: godot --headless --xr-mode off --path app/godot --script res://tests/check_scene_library.gd -- <build/scene_library>
## Each <slug>/low.glb is read at the low tier and <slug>/high.glb at the high tier.
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- <scene library build directory>")
		quit(2)
		return
	var failures := 0
	var rows := []
	for slug in DirAccess.get_directories_at(args[0]):
		for tier in ["low", "high"]:
			var path: String = args[0].path_join(slug).path_join(tier + ".glb")
			if not FileAccess.file_exists(path): continue
			var started := Time.get_ticks_msec()
			var result := Loader.new().load_scene(path, tier, {"use_cache": false})
			if result.has("error"):
				failures += 1
				print("FAIL %s %s: %s" % [slug, tier, result.error])
				continue
			var info: Dictionary = result.info
			var culled := int(info.actions.get("meshes_culled", 0))
			if culled > 0 or not info.over_budget.is_empty(): failures += 1
			rows.append({"slug": slug, "tier": tier, "ms": Time.get_ticks_msec() - started, "triangles": info.stats.triangles,
				"batches": info.stats.batches, "texture_bytes": info.stats.texture_bytes, "culled": culled, "over_budget": info.over_budget,
				"textures_resized": int(info.actions.get("textures_resized", 0)), "layout": info.layout.source})
			print("%s %s %s: %d ms, %d triangles, %d batches, %d MB textures, culled %d, resized %d, over %s" % ["ok" if culled == 0 and info.over_budget.is_empty() else "OVER", slug, tier,
				rows[-1].ms, info.stats.triangles, info.stats.batches, int(info.stats.texture_bytes) / 1048576, culled, rows[-1].textures_resized, info.over_budget])
			result.root.free()
	var file := FileAccess.open(args[0].path_join("import_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, " "))
	file.close()
	print("Scene library check: %d files, %d failures" % [rows.size(), failures])
	quit(1 if failures > 0 else 0)
