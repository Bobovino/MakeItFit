// Shared matte, flat-shaded surface for the diorama look.
//
//   albedo = tint (from the LevelPalette) x vertex colour x vertical gradient
//
// - Vertex colour is used when the mesh has it; meshes without a colour layer
//   read as white, so the tint and the gradient fallback carry the look alone.
// - The gradient runs on WORLD Y between grad_y_min and grad_y_max, darker at
//   the bottom, so nothing looks like flat paper and furniture sits in a soft
//   fake-occlusion band near the floor without any SSAO.
// - Roughness 1, metallic 0, specular off.
// - Shadows and unlit faces are filled with shadow_tint instead of black.
//
// Everything here is cheap enough for the Compatibility renderer / Android:
// no textures, no screen reads, one varying.
shader_type spatial;
render_mode specular_disabled;

#include "matte_gradient.gdshaderinc"
