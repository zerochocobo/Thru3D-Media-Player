extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Layout := preload("res://scripts/menu_surface_layout.gd")
const Move := preload("res://scripts/interface_move.gd")
var failures: Array[String] = []
var checks := 0
var state := {"has_video": true, "playing": true, "playback_state": "playing", "source_uri": "file:///layout.mp4",
	"duration_ms": 600000, "position_ms": 50000, "geometry": 0, "volume": 80, "audio_available": true,
	"audio_options": [{"value": -1, "label": "Automatic"}, {"value": 1, "label": "English"}, {"value": 2, "label": "Chinese"}],
	"subtitle_options": [{"id": 1, "title": "Chinese", "codec": "subrip"}], "capabilities_available": true,
	"bookmark_scope": "layout", "bookmark_ready": true, "bookmark_seekable": true,
	"bookmarks": [{"id": "one", "position_ms": 20000}], "playback_speed": 1.0}

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func ray(node: Node3D, point: Vector3 = Vector3.ZERO) -> Array:
	var end := node.to_global(point)
	return [end + node.global_basis.z * 0.4, -node.global_basis.z]
func faces(node: Node3D, point: Vector3, eye: Vector3) -> bool:
	return node.global_basis.z.normalized().dot((eye - node.to_global(point)).normalized()) > 0.99999

func pointer_surfaces(menu: Node3D, name: String) -> void:
	var panels: Array = [menu._backdrop]
	for node in menu._decorations:
		if node is MeshInstance3D and node.material_override is ShaderMaterial and node.material_override.render_priority in [10, 30]: panels.append(node)
	for panel in panels:
		if not panel.is_visible_in_tree(): continue
		# A point just inside the middle of the side edge avoids rounded corners.
		var point := Vector3(panel.mesh.size.x / 2 - 0.004, 0, 0)
		var pointer := ray(panel, point)
		var hit: Dictionary = menu.pointer_hit(pointer[0], pointer[1])
		check(not hit.is_empty() and float(hit.distance) <= 0.4001, name + " stops at visible panel or nearer control")
		menu.update_pointer("right_hand", pointer[0], pointer[1], true)
		check(menu._pointers.right_hand.dot.visible, name + " keeps the dot at panel edge")

func upper_check(menu: Node3D, surface: Node3D, eye: Vector3, name: String) -> void:
	var rect: Rect2 = surface.get_meta("menu_surface_bounds")
	var centre := Vector3(rect.get_center().x, rect.get_center().y, 0)
	var base := menu.to_global(menu.panel_centre())
	check(faces(surface, centre, eye), name + " faces the eye at its own centre")
	check(absf(base.distance_to(eye) - surface.to_global(centre).distance_to(eye)) < 0.0001, name + " shares the transport's radius")
	var top := menu.to_global(Vector3(0, menu._bar_bounds().end.y, 0)) - eye
	var bottom := surface.to_global(Vector3(centre.x, rect.position.y, 0)) - eye
	check(top.normalized().cross(bottom.normalized()).dot(menu.global_basis.x) > 0.01, name + " leaves an angular gap above floating actions")
	check(menu.global_basis.z.angle_to(surface.global_basis.z) > 0.1, name + " has a separate inclination")

