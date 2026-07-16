extends CanvasLayer
class_name HowToPlay

# Revisitable reference — the per-level "NEW MECHANIC" cards (Main.gd's
# _show_mechanic_intro_if_needed) only ever show once, the first time a
# player reaches that level, and there's no way to look them back up later.
# This pulls the same title/body pairs straight out of levels.json (so it
# can never drift out of sync with what the intro cards actually say),
# plus a static controls cheat-sheet and the needs glyph legend, all in one
# scrollable panel reachable from the Menu at any time.

static func open(host: Node) -> HowToPlay:
	var m := HowToPlay.new()
	host.add_child(m)
	m._build()
	return m


func _build() -> void:
	layer = 26  # above SettingsMenu (25), since it's opened from there

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.92)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_close())

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
	cs.border_color = GameTheme.C_BORDER
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(10)
	cs.anti_aliasing = true
	cs.set_content_margin_all(24)
	cs.shadow_color = Color(0, 0, 0, 0.4)
	cs.shadow_size  = 10
	card.add_theme_stylebox_override("panel", cs)
	card.position            = Vector2(290, 60)
	card.custom_minimum_size = Vector2(700, 600)
	add_child(card)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	card.add_child(outer)

	var title := Label.new()
	title.text = "HOW TO PLAY"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	vb.add_child(_section("Controls", [
		"Click a highlighted wall edge on the floor plan to inspect it or hang items.",
		"In the 3D view, drag an item onto a wall to hang it there.",
		"In the 3D view, middle-drag to orbit the camera, left-drag empty floor to pan, and scroll to zoom. Middle-click (no drag) recenters the view.",
		"Press R to rotate a piece — it cycles through all 4 facings, including a true 180° flip.",
		"Double-click a foldable piece (like a sofa bed) to fold or unfold it.",
		"The Builder tab (next to Furniture) adds walls, columns, windows, doors, and paints floor kinds like balcony or bathroom.",
		"Ctrl+%s undoes your last action; Ctrl+Shift+%s redoes it." % [
			OS.get_keycode_string(GameState.undo_keycode),
			OS.get_keycode_string(GameState.undo_keycode),
		],
		"Press T to switch between the Floor Plan and 3D view.",
		"Press Q to reopen the last wall panel you inspected on the current floor.",
		"Press 1-9 to jump straight to a moment (Day, Night, ...) without clicking its tab.",
		"Press Up/W or Down/S to step to the floor above or below.",
		"Press Left/A or Right/D to step to the previous or next moment.",
	]))

	vb.add_child(_needs_legend())
	vb.add_child(_mechanic_cards())

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	var rs := GameTheme.make_rent_btn_style()
	close_btn.add_theme_stylebox_override("normal",  rs[0])
	close_btn.add_theme_stylebox_override("hover",   rs[1])
	close_btn.add_theme_stylebox_override("pressed", rs[1])
	close_btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	close_btn.pressed.connect(_close)
	outer.add_child(close_btn)


func _section_header(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text.to_upper()
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	return lbl


func _section(header: String, lines: Array) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_child(_section_header(header))
	for line in lines:
		var lbl := Label.new()
		lbl.text = "•  " + (line as String)
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(lbl)
	return box


# Reuses TenantCard's own glyph set instead of a second hand-maintained copy
# — the quest-tracker chips and this legend can never disagree about what a
# given icon means.
func _needs_legend() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.add_child(_section_header("Needs"))
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 14)
	row.add_theme_constant_override("v_separation", 8)
	box.add_child(row)
	for need in TenantCard.NEED_GLYPH:
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 6)
		var glyph := Label.new()
		glyph.text = TenantCard.NEED_GLYPH[need] as String
		glyph.add_theme_font_size_override("font_size", 15)
		chip.add_child(glyph)
		var name_lbl := Label.new()
		name_lbl.text = (need as String).capitalize()
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
		chip.add_child(name_lbl)
		row.add_child(chip)
	return box


# Pulled straight from levels.json's own "mechanic_intro" fields (the same
# data Main.gd's one-time "NEW MECHANIC" card reads) so this can never say
# something different from what a first-time player actually saw.
func _mechanic_cards() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.add_child(_section_header("Mechanics"))

	var seen_titles: Dictionary = {}
	var f := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			for lvl in (parsed as Dictionary).get("levels", []) as Array:
				var intro := (lvl as Dictionary).get("mechanic_intro", {}) as Dictionary
				if intro.is_empty():
					continue
				var t := intro.get("title", "") as String
				if t == "" or seen_titles.has(t):
					continue
				seen_titles[t] = true
				box.add_child(_mechanic_card(t, intro.get("body", "") as String))
	return box


func _mechanic_card(mech_title: String, body: String) -> PanelContainer:
	var chip := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.06, 0.05, 0.6)
	s.border_color = Color(0.30, 0.80, 0.60, 0.55)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(12)
	chip.add_theme_stylebox_override("panel", s)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	chip.add_child(vb)

	var t := Label.new()
	t.text = mech_title
	t.add_theme_font_size_override("font_size", 14)
	t.add_theme_color_override("font_color", Color(0.55, 0.90, 0.72))
	vb.add_child(t)

	var b := Label.new()
	b.text = body
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", GameTheme.C_TEXT)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(b)

	return chip


func _close() -> void:
	queue_free()
