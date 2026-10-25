shader_type spatial;
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
uniform sampler2D menu_texture : source_color, filter_linear, repeat_disable;
void vertex() {
    // Godot multiview projections contain each eye's inverse relative pose.
    // A direction (w=0) removes eye translation, retaining its rotation and FOV.
    // Do not copy clip coordinates between asymmetric/canted eye projections.
    vec3 direction = (VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    POSITION = PROJECTION_MATRIX * vec4(direction, 0.0);
    POSITION.z = 0.0;
}
void fragment() {
    vec4 pixel = texture(menu_texture, UV);
    ALBEDO = pixel.rgb;
    ALPHA = pixel.a;
}
