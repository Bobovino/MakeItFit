extends PanelContainer
class_name TenantCard

signal moment_selected(moment_id: String)
signal need_clicked(need: String)   # a need chip was clicked: show what provides it
signal items_clicked(number: int)    # a counted need ("3 freezers") was clicked: show the pieces that count
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
# The moments themselves: a tab per moment (MomentClock), the one on screen
# named on its tab. Choosing a tab switches the moment.
var _moment_clock: MomentClock = null
var _moment_icon: Label = null
var _moment_name: Label = null
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
# The household, a column of portrait tiles Main keeps at the screen's left
# (household_box, set_household), as in The Sims 3: each says how many of
# their needs are still to do, and choosing one (its tile grows, framed in
# white) leaves the chips here that aren't theirs out of the bar.
var household_box: Container = null
var _household: Array = []          # [{id, name, color, body, feminine}]
var _owners_of := Callable()        # req id -> Array of resident ids; [] = everyone's
var _focus := ""                    # the resident whose needs are shown; "" = everyone
var _badges: Dictionary = {}        # resident id -> Label
var _badges_queued := false
const FACE_SIZE := 46.0          # a tile in the household column
const FACE_SIZE_CHOSEN := 58.0   # the one whose needs are shown
const TILE_RADIUS := 8


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
	"sleep":   "\ueb5c",
	"hygiene": "\uef48",
	"cook":    "\ueeff",
	"work":    "\ueb64",
	"sit":     "\uefaf",
	"storage": "\uea45",
	"eat":     "\ued64",
	"dine":    "\ued64",
	"dress":   "\uec0a",
	"laundry": "\uebe1",
	"social":  "\uee46",
	"pet":     "\ueff9",
	"sport":   "\ueff0",
}


func _ready() -> void:
	# No strip of its own: what is on it (sticky notes, the fax) lies on the
	# drawing board itself, like things on an architect's desk.
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0, 0, 0, 0)
	paper.set_content_margin(SIDE_LEFT, 12)
	paper.set_content_margin(SIDE_RIGHT, 310)   # Main adjusts this: see set_right_reserve()
	paper.set_content_margin(SIDE_TOP, 8)
	paper.set_content_margin(SIDE_BOTTOM, 8)
	paper.anti_aliasing = true
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
	_queue_fit()
	if not get_viewport().size_changed.is_connected(_queue_fit):
		get_viewport().size_changed.connect(_queue_fit)


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
	_moment_clock = null   # freed with the rest of the bar
	_moment_name = null
	_moment_icon = null
	_moment_rows.clear()
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
	lbl.name = "GoalLabel"
	# The fax button stands for the tenant's application: with it, whose
	# needs these are goes in its tooltip instead of taking up the bar.
	lbl.visible = not _has_application
	lbl.text = (tr("%s NEEDS") % _tenant_name.to_upper()) if _tenant_name != "" else tr("NEEDS")
	lbl.add_theme_font_override("font", GameTheme.font("mono_bold"))
	lbl.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	lbl.add_theme_color_override("font_color", GameTheme.CHALK_SOFT)
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

	# The moments as tabs (MomentClock), the one on screen named on its tab.
	_moment_clock = MomentClock.new()
	_moment_clock.name = "MomentClock"
	_moment_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_moment_clock.setup(_moments)
	_moment_clock.moment_chosen.connect(func(mid: String): moment_selected.emit(mid))
	checklist_container.add_child(_moment_clock)
	# With too many moments for icons on the small dial, the active one's
	# icon sits here instead.
	_moment_icon = Label.new()
	_moment_icon.name = "MomentIcon"
	_moment_icon.add_theme_font_override("font", GameTheme.font("icons"))
	_moment_icon.add_theme_font_size_override("font_size", 26)
	_moment_icon.add_theme_color_override("font_color", GameTheme.NAVY)
	_moment_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_moment_icon.visible = _moment_clock.is_compact()
	_moment_icon.text = _moment_clock.active_icon()
	checklist_container.add_child(_moment_icon)
	_moment_name = Label.new()
	_moment_name.name = "MomentName"
	_moment_name.text = tr(_moment_clock.active_label()).to_upper()
	_moment_name.add_theme_font_override("font", GameTheme.font("mono_bold"))
	_moment_name.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	_moment_name.add_theme_color_override("font_color", GameTheme.INK)
	_moment_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_moment_name.visible = false   # the moment's tab names it
	checklist_container.add_child(_moment_name)

	# Then a single shared content area — only the active moment's chip row is
	# actually visible/sized inside it at any one time (see highlight_moment).
	var content := HBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checklist_container.add_child(content)

	for i in _moments.size():
		var m     := _moments[i] as Dictionary
		var mid   := m["id"]    as String
		var needs := m["needs"] as Array

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
	lbl.add_theme_font_override("font", GameTheme.font("mono_bold"))
	lbl.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	lbl.add_theme_color_override("font_color", GameTheme.CHALK_SOFT)
	return lbl


