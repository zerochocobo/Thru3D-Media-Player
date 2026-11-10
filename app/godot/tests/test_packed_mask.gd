extends SceneTree
## Manual six-tile Alpha on 180/fisheye SBS: independent switch, source-space mask,
## exclusive with AI, safe layout changes, and durable per-file preference.
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var calls: Array = []
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, _vulkan: bool, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append(["open", uri, start, stereo, profile, alpha])
		return 7
	func close_mpv_video(id: int) -> void: calls.append(["close", id])
	func set_mpv_playing(id: int, playing: bool) -> void: calls.append(["play", id, playing])
	func revise_mpv_video(id: int, stereo: bool, alpha: bool, profile: String, position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append(["revise", id, stereo, alpha, profile, position])
		return 0

class Layers extends "res://scripts/video_layer.gd":
	func update_session() -> void: pass
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool) -> bool: return true

class LayerVideo extends "res://scripts/mpv_video_display.gd":
	var reopens: Array = []
	func _reopen_on_eye_buffer(position_ms: int, _trigger: String = "") -> void: reopens.append(position_ms)

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}

func tap(menu: Node3D, target: int) -> bool:
	var item := button(menu, target)
	if item.is_empty(): return false
	var centre: Vector2 = item.rect.get_center()
	var point: Vector3 = menu.to_global(Vector3(centre.x, centre.y, 1))
	menu.press_pointer("right_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
	return true

func _initialize() -> void: call_deferred("_run")

func _open(video: Node3D, name: String) -> void:
	video.open_local("file:///" + name, name, 0, true)
	video._waiting_first = false
	video.media.state = "playing"
	video.media.format = {"width": 7680, "height": 3840, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var directory := ProjectSettings.globalize_path("res://../../build/output/packed-mask-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var video := Video.new()
	video.bookmark_store = preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	video.mode_memory = Memory.new(directory.path_join("modes"))
	video.recent_files = Catalog.new(directory.path_join("recent"))
	root.add_child(video)
	video.set_process(false)
	var host := Host.new()
	video.platform = host
	var main := Main.new()
	main.settings_path = directory.path_join("settings.cfg")
	main.video = video
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.action_requested.connect(main._on_menu_action)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu
	menu.toggle()
	# A renamed official release: fisheye SBS by name, no Alpha marker.
	_open(video, "SLR_Your_Queen_4096p_FISHEYE190_x265.mp4")
	video._remember_file = true
	check(video.geometry == Geometry.Geometry.FISHEYE and video.stereo_sbs and not video.packed_file, "Without the marker the file opens as a plain fisheye")
	video.alpha_requested = true # live matting running
	menu._mode_open = true; menu.refresh()
	var packed := button(menu, Menu.MODE_PACKED)
	check(not packed.is_empty() and packed.enabled and menu._tips.get(Menu.MODE_PACKED, "") == "Use the video's own Alpha mask",
		"The mode panel offers the source mask with its tooltip")
	var fish := button(menu, Menu.MODE_PROJECTION + 2)
	check(fish.rect.end.x + 0.10 <= packed.rect.position.x and is_equal_approx(fish.rect.get_center().y, packed.rect.get_center().y),
		"The independent switch sits to the right of fisheye with a visible group gap")
	check(menu.text_snapshot().contains("Native passthrough") and not menu._lit_modes.has(Menu.MODE_PACKED), "Source mask has a visible caption and is not a projection choice")
	check(tap(menu, Menu.MODE_PACKED) and video.packed_mask_on() and not video.alpha_requested and menu._mode_open,
		"Turning it on uses the file's mask, stops live matting and keeps the panel open")
	check(host.calls.any(func(call): return call[0] == "revise" and call[3] == false), "Live matting is revised off")
	menu.refresh()
	check(button(menu, Menu.MODE_PACKED).node.get_child(1).get_child(0).position.x > 0, "The mask switch knob shows it is on")
	menu._mode_open = false; menu.refresh()
	check(not button(menu, 104).enabled and not menu._enabled("alpha"), "The bar's passthrough button is greyed out while the file's mask is in use")
	menu._mode_open = true; menu.refresh()
	check(tap(menu, Menu.MODE_LENS) and video.packed_mask_on() and video.fisheye_fov == Menu.LENS_FOVS[0], "A lens angle does not affect the mask")
	check(bool(video.mode_memory.lookup(video.local_uri).get("packed_mask", false)), "The choice is remembered for this file")
	# The same source mask survives either projection, including material activation.
	video.media.last_pair = {"pts_us": 12000000}
	video.set_projection(Geometry.Geometry.HALF_EQUIRECT)
	check(video.packed_mask_on() and video.material.get_shader_parameter("packed_alpha") == true,
		"180 SBS keeps the source mask active in the real material")
	menu.refresh()
	check(not button(menu, Menu.MODE_PACKED).is_empty() and not menu._enabled("alpha"), "180 offers the same switch and retains AI exclusion")
	var positions: Array = []
	for g in 4: positions.append(button(menu, Menu.MODE_PROJECTION + g).rect.get_center().x)
	video.set_projection(Geometry.Geometry.FISHEYE)
	check(video.packed_mask_on(), "Returning to fisheye does not reset the mask")
	for projection in [0, 3]:
		video.set_projection(projection); menu.refresh()
		check(not video.packed_mask_on() and video.material.get_shader_parameter("packed_alpha") == false and button(menu, Menu.MODE_PACKED).is_empty(),
			"Hidden mode stops the mask: " + str(projection))
		for g in 4: check(is_equal_approx(button(menu, Menu.MODE_PROJECTION + g).rect.get_center().x, positions[g]), "Projection positions stay fixed when switch hides")
		video.set_packed_mask(true)
		check(not video.packed_mask_on(), "Hidden projection cannot enable the mask")
		video.set_projection(1); video.set_stereo_layout(1); video.set_packed_mask(true)
	for layout in [0, 2, 3, 4]:
		video.set_stereo_layout(layout); menu.refresh()
		check(not video.packed_mask_on() and not button(menu, Menu.MODE_PACKED).enabled and menu._enabled("alpha"),
			"Unsupported source layout clears native mask and restores AI: " + str(layout))
		video.set_packed_mask(true)
		check(not video.packed_mask_on(), "Unsupported layout cannot enable source mask")
		video.set_stereo_layout(1); video.set_packed_mask(true)
	check(video.material.get_shader_parameter("packed_size") == Vector2(3072, 1536), "8K sample uses the established six-tile mask dimensions")
	video.media.format.unapplied_rotation_degrees = 90; video._apply_packed()
	check(video.material.get_shader_parameter("packed_alpha") == false, "Rotated mask data remains rejected")
	video.media.format.unapplied_rotation_degrees = 0; video._apply_packed()
	check(video.material.get_shader_parameter("packed_alpha") == true, "Valid source resumes the mask")
	# Reopening restores the user's word, also against the name.
	video.close_video()
	_open(video, "SLR_Your_Queen_4096p_FISHEYE190_x265.mp4")
	check(video.geometry == 1 and video.packed_mask_on() and not video.alpha_requested, "Reopening restores 180 and its mask despite the fisheye filename")
	video._reopen_after_context_loss(video.local_uri, video.display_name, 12000, true)
	check(video.geometry == 1 and video.packed_mask_on() and not video.alpha_requested, "Context recovery retains manual 180 mask without AI")
	video._reopen_at(15000, false)
	check(video.geometry == 1 and video.packed_mask_on() and not video.alpha_requested, "Render-path recovery retains manual 180 mask without AI")
	video._remember_file = true
	video.set_packed_mask(false)
	video.close_video()
	_open(video, "SLR_Your_Queen_4096p_FISHEYE190_x265.mp4")
	check(not video.packed_file, "Turned off, it stays off")
	video.close_video()
	_open(video, "SLR_CallOnHer_4096p_FISHEYE190_alpha.mp4")
	check(video.packed_mask_on(), "A file named with the Alpha marker starts with its mask on")
	video._remember_file = true
	video.set_packed_mask(false)
	video.close_video()
	_open(video, "SLR_CallOnHer_4096p_FISHEYE190_alpha.mp4")
	check(not video.packed_file, "The user's off wins over the marker")
	check(Memory.valid_mode({"profile": "320x320", "geometry": 2, "stereo_sbs": true, "swap_eyes": false, "alpha_requested": false, "packed_mask": true})
		and not Memory.valid_mode({"profile": "320x320", "geometry": 2, "stereo_sbs": true, "swap_eyes": false, "alpha_requested": false, "packed_mask": 1}),
		"Saved modes accept a boolean built-in mask only")
	video.close_video()
	_open(video, "sample [8K 3DMR] unmarked in Passt.mp4")
	video.set_projection(1); video.set_stereo_layout(1); video.set_packed_mask(true)
	check(video.packed_mask_on() and not video.alpha_requested, "Unmarked 180 SBS sample is manually selectable")
	video.close_video()
	_open(video, "sample [8K 3DMR] unmarked in Passt.mp4")
	check(video.geometry == 1 and video.packed_mask_on(), "Unmarked sample's projection and mask preference reopen together")
	var photo := preload("res://scripts/photo_menu.gd").new()
	photo.state_provider = func(): return {"geometry": 2, "stereo": true, "has_video": true, "packed_mask_available": true}
	root.add_child(photo); photo.set_process(false); photo._mode_open = true; photo.visible = true; photo.refresh()
	check(button(photo, Menu.MODE_PACKED).is_empty(), "Photo mode does not acquire a video mask switch")
	photo.free()
	menu.free(); video.free(); main.free()
	# 180 normally decodes directly to a compositor layer; native masks need sampled pixels.
	var layered := LayerVideo.new(); root.add_child(layered); layered.set_process(false)
	layered.platform = Host.new(); _open(layered, "layer_180_SBS.mp4")
	layered.video_layer = Layers.new(null); layered._layer_session = true; layered.media.frame_counter = 1
	check(layered._layer_presentation(), "Plain 180 can use its compositor layer")
	layered.set_packed_mask(true)
	check(not layered._layer_presentation(), "Native source mask prevents opaque direct layer playback")
	layered._update_layer()
	check(layered.reopens == [-1], "Native activation requests eye-buffer playback at the current position")
	layered.set_packed_mask(false)
	check(layered._layer_presentation(), "Disabling native mask allows the normal layer again")
	layered.video_layer = null; layered._layer_session = false; layered.free()
	print("Packed mask checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
