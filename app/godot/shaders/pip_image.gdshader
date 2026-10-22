shader_type spatial;
render_mode blend_mix, depth_draw_never, unshaded, cull_disabled, depth_test_disabled, fog_disabled;
uniform sampler2D image_texture : source_color, filter_linear_mipmap_anisotropic;
void fragment() {
	vec4 image = texture(image_texture, UV);
	ALBEDO = mix(vec3(0.025), image.rgb, image.a);
	ALPHA = 1.0; // Join the ordered PiP transparent pass, while keeping the picture opaque.
}
