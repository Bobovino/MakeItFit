class_name MenuKit
extends RefCounted

# The game's menus share one shape, the one players know from other games:
#
#   screen()   a large window (settings, how to play, credits): the title and
#              a close button on top; categories down the left; the page on
#              the right, scrolling only when it doesn't fit; under it, for
#              settings, what the selected row does; at the bottom the
#              page's own buttons on the left and Back on the right, with
#              the keys that work. It keeps its size from page to page.
#   menu_button()  one entry of a short list like the pause menu.
#   dialog()   asks before something that can't be undone; Cancel is
#              selected to start with and Esc means Cancel.
#
# Every one of them works with the mouse, a finger or the keyboard alone:
# whatever is selected is outlined, ↑ ↓ move, Enter picks, Esc goes back.

const PANEL_BG := Color(0.118, 0.103, 0.088)
const NAV_BG := Color(0.090, 0.080, 0.069)
const EDGE := 16.0                     # the least room left around a window
const SCREEN_SIZE := Vector2(980, 620)


# ── The large window ─────────────────────────────────────────────────────────
# Builds it under `layer` and returns its parts: {panel, nav, page, scroll,
# about_title, about_text, actions, back}. `nav` is null without `with_nav`,
# the about strip is hidden without `with_about`. `close` runs on Back, the ✕
# and a click outside; the caller runs it on Esc.
static func screen(layer: CanvasLayer, title: String, close: Callable, with_nav := true,
		with_about := false, size := SCREEN_SIZE) -> Dictionary:
	_backdrop(layer, close)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	ScreenFit.cover(center)

	var panel := PanelContainer.new()
	panel.theme = GameTheme.make()
	panel.add_theme_stylebox_override("panel", _card_style(PANEL_BG, 14, 0))
	center.add_child(panel)
	var fit := func() -> void:
		if is_instance_valid(panel) and panel.is_inside_tree():
			panel.custom_minimum_size = size.min(ScreenFit.size_of(panel) - Vector2(EDGE, EDGE) * 2.0)
	_on_resize(panel, fit)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	panel.add_child(col)

	# Header: the title in the game's hand, like a note on the drawing.
	var header := _margins(HBoxContainer.new(), 26, 10, 14, 6)
	col.add_child(header.get_parent())
	header.add_theme_constant_override("separation", 12)
	var t := Label.new()
	t.text = title
	var hand := GameTheme.handwriting()
	if hand:
		t.add_theme_font_override("font", hand)
		t.add_theme_font_size_override("font_size", 40)
	else:
		t.add_theme_font_size_override("font_size", 26)
	t.add_theme_color_override("font_color", GameTheme.C_AMBER)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(t)
	var x := close_button(close)
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(x)
	col.add_child(_rule())

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 0)
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(middle)

	var nav: VBoxContainer = null
	if with_nav:
		var nav_panel := PanelContainer.new()
		var ns := StyleBoxFlat.new()
		ns.bg_color = NAV_BG
		ns.set_content_margin_all(12)
		nav_panel.add_theme_stylebox_override("panel", ns)
		nav_panel.custom_minimum_size.x = 220
		middle.add_child(nav_panel)
		nav = VBoxContainer.new()
		nav.add_theme_constant_override("separation", 4)
		nav_panel.add_child(nav)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.add_child(right)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	var page := _margins(VBoxContainer.new(), 22, 18, 18, 18)
	page.get_parent().size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 6)
	scroll.add_child(page.get_parent())

	# What the selected setting does, in a strip of its own that keeps its
	# height, so the page doesn't jump as the selection moves.
	var about := PanelContainer.new()
	about.add_theme_stylebox_override("panel", _card_style(Color(0.150, 0.132, 0.110), 10, 12))
	(about.get_theme_stylebox("panel") as StyleBoxFlat).shadow_size = 0
	(about.get_theme_stylebox("panel") as StyleBoxFlat).set_border_width_all(1)
	about.custom_minimum_size.y = 84
	var about_wrap := _margins(about, 18, 0, 18, 14)
	right.add_child(about_wrap.get_parent())
	var about_box := VBoxContainer.new()
	about_box.add_theme_constant_override("separation", 4)
	about.add_child(about_box)
	var about_title := Label.new()
	about_title.add_theme_font_size_override("font_size", 15)
	about_title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	about_box.add_child(about_title)
	var about_text := Label.new()
	about_text.add_theme_font_size_override("font_size", 14)
	about_text.add_theme_color_override("font_color", GameTheme.C_TEXT.darkened(0.1))
	about_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about_box.add_child(about_text)
	if not with_about:
		about_wrap.get_parent().visible = false

	col.add_child(_rule())
	var footer := _margins(HBoxContainer.new(), 22, 12, 22, 14)
	col.add_child(footer.get_parent())
	footer.add_theme_constant_override("separation", 10)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	footer.add_child(actions)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(push)
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 16)
	footer.add_child(hints)
	var back := button(TranslationServer.translate("Back"), "primary")
	back.custom_minimum_size.x = 140
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(close)
	footer.add_child(back)
	if not TouchControls.active:
		if with_about:
			hints.add_child(keycap("↑↓", TranslationServer.translate("Select")))
			hints.add_child(keycap("←→", TranslationServer.translate("Change")))
		if with_nav:
			hints.add_child(keycap("Q E", TranslationServer.translate("Category")))
		hints.add_child(keycap("Esc", ""))

	return {"panel": panel, "nav": nav, "page": page, "scroll": scroll, "about_title": about_title,
		"about_text": about_text, "actions": actions, "back": back}


