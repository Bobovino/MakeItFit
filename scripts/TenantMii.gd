extends Node3D
class_name TenantMii

# Low-poly tenant avatar shown only in the post-win 3D showcase
# (Room3DView.start_tenant_showcase) — teleports between the furniture that
# satisfies each moment's needs and plays a single cheerful bounce loop the
# whole time. No pathfinding, no rigging: the target position is always a
# furniture tile we already know from _furniture_entries. Limbs are real
# connected geometry (arms/legs joined to the torso), not floating parts, so
# poses are done by moving/rotating the WHOLE model rather than individual
# limbs — repositioning one limb without the others would visibly pull it
# apart at the joint.

const MODEL_PATH := "res://assets/models/tenants/mii_tenant.glb"
const OUTLINE_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")
const TINTED_PARTS := ["Torso", "Arm_L", "Arm_R", "Leg_L", "Leg_R", "Foot_L", "Foot_R"]

const BOB_SPEED  := 3.2   # radians/sec
const BOB_AMOUNT := 0.035 # metres
const SQUASH_AMOUNT := 0.06

enum Pose { STAND, SIT, LIE }

var _model: Node3D = null
var _t: float = randf() * TAU   # random phase so multiple instances don't sync
var _pose: int = Pose.STAND
var _pose_y_offset: float = 0.0


func _ready() -> void:
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		return
	_model = packed.instantiate()
	add_child(_model)
	_apply_outline(_model)
	_add_happy_face()


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


func _process(delta: float) -> void:
	if not is_instance_valid(_model):
		return
	_t += delta * BOB_SPEED
	var bounce := (sin(_t) + 1.0) * 0.5   # 0..1, so it only ever bounces up
	if _pose == Pose.LIE:
		# No hopping while lying down — a slow breathing scale pulse instead.
		_model.position.y = _pose_y_offset
		var breathe := 1.0 + sin(_t * 0.6) * 0.025
		_model.scale = Vector3(1.0, breathe, breathe)
	else:
		_model.position.y = _pose_y_offset + bounce * BOB_AMOUNT * 2.0
		var squash := 1.0 - bounce * SQUASH_AMOUNT
		var stretch := 1.0 + bounce * SQUASH_AMOUNT * 0.5
		_model.scale = Vector3(stretch, squash, stretch)


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
	match _pose:
		Pose.STAND:
			_model.rotation = Vector3.ZERO
			_pose_y_offset = 0.0
		Pose.SIT:
			# Whole-body crouch — a lowered stance reads as "sitting at this
			# piece of furniture" without needing to bend any one connected
			# limb (which would visibly pull it away from its joint).
			_model.rotation = Vector3.ZERO
			_pose_y_offset = -0.14
		Pose.LIE:
			_model.rotation.x = deg_to_rad(-90.0)
			_pose_y_offset = -0.5


# A procedurally-drawn face (eyebrows + round eyes with a catch-light +
# a thick smile stroke + blush) on a billboarded quad in front of the head —
# went back to a flat decal after real 3D eyeball geometry turned out
# uncanny at this model's tiny scale (pupil vs. sclera proportions are very
# hard to tune blind, and the result read as empty eye sockets). Drawn at
# 128px (doubled from an earlier 64px pass) purely for smoother edges on the
# curves — same layout, just less jaggy up close. Eyebrows are the one new
# feature: without them the eyes read as two flat dots with nothing framing
# them, which is most of what was still making the plain-dot version feel
# "off" rather than actually expressive.
const FACE_TEX_SIZE := 128
const FACE_WORLD_SIZE := 0.16

func _add_happy_face() -> void:
	var head := _model.find_child("Head", true, false) as MeshInstance3D
	if head == null:
		return
	var img := Image.create(FACE_TEX_SIZE, FACE_TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# Soft near-black instead of pure black — pure black eyes on a small
	# head read as punched-out holes. A small white glint offset toward the
	# upper-left of each eye is what actually kills the "dead stare" look,
	# same trick any simple cartoon face uses to fake a catch-light.
	var ink := Color(0.14, 0.12, 0.11)
	var eye_r := 6.5
	var eye_l := Vector2(44, 54)
	var eye_r_pos := Vector2(84, 54)
	_draw_dot(img, eye_l.x, eye_l.y, eye_r, ink)
	_draw_dot(img, eye_r_pos.x, eye_r_pos.y, eye_r, ink)
	_draw_dot(img, eye_l.x - 2.6, eye_l.y - 2.8, 1.8, Color(1, 1, 1, 0.85))
	_draw_dot(img, eye_r_pos.x - 2.6, eye_r_pos.y - 2.8, 1.8, Color(1, 1, 1, 0.85))
	# Eyebrows: a gentle upward arch (apex HIGHER, i.e. smaller y, in the
	# middle) sitting just above each eye — this single addition is what
	# turns "two dots and a mouth" into an actual expressive face instead of
	# a blank stare with a smile stapled under it.
	for cx_v in [eye_l.x, eye_r_pos.x]:
		var cx: float = cx_v
		for x in range(int(cx - 8), int(cx + 9)):
			var t: float = (float(x) - (cx - 8)) / 16.0
			var y := 40 - int(round(3.5 * sin(PI * t)))
			_draw_dot(img, x, y, 1.4, ink)
	# Smile: corners (t=0,1) sit HIGHER (smaller y) than the middle (t=0.5,
	# larger y) — a "cup" shape, which is what a smiling mouth looks like in
	# image coordinates where y increases downward. Drawn as two overlapping
	# passes offset a couple pixels apart so the stroke actually has
	# visible thickness instead of reading as a thin scratch.
	for x in range(36, 95):
		var t := float(x - 36) / 58.0
		var y := 80 + int(round(12.0 * sin(PI * t)))
		_draw_dot(img, x, y, 3.0, ink)
		_draw_dot(img, x, y + 3, 2.6, ink)
	# Faint blush — reads as "friendly" rather than "blank," and costs
	# nothing extra to draw.
	_draw_dot(img, 28, 68, 6.0, Color(0.95, 0.55, 0.55, 0.22))
	_draw_dot(img, 100, 68, 6.0, Color(0.95, 0.55, 0.55, 0.22))
	var sprite := Sprite3D.new()
	sprite.texture = ImageTexture.create_from_image(img)
	sprite.pixel_size = FACE_WORLD_SIZE / FACE_TEX_SIZE
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.shaded = false
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.no_depth_test = true   # decal must never be clipped by the curved head surface it sits against
	sprite.position = Vector3(0, 0, 0.19)
	head.add_child(sprite)


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


# Recolors the body (torso/feet) to the tenant's color, leaving the skin-toned
# head/hands and the black outline shells untouched.
func set_tint(color: Color) -> void:
	if not is_instance_valid(_model):
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	for part_name in TINTED_PARTS:
		var mi := _model.find_child(part_name, true, false) as MeshInstance3D
		if mi:
			mi.set_surface_override_material(0, mat)
