extends Control
class_name CityMap

# ── Layout constants ────────────────────────────────────────────────────────
const MAP_W    := 860
const TOP_H    := 54
const H_PAD    := 20.0
const V_PAD    := 12.0
const COLS     := 5
const ROWS     := 9   # total rows in the grid (row 0 = tutorials, rows 1+ = regular levels)
const CARD_W   := 142
const CARD_H   := 108
const MAP_VISIBLE_H := 666.0   # 720 - TOP_H

# District accent colors (bg tint for cards)
const DISTRICT_COLORS := {
	"Wedding":         Color(0.20, 0.44, 0.55, 1.0),
	"Neukölln":        Color(0.60, 0.36, 0.20, 1.0),
	"Schöneberg":      Color(0.20, 0.52, 0.32, 1.0),
	"Kreuzberg":       Color(0.58, 0.20, 0.28, 1.0),
	"Friedrichshain":  Color(0.36, 0.20, 0.58, 1.0),
	"Prenzlauer Berg": Color(0.48, 0.22, 0.56, 1.0),
	"Mitte":           Color(0.72, 0.58, 0.18, 1.0),
}

# ── State ───────────────────────────────────────────────────────────────────
var _levels_data: Dictionary = {}
var _selected: Dictionary = {}
var _cards: Dictionary = {}      # level_id → Button

var _filter_progress: bool = false
var _filter_stars:    bool = false
var _map_content: Control = null

var _custom_levels:       Array      = []
var _selected_is_custom:  bool       = false
var _selected_custom_data: Dictionary = {}

var _debug_section_line: ColorRect = null
var _debug_section_hdr:  Label     = null

# Info panel widgets
var _info_title:    Label
var _info_district: Label
var _info_tenant:   Label
var _info_reqs:     Label
var _info_budget:   Label
var _info_rent:     Label
var _info_cost:     Label
var _action_btn:    Button
var _funds_label:   Label
var _stars_label:   Label


func _ready() -> void:
	_levels_data = _load_json("res://data/levels.json")
	_build_ui()
	_map_content.size.y = _map_total_h()
	GameState.company_funds_changed.connect(_on_funds_changed)
	if not GameState.debug_mode_changed.is_connected(_on_debug_mode_changed):
		GameState.debug_mode_changed.connect(_on_debug_mode_changed)
	_refresh_all_cards()
	if _levels_data.get("levels", []).size() > 0:
		_select_level(_levels_data["levels"][0] as Dictionary)


# ── JSON helper ─────────────────────────────────────────────────────────────
func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	json.parse(file.get_as_text())
	return json.get_data()


# ── Card position in screen coordinates ─────────────────────────────────────
func _card_xy(col: int, row: int) -> Vector2:
	# Positions are relative to _map_content (no TOP_H offset)
	var cell_w := (MAP_W - H_PAD * 2) / float(COLS)
	var cell_h := CARD_H + V_PAD * 2
	return Vector2(
		H_PAD + col * cell_w + (cell_w - CARD_W) * 0.5,
		V_PAD + row * cell_h + (cell_h - CARD_H) * 0.5
	)


func _map_total_h() -> float:
	return _real_section_reserved_h() + _debug_section_reserved_h()


func _custom_section_y() -> float:
	return _real_section_reserved_h() + _debug_section_reserved_h()


# ── Debug section (dev-only sandbox levels, kept visually separate from the
# real progression instead of interleaved into it — see _build_debug_section)
#
# A level counts as "debug" if its district is literally "Debug" OR its name
# is "Debug: ..." — a few mechanic-test levels (Balcony, Sloped Ceiling) were
# authored with a real district (Mitte) so they'd count toward normal
# progression, but they're still named like dev levels and read as one
# category to anyone looking at the map, so group them together too.
func _is_debug_level(ld: Dictionary) -> bool:
	if ld.get("district", "") == "Debug":
		return true
	return (ld.get("name", "") as String).begins_with("Debug:")


func _debug_level_count() -> int:
	var count := 0
	for ld in _levels_data.get("levels", []):
		if _is_debug_level(ld as Dictionary):
			count += 1
	return count


func _real_level_count() -> int:
	return (_levels_data.get("levels", []) as Array).size() - _debug_level_count()


# Real (non-debug) levels are packed sequentially — index 0, 1, 2... in COLS
# columns — instead of using each level's own authored map_row/map_col.
# Those hand-picked positions were meant for a much larger, district-grouped
# city map; with only a handful of real levels defined so far they left
# empty cells in the middle of the row and a large blank gap before the
# debug section (which used to start at a fixed row far below whatever
# content actually existed). Packing removes both problems at once — the
# debug section now starts right where the real levels end.
func _real_section_reserved_h() -> float:
	var count := _real_level_count()
	var rows := maxi(1, ceili(float(count) / float(COLS)))
	return rows * (CARD_H + V_PAD * 2) + V_PAD * 2


