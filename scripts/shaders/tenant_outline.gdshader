shader_type spatial;
render_mode unshaded, cull_front;

// A Mii's outline: the body again, pushed out along its normals and drawn
// back faces only, so a rim shows round the edge. The push is measured on
// screen, in pixels, so the line is equally solid near and far: a fixed
// thickness in metres went under a pixel in the small portraits and when
// zoomed out, and broke up into dashes.
uniform float outline_px : hint_range(0.0, 8.0) = 1.6;
uniform vec4 outline_color : source_color = vec4(0.02, 0.02, 0.02, 1.0);

void vertex() {
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_n = mat3(MODELVIEW_MATRIX) * NORMAL;
	vec2 dir = (PROJECTION_MATRIX * vec4(view_n, 0.0)).xy;
	if (length(dir) > 1e-5) {
		// Pixels to clip space: 2 / viewport size per pixel, times w.
		clip.xy += normalize(dir) * outline_px * 2.0 / VIEWPORT_SIZE * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	// Not in the ink's facing pass (style/ink_normal_pass.gd): there the Mii
	// is only a black silhouette (ink_mask, this material's next pass).
	if ((CAMERA_VISIBLE_LAYERS & (1u << 19u)) != 0u) {
		discard;
	}
	ALBEDO = outline_color.rgb;
}
