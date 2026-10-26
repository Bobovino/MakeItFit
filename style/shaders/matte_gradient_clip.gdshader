// matte_gradient.gdshader for a piece of furniture standing across a seam of
// a looped flat (LoopSeams): everything outside the room's own floor (clip_min
// .. clip_max, world X/Z) is cut away, so the part past the seam is drawn
// only where it comes back in. Both faces drawn, so the cut reads as solid.
shader_type spatial;
render_mode specular_disabled, cull_disabled;

#define MATTE_CLIP
#include "matte_gradient.gdshaderinc"
