extends RefCounted
## Pure maths of the passthrough relight: video-driven lighting of the real room
## around a flat screen (docs/PASSTHROUGH_RELIGHT.md lists every curve and constant).
##
## Two outputs per sampled frame:
##  - passthrough colour scale: the frame average, boosted, mapped through HSV curves
##    driven by one "intensity" (a brightness setting), applied to the real room.
##  - halo bar: 32 colours walking the picture's perimeter (left edge up, top, right edge
##    down, bottom), blurred along the perimeter;
##    the glow shader looks them up by angle around the screen.
##
## All colour maths is linear.

## Default brightness.
const DEFAULT_INTENSITY := 0.4
## Left-eye picture sample. The halo averages 0.08 UV squares and blurs along the
## perimeter, so finer detail never reaches the output.
const SAMPLE_SIZE := Vector2i(48, 27)
## Halo bar resolution (32 colours, looked up with wrap-around).
const BAR_SIZE := 32
## Perimeter samples before blurring; 128 is well below the blur scale.
const NEAR_BAR_SAMPLES := 128

## Time constants (seconds) of the room colour following the picture, and of its return to
## white when no picture is showing.
const ROOM_TAU := 0.4
const NEUTRAL_TAU := 1.0


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


## Bilinear, clamp to edge; v = 0 at the bottom of the picture.
static func sample(px: PackedFloat32Array, width: int, height: int, u: float, v: float) -> Vector3:
	var fx := clampf(u * width - 0.5, 0.0, width - 1.0)
	var fy := clampf((1.0 - v) * height - 0.5, 0.0, height - 1.0)
	var x0 := int(fx); var y0 := int(fy)
	var x1 := mini(x0 + 1, width - 1); var y1 := mini(y0 + 1, height - 1)
	var tx := fx - x0; var ty := fy - y0
	var a := (y0 * width + x0) * 3; var b := (y0 * width + x1) * 3
	var c := (y1 * width + x0) * 3; var d := (y1 * width + x1) * 3
	var top := Vector3(px[a], px[a + 1], px[a + 2]).lerp(Vector3(px[b], px[b + 1], px[b + 2]), tx)
	var bottom := Vector3(px[c], px[c + 1], px[c + 2]).lerp(Vector3(px[d], px[d + 1], px[d + 2]), tx)
	return top.lerp(bottom, ty)


## Gamma applied to the brightest channel of the frame average: below 1 it raises dark
## frames (a 20 % frame becomes about 28 %) and leaves white unchanged.
const DARK_LIFT_GAMMA := 0.8
## Room brightness for a black and for a white frame, at intensity 0 and 1.
const ROOM_BLACK := Vector2(0.02, 0.08)
const ROOM_WHITE := Vector2(0.45, 0.85)
## Share of the frame's saturation passed to the room, so tints stay gentle.
const ROOM_SATURATION := 0.6
## Halo fade distance in halo units at intensity 0 and 1.
const HALO_REACH := Vector2(0.25, 0.625)


## Frame average: a 16 x 16 grid mean, dark frames raised by DARK_LIFT_GAMMA on the
## brightest channel (hue and saturation kept), quantised to 8 bits.
static func screen_average(px: PackedFloat32Array, width: int, height: int) -> Color:
	var sum := Vector3.ZERO
	for i in 16:
		for j in 16:
			sum += sample(px, width, height, (i + 0.5) / 16.0, (j + 0.5) / 16.0)
	var avg := sum / 256.0
	var top := maxf(avg.x, maxf(avg.y, avg.z))
	var boosted := avg * pow(top, DARK_LIFT_GAMMA - 1.0) if top > 0.0 else avg
	return Color(snappedf(clampf(boosted.x, 0, 1), 1.0 / 255.0), snappedf(clampf(boosted.y, 0, 1), 1.0 / 255.0),
		snappedf(clampf(boosted.z, 0, 1), 1.0 / 255.0))


