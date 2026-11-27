extends SceneTree
## Two runners on the room-facing edges of the piers between the mirror and the lancets.
const Artist := preload("res://environments/magic_cottage/botanical_mesh.gd")
const STEM := Color("#49825b")
const VEIN := Color("#c3e8a7")
const LEAF := Color("#397e68")
var artist := Artist.new()

func joint(side: float,t: float,phase: float) -> Vector3:
	var arch := PI*.5*clampf((t-.68)/.32,0.,1.)
	var x := 2.76*cos(arch)+.105*sin(t*14.+phase)
	var y := .055+3.28*minf(.68,t)+1.83*sin(arch)
	return Vector3(side*x,y,-4.56+.045*cos(t*14.+phase))

func flower(center: Vector3) -> void:
	for petal in 7:
		var a:=petal*TAU/7.
		var d:=Vector3(cos(a),sin(a),0.)
		var crosswise:=Vector3(-d.y,d.x,0.)
		var rows:=[]; var dyes:=[]
		for j in 9:
			var t:=j/8.
			var ridge:=sin(PI*t)
			var p:=center+d*(.31*t)+Vector3.BACK*(.06*ridge+.035*t*t)
			var width:=.065*ridge+.001
			rows.append([p-crosswise*width,p+Vector3.BACK*.014*ridge,p+crosswise*width])
			dyes.append([Color("#89cab4"),Color("#fff1c4"),Color("#afdfc8")])
		artist.row_mesh(rows,dyes)
	artist.pearl(center+Vector3.BACK*.045,.044,.042,Color("#bb8644"),Color("#fff0b0"))

func ivy_leaf(base: Vector3,side: float,span: float) -> void:
	# The main rib and raised centre fold point out from the stone, toward the chair.
	var tip := Vector3(side*.86,.48,.31).normalized()*span
	var across := Vector3(-tip.y,tip.x,0.).normalized()*span
	var rows := []
	var dyes := []
	var widths := [.012,.31,.25,.40,.20,.21,.008]
	for i in widths.size():
		var t := i/6.
		var mid := base+tip*t
		var w: float = widths[i]
		var ridge := Vector3.BACK*(span*.18*sin(PI*t))
		rows.append([mid-across*w,mid+ridge,mid+across*w])
		dyes.append([LEAF,VEIN.lerp(LEAF,t*.42),Color("#72b888")])
	artist.row_mesh(rows,dyes,false,true)

func runner(side: float,phase: float,height: float) -> void:
	var path := []
	var radii := []
	var tints := []
	for i in 48:
		var t := height*i/47.
		path.append(joint(side,t,phase))
		radii.append(lerpf(.025,.006,i/47.))
		tints.append(STEM.lerp(VEIN,t*.70))
	artist.tube(path,radii,tints,7)
	for i in range(1,22):
		var t := height*i/22.
		var at := joint(side,t,phase)
		var facing := side if i%2 else -side
		var bud := at+Vector3(facing*.09,.062,.041)
		artist.stem(at,at+Vector3.UP*.055,bud,.010,.005,STEM)
		ivy_leaf(bud,facing,.24+.075*sin(i*2.4+phase))

func _initialize() -> void:
	artist.begin_specimen()
	for side: float in [-1.,1.]:
		runner(side,.53*side,1.)
		runner(side,PI+.37*side,.69)
		for t: float in [.48,.79,.93]:
			flower(joint(side,t,.53*side)+Vector3.BACK*.065)
	artist.finish_specimen()
	var result := ResourceSaver.save(artist.mesh,"res://environments/magic_cottage/wall_ivy.res",ResourceSaver.FLAG_COMPRESS)
	artist.free()
	quit(result)
