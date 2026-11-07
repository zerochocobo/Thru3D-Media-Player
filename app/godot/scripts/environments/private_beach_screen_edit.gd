extends RefCounted
## UI edits in a frozen horizontal viewer frame; the host accepts world-space
## parameters only after Apply. No geometry is changed while a slider is held.
const KEYS := ["width","center_x","center_z","yaw_degrees","pitch_degrees","bottom_clearance","curve","curve_radius"]
var frame := Transform3D.IDENTITY
var values := {}

static func parameters(source: Dictionary) -> Dictionary:
	var result := {}
	for key in KEYS:
		if source.has(key): result[key]=source[key]
	return result

func begin(source: Dictionary,head: Transform3D) -> void:
	var heading := atan2(head.basis.z.x,head.basis.z.z)
	frame=Transform3D(Basis(Vector3.UP,heading),Vector3(head.origin.x,0,head.origin.z))
	reset(source)

func reset(source: Dictionary) -> void:
	var relative := frame.affine_inverse()*Vector3(float(source.center_x),0,float(source.center_z))
	values={"width":float(source.width),"sideways":relative.x,"distance":-relative.z,
		"rotation":wrapf(float(source.yaw_degrees)-rad_to_deg(atan2(frame.basis.z.x,frame.basis.z.z)),-180,180),"tilt":float(source.pitch_degrees),"bottom_clearance":float(source.get("bottom_clearance",.45))}

func candidate() -> Dictionary:
	var center := frame*Vector3(float(values.sideways),0,-float(values.distance))
	return {"width":float(values.width),"center_x":center.x,"center_z":center.z,"bottom_clearance":float(values.get("bottom_clearance",.45)),
		"yaw_degrees":wrapf(float(values.rotation)+rad_to_deg(atan2(frame.basis.z.x,frame.basis.z.z)),-180,180),"pitch_degrees":float(values.tilt)}
