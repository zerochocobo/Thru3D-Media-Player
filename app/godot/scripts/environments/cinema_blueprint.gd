class_name CinemaBlueprint
extends RefCounted
## Reproducible, metre-scaled giant-screen auditorium layout. This blueprint is the
## single source for seats, navigation and colliders; tools/cinema/build_hall.py
## reads the generated manifest and models, lights and bakes the visible hall.

const SCREEN_WIDTH := 32.0
const SCREEN_HEIGHT := SCREEN_WIDTH / 1.43
# Lowered with the steeper rake so the middle rows look near the screen centre.
const SCREEN_BOTTOM := 0.7
const SCREEN_Z := -4.0
# The screen spans almost wall to wall, like a GT laser hall; walls frame nothing.
const ROOM_HALF_WIDTH := 17.0
const ROOM_FRONT := -5.0
const ROOM_BACK := 32.4
const ROOM_HEIGHT := 26.0
const WALL_MARGIN := 0.4
const ROOM_DEPTH := ROOM_BACK - ROOM_FRONT
const ROW_COUNT := 14
const COLUMN_COUNT := 24
const FIRST_ROW_Z := 6.0
const ROW_PITCH := 1.8
# About 22 degrees: at 14 degrees (0.45 m) most rows looked 20-48 degrees up at
# the screen centre and over 35 degrees to its top (the SMPTE EG-18 discomfort
# point). 32.7 degrees once hid the rows ahead; this keeps them in lower view.
const ROW_RISER := 0.72
const STEPS_PER_ROW := 4
const STAIR_TREAD := ROW_PITCH / STEPS_PER_ROW
const STAIR_RISER := ROW_RISER / STEPS_PER_ROW
# Premium lounge chairs: roomier than a real auditorium, because VR rewards
# presence. Neighbours share one wide armrest console, as real halls do.
const SEAT_PITCH := 0.90
const SEAT_Z_OFFSET := -0.40
const SEAT_EXIT_Z_OFFSET := -1.30
# Seated eye height used in cinema sightline design (1120 mm), with the eye a head
# depth in front of the headrest: at 1.2 m and 0.37 m forward the viewer's head
# floated above and ahead of the chair.
const SEATED_EYE_HEIGHT := 1.12
const SEAT_LINE_FROM_EYE := -0.10
# Chair envelope relative to the seat line; matches tools/cinema/seat_model.py.
const SEAT_FRONT := 0.42
const SEAT_REAR := 0.38
const SEAT_BACK_TOP := 1.16
# The collider stops below the seated head band (eye - 0.1 m): the headrest above
# it is visual, and walking is already blocked by a 1 m back.
const SEAT_BACK_COLLIDER_TOP := 1.0
const SEAT_HALF_WIDTH := 0.45
const TIER_FRONT_OFFSET := -ROW_PITCH + SEAT_Z_OFFSET + SEAT_REAR
const PLATFORM_HALF_WIDTH := 11.3
const AISLE_OUTER_X := 13.7
const RAIL_X := 14.1
const CEILING_REAR_CLEARANCE := 7.5
const DEFAULT_ROW := 9
const DEFAULT_COLUMN := 12
const SOURCE_VERSION := 9

