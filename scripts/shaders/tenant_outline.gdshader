shader_type spatial;
render_mode unshaded, cull_front;

uniform float outline_width : hint_range(0.0, 0.05) = 0.012;
uniform vec4 outline_color : source_color = vec4(0.02, 0.02, 0.02, 1.0);

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	// Not in the ink's facing pass (style/ink_normal_pass.gd): there the Mii
	// is only a black silhouette (ink_mask, this material's next pass).
	if ((CAMERA_VISIBLE_LAYERS & (1u << 19u)) != 0u) {
		discard;
	}
	ALBEDO = outline_color.rgb;
}
