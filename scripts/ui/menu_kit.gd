class_name MenuKit
extends RefCounted

# The shared shape of the game's windows (settings, how to play, credits):
#   - a dimmed backdrop; clicking it closes the window, as Esc does
#   - a card centred in the window whatever its shape, and never wider or
#     taller than it
#   - a header with the title and a close button, always in view
#   - a body that scrolls only when it doesn't fit
#   - a footer for the window's own buttons, always in view
# and the rows a settings list is made of, all on one grid: a label column,
# the control, and its value at the end.

const CARD_BG := Color(0.115, 0.100, 0.085)
const ROW_H := 40          # a row's height: a finger's worth on a phone
const LABEL_W := 170       # the label column
const VALUE_W := 48        # a slider's value column
const EDGE := 16           # the least room left around the card
const FONT_ROW := 15
const FONT_HINT := 12
const FONT_SECTION := 12


# Builds the window under `layer` and returns {card, top, body, footer}.
# `close` runs on the close button and on a click outside the card; the
# caller also calls it on Esc. `top` (tabs, say) stays in view above the
# body; put buttons in `footer`. Either is hidden while empty. With `tall`
# the window takes all the height it can, so switching what the body shows
# doesn't make it jump.
static func modal(layer: CanvasLayer, title: String, width: float, close: Callable, tall := false) -> Dictionary:
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.78)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(bg)
	ScreenFit.cover(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			close.call())

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	ScreenFit.cover(center)

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = CARD_BG
	cs.border_color = GameTheme.C_BORDER
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(12)
	cs.anti_aliasing = true
	cs.set_content_margin_all(22)
	cs.content_margin_top = 16
	cs.shadow_color = Color(0, 0, 0, 0.45)
	cs.shadow_size = 18
	cs.shadow_offset = Vector2(0, 6)
	card.add_theme_stylebox_override("panel", cs)
	card.theme = GameTheme.make()
	center.add_child(card)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	card.add_child(col)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	col.add_child(header)
	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(title_lbl)
	var x_btn := Button.new()
	x_btn.text = "✕"
	x_btn.flat = true
	x_btn.tooltip_text = TranslationServer.translate("Close")
	x_btn.custom_minimum_size = Vector2(ROW_H, ROW_H)
	x_btn.add_theme_font_size_override("font_size", 18)
	x_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	x_btn.add_theme_color_override("font_hover_color", GameTheme.C_AMBER)
	x_btn.pressed.connect(close)
	header.add_child(x_btn)
	col.add_child(HSeparator.new())

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	col.add_child(top)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	# Room on the right for the scrollbar, so it never sits on a control.
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_right", 14)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 18)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(body)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	col.add_child(footer)

	var fit := func() -> void:
		if not is_instance_valid(card) or not card.is_inside_tree():
			return
		var avail := ScreenFit.size_of(card) - Vector2(EDGE, EDGE) * 2.0
		card.custom_minimum_size.x = minf(width, avail.x)
		footer.visible = footer.get_child_count() > 0
		top.visible = top.get_child_count() > 0
		# What the card needs besides the body, then the body as tall as it
		# wants up to what is left.
		scroll.custom_minimum_size.y = 0.0
		var chrome := card.get_combined_minimum_size().y - scroll.get_combined_minimum_size().y
		var room := maxf(60.0, avail.y - chrome)
		scroll.custom_minimum_size.y = room if tall else clampf(body.get_combined_minimum_size().y, 60.0, room)
	# Twice: once the caller has filled the body, and once more after a
	# layout pass, when wrapped text knows its height.
	var hook := func() -> void:
		fit.call_deferred()
		card.get_tree().process_frame.connect(fit, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
		var vp := card.get_viewport()
		vp.size_changed.connect(fit)
		card.tree_exiting.connect(func():
			if vp.size_changed.is_connected(fit):
				vp.size_changed.disconnect(fit), CONNECT_ONE_SHOT)
	if card.is_inside_tree():
		hook.call()
	else:
		card.tree_entered.connect(hook, CONNECT_ONE_SHOT)
	body.minimum_size_changed.connect(func(): fit.call_deferred())
	return {"card": card, "top": top, "body": body, "footer": footer, "scroll": scroll}


# A row of tabs in `bar`; picking one calls `show.call(index)`. The first is
# picked to start with.
static func tabs(bar: Container, names: Array, show: Callable) -> void:
	var group := ButtonGroup.new()
	for i in names.size():
		var b := button(names[i] as String)
		b.toggle_mode = true
		b.button_group = group
		b.add_theme_stylebox_override("pressed", _tab_on())
		b.add_theme_color_override("font_pressed_color", GameTheme.C_AMBER)
		b.toggled.connect(func(on: bool):
			if on:
				show.call(i))
		bar.add_child(b)
	(bar.get_child(0) as Button).button_pressed = true


static func _tab_on() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.290, 0.230, 0.130)
	s.border_color = GameTheme.C_AMBER
	s.set_border_width_all(1)
	s.set_corner_radius_all(8)
	s.set_content_margin(SIDE_LEFT, 12)
	s.set_content_margin(SIDE_RIGHT, 12)
	s.set_content_margin(SIDE_TOP, 6)
	s.set_content_margin(SIDE_BOTTOM, 6)
	s.anti_aliasing = true
	return s


