shader_type spatial;
render_mode unshaded, cull_front;

uniform float outline_width : hint_range(0.0, 0.05) = 0.012;
uniform vec4 outline_color : source_color = vec4(0.02, 0.02, 0.02, 1.0);

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
