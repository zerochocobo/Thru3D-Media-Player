extends SceneTree
## Menu holes clear the projection alpha only when nothing is composited beneath the menu layers.
const Display := preload("res://scripts/xr_display.gd")
const Composition := preload("res://scripts/menu_composition.gd")
var failures: Array[String] = []
func _initialize() -> void:
	var composition := Composition.new()
	var display := Display.new()
	composition.display = display
	expect(composition, true, "Opaque scenery without layers beneath")
	display.video_layer = true
	expect(composition, false, "A video layer beneath keeps the scaled alpha")
	display.video_layer = false
	display.browser_layer = true
	expect(composition, false, "A browser underlay keeps the scaled alpha")
	display.browser_layer = false
	display.applied_passthrough = true
	expect(composition, false, "Passthrough keeps the scaled alpha")
	display.applied_passthrough = false
	expect(composition, true, "Back to opaque scenery")
	composition.free()
	print("Menu opaque scene: %d failures" % failures.size())
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
func expect(composition: Node, wanted: bool, message: String) -> void:
	composition._sync_opaque_scene()
	if composition._opaque_scene != wanted: failures.append(message)
