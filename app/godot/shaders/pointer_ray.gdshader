shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
#include "res://shaders/pointer_ray.gdshaderinc"
void vertex() {
    POSITION = ray_position(VERTEX, UV, COLOR.a, VIEW_MATRIX * MODEL_MATRIX,
        PROJECTION_MATRIX, vec3(0.0), VIEWPORT_SIZE);
}
void fragment() {
    ALBEDO = ray_color.rgb;
    ALPHA = ray_opacity(UV);
}
