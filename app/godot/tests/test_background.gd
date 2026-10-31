extends SceneTree
const Background := preload("res://scripts/app_background.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true
class CapturedPhotoHost extends RefCounted:
	# Same ready payload as PhotoBridge after CaptureFormat reads a screenshot's PNG metadata.
	var ready: Callable
	var mode := {}
	var sequence := 100
	func open_photo(uri: String) -> int:
		sequence += 1
		ready.call_deferred(sequence, JSON.stringify({"state":"ready", "path":uri.trim_prefix("file://"), "capture_mode":mode}))
		return sequence
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
var checks := 0
var failures: Array[String] = []
var folder := "user://background_test_%d" % Time.get_ticks_usec()
var output := ProjectSettings.globalize_path("res://../../build/output/background-preview")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func field_tap(menu: Node3D, target: int) -> void:
	for button in menu._buttons:
		if button.target == target:
			var origin: Vector3 = button.node.global_position + button.node.global_basis.z
			var direction: Vector3 = -button.node.global_basis.z
			menu.press_pointer("left_hand", origin, direction, true)
			menu.release_pointer("left_hand", origin, direction, true)
			return

func _initialize() -> void: call_deferred("_run")
func settle(background: Node) -> void:
	var deadline := Time.get_ticks_msec()+15000
	while background.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not background.loading, "Background loading completes")
func photo_ready(main: Node) -> void:
	var deadline := Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not main.photo.loading and main.photo.error.is_empty(), "PNG async decode completes")
func delete_target(main: Node) -> int:
	for index in main.recent_menu.rows.size():
		if main.recent_menu.rows[index].get("setting", []) == ["background_remove", true]: return main.recent_menu.ROW_BASE + index
	return -1

