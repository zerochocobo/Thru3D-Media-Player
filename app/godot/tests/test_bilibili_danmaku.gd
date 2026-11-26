extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
var failures: Array[String] = []

class Host extends RefCounted:
	var calls: Array = []
	var reply := ""
	func bilibili_danmaku_fetch(cid: String, segment: int) -> int:
		calls.append(["fetch", cid, segment])
		return calls.size()
	func bilibili_danmaku_cancel(id: int) -> void:
		calls.append(["cancel", id])
	func bilibili_danmaku_poll(_id: int) -> String:
		var packet := reply
		reply = ""
		return packet

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func _button(menu: Node3D, target: int) -> Dictionary:
	for button: Dictionary in menu._buttons:
		if int(button.target) == target: return button
	return {}

func _comment(space: Node3D, time: int) -> Dictionary:
	for comment: Dictionary in space._comments:
		if int(comment.time) == time: return comment
	return {}

func _run() -> void:
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	var camera := Camera3D.new()
	root.add_child(camera)
	video.view_camera = camera
	video.panel.global_position = Vector3(0, 0, -4)
	video.panel.show()
	video.media.begin(10)
	video.media.state = "playing"
	video.media.frame_counter = 1
	video.control.observe(10000, 780000)
	var host := Host.new()
	var state := ConfigFile.new()
	var danmaku := video.danmaku
	danmaku.restore(state)
	danmaku.open(host, "32020171134")
	danmaku.tick(video, 0.1)
	_check(host.calls.is_empty() and danmaku.cover_screen, "Default off and allowed to cover the picture")
	danmaku.setting("danmaku_enabled", true, state)
	danmaku.tick(video, 0.1)
	_check(host.calls == [["fetch", "32020171134", 1]], "First segment uses the captured CID")
	var items := [[10500, "测试弹幕", 0xff2040]]
	for index in range(120):
		items.append([10600 + index * 80, "第%d条弹幕" % index, 0xffffff])
	host.reply = JSON.stringify({"items": items})
	video.control.observe(10120, 780000)
	var space: Node3D = danmaku._space
	for frame in range(8): danmaku.tick(video, 0.0)
	var red: Dictionary = _comment(space, 10500)
	_check(not red.is_empty(), "A comment is laid out before its timestamp")
	if not red.is_empty():
		var front: Vector3 = space.point(red, 10500)
		_check(absf(front.x) < 0.01 and front.z < -2.5, "Ring crosses the picture direction at the comment time")
		_check(space.point(red, 500).z > 2.5 and space.point(red, 20500).z > 2.5, "Ring enters and leaves behind the viewer")
		_check(space.point(red, 9000).x > 0.4 and space.point(red, 12000).x < -0.4, "Ring moves right to left through the front")
		var tint: Color = red.label.modulate
		_check(tint.r8 == 255 and tint.g8 == 32 and tint.b8 == 64, "Ring uses original source RGB")
		_check(red.label.font_size * red.label.pixel_size > 0.1, "Text is large enough to read at ring distance")
	# Confirmed positions arrive four times a second. Motion must stay continuous.
	var steps: Array[float] = []
	var shown: int = space.active_count()
	var lowest: int = shown
	for frame in range(216):
		if frame % 18 == 17: video.control.observe(10120 + (frame + 1) * 1000 / 72, 780000)
		var before: float = danmaku._clock
		danmaku.tick(video, 1.0 / 72.0)
		steps.append(danmaku._clock - before)
		lowest = mini(lowest, space.active_count())
	_check(steps.all(func(step: float) -> bool: return step > 1000.0 / 72.0 * 0.75 and step < 1000.0 / 72.0 * 1.25),
		"Clock advances smoothly between sparse position reports: %s" % str(steps.slice(0, 24)))
	_check(lowest >= shown, "Sparse position reports never clear the comments")
	_check(space.active_count() > 30, "Medium density keeps far more than a dozen comments: %d" % space.active_count())
	var visible := 0
	for comment: Dictionary in space._comments: visible += int(comment.label.visible)
	_check(visible > 0, "Comments in front of the viewer are visible")
	var depths: Array = space._comments.map(func(comment: Dictionary) -> float: return comment.depth)
	_check(depths.max() - depths.min() > 1.2, "Ring comments spread over distinct distances: %s" % str(depths.slice(0, 8)))
	var elevations: Array = space._comments.map(func(comment: Dictionary) -> float: return space._lanes[comment.lane])
	var above: int = elevations.filter(func(angle: float) -> bool: return angle > 0.0).size()
	_check(elevations.min() < -0.5 and elevations.max() > 0.5 and above > elevations.size() / 4 and above < elevations.size() * 3 / 4,
		"Ring comments spread evenly above and below eye level: %s" % str(elevations.slice(0, 12)))
	_check(absf(space._lanes[0] + space._lanes[-1]) < 0.01 and space._lanes[-1] > 0.6 and space._lanes[-1] < PI / 4,
		"Ring lanes span about 45 degrees either way: %s" % str(space._lanes))
	# A scene or seat change moves the viewer far away. The comments come along at once.
	camera.global_position = Vector3(20, 0, 3)
	video.panel.global_position = Vector3(20, 0, -1)
	danmaku.tick(video, 1.0 / 72.0)
	var near: Array = space._comments.filter(func(comment: Dictionary) -> bool:
		var offset: Vector3 = space.point(comment, danmaku._clock) - camera.global_position
		return Vector2(offset.x, offset.z).length() < 5.2)
	_check(space.active_count() > 30 and near.size() == space.active_count(), "Comments follow a scene change: %d of %d" % [near.size(), space.active_count()])
	# Walking eases the anchor after the viewer instead of jumping.
	camera.global_position = Vector3(20.6, 0, 3)
	danmaku.tick(video, 1.0 / 72.0)
	var eased: float = space._origin.x
	for frame in range(144): danmaku.tick(video, 1.0 / 72.0)
	_check(eased > 20.0 and eased < 20.1 and absf(space._origin.x - 20.6) < 0.03,
		"A short walk eases the anchor: %.3f then %.3f" % [eased, space._origin.x])
	camera.global_position = Vector3.ZERO
	video.panel.global_position = Vector3(0, 0, -4)
	video.control.observe(int(danmaku._clock), 780000)
	danmaku.tick(video, 1.0 / 72.0)
	danmaku.setting("danmaku_transparency", 40, state)
	_check(space._comments.all(func(comment: Dictionary) -> bool: return is_equal_approx(comment.label.modulate.a, 0.6) and is_equal_approx(comment.label.outline_modulate.a, 0.6)),
		"Transparency fades text and outline of shown comments")
	danmaku.setting("danmaku_transparency", 0, state)
	var media_clock: float = danmaku._clock
	video.requested_play = false
	danmaku.tick(video, 0.3)
	_check(is_equal_approx(media_clock, danmaku._clock), "Pause freezes motion")
	video.requested_play = true
	var started := Time.get_ticks_usec()
	for frame in range(100): space.advance(danmaku._clock + frame * 14.0)
	print("Danmaku advance with %d comments: %.1f us/frame" % [space.active_count(), (Time.get_ticks_usec() - started) / 100.0])

	danmaku.setting("danmaku_mode", 1, state)
	_check(space.active_count() == 0, "Changing mode lays the comments out again")
	for frame in range(8): danmaku.tick(video, 0.0)
	var drop: Dictionary = {} if space._comments.is_empty() else space._comments[0]
	_check(not drop.is_empty() and "\n" in drop.label.text, "Rain stacks characters vertically")
	if not drop.is_empty():
		var middle: Vector3 = space.point(drop, drop.time)
		var later: Vector3 = space.point(drop, drop.time + 2000)
		_check(absf(middle.y) < 0.01 and later.y < middle.y and is_equal_approx(middle.x, later.x), "Rain crosses eye level at the comment time")
		_check(drop.end - drop.start > 11000, "Rain stays on view for longer than eleven seconds")
	var columns := {}
	for comment: Dictionary in space._comments: columns[comment.lane] = snappedf(comment.depth, 0.1)
	_check(columns.size() > 4 and columns.values().max() - columns.values().min() > 1.5,
		"Rain columns fall at layered distances: %s" % str(columns))
	var azimuths: Array = space._comments.map(func(comment: Dictionary) -> float: return space._lanes[comment.lane])
	_check(azimuths.min() < -0.6 and azimuths.max() > 0.6 and space._lanes[-1] < PI / 3,
		"Rain falls across about 120 degrees, not only in the middle: %s" % str(azimuths.slice(0, 12)))
	var burst := []
	for index in range(80): burst.append([40000 + index * 12, "密集%d" % index, 0xffffff])
	var counts: Array[int] = []
	for level in [0, 2]:
		danmaku.setting("danmaku_density", level, state)
		space.prepare(video, null, true)
		space.clear()
		for item in burst: space.feed(item, 40000)
		counts.append(space.active_count())
	_check(counts[1] > counts[0] * 2, "High density holds more of a burst than low: %s" % str(counts))
	danmaku.setting("danmaku_density", 1, state)
	danmaku.setting("danmaku_mode", 0, state)

	video.control.observe(345000, 780000)
	danmaku.tick(video, 0.1)
	_check(host.calls.back() == ["fetch", "32020171134", 2], "Long playback prefetches only the next segment")
	video.control.seek_absolute(735000)
	danmaku.tick(video, 0.1)
	_check(host.calls.back() == ["fetch", "32020171134", 3] and space.active_count() == 0, "Seek clears text and prioritizes the destination")
	_check(host.calls[-2][0] == "cancel", "A seek outside the prefetch window cancels the unused request")
	danmaku.open(host, "241222583")
	_check(host.calls.back()[0] == "cancel", "Changing CID cancels the old segment")
	_check(space.active_count() == 0 and danmaku._segments.is_empty(), "Changing CID clears old comments")

	_check(space.prepare(video, null, false), "Screen guard available")
	var middle_lane := 0
	for lane in range(space._lanes.size()):
		if absf(space._lanes[lane]) < absf(space._lanes[middle_lane]): middle_lane = lane
	var crossing := {"time": 10000, "lane": middle_lane, "half": 0.4, "depth": 3.4, "size": 1.0}
	_check(space._blocked(space.point(crossing, 10000), space._axis(crossing, 10000), space._thickness()),
		"With covering off, text passing the picture is hidden there")
	_check(not space._blocked(space.point(crossing, 15000), space._axis(crossing, 15000), space._thickness()),
		"The same lane shows the text again beside the picture")
	_check(space._blocked(Vector3(0, 0, -3.4), Vector3.ZERO, 0.05), "Both-eye screen guard protects the picture center")
	_check(not space._blocked(Vector3(0, 0, 3.4), Vector3.ZERO, 0.05), "Back of the ring remains available")
	_check(space.prepare(video, null, true) and not space._blocked(Vector3(0, 0, -3.4), Vector3.ZERO, 0.05), "Cover setting permits text over the picture")
	for rain in [0, 1]:
		space.configure(rain, 1, true)
		_check(space.prepare(video, null, false), "Outside-only layout available")
		var picture: Vector2 = space._picture_range(video.panel.global_transform, video.panel.get_aabb())
		var inside: Array = Array(space._lanes).filter(func(angle: float) -> bool: return angle > picture.x - 0.04 and angle < picture.y + 0.04)
		_check(inside.is_empty() and space._lanes.size() > 4 and picture.y - picture.x > 0.2,
			"Outside-only lanes (mode %d) skip the picture %s: %s" % [rain, str(picture), str(space._lanes)])
		_check(space.prepare(video, null, true) and Array(space._lanes).any(func(angle: float) -> bool: return absf(angle) < 0.1),
			"Allowing cover brings the picture lanes back (mode %d)" % rain)
	space.configure(1, 1)
	_check(space.prepare(video, null, true) and space.feed([10000, "黑色弹幕", 0], 10200), "Rain can show black comments")
	if space.active_count() > 0:
		var label: Label3D = space._comments[0].label
		_check(label.modulate == Color.BLACK and label.outline_modulate == Color.WHITE, "Black fill is preserved with a legible contrasting outline")
	video.geometry = Geometry.Geometry.EQUIRECT_360
	_check(not space.prepare(video, null, false), "360 video protects all directions with cover disabled")

	video.geometry = Geometry.Geometry.FLAT
	var menu := Menu.new()
	root.add_child(menu)
	var ui := {"has_video": true, "danmaku": danmaku.snapshot()}
	menu.state_provider = func(): return ui
	menu.refresh()
	for capture in [false, true]:
		for disc in [false, true]:
			ui.capture = {"available": capture}
			ui.disc_menu_available = disc
			menu.refresh()
			var picture_pos: Vector2 = _button(menu, Menu.PICTURE_OPEN).rect.get_center()
			var danmaku_pos: Vector2 = _button(menu, Menu.DANMAKU_OPEN).rect.get_center()
			_check(danmaku_pos.is_equal_approx(picture_pos + Vector2(0.14, 0)),
				"Danmaku follows picture control with capture=%s, disc=%s" % [capture, disc])
	var icon := _button(menu, Menu.DANMAKU_OPEN)
	_check(icon.node.get_child(0).text == "弹" and icon.base_color == menu.ACCENT, "Enabled button renders the 弹 glyph and active color")
	menu.setting_requested.connect(func(key: String, value: Variant):
		danmaku.setting(key, value, state)
		ui.danmaku = danmaku.snapshot())
	menu._activate(Menu.DANMAKU_OPEN)
	menu._activate(Menu.DANMAKU_MODE + 1)
	menu._activate(Menu.DANMAKU_DENSITY + 2)
	_check(_button(menu, Menu.DANMAKU_OUTSIDE).is_empty(), "Outside-only stays hidden while covering is allowed")
	menu._activate(Menu.DANMAKU_COVER)
	_check(danmaku.mode == 1 and danmaku.density == 2 and not danmaku.cover_screen, "Popup controls update mode, density and cover")
	_check(not _button(menu, Menu.DANMAKU_OUTSIDE).is_empty() and not danmaku.outside_only, "Outside-only appears, off, once covering is off")
	menu._activate(Menu.DANMAKU_OUTSIDE)
	_check(danmaku.outside_only and danmaku._space._outside and menu._danmaku_open, "Outside-only toggles and the popup stays open")
	_check(menu._adjust_rows.has(Menu.DANMAKU_TRANSPARENCY), "Popup has a transparency slider")
	menu.show()
	menu.adjustment_requested.connect(func(key: String, value: Variant):
		danmaku.setting(key, value, state)
		ui.danmaku_transparency = danmaku.transparency)
	menu._adjust_target = Menu.DANMAKU_TRANSPARENCY
	var row: Dictionary = menu._adjust_rows[Menu.DANMAKU_TRANSPARENCY]
	menu._set_adjustment_at(row.left + row.width)
	_check(is_equal_approx(danmaku.transparency, 90.0) and menu._adjust_rows[Menu.DANMAKU_TRANSPARENCY].label.text == "90%", "Slider end sets 90%% transparency: %s" % menu._adjust_rows[Menu.DANMAKU_TRANSPARENCY].label.text)
	menu._activate(Menu.SLIDER_RESET_BASE + Menu.DANMAKU_TRANSPARENCY)
	_check(is_equal_approx(danmaku.transparency, 0.0) and menu._danmaku_open, "Slider reset makes comments opaque and keeps the popup")
	menu._activate(Menu.DANMAKU_TOGGLE)
	_check(not danmaku.enabled and _button(menu, Menu.DANMAKU_OPEN).base_color != menu.ACCENT, "Toolbar marks the disabled setting")
	ui.danmaku = {"available": false}
	menu.refresh()
	_check(_button(menu, Menu.DANMAKU_OPEN).is_empty() and not menu._danmaku_open, "Sources without danmaku hide the button")
	video.free()
	menu.free()
	camera.free()
	for failure in failures: push_error(failure)
	print("Bilibili danmaku: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
