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

// Smooth filtering on both: a groove or face narrower than a pixel (a door's
// seam, a frame's bevel) blurs out instead of flickering in and out between
// pixels and drawing dashes.
uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;
uniform sampler2D normal_tex : filter_linear, repeat_disable;
uniform bool has_normals = false;
// How close the camera is compared with the view a room opens with (2 =
// twice as close). Lines get a little heavier close up and corners lighter
// far away, where small pieces' corners crowd together.
uniform float zoom = 1.0;
uniform vec4 ink_color : source_color = vec4(0.10, 0.15, 0.16, 1.0);
// Line width as a fraction of the viewport height.
uniform float width = 0.0012;
// How big a jump in depth, relative to the distance, makes a contour.
uniform float contour_threshold = 0.012;
// How far apart two neighbouring facing directions must be to make a corner
// (0.68 is about 40 degrees between the faces).
uniform float corner_lo = 0.60;
uniform float corner_hi = 0.84;
uniform float corner_strength = 0.85;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

// A facing-pass texel: the face's direction, and its distance in metres
// (w; -1 where the pass saw nothing).
vec4 facing(vec2 uv) {
	vec3 t = texture(normal_tex, uv).rgb;
	if (dot(t, vec3(1.0)) < 0.01) {
		return vec4(0.0, 0.0, 0.0, -1.0);
	}
	vec2 xy = t.xy * 2.0 - 1.0;
	return vec4(xy, sqrt(max(0.0, 1.0 - dot(xy, xy))), t.b * 20.0);
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

// How much ink at `uv`, with neighbours `px` apart.
float ink_at(vec2 uv, vec2 px, mat4 inv_proj) {
	float c = view_z(uv, inv_proj);
	float l = view_z(uv - vec2(px.x, 0.0), inv_proj);
	float r = view_z(uv + vec2(px.x, 0.0), inv_proj);
	float u = view_z(uv - vec2(0.0, px.y), inv_proj);
	float d = view_z(uv + vec2(0.0, px.y), inv_proj);
	// A groove (a door's seam, the gap between two drawers) is a far pixel
	// with nearer surfaces on BOTH sides; a contour has them on one side. A
	// groove narrower than a pixel or two flickered as dashes, so a jump only
	// counts along a direction where the other side isn't nearer too.
	float inv = 1.0 / max(c, 1e-4);
	float jx = max(c - l, c - r) * inv;
	float jy = max(c - u, c - d) * inv;
	float gx = min(c - l, c - r) * inv;
	float gy = min(c - u, c - d) * inv;
	float t2 = contour_threshold * 1.8;
	float ink = max(smoothstep(contour_threshold, t2, jx) * (1.0 - smoothstep(contour_threshold, t2, gx)),
		smoothstep(contour_threshold, t2, jy) * (1.0 - smoothstep(contour_threshold, t2, gy)));

	if (has_normals) {
		// A corner must show both across this pixel's neighbours and across a
		// span twice as wide: a face only a pixel or two wide on screen (a
		// frame's bevel, a moulding) passes the first and not the second, so
		// it draws no dots; a real corner between two faces passes both.
		vec2 sx = vec2(px.x, 0.0);
		vec2 sy = vec2(0.0, px.y);
		vec4 fc = facing(uv);
		vec4 xa = facing(uv - sx);
		vec4 xb = facing(uv + sx);
		vec4 ya = facing(uv - sy);
		vec4 yb = facing(uv + sy);
		float bx = min(length(xa.xyz - xb.xyz),
			length(facing(uv - 2.0 * sx).xyz - facing(uv + 2.0 * sx).xyz));
		float by = min(length(ya.xyz - yb.xyz),
			length(facing(uv - 2.0 * sy).xyz - facing(uv + 2.0 * sy).xyz));
		float bend = max(bx, by);
		// Only between surfaces the pass saw (the rest is the contour's job),
		// and only where nothing outside the pass (a Mii) stands nearer in the
		// real image: there the pass still sees the furniture behind it.
		float seen = step(0.0, min(min(xa.w, xb.w), min(ya.w, yb.w)));
		float uncovered = 1.0 - step(c, fc.w - max(0.15, fc.w * 0.04));
		float strength = corner_strength * mix(0.55, 1.0, smoothstep(0.8, 1.8, zoom));
		ink = max(ink, smoothstep(corner_lo, corner_hi, bend) * strength * seen * uncovered);
	}
	return ink;

}

void fragment() {
	float w = width * clamp(pow(zoom, 0.35), 0.8, 1.2);
	// Whole pixels: offsets that fell between pixels landed on one or the
	// next in a repeating pattern along a slanted edge, and it came out dashed.
	vec2 px = vec2(max(floor(w * VIEWPORT_SIZE.y + 0.5), 1.0)) / VIEWPORT_SIZE;
	// Four samples inside the pixel on a rotated grid, averaged: each one
	// decides ink or no ink, so alone the lines came out stair-stepped and
	// thin ones broke into dashes; together they give a smooth edge.
	vec2 p1 = 1.0 / VIEWPORT_SIZE;
	float ink = ink_at(SCREEN_UV + vec2(-0.125, -0.375) * p1, px, INV_PROJECTION_MATRIX)
		+ ink_at(SCREEN_UV + vec2(0.375, -0.125) * p1, px, INV_PROJECTION_MATRIX)
		+ ink_at(SCREEN_UV + vec2(0.125, 0.375) * p1, px, INV_PROJECTION_MATRIX)
		+ ink_at(SCREEN_UV + vec2(-0.375, 0.125) * p1, px, INV_PROJECTION_MATRIX);
	ink *= 0.25;
	ALBEDO = ink_color.rgb;
	ALPHA = ink_color.a * ink;
}
