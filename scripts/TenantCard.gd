extends PanelContainer
class_name TenantCard

signal moment_selected(moment_id: String)
signal need_clicked(need: String)   # a need chip was clicked: show what provides it
signal height_changed               # the chips wrapped onto more or fewer rows
signal application_requested        # the fax button: show the tenant's rental application again
signal project_map_requested        # the apartments chip: show every apartment of the project

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: HBoxContainer = $VBox/Checklist

# flat-list mode
var _check_chips: Dictionary = {}   # func_name -> Control
var _rule_chips: Array = []         # one per GameManager.rule_status() entry
var _rule_row: Container = null     # where those chips live
var _tenant_name: String = ""       # for the "ALEX NEEDS" lead-in, see _add_goal_label()

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
var _showcased_chips: Array = []          # chips currently gold-ringed by highlight_showcase_need()

# Every chip by the requirement id(s) it shows (see Requirements): one chip
# can answer to several, e.g. "need:sleep" and "moment:night:sleep".
var _chips_by_req: Dictionary = {}        # id -> Array[Control]
var _hidden_reqs: Array = []              # ids whose chips stay out of the bar (hidden requirements)
var _has_application := false             # show the fax button in front of the bar
# While the application prints, chips wait invisible (keeping their place,
# so the line drawn to them lands right) until their line stamps them in.
var _stamping := false
var _project_chip: PanelContainer = null   # "Apartments 1/3": shown when the project has boxes with tenants


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
	"dine":    "🍽",
	"dress":   "👕",
	"laundry": "🧺",
	"social":  "🎉",
	"pet":     "🐦",
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
	paper.set_content_margin(SIDE_RIGHT, 310)   # Main adjusts this: see set_right_reserve()
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


# Room kept free at the bar's right-hand end for the comfort gauge, the
# budget and the Furniture button, which Main lays over it.
func set_right_reserve(px: float) -> void:
	var paper := get_theme_stylebox("panel") as StyleBoxFlat
	if paper != null and not is_equal_approx(paper.get_content_margin(SIDE_RIGHT), px):
		paper.set_content_margin(SIDE_RIGHT, px)
		update_minimum_size()


var _last_height := -1.0

func _update_card_height() -> void:
	var hbox := $VBox as HBoxContainer
	var h := hbox.get_combined_minimum_size().y + 12.0
	size.y = h
	if not is_equal_approx(h, _last_height):
		_last_height = h
		height_changed.emit()


# RENT OUT was a manual "I'm done, finish the level" button; Main.gd now
# fires the same completion flow itself the instant every requirement is
# met, so there's nothing left here to show/hide — kept as no-op stubs since
# Main.gd still calls them (harmless, avoids touching that call site too).
func set_rented(_rented: bool) -> void:
	pass


func set_rent_available(_available: bool) -> void:
	pass


func setup(tenant: Dictionary) -> void:
	_tenant_name = str(tenant.get("name", ""))
	tenant_name_label.text = "%s, %d" % [tenant["name"], int(str(tenant["age"]))]
	flavor_label.text = tenant["flavor"]
	rent_label.text = tr("%d€ / month") % tenant["monthly_rent"]
	_moments = []
	_stamping = false
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
	_rule_chips.clear()
	_rule_row = null
	_moment_check_chips.clear()
	_moment_header_btns.clear()
	_moment_rows.clear()
	_moment_group = ButtonGroup.new()
	_showcased_chips.clear()   # the chips themselves are about to be freed with the old rows
	_chips_by_req.clear()
	_project_chip = null   # freed with the rest of the bar


# The bar is the level's goal, so it says so: "ALEX NEEDS" in front of the
# chips, and each chip carries its need's name. Icons alone left a new
# player looking at two unlabelled squares with no idea they were the
# objective.
func _add_goal_label() -> void:
	if _has_application:
		_add_application_button()
	var lbl := Label.new()
	lbl.text = (tr("%s NEEDS") % _tenant_name.to_upper()) if _tenant_name != "" else tr("NEEDS")
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", INK_MUTED)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl.tooltip_text = tr("Furnish the apartment so every need here is ticked")
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	checklist_container.add_child(lbl)


