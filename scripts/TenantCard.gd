extends PanelContainer
class_name TenantCard

signal rent_out_requested()
signal moment_selected(moment_id: String)

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: VBoxContainer = $VBox/Checklist

var _rent_btn: Button = null
var _rent_available: bool = false

# flat-list mode
var _check_chips: Dictionary = {}   # func_name -> Control

# Suppresses the ✓-pop animation for the burst of updates right after a level
# loads — only flips caused by the player's own actions should celebrate.
var _setup_ticks: int = 0

# moment mode
var _moments: Array = []
var _moment_check_chips: Dictionary = {}  # moment_id -> { need -> Control }
# Each moment's section header doubles as its nav button — clicking "DAY" or
# "NIGHT" both labels that need-group and switches the active moment, so the
# TopBar doesn't need its own separate Day/Night strip.
var _moment_header_btns: Dictionary = {}  # moment_id -> Button
var _moment_group := ButtonGroup.new()

# Collapsed by default: the sidebar is now a narrow compact column, and the
# flavor paragraph is the one thing that isn't needed at a glance — click the
# name row to reveal it.
var _expanded: bool = false
var _expand_arrow: Label = null


# WoW-quest-tracker style: a floating overlay on the game view, not a solid
# card — dark translucent glass with light ink so it reads over any scene.
const INK       := Color(0.94, 0.91, 0.83)   # warm cream text on dark glass
const INK_MUTED := Color(0.74, 0.70, 0.62)
const INK_GREEN := Color(0.56, 0.85, 0.50)

# Small glyph per need — WoW-quest-style: a glance at the panel should read
# as a row of icons with check/cross overlays, not a paragraph of chips.
const NEED_GLYPH := {
	"sleep":   "🛏",
	"hygiene": "🚿",
	"cook":    "🍳",
	"work":    "💻",
	"sit":     "🛋",
	"storage": "📦",
	"eat":     "🍽",
	"social":  "🎉",
}


func _ready() -> void:
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.05, 0.05, 0.05, 0.38)
	paper.border_color = Color(1, 1, 1, 0.14)
	paper.set_border_width_all(1)
	paper.set_corner_radius_all(6)
	paper.set_content_margin_all(12)
	paper.anti_aliasing = true
	paper.shadow_color = Color(0, 0, 0, 0.25)
	paper.shadow_size = 6
	paper.shadow_offset = Vector2(0, 3)
	add_theme_stylebox_override("panel", paper)

	tenant_name_label.add_theme_font_size_override("font_size", 14)
	tenant_name_label.add_theme_color_override("font_color", INK)

	# The client's own words in handwriting — a note scribbled on the brief
	var hand := GameTheme.handwriting()
	if hand:
		flavor_label.add_theme_font_override("font", hand)
		flavor_label.add_theme_font_size_override("font_size", 15)
	else:
		flavor_label.add_theme_font_size_override("font_size", 10)
	flavor_label.add_theme_color_override("font_color", INK_MUTED)
	flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	rent_label.add_theme_font_size_override("font_size", 12)
	rent_label.add_theme_color_override("font_color", INK_GREEN)

	checklist_container.add_theme_constant_override("separation", 6)

	_build_expand_header()
	flavor_label.visible = _expanded
	_build_rent_btn()

	# The card only occupies as much height as its actual content (needs
	# checklist, rent line, RENT OUT button when it appears) instead of
	# stretching all the way to the bottom of the screen — VBox's minimum
	# size already reflects whichever children are visible right now.
	var vbox := $VBox as VBoxContainer
	vbox.minimum_size_changed.connect(_update_card_height)
	_update_card_height()


func _update_card_height() -> void:
	var vbox := $VBox as VBoxContainer
	size.y = vbox.get_combined_minimum_size().y + 12.0


# Hidden until every need is fulfilled, then appears right where the eye
# already is (in the quest tracker) instead of a separate top-bar button the
# player has to notice on their own.
func _build_rent_btn() -> void:
	_rent_btn = Button.new()
	_rent_btn.text = "RENT OUT"
	_rent_btn.add_theme_font_size_override("font_size", 13)
	_rent_btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	_rent_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.72))
	var rs := GameTheme.make_rent_btn_style()
	_rent_btn.add_theme_stylebox_override("normal",  rs[0])
	_rent_btn.add_theme_stylebox_override("hover",   rs[1])
	_rent_btn.add_theme_stylebox_override("pressed", rs[1])
	_rent_btn.visible = false
	_rent_btn.pressed.connect(func(): rent_out_requested.emit())
	var vbox := $VBox as VBoxContainer
	vbox.add_child(_rent_btn)


