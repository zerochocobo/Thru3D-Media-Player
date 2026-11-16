extends Node
## The field recording that goes with an atmosphere theme: one looping voice that fades in and
## out. It never plays over a film or the viewer's own music; the controller decides when.
const Catalog := preload("res://scripts/atmosphere/atmosphere_catalog.gd")
const BUS := "Thru3D Atmosphere"
const FADE_SECONDS := 1.5
var theme := ""
var level := 0.0
var player: AudioStreamPlayer
var _gain_db := Catalog.SOUND_GAIN_DB
var _filter: AudioEffectLowPassFilter
var _owns_bus := false

func _ready() -> void:
	if AudioServer.get_bus_index(BUS) < 0:
		AudioServer.add_bus(); var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, BUS)
		# Underwater muffles the recording; other themes leave the filter off.
		_filter = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(index, _filter); AudioServer.set_bus_effect_enabled(index, 0, false)
		_owns_bus = true
	player = AudioStreamPlayer.new(); player.name = "AtmosphereSound"; player.bus = BUS
	add_child(player)

func _exit_tree() -> void:
	var index := AudioServer.get_bus_index(BUS)
	if _owns_bus and index >= 0: AudioServer.remove_bus(index)

func select(id: String) -> void:
	id = Catalog.clean(id)
	if id == theme: return
	theme = id; level = 0.0
	player.stop(); player.stream = null
	var row := Catalog.theme(theme)
	var path := Catalog.sound_path(row) if not row.is_empty() else ""
	if path.is_empty(): return
	# A private copy: the music player's own instance of the recording must not start looping.
	var stream := ResourceLoader.load(path, "AudioStream", ResourceLoader.CACHE_MODE_IGNORE) as AudioStream
	if stream is AudioStreamOggVorbis: stream.loop = true
	player.stream = stream
	_gain_db = float(row.get("gain_db", Catalog.SOUND_GAIN_DB))
	var index := AudioServer.get_bus_index(BUS)
	if index >= 0 and AudioServer.get_bus_effect_count(index) > 0:
		var cutoff := float(row.get("lowpass_hz", 0.0))
		var effect := AudioServer.get_bus_effect(index, 0) as AudioEffectLowPassFilter
		if effect and cutoff > 0.0: effect.cutoff_hz = cutoff
		AudioServer.set_bus_effect_enabled(index, 0, cutoff > 0.0)

func step(delta: float, audible: bool) -> void:
	if player.stream == null: return
	level = move_toward(level, 1.0 if audible else 0.0, delta / FADE_SECONDS)
	if level <= 0.0:
		# Silent means stopped: nothing is decoded while a film plays.
		if player.playing: player.stream_paused = true
		return
	player.volume_db = _gain_db + linear_to_db(level * level)
	if not player.playing: player.play()
	player.stream_paused = false
