extends CanvasLayer
class_name HowToPlay

# Revisitable reference — the per-level "NEW MECHANIC" cards (Main.gd's
# _show_mechanic_intro_if_needed) only ever show once, the first time a
# player reaches that level, and there's no way to look them back up later.
# This pulls the same title/body pairs straight out of levels.json (so it
# can never drift out of sync with what the intro cards actually say),
# plus a static controls cheat-sheet and the needs glyph legend, on three
# pages of one window reachable from the menu at any time.

static func open(host: Node) -> HowToPlay:
	var m := HowToPlay.new()
	host.add_child(m)
	m._build()
	return m


var _step_page: Callable


func _build() -> void:
	layer = 26  # over the pause menu (24) and the settings screen

	# Three pages instead of one long scroll: the controls, what the needs
	# icons mean, and the mechanics met so far, picked on the left like the
	# settings' categories.
	var w := MenuKit.screen(self, tr("How to Play"), _close, true, false)
	var page: VBoxContainer = w["page"]
	var scroll: ScrollContainer = w["scroll"]
	var pages := [_controls_page, _needs_legend, _mechanic_cards]
	_step_page = MenuKit.categories(w["nav"], [tr("Controls"), tr("Needs"), tr("Mechanics")], func(i: int):
		for c in page.get_children():
			page.remove_child(c)
			c.queue_free()
		(pages[i] as Callable).call(page)
		scroll.scroll_vertical = 0)


func _controls_page(body: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	body.add_child(box)
	for line in _controls():
		MenuKit.bullet(box, line as String)


func _controls() -> Array:
	return [
		tr("Things are hung on walls in the 3D view: drag an item onto a wall. Buying a wall-only item from the floor plan switches to 3D for you."),
		tr("In the 3D view, Q and E turn the view a quarter at a time and W/A/S/D move it. Scroll to zoom, left-drag empty floor to pan, middle-drag to orbit freely, middle-click to recenter."),
		tr("The Walls button (or Home/End) switches between walls Up, Cutaway and Down. Cutaway lowers only the walls in front of where you are looking."),
		tr("Double-click a box that has an apartment inside to step into it. Back takes you out one level; Map shows every apartment and jumps to any of them."),
		tr("Press R to rotate a piece — it cycles through all 4 facings, including a true 180° flip."),
		tr("Click a foldable piece (like a sofa bed) to fold or unfold it."),
		tr("The Builder tab (next to Furniture) adds walls, columns, windows, doors, and paints floor kinds like balcony or bathroom."),
		tr("The dot in a piece's corner shows how easily it moves: green moves freely, yellow can move but makes the tenant less comfortable, red keeps one position all day unless it is on a rail. On larger pieces, one to three feathers beside the dot say the same thing."),
		tr("The bar at the bottom is the goal: every need listed there has to be ticked."),
		tr("A piece with a heart after its name is a keepsake: it can be moved but never sold."),
		tr("Furniture can move between an apartment and the boxes in it: drag a piece onto a box, or, from inside a box, onto the Back button. You go with it, and it is on your pointer ready to put down. Hold Shift as you let go to send it without going: it waits under Owned in that apartment's catalogue, free to place. Keepsakes stay where they are."),
		tr("Build has a Glass Wall beside the ordinary Wall: a real wall you can't put things or look through, but daylight passes it. Good for a guest room that would otherwise be dark."),
		tr("Reeded glass and curtains hide what is behind them without darkening the room: they stop a line of sight and split a room into zones, but daylight passes. A curtain only does so while it is drawn (click it to draw it or pull it back)."),
		tr("A caged bird needs daylight, and it sings: a bed within half a metre of it is no place to sleep."),
		tr("You can also buy for another apartment: pick a piece in the catalogue and click it down on a box (or on Back). It is paid for from the budget of the apartment you are in and delivered to the other one, for a lodger whose own budget won't stretch."),
		tr("Rentals in the furniture catalogue are boxed apartments: placing one pays you its rent, in exchange for the floor it takes up. Removing it means paying the rent back. Double-click a box to look inside."),
		tr("Ctrl+%s undoes your last action; Ctrl+Shift+%s redoes it.") % [
			OS.get_keycode_string(GameState.undo_keycode),
			OS.get_keycode_string(GameState.undo_keycode),
		],
		tr("Press T to switch between the Floor Plan and 3D view."),
		tr("Press 1-9 to jump straight to a moment (Day, Night, ...) without clicking its tab."),
		tr("Press Up or Down to step to the floor above or below, Left or Right for the previous or next moment. On the floor plan W/S and A/D do the same."),
	]


# Reuses TenantCard's own glyph set instead of a second hand-maintained copy
# — the quest-tracker chips and this legend can never disagree about what a
# given icon means.
func _needs_legend(body: VBoxContainer) -> void:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 10)
	body.add_child(row)
	for need in TenantCard.NEED_GLYPH:
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", GameTheme.make_card_stylebox(GameTheme.CARD_DIM, GameTheme.CARD_DIM, 8))
		tile.custom_minimum_size = Vector2(160, 0)
		row.add_child(tile)
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 8)
		tile.add_child(chip)
		var glyph := Label.new()
		glyph.text = TenantCard.NEED_GLYPH[need] as String
		glyph.add_theme_font_size_override("font_size", 18)
		chip.add_child(glyph)
		var name_lbl := Label.new()
		name_lbl.text = Loc.need_name(need as String)
		name_lbl.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
		name_lbl.add_theme_color_override("font_color", GameTheme.INK)
		chip.add_child(name_lbl)


# Pulled straight from levels.json's own "mechanic_intro" fields (the same
# data Main.gd's one-time "NEW MECHANIC" card reads) so this can never say
# something different from what a first-time player actually saw.
func _mechanic_cards(body: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	body.add_child(box)

	var seen_titles: Dictionary = {}
	var f := FileAccess.open("res://data/levels.json", FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			Loc.localize_levels(parsed as Dictionary)
			for lvl in (parsed as Dictionary).get("levels", []) as Array:
				var intro := (lvl as Dictionary).get("mechanic_intro", {}) as Dictionary
				if intro.is_empty():
					continue
				var t := intro.get("title", "") as String
				if t == "" or seen_titles.has(t):
					continue
				seen_titles[t] = true
				_mechanic_card(box, t, intro.get("body", "") as String)


func _mechanic_card(parent: Control, mech_title: String, body: String) -> void:
	var vb := MenuKit.boxed(parent)
	var t := Label.new()
	t.text = mech_title
	t.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	t.add_theme_color_override("font_color", GameTheme.INK)
	vb.add_child(t)
	MenuKit.text(vb, body, GameTheme.FS_CAPTION)


func _close() -> void:
	queue_free()


# Esc closes this window; Q and E (or Page Up/Down) turn the page; ↑ ↓
# scroll it.
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var scroll := find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
	match key.keycode:
		KEY_ESCAPE:
			if key.echo:
				return
			_close()
		KEY_Q, KEY_PAGEUP:
			if key.echo:
				return
			_step_page.call(-1)
		KEY_E, KEY_PAGEDOWN:
			if key.echo:
				return
			_step_page.call(1)
		KEY_UP:
			scroll.scroll_vertical -= 60
		KEY_DOWN:
			scroll.scroll_vertical += 60
		_:
			return
	get_viewport().set_input_as_handled()
