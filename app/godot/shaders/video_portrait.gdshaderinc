// One source image, projected by the actual XR eyes. All three textures share one display lease.
#include "res://shaders/color_grade.gdshaderinc"
#include "res://shaders/sharpness.gdshaderinc"
uniform sampler2D alpha_texture : filter_linear, repeat_disable;
uniform sampler2D portrait_texture : filter_linear, repeat_disable;
uniform vec2 model_size = vec2(320.0);
uniform vec4 model_content_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 source_size = vec2(1920.0, 1080.0);
uniform int rotation_degrees = 0;
uniform vec2 alpha_edge = vec2(0.0, 1.0);
uniform vec2 portrait_size = vec2(1.9, 1.07);
uniform vec3 portrait_reference = vec3(0.0, 0.0, 2.0);
uniform float portrait_distance = 2.0;
uniform float portrait_relief = 0.1;

vec2 portrait_raw_uv(vec2 uv) {
    if (rotation_degrees == 90) { return vec2(uv.y, 1.0 - uv.x); }
    if (rotation_degrees == 180) { return vec2(1.0) - uv; }
    if (rotation_degrees == 270) { return vec2(1.0 - uv.y, uv.x); }
    return uv;
}
vec2 portrait_model_uv(vec2 raw) { return model_content_rect.xy + raw * model_content_rect.zw; }
bool portrait_outside(vec2 p) { return any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0))); }
vec2 portrait_sample_uv(vec2 p) {
    vec2 first = max((ceil(model_content_rect.xy * model_size - vec2(0.5)) + vec2(0.5)) / model_size, vec2(0.5) / model_size);
    vec2 last = min((floor((model_content_rect.xy + model_content_rect.zw) * model_size - vec2(0.5)) + vec2(0.5)) / model_size, vec2(1.0) - vec2(0.5) / model_size);
    return clamp(p, first, last);
}
void vertex() {
    vec2 p = portrait_model_uv(portrait_raw_uv(UV));
    float shape = textureLod(portrait_texture, portrait_sample_uv(p), 0.0).r * 1.5;
    // Smoothly end displacement at ROI boundaries; final transparency is the unblurred Alpha.
    float edge = min(min(p.x, 1.0-p.x), min(p.y, 1.0-p.y));
    shape *= smoothstep(0.0, 2.0 / min(model_size.x, model_size.y), edge);
    float distance = max(0.8, portrait_distance - portrait_relief * shape);
    vec2 point = (UV - vec2(0.5)) * portrait_size * vec2(1.0, -1.0);
    VERTEX.xy = portrait_reference.xy + (point - portrait_reference.xy) * distance / max(0.1, portrait_reference.z);
    VERTEX.z = portrait_reference.z - distance;
}
void fragment() {
    vec2 raw = portrait_raw_uv(UV);
    vec2 p = portrait_model_uv(raw);
    vec2 sample_uv = portrait_sample_uv(p);
    float mask = texture(alpha_texture, vec2(sample_uv.x * 0.5, sample_uv.y)).r;
    vec2 half_pixel = vec2(0.5) / source_size;
    vec2 color_uv = clamp(raw, half_pixel, vec2(1.0) - half_pixel);
    vec3 rgb = portrait_color(color_uv);
    if (sharpness > 0.0) {
        vec2 step_uv = max(vec2(1.0) / source_size, fwidth(color_uv));
        rgb = sharpen_rgb(rgb,
            portrait_color(clamp(color_uv+vec2(step_uv.x,0.0),half_pixel,vec2(1.0)-half_pixel)),
            portrait_color(clamp(color_uv-vec2(step_uv.x,0.0),half_pixel,vec2(1.0)-half_pixel)),
            portrait_color(clamp(color_uv+vec2(0.0,step_uv.y),half_pixel,vec2(1.0)-half_pixel)),
            portrait_color(clamp(color_uv-vec2(0.0,step_uv.y),half_pixel,vec2(1.0)-half_pixel)));
    }
    ALBEDO = color_grade(rgb);
    ALPHA = portrait_outside(p) ? 0.0 : clamp((mask-alpha_edge.x) / max(0.001,alpha_edge.y-alpha_edge.x),0.0,1.0);
    // Soften a person clipped by the source frame, independently of the moving inference ROI.
    vec2 source_edge = min(raw, vec2(1.0)-raw);
    vec2 fade = smoothstep(vec2(0.0), max(vec2(3.0)/source_size, vec2(0.003)), source_edge);
    ALPHA *= fade.x * fade.y;
}
