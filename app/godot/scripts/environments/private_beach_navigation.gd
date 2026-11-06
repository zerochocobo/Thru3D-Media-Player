extends RefCounted
## Same triangle diagonal and shoreline data as tools/beach/beach_layout.py.
## Floor/coast support; body obstacles are handled by the inherited locomotion.
const CinemaMotion := preload("res://scripts/environments/cinema_locomotion.gd")
var grid: Dictionary
var config: Dictionary
var _nx: int
var _nz: int
var _x_min: float
var _z_min: float
var _inverse_step: float
var _heights: PackedFloat64Array
var _walk_min: Vector2
var _walk_max: Vector2
var _clearance: float
var _coast: PackedVector2Array
var _segments: PackedVector2Array
var _inverse_lengths: PackedFloat64Array
var _highest_uprush := -INF

func _init(description: Dictionary, settings: Dictionary) -> void:
	grid=description.grid
	config=settings
	_nx=int(grid.nx); _nz=int(grid.nz)
	_x_min=float(grid.x_min); _z_min=float(grid.z_min); _inverse_step=1.0/float(grid.step)
	_heights=PackedFloat64Array(grid.heights)
	_walk_min=Vector2(config.walk.x_min,config.walk.z_min)
	_walk_max=Vector2(config.walk.x_max,config.walk.z_max)
	_clearance=float(config.walk.uprush_clearance)
	for value in config.shore.points:
		var point := Vector2(value[0],value[1]+config.shore.uprush_offset)
		_coast.append(point); _highest_uprush=maxf(_highest_uprush,point.y)
	for i in range(_coast.size()-1):
		var segment := _coast[i+1]-_coast[i]
		_segments.append(segment); _inverse_lengths.append(1.0/segment.length_squared())

func ground(x: float,z: float) -> float:
	var u := clampf((x-_x_min)*_inverse_step,0.0,_nx-1)
	var v := clampf((z-_z_min)*_inverse_step,0.0,_nz-1)
	var i := mini(int(u),_nx-2)
	var j := mini(int(v),_nz-2)
	u-=i; v-=j
	var a := j*_nx+i
	var h00 := _heights[a]; var h10 := _heights[a+1]
	var h01 := _heights[a+_nx]; var h11 := _heights[a+_nx+1]
	if u+v<=1: return h00+u*(h10-h00)+v*(h01-h00)
	return h11+(1-u)*(h01-h11)+(1-v)*(h10-h11)

func is_walkable(point: Vector3,radius := CinemaMotion.BODY_RADIUS) -> bool:
	if not point.is_finite() or radius<0: return false
	if point.x<_walk_min.x+radius or point.x>_walk_max.x-radius: return false
	if point.z<_walk_min.y+radius or point.z>_walk_max.y-radius: return false
	var required := _clearance+radius
	# A conservative lower bound: every shoreline point has z <= highest_uprush.
	# This removes most repeated distance queries without relaxing the boundary.
	if point.z>=_highest_uprush+required: return true
	var p := Vector2(point.x,point.z)
	var nearest := INF
	for i in range(_segments.size()):
		var a := _coast[i]; var segment := _segments[i]
		if point.x>=a.x and point.x<=_coast[i+1].x and segment.cross(p-a)<0: return false
		var t := clampf((p-a).dot(segment)*_inverse_lengths[i],0,1)
		nearest=minf(nearest,p.distance_squared_to(a+segment*t))
	return nearest>=required*required
