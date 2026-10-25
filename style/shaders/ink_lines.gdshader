// Ink lines along a model's creases and outer edges (see style/ink_lines.gd).
// Each edge is a quad of four vertices: VERTEX is this end, CUSTOM0.xyz the
// other end, UV.x the side (-1/+1). The quad is widened here, in screen
// space, so a line keeps the same thickness at every zoom: a fraction of the
// view's height, so it also reads the same on a phone and a large monitor.
//
// Each line draws its own soft edge (a pixel of falloff either side) rather
// than relying on the view's MSAA, which left thin lines stair-stepped.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, blend_mix, depth_draw_never;

uniform vec4 ink_color : source_color = vec4(0.12, 0.18, 0.19, 0.8);
// Line width as a fraction of the viewport height (0.0011 = 1 px at 900p).
uniform float width = 0.0011;
// Pulled this fraction of the way towards the camera, so a line drawn on a
// face isn't half hidden by that same face.
uniform float depth_pull = 0.004;

varying float v_px;      // distance from the line's centre, in pixels
varying float v_half;    // the line's half width, in pixels

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
	vec2 dir = len > 1e-4 ? d / len : vec2(1.0, 0.0);
	vec2 n = vec2(-dir.y, dir.x);
	v_half = max(width * VIEWPORT_SIZE.y, 0.9) * 0.5;
	// One pixel of falloff on each side, and the ends pushed out by half a
	// line so corners join without a notch.
	float reach = v_half + 1.0;
	v_px = UV.x * reach;
	vec2 off = n * UV.x * reach - dir * v_half;
	a.xy += off / half_vp * a.w;
	POSITION = a;
}

void fragment() {
	ALBEDO = ink_color.rgb;
	ALPHA = ink_color.a * clamp(v_half + 0.5 - abs(v_px), 0.0, 1.0);
}
