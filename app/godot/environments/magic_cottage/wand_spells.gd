extends "spell_brush.gd"
## A potion enchants both wands. All geometry and hit positions are in the room's frame.
enum { FIRE = 10, FROST, LIGHTNING, BELLS, ROSES, STARS, VORTEX, GATES, FISH, MOON }
const DURATION := 30.
const TINT := [Color("#ff813b"),Color("#99eaff"),Color("#baa4ff"),Color("#e8b96c"),Color("#f788a5"),
	Color("#b0dfff"),Color("#ecd6a0"),Color("#72dfba"),Color("#ffb168"),Color("#efe8ab")]
const IVORY := Color("#fff1c3")
const EMBER := Color("#fb6136")
const JADE := Color("#46aa83")
const GOLD := Color("#e4a54a")
const ICE := Color("#a3e6ff")
const Sound := preload("spell_audio.gd")
const SpellSurfaces := preload("spell_surfaces.gd")
const Raid := preload("window_raid.gd")

class Mark:
	var origin: Vector3
	var point: Vector3
	var frame: Basis
	var time := 0.
	var flight := 0.
	var lifespan := 3.
	var hand: String
	var held := false
	var arrived := false
	var guide: Vector3
	var forks := PackedVector3Array()
	var previous: Vector3
	var flight_voice := 0

var kind := -1
var elapsed := 0.
var ready_at := 0.
var expires_at := DURATION
var raid: Raid
var marks: Array[Mark] = []
var tips := {}
var surfaces: SpellSurfaces
var sound: Sound
## Brightest fireball burst this frame, 0..1. The baked room has no real-time lights, so the
## workshop warms its materials by this instead of a point light.
var flash := 0.

func _ready() -> void:
	super()

func activate(id: int) -> void:
	clear_magic()
	kind = id

func clear_magic() -> void:
	kind = -1
	elapsed = 0.
	ready_at = 0.
	expires_at = DURATION
	raid = null
	marks.clear()
	tips.clear()
	flash = 0.
	begin()
	finish()

func track(hand: String, origin: Vector3, dir: Vector3) -> void:
	tips[hand] = origin
	if kind == FISH:
		for mark in marks:
			if mark.held and mark.hand == hand: mark.guide = origin+dir*1.35

func untrack(hand: String) -> void:
	tips.erase(hand)
	for i in range(marks.size()-1,-1,-1):
		if marks[i].held and marks[i].hand == hand: marks.remove_at(i)

## Pick baked furnishing triangles only on casts. The glazed openings end at the night sky.
func contact(origin: Vector3, dir: Vector3, models: Node3D) -> Dictionary:
	var distance := 12.
	var normal := -dir
	if dir.z < -.001:
		var glass := (-5.14-origin.z)/dir.z
		var arch := (-4.97-origin.z)/dir.z
		var on_arch := origin+dir*arch
		if absf(on_arch.x) <= 2.66 and absf(on_arch.y-2.325)<=2.23: glass = arch
		if glass > 0. and glass < distance:
			distance = glass
			normal = Vector3.BACK
	for item: MeshInstance3D in models.get_children():
		if not item.visible: continue
		var inv := item.transform.affine_inverse()
		var start := inv*origin
		var direction := inv.basis*dir
		if item.get_aabb().grow(.001).intersects_segment(start,start+direction*distance)==null: continue
		var hit := surfaces.nearest(item.name,start,direction.normalized(),direction.length()*distance)
		if hit.is_empty(): continue
		var depth := ((item.transform*Vector3(hit.position))-origin).dot(dir)
		if depth < .02 or depth >= distance: continue
		distance = depth
		normal = (inv.basis.transposed()*Vector3(hit.normal)).normalized()
		if normal.dot(dir) > 0.: normal = -normal
	var x := Vector3.RIGHT if absf(normal.y) > .995 else Vector3.UP.cross(normal).normalized()
	x = (x-normal*x.dot(normal)).normalized()
	return {"point":origin+dir*distance+normal*.035,"frame":Basis(x,normal.cross(x),normal)}

