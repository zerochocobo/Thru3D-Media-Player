shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform samplerExternalOES video_texture;
uniform mat4 surface_transform = mat4(1.0);
void fragment() {
	vec2 uv = (surface_transform * vec4(UV.x, 1.0 - UV.y, 0.0, 1.0)).xy;
	ALBEDO = texture(video_texture, uv).rgb;
}
