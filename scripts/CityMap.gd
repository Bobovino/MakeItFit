extends Control
class_name CityMap

# ── Layout constants ────────────────────────────────────────────────────────
const MAP_W    := 860
const INFO_W   := 419   # info sidebar width (design px); anchored to the window's right edge
const TOP_H    := 54
const H_PAD    := 24.0
const V_PAD    := 16.0
const COLS     := 5
const ROWS     := 9   # total rows in the grid (row 0 = tutorials, rows 1+ = regular levels)
const CARD_W   := 142
const CARD_H   := 108
const MAP_VISIBLE_H := 666.0   # 720 - TOP_H
const SCROLLBAR_W := 14.0

# ── Archivador (vertical list) layout ───────────────────────────────────────
# Each level is a single full-width row now instead of a grid card — reads as
# a folder of expedientes, one line per project, grouped under a block header.
const ROW_H       := 40.0
const ROW_GAP     := 6.0
const HEADER_H    := 28.0
const SECTION_GAP := 16.0   # extra breathing room after each block's last row

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

var _map_content: Control = null
var _map_clip:    Control = null
var _scrollbar:   VScrollBar = null
var _content_h:   float = 0.0   # total height of the currently-built list (debug + real, in whatever order is active)
var _list_w:      float = MAP_W # actual list width in px — the clip's real width, not the MAP_W design constant, so rows/headers fill whatever room the window actually gives them instead of leaving a gap before the scrollbar on wider windows

var _custom_levels:       Array      = []
var _selected_is_custom:  bool       = false
var _selected_custom_data: Dictionary = {}

# Info panel widgets
var _info_title:    Label
var _info_district: Label
var _info_tenant:   Label
var _info_reqs:     Label
var _info_budget:   Label
var _info_rent:     Label
var _info_cost:     Label
var _action_btn:    Button
var _redesign_btn:  Button   # only shown alongside _action_btn when the selected level has a saved layout to fall back to
var _funds_label:   Label
var _stars_label:   Label


func _ready() -> void:
	_levels_data = _load_json("res://data/levels.json")
	_build_ui()
	_rebuild_levels_ui()
	GameState.company_funds_changed.connect(_on_funds_changed)
	get_viewport().size_changed.connect(_on_viewport_resized)
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


# ── Total scroll height ──────────────────────────────────────────────────────
func _map_total_h() -> float:
	return _content_h


# Scroll floor in runtime clip coordinates — recomputed from the clip's actual
# height so it stays correct at any window size (the const MAP_VISIBLE_H only
# held at the 720-design layout).
func _max_scroll() -> float:
	var clip_h := _map_clip.size.y if _map_clip else MAP_VISIBLE_H
	return minf(-(_map_total_h() - clip_h), 0.0)


# Re-clamp the scroll when the window changes size, so shrinking never leaves
# the content stranded past the new bottom.
func _on_viewport_resized() -> void:
	# Full rebuild (not just re-clamping scroll) since row/header widths are
	# derived from the clip's actual size — a resize can genuinely change
	# _list_w, and a stale width is exactly what left a gap before the
	# scrollbar on windows wider than the original 1280 design width.
	if _map_content:
		_rebuild_levels_ui()


# Keeps the visual scrollbar in lockstep with _map_content's actual scroll
# offset/range — called after anything that can change either (rebuilds,
# window resize, mouse-wheel scroll).
func _update_scrollbar() -> void:
	if not _scrollbar or not _map_clip:
		return
	var clip_h := _map_clip.size.y
	_scrollbar.max_value = maxf(_content_h, clip_h)
	_scrollbar.page       = clip_h
	_scrollbar.visible    = _content_h > clip_h
	_scrollbar.set_value_no_signal(-_map_content.position.y)


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


# Kept only for the dead-but-not-deleted "My Levels" custom-level section
# below (_build_custom_section is never called from _ready(), so this whole
# section is presently inert) — still needs to resolve at parse time.
func _custom_section_y() -> float:
	return _map_total_h()


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

	# Top bar — spans the map area only; the info sidebar owns the right edge,
	# so the filter buttons never slide underneath it on wide windows.
	var top_pc := PanelContainer.new()
	top_pc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_pc.offset_right = -(INFO_W + 1)
	top_pc.custom_minimum_size = Vector2(0, TOP_H)
	var ts := StyleBoxFlat.new()
	ts.bg_color     = Color(0.115, 0.100, 0.085, 0.98)
	ts.border_color = Color(0.320, 0.270, 0.205)
	ts.set_border_width(SIDE_BOTTOM, 1)
	ts.set_content_margin_all(8)
	top_pc.add_theme_stylebox_override("panel", ts)
	add_child(top_pc)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 14)
	top_pc.add_child(top_row)

	var title_lbl := Label.new()
	title_lbl.text = "PROJECTS"
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

	_update_top_bar_counters()

	# Clipped map viewport — cards scroll within this. Anchored to fill all
	# space left of the info sidebar (minus a strip for the scrollbar) so
	# wider windows show more map, not a dead strip.
	_map_clip = Control.new()
	_map_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_clip.offset_top    = TOP_H
	_map_clip.offset_right  = -(INFO_W + 1 + SCROLLBAR_W)
	_map_clip.clip_contents = true
	add_child(_map_clip)
	var map_clip := _map_clip

	_map_content = Control.new()
	_map_content.position = Vector2.ZERO
	map_clip.add_child(_map_content)

	# Visible scrollbar, in the strip reserved between the map and the divider —
	# mouse-wheel scrolling (see _gui_input) keeps it in sync, and dragging it
	# directly moves _map_content the same way.
	_scrollbar = VScrollBar.new()
	_scrollbar.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_scrollbar.offset_left  = -(INFO_W + 1 + SCROLLBAR_W)
	_scrollbar.offset_right = -(INFO_W + 1)
	_scrollbar.offset_top   = TOP_H
	_scrollbar.offset_bottom = 0
	_scrollbar.min_value = 0
	_scrollbar.value_changed.connect(func(v: float):
		_map_content.position.y = -v
		queue_redraw())
	add_child(_scrollbar)

	# Vertical divider before info panel — hugs the sidebar's left edge
	var div := ColorRect.new()
	div.color = Color(0.290, 0.245, 0.190)
	div.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	div.offset_left  = -(INFO_W + 1)
	div.offset_right = -INFO_W
	add_child(div)

	# Info panel — anchored to the window's right edge at a fixed width
	var ip := PanelContainer.new()
	ip.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	ip.offset_left = -INFO_W
	var ip_s := StyleBoxFlat.new()
	ip_s.bg_color = Color(0.115, 0.100, 0.085)
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
	sep1.add_theme_color_override("color", Color(0.290, 0.245, 0.190))
	vb.add_child(sep1)

	_info_tenant = _make_info_label(vb, 11, GameTheme.C_TEXT, true)
	_info_reqs   = _make_info_label(vb, 11, GameTheme.C_MUTED)
	_info_budget = _make_info_label(vb, 12, GameTheme.C_TEXT)
	_info_rent   = _make_info_label(vb, 15, Color(0.50, 0.78, 0.60))

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("color", Color(0.290, 0.245, 0.190))
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

	# Second entry point shown only for levels that already have a saved
	# layout (i.e. won at least once) — lets the player start over from
	# scratch instead of reopening the layout they won with.
	_redesign_btn = Button.new()
	_redesign_btn.text = "Rediseñar desde Cero"
	_redesign_btn.custom_minimum_size = Vector2(210, 32)
	_redesign_btn.add_theme_font_size_override("font_size", 11)
	_redesign_btn.visible = false
	_redesign_btn.pressed.connect(_on_redesign_pressed)
	vb.add_child(_redesign_btn)

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

	var quit_btn := Button.new()
	quit_btn.text = "⏻ Quit to Desktop"
	quit_btn.add_theme_font_size_override("font_size", 12)
	quit_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	quit_btn.pressed.connect(func(): get_tree().quit())
	vb.add_child(quit_btn)


func _make_info_label(parent: VBoxContainer, font_size: int, col: Color, autowrap: bool = false) -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	if autowrap:
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(lbl)
	return lbl


