extends SceneTree
const Cinema := preload("res://scripts/environments/cinema_environment.gd")
func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	var viewport:=SubViewport.new(); viewport.size=Vector2i(1024,576); viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var rig:=Node3D.new(); viewport.add_child(rig)
	var camera:=Camera3D.new(); camera.position=Vector3(0,1.7,16); rig.add_child(camera); camera.current=true
	var cinema:=Cinema.new(); viewport.add_child(cinema); cinema.configure(rig,camera); cinema.select(true)
	var deadline:=Time.get_ticks_msec()+45000
	while cinema.loading and Time.get_ticks_msec()<deadline: await process_frame
	if not cinema.is_ready: printerr("Cinema preview unavailable"); quit(1); return
	cinema.set_lighting("on",false)
	await create_timer(.5).timeout; await RenderingServer.frame_post_draw
	var image:=viewport.get_texture().get_image(); image.resize(512,288,Image.INTERPOLATE_LANCZOS)
	var path:=ProjectSettings.globalize_path("res://backgrounds/previews/cinema.jpg")
	if image.save_jpg(path,.90)!=OK: quit(1); return
	viewport.free(); print("SCENERY_PREVIEW_OK"); quit(0)
