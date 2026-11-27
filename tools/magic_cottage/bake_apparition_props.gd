extends SceneTree
## Original folded silk moth, pierced processional lantern and the visitor's hand.
const Artist := preload("res://environments/magic_cottage/botanical_mesh.gd")
const HONEY := Color("#f2ba58")
const BRASS := Color("#a87947")
const NIGHT := Color("#49383b")
const IVORY := Color("#fff1b8")
var art:=Artist.new()

func ellipsoid(p: Vector3,scale_xyz: Vector3,tint: Color) -> void:
	var rows: Array=[]
	var dyes: Array=[]
	for k in 9:
		var lat:=PI*(k/8.-.5)
		var row:=PackedVector3Array()
		var colors:=PackedColorArray()
		for j in 13:
			var angle:=TAU*j/12.
			row.append(p+scale_xyz*Vector3(maxf(.005,cos(lat))*cos(angle),sin(lat),maxf(.005,cos(lat))*sin(angle)))
			colors.append(tint.darkened(.12*(1.-sin(lat))))
		rows.append(row)
		dyes.append(colors)
	art.row_mesh(rows,dyes,true)

func silk(side: float,upper: bool) -> void:
	var rows: Array=[]
	var dyes: Array=[]
	for i in 17:
		var t:=i/16.
		var span:=(.173 if upper else .114)*t
		var chord:=(.059 if upper else .048)*pow(maxf(.015,sin(PI*t)),.70)
		var z:=(-.085*t+.014*sin(PI*t)) if upper else .074+.010*t
		var row:=PackedVector3Array()
		var colors:=PackedColorArray()
		for k in 9:
			var u:=k/8.
			row.append(Vector3(side*(.012+span),.028*t+.021*sin(PI*t)*sin(PI*u),z+(2.*u-1.)*chord))
			var dye:=HONEY.lerp(IVORY,t*.45)
			if k==0 or k==8 or i>=15: dye=BRASS
			if Vector2((t-.66)*1.65,u-.53).length()<.16: dye=NIGHT if u<.62 else IVORY
			colors.append(dye)
		rows.append(row)
		dyes.append(colors)
	art.hover=1.
	art.row_mesh(rows,dyes)
	art.hover=0.

func moth() -> void:
	ellipsoid(Vector3.ZERO,Vector3(.020,.021,.076),BRASS)
	ellipsoid(Vector3(0,.01,-.069),Vector3(.023,.022,.022),IVORY)
	for side: float in [-1.,1.]:
		silk(side,true)
		silk(side,false)
		art.stem(Vector3(0,.014,-.079),Vector3(.036*side,.05,-.093),Vector3(.039*side,.052,-.127),.0037,.0015,BRASS)

func lantern() -> void:
	var profile: Array=[Vector3(.018,-.24,0),Vector3(.13,-.17,0),Vector3(.137,-.15,0),
		Vector3(.137,.13,0),Vector3(.153,.145,0),Vector3(.075,.218,0),Vector3(.013,.255,0)]
	var dyes: Array=[BRASS,BRASS,IVORY,HONEY,BRASS,BRASS,HONEY]
	art.vessel(Vector3.ZERO,profile,dyes,0,6)
	for i in 6:
		var d:=art.radial(TAU*i/6.)
		art.stem(d*.137+Vector3.DOWN*.16,d*.141,d*.137+Vector3.UP*.14,.009,.009,NIGHT)
		art.stem(d*.14+Vector3.DOWN*.095,d*.145+art.radial(TAU*i/6.+.5)*.007,d*.14+Vector3.UP*.08,.004,.004,BRASS)
	var loop: Array=[]
	var widths: Array=[]
	var inks: Array=[]
	for i in 17:
		var a:=TAU*i/16.
		loop.append(Vector3(cos(a)*.049,.302+.057*sin(a),0))
		widths.append(.006)
		inks.append(BRASS)
	art.tube(loop,widths,inks,6)
	art.stem(Vector3.DOWN*.23,Vector3.DOWN*.28,Vector3.DOWN*.34,.012,.007,BRASS)
	ellipsoid(Vector3.DOWN*.35,Vector3(.025,.041,.025),HONEY)

func giant_hand() -> void:
	var skin:=Color("#94716a")
	ellipsoid(Vector3(.54,.25,-.20),Vector3(.25,.43,.29),skin.darkened(.15))
	for i in 4:
		var root:=Vector3(.43,.61-i*.20,-.17)
		var angle:=i*.44
		var lengths: Array=[.37,.51,.46,.32]
		var end:=Vector3(.46-float(lengths[i]),.55-i*.22,.37-.025*i)
		var joint:=Vector3(.25,.65-i*.21,.18)
		var points: Array=[]
		var widths: Array=[]
		var inks: Array=[]
		for j in 17:
			var t:=j/16.
			points.append(root.bezier_interpolate(joint+Vector3(.10,.09,0),end+Vector3(-.07,.13+.03*sin(angle),.05),end,t))
			widths.append(.091*(1.-.49*t)+.014*pow(sin(t*TAU),2.))
			inks.append(skin.lerp(Color("#c59e82"),t*.66))
		art.tube(points,widths,inks,9)
		ellipsoid(end,Vector3(.053,.080,.035),Color("#d9bd99"))
	art.stem(Vector3(.47,-.01,-.13),Vector3(.28,-.30,.12),Vector3(.16,-.28,.25),.115,.070,skin)

func _initialize() -> void:
	var library:=MeshLibrary.new()
	for i in 3:
		art.begin_specimen()
		match i:
			0: moth()
			1: lantern()
			2: giant_hand()
		art.finish_specimen()
		library.create_item(i)
		library.set_item_name(i,["Silk moth","Processional lantern","Window visitor"][i])
		library.set_item_mesh(i,art.mesh)
	var err:=ResourceSaver.save(library,"res://environments/magic_cottage/apparition_props.res",ResourceSaver.FLAG_COMPRESS)
	art.free()
	quit(err)
