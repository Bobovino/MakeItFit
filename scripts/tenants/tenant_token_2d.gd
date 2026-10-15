extends Node2D
class_name TenantToken2D

# A tenant on the floor plan: a round token seen from above, sized by body
# (adult, teen, child; animals are an oval), in a colour of their own. Lives
# under the Floor node so it pans and zooms with the plan, but the Floor
# never knows about it: it isn't furniture, takes up no tiles and blocks
# nothing. All motion is tweened: hops from spot to spot, a squash on
# landing, a shake when annoyed, a bounce when happy.

const TILE := Floor.TILE_SIZE
const RADIUS := {"adult": 1.9, "teen": 1.7, "child": 1.35, "animal": 1.5}   # in tiles

var resident: TenantResident
var tile := Vector2.ZERO          # top-left of the 4x4-tile patch they stand on
var color := Color.WHITE
var _r := 1.9 * TILE
var _annoyed := false
var _body: Node2D                 # what moves; the token itself stays on its spot
var _bubble_anchor: Node2D
var _bubble: TenantBubble
var _move_tween: Tween
var _mood_tween: Tween
var _shown := false


func setup(r: TenantResident, tint: Color) -> void:
	resident = r
	color = tint
	_r = (RADIUS.get(r.body, 1.9) as float) * TILE
	z_index = 6
	_body = Node2D.new()
	add_child(_body)
	_body.draw.connect(_draw_body)
	_bubble_anchor = Node2D.new()
	_bubble_anchor.z_index = 30
	add_child(_bubble_anchor)


func _process(_delta: float) -> void:
	# Bubbles keep one size on screen however far the plan is zoomed.
	var s := get_global_transform_with_canvas().get_scale()
	if s.x > 0.0001:
		_bubble_anchor.scale = Vector2.ONE / s
	_bubble_anchor.position = Vector2(0, -_r - 2.0)


func center_of(t: Vector2) -> Vector2:
	return (t + Vector2(2, 2)) * TILE


func place(t: Vector2, animate: bool) -> void:
	if _move_tween and _move_tween.is_valid():
		_move_tween.kill()
	var from := position
	tile = t
	var to := center_of(t)
	if not animate or GameState.reduce_motion:
		position = to
		_body.position = Vector2.ZERO
		_body.scale = Vector2.ONE
		_shown = true
		return
	if not _shown:
		# First appearance: drop in.
		_shown = true
		position = to
		_body.scale = Vector2(0.2, 0.2)
		_move_tween = create_tween()
		_move_tween.tween_property(_body, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		return
	# One hop: up and over, then a squash on landing.
	var height := clampf(from.distance_to(to) * 0.25, TILE * 1.5, TILE * 6.0)
	_move_tween = create_tween()
	_move_tween.tween_property(_body, "scale", Vector2(1.15, 0.85), 0.06)
	_move_tween.tween_method(func(k: float):
		position = from.lerp(to, k)
		_body.position = Vector2(0, -sin(k * PI) * height)
		_body.scale = Vector2(0.92, 1.1), 0.0, 1.0, 0.32).set_trans(Tween.TRANS_SINE)
	_move_tween.tween_property(_body, "scale", Vector2(1.2, 0.8), 0.05)
	_move_tween.tween_property(_body, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func set_present(present: bool) -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0 if present else 0.0, 0.15)


func react(req_id: String, mood: int) -> void:
	clear_reaction()
	_annoyed = mood == TenantBubble.Mood.ANNOYED
	_body.queue_redraw()
	_bubble = TenantBubble.make(req_id, mood)
	_bubble_anchor.add_child(_bubble)
	_bubble.position = Vector2(-_bubble.get_combined_minimum_size().x * 0.5, -_bubble.get_combined_minimum_size().y - 10)
	if GameState.reduce_motion:
		return
	_bubble.pivot_offset = _bubble.get_combined_minimum_size() * Vector2(0.5, 1.0)
	_bubble.scale = Vector2(0.3, 0.3)
	var pop := _bubble.create_tween()
	pop.tween_property(_bubble, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_mood_tween = create_tween()
	if _annoyed:
		for i in 4:
			_mood_tween.tween_property(_body, "rotation_degrees", 14.0 if i % 2 == 0 else -14.0, 0.06)
		_mood_tween.tween_property(_body, "rotation_degrees", 0.0, 0.06)
	else:
		_mood_tween.tween_property(_body, "position:y", -TILE * 2.0, 0.12).set_ease(Tween.EASE_OUT)
		_mood_tween.tween_property(_body, "position:y", 0.0, 0.18).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func clear_reaction() -> void:
	if _mood_tween and _mood_tween.is_valid():
		_mood_tween.kill()
	_body.rotation_degrees = 0.0
	_annoyed = false
	_body.queue_redraw()
	if is_instance_valid(_bubble):
		_bubble.queue_free()
	_bubble = null


func _draw_body() -> void:
	var animal := resident and resident.body == "animal"
	var squash := Vector2(1.35, 0.8) if animal else Vector2.ONE
	_body.draw_set_transform(Vector2.ZERO, 0.0, squash)
	# Shadow, body, outline.
	_body.draw_circle(Vector2(1.5, 2.5), _r, Color(0, 0, 0, 0.28))
	_body.draw_circle(Vector2.ZERO, _r, color)
	_body.draw_arc(Vector2.ZERO, _r, 0, TAU, 32, color.darkened(0.45), 1.6, true)
	# A lighter crown so it reads as a head seen from above.
	_body.draw_circle(Vector2(-_r * 0.18, -_r * 0.22), _r * 0.45, color.lightened(0.25))
	_body.draw_set_transform(Vector2.ZERO)
	# Eyes, looking down at the player.
	var eye := _r * 0.16
	var ex := _r * 0.36
	var ey := _r * 0.12
	for sx in [-1.0, 1.0]:
		_body.draw_circle(Vector2(sx * ex, ey), eye, Color(0.08, 0.07, 0.07))
		if _annoyed:
			# Brows down toward the middle.
			_body.draw_line(Vector2(sx * (ex + eye * 1.6), ey - eye * 2.6), Vector2(sx * (ex - eye * 1.2), ey - eye * 1.4),
				Color(0.08, 0.07, 0.07), 1.4, true)
