shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float elapsed = 0.0;
void fragment() {
	vec2 p = UV * vec2(1.7778, 1.0);
	float horizon = 0.55 + 0.035 * sin(p.x * 4.0 + elapsed * 0.15);
	vec3 sky = mix(vec3(0.025, 0.055, 0.14), vec3(0.21, 0.43, 0.50), smoothstep(0.0, 0.85, p.y));
	float sun = 1.0 - smoothstep(0.104, 0.109, length(p - vec2(1.13, 0.39)));
	sky = mix(sky, vec3(0.95, 0.70, 0.38), sun);
	float ridge = horizon + 0.08 * sin(p.x * 5.0) + 0.04 * sin(p.x * 11.0 + 1.0);
	vec3 color = mix(sky, vec3(0.045, 0.12, 0.18), step(ridge, p.y));
	float near_ridge = 0.78 + 0.045 * sin(p.x * 4.0 - elapsed * 0.025);
	color = mix(color, vec3(0.018, 0.052, 0.075), step(near_ridge, p.y));
	ALBEDO = color;
}
