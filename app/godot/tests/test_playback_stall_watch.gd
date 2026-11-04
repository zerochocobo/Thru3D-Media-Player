extends SceneTree
## Playback clock stall detection: only a real stall while playing triggers, once per minute;
## a stall that returns where the reopen restarted stops the recovery loop.
const Watch := preload("res://scripts/playback_stall_watch.gd")
var failures: Array[String] = []
var checks := 0
func _initialize() -> void:
	var watch := Watch.new()
	check(watch.observe(true, 10.0, 1000) == Watch.NONE, "First sample only anchors")
	check(watch.observe(true, 10.0, 4900) == Watch.NONE, "3.9 s frozen is not yet a stall")
	check(watch.observe(true, 10.0, 5000) == Watch.RECOVER, "4 s frozen while playing is a stall")
	# The reopen resumes and plays on: the next stall elsewhere is a new one.
	watch.observe(false, 10.0, 5500)
	for i in range(30): watch.observe(true, 10.0 + i * 0.1, 6000 + i * 100)
	check(watch.observe(true, 12.9, 9100) == Watch.NONE and watch.observe(true, 12.9, 13200) == Watch.NONE,
		"A new stall is not reopened within a minute")
	check(watch.observe(true, 12.9, 70000) == Watch.RECOVER, "A stall elsewhere past the minute recovers again")

	watch = Watch.new()
	var advancing := true
	for i in range(100): advancing = advancing and watch.observe(true, 10.0 + i * 0.1, 1000 + i * 100) == Watch.NONE
	check(advancing, "An advancing clock never stalls")

	watch = Watch.new()
	watch.observe(true, 20.0, 0)
	check(watch.observe(false, 20.0, 3000) == Watch.NONE, "Pause/buffering/seek resets the window")
	check(watch.observe(true, 20.0, 5000) == Watch.NONE and watch.observe(true, 20.0, 8900) == Watch.NONE, "The window restarts after resuming")
	check(watch.observe(true, 20.0, 9000) == Watch.RECOVER, "A stall after resuming is still detected")

	watch = Watch.new()
	check(watch.observe(true, NAN, 0) == Watch.NONE and watch.observe(true, -1.0, 9000) == Watch.NONE, "No clock is never a stall")

	# 2026-11-04 device case: the system stopped consuming the app's audio, so every reopen froze
	# at the same spot and the player reopened once a minute forever.
	watch = Watch.new()
	watch.observe(true, 1028.041, 1000)
	check(watch.observe(true, 1028.041, 5000) == Watch.RECOVER, "First freeze reopens")
	watch.observe(false, 1028.041, 5100) # reopening
	watch.observe(true, 1028.042, 6000)
	check(watch.observe(true, 1028.042, 9900) == Watch.NONE, "The reopen gets the full window")
	check(watch.observe(true, 1028.042, 10000) == Watch.STUCK, "Freezing again at the reopen position is stuck, without waiting a minute")
	check(watch.observe(true, 1028.042, 70000) == Watch.NONE, "Stuck is reported once")

	watch = Watch.new()
	watch.observe(true, 50.0, 1000)
	watch.observe(true, 50.0, 5000)
	watch.forget()
	watch.observe(true, 50.0, 6000)
	check(watch.observe(true, 50.0, 10000) == Watch.RECOVER, "Another file starts without the earlier recovery")
	print("Playback stall watch: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(1 if failures.size() else 0)
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
