extends "botanical_mesh.gd"
## Cabinet specimens. Each has its own construction, pigments and mature feature.
const JADE := Color("#386653")
const LEAF := Color("#70916a")
const INK := Color("#324a52")
const IVORY := Color("#eee3bd")
const GOLD := Color("#d5a052")
const WOOD := Color("#755846")
const PALETTE := [
	Color("#e7e9db"),Color("#8cbdab"),Color("#af91d6"),Color("#db8064"),Color("#e6bf74"),
	Color("#9adace"),Color("#f7bc64"),Color("#acd9f1"),Color("#ebc1db"),Color("#fbd698")]
var full := false

func build(id: int, stage: int) -> void:
	var forms: MeshLibrary = load("res://environments/magic_cottage/flora/species-%02d.res"%id)
	mesh=forms.get_item_mesh(stage)

func sculpt(id: int, stage: int) -> void:
	begin_specimen()
	full=stage==2
	if stage==0:
		var d:=radial(.62*id)
		var tip:=d*.019+Vector3.UP*(.068+.004*(id%4))
		stem(Vector3.ZERO,Vector3.UP*.046,tip,.0055,.003,JADE)
		blade(tip,d,.038,.018,.011,.013,JADE,LEAF)
		blade(tip,-d,.026,.012,.006,.009,JADE,LEAF.lerp(PALETTE[id],.28))
	else:
		match id:
			0: moonbells()
			1: fiddleheads()
			2: iris()
			3: toadstools()
			4: lunar_vine()
			5: tidal_rosette()
			6: lantern_husks()
			7: frost_orchid()
			8: water_lily()
			9: candle_tree()
	finish_specimen()

func foliage(count: int,reach: float,rise: float,width: float,c1: Color,c2: Color) -> void:
	for i in count:
		var d:=radial(i*2.400+.37)
		blade(Vector3.ZERO,d,reach*(.83+.17*cos(i*1.4)),rise*(.82+.18*sin(i*2.)),rise*.30,width,c1,c2,.16,.008*cos(i))

func moonbells() -> void:
	foliage(6 if full else 3,.173,.234 if full else .125,.051,JADE,LEAF)
	for i in (3 if full else 1):
		var d:=radial(i*2.28+.66)
		var height:=.445-.069*i if full else .23
		var path: Array=[]
		var widths: Array=[]
		var dyes: Array=[]
		for k in 12:
			var t:=k/11.
			path.append(d*(.147*t*t)+Vector3.UP*(height*(1.68*t-.71*t*t*t)))
			widths.append(.007-.004*t)
			dyes.append(JADE.lerp(LEAF,t))
		tube(path,widths,dyes)
		for j in (5 if full else 2):
			var at: Vector3=path[6+j]
			var side:=radial(i*2.28+(.85 if j%2 else -.85))
			var bell:=at+side*.042+Vector3.DOWN*.029
			stem(at,at+side*.035+Vector3.UP*.012,bell,.003,.002,LEAF)
			if not full:
				pearl(bell,.011,.020,LEAF,IVORY)
				continue
			vessel(bell,[Vector3(.003,0,0),Vector3(.018,-.009,0),Vector3(.024,-.026,.001),Vector3(.021,-.039,.002),Vector3(.029,-.048,.006),Vector3(.023,-.046,.005),Vector3(.010,-.026,0)],
				[LEAF,IVORY,Color("#f2e9d0"),IVORY,Color("#fff1d3"),Color("#c9b794"),Color("#9b8c69")],6,30)
			glow=.34
			pearl(bell+Vector3.DOWN*.046,.005,.010,GOLD,IVORY)
			glow=0.

func fiddleheads() -> void:
	var count:=7 if full else 3
	for i in count:
		var d:=radial(i*2.40)
		var side:=radial(i*2.40+PI*.5)
		var length:=.215+.055*cos(i*1.8) if full else .101
		var h:=.34+.05*sin(i*1.4) if full else .18
		var spine: Array=[]
		var radii: Array=[]
		var dyes: Array=[]
		for j in 16:
			var t:=j/15.
			var p:=d*length*t*t+Vector3.UP*h*(1.78*t-.88*t*t)
			spine.append(p)
			radii.append(.006*(1.-.74*t))
			dyes.append(Color("#607359").lerp(Color("#b4c9a9"),t))
			if j<3 or j>13: continue
			for signum: float in [-1.,1.]:
				var cross:=(side*signum*.80+d*.55).normalized()
				var size:=length*(.10+.47*sin(t*PI))
				blade(p,cross,size,.018+.015*(1.-t),.018,size*.19,JADE,Color("#92bfa9"),.22)
		tube(spine,radii,dyes)
		var coil: Array=[]
		var rr: Array=[]
		var cc: Array=[]
		for j in 23:
			var t:=j/22.
			var a:=t*TAU*1.22
			var radius:=(.027 if full else .032)*(1.-.82*t)
			coil.append(spine[-1]+d*radius*sin(a)+Vector3.UP*(.028-radius*cos(a)))
			rr.append(.0045-.002*t)
			cc.append(LEAF.lerp(IVORY,t*.65))
		tube(coil,rr,cc)

func iris() -> void:
	foliage(8 if full else 4,.114,.30 if full else .17,.016,INK,Color("#82a78b"))
	for i in (2 if full else 1):
		var p:=Vector3(.048-.098*i,.437-.125*i,-.014+.053*i) if full else Vector3(.025,.225,0)
		stem(Vector3.ZERO,Vector3(-.055,.24,0),p,.007,.005,JADE)
		if not full:
			pearl(p,.014,.040,JADE,Color("#8574a1"))
			continue
		for j in 3:
			var d:=radial(.31+j*TAU/3.+i*.7)
			blade(p,d,.112,-.056,.058,.046,Color("#775298"),Color("#9c88b9"),.44)
			blade(p+Vector3.UP*.006,d,.073,.007,.044,.009,GOLD,Color("#f5cf7d"))
			blade(p,radial(.91+j*TAU/3.+i*.7),.050,.084,.047,.035,Color("#65548f"),Color("#c7aed8"),.28)
		glow=.72
		hover=.60
		for j in 3:
			pearl(p+radial(j*2.1)*.033+Vector3.UP*(.10+j*.008),.004,.006,GOLD,IVORY)
		hover=0.
		glow=0.

func toadstools() -> void:
	foliage(6,.125,.037,.027,Color("#435c40"),Color("#82915d"))
	for i in (4 if full else 2):
		var d:=radial(i*2.4)
		var h: float=[.335,.222,.145,.097][i] if full else .097-.026*i
		var rad:=h*.37
		var at:=d*(.040+.023*i)+Vector3.UP*h
		stem(d*(.024*i),at*.4-d*.065,at,.016+h*.025,.012+h*.020,Color("#d3bd90"))
		vessel(at,[Vector3(.010,-rad*.06,0),Vector3(rad*.58,-rad*.12,0),Vector3(rad,-rad*.01,.003),Vector3(rad*.96,rad*.19,.002),Vector3(rad*.64,rad*.55,0),Vector3(rad*.28,rad*.73,0),Vector3(.001,rad*.76,0)],
			[Color("#a78062"),IVORY,Color("#e7bc89"),Color("#ad5649"),Color("#a34841"),Color("#a95248"),Color("#b5604e")],8,40)
		if not full: continue
		for j in 15:
			var angle:=j*2.40
			var ratio:=.32+.52*fposmod(j*.618,1.)
			var actual:=ratio/(1.-.055*cos(angle*8.))
			var hcap:=lerpf(.73,.55,clampf((actual-.28)/.36,0.,1.))
			if actual>.64: hcap=lerpf(.55,.19,clampf((actual-.64)/.32,0.,1.))
			pearl(at+radial(angle)*rad*ratio+Vector3.UP*(rad*hcap+.002),rad*(.048+.015*(j%3)),.004,Color("#c59f7e"),IVORY)
		glow=.5
		for j in 14:
			var f:=radial(j*TAU/14.)
			stem(at+f*rad*.17,at+f*rad*.57-Vector3.UP*rad*.14,at+f*rad*.91-Vector3.UP*.001,.002,.001,Color("#d9b780"))
		glow=0.

