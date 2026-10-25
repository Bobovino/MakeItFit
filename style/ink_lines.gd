class_name InkLines
extends RefCounted

# The illustrated look: thin ink around everything in the 3D room, like a
# drawing. One pass over the finished image (shaders/ink_post) reads the
# depth of each pixel and its neighbours: where depth jumps, one thing
# stands in front of another (a contour); where it bends, two faces meet at a
# corner. So every piece, wall and tenant is inked the same way, a rounded
# bath as cleanly as a box, with lines a fixed fraction of the view's height
# wide at every zoom and on every screen.
#
# Things that don't write depth get no ink of their own: placement ghosts,
# glass, floor markings. That's wanted: they're not solid objects.
#
# Lines found on the models themselves were tried first and dropped: the
# faces they sat on half covered them, so rounded rims came out as broken,
# doubled strokes.
#
# The Miis keep their own thin hull outline as well (TenantMii), so they're
# outlined in the project map's portrait too; mii_outline_material() gives it
# the same ink.

const POST_SHADER := preload("res://style/shaders/ink_post.gdshader")
const MII_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")
const NODE_NAME := "InkPass"
const MII_WIDTH := 0.008

static var _post: ShaderMaterial
static var _mii: ShaderMaterial


static func post_material() -> ShaderMaterial:
	if _post == null:
		_post = ShaderMaterial.new()
		_post.shader = POST_SHADER
	return _post


static func mii_outline_material() -> ShaderMaterial:
	if _mii == null:
		_mii = ShaderMaterial.new()
		_mii.shader = MII_SHADER
		_mii.set_shader_parameter("outline_width", MII_WIDTH)
		_mii.set_shader_parameter("outline_color", post_material().get_shader_parameter("ink_color"))
	return _mii


# Inks everything `camera` sees: a quad in front of it that covers the view.
static func attach(camera: Camera3D) -> MeshInstance3D:
	var old := camera.get_node_or_null(NODE_NAME)
	if old:
		return old as MeshInstance3D
	var quad := MeshInstance3D.new()
	quad.name = NODE_NAME
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	quad.mesh = mesh
	quad.material_override = post_material()
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# The shader places it over the whole view itself; never cull it.
	quad.extra_cull_margin = 16384.0
	quad.position = Vector3(0, 0, -1)
	camera.add_child(quad)
	return quad


# The ink: a deep shade of the palette's shadow tint, so it belongs to the
# level's colours instead of being a flat black.
static func set_palette(palette: LevelPalette) -> void:
	if palette == null:
		return
	var ink := palette.shadow_tint.darkened(0.55)
	ink.a = 1.0
	post_material().set_shader_parameter("ink_color", ink)
	mii_outline_material().set_shader_parameter("outline_color", ink)