func _debug_section_reserved_h() -> float:
	var count := _debug_level_count()
	if count == 0:
		return 0.0
	var rows := ceili(float(count) / float(COLS))
	return 30.0 + rows * (CARD_H + V_PAD * 2)


func _debug_section_y() -> float:
	return _real_section_reserved_h()


func _debug_card_xy(index: int) -> Vector2:
	var col    := index % COLS
	var row    := index / COLS
	var cell_w := (MAP_W - H_PAD * 2) / float(COLS)
	var cell_h := float(CARD_H + V_PAD * 2)
	var sy     := _debug_section_y() + 30.0
	return Vector2(
		H_PAD + col * cell_w + (cell_w - CARD_W) * 0.5,
		sy + V_PAD + row * cell_h + (cell_h - CARD_H) * 0.5
	)


func _custom_card_xy(index: int) -> Vector2:
	var col    := index % COLS
	var row    := index / COLS
	var cell_w := (MAP_W - H_PAD * 2) / float(COLS)
	var cell_h := float(CARD_H + V_PAD * 2)
	var sy     := _custom_section_y() + 30.0
	return Vector2(
		H_PAD + col * cell_w + (cell_w - CARD_W) * 0.5,
		sy + V_PAD + row * cell_h + (cell_h - CARD_H) * 0.5
	)


# ── Build all UI nodes ───────────────────────────────────────────────────────
func _build_ui() -> void:
	# Background
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Top bar
	var top_pc := PanelContainer.new()
	top_pc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_pc.custom_minimum_size = Vector2(0, TOP_H)
	var ts := StyleBoxFlat.new()
	ts.bg_color     = Color(0.09, 0.11, 0.15, 0.98)
	ts.border_color = Color(0.22, 0.28, 0.36)
	ts.set_border_width(SIDE_BOTTOM, 1)
	ts.set_content_margin_all(8)
	top_pc.add_theme_stylebox_override("panel", ts)
	add_child(top_pc)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 14)
	top_pc.add_child(top_row)

	var title_lbl := Label.new()
	title_lbl.text = "CITY MAP"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	top_row.add_child(title_lbl)

	_stars_label = Label.new()
	_stars_label.add_theme_font_size_override("font_size", 12)
	_stars_label.add_theme_color_override("font_color", GameTheme.C_AMBER)
	top_row.add_child(_stars_label)

	_funds_label = Label.new()
	_funds_label.add_theme_font_size_override("font_size", 13)
	_funds_label.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60))
	top_row.add_child(_funds_label)

	var filter_sep := Label.new()
	filter_sep.text = "|"
	filter_sep.add_theme_color_override("font_color", GameTheme.C_MUTED)
	top_row.add_child(filter_sep)

	var progress_btn := Button.new()
	progress_btn.text        = "Progress"
	progress_btn.toggle_mode = true
	progress_btn.add_theme_font_size_override("font_size", 11)
	progress_btn.toggled.connect(func(on: bool):
		_filter_progress = on
		if on: _filter_stars = false
		_refresh_all_cards())
	top_row.add_child(progress_btn)

	var stars_btn := Button.new()
	stars_btn.text        = "★ Replay"
	stars_btn.toggle_mode = true
	stars_btn.add_theme_font_size_override("font_size", 11)
	stars_btn.toggled.connect(func(on: bool):
		_filter_stars = on
		if on: _filter_progress = false
		_refresh_all_cards())
	top_row.add_child(stars_btn)

	_update_top_bar_counters()

	# Clipped map viewport — cards scroll within this
	var map_clip := Control.new()
	map_clip.position = Vector2(0, TOP_H)
	map_clip.size     = Vector2(MAP_W, 720.0 - TOP_H)
	map_clip.clip_contents = true
	add_child(map_clip)

	_map_content = Control.new()
	_map_content.position = Vector2.ZERO
	_map_content.size     = Vector2(MAP_W, _map_total_h())
	map_clip.add_child(_map_content)

	# Block header labels — one per block transition (blocks 2-5 have tutorial rows)
	_build_block_headers()

	# Property cards — children of _map_content, positioned relative to it.
	# Debug-district levels are laid out separately below (_build_debug_section)
	# instead of at their own map_row/map_col — those coordinates routinely
	# collide with real levels' cells (a debug sandbox and a tutorial level
	# both claiming row 0 / col 0, say), which only stayed invisible-by-luck
	# because debug levels used to be hidden outright.
	var real_index := 0
	for ld in _levels_data.get("levels", []):
		var d := ld as Dictionary
		if _is_debug_level(d):
			continue
		var card := _create_card(d, real_index)
		_cards[d["id"]] = card
		real_index += 1
	_build_debug_section()

	# Vertical divider before info panel
	var div := ColorRect.new()
	div.color = Color(0.20, 0.26, 0.34)
	div.position = Vector2(MAP_W, 0)
	div.size     = Vector2(1, 720)
	add_child(div)

	# Info panel
	var ip := PanelContainer.new()
	ip.position = Vector2(MAP_W + 1, 0)
	ip.size     = Vector2(1280 - MAP_W - 1, 720)
	var ip_s := StyleBoxFlat.new()
	ip_s.bg_color = Color(0.09, 0.11, 0.15)
	ip_s.set_content_margin(SIDE_LEFT,   22)
	ip_s.set_content_margin(SIDE_RIGHT,  22)
	ip_s.set_content_margin(SIDE_TOP,    60)
	ip_s.set_content_margin(SIDE_BOTTOM, 24)
	ip.add_theme_stylebox_override("panel", ip_s)
	add_child(ip)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	ip.add_child(vb)

	_info_title = _make_info_label(vb, 18, GameTheme.C_AMBER, true)
	_info_district = _make_info_label(vb, 11, GameTheme.C_MUTED)

	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("color", Color(0.20, 0.26, 0.34))
	vb.add_child(sep1)

	_info_tenant = _make_info_label(vb, 11, GameTheme.C_TEXT, true)
	_info_reqs   = _make_info_label(vb, 11, GameTheme.C_MUTED)
	_info_budget = _make_info_label(vb, 12, GameTheme.C_TEXT)
	_info_rent   = _make_info_label(vb, 15, Color(0.50, 0.78, 0.60))

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", Color(0.20, 0.26, 0.34))
	vb.add_child(sep2)

	_info_cost = _make_info_label(vb, 13, GameTheme.C_AMBER, true)

	_action_btn = Button.new()
	_action_btn.custom_minimum_size = Vector2(210, 44)
	_action_btn.add_theme_font_size_override("font_size", 14)
	var rs := GameTheme.make_rent_btn_style()
	_action_btn.add_theme_stylebox_override("normal",   rs[0])
	_action_btn.add_theme_stylebox_override("hover",    rs[1])
	_action_btn.add_theme_stylebox_override("pressed",  rs[1])
	_action_btn.add_theme_stylebox_override("disabled", rs[2])
	_action_btn.add_theme_color_override("font_color",          GameTheme.C_AMBER)
	_action_btn.add_theme_color_override("font_disabled_color", GameTheme.C_MUTED)
	_action_btn.pressed.connect(_on_action_pressed)
	vb.add_child(_action_btn)

	# Bottom spacer pushes the secondary buttons to the bottom of the panel
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(push)

	var sep3 := HSeparator.new()
	sep3.add_theme_color_override("color", Color(0.16, 0.20, 0.26))
	vb.add_child(sep3)

	var settings_btn := Button.new()
	settings_btn.text = "⚙ Settings"
	settings_btn.add_theme_font_size_override("font_size", 12)
	settings_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	settings_btn.pressed.connect(func(): SettingsMenu.open(self))
	vb.add_child(settings_btn)


