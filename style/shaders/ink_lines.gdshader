// Ink lines on a piece's edges (see style/ink_lines.gd). Every edge between
// two faces is a quad of four vertices: VERTEX is this end, CUSTOM0.xyz the
// other end, UV.x the side (-1/+1), CUSTOM1.xyz and CUSTOM2.xyz the normals
// of the two faces it joins, CUSTOM1.w 1 when the edge is a sharp corner.
//
// An edge is drawn when it's a corner, or when, seen from where the camera is
// now, one of its faces looks towards the camera and the other away: that's
// the piece's contour from this angle, round or square. Any other edge is
// collapsed out of view.
//
// The quad is widened here, in screen space, to a fixed fraction of the
// view's height, so a line keeps its weight at every zoom and on every
// screen, and draws its own pixel of soft edge rather than relying on MSAA.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, blend_mix, depth_draw_never;

uniform vec4 contour_color : source_color = vec4(0.12, 0.18, 0.19, 0.9);
uniform vec4 corner_color : source_color = vec4(0.12, 0.18, 0.19, 0.65);
// Line width as a fraction of the viewport height (0.0012 = 1.1 px at 900p).
uniform float width = 0.0012;
// Pulled this fraction of the way towards the camera, so a line drawn on a
// face isn't half hidden by that same face.
uniform float depth_pull = 0.004;

varying float v_px;      // distance from the line's centre, in pixels
varying float v_half;    // the line's half width, in pixels
varying float v_corner;  // 1 for a corner line, 0 for contour

void vertex() {
	vec4 va = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 vb = MODELVIEW_MATRIX * vec4(CUSTOM0.xyz, 1.0);
	vec3 to_cam = -(va.xyz + vb.xyz) * 0.5;
	vec3 n1 = mat3(MODELVIEW_MATRIX) * CUSTOM1.xyz;
	vec3 n2 = mat3(MODELVIEW_MATRIX) * CUSTOM2.xyz;
	bool contour = (dot(n1, to_cam) > 0.0) != (dot(n2, to_cam) > 0.0);
	bool corner = CUSTOM1.w > 0.5;
	v_corner = (corner && !contour) ? 1.0 : 0.0;
	if (!contour && !corner) {
		POSITION = vec4(0.0, 0.0, 2.0, 1.0);   // outside the view: not drawn
	} else {
		va.xyz *= 1.0 - depth_pull;
		vb.xyz *= 1.0 - depth_pull;
		vec4 a = PROJECTION_MATRIX * va;
		vec4 b = PROJECTION_MATRIX * vb;
		vec2 half_vp = VIEWPORT_SIZE * 0.5;
		vec2 sa = a.xy / max(abs(a.w), 1e-5) * half_vp;
		vec2 sb = b.xy / max(abs(b.w), 1e-5) * half_vp;
		vec2 d = sb - sa;
		float len = length(d);
		vec2 dir = len > 1e-4 ? d / len : vec2(1.0, 0.0);
		vec2 n = vec2(-dir.y, dir.x);
		v_half = max(width * VIEWPORT_SIZE.y, 0.9) * 0.5;
		// A pixel of falloff on each side, and the ends pushed out by half a
		// line so corners join without a notch.
		float reach = v_half + 1.0;
		v_px = UV.x * reach;
		a.xy += (n * UV.x * reach - dir * v_half) / half_vp * a.w;
		POSITION = a;
	}
}

void fragment() {
	vec4 c = mix(contour_color, corner_color, v_corner);
	ALBEDO = c.rgb;
	ALPHA = c.a * clamp(v_half + 0.5 - abs(v_px), 0.0, 1.0);
}
