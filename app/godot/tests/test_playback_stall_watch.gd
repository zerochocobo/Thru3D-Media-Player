extends SceneTree
## Playback clock stall detection: only a real stall while playing triggers, once per minute.
const Watch := preload("res://scripts/playback_stall_watch.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void:
	var watch := Watch.new()
	check(not watch.observe(true, 10.0, 1000), "First sample only anchors")
	check(not watch.observe(true, 10.0, 4900), "3.9 s frozen is not yet a stall")
	check(watch.observe(true, 10.0, 5000), "4 s frozen while playing is a stall")
	check(not watch.observe(true, 10.0, 9100), "A recovery is not repeated within a minute")
	check(watch.observe(true, 10.0, 70000), "A stall that persists past the minute recovers again")
	watch = Watch.new()
	var advancing := true
	for i in range(100): advancing = advancing and not watch.observe(true, 10.0 + i * 0.1, 1000 + i * 100)
	check(advancing, "An advancing clock never stalls")
	watch = Watch.new()
	watch.observe(true, 20.0, 0)
	check(not watch.observe(false, 20.0, 3000), "Pause/buffering/seek resets the window")
	check(not watch.observe(true, 20.0, 5000) and not watch.observe(true, 20.0, 8900), "The window restarts after resuming")
	check(watch.observe(true, 20.0, 9000), "A stall after resuming is still detected")
	watch = Watch.new()
	check(not watch.observe(true, NAN, 0) and not watch.observe(true, -1.0, 9000), "No clock is never a stall")
	print("Playback stall watch: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
