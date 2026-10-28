extends CanvasLayer
class_name DialogueScene

# A short conversation beside the plan: the tenants (or a tenant and the
# player, the ajustador) talking a change through, one line at a time, in a
# panel at the left, the speaker's portrait on top, like an adviser in a
# management game. The flat stays in view (the lines are mostly about it)
# and the game goes on. Click, Enter or Space for the next line; Esc skips
# the rest.
#
# lines: [{who, text}], `who` a resident id, or "you" for the player.
# speakers: {id: {name, color, body, feminine}} (Main builds it from the
# household). Whoever has a Mii (a body other than "animal") is shown above
# their line, the same Mii as in the flat, nodding as they say it.

signal finished

const PANEL_W := 300.0
const MARGIN := 20.0
const FACE_PX := 150
const MiiPortraitScript := preload("res://scripts/ui/mii_portrait.gd")

var _lines: Array = []
var _speakers: Dictionary = {}
var _i := -1
var _card: PanelContainer
var _who: Label
var _text: Label
var _header: Label
var _face_frame: PanelContainer
var _face: TextureRect
var _portrait = null   # MiiPortrait, made for the first speaker who has a Mii
var _face_who := ""
var _plan_bottom := Callable()   # -> float: where the plan ends on screen, above the needs bar or the shop


static func play(host: Node, lines: Array, speakers: Dictionary, title := "", plan_bottom := Callable()) -> DialogueScene:
	var d := DialogueScene.new()
	d._lines = lines
	d._speakers = speakers
	d._plan_bottom = plan_bottom
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
	_card.custom_minimum_size.x = PANEL_W
	_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_card.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_next())
	anchor.add_child(_card)
	# At the left, its foot just above the needs bar, or above the shop
	# while it is open (_process keeps it there); it grows upwards.
	_card.anchor_left = 0.0
	_card.anchor_right = 0.0
	_card.anchor_top = 1.0
	_card.anchor_bottom = 1.0
	_card.offset_left = MARGIN
	_card.offset_right = MARGIN + PANEL_W
	_card.offset_bottom = -110.0
	_card.grow_vertical = Control.GROW_DIRECTION_BEGIN

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_card.add_child(vb)
	_header = Label.new()
	_header.text = title.to_upper()
	_header.visible = title != ""
	_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_header.add_theme_font_override("font", GameTheme.font("mono_bold"))
	_header.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	_header.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	vb.add_child(_header)
	# The portrait's place is kept for every line once anyone in the scene
	# has a Mii, so the panel doesn't jump when the player speaks.
	_face_frame = PanelContainer.new()
	_face_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_face_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_face_frame)
	_face = TextureRect.new()
	_face.custom_minimum_size = Vector2(FACE_PX, FACE_PX)
	_face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE   # rendered at twice the size, for sharpness
	_face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_face.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face_frame.add_child(_face)
	_face_frame.visible = _lines.any(func(l): return _has_mii(_speakers.get((l as Dictionary).get("who", ""), {}) as Dictionary))
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
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	hint.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	vb.add_child(hint)


static func _has_mii(sp: Dictionary) -> bool:
	var body := sp.get("body", "") as String
	return body != "" and body != "animal"


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
	_show_face(who, sp)
	Audio.play("click")
	if not GameState.reduce_motion:
		_card.pivot_offset = _card.size * 0.5
		_card.scale = Vector2(0.97, 0.97)
		create_tween().tween_property(_card, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# The speaker's Mii above the line, turned towards the flat, framed in
# their colour; an empty place for the player or an animal.
func _show_face(who: String, sp: Dictionary) -> void:
	var body := sp.get("body", "") as String
	_face_frame.modulate.a = 1.0 if _has_mii(sp) else 0.0
	if not _has_mii(sp):
		return
	var frame := GameTheme.card_style(Color(1, 1, 1, 0.6), 10, 2, Vector2.ZERO)
	frame.border_color = sp.get("color", GameTheme.NAVY) as Color
	_face_frame.add_theme_stylebox_override("panel", frame)
	if _portrait == null:
		_portrait = MiiPortraitScript.create(FACE_PX * 2, "head")
		add_child(_portrait)
		_face.texture = _portrait.texture()
	if who != _face_who:
		_face_who = who
		_portrait.show_body(body, sp.get("feminine", false) as bool)
		_portrait.pose(1.0, 28.0)
	if not GameState.reduce_motion:
		_portrait.nod()


func _process(_delta: float) -> void:
	if _plan_bottom.is_valid():
		var bottom := (_plan_bottom.call() as float) - 14.0
		# Short of room (the shop open on a small screen): a smaller portrait
		# rather than a panel running off the top.
		if _face_frame.visible:
			var rest := _card.get_combined_minimum_size().y - _face.custom_minimum_size.y
			var face := clampf(bottom - MARGIN - rest, 72.0, FACE_PX)
			if absf(face - _face.custom_minimum_size.x) > 1.0:
				_face.custom_minimum_size = Vector2(face, face)
		# Exactly as tall as it needs, its foot on `bottom`.
		var h := _card.get_combined_minimum_size().y
		var vh := get_viewport().get_visible_rect().size.y
		_card.offset_bottom = bottom - vh
		_card.offset_top = bottom - vh - h


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
