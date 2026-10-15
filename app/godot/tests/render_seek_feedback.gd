extends SceneTree
const Overlay := preload("res://scripts/seek_overlay.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Loading := preload("res://scripts/media_loading.gd")
const I18n := preload("res://scripts/i18n.gd")
var sample := {}
var state := {}
var failures: Array[String] = []
var checks := 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("THRU3D_TEST_OUTPUT")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var overlay := Overlay.new(); overlay.source = func(): return sample
	camera.add_child(overlay); overlay.set_process(false)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.set_process(false); menu.position = Vector3(0, -0.25, -1.4)
	var backdrop := MeshInstance3D.new(); backdrop.mesh = QuadMesh.new(); backdrop.mesh.size = Vector2(2, 1.125)
	backdrop.position.z = -2.1
	var material := StandardMaterial3D.new(); material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.10, 0.17, 0.23); backdrop.material_override = material
	viewport.add_child(backdrop)
	var subtitle := Label3D.new(); subtitle.font = preload("res://scripts/ray_menu.gd").ui_font()
	subtitle.font_size = 32; subtitle.pixel_size = 0.0008; subtitle.position = Vector3(0, -0.28, -1.2)
	camera.add_child(subtitle)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for placement in ["flat", "immersive", "waiting", "controls", "fade", "hours", "subtitle"]:
			camera.rotation.x = deg_to_rad(65.0) if placement == "immersive" else 0.0
			subtitle.visible = placement == "subtitle"; subtitle.font = preload("res://scripts/ray_menu.gd").ui_font(); subtitle.text = I18n.t("Subtitles")
			var feedback := {"phase": "waiting" if placement == "waiting" else ("done" if placement == "fade" else "preview"),
				"origin_ms": 750000, "target_ms": 820000, "duration_ms": 5100000, "delta_ms": 70000,
				"alpha": 0.5 if placement == "fade" else 1.0}
			if placement == "hours": feedback.merge({"origin_ms": 35640000, "target_ms": 36070000, "duration_ms": 360000000, "delta_ms": 430000}, true)
			var caption := Loading.caption({"remote": true, "phase": "buffering", "elapsed_ms": 12000, "bytes_per_second": 2300000}) if placement == "waiting" else ""
			state = {"has_video": true, "title": "Movie.mkv", "position_ms": feedback.origin_ms, "duration_ms": feedback.duration_ms,
				"seek_feedback": feedback, "loading_caption": caption}
			menu.visible = placement == "controls"; backdrop.visible = placement == "flat"
			if menu.visible: menu.refresh()
			sample = {} if menu.visible else feedback.duplicate()
			if not sample.is_empty(): sample["caption"] = caption
			if placement == "flat": sample["flat_anchor"] = Vector3(0, -0.67, -2.1)
			if placement == "subtitle": sample["subtitle_y"] = -0.28
			overlay.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if overlay.visible:
				check(overlay.clock.get_aabb().size.x <= Overlay.WIDTH + 0.01, "Time counters fit: " + language + placement)
				check(overlay.detail.get_aabb().size.x <= Overlay.WIDTH + 0.01, "Localized offset/status fits: " + language + placement)
				check(overlay.global_basis.z.normalized().dot((camera.global_position - overlay.global_position).normalized()) > 0.999, "Lower HUD faces viewing centre")
				check(overlay.position.y < 0 and overlay.position.y > -0.45, "HUD stays in lower visible view")
				if placement == "subtitle": check(absf(overlay.position.y + 0.28) >= 0.139, "Custom low subtitles retain separation")
			else:
				check(menu._elapsed.text == "13:40" and menu._duration.text == "1:25:00" and menu._seek_origin.visible, "Transport owns a complete shared timeline")
				check(menu._status.text.contains("+01:10") and not overlay.visible, "Transport feedback has no second HUD")
			var picture := viewport.get_texture().get_image()
			check(picture.save_png(output.path_join(language + "-" + placement + ".png")) == OK, "Preview writes successfully")
	# A genuinely empty source removes every primitive, including the plate and old time labels.
	sample = {}; menu.dismiss(); overlay.refresh()
	check(not overlay.visible, "Completed/cancelled feedback has no orphan visuals")
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Seek feedback previews cases=28 checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
