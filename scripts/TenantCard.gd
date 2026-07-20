extends PanelContainer
class_name TenantCard

signal moment_selected(moment_id: String)

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: HBoxContainer = $VBox/Checklist

# flat-list mode
var _check_chips: Dictionary = {}   # func_name -> Control

# Suppresses the ✓-pop animation for the burst of updates right after a level
# loads — only flips caused by the player's own actions should celebrate.
var _setup_ticks: int = 0

# moment mode — chrome-tab style: every moment's tab is always visible in a
# connected strip, but only the ACTIVE moment's need chips actually take up
# space in the bar (the rest stay built but hidden), so a level with several
# moments each needing several functions can't overflow/wrap the bar just
# because every moment tried to show its chips side by side at once.
var _moments: Array = []
var _moment_check_chips: Dictionary = {}  # moment_id -> { need -> Control }
var _moment_rows: Dictionary = {}         # moment_id -> HFlowContainer (its chip row)
# Each moment's tab doubles as its nav button — clicking "DAY" or "NIGHT"
# both switches which chip row is visible and switches the active moment, so
# the TopBar doesn't need its own separate Day/Night strip.
var _moment_header_btns: Dictionary = {}  # moment_id -> Button
var _moment_group := ButtonGroup.new()


# Blueprint drafting-table palette — matches GridDraw.gd's corner title block
# (tenant/area/scale/sheet#), which used to draw directly on the 2D floor
# plan; that block is gone now (it collided with the floor-tab stack on
# multi-floor levels) and this bar adopts its look instead, so the same
# "architect's title block" reads as one continuous piece of UI instead of
# the plan losing it and the HUD gaining an unrelated dark bar.
const BP_BG     := Color(0.070, 0.150, 0.260, 0.94)   # title-block navy
const BP_LINE   := Color(0.62, 0.82, 0.98, 0.85)      # light blueprint-ink border
const BP_ACCENT := Color(0.10, 0.24, 0.40, 0.90)      # title bar's darker accent strip
const INK       := Color(0.91, 0.945, 0.965, 1.0)     # aged white drafting ink
const INK_MUTED := Color(0.60, 0.76, 0.94, 0.80)
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
	# A full-width bottom HUD strip, styled as the blueprint's own title block
	# rather than the old warm quest-tracker glass — same navy fill and light
	# blueprint-ink border GridDraw.gd used to draw in the plan's corner.
	var paper := StyleBoxFlat.new()
	paper.bg_color = BP_BG
	paper.border_color = BP_LINE
	paper.set_border_width(SIDE_TOP, 1)
	paper.set_content_margin(SIDE_LEFT, 12)
	paper.set_content_margin(SIDE_RIGHT, 12)
	paper.set_content_margin(SIDE_TOP, 8)
	paper.set_content_margin(SIDE_BOTTOM, 8)
	paper.anti_aliasing = true
	paper.shadow_color = Color(0, 0, 0, 0.3)
	paper.shadow_size = 6
	paper.shadow_offset = Vector2(0, -2)
	add_theme_stylebox_override("panel", paper)

	# Now a bottom status bar, not a quest-tracker sidebar column — the name/
	# age, flavor blurb, and rent line were the "who is this tenant" framing
	# that a tall column had room for; a bar only has room for (and only
	# needs) the moments/needs themselves, so all three stay permanently
	# hidden rather than toggled by the old expand header.
	tenant_name_label.visible = false
	flavor_label.visible = false
	rent_label.visible = false

	checklist_container.add_theme_constant_override("separation", 14)
	# Needs its own available width actually handed down from the bar's full
	# span, or the nested HFlowContainer rows below only ever see their own
	# cramped natural minimum width and wrap into extra rows they have no
	# height budget for (clipping off the bottom of the screen) even though
	# the bar itself has plenty of room.
	checklist_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# The bar only occupies as much width/height as its actual content (the
	# needs checklist — there's no RENT OUT button anymore, Main.gd finishes
	# the level on its own the instant every need is met) — HBox's minimum
	# size already reflects whichever children are visible right now.
	var hbox := $VBox as HBoxContainer
	hbox.minimum_size_changed.connect(_update_card_height)
	_update_card_height()


func _update_card_height() -> void:
	var hbox := $VBox as HBoxContainer
	size.y = hbox.get_combined_minimum_size().y + 12.0


