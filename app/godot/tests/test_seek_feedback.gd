extends SceneTree
const Feedback := preload("res://scripts/seek_feedback.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Overlay := preload("res://scripts/seek_overlay.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
var failures: Array[String] = []
var checks := 0

class InputMain extends "res://scripts/main.gd":
	func _update_menu_pointer(_hand: String, _activate: bool = false) -> bool: return false

class CountMenu extends "res://scripts/player_menu.gd":
	var value_refreshes := 0
	func refresh_values() -> void:
		value_refreshes += 1
		super.refresh_values()

class BindingProbe extends "res://scripts/pair_texture_binding.gd":
	func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
		material = target; ticket = pair.duplicate(true); return true

class Host extends RefCounted:
	var revisions: Array = []
	var pair := {}
	var revision_id := 0
	var acknowledge := true
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, target: int, _depth: bool, _tb: bool, _exact: bool) -> int:
		revisions.append([id, target]); return revision_id
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func set_mpv_audio(_id: int, _volume: float, _muted: bool, _track: int) -> void: pass
	func close_mpv_video(_id: int) -> void: pass
	func claim_mpv_pair(_id: int, _token: int) -> String: return JSON.stringify(pair)
	func acknowledge_mpv_pair(_id: int, _token: int) -> bool: return acknowledge
	func detach_mpv_pair(_id: int, _token: int) -> bool: return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func tick(main: Node3D, left: Vector2, right: Vector2, seconds: float = 0.05) -> void:
	main._update_seek_feedback(seconds)
	main._process_sticks(left, right, seconds)
	main.seek_overlay.refresh()

func reset(main: Node3D, host: RefCounted, position: int = 30000, duration: int = 300000) -> void:
	main.seek_feedback.clear(); main.controller_bindings.restore_all()
	main.stick_controls.suspend(); main.video.control.reject()
	main.video._pending_revision.clear(); main.video._waiting_first = false
	main.video.picker_error = ""; main.video.local_uri = "https://fixture/movie.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"
	main.video.media.playback = {"details": {"seekable": "yes"}}
	main.video.control.observe(position, duration); main.video.requested_play = true
	main.video.geometry = 0; main.video._layer_session = false
	main.video._binding.ticket.clear(); host.revisions.clear(); host.revision_id = 0; host.acknowledge = true
	main.video_menu._reset_navigation(); main.video_menu.dismiss()
	main.display.preview = true; main.photo_active = false
	tick(main, Vector2.ZERO, Vector2.ZERO)

func present(main: Node3D, host: RefCounted, actual_ms: int) -> void:
	main.video.control.take_pending(); main.video._pending_revision.clear()
	host.pair = {"session_id": main.video.media.session_id, "logical_session_id": 7, "generation": 2,
		"format_revision": 1, "effect_revision": 1, "model_generation": 1,
		"frame_id": 70, "pts_us": actual_ms * 1000, "source_epoch": 2, "slot_token": 10,
		"width": 1920, "height": 1080, "alpha_requested": false, "inference_ran": false, "source_pts_verified": true}
	main.video._pending_pair = host.pair
	main.video._present_pending()

