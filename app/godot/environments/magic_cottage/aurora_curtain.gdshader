shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;
uniform float room_light = 1.0;
uniform float age = 0.0;
void vertex() {
	float phase=MODEL_MATRIX[3].z;
	float fold=sin(UV.x*10.+age*.65+phase);
	VERTEX.z+=.62*fold+.20*sin(UV.x*24.-age*.8+phase);
	VERTEX.y+=.28*fold+.23*sin(UV.x*5.+phase);
}
void fragment() {
	float phase=MODEL_MATRIX[3].z;
	float x=UV.x*15.+phase+.58*sin(age*.6);
	float fringe=.20+.60*UV.y+.16*sin(x*1.4+age*.5);
	float columns=.34+.66*pow(.5+.5*sin(x*4.+age*.8+2.*sin(x*1.77)),2.);
	float edge=smoothstep(0.,.18,UV.x)*smoothstep(0.,.18,1.-UV.x);
	float envelope=smoothstep(.10,2.35,age)*(1.-smoothstep(5.5,8.,age));
	ALBEDO=mix(vec3(.10,1.,.49),vec3(.55,.18,1.),.5+.5*sin(x*.43-age*.3));
	ALBEDO *= room_light;
	ALPHA=envelope*edge*smoothstep(0.,.10,UV.y)*smoothstep(0.,.18,1.-UV.y)*columns*fringe*.78;
}
