extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const Errors := preload("res://scripts/playback_errors.gd")
const I18n := preload("res://scripts/i18n.gd")
const Loading := preload("res://scripts/media_loading.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
var state := {}
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("THRU3D_TEST_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/playback-errors-preview")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1500, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 55
	viewport.add_child(camera)
	var menu := Menu.new()
	menu.state_provider = func(): return state
	camera.add_child(menu)
	menu.position.z = -1.55
	menu.toggle()
	var photo := PhotoMenu.new(); photo.state_provider = func(): return state
	camera.add_child(photo); photo.position.z = -1.55; photo.visible = false
	for language in ["zh", "en", "zh_Hant", "ja"]:
		I18n.use(language)
		for code in ["STRM_MULTIPLE_TARGETS", "STRM_WINDOWS_PATH", "STRM_READ_TIMEOUT", "STRM_TARGET_UNAVAILABLE", "MPV_OPEN_TIMEOUT", "MPV_OUTPUT_TIMEOUT", "MPV_BUFFER_TIMEOUT"]:
			state = {"title": "电影.SBS.strm" if code.begins_with("STRM") else "电影.mkv", "error": I18n.t(Errors.MESSAGES[code])}
			menu.show_playback_error()
			check(menu.visible and menu._failure_open and menu.section == 0, "Error dialog is visible without entering Info")
			check(menu._info.text.ends_with(state.error), "Complete translated reason is shown")
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			check(menu._info.get_aabb().size.y < 0.75, "Wrapped error fits the panel: " + language + code)
			var image := viewport.get_texture().get_image()
			check(image.save_png(output.path_join(language + "-" + code + ".png")) == OK, "Error preview saved")
		for phase in Loading.PHASES:
			state = {"has_video": true, "title": "电影.mkv", "loading_caption": Loading.caption({"remote": true, "phase": phase, "elapsed_ms": 20000, "bytes_per_second": 8200000})}
			menu.section = 0; menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			check(menu._status.text.contains("20 s") and menu._status.text.contains("8.2 MB/s"), "Loading text is visible")
			check(menu._status.get_aabb().size.x < 1.1, "Loading status fits the control bar: " + language + phase)
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-loading-" + phase + ".png")) == OK, "Loading preview saved")
		for reason in ["unknown_format", "access_denied", "unknown"]:
			var report := {"code": "MPV_FRAME_PIPELINE_FAILED", "reason": reason, "stage": "parsing" if reason == "unknown_format" else "reading",
				"mpv_code": -17 if reason == "unknown_format" else -13, "http_status": 403 if reason == "access_denied" else 0,
				"detail": "MPV playback: unrecognized file format; media format could not be determined or the file is damaged" if reason == "unknown_format" else "Upstream HTTP 403" if reason == "access_denied" else "MPV playback: loading failed",
				"native_detail": "MPV playback: loading failed" if reason == "access_denied" else "",
				"exception_type": "PlaybackFailureException", "source_code": "cloud_unavailable" if reason == "unknown" else ""}
			state = {"title": "电影.mkv", "error": I18n.t(Errors.message(report)), "error_report": report}
			menu.position.y = -0.48; menu.position.z = -1.9
			menu.show_playback_error()
			for expanded in [false, true]:
				if expanded: menu._activate(Menu.ERROR_DETAILS)
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				check(menu._error_details_open == expanded, "Details disclosure follows the ray action")
				var details_found := false
				for label in menu._labels:
					if label.text.contains("MPV -"):
						details_found = true
						check(label.get_aabb().size.y < 0.51, "Complete diagnostic text fits the expanded panel: " + language + reason)
						check(label.position.y - label.get_aabb().size.y >= Menu.POPUP_BOTTOM + 0.015, "Diagnostics stay within the panel after wrapping")
				check(not menu._buttons.any(func(button): return button.target == 12), "Error dialog has no Info tab")
				for button in menu._buttons:
					if button.target == Menu.ERROR_DETAILS:
						check(button.rect.end.y < menu._info.position.y - menu._info.get_aabb().size.y, "Disclosure does not overlap the short reason")
				check(details_found == expanded, "Diagnostic codes only appear after expansion")
				check(viewport.get_texture().get_image().save_png(output.path_join(language + "-detail-" + reason + ("-open" if expanded else "-closed") + ".png")) == OK, "Details preview saved")
			menu.dismiss(); menu.visible = true
		menu.position.y = 0; menu.position.z = -1.55
		menu.visible = false; photo.visible = true
		state = {"loading": true, "count": 1, "title": "照片.jpg", "loading_caption": Loading.caption({"remote": true, "phase": "reading", "elapsed_ms": 15000, "bytes_per_second": 2400000})}
		photo.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(photo._status.visible and photo._status.text.contains("2.4 MB/s"), "Remote photo loading is visible")
		check(photo._status.get_aabb().size.x < 1.1, "Photo status fits")
		check(viewport.get_texture().get_image().save_png(output.path_join(language + "-loading-photo.png")) == OK, "Photo preview saved")
		photo.visible = false; menu.visible = true
	photo.free(); menu.free(); viewport.free()
	if failures.is_empty(): print("Playback error render checks passed: ", checks); quit(0)
	else:
		for failure in failures: push_error(failure)
		quit(1)