# Called by Main.gd whenever the win condition is (re-)evaluated — pulses
# once the moment every requirement flips green, same celebratory cue the old
# top-bar button used to give.
func set_rent_available(available: bool) -> void:
	var was_available := _rent_available
	_rent_available = available
	_rent_btn.visible = available
	if available and not was_available:
		Audio.play("success")
		if GameState.reduce_motion:
			return
		_rent_btn.pivot_offset = _rent_btn.size * 0.5
		_rent_btn.scale = Vector2.ONE
		var tw := create_tween()
		for i in 3:
			tw.tween_property(_rent_btn, "scale", Vector2(1.08, 1.08), 0.12) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(_rent_btn, "scale", Vector2.ONE, 0.12) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


# Wraps the name label in a header row with a ▸/▾ toggle button — clicking it
# (or the name itself) reveals the flavor paragraph, which stays hidden by
# default so the compact sidebar only shows it on request.
func _build_expand_header() -> void:
	var parent := tenant_name_label.get_parent() as VBoxContainer
	var idx := tenant_name_label.get_index()
	parent.remove_child(tenant_name_label)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.gui_input.connect(_on_header_gui_input)
	parent.add_child(header)
	parent.move_child(header, idx)

	tenant_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tenant_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(tenant_name_label)

	# A plain arrow glyph, not a Button — the whole header row is already the
	# click target (see _on_header_gui_input), so there's no separate button
	# chrome pretending to be a distinct control.
	_expand_arrow = Label.new()
	_expand_arrow.text = "▸"
	_expand_arrow.add_theme_font_size_override("font_size", 11)
	_expand_arrow.add_theme_color_override("font_color", INK_MUTED)
	_expand_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(_expand_arrow)


func _on_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
	and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_toggle_expanded()


func _toggle_expanded() -> void:
	_expanded = not _expanded
	flavor_label.visible = _expanded
	if is_instance_valid(_expand_arrow):
		_expand_arrow.text = "▾" if _expanded else "▸"


func setup(tenant: Dictionary) -> void:
	tenant_name_label.text = "%s, %d" % [tenant["name"], int(str(tenant["age"]))]
	flavor_label.text = tenant["flavor"]
	rent_label.text = "%d€ / month" % tenant["monthly_rent"]
	_moments = []
	_setup_ticks = Time.get_ticks_msec()
	_build_checklist(tenant["required_functions"])


func setup_moments(moments: Array) -> void:
	_moments = moments
	if moments.is_empty():
		return
	_build_moment_checklist()


func _clear_checklist() -> void:
	for child in checklist_container.get_children():
		checklist_container.remove_child(child)
		child.queue_free()
	_check_chips.clear()
	_moment_check_chips.clear()
	_moment_header_btns.clear()
	_moment_group = ButtonGroup.new()


func _build_checklist(required: Array) -> void:
	_clear_checklist()
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 4)
	row.add_theme_constant_override("v_separation", 4)
	checklist_container.add_child(row)
	for func_name in required:
		var chip := _make_need_chip(func_name, false)
		row.add_child(chip)
		_check_chips[func_name] = chip


func _build_moment_checklist() -> void:
	_clear_checklist()
	_moment_check_chips = {}
	for m in _moments:
		var mid   := m["id"]    as String
		var label := m["label"] as String
		var needs := m["needs"] as Array

		var hdr := _make_moment_header_btn(label.to_upper(), mid)
		checklist_container.add_child(hdr)
		_moment_header_btns[mid] = hdr

		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 4)
		row.add_theme_constant_override("v_separation", 4)
		checklist_container.add_child(row)

		_moment_check_chips[mid] = {}
		for func_name in needs:
			var chip := _make_need_chip(func_name, false)
			row.add_child(chip)
			(_moment_check_chips[mid] as Dictionary)[func_name] = chip


func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", INK_MUTED)
	return lbl


