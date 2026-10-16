extends CanvasLayer
class_name ResultScreen

# What the RENT OUT button ends in.
#
# Rented: which apartment, who lives there now and for what rent; the stars,
# with why (the share of the budget left over) and what the next one takes;
# what the level earned; how far the portfolio is from the goal. Then where
# to go: on to the next level (selected, so Enter goes on), or look around
# the apartment, play it again, or back to the projects.
#
# Not rented yet: what is missing, as a list, and back to the apartment to
# fix it (selected, and Esc does it too) — the work so far stays. Starting
# over is there as well, and asks first.
#
# Plain words throughout: it reports, it doesn't comment.

signal next_level_requested     # back to the projects (also "Retire" at the goal)
signal retry_requested          # start the level over
signal watch_again_requested    # close this and look around the finished apartment
signal advance_level_requested  # load the next owned level directly

const STAMP_RED := Color(0.780, 0.320, 0.260)

var _layer_root: Control
var _card: PanelContainer
var _failure := false
var _primary: Button


func _ready() -> void:
	# The panel Main.tscn gives this node is from an older layout; it is
	# built here instead.
	if has_node("Panel"):
		$Panel.queue_free()


# info: {level_name, tenant, rent, stars, funds, portfolio, has_next,
#        budget_left, budget_start}
func show_success(info: Dictionary) -> void:
	_failure = false
	var body := _open()
	var stars: int = info.get("stars", 1)
	var retired := GameState.is_retired()

	_header(body, tr("Rented out"), info.get("level_name", "") as String,
		tr("Tenant: %s · %s €/month") % [info.get("tenant", ""), _money(info.get("rent", 0))], true)

	# Stars, and what they are for.
	var star_box := VBoxContainer.new()
	star_box.add_theme_constant_override("separation", 2)
	body.add_child(star_box)
	var star_lbl := Label.new()
	star_lbl.add_theme_font_size_override("font_size", 34)
	star_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	star_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star_box.add_child(star_lbl)
	_animate_stars(star_lbl, stars)
	var start: int = info.get("budget_start", 0)
	var left: int = info.get("budget_left", 0)
	var share := float(left) / float(start) if start > 0 else 1.0
	var why := Label.new()
	why.add_theme_font_size_override("font_size", 14)
	why.add_theme_color_override("font_color", GameTheme.C_TEXT.darkened(0.15))
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if stars >= 3:
		why.text = tr("Top rating: %d%% of the budget left over.") % roundi(share * 100.0)
	else:
		var need := GameManager.STAR3_SHARE if stars == 2 else GameManager.STAR2_SHARE
		why.text = tr("%d%% of the budget left over · %d stars from %d%%") % [
			roundi(share * 100.0), stars + 1, roundi(need * 100.0)]
	star_box.add_child(why)

	# What the level brought in.
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 10)
	body.add_child(tiles)
	if start > 0:
		_tile(tiles, tr("Budget left"), "%s €" % _money(left), tr("of %s €") % _money(start))
	var funds: int = info.get("funds", 0)
	if funds > 0:
		_tile(tiles, tr("Studio funds"), "+%s €" % _money(funds), tr("for the next projects"))
	_tile(tiles, tr("Monthly rent"), "+%s €" % _money(info.get("rent", 0)), tr("to your portfolio"))

	# Towards the goal.
	var portfolio: int = info.get("portfolio", 0)
	var goal_row := HBoxContainer.new()
	body.add_child(goal_row)
	var goal_lbl := Label.new()
	goal_lbl.text = tr("Portfolio")
	goal_lbl.add_theme_font_size_override("font_size", 14)
	goal_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	goal_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	goal_row.add_child(goal_lbl)
	var goal_val := Label.new()
	goal_val.text = tr("%s of %s €/month") % [_money(portfolio), _money(GameState.RETIRE_GOAL)]
	goal_val.add_theme_font_size_override("font_size", 14)
	goal_val.add_theme_color_override("font_color", GameTheme.C_MUTED)
	goal_row.add_child(goal_val)
	body.add_child(_progress(float(portfolio) / float(GameState.RETIRE_GOAL)))
	if retired:
		var done := Label.new()
		done.text = tr("Goal reached: your portfolio pays for your retirement.")
		done.add_theme_font_size_override("font_size", 14)
		done.add_theme_color_override("font_color", GameTheme.C_GOOD)
		done.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(done)

	# Where to go.
	var bar := _footer(body)
	var back := _button(bar, tr("Projects"), "", func():
		visible = false
		next_level_requested.emit())
	back.tooltip_text = tr("Back to Projects")
	_button(bar, tr("View Apartment"), "", func(): watch_again_requested.emit())
	_button(bar, tr("Play Again"), "", func():
		MenuKit.dialog(self, tr("Play Again"), tr("Start this level over from the beginning? The layout you rented out stays saved."),
			tr("Start over"), func():
				visible = false
				retry_requested.emit(), false))
	_push(bar)
	if retired:
		_primary = _button(bar, tr("Retire"), "primary", func():
			visible = false
			next_level_requested.emit())
	elif info.get("has_next", false):
		_primary = _button(bar, tr("Next Level →"), "primary", func():
			visible = false
			advance_level_requested.emit())
	else:
		back.visible = false
		_primary = _button(bar, tr("Back to Projects"), "primary", func():
			visible = false
			next_level_requested.emit())
	_reveal()


