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

# moment mode
var _moments: Array = []
var _moment_check_chips: Dictionary = {}  # moment_id -> { need -> Control }
# Each moment's section header doubles as its nav button — clicking "DAY" or
# "NIGHT" both labels that need-group and switches the active moment, so the
# TopBar doesn't need its own separate Day/Night strip.
var _moment_header_btns: Dictionary = {}  # moment_id -> Button
var _moment_group := ButtonGroup.new()


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
	# A full-width bottom HUD strip now, not a floating quest-tracker card —
	# a border/rounded-corner treatment on all four sides read as a card
	# hovering over the scene; a bar reads as part of the screen's edge, so
	# only the top edge gets a border/shadow (matching how TopBarBg used to
	# frame the old top strip) and corners go square.
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.05, 0.05, 0.05, 0.55)
	paper.border_color = Color(1, 1, 1, 0.14)
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
	for i in _moments.size():
		var m     := _moments[i] as Dictionary
		var mid   := m["id"]    as String
		var label := m["label"] as String
		var needs := m["needs"] as Array

		# Extra breathing room before every section after the first — otherwise
		# a group sits exactly as close to its OWN row as it does to the
		# previous section's row, and the two moments read as one blob instead
		# of two distinct groups. Vertical separator now that groups sit
		# side-by-side in the bottom bar rather than stacked.
		if i > 0:
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(18, 0)
			checklist_container.add_child(gap)

		# Header + its chip row now form one horizontal group (was stacked
		# vertically) so multiple moments read left-to-right along the bar.
		var group := HBoxContainer.new()
		group.add_theme_constant_override("separation", 8)
		group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		checklist_container.add_child(group)

		var hdr := _make_moment_header_btn(label.to_upper(), mid)
		group.add_child(hdr)
		_moment_header_btns[mid] = hdr

		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 7)
		row.add_theme_constant_override("v_separation", 7)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		group.add_child(row)

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


# Styled as a small pill/tab, same visual language as the segmented Floor
# Plan/3D and floor-tab switchers elsewhere in the TopBar — a bare label with
# just a color change on click doesn't read as a button at all, so this needs
# a real chip background (border + fill) to signal "click me" at rest, not
# only once the player happens to hover it.
func _make_moment_header_btn(text: String, mid: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.toggle_mode  = true
	btn.button_group = _moment_group
	btn.focus_mode   = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.add_theme_font_size_override("font_size", 9)
	var n := GameTheme.make_card_stylebox(Color(0.16, 0.14, 0.11, 0.7), Color(0.45, 0.40, 0.32), 8)
	var h := GameTheme.make_card_stylebox(Color(0.22, 0.19, 0.14, 0.85), Color(0.70, 0.58, 0.32), 8)
	var p := GameTheme.make_card_stylebox(Color(0.42, 0.34, 0.14), GameTheme.C_AMBER, 8)
	n.set_content_margin(SIDE_TOP, 3); n.set_content_margin(SIDE_BOTTOM, 3)
	h.set_content_margin(SIDE_TOP, 3); h.set_content_margin(SIDE_BOTTOM, 3)
	p.set_content_margin(SIDE_TOP, 3); p.set_content_margin(SIDE_BOTTOM, 3)
	btn.add_theme_stylebox_override("normal",   n)
	btn.add_theme_stylebox_override("hover",    h)
	btn.add_theme_stylebox_override("pressed",  p)
	btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color",         INK_MUTED)
	btn.add_theme_color_override("font_hover_color",   INK)
	btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
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
