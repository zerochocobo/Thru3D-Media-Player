extends RefCounted
## Six enchanted intruders come through the real lancets and retreat down the side aisles.
const Brush := preload("spell_brush.gd")
const Sound := preload("spell_audio.gd")
const WINGS := ["bat_wing","scarab_wing","raven_wing"]
enum Foe { BAT, SCARAB, RAVEN }
const COUNT := 6
const GOAL := 4
const MAX_ON_SCREEN := 3
const ARRIVALS := [0.,1.8,2.7,5.5,7.8,9.1]
const SIDES := [-1.,1.,1.,-1.,-1.,1.]
const WIND := Color("#99dbea")
const BRASS := Color("#e9af57")
const PEARL := Color("#fff0c3")
const DUSK := Color("#413558")

class Visitor:
	var index: int
	var born: float
	var position: Vector3
	var heading := Vector3.BACK
	var size := 1.
	var next_beat := .55
	var wing_voice := 0

class Spark:
	var point: Vector3
	var born: float

var breed := Foe.BAT
var sound: Sound
var time := 0.
var next := 0
var hits := 0
var escaped := 0
var finished_at := -1.
var foes: Array[Visitor] = []
var sparks: Array[Spark] = []
var results := PackedInt32Array([0,0,0,0,0,0])

func _init(style: Foe,audio: Sound) -> void:
	breed=style
	sound=audio
	arrive()

func window(index: int) -> Vector3:
	return Vector3(3.50*SIDES[index],1.99,-5.13)

func arrive() -> void:
	var foe := Visitor.new()
	foe.index=next
	foe.born=time
	foe.position=window(next)
	foe.size=.24
	foes.append(foe)
	sound.cue("window_open",foe.position,-7.,1.04 if SIDES[next]>0 else .92,2)
	next+=1

func path(foe: Visitor, age: float) -> Vector3:
	var id := foe.index
	var gate := window(id)
	var side: float = SIDES[id]
	var t := clampf((age-.60)/4.4,0.,1.)
	var forward := smoothstep(0.,1.,t)
	var retreat := smoothstep(5.1,7.,age)
	var travel := forward*(1.-retreat)
	var flap := sin(t*PI)*(1.-retreat)
	var z := lerpf(-5.13,-4.68,clampf(age/.6,0.,1.)*(1.-retreat)) + 3.46*travel
	var x := gate.x - side*(1.53+.15*(id%3))*travel
	var y := gate.y-.26*travel
	x += (.19 if breed==Foe.SCARAB else .33)*sin(age*2.2+id)*flap
	y += (.25 if breed==Foe.BAT else .16)*sin(age*3.1+id*.8)*flap
	return Vector3(x,y,z)

func advance(delta: float) -> void:
	time+=delta
	for i in range(foes.size()-1,-1,-1):
		var foe := foes[i]
		var age := time-foe.born
		if age>=7.:
			sound.stop_voice(foe.wing_voice)
			sound.cue("escaped",window(foe.index),-8.,1.,2)
			results[foe.index]=-1
			escaped+=1
			foes.remove_at(i)
			continue
		foe.position=path(foe,age)
		if age>=foe.next_beat:
			foe.wing_voice=sound.cue(WINGS[breed],foe.position,-11.,.95+.04*(foe.index%3),0)
			foe.next_beat=age+1.36
		sound.follow(foe.wing_voice,foe.position)
		var heading:=path(foe,age+.025)-foe.position
		if heading.length_squared()>.000001: foe.heading=heading.normalized()
		foe.size=lerpf(.24,1.,smoothstep(0.,.94,age))*(1.-.66*smoothstep(6.1,7.,age))
	while next<COUNT and foes.size()<MAX_ON_SCREEN and time>=float(ARRIVALS[next]): arrive()
	for i in range(sparks.size()-1,-1,-1):
		if time-sparks[i].born>.60: sparks.remove_at(i)
	if next==COUNT and foes.is_empty() and finished_at<0.: finished_at=time

func first_hit(a: Vector3,b: Vector3,width: float) -> Visitor:
	var ray := b-a
	var length := ray.length()
	if length<.0001: return null
	ray/=length
	var nearest: Visitor
	var near_t := INF
	for foe in foes:
		var t := clampf((foe.position-a).dot(ray),0.,length)
		if t>=near_t: continue
		if (a+ray*t).distance_squared_to(foe.position)<=pow(.22*foe.size+width,2.):
			nearest=foe
			near_t=t
	return nearest

func repel(foe: Visitor) -> void:
	if not foes.has(foe): return
	sound.stop_voice(foe.wing_voice)
	sound.cue("repelled",foe.position,-7.,.94+hits*.045,2)
	results[foe.index]=1
	hits+=1
	var spark := Spark.new()
	spark.point=foe.position
	spark.born=time
	sparks.append(spark)
	foes.erase(foe)

func splash(p: Vector3,radius: float) -> void:
	for i in range(foes.size()-1,-1,-1):
		var foe:=foes[i]
		if foe.position.distance_to(p)<=radius+.22*foe.size: repel(foe)

