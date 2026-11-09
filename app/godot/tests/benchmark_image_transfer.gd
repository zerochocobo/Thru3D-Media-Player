extends SceneTree
const Raw := preload("res://scripts/raw_image.gd")
var folder := ProjectSettings.globalize_path("res://../../build/output/image-transfer")
var results: Array[Dictionary] = []
var failures := 0
func _initialize() -> void: call_deferred("run")
func measure(image: Image, label: String) -> void:
	var reference := image.get_data()
	for round_index in range(4):
		# Alternate order; round zero warms code/filesystem and is reported separately.
		for raw in ([false, true] if round_index % 2 == 0 else [true, false]):
			var path := folder.path_join("benchmark.t3di" if raw else "benchmark.png")
			var start := Time.get_ticks_usec()
			var ok := Raw.write(image, path) if raw else image.save_png(path) == OK
			var written := Time.get_ticks_usec()
			var readback := Raw.read(path) if raw else Image.load_from_file(path)
			var finished := Time.get_ticks_usec()
			var exact := ok and readback != null and readback.get_data() == reference
			if not exact: failures += 1
			var file := FileAccess.open(path, FileAccess.READ)
			results.append({"case": label, "round": round_index, "warmup": round_index == 0,
				"format": "t3di" if raw else "png", "width": image.get_width(), "height": image.get_height(),
				"write_ms": (written-start)/1000.0, "read_ms": (finished-written)/1000.0,
				"total_ms": (finished-start)/1000.0, "file_bytes": file.get_length(), "pixel_exact": exact})
			file.close()
			DirAccess.remove_absolute(path)
func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	# Same existing licensed source, same RGBA pixels and dimensions on both paths.
	var source := Image.load_from_file(ProjectSettings.globalize_path("res://backgrounds/belfast_sunset_puresky.jpg"))
	if source == null: quit(1); return
	source.convert(Image.FORMAT_RGBA8)
	for size in [Vector2i(512, 256), Vector2i(1028, 1028), Vector2i(4096, 2048), Vector2i(8192, 4096)]:
		var sample := source.duplicate() as Image
		sample.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		measure(sample, "belfast-%dx%d" % [size.x, size.y])
	var report := {"scope": "Windows Godot encode/write/read/decode only; no Android encoder, network, GPU upload or headset timings", "rounds": results, "failures": failures}
	var file := FileAccess.open(folder.path_join("benchmark.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ")); file.close()
	print("Image transfer benchmark: %d round trips, %d failures" % [results.size(), failures])
	quit(0 if failures == 0 else 1)
