shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D menu_texture : source_color, filter_linear, repeat_disable;
void fragment() { COLOR = texture(menu_texture, UV); }
