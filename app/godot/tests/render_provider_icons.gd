extends SceneTree
## Desktop visual fixture for the provider marks; never connects to a real account.
const Menu := preload("res://scripts/library_menu.gd")
const Icons := preload("res://scripts/menu_icons.gd")
const CloudFixture := preload("res://tests/test_cloud_accounts.gd")
const Servers := ["emby", "jellyfin", "plex", "stash", "xbvr"]
const Clouds := ["115_open", "baidu", "aliyun_open", "quark_open", "onedrive", "webdav"]
var output := ""
var viewport: SubViewport
var menu: Node

func _initialize() -> void: call_deferred("_run")

func capture(name: String) -> void:
	menu._reset_navigation(); menu.refresh()
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))

func _run() -> void:
	output = OS.get_environment("THRU3D_PROVIDER_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	# Inspect the actual imported pixels, including alpha and rasterized edge padding.
	for key in Icons.Providers.TEXTURES:
		var mark: Image = Icons.texture(key, 128).get_image()
		var used := mark.get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0 or used.position.x < 4 or used.position.y < 4 or used.end.x > 124 or used.end.y > 124:
			push_error("Empty/clipped provider mark: " + key); quit(1); return
		for y in mark.get_height():
			for x in mark.get_width():
				var pixel := mark.get_pixel(x, y)
				if pixel.a > 0.01 and (absf(pixel.r - pixel.g) > 0.01 or absf(pixel.g - pixel.b) > 0.01):
					push_error("Non-monochrome provider mark: " + key); quit(1); return
	print("11 imported provider marks: transparent padding and monochrome pixels verified")
	preload("res://scripts/i18n.gd").use("zh")
	viewport = SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	menu = Menu.new(); camera.add_child(menu)
	var platform := CloudFixture.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu.section = Menu.Section.MEDIA_SERVER
	menu.account_panel.open("server"); menu.account_panel.paused = true
	await capture("add-servers")
	menu.account_panel.close(); menu.server_browser.view = "servers"; menu.server_browser.servers = []
	for provider in Servers:
		menu.server_browser.servers.append({"id": provider, "name": menu.account_panel.provider_name(provider) + " · 客厅 NAS", "provider": provider})
	await capture("server-list")
	for provider in Servers:
		menu.server_browser.server = {"id": provider, "name": menu.account_panel.provider_name(provider) + " · 客厅 NAS", "provider": provider}
		menu.server_browser.view = "home"; menu.server_browser.entries = []
		await capture("server-" + provider)
	menu.section = Menu.Section.CLOUD
	menu.account_panel.open("cloud"); menu.account_panel.paused = true
	await capture("add-clouds")
	menu.account_panel.close(); menu._cloud_stack = []; menu._cloud_entries = []
	for provider in Clouds:
		menu._cloud_entries.append({"id": "/" + provider, "title": menu.account_panel.provider_name(provider) + " · 家庭影音", "provider": provider, "container": true})
	menu.view_mode = "grid"; await capture("cloud-list")
	menu.view_mode = "list"; await capture("cloud-list-rows")
	for account in menu._cloud_entries.duplicate(true):
		menu._cloud_stack = [account]; menu._cloud_entries = []
		await capture("cloud-" + str(account.provider))
	menu._cloud_stack = [{"id": "/115", "title": "115 · 家庭影音", "provider": "115_open"}, {"id": "/115/videos", "title": "视频"}, {"id": "/115/videos/travel", "title": "旅行"}]
	await capture("cloud-nested")
	menu.compact = true; await capture("cloud-compact")
	menu.compact = false; menu.section = Menu.Section.MEDIA_SERVER
	menu.server_browser.server = {"id": "jellyfin", "name": "Jellyfin · 客厅 NAS", "provider": "jellyfin"}
	menu.server_browser.view = "home"; menu.compact = true
	await capture("server-compact")
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	print("provider icon previews rendered")
	quit()
