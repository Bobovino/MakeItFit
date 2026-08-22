extends Node3D
class_name TenantMii

# Low-poly tenant avatar shown only in the post-win 3D showcase
# (Room3DView.start_tenant_showcase) — teleports between the furniture that
# satisfies each moment's needs. Rigged (18-bone armature) and animated via a
# baked AnimationPlayer that ships inside each .glb, rather than the earlier
# whole-body-transform pose hack: real Walk/Sit/Lie/etc. clips instead of
# rotating and offsetting the whole model.

# Two body variants — a male figure and a female one, each with their own
# baked palette, face, and animation set (built/exported in Blender, not
# swapped textures or runtime tints). Which one a given tenant gets is
# decided in set_tint() below, from the same color every caller already
# derives from the tenant's name — that keeps a given tenant consistently the
# same body everywhere without needing their name threaded through as a
# separate parameter. Teen/child variants exist on disk (assets/models/
# tenants/tenant_{teen,child}_{masc,fem}.glb) for whenever the game wants a
# body-size distinction; nothing currently selects them.
const MODEL_PATH_MALE   := "res://assets/models/tenants/tenant_adult_masc.glb"
const MODEL_PATH_FEMALE := "res://assets/models/tenants/tenant_adult_fem.glb"
const OUTLINE_SHADER := preload("res://scripts/shaders/tenant_outline.gdshader")

const BOB_SPEED  := 3.2   # radians/sec
const BOB_AMOUNT := 0.035 # metres
const SQUASH_AMOUNT := 0.06

enum Pose { STAND, SIT, LIE, REACH }

# Clip name for each pose's steady-state loop, and the one-shot transition
# clips either side of it. Every .glb ships all of these; STAND/REACH have no
# transition clips because the root never moves for them -- they blend
# straight off of Idle.
const LOOP_CLIP := {
	Pose.STAND: "Idle",
	Pose.SIT:   "Sit",
	Pose.LIE:   "Lie",
	Pose.REACH: "ReachFwd1H",
}
const DOWN_CLIP := { Pose.SIT: "SitDown", Pose.LIE: "LieDown" }
const UP_CLIP   := { Pose.SIT: "StandUp", Pose.LIE: "LieUp" }

# Clips that should loop forever once reached (everything else -- the
# transitions -- stops on its last frame, which is what lets queue() advance
# to the next queued clip via animation_finished).
const LOOPING_CLIPS := ["Idle", "Walk", "Sit", "SitRelaxed", "Lie", "Crouch",
	"ReachFwd", "ReachFwd1H", "ReachUp", "ReachUp1H"]

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _model_path: String = ""   # which of the two variants is currently loaded, so set_tint doesn't reload it every call
var _t: float = randf() * TAU   # random phase so multiple instances don't sync
var _pose: int = Pose.STAND
var _pose_y_offset: float = 0.0
var _animate: bool = true   # mirrors set_process() below, applied to _anim once it exists


func _ready() -> void:
	pass   # model loads lazily on the first set_tint() call, once the body variant is known


# CityMap's static city-map portrait wants a frozen figure, called BEFORE the
# model (and its AnimationPlayer) even exists yet. Plain Node.set_process only
# stops OUR OWN _process (the manual bounce/breathing) -- it does nothing to a
# child AnimationPlayer's independent internal playback, so the baked Idle
# sway would keep animating in every portrait regardless. Named separately
# rather than overriding set_process() itself: Godot's GDScript parser treats
# shadowing a native Node method as an error ("won't be called by the
# engine"), since only explicit script-side calls would ever reach it.
func set_animating(enable: bool) -> void:
	set_process(enable)
	_animate = enable
	if _anim:
		_anim.active = enable


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
	_apply_outline(_model)
	_anim = _find_animation_player(_model)
	if _anim:
		_anim.active = _animate
		for clip_name in LOOPING_CLIPS:
			if _anim.has_animation(clip_name):
				_anim.get_animation(clip_name).loop_mode = Animation.LOOP_LINEAR
	_goto_pose(_pose, true)   # the new model starts at bind pose -- jump straight to whatever pose was already set, no transition


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found:
			return found
	return null


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
		# The skeletal animation only drives bone poses inside the armature,
		# so scaling/offsetting _model itself on top of it is still safe.
		_model.position.y = _pose_y_offset
		var breathe := 1.0 + sin(_t * 0.6) * 0.025
		_model.scale = Vector3(1.0, breathe, breathe)
	else:
		_model.position.y = _pose_y_offset + bounce * BOB_AMOUNT * 2.0
		var squash := 1.0 - bounce * SQUASH_AMOUNT
		var stretch := 1.0 + bounce * SQUASH_AMOUNT * 0.5
		_model.scale = Vector3(stretch, squash, stretch)


# "stand" (default) / "sit" / "lie" / "reach" — called by Room3DView
# alongside each teleport so the tenant visibly uses whatever furniture it
# just landed on.
#
# `instant` defaults to true because every caller today is a TELEPORT
# between two different, unrelated pieces of furniture, not a tenant walking
# up to and using the SAME one -- so there is nothing to transition FROM.
# Passing false (still supported for whenever a tenant actually walks up to
# furniture in view) previously ran unconditionally, which is what made a
# teleport to the sink play the "getting up out of bed" animation right there
# at the sink: the position had already jumped, so LieUp's baked motion
# played in the new spot instead of the bed it was meant to leave.
func set_pose(pose_name: String, instant: bool = true) -> void:
	var pose: int
	match pose_name:
		"lie":
			pose = Pose.LIE
		"sit":
			pose = Pose.SIT
		"reach":
			pose = Pose.REACH
		_:
			pose = Pose.STAND
	if pose == _pose:
		return
	_goto_pose(pose, instant)


# Plays whatever one-shot transition clips get the rig from the current pose
# to the target pose, then hands off to the target's looping clip. Any
# sit<->lie jump routes through the shared STAND-adjacent "up" clip first
# (there's no direct sit-to-lie clip) -- two short transitions back to back
# rather than teaching every pose pair its own animation.
func _goto_pose(pose: int, instant: bool) -> void:
	var old_pose := _pose
	_pose = pose
	_pose_y_offset = 0.0

	if not _anim:
		return

	if instant:
		var loop: String = LOOP_CLIP[pose]
		if _anim.has_animation(loop):
			_anim.stop()
			_anim.play(loop)
		return

	var chain: Array[String] = []
	if UP_CLIP.has(old_pose):
		chain.append(UP_CLIP[old_pose])
	if DOWN_CLIP.has(pose):
		chain.append(DOWN_CLIP[pose])
	chain.append(LOOP_CLIP[pose])

	var first := true
	for clip_name in chain:
		if not _anim.has_animation(clip_name):
			continue
		if first:
			_anim.play(clip_name)
			first = false
		else:
			_anim.queue(clip_name)


# Picks which body variant to load — a male figure or a female one, each
# with its own baked palette/face/animations (see the MODEL_PATH_* comment
# above) — deterministically from the color's hue, so a given tenant is
# consistently the same body everywhere without a separate parameter. Both
# variants ship their own fixed palette now, so this no longer recolors
# anything at runtime the way the old flat-tint mii did.
func set_tint(color: Color) -> void:
	_load_model(MODEL_PATH_FEMALE if int(color.h * 997.0) % 2 == 0 else MODEL_PATH_MALE)
