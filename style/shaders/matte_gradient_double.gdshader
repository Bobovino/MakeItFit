// Double-sided variant of matte_gradient.gdshader, for walls: the game builds
// wall meshes without a consistent winding and relies on both faces drawing.
// Flat shading takes its normal from the visible surface, so back faces light
// correctly.
shader_type spatial;
render_mode specular_disabled, cull_disabled;

#include "matte_gradient.gdshaderinc"
