shader_type spatial;
render_mode cull_disabled, unshaded;
uniform float room_light = 1.0;
uniform float age = 0.0;
void vertex() {
	float beat=sin(age*16.+float(INSTANCE_ID)*2.4);
	VERTEX.y+=UV.y*abs(VERTEX.x)*beat*.83;
}
void fragment() {
	float light=.66+.34*abs(dot(normalize(NORMAL),normalize(vec3(-.37,.68,.53))));
	ALBEDO=COLOR.rgb*light;
	ALBEDO *= room_light;
}