func chain(foe: Visitor) -> PackedVector3Array:
	var points := PackedVector3Array()
	while foe and points.size()<3:
		var p := foe.position
		points.append(p)
		repel(foe)
		foe=null
		var distance:=1.85
		for candidate in foes:
			var gap:=candidate.position.distance_to(p)
			if gap<distance:
				foe=candidate
				distance=gap
	return points

func draw(ink: Brush) -> void:
	if finished_at>=0. and time-finished_at>2.8: return
	for s in [-1.,1.]:
		var gate := Vector3(3.5*s,1.99,-4.85)
		for i in 3:
			var index: int = [0,3,4][i] if s<0. else [1,2,5][i]
			var p := gate+Vector3((i-1)*.15,.66,.02)
			var colour := WIND if results[index]==0 else BRASS if results[index]==1 else DUSK
			ink.jewel(p,Vector3(.031,.061,.023),colour)
			if results[index]==1: ink.halo(p,.13,BRASS)
		if finished_at>=0.:
			var hue := BRASS if hits>=GOAL else WIND
			var since := time-finished_at
			ink.hoop(gate,Vector3.BACK,.25+.20*minf(1.,since),hue)
			if hits>=GOAL:
				for k in 4:
					var a:=k*TAU/4.
					ink.line(gate+Vector3(cos(a),sin(a),0)*.28,gate+Vector3(cos(a+PI*.5),sin(a+PI*.5),0)*.28,.013,BRASS)
			continue
		for foe in foes:
			var age:=time-foe.born
			if SIDES[foe.index]!=s or age>1.4: continue
			ink.hoop(gate,Vector3.BACK,.31+.085*sin(age*PI/1.4),WIND)
			ink.halo(gate,.65*(1.-age/1.4),WIND)
			break
	for foe in foes: draw_foe(ink,foe)
	for spark in sparks:
		var u := (time-spark.born)/.60
		for i in 7:
			var a := TAU*i/7.
			var d:=Vector3(cos(a),sin(a),.28*sin(a*3.))
			ink.line(spark.point+d*(.06+u*.36),spark.point+d*(.14+u*.36),.018*(1.-u),BRASS)
		ink.halo(spark.point,.54*(1.-u),PEARL)

func draw_foe(ink: Brush,foe: Visitor) -> void:
	var p:=foe.position
	var up:=Vector3.UP if absf(foe.heading.y)<.95 else Vector3.RIGHT
	var frame:=Basis.looking_at(foe.heading,up)*Basis(Vector3.FORWARD,.15*sin(time*3.+foe.index))
	frame=frame.scaled_local(Vector3.ONE*foe.size)
	var body:=Color("#785d91") if breed==Foe.BAT else Color("#297c78") if breed==Foe.SCARAB else Color("#8888aa")
	var accent:=Color("#f29d8a") if breed==Foe.BAT else BRASS if breed==Foe.SCARAB else WIND
	ink.jewel(p,Vector3(.088,.095,.17),body,frame)
	ink.jewel(p-frame.z*.145,Vector3(.084,.084,.086),body,frame)
	ink.halo(p,.38*foe.size,body)
	for s in [-1.,1.]:
		ink.bead(p+frame*Vector3(s*.051,.029,-.214),.021*foe.size,PEARL)
		var lift:=sin(time*(10. if breed==Foe.BAT else 16. if breed==Foe.SCARAB else 7.)+foe.index)*.14
		var root:=p+frame*Vector3(s*.062,.025,-.055)
		var elbow:=p+frame*Vector3(s*.239,.085+lift*.54,-.10)
		var tip:=p+frame*Vector3(s*(.34 if breed==Foe.SCARAB else .45),lift,.04)
		if breed==Foe.BAT:
			var notch:=p+frame*Vector3(s*.24,-.03,.092)
			ink.wing(root,elbow,notch,body)
			ink.wing(elbow,tip,notch,DUSK)
			ink.wing(root,notch,p+frame*Vector3(s*.12,-.06,.18),DUSK)
			ink.wing(p+frame*Vector3(s*.022,.054,-.16),p+frame*Vector3(s*.083,.18,-.14),p+frame*Vector3(s*.083,.022,-.12),accent)
		elif breed==Foe.SCARAB:
			var back:=p+frame*Vector3(s*.17,lift*.7,.18)
			ink.wing(root,tip,back,accent)
			ink.wing(root,elbow,tip,PEARL)
			ink.jewel(p+frame*Vector3(s*.058,.052,.015),Vector3(.07,.067,.16),BRASS,frame)
		else:
			ink.wing(root,elbow,tip,body)
			for j in 3:
				var end:=p+frame*Vector3(s*(.42-.07*j),lift-.04,.14+.047*j)
				ink.wing(root,tip,end,WIND if j==1 else body)
				tip=end
			ink.wing(root,p+frame*Vector3(s*.04,.035,-.23),p+frame*Vector3(0,0,-.32),BRASS)
		ink.line(root,elbow,.012*foe.size,accent)
		ink.line(elbow,tip,.008*foe.size,accent)
