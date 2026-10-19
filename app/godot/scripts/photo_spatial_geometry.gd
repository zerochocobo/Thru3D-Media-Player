extends RefCounted
## Bounded, single-image depth scene. All image work and immutable vertex arrays are prepared off
## the render thread. The tracked XR cameras render the resulting geometry without further AI.
const MAX_EDGE := 2048
const MAX_PIXELS := 3 * 1024 * 1024
const GRID := 192
const EDGE_JUMP := 0.16
const MAX_TRIANGLES := 100000
const MAX_RELIEF_METRES := 0.30
const RELIEF_SHAPE_GAIN := 1.25
const BORDER_BAND := 0.08
const HEAD_ENVELOPE_METRES := 0.25

static func prepare(source: Image, depth: Image, rect: Vector4, reference: Vector3, size: Vector2, native_pair: bool = false,
	strength: float = 1.0, fill_enabled: bool = true, eye_separation: float = 0.064) -> Dictionary:
	if source == null or depth == null or source.is_empty() or depth.is_empty() or not reference.is_finite() \
		or reference.z < 0.15 or not size.is_finite() or minf(size.x,size.y) <= 0.0 or not is_finite(strength) or strength<0 or strength>2 \
		or not rect.is_finite() or rect.x<0 or rect.y<0 or rect.z<=0 or rect.w<=0 or rect.x+rect.z>1.000001 or rect.y+rect.w>1.000001 \
		or not is_finite(eye_separation) or eye_separation<0.045 or eye_separation>0.085: return {}
	var color: Image = source.get_region(Rect2i(0,0,source.get_width()/2,source.get_height())) if native_pair else source.duplicate()
	var factor := minf(1.0,minf(float(MAX_EDGE)/maxi(color.get_width(),color.get_height()),sqrt(float(MAX_PIXELS)/(color.get_width()*color.get_height()))))
	color.resize(maxi(1,int(color.get_width()*factor)),maxi(1,int(color.get_height()*factor)),Image.INTERPOLATE_LANCZOS)
	color.convert(Image.FORMAT_RGBA8); color.clear_mipmaps()
	var map: Image = depth.duplicate(); map.clear_mipmaps(); map.convert(Image.FORMAT_RF)
	# Reuse photo_limit_gradient's foreground-safe rule, with a physical head/eye envelope.
	# Static SBS pixel shifts and their resolution-dependent cap do not define scene relief.
	# Keep the mesh connected so
	# nearby background stretches through a reveal, instead of cutting holes and painting a
	# separate low-resolution background. The original full-colour photograph stays the texture.
	# The normalized depth curve has one dimensionless shape. Its metre-scale amplitude is
	# defined solely by displayed short edge and reference distance below, not source pixels
	# or the original conversion strength. This remains relative-depth geometry.
	var span:=RELIEF_SHAPE_GAIN*strength
	var relief:=relief_limit(reference,size)
	# Bound d(z/(distance-z))/d(depth) for the compressed depth function. The old unbounded
	# gain excessively expanded foreground into the lower background during gradient fill.
	var slope:=reference.z*relief*span/pow(reference.z-relief,2)
	var offset:=minf(reference.z*0.25,HEAD_ENVELOPE_METRES)+eye_separation*0.5
	var half_columns:=2.0*offset*slope/size.x*rect.z*map.get_width()
	var half_rows:=2.0*offset*slope/size.y*rect.w*map.get_height()
	if fill_enabled: map=limit_gradient(map,rect,half_columns,half_rows)
	# Texture resize rounding must not change the geometry's topology or sampled UVs.
	var aspect := size.x/size.y
	var cols := GRID if aspect >= 1.0 else maxi(24,roundi(GRID*aspect))
	var rows := GRID if aspect < 1.0 else maxi(24,roundi(GRID/aspect))
	var data := {"vertices":PackedVector3Array(),"uv":PackedVector2Array()}
	var config := {"map":map,"rect":rect,"reference":reference,"size":size,"span":span,"fill":fill_enabled}
	# A uniform grid shares every interior edge exactly. Independent 4x cell refinement
	# left T-junctions against coarse neighbours, opening hairline cracks around real leaves.
	# 192x192 is at most 73,728 triangles and needs no per-frame topology repair.
	for y in rows:
		for x in cols:
			var a := Vector2(float(x)/cols,float(y)/rows)
			var b := Vector2(float(x+1)/cols,float(y+1)/rows)
			triangle(data,a,Vector2(b.x,a.y),b,config)
			triangle(data,a,b,Vector2(a.x,b.y),config)
	if data.vertices.is_empty(): return {}
	color.generate_mipmaps()
	return {"color":color,"vertices":data.vertices,"uv":data.uv,
		"reference":reference,"size":size,"span":config.span,"triangles":data.vertices.size()/3,
		"texture_bytes":color.get_data_size(),"native_pair":native_pair,"strength":strength,
		"gradient_half_cells":Vector2(half_columns,half_rows),"fill":fill_enabled,"relief_limit_m":relief}