func check_png_backgrounds(main: Node, viewport: SubViewport) -> void:
	var host := CapturedPhotoHost.new()
	host.ready = main.photo._on_ready
	main.photo.platform = host
	main.photo.auto_depth = false
	main.photo.mode_lock = {"geometry":0,"layout":0,"fisheye_fov":180}
	var source := ProjectSettings.globalize_path(folder.path_join("screenshot_20261020_001200_000.png"))
	var config := ConfigFile.new()
	var cases := [
		[Vector2i(512,256), false, false, false],
		[Vector2i(1024,256), true, false, false], [Vector2i(1024,256), true, false, true],
		[Vector2i(512,512), true, true, false], [Vector2i(512,512), true, true, true],
		[Vector2i(512,256), true, false, false, 1], [Vector2i(512,256), true, false, true, 1],
		[Vector2i(256,512), true, true, false, 1], [Vector2i(256,256), true, false, false, 1],
		[Vector2i(512,256), true, false, false], [Vector2i(512,256), true, true, true]]
	for index in cases.size():
		var item: Array = cases[index]
		var image := Image.create(item[0].x,item[0].y,false,Image.FORMAT_RGB8)
		image.fill(Color.RED)
		if item[1]:
			image.fill_rect(Rect2i(0,item[0].y/2,item[0].x,item[0].y/2) if item[2] else Rect2i(item[0].x/2,0,item[0].x/2,item[0].y),Color.BLUE)
		image.save_png(source)
		var geometry: int = item[4] if item.size()>4 else 3
		host.mode = {"version":1,"geometry":geometry,"stereo_sbs":item[1],"top_bottom":item[2],"swap_eyes":item[3]}
		main._on_library_chosen("file://"+source,source.get_file())
		await photo_ready(main)
		check(main.photo.geometry == geometry and main.photo.stereo_sbs == item[1] and main.photo.can_background(), "Captured 180/360 mono/full/half stereo PNG enables background %d" % index)
		main.photo_menu._activate(11)
		var buttons: Array = main.photo_menu._buttons.filter(func(button): return button.target == main.photo_menu.PHOTO_BACKGROUND)
		check(buttons.size()==1 and buttons[0].enabled, "Screenshot settings expose an enabled background action %d" % index)
		field_tap(main.photo_menu, main.photo_menu.PHOTO_BACKGROUND)
		await settle(main.photo_background)
		check(main.photo_background.error.is_empty() and main.photo_background.choice == "custom", "PNG photo background import succeeds %d" % index)
		check(main.photo_active and main.player_menu == main.photo_menu and main.photo.panel.visible, "Photo background import retains the current image and controls %d" % index)
		check(main.background.choice == "passthrough", "Photo import leaves the global background unchanged %d" % index)
		var saved := str(main.photo_background.custom_path)
		var header := preload("res://scripts/image_info.gd").read_header(saved)
		check(header.width == header.height * 2, "Stored sky is one complete 2:1 eye %d" % index)
		var sky_image: Image = main.photo_background._custom.get_image()
		var color := sky_image.get_pixel(sky_image.get_width()/2,sky_image.get_height()/2)
		check(color.is_equal_approx(Color.BLUE if item[3] else Color.RED), "Sky respects selected left eye and swap %d" % index)
		var restored := Background.new()
		restored.directory = main.photo_background.directory; restored.choice = "custom"; restored.custom_path = saved; restored.custom_orientation = main.photo_background.custom_orientation
		root.add_child(restored); await settle(restored)
		check(restored.error.is_empty() and restored.ready_sky()!=null and restored._custom.get_size() == main.photo_background._custom.get_size(), "Normalized PNG sky reloads without cropping twice %d" % index)
		restored.free()
		check(FileAccess.file_exists(source), "PNG source survives import %d" % index)
	# Deleting an active custom sky requires its own two trigger releases.
	main._on_photo_action("global_background"); await settle(main.background)
	check(main.photo_active and main.photo.panel.visible, "Global PNG import keeps viewing active")
	main._close_current_media(false)
	main._show_full_library(); main.recent_menu.section=main.recent_menu.Section.SETTINGS; main.recent_menu.tab=main.recent_menu.BACKGROUND_TAB; main.recent_menu.refresh()
	if DisplayServer.get_name() != "headless": await frame(viewport,"custom-delete")
	var saved := str(main.background.custom_path)
	check(delete_target(main)>=0, "Custom background has a delete row")
	field_tap(main.recent_menu,delete_target(main))
	check(main.background.has_custom() and FileAccess.file_exists(saved), "First delete tap only confirms")
	if DisplayServer.get_name() != "headless": await frame(viewport,"custom-delete-confirm")
	field_tap(main.recent_menu,delete_target(main)); await settle(main.background)
	check(not main.background.has_custom() and not FileAccess.file_exists(saved) and FileAccess.file_exists(source), "Confirmed deletion removes only the private sky copy")
	check(main.background.choice=="belfast" and main.display.environment.background_mode==Environment.BG_SKY, "Deleting active sky restores built-in scenery")
	config.load(main.settings_path)
	check(config.get_value("appearance","custom_path")=="" and config.get_value("appearance","custom_title")=="" and config.get_value("appearance","background")=="belfast", "Deletion clears persisted reference and selection")
	check(delete_target(main)<0 and not main.recent_menu.rows[0].choices.any(func(option):return option.value=="custom"), "Deleted background disappears from menu choices")
	# A completed worker must not close another photo or override a later background choice.
	host.mode = {"version":1,"geometry":3}
	main._on_library_chosen("file://"+source,source.get_file()); await photo_ready(main)
	var source_bytes := FileAccess.get_file_as_bytes(source)
	FileAccess.open(source,FileAccess.WRITE).store_string("broken")
	main._on_photo_action("global_background"); await settle(main.background)
	check(not main.background.error.is_empty() and main.photo_active and main.photo.panel.visible and main.background.choice=="belfast", "Failed background decode preserves the photo and previous sky")
	FileAccess.open(source,FileAccess.WRITE).store_buffer(source_bytes)
	main.background.set_process(false)
	main._on_photo_action("global_background")
	check(not main.background.remove_custom(), "Deletion cannot race a pending background import")
	main._on_setting_changed("background","dark")
	main._on_library_chosen("file://"+source,source.get_file()); await photo_ready(main)
	main.background.set_process(true); await settle(main.background)
	check(main.photo_active and main.photo.panel.visible and main.background.choice=="dark" and main.background.error.is_empty(), "Retry clears failure and late import preserves reopened photo and newer preset")
	saved = main.background.custom_path
	main._show_full_library(); main.recent_menu.section=main.recent_menu.Section.SETTINGS; main.recent_menu.tab=main.recent_menu.BACKGROUND_TAB; main.recent_menu.refresh()
	field_tap(main.recent_menu,delete_target(main)); field_tap(main.recent_menu,delete_target(main))
	check(main.background.choice=="dark" and not FileAccess.file_exists(saved) and main.photo.panel.visible, "Deleting inactive custom sky preserves selected preset and open photo")
	# Unsupported projections and cropped panoramas still do not offer a sky.
	main.photo.set_projection(1); check(not main.photo.can_background(), "VR180 PNG cannot supply a complete background")
	main.photo.set_projection(3)
	main.photo._metadata.merge({"FullPanoWidthPixels":1024,"FullPanoHeightPixels":512,"CroppedAreaImageWidthPixels":512,"CroppedAreaImageHeightPixels":256,"CroppedAreaLeftPixels":0,"CroppedAreaTopPixels":0},true)
	check(not main.photo.can_background(), "Partial GPano cannot supply a complete background")
	main._close_current_media(); main.photo.platform = null
	# A tampered saved path must never turn background deletion into source deletion.
	main.background.custom_path = source
	main._on_setting_changed("background_remove",true)
	check(FileAccess.file_exists(source) and main.background.custom_path.is_empty(), "Deletion never removes an external original path")
