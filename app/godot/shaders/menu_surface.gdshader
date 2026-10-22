shader_type spatial;
// Keep UI layer ordering, but let nearer controllers/hands occlude the surface.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 surface_color : source_color = vec4(0.07, 0.08, 0.10, 0.97);
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.02;
// Debug text bands: plates that are partly in the eye buffer and partly in band layers render solid
// in both, so the two halves match.
uniform bool solid = false;
uniform bool keep_opacity = false;
// Opt-in media-library feedback reuses this surface; no extra geometry or render pass.
uniform bool hovered = false;

void fragment() {
    float radius = min(corner_radius, min(surface_size.x, surface_size.y) * 0.5);
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(radius));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float edge = max(fwidth(distance), 0.0003);
    ALBEDO = surface_color.rgb;
    // Dense menu captures use solid plates so their text has full contrast even over video.
    // Other cameras retain the original translucent eye-buffer appearance.
    // Layers 16-19 are the menu slots and 14-15 the text bands.
    bool capture = (CAMERA_VISIBLE_LAYERS & 0xFC000u) != 0u && (CAMERA_VISIBLE_LAYERS & 0x3FFFu) == 0u;
    float opacity = !keep_opacity && (capture || solid) && surface_color.a > 0.0 ? 1.0 : surface_color.a;
    ALPHA = opacity * (1.0 - smoothstep(-edge, edge, distance));
    if (hovered) {
        float border = smoothstep(-0.0025 - edge, -0.0025 + edge, distance);
        ALBEDO = mix(ALBEDO, vec3(0.38, 0.94, 0.73), border);
    }
}
