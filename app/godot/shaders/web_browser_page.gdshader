shader_type spatial;
// The page itself, drawn where web_browser_hole.gdshader would uncover a compositor layer:
// same pass and depth rules, so depth-tested pointers stay in front.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
uniform samplerExternalOES page;
uniform mat4 surface_transform = mat4(1.0);
// xy origin and zw size of the shown part, in top-left page coordinates.
uniform vec4 crop = vec4(0.0, 0.0, 1.0, 1.0);
void fragment() {
	vec2 at = crop.xy + UV * crop.zw;
	// The OES sampler yields SDR encoded RGB. Compatibility's lighting space is sRGB.
	ALBEDO = texture(page, (surface_transform * vec4(at.x, 1.0 - at.y, 0.0, 1.0)).xy).rgb;
	ALPHA = 1.0;
}
