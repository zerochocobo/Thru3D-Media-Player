extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
const Style := preload("res://scripts/subtitle_style.gd")
const Bitmap := preload("res://scripts/bitmap_subtitles.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); print("FAILED: " + message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var video := Video.new(); root.add_child(video); video.set_process(false)
	var app := Main.new(); app.video = video
	app.settings_path = "user://subtitle-transparency.cfg"
	app._restore_subtitle_settings()
	check(video.subtitle_transparency == 0.0, "Existing configurations default to opaque")
	var library := Library.new(); root.add_child(library); library.set_process(false); app.recent_menu = library
	library.settings_provider = app._library_settings; library.setting_changed.connect(app._on_setting_changed)
	for value in [0.0, 40.0, 80.0, 120.0, -20.0]:
		app._on_setting_changed("subtitle_transparency", value)
		check(video.subtitle_transparency == clampf(value, 0, 80), "Setting range is 0 to 80")
		var saved := ConfigFile.new(); saved.load(app.settings_path)
		check(saved.get_value("subtitles", "transparency") == video.subtitle_transparency, "Setting uses existing persistence")
	app.settings.set_value("subtitles", "transparency", 45.0); app._restore_subtitle_settings()
	check(video.subtitle_transparency == 45.0, "Restore saved transparency")
	app._on_playback_adjustment("subtitle_transparency", NAN)
	check(video.subtitle_transparency == 45.0, "Non-finite drag is ignored")
	var player := Player.new(); root.add_child(player); player.set_process(false)
	player.state_provider = func():
		var state: Dictionary = app._menu_state()
		state.has_video = true
		return state
	app.player_menu = player
	player.setting_requested.connect(app._on_player_setting)
	for codec in ["subrip", "hdmv_pgs_subtitle"]:
		video.media.playback = {"details":{"pgs_supported":true,"subtitle_tracks":[{"id":2,"codec":codec,"title":"Subtitle"}]}}
		video.subtitles.select(2); player.visible = false; player.toggle(); player._activate(110)
		if player._subtitle_detail_group() != "appearance": player._activate(player.SUBTITLE_APPEARANCE)
		var fields: Array = player._subtitle_controls().filter(func(row):return row.get("field",{}).get("key") == "subtitle_transparency")
		check(fields.size() == 1, "Transparency is available for " + codec)
		player.dismiss()
	library.visible = true; library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB
	library._video_settings_expanded = {"subtitles":true}; library._subtitle_settings_expanded = "appearance"; library.refresh()
	var row_index := library.rows.find(library.rows.filter(func(row):return row.get("key") == "subtitle_transparency")[0])
	library._set_scroll(maxi(0,row_index-2))
	var resets: Array = library.choices.targets.keys().filter(func(id): return library.choices.targets[id].get("key") == "subtitle_transparency" and library.choices.targets[id].get("kind") == "reset")
	check(resets.size() == 1, "Standard reset button is present")
	if not resets.is_empty():
		var button: Dictionary = library._buttons.filter(func(item):return item.target == resets[0])[0]
		var origin: Vector3 = button.node.to_global(Vector3(0,0,1)); var direction: Vector3 = -button.node.global_basis.z
		check(library.ray_hit(origin,direction).get("target") == resets[0], "Reset is reachable by the controller ray")
		library.press_pointer("left_hand",origin,direction,true); library.release_pointer("left_hand",origin,direction,true)
		check(video.subtitle_transparency == 0.0 and app.settings.get_value("subtitles","transparency") == 0.0, "Ray reset restores and saves zero transparency")
	video.caption.text = "Subtitle 字幕"; video.caption.visible = true
	for geometry in [video.Geometry.Geometry.FLAT, video.Geometry.Geometry.HALF_EQUIRECT]:
		video.geometry = geometry
		for value in [0.0,50.0,80.0,0.0]:
			video.subtitle_transparency = value; video.caption.visible = true; video._place_caption()
			check(is_equal_approx(video.caption.modulate.a,1.0-value/100.0) and video.caption.outline_modulate.a == video.caption.modulate.a, "Text and outline fade together")
			if geometry != video.Geometry.Geometry.FLAT:
				check(video.projected_subtitles.label.modulate.a == 1.0 and video.projected_subtitles.vertical_text.modulate.a == 1.0, "Immersive glyphs stay opaque")
				check(is_equal_approx(video.projected_subtitles.fade.color.a,video.caption.modulate.a) and video.projected_subtitles.fade.visible == (value > 0.0), "Immersive canvas fades as one layer")
				var version: int = video.projected_subtitles.version
				video._place_caption(); check(video.projected_subtitles.version == version,"Unchanged alpha reuses canvas")
	video.geometry = video.Geometry.Geometry.FLAT
	var headless := DisplayServer.get_name() == "headless"
	for value in [50.0, 0.0]:
		video.subtitle_transparency = value; video.caption.visible = true; video._place_caption()
		var shown := false
		for attempt in 10:
			shown = video._fade_flat_caption(true)
			if shown: break
			await process_frame
		if headless:
			# No frame is drawn: the capture never completes, so the original label stays in use.
			check(not shown, "Uncaptured transparent caption keeps the original label")
			continue
		check(shown == (value > 0.0), "Eye-buffer caption uses the faded canvas only when transparent")
		if value > 0.0:
			var canvas: Node = video._flat_subtitle_canvas
			check(canvas.label.modulate.a == 1.0 and canvas.label.outline_modulate.a == 1.0, "Flat canvas captures opaque glyphs")
			check(is_equal_approx(canvas.fade.color.a, 0.5) and canvas.fade.visible, "Flat canvas fades as one layer")
			check(video._faded_caption.get_parent() == video.caption and video._faded_caption.visible, "Faded caption follows the caption's visibility")
		else:
			check(not video._faded_caption.visible, "Opaque captions keep the original label")
	video._fade_flat_caption(false)
	check(not video._faded_caption or not video._faded_caption.visible, "Layer or immersive display hides the faded caption")
	var bitmap := Bitmap.new(); var material := ShaderMaterial.new(); material.shader = preload("res://shaders/subtitle_surface.gdshader")
	var cue := {"version":1,"width":2,"height":1,"x":0,"y":0,"canvas_width":2,"canvas_height":1}
	var pixels := PackedByteArray([64,32,16,128,255,128,64,255])
	bitmap.apply(material,cue,1,pixels)
	var opaque := bitmap.texture
	bitmap.apply(material,cue,1,PackedByteArray([32,16,8,64,128,64,32,128]),1,0,0xffffff,0.5)
	check(bitmap.image.get_data() == PackedByteArray([32,16,8,64,128,64,32,128]), "PGS opacity scales premultiplied RGB and alpha once")
	check(bitmap.texture != opaque and not bitmap.needs_pixels(cue,1,0xffffff,0.5), "Alpha change invalidates layer texture")
	var faded := bitmap.texture
	bitmap.apply(material,cue,1,PackedByteArray(),1,0,0xffffff,0.5)
	check(bitmap.texture == faded, "Unchanged PGS cue/alpha reuses texture")
	bitmap.apply(material,cue,1,pixels)
	check(bitmap.image.get_data() == pixels, "PGS reset exactly restores original pixels")
	if app.subtitle_tasks: app.subtitle_tasks.translator.close()
	app.subtitle_tasks=null; app.video=null; app.recent_menu=null; app.player_menu=null
	app.free(); library.free(); player.free(); video.free(); await process_frame
	for failure in failures: push_error(failure)
	print("Subtitle transparency checks=%d failures=%d" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
