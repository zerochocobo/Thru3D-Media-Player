extends SceneTree
## Desktop visual coverage for shared fields across their real panel sizes.
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const Music := preload("res://scripts/music_menu.gd")
const Audio := preload("res://scripts/background_audio.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
var layouts := 0
var output: String
var viewport: SubViewport
var camera: Camera3D

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func shot(menu: Node3D, name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	for button in menu._buttons:
		if not button.node.is_visible_in_tree(): continue
		if button.has("select_arrow"):
			var caption: Label3D = button.select_caption
			var width := caption.font.get_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, caption.font_size).x * caption.pixel_size
			var arrow: MeshInstance3D = button.select_arrow
			check(caption.position.x + width + 0.008 <= arrow.position.x - arrow.mesh.size.x / 2, name + ": value clears arrow " + caption.text)
			check(menu.ray_hit(arrow.global_position + button.node.global_basis.z, -button.node.global_basis.z).get("target", -1) == button.target or not button.enabled, name + ": arrow shares field target")
		elif button.node.get_child_count() > 0 and button.node.get_child(0) is Label3D:
			var caption: Label3D = button.node.get_child(0)
			# Table rows have independently fitted columns; captioned icon buttons stack.
			if caption.text.is_empty() or button.has("hover_labels"): continue
			var width := caption.font.get_multiline_string_size(caption.text, HORIZONTAL_ALIGNMENT_LEFT, -1, caption.font_size).x * caption.pixel_size
			check(width <= button.rect.size.x - 0.004, name + ": caption fits " + caption.text)
	check(viewport.get_texture().get_image().save_png(output.path_join(name + ".png")) == OK, name + ": save")
	layouts += 1

func run() -> void:
	output = OS.get_environment("SELECT_UI_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/global-select-style/previews/%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1600, 1250); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	camera = Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var global_state := {"background": "belfast", "background_yaw": 0, "background_brightness": 1.0, "privacy_mode": "all", "file_settings_memory": "all", "alpha_profile": "320x320", "alpha_fps": 30}
	var library := Library.new(); library.settings_provider = func(): return global_state
	camera.add_child(library); library.toggle(); library.set_process(false); library.section = Library.Section.SETTINGS
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for tab in [Library.GENERAL_TAB, Library.DISPLAY_TAB, Library.VIDEO_TAB, Library.BACKGROUND_TAB]:
			library.tab = tab; library.scroll = 0; library.refresh()
			await shot(library, language + "-settings-%d" % tab)
			if tab in [Library.VIDEO_TAB, Library.BACKGROUND_TAB]:
				library._set_scroll(library._max_scroll())
				await shot(library, language + "-settings-%d-bottom" % tab)
	library.free()
	var state := {"has_video": true, "has_image": true, "count": 12, "title": "旅行 · Travel", "geometry": 0, "stereo": true, "source_uri": "file:///style.mp4", "duration_ms": 600000, "position_ms": 20000,
		"capabilities_available": true, "alpha_available": true, "alpha_enabled": true, "alpha_fps": 30, "alpha_feather": 100, "alpha_shrink": 40, "screen_distance": 4.5, "screen_scale": 150.0, "screen_rotation": 15.0, "playback_speed": 1.5, "viewing_eye": 0}
	var player := Player.new(); player.state_provider = func(): return state
	camera.add_child(player); player.toggle(); player.set_process(false); player.position.y = -0.30
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for view in ["playback", "screen", "cinema", "color_grade", "stereo_view"]:
			player.section = 1; player._adjustment = "" if view == "playback" else "screen" if view == "cinema" else view
			state.screen_cinema = view == "cinema"; player.refresh()
			await shot(player, language + "-player-" + view)
	player.free()
	var photo := Photo.new(); photo.state_provider = func(): return state
	camera.add_child(photo); photo.toggle(); photo.set_process(false); photo._adjustment = "photo_view"
	for language in ["zh", "en"]:
		I18n.use(language); photo.refresh(); await shot(photo, language + "-photo")
	photo.free()
	var audio := Audio.new(); var music := Music.new(); music.audio = audio
	camera.add_child(music); music.position.z = -2.0; music.open(false); music.set_process(false); music.view = "tracks"
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language); music.refresh(); await shot(music, language + "-music")
	music.free(); audio.importer.free(); audio.free(); viewport.free()
	await process_frame
	print("Select typography render layouts=%d checks=%d failures=%d output=%s" % [layouts, checks, failures.size(), output])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
