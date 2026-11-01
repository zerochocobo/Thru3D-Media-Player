shader_type texture_blit;
render_mode blend_disabled;
uniform sampler2D source_texture : hint_blit_source0, filter_nearest, repeat_disable;
void blit() {
	COLOR0 = texture(source_texture, UV);
}