## Room colour scale: the frame's hue, a reduced share of its saturation, and a brightness
## running linearly from ROOM_BLACK (black frame) to ROOM_WHITE (white frame).
## Higher intensity keeps the room brighter.
static func color_scale(average: Color, intensity: float) -> Color:
	var i := clampf(intensity, 0.0, 1.0)
	var low := lerpf(ROOM_BLACK.x, ROOM_BLACK.y, i)
	var high := lerpf(ROOM_WHITE.x, ROOM_WHITE.y, i)
	return Color.from_hsv(average.h, average.s * ROOM_SATURATION, lerpf(low, high, average.v))


## Halo fade distance for an intensity (the glow shader's `reach`).
static func halo_reach(intensity: float) -> float:
	return lerpf(HALO_REACH.x, HALO_REACH.y, clampf(intensity, 0.0, 1.0))


## Exponential easing towards `target` with time constant `tau`, independent of frame rate.
static func blend(current: Color, target: Color, tau: float, delta: float) -> Color:
	return current.lerp(target, 1.0 - exp(-maxf(delta, 0.0) / maxf(tau, 0.0001)))


## Point on the 0.06..0.94 inset rectangle for perimeter u.
static func perimeter_point(u: float) -> Vector2:
	if u < 0.25: return Vector2(0.06, 0.06 + 3.52 * u)
	if u < 0.5: return Vector2(3.52 * u - 0.82, 0.94)
	if u < 0.75: return Vector2(0.94, 2.7 - 3.52 * u)
	return Vector2(3.58 - 3.52 * u, 0.06)


## Edge colour around one perimeter point: the plain mean of a 5 x 5 grid,
## step NEAR_STEP UV, centred on the point.
const NEAR_STEP := 0.02

static func near_bar(px: PackedFloat32Array, width: int, height: int, u: float) -> Vector3:
	var p := perimeter_point(u)
	var sum := Vector3.ZERO
	for i in range(-2, 3):
		for j in range(-2, 3):
			sum += sample(px, width, height, p.x + i * NEAR_STEP, p.y + j * NEAR_STEP)
	return sum / 25.0


## Linear lookup into an evenly sampled bar (texel centres), clamp or repeat.
static func bar_lookup(bar: PackedVector3Array, u: float, repeat: bool) -> Vector3:
	var n := bar.size()
	var f := u * n - 0.5
	if repeat:
		f = fposmod(f, float(n))
		var i0 := int(f)
		return bar[i0].lerp(bar[(i0 + 1) % n], f - i0)
	f = clampf(f, 0.0, n - 1.0)
	var j0 := int(f)
	return bar[j0].lerp(bar[mini(j0 + 1, n - 1)], f - j0)


## Width (standard deviation) of the Gaussian blur along the perimeter, as a fraction of
## the whole perimeter. 0.035 spreads one edge colour over about a third of that edge.
const BAR_BLUR_SIGMA := 0.035


## Perimeter samples -> one Gaussian blur along the closed perimeter (weights normalised
## to sum to one) evaluated at the 32 bar positions. Unfiltered in time.
static func halo_bar(px: PackedFloat32Array, width: int, height: int) -> PackedVector3Array:
	var near := PackedVector3Array()
	near.resize(NEAR_BAR_SAMPLES)
	for k in NEAR_BAR_SAMPLES:
		near[k] = near_bar(px, width, height, (k + 0.5) / NEAR_BAR_SAMPLES)
	var out := PackedVector3Array()
	out.resize(BAR_SIZE)
	var inv := 1.0 / (2.0 * BAR_BLUR_SIGMA * BAR_BLUR_SIGMA)
	for i in BAR_SIZE:
		var x := (i + 0.5) / BAR_SIZE
		var sum := Vector3.ZERO
		var total := 0.0
		for k in NEAR_BAR_SAMPLES:
			var offset := absf(x - (k + 0.5) / NEAR_BAR_SAMPLES)
			offset = minf(offset, 1.0 - offset) # wrap around the closed perimeter
			var weight := exp(-offset * offset * inv)
			sum += near[k] * weight
			total += weight
		out[i] = sum / total
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
