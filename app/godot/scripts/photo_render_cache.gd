extends RefCounted
## A cache hit is display-ready only after its full-resolution GPU resources exist.
## Reuse the normal image-to-GPU path on an admitted idle frame; publish after a draw.
const Geometry := preload("res://scripts/video_geometry.gd")
const WORK_BYTES := 48 * 1024 * 1024 # Driver staging; CPU images/mips are already resident.
const MIB := 1024 * 1024
var photo: Node3D
var job := {}
var _report_request := 0
var _report_at := 0
var last_upload := {}
var max_upload_us := 0

func _init(owner: Node3D) -> void: photo = owner

func cancel() -> void:
	if job.has("holder") and job.holder.get("warming_texture") == job.get("texture"):
		job.holder.erase("warming_texture")
	job = {}

func optional_memory(seen: Dictionary) -> int:
	var resources := {}
	for key in ["ready_depth", "ready_stereo"]: resources[key] = photo._display_depth_data.get(key)
	resources["portrait"] = photo._display_depth_data.get("portrait_data", {}).get("ready_texture")
	resources["color"] = photo._display_result.get("ready_texture")
	resources["warming_color"] = photo._display_result.get("warming_texture")
	resources["warming_depth"] = photo._display_depth_data.get("warming_texture")
	resources["warming_mask"] = photo._display_depth_data.get("portrait_data", {}).get("warming_texture")
	return photo.reading_render.memory(resources, seen)

func total_memory() -> int:
	var seen := {}
	return photo.reading_render.memory(photo._prefetched, seen) + optional_memory(seen)

func diagnose() -> void:
	if photo.index < 0 or not photo.auto_depth or not photo._cache_supported(): return
	var now := Time.get_ticks_msec()
	if _report_request != photo._display_request:
		_report_request = photo._display_request; _report_at = now + 3000
	if now < _report_at: return
	_report_at = now + 5000
	var neighbors := []
	var complete := true
	for at in photo._neighbors(photo.index):
		var entry: Dictionary = photo._prefetched.get(at,{})
		var done := ready(entry,at)
		complete = complete and done
		neighbors.append({"index":at,"color":entry.get("result",{}).has("image"),"depth":entry.has("depth_data"),"render_ready":done})
	if complete: return
	DiagnosticLog.record("photo_cache_waiting", {"request":_report_request,"index":photo.index,"budget":photo.resource_budget.report(),
		"neighbors":neighbors,"resident_bytes":total_memory(),"gpu_stage":str(job.get("key","")),
		"color_request":photo._prefetch_request,"depth_request":photo._prefetch_depth_request})

func color_limit() -> int:
	return maxi(photo.CACHE_IMAGE_BYTES, int(photo.resource_budget.policy.get("cache_limit", photo.CACHE_IMAGE_BYTES)))

func ready(entry: Dictionary, at: int) -> bool:
	var result: Dictionary = entry.get("result", {})
	if not result.has("image") or not result.get("ready_texture") is Texture2D: return false
	if photo.spatial_preferred and not photo.auto_portrait: return false
	if not photo._requires_depth(at, entry.get("info", {})): return true
	var data: Dictionary = entry.get("depth_data", result.get("depth_data", {}))
	if not photo._valid_cached_depth(data, at) or int(data.get("source_id", -1)) != int(entry.get("id", 0)): return false
	if not data.get("ready_depth") is Texture2D or not data.get("ready_stereo") is Texture2D: return false
	if data.ready_stereo.get_width() != data.stereo_image.get_width() or data.ready_stereo.get_height() != data.stereo_image.get_height(): return false
	if photo.auto_portrait:
		var mask: Dictionary = data.get("portrait_data", {})
		return photo._valid_cached_portrait(mask, data) and mask.get("ready_texture") is Texture2D
	return true

func capture_current() -> Dictionary:
	if photo.index < 0 or photo._display_request <= 0 or photo.loading or photo._presentation_pending: return {}
	var result: Dictionary = photo._display_result
	# Large layer-backed photos already retain their original pixels for normal fallback.
	# Reuse that reference rather than decoding it again when returning to the photo.
	if result.is_empty() and photo._full_image != null:
		result = {"image":photo._full_image, "info":photo._display_info}
		if photo._display_proxy != null: result["proxy"] = photo._display_proxy
	if not result.has("image") and photo._display_depth_data.is_empty(): return {}
	if photo._texture != null and (photo._texture_full or result.has("proxy")):
		result["ready_texture"] = photo._texture; result["ready_proxy"] = not photo._texture_full
	var data: Dictionary = photo._display_depth_data
	if photo._depth_texture != null: data["ready_depth"] = photo._depth_texture
	if photo._stereo_texture != null: data["ready_stereo"] = photo._stereo_texture
	if photo._portrait_texture != null and photo._valid_cached_portrait(data.get("portrait_data", {}), data):
		data.portrait_data["ready_texture"] = photo._portrait_texture
	return {"id":photo._display_request, "info":photo._display_info, "result":result, "depth_data":data, "decoded":true}

func _valid_target() -> bool:
	if job.is_empty() or int(job.epoch) != photo._cache_epoch or not is_equal_approx(float(job.strength), photo.depth_strength): return false
	if int(job.get("rotation", 0)) != photo._stereo_rotation(int(job.index)): return false
	var entry: Dictionary = job.entry
	var id := int(entry.get("id", 0))
	if id == photo._display_request:
		return int(job.index) == photo.index and entry.depth_data == photo._display_depth_data and entry.result == photo._display_result
	return photo._prefetched.get(int(job.index)) == entry and id > 0