static func manifest() -> Dictionary:
	var seats: Array = []
	var walkable: Array = []
	var colliders: Array = []
	# Each deck begins at the previous chair's back, leaving the viewer's feet
	# and the entire front passage on the same level as their own chair.
	var first_edge := FIRST_ROW_Z + TIER_FRONT_OFFSET
	var stair_start := first_edge - (STEPS_PER_ROW - 1) * STAIR_TREAD
	var rear_edge := first_edge + ROW_COUNT * ROW_PITCH
	var stair_end := stair_start + ROW_COUNT * ROW_PITCH
	# Extents describe floor support; adjoining rectangles share their boundary.
	walkable.append(_floor("front", -PLATFORM_HALF_WIDTH, SCREEN_Z + 0.3,
		PLATFORM_HALF_WIDTH, first_edge, 0.0))
	for side in [-1.0, 1.0]:
		var x0 := PLATFORM_HALF_WIDTH if side > 0 else -ROOM_HALF_WIDTH + WALL_MARGIN
		var x1 := ROOM_HALF_WIDTH - WALL_MARGIN if side > 0 else -PLATFORM_HALF_WIDTH
		walkable.append(_floor("front_side_%s" % side, x0, SCREEN_Z + 0.3, x1, stair_start, 0.0))
		walkable.append(_floor("rear_side_%s" % side, x0, stair_end, x1, ROOM_BACK - WALL_MARGIN, ROW_COUNT * ROW_RISER))
	for row in range(ROW_COUNT):
		var z := FIRST_ROW_Z + row * ROW_PITCH
		var seat_z := z + SEAT_Z_OFFSET
		var level := (row + 1) * ROW_RISER
		walkable.append(_floor("row_%02d" % (row + 1), -PLATFORM_HALF_WIDTH, z + TIER_FRONT_OFFSET,
			PLATFORM_HALF_WIDTH, z + TIER_FRONT_OFFSET + ROW_PITCH, level))
		for column in range(COLUMN_COUNT):
			var x := (column - (COLUMN_COUNT - 1) * 0.5) * SEAT_PITCH
			var id := "%s%02d" % [String.chr(65 + row), column + 1]
			seats.append({"id": id, "label": id, "row": row + 1, "column": column + 1,
				"eye_position": [x, level + SEATED_EYE_HEIGHT, seat_z - SEAT_LINE_FROM_EYE], "yaw": 0.0,
				"exit_position": [x, level, z + SEAT_EXIT_Z_OFFSET]})
			# Seat backs and cushions block free walking; selecting a seat is explicit.
			colliders.append(_box_bounds("seat_%s_back" % id, Vector3(x - SEAT_HALF_WIDTH + 0.01, level + 0.45, seat_z + 0.10),
				Vector3(x + SEAT_HALF_WIDTH - 0.01, level + SEAT_BACK_COLLIDER_TOP, seat_z + SEAT_REAR)))
			colliders.append(_box_bounds("seat_%s_base" % id, Vector3(x - SEAT_HALF_WIDTH, level, seat_z - SEAT_FRONT),
				Vector3(x + SEAT_HALF_WIDTH, level + 0.66, seat_z + 0.25)))
		for step in range(STEPS_PER_ROW):
			var start_z := stair_start + row * ROW_PITCH + step * STAIR_TREAD
			var top := (row * STEPS_PER_ROW + step + 1) * STAIR_RISER
			walkable.append(_floor("stair_left_%02d_%d" % [row + 1, step], -AISLE_OUTER_X, start_z,
				-PLATFORM_HALF_WIDTH, start_z + STAIR_TREAD, top))
			walkable.append(_floor("stair_right_%02d_%d" % [row + 1, step], PLATFORM_HALF_WIDTH, start_z,
				AISLE_OUTER_X, start_z + STAIR_TREAD, top))
	walkable.append(_floor("rear", -PLATFORM_HALF_WIDTH, rear_edge,
		PLATFORM_HALF_WIDTH, ROOM_BACK - WALL_MARGIN, ROW_COUNT * ROW_RISER))
	# Outer service aisles follow the same small steps and provide room to turn.
	for side in [-1.0, 1.0]:
		for step in range(ROW_COUNT * STEPS_PER_ROW):
			var start_z := stair_start + step * STAIR_TREAD
			var inner_x := AISLE_OUTER_X if side > 0 else -ROOM_HALF_WIDTH + WALL_MARGIN
			var outer_x := ROOM_HALF_WIDTH - WALL_MARGIN if side > 0 else -AISLE_OUTER_X
			walkable.append(_floor("outer_%s_%02d" % ["right" if side > 0 else "left", step],
				inner_x, start_z, outer_x, start_z + STAIR_TREAD, (step + 1) * STAIR_RISER))
			# Segmented AABBs follow the sloped handrail without a triangle collider.
			var floor_y := (step + 1) * STAIR_RISER
			colliders.append(_box_bounds("rail_%s_%02d" % ["right" if side > 0 else "left", step],
				Vector3(side * RAIL_X - 0.045, floor_y + 0.88, start_z),
				Vector3(side * RAIL_X + 0.045, floor_y + 1.24, start_z + STAIR_TREAD)))
	for bounds in [
		_box_bounds("wall_left", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_FRONT - 0.3), Vector3(-ROOM_HALF_WIDTH + WALL_MARGIN, ROOM_HEIGHT, ROOM_BACK + 0.3)),
		_box_bounds("wall_right", Vector3(ROOM_HALF_WIDTH - WALL_MARGIN, 0, ROOM_FRONT - 0.3), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, ROOM_BACK + 0.3)),
		_box_bounds("wall_front", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_FRONT - 0.3), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, SCREEN_Z + 0.3)),
		_box_bounds("wall_rear", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_BACK - WALL_MARGIN), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, ROOM_BACK + 0.3))]:
		colliders.append(bounds)
	var default_seat: Dictionary = seats[(DEFAULT_ROW - 1) * COLUMN_COUNT + DEFAULT_COLUMN - 1]
	return {"schema_version": 1, "id": "grand_cinema", "name": "Grand Cinema", "units": "metres",
		"source_version": SOURCE_VERSION, "model": "cinema.glb",
		"screen": {"position": [0.0, SCREEN_BOTTOM + SCREEN_HEIGHT * 0.5, SCREEN_Z],
			"width": SCREEN_WIDTH, "height": SCREEN_HEIGHT, "aspect_ratio": 1.43, "yaw": 0.0},
		"room": {"width": ROOM_HALF_WIDTH * 2.0, "depth": ROOM_DEPTH, "height": ROOM_HEIGHT},
		"seats": seats, "default_seat": default_seat.id, "spawn": {"seat_id": default_seat.id, "eye_position": default_seat.eye_position,
			"yaw": 0.0}, "walkable": walkable, "colliders": colliders,
		"design": {"row_count": ROW_COUNT, "seats_per_row": COLUMN_COUNT, "row_pitch": ROW_PITCH,
			"row_riser": ROW_RISER, "stair_riser": STAIR_RISER, "stair_tread": STAIR_TREAD,
			"steps_per_row": STEPS_PER_ROW, "side_aisle_width": AISLE_OUTER_X - PLATFORM_HALF_WIDTH,
			"seat_pitch": SEAT_PITCH, "seat_z_offset": SEAT_Z_OFFSET,
			"clear_row_passage": ROW_PITCH - SEAT_FRONT - SEAT_REAR,
			"tier_front_offset": TIER_FRONT_OFFSET, "stair_start_z": stair_start,
			"rake_degrees": rad_to_deg(atan(ROW_RISER / ROW_PITCH)), "seated_eye_height": SEATED_EYE_HEIGHT,
			"first_row_z": FIRST_ROW_Z, "screen_bottom": SCREEN_BOTTOM,
			"room_front": ROOM_FRONT, "room_back": ROOM_BACK, "room_half_width": ROOM_HALF_WIDTH,
			"wall_margin": WALL_MARGIN, "platform_half_width": PLATFORM_HALF_WIDTH,
			"aisle_outer_x": AISLE_OUTER_X, "rail_x": RAIL_X,
			"ceiling_rear": ROW_COUNT * ROW_RISER + CEILING_REAR_CLEARANCE,
			"seat_front": SEAT_FRONT, "seat_rear": SEAT_REAR, "seat_back_top": SEAT_BACK_TOP,
			"seat_line_from_eye": SEAT_LINE_FROM_EYE,
			"reference": "Original GT-scale 1.43 auditorium study; independent prototype, not a certified venue."}}

static func _floor(id: String, x0: float, z0: float, x1: float, z1: float, height: float) -> Dictionary:
	return {"id": id, "min": [x0, height, z0], "max": [x1, height, z1], "height": height}

static func _box_bounds(id: String, minimum: Vector3, maximum: Vector3) -> Dictionary:
	return {"id": id, "min": [minimum.x, minimum.y, minimum.z], "max": [maximum.x, maximum.y, maximum.z]}
