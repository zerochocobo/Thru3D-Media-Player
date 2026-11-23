shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform samplerExternalOES video_texture;
uniform mat4 surface_transform = mat4(1.0);
// QIYU factory runtime only (airplay_window.gd): same decode as web_browser_page.gdshader.
uniform bool decode_srgb = false;
uniform float decode_gamma = 1.0; // QiyuController.DISPLAY_GAMMA
void fragment() {
	vec2 uv = (surface_transform * vec4(UV.x, 1.0 - UV.y, 0.0, 1.0)).xy;
	vec3 color = texture(video_texture, uv).rgb;
	if (decode_srgb) { color = pow(max(color, vec3(0.0)), vec3(decode_gamma)); color = mix(color / 12.92, pow((color + 0.055) / 1.055, vec3(2.4)), step(0.04045, color)); }
	ALBEDO = color;
}
