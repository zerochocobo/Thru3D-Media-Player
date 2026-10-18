shader_type spatial;
render_mode unshaded, cull_back, blend_mix, depth_draw_never;
uniform sampler2D image_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform float turn_light = 1.0;
void fragment() {
	float edge = 0.5 / float(textureSize(image_texture,0).y);
	ALBEDO = texture(image_texture,vec2(UV.x,clamp(UV.y,edge,1.0-edge))).rgb * turn_light;
	ALPHA = 0.30;
}