func check_bookmarks_while_seeking(main: Node3D, host: RefCounted, menu: Node3D, video: Node3D) -> void:
	reset(main, host, 60000, 2400000)
	var Store := preload("res://scripts/bookmark_store.gd")
	var directory := ProjectSettings.globalize_path("res://../../build/output/seek-feedback/bookmarks-" + str(Time.get_ticks_usec()))
	video.bookmark_store = Store.new(directory)
	video._bookmark_metadata = {"basename": "movie.mp4", "size": 5000}; video._bookmark_resolve()
	video.media.generation = 3; video.panel.visible = true
	video._binding.ticket = {"session_id": 7, "generation": 3, "pts_us": 60000000, "slot_token": 9, "source_pts_verified": true}
	var old: Dictionary = video.bookmark_store.add(video.local_uri, "movie.mp4", 5000, 30000)
	var scope: String = video.bookmark_scope()
	menu.toggle()
	check(menu._state.bookmark_ready, "Confirmed playback frame permits adding a bookmark")
	var revision: int = video.bookmark_store.revision
	main._begin_stick_seek("left_hand", "stick_right", 240000)
	menu.refresh_values()
	check(main.seek_feedback.phase == "preview" and menu._elapsed.text == "05:00" and video.control.observed_position_ms == 60000, "Four-minute preview moves the UI clock while the displayed frame remains at one minute")
	check(not menu._state.bookmark_ready, "Four-minute seek preview disables bookmark creation before the decoder seek exists")
	check(not menu._buttons.filter(func(item): return item.target == menu.BookmarkMenu.ADD)[0].enabled, "Preview disables the real add control")
	main._on_bookmark_request("add", "", scope)
	check(video.bookmark_store.revision == revision and video.bookmark_store.list_markers(video._bookmark_media_id).size() == 1, "Stale add request during preview cannot save the original frame behind the target clock")
	main.seek_feedback.poll(Vector2.ZERO, 0.05)
	main.seek_feedback.sequence = video.control.sequence + 1
	video.seek_absolute(main.seek_feedback.target_ms)
	menu.refresh_values(); main._on_bookmark_request("add", "", scope)
	check(not menu._state.bookmark_ready and video.bookmark_store.revision == revision, "Waiting for the actual seek frame still prevents adding")
	present(main, host, 299000)
	check(main.seek_feedback.phase == "done" and menu._state.bookmark_ready, "Acknowledged seek landing re-enables add while its feedback fades")
	main._on_bookmark_request("add", "", scope)
	var markers: Array = video.bookmark_store.list_markers(video._bookmark_media_id)
	check(markers.size() == 2 and markers[0].id == old.id and markers[1].position_ms == 299000, "After seeking, bookmark uses the confirmed source time rather than the old frame or predicted target")
	var groups: Array = menu._buttons.filter(func(item): return menu.bookmarks.targets.get(item.target, {}).get("kind") == "group")
	check(groups.size() == 2 and groups.all(func(item): return menu.bookmarks.targets[item.target].ids.size() == 1), "Bookmarks four minutes apart in a forty-minute movie stay in separate timeline positions")
	if groups.size() == 2:
		check(is_equal_approx(groups[1].node.position.x, -menu.BAR_SEEK / 2 + menu.BAR_SEEK * 299000.0 / 2400000), "Post-seek marker is placed at its own confirmed timestamp")
	menu.dismiss()

