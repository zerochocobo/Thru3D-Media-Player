shader_type spatial;
// Keep UI layer ordering, but let nearer controllers/hands occlude the surface.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 surface_color : source_color = vec4(0.07, 0.08, 0.10, 0.97);
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.02;
// Adjacent subtitle columns share an outer plate with square internal edges.
uniform bool round_left = true;
uniform bool round_right = true;
// Debug text bands: plates that are partly in the eye buffer and partly in band layers render solid
// in both, so the two halves match.
uniform bool solid = false;
uniform bool keep_opacity = false;
// Opt-in media-library feedback reuses this surface; no extra geometry or render pass.
uniform bool hovered = false;
uniform vec3 hover_border = vec3(0.38, 0.94, 0.73);
// Opt-in slider marker ink; the classic material keeps this disabled.
uniform vec4 marker_outline : source_color = vec4(0.0);
uniform float marker_outline_width = 0.001;
// Palette samples show the panel and accent together; ordinary surfaces stay solid.
uniform bool swatch_split = false;
uniform vec4 swatch_accent : source_color = vec4(1.0);
// Depth cues taken from the surface's own colour, so every palette gets them: a hairline rim and
// a faint top-to-bottom sheen. Dark surfaces lift towards white, light ones settle towards black.
uniform float rim = 0.0;
uniform float rim_width = 0.0016;
uniform float sheen = 0.0;

void fragment() {
    float radius = min(corner_radius, min(surface_size.x, surface_size.y) * 0.5);
    if ((UV.x < 0.5 && !round_left) || (UV.x >= 0.5 && !round_right)) radius = 0.0;
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(radius));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float edge = max(fwidth(distance), 0.0003);
    ALBEDO = surface_color.rgb;
    if (swatch_split) {
        float seam = max(fwidth(UV.x), 0.0001);
        ALBEDO = mix(ALBEDO, swatch_accent.rgb, smoothstep(0.5 - seam, 0.5 + seam, UV.x));
    }
    if (rim > 0.0 || sheen > 0.0) {
        float luminance = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
        vec3 lift = luminance < 0.4 ? vec3(1.0) : vec3(0.0);
        ALBEDO = mix(ALBEDO, lift, sheen * (1.0 - UV.y));
        float band = smoothstep(-rim_width - edge, -rim_width + edge, distance);
        ALBEDO = mix(ALBEDO, lift, band * rim * mix(0.45, 1.0, 1.0 - UV.y));
    }
    // Dense menu captures use solid plates so their text has full contrast even over video.
    // Other cameras retain the original translucent eye-buffer appearance.
    // Layers 16-19 are the menu slots and 14-15 the text bands.
    bool capture = (CAMERA_VISIBLE_LAYERS & 0xFC000u) != 0u && (CAMERA_VISIBLE_LAYERS & 0x3FFFu) == 0u;
    float opacity = !keep_opacity && (capture || solid) && surface_color.a > 0.0 ? 1.0 : surface_color.a;
    ALPHA = opacity * (1.0 - smoothstep(-edge, edge, distance));
    if (marker_outline.a > 0.0) {
        float marker_edge = smoothstep(-marker_outline_width - edge, -marker_outline_width + edge, distance);
        ALBEDO = mix(ALBEDO, marker_outline.rgb, marker_edge * marker_outline.a);
    }
    if (hovered) {
        float border = smoothstep(-0.0025 - edge, -0.0025 + edge, distance);
        ALBEDO = mix(ALBEDO, hover_border.rgb, border);
    }
}