func cast(hand: String, origin: Vector3, dir: Vector3, models: Node3D) -> void:
	if elapsed < ready_at: return
	ready_at = elapsed+.28
	track(hand,origin,dir)
	var hit := contact(origin,dir,models)
	var m := Mark.new()
	m.hand = hand
	m.origin = origin
	m.previous = origin
	m.point = hit.point
	m.frame = hit.frame
	if kind==BELLS:
		for existing in marks:
			if existing.point.distance_to(m.point)<.17:
				marks.erase(existing)
				break
	m.flight = clampf(origin.distance_to(m.point)/7.8,.13,1.25)
	if kind in [FIRE,LIGHTNING,MOON]:
		if not raid:
			var breed := Raid.Foe.BAT if kind==FIRE else Raid.Foe.SCARAB if kind==LIGHTNING else Raid.Foe.RAVEN
			raid = Raid.new(breed,sound)
			expires_at = maxf(DURATION,elapsed+22.)
		var foe := raid.first_hit(origin,m.point,.07)
		if foe and kind==LIGHTNING:
			m.forks=raid.chain(foe)
			m.point=m.forks[0]
		elif foe and kind==MOON:
			m.point=foe.position
			m.flight=clampf(origin.distance_to(m.point)/7.8,.13,1.25)
	if kind == GATES and marks.size() == 2: marks.clear()
	var max_marks := 8 if kind == STARS else 6
	if marks.size() >= max_marks:
		for i in marks.size():
			if not marks[i].held:
				marks.remove_at(i)
				break
	marks.append(m)
	match kind:
		FIRE:
			m.lifespan = m.flight+.8
			sound.cue("fire_cast",origin,-6.)
			m.flight_voice=sound.cue("fire_air",origin,-12.,1.,0)
		FROST, ROSES: m.lifespan = 5.
		LIGHTNING: m.lifespan = .45
		BELLS:
			var key := clampi(roundi(m.point.y*1.5),0,7)
			var steps := [0,2,4,7,9,12,14,16]
			sound.cue("bronze_bell",m.point,-5.,pow(2.,float(steps[key])/12.))
		STARS, GATES: m.lifespan = DURATION+1.
		VORTEX: m.lifespan = 4.
		FISH:
			m.held = true
			m.guide = origin+dir*1.35
			m.lifespan = DURATION+1.
		MOON: m.lifespan = m.flight*2.
	if kind not in [FIRE,BELLS]:
		var key: String = Sound.CASTS[kind-FIRE]
		if kind==GATES and marks.size()==2: key="gate_link"
		var pitch := 1.+.045*(marks.size()-1) if kind==STARS else 1.
		sound.cue(key,origin if kind in [MOON,FISH] else m.point,-5.,pitch)

func release_fish(hand: String, origin: Vector3, dir: Vector3, models: Node3D) -> void:
	for m in marks:
		if not m.held or m.hand != hand: continue
		var hit := contact(origin,dir,models)
		m.held = false
		m.origin = m.guide
		m.point = hit.point
		m.frame = hit.frame
		m.time = 0.
		m.flight = maxf(.38,m.origin.distance_to(m.point)/3.8)
		m.lifespan = m.flight+1.6
		sound.cue("koi_swim",m.guide,-8.)

