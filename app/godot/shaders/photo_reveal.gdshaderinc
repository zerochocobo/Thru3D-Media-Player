// The same per-eye surface coordinates reveal colour and dissolve the frosted cover.
float photo_reveal_coordinate(vec2 uv) {
	return dot(uv, vec2(0.82, 0.18));
}

float photo_reveal_clear(vec2 uv, float progress) {
	if (progress <= 0.0) { return 0.0; }
	if (progress >= 1.0) { return 1.0; }
	float front = mix(-0.12, 1.12, progress);
	return 1.0 - smoothstep(front - 0.06, front + 0.06, photo_reveal_coordinate(uv));
}

// White translucent frost, shared by full-photo covers and unloaded gallery cards.
vec4 photo_loading_glass(vec2 uv, vec2 size, float clock, float reveal) {
	float grain = fract(sin(dot(floor(uv * size * 800.0), vec2(12.9898, 78.233))) * 43758.5453);
	float front = reveal < 0.0 ? mix(-0.22, 1.22, fract(clock / 4.0)) : mix(-0.12, 1.12, reveal);
	float light = 1.0 - smoothstep(0.025, reveal < 0.0 ? 0.25 : 0.13, abs(photo_reveal_coordinate(uv) - front));
	float mist = sin(clock * 0.9 + uv.x * 4.0 + uv.y * 6.0);
	vec3 frost = mix(vec3(0.93, 0.95, 0.97), vec3(0.98, 0.99, 1.0), uv.y);
	frost += (grain - 0.5) * 0.025 + mist * 0.008;
	frost = mix(frost, vec3(1.0), light * 0.75);
	float covered = reveal < 0.0 ? 1.0 : 1.0 - photo_reveal_clear(uv, reveal);
	return vec4(frost, (0.54 + light * 0.14) * covered);
}