# A line of running text in the body colour, wrapped, for help pages.
static func text(parent: Control, line: String, size := 14) -> Label:
	var lbl := Label.new()
	lbl.text = line
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(lbl)
	return lbl


# A list item: an amber bullet and its wrapped text beside it.
static func bullet(parent: Control, line: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 10)
	parent.add_child(r)
	var dot := Label.new()
	dot.text = "•"
	dot.add_theme_font_size_override("font_size", 14)
	dot.add_theme_color_override("font_color", GameTheme.C_AMBER.darkened(0.2))
	dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	r.add_child(dot)
	text(r, line)
	return r


# A framed block, for a card inside the body.
static func boxed(parent: Control) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", GameTheme.make_card_stylebox(Color(0.145, 0.127, 0.105), Color(0.250, 0.215, 0.170), 8))
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)
	return vb


# A titled group of rows in the body. Returns the box to add rows to.
static func section(body: Control, title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	body.add_child(box)
	var lbl := Label.new()
	lbl.text = title.to_upper()
	lbl.add_theme_font_size_override("font_size", FONT_SECTION)
	lbl.add_theme_color_override("font_color", GameTheme.C_AMBER.darkened(0.3))
	box.add_child(lbl)
	return box


static func label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", FONT_ROW)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.custom_minimum_size.x = LABEL_W
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


# Label | control (stretched) | trailing, on one line.
static func row(rows: Control, text: String, control: Control, trailing: Control = null) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	r.custom_minimum_size.y = ROW_H
	rows.add_child(r)
	r.add_child(label(text))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_child(control)
	if trailing:
		r.add_child(trailing)
	return r


# A slider with its value shown at the end, as `shown.call(value)` puts it.
static func slider_row(rows: Control, text: String, value: float, lo: float, hi: float, step: float,
		on_change: Callable, shown: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size.y = 24
	var val := Label.new()
	val.text = shown.call(value) as String
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", GameTheme.C_MUTED)
	val.custom_minimum_size.x = VALUE_W
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row(rows, text, slider, val)
	slider.value_changed.connect(func(v: float):
		val.text = shown.call(v) as String
		on_change.call(v))
	return slider


# A whole-row switch: the label on the left, the switch on the right, and
# the row is what you press.
static func switch_row(rows: Control, text: String, on: bool, on_toggle: Callable) -> CheckButton:
	var sw := CheckButton.new()
	sw.text = text
	sw.button_pressed = on
	sw.custom_minimum_size.y = ROW_H
	sw.add_theme_font_size_override("font_size", FONT_ROW)
	sw.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sw.toggled.connect(on_toggle)
	rows.add_child(sw)
	return sw


# A picker filled from [[text, metadata], ...], `selected` matched against
# the metadata.
static func picker(items: Array, selected: Variant) -> OptionButton:
	var p := OptionButton.new()
	p.add_theme_font_size_override("font_size", 14)
	p.custom_minimum_size.y = 34
	p.fit_to_longest_item = false
	for it in items:
		p.add_item(it[0] as String)
		p.set_item_metadata(p.item_count - 1, it[1])
		if it[1] == selected:
			p.select(p.item_count - 1)
	p.get_popup().add_theme_font_size_override("font_size", 14)
	return p


static func hint(rows: Control, text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", FONT_HINT)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(lbl)
	return lbl


# "primary" is the amber call to action, "danger" reads as a warning,
# anything else is a plain button.
static func button(text: String, kind := "") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 38
	b.add_theme_font_size_override("font_size", 14)
	if kind == "primary":
		var rs := GameTheme.make_rent_btn_style()
		b.add_theme_stylebox_override("normal", rs[0])
		b.add_theme_stylebox_override("hover", rs[1])
		b.add_theme_stylebox_override("pressed", rs[1])
		b.add_theme_stylebox_override("focus", rs[1])
		b.add_theme_color_override("font_color", GameTheme.C_AMBER)
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.72))
	elif kind == "danger":
		b.add_theme_color_override("font_color", GameTheme.C_BAD)
		b.add_theme_color_override("font_hover_color", GameTheme.C_BAD.lightened(0.2))
	return b


# Asks before `on_yes` runs: the buttons of `bar` give way to the question
# with Cancel and `yes_text`, and come back on Cancel.
static func confirm(bar: Container, question: String, yes_text: String, on_yes: Callable) -> void:
	var shown: Array = []
	for c in bar.get_children():
		if (c as Control).visible:
			shown.append(c)
			(c as Control).visible = false
	var ask := HBoxContainer.new()
	ask.add_theme_constant_override("separation", 8)
	ask.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(ask)
	var q := Label.new()
	q.text = question
	q.add_theme_font_size_override("font_size", 14)
	q.add_theme_color_override("font_color", GameTheme.C_TEXT)
	q.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	q.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ask.add_child(q)
	var no := button(TranslationServer.translate("Cancel"))
	ask.add_child(no)
	var yes := button(yes_text, "danger")
	ask.add_child(yes)
	no.pressed.connect(func():
		ask.queue_free()
		for c in shown:
			if is_instance_valid(c):
				(c as Control).visible = true)
	yes.pressed.connect(on_yes)
	no.grab_focus.call_deferred()


# Esc, for a window's _input(): true when it was Esc going down.
static func is_escape(event: InputEvent) -> bool:
	var k := event as InputEventKey
	return k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE
