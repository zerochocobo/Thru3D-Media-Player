shader_type spatial;
render_mode cull_disabled, unshaded;
uniform float room_light = 1.0;
void vertex() {
	float weight=UV.y;
	VERTEX.y+=weight*.010*sin(TIME*1.48);
	VERTEX.x+=weight*.0035*cos(TIME*1.08);
}
void fragment() {
	vec3 dye=COLOR.rgb;
	if(UV2.x>=0.){
		float half_width=abs(UV2.x-.5)*2.;
		float vein=abs(fract(UV2.y*7.-half_width*.86-.28*half_width*half_width)-.5);
		float rib=(1.-smoothstep(.018,.068,vein))*sin(clamp(UV2.y,0.,1.)*3.14159)*(1.-half_width*.76);
		float mid=1.-smoothstep(.012,.039,half_width);
		dye=mix(dye*vec3(.93,.97,.93),min(vec3(1.),dye+vec3(.14,.105,.058)),rib*.55+mid*.55);
	}
	if(!OUTPUT_IS_SRGB) dye=mix(dye/12.92,pow((dye+vec3(.055))/1.055,vec3(2.4)),step(vec3(.04045),dye));
	// Unshaded like the baked room: a fixed warm key from the hearth side plus a soft fill.
	float key=clamp(dot(normalize(NORMAL),normalize((VIEW_MATRIX*vec4(.55,.70,.45,0.)).xyz)),0.,1.);
	vec3 glow=dye*UV.x*(.80+.20*sin(TIME*1.9+VERTEX.y*4.));
	ALBEDO=(dye*(.42+.58*key)*vec3(1.,.93,.84)+glow)*room_light;
}