func lunar_vine() -> void:
	foliage(5,.130,.090,.043,JADE,Color("#91a784"))
	var height:=.446 if full else .244
	for i in 2:
		var path: Array=[]
		var radius: Array=[]
		var col: Array=[]
		for j in 32:
			var t:=j/31.
			var a:=i*PI+t*TAU*(1.32 if full else .87)
			var p:=radial(a)*sin(PI*t)*.078+Vector3.UP*t*height
			path.append(p)
			radius.append(.009-.005*t)
			col.append(JADE.lerp(Color("#97865d"),t))
			if j in [6,12,18,24]:
				blade(p,radial(a),.081,.040,.018,.025,JADE,LEAF)
		tube(path,radius,col)
	var at:=Vector3.UP*height
	if not full:
		pearl(at,.018,.024,LEAF,Color("#b9aa79"))
		return
	# The tendrils cradle a crescent without ever touching its floating edge.
	for i in 2:
		var signum:=1. if i==0 else -1.
		stem(at,at+Vector3(signum*.147,-.015,0),at+Vector3(signum*.091,.115,0),.005,.001,GOLD)
	hover=1.
	glow=.75
	var path: Array=[]
	var rr: Array=[]
	var cc: Array=[]
	for j in 27:
		var t:=j/26.
		var a:float=lerpf(-2.18,2.18,t)
		path.append(at+Vector3(-.050*cos(a),.081+.064*sin(a),0))
		rr.append(.001+.016*pow(sin(PI*t),1.15))
		cc.append(GOLD.lerp(IVORY,.45))
	tube(path,rr,cc,12)
	pearl(at+Vector3(.030,.084,0),.012,.012,Color("#b6d8c7"),IVORY)
	hover=0.
	glow=0.

func tidal_rosette() -> void:
	for ring in (4 if full else 2):
		var n:=10-ring
		for j in n:
			var d:=radial(j*TAU/n+ring*.42)
			var extent:=(.195-.033*ring)*(1. if full else .59)
			var base:=Vector3.UP*ring*.019
			blade(base,d,extent,.057+.032*ring,.025,.064-ring*.009,Color("#466f6b"),Color("#a5bbac"),.06)
			blade(base+Vector3.UP*.008,d,extent*.92,.067+.032*ring,.035,.037-ring*.006,Color("#769f94"),Color("#c6b7a8"))
	if full:
		hover=1.
		glow=.36
		pearl(Vector3.UP*.256,.037,.041,Color("#507f94"),Color("#e4f4da"))
		for j in 4:
			pearl(radial(j*TAU/4.)*.058+Vector3.UP*(.212+.012*j),.008,.011,Color("#8bbec1"),IVORY)
		hover=0.
		glow=0.

func lantern_husks() -> void:
	foliage(5,.127,.14,.051,JADE,Color("#749065"))
	for i in (4 if full else 2):
		var d:=radial(.3+i*2.40)
		var at:=d*(.117+.019*i)+Vector3.UP*((.392-.046*i) if full else (.208-.040*i))
		var bend:=at*.83+Vector3.UP*.096
		stem(Vector3.ZERO,bend*.58,bend,.009,.004,Color("#5a744e"))
		stem(bend,bend+d*.038,at,.004,.0025,LEAF)
		blade(bend*.57,-d,.083,.052,.018,.028,JADE,LEAF)
		var size:=.067 if full else .03
		# Openwork calyx with five amber ribs and two cross-veins per panel.
		for j in 7:
			var arc:=radial(j*TAU/7.)
			var path: Array=[]
			var rr: Array=[]
			var cc: Array=[]
			for k in 12:
				var t:=k/11.
				path.append(at+arc*size*.72*pow(maxf(0.,sin(PI*t)),.72)*(1.24-.47*t)-Vector3.UP*size*1.85*t)
				rr.append(.0025+.001*sin(PI*t))
				cc.append(Color("#ba7144").lerp(GOLD,t))
			tube(path,rr,cc,5)
			if full:
				var adj:=radial((j+1)*TAU/7.)
				for t: float in [.35,.62]:
					var start:=at+arc*size*.72*sin(PI*t)-Vector3.UP*size*1.85*t
					var end:=at+adj*size*.73*sin(PI*(t+.12))-Vector3.UP*size*1.85*(t+.12)
					stem(start,start.lerp(end,.5)+arc*.002,end,.0011,.001,Color("#b77e49"))
		glow=.95 if full else .15
		pearl(at-Vector3.UP*size*.92,size*.33,size*.49,Color("#d67635"),Color("#ffe6a1"))
		glow=0.

