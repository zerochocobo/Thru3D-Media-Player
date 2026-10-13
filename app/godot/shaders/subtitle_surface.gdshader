shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix;
#include "res://shaders/projected_subtitles.gdshaderinc"
#include "res://shaders/bitmap_subtitles.gdshaderinc"
uniform int rotation_degrees = 0;
void vertex() {
    subtitle_patch_position = vec3(0.0);
    subtitle_patch_eye = vec3(0.0);
    if (subtitle_enabled) {
        subtitle_patch_position = (subtitle_world_to_patch * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
        subtitle_patch_eye = (subtitle_world_to_patch * INV_VIEW_MATRIX * vec4(EYE_OFFSET, 1.0)).xyz;
    }
}
void fragment() {
    vec2 p = UV;
    if (rotation_degrees == 90) { p = vec2(p.y, 1.0 - p.x); }
    else if (rotation_degrees == 180) { p = vec2(1.0) - p; }
    else if (rotation_degrees == 270) { p = vec2(1.0 - p.y, p.x); }
    vec4 result = caption_composite(vec3(0.0), 0.0, projected_caption());
    result = caption_composite(result.rgb, result.a, bitmap_caption(p));
    ALBEDO = result.rgb; ALPHA = result.a;
}