func _make_info_label(parent: VBoxContainer, font_size: int, col: Color, autowrap: bool = false) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	if autowrap:
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)
	return lbl


# ── Card creation ────────────────────────────────────────────────────────────
func _create_card(ld: Dictionary, index: int = 0) -> Button:
	var pos := _card_xy(index % COLS, index / COLS)

	var card := Button.new()
	card.position = pos
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size = Vector2(CARD_W, CARD_H)
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	var sn := StyleBoxFlat.new()
	sn.bg_color     = Color(0.12, 0.15, 0.20)
	sn.border_color = Color(0.22, 0.28, 0.36)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(7)
	sn.set_content_margin_all(0)
	sn.anti_aliasing = true
	sn.shadow_color = Color(0, 0, 0, 0.30)
	sn.shadow_size = 5
	sn.shadow_offset = Vector2(0, 2)
	card.add_theme_stylebox_override("normal", sn)

	var sh := sn.duplicate() as StyleBoxFlat
	sh.border_color = GameTheme.C_AMBER
	sh.set_border_width_all(2)
	sh.shadow_color = Color(0.95, 0.88, 0.55, 0.30)
	sh.shadow_size = 8
	card.add_theme_stylebox_override("hover", sh)
	card.add_theme_stylebox_override("pressed", sh)

	card.pressed.connect(_select_level.bind(ld))
	_map_content.add_child(card)
	return card


# ── Card content refresh ─────────────────────────────────────────────────────
func _refresh_all_cards() -> void:
	for ld in _levels_data.get("levels", []):
		var lid := (ld as Dictionary)["id"] as String
		var card := _cards.get(lid) as Button
		if card:
			_fill_card(card, ld as Dictionary)


