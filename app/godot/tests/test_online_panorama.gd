extends SceneTree
const Menu := preload("res://scripts/photo_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Tiles := preload("res://scripts/panorama_tiles.gd")
const Online := preload("res://scripts/online_panorama_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var urls: Array[String] = []
	var actions: Array[String] = []
	var paused := true
	var report := {}
	var region := {}
	var requests: Array[Vector2i] = []
	var released: Array[int] = []
	var sequence := 0
	var tile_path := ""
	var save_report := {}
	var saves: Array=[]
	var original_views: Array[String] = []
	func panorama_original_view(uri: String) -> void: original_views.append(uri)
	func panorama_save_pictures(uri: String,title: String,sphere: bool) -> bool:
		saves.append([uri,title,sphere]); save_report={"state":"saved","source":uri,"uri":"content://media/1"}; return true
	func panorama_save_status() -> String: return JSON.stringify(save_report)
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass
	func panorama_browse(url: String) -> void: urls.append(url); paused=false
	func panorama_browser_pause(value: bool) -> void: paused=value
	func panorama_browser_action(action: String,_x: float,_y: float,_text: String) -> void: actions.append(action)
	func panorama_browser_status() -> String: return JSON.stringify(report)
	func panorama_browser_frame() -> PackedByteArray: return PackedByteArray()
	func panorama_regions_open(_path: String) -> int: sequence+=1; region={"state":"ready"}; return sequence
	func panorama_regions_close(id: int) -> void: released.append(id)
	func panorama_regions_status(_id: int) -> String: return JSON.stringify(region)
	func panorama_regions_request(_id: int,column: int,row: int) -> bool:
		requests.append(Vector2i(column,row))
		var core:=Tiles.core_rect(Vector2i(20778,10389),Vector2i(column,row))
		var rect:=core.grow(2).intersection(Rect2i(0,0,20778,10389))
		var image:=Image.create(rect.size.x,rect.size.y,false,Image.FORMAT_RGB8)
		image.fill(Color.GREEN); image.save_png(tile_path)
		region={"state":"tile","column":column,"row":row,"path":tile_path,"x":rect.position.x,"y":rect.position.y,"width":rect.size.x,"height":rect.size.y}
		return true

func check(value: bool, message: String) -> void:
	checks+=1
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	I18n.use("zh")
	var host:=Host.new()
	var menu:=Menu.new(); root.add_child(menu); menu.visible=true
	menu.online.platform=host; menu.refresh()
	var entry: Dictionary={}
	for button in menu._buttons:
		if button.target==Menu.PHOTO_ONLINE: entry=button
	check(entry.is_empty(),"Online panorama photo entry is temporarily hidden")
	menu.online.open()
	check(menu._buttons.filter(func(b):return b.target>=Online.BASE+10 and b.target<=Online.BASE+13).size()==4,"Four verified sources")
	menu.online.activate(Online.BASE+3)
	check(menu._buttons.filter(func(b):return b.target>=Online.BASE+10 and b.target<=Online.BASE+13).size()==2,"Chinese interfaces filter")
	menu.online.activate(Online.BASE+12)
	check(host.urls.size()==1 and host.urls[0].contains("uselang=zh"),"Chinese Commons uses localized URL")
	check(menu.online.browsing and not host.paused,"Browser visible and resumed")
	menu.online.activate(Online.BASE+9)
	check(host.actions.back()=="open_image","Visible webpage image can be explicitly handed to the downloader")
	check(preload("res://scripts/image_info.gd").is_image("cloud://provider/sky.TIFF?token=1"),"TIFF photos route to image mode across remote sources")
	var origin:=menu.to_global(Vector3(0,0,1)); var direction:=-menu.global_basis.z
	check(menu.press_pointer("right_hand",origin,direction,true),"Web pointer press captured")
	check(menu.has_pointer_capture() and menu.online.hand=="right_hand","Web drag owns pointer")
	menu.release_pointer("left_hand",origin,direction,true)
	check(menu.online.hand=="right_hand","Other controller cannot release web drag")
	menu.release_pointer("right_hand",menu.to_global(Vector3(3,0,1)),direction,true)
	check(menu.online.hand.is_empty() and host.actions.back()=="cancel","Release outside cancels click")
	host.report={"editing":true,"download":{}}
	menu.online.tick(0.21)
	check(menu._buttons.any(func(b):return b.target==Online.KEY+43),"Web editor shows VR keyboard")
	menu.online.back()
	check(host.actions.back()=="keyboard_close","Back closes keyboard before page")
	host.report={"editing":false,"download":{"state":"ready","uri":"file:///original.jpg","width":20778,"height":10389}}
	var selected: Array=[]
	menu.online_image_requested.connect(func(item,spherical):selected.append([item,spherical]))
	menu.online.tick(0.21)
	check(selected.size()==1 and selected[0][1] and selected[0][0].width==20778,"Download automatically hands original dimensions to 360 playback")
	check(not menu.online.opened and host.paused,"Playback pauses browser")
	menu.online.open(); menu.online.tick(0.21)
	check(selected.size()==1,"Returning to web does not reopen the consumed download")
	menu.dismiss()
	check(host.paused and not menu.online.opened,"Dismiss pauses browser")
	menu.free()
	var library:=Library.new(); root.add_child(library); library.visible=true
	library.media_filter=2; library.refresh()
	check(not library._buttons.any(func(b):return b.target==Library.ONLINE_PANORAMAS),"Online panorama image library entry is temporarily hidden")
	library.media_filter=1; library.refresh()
	check(not library._buttons.any(func(b):return b.target==Library.ONLINE_PANORAMAS),"Video library has no image-only entry")
	library.free()
	# Verify coverage including partial last tiles, seam and both poles.
	var size:=Vector2i(20778,10389); var pixels:=0
	for row in ceili(float(size.y)/Tiles.TILE):
		for column in ceili(float(size.x)/Tiles.TILE):
			var core:=Tiles.core_rect(size,Vector2i(column,row)); pixels+=core.size.x*core.size.y
	check(pixels==size.x*size.y,"Original region grid covers every source pixel once")
	for forward in [Vector3.FORWARD,Vector3.BACK,Vector3.UP,Vector3.DOWN]:
		var cells:=Tiles.priority_cells(size,forward)
		check(not cells.is_empty() and cells.size()<=Tiles.MAX_TILES,"Bounded resident tiles at seam/poles")
		var first:=Tiles.core_rect(size,cells[0])
		check(Tiles.direction((Vector2(first.position)+Vector2(first.size)*0.5)/Vector2(size)).dot(forward)>0.98,"First region follows viewing direction")
	var seam:=Tiles.priority_cells(size,Vector3.BACK)
	check(seam.any(func(c):return c.x==0) and seam.any(func(c):return c.x==20),"Both sides of longitude seam requested")
	var corner:=Tiles.core_rect(size,Vector2i(20,10))
	var mesh:=Tiles.patch_mesh(size,Vector2i(20,10),corner.grow(2).intersection(Rect2i(Vector2i.ZERO,size)))
	var arrays:=mesh.surface_get_arrays(0)
	check(arrays[Mesh.ARRAY_TEX_UV][0].x>0.0 and arrays[Mesh.ARRAY_TEX_UV][-1].x<=1.0,"Partial edge patch samples decoded gutter correctly")
	# Exercise the real asynchronous Godot tile loader and source-switch cancellation.
	host.tile_path=ProjectSettings.globalize_path("user://online-panorama-tile.png")
	var photo:=Photo.new(); photo.history_enabled=false; root.add_child(photo)
	photo.panel.visible=true; photo.set_projection(3)
	photo.panorama_tiles.configure({"region_source":"original.jpg","width":size.x,"height":size.y},host)
	var deadline:=Time.get_ticks_msec()+8000
	while photo.panorama_tiles.tiles.size()<3 and Time.get_ticks_msec()<deadline: await create_timer(.02).timeout
	check(photo.panorama_tiles.tiles.size()>=3,"Original-pixel tiles decode asynchronously")
	check(photo.snapshot().source_size=="20778 × 10389","Player reports original panorama dimensions instead of preview dimensions")
	check(photo.panorama_tiles.details.size()==photo.panorama_tiles.tiles.size(),"Magnifier shares the full-resolution tile cache")
	photo.panorama_tiles.clear()
	check(host.released.has(1) and photo.panorama_tiles.tiles.is_empty() and photo.panorama_tiles.details.is_empty(),"Source close releases native session and all GPU regions")
	photo.panorama_tiles.configure({"region_source":"ordinary.jpg","width":size.x,"height":size.y},host)
	photo.set_projection(0)
	check(not photo.panorama_tiles.active(),"A 2:1 ordinary photo never activates spherical tiles implicitly")
	photo.free(); DirAccess.remove_absolute(host.tile_path)
	# App-level routing must keep a long download open and return to normal controls afterward.
	var main:=Main.new(); main.settings_path="user://online-test-settings.cfg"
	root.add_child(main); main.set_process(false); main.photo.history_enabled=false
	main._show_online_panoramas()
	check(not main.photo_menu.online.opened,"Public online panorama action is temporarily disabled")
	# Retain internal browser coverage while the public entry is unavailable.
	main.photo_active=true; main.player_menu=main.photo_menu
	main._show_player_menu(); main.photo_menu.online.open()
	main._menu_touched_ms=Time.get_ticks_msec()-Main.CONTROLS_HIDE_MS-1000
	main._update_controls_visibility(main.photo_menu)
	check(main.photo_active and main.photo_menu.visible and main.photo_menu.online.opened,"Website/download cannot auto-hide like playback controls")
	var fixture:=ProjectSettings.globalize_path("user://online-route.jpg")
	var image:=Image.create(64,32,false,Image.FORMAT_RGB8); image.fill(Color.BLUE); image.save_jpg(fixture)
	main.photo_menu.online.hide()
	main._open_online_panorama({"uri":"file://"+fixture,"title":"Online test","source":"https://example.org/original"},true)
	var until:=Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(not main.photo.loading and main.photo.error.is_empty() and main.photo.geometry==3,"App hands downloaded image to real photo loading and 360 projection")
	check(main.player_menu==main.photo_menu and not main.photo_menu.online.opened and main.photo.source_location.online_source=="https://example.org/original","Playback returns normal photo controls with source attribution")
	main.photo.platform=host
	check(main.photo.can_save_pictures(),"Downloaded original exposes Pictures action")
	main.photo_menu.refresh()
	check(main.photo_menu._buttons.any(func(b):return b.target==Menu.PHOTO_SAVE),"Viewing controls offer save original")
	main.photo_menu._activate(Menu.PHOTO_SAVE)
	check(host.saves.size()==1 and host.saves[0][0]==main.photo.local_uri and host.saves[0][2],"Save uses original URI and full-sphere intent")
	check(not main.photo.save_to_pictures(),"Saved image cannot be duplicated by repeated trigger")
	main.photo.close_image(false, "file:///private/incoming.jpg")
	check(host.original_views.back()=="file:///private/incoming.jpg","Photo switch transfers temporary original ownership")
	main.photo.close_image()
	check(host.original_views.back()=="","Photo close releases temporary original")
	main.photo.source_location={}
	check(not main.photo.can_save_pictures(),"Internal export never offers an unrelated local file")
	main.free(); DirAccess.remove_absolute(fixture)
	print("Online panorama regression: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
