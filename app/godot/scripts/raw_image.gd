extends RefCounted
## T3DI v2: straight-alpha RGBA8. Read legacy v1 Godot spreads without changing their pixels.
const MAX_PIXELS := 32 * 1024 * 1024

static func header(bytes: PackedByteArray, length: int) -> Dictionary:
	if bytes.size() < 16 or bytes.slice(0, 4).get_string_from_ascii() != "T3DI": return {}
	var w := bytes.decode_u32(4); var h := bytes.decode_u32(8)
	if bytes.decode_u32(12) not in [1, 2] or w < 1 or h < 1 or w > 8192 or h > 8192 or w * h > MAX_PIXELS or length != 16 + w * h * 4: return {}
	return {"width": w, "height": h, "codec": "rgba", "orientation": 1, "panorama": false}

static func decode(bytes: PackedByteArray) -> Image:
	var info := header(bytes, bytes.size())
	if info.is_empty(): return null
	return Image.create_from_data(info.width, info.height, false, Image.FORMAT_RGBA8, bytes.slice(16))

static func read(path: String, max_edge: int = 8192) -> Image:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return null
	var info := header(file.get_buffer(16), file.get_length())
	if info.is_empty() or info.width > max_edge or info.height > max_edge: return null
	var bytes := file.get_buffer(info.width * info.height * 4)
	if bytes.size() != info.width * info.height * 4: return null
	return Image.create_from_data(info.width, info.height, false, Image.FORMAT_RGBA8, bytes)

static func write(image: Image, path: String) -> bool:
	if image == null or image.is_empty() or image.get_width() > 8192 or image.get_height() > 8192 or image.get_width() * image.get_height() > MAX_PIXELS: return false
	if image.get_format() != Image.FORMAT_RGBA8 or image.has_mipmaps():
		image = image.duplicate() as Image
		image.clear_mipmaps(); image.convert(Image.FORMAT_RGBA8)
	var temporary := path + ".part"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not file: return false
	file.store_buffer("T3DI".to_ascii_buffer())
	file.store_32(image.get_width()); file.store_32(image.get_height()); file.store_32(2)
	file.store_buffer(image.get_data()); file.flush()
	var ok := file.get_error() == OK
	file.close()
	if ok: ok = DirAccess.rename_absolute(temporary, path) == OK
	if not ok: DirAccess.remove_absolute(temporary)
	return ok
