extends Node
## Atmosphere themes for the whole player (docs/ATMOSPHERE_THEMES_PLAN_20261116_CN.md). Reads what
## is on screen each frame and decides whether the particles show, which flat picture they keep
## clear of, and whether the theme's recording may be heard.
signal changed
const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const Field := preload("res://scripts/atmosphere/atmosphere_field.gd")
const Sound := preload("res://scripts/atmosphere/atmosphere_sound.gd")
const Memory := preload("res://scripts/atmosphere/atmosphere_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const XrFloor := preload("res://scripts/xr_floor.gd")
const SECTION := "atmosphere"
var app: Node
var field := Field.new()
var sound := Sound.new()
var memory := Memory.new("user://atmosphere")
## Videos and the library; pictures have their own default, and folders their own choice.
var theme_global := ""
var theme_photo := ""
var amount := Catalog.DEFAULT_AMOUNT
var sound_on := true
var last := {}
var _folder_key := []
var _folder_value: Variant = null

func setup(owner: Node) -> void:
	app = owner
	var settings: ConfigFile = app.settings
	theme_global = Catalog.clean(settings.get_value(SECTION, "theme", ""))
	theme_photo = Catalog.clean(settings.get_value(SECTION, "photo_theme", ""))
	amount = Catalog.clean_amount(settings.get_value(SECTION, "amount", Catalog.DEFAULT_AMOUNT))
	sound_on = settings.get_value(SECTION, "sound", true) == true
	memory.load_saved()

func _ready() -> void:
	field.name = "AtmosphereField"; add_child(field); add_child(sound)

## What to present for a description of the screen. Kept free of nodes so it can be tested.
static func decide(state: Dictionary) -> Dictionary:
	var picture: bool = state.get("photo", false)
	# A puzzle takes the place of the picture or film it was made from.
	var puzzle: bool = state.get("puzzle", false)
	var film: bool = state.get("video", false) and not picture and not puzzle
	var theme: String = state.get("theme_global", "")
	if picture:
		var folder: Variant = state.get("folder_theme")
		theme = str(folder) if folder is String else str(state.get("theme_photo", ""))
	# An immersive film fills the whole view. The cinema, the beach and imported 3D scenes take
	# the theme like any other background: their walls hide what falls behind them.
	var shown: bool = not theme.is_empty() and (picture or not film or state.get("video_flat", true))
	var keep := ""
	# A flat puzzle's board is kept clear like a picture; a spherical one is all around.
	if shown and puzzle: keep = "puzzle" if state.get("puzzle_flat", false) else ""
	elif shown and picture and state.get("photo_flat", false): keep = "photo"
	elif shown and film: keep = "video"
	var audible: bool = shown and state.get("sound_on", true) and not film and state.get("focused", true) \
		and not state.get("music", false) and not state.get("speaking", false)
	return {"theme": theme if shown else "", "shown": shown, "keep": keep, "audible": audible}

func _photo_uri() -> String:
	return str(app.photo.local_uri) if app.photo_active and app.photo else ""

## The open picture's folder choice, or null. Asked every frame, so the answer is kept until
## the picture, the store or the privacy choice changes.
func _folder_theme() -> Variant:
	var key := [_photo_uri(), memory.sequence, memory.dirty, Privacy.file_settings]
	if key == _folder_key: return _folder_value
	_folder_key = key; _folder_value = null
	var folder := Memory.folder_of(_photo_uri())
	if not folder.is_empty():
		var saved := memory.lookup(folder)
		if saved.has("theme"): _folder_value = str(saved.theme)
	return _folder_value

func _state() -> Dictionary:
	var photo_uri := _photo_uri()
	var video: Node = app.video
	var audio: Node = app.background_audio
	return {"photo": not photo_uri.is_empty(), "photo_flat": app.photo != null and app.photo.geometry == 0 and not app.photo.gallery.overview(),
		"video": video != null and video.has_active_presentation(), "video_flat": video != null and video.geometry == 0,
		"puzzle": _puzzle() != null, "puzzle_flat": _puzzle() != null and not _puzzle().spherical,
		"music": audio != null and not audio.blocked(),
		"speaking": app.photo_active and app.photo != null and app.photo.comic.speech_state == "speaking",
		"focused": app._input_focused() and not app._background_app_paused,
		"sound_on": sound_on, "theme_global": theme_global, "theme_photo": theme_photo, "folder_theme": _folder_theme()}

## The puzzle being played, or null.
func _puzzle() -> Node3D:
	var game: Node = app.puzzle_game
	return game.session if game != null and game.active and is_instance_valid(game.session) else null

func _screen(keep: String) -> Dictionary:
	if keep == "puzzle":
		var session := _puzzle()
		if session == null or not is_instance_valid(session.board) or not session.board.is_visible_in_tree(): return {}
		return {"transform": session.board.global_transform, "size": session.frame_size()}
	var surface: Node = app.photo if keep == "photo" else app.video if keep == "video" else null
	if surface == null or not is_instance_valid(surface.panel) or not surface.panel.is_visible_in_tree(): return {}
	return {"transform": surface.panel.global_transform, "size": surface._flat.size}

func _process(delta: float) -> void:
	if app == null: return
	last = decide(_state())
	# Fade the old theme out before the next one is built.
	if field.theme != last.theme and not last.theme.is_empty() and field.opacity <= 0.0:
		field.build(last.theme, amount, app.low_end_gpu)
	elif field.amount != amount and not field.theme.is_empty() and field.opacity <= 0.0:
		field.build(field.theme, amount, app.low_end_gpu)
	var current: bool = last.shown and field.theme == last.theme and field.amount == amount
	field.step(delta, current, app.xr_camera.global_position, app.xr_origin.global_position.y - XrFloor.offset(), _screen(last.keep), _over_layers())
	if last.theme.is_empty() and field.opacity <= 0.0 and not field.theme.is_empty(): field.clear()
	# The recording is only loaded once it may be heard, and changes after the old one has faded.
	if last.audible and sound.theme != last.theme and sound.level <= 0.0: sound.select(str(last.theme))
	sound.step(delta, last.audible and sound.theme == last.theme)

## The particles are seen against something beneath the eye buffer: the camera picture, or an
## immersive picture on its compositor layer. A flat picture's layer is kept clear instead.
func _over_layers() -> bool:
	if app.display.preview: return false
	if app.display.applied_passthrough: return true
	var photo: Node = app.photo
	return app.photo_active and photo != null and last.keep == "" and _puzzle() == null and is_instance_valid(photo._hole) and photo._hole.visible

## For the scene menu: `scope` is its "global" or "image" tab.
func snapshot(scope: String) -> Dictionary:
	var folder: Variant = _folder_theme() if scope == "image" else null
	var theme := theme_global if scope != "image" else str(folder) if folder is String else theme_photo
	return {"theme": theme, "amount": amount, "sound": sound_on,
		"folder": scope == "image" and _folder_scope()}

## A picture is open in a folder whose choice may be kept.
func _folder_scope() -> bool:
	var uri := _photo_uri()
	var folder := Memory.folder_of(uri)
	return not folder.is_empty() and Privacy.persist_allowed(uri) and Privacy.settings_allowed(folder)

func command(scope: String, key: String, value: Variant) -> void:
	var settings: ConfigFile = app.settings
	match key:
		"theme":
			var id := Catalog.clean(value)
			if scope == "image" and _folder_scope():
				if memory.remember(Memory.folder_of(_photo_uri()), {"theme": id}): memory.save()
			elif scope == "image":
				theme_photo = id; settings.set_value(SECTION, "photo_theme", id)
			else:
				theme_global = id; settings.set_value(SECTION, "theme", id)
		"amount":
			amount = Catalog.clean_amount(value); settings.set_value(SECTION, "amount", amount)
		"sound":
			sound_on = value == true; settings.set_value(SECTION, "sound", sound_on)
		_: return
	settings.save(app.settings_path)
	DiagnosticLog.record("atmosphere", {"scope": scope, "key": key, "value": value})
	changed.emit()
