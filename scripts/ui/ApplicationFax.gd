extends CanvasLayer
class_name ApplicationFax

# The tenant's rental application, printed by a fax machine over the level
# when it starts: each line is one requirement in the tenant's own words, and
# as a line finishes printing its requirement's chip stamps into the needs bar
# (TenantCard), with a short ink line from one to the other. The bar stays
# the precise reference; this is the introduction to it. Reopened from the
# bar's fax button, the sheet is shown already printed, and clicking a line
# points at its chip again.
#
# Purely presentation: it reads the level's TenantApplication and drives the
# TenantCard's chips; nothing here touches the checker.

signal closed

const WIDTH := 470.0
const LINE_FONT_SIZE := 22
const FEED_TIME := 0.22
const CHARS_PER_SEC := 55.0

var _app: TenantApplication
var _card: TenantCard
var _animate := true

var _scroll: ScrollContainer
var _paper: PanelContainer
var _rows: Array = []        # one per printed line: {row, label, icon, line}
var _footer: Control
var _lcd: Label
var _key: Button
var _links: Node2D
var _printing := false
var _skipping := false
var _active_tween: Tween


# `animate` false shows the sheet already printed (reopening it).
static func open(host: Node, app: TenantApplication, card: TenantCard, animate: bool) -> ApplicationFax:
	var fax := ApplicationFax.new()
	fax._app = app
	fax._card = card
	fax._animate = animate and not GameState.reduce_motion
	host.add_child(fax)
	return fax


func _ready() -> void:
	layer = 20
	_build()
	if _animate:
		_card.begin_stamping()
		_print_sheet()
	else:
		_show_printed()


func _bar_top() -> float:
	if is_instance_valid(_card) and _card.is_visible_in_tree():
		return _card.get_global_transform_with_canvas().origin.y
	return get_viewport().get_visible_rect().size.y


