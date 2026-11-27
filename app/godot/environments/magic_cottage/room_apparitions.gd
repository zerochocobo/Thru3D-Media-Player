extends "spell_brush.gd"
## The room's eight-second apparitions. Positions and motion stay relative to the seated hall.
const Sound := preload("spell_audio.gd")
const GOLD := Color("#eabc68")
const WHITE := Color("#fff2cf")
const ICE := Color("#b6e7f7")
const TEAL := Color("#63d5c0")
const PURPLE := Color("#9a85d5")
const BROTH := Vector3(3.96,1.09,-.94)
const TONES := [Color("#96b6e6"),Color("#76545b"),Color("#b881b9"),Color("#6ddfc1"),Color("#ffce83"),
	Color("#a9def8"),Color("#ffd093"),Color("#b5a2ed"),Color("#86d5a3"),Color("#ffd28c")]
const SECOND_SOUND := ["weightless","watcher","collapse","aurora","moths","frost","meteors","backward","ivy","lanterns"]
var art := MultiMeshInstance3D.new()
var costumes := ShaderMaterial.new()
var curtain := ShaderMaterial.new()
var curtains := Node3D.new()
var meshes: MeshLibrary
var beat := 0
var frozen := false

func _ready() -> void:
	super()
	costumes.shader=preload("apparition_props.gdshader")
	meshes=load("res://environments/magic_cottage/apparition_props.res")
	art.multimesh=MultiMesh.new()
	art.multimesh.transform_format=MultiMesh.TRANSFORM_3D
	art.multimesh.instance_count=64
	art.multimesh.custom_aabb=AABB(Vector3(-6,-1,-6),Vector3(12,8,10))
	art.material_override=costumes
	art.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(art)
	curtain.shader=preload("aurora_curtain.gdshader")
	inks.append(costumes)
	inks.append(curtain)
	var silk:=QuadMesh.new()
	silk.size=Vector2(8.3,1.35)
	silk.subdivide_width=54
	silk.subdivide_depth=6
	add_child(curtains)
	for i in 3:
		var piece:=MeshInstance3D.new()
		piece.mesh=silk
		piece.material_override=curtain
		piece.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		piece.position=Vector3(0,2.96+.21*i,-3.80+1.1*i)
		piece.rotation.z=.10*(i-1)
		curtains.add_child(piece)
	stop()

func open(id: int) -> void:
	visible=true
	beat=0
	frozen=false
	curtains.visible=id==3
	art.visible=id in [4,9]
	if art.visible:
		var style:=0 if id==4 else 1
		art.multimesh.mesh=meshes.get_item_mesh(style)
	art.multimesh.visible_instance_count=0
	begin()
	finish()

func stop() -> void:
	visible=false
	art.multimesh.visible_instance_count=0
	begin()
	finish()

func prop(index: int,position: Vector3,axes: Basis,scale_xyz: Vector3) -> void:
	art.multimesh.set_instance_transform(index,Transform3D(axes.scaled_local(scale_xyz),position))

func step(id: int,t: float,movie: bool,sound: Sound) -> void:
	var envelope:=smoothstep(0.,1.3,t)*(1.-smoothstep(6.55,8.,t))
	# Frost has finished branching from 2.71 s until the fade, so its strokes stay as written.
	var still:=id==5 and envelope>=1. and t>2.72
	if not (still and frozen): draw(id,t,envelope,movie)
	frozen=still
	# Echoes answer from a second place as the room reaches its peak and settles.
	var cue_time:=2.7 if beat==0 else 5.8
	if beat<2 and t>=cue_time:
		var at:=Vector3(-2.8,2.65,-4.40) if beat==0 else Vector3(2.6,2.,-3.45)
		var key: String=SECOND_SOUND[id]
		if id==0 and beat==1: key="escaped"
		if id==2 and beat==1: key="fire_impact"
		if id==6: key="fire_impact"
		if id==9: key="bronze_bell"
		sound.cue(key,at,-7. if beat==0 else -9.,.78 if beat==0 else 1.12,1)
		beat+=1

func draw(id: int,t: float,envelope: float,movie: bool) -> void:
	begin()
	if art.visible: costumes.set_shader_parameter("age",t)
	match id:
		0: gravity(t,envelope)
		1: visitor(t,envelope)
		2: collapse(t,envelope,movie)
		3: curtain.set_shader_parameter("age",t)
		4: moths(t,movie)
		5: winter(t,envelope)
		6: shower(t,envelope)
		7: orrery(t,envelope,movie)
		8: pollen(t,envelope)
		9: procession(t,movie)
	finish()