func step(delta: float, broth: Vector3) -> void:
	elapsed += delta
	begin()
	flash = 0.
	if raid:
		var previously_done := raid.finished_at>=0.
		raid.advance(delta)
		if not previously_done and raid.finished_at>=0.:
			sound.cue("ward_win" if raid.hits>=Raid.GOAL else "ward_lost",Vector3(0,2.65,-4.65),-4.,1.,3)
	var tint: Color = TINT[kind-FIRE]
	for hand in tips:
		var tip: Vector3 = tips[hand]
		if elapsed < .85:
			var u := elapsed/.85
			var arc := broth.lerp(tip,u)+Vector3.UP*sin(PI*u)*.65
			bead(arc,.05,tint)
			bead(arc+Vector3.UP*.05,.018,IVORY)
		var fade := clampf((expires_at-elapsed)/2.,0.,1.)
		for i in 3:
			var a := elapsed*3.4+TAU*i/3.
			bead(tip+Vector3(cos(a),sin(a*1.6)*.5,sin(a))*.026,.009*fade,tint)
	for m in marks: m.time = minf(m.time+delta,m.lifespan)
	for i in marks.size():
		var m := marks[i]
		match kind:
			FIRE: fire(m)
			FROST: frost(m)
			LIGHTNING: lightning(m)
			BELLS: bell(m)
			ROSES: rose(m)
			STARS: star(m,i)
			VORTEX: vortex(m)
			GATES: gate(m,i)
			FISH: fish(m)
			MOON: moon(m)
	for i in range(marks.size()-1,-1,-1):
		if marks[i].time>=marks[i].lifespan: marks.remove_at(i)
	if raid: raid.draw(self)
	finish()

func fire(m: Mark) -> void:
	var dir := m.origin.direction_to(m.point)
	if not m.arrived:
		var next := m.origin.lerp(m.point,minf(1.,m.time/m.flight))
		var foe := raid.first_hit(m.previous,next,.13)
		if foe:
			m.point=foe.position
			m.flight=m.time
			m.lifespan=m.flight+.8
		m.previous=next
	if m.time < m.flight:
		var p := m.origin.lerp(m.point,m.time/m.flight)
		sound.follow(m.flight_voice,p)
		var axes := Basis(Quaternion(Vector3.UP,dir))
		jewel(p,Vector3(.076,.125,.076),IVORY,axes)
		halo(p,.54,EMBER)
		for i in 6:
			var a := m.time*14.+i*TAU/6.
			var radial := axes*Vector3(cos(a),0,sin(a))
			var root := p+radial*.064
			var tip := p-dir*(.21+.12*(.5+.5*sin(a*3.+m.time*5.)))+radial*.10
			wing(root-dir*.015,root+axes.x*.053,tip,GOLD if i%2 else EMBER)
			halo(root-dir*.095,.16,GOLD)
		return
	if not m.arrived:
		m.arrived = true
		raid.splash(m.point,.76)
		sound.stop_voice(m.flight_voice)
		sound.cue("fire_impact",m.point,-4.,1.,2)
	var t := clampf((m.time-m.flight)/.8,0.,1.)
	var center := m.point+m.frame.z*.07
	halo(center,(1.-t)*.88,GOLD)
	hoop(center,m.frame.z,.10+.65*t,EMBER.lerp(Color("#512438"),t))
	for i in 12:
		var a := i*TAU/12.
		var ray := m.frame*Vector3(cos(a),sin(a),.24+.4*absf(sin(i*3.)))
		var p := center+ray*(.10+.74*t)-Vector3.UP*.23*t*t
		line(p,p+ray*(1.-t)*.13,.014*(1.-t),GOLD)
		bead(p,.032*(1.-t),IVORY)
	flash = maxf(flash,1.-t)

func frost(m: Mark) -> void:
	var size := .49*minf(1.,m.time*1.8)*clampf(m.lifespan-m.time,0.,1.)
	for i in 6:
		var a := i*TAU/6.
		var ray := m.frame*Vector3(cos(a),sin(a),0)
		var side := m.frame.z.cross(ray)
		line(m.point,m.point+ray*size,.012,ICE)
		for j in range(1,4):
			var fork := m.point+ray*size*j*.22
			for sign_x in [-1.,1.]:
				line(fork,fork+(ray+side*sign_x)*size*(.22-.032*j),.007,IVORY)
	bead(m.point,.043,IVORY)