# Called by Main after it switches moments (including the initial one on
# level load), however the switch was made: turns the clock's hand, names
# the moment and shows that moment's chips.
func highlight_moment(moment_id: String) -> void:
	if is_instance_valid(_moment_clock):
		_moment_clock.set_active(moment_id)
		_moment_name.text = tr(_moment_clock.active_label()).to_upper()
		_moment_icon.text = _moment_clock.active_icon()
	for mid in _moment_rows:
		(_moment_rows[mid] as Control).visible = (mid == moment_id)


# A small square glyph tile with a check/cross badge in the corner — reads at
# a glance as a WoW-style quest tracker instead of a text checklist. Native
# tooltip_text carries the need's name on hover since there's little more to
# say about a need than "done or not."
func _make_need_chip(func_name: String, satisfied: bool, req_id: String = "") -> PanelContainer:
	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(0, GameTheme.TOUCH_SMALL)
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

	var icon := Requirements.make_icon(req_id if req_id != "" else "need:" + func_name, GameTheme.FS_LABEL)
	icon.name = "Icon"
	row.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = Loc.need_name(func_name)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_lbl)

	var badge := Label.new()
	badge.name = "Badge"
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", GameTheme.FS_LABEL)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(badge)

	chip.set_meta("satisfied", satisfied)
	_paint_need_chip(chip, satisfied)
	return chip


func _paint_need_chip(chip: PanelContainer, satisfied: bool, showcased: bool = false) -> void:
	chip.add_theme_stylebox_override("panel", _chip_style(satisfied, showcased))
	# A sticky note on the architect's desk: still to do, yellow with a red
	# cross; done, green with a tick, folded down to its icon. Written by
	# hand.
	var ink := NOTE_DONE_INK if satisfied else NOTE_TODO_INK
	for part in ["Icon", "Name"]:
		var lbl := chip.find_child(part, true, false) as Label
		if lbl:
			lbl.add_theme_color_override("font_color", ink)
	var hand := chip.find_child("Name", true, false) as Label
	if hand and GameTheme.handwriting():
		hand.add_theme_font_override("font", GameTheme.handwriting())
		hand.add_theme_font_size_override("font_size", GameTheme.FS_BODY + 6)
	# A need that is met folds down to its icon and tick (its name stays in
	# the tooltip): what is still to do is what takes the room.
	var name_lbl := chip.find_child("Name", true, false) as Label
	if name_lbl:
		name_lbl.visible = not satisfied and not (chip.get_meta("squeezed", false) as bool)
	var badge := chip.find_child("Badge", true, false) as Label
	if satisfied:
		badge.text = "\uea5e"
		badge.add_theme_color_override("font_color", NOTE_DONE_INK)
	else:
		badge.text = "\ueb55"
		badge.add_theme_color_override("font_color", GameTheme.RED)


# Each need a sticky note: yellow while still to do, green once done, so
# the goal list reads at a glance by colour and by its cross or tick.
# `showcased` (the 3D post-win showcase currently posing the tenant at this
# need's furniture) rings the tile in gold on top of whichever fill applies —
# an independent "look here" cue layered over, not instead of, done/pending.
const NOTE_TODO      := Color("fbe37a")   # a yellow sticky note
const NOTE_TODO_EDGE := Color("c9a93b")
const NOTE_TODO_INK  := Color("5a4400")
const NOTE_DONE      := Color("d9edc9")   # a green one, ticked
const NOTE_DONE_EDGE := Color("7aa35a")
const NOTE_DONE_INK  := Color("27500a")

