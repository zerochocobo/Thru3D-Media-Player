extends RefCounted
## Strong resource references live for a game; never infer projection from image aspect.
const Geometry := preload("res://scripts/video_geometry.gd")
const ImageInfo := preload("res://scripts/image_info.gd")

static func availability(photo: Node) -> String:
	if photo == null or photo.loading or not photo.error.is_empty() or photo._texture == null: return "Image not ready"
	if photo.geometry not in [Geometry.Geometry.FLAT,Geometry.Geometry.EQUIRECT_360]: return "Unsupported projection"
	if photo.geometry==Geometry.Geometry.EQUIRECT_360:
		if photo.stereo_sbs or photo._metadata.get("native_stereo",false): return "Unsupported projection"
		if photo._size.y<=0 or absf(photo._size.x/photo._size.y-2.0)>0.05: return "Unsupported projection"
		if ImageInfo.panorama_rect(photo._metadata)!=Vector4(0,0,1,1): return "Unsupported projection"
		var full := Vector2(float(photo._metadata.get("FullPanoWidthPixels",0)),float(photo._metadata.get("FullPanoHeightPixels",0)))
		if full.x>0 and full.y>0:
			var area := Vector2(float(photo._metadata.get("CroppedAreaImageWidthPixels",full.x)),float(photo._metadata.get("CroppedAreaImageHeightPixels",full.y)))
			if area!=full or int(photo._metadata.get("CroppedAreaLeftPixels",0))!=0 or int(photo._metadata.get("CroppedAreaTopPixels",0))!=0: return "Unsupported projection"
	if photo.portrait_requested or photo.gallery.overview(): return "Open an image first"
	if photo.depth_requested and not photo.depth_enabled: return "Image not ready"
	return ""

static func from_photo(photo: Node) -> Dictionary:
	var error := availability(photo)
	if not error.is_empty(): return {"error":error}
	var source_image: Image = photo._full_image
	var texture: Texture2D = photo._texture
	if source_image != null:
		if source_image.get_width()>4096 or source_image.get_height()>4096:
			source_image=source_image.duplicate()
			var ratio := minf(4096.0/source_image.get_width(),4096.0/source_image.get_height())
			source_image.resize(maxi(2,int(source_image.get_width()*ratio)&~1),maxi(2,int(source_image.get_height()*ratio)&~1),Image.INTERPOLATE_LANCZOS)
			source_image.generate_mipmaps()
		texture = ImageTexture.create_from_image(source_image)
	if source_image==null: source_image=texture.get_image()
	var size: Vector2 = photo._size
	var stereo_layout := (2 if photo.top_bottom else 1) if photo.stereo_sbs else 0
	if stereo_layout == 1: size.x *= 0.5
	elif stereo_layout == 2: size.y *= 0.5
	var depth: Image = photo._display_depth_data.get("image") if photo.geometry==Geometry.Geometry.FLAT and photo.depth_enabled and not photo.stereo_sbs else null
	var retained: Dictionary=photo.queue[photo.index].get("retained_source",{}) if photo.index>=0 and photo.index<photo.queue.size() else {}
	return {"texture":texture, "image":source_image, "size":size, "uri":photo.local_uri, "title":photo.display_name,
		"image_key":str(retained.get("image_key","")),
		"projection":"sphere" if photo.geometry==Geometry.Geometry.EQUIRECT_360 else "flat",
		"layout":stereo_layout, "swap_eyes":photo.swap_eyes,
		"spatial_disparity":float(photo._metadata.get("spatial_disparity",0)) if photo.stereo_sbs else 0.0,
		"kind":"stereo" if stereo_layout else ("relief" if depth != null else "flat"),
		"depth":depth, "depth_rect":photo._depth_rect,
		"relief":clampf(float(photo.depth_strength)*0.02,0,0.04) if depth != null else 0.0}
