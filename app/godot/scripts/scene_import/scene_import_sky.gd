extends RefCounted
## Equirectangular panorama (.hdr / .exr / .jpg / .png) as a sky for an imported scene.
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const MAX_BYTES := 256 * 1024 * 1024
const EXTENSIONS := ["hdr", "exr", "jpg", "jpeg", "png", "webp"]

## Returns {sky, texture} or {error}.
static func load_sky(path: String, tier: String) -> Dictionary:
	if not path.get_extension().to_lower() in EXTENSIONS: return {"error": "Unsupported sky format"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES: return {"error": "Sky image unavailable or too large"}
	file = null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty(): return {"error": "Sky image could not be read"}
	if image.is_compressed() and image.decompress() != OK: return {"error": "Sky image could not be read"}
	var limit := int(Budget.limits(tier).sky_width)
	if image.get_width() > limit:
		# Packed HDR pixels cannot be filtered in place.
		if image.get_format() == Image.FORMAT_RGBE9995: image.convert(Image.FORMAT_RGBH)
		while image.get_width() >= limit * 2: image.shrink_x2()
		if image.get_width() > limit:
			image.resize(limit, maxi(image.get_height() * limit / image.get_width(), 1), Image.INTERPOLATE_BILINEAR)
	var texture := ImageTexture.create_from_image(image)
	var material := PanoramaSkyMaterial.new()
	material.panorama = texture
	var sky := Sky.new()
	sky.sky_material = material
	return {"sky": sky, "texture": texture}
