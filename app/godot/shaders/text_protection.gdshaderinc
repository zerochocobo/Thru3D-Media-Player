// Analytic source-UV mask: no low-resolution depth quantization or extra video texture copy.
uniform int depth_text_count = 0;
uniform vec4 depth_text_regions[8];
uniform vec4 depth_text_weights0 = vec4(1.0);
uniform vec4 depth_text_weights1 = vec4(1.0);
float protected_near(float near_value, vec2 uv) {
	vec2 feather = vec2(2.0) / max(source_size, vec2(1.0));
	float guard = abs(depth_shift) * 0.5 * max(depth_convergence, 1.0-depth_convergence);
	vec2 padding = vec2(guard, feather.y);
	if (rotation_degrees == 90 || rotation_degrees == 270) { padding = vec2(feather.x, guard); }
	float weight = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= depth_text_count) { break; }
		vec4 rect = depth_text_regions[i] + vec4(-padding, padding);
		vec2 d = min(uv-rect.xy, rect.zw-uv);
		vec2 a = smoothstep(vec2(0.0), feather, d);
		float opacity = i < 4 ? depth_text_weights0[i] : depth_text_weights1[i-4];
		weight = max(weight, a.x*a.y*opacity);
	}
	return mix(near_value, depth_convergence, weight);
}
