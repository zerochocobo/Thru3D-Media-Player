extends Node3D
const STREAMS := {"rotate":preload("res://audio/puzzle/rotate.wav"),"snap":preload("res://audio/puzzle/snap.wav"),"success":preload("res://audio/puzzle/success.wav"),"launch":preload("res://audio/puzzle/launch.wav"),"burst":preload("res://audio/puzzle/burst.wav")}
const VOLUMES := {"rotate":-6.0,"snap":-6.0,"success":-9.0,"launch":-11.0,"burst":-9.0}
var voices := {}
var cursor := {}
var counts := {}
var completed := false
var last_rotation_ms := -1000

func _ready() -> void:
	for kind in STREAMS:
		voices[kind]=[]; cursor[kind]=0; counts[kind]=0
		for i in (3 if kind in ["launch","burst"] else 2):
			var player := AudioStreamPlayer3D.new(); player.stream=STREAMS[kind]; player.volume_db=VOLUMES[kind]
			player.unit_size=2.5; player.panning_strength=0.8; add_child(player); voices[kind].append(player)

func play(kind: String, point: Vector3) -> void:
	if not voices.has(kind) or not point.is_finite(): return
	if kind=="rotate":
		var now := Time.get_ticks_msec()
		if now-last_rotation_ms<80: return
		last_rotation_ms=now
	var index: int=cursor[kind]; var player: AudioStreamPlayer3D=voices[kind][index]
	player.global_position=point; player.play(); counts[kind]+=1; cursor[kind]=(index+1)%voices[kind].size()

func success(point: Vector3) -> bool:
	if completed: return false
	completed=true; play("success",point); return true

func stop_all() -> void:
	for pool in voices.values():
		for player in pool: player.stop()

func reset() -> void:
	stop_all(); completed=false; last_rotation_ms=-1000
	for kind in counts: counts[kind]=0

func _exit_tree() -> void:
	stop_all()
	for pool in voices.values():
		for player in pool: player.stream=null
