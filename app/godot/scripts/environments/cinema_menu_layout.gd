extends RefCounted
## Placement policy for the existing PlayerMenu. The transport depends only on
## the physical screen; transient tools get one world pose when explicitly opened.

const TRANSPORT_SCALE := 16.0
const TRANSPORT_TOP := 0.255
const SCREEN_GAP := 0.15
const SCREEN_FORWARD := 0.10
const RAY_DISTANCE := 100.0
const POPUP_DISTANCE := 1.4

static func transport_pose(screen: Dictionary) -> Transform3D:
	var centre := Vector3(float(screen.position[0]), float(screen.position[1]), float(screen.position[2]))
	var heading := Basis(Vector3.UP, float(screen.get("yaw", 0.0)))
	var offset := Vector3(0.0, -float(screen.height) * 0.5 - SCREEN_GAP - TRANSPORT_TOP * TRANSPORT_SCALE, SCREEN_FORWARD)
	return Transform3D(heading.scaled(Vector3.ONE * TRANSPORT_SCALE), centre + heading * offset)

static func popup_centre(head: Transform3D) -> Transform3D:
	var forward := -head.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001: forward = Vector3.FORWARD
	forward = forward.normalized()
	var heading := Basis(Vector3.UP, atan2(-forward.x, -forward.z))
	return Transform3D(heading, head.origin + forward * POPUP_DISTANCE + Vector3.DOWN * 0.05)

static func place_popup(centre: Transform3D, bounds: Rect2) -> Transform3D:
	return centre * Transform3D(Basis.IDENTITY, -Vector3(bounds.get_center().x, bounds.get_center().y, 0))
