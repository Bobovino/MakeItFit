// Transparent variant of matte_gradient.gdshader, for placement ghosts and
// fading walls: same look, plus an `alpha` uniform. Kept separate so ordinary
// surfaces stay in the cheap opaque pass. The depth prepass stops a
// see-through model from showing its own back parts through its front.
shader_type spatial;
render_mode specular_disabled, blend_mix, depth_prepass_alpha;

#define MATTE_ALPHA
#include "matte_gradient.gdshaderinc"
