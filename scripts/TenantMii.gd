extends Node3D
class_name TenantMii

# Low-poly tenant avatar shown only in the post-win 3D showcase
# (Room3DView.start_tenant_showcase) — teleports between the furniture that
# satisfies each moment's needs and plays a matching animation the whole
# time. No pathfinding: the target position is always a furniture tile we
# already know from _furniture_entries.
#
# Body model: Kenney's "Mini Characters" pack (CC0, kenney.nl) — a real
# rigged/skinned low-poly character with 32 baked animations, replacing an
# earlier from-scratch Blender build whose proportions and canned bob/squash
# animation still read as amateurish. License copy lives alongside the
# models at assets/models/tenants/kenney/LICENSE_Kenney_MiniCharacters.txt.
const MODEL_PATH_MALE   := "res://assets/models/tenants/kenney/character-male-a.glb"
const MODEL_PATH_FEMALE := "res://assets/models/tenants/kenney/character-female-a.glb"
const OUTLINE_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")

enum Pose { STAND, SIT, LIE }

# How each pose maps onto the pack's baked animation names, and how far to
# sink the whole rig into the furniture (the pack's own anims don't know
# about our specific bed/chair meshes, so a small manual offset still does
# the "actually inside the furniture, not floating above it" work).
const POSE_ANIM := {
	Pose.STAND: "idle",
	Pose.SIT: "sit",
	Pose.LIE: "die",   # only baked anim that puts the rig flat on its back
}
const POSE_Y_OFFSET := {
	Pose.STAND: 0.0,
	Pose.SIT: -0.14,
	Pose.LIE: -0.05,
}

var _model: Node3D = null
var _model_path: String = ""   # which of the two variants is currently loaded, so set_tint doesn't reload it every call
var _anim_player: AnimationPlayer = null
var _pose: int = Pose.STAND


func _ready() -> void:
	pass   # model loads lazily on the first set_tint() call, once the body variant is known


func _load_model(path: String) -> void:
	if path == _model_path:
		return
	if is_instance_valid(_model):
		_model.queue_free()
	var packed := load(path) as PackedScene
	if packed == null:
		return
	_model = packed.instantiate()
	add_child(_model)
	_model_path = path
	_anim_player = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	_apply_outline(_model)
	_add_happy_face()
	_apply_pose()   # the new model starts at identity transform — reapply whatever pose was already set


# Black rim around each part via a next-pass shader (cull_front + vertex push
# along normal) instead of baked-in inverted-hull geometry — much easier to
# get right/iterate on than doubling geometry in Blender.
func _apply_outline(node: Node) -> void:
	var outline_mat := ShaderMaterial.new()
	outline_mat.shader = OUTLINE_SHADER
	for child in node.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_overlay = outline_mat
		_apply_outline(child)


# "stand" (default) / "sit" / "lie" — called by Room3DView alongside each
# teleport so the tenant visibly uses whatever furniture it just landed on.
func set_pose(pose_name: String) -> void:
	match pose_name:
		"lie":
			_pose = Pose.LIE
		"sit":
			_pose = Pose.SIT
		_:
			_pose = Pose.STAND
	_apply_pose()


func _apply_pose() -> void:
	if not is_instance_valid(_model):
		return   # set_pose() called before the first set_tint() picked a body variant
	position.y = POSE_Y_OFFSET[_pose]
	if is_instance_valid(_anim_player):
		var anim_name: String = POSE_ANIM[_pose]
		if _anim_player.has_animation(anim_name):
			_anim_player.play(anim_name)
			# "die" is a one-shot animation (it's meant to end with the
			# character down and stay there) — everything else loops so the
			# tenant doesn't freeze mid-stride while standing or sitting.
			_anim_player.get_animation(anim_name).loop_mode = (
				Animation.LOOP_NONE if _pose == Pose.LIE else Animation.LOOP_LINEAR
			)


# A tiny procedurally-drawn smiley (two dot eyes + a curved mouth) on a
# billboarded quad in front of the head — the pack's own head mesh is a flat
# skin-toned block with no baked face, same blank-slate situation as the
# from-scratch model this replaced. Parented to a BoneAttachment3D tracking
# the "head" bone (not the head-mesh node itself, which stays put at the
# origin under GPU skinning — only its vertices move) so the face still
# rides along with every animation.
const FACE_TEX_SIZE := 64
const FACE_WORLD_SIZE := 0.16

