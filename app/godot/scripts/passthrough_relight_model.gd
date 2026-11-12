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
## Left-eye picture sample. The halo blurs with rings up to 0.06 UV and a ~0.1 UV
## perimeter kernel, so finer detail never reaches the output.
const SAMPLE_SIZE := Vector2i(48, 27)
## Halo bar resolution (32 colours, looked up with wrap-around).
const BAR_SIZE := 32
## Perimeter samples before blurring; 128 is well below the blur scale.
const NEAR_BAR_SAMPLES := 128

## The room colour eases per frame at a nominal 72 Hz.
const SCALE_FRAME_RATE := 72.0
const SCALE_KEEP := 0.9 # smoothed*0.9 + target*0.1 while a video plays
const NEUTRAL_KEEP := 0.98 # 2 % per frame back to white without video
## The halo bar keeps 25 % of its previous value at a nominal 36 Hz.
const BAR_FRAME_RATE := 36.0
const BAR_KEEP := 0.25


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


## Frame average: a 16 x 16 grid mean with a lift that
## raises dark frames, quantised to 8 bits.
static func screen_average(px: PackedFloat32Array, width: int, height: int) -> Color:
	var sum := Vector3.ZERO
	for i in 16:
		for j in 16:
			sum += sample(px, width, height, i * 0.0625, j * 0.0625)
	var avg := sum / 256.0
	var lift := 1.0 - maxf(avg.x, maxf(avg.y, avg.z))
	var boosted := avg * (1.0 + 2.0 * lift * lift) # dot(vec2(x), vec2(x)) + 1
	return Color(snappedf(clampf(boosted.x, 0, 1), 1.0 / 255.0), snappedf(clampf(boosted.y, 0, 1), 1.0 / 255.0),
		snappedf(clampf(boosted.z, 0, 1), 1.0 / 255.0))


static func _sigmoid(x: float, steepness: float, centre: float) -> float:
	return 1.0 / (1.0 + exp(-steepness * (x - centre)))


## Room colour scale: the frame colour through HSV curves.
## Intensity 0..1 steepens the value curve and relaxes the saturation curve.
static func color_scale(average: Color, intensity: float) -> Color:
	var h := average.h
	var s := average.s
	var v := average.v
	var bend := (_sigmoid(intensity, 8.0, 0.85) - 0.0011125360615551472) / -0.7674121856689453
	var exponent := bend * 0.4 + 1.2
	s = s * ((exponent + 1.0) - pow(s, exponent)) / (exponent + 1.0)
	var steep := -8.0 * (_sigmoid(intensity, 8.0, 0.4) - 0.03916572406888008)
	var floor_lift := _sigmoid(intensity, 8.0, 0.8) - 0.0016588012222200632
	var threshold := 0.2 - 0.1 * floor_lift
	var value := 1.0 / (1.0 + exp(steep * (v - threshold))) - 1.0 / (1.0 + exp(steep * (-0.2 - floor_lift)))
	return Color.from_hsv(h, s, value)


## Frame-rate independent form of the per-frame blend `x*keep + target*(1-keep)`.
static func blend(current: Color, target: Color, keep: float, rate: float, delta: float) -> Color:
	return current.lerp(target, 1.0 - pow(keep, maxf(delta, 0.0) * rate))


## Point on the 0.06..0.94 inset rectangle for perimeter u.
static func perimeter_point(u: float) -> Vector2:
	if u < 0.25: return Vector2(0.06, 0.06 + 3.52 * u)
	if u < 0.5: return Vector2(3.52 * u - 0.82, 0.94)
	if u < 0.75: return Vector2(0.94, 2.7 - 3.52 * u)
	return Vector2(3.58 - 3.52 * u, 0.06)


## Ring blur around one perimeter point: rings 1..4 x 0.015 UV, 8 taps each at
## k*pi/4 + pi/7, weights (6 - ring)/144 (they sum to one).
static func near_bar(px: PackedFloat32Array, width: int, height: int, u: float) -> Vector3:
	var p := perimeter_point(u)
	var sum := Vector3.ZERO
	for ring in 4:
		var weight := float(6 - ring) / 144.0
		var radius := float(ring + 1) * 0.015
		for tap in 8:
			var angle := tap * 0.78539812564849853515625 + 0.448798954486846923828125
			sum += sample(px, width, height, p.x + cos(angle) * radius, p.y + sin(angle) * radius) * weight
	return sum


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


## Perimeter samples -> 31-tap blur (step 0.002, weights (22-|k|)/442, clamp)
## -> 9-tap blur at k/32 (repeat). Unfiltered in time.
static func halo_bar(px: PackedFloat32Array, width: int, height: int) -> PackedVector3Array:
	var near := PackedVector3Array()
	near.resize(NEAR_BAR_SAMPLES)
	for k in NEAR_BAR_SAMPLES:
		near[k] = near_bar(px, width, height, (k + 0.5) / NEAR_BAR_SAMPLES)
	var smooth := PackedVector3Array()
	smooth.resize(64)
	for i in 64:
		var x := (i + 0.5) / 64.0
		var sum := Vector3.ZERO
		for k in range(-15, 16):
			sum += bar_lookup(near, x + k * 0.002, false) * (float(22 - absi(k)) / 442.0)
		smooth[i] = sum
	const WEIGHTS := [0.02, 0.06, 0.13, 0.34, 2.46, 0.34, 0.13, 0.06, 0.02]
	var out := PackedVector3Array()
	out.resize(BAR_SIZE)
	for i in BAR_SIZE:
		var x := (i + 0.5) / BAR_SIZE
		var sum := Vector3.ZERO
		for k in range(-4, 5):
			sum += bar_lookup(smooth, x + k / 32.0, true) * WEIGHTS[k + 4]
		out[i] = sum * 0.280898869037628173828125
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