# ── Archivador rebuild ───────────────────────────────────────────────────────
# Clears and rebuilds the whole scrollable list from scratch. Needed (rather
# than just toggling row visibility) because debug mode changes WHERE the
# debug section sits — first when active, per the "put it up front while
# poking around" request — which means every real level's row also has to
# shift down, not just show/hide.
func _rebuild_levels_ui() -> void:
	for ch in _map_content.get_children():
		ch.queue_free()
	_cards.clear()

	_list_w = _map_clip.size.x if _map_clip and _map_clip.size.x > 0.0 else float(MAP_W)

	var y := V_PAD
	if GameState.debug_mode:
		y = _build_debug_section(y)
	y = _build_levels_list(y)

	_content_h = y
	_map_content.size = Vector2(_list_w, _content_h)
	_map_content.position.y = clampf(_map_content.position.y, _max_scroll(), 0.0)
	_update_scrollbar()
	queue_redraw()


# Lays out every non-debug level as a full-width row, grouped under a header
# per block (in the order blocks are authored in levels.json), starting at y.
# Returns the y position immediately after the last row.
func _build_levels_list(start_y: float) -> float:
	var y := start_y
	var levels: Array = _levels_data.get("levels", [])
	for blk in _levels_data.get("blocks", []):
		var bd  := blk as Dictionary
		var bid := bd.get("id", 0) as int
		var block_levels: Array = []
		for ld in levels:
			var d := ld as Dictionary
			if _is_debug_level(d):
				continue
			if (d.get("block", 1) as int) == bid:
				block_levels.append(d)
		if block_levels.is_empty():
			continue

		var hex := bd.get("color", "#3870A0") as String
		y = _add_section_header(y,
			"BLOQUE %d — %s" % [bid, (bd.get("name", "") as String).to_upper()],
			bd.get("subtitle", "") as String,
			Color(hex))

		for ld in block_levels:
			var row := _create_row(ld as Dictionary)
			row.position = Vector2(H_PAD, y)
			_cards[(ld as Dictionary)["id"]] = row
			_fill_row(row, ld as Dictionary)
			y += ROW_H + ROW_GAP
		y += SECTION_GAP
	return y


