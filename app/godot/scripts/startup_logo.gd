extends "res://scripts/main_logo.gd"

signal finished

const HOLD_SECONDS := 1.2
const FADE_SECONDS := 0.25
var ready_to_present: Callable
var interrupted: Callable
var elapsed := 0.0

func _ready() -> void:
	name = "StartupLogo"
	position = Vector3(0, 0, -1.8)
	(material_override as StandardMaterial3D).no_depth_test = true

func _process(delta: float) -> void:
	# Count visible frames only: OpenXR may start before the user wears the headset.
	if interrupted.is_valid() and interrupted.call():
		_finish()
		return
	if ready_to_present.is_valid() and not ready_to_present.call(): return
	elapsed += minf(delta, 0.1)
	var material := material_override as StandardMaterial3D
	material.albedo_color.a = 1.0 - clampf((elapsed - HOLD_SECONDS) / FADE_SECONDS, 0.0, 1.0)
	if elapsed >= HOLD_SECONDS + FADE_SECONDS: _finish()

func _finish() -> void:
	set_process(false)
	hide()
	finished.emit()
	queue_free()
