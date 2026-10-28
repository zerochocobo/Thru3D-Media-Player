shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha, blend_mix;
uniform sampler2D color_texture : filter_linear, repeat_disable;
vec3 portrait_color(vec2 uv) { return texture(color_texture, uv).rgb; }
#include "res://shaders/video_portrait.gdshaderinc"