func _build() -> void:
	var view := get_viewport().get_visible_rect().size

	# Swallows every click while the sheet is up; a click while it prints
	# skips to the end, a click once it's done closes it.
	var blocker := Control.new()
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	ScreenFit.cover(blocker)
	blocker.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_on_key())

	# Dims the plan but not the needs bar, which is where the stamps land.
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.05, 0.09, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.position = Vector2.ZERO
	dim.size = Vector2(view.x, _bar_top())
	add_child(dim)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", -6)   # the sheet tucks into the slot
	column.position = Vector2((view.x - WIDTH) * 0.5, 14)
	column.custom_minimum_size.x = WIDTH
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	# ── the machine ──
	var machine := PanelContainer.new()
	machine.add_theme_stylebox_override("panel", FaxStyle.machine())
	machine.mouse_filter = Control.MOUSE_FILTER_STOP
	column.add_child(machine)
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 10)
	machine.add_child(mrow)
	var mtitle := Label.new()
	mtitle.text = tr("RENTAL APPLICATION")
	mtitle.add_theme_font_size_override("font_size", 12)
	mtitle.add_theme_color_override("font_color", Color(0.80, 0.82, 0.84))
	mtitle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mrow.add_child(mtitle)
	_lcd = FaxStyle.lcd(tr("READY"))
	_lcd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lcd.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mrow.add_child(_lcd)
	_key = Button.new()
	_key.custom_minimum_size = Vector2(96, 34)
	_key.add_theme_font_size_override("font_size", 13)
	_key.focus_mode = Control.FOCUS_NONE
	FaxStyle.key(_key, FaxStyle.KEY_GREEN, Color(0.94, 1.0, 0.95))
	_key.pressed.connect(_on_key)
	mrow.add_child(_key)

	var slot_holder := MarginContainer.new()
	slot_holder.add_theme_constant_override("margin_left", 14)
	slot_holder.add_theme_constant_override("margin_right", 14)
	slot_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot_holder.add_child(FaxStyle.slot())
	column.add_child(slot_holder)
	column.move_child(slot_holder, 1)

	# ── the sheet, fed out of the slot: the scroll area grows as it prints ──
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(WIDTH - 28.0, 0)
	_scroll.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	column.add_child(_scroll)

	_paper = PanelContainer.new()
	_paper.add_theme_stylebox_override("panel", FaxStyle.paper())
	_paper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paper.mouse_filter = Control.MOUSE_FILTER_STOP
	_scroll.add_child(_paper)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_paper.add_child(vb)

	var head := Label.new()
	head.text = tr("FAX  ·  RE: RENTAL APPLICATION  ·  PAGE 1/1")
	head.add_theme_font_size_override("font_size", 9)
	head.add_theme_color_override("font_color", FaxStyle.INK_SOFT)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(head)
	var rule := HSeparator.new()
	rule.add_theme_color_override("color", FaxStyle.INK_SOFT)
	vb.add_child(rule)
	var who := Label.new()
	who.text = tr_n("Applicant: %s", "Applicants: %s", _app.residents.size()) % _app.signatories()
	who.add_theme_font_size_override("font_size", 14)
	who.add_theme_color_override("font_color", FaxStyle.INK)
	who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(who)

	var hand := load("res://assets/fonts/Caveat.ttf") as Font
	var many := _app.residents.size() > 1
	for line in _app.printed_lines():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.mouse_filter = Control.MOUSE_FILTER_STOP
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		vb.add_child(row)
		var text_col := VBoxContainer.new()
		text_col.add_theme_constant_override("separation", -4)
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text_col)
		var lbl := Label.new()
		lbl.text = tr(line.text)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.add_theme_font_override("font", hand)
		lbl.add_theme_font_size_override("font_size", LINE_FONT_SIZE)
		lbl.add_theme_color_override("font_color", FaxStyle.INK)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_col.add_child(lbl)
		if many and line.speaker != &"":
			var by := Label.new()
			by.text = "— " + _app.speaker_name(line)
			by.add_theme_font_size_override("font_size", 10)
			by.add_theme_color_override("font_color", FaxStyle.INK_SOFT)
			by.mouse_filter = Control.MOUSE_FILTER_IGNORE
			text_col.add_child(by)
		# The requirement's icon, stamped at the end of its line.
		var icon_box := CenterContainer.new()
		icon_box.custom_minimum_size = Vector2(34, 34)
		icon_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ring := PanelContainer.new()
		var ring_sb := StyleBoxFlat.new()
		ring_sb.bg_color = Color(0, 0, 0, 0)
		ring_sb.border_color = FaxStyle.STAMP_INK
		ring_sb.set_border_width_all(2)
		ring_sb.set_corner_radius_all(17)
		ring_sb.set_content_margin_all(4)
		ring.add_theme_stylebox_override("panel", ring_sb)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ring.add_child(Requirements.make_icon(line.requirement, 17))
		icon_box.add_child(ring)
		row.add_child(icon_box)
		row.gui_input.connect(_on_row_input.bind(_rows.size()))
		_rows.append({"row": row, "label": lbl, "icon": ring, "line": line})

	_footer = VBoxContainer.new()
	vb.add_child(_footer)
	var rule2 := HSeparator.new()
	rule2.add_theme_color_override("color", FaxStyle.INK_SOFT)
	_footer.add_child(rule2)
	var sign := Label.new()
	sign.text = _app.signatories()
	sign.add_theme_font_override("font", hand)
	sign.add_theme_font_size_override("font_size", 26)
	sign.add_theme_color_override("font_color", Color(0.15, 0.22, 0.45))
	sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_footer.add_child(sign)

	_links = Node2D.new()
	_links.z_index = 10
	add_child(_links)


func _max_sheet_height() -> float:
	var top := _scroll.get_global_transform_with_canvas().origin.y
	return maxf(120.0, _bar_top() - top - 14.0)


func _sheet_height() -> float:
	return minf(_paper.get_combined_minimum_size().y, _max_sheet_height())


# ── printing ─────────────────────────────────────────────────────────────────

func _print_sheet() -> void:
	_printing = true
	_key.text = tr("Skip")
	_lcd.text = tr("RECEIVING…")
	for r in _rows:
		(r["row"] as Control).visible = false
		(r["icon"] as Control).modulate.a = 0.0
	_footer.visible = false
	await get_tree().process_frame
	Audio.play("fax")
	await _feed()

	for r in _rows:
		if not is_inside_tree():
			return
		var lbl := r["label"] as Label
		(r["row"] as Control).visible = true
		lbl.visible_ratio = 0.0
		await get_tree().process_frame
		await _feed()
		_active_tween = create_tween()
		_active_tween.tween_property(lbl, "visible_ratio", 1.0,
			clampf(lbl.text.length() / CHARS_PER_SEC, 0.25, 1.1))
		if _skipping:
			_active_tween.custom_step(10.0)
		else:
			await _active_tween.finished
		_stamp_row(r, not _skipping)
		if not _skipping:
			await get_tree().create_timer(0.18).timeout

	_footer.visible = true
	await get_tree().process_frame
	await _feed()
	_finish()


