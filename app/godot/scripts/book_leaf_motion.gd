extends RefCounted
## Shared paper inertia and wand sweep in normalized page widths.
const TURN_SECONDS := .55
const FLICK := 2.
var yaw := 0.
var velocity := 0.
var rest := 0.
var samples: Array[Vector2] = []

func track(angle: float, across: Variant, delta: float) -> void:
	velocity = lerpf(velocity,(angle-yaw)/maxf(delta,.001),.5)
	yaw = angle
	rest = maxf(0.,rest-delta)
	var now := Time.get_ticks_msec()
	if across!=null: samples.append(Vector2(now,across))
	while not samples.is_empty() and now-samples[0].x>320: samples.pop_front()

func swish() -> int:
	if rest>0. or absf(velocity)<=4.5 or samples.size()<2: return 0
	var low := INF
	var high := -INF
	for sample in samples:
		low=minf(low,sample.y)
		high=maxf(high,sample.y)
	if high-low<=1.: return 0
	rest=1.
	samples.clear()
	return 1 if velocity<0 else -1

static func carry(leaf: Dictionary, across: float, delta: float) -> void:
	var old := float(leaf.amount)
	var goal := clampf((1.-across)*.5,.03,.97)
	leaf.amount=lerpf(old,goal,1.-exp(-delta*16.))
	leaf.speed=lerpf(float(leaf.get("speed",0.)),(float(leaf.amount)-old)/maxf(delta,.001),.4)

static func drop(leaf: Dictionary, tapped: bool) -> bool:
	var forward := int(leaf.direction)>0
	var amount := float(leaf.amount)
	var speed := float(leaf.get("speed",0.))*(1. if forward else -1.)
	var finish := tapped or speed>FLICK or (speed> -FLICK and (amount>.45 if forward else amount<.55))
	leaf.held=false
	leaf.commit=finish
	leaf.target=1. if finish==forward else 0.
	return finish

static func advance(leaf: Dictionary, delta: float, queued := false) -> void:
	var goal:=float(leaf.target)
	var momentum:=float(leaf.get("speed",0.))
	var speed:=maxf(1./(TURN_SECONDS*(.6 if queued else 1.)),absf(momentum))
	leaf.speed=move_toward(momentum,0.,delta*4.)
	var remaining:=absf(goal-float(leaf.amount))
	leaf.amount=move_toward(float(leaf.amount),goal,delta*speed*clampf(remaining*6.+.25,.25,1.))
