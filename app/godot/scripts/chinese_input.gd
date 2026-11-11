extends RefCounted
const I18n := preload("res://scripts/i18n.gd")
const Keyboard := preload("res://scripts/chinese_keyboard.gd")
static var selected := false
static var quest := OS.has_feature("quest")
static var pico := OS.has_feature("pico")
static var android := OS.has_feature("android")
static var browser_keyboard := "builtin"
static var popup: Node3D
static var head_provider: Callable
static var on_open: Callable

## Static hooks must not retain a closure over a player after its tree exits.
## An older player's disposal must not detach a newer player's bindings.
static func release_host(host: Node) -> void:
	if head_provider.get_object()==host: head_provider=Callable()
	if on_open.get_object()==host: on_open=Callable()
	if is_instance_valid(popup) and popup.head_provider.get_object()==host:
		popup.head_provider=Callable()

static func is_generic_openxr() -> bool: return android and not quest and not pico
static func _quest_available() -> bool: return quest and I18n.language == "zh"
static func available() -> bool: return _quest_available() or is_generic_openxr()
static func app_setting_key() -> String:
	return "openxr_chinese_keyboard" if is_generic_openxr() else "quest_chinese_keyboard"

static func enabled() -> bool: return selected and available()
## Generic Android OpenXR runtimes may not composite the system IME in VR.
static func browser_choice_available() -> bool: return is_generic_openxr()
static func browser_enabled() -> bool:
	if browser_choice_available(): return browser_keyboard == "builtin"
	return _quest_available() and selected
static func active() -> bool: return is_instance_valid(popup) and popup.visible

static func configure_browser(value: String) -> void:
	browser_keyboard = "system" if value == "system" else "builtin"
	if not browser_enabled(): close("browser", true)

static func configure(value: bool) -> void:
	selected = value
	if not enabled() and active() and (popup.owner_id != "browser" or not browser_enabled()): popup.close()
	if enabled(): Keyboard.Pinyin.begin_load()

static func ensure(parent: Node) -> Node3D:
	if not is_instance_valid(popup):
		popup = Keyboard.new(); popup.name = "ChineseKeyboard"
		parent.add_child(popup)
	return popup

static func open(host: Node, id: String, action: Callable, valid: Callable, preview: Callable = Callable(), english: bool = false, allow_system: bool = false) -> void:
	var keyboard := ensure(host.get_tree().root)
	keyboard.head_provider = head_provider
	Keyboard.Pinyin.begin_load()
	if active(): keyboard.close()
	keyboard.present(id, action, valid, preview, english, allow_system)
	var head: Variant = head_provider.call() if head_provider.is_valid() else null
	if head is Transform3D:
		var frame := Keyboard.Move.menu_head(head)
		var offset := Transform3D(Basis.from_scale(Vector3.ONE * Keyboard.WINDOW_SCALE), Vector3(0, -0.38, -1.20))
		keyboard.global_transform = frame * (keyboard.placement if keyboard.placement is Transform3D else offset)
	elif host is Node3D:
		keyboard.global_transform = host.global_transform.translated_local(Vector3(0, -0.12, 0.18))
		keyboard.global_basis = keyboard.global_basis.orthonormalized().scaled(Vector3.ONE * Keyboard.WINDOW_SCALE)
	if on_open.is_valid(): on_open.call()

static func close(id: String = "", notify: bool = false) -> void:
	if active() and (id.is_empty() or popup.owner_id == id): popup.close(notify)
