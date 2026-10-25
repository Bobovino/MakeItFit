// Body shared by matte_gradient.gdshader (opaque) and
// matte_gradient_alpha.gdshader (transparent). Edit the look here.

uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 shadow_tint : source_color = vec3(0.2, 0.35, 0.4);
uniform float shadow_fill : hint_range(0.0, 1.0) = 0.3;

uniform float grad_y_min = 0.0;
uniform float grad_y_max = 2.4;
uniform float grad_bottom : hint_range(0.0, 2.0) = 0.8;
uniform float grad_top : hint_range(0.0, 2.0) = 1.05;

// Per-face normals from screen-space derivatives: hard low-poly facets even
// on meshes exported with smooth normals.
uniform bool flat_shading = true;

// Cut face: upward faces take this flat colour instead of the tint and the
// gradient. On walls it makes the top read as a clean slice, like a section
// model, whether the wall is at full height or lowered to a stub.
uniform vec3 top_tint : source_color = vec3(1.0);
uniform float top_tint_amount : hint_range(0.0, 1.0) = 0.0;

// Floorboards: bands of slightly different tone running along world X,
// broken into boards of uneven length. Flat tones only (no thin seam lines),
// so it stays stable when the camera moves. 0 turns it off.
uniform float pattern_strength : hint_range(0.0, 0.3) = 0.0;
uniform float plank_width = 0.2;

uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;

#ifdef MATTE_ALPHA
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
// Optional dissolve by world height: fully faded at fade_y_min, solid from
// fade_y_max up. Used by the plinth under a level; off by default.
uniform float fade_y_min = -100000.0;
uniform float fade_y_max = -99999.0;
#endif

// Lambert normalisation, per renderer. Forward+ and Mobile add every light in
// linear space. Compatibility draws a shadowed light in a separate additive
// pass that is blended AFTER tonemapping/sRGB encoding, so the same energy
// lands far brighter there (measured in 4.7: ambient-only and sun-only frames
// match Forward+, the two together do not). The Compatibility factor is an
// empirical fit that keeps one palette looking close on all three renderers;
// it cannot be exact, so judge final colours on the renderer you ship.
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
const float LAMBERT = 0.055;
#else
const float LAMBERT = 1.0 / PI;
#endif

varying vec3 world_pos;
varying float face_up;   // 1 on faces pointing straight up

float plank_hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	face_up = normalize(MODEL_NORMAL_MATRIX * NORMAL).y;
}

void fragment() {
	float world_y = world_pos.y;
	float g = smoothstep(grad_y_min, grad_y_max, world_y);
	ALBEDO = tint * COLOR.rgb * mix(grad_bottom, grad_top, g);
	ALBEDO = mix(ALBEDO, top_tint, top_tint_amount * step(0.9, face_up));
	// Boards only on upward faces, so things that merely share the floor's
	// colour (window frames, the slab's sides) stay plain.
	if (pattern_strength > 0.0 && face_up > 0.9) {
		float row = floor(world_pos.z / plank_width);
		float board = floor(world_pos.x / (plank_width * 6.0) + plank_hash(row));
		ALBEDO *= 1.0 - pattern_strength * plank_hash(row * 7.0 + board * 13.0);
	}
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	EMISSION = emission * emission_energy;
	if (flat_shading) {
		NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	}
#ifdef MATTE_ALPHA
	ALPHA = alpha * smoothstep(fade_y_min, fade_y_max, world_y);
#endif
	// The ink's facing pass (style/ink_normal_pass.gd, its camera has layer
	// 20): paint which way this face points, nothing else. Albedo 0 leaves
	// the lights nothing to add.
	if ((CAMERA_VISIBLE_LAYERS & (1u << 19u)) != 0u) {
		ALBEDO = vec3(0.0);
		EMISSION = NORMAL * 0.5 + 0.5;
#ifdef MATTE_ALPHA
		// See-through things (a placement ghost, a fading wall) aren't
		// solid: no corners of their own.
		if (ALPHA < 0.99) {
			discard;
		}
		ALPHA = 1.0;
#endif
	}
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	if (LIGHT_IS_DIRECTIONAL) {
		// lit = 1 in full sun, 0 in shadow or facing away. The unlit end is
		// the palette's shadow tint rather than zero, which is what colours
		// the shadows.
		float lit = ndl * ATTENUATION;
		DIFFUSE_LIGHT += LIGHT_COLOR * LAMBERT * mix(shadow_tint * shadow_fill, vec3(1.0), lit);
	} else {
		DIFFUSE_LIGHT += LIGHT_COLOR * LAMBERT * ndl * ATTENUATION;
	}
}
