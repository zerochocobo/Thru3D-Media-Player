extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_directory_filter.gd")
const Favorites := preload("res://scripts/favorite_store.gd")
const Player := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func shot(view: SubViewport, name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://../../build/output/library-filter-subtitles/previews")
	DirAccess.make_dir_recursive_absolute(path)
	if view.get_texture().get_image().save_png(path.path_join(name + ".png")) != OK: failures.append(name)

func run() -> void:
	var view := SubViewport.new(); view.size=Vector2i(1800,1250); view.own_world_3d=true; view.render_target_update_mode=SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.position.y=0.30; camera.fov=70; view.add_child(camera)
	var menu := Library.new(); menu.platform=Fixture.Host.new(); camera.add_child(menu); menu.set_process(false)
	var files: Array = [{"id":"share/film","title":"电影合集","container":true}]
	for i in 15: files.append({"uri":"smb://saved/share/%d.mp4" % i,"title":"电影 %02d — Mountains and sea.mp4" % i,"kind":"video","size":123456789})
	var store := Favorites.new("user://directory-filter-preview"); store.entries.clear(); menu.collections.store=store
	for spec in [["folder","folder://preview","电影合集"],["video","file:///film.mp4","Mountains.mp4"],["image","file:///photo.jpg","Sea.jpg"]]:
		store.entries[store.key_for(spec[1])] = {"uri":spec[1],"kind":spec[0],"title":spec[2],"added":1}
	for language in ["zh","zh_Hant","en","ja"]:
		I18n.use(language)
		for compact in [false,true]:
			for mode in ["list","grid"]:
				menu.subtitle_filter.reset(); menu.section=Library.Section.SMB; menu._smb_server="saved"; menu._smb_path="share"; menu._smb_entries=files
				menu.compact=compact; menu.view_mode=mode; menu.visible=true; menu.refresh(); menu._activate(menu.SubtitleFilter.OPEN); menu.subtitle_filter.apply("电影")
				await shot(view, "%s-%s-%s" % [language,"compact" if compact else "full",mode])
		menu.subtitle_filter.reset(); menu.compact=false; menu.section=Library.Section.RECENT; menu.collections.home_tab=1; menu.media_filter=0; menu.refresh()
		await shot(view, language + "-favorites-all")
		menu._activate(Library.FILTER_BASE+3); await shot(view,language+"-favorites-folders")
		menu.section=Library.Section.SETTINGS; menu.tab=Library.VIDEO_TAB; menu._video_settings_expanded={"subtitles":true}; menu._subtitle_settings_expanded="appearance"
		menu.settings_provider=func():return {"subtitle_transparency":50.0}
		menu.refresh()
		var row_index := menu.rows.find(menu.rows.filter(func(row):return row.get("key")=="subtitle_transparency")[0]); menu._set_scroll(maxi(0,row_index-2))
		await shot(view,language+"-subtitle-settings")
	menu.visible=false
	var player := Player.new(); view.add_child(player); player.position=Vector3(0,-0.43,-1.85); player.set_process(false)
	var state := {"has_video":true,"source_uri":"file:///film.mp4","subtitle_track":1,"subtitle_options":[{"id":1,"codec":"subrip","title":"中文字幕"}],"subtitle_transparency":50.0}
	player.state_provider=func():return state
	for language in ["zh","en","ja"]:
		I18n.use(language); player.dismiss(); player.toggle(); player._activate(110)
		await shot(view,language+"-subtitle-player")
	view.queue_free(); await process_frame
	print("Directory/subtitle UI previews failures=%d" % failures.size())
	quit(0 if failures.is_empty() else 1)