# Fills `nav` with one entry per name; picking one calls `show.call(index)`.
# Returns a Callable(step) that moves the pick by `step` (for Q and E).
static func categories(nav: VBoxContainer, names: Array, show: Callable) -> Callable:
	var group := ButtonGroup.new()
	var buttons: Array[Button] = []
	for i in names.size():
		var b := Button.new()
		b.text = names[i] as String
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size.y = 44
		b.add_theme_font_size_override("font_size", 16)
		b.add_theme_stylebox_override("normal", _nav_style(false, false))
		b.add_theme_stylebox_override("hover", _nav_style(false, true))
		b.add_theme_stylebox_override("pressed", _nav_style(true, false))
		b.add_theme_stylebox_override("hover_pressed", _nav_style(true, false))
		b.add_theme_color_override("font_color", GameTheme.C_TEXT.darkened(0.15))
		b.add_theme_color_override("font_hover_color", GameTheme.C_TEXT)
		b.add_theme_color_override("font_pressed_color", GameTheme.C_AMBER)
		b.add_theme_color_override("font_hover_pressed_color", GameTheme.C_AMBER)
		b.toggled.connect(func(on: bool):
			if on:
				show.call(i))
		nav.add_child(b)
		buttons.append(b)
	buttons[0].button_pressed = true
	return func(step: int) -> void:
		for i in buttons.size():
			if buttons[i].button_pressed:
				buttons[posmod(i + step, buttons.size())].button_pressed = true
				Audio.play("click")
				return