func _fill_card(card: Button, ld: Dictionary) -> void:
	var district  := ld.get("district", "Wedding") as String
	# Debug/dev-only sandbox levels (loft mechanics, sloped ceilings, balcony
	# rendering, etc.) are clutter for a real player, so they stay hidden
	# until debug mode is on.
	card.visible = not _is_debug_level(ld) or GameState.debug_mode
	if not card.visible:
		return

	# Remove previous content
	for ch in card.get_children():
		ch.queue_free()

	var lid       := ld["id"] as String
	var is_owned  := GameState.is_owned(lid)
	var cost      := ld.get("acquisition_cost", 0) as int
	var min_stars := ld.get("min_stars", 0) as int
	var level_visible := GameState.total_stars() >= min_stars
	var can_buy   := GameState.company_funds >= cost
	var stars     := GameState.get_stars(lid)
	var dist_col  := DISTRICT_COLORS.get(district, Color(0.4, 0.4, 0.4, 1.0)) as Color

	# Update card background tint via normal StyleBoxFlat
	var sn := card.get_theme_stylebox("normal") as StyleBoxFlat
	if sn:
		if not level_visible:
			sn.bg_color = Color(0.08, 0.09, 0.11)
			sn.border_color = Color(0.14, 0.16, 0.19)
		elif is_owned:
			sn.bg_color     = Color(dist_col.r * 0.28 + 0.07, dist_col.g * 0.28 + 0.09, dist_col.b * 0.28 + 0.11)
			sn.border_color = Color(dist_col.r * 0.70 + 0.10, dist_col.g * 0.70 + 0.10, dist_col.b * 0.70 + 0.10, 0.80)
		elif can_buy:
			sn.bg_color     = Color(0.12, 0.15, 0.20)
			sn.border_color = Color(0.22, 0.28, 0.36)
		else:
			sn.bg_color     = Color(0.09, 0.11, 0.14)
			sn.border_color = Color(0.16, 0.20, 0.25)

	var vb := VBoxContainer.new()
	vb.position = Vector2(7, 7)
	vb.size     = Vector2(CARD_W - 14, CARD_H - 14)
	vb.add_theme_constant_override("separation", 3)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	if not level_visible:
		var q := Label.new()
		q.text = "?"
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		q.size_flags_vertical  = Control.SIZE_EXPAND_FILL
		q.add_theme_font_size_override("font_size", 30)
		q.add_theme_color_override("font_color", Color(0.26, 0.30, 0.35))
		vb.add_child(q)
		var nl := Label.new()
		nl.text = "Need %d ★" % min_stars
		nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nl.add_theme_font_size_override("font_size", 9)
		nl.add_theme_color_override("font_color", Color(0.34, 0.38, 0.44))
		vb.add_child(nl)
		return

	# Level name
	var nm := Label.new()
	nm.text = ld["name"] as String
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color", GameTheme.C_AMBER if is_owned else GameTheme.C_TEXT)
	vb.add_child(nm)

	# District tag (or TUTORIAL badge)
	var is_tut := ld.get("is_tutorial", false) as bool
	var dt := Label.new()
	if is_tut:
		dt.text = "TUTORIAL"
		dt.add_theme_font_size_override("font_size", 8)
		dt.add_theme_color_override("font_color", Color(0.40, 0.90, 0.70))
	else:
		dt.text = district.to_upper()
		dt.add_theme_font_size_override("font_size", 8)
		dt.add_theme_color_override("font_color", Color(dist_col.r * 0.8 + 0.1, dist_col.g * 0.8 + 0.1, dist_col.b * 0.8 + 0.1))
	vb.add_child(dt)

	# Tutorial glow border override
	if is_tut:
		var tut_s := card.get_theme_stylebox("normal").duplicate() as StyleBoxFlat
		tut_s.bg_color     = Color(0.08, 0.16, 0.14)
		tut_s.border_color = Color(0.30, 0.80, 0.60, 0.75)
		tut_s.set_border_width_all(1)
		card.add_theme_stylebox_override("normal", tut_s)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(spacer)

	# Bottom row: stars / cost / ready
	if stars > 0:
		var sl := Label.new()
		sl.text = "★".repeat(stars) + "☆".repeat(3 - stars)
		sl.add_theme_font_size_override("font_size", 15)
		sl.add_theme_color_override("font_color", GameTheme.C_AMBER)
		vb.add_child(sl)
	elif is_owned:
		var rl := Label.new()
		rl.text = "READY"
		rl.add_theme_font_size_override("font_size", 10)
		rl.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60))
		vb.add_child(rl)
	else:
		var cl := Label.new()
		cl.text = "%d€" % cost
		cl.add_theme_font_size_override("font_size", 11)
		cl.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60) if can_buy else GameTheme.C_MUTED)
		vb.add_child(cl)

	# ── Filter overlays ───────────────────────────────────────────────────────
	var completed := lid in GameState.completed
	if _filter_progress and completed:
		# Grey veil over completed apartments so new ones pop
		var veil := ColorRect.new()
		veil.color = Color(0.05, 0.06, 0.08, 0.62)
		veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(veil)
	elif _filter_stars and completed and stars < 3:
		# Amber glow border on 1-2 star apartments — worth replaying
		var sn2 := card.get_theme_stylebox("normal").duplicate() as StyleBoxFlat
		sn2.border_color = Color(GameTheme.C_AMBER.r, GameTheme.C_AMBER.g, GameTheme.C_AMBER.b, 0.85)
		sn2.set_border_width_all(2)
		card.add_theme_stylebox_override("normal", sn2)
		var tag := Label.new()
		tag.text = "↺"
		tag.add_theme_font_size_override("font_size", 18)
		tag.add_theme_color_override("font_color", GameTheme.C_AMBER)
		tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		tag.vertical_alignment   = VERTICAL_ALIGNMENT_TOP
		tag.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(tag)


