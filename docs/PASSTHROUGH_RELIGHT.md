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
| Frame average | 1 colour | mean of a 16×16 grid, then `avg · max(rgb)^(γ − 1)` with γ = 0.8 to lift dark frames (white is unchanged, hue and saturation are kept) |
| Halo bar | 32 colours | 128 points on the perimeter of the 0.06–0.94 inset rectangle (left edge up, top, right edge down, bottom), each the mean of a 5×5 grid at 0.02 UV steps; then one Gaussian blur along the closed perimeter (σ = 0.035 of the perimeter, normalised weights) evaluated at the 32 bar positions |

All colour maths is linear. Smoothing is exponential easing with a time constant, independent
of frame rate: 0.4 s for the room colour, 1 s for its return to white when no picture is showing,
and 0.08 s for the halo colours.

### Room relight

The frame average is mapped to a per-channel colour scale for the room:

With I = intensity (0..1) and the frame average in HSV:

```
low   = lerp(0.02, 0.08, I)      # room brightness for a black frame
high  = lerp(0.45, 0.85, I)      # room brightness for a white frame
scale = HSVToRGB(H, 0.6·S, lerp(low, high, V))
```

The intensity is fixed at 0.4; no slider is exposed yet. At 0.4, a black frame takes the room to
about 4 %, a mid frame to about 33 %, and a white frame to about 61 %.

Godot's passthrough layer is owned by the OpenXR Vendors plugin, so the per-channel multiply is
expressed as an `XR_META_passthrough_color_lut` (16³, `out = encode(decode(in)·scale)`) through
`OpenXRFbPassthroughExtension.set_color_lut`. The LUT is rebuilt at most every 66 ms and only
for a change of more than 1.5/255; the new LUT is set before the previous one is released,
because the plugin disables the filter when a LUT that is in use is freed. On runtimes
without color LUTs (PICO, standard OpenXR), the halo and floor shadow still work and the room
is left untouched (`snapshot().lut_supported`).

### Screen halo

The colour comes from the halo bar at the nearest edge of the picture (the same perimeter walk;
each fragment picks the edge it is closest to in aspect-normalised coordinates, so the corners
land on the quarter points). `d` is the signed distance to the picture as a rounded rectangle
(corner radius 0.08). The glow is:

```
glow   = peak / (1 + (max(d, 0) / reach)⁴)^¼      peak = 1, reach = lerp(0.25, 0.625, I)
alpha  = glow
colour = c · gain / (1 + 0.5 · luma(c)) · glow    gain = 1.25, premultiplied
```

The profile is flat for about `reach` past the edge, so it continues the edge band without a
step, then falls as `reach / d`. At the default intensity (reach 0.4) it is at 98 % 0.2 units
out, 57 % at 0.7, 26 % at 1.5 and 13 % at 3 units. The colour term tones bright colours down
(white to about 83 %) so the glow is never brighter than the picture. The compositor keeps
`(1 − alpha)` of the room and adds the colour. The halo quad reaches 29 units past the edge so
its own border is never visible.

### Edge dissolve

The picture is an opaque compositor layer, so its edge cannot fade into the room. The outer
0.12 units of the picture are covered by the glow colour (shader `part = 1`, a quad of the
picture's size drawn after the layer's hole) with `alpha = (1 − t)²`, t = 0 at the edge and 1 at
0.12 units in: fully opaque at the edge, so the picture's border never shows, and falling off
quickly so most of the band is already picture.

### How the curves were chosen

Every curve is a standard, simple form picked for one visual property, with round-number
constants that are meant to be tuned on the device:

- **Halo profile**: `1 / (1 + x⁴)^¼` is flat near the edge, has a long `1/x` tail into the room
  and one size parameter (`reach`). Its slope has no kink, so it shows no ring. `reach` was
  tuned so the glow keeps the width and tail of the previous version of this effect.
- **Gaussian perimeter blur**: separates the colours of different edges while hiding the
  sampling grid; normalised weights keep a uniform picture's colour exact.
- **Quadratic edge band**: opaque at the edge, mostly picture after a third of the band.
- **Gamma lift of the frame average**: dark scenes still tint the room, white stays white.
- **Linear room brightness between two end points**: easy to tune by looking at a black and a
  white frame; reduced saturation keeps the room's tint gentle.

Tuning procedure (Quest 3): play a colour-card video and full-screen black, grey and white
frames, take headset screenshots with the effect on and off, and read the room brightness and
the halo brightness at fixed distances from the screen edge. Adjust `ROOM_BLACK`/`ROOM_WHITE`,
`HALO_REACH`, `peak` and `gain` until the room and the halo look right; all of them are named
constants or shader uniforms.

### Floor shadow

A black strip on the floor under the screen's bottom edge, 0.3 m deep and 0.8 × the screen width
long, with an elliptical falloff `alpha = (1 − r²)² · 0.15` (r = 0 in the middle, 1 at the
ellipse touching the strip's edges). It is at full strength while the screen's bottom edge is
below 0.5 m, fades to 30 % by 2 m, fades out within 0.1 m of the floor, and fades in over 0.25 s.

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
