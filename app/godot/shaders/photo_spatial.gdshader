shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;
uniform sampler2D image_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec2 portal_size = vec2(1.0);
uniform vec3 reference_eye = vec3(0.0, 0.0, 3.0);
uniform vec3 display_scale = vec3(1.0);
varying vec3 local_position;
varying vec3 local_eye;
void vertex() {
	// Reproject from the fixed calibration eye when the user resizes the photo.
	// Scaling Z alone would move interior pixels away from their original image rays.
	vec2 image_point = (UV - vec2(0.5)) * portal_size * vec2(1.0, -1.0);
	vec2 scaled_reference = reference_eye.xy / display_scale.xy;
	VERTEX.xy = scaled_reference + (image_point - scaled_reference) * (1.0 - VERTEX.z * display_scale.z / reference_eye.z);
	local_position = VERTEX;
	// MODELVIEW includes the current rendering eye. Do not use the multiview midpoint
	// or a head-centre uniform: both eyes must intersect the same world-space rectangle.
	local_eye = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}
void fragment() {
	vec3 ray = local_position - local_eye;
	if (abs(ray.z) < 0.00001) { discard; }
	vec2 portal_uv = (local_eye.xy - ray.xy * local_eye.z / ray.z) / portal_size + vec2(0.5);
	float distance_to_edge = min(min(portal_uv.x,1.0-portal_uv.x),min(portal_uv.y,1.0-portal_uv.y));
	if (distance_to_edge <= 0.0) { discard; }
	vec4 color = texture(image_texture, UV);
	// Feather on the fixed portal plane, rather than on a moving depth-texture contour.
	float edge = smoothstep(0.0, 0.004, distance_to_edge);
	ALBEDO = color.rgb;
	ALPHA = color.a * edge;
}
