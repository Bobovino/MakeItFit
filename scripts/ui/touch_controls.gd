extends CanvasLayer
class_name TouchControls

# Touch play for phones and tablets. One finger already works through
# Godot's touch-to-mouse emulation (drag a piece to move it, tap a foldable
# to fold it, drag empty floor in 3D to pan); this adds what a mouse wheel,
# middle button, right button and keyboard did:
#
#   - Two fingers: pinch to zoom and drag to pan, on the plan and in 3D,
#     where twisting them also turns the view. A second finger landing calls
#     off whatever the first had started (a piece picked up, a pan).
#   - Long-press a piece: a bar of big buttons to rotate, fold or sell it
#     (sell only, for something hung on a wall).
#   - Buying: the finger moves the piece about without putting it down;
#     the bar has Rotate, Place and Cancel.
#
# Only while the last input came from a finger (`active`); with a mouse
# nothing here shows, so the desktop game is unchanged.

static var active := OS.has_feature("mobile")   # the last pointer input was a touch (a phone starts out so)
const LONG_PRESS_MS := 450

var main: Node                  # Main (no class_name)

var _touches: Dictionary = {}   # finger index -> position
var _gesture := false
var _bar: PanelContainer
var _row: HBoxContainer
var _state := ""                # what the bar is showing: "", "placing", "piece", "wall"
var _piece: Furniture
var _wall_hit: Dictionary = {}


func _ready() -> void:
	layer = 15
	_bar = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.10, 0.16, 0.92)
	sb.border_color = Color(0.62, 0.82, 0.98, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(8)
	_bar.add_theme_stylebox_override("panel", sb)
	_bar.visible = false
	add_child(_bar)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	_bar.add_child(_row)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		active = true
	elif (event is InputEventMouseMotion or event is InputEventMouseButton) \
			and event.device != InputEvent.DEVICE_ID_EMULATION:
		active = false
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
			if _touches.size() == 2:
				_gesture = true
				main.touch_cancel_pointer()
		else:
			_touches.erase(st.index)
			if _touches.size() < 2:
				_gesture = false
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if not _touches.has(sd.index):
			return
		if _gesture and _touches.size() >= 2:
			var ids := _touches.keys()
			ids.sort()
			var a0: Vector2 = _touches[ids[0]]
			var b0: Vector2 = _touches[ids[1]]
			_touches[sd.index] = sd.position
			var a1: Vector2 = _touches[ids[0]]
			var b1: Vector2 = _touches[ids[1]]
			var d0 := a0.distance_to(b0)
			if d0 > 1.0:
				var zoom := a1.distance_to(b1) / d0
				var pan := (a1 + b1) * 0.5 - (a0 + b0) * 0.5
				var twist := rad_to_deg(wrapf((b1 - a1).angle() - (b0 - a0).angle(), -PI, PI))
				main.touch_gesture(zoom, pan, twist, (a1 + b1) * 0.5)
			get_viewport().set_input_as_handled()
		else:
			_touches[sd.index] = sd.position


func _process(_delta: float) -> void:
	var want := ""
	if active:
		if main.touch_is_placing():
			want = "placing"
		elif is_instance_valid(_piece):
			want = "piece"
		elif not _wall_hit.is_empty():
			want = "wall"
	if want != _state:
		_state = want
		_rebuild()
	if _bar.visible:
		_place_bar()


# Long-pressing a piece (from the plan's Furniture or the 3D view) selects it.
func show_piece(f: Furniture) -> void:
	_wall_hit = {}
	_piece = f
	_state = "?"   # force a rebuild even if it was already showing a piece


func show_wall_item(hit: Dictionary) -> void:
	_piece = null
	_wall_hit = hit
	_state = "?"


func close_actions() -> void:
	_piece = null
	_wall_hit = {}


func _rebuild() -> void:
	for c in _row.get_children():
		c.queue_free()
	match _state:
		"placing":
			_add_button("⟳  " + tr("Rotate"), FaxStyle.KEY_GREY, func(): main.touch_rotate_placing())
			_add_button("✓  " + tr("Place"), FaxStyle.KEY_GREEN, func(): main.touch_confirm_placing())
			_add_button("✕  " + tr("Cancel"), Color(0.62, 0.26, 0.24), func(): main.touch_cancel_placing())
		"piece":
			_add_button("⟳  " + tr("Rotate"), FaxStyle.KEY_GREY, func(): main.touch_rotate_piece(_piece))
			if _piece.foldable:
				_add_button("⇕  " + tr("Fold"), FaxStyle.KEY_GREY, func(): main.touch_fold_piece(_piece))
			if not _piece.keepsake:
				_add_button("€  " + tr("Sell"), Color(0.62, 0.26, 0.24), func():
					var f := _piece
					close_actions()
					main.touch_sell_piece(f))
			_add_button("✕", FaxStyle.KEY_GREY, close_actions)
		"wall":
			_add_button("€  " + tr("Sell"), Color(0.62, 0.26, 0.24), func():
				var hit := _wall_hit
				close_actions()
				main.touch_sell_wall_item(hit))
			_add_button("✕", FaxStyle.KEY_GREY, close_actions)
	_bar.visible = _state != ""
	_bar.reset_size()


func _add_button(text: String, face: Color, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(64, 56)   # a fingertip, on a phone
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	FaxStyle.key(b, face, Color(0.96, 0.97, 0.98))
	b.pressed.connect(action)
	_row.add_child(b)


# Centred, just above the needs bar.
func _place_bar() -> void:
	var view := get_viewport().get_visible_rect().size
	var bottom: float = main.touch_bar_bottom()
	var sz := _bar.get_combined_minimum_size()
	_bar.position = Vector2((view.x - sz.x) * 0.5, bottom - sz.y - 12.0)
