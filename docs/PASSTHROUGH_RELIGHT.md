# Passthrough relighting

Player: the light button in the floating row above the bar, or **More → Passthrough relighting**.
Browser: the Lighting button on the effect bar, or the switch in Browser effects; it uses the
focus-selected region. Both are off whenever the app opens and are not saved, like person
passthrough. While on, the background shows passthrough without changing the saved scenery and
the session's passthrough button is disabled.
It applies to flat pictures (regular or 3D videos, browser pages) while passthrough is shown:

1. **Room relight**: the real room is tinted and dimmed by the picture's colour.
2. **Screen halo**: the colours along the picture's edge glow around the screen.
3. **Floor shadow**: a soft dark strip on the floor beneath the screen.

Implementation: `scripts/passthrough_relight.gd` (runtime), `scripts/passthrough_relight_model.gd`
(maths), `shaders/passthrough_relight_glow.gdshader`, `shaders/passthrough_relight_floor.gdshader`,
test `tests/test_passthrough_relight.gd`.

## Design

Lengths below are in halo units: a 16:9 screen is 1.92 × 1.08 units, and one unit in metres is
`screen height / 1.08`, so the halo grows with the screen.

### Sampling

The picture is read on the CPU at 48×27 (left eye) through the same layer-PixelCopy / eye-buffer
paths as the cinema film light: every 80 ms on layers and every 250 ms on the eye buffer, not
every frame. The left-eye crop is the left half for side-by-side, the top for top-bottom and the
whole frame for mono. Browser pages are sampled by PixelCopy of the page's producer surface
(`LayerThumbnail.requestSurface`), cropped to the focus region, every 100 ms.

Two values are derived from each sample:

| Value | Size | Work |
|---|---|---|
| Frame average | 1 colour | mean of a 16×16 grid, then `avg · (1 + 2(1 − max(rgb))²)` to lift dark frames |
| Halo bar | 32 colours | perimeter of the 0.06–0.94 inset rectangle (left edge up, top, right edge down, bottom); 4 rings × 8 taps, radius 0.015·k, weights (6−k)/144; then a 31-tap blur (step 0.002, weights (22−\|k\|)/442) and a 9-tap blur at k/32 |

All colour maths is linear. Per-frame blends are written in frame-rate-independent form at nominal
rates (72 Hz for the room colour, 36 Hz for the halo bar, which keeps 25 % of its previous value),
and the halo adds a 60 ms settle to hide sample steps.

### Room relight

The frame average goes through HSV curves to a per-channel colour scale, eased as
`smoothed·0.9 + target·0.1` per frame. Without a picture it returns to white at 2 % per frame.

With σ(x; k, c) = 1/(1 + e^(−k(x − c))) and I = intensity:

```
H, S, V = RGBToHSV(rgb)
p  = 1.2 + 0.4·(σ(I;8,.85) − 0.0011125) / −0.7674122
S' = S·((p + 1) − S^p) / (p + 1)
b  = σ(I;8,.4) − 0.0391657 ;  c = σ(I;8,.8) − 0.0016588 ;  t = 0.2 − 0.1c
V' = 1/(1 + e^(−8b(V − t))) − 1/(1 + e^(−8b(−0.2 − c)))
scale = HSVToRGB(H, S', V')
```

The intensity is fixed at 0.4; no slider is exposed yet. At 0.4, a black frame takes the room to
about 3 %, a mid frame to about 45 %, and a white frame to about 66 %.

Godot's passthrough layer is owned by the OpenXR Vendors plugin, so the per-channel multiply is
expressed as an `XR_META_passthrough_color_lut` (16³, `out = encode(decode(in)·scale)`) through
`OpenXRFbPassthroughExtension.set_color_lut`. The LUT is rebuilt at most every 66 ms and only
for a change of more than 1.5/255; the new LUT is set before the previous one is released,
because the plugin disables the filter when a LUT that is in use is freed. On runtimes
without color LUTs (PICO, standard OpenXR), the halo and floor shadow still work and the room
is left untouched (`snapshot().lut_supported`).

### Screen halo

The colour comes from the halo bar at the pseudo-angle around the screen (the same perimeter
walk, aspect-normalised so the corners land at quarter points). It is compressed by
`L = 1 − 1/(1 + r + g + 2·min(r,g))`, `f = 1 − L·(0.4 + 0.6(1 − G))`, and shaped by a
rounded-rect distance `d` (radius 0.08). The profile is nearly opaque at the picture's edge,
holds for about a third of the screen height, then fades as `0.7 / (1 + 2.2 x)` across the room.
The result is multiplied by a gain of 1.25. Output is premultiplied `(G·w·f·c, G·w)`, so the
compositor darkens the room behind the glow and adds the picture's edge colour. The halo quad
reaches 29 units past the edge so its own border is never visible.

### Edge dissolve

The picture is an opaque compositor layer, so its edge cannot fade into the room. The outer
0.12 units of the picture, with rounded corners, are covered by the glow colour with alpha
`(d / 0.12)²` (shader `part = 1`, a quad of the picture's size drawn after the layer's hole),
which meets the halo seamlessly and leaves no hard border.

### Floor shadow

Colour (0, 0, 0, 0.18) × intensity 0.72, edge feather 0.68, centre lift 0.58, strip depth 0.18 m
(+ up to 0.24 with tilt × 0.35), length 0.667 × panel width, height fade from 0.45 m to 1.6 m
down to 25 %, ground-contact fade 0.08 m, 0.2 s visibility fade. Fragment:
`alpha = clamp((1 − lift·r²)·(1 − smoothstep(edge)))·a`.

## Notes

- **Output encoding** (measured on a Quest 3 with headset screenshots): the eye buffer takes
  display-referred, premultiplied values, so the shader writes `sRGB(colour · a)` and `a`. Linear
  output showed at about a fifth of the intended brightness; straight colour clipped the edge band.
- **Curved screens** keep the room relight and floor shadow but show no halo.
- Controller and hand materials are unshaded, so they are not tinted.

Checked on a Quest 3 (store 0.17.5 build with these scripts) by playing a colour-card video and
measuring headset screenshots: the edge profile is smooth and monotone from the picture into the
room, and each side takes its own edge colour. Frame rate cost, Quest 2 and PICO remain to be
measured.
