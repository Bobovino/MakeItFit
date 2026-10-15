class_name StyleQuality
extends RefCounted

# Optional quality tiers layered on top of the base look.
#
#   LOW    - base look only: matte gradient materials, tinted light, one
#            shadowed sun, backdrop, fog, tonemap. Nothing post-processed.
#   MEDIUM - adds glow (windows/lamps only) and the vignette.
#   HIGH   - adds SSAO and, if asked for, a subtle far depth of field.
#
# Each effect is switched on only where the running renderer supports it, so
# asking for HIGH on Compatibility or Mobile quietly degrades instead of
# erroring. The base look never depends on any of these.

enum Level { LOW, MEDIUM, HIGH }

# i18n-const
const LEVEL_NAMES := ["Low", "Medium", "High"]


# "forward_plus", "mobile" or "gl_compatibility" - the renderer actually
# running, which can differ from the project setting (command-line override,
# or the automatic fallback to Compatibility on unsupported hardware).
static func rendering_method() -> String:
	return RenderingServer.get_current_rendering_method()


static func supports_glow() -> bool:
	return true   # all three renderers


# Forward+ only. Mobile has no SSAO. Compatibility does have it in Godot 4.7,
# but with this look it draws a stippled patch on walls next to tall
# furniture, so it stays off there.
static func supports_ssao() -> bool:
	return rendering_method() == "forward_plus"


static func supports_dof() -> bool:
	return rendering_method() != "gl_compatibility"


# A safe starting tier: LOW on phones and the web, MEDIUM elsewhere. HIGH is
# never picked automatically.
static func recommended() -> Level:
	if OS.has_feature("mobile") or OS.has_feature("web"):
		return Level.LOW
	return Level.MEDIUM


# Short human-readable list of what a tier really enables on this renderer.
static func describe(level: Level, want_dof: bool = false) -> String:
	var parts: PackedStringArray = ["base"]
	if level >= Level.MEDIUM:
		parts.append("glow")
		parts.append("vignette")
	if level >= Level.HIGH:
		parts.append("SSAO" if supports_ssao() else "SSAO unsupported")
		if want_dof:
			parts.append("DOF" if supports_dof() else "DOF unsupported")
	return ", ".join(parts)


# Edge smoothing for the viewport the room is drawn in. Each 3D view renders
# into its own SubViewport, which does not inherit the project's settings, so
# without this every silhouette is stair-stepped. MSAA works on every
# renderer, Compatibility included, and is cheap on the tile-based GPUs of
# phones; Low still gets 2x since aliasing is the most visible flaw of all.
static func apply_viewport(vp: Viewport, level: Level) -> void:
	if vp == null:
		return
	vp.msaa_3d = Viewport.MSAA_2X if level == Level.LOW else Viewport.MSAA_4X


static func apply_environment(env: Environment, level: Level) -> void:
	# Additive glow with no bloom and an HDR threshold of 1: only emissive
	# surfaces brighter than white (windows, lamps) contribute, so the rest of
	# the image stays crisp for reading the puzzle.
	env.glow_enabled = level >= Level.MEDIUM and supports_glow()
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_intensity = 0.35
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.2

	env.ssao_enabled = level >= Level.HIGH and supports_ssao()
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.2
	env.ssao_power = 1.5


# Far-only blur that starts toward the back of the level and never touches
# its centre or front. (Starting it fully behind the level would do nothing:
# the only thing back there is the backdrop gradient.) Only replaces camera attributes this script created.
static func apply_camera(camera: Camera3D, level: Level, want_dof: bool, focus_depth: float, scene_radius: float) -> void:
	if camera == null:
		return
	var ours := camera.attributes != null and camera.attributes.has_meta("style_quality")
	if level >= Level.HIGH and want_dof and supports_dof():
		if camera.attributes != null and not ours:
			return   # the level set its own attributes; leave them alone
		var attrs := CameraAttributesPractical.new()
		attrs.set_meta("style_quality", true)
		attrs.dof_blur_far_enabled = true
		attrs.dof_blur_far_distance = focus_depth + scene_radius * 0.5
		attrs.dof_blur_far_transition = scene_radius * 1.5
		attrs.dof_blur_amount = 0.1
		camera.attributes = attrs
	elif ours:
		camera.attributes = null


# Directional shadow atlas size and filter are global (RenderingServer), not
# per viewport. Kept modest on every tier.
static func apply_global_shadows(level: Level) -> void:
	RenderingServer.directional_shadow_atlas_set_size(1024 if level == Level.LOW else 2048, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_LOW)
