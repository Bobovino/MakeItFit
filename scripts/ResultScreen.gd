extends CanvasLayer
class_name ResultScreen

# What the RENT OUT button ends in.
#
# Rented: which apartment and who lives there now; the stars, with why (the
# share of the budget left over) and what the next one takes. Then where
# to go: on to the next level (selected, so Enter goes on), or look around
# the apartment, play it again, or back to the projects.
#
# Not rented yet: what is missing, as a list, and back to the apartment to
# fix it (selected, and Esc does it too) — the work so far stays. Starting
# over is there as well, and asks first.
#
# Plain words throughout: it reports, it doesn't comment.

signal next_level_requested     # back to the projects (also "Finish" at the goal)
signal retry_requested          # start the level over
signal watch_again_requested    # close this and look around the finished apartment
signal walk_through_requested   # close this and walk around the finished apartment in first person
signal advance_level_requested  # load the next owned level directly

const STAMP_INK := GameTheme.NAVY   # the Housing Office's stamp

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
		tr("Tenant: %s") % info.get("tenant", ""), true)

	# Stars, and what they are for.
	var star_box := VBoxContainer.new()
	star_box.add_theme_constant_override("separation", 2)
	body.add_child(star_box)
	var star_lbl := Label.new()
	star_lbl.add_theme_font_size_override("font_size", GameTheme.FS_DISPLAY)
	star_lbl.add_theme_color_override("font_color", GameTheme.RED)
	star_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	star_box.add_child(star_lbl)
	_animate_stars(star_lbl, stars)
	var start: int = info.get("budget_start", 0)
	var left: int = info.get("budget_left", 0)
	var share := float(left) / float(start) if start > 0 else 1.0
	var why := Label.new()
	why.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	why.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if stars >= 3:
		why.text = tr("Top rating: %d%% of the budget left over.") % roundi(share * 100.0)
	else:
		var need := GameManager.STAR3_SHARE if stars == 2 else GameManager.STAR2_SHARE
		why.text = tr("%d%% of the budget left over · %d stars from %d%%") % [
			roundi(share * 100.0), stars + 1, roundi(need * 100.0)]
	star_box.add_child(why)

	if retired:
		var done := Label.new()
		done.text = tr("Goal reached: your portfolio is complete.")
		done.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
		done.add_theme_color_override("font_color", GameTheme.OK)
		done.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(done)

	# Where to go.
	var bar := _footer(body)
	var back := _button(bar, tr("Projects"), "", func():
		visible = false
		next_level_requested.emit())
	back.tooltip_text = tr("Back to Projects")
	_button(bar, tr("View Apartment"), "", func(): watch_again_requested.emit())
	# Walking needs a keyboard and mouse for now; touch controls come later.
	if not TouchControls.active:
		var walk := _button(bar, tr("Walk Through"), "", func(): walk_through_requested.emit())
		walk.tooltip_text = tr("Walk around the finished flat at eye height")
	_button(bar, tr("Play Again"), "", func():
		MenuKit.dialog(self, tr("Play Again"), tr("Start this level over from the beginning? The layout you rented out stays saved."),
			tr("Start over"), func():
				visible = false
				retry_requested.emit(), false))
	_push(bar)
	if retired:
		_primary = _button(bar, tr("Finish"), "primary", func():
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
			x.text = "\ueb55"
			x.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
			x.add_theme_color_override("font_color", GameTheme.RED)
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
	bg.color = Color(GameTheme.NAVY, 0.62)
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
	_card.custom_minimum_size.x = 680
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
	k.add_theme_font_override("font", GameTheme.font("mono_bold"))
	k.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	k.add_theme_color_override("font_color", GameTheme.OK if stamp else GameTheme.RED)
	col.add_child(k)
	var t: Label
	if stamp:
		t = GameTheme.title_label(title, GameTheme.FS_DISPLAY)
	else:
		t = Label.new()
		t.text = title
		t.add_theme_font_size_override("font_size", GameTheme.FS_LABEL)
		t.add_theme_color_override("font_color", GameTheme.INK)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(t)
	if subtitle != "":
		var s := Label.new()
		s.text = subtitle
		s.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
		s.add_theme_color_override("font_color", GameTheme.INK_SOFT)
		col.add_child(s)
	if stamp:
		var st := Label.new()
		st.text = tr("APPROVED")
		st.add_theme_font_override("font", GameTheme.font("display"))
		st.add_theme_font_size_override("font_size", GameTheme.FS_TITLE)
		st.add_theme_color_override("font_color", Color(STAMP_INK, 0.9))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		sb.border_color = Color(STAMP_INK, 0.85)
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
	var shown := func(n: int) -> String: return "\uf6a6".repeat(n) + "\ueb2e".repeat(3 - n)
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
