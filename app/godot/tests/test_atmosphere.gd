extends SceneTree

const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const Controller := preload("res://scripts/atmosphere/atmosphere_controller.gd")
const Field := preload("res://scripts/atmosphere/atmosphere_field.gd")
const Sound := preload("res://scripts/atmosphere/atmosphere_sound.gd")
const Memory := preload("res://scripts/atmosphere/atmosphere_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Icons := preload("res://scripts/menu_icons.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var directory := ProjectSettings.globalize_path("res://../../build/output/atmosphere/test-data").simplify_path()

func check(ok: bool, message: String, detail: Variant = null) -> void:
	checks += 1
	if not ok: failures.append(message + ("" if detail == null else ": " + str(detail)))

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	# Catalog: every theme can be drawn, named, heard and translated.
	var ids := Catalog.ids()
	check(ids.size() == 6 and ids.size() == Array(ids).reduce(func(seen, id): return seen if seen.has(id) else seen + [id], []).size(), "Six distinct themes", ids)
	for row in Catalog.THEMES:
		check(Icons.PATHS.has(row.icon), "Theme icon exists", row.icon)
		check(FileAccess.file_exists(Catalog.sound_path(row)) or ResourceLoader.exists(Catalog.sound_path(row)), "Theme recording exists", row.sound)
		check(not row.layers.is_empty(), "Theme has particles", row.id)
		for language in ["zh", "zh_Hant", "ja"]:
			I18n.use(language)
			check(I18n.t(row.label) != row.label, "%s translates %s" % [language, row.label])
		for layer in row.layers:
			check(layer.shape in [Catalog.DOT, Catalog.STREAK, Catalog.LEAF, Catalog.PETAL, Catalog.BUBBLE], "Known shape", row.id)
			var box: Vector3 = layer.box
			check(box.x >= 6.0 and box.z >= 6.0 and box.y >= 2.0, "Box surrounds the viewer", row.id)
			check((layer.velocity as Vector3).length() > 0.0, "Streaks and drifts have a direction", row.id)
	I18n.use("en")
	check(Catalog.clean("rain") == "rain" and Catalog.clean("fog") == "" and Catalog.clean(3) == "", "Unknown themes are off")
	check(Catalog.clean_amount(9) == 2 and Catalog.clean_amount(-1) == 0 and Catalog.clean_amount("x") == Catalog.DEFAULT_AMOUNT, "Amount is clamped")

	# Budget: low-end GPUs draw half; no theme goes past the planned ceiling.
	for row in Catalog.THEMES:
		var standard := 0; var low := 0; var most := 0
		for layer in row.layers:
			standard += Catalog.instances(layer, 1, false); low += Catalog.instances(layer, 1, true); most += Catalog.instances(layer, 2, false)
		check(standard <= 900 and most <= 1440, "Particle ceiling", [row.id, standard, most])
		check(absi(low * 2 - standard) <= row.layers.size(), "Low-end GPUs draw half", [row.id, low, standard])

	# Where each kind of screen shows a theme, keeps the picture clear, and lets it be heard.
	var base := {"theme_global": "rain", "theme_photo": "snow", "folder_theme": null, "sound_on": true, "focused": true}
	var library := Controller.decide(base)
	check(library.theme == "rain" and library.shown and library.keep == "" and library.audible, "Library shows and sounds the global theme", library)
	var film := Controller.decide(base.merged({"video": true, "video_flat": true}, true))
	check(film.theme == "rain" and film.keep == "video" and not film.audible, "A flat film keeps its picture clear and stays silent", film)
	var immersive := Controller.decide(base.merged({"video": true, "video_flat": false}, true))
	check(not immersive.shown and immersive.theme == "" and not immersive.audible, "An immersive film hides the theme", immersive)
	var panorama := Controller.decide(base.merged({"photo": true, "photo_flat": false}, true))
	check(panorama.theme == "snow" and panorama.keep == "" and panorama.audible, "A panorama takes the picture theme all around", panorama)
	var flat := Controller.decide(base.merged({"photo": true, "photo_flat": true}, true))
	check(flat.keep == "photo" and flat.audible, "A flat picture is kept clear", flat)
	var folder := Controller.decide(base.merged({"photo": true, "folder_theme": "leaves"}, true))
	check(folder.theme == "leaves", "A folder's choice wins over the picture default", folder)
	var folder_off := Controller.decide(base.merged({"photo": true, "folder_theme": ""}, true))
	check(not folder_off.shown, "A folder can turn the theme off", folder_off)
	var board := Controller.decide(base.merged({"puzzle": true, "puzzle_flat": true}, true))
	check(board.theme == "rain" and board.keep == "puzzle" and board.audible, "A flat puzzle keeps its board clear", board)
	var sphere := Controller.decide(base.merged({"puzzle": true, "puzzle_flat": false, "video": true, "video_flat": false}, true))
	check(sphere.shown and sphere.keep == "" and sphere.audible, "A spherical puzzle is surrounded, whatever film it came from", sphere)
	var from_picture := Controller.decide(base.merged({"puzzle": true, "puzzle_flat": true, "photo": true, "photo_flat": true, "folder_theme": "leaves"}, true))
	check(from_picture.theme == "leaves" and from_picture.keep == "puzzle", "A puzzle of a picture keeps that picture's theme", from_picture)
	check(not Controller.decide(base.merged({"photo": true, "video": true, "video_flat": false}, true)).keep == "video", "A picture in front decides, not the film behind")
	for quiet in [{"music": true}, {"speaking": true}, {"focused": false}, {"sound_on": false}]:
		var result := Controller.decide(base.merged(quiet, true))
		check(result.shown and not result.audible, "Silent but still shown", quiet)
	check(not Controller.decide(base.merged({"theme_global": ""}, true)).shown, "Off shows nothing")

	# Folder keys.
	check(Memory.folder_of("file:///sdcard/Pictures/trip/a.jpg") == "file:///sdcard/Pictures/trip", "File folder")
	check(Memory.folder_of("smb://nas/photos/2025/b.jpg?x=1") == "smb://nas/photos/2025", "Query is not part of the folder")
	var document := "content://com.android.externalstorage.documents/tree/primary%3APictures/document/primary%3APictures%2Ftrip%2Fa.jpg"
	check(Memory.folder_of(document) == document.trim_suffix("%2Fa.jpg"), "Android document folder", Memory.folder_of(document))
	check(Memory.folder_of(document.replace("%2F", "%2f")) == document.replace("%2F", "%2f").trim_suffix("%2fa.jpg"), "Lower-case escapes")
	check(Memory.folder_of("") == "" and Memory.folder_of("archive-image://x/y/z") == "" and Memory.folder_of("a.jpg") == "", "No folder for pages and bare names")

	# Folder memory: validated, private when asked, cleared like other per-file settings.
	directory += "-%d" % Time.get_ticks_usec()
	var memory := Memory.new(directory)
	memory.load_saved()
	var trip := "file:///sdcard/Pictures/trip"
	var nas := "smb://nas/photos/2025"
	Privacy.configure_file_settings(Privacy.ALL)
	check(memory.lookup(trip).is_empty(), "Nothing remembered at first")
	check(memory.remember(trip, {"theme": "snow"}) and memory.remember(nas, {"theme": ""}) and memory.save(), "Remember a theme and an off choice", memory.last_error)
	check(not memory.remember(trip, {"theme": "fog"}) and not memory.remember(trip, {"theme": "rain", "extra": 1}), "Unknown values are refused")
	var reloaded := Memory.new(directory); reloaded.load_saved()
	check(reloaded.lookup(trip) == {"theme": "snow"} and reloaded.lookup(nas) == {"theme": ""}, "Choices survive a restart", [reloaded.lookup(trip), reloaded.lookup(nas)])
	Privacy.configure_file_settings(Privacy.LOCAL)
	check(reloaded.lookup(trip).has("theme") and reloaded.lookup(nas).is_empty(), "Local-only memory ignores network folders")
	check(not reloaded.remember(nas, {"theme": "rain"}), "Local-only memory does not write network folders")
	Privacy.configure_file_settings(Privacy.NONE)
	check(reloaded.lookup(trip).is_empty() and not reloaded.remember(trip, {"theme": "rain"}), "No memory when settings are not kept")
	Privacy.configure_file_settings(Privacy.ALL)
	var network: Array = reloaded.entries.keys().filter(func(key): return reloaded.entries[key].get("network", false))
	check(network.size() == 1 and reloaded.purge_keys(network) and reloaded.lookup(nas).is_empty() and reloaded.lookup(trip).has("theme"), "Network folders clear on their own")
	check(reloaded.purge_keys(reloaded.entries.keys()) and reloaded.lookup(trip).is_empty(), "Clearing settings forgets every folder")

	# Field: built to the budget, hidden until shown, cleared when off.
	var field := Field.new(); root.add_child(field)
	field.build("underwater", 1, false)
	check(field.layers.size() == 2 and field.particle_count() == 560, "Standard underwater", field.particle_count())
	check(not field.layers[0].node.visible, "Hidden until stepped")
	var screen := {"transform": Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -3)), "size": Vector2(3.2, 1.8)}
	field.step(0.5, true, Vector3(0, 1.6, 0), 0.0, screen, false)
	var material: ShaderMaterial = field.layers[0].material
	check(field.layers[0].node.visible and is_equal_approx(field.opacity, 0.5 / Field.FADE_SECONDS), "Fades in", field.opacity)
	check(material.get_shader_parameter("screen_half") == Vector2(1.6, 0.9) and material.get_shader_parameter("head") == Vector3(0, 1.6, 0) and material.get_shader_parameter("centre") == Vector3(0, 2.3, 0), "Screen, head and a box standing on the floor reach the shader", material.get_shader_parameter("centre"))
	check(material.render_priority > -126 and material.render_priority < 9, "Drawn after the picture's hole and before menus")
	field.step(10.0, false, Vector3.ZERO, 0.0, {}, false)
	check(not field.layers[0].node.visible and field.opacity == 0.0, "Fades out and hides")
	field.build("rain", 2, true)
	check(field.particle_count() == roundi(700 * 1.6 * 0.5), "More, on a low-end GPU", field.particle_count())
	field.build("", 1, false)
	check(field.layers.is_empty() and field.theme == "", "Off builds nothing")
	field.queue_free()

	# Sound: a private looping copy, silent until asked, muffled under water.
	var sound := Sound.new(); root.add_child(sound)
	sound.select("underwater")
	var bus := AudioServer.get_bus_index(Sound.BUS)
	check(sound.player.stream is AudioStreamOggVorbis and sound.player.stream.loop, "Recording loops")
	check(not (load(Catalog.sound_path(Catalog.theme("underwater"))) as AudioStreamOggVorbis).loop, "The music player's copy is untouched")
	check(bus >= 0 and AudioServer.is_bus_effect_enabled(bus, 0), "Underwater is muffled")
	sound.step(0.1, false)
	check(not sound.player.playing, "Silent until audible")
	sound.step(Sound.FADE_SECONDS, true)
	check(sound.player.playing and not sound.player.stream_paused and is_equal_approx(sound.level, 1.0), "Fades in and plays", sound.level)
	sound.step(Sound.FADE_SECONDS, false)
	check(sound.player.stream_paused and sound.level == 0.0, "Fades out and pauses")
	sound.select("rain")
	check(not AudioServer.is_bus_effect_enabled(bus, 0), "Other themes are not muffled")
	sound.select("")
	check(sound.player.stream == null, "Off holds no recording")
	sound.queue_free()

	if failures.is_empty(): print("Atmosphere checks passed: %d" % checks)
	else:
		for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)