func frame(viewport: SubViewport, name: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image

func check_panorama_direction() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256,256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	viewport.add_child(world)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	# Distinguish the image centre from its joined edges in the real sky renderer.
	var pixels := Image.create(512,256,false,Image.FORMAT_RGB8)
	pixels.fill(Color.BLUE)
	pixels.fill_rect(Rect2i(0,0,64,256),Color.RED)
	pixels.fill_rect(Rect2i(448,0,64,256),Color.RED)
	pixels.fill_rect(Rect2i(224,0,64,256),Color.GREEN)
	var material := PanoramaSkyMaterial.new()
	material.panorama = ImageTexture.create_from_image(pixels)
	var sky := Sky.new()
	sky.sky_material = material
	var display := XrDisplay.new()
	display.configure(viewport, world.environment, null, true)
	display.set_scenery(sky)
	var front: Image = await frame(viewport,"direction-front")
	check(front.get_pixel(128,128).g > .8 and front.get_pixel(128,128).r < .1, "Global sky 0 degrees faces the panorama centre")
	camera.rotation.y = PI
	var back: Image = await frame(viewport,"direction-back")
	check(back.get_pixel(128,128).r > .8 and back.get_pixel(128,128).g < .1, "Global panorama seam is behind the viewer")
	camera.rotation.y = 0
	display.set_scenery(sky, 180)
	var rotated: Image = await frame(viewport,"direction-rotated")
	check(rotated.get_pixel(128,128).r > .8 and rotated.get_pixel(128,128).g < .1, "User 180-degree rotation still rotates relative to the image centre")
	viewport.queue_free(); await process_frame

func check_first_run_backgrounds() -> void:
	var main := Main.new()
	main.settings_path = folder.path_join("first-run.cfg")
	root.add_child(main)
	main.set_process(false)
	main.report_timer.stop()
	check(main.background.choice == "cinema", "Fresh settings select the cinema without a manual background change")
	var deadline := Time.get_ticks_msec() + 15000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline:
		await create_timer(.01).timeout
	check(main.cinema_environment.is_ready and main.cinema_environment.active, "Fresh launch loads and presents the bundled cinema")
	check(main.photo_background.choice == main.photo_menu.SCENERIES[0], "Fresh photo background selects the first panorama independently")
	await settle(main.photo_background)
	main.photo_active = true
	main._update_background()
	check(not main.cinema_environment.active and main._active_background() == main.photo_background, "Entering photo mode hides the default cinema")
	check(main.photo_background.ready_sky() != null and main.display.environment.background_mode == Environment.BG_SKY, "Photo mode displays a loaded panorama instead of a black background")
	main.photo_active = false
	main._update_background()
	check(main.cinema_environment.active and main.background.choice == "cinema", "Leaving photo mode restores the default cinema")
	main.queue_free()
	await process_frame

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	DirAccess.make_dir_recursive_absolute(output)
	await check_first_run_backgrounds()
	if DisplayServer.get_name() != "headless": await check_panorama_direction()
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "zh")
	config.set_value("alpha", "model", "quality")
	config.save(folder.path_join("settings.cfg"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280,800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var main := Main.new()
	main.settings_path = folder.path_join("settings.cfg")
	viewport.add_child(main)
	check(main.settings.get_value("alpha", "model") == "fast" and main.video.profile == main.video.AUTOMATIC_PROFILE, "Legacy quality model migrates to the unified playback configuration")
	main.photo.history_enabled = false
	main.background.directory = folder.path_join("backgrounds")
	main.photo_background.directory = folder.path_join("photo-backgrounds")
	check(main.background.choice == "dark" and main.display.environment.background_mode == Environment.BG_COLOR, "Saved dark background applies at startup")
	main._on_setting_changed("background", "belfast")
	await settle(main.background)
	check(main.display.environment.background_mode == Environment.BG_SKY and not viewport.transparent_bg, "Belfast is opaque application sky")
	check(main.background._builtin.get_size() == Vector2(8192,4096), "Packaged sky retains full 8K dimensions")
	main._show_recent_menu()
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB
	main.recent_menu.refresh()
	check(main.recent_menu.rows[0].key == "background" and main.recent_menu.rows[0].value == "belfast", "Background selection is shown in one settings field")
	main.recent_menu.stick_scroll(-1,.25)
	check(main.background.choice == "belfast", "Menu stick scroll never changes background selection")
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "open" and item.key == "background": field_tap(main.recent_menu, target); break
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "choose" and item.key == "background" and item.value == "dark": field_tap(main.recent_menu, target); break
	check(main.background.choice == "dark", "Same-hand ray/trigger switches background")
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "open" and item.key == "background": field_tap(main.recent_menu, target); break
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "choose" and item.key == "background" and item.value == "morning": field_tap(main.recent_menu, target); break
	await settle(main.background)
	check(main.background.choice == "morning" and main.background._builtin.resource_path == Background.MORNING,
		"Same-hand ray/trigger selects the morning sky texture")
	check(main.background._builtin.get_size() == Vector2(8192,4096) and main.display.environment.background_mode == Environment.BG_SKY,
		"Morning sky renders at its full 8K dimensions")
	check(main.recent_menu.rows.any(func(row): return row.get("key") == "background_yaw") and
		main.recent_menu.rows.any(func(row): return row.get("key") == "background_brightness"), "Morning sky retains direction and brightness controls")
	config.load(main.settings_path)
	check(config.get_value("appearance","background") == "morning", "Morning sky selection persists")
	if DisplayServer.get_name() != "headless":
		await frame(viewport,"morning-settings")
		main.recent_menu.dismiss()
		await frame(viewport,"morning")
	main.recent_menu.visible = true; main.recent_menu.refresh()
	check(main.recent_menu.rows[0].choices[2].value == "night", "Milky Way panorama is the third global background choice")
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "open" and item.key == "background": field_tap(main.recent_menu, target); break
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "choose" and item.key == "background" and item.value == "night": field_tap(main.recent_menu, target); break
	await settle(main.background)
	check(main.background.choice == "night" and main.background._builtin != null and main.background._builtin.resource_path == Background.NIGHT and
		main.background._builtin.get_size() == Vector2(6000,3000), "Ray selection loads the original 6K Milky Way panorama")
	check(main.recent_menu.find_children("*", "Label3D", true, false).any(func(label): return label.text.contains("ESO/S. Brunier")), "Global Milky Way panel visibly credits the photographer")
	check(main.recent_menu.rows.any(func(row): return row.get("key") == "background_yaw") and
		main.recent_menu.rows.any(func(row): return row.get("key") == "background_brightness"), "Night background exposes direction and brightness controls")
	var night_config := ConfigFile.new(); night_config.load(main.settings_path)
	var night_preset := Background.new(); night_preset.choice = str(night_config.get_value("appearance", "background"))
	viewport.add_child(night_preset); await settle(night_preset)
	check(night_preset.choice == "night" and night_preset._builtin != null and night_preset._builtin.resource_path == Background.NIGHT, "Saved night background loads in a fresh instance")
	night_preset.free()
	if DisplayServer.get_name() != "headless":
		await frame(viewport,"night-settings")
		main.recent_menu.dismiss()
		await frame(viewport,"night")
	# Switch while the next built-in request may still be pending; only the last choice wins.
	main._on_setting_changed("background", "belfast")
	main._on_setting_changed("background", "dark")
	main._on_setting_changed("background", "night")
	main._on_setting_changed("background", "morning")
	await settle(main.background)
	check(main.background.choice == "morning" and main.background._builtin.resource_path == Background.MORNING and
		main.background.error.is_empty(), "Rapid preset switches never apply a stale sky")
	var preset := Background.new()
	preset.choice = str(config.get_value("appearance", "background"))
	viewport.add_child(preset)
	await settle(preset)
	check(preset.ready_sky() != null and preset._builtin.resource_path == Background.MORNING, "Saved morning choice loads at startup")
	preset.free()
	main._on_setting_changed("background", "belfast")
	await settle(main.background)
	config.load(main.settings_path)
	check(config.get_value("appearance","background") == "belfast", "Background choice persists")
	main._on_setting_changed("background_yaw", true)
	main._on_setting_changed("background_brightness", true)
	check(is_equal_approx(main.display.environment.sky_rotation.y, PI + PI/4) and main.background.brightness == 1.25, "Rotation applies relative to panorama centre; brightness still applies")
	main.background.yaw = 0; main.background.brightness = 1; main.background._apply()
	if DisplayServer.get_name() != "headless":
		var shot: Image = await frame(viewport,"settings")
		var sky_color := shot.get_pixel(80,100)
		check(sky_color.r + sky_color.g + sky_color.b > .3, "Panorama renders behind the current settings panel")
		main.recent_menu.dismiss()
		await frame(viewport,"belfast")
	# A private copy survives navigation/deleting the original file and app restart.
	var pixels := Image.create(512,256,false,Image.FORMAT_RGB8)
	pixels.fill(Color(.2,.4,.7))
	var source := ProjectSettings.globalize_path(folder.path_join("source_360_2D.jpg"))
	pixels.save_jpg(source)
	main._on_library_chosen("file://"+source,"source_360_2D.jpg")
	var deadline := Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.photo.geometry == 3 and main.photo.can_background(), "Full mono panorama offers use-as-background")
	check(main.display.environment.background_mode == Environment.BG_COLOR, "Immersive media temporarily hides scenery")
	main._on_photo_action("global_background")
	await settle(main.background)
	check(main.background.choice == "custom" and main.photo.panel.visible and main.display.environment.background_mode == Environment.BG_COLOR, "Global panorama import keeps the immersive photo displayed")
	check(main.photo_active and main._has_open_media() and main.photo.local_uri == "file://"+source, "JPG import preserves the current photo link and playback session")
	main._close_current_media(false)
	check(not main.photo_active and main.display.environment.background_mode == Environment.BG_SKY, "Global scenery appears only after the user closes the photo")
	var saved := str(main.background.custom_path)
	check(FileAccess.file_exists(saved) and saved != source, "Background has independent private copy")
	DirAccess.remove_absolute(source)
	config.load(main.settings_path)
	check(config.get_value("appearance","custom_path") == saved and config.get_value("appearance","background") == "custom", "Custom background selection persists")
	var restored := Background.new()
	restored.directory = main.background.directory
	restored.choice = "custom"
	restored.custom_path = saved
	root.add_child(restored)
	await settle(restored)
	check(restored.ready_sky() != null and restored.error.is_empty(), "Custom background reloads without original file")
	main._on_setting_changed("background","belfast")
	await settle(main.background)
	check(main.background.has_custom(), "Changing preset retains the custom choice")
	main.photo.open_image(saved,"plain.jpg")
	deadline = Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.photo.geometry == 0 and main.display.environment.background_mode == Environment.BG_SKY, "Flat photo preserves the application backdrop")
	main.photo.set_stereo_layout(1)
	check(not main.photo.can_background(), "Flat stereo cannot supply a complete sky")
	main.photo.close_image()
	main._on_setting_changed("background","passthrough")
	check(main.background.choice == "passthrough" and main.display.environment.background_mode == Environment.BG_COLOR and not viewport.transparent_bg, "Unavailable desktop passthrough falls back to opaque dark")
	main._on_setting_changed("background","belfast")
	await settle(main.background)
	check(main.display.environment.background_mode == Environment.BG_SKY, "Leaving passthrough restores selected panorama")
	check(not main.background.select("invalid"), "Unknown saved choice rejected")
	# Simulate only XR capability; exercise the real background policy and renderer.
	# This cannot verify Quest camera composition, which still requires the headset.
	var supported := SupportedDisplay.new()
	supported.configure(viewport, main.display.environment, null, true)
	main.display = supported
	main.photo_active = false
	main.video.local_uri = "smb://test/share/clip.mp4"
	main.video.media.begin(7)
	main.video.geometry = 1
	main.video.alpha_requested = true
	for choice in ["belfast", "custom", "dark", "passthrough"]:
		main.background.select(choice)
		main._update_background()
		check(supported.applied_passthrough and viewport.transparent_bg, "Preparing Alpha uses passthrough with " + choice)
		check(supported.environment.background_mode == Environment.BG_COLOR and supported.environment.background_color.a == 0.0 and supported.environment.sky == null, "Alpha removes opaque environment with " + choice)
		check(main.background.choice == choice, "Alpha preserves saved background " + choice)
	main.video.alpha_requested = false
	main.video.packed_file = true
	main.video.packed_alpha = true
	main.background.select("belfast")
	main._update_background()
	check(not supported.applied_passthrough and not viewport.transparent_bg, "Packed Alpha stays opaque until a frame shows its mask")
	main.video.packed_file = false
	main.video.packed_alpha = false
	main.video.alpha_enabled = true
	main._update_background()
	check(supported.applied_passthrough, "Displayed Alpha remains transparent during mode transition")
	main.video.alpha_enabled = false
	main.video.alpha_requested = true
	main.video.media.state = "ended"
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Natural Alpha EOF restores saved panorama despite retained URI and Alpha preference")
	main.video.loop_enabled = true
	main._update_background()
	check(supported.applied_passthrough, "Looping Alpha does not flash scenery at EOF")
	main.video.loop_enabled = false
	main.video.media.state = "ready"
	main.video.requested_play = false
	main._update_background()
	check(supported.applied_passthrough, "Paused Alpha retains passthrough")
	main.video.requested_play = true
	main.video.close_video()
	check(not main.video.local_uri.is_empty() and main.video.alpha_requested, "Regression reproduces closed video with retained URI and Alpha preference")
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Closing Alpha restores saved panorama")
	main.video.media.begin(8)
	main.video.media.state = "failed"
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Failed Alpha restores saved panorama")
	main.video.media.begin(9)
	main.video.alpha_requested = false
	main.video.geometry = 0
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Leaving Alpha restores selected sky for flat video")
	main.background.select("passthrough")
	for geometry in [0, 1, 2, 3]:
		main.video.geometry = geometry
		main._update_background()
		check(supported.applied_passthrough, "Explicit passthrough works behind video geometry %d" % geometry)
	main.video.local_uri = ""
	main._update_background()
	check(supported.applied_passthrough, "Passthrough stays active after closing video")
	main.photo_active = true
	main.photo.local_uri = "file://photo.jpg"
	check(main.photo_background.choice != "passthrough", "Global passthrough does not overwrite photo scenery")
	main.photo_background.select("passthrough")
	for geometry in [0, 1, 2, 3]:
		main.photo.geometry = geometry
		main._update_background()
		check(supported.applied_passthrough, "Explicit passthrough works behind photo geometry %d" % geometry)
	main.photo.local_uri = ""
	main.visible = false
	if DisplayServer.get_name() != "headless":
		var transparent_frame: Image = await frame(viewport, "passthrough-alpha")
		check(transparent_frame.get_pixel(80,100).a == 0.0, "Rendered passthrough background has zero alpha")
	supported._on_session_event("session_begun")
	check(viewport.transparent_bg and supported.environment.background_color.a == 0.0, "Session resume preserves transparent background")
	main.photo_background.select("dark")
	check(not supported.applied_passthrough and not viewport.transparent_bg and supported.environment.background_color.a == 1.0, "Dark is opaque and distinct from passthrough")
	main.visible = true
	await check_png_backgrounds(main,viewport)
	restored.queue_free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Application background: %d checks, %d failures; previews %s" % [checks,failures.size(),output])
	quit(0 if failures.is_empty() else 1)
