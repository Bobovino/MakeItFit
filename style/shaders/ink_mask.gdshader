// A Mii's silhouette in the ink's facing pass (see style/ink_normal_pass.gd):
// solid black there, which the ink pass reads as "nothing to ink", so the
// corners of furniture behind a Mii are never drawn across it, however close
// it stands (lying on a bed, sitting on a sofa). In the view itself it draws
// nothing. Used as the next pass of the Mii's outline material.
shader_type spatial;
render_mode unshaded, shadows_disabled, fog_disabled;

void fragment() {
	if ((CAMERA_VISIBLE_LAYERS & (1u << 19u)) == 0u) {
		discard;
	}
	ALBEDO = vec3(0.0);
}
