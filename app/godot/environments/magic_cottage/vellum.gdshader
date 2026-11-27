shader_type spatial;
render_mode unshaded, cull_disabled;
varying vec2 page_uv;
void vertex(){page_uv=VERTEX.xy/vec2(.382,.451)+.5;}
float noise_at(vec2 g){return fract(sin(dot(g,vec2(19.27,72.47)))*4719.11);}
float cloud(vec2 p){
	vec2 g=floor(p),f=fract(p); f=f*f*(3.-2.*f);
	return mix(mix(noise_at(g),noise_at(g+vec2(1,0)),f.x),mix(noise_at(g+vec2(0,1)),noise_at(g+vec2(1)),f.x),f.y);
}
void fragment(){
	vec2 p=page_uv; vec2 edge=min(p,1.-p);
	float sides=min(edge.x,edge.y);
	float stain=cloud(p*6.)*.48+cloud(p*27.)*.26+noise_at(floor(p*520.))*.26;
	vec3 stock=mix(vec3(.63,.45,.23),vec3(.90,.79,.57),.53+.43*stain);
	stock*=.85+.15*smoothstep(0.,.08,sides);
	float border=1.-smoothstep(.0016,.0032,min(abs(sides-.035),abs(sides-.043)));
	float ornament=step(edge.x,.14)*step(edge.y,.13)*(1.-smoothstep(.0015,.0035,abs(length((edge-vec2(.049,.052))*vec2(1.,1.2))-.037)));
	ALBEDO=mix(stock,vec3(.45,.30,.14),max(border*.62,ornament*.80));
}