# ── Info panel update ────────────────────────────────────────────────────────
func _select_level(ld: Dictionary) -> void:
	_selected_is_custom = false
	_selected = ld
	var lid      := ld["id"] as String
	var is_owned := GameState.is_owned(lid)
	var cost     := ld.get("acquisition_cost", 0) as int
	var min_st   := ld.get("min_stars", 0) as int
	var level_visible := GameState.total_stars() >= min_st
	var can_buy  := GameState.company_funds >= cost
	var stars    := GameState.get_stars(lid)
	var tenant   := ld["tenant"] as Dictionary

	_info_title.text    = ld["name"] as String
	_info_district.text = "%s  ·  %s" % [
		ld.get("district", "?") as String,
		_sqm_label(ld)
	]

	var star_suffix := ""
	if stars > 0:
		star_suffix = "\n" + "★".repeat(stars) + "☆".repeat(3 - stars)
	_info_tenant.text = "%s, %d\n\"%s\"%s" % [
		tenant.get("name", "?"), int(str(tenant.get("age", 0))),
		tenant.get("bio", ""),
		star_suffix
	]

	var funcs := tenant.get("required_functions", []) as Array
	var mechanic_intro := ld.get("mechanic_intro", {}) as Dictionary
	if not mechanic_intro.is_empty():
		var intro_title := mechanic_intro.get("title", "") as String
		_info_reqs.text = "★ " + intro_title
	elif funcs.is_empty():
		_info_reqs.text = "Requires: (see Moments)"
	else:
		_info_reqs.text = "Requires: " + ", ".join(funcs)
	_info_budget.text = "Budget: %d€" % ld.get("starting_budget", 0)
	_info_rent.text   = "%d€ / month" % (tenant.get("monthly_rent", 0) as int)

	if not level_visible:
		_info_cost.text    = "Locked — need %d total ★" % min_st
		_action_btn.text   = "LOCKED"
		_action_btn.disabled = true
	elif is_owned:
		var reward := ld.get("funds_base_reward", 0) as int
		_info_cost.text    = "Reward: ~%d€ CompanyFunds" % reward
		_action_btn.text   = "ENTER  →"
		_action_btn.disabled = false
	else:
		_info_cost.text    = "Acquisition: %d€ CompanyFunds" % cost
		_action_btn.text   = "BUY — %d€" % cost
		_action_btn.disabled = not can_buy


func _sqm_label(ld: Dictionary) -> String:
	var floors := (ld["apartment"] as Dictionary).get("floors", []) as Array
	var total_tiles := 0
	for fd in floors:
		total_tiles += (fd as Dictionary).get("grid_w", 0) as int * (fd as Dictionary).get("grid_h", 0) as int
	return "%.0f m²" % (float(total_tiles) * 0.01)  # 1 tile = 10cm × 10cm = 0.01m²


func _update_top_bar_counters() -> void:
	if _stars_label:
		_stars_label.text = "★ %d  |  " % GameState.total_stars()
	if _funds_label:
		_funds_label.text = "CompanyFunds: %d€" % GameState.company_funds


# ── Signals ──────────────────────────────────────────────────────────────────
func _on_action_pressed() -> void:
	if _selected_is_custom:
		Audio.play("click")
		GameState.custom_level_data = _selected_custom_data
		GameState.pending_level_id  = "_custom"
		GameState.own_level("_custom")
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
		return
	if _selected.is_empty():
		return
	var lid     := _selected["id"] as String
	var is_owned := GameState.is_owned(lid)

	if is_owned:
		Audio.play("click")
		GameState.pending_level_id = lid
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
	else:
		var cost := _selected.get("acquisition_cost", 0) as int
		if GameState.buy_level(lid, cost):
			Audio.play("success")
			_fill_card(_cards[lid] as Button, _selected)
			_select_level(_selected)
		else:
			Audio.play("error")


