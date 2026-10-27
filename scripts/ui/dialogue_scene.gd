extends CanvasLayer
class_name DialogueScene

# A short conversation over the plan: the tenants (or a tenant and the
# player, the ajustador) talking a change through, one line at a time, in a
# card above the needs bar. Click, Enter or Space for the next line; Esc
# skips the rest. It doesn't cover the flat or stop the game.
#
# lines: [{who, text}], `who` a resident id, or "you" for the player.
# speakers: {id: {name, color}} (Main builds it from the household).

signal finished

const CARD_W := 620.0

var _lines: Array = []
var _speakers: Dictionary = {}
var _i := -1
var _card: PanelContainer
var _who: Label
var _text: Label
var _header: Label


static func play(host: Node, lines: Array, speakers: Dictionary, title := "") -> DialogueScene:
	var d := DialogueScene.new()
	d._lines = lines
	d._speakers = speakers
	host.add_child(d)
	d._build(title)
	d._next()
	return d


func _build(title: String) -> void:
	layer = 22
	var anchor := Control.new()
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(anchor)
	_card = PanelContainer.new()
	_card.theme = GameTheme.make()
	_card.add_theme_stylebox_override("panel", GameTheme.card_style(GameTheme.CARD, 12, 18, Vector2(4, 5)))
	_card.custom_minimum_size.x = CARD_W
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_card.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_next())
	anchor.add_child(_card)
	# Above the needs bar, centred.
	_card.anchor_left = 0.5
	_card.anchor_right = 0.5
	_card.anchor_top = 1.0
	_card.anchor_bottom = 1.0
	_card.offset_left = -CARD_W * 0.5
	_card.offset_right = CARD_W * 0.5
	_card.offset_bottom = -110.0
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_card.add_child(vb)
	_header = Label.new()
	_header.text = title.to_upper()
	_header.visible = title != ""
	_header.add_theme_font_override("font", GameTheme.font("mono_bold"))
	_header.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	_header.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	vb.add_child(_header)
	_who = Label.new()
	_who.add_theme_font_override("font", GameTheme.font("display"))
	_who.add_theme_font_size_override("font_size", GameTheme.FS_LABEL)
	vb.add_child(_who)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	_text.add_theme_color_override("font_color", GameTheme.INK)
	vb.add_child(_text)
	var hint := Label.new()
	hint.text = tr("Click or Enter to go on · Esc to skip")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	hint.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	vb.add_child(hint)


func _next() -> void:
	_i += 1
	if _i >= _lines.size():
		_end()
		return
	var line := _lines[_i] as Dictionary
	var who := line.get("who", "") as String
	var sp := _speakers.get(who, {}) as Dictionary
	_who.text = sp.get("name", tr("You") if who == "you" else who.capitalize()) as String
	_who.add_theme_color_override("font_color", sp.get("color", GameTheme.NAVY) as Color)
	_text.text = tr(line.get("text", "") as String)
	Audio.play("click")
	if not GameState.reduce_motion:
		_card.pivot_offset = _card.size * 0.5
		_card.scale = Vector2(0.97, 0.97)
		create_tween().tween_property(_card, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _end() -> void:
	if is_queued_for_deletion():
		return
	finished.emit()
	queue_free()


# _input, not _unhandled_input: Esc here skips the scene, and must not also
# reach the game (which opens its menu on Esc).
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not (event as InputEventKey).pressed or (event as InputEventKey).echo:
		return
	var k := (event as InputEventKey).keycode
	if k == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_end()
	elif k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
		get_viewport().set_input_as_handled()
		_next()
