// Ink over the finished 3D image, like a drawing (see style/ink_lines.gd).
//
// - Contours, from depth: where a neighbouring pixel is well in front of this
//   one, one thing stands in front of another. The line lands on the far
//   side, just outside the nearer thing.
// - Corners, from the facing pass (InkNormalPass): a texture of which way
//   each styled surface faces, rendered from the same camera. Where that
//   direction changes sharply between neighbouring pixels, two faces meet:
//   a box's edges, a drawer's front, a window's frame.
//
// Both come from the image itself, so they line up and keep the same width
// (a fixed fraction of the view's height) on every piece and at every zoom.
// Drawn on a quad that covers the screen, attached to the camera.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled, blend_mix;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D normal_tex : filter_nearest, repeat_disable;
uniform bool has_normals = false;
uniform vec4 ink_color : source_color = vec4(0.10, 0.15, 0.16, 1.0);
// Line width as a fraction of the viewport height.
uniform float width = 0.0016;
// How big a jump in depth, relative to the distance, makes a contour.
uniform float contour_threshold = 0.012;
// How far apart two neighbouring facing colours must be to make a corner
// (0.34 is about 40 degrees between the faces).
uniform float corner_lo = 0.30;
uniform float corner_hi = 0.42;
uniform float corner_strength = 0.85;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

float view_z(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(uv * 2.0 - 1.0, d * 2.0 - 1.0);
#else
	vec3 ndc = vec3(uv * 2.0 - 1.0, d);
#endif
	vec4 v = inv_proj * vec4(ndc, 1.0);
	return -v.z / v.w;
}

void fragment() {
	vec2 px = vec2(max(width * VIEWPORT_SIZE.y, 1.0)) / VIEWPORT_SIZE;
	float c = view_z(SCREEN_UV, INV_PROJECTION_MATRIX);
	float l = view_z(SCREEN_UV - vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float r = view_z(SCREEN_UV + vec2(px.x, 0.0), INV_PROJECTION_MATRIX);
	float u = view_z(SCREEN_UV - vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	float d = view_z(SCREEN_UV + vec2(0.0, px.y), INV_PROJECTION_MATRIX);
	float near = min(min(l, r), min(u, d));
	float jump = (c - near) / max(c, 1e-4);
	float ink = smoothstep(contour_threshold, contour_threshold * 1.8, jump);

	if (has_normals) {
		// Forward differences only (right and down), so a corner gives one
		// line of the set width rather than one on each side of it.
		vec3 nc = texture(normal_tex, SCREEN_UV).rgb;
		vec3 nr = texture(normal_tex, SCREEN_UV + vec2(px.x, 0.0)).rgb;
		vec3 nd = texture(normal_tex, SCREEN_UV + vec2(0.0, px.y)).rgb;
		float bend = max(length(nc - nr), length(nc - nd));
		// Only between surfaces that are in the facing pass: the black around
		// them (markings, the Miis, the sky) is the contour's job.
		float both = step(0.01, dot(nc, vec3(1.0))) * step(0.01, min(dot(nr, vec3(1.0)), dot(nd, vec3(1.0))));
		ink = max(ink, smoothstep(corner_lo, corner_hi, bend) * corner_strength * both);
	}

	ALBEDO = ink_color.rgb;
	ALPHA = ink_color.a * ink;
}
