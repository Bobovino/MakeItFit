extends Node3D
class_name TenantPawn3D

# A tenant in the 3D view: a low-poly peg figure (a capsule body and a round
# head) in their own colour, or a flattened oval for an animal. No skeleton:
# hops, squash and stretch, a shake when annoyed and a bounce when happy are
# all tweens on the whole figure. Turns to face the camera so the eyes read.
# Not part of the room's build: it lives beside it and the room never sees it.

const HEIGHT := {"adult": 1.6, "teen": 1.45, "child": 1.1, "animal": 0.32}

var resident: TenantResident
var cam: Camera3D
var _height := 1.6
var _figure: Node3D          # what moves and squashes
var _bubble_vp: SubViewport
var _bubble_sprite: Sprite3D
var _move_tween: Tween
var _mood_tween: Tween
var _shown := false


func setup(r: TenantResident, tint: Color, camera: Camera3D) -> void:
	resident = r
	cam = camera
	_height = HEIGHT.get(r.body, 1.6) as float
	_figure = Node3D.new()
	add_child(_figure)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.8
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.07, 0.07)
	if r.body == "animal":
		var body := MeshInstance3D.new()
		var s := SphereMesh.new()
		s.radius = 0.3
		s.height = 0.6
		body.mesh = s
		body.material_override = mat
		body.scale = Vector3(0.9, 0.55, 1.4)
		body.position.y = 0.17
		_figure.add_child(body)
		_add_eyes(dark, Vector3(0, 0.22, 0.38), 0.035, 0.09)
		return
	var w := 0.17 * _height / 1.6
	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = w
	cap.height = _height * 0.72
	body.mesh = cap
	body.material_override = mat
	body.position.y = _height * 0.36
	_figure.add_child(body)
	var head := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = w * 0.95
	hs.height = w * 1.9
	head.mesh = hs
	var head_mat := mat.duplicate() as StandardMaterial3D
	head_mat.albedo_color = tint.lightened(0.2)
	head.material_override = head_mat
	head.position.y = _height * 0.72 + w * 0.8
	_figure.add_child(head)
	_add_eyes(dark, Vector3(0, head.position.y + w * 0.1, w * 0.82), w * 0.16, w * 0.38)


func _add_eyes(mat: Material, center: Vector3, radius: float, spread: float) -> void:
	for sx in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = radius
		m.height = radius * 2.0
		m.radial_segments = 8
		m.rings = 4
		eye.mesh = m
		eye.material_override = mat
		eye.position = center + Vector3(sx * spread, 0, 0)
		_figure.add_child(eye)


func _process(_delta: float) -> void:
	if is_instance_valid(cam):
		var to := cam.global_position - global_position
		rotation.y = atan2(to.x, to.z)


func place(at: Vector3, animate: bool) -> void:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	var from := position
	if not animate or GameState.reduce_motion or not _shown:
		position = at
		_figure.position = Vector3.ZERO
		_figure.scale = Vector3.ONE
		if animate and not GameState.reduce_motion and not _shown:
			_figure.scale = Vector3(0.2, 0.2, 0.2)
			_move_tween = create_tween()
			_move_tween.tween_property(_figure, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_shown = true
		return
	var height := clampf(from.distance_to(at) * 0.3, 0.15, 0.6)
	_move_tween = create_tween()
	_move_tween.tween_property(_figure, "scale", Vector3(1.12, 0.85, 1.12), 0.06)
	_move_tween.tween_method(func(k: float):
		position = from.lerp(at, k)
		_figure.position.y = sin(k * PI) * height
		_figure.scale = Vector3(0.94, 1.08, 0.94), 0.0, 1.0, 0.32).set_trans(Tween.TRANS_SINE)
	_move_tween.tween_property(_figure, "scale", Vector3(1.18, 0.82, 1.18), 0.05)
	_move_tween.tween_property(_figure, "scale", Vector3.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func set_present(present: bool) -> void:
	visible = present


func head_point() -> Vector3:
	return global_position + Vector3(0, _height + 0.05, 0)


func react(req_id: String, mood: int) -> void:
	clear_reaction()
	_bubble_vp = SubViewport.new()
	_bubble_vp.transparent_bg = true
	_bubble_vp.disable_3d = true
	_bubble_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_bubble_vp)
	# Measured once in the tree, where the bubble's theme applies.
	var bubble := TenantBubble.make(req_id, mood)
	_bubble_vp.add_child(bubble)
	var sz := bubble.get_combined_minimum_size()
	bubble.size = sz
	bubble.position = Vector2(4, 4)
	_bubble_vp.size = Vector2i(int(sz.x) + 8, int(sz.y) + 18)   # room for the tail
	_bubble_sprite = Sprite3D.new()
	_bubble_sprite.texture = _bubble_vp.get_texture()
	_bubble_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble_sprite.fixed_size = true
	_bubble_sprite.pixel_size = 0.0006
	_bubble_sprite.no_depth_test = true
	_bubble_sprite.render_priority = 10
	_bubble_sprite.offset = Vector2(0, _bubble_vp.size.y * 0.5)
	_bubble_sprite.position.y = _height + 0.1
	add_child(_bubble_sprite)
	if GameState.reduce_motion:
		return
	_mood_tween = create_tween()
	if mood == TenantBubble.Mood.ANNOYED:
		for i in 4:
			_mood_tween.tween_property(_figure, "rotation_degrees:z", 10.0 if i % 2 == 0 else -10.0, 0.06)
		_mood_tween.tween_property(_figure, "rotation_degrees:z", 0.0, 0.06)
	else:
		_mood_tween.tween_property(_figure, "position:y", 0.25, 0.12).set_ease(Tween.EASE_OUT)
		_mood_tween.tween_property(_figure, "position:y", 0.0, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func clear_reaction() -> void:
	if _mood_tween and _mood_tween.is_valid():
		_mood_tween.kill()
	if _figure:
		_figure.rotation_degrees = Vector3.ZERO
	if is_instance_valid(_bubble_sprite):
		_bubble_sprite.queue_free()
	if is_instance_valid(_bubble_vp):
		_bubble_vp.queue_free()
	_bubble_sprite = null
	_bubble_vp = null