func _build_checklist(required: Array) -> void:
	_clear_checklist()
	_add_goal_label()
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
		_register_chip("need:" + str(func_name), chip)
	_rule_row = row
	_apply_requirement_state()


func _build_moment_checklist() -> void:
	_clear_checklist()
	_moment_check_chips = {}
	_add_goal_label()

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
			chip.set_meta("moment", mid)
			row.add_child(chip)
			(_moment_check_chips[mid] as Dictionary)[func_name] = chip
			_register_chip("need:" + str(func_name), chip)
			_register_chip("moment:%s:%s" % [mid, func_name], chip)
	_apply_requirement_state()


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
func _make_need_chip(func_name: String, satisfied: bool, req_id: String = "") -> PanelContainer:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(0, 30)
	chip.tooltip_text = tr("%s — click to see the furniture that provides it") % Loc.need_name(func_name)
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	if func_name != "rule":
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				need_clicked.emit(func_name))

	# Icon, name, then the tick or cross: readable without hovering.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(row)

	row.add_child(Requirements.make_icon(req_id if req_id != "" else "need:" + func_name, 15))

	var name_lbl := Label.new()
	name_lbl.text = Loc.need_name(func_name)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.20, 0.17, 0.13))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_lbl)

	var badge := Label.new()
	badge.name = "Badge"
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 13)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge)

	_paint_need_chip(chip, satisfied)
	return chip


func _paint_need_chip(chip: PanelContainer, satisfied: bool, showcased: bool = false) -> void:
	chip.add_theme_stylebox_override("panel", _chip_style(satisfied, showcased))
	var badge := chip.find_child("Badge", true, false) as Label
	if satisfied:
		badge.text = "✓"
		badge.add_theme_color_override("font_color", Color(0.180, 0.420, 0.160))
	else:
		badge.text = "✗"
		badge.add_theme_color_override("font_color", Color(0.620, 0.220, 0.180))


