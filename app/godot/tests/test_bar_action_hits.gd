extends SceneTree

const Video := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func hit(menu: Node3D, point: Vector2) -> int:
	return int(menu.ray_hit(menu.to_global(Vector3(point.x, point.y, 1)), -menu.global_basis.z).get("target", -1))

func control(menu: Node3D, target: int) -> Dictionary:
	for button in menu._buttons:
		if button.target == target: return button
	return {}

func inspect(menu: Node3D, label: String) -> void:
	var row: Array = []
	for button in menu._buttons:
		if button.node.get_parent() != menu or not is_equal_approx(button.node.position.y, 0.215): continue
		row.append(button)
		if not button.rect.size.is_equal_approx(Vector2(0.10, 0.10)): continue
		check(button.node.mesh.size.is_equal_approx(Vector2(0.08, 0.08)), label + ": visible disc unchanged")
		check(button.node.get_child(1).mesh.size.is_equal_approx(Vector2(0.044, 0.044)), label + ": icon unchanged")
		var centre: Vector2 = button.rect.get_center()
		for offset in [Vector2(-0.047, 0), Vector2(0.047, 0), Vector2(0, -0.047), Vector2(0, 0.047)]:
			var target := hit(menu, centre + offset)
			check(target == button.target if button.enabled else target != button.target, label + ": expanded edge respects enabled state")
	row.sort_custom(func(a, b): return a.rect.get_center().x < b.rect.get_center().x)
	for index in range(1, row.size()):
		var left: Dictionary = row[index - 1]
		var right: Dictionary = row[index]
		var gap: float = right.rect.position.x - left.rect.end.x
		check(gap >= 0.0149, label + ": neighboring targets keep a dead zone")
		if left.rect.size.is_equal_approx(Vector2(0.10, 0.10)) and right.rect.size.is_equal_approx(Vector2(0.10, 0.10)):
			check(gap >= 0.0399, label + ": compact row retains 0.04 safety gap")
		for fraction in [0.1, 0.5, 0.9]:
			var target := hit(menu, Vector2(lerpf(left.rect.end.x, right.rect.position.x, fraction), 0.215))
			check(target != left.target and target != right.target, label + ": ray in gap selects neither neighbor")
	var inside := control(menu, 11)
	check(inside.rect.size.is_equal_approx(Vector2(0.075, 0.075)), label + ": panel settings hit area unchanged")
	var library := control(menu, 100)
	check(library.rect.size.is_equal_approx(Vector2(0.10, 0.10)), label + ": library expanded")
	check(library.node.position.is_equal_approx(Vector3(0, 0.215, 0.002)), label + ": layout unchanged")

func run() -> void:
	var state := {"has_video": true, "has_image": true, "source_uri": "test.mp4", "title": "Test", "count": 20,
		"index": 0, "duration_ms": 60000, "audio_available": true, "can_previous": true, "can_next": true,
		"has_previous_video": true, "has_next_video": true, "audio_play_during_video": true,
		"capture": {"available": true}, "favorite": {"available": true}, "can_save_pictures": true}
	var video := Video.new()
	root.add_child(video)
	video.state_provider = func(): return state
	video.visible = true; video.refresh()
	inspect(video, "video")
	video.music_quick.expanded = true; video.refresh()
	inspect(video, "video music expanded")
	video.music_quick.expanded = false
	state.disc_menu_available = true; video.refresh()
	inspect(video, "video disc and capture")
	state.disc_menu_available = false
	state.has_video = false; video.refresh()
	inspect(video, "video idle")
	state.has_video = true
	video.refresh()
	# The real quick-slider blocker must still win over a larger target behind it.
	video._volume_open = true; video.refresh()
	var music: Dictionary = control(video, Video.MUSIC_OPEN)
	var point: Vector2 = music.rect.get_center() - Vector2(0.047, 0)
	check(hit(video, point) != Video.MUSIC_OPEN, "Volume popup blocks expanded music target")
	video.free()
	var photo := Photo.new()
	root.add_child(photo)
	photo.state_provider = func(): return state
	photo.visible = true
	for layout in range(5):
		state.layout = layout; state.gallery_focus = -1; photo.refresh()
		inspect(photo, "photo layout %d" % layout)
		photo.music_quick.expanded = true; photo.refresh()
		inspect(photo, "photo music layout %d" % layout)
		photo.music_quick.expanded = false
	state.gallery_focus = 0; photo.refresh(); inspect(photo, "photo return")
	state.portrait_requested = true; photo.refresh(); inspect(photo, "photo portrait")
	photo.free()
	print("Bar action hits: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
