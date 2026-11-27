extends Node3D
## Original mono sources stay in room coordinates; the XR listener provides the stereo image.
const SCENES := ["weightless","watcher","collapse","aurora","moths","frost","meteors","backward","ivy","lanterns"]
const CASTS := ["fire_cast","ice_bloom","forked_thunder","bronze_bell","rose_bloom","star_ink","page_vortex","gate_open","koi_call","moon_cast"]
const EXTRAS := ["fire_air","fire_impact","gate_link","koi_swim","moon_return","window_open","bat_wing","scarab_wing","raven_wing","repelled","escaped","ward_win","ward_lost","attune","coffer","ingredient","brew_fail","pour"]
const VOICES := 8
var clips := {}
var sources: Array[AudioStreamPlayer3D] = []
var tokens := PackedInt32Array()
var levels := PackedFloat32Array()
var priorities := PackedInt32Array()
var serial := 0
var duck_db := 0.

func _ready() -> void:
	for key in SCENES+CASTS+EXTRAS:
		clips[key] = load("res://environments/magic_cottage/sounds/%s.wav"%key)
	tokens.resize(VOICES)
	levels.resize(VOICES)
	priorities.resize(VOICES)
	for i in VOICES:
		var player := AudioStreamPlayer3D.new()
		player.unit_size=4.
		player.max_distance=18.
		add_child(player)
		sources.append(player)

func cue(key: String,p: Vector3,db := -6.,pitch := 1.,priority := 1) -> int:
	var slot := 0
	for i in sources.size():
		if not sources[i].playing:
			slot=i
			break
		if priorities[i]<priorities[slot] or (priorities[i]==priorities[slot] and tokens[i]<tokens[slot]):
			slot=i
	if sources[slot].playing and priorities[slot]>priority: return 0
	serial+=1
	tokens[slot]=serial
	levels[slot]=db
	priorities[slot]=priority
	var player:=sources[slot]
	player.stop()
	player.position=p
	player.stream=clips[key]
	player.volume_db=db+duck_db
	player.pitch_scale=pitch
	player.play()
	return serial

func follow(token: int,p: Vector3) -> void:
	var i:=tokens.find(token) if token>0 else -1
	if i>=0: sources[i].position=p

func stop_voice(token: int) -> void:
	var i:=tokens.find(token) if token>0 else -1
	if i>=0:
		sources[i].stop()
		tokens[i]=0

func quiet() -> void:
	for source in sources: source.stop()
	tokens.fill(0)

func set_movie(playing: bool) -> void:
	duck_db=-10. if playing else 0.
	for i in sources.size(): sources[i].volume_db=levels[i]+duck_db
