// Subtle hue-tinted vignette on a full-rect ColorRect. A plain alpha blend,
// no screen texture read, so it costs next to nothing on any renderer.
shader_type canvas_item;

uniform vec3 color : source_color = vec3(0.14, 0.28, 0.3);
uniform float strength : hint_range(0.0, 1.0) = 0.22;
uniform float inner : hint_range(0.0, 1.5) = 0.55;
uniform float outer : hint_range(0.0, 2.0) = 1.45;

void fragment() {
	float r = length((UV - 0.5) * 2.0);
	COLOR = vec4(color, smoothstep(inner, outer, r) * strength);
}
