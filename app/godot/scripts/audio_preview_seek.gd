extends RefCounted
## Compact audition timeline; dragging never selects a file or scrolls its row.
const TARGET := -5410
const WIDTH := 0.57
var host: Node3D
var capture := {}
var view := {}
var _poll := 0.0

func _init(menu: Node3D) -> void: host = menu

func clear_layout() -> void:
	cancel(str(capture.get("hand", "")))
	view.clear()

func draw(row: Node3D, state: Dictionary) -> void:
	for child in row.get_children():
		if child is Label3D and child.position.y < -0.01: child.visible = false
	var title: Label3D = row.get_child(0)
	title.position.y = 0.023
	var enabled := bool(state.get("audio_preview_seekable", false)) and not bool(state.get("audio_preview_loading", false))
	host._text_button(TARGET, "", Vector2.ZERO, Vector2(WIDTH, 0.036), enabled)
	host._buttons.back()["hover_disabled"] = true
	var node: Node3D = host._buttons.back().node
	node.reparent(row, false); node.position = Vector3(-0.10, -0.024, 0.016)
	var track: MeshInstance3D = host._quad(Vector2(WIDTH, 0.006), Vector3.ZERO, host.MUTED * Color(1, 1, 1, 0.35), 13)
	node.add_child(track)
	var fill: MeshInstance3D = host._quad(Vector2(WIDTH, 0.006), Vector3(0, 0, 0.001), host.ACCENT if enabled else host.MUTED, 14)
	node.add_child(fill)
	var thumb: MeshInstance3D = host._quad(Vector2.ONE * 0.016, Vector3(0, 0, 0.002), host.ACCENT, 15)
	node.add_child(thumb); thumb.visible = enabled
	var elapsed: Label3D = host._label("", Vector3(-0.48, -0.024, 0.020), 13, row)
	elapsed.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; elapsed.modulate = host.MUTED; elapsed.render_priority = 14
	var total: Label3D = host._label("", Vector3(0.30, -0.024, 0.020), 13, row)
	total.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; total.modulate = host.MUTED; total.render_priority = 14
	view = {"node": node, "fill": fill, "thumb": thumb, "elapsed": elapsed, "total": total, "enabled": enabled,
		"token": int(state.get("audio_preview_token", 0)), "uri": str(state.get("audio_preview_uri", "")), "duration": float(state.get("audio_preview_duration", 0))}
	show_position(float(state.get("audio_preview_position", 0)))

func show_position(seconds: float) -> void:
	if view.is_empty() or not is_instance_valid(view.node): return
	var duration: float = view.duration
	var ratio := clampf(seconds / duration, 0, 1) if duration > 0 else 0.0
	view.fill.visible = ratio > 0
	view.fill.scale.x = maxf(0.001, ratio); view.fill.position.x = (ratio - 1) * WIDTH * 0.5
	view.thumb.position.x = (ratio - 0.5) * WIDTH
	view.elapsed.text = time_text(seconds)
	view.total.text = time_text(duration) if duration > 0 else "–:––"

func time_text(seconds: float) -> String:
	return "%d:%02d" % [int(maxf(0, seconds)) / 60, int(maxf(0, seconds)) % 60]

func _state() -> Dictionary:
	return host.background_audio_provider.call() if host.background_audio_provider.is_valid() else {}

func _owned(state: Dictionary, owner: Dictionary) -> bool:
	return host.visible and host.audio_import_mode and int(state.get("audio_preview_token", 0)) == int(owner.token) \
		and str(state.get("audio_preview_uri", "")) == str(owner.uri) and int(owner.token) > 0

func poll(delta: float) -> void:
	if view.is_empty(): return
	_poll += delta
	if _poll < 0.1: return
	_poll = 0
	var state := _state()
	if not capture.is_empty() and (not _owned(state, capture) or capture.scope != host._audio_preview_scope_key()): cancel(str(capture.hand))
	if capture.is_empty() and _owned(state, view):
		# Availability can arrive after the initial ready notification, without reloading directory data.
		if bool(state.get("audio_preview_seekable", false)) != bool(view.enabled) or float(state.get("audio_preview_duration", 0)) != float(view.duration):
			host._audio_preview_dirty = true
		else: show_position(float(state.get("audio_preview_position", 0)))

func press(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not capture.is_empty(): return true
	if not tracked or host.has_pointer_capture() or view.is_empty(): return false
	var hit: Dictionary = host.ray_hit(origin, direction)
	if int(hit.get("target", 0)) != TARGET: return false
	var state := _state()
	if not _owned(state, view) or not bool(state.get("audio_preview_seekable", false)): return true
	capture = {"hand": hand, "token": view.token, "uri": view.uri, "duration": view.duration,
		"scope": host._audio_preview_scope_key(), "plane": host.control_plane(TARGET), "position": 0.0}
	host._fling = 0.0
	host.audio_preview_scrubbed.emit(int(capture.token), -1.0, true)
	move(hand, origin, direction, tracked)
	return true

func move(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.get("hand", "") != hand or capture.is_empty(): return
	var point: Variant = host.project_pointer(origin, direction, capture.plane) if tracked else null
	if point == null: cancel(hand); return
	capture.position = clampf((float(point.x) + WIDTH * 0.5) / WIDTH, 0, 1) * float(capture.duration)
	show_position(float(capture.position))

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if capture.is_empty() or capture.hand != hand: return false
	move(hand, origin, direction, tracked)
	if capture.is_empty(): return true
	var previous := capture; capture = {}
	var valid: bool = _owned(_state(), previous) and previous.scope == host._audio_preview_scope_key()
	host.audio_preview_scrubbed.emit(int(previous.token), float(previous.position) if valid else -1.0, false)
	return true

func cancel(hand: String) -> void:
	if capture.is_empty() or capture.hand != hand: return
	var token := int(capture.token); capture = {}
	host.audio_preview_scrubbed.emit(token, -1.0, false)