func pump() -> bool:
	if not photo._cache_supported() or photo.geometry != Geometry.Geometry.FLAT: return false
	if not photo.resource_budget.can_start(WORK_BYTES) or photo._depth_busy or photo._depth_thread or photo._thread \
		or not photo._upload.is_empty() or photo._prefetch_request != 0 or photo._prefetch_depth_request != 0 \
		or photo._prefetch_portrait_request != 0 or photo._portrait_thread: return false
	if not job.is_empty():
		if not _valid_target(): cancel(); return false
		return _step()
	if photo.spatial_requested or (photo.spatial_preferred and not photo.auto_portrait): return false
	var targets: Array = [photo.index]
	targets.append_array(photo._neighbors(photo.index))
	for at in targets:
		var current: bool = at == photo.index
		var entry: Dictionary = capture_current() if current else photo._prefetched.get(at, {})
		if entry.is_empty() or not entry.get("decoded", false) or entry.get("info", {}).get("animated", false): continue
		var data: Dictionary = entry.get("depth_data", {})
		if photo._requires_depth(at, entry.get("info", {})):
			if not photo._valid_cached_depth(data, at): continue
			if photo.auto_portrait and not photo._valid_cached_portrait(data.get("portrait_data", {}), data): continue
		var result: Dictionary = entry.get("result", {})
		if not result.has("image"):
			if _queue_color(at, entry): return true
			continue
		var stages: Array = [[result, "ready_texture", result.get("proxy", result.image) if photo._requires_depth(at, entry.info) else result.image]]
		if photo._requires_depth(at, entry.info):
			stages.append([data, "ready_depth", data.image])
			if data.has("stereo_image"): stages.append([data, "ready_stereo", data.stereo_image])
			if photo.auto_portrait: stages.append([data.portrait_data, "ready_texture", data.portrait_data.image])
		for stage in stages:
			if stage[0].get(stage[1]) is Texture2D: continue
			var image: Image = stage[2]
			if stage[1] != "ready_depth" and image.get_format() not in [Image.FORMAT_RGB8, Image.FORMAT_RGBA8, Image.FORMAT_R8]: break
			var bytes := int(image.get_width() * image.get_height() * 16.0 / 3.0)
			if not _reserve(bytes, at) or not photo.resource_budget.can_start(WORK_BYTES, bytes): break
			job = {"entry":entry,"index":at,"holder":stage[0],"key":stage[1],"image":image,"row":0,"level":0,
				"epoch":photo._cache_epoch,"strength":photo.depth_strength,"rotation":photo._stereo_rotation(at)}
			if current: photo._display_result = result
			return _step()
	return false

func _reserve(bytes: int, at: int) -> bool:
	var resident := total_memory()
	if resident + bytes <= photo.resource_budget.resident_limit(resident): return true
	var neighbors: Array[int] = photo._neighbors(photo.index)
	var start: int = neighbors.find(at) + 1 if at != photo.index else 0
	var lower: Array[int] = neighbors.slice(start); lower.reverse()
	for victim in lower:
		var entry: Dictionary = photo._prefetched.get(victim,{})
		# A complete cached picture is more valuable than another partially prepared result.
		if not entry.is_empty() and not ready(entry,victim): photo._drop_cached_depth(victim)
		resident = total_memory()
		if resident + bytes <= photo.resource_budget.resident_limit(resident): return true
	return false

func _queue_color(at: int, entry: Dictionary) -> bool:
	if photo._thread or not photo._prefetch_decode.is_empty() or photo._prefetch_request != 0: return false
	var info: Dictionary = entry.get("info", {})
	var width := int(info.get("width", 0)); var height := int(info.get("height", 0))
	if width <= 0 or height <= 0: return false
	var bytes := int(width * height * 16.0 / 3.0)
	var resident := total_memory()
	if bytes > color_limit() or resident + bytes > photo.resource_budget.resident_limit(resident) \
		or not photo.resource_budget.can_start(bytes * 2 + 8 * MIB, bytes): return false
	photo._prefetch_decode = {"id":entry.id,"index":at,"info":info,"prefetch":true,"epoch":photo._cache_epoch,
		"cache_image_limit":color_limit(),"render_current":int(entry.id) == photo._display_request}
	return true

func _step() -> bool:
	var started := Time.get_ticks_usec()
	var stage := {"index":int(job.index),"key":str(job.key),"level":int(job.level),"row":int(job.row)}
	var progressed := _upload_step()
	stage["cpu_us"] = Time.get_ticks_usec() - started
	max_upload_us = maxi(max_upload_us,int(stage.cpu_us))
	last_upload = stage
	return progressed

func _upload_step() -> bool:
	var image: Image = job.image
	if not job.has("texture"):
		# Reuse the displayed-photo path: source pixels and mips already exist.
		# DrawableTexture2D.setup would first fill/upload an equally large empty image.
		job["texture"] = ImageTexture.create_from_image(image)
		job["frame"] = Engine.get_frames_drawn()
		job.holder["warming_texture"] = job.texture
		return true
	if Engine.get_frames_drawn() <= int(job.frame): return true
	job.holder[job.key] = job.texture
	job.holder.erase("warming_texture")
	if job.key == "ready_texture" and job.holder == job.entry.get("result", {}):
		job.holder["ready_proxy"] = job.image == job.holder.get("proxy")
	if ready(job.entry, int(job.index)):
		job.entry["render_ready_us"] = Time.get_ticks_usec()
		DiagnosticLog.record("photo_cache_render_ready", {"request":int(job.entry.id),"index":int(job.index),"portrait":photo.auto_portrait})
	cancel()
	return true
