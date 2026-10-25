extends SceneTree
const Fonts := preload("res://scripts/ray_menu.gd")
const Fixtures := preload("res://tests/test_comic_translation.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/comic-translation-20261025/ui")
func _initialize() -> void: run.call_deferred()
func capture(viewport: SubViewport, name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join(name + ".png"))
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400,1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.position.z = 1.1; camera.fov = 47; viewport.add_child(camera)
	for language in ["zh","zh_Hant","ja","en"]:
		preload("res://scripts/i18n.gd").use(language)
		var menu := preload("res://scripts/photo_menu.gd").new()
		var state := {"comic_supported":true,"has_image":true,"translation_enabled":true,"translation_target":"zh-Hans","translation_source":"auto","translation_state":"ready","translation_count":8,"translation_total":8,"title":"Comic","count":24,"index":3}
		menu.state_provider = func(): return state
		viewport.add_child(menu); menu.visible = true; menu.set_process(false)
		menu.refresh(); await capture(viewport,language + "-bar")
		menu._activate(menu.PHOTO_TRANSLATION); await capture(viewport,language + "-panel")
		menu.choices.opened = "translation_target"; menu.refresh(); await capture(viewport,language + "-target")
		menu.choices.offset = 14; menu.refresh(); await capture(viewport,language + "-target-tail")
		menu._activate(menu.PHOTO_COMIC_VOICE); await capture(viewport,language + "-translated-reading")
		menu.free()
	preload("res://scripts/i18n.gd").use("zh")
	var source := SubViewport.new(); source.size = Vector2i(1000,750); source.transparent_bg = false
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	source.disable_3d = true; root.add_child(source)
	var svg := '<svg width="1000" height="750" xmlns="http://www.w3.org/2000/svg"><rect width="1000" height="750" fill="#f3efe4"/><path d="M400 0V750" stroke="#182536" stroke-width="14"/><rect x="20" y="20" width="360" height="710" rx="5" fill="#d5e1e7" stroke="#182536" stroke-width="5"/><rect x="425" y="20" width="550" height="365" fill="#bdd1d7" stroke="#182536" stroke-width="5"/><rect x="425" y="410" width="550" height="320" fill="#d2c6b8" stroke="#182536" stroke-width="5"/><path d="M30 700L180 400 370 700M440 370L720 40 965 365M435 710L700 440 965 710" stroke="#6f919b" stroke-width="10" fill="none"/><ellipse cx="200" cy="160" rx="154" ry="104" fill="white" stroke="#182536" stroke-width="5"/><ellipse cx="660" cy="185" rx="194" ry="119" fill="white" stroke="#182536" stroke-width="5"/><ellipse cx="740" cy="555" rx="184" ry="109" fill="white" stroke="#182536" stroke-width="5"/></svg>'
	var image := Image.new(); image.load_svg_from_string(svg)
	var background := TextureRect.new(); background.texture = ImageTexture.create_from_image(image); source.add_child(background)
	var texts := ["待って！\nまだ話は\n終わってない！", "ここで逃げたら、\nあいつに顔向け\nできない。", "ドキドキ……\nなんで急に顔が\n熱くなるの？"]
	var positions := [Vector2(105,85),Vector2(540,110),Vector2(620,485)]
	for i in texts.size():
		var label := Label.new(); label.text = texts[i]; label.position = positions[i]; label.size = Vector2(240,150)
		label.add_theme_font_override("font", Fonts.ui_font()); label.add_theme_font_size_override("font_size",25)
		label.add_theme_color_override("font_color",Color.BLACK); source.add_child(label)
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var picture := source.get_texture().get_image()
	picture.save_png(output.path_join("fixture-source.png"))
	var photo := preload("res://scripts/photo_display.gd").new(); viewport.add_child(photo); photo.set_process(false)
	photo._size = Vector2(1000,750); photo.screen_curve = 0; photo._texture = ImageTexture.create_from_image(picture)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo._apply_geometry(); photo.panel.position = Vector3.ZERO; photo.panel.visible = true
	camera.position.z = 3.1; camera.fov = 50
	var blocks := [ellipse_block(0,texts[0],Rect2i(50,60,300,200)),ellipse_block(0,texts[1],Rect2i(70,70,380,230)),ellipse_block(1,texts[2],Rect2i(160,450,360,210))]
	var entries := []; var cache := {}; var translations := ["等等！话还没说完！", "如果现在逃跑，\n就无法面对那家伙。", "心跳……为什么\n脸突然变得这么热？"]
	for i in 3:
		entries.append({"key":str(i),"block":blocks[i],"size":Vector2(400 if i==0 else 600,750),"region":Rect2(0 if i==0 else .4,0,.4 if i==0 else .6,1)})
		cache[str(i)] = {"text":translations[i],"provider":"Bing"}
	await capture(viewport,"spread-original")
	var overlay := preload("res://scripts/comic_translation_overlay.gd").new(photo)
	overlay.update(entries,cache,1.0); await capture(viewport,"spread-translated")
	photo.screen_curve = .6; photo._shape_screen(); overlay.sync(true); await capture(viewport,"spread-curved")
	var foreground := preload("res://scripts/photo_menu.gd").new()
	foreground.state_provider = func(): return {"comic_supported":true,"has_image":true,"translation_enabled":true,"translation_state":"ready","translation_count":3,"translation_total":3}
	viewport.add_child(foreground); foreground.set_process(false); foreground.position = Vector3(0,0,1.4)
	foreground.visible = true; foreground._activate(foreground.PHOTO_TRANSLATION)
	await capture(viewport,"spread-menu")
	foreground.free()
	overlay.visible(false); await capture(viewport,"spread-original-restored")
	print("Translation overlay: %d of 3 bubbles rendered" % overlay.shown)
	overlay.close(); photo.free(); source.free(); viewport.free(); quit()
func ellipse_block(id: int, text: String, rect: Rect2i) -> Dictionary:
	var rows := []
	for y in rect.size.y:
		var t := (y + .5 - rect.size.y / 2.0) / (rect.size.y / 2.0)
		var span := sqrt(maxf(0,1-t*t)) * rect.size.x / 2.0
		rows.append([ceili(rect.position.x + rect.size.x/2.0-span),floori(rect.position.x + rect.size.x/2.0+span)])
	return {"id":id,"text":text,"language":"ja","eligible":true,"hit_rect":[rect.position.x,rect.position.y,rect.end.x,rect.end.y],"hit_rows":rows}
