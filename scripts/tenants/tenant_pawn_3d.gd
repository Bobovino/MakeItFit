extends Node3D
class_name TenantPawn3D

# A tenant in the 3D view: the same Mii as the project map's portrait and the
# post-win showcase (TenantMii: a body of their own age and look, with its
# baked Idle/Walk/Sit/Lie clips), or a simple oval for an animal, which has
# no Mii. Hops, squash, a shake when annoyed and a bounce when happy are
# tweens on top. Faces the camera while standing about, the way it's going
# while walking, and the furniture while using it. Not part of the room's
# build: it lives beside it and the room never sees it.

const HEIGHT := {"adult": 1.6, "teen": 1.45, "child": 1.1, "animal": 0.32}
const TenantMiiScript := preload("res://scripts/TenantMii.gd")

var resident: TenantResident
var cam: Camera3D
var _height := 1.6
var _figure: Node3D          # what hops and squashes
var _mii: TenantMii          # null for an animal
var _bubble_vp: SubViewport
var _bubble_sprite: Sprite3D
var _move_tween: Tween
var _mood_tween: Tween
var _shown := false
var _heading := NAN          # set while walking or using something: the way to face instead of the camera


func setup(r: TenantResident, tint: Color, camera: Camera3D) -> void:
	resident = r
	cam = camera
	_height = HEIGHT.get(r.body, 1.6) as float
	_figure = Node3D.new()
	add_child(_figure)
	if r.body != "animal":
		_mii = TenantMiiScript.new()
		_figure.add_child(_mii)
		_mii.set_body(r.body, r.is_feminine())
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.8
	var body := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.3
	s.height = 0.6
	body.mesh = s
	body.material_override = mat
	body.scale = Vector3(0.9, 0.55, 1.4)
	body.position.y = 0.17
	_figure.add_child(body)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.07, 0.07)
	for sx in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.035
		m.height = 0.07
		eye.mesh = m
		eye.material_override = dark
		eye.position = Vector3(sx * 0.09, 0.22, 0.38)
		_figure.add_child(eye)


func _process(_delta: float) -> void:
	if not is_nan(_heading):
		rotation.y = _heading
	elif is_instance_valid(cam):
		var to := cam.global_position - global_position
		rotation.y = atan2(to.x, to.z)


func place(at: Vector3, animate: bool) -> void:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	_heading = NAN
	if _mii:
		_mii.set_walking(false)
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


func walk(points: Array, step_time: float) -> Tween:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	if _mii:
		_mii.set_walking(true)
	_move_tween = create_tween()
	var from := position
	var bob := 0.03 if _mii else 0.09   # the Mii's own walk already bobs
	for p in points:
		var a := from
		var b := p as Vector3
		_move_tween.tween_callback(func():
			var d := b - a
			if d.length() > 0.001:
				_heading = atan2(d.x, d.z))
		_move_tween.tween_method(func(k: float):
			position = a.lerp(b, k)
			_figure.position.y = sin(k * PI) * bob, 0.0, 1.0, step_time)
		from = b
	_move_tween.tween_callback(func():
		_heading = NAN
		if _mii:
			_mii.set_walking(false))
	return _move_tween