static func limit_gradient(map: Image, rect: Vector4, half_columns: float, half_rows: float = 0.0) -> Image:
	# O(N) max-plus distance transform of native/rvm/photo_depth.h::photo_limit_gradient.
	# Each scan computes max(input[j] - 0.9/half * abs(i-j)). The native reference enumerates
	# the same neighbours. Host parity tests compare the actual C++ and GDScript outputs.
	if half_columns<=0 and half_rows<=0: return map.duplicate()
	var w:=map.get_width(); var h:=map.get_height()
	var x0:=clampi(roundi(rect.x*w),0,w-1); var y0:=clampi(roundi(rect.y*h),0,h-1)
	var cw:=clampi(roundi(rect.z*w),1,w-x0); var ch:=clampi(roundi(rect.w*h),1,h-y0)
	var values:=map.get_data().to_float32_array()
	for i in values.size(): values[i]=clampf(values[i],0,1) if is_finite(values[i]) else 0.35
	if half_columns>0:
		var slope:=0.9/half_columns
		for y in range(y0,y0+ch):
			for x in range(x0+1,x0+cw): values[y*w+x]=maxf(values[y*w+x],values[y*w+x-1]-slope)
			for x in range(x0+cw-2,x0-1,-1): values[y*w+x]=maxf(values[y*w+x],values[y*w+x+1]-slope)
	if half_rows>0:
		var slope:=0.9/half_rows
		for x in range(x0,x0+cw):
			for y in range(y0+1,y0+ch): values[y*w+x]=maxf(values[y*w+x],values[(y-1)*w+x]-slope)
			for y in range(y0+ch-2,y0-1,-1): values[y*w+x]=maxf(values[y*w+x],values[(y+1)*w+x]-slope)
	for y in h:
		for x in w:
			if x<x0 or x>=x0+cw or y<y0 or y>=y0+ch: values[y*w+x]=values[clampi(y,y0,y0+ch-1)*w+clampi(x,x0,x0+cw-1)]
	return Image.create_from_data(w,h,false,Image.FORMAT_RF,values.to_byte_array())

static func sample(map: Image, uv: Vector2, rect: Vector4) -> float:
	var p := Vector2(rect.x,rect.y)+uv*Vector2(rect.z,rect.w)
	var x := clampf(p.x*(map.get_width()-1),0,map.get_width()-1)
	var y := clampf(p.y*(map.get_height()-1),0,map.get_height()-1)
	var x0 := int(x); var y0 := int(y)
	var value := lerpf(lerpf(map.get_pixel(x0,y0).r,map.get_pixel(mini(x0+1,map.get_width()-1),y0).r,x-x0),
		lerpf(map.get_pixel(x0,mini(y0+1,map.get_height()-1)).r,map.get_pixel(mini(x0+1,map.get_width()-1),mini(y0+1,map.get_height()-1)).r,x-x0),y-y0)
	return clampf(value,0,1) if is_finite(value) else 0.35

static func relief_limit(reference: Vector3, size: Vector2) -> float:
	return minf(MAX_RELIEF_METRES,minf(minf(size.x,size.y)*0.16,reference.z*0.12))

static func point(uv: Vector2, near_value: float, reference: Vector3, size: Vector2, span: float) -> Vector3:
	var edge:=minf(minf(uv.x,1.0-uv.x),minf(uv.y,1.0-uv.y))
	# Anchor every boundary vertex to the original rectangle; ease the interior relief into
	# that fixed portal instead of allowing near-valued bottom edges to bulge with the ground.
	var z:=relief_limit(reference,size)*tanh((near_value-0.35)*span)*smoothstep(0.0,BORDER_BAND,edge)
	var p := Vector2(uv.x-0.5,0.5-uv.y)*size
	# Preserve the original reference image: each vertex stays on its original camera ray.
	p = Vector2(reference.x,reference.y)+(p-Vector2(reference.x,reference.y))*(1.0-z/reference.z)
	return Vector3(p.x,p.y,z)

static func triangle(data: Dictionary, a: Vector2, b: Vector2, c: Vector2, config: Dictionary) -> void:
	var values := Vector3(sample(config.map,a,config.rect),sample(config.map,b,config.rect),sample(config.map,c,config.rect))
	# Only the desktop diagnostic can disable our foreground-safe background stretch.
	if not config.fill and maxf(values.x,maxf(values.y,values.z))-minf(values.x,minf(values.y,values.z)) > EDGE_JUMP: return
	for entry in [[a,values.x],[c,values.z],[b,values.y]]:
		data.vertices.append(point(entry[0],entry[1],config.reference,config.size,config.span))
		data.uv.append(entry[0])