func _gui_input(event: InputEvent) -> void:
	if not _map_content:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.position.x < MAP_W:
			var scroll_step := 60.0
			var max_scroll  := -((_map_total_h()) - MAP_VISIBLE_H)
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_map_content.position.y = maxf(_map_content.position.y - scroll_step, max_scroll)
				queue_redraw()
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_map_content.position.y = minf(_map_content.position.y + scroll_step, 0.0)
				queue_redraw()
				accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	var ke := event as InputEventKey
	if ke.keycode == KEY_E and ke.ctrl_pressed and ke.shift_pressed and ke.alt_pressed:
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file("res://scenes/LevelEditor.tscn")
		return
	if ke.keycode == KEY_D and ke.ctrl_pressed and ke.shift_pressed and ke.alt_pressed:
		get_viewport().set_input_as_handled()
		_on_toggle_debug_mode()
		return
	if ke.keycode == KEY_D and ke.ctrl_pressed and ke.alt_pressed:
		get_viewport().set_input_as_handled()
		_on_toggle_debug_mode()
		return
	if not OS.is_debug_build():
		return
	if ke.keycode == KEY_D and ke.ctrl_pressed:
		get_viewport().set_input_as_handled()
		_on_dev_unlock()


func _on_toggle_debug_mode() -> void:
	GameState.set_debug_mode(not GameState.debug_mode)
	if GameState.debug_mode:
		_on_dev_unlock()   # every level open and playable while poking around in debug mode
	else:
		_refresh_all_cards()


func _on_debug_mode_changed(_enabled: bool) -> void:
	_refresh_all_cards()
	_update_debug_section_visibility()


func _on_dev_unlock() -> void:
	var all_ids: Array = []
	for ld in _levels_data.get("levels", []):
		all_ids.append((ld as Dictionary)["id"] as String)
	GameState.dev_unlock_all(all_ids)
	_refresh_all_cards()
	if not _selected.is_empty():
		_select_level(_selected)


func _on_funds_changed(_amount: int) -> void:
	_update_top_bar_counters()
	_refresh_all_cards()
	if not _selected.is_empty():
		_select_level(_selected)


# ── Block headers ────────────────────────────────────────────────────────────
func _build_block_headers() -> void:
	var blocks: Array = _levels_data.get("blocks", [])
	if blocks.is_empty():
		return
	# Find the first level of each block to get its row
	var block_rows: Dictionary = {}  # block_id (int) -> row (int)
	for ld in _levels_data.get("levels", []):
		var b := (ld as Dictionary).get("block", 1) as int
		var r := (ld as Dictionary).get("map_row", 0) as int
		if b not in block_rows or r < block_rows[b]:
			block_rows[b] = r

	var cell_h := float(CARD_H + V_PAD * 2)
	for blk in blocks:
		var bid  := (blk as Dictionary).get("id",   1) as int
		var blk_name := (blk as Dictionary).get("name", "") as String
		var sub  := (blk as Dictionary).get("subtitle", "") as String
		if bid == 0 or bid == 1:
			continue  # no header before the first visible blocks
		if bid not in block_rows:
			continue
		var row := block_rows[bid] as int
		var y   := V_PAD * 0.5 + row * cell_h - 18.0

		var hdr := Label.new()
		hdr.text = ("BLOQUE %d  —  %s" % [bid, blk_name.to_upper()]) + ("  ·  " + sub if sub != "" else "")
		hdr.position = Vector2(H_PAD, y)
		hdr.size     = Vector2(MAP_W - H_PAD * 2, 16)
		hdr.add_theme_font_size_override("font_size", 9)
		# Color from block data
		var hex: String = (blk as Dictionary).get("color", "#3870A0")
		var col := Color(hex)
		hdr.add_theme_color_override("font_color", col.lightened(0.3))
		hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_map_content.add_child(hdr)

		# Thin divider line above header
		var line := ColorRect.new()
		line.color    = Color(col.r, col.g, col.b, 0.35)
		line.position = Vector2(H_PAD, y - 4.0)
		line.size     = Vector2(MAP_W - H_PAD * 2, 1)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_map_content.add_child(line)