func gravity(t: float,e: float) -> void:
	for i in 32:
		var a:=TAU*i/32.
		var radius:=2.4+.59*sin(7.1*i)
		var p:=Vector3(cos(a)*radius,.05+e*(.42+1.48*absf(sin(i*7.3))),-1.7+sin(a)*radius)
		var axes:=Basis(Vector3.UP,t+i)*Basis(Vector3.FORWARD,t*.65+i)
		form(PAPER,p,axes,Vector3(.17,.12,.14)*e,GOLD if i%4==0 else Color("#a58c75"))
	for i in 3:
		var radius:=fposmod(t*.67+i*1.18,3.54)
		if radius>.05: hoop(Vector3(0,.046,-1.54),Vector3.UP,radius*e,TEAL.darkened(.45))

## The watcher is only the eye at the windows and its shadow on the wall (observatory.gdshader);
## the giant hands that gripped the sills were removed after play-testing.
func visitor(_t: float,_e: float) -> void:
	pass

func collapse(t: float,e: float,movie: bool) -> void:
	var sink:=Vector3(3.49,2.03,-4.77) if movie else Vector3(0,2.35,-4.62)
	var wide:=1.15 if movie else 1.95
	for i in 20:
		var phase:=fposmod(t*(.24+.014*(i%4))+i*.049,1.)
		var a:=TAU*i/20.+phase*3.05+t*.46
		var p:=sink+Vector3(cos(a)*wide,sin(a)*.94,1.78)*(1.-phase)+Vector3(cos(a)*.46,sin(a)*.39,0)
		for j in 4:
			var b:=a-.065*(j+1)
			var tail:=sink+Vector3(cos(b)*wide,sin(b)*.94,1.78)*(1.-phase+.018*(j+1))+Vector3(cos(b)*.46,sin(b)*.39,0)
			line(p,tail,(.023-.004*j)*e,WHITE.lerp(PURPLE,j*.24))
			p=tail
	halo(sink,1.4*e,GOLD)
	if t>4.8 and t<6.4:
		var u:=(t-4.8)/1.6
		hoop(sink+Vector3.BACK*.2,Vector3.BACK,.68+u*(.65 if movie else 2.8),GOLD.darkened(u*.78))

func moths(t: float,movie: bool) -> void:
	for i in 60:
		var a:=i*2.4+t*(1.07+.07*(i%4))
		var release:=smoothstep(.026*i,1.37+.026*i,t)*(1.-smoothstep(6.+.009*i,7.85,t))
		var radius:=1.6+.039*i
		var sky:=Vector3(cos(a)*radius,2.1+.85*sin(a*1.4+i*.31),-1.73+sin(a)*1.24)
		if movie and absf(sky.x)<2.: sky.y+=1.45
		var p:=BROTH.lerp(sky,release)+Vector3.UP*.55*sin(release*PI)
		var axes:=Basis(Vector3.UP,-a+PI)*Basis(Vector3.FORWARD,.31*sin(t*4.+i))
		var size:=release*(.68+.48*absf(sin(i*3.2)))
		prop(i,p,axes,Vector3.ONE*maxf(.001,size))
		if i%4==0: halo(p,.31*size,GOLD)
	art.multimesh.visible_instance_count=60

func winter(t: float,e: float) -> void:
	for side: float in [-1.,1.]:
		for root in 5:
			var start:=Vector3(side*(3.98-.63*root),.066,-4.12+.31*root)
			var d:=Vector3(-side*.40,0.,.91).normalized()
			var lateral:=d.cross(Vector3.UP)
			var prev:=start
			for j in range(1,7):
				var growth:=smoothstep(j*.15+root*.31,j*.15+root*.31+.57,t)*e
				var p:=prev+d*.37*growth
				line(prev,p,.016*growth,ICE)
				for s: float in [-1.,1.]:
					var fork:=p+(lateral*s*.22+d*.17)*growth
					line(p,fork,.010*growth,TEAL.lerp(ICE,.55))
					line(fork,fork+d*.11*growth,.008*growth,ICE)
				prev=p
		for j in 11:
			var x:=side*(.27+j*.35)
			var h:=3.15+.98*cos(j*.135)
			var length:=(.24+.27*absf(sin(j*4.1)))*e
			var root:=Vector3(x,h,-4.49)
			var tip:=root+Vector3.DOWN*length*1.8
			for k in 4:
				var a:=TAU*k/4.
				var b:=a+PI*.5
				wing(root+Vector3(cos(a),0,sin(a))*.058*e,root+Vector3(cos(b),0,sin(b))*.058*e,tip,ICE if k%2 else TEAL)

