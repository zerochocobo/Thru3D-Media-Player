shader_type spatial;
// Clears the eye buffer only where the menu layer beneath it has coverage. The quad lies on the
// captured plane, so input models in front win the depth test and later blends draw over it.
render_mode unshaded, blend_sub, cull_disabled, depth_draw_always, fog_disabled, shadows_disabled;
uniform sampler2D menu_texture : filter_linear, repeat_disable;
void fragment() {
	if (texture(menu_texture, UV).a < 0.001) { discard; }
	ALBEDO = vec3(1.0);
	ALPHA = 1.0;
}
