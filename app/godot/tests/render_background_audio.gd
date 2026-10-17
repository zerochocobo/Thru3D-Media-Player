extends SceneTree
const Menu := preload("res://scripts/music_menu.gd")
const Audio := preload("res://scripts/background_audio.gd")
const Home := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
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
	var audio := Audio.new()
	audio.current = "yunhai"; audio.queue.assign(["yunhai", "xingmian"]); audio.queue_name = "Calm"; audio.queue_source = "calm"; audio._loaded = "yunhai"; audio.paused = false; audio._resume_position = 47.5
	var wav := AudioStreamWAV.new(); wav.mix_rate = 8000; wav.format = AudioStreamWAV.FORMAT_8_BITS; var data := PackedByteArray(); data.resize(240 * 8000); wav.data = data
	audio.player = AudioStreamPlayer.new(); audio.player.stream = wav
	audio.library.imports.append({"id": "import_fixture", "label": "My quiet evening - a very long imported soundtrack name.mp3", "path": "fixture.mp3", "bytes": 100})
	audio.library.playlists.append({"id": "list_fixture", "label": "My panorama", "tracks": ["ocean_waves", "yunhai", "import_fixture"], "builtin": false})
	audio.library.playlists.append({"id": "list_empty", "label": "Quiet evening", "tracks": [], "builtin": false})
	var base_playlists: Array = audio.library.playlists.duplicate(true)
	var menu := Menu.new(); menu.audio = audio; camera.add_child(menu); menu.position = Vector3(0, 0, -2.4)
	var home := Home.new(); camera.add_child(home); home.position = Vector3(0, 0, -2.4); home.background_audio_provider = audio.snapshot
	var photo := Photo.new(); camera.add_child(photo); photo.position = Vector3(0, 0, -2.4); photo.state_provider = func(): return {"has_image": true, "count": 12, "index": 0, "title": "Mountain panorama.jpg", "audio_active": true}
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for view in ["mini", "volume", "sequence", "single", "shuffle", "empty", "long-title", "lists", "tracks", "environment", "all", "queue", "custom", "add", "track-actions", "delete", "name", "importing", "home", "photo", "import-browser", "organize", "add-source", "playlist-actions", "delete-playlist", "choose-list", "empty-playlist", "custom-source", "deleted-source", "library-source", "paged-playlists", "long-source", "environment-end", "ambience-source"]:
			menu.dismiss(); home.dismiss(); photo.dismiss(); audio.importer.busy = false
			audio.library.playlists.assign(base_playlists.duplicate(true))
			var shown: Node3D = menu
			if view in ["home", "import-browser"]:
				shown = home; home.visible = true
				if view == "import-browser":
					home.section = Home.Section.LOCAL; home._local_entries = [{"title": "Sea and wind.wav", "uri": "file:///sea.wav", "kind": "audio"}, {"title": "My ambient music.mp3", "uri": "file:///song.mp3", "kind": "audio"}]; home.begin_audio_import(); home._choose(home.rows[0])
				home.refresh()
			elif view == "photo": shown = photo; photo.visible = true; photo.refresh()
			else:
				menu.open(true); menu.compact = view in ["mini", "volume", "sequence", "single", "shuffle", "empty", "long-title", "custom-source", "deleted-source", "library-source", "long-source", "ambience-source"]
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
				menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-" + view + ".png")) == OK, "Save " + language + view)
			if shown == menu:
				for label in menu.find_children("*", "Label3D", true, false):
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
	menu.free(); home.free(); photo.free(); audio.player.free(); audio.player = null; audio.importer.free(); audio.free(); viewport.free(); wav = null
	await process_frame
	for failure in failures: push_error(failure)
	print("Background audio render: %d checks, %d failures" % [checks, failures.size()]); quit(0 if failures.is_empty() else 1)
