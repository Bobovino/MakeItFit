// Gradient backdrop behind the floating diorama. StyleController keeps this
// quad glued to the camera, far away and scaled to fill the view, so it is
// ordinary geometry: it sorts behind the level on every renderer, in a
// SubViewport or not, with a perspective or an orthographic camera.
// Done as a mesh rather than a Sky because a sky has no usable gradient under
// an orthographic camera (every pixel looks in the same direction).
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, shadows_disabled;

uniform vec3 top_color : source_color = vec3(0.87, 0.92, 0.91);
uniform vec3 bottom_color : source_color = vec3(0.7, 0.8, 0.78);
// Soft lighter patch behind the level, so the block separates from the haze.
uniform float center_lift : hint_range(0.0, 0.5) = 0.08;

void fragment() {
	// Remap the quad's UVs (v runs down the screen) to -1..1 with +Y up.
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float t = smoothstep(-0.9, 0.9, p.y);
	vec3 col = mix(bottom_color, top_color, t);
	float r = clamp(1.0 - length(p * vec2(0.8, 1.0)), 0.0, 1.0);
	ALBEDO = col + center_lift * r * r;
}
