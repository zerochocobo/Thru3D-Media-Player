shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform float hue = 0.0;
// RayMenu tracks this stable value for hover/cache invalidation; the gradient supplies RGB.
uniform vec4 surface_color : source_color = vec4(1.0);
uniform bool hue_strip = false;
uniform vec2 surface_size = vec2(0.52, 0.40);
uniform vec4 background_luminance = vec4(0.0);
uniform float contrast_floor = 0.0;

vec3 hsv(vec3 c) {
    vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return c.z * mix(vec3(1.0), rgb, c.y);
}

vec3 linear_color(vec3 color) {
    return mix(pow((color + vec3(0.055)) / 1.055, vec3(2.4)), color / 12.92, lessThanEqual(color, vec3(0.04045)));
}

void fragment() {
    vec3 color = hsv(hue_strip ? vec3(UV.x, 1.0, 1.0) : vec3(hue, UV.x, 1.0 - UV.y));
    if (!hue_strip && contrast_floor > 0.0) {
        float ink = dot(linear_color(color), vec3(0.2126, 0.7152, 0.0722));
        vec4 ratios = (max(vec4(ink), background_luminance) + 0.05) / (min(vec4(ink), background_luminance) + 0.05);
        if (min(min(ratios.x, ratios.y), min(ratios.z, ratios.w)) < contrast_floor) {
            float hatch = step(0.5, fract((UV.x + UV.y) * 28.0));
            color = mix(color, vec3(0.25 + hatch * 0.06), 0.78);
        }
    }
    ALBEDO = OUTPUT_IS_SRGB ? color : linear_color(color);
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(0.008));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - 0.008;
    float edge = max(fwidth(distance), 0.0003);
    ALPHA = 1.0 - smoothstep(-edge, edge, distance);
}