# Thin colored rule + label, same look the old grid's block headers used —
# now every block (including Tutorial/Aprendizaje) gets one, since a plain
# list has no background-color district cue to lean on instead.
func _add_section_header(y: float, title: String, subtitle: String, col: Color) -> float:
	var line := ColorRect.new()
	line.color = Color(col.r, col.g, col.b, 0.35)
	line.position = Vector2(H_PAD, y)
	line.size = Vector2(_list_w - H_PAD * 2, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(line)

	var hdr := Label.new()
	hdr.text = title + ("  ·  " + subtitle if subtitle != "" else "")
	hdr.position = Vector2(H_PAD, y + 6.0)
	hdr.size     = Vector2(_list_w - H_PAD * 2, 16)
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", col.lightened(0.3))
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(hdr)

	return y + HEADER_H


# ── Row creation ─────────────────────────────────────────────────────────────
func _create_row(ld: Dictionary) -> Button:
	var row := Button.new()
	row.custom_minimum_size = Vector2(_list_w - H_PAD * 2, ROW_H)
	row.size = Vector2(_list_w - H_PAD * 2, ROW_H)
	row.mouse_filter = Control.MOUSE_FILTER_STOP

	var sn := StyleBoxFlat.new()
	sn.bg_color     = Color(0.165, 0.145, 0.120)
	sn.border_color = Color(0.320, 0.270, 0.205)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(5)
	sn.set_content_margin(SIDE_LEFT,  12)
	sn.set_content_margin(SIDE_RIGHT, 12)
	sn.anti_aliasing = true
	row.add_theme_stylebox_override("normal", sn)

	var sh := sn.duplicate() as StyleBoxFlat
	sh.border_color = GameTheme.C_AMBER
	sh.set_border_width_all(2)
	row.add_theme_stylebox_override("hover", sh)
	row.add_theme_stylebox_override("pressed", sh)

	row.pressed.connect(_select_level.bind(ld))
	_map_content.add_child(row)
	return row


# ── Row content refresh ──────────────────────────────────────────────────────
func _refresh_all_cards() -> void:
	for ld in _levels_data.get("levels", []):
		var lid := (ld as Dictionary)["id"] as String
		var row := _cards.get(lid) as Button
		if row:
			_fill_row(row, ld as Dictionary)


func _fill_row(row: Button, ld: Dictionary) -> void:
	var district := ld.get("district", "Wedding") as String
	# Debug/dev-only sandbox levels (loft mechanics, sloped ceilings, balcony
	# rendering, etc.) are clutter for a real player, so they stay hidden
	# until debug mode is on.
	row.visible = not _is_debug_level(ld) or GameState.debug_mode
	if not row.visible:
		return

	for ch in row.get_children():
		ch.queue_free()

	var lid       := ld["id"] as String
	var is_owned  := GameState.is_owned(lid)
	var cost      := ld.get("acquisition_cost", 0) as int
	var min_stars := ld.get("min_stars", 0) as int
	var level_visible := GameState.total_stars() >= min_stars
	var can_buy   := GameState.company_funds >= cost
	var stars     := GameState.get_stars(lid)
	var dist_col  := DISTRICT_COLORS.get(district, Color(0.4, 0.4, 0.4, 1.0)) as Color

	var sn := row.get_theme_stylebox("normal") as StyleBoxFlat
	if sn:
		if not level_visible:
			sn.bg_color = Color(0.08, 0.09, 0.11)
			sn.border_color = Color(0.200, 0.175, 0.145)
		elif is_owned:
			sn.bg_color     = Color(dist_col.r * 0.22 + 0.06, dist_col.g * 0.22 + 0.07, dist_col.b * 0.22 + 0.09)
			sn.border_color = Color(dist_col.r * 0.70 + 0.10, dist_col.g * 0.70 + 0.10, dist_col.b * 0.70 + 0.10, 0.80)
		elif can_buy:
			sn.bg_color     = Color(0.165, 0.145, 0.120)
			sn.border_color = Color(0.320, 0.270, 0.205)
		else:
			sn.bg_color     = Color(0.110, 0.098, 0.085)
			sn.border_color = Color(0.16, 0.20, 0.25)

	# A manually-added child Control ignores the row's own stylebox content
	# margins (those only apply to the Button's own internal text/icon), so
	# without matching insets here the right-hand status label sits flush
	# against the row's edge with no breathing room.
	var hb := HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.offset_left  = 12
	hb.offset_right = -12
	hb.add_theme_constant_override("separation", 10)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	# [X] / [ ] / locked checkbox glyph, leftmost — the "expediente" marker
	var chk := Label.new()
	chk.custom_minimum_size = Vector2(20, 0)
	chk.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	chk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if not level_visible:
		chk.text = "🔒"
		chk.add_theme_font_size_override("font_size", 12)
		chk.add_theme_color_override("font_color", Color(0.34, 0.38, 0.44))
	elif stars > 0:
		chk.text = "✓"
		chk.add_theme_font_size_override("font_size", 15)
		chk.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60))
	else:
		chk.text = "○"
		chk.add_theme_font_size_override("font_size", 13)
		chk.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hb.add_child(chk)

	if not level_visible:
		var lbl := Label.new()
		lbl.text = "%s   —   Necesita %d ★ para desbloquear" % [ld["name"] as String, min_stars]
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.34, 0.38, 0.44))
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(lbl)
		return

	var name_vb := VBoxContainer.new()
	name_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_vb.add_theme_constant_override("separation", 0)
	# hb stretches this to the row's full height, but VBoxContainer top-aligns
	# its own children by default — that pinned the title flush against the
	# row's top edge with no breathing room above it. Center the name+subtitle
	# block vertically instead.
	name_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_child(name_vb)

	var tenant := ld.get("tenant", {}) as Dictionary
	var nm := Label.new()
	nm.text = "%s  —  %s" % [ld["name"] as String, tenant.get("name", "") as String]
	nm.add_theme_font_size_override("font_size", 12)
	nm.add_theme_color_override("font_color", GameTheme.C_AMBER if is_owned else GameTheme.C_TEXT)
	name_vb.add_child(nm)

	# District tag (or TUTORIAL badge), as a small subtitle under the name
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
	name_vb.add_child(dt)

	# Right-aligned status: stars / [DISPONIBLE] / price
	if stars > 0:
		var sl := Label.new()
		sl.text = "★".repeat(stars) + "☆".repeat(3 - stars)
		sl.add_theme_font_size_override("font_size", 14)
		sl.add_theme_color_override("font_color", GameTheme.C_AMBER)
		hb.add_child(sl)
	elif is_owned:
		var rl := Label.new()
		rl.text = "[DISPONIBLE]"
		rl.add_theme_font_size_override("font_size", 10)
		rl.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60))
		hb.add_child(rl)
	else:
		var cl := Label.new()
		cl.text = ("%d€" if can_buy else "🔒 %d€") % cost
		cl.add_theme_font_size_override("font_size", 11)
		cl.add_theme_color_override("font_color", Color(0.50, 0.78, 0.60) if can_buy else GameTheme.C_MUTED)
		hb.add_child(cl)



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
	var flavor := tenant.get("flavor", "") as String
	var flavor_line := "\n\"%s\"" % flavor if flavor != "" else ""
	_info_tenant.text = "%s, %d%s%s" % [
		tenant.get("name", "?"), int(str(tenant.get("age", 0))),
		flavor_line,
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
		_redesign_btn.visible = false
	elif is_owned:
		var reward := ld.get("funds_base_reward", 0) as int
		_info_cost.text    = "Reward: ~%d€ Studio Funds" % reward
		if stars > 0 and GameState.has_level_layout(lid):
			# Already won at least once — default to reopening it exactly as
			# left, with "start over" as an explicit secondary choice rather
			# than the only option.
			_action_btn.text   = "Revisar Plano Actual"
			_action_btn.disabled = false
			_redesign_btn.visible = true
			_redesign_btn.disabled = false
		else:
			_action_btn.text   = "ENTER  →"
			_action_btn.disabled = false
			_redesign_btn.visible = false
	else:
		_info_cost.text    = "Acquisition: %d€ Studio Funds" % cost
		_action_btn.text   = "BUY — %d€" % cost
		_action_btn.disabled = not can_buy
		_redesign_btn.visible = false


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
		_funds_label.text = "Studio Funds: %d€" % GameState.company_funds


# ── Signals ──────────────────────────────────────────────────────────────────
func _on_action_pressed() -> void:
	if _selected_is_custom:
		Audio.play("click")
		GameState.custom_level_data = _selected_custom_data
		GameState.pending_level_id  = "_custom"
		GameState.own_level("_custom")
		Transition.change_scene("res://scenes/Main.tscn")
		return
	if _selected.is_empty():
		return
	var lid     := _selected["id"] as String
	var is_owned := GameState.is_owned(lid)

	if is_owned:
		Audio.play("click")
		GameState.pending_level_id = lid
		# _action_btn doubles as "Revisar Plano Actual" once the level has a
		# saved layout (see _select_level) — reopen it as-is in that case,
		# otherwise this is a first-time "ENTER" and there's nothing to reopen.
		GameState.pending_use_saved_layout = \
			GameState.get_stars(lid) > 0 and GameState.has_level_layout(lid)
		Transition.change_scene("res://scenes/Main.tscn")
	else:
		var cost := _selected.get("acquisition_cost", 0) as int
		if GameState.buy_level(lid, cost):
			Audio.play("success")
			_fill_row(_cards[lid] as Button, _selected)
			_select_level(_selected)
		else:
			Audio.play("error")


# Secondary entry point, only visible for levels with a saved layout — always
# starts from the level's original starting_furniture, discarding nothing
# (the saved layout itself is untouched, so "Revisar Plano Actual" still
# works afterwards).
func _on_redesign_pressed() -> void:
	if _selected.is_empty():
		return
	var lid := _selected["id"] as String
	if not GameState.is_owned(lid):
		return
	Audio.play("click")
	GameState.pending_level_id = lid
	GameState.pending_use_saved_layout = false
	Transition.change_scene("res://scenes/Main.tscn")


func _gui_input(event: InputEvent) -> void:
	if not _map_content:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.position.x < _map_clip.size.x:
			var scroll_step := 60.0
			var max_scroll  := _max_scroll()
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_map_content.position.y = maxf(_map_content.position.y - scroll_step, max_scroll)
				_update_scrollbar()
				queue_redraw()
				accept_event()
			elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_map_content.position.y = minf(_map_content.position.y + scroll_step, 0.0)
				_update_scrollbar()
				queue_redraw()
				accept_event()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and (event as InputEventKey).pressed):
		return
	var ke := event as InputEventKey
	if ke.keycode == KEY_E and ke.ctrl_pressed and ke.shift_pressed and ke.alt_pressed:
		get_viewport().set_input_as_handled()
		Transition.change_scene("res://scenes/LevelEditor.tscn")
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
	# Debug rows need to move to the front of the list (or back out of it
	# entirely) rather than just show/hide, so this fully rebuilds the list —
	# see _rebuild_levels_ui.
	_rebuild_levels_ui()
	_refresh_all_cards()


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


