extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Capture := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func valid_controls(menu: Node) -> bool:
	return menu._buttons.all(func(button): return is_instance_valid(button.node))
func run() -> void:
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.visible=true; menu.audio_import_mode=true; menu.section=Menu.Section.CLOUD
	menu._cloud_stack=[{"id":"/music","title":"Music"}]; menu._cloud_location="/music"
	var preview := {"audio_preview_available":true,"audio_preview_uri":"cloud:///music/track00.mp3","audio_preview_token":1,
		"audio_preview_seekable":true,"audio_preview_position":5.0,"audio_preview_duration":60.0}
	menu.background_audio_provider=func():return preview
	var auditions:Array=[]
	menu.audio_preview_requested.connect(func(uri,_title):auditions.append(uri))
	for i in 48: menu._cloud_entries.append({"id":"/music/track%02d.mp3"%i,"title":"track%02d.mp3"%i,"uri":"cloud:///music/track%02d.mp3"%i,"kind":"audio"})
	menu.refresh()
	check(menu.rows.size()==48 and valid_controls(menu),"Audio import starts with valid file/preview controls")
	var header:Node=menu._buttons.filter(func(button):return button.target==Menu.BACK)[0].node
	var selection:String=menu.rows[0].uri; menu.audio_selection[selection]=menu.rows[0]
	var budget:int=menu._buttons.size()
	menu._hover["right_hand"]=Menu.AUDIO_PREVIEW_BASE
	menu.stick_scroll(-1,.4)
	check(menu.scroll>=1,"Stick crosses a row boundary")
	check(valid_controls(menu),"Row replacement unregisters freed inline preview controls")
	# Stop before dereferencing the old controls; this assertion reproduces the bug safely.
	if valid_controls(menu):
		check(menu._hover.get("right_hand",menu.NONE)==menu.NONE,"Old hovered preview is cleared before slot reuse")
		for i in 80:
			menu.stick_scroll(-1 if i<40 else 1,.1)
			check(valid_controls(menu),"No freed controls during repeated bidirectional scrolling %d"%i)
			check(menu._buttons.size()<=budget and menu._audio_preview_rows.size()<=menu._drawn_slots(),"Preview registry remains bounded %d"%i)
			if not valid_controls(menu): break
			menu.update_pointer("right_hand",menu.to_global(Vector3(.4,0,1)),-menu.global_basis.z,true)
			menu.audio_preview_seek.poll(.12)
		check(is_instance_valid(header),"Scrolling keeps the header alive")
		check(menu.audio_selection.has(selection),"Scrolling preserves selected imports")
		check(auditions.is_empty(),"Stick scrolling never auditions or selects a song")
		menu._set_scroll(menu._max_scroll())
		check(menu.audio_preview_seek.view.is_empty(),"Offscreen audition timeline releases its row view")
		var inline:Dictionary=menu._buttons.filter(func(button):return button.target==Menu.AUDIO_PREVIEW_BASE)[0]
		var expected:String=menu._audio_preview_rows[inline.target].uri
		var ray:Vector3=inline.node.to_global(Vector3(0,0,1))
		menu.press_pointer("right_hand",ray,-inline.node.global_basis.z,true)
		menu.release_pointer("right_hand",ray,-menu.global_basis.z,true)
		check(auditions==[expected] and expected!=selection,"Reused preview target auditions the current row through the ray")
		menu._set_scroll(0)
		check(not menu.audio_preview_seek.view.is_empty() and is_instance_valid(menu.audio_preview_seek.view.node),"Scrolling back recreates the active audition timeline")
		menu.refresh(); check(valid_controls(menu),"Full redraw remains valid after scrolling")
		if DisplayServer.get_name()!="headless": await render_scroll(menu)
	menu.free()
	print("Audio import scroll: %d checks, %d failures"%[checks,failures.size()])
	for failure in failures: printerr(failure)
	quit(0 if failures.is_empty() else 1)

func render_scroll(menu: Node3D) -> void:
	var origin:=Node3D.new(); root.add_child(origin)
	var camera:=Camera3D.new(); origin.add_child(camera)
	camera.global_position=menu.global_position+Vector3(0,0,1.5)
	var display:=preload("res://scripts/xr_display.gd").new()
	display.configure(root,Environment.new(),null,true)
	var capture:=Capture.new(); root.add_child(capture)
	capture.configure(origin,camera,display,[menu],false,true); capture.set_process(false)
	var sizes:Array=capture.slots.map(func(slot):return slot.raw.size)
	for i in 24:
		menu.stick_scroll(-1 if i<12 else 1,.3)
		capture.update(); await process_frame; await RenderingServer.frame_post_draw
		check(capture.slots.filter(func(slot):return slot.used).all(func(slot):return slot.nodes.all(func(node):return is_instance_valid(node))),"Capture releases old row nodes %d"%i)
	check(capture.slots.map(func(slot):return slot.raw.size)==sizes,"Scrolling never resizes compositor buffers")
	capture.free(); origin.free()