# `reason` says what is wrong; `missing`, when known, lists it item by item.
func show_failure(reason: String, missing: Array = []) -> void:
	_failure = true
	var body := _open()
	_header(body, tr("Not ready to rent"), reason, "", false)
	if not missing.is_empty():
		var list := VBoxContainer.new()
		list.add_theme_constant_override("separation", 6)
		body.add_child(list)
		for m in missing:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 10)
			list.add_child(row)
			var x := Label.new()
			x.text = "✕"
			x.add_theme_font_size_override("font_size", 15)
			x.add_theme_color_override("font_color", GameTheme.C_BAD)
			x.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			row.add_child(x)
			MenuKit.text(row, m as String)
	var bar := _footer(body)
	_button(bar, tr("Restart Level"), "", func():
		MenuKit.dialog(self, tr("Restart Level"), tr("Discard this layout and start over?"), tr("Yes, restart"), func():
			visible = false
			retry_requested.emit()))
	_push(bar)
	_primary = _button(bar, tr("Keep furnishing"), "primary", _close_failure)
	_reveal()


func _close_failure() -> void:
	visible = false


func _input(event: InputEvent) -> void:
	if visible and _failure and MenuKit.is_escape(event):
		for c in get_children():
			if c is CanvasLayer:
				return   # a question is up: Esc is its Cancel
		_close_failure()
		get_viewport().set_input_as_handled()


# Main.tscn still connects the old panel's buttons to these.
func _on_next_pressed() -> void:
	next_level_requested.emit()


func _on_retry_pressed() -> void:
	retry_requested.emit()


# ── Building ─────────────────────────────────────────────────────────────────
# A fresh card over a dimmed backdrop; returns the box to fill.
func _open() -> VBoxContainer:
	if is_instance_valid(_layer_root):
		_layer_root.queue_free()
	visible = true
	_layer_root = Control.new()
	_layer_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_layer_root)
	ScreenFit.cover(_layer_root)
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.06, 0.62)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # the level under it stays untouchable
	_layer_root.add_child(bg)
	ScreenFit.cover(bg)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer_root.add_child(center)
	ScreenFit.cover(center)
	_card = PanelContainer.new()
	_card.theme = GameTheme.make()
	_card.add_theme_stylebox_override("panel", MenuKit._card_style(MenuKit.PANEL_BG, 14, 0))
	_card.custom_minimum_size.x = 640
	center.add_child(_card)
	var body := MenuKit._margins(VBoxContainer.new(), 32, 24, 32, 22) as VBoxContainer
	body.add_theme_constant_override("separation", 18)
	_card.add_child(body.get_parent())
	return body


