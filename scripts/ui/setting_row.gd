class_name SettingRow
extends PanelContainer

# One line of a settings page, the way game menus have them: the whole row
# is one selectable thing (pointing at it or the arrow keys select it), its
# name on the left and its value on the right, and what it does is shown in
# the page's description strip while it is selected (see `selected`).
#
#   slider  ← → step it; or drag the bar
#   choice  ← → go through the options; or the arrows; a click goes to the next
#   toggle  ← →, Enter or a click flip it
#   action  Enter or a click runs it (the key to rebind, say)
#
# Its parts never take keyboard focus themselves, so ↑ ↓ always go from row
# to row.

signal selected(row: SettingRow)

const H := 50
const VALUE_W := 300

var title := ""
var _describe: Variant = ""   # a String, or a Callable(value) -> String
var _kind := ""
var _value: Variant
var _on_change: Callable
var _items: Array = []        # choice: [[text, value], ...]
var _shown: Callable          # slider: value -> text
var _step := 0.05
var _enabled := true

var _value_box: HBoxContainer
var _slider: HSlider
var _value_lbl: Label
var _switch: CheckButton
var _btn: Button


static func slider(label_text: String, describe: Variant, value: float, lo: float, hi: float, key_step: float,
		on_change: Callable, shown: Callable) -> SettingRow:
	var r := SettingRow.new()
	r._setup(label_text, describe, "slider", value, on_change)
	r._shown = shown
	r._step = key_step
	r._slider = HSlider.new()
	r._slider.min_value = lo
	r._slider.max_value = hi
	r._slider.step = 0.01
	r._slider.value = value
	r._slider.focus_mode = Control.FOCUS_NONE
	r._slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r._slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r._slider.custom_minimum_size.y = 24
	r._value_box.add_child(r._slider)
	r._value_lbl = r._value_label(HORIZONTAL_ALIGNMENT_RIGHT)
	r._value_lbl.custom_minimum_size.x = 52
	r._value_lbl.size_flags_horizontal = Control.SIZE_SHRINK_END
	r._value_lbl.text = shown.call(value) as String
	r._slider.value_changed.connect(func(v: float): r._apply_value(v))
	return r


static func choice(label_text: String, describe: Variant, items: Array, current: Variant, on_change: Callable) -> SettingRow:
	var r := SettingRow.new()
	r._setup(label_text, describe, "choice", current, on_change)
	r._items = items
	r._value_box.add_child(r._arrow("‹", -1))
	r._value_lbl = r._value_label(HORIZONTAL_ALIGNMENT_CENTER)
	r._value_box.add_child(r._arrow("›", 1))
	r._refresh()
	return r


static func toggle(label_text: String, describe: Variant, on: bool, on_change: Callable) -> SettingRow:
	var r := SettingRow.new()
	r._setup(label_text, describe, "toggle", on, on_change)
	r._value_lbl = r._value_label(HORIZONTAL_ALIGNMENT_RIGHT)
	r._switch = CheckButton.new()
	r._switch.focus_mode = Control.FOCUS_NONE
	r._switch.button_pressed = on
	r._switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r._switch.toggled.connect(func(v: bool): r._apply_value(v))
	r._value_box.add_child(r._switch)
	r._refresh()
	return r


static func action(label_text: String, describe: Variant, text: String, on_press: Callable) -> SettingRow:
	var r := SettingRow.new()
	r._setup(label_text, describe, "action", text, on_press)
	r._btn = Button.new()
	r._btn.text = text
	r._btn.focus_mode = Control.FOCUS_NONE
	r._btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r._btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r._btn.add_theme_font_size_override("font_size", 14)
	r._btn.pressed.connect(func(): r._activate())
	r._value_box.add_child(r._btn)
	return r


# What the description strip says about this row now.
func description() -> String:
	if _describe is Callable:
		return (_describe as Callable).call(_value) as String
	return _describe as String


