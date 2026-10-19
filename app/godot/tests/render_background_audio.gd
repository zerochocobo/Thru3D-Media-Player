extends SceneTree
const Menu := preload("res://scripts/music_menu.gd")
const Audio := preload("res://scripts/background_audio.gd")
const Home := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const Video := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
class RenderPlatform extends RefCounted:
	func background_audio_storage() -> String: return JSON.stringify({"used_bytes": 256 * 1024 * 1024, "free_bytes": 78 * 1024 * 1024 * 1024, "total_bytes": 128 * 1024 * 1024 * 1024, "max_file_bytes": 512 * 1024 * 1024})
	func preview_background_audio(_uri: String) -> int: return 1
	func seek_audio_preview(_id: int, _position: float) -> bool: return true
var failures: Array[String] = []
var checks := 0
func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/music-management/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 1300); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 45; viewport.add_child(camera)
	var audio := Audio.new(); audio.importer.platform = RenderPlatform.new()
	audio.current = "yunhai"; audio.queue.assign(["yunhai", "xingmian"]); audio.queue_name = "Calm"; audio.queue_source = "calm"; audio._loaded = "yunhai"; audio.paused = false; audio._resume_position = 47.5
	var wav := AudioStreamWAV.new(); wav.mix_rate = 8000; wav.format = AudioStreamWAV.FORMAT_8_BITS; var data := PackedByteArray(); data.resize(240 * 8000); wav.data = data
	audio.player = AudioStreamPlayer.new(); audio.player.stream = wav
	audio.library.imports.append({"id": "import_fixture", "label": "My quiet evening - a very long imported soundtrack name.mp3", "path": "fixture.mp3", "bytes": 100})
	audio.library.playlists.append({"id": "list_fixture", "label": "My panorama", "tracks": ["ocean_waves", "yunhai", "import_fixture"], "builtin": false})
	audio.library.playlists.append({"id": "list_empty", "label": "Quiet evening", "tracks": [], "builtin": false})
	var base_playlists: Array = audio.library.playlists.duplicate(true)
	var menu := Menu.new(); menu.audio = audio; camera.add_child(menu); menu.position = Vector3(0, 0, -2.4)
	var home := Home.new(); camera.add_child(home); home.position = Vector3(0, 0, -2.4); home.background_audio_provider = audio.snapshot
	var photo := Photo.new(); camera.add_child(photo); photo.position = Vector3(0, 0, -2.4); photo.state_provider = func():
		var state: Dictionary = audio.snapshot(); state.merge({"has_image": true, "count": 12, "index": 0, "title": "Mountain panorama.jpg"}); return state
	var video := Video.new(); camera.add_child(video); video.position = Vector3(0, 0, -2.4); video.state_provider = func():
		var state: Dictionary = audio.snapshot(); state.merge({"has_video": true, "playing": true, "playback_state": "playing", "source_uri": "tutorial.mp4", "title": "Tutorial.mp4", "audio_available": true, "volume": 67, "duration_ms": 600000, "position_ms": 123456}); return state
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for view in ["mini", "volume", "sequence", "single", "shuffle", "empty", "long-title", "lists", "tracks", "environment", "all", "queue", "custom", "add", "track-actions", "delete", "name", "importing", "home", "photo", "import-browser", "organize", "add-source", "playlist-actions", "delete-playlist", "choose-list", "empty-playlist", "custom-source", "deleted-source", "library-source", "paged-playlists", "long-source", "environment-end", "ambience-source", "home-hover", "home-hover-empty", "photo-hover", "photo-hover-paused", "import-preview", "import-preview-loading", "import-preview-stream", "import-preview-drag", "mini-video-on", "lists-video-on", "video-off", "video-on", "video-hover", "video-hover-paused", "settings-mini-off", "settings-mini-on", "settings-full-off", "settings-full-on"]:
			menu.dismiss(); home.dismiss(); photo.dismiss(); video.dismiss(); audio.importer.busy = false
			audio.play_during_video = ("video" in view and view != "video-off") or view in ["settings-mini-on", "settings-full-on"]
			audio._preview_uri = ""; audio._preview_token = 0; audio._preview_loading = false; audio._preview_seekable = false
			audio.paused = view in ["photo-hover-paused", "video-hover-paused"]; audio.current = "" if view == "home-hover-empty" else "yunhai"
			camera.fov = 50 if "hover" in view else 45
			audio.library.playlists.assign(base_playlists.duplicate(true))
			var shown: Node3D = menu
			if view in ["home", "import-browser", "home-hover", "home-hover-empty"] or view.begins_with("import-preview"):
				shown = home; home.visible = true
				if view == "import-browser" or view.begins_with("import-preview"):
					home.section = Home.Section.LOCAL; home._local_entries = [{"title": "Sea and wind.wav", "uri": "file:///sea.wav", "kind": "audio"}, {"title": "My ambient music.mp3", "uri": "file:///song.mp3", "kind": "audio"}]; home.begin_audio_import(); home._choose(home.rows[0])
				if view.begins_with("import-preview"):
					audio._preview_uri = "file:///sea.wav"; audio._preview_token = 1
					audio._preview_loading = view == "import-preview-loading"
					audio._preview_seekable = view in ["import-preview", "import-preview-drag"]
					audio._preview_position = 72 if audio._preview_seekable else 0
					audio._preview_duration = 300 if audio._preview_seekable else 0
				home.refresh()
				if view == "import-preview-drag":
					var rail: Node3D = home.audio_preview_seek.view.node
					home.press_pointer("left_hand", Vector3.ZERO, rail.global_position.normalized(), true)
					home.update_pointer("left_hand", Vector3.ZERO, (rail.global_transform * Vector3(0.1425, 0, 0)).normalized(), true)
				if view in ["home-hover", "home-hover-empty"]: home.music_quick.expanded = true; home.refresh_music_quick_controls()
			elif view in ["photo", "photo-hover", "photo-hover-paused"]:
				shown = photo; photo.visible = true; photo.refresh_values()
				if "hover" in view: photo.music_quick.expanded = true; photo.refresh_music_quick_controls()
			elif view.begins_with("video-"):
				shown = video; video.visible = true; video.refresh()
				if "hover" in view: video.music_quick.expanded = true; video.refresh_music_quick_controls()
			else:
				menu.open(true); menu.compact = view in ["mini", "volume", "sequence", "single", "shuffle", "empty", "long-title", "custom-source", "deleted-source", "library-source", "long-source", "ambience-source"]
				if view == "mini-video-on": menu.compact = true
				audio.queue_source = "calm"; audio.queue_name = "Calm"
				if view == "custom-source": audio.queue_source = "list_fixture"; audio.queue_name = "My panorama"
				if view == "deleted-source": audio.queue_source = "list_deleted"; audio.queue_name = "Previous playlist"
				if view == "library-source": audio.queue_source = ""; audio.queue_name = "Audio library"
				audio.mode = view if view in ["sequence", "single", "shuffle"] else "list"
				audio.current = "" if view == "empty" else ("import_fixture" if view == "long-title" else "yunhai")
				audio.player.stream = null if view == "empty" else wav
				audio._resume_position = 0 if view == "empty" else 47.5; audio.paused = view == "empty"
				audio.queue.assign([] if view == "empty" else ["yunhai", "xingmian"])
				menu._volume_open = view == "volume"; menu.view = "lists"; menu.offset = 0; menu.playlist_id = "calm"; menu.filter = "all"
				if view == "long-source": audio.queue_source = "list_fixture"; audio.library.playlists[0].label = "A very long playlist title for a quiet evening / 長いプレイリスト名 / 很长的自建歌单名称"
				if view == "paged-playlists":
					for i in 10: audio.library.playlists.append({"id": "list_page%d" % i, "label": "Playlist %d" % i, "tracks": [], "builtin": false})
					menu.offset = 6
				if view in ["tracks", "environment", "custom", "add"]:
					menu.view = "add" if view == "add" else "tracks"
					menu.playlist_id = "ambience" if view == "environment" else ("list_fixture" if view in ["custom", "add"] else "calm")
				if view in ["all", "queue"]: menu.view = view
				if view == "environment-end": menu.view = "tracks"; menu.playlist_id = "ambience"; menu.offset = 1
				if view == "ambience-source": audio.queue_source = "ambience"; audio.queue_name = "Ambience"; audio.current = "forest_wind"; audio.queue.assign(["forest_wind"]); audio.mode = "single"
				if view in ["organize", "empty-playlist"]: menu.view = "tracks"; menu.playlist_id = "list_empty" if view == "empty-playlist" else "list_fixture"; menu.editing = view == "organize"
				if view == "add": menu.selected_tracks.assign(["yunhai", "ocean_waves"])
				if view in ["add-source", "playlist-actions", "delete-playlist", "choose-list"]:
					menu.playlist_id = "list_fixture"; menu.target_playlist = "list_fixture"; menu.target_track = "import_fixture" if view == "choose-list" else ""
					menu.modal = {"add-source": "add_source", "playlist-actions": "playlist", "delete-playlist": "confirm_list", "choose-list": "choose_list"}[view]
				if view in ["track-actions", "delete"]: menu.target_track = "import_fixture"; menu.target_playlist = "list_fixture"; menu.modal = "confirm_file" if view == "delete" else "track"
				if view == "name": menu.modal = "name"; menu.name_text = I18n.t("Playlist") + " 2"
				if view == "importing": audio.importer.busy = true; audio.importer.progress = 0.67
				if view.begins_with("settings-"):
					menu.compact = "mini" in view; menu._open_modal("settings")
				menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if shown == menu and menu.modal.is_empty():
				check(menu._storage_labels.is_empty() and not menu.choices.targets.values().any(func(item): return item.get("key", "") == "audio_play_during_video"), "Clean playback footer: " + language + view)
			if view.begins_with("settings-"):
				check(menu._storage_labels.size() == 3 and menu.choices.targets.values().any(func(item): return item.get("key", "") == "audio_play_during_video"), "Settings contains music option and capacity: " + language + view)
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-" + view + ".png")) == OK, "Save " + language + view)
			if view in ["import-preview", "import-preview-drag"]:
				var seek: RefCounted = home.audio_preview_seek
				check(seek.view.elapsed.text in (["3:44", "3:45"] if view == "import-preview-drag" else ["1:12"]) and seek.view.total.text == "5:00", "Preview time labels: " + language + view)
				var rail: Node3D = seek.view.node
				var frame := viewport.get_texture().get_image(); var mint := 0
				var a := camera.unproject_position(rail.global_transform * Vector3(-0.27, 0, 0))
				var b := camera.unproject_position(rail.global_position)
				for x in range(int(a.x), int(b.x)):
					for y in range(int(a.y) - 3, int(a.y) + 4):
						var color := frame.get_pixel(x, y)
						if color.g > color.r + 0.10 and color.g > 0.60: mint += 1
				check(mint > 35, "Audition progress renders above the row: " + language + view)
			if "hover" in view or view.begins_with("import-preview"):
				var target := Home.AUDIO_PREVIEW_BASE if view.begins_with("import-preview") else -5401
				for control in shown._buttons:
					if int(control.target) != target: continue
					var centre: Vector2 = camera.unproject_position(control.node.global_position)
					var frame := viewport.get_texture().get_image(); var mint := 0
					for x in range(int(centre.x) - 14, int(centre.x) + 15):
						for y in range(int(centre.y) - 14, int(centre.y) + 15):
							var color := frame.get_pixel(x, y)
							if color.g > 0.60 and color.r > 0.35 and color.b > 0.45 and color.g > color.r + 0.10: mint += 1
					check(mint > 100, "Transport remains visible above its plate: " + language + view)
			for label in shown.find_children("*", "Label3D", true, false):
				if label.has_meta("music_text_width"):
					check(label.get_aabb().size.x <= float(label.get_meta("music_text_width")) + 0.006, "Rendered text width: " + language + " " + view + " " + label.text + " actual=" + str(label.get_aabb().size.x))
			for control in shown._buttons:
				if not control.enabled: continue
				var direction: Vector3 = control.node.global_position.normalized()
				var hit: Dictionary = shown.ray_hit(Vector3.ZERO, direction)
				check(int(hit.get("target", -999)) == int(control.target), "Ray target " + language + " " + view + " " + str(control.target) + " got " + str(hit.get("target")))
				if control.node.get_child_count() > 0 and control.node.get_child(0) is Label3D:
					var label: Label3D = control.node.get_child(0)
					var width: float = shown.text_width(label.text, int(label.font_size / shown.TEXT_RASTER_SCALE))
					check(width < control.rect.size.x + 0.005, "Button text fits " + language + view + " " + label.text)
	menu.free(); home.free(); photo.free(); video.free(); audio.player.free(); audio.player = null; audio.importer.free(); audio.free(); viewport.free(); wav = null
	await process_frame
	for failure in failures: push_error(failure)
	print("Background audio render: %d checks, %d failures" % [checks, failures.size()]); quit(0 if failures.is_empty() else 1)
