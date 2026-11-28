shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
uniform vec4 dot_color : source_color = vec4(1.0);
void vertex() {
    // The same eye-offset cancellation as the mono ray's far end, so both eyes see the
    // reticle in the centre-eye direction of the zero-parallax capture, every frame.
    POSITION = PROJECTION_MATRIX * vec4((VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz + EYE_OFFSET, 1.0);
}
void fragment() {
    ALBEDO = dot_color.rgb;
    ALPHA = dot_color.a;
}
