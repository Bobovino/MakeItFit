extends SubViewport
class_name MiiPortrait

# A tenant's Mii rendered small, offscreen, for a card: the project map's fax
# prints one, and a dialogue shows the one who is speaking. Use texture() as
# a TextureRect's texture; it keeps drawing while the portrait is in the tree.
#
# Two framings:
#   "fax"   thighs up, from low down, posed like the family in Young Sheldon's
#           titles: turned three-quarters, looking up at the sky.
#   "head"  head and shoulders, the camera on the face, for someone talking.

const TenantMiiScript := preload("res://scripts/TenantMii.gd")

var mii: TenantMii
var _cam: Camera3D
var _light: DirectionalLight3D
var _ambient: Environment
var _framing := "fax"


static func create(px: int, framing := "fax") -> MiiPortrait:
	var p := MiiPortrait.new()
	p._framing = framing
	p.size = Vector2i(px, px)
	p.msaa_3d = Viewport.MSAA_4X   # the Mii's outline and edges stay smooth this small
	p.transparent_bg = true
	p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	p._build()
	return p


func _build() -> void:
	_cam = Camera3D.new()
	_cam.fov = 35.0
	# The model is ~1.72 m tall, feet at y=0. "head" is aimed at the face
	# once the body is known (_frame()).
	_cam.look_at_from_position(Vector3(0, 0.75, 2.3), Vector3(0, 1.22, 0), Vector3.UP)   # thighs up: the face reads at portrait size
	# Not the ink's facing-pass layer: there the Mii's outline paints it solid
	# black (ink_mask), and the portrait came out as a black silhouette.
	_cam.cull_mask &= ~InkNormalPass.PASS_FLAG
	add_child(_cam)

	_light = DirectionalLight3D.new()
	_light.rotation_degrees = Vector3(-45, 35, 0)
	_light.light_energy = 1.2
	add_child(_light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	env_node.environment = env
	_ambient = env
	add_child(env_node)

	mii = TenantMiiScript.new()
	add_child(mii)
	mii.set_animating(false)   # a still portrait: no idle bounce

	# A soft contact shadow right under the feet: with no floor the full-body
	# framing left the figure floating in empty space.
	var shadow := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.42, 0.42)
	shadow.mesh = quad
	var shadow_mat := StandardMaterial3D.new()
	shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow_mat.albedo_texture = _shadow_blob()
	shadow.material_override = shadow_mat
	shadow.rotation.x = deg_to_rad(-90.0)
	shadow.position = Vector3(0, 0.01, 0)
	add_child(shadow)


# Again once in the tree: entering it turns the Mii's own bounce back on.
func _ready() -> void:
	mii.set_animating(false)


func texture() -> Texture2D:
	return get_texture()


# The look: a colour (the fax's tenants, whose body follows from it, see
# TenantMii.set_tint) or a body (a household's residents, as in the flat).
func show_tint(color: Color) -> void:
	mii.set_tint(color)
	_frame()


func show_body(body: String, feminine: bool) -> void:
	mii.set_body(body, feminine)
	_frame()


# Turned `side` (1 or -1) by `turn_deg` from the camera, head raised by
# `look_up_deg`. The light comes from the side they look away from: lit from
# the side they turn to, the face washed out to white.
func pose(side: float, turn_deg: float, look_up_deg := 0.0) -> void:
	mii.rotation_degrees.y = turn_deg * side
	_light.rotation_degrees.y = -35.0 * side
	_set_head(look_up_deg)


# A nod: the head dips and comes back, for a new line said.
func nod() -> void:
	var sk := _skeleton()
	if sk == null:
		return
	var tw := create_tween()
	tw.tween_method(func(d: float): _set_head(-d), 0.0, 9.0, 0.09).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(d: float): _set_head(-d), 9.0, 0.0, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _set_head(up_deg: float) -> void:
	var sk := _skeleton()
	if sk == null:
		return
	var head := sk.find_bone("head")
	if head >= 0:
		var rest := sk.get_bone_rest(head).basis.get_rotation_quaternion()
		sk.set_bone_pose_rotation(head, rest * Quaternion(Vector3.LEFT, deg_to_rad(up_deg)))


# The current body's: one just swapped out lingers until the frame ends.
func _skeleton() -> Skeleton3D:
	for sk in mii.find_children("*", "Skeleton3D", true, false):
		var n := sk as Node
		var gone := false
		while n != mii:
			if n.is_queued_for_deletion():
				gone = true
				break
			n = n.get_parent()
		if not gone:
			return sk as Skeleton3D
	return null


# "head": the camera in front of the face, wherever it is on this body (a
# child's is lower down).
func _frame() -> void:
	if _framing != "head":
		return
	var face := Vector3(0, 1.5, 0)
	var sk := _skeleton()
	if sk != null and sk.is_inside_tree():
		var head := sk.find_bone("head")
		if head >= 0:
			face = sk.global_transform * sk.get_bone_global_rest(head).origin + Vector3(0, 0.08, 0)
	_cam.fov = 30.0
	_cam.look_at_from_position(face + Vector3(0, 0.06, 1.2), face - Vector3(0, 0.02, 0), Vector3.UP)
	_ambient.ambient_light_energy = 0.75   # this close, full ambient washes the face out


# A soft radial dark blob fading to transparent at the edges.
static func _shadow_blob() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var center := Vector2(n / 2.0, n / 2.0)
	for x in range(n):
		for y in range(n):
			var d := Vector2(x, y).distance_to(center) / (n / 2.0)
			img.set_pixel(x, y, Color(0, 0, 0, clampf(1.0 - d, 0.0, 1.0) * 0.45))
	return ImageTexture.create_from_image(img)