static func _chip_style(satisfied: bool, showcased: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if satisfied:
		s.bg_color     = NOTE_DONE
		s.border_color = NOTE_DONE_EDGE
	else:
		s.bg_color     = NOTE_TODO
		s.border_color = NOTE_TODO_EDGE
	s.set_border_width_all(3 if showcased else 1)
	if showcased:
		s.border_color = GameTheme.RED
	# Paper: square corners, lying a little off the desk.
	s.set_corner_radius_all(2)
	s.shadow_color = Color(0, 0, 0, 0.3)
	s.shadow_size = 1
	s.shadow_offset = Vector2(2, 3)
	s.set_content_margin(SIDE_LEFT, 12)
	s.set_content_margin(SIDE_RIGHT, 12)
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
	if satisfied != was_satisfied:
		_queue_fit()
		_queue_badges()


# ── Keeping the bar on one row ──────────────────────────────────────────────
# Needs that are met already fold down to their icon and tick. When what is
# still to do doesn't fit on one row either (a phase adds a need and a rule,
# say), the rules still to do fold down to icon and cross first, then the
# needs: the name stays in each chip's tooltip. Unfolded again whenever
# there is room.
var _fit_queued := false

func _queue_fit() -> void:
	if _fit_queued or not is_inside_tree():
		return
	_fit_queued = true
	_fit_bar.call_deferred()


func _bar_chips() -> Array:
	return checklist_container.find_children("*", "PanelContainer", true, false).filter(
		func(c): return (c as Node).find_child("Badge", true, false) != null)


func _bar_wraps() -> bool:
	for flow in checklist_container.find_children("*", "FlowContainer", true, false):
		if (flow as FlowContainer).visible and (flow as FlowContainer).get_line_count() > 1:
			return true
	# Without a wrapping row, too wide for the bar.
	return checklist_container.get_combined_minimum_size().x > checklist_container.size.x + 1.0


func _fit_bar() -> void:
	_fit_queued = false
	var chips := _bar_chips()
	for c in chips:
		_squeeze(c, false)
	for step in ["rule", "need"]:
		await get_tree().process_frame
		if not is_inside_tree() or not _bar_wraps():
			return
		for c in chips:
			if is_instance_valid(c) and (step == "need" or (c as Node).get_meta("rule", false)):
				_squeeze(c, true)


func _squeeze(chip: PanelContainer, on: bool) -> void:
	chip.set_meta("squeezed", on)
	var name_lbl := chip.find_child("Name", true, false) as Label
	if name_lbl:
		name_lbl.visible = not (chip.get_meta("satisfied", false) as bool) and not on


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
			var is_quiet := (rule["kind"] as String) == "quiet"
			if not is_sight and not is_items and not is_quiet:
				zone_number += 1
			var req_id := ("sight:%d" % rule["number"]) if is_sight else (("items:%d" % rule["number"]) if is_items \
				else (("quiet:%d" % rule["number"]) if is_quiet else ("zones:%d" % zone_number)))
			var chip := _make_need_chip("rule", false, req_id)
			chip.set_meta("rule", true)
			var text := rule.get("short", "") as String
			if text == "":
				text = rule["label"] as String
			if is_sight:
				text = "%d  %s" % [rule["number"], text]
			(chip.get_child(0).get_child(1) as Label).text = text
			chip.tooltip_text = (rule["label"] as String) + (
				"\n" + tr("The numbered line on the plan shows it.") if is_sight
				else ("\n" + tr("Put them all down in the flat.") if is_items
				else ("\n" + tr("The footsteps on the plan show the way, red where it wakes them.") if is_quiet
				else "\n" + tr("Tall storage splits a room into zones."))))
			if is_items:
				var n: int = rule["number"]
				chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				chip.tooltip_text += "\n" + tr("Click to see the pieces that count")
				chip.gui_input.connect(func(event: InputEvent):
					if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
						and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
						items_clicked.emit(n))
			_rule_row.add_child(chip)
			_rule_chips.append(chip)
			_register_chip(req_id, chip)
		_apply_requirement_state()
		_queue_fit()
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
	var done := {}
	for m in _moments:
		var mid    := m["id"]    as String
		var needs  := m["needs"] as Array
		var mfulfilled_all := (results.get(mid, {}) as Dictionary).get("fulfilled", []) as Array
		# Hidden needs don't count, so the clock doesn't give them away.
		done[mid] = needs.all(func(f) -> bool:
			return f in mfulfilled_all or is_hidden_requirement("moment:%s:%s" % [mid, f]) \
				or is_hidden_requirement("need:" + str(f)))
		if not _moment_check_chips.has(mid):
			continue
		var chips  := _moment_check_chips[mid] as Dictionary
		var mdata  := results.get(mid, {}) as Dictionary
		var mfulfilled := mdata.get("fulfilled", []) as Array
		for func_name in needs:
			if chips.has(func_name):
				_set_need_chip(chips[func_name] as PanelContainer, func_name in mfulfilled)
	if is_instance_valid(_moment_clock):
		_moment_clock.set_status(done)


# ── Requirement ids, hidden requirements, the application ───────────────────

func _register_chip(req_id: String, chip: Control) -> void:
	if not _chips_by_req.has(req_id):
		_chips_by_req[req_id] = []
	(_chips_by_req[req_id] as Array).append(chip)
	if _stamping:
		chip.set_meta("unstamped", true)
	chip.set_meta("tilt", float(absi(req_id.hash()) % 7 - 3) * 0.8)   # each note its own, always the same
	_tilt_notes_in(chip.get_parent())


# Notes lie a little askew, as if put down by hand. A container sets its
# children straight whenever it lays them out, so the tilt goes back on
# after each layout.
func _tilt_notes_in(row: Node) -> void:
	if not (row is Container) or row.has_meta("tilts"):
		return
	row.set_meta("tilts", true)
	(row as Container).sort_children.connect(func():
		for c in row.get_children():
			if c is Control and (c as Control).has_meta("tilt"):
				(c as Control).pivot_offset = (c as Control).size * 0.5
				(c as Control).rotation_degrees = (c as Control).get_meta("tilt") as float)


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
	var goal := checklist_container.get_node_or_null("GoalLabel")
	if goal:
		(goal as Control).visible = not available
	_apply_requirement_state()


func _add_application_button() -> void:
	var btn := Button.new()
	btn.name = "ApplicationButton"
	btn.text = "\ueb0e"
	btn.tooltip_text = tr("Read the tenant's rental application again") + \
		(("\n" + tr("%s NEEDS") % _tenant_name.to_upper()) if _tenant_name != "" else "")
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	GameTheme.hud_button(btn, true)
	btn.pressed.connect(func(): application_requested.emit())
	btn.set_meta("tilt", -3.0)   # a sheet laid down on the desk
	checklist_container.add_child(btn)
	_tilt_notes_in(checklist_container)


func _apply_requirement_state() -> void:
	var hidden_chips: Array = []
	for req_id in _hidden_reqs:
		hidden_chips.append_array(_chips_by_req.get(req_id, []) as Array)
	for req_id in _chips_by_req:
		for chip in _chips_by_req[req_id]:
			var c := chip as Control
			if not is_instance_valid(c):
				continue
			# Someone else's need, while one resident's are shown: left out.
			var theirs := _focus == "" or _is_theirs(req_id, _focus)
			c.visible = c not in hidden_chips and theirs
			c.modulate.a = 0.0 if c.get_meta("unstamped", false) else 1.0
	_queue_badges()
	_queue_fit()


# ── The household ───────────────────────────────────────────────────────────

# Called by Main with the level's residents ({id, name, color, body,
# feminine}) and who each requirement belongs to.
func set_household(residents: Array, owners_of: Callable) -> void:
	_household = residents
	_owners_of = owners_of
	if not _household.any(func(r): return (r as Dictionary)["id"] == _focus):
		_focus = ""
	_add_household()
	_apply_requirement_state()


func _is_theirs(req_id: String, rid: String) -> bool:
	if not _owners_of.is_valid():
		return true
	var owners := _owners_of.call(req_id) as Array
	return owners.is_empty() or rid in owners


func _add_household() -> void:
	_badges.clear()
	if _household.is_empty():
		return
	if household_box == null:
		return
	for c in household_box.get_children():
		household_box.remove_child(c)
		c.queue_free()
	household_box.visible = not _household.is_empty()
	if _household.is_empty():
		return
	for r in _household:
		var rd := r as Dictionary
		var rid := rd["id"] as String
		# A rounded square tile in their colour; the chosen one bigger, in white.
		var chosen := rid == _focus
		var side := FACE_SIZE_CHOSEN if chosen else FACE_SIZE
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(side, side)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.tooltip_text = (tr("%s NEEDS") % (rd["name"] as String).to_upper()) + "\n" + tr("Click to show only theirs")
		var col := rd["color"] as Color
		var sb := StyleBoxFlat.new()
		sb.bg_color = col.lightened(0.15)
		sb.border_color = Color.WHITE if chosen else col.darkened(0.35)
		sb.set_border_width_all(4 if chosen else 2)
		sb.set_corner_radius_all(TILE_RADIUS)
		sb.shadow_color = Color(0, 0, 0, 0.35)
		sb.shadow_size = 3
		sb.anti_aliasing = true
		for state in ["normal", "hover", "pressed"]:
			btn.add_theme_stylebox_override(state, sb)
		var body := rd.get("body", "adult") as String
		if body == "animal":
			btn.text = NEED_GLYPH["pet"]
			btn.add_theme_color_override("font_color", col.darkened(0.45))
		else:
			# The face, cut to the tile's rounded frame by a mask.
			var mask := Panel.new()
			var round := StyleBoxFlat.new()
			round.set_corner_radius_all(TILE_RADIUS - 2)
			mask.add_theme_stylebox_override("panel", round)
			mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
			mask.set_anchors_preset(Control.PRESET_FULL_RECT)
			mask.offset_left = 3; mask.offset_top = 3; mask.offset_right = -3; mask.offset_bottom = -3
			mask.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
			btn.add_child(mask)
			var pic := TextureRect.new()
			pic.texture = MiiPortrait.face(body, rd.get("feminine", false) as bool)
			pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pic.set_anchors_preset(Control.PRESET_FULL_RECT)
			mask.add_child(pic)
		# How many of their needs are still to do; a tick once there are none.
		var badge := Label.new()
		badge.add_theme_font_override("font", GameTheme.font("mono_bold"))
		badge.add_theme_font_size_override("font_size", 11)
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		badge.custom_minimum_size = Vector2(16, 16)
		badge.position = Vector2(side - 12, -5)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(badge)
		_badges[rid] = badge
		btn.pressed.connect(func():
			Audio.play("click")
			_focus = "" if _focus == rid else rid
			set_household(_household, _owners_of))
		household_box.add_child(btn)
	_queue_badges()


func _queue_badges() -> void:
	if not _badges_queued:
		_badges_queued = true
		_refresh_badges.call_deferred()


func _refresh_badges() -> void:
	_badges_queued = false
	for rid in _badges:
		var badge := _badges[rid] as Label
		if not is_instance_valid(badge):
			continue
		# By chip: one chip can answer to two ids ("need:sleep", "moment:night:sleep").
		var todo := {}
		for req_id in _chips_by_req:
			if req_id in _hidden_reqs or not _is_theirs(req_id, rid):
				continue
			for c in _chips_by_req[req_id]:
				if is_instance_valid(c) and not (c as Control).get_meta("satisfied", false):
					todo[c] = true
		var missing := todo.size()
		var sb := StyleBoxFlat.new()
		sb.bg_color = GameTheme.RED if missing > 0 else GameTheme.OK
		sb.set_corner_radius_all(8)
		badge.add_theme_stylebox_override("normal", sb)
		badge.text = str(missing) if missing > 0 else ""


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
		if mid != "" and is_instance_valid(_moment_clock) and not is_hidden_requirement(req_id):
			return _moment_clock
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
