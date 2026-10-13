shader_type spatial;
// Reeded (fluted) glass for translucent walls: you can tell there is a room
// behind it, but not what is in it. The reeds are vertical half-round ribs,
// drawn from the wall's own coordinates (x runs along it, z across its
// thickness), so they keep their width whatever the wall's length and line up
// across the full wall and the low stub it becomes in the cutaway view.
//
// Cheap on purpose: no screen texture, no refraction. Each rib is lighter and
// clearer along its crest and denser in the groove beside it, which is enough
// to read as glass at the camera distances this game uses.
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_lambert, specular_disabled, shadows_disabled;

uniform vec3 tint : source_color = vec3(0.80, 0.95, 0.93);
uniform vec3 emission : source_color = vec3(1.0);
uniform float emission_energy = 0.0;
uniform float reed_width = 0.055;                       // metres from crest to crest
uniform float clear_alpha : hint_range(0.0, 1.0) = 0.26; // along a rib's crest
uniform float groove_alpha : hint_range(0.0, 1.0) = 0.66; // in the groove between two ribs
uniform float alpha : hint_range(0.0, 1.0) = 1.0;        // overall fade (walls dissolving in and out)

varying vec3 wall_pos;
varying vec3 wall_normal;

void vertex() {
	wall_pos = VERTEX;
	wall_normal = NORMAL;
}

void fragment() {
	// Along the wall on its two faces; across it on the narrow end caps.
	float along = abs(wall_normal.x) > 0.5 ? wall_pos.z : wall_pos.x;
	float crest = sin(fract(along / reed_width) * 3.14159265);   // 0 in the groove, 1 on the crest
	crest = crest * crest;
	bool top_edge = abs(wall_normal.y) > 0.5;

	vec3 colour = tint * mix(0.74, 1.10, crest);
	float a = mix(groove_alpha, clear_alpha, crest);
	if (top_edge) {
		// The cut edge of the pane: a solid pale line, like the edge of real glass.
		colour = tint * 1.05;
		a = 0.92;
	}
	ALBEDO = colour;
	ALPHA = a * alpha;
	ROUGHNESS = 1.0;
	// Light is coming through it: the crests catch the most.
	EMISSION = emission * emission_energy * mix(0.35, 1.0, crest);
}
