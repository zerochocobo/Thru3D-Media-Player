extends "res://tests/test_photo_presentation.gd"
## Production GPU preparation and the first frame after selecting a cache hit.
var output := ProjectSettings.globalize_path("res://../../build/output/photo-cache-presentation-20261101")
const Fixture := preload("res://tests/test_photo_presentation.gd")
const Budget := preload("res://scripts/background_resource_budget.gd")
class GlesBudget extends Budget:
	# Reproduce Android GLES: Godot reports CPU timing, but no viewport GPU timestamp.
	func render_times(_viewport: RID) -> Vector2: return Vector2(2,0)
	func refresh_rate() -> float: return 60.0
	func frame_interval(_delta: float) -> float: return 1.0/60 # Deterministic XR cadence; host scheduling is not the device's load.

class NativeHost extends CacheHost:
	var starts := 0
	var ends := 0
	var stops := 0
	var supported := true
	func background_gpu_timing(action: int) -> float:
		if action < 0: stops += 1; return 0
		if action == 0: ends += 1; return 0
		starts += 1
		return 3.0 if supported else -1.0

class CacheHost extends Fixture.Host:
	var portraits := 0
	var spare_bytes := 4*1024*1024*1024
	func background_resource_policy() -> String:
		return JSON.stringify({"work":true,"retain":true,"spare_bytes":spare_bytes,"cache_limit":512*1024*1024})
	func prepare_photo_portrait(_id: int, _token: int, _strength: float) -> bool: portraits += 1; return true
	func cancel_photo_portrait(_token: int) -> void: pass

func prime(photo: Node3D) -> void:
	photo.resource_budget.policy = {"work":true,"retain":true,"spare_bytes":4*1024*1024*1024,"cache_limit":512*1024*1024}
	photo.resource_budget.stable=10; photo.resource_budget.samples=120; photo.resource_budget.cooldown=0

