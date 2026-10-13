extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Gestures := preload("res://scripts/photo_hand_gestures.gd")
var failures: Array[String] = []
var checks := 0

class SlowHost extends RefCounted:
	var request := 100
	var released: Array[int] = []
	func open_photo(_uri: String) -> int: request += 1; return request
	func activate_photo(_id: int) -> bool: return false
	func cancel_photo(id: int) -> void: released.append(id)
	func release_photo(id: int) -> void: released.append(id)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var photo := Photo.new()
	photo.history_enabled = false
	photo.mode_memory = Memory.new("user://loading_modes_%d" % Time.get_ticks_usec())
	root.add_child(photo)
	photo.set_process(false)
	var host := SlowHost.new(); photo.platform = host
	var entries := [
		{"uri":"file://first.jpg", "title":"first.jpg", "kind":"image"},
		{"uri":"file://portrait.jpg", "title":"portrait.jpg", "kind":"image"},
		{"uri":"file://third.jpg", "title":"third.jpg", "kind":"image"}]
	photo.open_image(entries[0].uri, entries[0].title, entries)
	check(photo.loading and photo.placeholder_visible() and photo.index == -1, "First selection presents a placeholder before any response")
	var first_id: int = photo._request
	photo._on_ready(first_id, '{"state":"metadata","width":6000,"height":4000,"orientation":6}')
	check(photo.loading and photo._next_decode.is_empty(), "Header event does not start decoding an incomplete transfer")
	check(is_equal_approx(photo._placeholder_size.x / photo._placeholder_size.y, 2.0 / 3.0), "Portrait EXIF rotates placeholder dimensions")
	photo._process(0.3)
	check(photo._placeholder.transform == photo.flat_pose and not photo._transition_active, "Placeholder slide completes while IO remains pending")
	photo.navigate(1)
	var second_id: int = photo._request
	photo._on_ready(first_id, '{"state":"metadata","width":900,"height":100}')
	check(not photo.queue[1].has("photo_info"), "Stale header cannot reshape the new selection")
	photo._on_metadata(second_id, photo._serial - 1, 1, {"width":900,"height":100})
	check(not photo.queue[1].has("photo_info"), "Late decoder header is rejected by serial")
	photo._on_ready(second_id, '{"state":"metadata","width":2000,"height":1000}')
	check(is_equal_approx(photo._placeholder_size.x / photo._placeholder_size.y, 2.0), "Header corrects incoming aspect during the slide")
	var image := Image.create(64,32,false,Image.FORMAT_RGB8); image.fill(Color.RED)
	photo._accept({"image":image,"thumbnail":image,"info":{"width":2000,"height":1000}},
		{"id":second_id,"index":1,"direction":1})
	check(photo.index == 1 and not photo.loading and photo._transition_time == 0, "Fast decode joins the existing selection slide")
	photo.finish_transition()
	var original: ImageTexture = photo._texture
	photo.preview_navigation(-.045)
	check(photo.panel.position.x < photo.flat_pose.origin.x, "Held pinch gives immediate presentation movement")
	check(photo.flat_pose.origin.x == 0, "Swipe preview preserves the saved screen pose")
	photo.preview_navigation(0)
	check(photo.panel.transform == photo.flat_pose, "Cancelled swipe restores the presentation pose")
	photo.navigate(1)
	check(photo.placeholder_visible() and is_instance_valid(photo._departing), "Button selection animates away the old photo before decode")
	check(photo._departing.material_override.get_shader_parameter("photo_texture") == original, "Departing surface retains its own colour")
	photo._process(0.3)
	check(photo.material.get_shader_parameter("presentation_opacity") == 0.0 and photo.placeholder_visible(), "Finished slide keeps the placeholder visible while loading")
	photo._on_ready(photo._request, '{"state":"error"}')
	check(not photo.loading and not photo.placeholder_visible() and photo._texture == original, "Load failure restores the last successful photo")
	check(photo.material.get_shader_parameter("presentation_opacity") == 1.0, "Failure restores original opacity")
	photo._select(0, -1)
	photo._on_metadata(photo._request, photo._serial, photo.pending_index, {"width":320,"height":640})
	photo._process(0.3)
	var target: int = photo.pending_index
	photo._accept({"image":image,"thumbnail":image,"info":{}}, {"id":photo._request,"index":target})
	check(photo._reveal_seconds > 0 and photo.material.get_shader_parameter("reveal_progress") == 0.0, "Slow decode starts a reveal in place instead of a second slide")
	photo._process(Photo.REVEAL_SECONDS * .5)
	check(is_equal_approx(photo.material.get_shader_parameter("reveal_progress"), .5) and is_equal_approx(photo._placeholder_material.get_shader_parameter("reveal_progress"), .5), "Colour and frost share the same reveal frontier")
	photo._process(Photo.REVEAL_SECONDS * .5 + .01)
	check(not photo.placeholder_visible() and photo.material.get_shader_parameter("reveal_progress") == 1.0, "Reveal immediately releases the placeholder at completion")
	# Cache metadata is used before a foreground transfer can respond.
	photo.queue[2]["photo_info"] = {"width":4000,"height":6000}
	photo._select(2)
	check(is_equal_approx(photo._placeholder_size.x / photo._placeholder_size.y, 2.0/3.0), "Known queue dimensions immediately size the placeholder")
	photo._process(.3)
	var old_size: Vector2 = photo._placeholder_size
	photo.set_hand_scale(1.5)
	check(photo._placeholder_size.is_equal_approx(old_size * 1.5), "Two-hand zoom also resizes a waiting placeholder")
	photo.close_image()
	check(not photo.placeholder_visible() and not is_instance_valid(photo._departing), "Closing clears pending visual feedback")
	photo.open_image(entries[0].uri, entries[0].title, entries)
	photo._prefetch_request = 999
	photo._prefetched[1] = {"id":999,"decoded":false}
	photo._on_ready(999, '{"state":"metadata","width":1600,"height":900}')
	check(photo._prefetch_request == 999 and photo._prefetched.has(1) and not photo._prefetched[1].has("info"), "Preload metadata is nonterminal and cannot promote an incomplete source")
	check(photo.queue[1].photo_info.width == 1600, "Preload dimensions persist for a later selection")
	photo._on_ready(999, '{"state":"ready","width":1600,"height":900,"path":"file.jpg"}')
	check(photo._prefetch_request == 0 and photo._prefetched[1].has("info"), "Only the completed transfer publishes a preload source")
	# A running old decoder may finish slowly; selections and visual feedback keep responding.
	var blocked_id: int = photo._request
	photo._decoding = {"id":blocked_id,"serial":photo._serial,"index":photo.pending_index}
	var entered := Semaphore.new(); var release := Semaphore.new()
	photo._thread = Thread.new()
	photo._thread.start(func(): entered.post(); release.wait(); return {"error":"Image unavailable"})
	entered.wait()
	photo.navigate(1)
	check(photo._thread.is_alive() and photo.placeholder_visible() and photo.pending_index == 1,
		"Navigation responds while the old decoder is still blocked")
	check(photo._deferred_release_ids.has(blocked_id), "Old source remains leased until its decoder finishes")
	release.post()
	while photo._thread.is_alive(): await create_timer(.01).timeout
	photo._process(0)
	check(photo.loading and photo.error.is_empty() and not photo._deferred_release_ids.has(blocked_id),
		"Stale decode failure releases its lease without hiding the chosen placeholder")
	photo.close_image(); photo.free()
	var g := Gestures.new()
	var origin := Vector3(0,1,-.5)
	var hand := {"source":"hand","tracked":true,"position":origin,"down":true,"pressed":true}
	g.update({"right_hand":hand},true,1,Basis.IDENTITY,1,1)
	hand = hand.duplicate(); hand.pressed = false; hand.position = origin + Vector3(-.06,0,0)
	var result: Dictionary = g.update({"right_hand":hand},true,1,Basis.IDENTITY,1,1)
	check(result.actions.is_empty() and is_equal_approx(result.preview, -.06), "Held swipe previews without committing navigation")
	result = g.update({"right_hand":hand},false,1,Basis.IDENTITY,1,1)
	check(result.preview == 0, "Menu interruption cancels the swipe preview")
	for failure in failures: push_error(failure)
	print("Photo loading feedback: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
