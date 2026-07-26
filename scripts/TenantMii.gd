extends Node3D
class_name TenantMii

# Low-poly tenant avatar shown only in the post-win 3D showcase
# (Room3DView.start_tenant_showcase) — teleports between the furniture that
# satisfies each moment's needs and plays a matching animation the whole
# time. No pathfinding: the target position is always a furniture tile we
# already know from _furniture_entries.
#
# Body model: Kenney's "Animated Characters Retro" pack (CC0, kenney.nl),
# swapped in over the previous "Mini Characters" pack (also CC0/Kenney)
# because Mini Characters' wide tapered-cone torso read as "fat" once seen
# at real in-game size. This pack uses one shared rig/mesh
# ("characterMedium") for every skin — gender is told apart by which skin
# texture goes on it, not by loading a different model. Its head texture
# already has a painted face, so there's no need for this script's old
# procedural smiley-decal system anymore. License copy lives alongside the
# files at assets/models/tenants/kenney_retro/LICENSE_Kenney_AnimatedCharactersRetro.txt.
const MODEL_PATH  := "res://assets/models/tenants/kenney_retro/characterMedium.fbx"
const SKIN_MALE   := "res://assets/models/tenants/kenney_retro/humanMaleA.png"
const SKIN_FEMALE := "res://assets/models/tenants/kenney_retro/humanFemaleA.png"
const ANIM_IDLE_PATH := "res://assets/models/tenants/kenney_retro/Animations/idle.fbx"
const OUTLINE_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")

# Measured empirically (this model's own reported world-space AABB comes
# out ~3.76m tall as imported — looks like an FBX unit-conversion artifact
# baked into the source file rather than an intentional giant) and
# corrected back down to a normal ~1.6m standing height, the same way
# MODEL_SCALE corrected the previous model's too-SMALL scale in the other
# direction.
const MODEL_SCALE := 0.42

enum Pose { STAND, SIT, LIE, CROUCH }

# This pack only ships "idle"/"run"/"jump" animations — no sit/lie/crouch
# exists to play, unlike the previous model. Every seated/lying pose is
# therefore the frozen idle frame plus our own whole-model rotation/offset
# (the same trick already used for lying down before), which is an
# approximation but doesn't depend on this pack having poses it simply
# doesn't ship.
const POSE_Y_OFFSET := {
	Pose.STAND: 0.0,
	Pose.SIT: -0.35,
	Pose.LIE: 0.5,
	Pose.CROUCH: -0.25,
}
const POSE_ROTATION_X_DEG := {
	Pose.STAND: 0.0,
	Pose.SIT: 0.0,
	Pose.LIE: -90.0,
	Pose.CROUCH: 0.0,
}

var _model: Node3D = null
var _model_loaded := false
var _anim_player: AnimationPlayer = null
var _body_mesh: MeshInstance3D = null
var _pose: int = Pose.STAND


func _ready() -> void:
	pass   # model loads lazily on the first set_tint() call


func _load_model() -> void:
	if _model_loaded:
		return
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		return
	_model = packed.instantiate()
	add_child(_model)
	_model.scale = Vector3.ONE * MODEL_SCALE
	_model_loaded = true
	_body_mesh = _model.find_child("characterMedium", true, false) as MeshInstance3D
	_anim_player = _build_anim_player()
	_apply_outline(_model)
	_apply_pose()


# The pack ships each animation as its own separate FBX sharing this same
# skeleton, meant to be combined at import time — there's no single file
# that already has a ready-made AnimationPlayer sitting on our model. This
# pulls the "Idle" clip out of its own throwaway scene instance and
# re-hosts it on an AnimationPlayer of our own under a plain name, since
# the track paths ("Root/Skeleton3D:BoneName") match this model's own
# hierarchy either way.
func _build_anim_player() -> AnimationPlayer:
	var ap := AnimationPlayer.new()
	_model.add_child(ap)
	var lib := AnimationLibrary.new()
	var idle_packed := load(ANIM_IDLE_PATH) as PackedScene
	if idle_packed:
		var idle_inst := idle_packed.instantiate()
		var idle_ap := idle_inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if idle_ap:
			for lib_name in idle_ap.get_animation_library_list():
				var src_lib := idle_ap.get_animation_library(lib_name)
				for anim_key in src_lib.get_animation_list():
					if anim_key.ends_with("|Idle"):
						lib.add_animation("idle", src_lib.get_animation(anim_key))
		idle_inst.free()
	ap.add_animation_library("", lib)
	return ap


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


# "stand" (default) / "sit" / "lie" / "crouch" — called by Room3DView
# alongside each teleport so the tenant visibly uses whatever furniture it
# just landed on.
func set_pose(pose_name: String) -> void:
	match pose_name:
		"lie":
			_pose = Pose.LIE
		"sit":
			_pose = Pose.SIT
		"crouch":
			_pose = Pose.CROUCH
		_:
			_pose = Pose.STAND
	_apply_pose()


# Freezes/resumes the AnimationPlayer on its own — set_process(false) on this
# node only stops OUR _process, not the AnimationPlayer child buried inside
# the loaded model, which keeps advancing its own animation regardless. The
# portrait viewport (CityMap.gd) needs a static headshot, not a tiny
# perpetually-idling figure, so it calls this after set_tint().
func set_animated(enabled: bool) -> void:
	if is_instance_valid(_anim_player):
		_anim_player.active = enabled


func _apply_pose() -> void:
	if not is_instance_valid(_model):
		return   # set_pose() called before the first set_tint() loaded the model
	position.y = POSE_Y_OFFSET[_pose]
	# Rotating the WHOLE model (not any one limb) around its own feet-level
	# origin is what lays it down for LIE — since position.y above already
	# lifted that origin up to mattress height, the body swings out flat at
	# that same height instead of describing an arc through the floor.
	_model.rotation.x = deg_to_rad(POSE_ROTATION_X_DEG[_pose])
	if is_instance_valid(_anim_player) and _anim_player.has_animation("idle"):
		_anim_player.play("idle")
		_anim_player.get_animation("idle").loop_mode = Animation.LOOP_LINEAR


# Picks the tenant's skin (deterministic from the tint color's hue, so a
# given tenant is consistently the same gender everywhere without a
# separate parameter — every caller already derives this color as a hash of
# the tenant's name) and applies it with a light color cast. Unlike the
# previous model's blank color-block atlas, this skin is a fully painted
# texture (face, shirt, shoes), so a strong tint would just muddy it —
# mostly-white keeps some per-tenant variety without wrecking the art.
func set_tint(color: Color) -> void:
	_load_model()
	if not is_instance_valid(_body_mesh):
		return
	var is_female := int(color.h * 997.0) % 2 == 0
	var tex := load(SKIN_FEMALE if is_female else SKIN_MALE) as Texture2D
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.albedo_color = color.lerp(Color.WHITE, 0.65)
	mat.roughness = 1.0
	_body_mesh.set_surface_override_material(0, mat)