# ── Blueprint grid (drawn on root canvas) ────────────────────────────────────
func _draw() -> void:
	var minor := Color(0.15, 0.20, 0.30, 0.18)
	var major := Color(0.20, 0.28, 0.42, 0.35)
	for x in range(0, 1281, 20):
		draw_line(Vector2(x, 0), Vector2(x, 720), major if x % 100 == 0 else minor, 1.0)
	for y in range(0, 721, 20):
		draw_line(Vector2(0, y), Vector2(1280, y), major if y % 100 == 0 else minor, 1.0)

	# District region outlines — account for scroll offset
	var scroll_y := _map_content.position.y if _map_content else 0.0
	var dist_bounds: Dictionary = {}
	var cw := (MAP_W - H_PAD * 2) / float(COLS)
	var ch := float(CARD_H + V_PAD * 2)

	for ld in _levels_data.get("levels", []):
		var district := (ld as Dictionary).get("district", "") as String
		var col := (ld as Dictionary).get("map_col", 0) as int
		var row := (ld as Dictionary).get("map_row", 0) as int
		var r := Rect2(
			Vector2(H_PAD + col * cw, TOP_H + V_PAD + row * ch + scroll_y),
			Vector2(cw, ch)
		)
		if district not in dist_bounds:
			dist_bounds[district] = r
		else:
			dist_bounds[district] = (dist_bounds[district] as Rect2).merge(r)

	for district in dist_bounds:
		var r   := (dist_bounds[district] as Rect2).grow(-6)
		var dc  := DISTRICT_COLORS.get(district, Color(0.5, 0.5, 0.5, 1.0)) as Color
		var tc  := Color(dc.r * 0.50, dc.g * 0.50, dc.b * 0.50, 0.06)
		var bc  := Color(dc.r * 0.60, dc.g * 0.60, dc.b * 0.60, 0.38)
		draw_rect(r, tc, true)
		draw_rect(r, bc, false, 1.0)
		draw_string(ThemeDB.fallback_font,
			r.position + Vector2(7, 13),
			district.to_upper(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 8,
			Color(bc.r * 1.6, bc.g * 1.6, bc.b * 1.6, 0.75))


# ── Debug section (dev-only sandbox levels) ─────────────────────────────────

func _build_debug_section() -> void:
	var debug_levels: Array = []
	for ld in _levels_data.get("levels", []):
		if _is_debug_level(ld as Dictionary):
			debug_levels.append(ld)
	if debug_levels.is_empty():
		return
	var sy := _debug_section_y()

	_debug_section_line = ColorRect.new()
	_debug_section_line.color         = Color(0.55, 0.32, 0.20, 0.35)
	_debug_section_line.position      = Vector2(H_PAD, sy + 6.0)
	_debug_section_line.size          = Vector2(MAP_W - H_PAD * 2, 1)
	_debug_section_line.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(_debug_section_line)

	_debug_section_hdr = Label.new()
	_debug_section_hdr.text          = "DEBUG LEVELS  (Ctrl+Shift+Alt+D)"
	_debug_section_hdr.position      = Vector2(H_PAD, sy + 10.0)
	_debug_section_hdr.size          = Vector2(MAP_W - H_PAD * 2, 16)
	_debug_section_hdr.add_theme_font_size_override("font_size", 9)
	_debug_section_hdr.add_theme_color_override("font_color", Color(0.85, 0.58, 0.38, 0.85))
	_debug_section_hdr.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(_debug_section_hdr)

	for i in range(debug_levels.size()):
		var ld := debug_levels[i] as Dictionary
		var card := _create_card(ld)
		card.position = _debug_card_xy(i)
		_cards[ld["id"]] = card

	_update_debug_section_visibility()


func _update_debug_section_visibility() -> void:
	var v := GameState.debug_mode
	if is_instance_valid(_debug_section_line):
		_debug_section_line.visible = v
	if is_instance_valid(_debug_section_hdr):
		_debug_section_hdr.visible = v


# ── My Levels (custom / player-created) ──────────────────────────────────────

func _load_custom_levels() -> void:
	_custom_levels.clear()
	if not DirAccess.dir_exists_absolute("user://custom_levels"):
		DirAccess.make_dir_absolute("user://custom_levels")
		return
	var dir := DirAccess.open("user://custom_levels")
	if not dir:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var ld := _load_json("user://custom_levels/" + fname)
			if not ld.is_empty():
				ld["_path"] = "user://custom_levels/" + fname
				_custom_levels.append(ld)
		fname = dir.get_next()
	dir.list_dir_end()


func _build_custom_section() -> void:
	var sy := _custom_section_y()

	var line := ColorRect.new()
	line.color    = Color(0.28, 0.48, 0.36, 0.35)
	line.position = Vector2(H_PAD, sy + 6.0)
	line.size     = Vector2(MAP_W - H_PAD * 2, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(line)

	var hdr := Label.new()
	hdr.text = "MY LEVELS"
	hdr.position = Vector2(H_PAD, sy + 10.0)
	hdr.size     = Vector2(MAP_W - H_PAD * 2, 16)
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", Color(0.38, 0.70, 0.50, 0.85))
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(hdr)

	for i in range(_custom_levels.size()):
		_create_custom_card(i, _custom_levels[i] as Dictionary)
	_create_new_level_card(_custom_levels.size())


func _create_custom_card(index: int, ld: Dictionary) -> void:
	var pos  := _custom_card_xy(index)
	var card := Button.new()
	card.position            = pos
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size                = Vector2(CARD_W, CARD_H)
	card.mouse_filter        = Control.MOUSE_FILTER_STOP

	var sn := StyleBoxFlat.new()
	sn.bg_color     = Color(0.10, 0.16, 0.13)
	sn.border_color = Color(0.28, 0.52, 0.38, 0.65)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(3)
	card.add_theme_stylebox_override("normal", sn)
	var sh := sn.duplicate() as StyleBoxFlat
	sh.border_color = Color(0.38, 0.80, 0.54)
	sh.set_border_width_all(2)
	card.add_theme_stylebox_override("hover",   sh)
	card.add_theme_stylebox_override("pressed", sh)

	var vb := VBoxContainer.new()
	vb.position = Vector2(7, 7)
	vb.size     = Vector2(CARD_W - 14, CARD_H - 14)
	vb.add_theme_constant_override("separation", 3)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	var nm := Label.new()
	nm.text              = ld.get("name", "Unnamed") as String
	nm.autowrap_mode     = TextServer.AUTOWRAP_WORD_SMART
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color", Color(0.38, 0.80, 0.54))
	vb.add_child(nm)

	var badge := Label.new()
	badge.text = "CUSTOM"
	badge.add_theme_font_size_override("font_size", 8)
	badge.add_theme_color_override("font_color", Color(0.28, 0.55, 0.40, 0.70))
	vb.add_child(badge)

	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sp.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	vb.add_child(sp)

	var budget := ld.get("starting_budget", 0) as int
	if budget > 0:
		var bl := Label.new()
		bl.text = "%d€" % budget
		bl.add_theme_font_size_override("font_size", 10)
		bl.add_theme_color_override("font_color", Color(0.28, 0.55, 0.40, 0.70))
		vb.add_child(bl)

	card.pressed.connect(_select_custom_level.bind(ld))
	_map_content.add_child(card)


func _create_new_level_card(index: int) -> void:
	var pos  := _custom_card_xy(index)
	var card := Button.new()
	card.position            = pos
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.size                = Vector2(CARD_W, CARD_H)
	card.mouse_filter        = Control.MOUSE_FILTER_STOP

	var sn := StyleBoxFlat.new()
	sn.bg_color     = Color(0.09, 0.12, 0.10)
	sn.border_color = Color(0.22, 0.44, 0.32, 0.45)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(3)
	card.add_theme_stylebox_override("normal", sn)
	var sh := sn.duplicate() as StyleBoxFlat
	sh.border_color = Color(0.32, 0.68, 0.48)
	sh.set_border_width_all(2)
	card.add_theme_stylebox_override("hover",   sh)
	card.add_theme_stylebox_override("pressed", sh)

	var plus := Label.new()
	plus.text                    = "＋"
	plus.horizontal_alignment    = HORIZONTAL_ALIGNMENT_CENTER
	plus.vertical_alignment      = VERTICAL_ALIGNMENT_CENTER
	plus.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plus.offset_bottom           = -22
	plus.add_theme_font_size_override("font_size", 26)
	plus.add_theme_color_override("font_color", Color(0.26, 0.52, 0.38, 0.65))
	plus.mouse_filter            = Control.MOUSE_FILTER_IGNORE
	card.add_child(plus)

	var lbl := Label.new()
	lbl.text                  = "New Level"
	lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchor(SIDE_TOP,    1.0)
	lbl.set_anchor(SIDE_RIGHT,  1.0)
	lbl.set_anchor(SIDE_BOTTOM, 1.0)
	lbl.offset_top    = -22
	lbl.offset_bottom = -6
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", Color(0.26, 0.52, 0.38, 0.65))
	lbl.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	card.add_child(lbl)

	card.pressed.connect(func():
		get_tree().change_scene_to_file("res://scenes/LevelEditor.tscn"))
	_map_content.add_child(card)


func _select_custom_level(ld: Dictionary) -> void:
	_selected             = {}
	_selected_is_custom   = true
	_selected_custom_data = ld

	_info_title.text    = ld.get("name", "Unnamed Level") as String
	_info_district.text = "Custom Level  ·  " + _sqm_label(ld)

	var tenant := ld.get("tenant", {}) as Dictionary
	if tenant.is_empty():
		_info_tenant.text = "No tenant defined"
	else:
		_info_tenant.text = "%s, %d\n\"%s\"" % [
			tenant.get("name", "?"), tenant.get("age", 0),
			tenant.get("bio", "")
		]

	var funcs := tenant.get("required_functions", []) as Array
	_info_reqs.text   = ("Requires: " + ", ".join(funcs)) if not funcs.is_empty() else ""
	_info_budget.text = "Budget: %d€" % ld.get("starting_budget", 0)
	_info_rent.text   = ""
	_info_cost.text   = ""

	_action_btn.text     = "PLAY →"
	_action_btn.disabled = false