func frost_orchid() -> void:
	foliage(6,.183,.100,.044,Color("#385960"),Color("#81aca3"))
	for i in (8 if full else 3):
		var d:=radial(i*2.40)
		var h:=(.24+.18*fposmod(i*.618+.19,1.))*(1. if full else .52)
		var root:=d*.027
		var top:=root+d*(.033+.019*(i%4))+Vector3.UP*h
		var shoulder:=top-(top-root).normalized()*.079
		var path: Array=[root,root.lerp(shoulder,.17),shoulder,top]
		var width:=.025+.006*(i%3)
		# Flat colour facets in cold blue, the internal seam catches the light.
		for j in 5:
			var rows: Array=[]
			var dyes: Array=[]
			var sizes: Array=[.009,width*.70,width,.0008]
			var wall:=Color("#6393ab").lerp(Color("#b6d0d5"),.5+.5*sin(j*1.94+i))
			for k in 4:
				rows.append([path[k]+radial(j*TAU/5.+i)*float(sizes[k]),path[k]+radial((j+1)*TAU/5.+i)*float(sizes[k])])
				var ink: Color=wall.lerp(Color("#dbeafa"),k*.19)
				dyes.append([ink,ink])
			row_mesh(rows,dyes)
		if full and i%2==0:
			glow=.70
			stem(shoulder+d*width,top+d*.011,top,.002,.001,Color("#cfeef0"))
			glow=0.
	if full:
		glow=.68
		hover=.8
		var at:=Vector3.UP*.465
		for j in 6:
			var d:=radial(j*TAU/6.)
			stem(at,at+d*.022,at+d*.047,.003,.001,Color("#bfe2f1"))
			pearl(at+d*.047,.004,.004,IVORY,IVORY)
		hover=0.
		glow=0.

func water_lily() -> void:
	for i in (4 if full else 2):
		var d:=radial(i*2.4)
		var center:=d*(.067+.016*i)+Vector3.UP*(.032+.017*i)
		stem(Vector3.ZERO,center*.62,center,.005,.003,JADE)
		var rows: Array=[]
		var dyes: Array=[]
		for r in 7:
			var ring:=PackedVector3Array()
			var tint:=PackedColorArray()
			var t:=maxf(.018,r/6.)
			for j in 33:
				var a:=i+lerpf(.22,TAU-.22,j/32.)
				ring.append(center+radial(a)*t*(.074+.011*i)*(1.+.11*cos(a-i))+Vector3.UP*(.015*t*t+.003*t*sin(7*a)))
				tint.append(JADE.lerp(Color("#90a57e"),t*.65+.12*cos(8*a)))
			rows.append(ring)
			dyes.append(tint)
		row_mesh(rows,dyes)
	var at:=Vector3(0,.146 if full else .093,0)
	stem(Vector3.ZERO,at*.56+Vector3(.021,0,0),at,.008,.006,JADE)
	if not full:
		pearl(at,.024,.042,LEAF,Color("#c28eab"))
		return
	for ring in 3:
		for j in 9-ring:
			var d:=radial(j*TAU/(9-ring)+ring*.45)
			blade(at+Vector3.UP*ring*.012,d,.114-ring*.027,.034+.023*ring,.017,.033-.004*ring,Color("#b9829f"),Color("#f1d9d2"),.08)
	glow=.50
	pearl(at+Vector3.UP*.072,.023,.014,GOLD,IVORY)
	hover=1.
	for i in 6:
		var a:=i*TAU/6.
		pearl(at+radial(a)*.069+Vector3.UP*(.106+.016*sin(a)),.005,.008,Color("#dbb480"),IVORY)
	hover=0.
	glow=0.

func candle_tree() -> void:
	var trunk:=Vector3(.028,.299 if full else .182,0)
	stem(Vector3.ZERO,Vector3(-.047,.161,.022),trunk,.029,.009,WOOD)
	for i in 6:
		var d:=radial(i*2.4+.20)
		stem(Vector3.UP*.038,d*.042,d*(.082+.014*(i%2)),.013,.001,WOOD)
	for i in (7 if full else 3):
		var d:=radial(i*2.4)
		var base:=trunk*(.35+(i%3)*.16)
		var fork:=base+d*(.079+.015*(i%3))+Vector3.UP*.069
		var top:=fork+d*.047+Vector3.UP*(.130 if full else .054)
		stem(base,fork-Vector3.UP*.035,fork,.015,.009,WOOD)
		stem(fork,top-d*.035,top,.009,.003,WOOD)
		var twig:=fork+Vector3(-d.z,0,d.x)*.055+Vector3.UP*.066
		stem(fork,fork.lerp(twig,.32)-Vector3.UP*.012,twig,.006,.002,WOOD)
		blade(twig,d,.051,.022,.013,.023,Color("#774e44"),Color("#b47f53"))
		if full:
			for j in 3:
				blade(top,radial(j*2.1+i),.022,.008,.005,.009,WOOD,GOLD)
			glow=.95
			pearl(top+Vector3.UP*.020,.012,.024,Color("#db9653"),Color("#ffebb0"))
			glow=0.