# RENT OUT was a manual "I'm done, finish the level" button; Main.gd now
# fires the same completion flow itself the instant every requirement is
# met, so there's nothing left here to show/hide — kept as no-op stubs since
# Main.gd still calls them (harmless, avoids touching that call site too).
func set_rented(_rented: bool) -> void:
	pass


func set_rent_available(_available: bool) -> void:
	pass


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
	_moment_rows.clear()
	_moment_group = ButtonGroup.new()


func _build_checklist(required: Array) -> void:
	_clear_checklist()
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 7)
	row.add_theme_constant_override("v_separation", 7)
	# Without this the row only ever measures its own cramped natural width
	# inside checklist_container (an HBoxContainer, which doesn't stretch a
	# plain child to fill available space) and wraps into extra rows well
	# before it actually runs out of real screen space.
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checklist_container.add_child(row)
	for func_name in required:
		var chip := _make_need_chip(func_name, false)
		row.add_child(chip)
		_check_chips[func_name] = chip


func _build_moment_checklist() -> void:
	_clear_checklist()
	_moment_check_chips = {}

	# Chrome-tab strip: every moment's tab sits in one connected row up front,
	# always visible regardless of which one is active.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	checklist_container.add_child(tabs)

	# Then a single shared content area — only the active moment's chip row is
	# actually visible/sized inside it at any one time (see highlight_moment).
	var content := HBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checklist_container.add_child(content)

	for i in _moments.size():
		var m     := _moments[i] as Dictionary
		var mid   := m["id"]    as String
		var label := m["label"] as String
		var needs := m["needs"] as Array

		var hdr := _make_moment_header_btn(label.to_upper(), mid, i, _moments.size())
		tabs.add_child(hdr)
		_moment_header_btns[mid] = hdr

		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 7)
		row.add_theme_constant_override("v_separation", 7)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.visible = (i == 0)   # first moment starts active; Main.gd corrects this via highlight_moment() right after load
		content.add_child(row)
		_moment_rows[mid] = row

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


# Chrome-tab styling: one connected strip (zero separation between buttons,
# only the outer ends rounded — see _tab_style()) instead of separate pill
# chips, and the ACTIVE tab's fill matches the bar's own background so it
# visually fuses with the chip row beneath it, the way a browser's selected
# tab merges into the page below while the others stay a shade darker.
func _make_moment_header_btn(text: String, mid: String, index: int, count: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode  = true
	btn.button_group = _moment_group
	btn.focus_mode   = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.add_theme_font_size_override("font_size", 9)
	var n := _tab_style(Color(0.045, 0.095, 0.165, 0.85), BP_LINE, index, count)
	var h := _tab_style(Color(0.09, 0.19, 0.32, 0.9),     BP_LINE, index, count)
	var p := _tab_style(BP_BG,                            Color(1.0, 0.95, 0.70), index, count)
	btn.add_theme_stylebox_override("normal",   n)
	btn.add_theme_stylebox_override("hover",    h)
	btn.add_theme_stylebox_override("pressed",  p)
	btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color",         INK_MUTED)
	btn.add_theme_color_override("font_hover_color",   INK)
	btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
	btn.pressed.connect(func(): moment_selected.emit(mid))
	return btn


static func _tab_style(bg: Color, border: Color, index: int, count: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.anti_aliasing = true
	s.set_content_margin(SIDE_LEFT, 10)
	s.set_content_margin(SIDE_RIGHT, 10)
	s.set_content_margin(SIDE_TOP, 4)
	s.set_content_margin(SIDE_BOTTOM, 4)
	var r_left  := 6 if index == 0 else 0
	var r_right := 6 if index == count - 1 else 0
	s.corner_radius_top_left     = r_left
	s.corner_radius_bottom_left  = r_left
	s.corner_radius_top_right    = r_right
	s.corner_radius_bottom_right = r_right
	return s


# Called by Main after it switches moments (including the initial one on
# level load) so the header that matches the active moment stays highlighted
# even when the switch was triggered some other way. Also swaps which
# moment's chip row is actually visible — the chrome-tab illusion of
# "switching pages" rather than just re-coloring a button.
func highlight_moment(moment_id: String) -> void:
	if _moment_header_btns.has(moment_id):
		(_moment_header_btns[moment_id] as Button).button_pressed = true
	for mid in _moment_rows:
		(_moment_rows[mid] as Control).visible = (mid == moment_id)


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
