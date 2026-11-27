extends Node3D
## Emitted once a book is back on its shelf, animated or not.
signal closed
const FLIGHT := .42
## A book leaves and reaches its shelf at this fraction of its reading size.
const SHELF_SCALE := .45
const Model := preload("res://scripts/book_model.gd")
const Motion := preload("res://scripts/book_leaf_motion.gd")
const Spread := preload("folio_spread.gd")
const Discovery := preload("discovery.gd")
var kind := ""
var page := 0
var entries: Array = []
var archive: Discovery
var atlas: Texture2D
var model: Model
var current: Spread
var other: Spread
var leaf := {}
var turn_hand := ""
var since := 0
var sweeps := {}
var closing := false
var shelf := Transform3D()
var motion: Tween

func _ready() -> void:
	visible=false

func prepare() -> void:
	if model:
		model.process_mode = Node.PROCESS_MODE_INHERIT
		return
	model=Model.new()
	model.page_size=Vector2(.39,.451)
	model.paper=Color("#e0c796")
	model.cover=Color("#492837")
	model.rebuild()
	model.set_marked(false,true)
	add_child(model)
	current=Spread.new()
	add_child(current)

## from: where the book sits on its shelf; it flies from there to the reader.
func open(book: String, pose: Transform3D, wall: int, from := Transform3D()) -> void:
	prepare()
	if motion: motion.kill()
	closing = false
	kind = book
	page = 0
	var forward := -pose.basis.z
	forward.y = 0
	if forward.length_squared() < .01: forward = Vector3.FORWARD
	forward = forward.normalized()
	var rest := Transform3D(Basis.looking_at(forward),pose.origin+forward*.91+Vector3.DOWN*.10)
	shelf = Transform3D(rest.basis.scaled(Vector3.ONE*SHELF_SCALE),from.origin) if from != Transform3D() else rest
	visible = true
	rebuild(wall,true)
	fly(shelf,rest)

func fly(start: Transform3D, end: Transform3D, then := Callable()) -> void:
	if motion: motion.kill()
	global_transform = start
	if start.is_equal_approx(end):
		if then.is_valid(): then.call()
		return
	motion = create_tween()
	motion.tween_method(func(t: float):
		var arc := Vector3.UP*.12*sin(PI*t)
		global_transform = start.interpolate_with(end,t).translated(arc)
	,0.,1.,FLIGHT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if then.is_valid(): motion.tween_callback(then)

func rebuild(wall: int,prefer_hint := false) -> void:
	reset_turn()
	entries.clear()
	match kind:
		"Recipe":
			for k in archive.recipes: entries.append({"key":k,"visible":3})
			if prefer_hint: page = entries.size()
			var leads := archive.hints(wall)
			if not leads.is_empty():
				var lead: Dictionary = leads[0]
				if leads.size()>1: lead["second"] = leads[1]
				entries.append(lead)
		"Herbal":
			# The pot in the room comes first: what is growing, how far along, and whether it has water.
			entries.append({"pot":true})
			for id in archive.herbs: entries.append({"id":id})
		"Atlas":
			for id in 64: entries.append({"chart":id})
		"Journal":
			entries.append({"journal":true})
	page = clampi(page,0,maxi(0,entries.size()-1))
	draw()

func draw() -> void:
	current.paint(kind,entries,page,archive,atlas)
	model.progress=float(page)/maxf(1,entries.size()-1)
	model.rebuild()
	model.set_pages(current.side(0),current.side(1))

func reset_turn() -> void:
	if model:
		model.turn(0.)
		model.set_leaf(null,null)
	leaf.clear()
	turn_hand=""
	sweeps.clear()

## animated: the book shuts and flies back to its shelf first.
func close(animated := false) -> void:
	if not visible: return
	if animated:
		if closing: return
		closing = true
		reset_turn()
		fly(global_transform,shelf,finish_close)
		return
	if motion: motion.kill()
	finish_close()

func finish_close() -> void:
	closing = false
	reset_turn()
	visible=false
	# Building the book and its four page targets takes several frames on a headset, so
	# a closed book stays parked (about 19 MB of page targets) until the room is left.
	if model: model.process_mode = Node.PROCESS_MODE_DISABLED
	closed.emit()

func hit(ray: Array) -> String:
	if not visible or not model or closing or (motion and motion.is_running()): return ""
	var surface:=model.hit(ray[0],ray[1])
	if surface.is_empty(): return ""
	var p:=model.to_local(surface.point)
	return "next" if p.x>0 else "previous"

func lift(direction: int,hand: String,held: bool) -> void:
	if not leaf.is_empty() or entries.size()<2: return
	var to:=posmod(page+direction,entries.size())
	if not other:
		other=Spread.new()
		add_child(other)
	other.paint(kind,entries,to,archive,atlas)
	if direction>0:
		model.set_leaf(current.side(1),other.side(0))
		model.set_pages(current.side(0),other.side(1))
	else:
		model.set_leaf(other.side(1),current.side(0))
		model.set_pages(other.side(0),current.side(1))
	turn_hand=hand
	since=Time.get_ticks_msec()
	leaf={"amount":.015 if direction>0 else .985,"direction":direction,"to":to,
		"target":1. if direction>0 else 0.,"held":held,"commit":true}
	model.turn(leaf.amount)
	model.sound(randf_range(.92,1.12))

func press(hand: String,action: String) -> void:
	if action=="close": close()
	else: lift(1 if action=="next" else -1,hand,true)

func release_hand(hand: String,cancelled := false) -> void:
	if cancelled: sweeps.erase(hand)
	if turn_hand!=hand or leaf.is_empty() or not leaf.held: return
	if cancelled:
		leaf.held=false
		leaf.commit=false
		leaf.target=0. if leaf.direction>0 else 1.
	else: Motion.drop(leaf,Time.get_ticks_msec()-since<260)

func aim(hand: String,ray: Array,delta: float,free: bool) -> Dictionary:
	if not visible or not model or closing: return {}
	var surface:=model.hit(ray[0],ray[1])
	var reach:=model.hit(ray[0],ray[1],1.35)
	if not sweeps.has(hand): sweeps[hand]=Motion.new()
	var sweep: Motion=sweeps[hand]
	var pointing: Vector3 = global_basis.inverse()*Vector3(ray[1])
	sweep.track(atan2(pointing.x,-pointing.z),model.to_local(reach.point).x/model.page_size.x if not reach.is_empty() else null,delta)
	if not leaf.is_empty() and leaf.held and turn_hand==hand and not surface.is_empty():
		Motion.carry(leaf,model.to_local(surface.point).x/model.page_size.x,delta)
		model.turn(leaf.amount)
	elif leaf.is_empty() and free and not reach.is_empty():
		var direction:=sweep.swish()
		if direction: lift(direction,hand,false)
	return surface

func _process(delta: float) -> void:
	if not visible or leaf.is_empty() or leaf.held: return
	Motion.advance(leaf,delta)
	model.turn(leaf.amount)
	if not is_equal_approx(leaf.amount,leaf.target): return
	if leaf.commit:
		page=leaf.to
		var old:=current
		current=other
		other=old
		model.sound(randf_range(.7,.8),-6.)
	reset_turn()
	model.progress=float(page)/maxf(1,entries.size()-1)
	model.rebuild()
	model.set_pages(current.side(0),current.side(1))
