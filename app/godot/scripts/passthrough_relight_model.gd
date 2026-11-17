# The effect was first contributed by ghanshyam (github.com/ghanshyamv1) in public PR #9.
# The curves and constants in this file were rewritten for 0.18.1.1.
extends RefCounted
## Pure maths of the screen mood light: video-driven lighting of the room around a flat screen.
##
## Two outputs per sampled frame:
##  - room colour: the frame's mean colour, with its brightness and saturation remapped,
##    multiplied into the camera picture.
##  - halo bar: 32 colours around the picture's border (clockwise from the top-left corner),
##    which the glow shader looks up by direction from the picture's centre.
##
## All colour maths is linear. Lengths are in screen heights.

## The viewer's two controls, 0..1: how far the halo spreads (a tight ring to the whole room)
## and how strongly the halo and the room tint show.
const DEFAULT_REACH := 0.35
const DEFAULT_BRIGHTNESS := 0.6
## The same two controls as the settings sliders show them. Brightness stops short of zero:
## the switch turns the light off.
const PERCENT_DEFAULTS := {"ambient_range": 35.0, "ambient_brightness": 60.0}
const PERCENT_LIMITS := {"ambient_range": Vector2(0, 100), "ambient_brightness": Vector2(20, 100)}

## Halo falloff past the picture's edge: peak / (1 + (d / width)^1.5)^(1 / 1.5), level near the
## edge and inversely proportional to distance far from it, like light from a long source.
## A wider reach raises the peak past one, which shows as a solid ring at the edge, and
## widens the level part.
const HALO_POWER := 1.5
const HALO_PEAK := Vector2(0.62, 1.85) # tightest, widest
const HALO_PEAK_EASE := 1.25
const HALO_WIDTH := 0.063
const HALO_WIDEN := 2.0
const HALO_WIDEN_EASE := 6.0
## The halo is cut where it has fallen to this fraction; the shader fades it out before that.
const HALO_CUTOFF := 0.03
const HALO_MARGIN_LIMITS := Vector2(1.4, 12.0)
## The picture's own outer band dissolves into the halo, with corners of the same radius.
const EDGE_BAND := 0.1
## The halo mesh: rings at these distances past the picture's edge (denser where the glow
## falls fastest), and this many cells along the picture's width and height.
const HALO_RINGS := [0.02, 0.05, 0.1, 0.2, 0.4, 0.8, 1.5, 3.0, 6.0]
const HALO_CELLS := Vector2i(16, 9)
## Left-eye picture sample: the halo only needs the border's broad colours.
const SAMPLE_SIZE := Vector2i(48, 27)
const BAR_SIZE := 32
## The outer part of the picture that colours the halo, as a share of the way from the centre
## to the border; pixels nearer the border count more.
const BORDER_SHARE := 0.24
## Blur along the border, in bar entries either side.
const BAR_BLUR := [6.0, 4.0, 1.0]

## Room brightness for a frame's brightness v: from ROOM_VALUE.x under a black frame, rising
## quickly (1 - exp(-v / ROOM_RISE)) to ROOM_VALUE.y under a white one. Saturated frames tint
## the room less than proportionally.
const ROOM_VALUE := Vector2(0.02, 0.64)
const ROOM_RISE := 0.19
const ROOM_DESATURATE := 0.44

## Easing time constants, seconds: the room follows the film, returns to white without one,
## and the halo follows the border.
const ROOM_FOLLOW := 0.15
const ROOM_RETURN := 0.7
const HALO_FOLLOW := 0.07


## Linear RGB floats of an image, row 0 at the top.
static func linear_pixels(image: Image) -> PackedFloat32Array:
	var width := image.get_width()
	var height := image.get_height()
	var out := PackedFloat32Array()
	out.resize(width * height * 3)
	var index := 0
	for y in height:
		for x in width:
			var c := image.get_pixel(x, y).srgb_to_linear()
			out[index] = c.r; out[index + 1] = c.g; out[index + 2] = c.b
			index += 3
	return out


## Mean colour of the frame.
static func screen_average(px: PackedFloat32Array, width: int, height: int) -> Color:
	var sum := Vector3.ZERO
	for index in range(0, width * height * 3, 3):
		sum += Vector3(px[index], px[index + 1], px[index + 2])
	sum /= maxf(1.0, width * height)
	return Color(sum.x, sum.y, sum.z)


## What the room is multiplied by under a frame of this mean colour.
static func color_scale(average: Color) -> Color:
	var rise := (1.0 - exp(-average.v / ROOM_RISE)) / (1.0 - exp(-1.0 / ROOM_RISE))
	var saturation := average.s * (1.0 - ROOM_DESATURATE * average.s)
	return Color.from_hsv(average.h, saturation, lerpf(ROOM_VALUE.x, ROOM_VALUE.y, rise))


## Exponential easing towards a target with a time constant, whatever the frame rate.
static func ease_weight(time_constant: float, delta: float) -> float:
	return 1.0 - exp(-maxf(delta, 0.0) / time_constant)


## Border coordinate 0..1 of a direction from the picture's centre, where the ray leaves the
## picture: clockwise from the top-left corner, a quarter for each side. `point` is in half
## sizes, y up. The glow shader walks the border the same way.
static func border_coordinate(point: Vector2) -> float:
	var reach := maxf(maxf(absf(point.x), absf(point.y)), 0.000001)
	var edge := point / reach
	if absf(point.x) < absf(point.y):
		return 0.125 * (edge.x + 1.0) if point.y > 0.0 else 0.5 + 0.125 * (1.0 - edge.x)
	return 0.25 + 0.125 * (1.0 - edge.y) if point.x > 0.0 else 0.75 + 0.125 * (edge.y + 1.0)


## The border's colours: every pixel in the picture's outer part adds its colour to the bar
## entries nearest its direction from the centre, then the bar is blurred around the border.
static func halo_bar(px: PackedFloat32Array, width: int, height: int) -> PackedVector3Array:
	var sums := PackedVector3Array()
	sums.resize(BAR_SIZE)
	var weights := PackedFloat32Array()
	weights.resize(BAR_SIZE)
	var index := 0
	for y in height:
		var py := 1.0 - (y + 0.5) * 2.0 / height
		for x in width:
			var point := Vector2((x + 0.5) * 2.0 / width - 1.0, py)
			var weight := (maxf(absf(point.x), absf(point.y)) - (1.0 - BORDER_SHARE)) / BORDER_SHARE
			if weight > 0.0:
				var at := border_coordinate(point) * BAR_SIZE - 0.5
				var first := int(floor(at))
				var share := at - first
				var colour := Vector3(px[index], px[index + 1], px[index + 2]) * weight
				var a := posmod(first, BAR_SIZE)
				var b := posmod(first + 1, BAR_SIZE)
				sums[a] += colour * (1.0 - share); weights[a] += weight * (1.0 - share)
				sums[b] += colour * share; weights[b] += weight * share
			index += 3
	var out := PackedVector3Array()
	out.resize(BAR_SIZE)
	for entry in BAR_SIZE:
		var sum := Vector3.ZERO
		var total := 0.0
		for offset in range(1 - BAR_BLUR.size(), BAR_BLUR.size()):
			var from := posmod(entry + offset, BAR_SIZE)
			var blur: float = BAR_BLUR[absi(offset)]
			sum += sums[from] * blur; total += weights[from] * blur
		out[entry] = sum / total if total > 0.0 else Vector3.ZERO
	return out


## LUT for XR_META_passthrough_color_lut that multiplies linear passthrough colour by
## `scale`, like a per-layer colour scale. Image layout of the Godot OpenXR
## Vendors OpenXRMetaPassthroughColorLut: width res*res, height res; pixel (b*res + r, g).
static func scale_lut_image(scale: Color, resolution: int) -> Image:
	var data := PackedByteArray()
	data.resize(resolution * resolution * resolution * 3)
	var encoded := PackedFloat32Array()
	encoded.resize(resolution * 3)
	for i in resolution:
		var level := Color(float(i) / (resolution - 1), float(i) / (resolution - 1), float(i) / (resolution - 1)).srgb_to_linear()
		var c := Color(level.r * scale.r, level.g * scale.g, level.b * scale.b).linear_to_srgb()
		encoded[i * 3] = clampf(c.r, 0, 1); encoded[i * 3 + 1] = clampf(c.g, 0, 1); encoded[i * 3 + 2] = clampf(c.b, 0, 1)
	var width := resolution * resolution
	for g in resolution:
		for b in resolution:
			for r in resolution:
				var at := (g * width + b * resolution + r) * 3
				data[at] = int(round(encoded[r * 3] * 255.0))
				data[at + 1] = int(round(encoded[g * 3 + 1] * 255.0))
				data[at + 2] = int(round(encoded[b * 3 + 2] * 255.0))
	return Image.create_from_data(width, resolution, false, Image.FORMAT_RGB8, data)


## The falloff's peak and width for a reach; the shader takes them as they are.
static func halo_profile(reach: float) -> Vector2:
	var amount := clampf(reach, 0.0, 1.0)
	return Vector2(lerpf(HALO_PEAK.x, HALO_PEAK.y, pow(amount, HALO_PEAK_EASE)),
		HALO_WIDTH * (1.0 + HALO_WIDEN * pow(amount, HALO_WIDEN_EASE)))


## How far past the picture's edge the glow mesh has to reach: where the falloff meets the cutoff.
static func halo_margin(reach: float) -> float:
	var profile := halo_profile(reach)
	var distance := profile.y * pow(pow(profile.x / HALO_CUTOFF, HALO_POWER) - 1.0, 1.0 / HALO_POWER)
	return clampf(distance, HALO_MARGIN_LIMITS.x, HALO_MARGIN_LIMITS.y)


static func halo_strength(brightness: float) -> float:
	return lerpf(0.35, 1.0, clampf(brightness, 0.0, 1.0))


## The room keeps part of its own colour at lower brightness.
static func room_tint(scale: Color, brightness: float) -> Color:
	return Color.WHITE.lerp(scale, lerpf(0.25, 1.0, clampf(brightness, 0.0, 1.0)))


static func _halo_lines(half: float, cells: int, offsets: PackedFloat32Array) -> PackedFloat32Array:
	var lines := PackedFloat32Array()
	for index in range(offsets.size() - 1, -1, -1): lines.append(-half - offsets[index])
	for index in cells + 1: lines.append(lerpf(-half, half, float(index) / cells))
	for offset in offsets: lines.append(half + offset)
	return lines


## Surface arrays of the halo around a `size` picture (metres), reaching `margin` metres past it:
## a grid with the picture's own rectangle left out. The shader's fade starts at 0.7 of the reach.
static func halo_arrays(size: Vector2, margin: float, unit: float) -> Array:
	var offsets := PackedFloat32Array()
	for ring in HALO_RINGS:
		if ring * unit < margin * 0.7: offsets.append(ring * unit)
	offsets.append(margin * 0.7)
	offsets.append(margin)
	var half := size * 0.5
	var xs := _halo_lines(half.x, HALO_CELLS.x, offsets)
	var ys := _halo_lines(half.y, HALO_CELLS.y, offsets)
	var vertices := PackedVector3Array()
	for y in ys:
		for x in xs: vertices.append(Vector3(x, y, 0))
	var indices := PackedInt32Array()
	var columns := xs.size()
	for row in ys.size() - 1:
		for column in columns - 1:
			# Cells of the picture itself: the compositor layer or the video panel covers them.
			if column >= offsets.size() and column < offsets.size() + HALO_CELLS.x and row >= offsets.size() and row < offsets.size() + HALO_CELLS.y: continue
			var at := row * columns + column
			indices.append_array(PackedInt32Array([at, at + 1, at + columns + 1, at, at + columns + 1, at + columns]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays
