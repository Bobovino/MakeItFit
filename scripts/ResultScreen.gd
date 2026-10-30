extends CanvasLayer
class_name ResultScreen

# What the RENT OUT button ends in.
#
# Rented: which apartment, and which phase of it. Then where
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


var _layer_root: Control
var _card: PanelContainer
var _failure := false
var _primary: Button


func _ready() -> void:
	# The panel Main.tscn gives this node is from an older layout; it is
	# built here instead.
	if has_node("Panel"):
		$Panel.queue_free()


# info: {level_name, has_next, phase, phase_title, phase_count}
func show_success(info: Dictionary) -> void:
	_failure = false
	var body := _open()
	var retired := GameState.is_retired()

	var title := GameTheme.title_label(info.get("level_name", "") as String, GameTheme.FS_DISPLAY)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(title)
	# Which phase of the level this was, when it has more than one.
	var count: int = info.get("phase_count", 0)
	if count >= 2:
		var phase: int = info.get("phase", 0)
		var ph_title := tr(info.get("phase_title", "") as String)
		var ph := Label.new()
		ph.text = (tr("Phase %d of %d") % [mini(phase, count - 1) + 1, count]) + ("  ·  " + ph_title if ph_title != "" else "")
		ph.add_theme_font_override("font", GameTheme.font("mono_bold"))
		ph.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
		ph.add_theme_color_override("font_color", GameTheme.INK_SOFT)
		ph.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_child(ph)

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
	_header(body, tr("Not ready to rent"), reason, "")
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


# Kicker, title and subtitle.
func _header(body: VBoxContainer, kicker: String, title: String, subtitle: String) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	body.add_child(col)
	var k := Label.new()
	k.text = kicker.to_upper()
	k.add_theme_font_override("font", GameTheme.font("mono_bold"))
	k.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	k.add_theme_color_override("font_color", GameTheme.RED)
	col.add_child(k)
	var t := Label.new()
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