func run() -> void:
	for following in [false, true]:
		for pitch in [0.0, 0.6, -0.8, -1.4]:
			var head := Transform3D(Basis.from_euler(Vector3(pitch, 0.4, 0.2)), Vector3(0.2, 1.7, -0.3))
			var menu := Player.new(); root.add_child(menu); menu.set_process(false)
			var live := {"head": head}
			menu.layout_head_provider = func(): return live.head
			menu.state_provider = func(): return state
			var frame := Move.menu_head(head, following)
			menu.global_transform = frame * Transform3D(Basis.IDENTITY, Vector3(0, -0.45, -1.4))
			var centre := menu.to_global(menu.panel_centre())
			menu.set_layout_viewer(head, following); menu.toggle()
			check(menu.to_global(menu.panel_centre()).is_equal_approx(centre) and faces(menu, menu.panel_centre(), head.origin), "Default transport keeps its centre and faces the viewer")
			check(absf(menu.global_basis.x.dot(head.basis.y if following else Vector3.UP)) < 0.00001, "Roll follows the selected reference frame")
			var bar := menu.global_transform
			for mode in ["settings", "settings-alpha", "screen", "color_grade", "stereo_view", "modes", "subtitles", "audio", "narration", "bookmarks", "error"]:
				state.narration_available = mode == "narration"
				state.narration_enabled = true; state.narration_resolved_language = "zh"; state.narration_voice = "Yuewen"
				state.narration_sources = [{"value": -1, "label": "Follow current subtitles"}, {"value": 1, "label": "Chinese"}, {"value": 2, "label": "English"}]
				menu._reset_navigation(); state.erase("error")
				state.stereo = mode == "stereo_view"
				state.geometry = 1 if mode == "settings-alpha" else 0
				match mode:
					"settings", "settings-alpha": menu.section = 1
					"screen", "color_grade", "stereo_view": menu._adjustment = mode
					"modes": menu._mode_open = true
					"subtitles": menu._subtitle_open = true
					"audio": menu._audio_open = true; menu._audio_source = str(state.source_uri); menu.choices.opened = "audio_track"
					"narration": menu._audio_open = true; menu._audio_source = str(state.source_uri)
					"bookmarks": menu.bookmarks.opened = true
					"error": state.error = "Network unavailable"; menu._failure_open = true
				menu.refresh()
				pointer_surfaces(menu, mode)
				check(menu._popup_surfaces.size() == 1, mode + " has one complete surface")
				if menu._popup_surfaces.is_empty(): continue
				var surface: Node3D = menu._popup_surfaces[0]
				upper_check(menu, surface, head.origin, mode)
				check(menu.global_transform.is_equal_approx(bar), "Opening " + mode + " keeps the transport still")
				for item in menu._buttons:
					if not item.enabled or not surface.is_ancestor_of(item.node): continue
					var pointer := ray(item.node)
					check(int(menu.ray_hit(pointer[0], pointer[1]).get("target", -999)) == item.target, mode + " ray reaches target " + str(item.target))
				# An unrelated head turn and normal value refresh cannot move visible controls.
				var stable := surface.global_transform
				menu.refresh_values()
				check(menu._popup_surfaces[0].global_transform.is_equal_approx(stable), mode + " remains stable through refresh")
			menu._reset_navigation(); state.erase("error"); state.stereo = false; menu.section = 1; menu.refresh()
			var slider := button(menu, 453)
			var pointer := ray(slider.node)
			var changes: Array = []
			menu.adjustment_requested.connect(func(key, value): changes.append([key, value]))
			check(menu.press_pointer("right_hand", pointer[0], pointer[1], true), "Angled speed slider captures")
			var surface := menu._input_surface(453)
			var target := surface.to_global(Vector3(menu.SLIDER_LEFT + menu.SLIDER_WIDTH, slider.node.position.y, 0))
			menu.update_pointer("right_hand", target + surface.global_basis.z * 0.4, -surface.global_basis.z, true)
			check(changes.any(func(item): return item[0] == "playback_speed" and is_equal_approx(item[1], 3.0)), "Drag uses the angled surface and reaches the endpoint")
			menu.release_pointer("right_hand", pointer[0], pointer[1], true)
			# Release-owned choices and bookmarks must not mistake an oblique stationary ray for a drag.
			var events: Array = []
			menu.setting_requested.connect(func(key, value): events.append([key, value]))
			for id in menu.choices.targets:
				if menu.choices.targets[id].get("key", "") != "show_fps": continue
				var item := button(menu, id)
				var origin := head.origin + Vector3(0.1, 0, 0)
				var direction: Vector3 = (item.node.global_position - origin).normalized()
				menu.press_pointer("left_hand", origin, direction, true)
				menu.update_pointer("left_hand", origin, direction, true)
				check(not menu.choices.capture.get("moved", true), "Stationary angled choice stays a click")
				menu.release_pointer("left_hand", origin, direction, true)
				check(events.any(func(item): return item[0] == "show_fps"), "Angled choice commits on release")
				break
			menu._reset_navigation(); menu.bookmarks.opened = true; menu.refresh()
			var bookmark := button(menu, menu.BookmarkMenu.ROW)
			var origin := head.origin
			var direction: Vector3 = (bookmark.node.global_position - origin).normalized()
			var bookmarks: Array = []
			menu.bookmark_requested.connect(func(operation, id, scope): bookmarks.append([operation, id, scope]))
			menu.press_pointer("left_hand", origin, direction, true); menu.update_pointer("left_hand", origin, direction, true)
			check(not menu.bookmarks.capture.get("moved", true), "Stationary angled bookmark stays a click")
			menu.release_pointer("left_hand", origin, direction, true)
			check(bookmarks.has(["seek", "one", "layout"]), "Angled bookmark activates on release")
			# Tooltip follows the popup plane and survives a page rebuild.
			menu._tips[menu.BookmarkMenu.CLOSE] = "Close bookmarks"
			pointer = ray(button(menu, menu.BookmarkMenu.CLOSE).node)
			menu.update_pointer("right_hand", pointer[0], pointer[1], true)
			check(menu._tooltip.visible and menu._tooltip.global_basis.is_equal_approx(menu._popup_surfaces[0].global_basis), "Tooltip shares its popup's plane")
			menu.refresh(); check(is_instance_valid(menu._tooltip) and not menu._tooltip.visible, "Refreshing a popup safely retires its tooltip")
			var library := Library.new(); root.add_child(library); library.set_process(false)
			menu._reset_navigation(); menu.refresh(); menu.expanded_library = library; library.reparent(menu, false)
			for compact in [true, false, true]:
				library.playback_expanded = not compact; library.set_compact(compact); library.visible = true; library.refresh()
				pointer_surfaces(library, "library compact=" + str(compact))
				var edge := ray(library._backdrop, Vector3(library._backdrop.mesh.size.x / 2 - 0.004, 0, 0))
				check(menu.pointer_hit(edge[0], edge[1]).get("library", false), "Expanded library background owns pointer routing")
				menu.update_pointer("left_hand", edge[0], edge[1], true)
				check(library._pointers.left_hand.dot.visible and not menu._pointers.left_hand.line.visible, "Only expanded library draws the background pointer")
				upper_check(menu, library, head.origin, "library compact=" + str(compact))
				check(menu.global_transform.is_equal_approx(bar), "Expanding/collapsing the library keeps the transport still")
			# Drag and depth changes update both surfaces around the current head, without scaling.
			var move := Move.new(); var follow := preload("res://scripts/view_follow.gd").new(); follow.set_enabled(following)
			var hand := Transform3D(Basis.IDENTITY, head.origin + Vector3(0, 0, -0.4))
			move.begin("left_hand", "grip_click", hand, [{"node": menu, "kind": "menu", "key": "menu", "pose": menu.global_transform}], menu.to_global(menu.panel_centre()), head, following)
			move.adjust_distance(Vector2.ZERO, 0.1); move.adjust_distance(Vector2(0, 1), 0.1)
			hand.origin += Vector3(0.1, 0.05, 0)
			check(move.update(hand, head, follow) and faces(menu, menu.panel_centre(), head.origin), "Drag/depth retains viewer-facing transport")
			upper_check(menu, library, head.origin, "dragged library")
			check(menu.scale.is_equal_approx(Vector3.ONE) and library.scale.is_equal_approx(Vector3.ONE), "Spherical movement preserves physical size")
			library.visible = false; menu._reset_navigation(); menu.refresh()
			var moved_head := head; moved_head.origin += Vector3(0.12, 0.05, 0.08); live.head = moved_head
			var fixed_bar := menu.global_transform
			menu.section = 1; menu.refresh()
			upper_check(menu, menu._popup_surfaces[0], moved_head.origin, "new popup after head translation")
			check(menu.global_transform.is_equal_approx(fixed_bar), "New popup uses the current head without shifting the transport")
			var stable_popup: Transform3D = menu._popup_surfaces[0].global_transform
			live.head = Transform3D(Basis.from_euler(Vector3(0.3, 0.8, -0.2)), moved_head.origin + Vector3(0.2, 0.1, 0))
			menu.refresh_values(); menu.refresh()
			check(menu.global_transform.is_equal_approx(fixed_bar) and menu._popup_surfaces[0].global_transform.is_equal_approx(stable_popup), "Head motion and ordinary redraws do not chase the viewer")
			menu.free()
	for failure in failures: push_error(failure)
	print("Spherical menu layout: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
