extends "res://scripts/ray_menu.gd"
signal requested(operation: String)
var spherical := false
var audio_provider: Callable
var capture_provider: Callable
func _ready() -> void:
	super()
	visibility_changed.connect(func():
		if not visible and music_quick: music_quick.reset())
func has_pointer_capture() -> bool:
	return bool(capture_provider.call()) if capture_provider.is_valid() else false
func _place_device_status(_centre: Vector2) -> void:
	if not device_status: device_status=DeviceStatus.new(); add_child(device_status)
	device_status.position=Vector3(0,-0.10,0.004)
func _draw() -> void:
	_clear_layout(); _set_backdrop(Vector2(0.001,0.001),Vector2.ZERO); _backdrop.visible=false
	_round(1,"menu",Vector2.ZERO,0.065,true,false,I18n.t("Puzzle"))
	_round(2,"photo_batch",Vector2(-0.12,0),0.065,true,false,I18n.t("Random batch"))
	_round(3,"next",Vector2(0.12,0),0.065,true,false,I18n.t("Next batch"))
	if spherical: _round(4,"recenter",Vector2(0.24,0),0.065,true,false,I18n.t("Reset sky"))
	_round(5,"image",Vector2(-0.24,0),0.065,true,false,I18n.t("Reference"))
	if not music_quick: music_quick=preload("res://scripts/music_quick_controls.gd").new(self,func(): requested.emit("music_toggle"))
	music_quick.draw(6,Vector2(-0.36,0),audio_provider.call() if audio_provider.is_valid() else {})
func _activate(target: int) -> void:
	if target in [1,2,3,4,5,6]: requested.emit({1:"menu",2:"organize",3:"tray",4:"recenter",5:"reference",6:"music"}[target])