# Kicker, title, subtitle; with `stamp`, the Housing Office's stamp beside it.
func _header(body: VBoxContainer, kicker: String, title: String, subtitle: String, stamp: bool) -> void:
	var row := HBoxContainer.new()
	body.add_child(row)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	var k := Label.new()
	k.text = kicker.to_upper()
	k.add_theme_font_size_override("font_size", 13)
	k.add_theme_color_override("font_color", GameTheme.C_GOOD if stamp else GameTheme.C_BAD)
	col.add_child(k)
	var t := Label.new()
	t.text = title
	var hand := GameTheme.handwriting()
	if hand and stamp:
		t.add_theme_font_override("font", hand)
		t.add_theme_font_size_override("font_size", 46)
	else:
		t.add_theme_font_size_override("font_size", 20 if not stamp else 30)
	t.add_theme_color_override("font_color", GameTheme.C_AMBER if stamp else GameTheme.C_TEXT)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(t)
	if subtitle != "":
		var s := Label.new()
		s.text = subtitle
		s.add_theme_font_size_override("font_size", 15)
		s.add_theme_color_override("font_color", GameTheme.C_TEXT.darkened(0.15))
		col.add_child(s)
	if stamp:
		var st := Label.new()
		st.text = tr("APPROVED")
		var hf := GameTheme.handwriting()
		if hf:
			st.add_theme_font_override("font", hf)
		st.add_theme_font_size_override("font_size", 26)
		st.add_theme_color_override("font_color", Color(STAMP_RED, 0.9))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(STAMP_RED, 0.85)
		sb.set_border_width_all(3)
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.anti_aliasing = true
		st.add_theme_stylebox_override("normal", sb)
		st.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		st.resized.connect(func(): st.pivot_offset = st.size * 0.5)
		row.add_child(st)
		if not GameState.reduce_motion:
			st.modulate.a = 0.0
			st.scale = Vector2(1.8, 1.8)
			var tw := st.create_tween().set_parallel(true)
			tw.tween_interval(0.35)
			tw.chain().tween_property(st, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
			tw.tween_property(st, "modulate:a", 1.0, 0.14)
			tw.chain().tween_callback(func(): Audio.play("place"))


func _tile(row: HBoxContainer, label: String, value: String, note: String) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", GameTheme.make_card_stylebox(Color(0.150, 0.132, 0.110), Color(0.260, 0.225, 0.178), 10))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(p)
	var vb := MenuKit._margins(VBoxContainer.new(), 6, 4, 6, 4)
	vb.add_theme_constant_override("separation", 0)
	p.add_child(vb.get_parent())
	var l := Label.new()
	l.text = label.to_upper()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(l)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 22)
	v.add_theme_color_override("font_color", GameTheme.C_TEXT)
	vb.add_child(v)
	var n := Label.new()
	n.text = note
	n.add_theme_font_size_override("font_size", 12)
	n.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(n)


func _progress(share: float) -> Control:
	var track := Panel.new()
	track.custom_minimum_size.y = 10
	var ts := StyleBoxFlat.new()
	ts.bg_color = Color(0.200, 0.176, 0.145)
	ts.set_corner_radius_all(5)
	track.add_theme_stylebox_override("panel", ts)
	var fill := Panel.new()
	var fs := StyleBoxFlat.new()
	fs.bg_color = GameTheme.C_GOOD
	fs.set_corner_radius_all(5)
	fill.add_theme_stylebox_override("panel", fs)
	track.add_child(fill)
	track.resized.connect(func():
		fill.size = Vector2(track.size.x * clampf(share, 0.0, 1.0), track.size.y))
	return track


func _footer(body: VBoxContainer) -> HBoxContainer:
	body.add_child(MenuKit._rule())
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	body.add_child(bar)
	return bar


func _push(bar: HBoxContainer) -> void:
	var p := Control.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(p)


func _button(bar: HBoxContainer, text: String, kind: String, on_press: Callable) -> Button:
	var b := MenuKit.button(text, kind)
	b.custom_minimum_size.y = 44
	if kind == "primary":
		b.custom_minimum_size.x = 190
	b.pressed.connect(on_press)
	b.mouse_entered.connect(func(): b.grab_focus())
	bar.add_child(b)
	return b


# The card settles in, and the default action is selected.
func _reveal() -> void:
	_primary.grab_focus.call_deferred()
	if GameState.reduce_motion:
		return
	_card.modulate.a = 0.0
	var tw := _card.create_tween().set_parallel(true)
	tw.tween_property(_card, "modulate:a", 1.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# Stars fill in one at a time with a pop; all at once with Reduce motion.
func _animate_stars(lbl: Label, stars: int) -> void:
	var shown := func(n: int) -> String: return "★".repeat(n) + "☆".repeat(3 - n)
	if GameState.reduce_motion:
		lbl.text = shown.call(stars)
		return
	lbl.text = shown.call(0)
	lbl.resized.connect(func(): lbl.pivot_offset = lbl.size * 0.5)
	var tw := lbl.create_tween()
	tw.tween_interval(0.25)
	for i in range(1, stars + 1):
		var n := i
		tw.tween_interval(0.25)
		tw.tween_callback(func():
			lbl.text = shown.call(n)
			Audio.play("place"))
		tw.tween_property(lbl, "scale", Vector2(1.18, 1.18), 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(lbl, "scale", Vector2.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# 10000 -> "10.000" / "10,000", the way the language writes it.
func _money(v: Variant) -> String:
	var n := absi(int(v))
	var s := str(n)
	var sep := "," if TranslationServer.get_locale().begins_with("en") else "."
	var out := ""
	while s.length() > 3:
		out = sep + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if int(v) < 0 else "") + s + out