static func _nav_style(on: bool, hover: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(GameTheme.C_AMBER.r, GameTheme.C_AMBER.g, GameTheme.C_AMBER.b, 0.12) if on \
		else (Color(1, 1, 1, 0.05) if hover else Color(0, 0, 0, 0))
	s.border_color = GameTheme.C_AMBER if on else Color(0, 0, 0, 0)
	s.border_width_left = 3
	s.set_corner_radius_all(6)
	s.corner_radius_top_left = 2
	s.corner_radius_bottom_left = 2
	s.content_margin_left = 16
	s.content_margin_right = 12
	return s


# A heading inside a page.
static func heading(page: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	var room := StyleBoxEmpty.new()
	room.content_margin_top = 14 if page.get_child_count() > 0 else 0
	room.content_margin_bottom = 2
	l.add_theme_stylebox_override("normal", room)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", GameTheme.C_AMBER.darkened(0.3))
	page.add_child(l)
	return l


# A key and what it does, for the footer: "[Esc] Back".
static func keycap(key: String, what: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	var k := Label.new()
	k.text = key
	k.add_theme_font_size_override("font_size", 12)
	k.add_theme_color_override("font_color", GameTheme.C_TEXT)
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color(0.200, 0.176, 0.145)
	ks.border_color = Color(0.380, 0.330, 0.260)
	ks.set_border_width_all(1)
	ks.border_width_bottom = 2
	ks.set_corner_radius_all(4)
	ks.content_margin_left = 6
	ks.content_margin_right = 6
	ks.content_margin_top = 1
	ks.content_margin_bottom = 1
	k.add_theme_stylebox_override("normal", ks)
	k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_child(k)
	if what != "":
		var w := Label.new()
		w.text = what
		w.add_theme_font_size_override("font_size", 13)
		w.add_theme_color_override("font_color", GameTheme.C_MUTED)
		w.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		r.add_child(w)
	return r


# ── Short lists (the pause menu) ─────────────────────────────────────────────
# A wide entry: selected by pointing at it or by ↑ ↓, outlined in amber
# while selected. "primary" is the default action, "danger" can't be undone.
static func menu_button(text: String, kind := "") -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size.y = 50
	b.add_theme_font_size_override("font_size", 17)
	var base := Color(0.170, 0.150, 0.125)
	var normal := _entry_style(base, Color(0, 0, 0, 0))
	var sel := _entry_style(base.lightened(0.08), GameTheme.C_AMBER)
	if kind == "primary":
		normal = _entry_style(Color(0.330, 0.245, 0.095), Color(0.560, 0.430, 0.180))
		sel = _entry_style(Color(0.420, 0.310, 0.110), GameTheme.C_AMBER)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", sel)
	b.add_theme_stylebox_override("focus", sel)
	b.add_theme_stylebox_override("pressed", sel)
	var fc := GameTheme.C_AMBER if kind == "primary" else (GameTheme.C_BAD if kind == "danger" else GameTheme.C_TEXT)
	for c in ["font_color", "font_hover_color", "font_focus_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, fc if c == "font_color" else fc.lightened(0.15))
	b.mouse_entered.connect(func():
		if not b.has_focus():
			b.grab_focus())
	return b


static func _entry_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(8)
	s.content_margin_left = 20
	s.content_margin_right = 20
	s.anti_aliasing = true
	return s


# A plain button: "primary" is the amber call to action, "danger" reads as a
# warning.
static func button(text: String, kind := "") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 40
	b.add_theme_font_size_override("font_size", 15)
	if kind == "primary":
		var rs := GameTheme.make_rent_btn_style()
		b.add_theme_stylebox_override("normal", rs[0])
		b.add_theme_stylebox_override("hover", rs[1])
		b.add_theme_stylebox_override("pressed", rs[1])
		b.add_theme_stylebox_override("focus", rs[1])
		b.add_theme_color_override("font_color", GameTheme.C_AMBER)
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.72))
		b.add_theme_color_override("font_focus_color", Color(1.0, 0.96, 0.72))
	elif kind == "danger":
		b.add_theme_color_override("font_color", GameTheme.C_BAD)
		b.add_theme_color_override("font_hover_color", GameTheme.C_BAD.lightened(0.2))
		b.add_theme_color_override("font_focus_color", GameTheme.C_BAD.lightened(0.2))
	return b


static func close_button(close: Callable) -> Button:
	var x := Button.new()
	x.text = "✕"
	x.flat = true
	x.focus_mode = Control.FOCUS_NONE
	x.tooltip_text = TranslationServer.translate("Close")
	x.custom_minimum_size = Vector2(44, 44)
	x.add_theme_font_size_override("font_size", 20)
	x.add_theme_color_override("font_color", GameTheme.C_MUTED)
	x.add_theme_color_override("font_hover_color", GameTheme.C_AMBER)
	x.pressed.connect(close)
	return x


# ── Asking first ─────────────────────────────────────────────────────────────
# A small window over everything: what is about to happen, Cancel (selected
# to start with, and what Esc does) and the action itself. `on_yes` runs
# after the window has gone.
static func dialog(host: Node, title: String, text: String, yes_text: String, on_yes: Callable,
		danger := true) -> CanvasLayer:
	var d := _Dialog.new()
	d.layer = 40
	host.add_child(d)
	var cancel := func() -> void:
		d.queue_free()
	d.cancel = cancel
	_backdrop(d, cancel)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_child(center)
	ScreenFit.cover(center)
	var card := PanelContainer.new()
	card.theme = GameTheme.make()
	card.add_theme_stylebox_override("panel", _card_style(PANEL_BG, 14, 2))
	card.custom_minimum_size.x = 460
	center.add_child(card)
	var vb := _margins(VBoxContainer.new(), 26, 22, 26, 20)
	card.add_child(vb.get_parent())
	vb.add_theme_constant_override("separation", 14)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 20)
	t.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(t)
	var body := Label.new()
	body.text = text
	body.add_theme_font_size_override("font_size", 15)
	body.add_theme_color_override("font_color", GameTheme.C_TEXT)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.x = 408
	vb.add_child(body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_END
	vb.add_child(row)
	var no := button(TranslationServer.translate("Cancel"))
	no.custom_minimum_size.x = 140
	no.pressed.connect(cancel)
	row.add_child(no)
	var yes := button(yes_text, "danger" if danger else "primary")
	yes.custom_minimum_size.x = 160
	yes.pressed.connect(func():
		d.queue_free()
		on_yes.call())
	row.add_child(yes)
	for b in [no, yes]:
		var btn := b as Button
		btn.mouse_entered.connect(func(): btn.grab_focus())
	no.focus_neighbor_right = no.get_path_to(yes)
	yes.focus_neighbor_left = yes.get_path_to(no)
	no.grab_focus.call_deferred()
	return d


class _Dialog extends CanvasLayer:
	var cancel: Callable

	func _input(event: InputEvent) -> void:
		if MenuKit.is_escape(event):
			cancel.call()
			get_viewport().set_input_as_handled()


# ── Text for help pages ──────────────────────────────────────────────────────
static func text(parent: Control, line: String, size := 15) -> Label:
	var lbl := Label.new()
	lbl.text = line
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_constant_override("paragraph_spacing", 2)
	parent.add_child(lbl)
	return lbl


# A list item: an amber bullet and its wrapped text beside it.
static func bullet(parent: Control, line: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	parent.add_child(r)
	var dot := Label.new()
	dot.text = "•"
	dot.add_theme_font_size_override("font_size", 15)
	dot.add_theme_color_override("font_color", GameTheme.C_AMBER.darkened(0.2))
	dot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	r.add_child(dot)
	text(r, line)
	return r


# A framed block, for a card inside a page.
static func boxed(parent: Control) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", GameTheme.make_card_stylebox(Color(0.150, 0.132, 0.110), Color(0.260, 0.225, 0.178), 8))
	parent.add_child(panel)
	var vb := _margins(VBoxContainer.new(), 8, 6, 8, 6)
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb.get_parent())
	return vb


# Esc, for a window's _input(): true when it was Esc going down.
static func is_escape(event: InputEvent) -> bool:
	var k := event as InputEventKey
	return k != null and k.pressed and not k.echo and k.keycode == KEY_ESCAPE


# ── Pieces ───────────────────────────────────────────────────────────────────
static func _backdrop(layer: CanvasLayer, close: Callable) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.06, 0.72)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(bg)
	ScreenFit.cover(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			close.call())


static func _card_style(bg: Color, radius: int, margin: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = GameTheme.C_BORDER
	s.set_border_width_all(2)
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	s.set_content_margin_all(margin)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 22
	s.shadow_offset = Vector2(0, 8)
	return s


static func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(GameTheme.C_BORDER.r, GameTheme.C_BORDER.g, GameTheme.C_BORDER.b, 0.8)
	r.custom_minimum_size.y = 1
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# `inner` inside a MarginContainer with these margins; returns `inner`.
static func _margins(inner: Control, l: int, t: int, r: int, b: int) -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(inner)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return inner


# Runs `fit` now (or once in the tree) and whenever the window changes size.
static func _on_resize(node: Control, fit: Callable) -> void:
	var hook := func() -> void:
		fit.call()
		var vp := node.get_viewport()
		vp.size_changed.connect(fit)
		node.tree_exiting.connect(func():
			if vp.size_changed.is_connected(fit):
				vp.size_changed.disconnect(fit), CONNECT_ONE_SHOT)
	if node.is_inside_tree():
		hook.call()
	else:
		node.tree_entered.connect(hook, CONNECT_ONE_SHOT)
