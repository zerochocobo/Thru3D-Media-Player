shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
uniform vec4 ray_color : source_color = vec4(1.0);
void vertex() {
    // Keep the origin on the tracked hand; the endpoint joins the mono reticle.
    vec3 point = (VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    POSITION = PROJECTION_MATRIX * vec4(point + EYE_OFFSET * COLOR.a, 1.0);
}
void fragment() { ALBEDO = ray_color.rgb; ALPHA = ray_color.a; }
