extends MeshInstance3D
## All botanical surfaces share one draw, including luminous tissue. Distances are metres.
const BotanicalShader := preload("botanical.gdshader")
var surface: SurfaceTool
var glow := 0.
var hover := 0.

func begin_specimen() -> void:
	surface=SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	glow=0.
	hover=0.

func finish_specimen() -> void:
	var mat:=ShaderMaterial.new()
	mat.shader=BotanicalShader
	surface.set_material(mat)
	surface.index()
	mesh=surface.commit()
	surface=null

func radial(a: float) -> Vector3:
	return Vector3(cos(a),0,sin(a))

func row_mesh(rows: Array, dyes: Array, looped := false, veined := false) -> void:
	var count: int=rows[0].size()
	var normals: Array=[]
	for j in rows.size():
		var row:=PackedVector3Array()
		for i in count:
			var prev:=posmod(i-1,count-1) if looped else maxi(0,i-1)
			var next:=posmod(i+1,count-1) if looped else mini(count-1,i+1)
			var along: Vector3=rows[mini(j+1,rows.size()-1)][i]-rows[maxi(0,j-1)][i]
			var across: Vector3=rows[j][next]-rows[j][prev]
			row.append(along.cross(across).normalized())
		normals.append(row)
	for j in rows.size()-1:
		for i in count-1:
			for offset: Vector2i in [Vector2i(0,0),Vector2i(1,0),Vector2i(0,1),Vector2i(1,0),Vector2i(1,1),Vector2i(0,1)]:
				var x:=i+offset.x
				var y:=j+offset.y
				surface.set_color(dyes[y][x])
				surface.set_normal(normals[y][x])
				surface.set_uv(Vector2(glow,hover))
				surface.set_uv2(Vector2(float(x)/(count-1),float(y)/(rows.size()-1)) if veined else Vector2(-1.,0.))
				surface.add_vertex(rows[y][x])

func tube(path: Array, radii: Array, colors: Array, sides := 7) -> void:
	var rows: Array=[]
	var dyes: Array=[]
	var right:=Vector3.RIGHT
	for j in path.size():
		var tangent: Vector3=(path[mini(j+1,path.size()-1)]-path[maxi(j-1,0)]).normalized()
		right-=tangent*right.dot(tangent)
		if right.length_squared()<.0001: right=tangent.cross(Vector3.UP if absf(tangent.y)<.9 else Vector3.FORWARD)
		right=right.normalized()
		var flank:=right.cross(tangent)
		var ring:=PackedVector3Array()
		var tint:=PackedColorArray()
		for k in sides+1:
			var angle:=TAU*k/sides
			ring.append(path[j]+(right*cos(angle)+flank*sin(angle))*float(radii[j]))
			tint.append(colors[j])
		rows.append(ring)
		dyes.append(tint)
	row_mesh(rows,dyes,true)

func stem(a: Vector3, b: Vector3, c: Vector3, r: float, tip: float, dye: Color) -> void:
	var points: Array=[]
	var radii: Array=[]
	var colors: Array=[]
	for j in 8:
		var t:=j/7.
		points.append(a.bezier_interpolate(a.lerp(b,.7),c.lerp(b,.7),c,t))
		radii.append(lerpf(r,tip,t))
		colors.append(dye.lerp(dye.lightened(.18),t))
	tube(points,radii,colors)

# A cambered leaf or petal with a central vein, rolled edges, a tapered heel and a drawn-out tip.
func blade(base: Vector3,d: Vector3,reach: float,rise: float,bow: float,width: float,base_col: Color,tip_col: Color,ruffle:=0.,twist:=0.) -> void:
	var rows: Array=[]
	var dyes: Array=[]
	var side:=Vector3(d.z,0,-d.x)
	for j in 13:
		var t:=j/12.
		var arc:=sin(PI*t)
		var w:=maxf(.0008,width*pow(arc,.78)*(.66+.48*t))
		var mid:=base+d*(reach*t)+Vector3.UP*(rise*t+bow*arc)+side*(twist*.42*t*t)
		var row:=PackedVector3Array()
		var tint:=PackedColorArray()
		for s: float in [-1.,-.74,-.28,0.,.28,.74,1.]:
			var rib:=w*(.31*(1.-absf(s))+.18*s*s)
			var edge_wave:=ruffle*w*pow(absf(s),2.)*sin(12.*t+s*1.9)
			row.append(mid+side*(s*w)+Vector3.UP*(rib+edge_wave+s*twist*t))
			var color:=base_col.lerp(tip_col,t*.82+.10*absf(s))
			if is_zero_approx(s): color=color.lerp(tip_col.lightened(.27),.48)
			tint.append(color)
		rows.append(row)
		dyes.append(tint)
	row_mesh(rows,dyes,false,true)

# Each profile row is radius, height, and scallop amplitude in metres.
func vessel(origin: Vector3, profile: Array, colors: Array, flutes: int, sides:=32) -> void:
	var rows: Array=[]
	var dyes: Array=[]
	for j in profile.size():
		var ring:=PackedVector3Array()
		var tint:=PackedColorArray()
		var p: Vector3=profile[j]
		for k in sides+1:
			var a:=k*TAU/sides
			var rib:=cos(a*flutes)
			ring.append(origin+radial(a)*p.x*(1.-.055*rib)+Vector3.UP*(p.y+p.z*rib))
			tint.append(Color(colors[j]).darkened(.075*(.5+.5*rib)))
		rows.append(ring)
		dyes.append(tint)
	row_mesh(rows,dyes,true)

func pearl(at: Vector3, radius: float, tall: float, bottom: Color, top: Color) -> void:
	var profile: Array=[]
	var dye: Array=[]
	for j in 9:
		var a: float=-PI*.5+PI*j/8.
		profile.append(Vector3(maxf(.0002,radius*cos(a)),tall*sin(a),0))
		dye.append(bottom.lerp(top,j/8.))
	vessel(at,profile,dye,0,14)
