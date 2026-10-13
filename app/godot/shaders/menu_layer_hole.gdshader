shader_type spatial;
// Clears the eye buffer only where the menu layer beneath it has coverage. The quad lies on the
// captured plane, so input models in front win the depth test and later blends draw over it.
render_mode unshaded, blend_sub, cull_disabled, depth_draw_always, fog_disabled, shadows_disabled;
uniform sampler2D menu_texture : filter_linear, repeat_disable;
// Text bands: keep the eye-buffer panel over semi-transparent edges and the band's top and bottom
// strips, so the compositor's antialiased quad borders stay hidden under matching content.
uniform float coverage_min = 0.001;
uniform float inset_v = 0.0;
// UV distance that must also be covered around the pixel: keeps silhouettes out of the hole.
uniform vec2 erode = vec2(0.0);
void fragment() {
	if (UV.y < inset_v || UV.y > 1.0 - inset_v) { discard; }
	if (texture(menu_texture, UV).a < coverage_min) { discard; }
	if (erode.x > 0.0 && min(min(texture(menu_texture, UV + vec2(erode.x, 0.0)).a, texture(menu_texture, UV - vec2(erode.x, 0.0)).a),
			min(texture(menu_texture, UV + vec2(0.0, erode.y)).a, texture(menu_texture, UV - vec2(0.0, erode.y)).a)) < coverage_min) { discard; }
	ALBEDO = vec3(1.0);
	ALPHA = 1.0;
}
