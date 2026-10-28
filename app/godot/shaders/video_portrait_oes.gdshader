shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha, blend_mix;
uniform samplerExternalOES color_texture;
uniform vec2 color_uv_scale = vec2(1.0);
vec3 portrait_color(vec2 uv) { return texture(color_texture, uv * color_uv_scale).rgb; }
#include "res://shaders/video_portrait.gdshaderinc"
