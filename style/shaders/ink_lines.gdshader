// Ink lines along a model's creases and outer edges (see style/ink_lines.gd).
// Each edge is a quad of four vertices: VERTEX is this end, CUSTOM0.xyz the
// other end, UV.x the side (-1/+1). The quad is widened here, in screen
// space, so a line keeps the same thickness at every zoom: a fraction of the
// view's height, so it also reads the same on a phone and a large monitor.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 ink_color : source_color = vec4(0.07, 0.13, 0.14, 1.0);
// Line width as a fraction of the viewport height (0.0018 = 1.3 px at 720p).
uniform float width = 0.0018;
// Pulled this fraction of the way towards the camera, so a line drawn on a
// face isn't half hidden by that same face.
uniform float depth_pull = 0.004;

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
	float w = max(width * VIEWPORT_SIZE.y, 1.0) * 0.5;
	// Out to the side, and half a width past the end so corners join up.
	vec2 off = (n * UV.x - dir) * w;
	a.xy += off / half_vp * a.w;
	POSITION = a;
}

void fragment() {
	ALBEDO = ink_color.rgb;
}