func bolt(a: Vector3,b: Vector3,side: Vector3,seed_value: int,width: float) -> void:
	var prev := a
	for i in range(1,8):
		var t := i/7.
		var jag := sin(i*2.43+float(seed_value))*.17
		var next := a.lerp(b,t)+side*sin(t*PI)*jag
		line(prev,next,width*.68,Color("#e4dbff"))
		halo(next,width*7.,Color("#a78dff"))
		if i in [2,5]:
			var twig:=next+(next-prev)*.37-side*signf(jag)*.15
			line(next,twig,width*.35,Color("#b9afff"))
		prev = next

func lightning(m: Mark) -> void:
	var width := .024*clampf(1.-m.time/m.lifespan,0.,1.)
	var phase := mini(2,int(m.time*8.))
	bolt(m.origin,m.point,m.frame.y,phase,width)
	for i in range(1,m.forks.size()):
		bolt(m.forks[i-1],m.forks[i],m.frame.y,phase+i,width*.86)
		halo(m.forks[i],.32,ICE)
	for i in 3:
		var a := TAU*i/3.+.52
		var end := m.point+m.frame*Vector3(cos(a)*.74,sin(a)*.74,.11)
		bolt(m.point,end,m.frame.x,phase+i+2,width*.65)
		bead(end,width*2.,IVORY)

func bell(m: Mark) -> void:
	var hook := m.point+m.frame.z*.16
	line(m.point,hook,.014,GOLD)
	var pivot := Basis(Vector3.FORWARD,.30*sin(m.time*12.)*exp(-2.*m.time))
	var scale_factor := minf(1.,(m.lifespan-m.time)*3.)
	line(hook,hook+pivot*Vector3.DOWN*.12,.009,IVORY)
	var shell := hook+pivot*Vector3.DOWN*.24
	form(BELL,shell,pivot,Vector3.ONE*.16*scale_factor,GOLD)
	bead(shell+pivot*Vector3.DOWN*.095,.037*scale_factor,IVORY)
	if m.time < .8: hoop(shell,Vector3.UP,.16+.24*m.time,Color("#f1d49a"))

func rose(m: Mark) -> void:
	var growth := clampf(m.time*.91,0.,1.)*clampf(m.lifespan-m.time,0.,1.)
	for branch in [-1.,1.]:
		var prev := m.point
		for j in range(1,9):
			var t := minf(j/8.,growth)
			var p := m.point+m.frame*Vector3(branch*(.22*t+.06*sin(t*7.)),.86*t,.065*sin(t*PI))
			line(prev,p,.013,JADE)
			if j/8.>growth: break
			var leaf := m.frame.rotated(m.frame.z,branch*(.8 if j%2 else -.8))
			jewel(p,Vector3(.028,.067,.012),JADE,leaf)
			if j in [4,7,8]:
				for k in 5:
					var a := k*TAU/5.
					bead(p+m.frame*Vector3(cos(a)*.037,sin(a)*.037,.025),.032,Color("#e77796"))
				bead(p+m.frame.z*.055,.022,GOLD)
			prev = p

func star(m: Mark,index: int) -> void:
	var pulse := .043+.007*sin(elapsed*3.+index)
	bead(m.point,pulse,IVORY)
	for axis in [m.frame.x,m.frame.y]:
		line(m.point-axis*pulse*1.8,m.point+axis*pulse*1.8,.009,ICE)
	if index>0:
		var prev := marks[index-1].point
		line(prev,prev.lerp(m.point,minf(1.,m.time*4.)),.010,Color("#72afd0"))

