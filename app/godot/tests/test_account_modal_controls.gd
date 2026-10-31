extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/ray_menu.gd")
const Platform := preload("res://tests/account_platform_fixture.gd")
class Host extends "res://scripts/main.gd":
	func _place_menu(_menu: Node3D, _recenter: bool = false) -> void: pass
var checks := 0
var failures := 0
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures += 1; push_error(label)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var main := Host.new()
	var menu := Menu.new(); var player := Player.new(); var platform := Platform.new()
	root.add_child(menu); root.add_child(player); menu.attach_platform(platform); menu.visible = true
	main.recent_menu = menu; main.player_menu = player
	var panel: RefCounted = menu.account_panel
	panel.start("cloud", "onedrive")
	var identity: int = panel.session
	var state: Dictionary = platform.account_sessions[identity]
	state.state = "web"; state.web = {"renderer":"gecko","width":440,"height":600}
	panel.poll()
	for action in [main._toggle_player_menu, main._show_player_menu, main._show_recent_menu]:
		action.call()
		check(menu.visible and not player.visible, "Ordinary controls do not cover the authentication page")
		check(panel.session == identity and panel.view == "web" and not identity in platform.account_cancels, "Controls navigation preserves the same authentication workflow")
	menu._activate(menu.CLOSE)
	main._show_player_menu()
	check(not panel.active() and identity in platform.account_cancels, "The explicit close button still cancels authentication")
	check(player.visible, "Ordinary controls are available again after explicit close")
	main.recent_menu = null; main.player_menu = null
	menu.free(); player.free(); platform.free(); main.free()
	print("Account modal controls: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
