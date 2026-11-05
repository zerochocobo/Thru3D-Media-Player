shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D gray_icon : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 shadow_ink : source_color = vec4(0.11, 0.11, 0.11, 1.0);
uniform vec4 highlight_ink : source_color = vec4(0.44, 0.44, 0.44, 1.0);

void fragment() {
    vec4 sample_color = texture(gray_icon, UV);
    // Retain the authored folds and gradient. Multiplication by text ink
    // compressed both silver highlights and shadows into almost-black pixels.
    float value = sample_color.r;
    if (!OUTPUT_IS_SRGB) {
        value = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1.0 / 2.4) - 0.055;
    }
    float shade = clamp((value - 0.10) / 0.78, 0.0, 1.0);
    ALBEDO = mix(shadow_ink.rgb, highlight_ink.rgb, shade);
    ALPHA = sample_color.a;
}
