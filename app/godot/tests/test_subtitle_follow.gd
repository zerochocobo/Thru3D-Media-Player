extends SceneTree
## Captions that follow the view: they rest while the view stays near, glide after it once it has
## left, and keep their own offsets and limits.

const Follow := preload("res://scripts/subtitle_follow.gd")
const Depth := preload("res://scripts/subtitle_depth.gd")
var failures: Array[String] = []
var checks := 0

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func _near(a: float, b: float, tolerance := 0.001) -> bool:
	return absf(a - b) < tolerance

func _view(yaw: float, pitch := 0.0) -> Vector3:
	return Follow.direction(Vector2(deg_to_rad(yaw), deg_to_rad(pitch)))

func _init() -> void:
	var follow := Follow.new()
	follow.tick(_view(30, 10), 0.014)
	_check(_near(follow.centre.x, deg_to_rad(30)) and _near(follow.centre.y, deg_to_rad(10)), "The first view places the captions")
	follow.tick(_view(38, 12), 0.014)
	_check(_near(follow.centre.x, deg_to_rad(30)) and _near(follow.centre.y, deg_to_rad(10)), "A view that stays near leaves the captions where they are")
	follow.tick(_view(45, 10), 0.014)
	var first := follow.centre.x
	_check(first > deg_to_rad(30) and first < deg_to_rad(33), "A view that has left starts the captions gliding")
	for i in 200: follow.tick(_view(45, 10), 0.014)
	_check(_near(follow.centre.x, deg_to_rad(45), deg_to_rad(0.6)), "The glide ends under the view")
	var rested := follow.centre
	follow.tick(_view(50, 10), 0.014)
	_check(follow.centre == rested, "Captions that arrived rest again")
	follow.tick(_view(170, 0), 0.014)
	_check(_near(follow.centre.x, deg_to_rad(170)), "Captions left out of sight are put under the view")
	for i in 400: follow.tick(_view(-175, 0), 0.014)
	_check(_near(absf(follow.centre.x), deg_to_rad(175), deg_to_rad(0.6)) and follow.centre.x < 0.0, "The glide crosses the back of a 360 picture the short way")
	follow.tick(_view(-175, 89), 0.014)
	for i in 400: follow.tick(_view(-175, 89), 0.014)
	_check(follow.centre.y <= Follow.MAX_PITCH + 0.001, "Captions stop short of the pole")
	follow.reset()
	follow.tick(_view(0, 0), 0.014)
	_check(follow.centre.is_zero_approx(), "A reset places the captions anew")

	var down := Depth.view_anchor(Vector2(deg_to_rad(100), deg_to_rad(-15))) * Vector3.FORWARD
	_check(down.is_equal_approx(_view(100, -15)), "A following anchor reaches all the way round")
	_check(Depth.follow_default(false) == Vector2(0, -15) and Depth.follow_default(true) == Vector2(20, 0), "Lines start below the view centre, columns beside it")
	var row := Depth.follow_row("subtitle_vertical_position", -50.0, false)
	_check(row.value == -30.0 and row.span == Vector3(-30, 30, 1) and row.reset_value == -15.0, "A following offset stays within sight and resets to its own default")
	_check(Depth.follow_row("subtitle_horizontal_position", 5.0, true).reset_value == 20.0, "Columns reset beside the view centre")
	var settings := ConfigFile.new()
	_check(Depth.restore_follow(settings, false) == Vector2(0, -15), "Unsaved offsets are the defaults")
	Depth.save_follow(settings, Vector2(4, -22), Vector2(-25, 3))
	_check(Depth.restore_follow(settings, false) == Vector2(4, -22) and Depth.restore_follow(settings, true) == Vector2(-25, 3), "Offsets survive a save")
	_check(Depth.mode_row(true).value == 1 and Depth.mode_row(false).choices.size() == 2
		and Depth.mode_row(false).choices.all(func(choice): return not str(choice.get("hint", "")).is_empty()), "Both caption modes explain themselves on hover")

	print("subtitle follow: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: printerr("ERROR: " + failure)
	quit(0 if failures.is_empty() else 1)