func warm(photo: Node3D, entry: Dictionary, at: int) -> void:
	for i in range(100):
		if photo.render_cache.ready(entry,at): return
		photo.render_cache.pump()
		await process_frame
		await RenderingServer.frame_post_draw
	check(false,"GPU resources reach display-ready state")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	color=Image.create(1024,1024,false,Image.FORMAT_RGBA8); color.fill(Color(.3,.4,.5))
	proxy=Image.create(64,64,false,Image.FORMAT_RGBA8); proxy.fill(Color(.3,.4,.5))
	depth=Image.create(518,518,false,Image.FORMAT_RF); depth.fill(Color(.7,0,0))
	stereo=Image.create(2048,1024,false,Image.FORMAT_RGBA8)
	stereo.fill_rect(Rect2i(0,0,1024,1024),Color(.45,.2,.7)); stereo.fill_rect(Rect2i(1024,0,1024,1024),Color(.8,.6,.15)); stereo.generate_mipmaps()
	stereo.fill_rect(Rect2i(120,120,64,64),Color(.4,.1,.8,.4)); stereo.generate_mipmaps()
	var photo := make_photo()
	photo.platform=CacheHost.new(); photo.video_layer.platform=photo.platform
	cold(photo); finish(photo)
	prime(photo)
	var current: Dictionary = photo.render_cache.capture_current()
	await warm(photo,current,photo.index)
	check(photo._display_depth_data.get("ready_stereo") is ImageTexture,"The displayed layer photo reuses the normal GPU image path before it is left")
	var target_result := result()
	var target_depth := converted(photo.depth_strength); target_depth["source_id"]=21
	var entry := {"id":21,"info":target_result.info,"result":target_result,"decoded":true,"depth_data":target_depth}
	photo._prefetched[1]=entry
	var before_memory: int = photo.reading_render.memory(photo._prefetched,{})
	photo.render_cache.pump()
	check(not photo.render_cache.ready(entry,1) and not photo.render_cache.job.is_empty(),"An allocated but incomplete GPU texture is never published as ready")
	check(photo.reading_render.memory(photo._prefetched,{})>before_memory,"Incomplete GPU storage is charged to the cache budget")
	photo.render_cache.cancel()
	check(not entry.result.has("warming_texture"),"Cancelling partial GPU preparation releases its storage reference")
	photo.render_cache.pump(); photo._cache_epoch+=1; photo.render_cache.pump()
	check(photo.render_cache.job.is_empty() and not entry.result.has("ready_texture"),"A changed album generation cannot publish a stale upload")
	var normal_limit: int=photo.resource_budget.policy.cache_limit
	photo.resource_budget.policy.cache_limit=1
	photo.render_cache.pump()
	check(photo.render_cache.job.is_empty(),"Insufficient GPU storage budget prevents optional preparation")
	photo.resource_budget.policy.cache_limit=normal_limit
	await warm(photo,entry,1)
	var gpu: Texture2D = entry.depth_data.ready_stereo
	var readback := gpu.get_image()
	check(readback != null and readback.get_size()==stereo.get_size(),"The pre-rendered texture keeps full eye resolution")
	if readback != null:
		check(readback.get_pixel(200,200).is_equal_approx(stereo.get_pixel(200,200)),"Prepared textures preserve color values without an extra sRGB conversion")
		var base_bytes := stereo.get_width()*stereo.get_height()*4
		check(readback.get_data().slice(0,base_bytes)==stereo.get_data().slice(0,base_bytes),"Uploaded base pixels preserve source RGB and straight alpha bytes")
	var calls: int = photo.platform.calls.size(); var bands: int = photo.platform.bands
	check(photo._select(1,1),"A fully rendered cache entry can be selected")
	check(not photo.loading and not photo._presentation_pending and not photo.placeholder_visible(),"GPU cache hit has no loading cover in the selection call")
	check(photo._stereo_texture==gpu and photo.material.get_shader_parameter("photo_stereo"),"First-frame material binds the completed full-resolution stereo texture")
	check(photo.platform.calls.size()==calls and photo.platform.bands==bands,"Selecting a ready entry neither reruns inference nor waits for another compositor upload")
	photo.view_camera.position=Vector3(0,1.6,0); photo.view_camera.make_current()
	await process_frame; await RenderingServer.frame_post_draw
	var first := root.get_texture().get_image()
	first.save_png(output.path_join("cache-hit-first-frame.png"))
	var centre := first.get_pixel(first.get_width()/2,first.get_height()/2)
	check(maxf(centre.r,maxf(centre.g,centre.b))>.1 and minf(centre.r,minf(centre.g,centre.b))<.8,"The first rendered frame contains the picture rather than a white or empty cover")
	# Compare through the production shader against a normal ImageTexture, not just get_image().
	photo.material.set_shader_parameter("stereo_texture",ImageTexture.create_from_image(stereo))
	await process_frame; await RenderingServer.frame_post_draw
	var reference := root.get_texture().get_image()
	var other := reference.get_pixel(reference.get_width()/2,reference.get_height()/2)
	check(absf(centre.r-other.r)<.015 and absf(centre.g-other.g)<.015 and absf(centre.b-other.b)<.015,"Pre-rendered and ordinary texture paths display the same colors")
	photo.material.set_shader_parameter("stereo_texture",gpu)
	photo._process(.01)
	check(not photo.placeholder_visible() and not photo._presentation_pending,"Optional native layer copying proceeds without covering the ready eye-buffer picture")
	check(photo._prefetched.has(0) and photo.render_cache.ready(photo._prefetched[0],0),"The previously displayed photo remains GPU-ready for an immediate return")
	check(photo._select(0,-1) and not photo.placeholder_visible() and not photo._presentation_pending,"Returning to the previous ready photo also skips the loading cover")
	# Cached portrait resources must also be bound without uploading a matte on selection.
	photo.auto_portrait=true; photo.transparent_background=true
	var portrait_depth := converted(photo.depth_strength); portrait_depth["source_id"]=22
	var mask := Image.create(2048,1024,false,Image.FORMAT_R8); mask.fill(Color(.5,0,0))
	portrait_depth["portrait_data"]={"image":mask,"mask":mask.get_data(),"strength":photo.depth_strength,"source_id":22}
	var portrait_result := result()
	var portrait_entry := {"id":22,"info":portrait_result.info,"result":portrait_result,"depth_data":portrait_depth,"decoded":true}
	photo._prefetched[2]=portrait_entry; prime(photo)
	await warm(photo,portrait_entry,2)
	var mask_texture: Texture2D=portrait_depth.portrait_data.ready_texture
	var mask_readback := mask_texture.get_image()
	check(absf(mask_readback.get_pixel(200,200).r-mask.get_pixel(200,200).r)<.005,"R8 matte textures preserve linear mask values")
	check(photo._select(2,1) and photo.portrait_enabled and not photo.placeholder_visible() and not photo._presentation_pending,
		"A completed portrait cache entry appears in the selection call")
	check(photo._portrait_texture==mask_texture and photo.platform.portraits==0,"Portrait selection reuses the prepared GPU matte without another upload or inference")
	var proxy_texture: Texture2D=photo._texture
	photo._process_layer()
	check(photo._texture==proxy_texture and photo._stereo_texture!=null,"An unavailable optional portrait layer does not upload unused full colour behind the ready stereo picture")
	# Larger images used to keep files only even when there was room for display resources.
	var large := Image.create(4096,2304,false,Image.FORMAT_RGB8); large.fill(Color(.2,.3,.4))
	var large_path := output.path_join("large-colour.png"); large.save_png(large_path)
	var large_info := {"path":large_path,"width":4096,"height":2304}
	var bounded: Dictionary=Photo._decode({"info":large_info,"prefetch":true})
	check(bounded.get("uncached",false),"Legacy fixed-size decode declines the larger colour cache")
	check(photo.render_cache._queue_color(1,{"id":31,"info":large_info}),"Measured headroom admits a separate bounded larger-colour decode")
	var decode_job: Dictionary=photo._prefetch_decode; photo._prefetch_decode={}
	var decoded: Dictionary=Photo._decode(decode_job)
	check(decoded.has("image") and decoded.image.get_width()==4096 and decoded.image.get_data_size()>Photo.CACHE_IMAGE_BYTES,
		"The admitted full-resolution result avoids another decode on cache selection")
	photo._prefetched[1]={"id":31,"info":large_info,"result":decoded,"decoded":true}
	var displayed: Texture2D=photo._stereo_texture
	photo.resource_budget.policy.retain=false; photo._trim_depth_cache()
	check(not photo._prefetched[1].has("result") and photo._prefetched[1].has("info"),
		"Memory pressure releases larger CPU/GPU cache residents while preserving the source file")
	check(photo._stereo_texture==displayed and not photo.placeholder_visible(),
		"Releasing optional cache resources leaves the displayed photo intact")
	dispose(photo)
	await native_gate_case()
	call_deferred("done")