# Objective tiles: a filled green tile when solved, a dim red-outline tile
# when pending — the puzzle "goal list" reads at a glance instead of as text.
# `showcased` (the 3D post-win showcase currently posing the tenant at this
# need's furniture) rings the tile in gold on top of whichever fill applies —
# an independent "look here" cue layered over, not instead of, done/pending.
static func _chip_style(satisfied: bool, showcased: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if satisfied:
		# Sage fill on cream paper — a highlighted, done line item
		s.bg_color     = Color(0.780, 0.880, 0.720)
		s.border_color = Color(0.420, 0.620, 0.380)
	else:
		# Blank cream tile with a terracotta pen outline — still to do
		s.bg_color     = Color(0.930, 0.895, 0.820)
		s.border_color = Color(0.800, 0.470, 0.390)
	if showcased:
		s.border_color = Color(1.0, 0.85, 0.30)
		s.set_border_width_all(3)
	else:
		s.set_border_width_all(1)
	s.set_corner_radius_all(7)
	s.set_content_margin(SIDE_LEFT, 8)
	s.set_content_margin(SIDE_RIGHT, 8)
	s.set_content_margin(SIDE_TOP, 2)
	s.set_content_margin(SIDE_BOTTOM, 2)
	s.anti_aliasing = true
	return s


func _set_need_chip(chip: PanelContainer, satisfied: bool) -> void:
	var was_satisfied := chip.get_meta("satisfied", false) as bool
	chip.set_meta("satisfied", satisfied)
	_paint_need_chip(chip, satisfied, chip.get_meta("showcased", false) as bool)
	if satisfied and not was_satisfied and Time.get_ticks_msec() - _setup_ticks > 800:
		_pop_chip(chip)


# Called by Main whenever the post-win 3D showcase moves the tenant to a new
# stop, so the checklist visibly points at whichever need it's currently
# demonstrating instead of just leaving the player to guess from the 3D
# camera alone. Switches to that stop's own moment tab too (matching
# highlight_moment) since the relevant chip might be on a row that isn't
# the one currently showing.
func highlight_showcase_need(moment_id: String, needs: Array) -> void:
	for chip in _showcased_chips:
		if is_instance_valid(chip):
			chip.set_meta("showcased", false)
			_paint_need_chip(chip, chip.get_meta("satisfied", false) as bool, false)
	_showcased_chips.clear()
	if not _moment_check_chips.has(moment_id):
		return
	highlight_moment(moment_id)
	var chips := _moment_check_chips[moment_id] as Dictionary
	for need in needs:
		if not chips.has(need):
			continue
		var chip := chips[need] as PanelContainer
		chip.set_meta("showcased", true)
		_paint_need_chip(chip, chip.get_meta("satisfied", false) as bool, true)
		_showcased_chips.append(chip)


# Called when the showcase stops (post-win view exited) so no chip is left
# permanently ringed in gold once there's nothing left demonstrating it.
func clear_showcase_highlight() -> void:
	highlight_showcase_need("", [])


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


# Chips for the rules that are not furniture needs: lines of sight ("1 Sofa
# sees the door") and zone separations. Built the first time they arrive and
# after every rebuild of the bar; then only repainted.
func update_rules(rules: Array) -> void:
	if rules.is_empty() and _rule_chips.is_empty():
		return
	if _rule_chips.size() != rules.size():
		for c in _rule_chips:
			if is_instance_valid(c):
				c.queue_free()
		_rule_chips.clear()
		if _rule_row == null or not is_instance_valid(_rule_row):
			# A level with moments keeps its needs behind tabs; the rules
			# hold all day, so they get their own row beside the tabs.
			_rule_row = HBoxContainer.new()
			_rule_row.add_theme_constant_override("separation", 7)
			checklist_container.add_child(_rule_row)
		var zone_number := 0
		for r in rules:
			var rule := r as Dictionary
			var is_sight := (rule["kind"] as String) == "sight"
			var is_items := (rule["kind"] as String) == "items"
			if not is_sight and not is_items:
				zone_number += 1
			var req_id := ("sight:%d" % rule["number"]) if is_sight else (("items:%d" % rule["number"]) if is_items else ("zones:%d" % zone_number))
			var chip := _make_need_chip("rule", false, req_id)
			var text := rule.get("short", "") as String
			if text == "":
				text = rule["label"] as String
			if is_sight:
				text = "%d  %s" % [rule["number"], text]
			(chip.get_child(0).get_child(1) as Label).text = text
			chip.tooltip_text = (rule["label"] as String) + (
				"\n" + tr("The numbered line on the plan shows it.") if is_sight
				else ("\n" + tr("Put them all down in the flat.") if is_items
				else "\n" + tr("Tall storage splits a room into zones.")))
			_rule_row.add_child(chip)
			_rule_chips.append(chip)
			_register_chip(req_id, chip)
		_apply_requirement_state()
	for i in rules.size():
		var rule_i := rules[i] as Dictionary
		_set_need_chip(_rule_chips[i] as PanelContainer, rule_i["ok"] as bool)
		if (rule_i["kind"] as String) == "items":
			# The count changes as pieces go down: "3 freezers 1/3".
			(_rule_chips[i].get_child(0).get_child(1) as Label).text = rule_i["short"] as String


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


# ── Requirement ids, hidden requirements, the application ───────────────────

func _register_chip(req_id: String, chip: Control) -> void:
	if not _chips_by_req.has(req_id):
		_chips_by_req[req_id] = []
	(_chips_by_req[req_id] as Array).append(chip)
	if _stamping:
		chip.set_meta("unstamped", true)


# Called by Main after setup()/setup_moments(): whether the level has an
# application (puts the fax button in front of the bar) and which
# requirements it keeps hidden.
func set_application(available: bool, hidden_requirements: Array) -> void:
	_has_application = available
	_hidden_reqs = hidden_requirements.duplicate()
	var existing := checklist_container.get_node_or_null("ApplicationButton")
	if available and existing == null and checklist_container.get_child_count() > 0:
		_add_application_button()
		checklist_container.move_child(checklist_container.get_node("ApplicationButton"), 0)
	elif not available and existing != null:
		existing.queue_free()
	_apply_requirement_state()


func _add_application_button() -> void:
	var btn := Button.new()
	btn.name = "ApplicationButton"
	btn.text = "📠"
	btn.tooltip_text = tr("Read the tenant's rental application again")
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.custom_minimum_size = Vector2(34, 30)
	btn.add_theme_font_size_override("font_size", 15)
	btn.pressed.connect(func(): application_requested.emit())
	checklist_container.add_child(btn)


func _apply_requirement_state() -> void:
	var hidden_chips: Array = []
	for req_id in _hidden_reqs:
		hidden_chips.append_array(_chips_by_req.get(req_id, []) as Array)
	for list in _chips_by_req.values():
		for chip in list:
			var c := chip as Control
			if not is_instance_valid(c):
				continue
			c.visible = c not in hidden_chips
			c.modulate.a = 0.0 if c.get_meta("unstamped", false) else 1.0


func is_hidden_requirement(req_id: String) -> bool:
	return req_id in _hidden_reqs


# Every chip goes invisible until stamp() brings it in.
func begin_stamping() -> void:
	_stamping = true
	for list in _chips_by_req.values():
		for chip in list:
			(chip as Control).set_meta("unstamped", true)
	_apply_requirement_state()


# Stamps in the chips of `req_id`; returns the control on screen the
# application's line should point at (the chip, or its moment's tab when that
# moment's row isn't the one showing), or null.
func stamp(req_id: String, animate: bool = true) -> Control:
	for chip in _chips_by_req.get(req_id, []) as Array:
		var c := chip as Control
		if c.get_meta("unstamped", false):
			c.set_meta("unstamped", false)
			c.modulate.a = 1.0
			if animate:
				_stamp_chip(c)
	return requirement_anchor(req_id)


# Stamps whatever is left (requirements no line mentions) and stops holding
# back new chips.
func finish_stamping() -> void:
	_stamping = false
	for list in _chips_by_req.values():
		for chip in list:
			(chip as Control).set_meta("unstamped", false)
	_apply_requirement_state()


func requirement_anchor(req_id: String) -> Control:
	var chips := _chips_by_req.get(req_id, []) as Array
	for chip in chips:
		if (chip as Control).is_visible_in_tree():
			return chip
	for chip in chips:
		var mid := (chip as Control).get_meta("moment", "") as String
		if _moment_header_btns.has(mid) and not is_hidden_requirement(req_id):
			return _moment_header_btns[mid]
	return null


# A chip pointed at from the application: a quick pop, no sound.
func flash_requirement(req_id: String) -> Control:
	for chip in _chips_by_req.get(req_id, []) as Array:
		if (chip as Control).is_visible_in_tree() and not GameState.reduce_motion:
			var c := chip as Control
			c.pivot_offset = c.size * 0.5
			var tw := c.create_tween()
			tw.tween_property(c, "scale", Vector2(1.18, 1.18), 0.08)
			tw.tween_property(c, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return requirement_anchor(req_id)


# A rubber stamp coming down: big and tilted, then flat on the paper.
func _stamp_chip(chip: Control) -> void:
	Audio.play("place")
	if GameState.reduce_motion:
		return
	chip.pivot_offset = chip.size * 0.5
	chip.scale = Vector2(1.7, 1.7)
	chip.rotation_degrees = -9.0
	chip.modulate.a = 0.0
	var tw := chip.create_tween().set_parallel()
	tw.tween_property(chip, "modulate:a", 1.0, 0.07)
	tw.tween_property(chip, "scale", Vector2.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(chip, "rotation_degrees", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# How many of the project's apartments are ready: the one from the map and
# the boxes with tenants inside it. The project is rented out only when all
# are; until then this chip says so and names the ones left (tooltip).
func set_project_status(done: int, total: int, pending: Array) -> void:
	if total <= 1:
		if is_instance_valid(_project_chip):
			_project_chip.queue_free()
		_project_chip = null
		return
	if not is_instance_valid(_project_chip):
		_project_chip = _make_need_chip("rule", false, "apartments")
		_project_chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_project_chip.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				project_map_requested.emit())
		checklist_container.add_child(_project_chip)
	(_project_chip.get_child(0).get_child(1) as Label).text = tr("Apartments %d/%d") % [done, total]
	_project_chip.tooltip_text = (tr("Still to furnish: %s") % Loc.join_list(pending)) if not pending.is_empty() \
		else tr("Every apartment is ready")
	_set_need_chip(_project_chip, done == total)