# Grows the visible sheet to fit what has been printed so far, keeping the
# newest line in view once the sheet is taller than the room above the bar.
func _feed() -> void:
	if not is_inside_tree():
		return
	var h := _sheet_height()
	_active_tween = create_tween().set_parallel()
	_active_tween.tween_property(_scroll, "custom_minimum_size:y", h, FEED_TIME) \
		.set_trans(Tween.TRANS_LINEAR)
	var bottom := maxf(0.0, _paper.get_combined_minimum_size().y - h)
	_active_tween.tween_property(_scroll, "scroll_vertical", int(bottom), FEED_TIME)
	if _skipping:
		_active_tween.custom_step(10.0)
		return
	await _active_tween.finished


func _stamp_row(r: Dictionary, animate: bool) -> void:
	var line := r["line"] as ApplicationLine
	var ring := r["icon"] as Control
	ring.modulate.a = 1.0
	if animate:
		ring.pivot_offset = ring.size * 0.5
		ring.scale = Vector2(1.8, 1.8)
		ring.rotation_degrees = 12.0
		var tw := ring.create_tween().set_parallel()
		tw.tween_property(ring, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(ring, "rotation_degrees", 0.0, 0.18)
	var anchor := _card.stamp(line.requirement, animate)
	if animate and anchor:
		_draw_link(ring, anchor)


func _finish() -> void:
	_printing = false
	_skipping = false
	_card.finish_stamping()
	_lcd.text = tr("READY")
	_key.text = tr("OK")


func _show_printed() -> void:
	_lcd.text = tr("READY")
	_key.text = tr("OK")
	await get_tree().process_frame
	_scroll.custom_minimum_size.y = _sheet_height()


# Esc: the same as the machine's key.
func skip_or_close() -> void:
	_on_key()


func _on_key() -> void:
	if _printing:
		if not _skipping:
			_skipping = true
			if _active_tween and _active_tween.is_valid():
				_active_tween.custom_step(10.0)
		return
	_close()


func _on_row_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT):
		return
	get_viewport().set_input_as_handled()
	if _printing:
		_on_key()
		return
	var r := _rows[index] as Dictionary
	var anchor := _card.flash_requirement((r["line"] as ApplicationLine).requirement)
	if anchor:
		_draw_link(r["icon"] as Control, anchor)


# Freed early (the level restarted while it printed): no chip may stay
# waiting for a stamp that will never come.
func _exit_tree() -> void:
	if _printing and is_instance_valid(_card):
		_card.finish_stamping()


func _close() -> void:
	closed.emit()
	queue_free()


# ── the ink line from a line's stamp to its chip ────────────────────────────

func _draw_link(from_ctrl: Control, to_ctrl: Control) -> void:
	var a := _center_of(from_ctrl)
	var b := _center_of(to_ctrl) - Vector2(0, to_ctrl.size.y * 0.5 - 2.0)
	var line := Line2D.new()
	line.width = 2.5
	line.default_color = FaxStyle.STAMP_INK
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	_links.add_child(line)
	# A loose curve, bowing sideways, like a hand-drawn arrow.
	var ctrl := (a + b) * 0.5 + Vector2((b.y - a.y) * 0.25 * (1.0 if b.x >= a.x else -1.0), 0)
	var pts: PackedVector2Array = []
	for i in 21:
		var t := i / 20.0
		pts.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
	var dot := _arrow_dot(b)
	line.add_child(dot)
	dot.visible = false
	var tw := line.create_tween()
	tw.tween_method(func(t: float):
		var n := maxi(2, int(t * pts.size()))
		line.points = pts.slice(0, n)
		dot.visible = t >= 1.0, 0.0, 1.0, 0.22)
	tw.tween_interval(0.7)
	tw.tween_property(line, "modulate:a", 0.0, 0.5)
	tw.tween_callback(line.queue_free)


func _arrow_dot(at: Vector2) -> Node2D:
	var dot := Polygon2D.new()
	var pts: PackedVector2Array = []
	for i in 12:
		pts.append(at + Vector2.from_angle(TAU * i / 12.0) * 4.0)
	dot.polygon = pts
	dot.color = FaxStyle.STAMP_INK
	return dot


func _center_of(c: Control) -> Vector2:
	return c.get_global_transform_with_canvas() * (c.size * 0.5)