# An action row's button text (the key just bound, say).
func set_text(text: String) -> void:
	if _btn:
		_btn.text = text


# Greyed out and inert, but still selectable so its description can say why.
func set_enabled(on: bool) -> void:
	_enabled = on
	_value_box.modulate.a = 1.0 if on else 0.35
	if _slider:
		_slider.editable = on
	if _switch:
		_switch.disabled = not on
	if _btn:
		_btn.disabled = not on


func _setup(label_text: String, describe: Variant, kind: String, value: Variant, on_change: Callable) -> void:
	title = label_text
	_describe = describe
	_kind = kind
	_value = value
	_on_change = on_change
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size.y = H
	mouse_filter = Control.MOUSE_FILTER_STOP
	_style(false)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 16)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(line)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(lbl)
	_value_box = HBoxContainer.new()
	_value_box.add_theme_constant_override("separation", 10)
	_value_box.custom_minimum_size.x = VALUE_W
	_value_box.size_flags_horizontal = Control.SIZE_SHRINK_END
	_value_box.mouse_filter = Control.MOUSE_FILTER_PASS
	line.add_child(_value_box)

	mouse_entered.connect(func():
		if not has_focus():
			grab_focus())
	focus_entered.connect(func():
		_style(true)
		selected.emit(self))
	focus_exited.connect(func(): _style(false))


func _value_label(align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", GameTheme.C_AMBER)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_value_box.add_child(l)
	return l


func _arrow(glyph: String, dir: int) -> Button:
	var b := Button.new()
	b.text = glyph
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(36, 36)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", GameTheme.C_MUTED)
	b.add_theme_color_override("font_hover_color", GameTheme.C_AMBER)
	b.pressed.connect(func(): _step_by(dir))
	return b


func _style(on: bool) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.07) if on else Color(1, 1, 1, 0.025)
	s.border_color = GameTheme.C_AMBER if on else Color(0, 0, 0, 0)
	s.border_width_left = 3
	s.set_corner_radius_all(6)
	s.corner_radius_top_left = 2
	s.corner_radius_bottom_left = 2
	s.content_margin_left = 16
	s.content_margin_right = 14
	s.anti_aliasing = true
	add_theme_stylebox_override("panel", s)


func _refresh() -> void:
	match _kind:
		"choice":
			for it in _items:
				if it[1] == _value:
					_value_lbl.text = it[0] as String
		"toggle":
			_value_lbl.text = tr("On") if _value else tr("Off")
			_value_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER if _value else GameTheme.C_MUTED)
			if _switch.button_pressed != (_value as bool):
				_switch.set_pressed_no_signal(_value as bool)
		"slider":
			_value_lbl.text = _shown.call(_value) as String


func _apply_value(v: Variant) -> void:
	if v == _value:
		return
	_value = v
	_refresh()
	_on_change.call(v)
	if has_focus():
		selected.emit(self)   # the description may depend on the value


func _step_by(dir: int) -> void:
	if not _enabled:
		return
	match _kind:
		"slider":
			_slider.value = clampf(snappedf((_value as float) + dir * _step, _step), _slider.min_value, _slider.max_value)
		"choice":
			var i := 0
			for k in _items.size():
				if _items[k][1] == _value:
					i = k
			_apply_value(_items[posmod(i + dir, _items.size())][1])
			Audio.play("click")
		"toggle":
			_apply_value(not (_value as bool))
			Audio.play("click")


func _activate() -> void:
	if not _enabled:
		return
	match _kind:
		"choice":
			_step_by(1)
		"toggle":
			_step_by(1)
		"action":
			Audio.play("click")
			_on_change.call()


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_left", true):
		_step_by(-1)
		accept_event()
	elif event.is_action_pressed("ui_right", true):
		_step_by(1)
		accept_event()
	elif event.is_action_pressed("ui_accept"):
		_activate()
		accept_event()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and _kind != "slider":
		_activate()
		accept_event()
