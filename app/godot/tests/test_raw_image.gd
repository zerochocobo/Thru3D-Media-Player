extends SceneTree
const Raw := preload("res://scripts/raw_image.gd")
const Info := preload("res://scripts/image_info.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Preview := preload("res://scripts/photo_preview_cache.gd")
const Pip := preload("res://scripts/video_pip_images.gd")
const Tiles := preload("res://scripts/panorama_tiles.gd")
var checks := 0
var failures: Array[String] = []
var folder := ProjectSettings.globalize_path("res://../../build/output/image-transfer")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var bytes := PackedByteArray(); bytes.resize(257 * 31 * 4)
	for i in bytes.size(): bytes[i] = (i * 73 + i / 97) % 256
	var original := Image.create_from_data(257, 31, false, Image.FORMAT_RGBA8, bytes)
	var path := ProjectSettings.globalize_path(folder.path_join("pixels.t3di"))
	check(Raw.write(original, path), "write portable RGBA")
	check(Raw.read(path).get_data() == bytes, "all RGBA channels including transparent RGB survive exactly")
	check(Raw.decode(FileAccess.get_file_as_bytes(path)).get_data() == bytes, "bridge payload has identical pixels")
	check(Info.read_header(path).codec == "rgba", "header probe recognizes internal format")
	check(Raw.read(path, 256) == null, "component edge cap checked before pixel allocation")
	check(Raw.write(original, path), "atomic replacement of an existing tile")
	check(not FileAccess.file_exists(path + ".part"), "successful publication leaves no temporary file")
	# A headerless HEIF/AVIF payload may coincidentally start with the four magic bytes.
	var legacy := bytes.duplicate(); legacy[0] = 84; legacy[1] = 51; legacy[2] = 68; legacy[3] = 73
	var legacy_file := FileAccess.open(path + ".rgba", FileAccess.WRITE)
	legacy_file.store_buffer(legacy); legacy_file.close()
	var legacy_result := Photo._decode({"info": {"path": path + ".rgba", "raw_rgba": true, "decoded_width": 257, "decoded_height": 31}, "skip_thumbnail": true})
	check(legacy_result.has("image"), "headerless legacy payload is distinguished by length")
	if legacy_result.has("image"): legacy_result.image.clear_mipmaps(); check(legacy_result.image.get_data() == legacy, "legacy raw channels unchanged")
	for orientation in range(1, 9):
		var expected := original.duplicate() as Image; Info.orient(expected, orientation)
		var result := Photo._decode({"info": {"path": path, "raw_rgba": true, "decoded_width": 257, "decoded_height": 31, "orientation": orientation}, "skip_thumbnail": true})
		check(result.has("image"), "full photo accepts raw orientation %d" % orientation)
		if result.has("image"):
			var actual: Image = result.image; actual.clear_mipmaps()
			check(actual.get_size() == expected.get_size() and actual.get_data() == expected.get_data(), "orientation/alpha preserved %d" % orientation)
	var pip := Pip._decode({"path": path, "orientation": 6})
	var expected := original.duplicate() as Image; Info.orient(expected, 6)
	check(pip != null and pip.get_size() == expected.get_size(), "PiP consumes the same raw protocol")
	if pip: pip.clear_mipmaps(); check(pip.get_data() == expected.get_data(), "PiP alpha unchanged")
	var tile := Tiles._decode(path)
	check(tile != null, "panorama accepts T3DI")
	if tile: tile.clear_mipmaps(); check(tile.get_data() == bytes, "panorama tile lossless")
	var preview := Preview._decode({"info": {"path": path, "cached": true}, "uri": "file:///raw-transfer-test"})
	check(preview.has("image"), "cached gallery accepts T3DI")
	if preview.has("image"): preview.image.clear_mipmaps(); check(preview.image.get_data() == bytes, "gallery alpha unchanged")
	var valid := FileAccess.get_file_as_bytes(path)
	var legacy_header := valid.duplicate(); legacy_header.encode_u32(12, 1)
	check(Raw.decode(legacy_header).get_data() == bytes, "old Godot v1 spreads remain readable")
	for mode in range(5):
		var bad := valid.duplicate()
		match mode:
			0: bad.resize(bad.size() - 1)
			1: bad.append(0)
			2: bad.encode_u32(4, 0xffffffff)
			3: bad.encode_u32(12, 3)
			4: bad.encode_u32(8, 0)
		check(Raw.decode(bad) == null, "reject malformed payload %d" % mode)
	# Existing original PNGs are still lossless inputs, not forbidden file formats.
	var png := path + ".png"; original.save_png(png)
	var png_result := Photo._decode({"info": {"path": png}, "skip_thumbnail": true})
	check(png_result.has("image"), "original PNG still supported")
	if png_result.has("image"): png_result.image.clear_mipmaps(); check(png_result.image.get_data() == bytes, "original PNG pixels unchanged")
	for name in [".png", ".png.json", ".t3di", ".t3di.json"]:
		check(Preview._cache_file("a".repeat(64) + name), "legacy/current cache cleanup %s" % name)
	print("Raw image: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
