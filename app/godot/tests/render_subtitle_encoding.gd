extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const Encoding := preload("res://scripts/file_subtitle_encoding.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func save(viewport: SubViewport, path: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().save_png(path) == OK, "Save preview")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-encoding/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(2000, 1400); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 70; camera.position.y = 0.30; viewport.add_child(camera)
	var track := {"id": 1, "external": true, "title": "Movie.ko.smi", "source_file": "Movie.ko.smi", "codec": "sami", "encoding": "auto"}
	var state := {"has_video": true, "title": "Film", "source_uri": "file:///movie.mkv", "duration_ms": 240000, "position_ms": 40000,
		"subtitle_options": [track], "subtitle_track": 1, "subtitle_browse_available": true, "subtitle_encoding_row": Encoding.row(track, "file:///movie.mkv")}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.position.y = -0.35; menu.toggle(); menu.set_process(false); menu._subtitle_open = true
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language); menu._subtitle_appearance_open = false; menu.choices.opened = ""; menu.refresh()
		check(not menu.text_snapshot().contains(I18n.t("Subtitle encoding")), "Collapsed menu omits encoding: " + language)
		await save(viewport, output.path_join(language + "-collapsed.png"))
		menu._subtitle_appearance_open = true; menu.refresh()
		await save(viewport, output.path_join(language + "-expanded.png"))
		menu.choices.opened = "subtitle_encoding"; menu.refresh()
		await save(viewport, output.path_join(language + "-choices.png"))
	menu.free(); viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "layouts": 12}, "\t"))
	for failure in failures: push_error(failure)
	print("Subtitle encoding render checks=%d failures=%d layouts=12" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
