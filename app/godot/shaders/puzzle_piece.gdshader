shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;
uniform sampler2D image_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D panorama_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool panorama = false;
uniform vec3 cube_centre = vec3(0.0,0.0,-1.0);
uniform vec3 cube_right = vec3(1.0,0.0,0.0);
uniform vec3 cube_up = vec3(0.0,1.0,0.0);
uniform float turn_light = 1.0;
uniform int stereo_layout = 0;
uniform bool swap_eyes = false;
uniform float spatial_disparity = 0.0;
uniform vec3 body_color : source_color = vec3(0.38, 0.31, 0.22);
uniform int test_eye = -1;
varying flat int eye;
varying float face;
varying vec3 world_normal;
varying vec3 photo_direction;
void vertex() {
	eye = test_eye >= 0 ? test_eye : int(VIEW_INDEX);
	face = COLOR.a;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	photo_direction = normalize(cube_centre+cube_right*(UV.x*2.0-1.0)+cube_up*(1.0-UV.y*2.0));
}
void fragment() {
	vec2 p = UV;
	int source_eye = swap_eyes ? 1-eye : eye;
	if (stereo_layout != 0) {
		p.x += (source_eye == 0 ? 0.5 : -0.5) * spatial_disparity;
		vec2 eye_size = vec2(textureSize(image_texture, 0));
		if (stereo_layout == 1) eye_size.x *= 0.5; else eye_size.y *= 0.5;
		p = clamp(p, vec2(0.5)/eye_size, vec2(1.0)-vec2(0.5)/eye_size);
		if (stereo_layout == 1) p.x = (p.x + float(source_eye))*0.5;
		else p.y = (p.y + float(source_eye))*0.5;
	}
	vec3 color;
	if (panorama) {
		vec3 d = normalize(photo_direction);
		p = vec2(atan(d.x, -d.z) / 6.28318530718 + 0.5, acos(clamp(d.y,-1.0,1.0)) / 3.14159265359);
		float edge = 0.5 / float(textureSize(panorama_texture, 0).y);
		p.y = clamp(p.y,edge,1.0-edge);
		vec2 dx = dFdx(p); vec2 dy = dFdy(p);
		dx.x -= round(dx.x); dy.x -= round(dy.x);
		float pole_weight = sqrt(max(1.0-d.y*d.y,0.000001));
		dx.x *= pole_weight; dy.x *= pole_weight;
		color = textureGrad(panorama_texture,p,dx,dy).rgb;
	} else { color = texture(image_texture, p).rgb; }
	float light = 0.5 + 0.5*max(dot(normalize(world_normal), normalize(vec3(-0.45, 0.75, 0.6))), 0.0);
	ALBEDO = (face > 0.5 ? color : body_color*light) * turn_light;
}
