extends SceneTree
const PhotoAnimation := preload("res://scripts/photo_animation.gd")
const Info := preload("res://scripts/image_info.gd")
var failures: Array[String] = []
var checks := 0

class Gallery extends RefCounted:
	var mode := 0
	var overview_active := false
	func overview() -> bool: return overview_active

class Platform extends RefCounted:
	var report := {"token":1,"width":2,"height":2,"paused":false,"ended":false,"failed":false}
	var pauses: Array[bool] = []
	var uploads := 0
	var restarts := 0
	func get_photo_animation_frame(_id: int) -> String: return JSON.stringify(report)
	func pause_photo_animation(_id: int,value: bool) -> void: pauses.append(value)
	func restart_photo_animation(_id: int) -> void: restarts += 1
	func upload_photo_animation_frame(_id: int,_token: int,_texture: int,_mipmaps: bool) -> bool:
		uploads += 1; return false
	func photo_animation_pixels(_id: int,token: int) -> PackedByteArray:
		var data := PackedByteArray()
		for _i in 4: data.append_array(PackedByteArray([255,0,0,255] if token == 1 else [0,255,0,255]))
		return data

class Owner extends Node3D:
	signal changed
	var _metadata := {"animated":true}
	var _display_request := 1
	var _texture: ImageTexture
	var _full_image: Image
	var _display_result := {}
	var _display_depth_data := {"cached":true}
	var _depth_texture: ImageTexture
	var _stereo_texture: ImageTexture
	var _size := Vector2(2,2)
	var archive_mode := false
	var loading := false
	var depth_requested := false
	var portrait_requested := false
	var spatial_requested := false
	var discarded := 0
	var gallery := Gallery.new()
	var platform := Platform.new()
	func _ensure_full_texture() -> void: pass
	func set_portrait(value: bool) -> void: portrait_requested = value
	func set_spatial(value: bool) -> void: spatial_requested = value
	func set_depth(value: bool) -> void: depth_requested = value
	func _discard_native_depth(_id: int) -> void: discarded += 1

func check(value: bool,message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	for ext in ["avif","avifs","gif","apng","dng","cr2","cr3","nef","nrw","arw","raf","rw2","orf","pef","srw"]:
		check(Info.is_image("https://host/照片."+ext.to_upper()+"?token=1#view"),"New format enters image queue: "+ext)
		check(not Info.is_image("image."+ext+".exe"),"Executable suffix is not an image: "+ext)
	var owner := Owner.new()
	var image := Image.create(2,2,false,Image.FORMAT_RGBA8); image.fill(Color.BLUE); image.generate_mipmaps()
	owner._texture = ImageTexture.create_from_image(image); owner._display_result["image"] = image
	root.add_child(owner)
	var animation := PhotoAnimation.new(owner)
	animation.app_focused = func(): return true
	animation.activate(); animation.tick()
	check(animation.token == 1,"First frame accepted")
	check(owner.platform.uploads == 1,"Complete frame uploaded once")
	animation.tick(); check(owner.platform.uploads == 1,"Repeated polling does not upload an unchanged frame")
	animation.freeze()
	check(animation.paused,"AI freezes animation")
	check(owner._full_image.get_pixel(0,0).r > 0.9,"AI snapshot uses current frame instead of initial poster")
	owner.depth_requested = true; owner.portrait_requested = true; owner.spatial_requested = true
	animation.toggle()
	check(not animation.paused,"Playback resumes")
	check(not owner.depth_requested and not owner.portrait_requested and not owner.spatial_requested,"Resume retires frame-specific AI effects")
	check(owner._display_depth_data.is_empty() and owner.discarded == 1,"Resume invalidates stale depth cache")
	owner.gallery.overview_active = true; owner.platform.report.token = 2
	animation.tick(); check(animation.token == 1 and owner.platform.pauses.back(),"Gallery overview pauses presentation")
	owner.gallery.overview_active = false; animation.tick()
	check(animation.token == 2,"Focused picture resumes current frame")
	animation.freeze(); check(owner._full_image.get_pixel(0,0).g > 0.9,"Later AI snapshot follows the displayed green frame")
	owner.platform.report.ended = true; animation.tick(); check(animation.ended,"Finite animation completion reaches UI")
	animation.toggle(); check(owner.platform.restarts == 1 and not animation.ended,"Replay creates a new playback run")
	owner.archive_mode = true; check(not animation.available(),"Archive pages retain static presentation")
	animation.tick(); check(owner.platform.pauses.back(),"Archive layout suspends the previous focused decoder")
	owner.archive_mode = false; owner.gallery.mode = 4; check(not animation.available(),"Magazine pages retain static presentation")
	animation.tick(); check(owner.platform.pauses.back(),"Magazine layout suspends the decoder")
	owner.gallery.mode = 0; animation.app_focused = func(): return false
	animation.tick(); check(owner.platform.pauses.back(),"Focus loss suspends before polling")
	animation.suspend(); check(owner.platform.pauses.back(),"Application pause works without another process tick")
	animation.close(); check(animation.request == 0,"Close revokes frame presentation")
	owner.free()
	for failure in failures: push_error(failure)
	print("Photo animation: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