func vortex(m: Mark) -> void:
	var size := clampf(m.time*3.,0.,1.)*clampf(m.lifespan-m.time,0.,1.)
	var base := m.point+m.frame.z*.43
	for i in 11:
		var a := m.time*(2.4+i*.055)+i*2.40
		var level := fposmod(m.time*.36+i/11.,1.)
		var radius := (.08+level*.34)*size
		var p := base+Vector3(cos(a)*radius,(level-.35)*.81*size,sin(a)*radius)
		var axes := Basis(Vector3.UP,-a)*Basis(Vector3.RIGHT,.4+sin(a)*.55)*Basis(Vector3.FORWARD,.3)
		form(PAPER,p,axes,Vector3(.13,.18,.13)*size,IVORY if i%3 else GOLD)
		line(p-axes.x*.041,p+axes.x*.041,.004,Color("#856041"))

func gate(m: Mark,index: int) -> void:
	var p := m.point+m.frame.z*.05
	var opening := clampf(m.time*3.,.02,1.)
	var color := JADE if index==0 else GOLD
	hoop(p,m.frame.z,.30*opening,color)
	hoop(p,m.frame.z,.24*opening,IVORY)
	for i in 6:
		var a := elapsed*.7+i*TAU/6.
		bead(p+m.frame*Vector3(cos(a),sin(a),0)*.27*opening,.023,color)
	if marks.size()!=2: return
	# The same moth dives into the first mouth and emerges from the second.
	for i in 3:
		var phase := fposmod(marks[1].time*.53+i/3.,1.)
		if (index==0) != (phase<.5): continue
		var t := 1.-2.*phase if index==0 else (phase-.5)*2.
		var a := t*4.+i*2.
		var pos := p+m.frame*Vector3(cos(a)*t*.36,sin(a*1.4)*t*.23,.67*t)
		for sign_x in [-1.,1.]:
			var axes := m.frame.rotated(m.frame.y,sign_x*.65*sin(elapsed*20.+i))
			var tip := pos+axes*Vector3(sign_x*.085,.048,0)
			wing(pos,tip,pos+axes*Vector3(sign_x*.047,-.024,0),IVORY)
			wing(pos,pos+axes*Vector3(sign_x*.047,-.024,0),pos+axes*Vector3(sign_x*.026,-.054,0),GOLD)

func fish(m: Mark) -> void:
	var pos := m.guide
	var forward := (m.guide-Vector3(tips.get(m.hand,m.origin))).normalized()
	if not m.held:
		var t := minf(1.,m.time/m.flight)
		pos = m.origin.lerp(m.point,t)+Vector3.UP*.20*sin(PI*t)
		forward = m.origin.direction_to(m.point)
		if t>=1.:
			var a := (m.time-m.flight)*3.
			pos += m.frame*Vector3(sin(a)*.20,(1.-cos(a))*.09,.08)
			forward = (m.frame.x*cos(a)+m.frame.y*.45*sin(a)).normalized()
	if forward.length_squared()<.5: forward=Vector3.FORWARD
	var up := Vector3.RIGHT if absf(forward.y)>.98 else Vector3.UP
	koi(pos,Basis.looking_at(forward,up),m.time*1.7+float(m.hand.length()))

