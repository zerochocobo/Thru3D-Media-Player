extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Composition := preload("res://scripts/menu_composition.gd")
const Mono := preload("res://scripts/mono_menu_capture.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/mono-scope-alignment-20261025")
func check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func frames() -> void:
	for i in 3: await process_frame; await RenderingServer.frame_post_draw
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var view := SubViewport.new(); view.size = Vector2i(1400,1000); view.own_world_3d = true
	view.transparent_bg = true; view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var origin := Node3D.new(); view.add_child(origin)
	var eye := Camera3D.new(); eye.fov = 65; origin.add_child(eye)
	var menu := Player.new(); origin.add_child(menu)
	menu.state_provider = func(): return {"has_video":true,"geometry":1,"stereo":true,"playing":true,"position_ms":120000,"duration_ms":600000,"volume":80,"audio_available":true,"capture":{"available":true}}
	menu.layout_head_provider = func(): return eye.global_transform
	menu.global_transform = Transform3D(Basis.IDENTITY,Vector3(0,-0.45,-1.4))
	menu.set_layout_viewer(eye.global_transform); menu.toggle()
	var originals: Array[Dictionary] = []
	for button in menu._buttons:
		originals.append({"node":button.node,"pose":button.node.transform,"button":true})
		for child in button.node.get_children():
			if child is VisualInstance3D:
				originals.append({"node":child,"pose":child.transform,"button":false})
	var compositor := Composition.new(); origin.add_child(compositor)
	compositor.configure(origin,eye,null,[menu],false,true)
	var mono := Mono.new(); origin.add_child(mono); mono.configure(eye,compositor,func():return menu,false,true)
	await frames()
	for translation in [Vector3.ZERO,Vector3(0.15,0.06,0.1)]:
		eye.position = translation; mono.update()
		for saved in originals:
			if saved.button: check(saved.node.transform == saved.pose,"Capture preserves logical button geometry")
		var aligned := 0
		for button in menu._buttons:
			if not is_equal_approx(button.rect.get_center().y,0.215): continue
			for child in button.node.get_children():
				if not child is MeshInstance3D or not child.material_override is BaseMaterial3D or child.material_override.albedo_texture == null: continue
				var circle := mono.camera.unproject_position(button.node.global_position)
				var glyph := mono.camera.unproject_position(child.global_position)
				var offset := glyph-circle
				print("Top-row alignment: ",button.target," x=",button.rect.get_center().x," capture_pixels=",offset)
				check(offset.length() < 0.05,"Floating glyph and plate share a capture centre: %d" % button.target)
				aligned += 1
		check(aligned >= 5,"Alignment checks cover both ends of the floating row")
		await frames()
		for saved in originals:
			check(saved.node.transform.is_equal_approx(saved.pose),"Original button and ink transforms restored after drawing")
	view.get_texture().get_image().save_png(output.path_join("mono-aligned.png"))
	mono.update(); mono.stop()
	for saved in originals:
		check(saved.node.transform.is_equal_approx(saved.pose),"Stopping mid-frame restores original UI transforms")
	menu.dismiss(); compositor.set_active(false); view.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Mono alignment: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
