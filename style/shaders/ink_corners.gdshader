// Ink on a piece's sharp corners (see style/ink_corners.gd): the inner edges
// a depth pass can't see cleanly, such as a box's front edges, a drawer's
// seams or a window frame. The contours come from the depth pass
// (ink_post). Each edge is a quad of four vertices: VERTEX is this end,
// CUSTOM0.xyz the other end, UV.x the side (-1/+1). The quad is widened
// here, in screen space, to a fixed fraction of the view's height, draws its
// own pixel of soft edge, and is pulled towards the camera so the two faces
// meeting at the corner don't cover it.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, blend_mix, depth_draw_never;

uniform vec4 ink_color : source_color = vec4(0.10, 0.15, 0.16, 0.75);
// Line width as a fraction of the viewport height (matches ink_post).
uniform float width = 0.0014;
// Pulled this fraction of the way towards the camera.
uniform float depth_pull = 0.01;

varying float v_px;      // distance from the line's centre, in pixels
varying float v_half;    // the line's half width, in pixels
varying float v_fade;    // 0 for a segment too short on screen to read

// A segment shorter than this on screen (pixels) fades out: a rounded rim
// built of tiny sharp facets turned into a scribble from a distance, while
// a box's long edges stay.
uniform float min_len_px = 4.0;
uniform float full_len_px = 10.0;

void vertex() {
	vec4 va = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 vb = MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0);
	va.xyz *= 1.0 - depth_pull;
	vb.xyz *= 1.0 - depth_pull;
	vec4 a = PROJECTION_MATRIX * va;
	vec4 b = PROJECTION_MATRIX * vb;
	vec2 half_vp = VIEWPORT_SIZE * 0.5;
	vec2 sa = a.xy / max(abs(a.w), 1e-5) * half_vp;
	vec2 sb = b.xy / max(abs(b.w), 1e-5) * half_vp;
	vec2 d = sb - sa;
	float len = length(d);
	v_fade = smoothstep(min_len_px, full_len_px, len);
	vec2 dir = len > 1e-4 ? d / len : vec2(1.0, 0.0);
	vec2 n = vec2(-dir.y, dir.x);
	v_half = max(width * VIEWPORT_SIZE.y, 0.9) * 0.5;
	float reach = v_half + 1.0;
	v_px = UV.x * reach;
	a.xy += (n * UV.x * reach - dir * v_half) / half_vp * a.w;
	POSITION = a;
}

void fragment() {
	ALBEDO = ink_color.rgb;
	ALPHA = ink_color.a * v_fade * clamp(v_half + 0.5 - abs(v_px), 0.0, 1.0);
}