## A koi about 34 cm long: a spine of five segments that ripples from head to tail, orange and ivory
## patches, a dorsal fin, beating side fins, a forked veil tail, eyes, barbels and a few bubbles.
func koi(pos: Vector3, axes: Basis, phase: float) -> void:
	const LENGTHS := [.070,.075,.070,.060,.050]
	const WIDTHS := [.048,.055,.050,.039,.024]
	const BODY := [Color("#f2803a"),Color("#ef7432"),Color("#f07c36"),Color("#f38f44"),Color("#f5a352")]
	var swim := elapsed*9.+phase
	var spine: Array[Vector3] = [pos-axes.z*.16]
	for k in LENGTHS.size():
		var sway := .55*sin(swim-k*.95)*pow((k+1.)/LENGTHS.size(),1.4)
		var heading := axes.rotated(axes.y,sway)
		spine.append(spine[k]+heading.z*float(LENGTHS[k]))
	for k in LENGTHS.size():
		var a: Vector3 = spine[k]
		var b: Vector3 = spine[k+1]
		var along := (b-a).normalized()
		var side := axes.y.cross(along).normalized()
		var basis := Basis(side,axes.y,along)
		jewel((a+b)*.5,Vector3(WIDTHS[k],WIDTHS[k]*1.22,float(LENGTHS[k])*.95),BODY[k],basis)
		# Ivory patches lie over the back of the second and fourth segments, as on a kohaku.
		if k in [1,3]:
			jewel((a+b)*.5+axes.y*float(WIDTHS[k])*.38+side*.006*(k-2),Vector3(WIDTHS[k]*.86,WIDTHS[k]*.80,float(LENGTHS[k])*.70),Color("#fff3e2"),basis)
	var head: Vector3 = spine[0]
	var nose := head-axes.z*.035
	jewel(head+axes.y*.012-axes.z*.008,Vector3(.040,.038,.040),Color("#d8462a"),axes)
	for s: float in [-1.,1.]:
		bead(head+axes.x*.038*s+axes.y*.018,.010,Color("#25182b"))
		line(nose+axes.x*.012*s,nose+axes.x*.045*s+axes.z*.030-axes.y*.018,.0025,IVORY)
		# Side fins open and close against the body.
		var beat := .5+.5*sin(elapsed*6.+phase+s)
		var root: Vector3 = spine[1]+axes.x*.045*s-axes.y*.020
		wing(root,root+axes.z*.055,root+(axes.x*s*(.035+.035*beat)+axes.z*.030-axes.y*.030),Color(1.,.86,.70))
	# Dorsal fin along the back from the second to the fourth segment.
	var back := axes.y*.062
	wing(spine[1]+back*.9,spine[3]+back*.7,spine[2]+back*1.75,Color(1.,.80,.60))
	# The veil tail spreads into two lobes that trail the last segment's sway.
	var tail: Vector3 = spine[spine.size()-1]
	var trail := (tail-spine[spine.size()-2]).normalized()
	var flare := axes.y.cross(trail).normalized()*.025*sin(swim-5.)
	for s: float in [-1.,1.]:
		var tip := tail+trail*.115+axes.y*.068*s+flare
		wing(tail,tip,tail+trail*.075+axes.y*.016*s,Color(1.,.93,.82))
		wing(tail,tip,tail+trail*.045+axes.y*.050*s,Color(1.,.70,.45))
	halo((head+tail)*.5,.30,Color("#ffb066"))
	for i in 4:
		var u := fposmod(elapsed*.9+i*.25+phase,1.)
		bead(tail+trail*(.03+.10*u)+Vector3.UP*.16*u+axes.x*.02*sin(i*2.3),.007*(1.-u)+.002,Color("#bfe9ff"))

func moon(m: Mark) -> void:
	var t := clampf(m.time/m.lifespan,0.,1.)
	var outbound := t < .5
	var u := 2.*t if outbound else (t-.5)*2.
	var returning_to: Vector3 = tips.get(m.hand,m.origin)
	var side := m.frame.x*(.52*sin(PI*u))
	var p := m.origin.lerp(m.point,u)+side if outbound else m.point.lerp(returning_to,u)-side
	if not outbound and not m.arrived: sweep_moon(m,m.point)
	sweep_moon(m,p)
	var axes := m.frame.rotated(m.frame.z,elapsed*5.)
	var prev := Vector3.ZERO
	for i in 13:
		var a := lerpf(-2.23,2.23,i/12.)
		var curr := p+axes*Vector3(cos(a)*.15,sin(a)*.15,0)
		if i: line(prev,curr,.011+.025*sin(i*PI/13.),IVORY)
		prev = curr
	if not outbound and not m.arrived:
		m.arrived=true
		sound.cue("moon_return",m.point,-7.)

func sweep_moon(m: Mark, end: Vector3) -> void:
	var foe := raid.first_hit(m.previous,end,.17)
	while foe:
		raid.repel(foe)
		foe=raid.first_hit(m.previous,end,.17)
	m.previous=end
