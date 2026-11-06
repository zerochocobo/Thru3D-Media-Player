extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Surface := preload("res://scripts/web_browser_surface.gd")
class Preparation extends RefCounted:
	var ready := false
	var cleared := 0
	func prepare(_id: int,_depth: bool,_matte: bool) -> String: return JSON.stringify({"state":"ready" if ready else "preparing"})
	func clearPreparation(_id: int) -> void: cleared += 1
class Bridge extends RefCounted:
	var acknowledged := 0
	var requests := 0
	var legacy_calls := 0
	func windowReleaseState(_window: int,generation: int) -> int: return 1 if acknowledged == generation else 0
	func requestWindowRelease(_window: int,_generation: int) -> bool: requests += 1;return true
	func releaseWindowForResize(_window: int,_generation: int) -> bool: legacy_calls += 1;return false
class Layer extends RefCounted:
	var stereo := false
	var alpha := false
	var source_crop := Rect2(0,0,1,1)
	var sort_order := 0
	var effect_state := "ready"
	var shown := 0
	var destroy_calls := 0
	var asynchronous := false
	var stop_ready := false
	func present(_pose: Transform3D,_size: Vector2,_crop: Rect2) -> bool: shown += 1;return true
	func hide() -> void: pass
	func input_surface() -> JavaObject: return null
	func configure_effect(_strength: float,_position: float,_identity: String,_fill: bool,_depth: bool) -> String: return ""
	func destroy(nonblocking: bool=false) -> bool: destroy_calls += 1;asynchronous=nonblocking;return stop_ready
class Producer extends Surface:
	var created := 0
	func _create_layer() -> void:
		created += 1;layer=Layer.new();layer.stereo=true
var checks := 0
var failures: Array[String] = []
func check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new();root.add_child(menu);menu.attach_platform(platform);menu.toggle();menu._activate(Menu.NAV_BASE+Menu.Section.WEB)
	var browser: RefCounted=menu.web_browser;browser.open("https://example.com/video");browser.next_poll=0;browser.tick()
	var host: Node3D=browser.windows[1]
	var producer:=Producer.new();producer.configure(host,platform,1);root.add_child(producer)
	var old:=Layer.new();var preparation:=Preparation.new();var transfer:=Bridge.new()
	producer.layer=old;producer.bridge=transfer;producer.preparation_api=preparation
	producer.attached=true;producer.generation=42;producer.shown=true
	producer.state={"generation":42,"attached":true,"tab_id":1};producer.state_poll=9223372036854775807
	producer.hole=MeshInstance3D.new();producer.hole.mesh=QuadMesh.new();producer.add_child(producer.hole)
	host.depth.enabled=true
	for frame in 100: producer._process(0)
	check(old.shown==100 and old.destroy_calls==0 and producer.created==0,"Cold preparation keeps presenting the existing 2D page on every application frame")
	check(transfer.requests==0 and transfer.legacy_calls==0,"Cold model work does not detach Gecko or call the blocking release API")
	host.depth.enabled=false;producer._process(0)
	check(preparation.cleared>0 and producer.layer==old,"Turning the effect off during preparation preserves the original surface")
	host.depth.enabled=true;preparation.ready=true
	for frame in 20: producer._process(0)
	check(transfer.requests>0 and old.destroy_calls==0 and producer.layer==old,"Pending UI acknowledgement cannot destroy the old surface")
	transfer.acknowledged=41;producer._process(0)
	check(old.destroy_calls==0,"An old surface generation cannot authorize the switch")
	transfer.acknowledged=42;producer._process(0)
	check(old.asynchronous and producer.layer==old,"Effect cleanup is queued rather than waited on by the XR frame loop")
	old.stop_ready=true;producer._process(0)
	check(producer.created==1 and producer.layer!=old and transfer.legacy_calls==0,"Only the matching release and completed cleanup install the new producer")
	producer.layer=null;producer.bridge=null;producer.generation=0;producer.queue_free()
	menu.free();platform.free();await process_frame
	print("Browser effect transition: %d checks, %d failures" % [checks,failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