func _add_happy_face() -> void:
	var skel := _model.find_child("Skeleton3D", true, false) as Skeleton3D
	if skel == null:
		return
	var bone_idx := skel.find_bone("head")
	if bone_idx < 0:
		return
	var attach := BoneAttachment3D.new()
	skel.add_child(attach)
	attach.bone_name = "head"
	var img := Image.create(FACE_TEX_SIZE, FACE_TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var ink := Color(0.14, 0.12, 0.11)
	var eye_r := 3.0
	_draw_dot(img, 22, 27, eye_r, ink)
	_draw_dot(img, 42, 27, eye_r, ink)
	_draw_dot(img, 20.7, 25.6, 0.9, Color(1, 1, 1, 0.85))
	_draw_dot(img, 40.7, 25.6, 0.9, Color(1, 1, 1, 0.85))
	for x in range(18, 47):
		var t := float(x - 18) / 28.0
		var y := 40 + int(round(6.0 * sin(PI * t)))
		_draw_dot(img, x, y, 1.6, ink)
	_draw_dot(img, 14, 34, 3.0, Color(0.95, 0.55, 0.55, 0.22))
	_draw_dot(img, 50, 34, 3.0, Color(0.95, 0.55, 0.55, 0.22))
	var sprite := Sprite3D.new()
	sprite.texture = ImageTexture.create_from_image(img)
	sprite.pixel_size = FACE_WORLD_SIZE / FACE_TEX_SIZE
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.no_depth_test = true   # decal must never be clipped by the curved head surface it sits against
	sprite.position = Vector3(0, 0.03, 0.075)
	attach.add_child(sprite)


# A soft 1px falloff at the rim (instead of a hard pixel edge) is the
# difference between "small drawn dot" and "jagged blob" at this texture's
# tiny 64x64 resolution — cheap alpha blend against whatever's already
# there so overlapping dots (glint over eye) still look right.
func _draw_dot(img: Image, cx: float, cy: float, r: float, color: Color = Color.BLACK) -> void:
	var ri := int(ceil(r)) + 1
	for x in range(int(cx) - ri, int(cx) + ri + 1):
		for y in range(int(cy) - ri, int(cy) + ri + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var d := Vector2(x - cx, y - cy).length()
			if d > r + 1.0:
				continue
			var edge_alpha := clampf(r + 0.5 - d, 0.0, 1.0)
			var blend_a := color.a * edge_alpha
			if blend_a <= 0.0:
				continue
			# Proper "over" compositing (not a plain lerp) — needed so a
			# translucent dot (the blush, or the glint over an eye already
			# drawn) actually ends up at its own requested alpha instead of
			# getting further diluted by whatever's already underneath.
			var under := img.get_pixel(x, y)
			var out_a := blend_a + under.a * (1.0 - blend_a)
			var out_col := Color(0, 0, 0, 0)
			if out_a > 0.0:
				out_col = Color(
					(color.r * blend_a + under.r * under.a * (1.0 - blend_a)) / out_a,
					(color.g * blend_a + under.g * under.a * (1.0 - blend_a)) / out_a,
					(color.b * blend_a + under.b * under.a * (1.0 - blend_a)) / out_a,
					out_a)
			img.set_pixel(x, y, out_col)


# Recolors the body mesh (clothes/skin block) to the tenant's color, leaving
# the head mesh (skin tone) and the black outline shells untouched. Also
# picks which body variant to load — see the MODEL_PATH_* comment above —
# from the color's hue, so it's deterministic per tenant without a separate
# parameter.
func set_tint(color: Color) -> void:
	_load_model(MODEL_PATH_FEMALE if int(color.h * 997.0) % 2 == 0 else MODEL_PATH_MALE)
	if not is_instance_valid(_model):
		return
	var body := _model.find_child("body-mesh", true, false) as MeshInstance3D
	if body == null:
		return
	# Duplicate the pack's own material (keeps its colormap texture/roughness
	# intact) and multiply in the tenant's color via albedo_color rather than
	# replacing the texture outright.
	var base_mat := body.get_active_material(0) as StandardMaterial3D
	var mat: StandardMaterial3D = base_mat.duplicate() if base_mat else StandardMaterial3D.new()
	mat.albedo_color = color
	body.set_surface_override_material(0, mat)
