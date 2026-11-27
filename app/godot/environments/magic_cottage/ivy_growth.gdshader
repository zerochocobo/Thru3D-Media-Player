shader_type spatial;
render_mode cull_disabled, unshaded;
uniform float room_light = 1.0;
uniform float height = 0.0;
varying float altitude;

void vertex() {
	altitude = VERTEX.y;
}

void fragment() {
	if (altitude > height) discard;
	float tip = 1.0 - smoothstep(0., .21, height-altitude);
	float rib = (1.0 - smoothstep(.0,.075,abs(UV2.x-.5))) * step(0.,UV2.x);
	ALBEDO = COLOR.rgb * (.75+.25*abs(NORMAL.z)) + vec3(.30,.49,.21)*(tip+.32*rib);
	ALBEDO *= room_light;
}