# A flat, borderless toggle styled to still read as a plain section label at
# rest — only the active moment picks up the amber accent (same as every
# other active-mode indicator in the game), so this doubles as both the
# "DAY"/"NIGHT" heading and the moment switcher without adding a separate
# control.
func _make_moment_header_btn(text: String, mid: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode  = true
	btn.button_group = _moment_group
	btn.focus_mode   = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.add_theme_font_size_override("font_size", 9)
	btn.add_theme_stylebox_override("normal",   StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("hover",    StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("pressed",  StyleBoxEmpty.new())
	btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color",         INK_MUTED)
	btn.add_theme_color_override("font_hover_color",   INK)
	btn.add_theme_color_override("font_pressed_color", GameTheme.C_AMBER)
	btn.pressed.connect(func(): moment_selected.emit(mid))
	return btn


# Called by Main after it switches moments (including the initial one on
# level load) so the header that matches the active moment stays highlighted
# even when the switch was triggered some other way.
func highlight_moment(moment_id: String) -> void:
	if _moment_header_btns.has(moment_id):
		(_moment_header_btns[moment_id] as Button).button_pressed = true


# A small square glyph tile with a check/cross badge in the corner — reads at
# a glance as a WoW-style quest tracker instead of a text checklist. Native
# tooltip_text carries the need's name on hover since there's little more to
# say about a need than "done or not."
func _make_need_chip(func_name: String, satisfied: bool) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(30, 30)
	chip.tooltip_text = func_name.capitalize()
	chip.mouse_filter = Control.MOUSE_FILTER_STOP

	var glyph := Label.new()
	glyph.text = NEED_GLYPH.get(func_name, "❔") as String
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 15)
	chip.add_child(glyph)

	var badge := Label.new()
	badge.name = "Badge"
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	badge.add_theme_font_size_override("font_size", 11)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(badge)

	_paint_need_chip(chip, satisfied)
	return chip


func _paint_need_chip(chip: PanelContainer, satisfied: bool) -> void:
	chip.add_theme_stylebox_override("panel", _chip_style(satisfied))
	var badge := chip.get_node("Badge") as Label
	if satisfied:
		badge.text = "✓"
		badge.add_theme_color_override("font_color", Color(0.180, 0.420, 0.160))
	else:
		badge.text = "✗"
		badge.add_theme_color_override("font_color", Color(0.620, 0.220, 0.180))


# Objective tiles: a filled green tile when solved, a dim red-outline tile
# when pending — the puzzle "goal list" reads at a glance instead of as text.
static func _chip_style(satisfied: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if satisfied:
		# Sage fill on cream paper — a highlighted, done line item
		s.bg_color     = Color(0.780, 0.880, 0.720)
		s.border_color = Color(0.420, 0.620, 0.380)
	else:
		# Blank cream tile with a terracotta pen outline — still to do
		s.bg_color     = Color(0.930, 0.895, 0.820)
		s.border_color = Color(0.800, 0.470, 0.390)
	s.set_border_width_all(1)
	s.set_corner_radius_all(7)
	s.anti_aliasing = true
	return s


func _set_need_chip(chip: PanelContainer, satisfied: bool) -> void:
	var was_satisfied := chip.get_meta("satisfied", false) as bool
	chip.set_meta("satisfied", satisfied)
	_paint_need_chip(chip, satisfied)
	if satisfied and not was_satisfied and Time.get_ticks_msec() - _setup_ticks > 800:
		_pop_chip(chip)


# Little scale-pop when an objective flips to solved — the classic bit of
# puzzle-game feedback that makes ticking a goal feel earned.
func _pop_chip(chip: Control) -> void:
	Audio.play("place")
	if GameState.reduce_motion:
		return
	chip.pivot_offset = chip.size * 0.5
	chip.scale = Vector2.ONE
	var tw := chip.create_tween()
	tw.tween_property(chip, "scale", Vector2(1.22, 1.22), 0.09) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(chip, "scale", Vector2.ONE, 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func update_checks(fulfilled: Array, required: Array) -> void:
	if not _moments.is_empty():
		return  # moment levels drive via update_moments
	for func_name in required:
		if not (func_name in _check_chips):
			continue
		_set_need_chip(_check_chips[func_name] as PanelContainer, func_name in fulfilled)


func update_moments(results: Dictionary) -> void:
	if _moments.is_empty():
		return
	for m in _moments:
		var mid    := m["id"]    as String
		var needs  := m["needs"] as Array
		if not _moment_check_chips.has(mid):
			continue
		var chips  := _moment_check_chips[mid] as Dictionary
		var mdata  := results.get(mid, {}) as Dictionary
		var mfulfilled := mdata.get("fulfilled", []) as Array
		for func_name in needs:
			if chips.has(func_name):
				_set_need_chip(chips[func_name] as PanelContainer, func_name in mfulfilled)
