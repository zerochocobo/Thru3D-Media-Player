extends "res://tests/test_photo_presentation.gd"
## Exercise production photo selection, native-result gates, persistence and real ray controls.
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const VideoMenu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const VideoFixtures := preload("res://tests/test_file_mode_memory.gd")
const Default := preload("res://scripts/photo_mode_default.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/photo-mode-default")
var serial := 0

func current(photo: Node3D) -> Dictionary:
	var mode: Dictionary = photo.current_lock()
	mode.swap_eyes = photo.swap_eyes
	return Default.clean(mode)

func show_photo(photo: Node3D, title: String = "Photo", extra: Dictionary = {}, saved: Dictionary = {}, retained: Dictionary = {}) -> void:
	serial += 1
	var uri := "file:///photo-default-%d.jpg" % serial
	var at: int = photo.queue.size()
	photo.queue.append({"uri":uri, "title":title})
	if not retained.is_empty(): photo.queue[at]["retained_source"] = retained
	if not saved.is_empty(): photo.mode_memory.remember(uri, saved)
	check(photo._select(at), "Foreground selection starts")
	var data := result(); data.info.merge(extra, true)
	photo._prepare_display(data, {"id":photo._request,"index":at,"serial":photo._serial})
	photo._process(.5)
	check(not photo.loading and not photo._presentation_pending, "Foreground photo is displayed")