func native_gate_case() -> void:
	var previous_fps := Engine.max_fps
	Engine.max_fps = 60; DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var photo := make_photo()
	var host := NativeHost.new()
	photo.platform = host; photo.video_layer.platform = host
	photo.resource_budget = GlesBudget.new()
	cold(photo); finish(photo)
	var data := converted(photo.depth_strength); data["source_id"] = 71
	var entry := {"id":71,"info":result().info,"result":result(),"depth_data":data,"decoded":true}
	photo._prefetched[1] = entry
	check(not photo.resource_budget.can_start(1),"An Android GLES cache starts with no fabricated frame headroom")
	var deadline := Time.get_ticks_msec() + 45000
	# No prime(), fake stable counter or cooldown override: actual frame callbacks,
	# budget.tick and the production scheduler run against a controlled CPU/XR profile.
	photo.set_process(true)
	while Time.get_ticks_msec() < deadline and not photo.render_cache.ready(entry,1):
		await create_timer(.05).timeout
	photo.set_process(false)
	check(host.starts > 60 and host.ends > 60,"The fallback brackets real render frames through the render-thread API")
	check(photo.resource_budget.gpu_source == "gles_timer" and photo.resource_budget.can_start(1),
		"Normal settling admits the controlled frame profile when Godot GPU readings stay zero but EXT samples are valid")
	check(photo.render_cache.ready(entry,1),"Normal scheduler processing reaches GPU-ready without manually priming the budget")
	# The former 1.5 GiB foreground-peak guard discarded even completed neighbours
	# when selecting a GPU hit which needs no foreground peak allocation.
	host.spare_bytes=1300*1024*1024; photo.resource_budget.policy.spare_bytes=host.spare_bytes
	var second_data: Dictionary=entry.depth_data.duplicate(); second_data.source_id=72
	var second := {"id":72,"info":entry.info,"result":entry.result.duplicate(),"depth_data":second_data,"decoded":true}
	photo._prefetched[2]=second
	check(photo._select(1,1) and not photo.placeholder_visible() and not photo._presentation_pending,
		"The naturally prepared Android GLES cache hit displays directly in single-photo navigation")
	check(photo._prefetched.has(2) and photo.render_cache.ready(photo._prefetched[2],2),
		"A complete cache hit keeps other prepared neighbours when the memory reserve is healthy")
	check(photo._select(2,1) and not photo.placeholder_visible() and not photo._presentation_pending,
		"The second immediate forward step also uses its prepared 3D picture")
	host.supported = false
	for i in 4:
		photo._process(1.0/60); await process_frame; await RenderingServer.frame_post_draw
	check(not photo.resource_budget.can_start(1),"An invalid native GPU reading immediately closes optional-work admission")
	var budget: RefCounted = photo.resource_budget
	var generation: int = budget._native_generation
	dispose(photo)
	budget._accept_native(3,generation)
	await process_frame; await RenderingServer.frame_post_draw
	check(budget._native_gpu == 0 and host.stops > 0,"Closing disconnects frame hooks, releases native queries and rejects stale callbacks")
	Engine.max_fps = previous_fps

func done() -> void:
	for failure in failures: push_error(failure)
	print("Photo render cache: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