# ── Blueprint grid (drawn on root canvas) ────────────────────────────────────
# District tinting used to be drawn here as background rectangles behind the
# card grid — in list mode each row already carries its district as a text
# tag and each block already gets its own colored header rule, so that
# overlay (which relied on the old map_col/map_row grid coordinates) is gone;
# only the blueprint graph-paper backdrop remains.
func _draw() -> void:
	var minor := Color(0.15, 0.20, 0.30, 0.18)
	var major := Color(0.20, 0.28, 0.42, 0.35)
	var vw := int(size.x) + 1
	var vh := int(size.y) + 1
	for x in range(0, vw, 20):
		draw_line(Vector2(x, 0), Vector2(x, vh), major if x % 100 == 0 else minor, 1.0)
	for y in range(0, vh, 20):
		draw_line(Vector2(0, y), Vector2(vw, y), major if y % 100 == 0 else minor, 1.0)


# ── Debug section (dev-only sandbox levels) ─────────────────────────────────
# Placed at the very front of the list while debug mode is on (see
# _rebuild_levels_ui), under its own "DEBUG LEVELS" header — only ever called
# while debug_mode is on, so the rows are built plainly visible; the whole
# section is simply torn down again the moment debug mode goes back off.
func _build_debug_section(start_y: float) -> float:
	var debug_levels: Array = []
	for ld in _levels_data.get("levels", []):
		if _is_debug_level(ld as Dictionary):
			debug_levels.append(ld)
	if debug_levels.is_empty():
		return start_y

	var y := _add_section_header(start_y,
		"DEBUG LEVELS  (Ctrl+Shift+Alt+D)", "",
		Color(0.85, 0.58, 0.38))

	for ld in debug_levels:
		var d := ld as Dictionary
		var row := _create_row(d)
		row.position = Vector2(H_PAD, y)
		_cards[d["id"]] = row
		_fill_row(row, d)
		y += ROW_H + ROW_GAP

	return y + SECTION_GAP


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
		Transition.change_scene("res://scenes/LevelEditor.tscn"))
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
		var flavor := tenant.get("flavor", "") as String
		var flavor_line := "\n\"%s\"" % flavor if flavor != "" else ""
		_info_tenant.text = "%s, %d%s" % [
			tenant.get("name", "?"), tenant.get("age", 0),
			flavor_line
		]

	var funcs := tenant.get("required_functions", []) as Array
	_info_reqs.text   = ("Requires: " + ", ".join(funcs)) if not funcs.is_empty() else ""
	_info_budget.text = "Budget: %d€" % ld.get("starting_budget", 0)
	_info_rent.text   = ""
	_info_cost.text   = ""

	_action_btn.text     = "PLAY →"
	_action_btn.disabled = false
	_redesign_btn.visible = false
