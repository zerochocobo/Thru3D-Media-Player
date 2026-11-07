extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Rotation := preload("res://scripts/screen_rotation_control.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var main: Harness
var photo: Node3D
var camera: Camera3D
var menu: Node3D
var output := ProjectSettings.globalize_path("res://../../build/output/photo-orientation")
var entries: Array[Dictionary] = []

class Harness extends "res://scripts/main.gd":
	var rays := {}
	func _ray(hand: String) -> Variant: return super(hand) if hand == "mouse" else rays.get(hand)
	func _head_pose() -> Variant: return photo.view_camera.global_transform

class Layer extends "res://scripts/video_layer.gd":
	func _init() -> void: super(null)
	func available() -> bool: return true
	func supports(_geometry: int, _curved: bool = false) -> bool: return true

class LayerHost extends RefCounted:
	func copy_layer_band(_slot: int, _image: int, _y: int, _rows: int) -> bool: return true

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func aim(hand: String) -> void:
	var point: Vector3 = photo.panel.to_global(photo.screen_corner(Rotation.lower_left_corner(photo)))
	main.rays[hand] = [camera.global_position, (point - camera.global_position).normalized()]
	main._update_screen_rotation_control()

func turn(hand: String, degrees: float) -> void:
	var angle: float = main._grab.rotate.last - deg_to_rad(degrees)
	var point: Vector3 = photo.global_transform * photo.flat_pose * Vector3(cos(angle), sin(angle), 0)
	main.rays[hand] = [camera.global_position, (point - camera.global_position).normalized()]
	main._update_grab()

func settle() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	photo.finish_transition(); photo._process_presentation()
	check(not photo.loading and photo.error.is_empty(), "Photo fixture loads")

func geometry_checks() -> void:
	for source in [Vector2(320, 180), Vector2(180, 320)]:
		photo._size = source; photo.set_screen_scale(1); photo._apply_geometry()
		var size: Vector2 = photo._flat.size
		for curve in [30.0, 90.0, 160.0]:
			photo.set_screen_curve(curve)
			for angle in [0.0, 45.0, 90.0, 135.0, 180.0, 270.0]:
				photo.set_screen_rotation(angle)
				var arrays: Array = photo.panel.mesh.surface_get_arrays(0)
				check(arrays[Mesh.ARRAY_VERTEX].size() < 700, "Curved rotation stays within the mobile mesh budget")
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
				var roll := Basis(Vector3.FORWARD, deg_to_rad(photo.screen_rotation))
				var radius: float = photo._curve_radius()
				var correct := true
				for index in vertices.size():
					var original := roll * Vector3((uvs[index].x-.5)*size.x, (.5-uvs[index].y)*size.y, 0)
					var expected := Vector3(sin(original.x/radius)*radius, original.y, (1-cos(original.x/radius))*radius)
					correct = correct and (roll * vertices[index]).distance_to(expected) < .00001
				check(correct, "Image pixels rotate while the cylinder bends only viewer-left/right at %s degrees" % angle)
				for uv in [Vector2(.5,.5), Vector2(.2,.25), Vector2(.8,.7)]:
					var point: Vector3 = photo.surface_point(Vector3((uv.x-.5)*size.x, (.5-uv.y)*size.y, 0))
					var world: Vector3 = photo.panel.to_global(point)
					var direction := (world-camera.global_position).normalized()
					var hit: Variant = photo.screen_hit(camera.global_position, direction)
					check(hit != null and hit.distance_to(world) < .0001, "Ray intersects the displayed rotated surface")
					check(photo._inspect_uv(camera.global_position,direction).distance_to(uv) < .0001, "Magnifier picks the same source pixel after curved rotation")
					var mapping: Vector4 = photo._flat_crop_mapping(uv)
					check(mapping.is_finite(), "Magnifier crop remains finite")
				for corner in 4:
					var world: Vector3 = photo.panel.to_global(photo.screen_corner(corner))
					check(photo.corner_at(camera.global_position,(world-camera.global_position).normalized()) == corner, "Resizing and rotation share actual curved corner hits")
				photo._image_rotations[photo.local_uri]=fposmod(angle,360)
				photo._size_placeholder(photo.index,{"width":source.x,"height":source.y})
				check(is_equal_approx(photo._placeholder_rotation,deg_to_rad(fposmod(angle,360))), "Loading placeholders use the target image's own rotation")
				photo.finish_transition()

func input_checks() -> void:
	for hand in ["left_hand", "right_hand"]:
		for curve in [0.0,.7]:
			for angle in [0.0,90.0,180.0,270.0]:
				photo.set_screen_curve(curve); photo.set_screen_rotation(angle); aim(hand)
				check(main.screen_rotation_control.visible, "Photo has a hover-only lower-left rotation arc in every orientation")
				main._update_corner_hover()
				check(photo.hovered_corner == -1, "Arc replaces the lower-left bracket")
				check(main._try_screen_rotation(hand), "Either hand captures photo rotation")
				main._on_pointer_release("trigger_click",hand)
				check(is_zero_approx(wrapf(photo.screen_rotation-angle,-180,180)) and not photo._rotation_preview, "Short click leaves the image unchanged")
				main._try_screen_rotation(hand); turn(hand,132)
				check(is_zero_approx(wrapf(photo.screen_rotation-angle-132,-180,180)), "Dragging previews a continuous unsnapped angle")
				main._on_pointer_release("trigger_click","right_hand" if hand=="left_hand" else "left_hand")
				check(main._grab.has("rotate"), "Other hand cannot release the capture")
				main._on_pointer_release("trigger_click",hand)
				check(is_zero_approx(wrapf(photo.screen_rotation-angle-90,-180,180)), "Release snaps to nearest 90 degrees")
				check(photo._image_rotations[photo.local_uri] == fposmod(photo.screen_rotation,360), "Committed photo angle is remembered per image")
	for direction in [1,-1]:
		photo.set_screen_rotation(0); aim("right_hand")
		var end: Vector3 = main.screen_rotation_control.to_global(Vector3(-.11,.035,0) if direction==1 else Vector3(.035,-.11,0))
		main.rays.right_hand = [camera.global_position,(end-camera.global_position).normalized()]
		main._try_screen_rotation("right_hand")
		check(main._grab.rotate.hold_direction == direction, "Each arrow selects the corresponding repeat direction")
		Rotation.hold_tick(photo, main._grab, main._grab.rotate.next_hold-1)
		check(photo.screen_rotation==0, "Short press respects the 500 ms hold delay")
		for step in 10:
			Rotation.hold_tick(photo,main._grab,main._grab.rotate.next_hold); main._update_grab()
			check(main._grab.has("rotate") and is_zero_approx(wrapf(photo.screen_rotation-(step+1)*90*direction,-180,180)), "Hold keeps rotating over multiple revolutions without re-aiming")
		var held: float = photo.screen_rotation
		turn("right_hand",23)
		Rotation.hold_tick(photo,main._grab,main._grab.rotate.next_hold+20000)
		check(is_zero_approx(wrapf(photo.screen_rotation-held-23,-180,180)), "Intentional drag takes over from continuous hold")
		main._on_pointer_release("trigger_click","right_hand")
	photo.set_screen_rotation(0); aim("right_hand"); main._try_screen_rotation("right_hand"); turn("right_hand",-178); turn("right_hand",-24)
	check(is_equal_approx(photo.screen_rotation,158), "Continuous drag crosses the 180-degree seam")
	main.rays.erase("right_hand"); main._update_grab()
	check(main._grab.is_empty() and photo.screen_rotation==180 and not photo._rotation_preview, "Tracking loss finishes and snaps the current photo")
	photo.set_screen_rotation(0); aim("right_hand"); main._try_screen_rotation("right_hand"); turn("right_hand",65)
	photo._cancel_rotation_preview()
	check(photo.screen_rotation==0 and not photo._rotation_preview, "Interrupted selection restores the previous committed image orientation")
	main._grab.clear(); aim("right_hand"); main._try_screen_rotation("right_hand"); turn("right_hand",65)
	photo.open_image(entries[1].uri,entries[1].title,entries); await settle(); main._update_grab()
	check(photo.screen_rotation==0 and main._grab.is_empty() and not photo._rotation_preview, "Changing files invalidates an old rotation capture")
	photo.open_image(entries[0].uri,entries[0].title,entries); await settle()
	photo.set_screen_curve(0); photo.set_screen_rotation(0)
	var point: Vector3 = photo.panel.to_global(photo.screen_corner(Rotation.lower_left_corner(photo)))
	var motion := InputEventMouseMotion.new(); motion.position=camera.unproject_position(point)
	main._screen_rotation_mouse_input(motion)
	var press := InputEventMouseButton.new(); press.button_index=MOUSE_BUTTON_LEFT; press.pressed=true; press.position=motion.position
	check(main._screen_rotation_mouse_input(press), "Desktop mouse can capture the photo arc")
	var angle: float = main._grab.rotate.last-deg_to_rad(104)
	point=photo.global_transform*photo.flat_pose*Vector3(cos(angle),sin(angle),0)
	motion.position=camera.unproject_position(point); main._screen_rotation_mouse_input(motion)
	press.position=motion.position; press.pressed=false; main._screen_rotation_mouse_input(press)
	check(photo.screen_rotation==90 and main._grab.is_empty(), "Mouse photo drag also snaps on release")
	main._screen_rotation_mouse_position=null

func layout_checks() -> void:
	var defaults:=Photo.new()
	check(not defaults.ground_vertical, "Ground-vertical policy defaults off"); defaults.free()
	camera.rotation=Vector3(deg_to_rad(32),deg_to_rad(21),deg_to_rad(12))
	for mode in 5:
		photo.set_layout_mode(mode); photo.gallery.recenter(); photo.gallery.synchronize()
		if mode in [0,1,4]: main._place_screen(true)
		var indices: Array = photo.gallery.cards.keys()
		var distance: float = photo.flat_pose.origin.distance_to(camera.global_position)
		var scale: float = photo.screen_scale
		main._on_photo_adjustment("ground_vertical",true)
		check(photo.ground_vertical and absf(photo.flat_pose.basis.z.y)<.00001, "Turning on levels the current photo immediately in layout %d"%mode)
		check(photo.gallery.cards.values().all(func(card): return absf(card.pose.basis.z.y)<.00001), "All visible gallery planes are perpendicular to ground")
		if mode in [2,3] and not photo.gallery.cards.is_empty():
			var focus: int=photo.gallery.cards.keys()[0]
			photo.gallery.focus=focus; photo.gallery._place_focus(); photo.gallery.progress=.5; photo.gallery._animate_focus()
			check(absf(photo.gallery.cards[focus].node.global_basis.z.y)<.00001, "Gallery focus animation keeps the photo plane vertical")
			photo.gallery.focus=-1; photo.gallery.progress=0
		check(photo.gallery.cards.keys()==indices and photo.screen_scale==scale and is_equal_approx(photo.flat_pose.origin.distance_to(camera.global_position),distance), "Live orientation toggle preserves batch, size and photo distance")
		photo.gallery.recenter(); photo.gallery.synchronize(); main._place_screen(true)
		check(absf(photo.flat_pose.basis.z.y)<.00001 and absf(photo.gallery.anchor.basis.z.y)<.00001, "New layout placement observes the same ground policy")
		var arbitrary:=Transform3D(Basis.from_euler(Vector3(.8,.3,.2)),photo.flat_pose.origin)
		photo.set_flat_world_pose(arbitrary)
		check(absf(photo.flat_pose.basis.z.y)<.00001, "Dragging and following cannot tilt an enabled photo plane")
		main._on_photo_adjustment("ground_vertical",false)
		check(photo.flat_pose.basis.is_equal_approx(camera.global_basis), "Turning off immediately restores the view-relative image plane")
		check(photo.gallery.anchor.basis.is_equal_approx(camera.global_basis), "All layout anchors use the full view orientation while off")
		photo.gallery._place_focus()
		check(photo.gallery.focus_pose.basis.is_equal_approx(camera.global_basis), "Opening a gallery photo follows the selected orientation policy")
	var settings:=ConfigFile.new(); photo.set_ground_vertical(true); photo.save_layout_settings(settings)
	var restored:=Photo.new(); restored.restore_view_settings(settings)
	check(restored.ground_vertical, "Ground policy persists globally across picture modes and app sessions")
	restored.free()
	for enabled in [false,true]:
		photo.set_ground_vertical(enabled); I18n.use("zh"); menu.section=1; menu.refresh()
		for option in [true, false]:
			var target: int=Menu.PHOTO_GROUND_VERTICAL_ON if option else Menu.PHOTO_GROUND_VERTICAL_OFF
			var buttons: Array=menu._buttons.filter(func(button): return button.target==target)
			check(buttons.size()==1 and buttons[0].rect.size==Vector2(.25,.075), "Ground setting reuses the adjacent-cache option button size")
			check(menu._tips[target]==("图片垂直于地面" if option else "图片平面垂直于视线"), "Each explicit option explains its orientation")
			menu._activate(target)
			check(photo.ground_vertical==option, "On/Off selection applies the requested policy immediately")
			menu._activate(target)
			check(photo.ground_vertical==option, "Clicking the selected option cannot toggle the policy accidentally")
			check(menu._buttons.filter(func(button): return button.target==target)[0].base_color==menu.SELECTED, "Exactly the chosen ground policy is highlighted")
	menu.dismiss(); I18n.use("en")

func layer_checks() -> void:
	photo.video_layer=Layer.new(); photo.platform=LayerHost.new(); photo.layer_enabled=true
	photo.set_screen_curve(60); photo.set_screen_rotation(0)
	check(photo._layer_eligible(), "Unrotated curved photos retain native cylinder layers")
	for angle in [45,90,135,270]:
		photo.set_screen_rotation(angle)
		check(not photo._layer_eligible(), "Native cylinder cannot replace a photo bent horizontally after rotation")
	photo._full_image=photo._texture.get_image(); photo._texture_full=false
	photo._texture=ImageTexture.create_from_image(Image.create(4,4,false,Image.FORMAT_RGBA8))
	photo._hole.visible=true; photo._process_layer()
	check(photo._texture_full and photo._texture.get_width()>4 and not photo._hole.visible, "Fallback restores full photo quality and closes the compositor hole")
	var origin:=XROrigin3D.new(); root.add_child(origin); camera.reparent(origin)
	photo._presentation_pending=true; photo._placeholder.visible=true
	photo._process_presentation()
	check(not photo._presentation_pending and not photo.placeholder_visible(), "A rotated curved photo finishes presentation even when native cylinder layers are available")
	camera.reparent(root); origin.free()
	photo.set_screen_rotation(180)
	check(photo._layer_eligible(), "Upside-down horizontal cylinder remains supported")
	photo.set_screen_curve(0); photo.set_screen_rotation(90)
	check(photo._layer_eligible(), "Flat photo rotation retains the native quad path")
	photo.begin_screen_rotation()
	check(not photo._layer_eligible(), "Continuous rotation previews never leave an old native layer visible")
	photo.finish_screen_rotation(false); photo.video_layer=null; photo.platform=null

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	for index in 12:
		var pixels:=Image.create(320,200,false,Image.FORMAT_RGBA8); pixels.fill(Color.from_hsv(index/12.0,.65,.85))
		for x in range(0,320,40): pixels.fill_rect(Rect2i(x,0,2,200),Color.WHITE)
		for y in range(0,200,40): pixels.fill_rect(Rect2i(0,y,320,2),Color.WHITE)
		var path:=ProjectSettings.globalize_path(output.path_join("photo%d.png"%index)); pixels.save_png(path)
		entries.append({"uri":"file://"+path,"title":"Photo %d"%index,"kind":"image"})
	main=Harness.new(); main.photo_active=true; main.settings_path=ProjectSettings.globalize_path(output.path_join("settings.cfg"))
	main.video=preload("res://scripts/mpv_video_display.gd").new(); root.add_child(main.video); main.video.set_process(false)
	camera=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,1.6,0)
	photo=Photo.new(); photo.history_enabled=false; photo.auto_depth=false; root.add_child(photo); photo.view_camera=camera; main.photo=photo
	photo.open_image(entries[0].uri,entries[0].title,entries); await settle()
	photo.set_flat_world_pose(Transform3D(Basis.IDENTITY,Vector3(0,1.6,-3)))
	var control:=Rotation.new(); root.add_child(control); main.screen_rotation_control=control
	menu=Menu.new(); root.add_child(menu); menu.set_process(false); menu.state_provider=photo.snapshot; menu.setting_requested.connect(main._on_photo_adjustment)
	main.photo_menu=menu; main.player_menu=menu
	main.recent_menu=preload("res://scripts/library_menu.gd").new(); main.recent_menu.visible=false
	main._update_screen_rotation_control(); check(not control.visible, "No permanent photo rotation button")
	geometry_checks(); await input_checks(); layer_checks(); layout_checks()
	menu.free(); control.free(); photo.free(); camera.free(); main.video.free(); main.recent_menu.free(); main.free()
	for failure in failures: push_error(failure)
	print("Photo orientation: %d checks, %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
