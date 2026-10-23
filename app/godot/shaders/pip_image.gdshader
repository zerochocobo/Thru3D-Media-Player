shader_type spatial;
render_mode blend_mix, depth_draw_never, unshaded, cull_disabled, depth_test_disabled, fog_disabled;
uniform sampler2D image_texture : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 edge_feather = vec2(0.0);
void fragment() {
	vec4 image = texture(image_texture, UV);
	ALBEDO = mix(vec3(0.025), image.rgb, image.a);
	vec2 fade = smoothstep(vec2(0.0), max(edge_feather, vec2(0.00001)), min(UV, vec2(1.0) - UV));
	ALPHA = fade.x * fade.y;
}