# A need met. With `use` ({pos, rot_y, pose} from Room3DView's
# _tenant_anchor_for(), in the room's own space) the Mii gets on the bed or
# into the seat and does it for real, then steps back to where it stood.
func perform(kind: String, req_id: String, use: Dictionary = {}) -> Tween:
	_show_bubble(req_id, TenantBubble.Mood.HAPPY)
	_mood_tween = create_tween()
	if GameState.reduce_motion:
		_mood_tween.tween_interval(1.2)
		return _mood_tween
	if _mii and not use.is_empty() and (use["pose"] as String) in ["lie", "sit"]:
		var home := position
		var spot: Vector3 = use["pos"]
		_mood_tween.tween_callback(func(): _heading = atan2(spot.x - home.x, spot.z - home.z))
		_mood_tween.tween_property(self, "position", spot, 0.3).set_trans(Tween.TRANS_SINE)
		_mood_tween.tween_callback(func():
			_heading = use["rot_y"]
			_mii.set_pose(use["pose"], false))
		_mood_tween.tween_interval(1.8)
		_mood_tween.tween_callback(func(): _mii.set_pose("stand", false))
		_mood_tween.tween_interval(0.5)
		_mood_tween.tween_callback(func(): _heading = atan2(home.x - spot.x, home.z - spot.z))
		_mood_tween.tween_property(self, "position", home, 0.3).set_trans(Tween.TRANS_SINE)
		_mood_tween.tween_callback(func(): _heading = NAN)
		return _mood_tween
	match kind:
		"lie":
			_mood_tween.tween_property(_figure, "rotation_degrees:x", -80.0, 0.25)
			_mood_tween.parallel().tween_property(_figure, "position:y", 0.25, 0.25)
			_mood_tween.tween_interval(0.9)
			_mood_tween.tween_property(_figure, "rotation_degrees:x", 0.0, 0.2)
			_mood_tween.parallel().tween_property(_figure, "position:y", 0.0, 0.2)
		"sit":
			_mood_tween.tween_property(_figure, "scale", Vector3(1.08, 0.72, 1.08), 0.14)
			_mood_tween.tween_interval(0.9)
			_mood_tween.tween_property(_figure, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK)
		_:
			_mood_tween.tween_property(_figure, "rotation_degrees:y", 360.0, 0.45).set_trans(Tween.TRANS_QUAD)
			_mood_tween.tween_callback(func(): _figure.rotation_degrees.y = 0.0)
			_mood_tween.tween_property(_figure, "position:y", 0.25, 0.12).set_ease(Tween.EASE_OUT)
			_mood_tween.tween_property(_figure, "position:y", 0.0, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
			_mood_tween.tween_interval(0.5)
	return _mood_tween


func shrug(req_id: String) -> Tween:
	_show_bubble(req_id, TenantBubble.Mood.UNSURE)
	_mood_tween = create_tween()
	if GameState.reduce_motion:
		_mood_tween.tween_interval(1.2)
		return _mood_tween
	for i in 2:
		_mood_tween.tween_property(_figure, "scale", Vector3(0.92, 1.1, 0.92), 0.12)
		_mood_tween.parallel().tween_property(_figure, "rotation_degrees:z", 7.0 if i == 0 else -7.0, 0.12)
		_mood_tween.tween_property(_figure, "scale", Vector3.ONE, 0.16)
		_mood_tween.parallel().tween_property(_figure, "rotation_degrees:z", 0.0, 0.16)
	_mood_tween.tween_interval(0.8)
	return _mood_tween


func react(req_id: String, mood: int) -> void:
	_show_bubble(req_id, mood)
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


func stop_moving() -> void:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	_heading = NAN
	if _mii:
		_mii.set_walking(false)
	if _figure:
		_figure.position = Vector3.ZERO
		_figure.scale = Vector3.ONE


func clear_reaction() -> void:
	if _mood_tween and _mood_tween.is_valid():
		_mood_tween.kill()
	if _mii:
		_mii.set_pose("stand", true)
	_heading = NAN
	if _figure:
		_figure.rotation_degrees = Vector3.ZERO
		_figure.position = Vector3.ZERO
		_figure.scale = Vector3.ONE
	if is_instance_valid(_bubble_sprite):
		_bubble_sprite.queue_free()
	if is_instance_valid(_bubble_vp):
		_bubble_vp.queue_free()
	_bubble_sprite = null
	_bubble_vp = null


func _show_bubble(req_id: String, mood: int) -> void:
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
	_bubble_sprite.position.y = _height + 0.15
	add_child(_bubble_sprite)