func shower(t: float,e: float) -> void:
	for i in 27:
		var side:= -1. if i%2==0 else 1.
		var a:=Vector3(side*(2.5+1.6*absf(sin(i*2.))),3.65+.63*sin(i*1.8),-4.60)
		var b:=Vector3(side*(1.70+1.50*absf(cos(i*1.3))),.14,-2.80+.68*sin(i*2.1))
		var phase:=fposmod(t*(.34+.045*(i%4))+i*.145,1.)
		if phase<.74:
			var u:=phase/.74
			var p:=a.lerp(b,u*u)
			var tail:=a.lerp(b,maxf(0.,u*u-.19))
			line(p,tail,(.014 if i%5 else .035)*e,ICE)
			bead(p,(.032 if i%5 else .079)*e,WHITE)
			if i%5==0: halo(p,.36*e,GOLD)
		elif i%3==0:
			var u:=(phase-.74)/.26
			for j in 7:
				var angle:=TAU*j/7.
				var p:=b+Vector3(cos(angle)*u*.41,.50*sin(PI*u),sin(angle)*u*.41)
				bead(p,.031*(1.-u)*e,GOLD)

func orrery(t: float,e: float,movie: bool) -> void:
	var center:=Vector3(0,3.78,-3.83) if movie else Vector3(0,2.39,-3.67)
	var radius:=(.72 if movie else 1.49)*e
	if radius<.01: return
	for i in 3:
		var axes:=Basis(Vector3.BACK,float(i)*1.02)*Basis(Vector3.UP,t*(.58 if i%2 else -.77)+i)*Basis(Vector3.RIGHT,.52)
		var r:=radius*(1.-i*.12)
		hoop(center,axes.z,r,GOLD if i!=1 else TEAL)
		for k in 12:
			var a:=TAU*k/12.
			var d:=axes*Vector3(cos(a),sin(a),0)
			line(center+d*(r-.055*e),center+d*(r+.062*e),.010*e,WHITE)
		var a:=-t*(1.43+i*.23)+i*2.2
		var planet:=center+axes*Vector3(cos(a),sin(a),0)*r
		bead(planet,.14*e,TEAL if i==1 else GOLD)
		hoop(planet,axes.y,.19*e,IVORY_TINT)
	bead(center,.12*e,WHITE)
	halo(center,.76*e,GOLD)

const IVORY_TINT := Color("#e9d1a2")

func pollen(t: float,e: float) -> void:
	for i in 30:
		var h:=fposmod(t*.22+i*.035,1.)
		var side:= -1. if i%2 else 1.
		var p:=Vector3(side*(2.76+.54*sin(i*2.4+t))*(1.-.35*h),.28+h*3.58,-4.29+.47*cos(t*.93+i))
		bead(p,.022*e,WHITE)
		if i%3==0: halo(p,.17*e,TEAL)

func procession(t: float,movie: bool) -> void:
	var crown:=smoothstep(3.1,5.7,t)
	for i in 24:
		var a:=TAU*i/24.+.46*t
		var rise:=smoothstep(.035*i,.90+.035*i,t)*(1.-smoothstep(6.35+.018*i,7.95,t))
		var lane:=Vector3(cos(a)*3.25,1.55+.58*sin(a*2.+t),-1.63+sin(a)*1.86)
		if movie and absf(lane.x)<2.: lane.y+=1.65
		var ring:=Vector3(cos(a)*2.50,3.36+.24*cos(a*3.),-1.83+sin(a)*1.09)
		var p:=lane.lerp(ring,crown)
		p.y+=(1.-rise)*1.25
		var axes:=Basis(Vector3.UP,a)*Basis(Vector3.FORWARD,.10*sin(t*2.2+i))
		prop(i,p,axes,Vector3.ONE*maxf(.001,rise*1.35))
		halo(p,.60*rise,GOLD)
	art.multimesh.visible_instance_count=24
