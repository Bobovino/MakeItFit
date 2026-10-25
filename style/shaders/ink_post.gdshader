// Ink over the finished 3D image, like a drawing (see style/ink_lines.gd).
// Reads the depth of every pixel and its neighbours: where depth jumps, one
// thing stands in front of another (a contour); where it bends, two faces
// meet at a corner. Both become a line of a fixed number of pixels, so every
// piece, wall and tenant is inked the same way at every zoom.
//
// Drawn on a quad that covers the screen, attached to the camera.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled, blend_mix;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 ink_color : source_color = vec4(0.10, 0.15, 0.16, 1.0);
// Line width as a fraction of the viewport height.
uniform float width = 0.0018;
// How big a jump in depth, relative to the distance, makes a contour.
uniform float contour_threshold = 0.012;
// How sharp a bend makes a corner (in units of 1/depth, relative).
uniform float corner_threshold = 0.01;
uniform float corner_strength = 0.75;
// Up to this distance (metres) the corner threshold holds; beyond, it grows.
uniform float corner_near_m = 3.0;

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

	// Contour: the nearest of the neighbours is well in front of this pixel,
	// so the line lands on the far side, just outside the nearer thing.
	float near = min(min(l, r), min(u, d));
	float jump = (c - near) / max(c, 1e-4);
	float contour = smoothstep(contour_threshold, contour_threshold * 1.8, jump);

	// Corner: 1/depth is linear across a flat face on screen, so its second
	// difference is zero there and spikes where two faces meet. Measured two
	// line widths apart, so depth's own rounding doesn't break it into dashes.
	vec2 q = px * 2.0;
	float l2 = view_z(SCREEN_UV - vec2(q.x, 0.0), INV_PROJECTION_MATRIX);
	float r2 = view_z(SCREEN_UV + vec2(q.x, 0.0), INV_PROJECTION_MATRIX);
	float u2 = view_z(SCREEN_UV - vec2(0.0, q.y), INV_PROJECTION_MATRIX);
	float d2 = view_z(SCREEN_UV + vec2(0.0, q.y), INV_PROJECTION_MATRIX);
	float ic = 1.0 / c;
	float bx = abs(1.0 / l2 + 1.0 / r2 - 2.0 * ic) / ic;
	float by = abs(1.0 / u2 + 1.0 / d2 - 2.0 * ic) / ic;
	// Only where the bend isn't already a contour (a jump on either side).
	float far_jump = max(max(abs(l2 - c), abs(r2 - c)), max(abs(u2 - c), abs(d2 - c))) / max(c, 1e-4);
	// The depth buffer's steps are even in 1/depth, so measured this way the
	// rounding grows with distance: the threshold grows with it, or far
	// pieces get freckled with dots.
	float ct = corner_threshold * max(1.0, c / corner_near_m);
	float corner = smoothstep(ct, ct * 2.0, max(bx, by))
		* (1.0 - smoothstep(contour_threshold * 2.0, contour_threshold * 4.0, far_jump))
		* corner_strength;

	float ink = max(contour, corner);
	ALBEDO = ink_color.rgb;
	ALPHA = ink_color.a * ink;
}