func ray_toggle(menu: Node3D, hand: String) -> void:
	var buttons: Array = menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)
	check(buttons.size() == 1, "Exactly one reuse switch")
	if buttons.is_empty(): return
	var button: Dictionary = buttons[0]
	var origin: Vector3 = button.node.to_global(Vector3(.46, 0, 1))
	var direction: Vector3 = -button.node.global_basis.z
	menu.press_pointer(hand, origin, direction, true)
	menu.release_pointer(hand, origin, direction, true)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	color = Image.create(320, 160, false, Image.FORMAT_RGBA8); color.fill(Color(.3,.4,.5))
	proxy = null
	depth = Image.create(518,518,false,Image.FORMAT_RF); depth.fill(Color(.7,0,0))
	stereo = Image.create(640,160,false,Image.FORMAT_RGBA8); stereo.fill(Color(.2,.4,.6))
	var main := Main.new(); main.settings_path = output.path_join("preferences.cfg")
	var photo := make_photo(false); photo.auto_depth = false; main.photo = photo
	photo.mode_memory = Photo.ModeMemory.new(output.path_join("modes-%d" % Time.get_ticks_usec()))
	photo.last_mode_changed.connect(main._on_last_photo_mode_changed)
	photo.reuse_last_mode_changed.connect(main._on_reuse_last_photo_mode_changed)
	photo.mode_lock_changed.connect(main._on_mode_lock_changed.bind("photo"))
	photo.load_last_mode_preferences(main.settings)
	check(not photo.reuse_last_mode and photo.last_mode.is_empty(), "Fresh and upgraded users default off without video migration")
	for invalid in [null, {}, {"geometry":1.5,"layout":1,"fisheye_fov":180}, {"geometry":1,"layout":3,"fisheye_fov":180},
		{"geometry":1,"layout":4,"fisheye_fov":180}, {"geometry":1,"layout":2,"fisheye_fov":90}, {"geometry":1,"layout":2,"fisheye_fov":180,"swap_eyes":"true"}]:
		check(Default.clean(invalid).is_empty(), "Invalid or video-only layouts are ignored")
	main.settings.set_value("video", "reuse_last_mode", true)
	main.settings.set_value("video", "last_mode", {"geometry":2,"layout":4,"fisheye_fov":220,"swap_eyes":true})
	photo.load_last_mode_preferences(main.settings)
	check(not photo.reuse_last_mode and photo.last_mode.is_empty(), "Video preferences cannot initialize photo preferences")
	photo.set_reuse_last_mode(true)
	check(photo.last_mode.is_empty(), "Enabling before any photo does not capture a synthetic mode")
	show_photo(photo)
	check(photo.last_mode.geometry == 0 and photo.last_mode.layout == 0, "No prior photo mode falls back to normal flat inference")
	photo.set_reuse_last_mode(false)
	photo.set_projection(2); photo.set_stereo_layout(2); photo.set_fisheye_fov(220); photo.toggle_eye_order()
	photo.toggle_mode_lock()
	var expected := current(photo)
	main._on_photo_adjustment("reuse_last_mode", true)
	check(photo.reuse_last_mode and photo.mode_lock.is_empty() and photo.last_mode == expected and current(photo) == expected,
		"Enabling captures the displayed mode and removes only the photo lock without changing the picture")
	var config := ConfigFile.new(); config.load(main.settings_path)
	var restarted := Photo.new(); restarted.load_last_mode_preferences(config)
	check(restarted.reuse_last_mode and restarted.last_mode == expected and restarted.mode_lock.is_empty(), "Photo switch and full mode persist across restart")
	restarted.free()
	check(config.get_value("video", "last_mode") == main.settings.get_value("video", "last_mode"), "Saving photo preferences preserves video preferences")
	for projection in range(4):
		for layout in range(3):
			photo.set_projection(projection); photo.set_stereo_layout(layout)
			expected = current(photo)
			show_photo(photo)
			check(current(photo) == expected and photo.last_mode == expected, "Next unnamed photo follows manual projection/layout: %d/%d" % [projection,layout])
	show_photo(photo, "flat_2d.jpg")
	check(photo.geometry == 0 and not photo.stereo_sbs and photo.last_mode == current(photo), "Explicit filename wins and seeds the next ordinary photo")
	photo.set_projection(3); photo.set_stereo_layout(2)
	show_photo(photo, "clip_180.jpg")
	check(photo.geometry == 1 and not photo.top_bottom, "Partial filename does not borrow the last TB layout")
	var saved := {"geometry":3,"stereo_sbs":true,"top_bottom":true,"swap_eyes":true,"fisheye_fov":200,"profile":"320x320","alpha_requested":false}
	show_photo(photo, "flat_2d.jpg", {}, saved)
	check(photo.geometry == 3 and photo.top_bottom and photo.swap_eyes and photo.last_mode == current(photo), "Per-photo correction beats filename and default, then becomes the last mode")
	show_photo(photo, "Photo", {"capture_mode":{"version":1,"geometry":2,"stereo_sbs":true,"fisheye_fov":190}})
	check(photo.geometry == 2 and photo.stereo_sbs and photo.fisheye_fov == 190, "Exported capture format wins over the default")
	photo.set_projection(0); photo.set_stereo_layout(0)
	show_photo(photo, "Photo", {"panorama":true})
	check(photo.geometry == 3 and not photo.stereo_sbs, "Tagged panorama keeps its projection despite a flat fallback")
	expected = photo.last_mode.duplicate()
	show_photo(photo, "Photo", {"native_stereo":true})
	check(photo.geometry == 0 and photo.stereo_sbs and photo.last_mode == expected, "Native spatial photo neither inherits nor replaces the ordinary photo default")
	for layout in [0,1]:
		show_photo(photo, "Photo", {}, {}, {"projection":"flat","layout":layout})
		check(photo.last_mode == expected and photo.geometry == 0, "Temporary mono/stereo retained image does not seed the ordinary default")
	var retained_at: int = photo.queue.size()
	photo.queue.append({"uri":"file:///retained.jpg","title":"Photo","retained_source":{"projection":"flat","layout":1}})
	check(photo._resolved_mode(retained_at, {}).geometry == 0 and photo._resolved_mode(retained_at, {}).stereo_sbs, "Retained source keeps its own projection/layout")
	photo.archive_mode = true
	check(photo._resolved_mode(retained_at-1, {}).geometry == 0, "Single-page reading does not inherit the photo fallback")
	photo._last_mode_dirty = true; photo._remember_last_mode()
	check(photo.last_mode == expected, "Reading does not seed ordinary defaults")
	photo.archive_mode = false
	photo.gallery.mode = Photo.Gallery.Layout.MAGAZINE
	check(photo._resolved_mode(retained_at-1, {}).geometry == 0 and not photo._resolved_mode(retained_at-1, {}).stereo_sbs, "Magazine spread remains flat mono")
	photo.gallery.mode = Photo.Gallery.Layout.SINGLE
	show_photo(photo)
	photo.set_projection(0); photo.set_stereo_layout(0)
	show_photo(photo)
	check(photo.geometry == 0 and not photo.stereo_sbs and photo.last_mode.geometry == 0 and photo.last_mode.layout == 0,
		"Returning from VR to 2D updates both next-photo fallback and persistent preference")
	var before: Dictionary = photo.last_mode.duplicate()
	var at: int = photo.queue.size(); photo.queue.append({"uri":"file:///failed.jpg","title":"360_SBS.jpg"})
	photo._select(at)
	photo._on_ready(photo._request, JSON.stringify({"state":"error"}))
	photo._process(.5)
	check(photo.last_mode == before, "A failed selection does not replace the successful mode")
	show_photo(photo)
	var old_id: int = photo._request
	photo.queue.append({"uri":"file:///delayed.jpg","title":"360_SBS.jpg"}); photo._select(photo.queue.size()-1)
	var delayed_id: int = photo._request
	show_photo(photo)
	photo._on_ready(delayed_id, JSON.stringify({"state":"ready","path":"unused","panorama":true}))
	photo._on_metadata(old_id, photo._serial-1, photo.index, {"width":640,"height":320,"panorama":true})
	check(photo.last_mode == before and photo._next_decode.is_empty(), "Cancelled and stale source callbacks do not change the last mode")
	photo.gallery.mode = Photo.Gallery.Layout.WALL; photo.gallery.focus = -1
	photo.geometry = 3; photo._last_mode_dirty = true; photo._remember_last_mode()
	check(photo.last_mode == before, "An unexpanded gallery card cannot seed the default")
	photo.gallery.focus = photo.index; photo.gallery.progress = 1; photo.gallery.returning = false
	photo._remember_last_mode()
	check(photo.last_mode.geometry == 3, "A successfully expanded foreground photo can seed the default")
	photo.gallery.mode = Photo.Gallery.Layout.SINGLE
	Privacy.configure_file_settings(Privacy.NONE)
	photo.set_projection(0); photo.set_stereo_layout(0)
	check(photo.last_mode.geometry == 0 and photo.last_mode.layout == 0, "Global layout preference is independent of per-file memory privacy")
	Privacy.configure_file_settings(Privacy.ALL)
	photo.set_reuse_last_mode(false); photo.set_projection(3)
	show_photo(photo)
	check(photo.geometry == 0, "Disabling restores ordinary automatic selection")
	photo.set_reuse_last_mode(true); photo.toggle_mode_lock()
	config.load(main.settings_path)
	check(not photo.reuse_last_mode and not config.get_value("photo","reuse_last_mode",true) and not photo.mode_lock.is_empty(), "Fixed photo lock persistently disables follow-last")
	photo._unlock_mode(); photo.set_reuse_last_mode(true)
	# Real video controller and Main persistence callbacks, with the same anonymous source as video tests.
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.platform = VideoFixtures.Host.new()
	video.mode_memory = Video.ModeMemory.new(output.path_join("video-modes-%d" % Time.get_ticks_usec()))
	video.last_mode_changed.connect(main._on_last_video_mode_changed)
	video.reuse_last_mode_changed.connect(main._on_reuse_last_video_mode_changed)
	video.load_last_mode_preferences(main.settings)
	var photo_before: Dictionary = photo.last_mode.duplicate()
	video.open_local("file:///independent.mp4", "Clip")
	video.media.format = {"width":1920,"height":1080}; video.media.frame_counter = 1; video._complete_layout()
	video.set_projection(1); video.set_stereo_layout(1)
	check(photo.last_mode == photo_before, "Playing and changing video cannot modify the photo last mode")
	var video_before: Dictionary = video.last_mode.duplicate()
	photo.set_projection(2); photo.set_fisheye_fov(200)
	check(video.last_mode == video_before and video.reuse_last_mode, "Changing photo mode cannot modify the video mode or switch")
	var menu := Menu.new(); menu.state_provider = photo.snapshot; main.photo_menu = menu
	menu.setting_requested.connect(main._on_photo_adjustment)
	root.add_child(menu); menu.set_process(false); menu.visible = true; menu._mode_open = true
	var video_menu := VideoMenu.new(); root.add_child(video_menu); video_menu.set_process(false); video_menu.visible = true; video_menu._mode_open = true
	for language in ["zh","zh_Hant","ja","en"]:
		I18n.use(language)
		for projection in range(4):
			photo.set_projection(projection); menu.refresh()
			video_menu.state_provider = func(): return {"geometry":projection,"has_video":true,"reuse_last_mode":photo.reuse_last_mode}
			video_menu.refresh()
			var button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)[0]
			var reference: Dictionary = video_menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)[0]
			check(button.rect == reference.rect and button.node.position == reference.node.position, "Photo switch has exactly the video position and hit rectangle")
			check(button.node.get_child(0).text == I18n.t(Default.TITLE) and menu._tips[Menu.MODE_REUSE] == I18n.t(Default.HINT), "Photo title and tooltip are localized")
			var label: Label3D = button.node.get_child(0)
			check(menu.text_width(label.text,label.font_size) < .9, "Localized title fits before the shared switch")
			for child in range(button.node.get_child_count()):
				check(button.node.get_child(child).position == reference.node.get_child(child).position, "Caption and switch share the video geometry")
			for other in menu._buttons:
				if other.target != Menu.MODE_REUSE: check(not button.rect.intersects(other.rect), "Switch avoids every other photo pointer target")
			var rect: Rect2 = button.rect
			var mode_before := current(photo); var enabled_before: bool = photo.reuse_last_mode
			ray_toggle(menu, "left")
			check(photo.reuse_last_mode != enabled_before and current(photo) == mode_before and menu._mode_open, "Left ray changes the photo preference without closing popup or changing image")
			check(menu._buttons.filter(func(b): return b.target == Menu.MODE_REUSE)[0].rect == rect, "Switch stays stationary after toggling")
			ray_toggle(menu, "right")
			check(photo.reuse_last_mode == enabled_before and video.last_mode == video_before, "Right ray toggles back without changing video")
	I18n.use("en")
	menu.free(); video_menu.free(); photo.free(); video.free(); main.free()
	cache_compatibility()
	for failure in failures: push_error(failure)
	print("Photo mode default: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func cache_compatibility() -> void:
	var photo := make_photo(false)
	photo.set_reuse_last_mode(true)
	photo.last_mode = {"geometry":1,"layout":1,"fisheye_fov":180,"swap_eyes":false}
	var data := result(); data["ready_texture"] = ImageTexture.create_from_image(color)
	var pair := converted(); pair["source_id"] = 501
	pair["ready_depth"] = ImageTexture.create_from_image(depth); pair["ready_stereo"] = ImageTexture.create_from_image(stereo)
	data["depth_data"] = pair
	var entry := {"id":501,"info":data.info,"result":data,"decoded":true,"depth_data":pair}
	photo._prefetched[1] = entry
	photo.render_cache.job = {"entry":entry,"index":1,"epoch":photo._cache_epoch,"strength":photo.depth_strength,"rotation":0,"key":"ready_stereo"}
	check(not photo.render_cache._valid_target(), "A pending generated-eye upload is invalid after switching the fallback to VR")
	photo.render_cache.job.key = "ready_texture"
	check(photo.render_cache._valid_target(), "The same fallback change preserves a compatible source-colour upload")
	photo.render_cache.cancel()
	var before: Dictionary = photo.last_mode.duplicate()
	check(photo.render_cache.ready(entry,1) and photo.last_mode == before, "Preparing cached colour can read the fallback without changing it")
	check(photo._select(1), "Warm colour can be selected with inherited VR")
	photo._process(.5)
	check(photo.geometry == 1 and photo.stereo_sbs and photo._display_depth_data.is_empty() and not photo.depth_requested,
		"VR fallback reuses cached colour and discards an incompatible generated stereo pair")
	photo.auto_depth = false; photo.set_projection(0); photo.set_stereo_layout(0)
	photo.auto_depth = true
	check(photo._requires_depth(2, {}), "Flat mono fallback still obeys the independent automatic 3D preference")
	photo.free()
