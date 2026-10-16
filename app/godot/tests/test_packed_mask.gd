extends SceneTree
## The video's own Alpha mask, switched on by the user in the fisheye mode panel (official packed
## releases renamed without the "_alpha" marker): it replaces live matting, greys out the bar's
## passthrough button, leaves with the fisheye projection and is remembered per file.
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
	video.media.format = {"width": 8192, "height": 4096}

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
		"The fisheye panel offers the built-in mask beside the lens angles, with its tooltip")
	var lens := button(menu, Menu.MODE_LENS + Menu.LENS_FOVS.size() - 1)
	check(not lens.is_empty() and lens.rect.end.x < packed.rect.position.x, "The lens angles stay, left of the mask button")
	check(tap(menu, Menu.MODE_PACKED) and video.packed_mask_on() and not video.alpha_requested and menu._mode_open,
		"Turning it on uses the file's mask, stops live matting and keeps the panel open")
	check(host.calls.any(func(call): return call[0] == "revise" and call[3] == false), "Live matting is revised off")
	menu.refresh()
	check(button(menu, Menu.MODE_PACKED).base_color == Menu.SELECTED, "The mask button shows it is on")
	menu._mode_open = false; menu.refresh()
	check(not button(menu, 104).enabled and not menu._enabled("alpha"), "The bar's passthrough button is greyed out while the file's mask is in use")
	menu._mode_open = true; menu.refresh()
	check(tap(menu, Menu.MODE_LENS) and video.packed_mask_on() and video.fisheye_fov == Menu.LENS_FOVS[0], "A lens angle does not affect the mask")
	check(bool(video.mode_memory.lookup(video.local_uri).get("packed_mask", false)), "The choice is remembered for this file")
	# Leaving fisheye leaves the mask.
	video.set_projection(Geometry.Geometry.HALF_EQUIRECT)
	check(not video.packed_mask_on() and not video.packed_file, "Another projection turns the built-in mask off")
	menu.refresh()
	check(menu._enabled("alpha"), "The bar's passthrough button returns")
	video.set_packed_mask(true)
	check(not video.packed_mask_on(), "The mask cannot be turned on outside fisheye")
	video.set_projection(Geometry.Geometry.FISHEYE)
	video.set_packed_mask(true)
	check(video.packed_mask_on(), "Back on fisheye it can be turned on again")
	# Reopening restores the user's word, also against the name.
	video.close_video()
	_open(video, "SLR_Your_Queen_4096p_FISHEYE190_x265.mp4")
	check(video.packed_mask_on() and not video.alpha_requested, "Reopening the file restores its built-in mask")
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
	menu.free(); video.free(); main.free()
	print("Packed mask checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
