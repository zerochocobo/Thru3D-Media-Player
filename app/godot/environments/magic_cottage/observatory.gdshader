shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
uniform sampler2D charts : source_color, filter_linear_mipmap, repeat_disable;
uniform float clock = 0.0;
uniform int spell = -2;
uniform float age = 0.0;
uniform float pane = 0.0;
uniform float brightness = 1.0;
uniform bool playing = false;
float hash(vec2 p) {return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
mat2 turn(float a){return mat2(vec2(cos(a),sin(a)),vec2(-sin(a),cos(a)));}
float stars(vec2 p,float t) {
	vec2 i=floor(p), f=fract(p)-vec2(hash(i),hash(i+51.0));
	return (1.0-smoothstep(.018,.083,length(f)))*(.55+.45*sin(t+hash(i+17.0)*6.28))*step(.68,hash(i+3.0));
}
vec3 chart(float index,vec2 uv) {
	float k=mod(index*17.0,64.0);
	return texture(charts,(vec2(mod(k,8.0),floor(k/8.0))+clamp(uv,.002,.998))/8.0).rgb;
}
void fragment() {
	// The movie covers the arch: skip the stars and chart lookups behind it.
	if(playing && pane==0.0) {
		ALBEDO=vec3(.005,.007,.014)*brightness;
	} else {
		vec2 p=UV-.5;
		float t=clock;
		vec2 sky=p*vec2(pane==0.0?1.2:.55,1.0)+vec2(pane*.37,.0);
		float f=stars(sky*61.0,t*1.1)+.45*stars(sky*103.0,t*.7);
		vec3 col=vec3(.011,.020,.063)+vec3(.65,.79,1.)*f;
		if(pane==0.0) {
			float ct=t/8.0;
			vec2 q=UV;
			if(spell==7){q=turn(-age*.34)*p+.5;ct=(t-age*3.7)/8.;}
			vec2 main_uv=(q-.5)*1.42+.5;
			float edge=1.-smoothstep(.45,.57,max(abs(main_uv.x-.5),abs(main_uv.y-.5)));
			col+=mix(chart(floor(ct),main_uv),chart(floor(ct)+1.,main_uv),smoothstep(.72,1.,fract(ct)))*1.70*edge;
			// Smaller charts move through a separate sequence around the vault.
			vec2 local=fract(q*vec2(4.,3.));
			vec2 cell=floor(q*vec2(4.,3.));
			float field=smoothstep(.35,.46,max(abs(q.x-.5)*1.3,abs(q.y-.5)*1.29));
			float satellite=ct*.53+cell.x*7.+cell.y*11.+.31;
			vec3 small=mix(chart(floor(satellite),local),chart(floor(satellite)+1.,local),smoothstep(.68,1.,fract(satellite)));
			col+=small*field*.39*(1.-smoothstep(.40,.50,max(abs(local.x-.5),abs(local.y-.5))));
		} else {
			col+=vec3(.026,.032,.09)*(.5+.5*sin(4.*sky.x+5.*sky.y+.45*sin(7.*sky.y)));
		}
		float env=smoothstep(0.,.8,age)*(1.-smoothstep(6.,8.,age));
		vec3 effect=col;
		if(spell==1 && pane==0.0) effect=col*(.14+.86*smoothstep(-.2,.27,abs(p.x-.45*sin(age*.86))-.19));
		if(spell==1 && pane!=0.0) {
			vec2 q=p*vec2(1.,1.84);
			float blink=(age-4.6)*6.;
			float lid=.68*(1.-.93*exp(-blink*blink));
			float eye=1.-smoothstep(.005,.055,abs(q.y)-lid*(1.-pow(min(abs(q.x)*1.44,1.),1.6)));
			vec2 offset=q-vec2(.12*sin(age*.86),.04*sin(age*.67));
			float iris=length(offset);
			float rays=sin(atan(offset.y,offset.x)*77.+iris*25.)*.16+sin(atan(offset.y,offset.x)*33.-iris*37.)*.14;
			vec3 detail=mix(vec3(.50,.29,.18),mix(vec3(.11,.46,.38),vec3(.61,.39,.12),smoothstep(.17,.33,iris))*(.83+rays),1.-smoothstep(.35,.37,iris));
			detail=mix(vec3(.003),detail,smoothstep(.125,.134,iris));
			detail+=vec3(.8)* (1.-smoothstep(.012,.033,length(q-vec2(.08,-.07))));
			effect=mix(vec3(.12,.062,.055)*(1.+.24*sin(q.y*37.+q.x*6.)),detail,eye);
		}
		if(spell==2){
			vec2 q=p*vec2(pane==0.?1.2:.6,1.);
			float r=length(q);
			float swell=smoothstep(.15,2.6,age);
			float disk=(pane==0.0?.265:.13)*swell;
			float ring=exp(-abs(r-disk-.015)*41.);
			float blast=exp(-abs(r-age*.52)*45.);
			float swirl=.5+.5*cos(atan(q.y,q.x)*4.+16.*log(max(r,.018))-age*2.8);
			float cloud=pow(swirl,3.)*exp(-abs(r-disk-.053)*10.)*swell;
			effect=col*smoothstep(disk-.018,disk+.018,r)+vec3(1.,.40,.12)*ring+vec3(.67,.28,.50)*cloud*smoothstep(disk,disk+.015,r)+blast*vec3(.8,.65,1.);
		}
		if(spell==3){
			float curtain=exp(-abs(p.y-.06-.12*sin(p.x*8.+age*.6)-.04*sin(p.x*24.-age))*9.);
			effect+=curtain*mix(vec3(.035,.80,.39),vec3(.38,.10,.73),.5+.5*sin(p.x*7.+age));
		}
		if(spell==5){
			vec2 q=abs(fract(UV*vec2(6.,9.)+vec2(.17,0.))-.5);
			float vane=exp(-min(abs(q.x-.56*q.y),abs(q.y-.56*q.x))*72.);
			float edge=smoothstep(.08,.47,max(abs(p.x),abs(p.y))+.10*sin(age*.5));
			effect+=vec3(.29,.68,.94)*vane*edge;
		}
		if(spell==6){
			vec2 q=turn(.62)*p*vec2(11.,3.);
			float k=hash(vec2(floor(q.x),pane));
			float trail=(1.-smoothstep(.008,.036,abs(fract(q.x)-k)))*exp(-fract(q.y-age*(1.+k)+k*12.)*8.);
			effect+=vec3(.67,.85,1.)*trail*2.2;
		}
		if(spell==7 && pane!=0.) effect+=.7*stars((turn(-age*.30)*sky)*43.,t)*vec3(.65,.40,.88);
		col=mix(col,effect,env);
		ALBEDO=col*brightness;
	}
}
