extends SceneTree
const Main := preload("res://scripts/main.gd")
const Tests := preload("res://tests/test_view_follow.gd")
const Menu := preload("res://scripts/ray_menu.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/view-follow/render")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}

func capture(viewport: SubViewport, camera: Camera3D, menu: Node3D, name: String) -> void:
	menu.device_status.status_provider = func(): return {"level":85,"clock24":true}
	menu.device_status.clock_provider = func(): return {"hour":21,"minute":30}
	menu.device_status.refresh(true)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	for target in [Menu.FOLLOW, Menu.TEMP_PASSTHROUGH]:
		var item := button(menu,target)
		if item.is_empty():
			check(false, name + " control missing"); continue
		var centre := camera.unproject_position(item.node.global_position)
		var half := camera.unproject_position(item.node.to_global(Vector3(Menu.FOOTER_DIAMETER / 2,0,0))).distance_to(centre)
		check(centre.x - half > 0 and centre.x + half < viewport.size.x and centre.y - half > 0 and centre.y + half < viewport.size.y, name + " footer circle fits the view")
		var color := image.get_pixelv(Vector2i(centre + Vector2(half * .65,0)))
		check(color.r + color.g + color.b > .16, name + " footer circle visibly renders")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280,960); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var config := ConfigFile.new()
	config.set_value("appearance","background","dark"); config.set_value("ui","language","zh")
	config.save(output.path_join("settings.cfg"))
	var main := Main.new(); main.settings_path = output.path_join("settings.cfg")
	main.display = Tests.SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false); main.report_timer.stop()
	main.xr_camera.fov = 70
	await capture(viewport,main.xr_camera,main.recent_menu,"library-off")
	main._on_session_control("follow")
	main.xr_camera.transform = Transform3D(Basis.from_euler(Vector3(PI/2,.4,.6)),Vector3(2,.4,1))
	main._update_view_follow()
	await capture(viewport,main.xr_camera,main.recent_menu,"library-lying-follow")
	main._show_player_menu()
	await capture(viewport,main.xr_camera,main.video_menu,"video-follow")
	main.video_menu.section = 1; main.video_menu.refresh()
	await capture(viewport,main.xr_camera,main.video_menu,"video-settings")
	main._show_recent_menu()
	main.recent_menu.file_actions.modal = "delete"
	main.recent_menu.file_actions.target = {"title":"旅行记录.mp4","uri":"file:///example.mp4"}
	main.recent_menu.refresh()
	await capture(viewport,main.xr_camera,main.recent_menu,"file-confirmation")
	main.recent_menu.file_actions.modal = ""
	# Real menu rendering with a simulated active Alpha/XR state.
	main.video.platform = Tests.HostTest.Host.new()
	main._on_library_chosen("file:///render/person_2D.mp4","人像视频.mp4")
	main.video.set_alpha(true)
	# With a video open the library sits compact above the bar, which carries the footer.
	main._show_recent_menu(); main.recent_menu.refresh()
	var item := button(main.video_menu,Menu.TEMP_PASSTHROUGH)
	main.video_menu.update_pointer("right_hand",item.node.global_position + item.node.global_basis.z * .3,-item.node.global_basis.z,true)
	await capture(viewport,main.xr_camera,main.video_menu,"alpha-disabled-tooltip")
	main.video.close_video(); main.photo_active = true; main.player_menu = main.photo_menu
	main._show_player_menu()
	await capture(viewport,main.xr_camera,main.photo_menu,"photo-follow")
	viewport.queue_free(); await process_frame
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures},"\t"))
	for failure in failures: push_error(failure)
	print("View follow render: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
