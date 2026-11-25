extends SceneTree
const Position := preload("res://scripts/depth_position.gd")
const Foreground := preload("res://scripts/depth_foreground.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const Main := preload("res://scripts/main.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Spatial := preload("res://scripts/photo_spatial_geometry.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var calls: Array = []
	var foregrounds: Array = []
	func set_mpv_depth_view(id: int, strength: float, plane: float) -> bool:
		calls.append([id, strength, plane]); return true
	func set_mpv_depth_foreground(id: int, scale: float) -> bool:
		foregrounds.append([id, scale]); return true
	func prepare_photo_3d(_id: int, _strength: float) -> bool: return true
	func prepare_photo_3d_view(id: int, strength: float, plane: float, rotation: int) -> bool:
		calls.append([id, strength, plane, rotation]); return true
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var directory := ProjectSettings.globalize_path("res://../../build/output/depth-position/test-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	for invalid in [null, "35", NAN, INF, -INF]: check(Position.normalize(invalid) == 0, "Invalid preference defaults")
	check(Position.normalize(999) == 100 and Position.normalize(-999) == -100, "Bound user offsets")
	check(is_equal_approx(Position.convergence(0), 0.35), "Default preserves existing plane")
	var cfg := ConfigFile.new()
	cfg.set_value("video", Position.KEY, -70); cfg.set_value("photo", Position.KEY, 45)
	cfg.save(directory.path_join("preferences.cfg")); cfg = ConfigFile.new(); cfg.load(directory.path_join("preferences.cfg"))
	check(Position.load_value(cfg) == -70 and Position.load_value(cfg, true) == 45, "Video/photo preferences survive reload independently")
	var video := Video.new()
	video.mode_memory = Memory.new(directory.path_join("modes"))
	video.material = ShaderMaterial.new()
	video.material.shader = preload("res://shaders/video_rvm_pair.gdshader")
	video.local_uri = "file:///position-a.mp4"
	video.media.session_id = 12; video.depth_enabled = true; video.depth_requested = true
	var host := Host.new(); video.platform = host
	video.set_depth_position(-20)
	check(video.depth_position == -20, "Global default applies without override")
	var strength := video.depth_strength
	video.set_depth_position(100)
	check(is_equal_approx(host.calls.back()[2], 0.05) and video.depth_strength == strength, "Paused-frame bridge updates plane without changing strength")
	var count := host.calls.size(); video._send_depth_view()
	check(host.calls.size() == count, "Unchanged parameters deduplicate")
	video.set_depth_position(-100)
	check(host.calls.size() == count + 1 and is_equal_approx(host.calls.back()[2], 0.65), "Plane change participates in bridge key")
	check(is_equal_approx(video.material.get_shader_parameter("depth_convergence"), 0.65), "Fallback shader agrees with native plane")
	video.set_depth_position(40)
	check(video.depth_position == 40, "Global change updates current video")
	video.media.state = "paused"; video._remember_file = true
	video._remember_mode()
	var saved := video.mode_memory.lookup(video.local_uri)
	check(not saved.has(Position.KEY), "Position is never stored per file")
	var legacy := saved.duplicate(); legacy[Position.KEY] = -90
	video._restore_saved_mode(legacy)
	check(video.depth_position == 40, "Opening a saved file preserves global position")
	Privacy.configure_file_settings(Privacy.NONE)
	video.local_uri = "file:///private-position.mp4"; video.set_depth_position(30)
	Privacy.configure_file_settings(Privacy.ALL)
	check(video.depth_position == 30, "Global position works independently of per-file memory")
	var main := Main.new(); main.video = video; main.settings_path = directory.path_join("settings.cfg")
	main._on_player_setting(Position.KEY, 30)
	var stored := ConfigFile.new(); stored.load(main.settings_path)
	check(Position.load_value(stored) == 30, "Playback slider commits global video preference")
	main._on_playback_adjustment("depth_position_default", -45)
	main._on_setting_changed("depth_position_default", -45)
	stored.load(main.settings_path)
	check(video.depth_position == -45 and Position.load_value(stored) == -45, "Global video entry shares the same persisted value")
	video.set_depth_position(30)
	for invalid in [null, "35", NAN, INF, -INF]: check(Foreground.normalize(invalid) == 0, "Invalid foreground scale defaults")
	check(Foreground.normalize(999) == 100 and Foreground.normalize(-999) == -100 and Foreground.scale(-50) == -0.5, "Foreground scale is bounded and maps to the bridge's -1..1")
	count = host.calls.size()
	video.set_depth_foreground(60)
	check(host.foregrounds.back() == [12, 0.6] and host.calls.size() == count + 1 and video.depth_position == 30, "Foreground scale reaches the bridge with a redraw, plane unchanged")
	count = host.calls.size(); video._send_depth_view()
	check(host.calls.size() == count, "Unchanged foreground scale deduplicates")
	main._on_playback_adjustment("depth_foreground_default", -40)
	main._on_setting_changed("depth_foreground_default", -40)
	stored.load(main.settings_path)
	check(video.depth_foreground == -40 and Foreground.load_value(stored) == -40, "Global foreground entry persists")
	main._on_player_setting(Foreground.KEY, 25)
	stored.load(main.settings_path)
	check(video.depth_foreground == 25 and Foreground.load_value(stored) == 25, "Playback foreground slider commits the same global value")
	var photo := Photo.new(); photo.material = ShaderMaterial.new(); photo.material.shader = preload("res://shaders/photo.gdshader")
	photo.platform = host; photo.geometry = 0
	check(photo.set_depth_position(75) and photo.depth_position == 75 and video.depth_position == 30, "Photo preference independent of video")
	var depth := Image.create(4,4,false,Image.FORMAT_RF)
	var pair := Image.create(8,4,false,Image.FORMAT_RGBA8)
	var data := {"image":depth,"stereo_image":pair,"strength":photo.depth_strength,"rotation":0,"convergence":0.35}
	check(not photo._valid_cached_depth(data), "Old generated photo plane is not a valid cache hit")
	data.convergence = Position.convergence(75)
	check(photo._valid_cached_depth(data), "Matching generated photo plane is reusable")
	photo._metadata = {"native_stereo":true}
	check(not photo.set_depth_position(-50) and photo.depth_position == 75, "Native stereo remains unchanged")
	for strength_value in [0.0, 0.5, 1.0, 2.0]:
		for near in [0.0, 0.35, 1.0]:
			var a := Spatial.point(Vector2(0.5,0.5), near, Vector3(0,0,3), Vector2(2,1), strength_value, Position.convergence(-100))
			var b := Spatial.point(Vector2(0.5,0.5), near, Vector3(0,0,3), Vector2(2,1), strength_value, Position.convergence(100))
			check(b.z >= a.z, "Spatial image follows screen-in/out direction")
			check(Spatial.point(Vector2.ZERO,near,Vector3(0,0,3),Vector2(2,1),strength_value,Position.convergence(100)).z == 0, "Spatial portal boundary remains fixed")
	var state := {"has_video":true,"has_image":true,"geometry":0,"source_uri":"file:///a.mp4","depth_available":true,"depth_requested":true,"depth_strength":0.5,"depth_position":0,"count":1}
	for is_photo in [false,true]:
		var menu: Node3D = PhotoMenu.new() if is_photo else Menu.new()
		menu.state_provider = func(): return state.duplicate()
		root.add_child(menu); menu.set_process(false); menu.toggle()
		menu.section = 1
		menu._depth_expanded = true # the position slider sits under the 2D to 3D header
		menu.refresh()
		if not is_photo:
			menu.adjustment_requested.connect(main._on_playback_adjustment)
			menu.adjustment_committed.connect(main._save_playback_adjustments)
			var slider: Dictionary = menu._adjust_rows[Menu.DEPTH_POSITION]
			var speed: Dictionary = menu._adjust_rows[453]
			check(slider.left == speed.left and slider.width == speed.width and slider.label.position.x == speed.label.position.x, "Settings slider columns align")
			var p: Vector3 = menu.to_global(Vector3(slider.left + slider.width, slider.button.node.position.y, 1))
			check(menu.press_pointer("right_hand", p, -menu.global_basis.z, true), "Settings ray captures position slider")
			check(menu.has_pointer_capture(), "Settings drag owns pointer")
			menu.release_pointer("right_hand", p, -menu.global_basis.z, true)
			stored.load(main.settings_path)
			check(video.depth_position == 100 and Position.load_value(stored) == 100, "Settings release saves global position")
			var foreground_row: Dictionary = menu._adjust_rows.get(Menu.DEPTH_FOREGROUND, {})
			check(not foreground_row.is_empty() and foreground_row.left == slider.left, "Foreground scale sits under the convergence")
			if not foreground_row.is_empty():
				var f: Vector3 = menu.to_global(Vector3(foreground_row.left, foreground_row.button.node.position.y, 1))
				check(menu.press_pointer("right_hand", f, -menu.global_basis.z, true), "Settings ray captures foreground slider")
				# Held past the tap time, the slider clears the menu down to its own row.
				menu.pointer_held = func(_hand): return true
				menu._adjust_pressed_ms -= 1000
				menu.update_pointer("right_hand", f, -menu.global_basis.z, true)
				check(not menu._backdrop.visible and foreground_row.knob.visible, "Held foreground slider clears the menu, keeps its row")
				menu.release_pointer("right_hand", f, -menu.global_basis.z, true)
				stored.load(main.settings_path)
				check(menu._backdrop.visible and video.depth_foreground == -100 and Foreground.load_value(stored) == -100, "Release brings the menu back and saves the foreground scale")
			menu.section = 0; menu._depth_open = true; menu.refresh()
			check(not menu._adjust_rows.has(Menu.DEPTH_POSITION) and menu.choices.sliders.is_empty(), "Quick strength rail has no position popup")
			var rail_button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.DEPTH)[0]
			var r: Vector3 = rail_button.node.global_position + menu.global_basis.z
			check(menu.press_pointer("left_hand", r, -menu.global_basis.z, true) and menu._depth_hand == "left_hand", "Ray captures the strength rail")
			menu._adjust_pressed_ms -= 1000
			menu.update_pointer("left_hand", r, -menu.global_basis.z, true)
			check(not menu._backdrop.visible and rail_button.node.visible and menu._depth_rail_nodes.all(func(n): return n.visible), "Held strength rail clears the menu, keeps the rail")
			menu.release_pointer("left_hand", r, -menu.global_basis.z, true)
			check(menu._backdrop.visible and menu._depth_hand.is_empty(), "Rail release brings the menu back")
			menu.pointer_held = Callable()
			main._on_player_setting(Position.KEY, -45)
			menu.free()
			continue
		if is_photo:
			photo._metadata = {}; main.photo = photo; main.photo_menu = menu; main.photo_active = true
			menu.adjustment_requested.connect(main._on_photo_adjustment)
			menu.setting_requested.connect(main._on_photo_adjustment)
		var targets: Array = menu.choices.targets.keys().filter(func(t): return menu.choices.targets[t].get("key") == Position.KEY and menu.choices.targets[t].kind == "slider")
		check(targets.size() == 1, "One position slider in the requested entry")
		if targets.size() == 1:
			var slider: Dictionary = menu.choices.sliders[targets[0]]
			var previews: Array = []; var commits: Array = []
			menu.adjustment_requested.connect(func(_key,value): previews.append(value))
			menu.setting_requested.connect(func(_key,value): commits.append(value))
			var p: Vector3 = slider.node.to_global(Vector3(slider.left + slider.width,0,1))
			check(menu.press_pointer("right_hand",p,-menu.global_basis.z,true), "Ray captures position slider")
			check(menu.has_pointer_capture(), "Dragging owns pointer and blocks playback shortcuts")
			menu.release_pointer("right_hand",p,-menu.global_basis.z,true)
			check(not previews.is_empty() and previews.back() == 100, "Right endpoint previews screen-out")
			check(commits.size() == 1 and commits[0] == 100, "Release commits global preference once")
		if is_photo:
			stored.load(main.settings_path)
			check(Position.load_value(stored, true) == 100 and Position.load_value(stored) == -45, "Photo release saves independent global value")
		menu.free()
	main.free(); photo.free(); video.free()
	for failure in failures: push_error(failure)
	print("Depth position: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