func run() -> void:
	var host := Host.new()
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.platform = host; video._binding = BindingProbe.new(); video._remember_file = false
	var main := InputMain.new(); main.video = video
	main.settings_path = "user://seek_visibility_%d.cfg" % Time.get_ticks_usec()
	video.changed.connect(main._on_video_changed)
	video.seek_presented.connect(main._on_stick_seek_presented)
	var menu := CountMenu.new(); menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	var camera := XRCamera3D.new(); root.add_child(camera); main.xr_camera = camera
	var overlay := Overlay.new(); overlay.source = main._seek_overlay_sample
	camera.add_child(overlay); overlay.set_process(false); main.seek_overlay = overlay
	check_bookmarks_while_seeking(main, host, menu, video)
	reset(main, host)
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(overlay.visible, "Missing visibility setting preserves the existing progress HUD")
	main._on_setting_changed("stick_seek_overlay", false)
	check(not overlay.visible and main.seek_feedback.phase == "preview" and main.seek_feedback.target_ms == 40000, "Turning off HUD immediately hides it without cancelling the seek preview")
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("ui", "stick_seek_overlay", true) == false, "Progress visibility persists across config reload")
	tick(main, Vector2.ZERO, Vector2.ZERO)
	check(not overlay.visible and host.revisions.size() == 1 and host.revisions[0][1] == 40000, "Hidden HUD still submits the same seek on release")
	main._on_setting_changed("stick_seek_overlay", true)
	check(overlay.visible, "Turning HUD back on restores current feedback")
	reset(main, host); main._on_setting_changed("stick_seek_overlay", false); main._show_player_menu()
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(menu._elapsed.text == "00:40" and not overlay.visible, "Hiding passive HUD preserves visible transport timeline feedback")
	main._on_setting_changed("stick_seek_overlay", true)
	for geometry in [0, 1, 2, 3]:
		for hand in ["left_hand", "right_hand"]:
			for direction in [-1, 1]:
				reset(main, host); video.geometry = geometry
				var left := Vector2(direction, 0) if hand == "left_hand" else Vector2.ZERO
				var right := Vector2(direction, 0) if hand == "right_hand" else Vector2.ZERO
				tick(main, left, right)
				var step: int = (20000 if hand == "left_hand" else 10000) * direction
				check(host.revisions.is_empty() and video.control.display_position_ms() == 30000 and main.seek_feedback.target_ms == 30000 + step,
					"A short push only previews the original hand step: %s/%s/%s" % [geometry, hand, direction])
				check(overlay.visible and overlay.clock.text.contains(Feedback.time(30000 + step)) and not menu.visible, "Hidden transport has passive progress feedback")
				tick(main, Vector2.ZERO, Vector2.ZERO)
				check(host.revisions.size() == 1 and host.revisions[0][1] == 30000 + step and main.seek_feedback.phase == "waiting", "Release submits exactly one absolute target")
				tick(main, Vector2.ZERO, Vector2.ZERO)
				check(host.revisions.size() == 1 and overlay.visible, "Waiting never resubmits or disappears before a frame")
	reset(main, host)
	tick(main, Vector2.ZERO, Vector2(1, 0))
	for frame in 19: tick(main, Vector2.ZERO, Vector2(1, 0))
	check(main.seek_feedback.target_ms == 70000 and host.revisions.is_empty(), "One second hold adds the initial step and three stable repeats without decoding")
	video.control.observe(35000, 300000)
	check(main.seek_feedback.origin_ms == 30000 and main.seek_feedback.snapshot().delta_ms == 40000, "Continuing playback cannot drift the preview origin")
	tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.size() == 1 and video.control.target_ms == 70000, "Long hold commits its final target once")
	main._on_stick_seek_presented(video.control.sequence - 1, 1000)
	check(main.seek_feedback.phase == "waiting", "An old request cannot complete the current preview")
	host.acknowledge = false; present(main, host, 68000)
	check(main.seek_feedback.phase == "waiting", "A frame rejected by the presentation bridge cannot confirm a seek")
	host.acknowledge = true; present(main, host, 68000)
	check(main.seek_feedback.phase == "done" and main.seek_feedback.target_ms == 68000 and video.control.observed_position_ms == 68000, "Acknowledged first source frame confirms actual keyframe time")
	main._update_seek_feedback(0.125)
	check(overlay.visible and is_equal_approx(float(main.seek_feedback.snapshot().alpha), 0.5), "Confirmed frame fades rather than vanishing immediately")
	main._update_seek_feedback(0.13)
	check(not overlay.visible and main.seek_feedback.snapshot().is_empty(), "Successful seek completely removes passive HUD")
	reset(main, host); video.requested_play = false
	tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	present(main, host, 39000)
	check(not video.requested_play and overlay.visible, "Paused seeking stays paused and retains the short-readability window")
	main._update_seek_feedback(0.1)
	check(is_equal_approx(float(main.seek_feedback.snapshot().alpha), 1.0), "Fast completion remains legible for the minimum display time")
	main._update_seek_feedback(1.0)
	check(not overlay.visible, "Short seek eventually fades")
	reset(main, host); host.revision_id = 8
	tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	check(video.media.session_id == 8 and main.seek_feedback.phase == "waiting", "Decoder replacement session retains the owning seek request")
	present(main, host, 39000)
	check(main.seek_feedback.phase == "done", "New-session first frame confirms the same seek")
	reset(main, host)
	tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	tick(main, Vector2.ZERO, Vector2(1, 0))
	var old_request: int = video.control.sequence
	video.media.begin(8); main._update_seek_feedback(0)
	check(main.seek_feedback.phase == "preview" and main.seek_feedback.target_ms == 50000, "Earlier decoder replacement cannot cancel a newer unsubmitted gesture")
	main._on_stick_seek_presented(old_request, 39000)
	check(main.seek_feedback.phase == "preview", "Older presented frame cannot complete a newer preview")
	tick(main, Vector2.ZERO, Vector2.ZERO)
	check(video.control.target_ms == 50000 and video.control.sequence == old_request + 1, "New gesture commits independently of earlier decoder replacement")
	reset(main, host)
	tick(main, Vector2.ZERO, Vector2(1, 0), 5.0)
	check(main.seek_feedback.target_ms == 40000 and host.revisions.is_empty(), "One stalled frame cannot accumulate an uncontrolled jump")
	for boundary in [[5000, -1, 0], [295000, 1, 299999]]:
		reset(main, host, boundary[0])
		for frame in 30: tick(main, Vector2(boundary[1], 0), Vector2.ZERO)
		check(main.seek_feedback.target_ms == boundary[2] and main.seek_feedback.snapshot().delta_ms == boundary[2] - boundary[0], "Clamped limits and displayed offset use actual bounds")
		check(host.revisions.is_empty(), "Holding at a boundary cannot repeatedly seek")
	reset(main, host, 0)
	tick(main, Vector2(-1, 0), Vector2.ZERO); tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.is_empty() and not overlay.visible, "A zero-change boundary release does not rebuffer")
	reset(main, host); main._show_player_menu()
	tick(main, Vector2.ZERO, Vector2(1, 0))
	check(not overlay.visible and menu._elapsed.text == "00:40" and menu._seek_origin.visible and menu._status.text.contains("+00:10"), "Visible transport reuses timeline, original marker and concise offset")
	check(menu._duration.text == "05:00" and host.revisions.is_empty(), "Transport retains total duration without decoding during preview")
	var refreshes := menu.value_refreshes
	tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2(1, 0))
	check(menu.value_refreshes == refreshes, "Unchanged held target does not repaint the transport every XR frame")
	menu.dismiss(); overlay.refresh()
	check(overlay.visible, "Dismissing transport transfers the same preview to passive HUD")
	main._show_player_menu(); overlay.refresh()
	check(not overlay.visible, "Opening transport removes duplicate HUD")
	for capture in ["_seek_hand", "_volume_hand", "_depth_hand", "_adjust_hand"]:
		reset(main, host); main._show_player_menu(); tick(main, Vector2.ZERO, Vector2(1, 0))
		menu.set(capture, "left_hand"); tick(main, Vector2.ZERO, Vector2(1, 0)); menu.set(capture, "")
		tick(main, Vector2.ZERO, Vector2.ZERO)
		check(main.seek_feedback.phase.is_empty() and host.revisions.is_empty(), "Pointer capture cancels an uncommitted preview: " + capture)
	for popup in ["_subtitle_open", "_mode_open"]:
		reset(main, host); main._show_player_menu(); tick(main, Vector2.ZERO, Vector2(1, 0))
		menu.set(popup, true); tick(main, Vector2.ZERO, Vector2(1, 0)); menu.set(popup, false)
		tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
		check(host.revisions.is_empty() and main.seek_feedback.phase.is_empty(), "Popup cancels preview and still requires recenter: " + popup)
	reset(main, host); tick(main, Vector2.ZERO, Vector2(1, 0))
	main.display.preview = false; main.display.session_state = "session_visible"
	tick(main, Vector2.ZERO, Vector2(1, 0)); main.display.preview = true
	tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.is_empty() and main.seek_feedback.phase.is_empty(), "Focus loss cancels rather than commits")
	reset(main, host); tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2(NAN, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.is_empty() and main.seek_feedback.phase.is_empty(), "Invalid axes cannot submit a preview")
	reset(main, host); tick(main, Vector2(1, 0), Vector2(-1, 0))
	check(main.seek_feedback.owner == "left_hand" and main.seek_feedback.target_ms == 50000, "Two simultaneous hands deterministically keep the first preview owner")
	tick(main, Vector2.ZERO, Vector2(-1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.size() == 1 and host.revisions[0][1] == 50000, "Other-hand release cannot send a second jump")
	for input in ["stick_right", "stick_up"]:
		reset(main, host)
		check(main.controller_bindings.assign("forward10", Bindings.bind("left_hand", input), false, true).ok, "Custom seek axis can be assigned")
		var stick := Vector2.RIGHT if input == "stick_right" else Vector2(0, 1)
		for frame in 10: tick(main, stick, Vector2.ZERO)
		check(main.seek_feedback.target_ms == 50000 and host.revisions.is_empty(), "Remapped seeks share deferred repeat semantics: " + input)
		tick(main, Vector2.ZERO, Vector2.ZERO)
		check(host.revisions.size() == 1 and host.revisions[0][1] == 50000, "Custom seek axis submits once on release")
	for cleanup in ["closed", "failed", "source", "external_seek", "photo"]:
		reset(main, host); tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
		match cleanup:
			"closed", "failed": video.media.state = cleanup
			"source": video.local_uri = "https://fixture/other.mp4"
			"external_seek": video.control.seek_absolute(5000)
			"photo": main.photo_active = true
		main._update_seek_feedback(0)
		check(main.seek_feedback.phase.is_empty() and not overlay.visible, "Obsolete feedback clears on " + cleanup)
	reset(main, host)
	video.media.playback.details.seekable = "no"
	tick(main, Vector2.ZERO, Vector2(1, 0)); tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.is_empty() and not overlay.visible, "Non-seekable streams do not show a fake seek bar")
	check(Overlay.placement({}) == Vector3(0, -0.28, -1.2), "Immersive HUD occupies lower current view")
	for anchor in [Vector3(0, -0.6, -2), Vector3(10, -20, -2), Vector3(0, 0, 2), Vector3(INF, 0, -1)]:
		var placed := Overlay.placement({"flat_anchor": anchor})
		check(placed.is_finite() and placed.y >= -0.40001 and placed.y <= -0.19999 and absf(placed.x) <= 0.22001, "Flat/oversized/off-view screen feedback stays visible")
	check(Feedback.time(3723000) == "1:02:03" and Feedback.offset(-70000) == "−01:10", "Hour counters and signed minute-second offsets are concise")
	var library := preload("res://scripts/library_menu.gd").new(); root.add_child(library); library.set_process(false)
	main.recent_menu = library; library.section = library.Section.MEDIA_SERVER
	var browser: RefCounted = library.server_browser
	browser.server = {"id": "stills", "provider": "emby"}; browser.view = "picture"
	browser.detail = {"id": "film", "title": "Stills", "images": [{"id": "film", "image_type": "Backdrop", "image_index": 0}, {"id": "film", "image_type": "Backdrop", "image_index": 1}]}
	library.visible = true; library.refresh(); reset(main, host)
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(main.seek_feedback.phase == "preview" and browser.gallery.selected_image == 0, "Active video seek takes priority over still navigation")
	tick(main, Vector2.ZERO, Vector2.ZERO)
	check(host.revisions.size() == 1 and host.revisions[0][1] == 40000, "Still viewer submits the original playback seek on release")
	reset(main, host); video.media.state = "paused"; video.requested_play = false
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(main.seek_feedback.phase == "preview" and browser.gallery.selected_image == 0, "Pausing a video does not change the stick's owner")
	reset(main, host)
	main.controller_bindings.assign("forward10", Bindings.bind("left_hand", "stick_right"), false, true)
	tick(main, Vector2.RIGHT, Vector2.ZERO)
	check(main.seek_feedback.phase == "preview" and browser.gallery.selected_image == 0, "Custom playback seek also wins over still navigation")
	main.seek_feedback.clear(); main.controller_bindings.restore_all(); main.stick_controls.suspend()
	video.media.state = "closed"; video.local_uri = ""
	tick(main, Vector2.ZERO, Vector2.ZERO); browser.gallery.stick_at = 0
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(browser.gallery.selected_image == 1 and main.seek_feedback.phase.is_empty(), "Without a video session the right stick switches stills")
	browser.gallery.stick_at = 0; tick(main, Vector2.LEFT, Vector2.ZERO)
	check(browser.gallery.selected_image == 0, "Without a video session the left stick also switches stills")
	reset(main, host); library._drag = {"hand": "right_hand"}
	tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(main.seek_feedback.phase.is_empty() and browser.gallery.selected_image == 0, "Pointer capture blocks both competing actions")
	library._drag.clear(); browser.view = "detail"; browser.capabilities = {"artwork": true}; library.refresh()
	tick(main, Vector2.ZERO, Vector2.ZERO); tick(main, Vector2.ZERO, Vector2.RIGHT)
	check(main.seek_feedback.phase.is_empty(), "Ordinary media-library pages retain playback shortcut isolation")
	main.recent_menu = null; library.free()
	video.changed.disconnect(main._on_video_changed); video.seek_presented.disconnect(main._on_stick_seek_presented)
	video._binding.ticket.clear(); video.platform = null
	DirAccess.remove_absolute(main.settings_path)
	camera.free(); menu.free(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Seek feedback checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
