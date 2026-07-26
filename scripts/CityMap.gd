extends Control
class_name CityMap

const TenantMiiScript := preload("res://scripts/TenantMii.gd")

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
const PAPER_MARGIN := 18.0   # thickness of the kraft-paper band framing the blueprint sheet — keep
							  # this small: it eats directly into the grid's usable width, and wider
							  # values silently drop a whole manzana column (verified: 34px only fit 1)

# ── City map (parcels) layout ───────────────────────────────────────────────
# Each district is a "block" — a big tinted terrain rect containing that
# district's levels laid out as small rectangular building parcels, one per
# fixed-size grid cell. Locked/owned/starred state is shown directly on the
# parcel instead of in a text row.
const PARCEL_MAX_W   := 150.0   # also the fixed cell width every grid slot uses
const PARCEL_MAX_H   := 120.0   # also the fixed cell height every grid slot uses
const BLOCK_PAD      := 14.0
const BLOCK_HEADER_H := 20.0
const MANZANA_CELL_GAP := 3.0   # thin property line between the 2 cells inside one manzana — small enough that the 4 items still read as one block, not four separate cards
const ROAD_W            := 26.0 # road width between manzanas, both across and down

# ── Archivador (filing-cabinet tabs) ─────────────────────────────────────────
# One vertical tab per game "block" (progression chapter), along the left
# edge — clicking a tab shows just that block's own neighborhood map instead
# of scrolling through every block stacked on one continuous page.
const TAB_W   := 92.0
const TAB_H   := 64.0
const TAB_GAP := 4.0

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
var _furniture_catalog: Dictionary = {}   # furniture id → its data (size, color, ...), for the blueprint preview
var _selected: Dictionary = {}
var _cards: Dictionary = {}      # level_id → Button
var _selected_card: Button = null   # whichever card last got the "selected" outline — see _select_level/_set_card_selected

var _map_content: Control = null
var _map_clip:    Control = null
var _page_tint:   ColorRect = null
var _scrollbar:   VScrollBar = null
var _content_h:   float = 0.0   # total height of the currently-built list (debug + real, in whatever order is active)
var _list_w:      float = MAP_W # actual list width in px — the clip's real width, not the MAP_W design constant, so rows/headers fill whatever room the window actually gives them instead of leaving a gap before the scrollbar on wider windows

var _tabs_col:         Control    = null
var _tab_buttons:      Dictionary = {}   # block id (int, -1 = debug) → Button
var _current_block_id: int        = -2   # -2 = "not chosen yet", -1 = debug pseudo-block

var _custom_levels:       Array      = []
var _selected_is_custom:  bool       = false
var _selected_custom_data: Dictionary = {}

const BlueprintPreviewScript := preload("res://scripts/BlueprintPreview.gd")

# Info panel widgets
var _info_title:    Label
var _info_district: Label
var _blueprint_preview   # untyped: BlueprintPreview.gd isn't referenced by class name (avoids relying on the global script class cache), so calls to its set_data() go through dynamic dispatch
var _tenant_portrait:   TextureRect
var _portrait_viewport: SubViewport = null
var _portrait_mii:      Node3D     = null   # a real TenantMii, recolored per-tenant — same face the 3D win showcase uses
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
	_load_furniture_catalog()
	_build_ui()
	_rebuild_tabs()
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


func _load_furniture_catalog() -> void:
	var data := _load_json("res://data/furniture.json")
	for f in data.get("furniture", []) as Array:
		var fd := f as Dictionary
		_furniture_catalog[fd.get("id", "") as String] = fd


# Starting furniture as simple tile-space rects for the blueprint preview —
# size/color looked up from the same catalog the real shop uses, so the
# preview's furniture always matches what the shop would actually place.
func _furniture_preview_rects(ld: Dictionary) -> Array:
	var out: Array = []
	for sf in ld.get("starting_furniture", []) as Array:
		var s := sf as Dictionary
		var fdata: Dictionary = _furniture_catalog.get(s.get("id", "") as String, {})
		if fdata.is_empty():
			continue
		var sz := fdata.get("size", {}) as Dictionary
		out.append({
			"x": s.get("x", 0) as float, "y": s.get("y", 0) as float,
			"w": float(sz.get("w", 4) as int), "h": float(sz.get("h", 4) as int),
			"color": Color("#" + (fdata.get("color", "888888") as String)),
		})
	return out


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
	# No opaque full-screen background here on purpose — the root _draw()
	# below paints a solid base fill *and* the blueprint grid, and every
	# other panel (tabs, top bar, info sidebar) draws its own opaque
	# background over its own region. That leaves the map viewport as the
	# only area where the blueprint grid actually shows through, which is
	# the point — an opaque bg previously painted here covered the grid
	# completely, so it never actually rendered anywhere.

	# Archivador tab rail — full-height strip along the left edge, one tab per
	# game block, populated by _rebuild_tabs(). Everything else (top bar, map
	# viewport) starts at TAB_W instead of the window's left edge.
	_tabs_col = Control.new()
	_tabs_col.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_tabs_col.offset_right = TAB_W
	add_child(_tabs_col)

	var tabs_bg := ColorRect.new()
	tabs_bg.color = GameTheme.C_BG
	tabs_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tabs_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tabs_bg.draw.connect(_draw_wood_grain.bind(tabs_bg))
	_tabs_col.add_child(tabs_bg)

	_tabs_col.z_index = 2

	# Top bar — spans the map area only; the info sidebar owns the right edge,
	# so the filter buttons never slide underneath it on wide windows.
	var top_pc := PanelContainer.new()
	top_pc.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_pc.offset_left  = TAB_W
	top_pc.offset_right = -(INFO_W + 1)
	top_pc.custom_minimum_size = Vector2(0, TOP_H)
	var ts := StyleBoxFlat.new()
	ts.bg_color     = GameTheme.C_BG2
	ts.border_color = GameTheme.C_BORDER
	ts.set_border_width(SIDE_BOTTOM, 1)
	ts.set_content_margin_all(8)
	# A real drop shadow, not just the 1px border — the desk/blueprint area
	# sits underneath and is added later (drawn on top of tree order), so
	# this needs z_index to actually show instead of being painted over.
	ts.shadow_color  = Color(0, 0, 0, 0.35)
	ts.shadow_size   = 8
	ts.shadow_offset = Vector2(0, 3)
	top_pc.add_theme_stylebox_override("panel", ts)
	top_pc.z_index = 2
	top_pc.draw.connect(_draw_wood_grain.bind(top_pc))
	add_child(top_pc)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 14)
	top_pc.add_child(top_row)

	# Same tiny floor-plan motif as MainMenu's title — ties this screen back
	# to the same brand mark instead of "PROJECTS" being a bare text label.
	var motif := Control.new()
	motif.custom_minimum_size = Vector2(26, 26)
	motif.mouse_filter = Control.MOUSE_FILTER_IGNORE
	motif.draw.connect(_draw_title_motif.bind(motif))
	top_row.add_child(motif)

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

	# Compass + scale legend, printed in the top bar like a map's own legend —
	# simplest reliable placement (no anchor-math edge cases), always visible.
	var legend_sep := VSeparator.new()
	top_row.add_child(legend_sep)
	var legend := Label.new()
	legend.text = "▲ N   ├── 5 m ──┤"
	legend.add_theme_font_size_override("font_size", 11)
	legend.add_theme_color_override("font_color", Color(0.55, 0.68, 0.80, 0.65))
	top_row.add_child(legend)

	# The OUTSIDE reads as a thick stack of kraft/off-white paper resting on
	# the desk (a couple of duller sheets peeking out at the corners, plus a
	# soft shadow stack underneath) — the INSIDE (_map_clip) is the actual
	# blueprint: pure saturated cyanotype blue, clipped and framed like a
	# sheet pinned on top of that paper stack.
	for corner_off in [Vector2(-8, 8), Vector2(-4, 4)]:
		var peek := Panel.new()
		peek.set_anchors_preset(Control.PRESET_FULL_RECT)
		peek.offset_left   = TAB_W + corner_off.x
		peek.offset_top    = TOP_H
		peek.offset_right  = -(INFO_W + 1 + SCROLLBAR_W)
		peek.offset_bottom = corner_off.y
		peek.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var peek_sn := StyleBoxFlat.new()
		peek_sn.bg_color = GameTheme.C_PAPER.darkened(0.12 if corner_off.x < -6 else 0.06)
		peek.add_theme_stylebox_override("panel", peek_sn)
		add_child(peek)

	var table_bg := Panel.new()
	table_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	table_bg.offset_left  = TAB_W
	table_bg.offset_top   = TOP_H
	table_bg.offset_right = -(INFO_W + 1 + SCROLLBAR_W)
	table_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var table_sn := StyleBoxFlat.new()
	table_sn.bg_color = GameTheme.C_PAPER   # thick kraft/off-white sheet
	table_sn.border_color = GameTheme.C_BORDER
	table_sn.set_border_width_all(1)
	table_bg.add_theme_stylebox_override("panel", table_sn)
	add_child(table_bg)

	# Paper grain — a scatter of tiny specks over the kraft sheet so it reads
	# as an actual textured material instead of a flat color fill. Purely
	# decorative, drawn once at build time (not per-frame), sized to the
	# table's own rect.
	var grain := Control.new()
	grain.set_anchors_preset(Control.PRESET_FULL_RECT)
	grain.offset_left  = TAB_W
	grain.offset_top   = TOP_H
	grain.offset_right = -(INFO_W + 1 + SCROLLBAR_W)
	grain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grain.draw.connect(_draw_paper_grain.bind(grain))
	add_child(grain)

	# Clipped map viewport — cards scroll within this. Inset from the paper
	# background by PAPER_MARGIN, and anchored to fill all space left of the
	# info sidebar (minus a strip for the scrollbar) so wider windows show
	# more map, not a dead strip.
	_map_clip = Control.new()
	_map_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_clip.offset_left   = TAB_W + PAPER_MARGIN
	_map_clip.offset_top    = TOP_H + PAPER_MARGIN
	_map_clip.offset_right  = -(INFO_W + 1 + SCROLLBAR_W + PAPER_MARGIN)
	_map_clip.offset_bottom = -PAPER_MARGIN
	_map_clip.clip_contents = true
	add_child(_map_clip)
	var map_clip := _map_clip

	# The blueprint sheet's own fill — noticeably brighter/more saturated than
	# GameTheme.BP_PAPER (the real floor-plan editor's color, left untouched
	# here on purpose). At BP_PAPER's actual value this whole page read as
	# dark gray rather than blue once the grain/shadows/dimmed decorations
	# added on top of it all stacked up — this is CityMap's own map-only fill,
	# not the shared constant, so brightening it here can't affect that editor.
	var blueprint_fill := ColorRect.new()
	blueprint_fill.color = Color(0.11, 0.24, 0.40)
	blueprint_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blueprint_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_clip.add_child(blueprint_fill)

	# Fine drafting grid on top of the fill — the opaque fill above replaced
	# the grid that used to show through from the root _draw(), so it's
	# redrawn explicitly here, sized to the sheet instead of the whole window.
	var grid_lines := Control.new()
	grid_lines.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grid_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid_lines.draw.connect(_draw_blueprint_grid.bind(grid_lines))
	map_clip.add_child(grid_lines)

	# A per-district color wash used to live here, translucent over the whole
	# map — removed, it read as a dark film sitting over the entire
	# blueprint rather than a subtle per-tab tint. _page_tint stays null;
	# _update_page_tint() below already no-ops when it is.

	# Thin ink frame — the blueprint sheet reads as pinned/clipped onto the
	# paper stack beneath it, not just a color change.
	var clip_frame := Panel.new()
	clip_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	clip_frame.offset_left   = TAB_W + PAPER_MARGIN
	clip_frame.offset_top    = TOP_H + PAPER_MARGIN
	clip_frame.offset_right  = -(INFO_W + 1 + SCROLLBAR_W + PAPER_MARGIN)
	clip_frame.offset_bottom = -PAPER_MARGIN
	clip_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame_sn := StyleBoxFlat.new()
	frame_sn.bg_color = Color(0, 0, 0, 0)
	frame_sn.border_color = Color(GameTheme.BP_INK.r, GameTheme.BP_INK.g, GameTheme.BP_INK.b, 0.55)
	frame_sn.set_border_width_all(2)
	clip_frame.add_theme_stylebox_override("panel", frame_sn)
	add_child(clip_frame)

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
	div.color = GameTheme.C_BORDER
	div.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	div.offset_left  = -(INFO_W + 1)
	div.offset_right = -INFO_W
	add_child(div)

	# Info panel — anchored to the window's right edge at a fixed width
	var ip := PanelContainer.new()
	ip.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	ip.offset_left = -INFO_W
	var ip_s := StyleBoxFlat.new()
	ip_s.bg_color = GameTheme.C_BG2
	ip_s.set_content_margin(SIDE_LEFT,   22)
	ip_s.set_content_margin(SIDE_RIGHT,  22)
	ip_s.set_content_margin(SIDE_TOP,    60)
	ip_s.set_content_margin(SIDE_BOTTOM, 24)
	ip_s.shadow_color  = Color(0, 0, 0, 0.35)
	ip_s.shadow_size   = 10
	ip_s.shadow_offset = Vector2(-3, 0)
	ip.add_theme_stylebox_override("panel", ip_s)
	ip.z_index = 2
	ip.draw.connect(_draw_wood_grain.bind(ip))
	add_child(ip)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	ip.add_child(vb)

	_info_title = _make_info_label(vb, 18, GameTheme.C_AMBER, true)
	_info_district = _make_info_label(vb, 11, GameTheme.C_MUTED)

	# Blueprint preview — the level's actual wall segments, drawn as a small
	# top-down sketch, so you can see the real apartment shape before
	# committing to it instead of just reading a size number. Framed like a
	# pinned photo/plan (border + shadow) instead of floating loose against
	# the sidebar's flat background.
	var preview_frame := PanelContainer.new()
	var pf_sn := StyleBoxFlat.new()
	pf_sn.bg_color = Color(0, 0, 0, 0)
	pf_sn.border_color = GameTheme.C_BORDER
	pf_sn.set_border_width_all(3)
	pf_sn.set_corner_radius_all(2)
	pf_sn.shadow_color  = Color(0, 0, 0, 0.4)
	pf_sn.shadow_size   = 6
	pf_sn.shadow_offset = Vector2(2, 3)
	pf_sn.set_content_margin_all(0)
	preview_frame.add_theme_stylebox_override("panel", pf_sn)
	vb.add_child(preview_frame)

	_blueprint_preview = BlueprintPreviewScript.new()
	_blueprint_preview.custom_minimum_size = Vector2(0, 130)
	preview_frame.add_child(_blueprint_preview)

	var sep1 := HSeparator.new()
	sep1.add_theme_color_override("color", GameTheme.C_BORDER)
	vb.add_child(sep1)

	# Tenant row: the real 3D Mii's face (rendered offscreen, see
	# _setup_portrait_viewport), tinted the same hash-derived color as the
	# post-win 3D showcase, so it's recognizably the same person — not a
	# separate flat icon style.
	var tenant_row := HBoxContainer.new()
	tenant_row.add_theme_constant_override("separation", 10)
	vb.add_child(tenant_row)

	# Same pinned-photo framing as the blueprint preview — a bare 64x64
	# texture floating in a row read as an icon, not a portrait.
	var portrait_frame := PanelContainer.new()
	var por_sn := StyleBoxFlat.new()
	por_sn.bg_color = Color(0, 0, 0, 0)
	por_sn.border_color = GameTheme.C_BORDER
	por_sn.set_border_width_all(2)
	por_sn.set_corner_radius_all(2)
	por_sn.shadow_color  = Color(0, 0, 0, 0.4)
	por_sn.shadow_size   = 5
	por_sn.shadow_offset = Vector2(2, 2)
	por_sn.set_content_margin_all(0)
	portrait_frame.add_theme_stylebox_override("panel", por_sn)
	tenant_row.add_child(portrait_frame)

	_tenant_portrait = TextureRect.new()
	_tenant_portrait.custom_minimum_size = Vector2(64, 64)
	_tenant_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_frame.add_child(_tenant_portrait)
	_setup_portrait_viewport()

	_info_tenant = Label.new()
	_info_tenant.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_tenant.add_theme_font_size_override("font_size", 11)
	_info_tenant.add_theme_color_override("font_color", GameTheme.C_TEXT)
	_info_tenant.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tenant_row.add_child(_info_tenant)

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
	_action_btn.draw.connect(_draw_sheen.bind(_action_btn))
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
	_redesign_btn.draw.connect(_draw_sheen.bind(_redesign_btn))
	vb.add_child(_redesign_btn)

	# Bottom spacer pushes the secondary buttons to the bottom of the panel
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(push)

	var sep3 := HSeparator.new()
	sep3.add_theme_color_override("color", Color(0.16, 0.20, 0.26))
	vb.add_child(sep3)

	# Same blueprint-label tag style as MainMenu's secondary actions — bare
	# text links here read as a plain settings list, not part of the same
	# desk/tag visual language everything else on this page now uses.
	var settings_btn := Button.new()
	settings_btn.text = "⚙ Settings"
	settings_btn.add_theme_font_size_override("font_size", 12)
	settings_btn.add_theme_color_override("font_color", GameTheme.C_TEXT)
	var settings_ts := GameTheme.make_tag_btn_style()
	settings_btn.add_theme_stylebox_override("normal",  settings_ts[0])
	settings_btn.add_theme_stylebox_override("hover",   settings_ts[1])
	settings_btn.add_theme_stylebox_override("pressed", settings_ts[2])
	settings_btn.pressed.connect(func(): SettingsMenu.open(self))
	vb.add_child(settings_btn)

	var quit_btn := Button.new()
	quit_btn.text = "⏻ Quit to Desktop"
	quit_btn.add_theme_font_size_override("font_size", 12)
	quit_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	var quit_ts := GameTheme.make_tag_btn_style()
	quit_btn.add_theme_stylebox_override("normal",  quit_ts[0])
	quit_btn.add_theme_stylebox_override("hover",   quit_ts[1])
	quit_btn.add_theme_stylebox_override("pressed", quit_ts[2])
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


# Offscreen render of a real TenantMii — same model, same outline shader,
# same happy face as the post-win 3D showcase — cropped tight on the head so
# it reads as a portrait. Built once; _update_portrait() just recolors and
# re-frames the existing Mii instead of rebuilding per-selection.
func _setup_portrait_viewport() -> void:
	_portrait_viewport = SubViewport.new()
	_portrait_viewport.size = Vector2i(128, 128)
	_portrait_viewport.transparent_bg = true
	_portrait_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_portrait_viewport)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.83, 0.42)
	cam.fov = 35.0
	_portrait_viewport.add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 35, 0)
	light.light_energy = 1.2
	_portrait_viewport.add_child(light)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	env_node.environment = env
	_portrait_viewport.add_child(env_node)

	_portrait_mii = TenantMiiScript.new()
	_portrait_viewport.add_child(_portrait_mii)
	_portrait_mii.set_process(false)   # static portrait — no idle bounce needed here

	_tenant_portrait.texture = _portrait_viewport.get_texture()


func _update_portrait(tenant_name: String) -> void:
	if not is_instance_valid(_portrait_mii):
		return
	var hue := float(tenant_name.hash() % 360) / 360.0
	_portrait_mii.set_tint(Color.from_hsv(hue, 0.55, 0.85))


# ── Archivador tabs ──────────────────────────────────────────────────────────
# Rebuilds the vertical tab rail — called on ready and whenever debug mode
# toggles (the DEBUG tab only exists while it's on). Picks a default active
# tab the first time (or if the active one just disappeared).
func _rebuild_tabs() -> void:
	for ch in _tabs_col.get_children():
		ch.queue_free()
	_tab_buttons.clear()

	var y := TOP_H + 10.0
	for blk in _levels_data.get("blocks", []):
		var bd  := blk as Dictionary
		var bid := bd.get("id", 0) as int
		if not _block_has_levels(bid):
			continue
		var tab := _create_tab_button((bd.get("name", "") as String), Color(bd.get("color", "#3870A0") as String), bid)
		tab.position = Vector2(0, y)
		_tabs_col.add_child(tab)
		_tab_buttons[bid] = tab
		y += TAB_H + TAB_GAP

	if GameState.debug_mode:
		var dtab := _create_tab_button("Debug", Color(0.85, 0.58, 0.38), -1)
		dtab.position = Vector2(0, y)
		_tabs_col.add_child(dtab)
		_tab_buttons[-1] = dtab
		y += TAB_H + TAB_GAP

	if not _tab_buttons.has(_current_block_id):
		_current_block_id = -2
	if _current_block_id == -2:
		for blk in _levels_data.get("blocks", []):
			var bid := (blk as Dictionary).get("id", 0) as int
			if _tab_buttons.has(bid):
				_current_block_id = bid
				break
	_update_tab_styles()


func _block_has_levels(bid: int) -> bool:
	for ld in _levels_data.get("levels", []):
		var d := ld as Dictionary
		if not _is_debug_level(d) and (d.get("block", 1) as int) == bid:
			return true
	return false


func _find_block(bid: int) -> Dictionary:
	for blk in _levels_data.get("blocks", []):
		if (blk as Dictionary).get("id", 0) as int == bid:
			return blk as Dictionary
	return {}


# A folder tab sticking out from the left edge — flat left side (flush with
# the rail), rounded right side, colored by district. The active tab is
# pushed further right and fully bright (see _update_tab_styles) so it reads
# as "pulled forward," same as a real filing-cabinet tab.
# One glyph per progression chapter — plain text labels alone read as a
# generic settings list; a small icon per tab gives the rail its own
# identity at a glance, same as a real game's chapter-select tabs.
# Plain BMP symbols only — SpaceGrotesk (this game's global fallback font)
# has no color-emoji glyphs, so the pictographs tried here first (🎓🛋🏢...)
# rendered as empty tofu boxes. These are the same glyphs already proven to
# render correctly elsewhere in this game (Settings/Undo/Redo/stars).
const BLOCK_ICONS := {
	0: "★", 1: "⚙", 2: "▲", 3: "↺", 4: "⏻", 5: "!", -1: "•",
}

func _create_tab_button(label_text: String, col: Color, bid: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(TAB_W, TAB_H)
	btn.size = Vector2(TAB_W, TAB_H)
	# Icon and label share one line instead of the icon getting its own row —
	# a 2-word label ("LOFTS Y ESPACIOS") already wraps to 2 lines on its
	# own, and stacking the icon above it as a 3rd line overflowed TAB_H,
	# clipping the bottom of the button.
	btn.text = "%s  %s" % [BLOCK_ICONS.get(bid, "▪"), label_text.to_upper()]
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	btn.add_theme_font_size_override("font_size", 10)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	btn.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))

	var sn := StyleBoxFlat.new()
	sn.bg_color = col.darkened(0.35)
	sn.border_color = col
	sn.set_border_width_all(1)
	sn.corner_radius_top_right = 8
	sn.corner_radius_bottom_right = 8
	sn.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", sn)

	var sh := sn.duplicate() as StyleBoxFlat
	sh.bg_color = col.darkened(0.15)
	btn.add_theme_stylebox_override("hover", sh)
	btn.add_theme_stylebox_override("pressed", sh)

	btn.pressed.connect(_on_tab_pressed.bind(bid))
	btn.draw.connect(_draw_sheen.bind(btn))
	return btn


func _on_tab_pressed(bid: int) -> void:
	if bid == _current_block_id:
		return
	Audio.play("click")
	_current_block_id = bid
	_update_tab_styles()
	_rebuild_levels_ui()


func _update_tab_styles() -> void:
	for bid in _tab_buttons:
		var btn: Button = _tab_buttons[bid]
		var active: bool = bid == _current_block_id
		btn.position.x = 8.0 if active else 0.0
		btn.modulate = Color(1, 1, 1, 1)


# Tints the whole page a translucent wash of the active tab's district
# color — the blueprint grid drawn on the root canvas still shows through
# underneath (this is well below full opacity), but each tab now visibly
# reads as its own colored dossier sheet instead of every tab looking the
# same dark neutral page.
func _update_page_tint() -> void:
	if not _page_tint:
		return
	var col := Color(0.85, 0.58, 0.38) if _current_block_id == -1 else \
		Color(_find_block(_current_block_id).get("color", "#3870A0") as String)
	_page_tint.color = Color(col.r, col.g, col.b, 0.16)


# ── Archivador rebuild ───────────────────────────────────────────────────────
# Clears and rebuilds just the currently-active tab's own map — clicking a
# different tab shows a completely different neighborhood instead of
# scrolling through every block stacked on one continuous page.
func _rebuild_levels_ui() -> void:
	for ch in _map_content.get_children():
		ch.queue_free()
	_cards.clear()
	_selected_card = null   # the button it pointed to is one of the freed children above

	_list_w = _map_clip.size.x if _map_clip and _map_clip.size.x > 0.0 else float(MAP_W)
	_update_page_tint()

	var y := V_PAD
	if _current_block_id == -1:
		y = _build_debug_section(y)
	else:
		var bd := _find_block(_current_block_id)
		if not bd.is_empty():
			var block_levels: Array = []
			for ld in _levels_data.get("levels", []):
				var d := ld as Dictionary
				if _is_debug_level(d):
					continue
				if (d.get("block", 1) as int) == _current_block_id:
					block_levels.append(d)
			if not block_levels.is_empty():
				y = _build_district_block(y, bd, block_levels)

	_content_h = y
	_map_content.size = Vector2(_list_w, _content_h)
	_map_content.position.y = clampf(_map_content.position.y, _max_scroll(), 0.0)
	_update_scrollbar()
	queue_redraw()


# ── Decorations ──────────────────────────────────────────────────────────────
# Non-clickable filler items (parks, lakes, monuments, ...) inserted directly
# into the same wrap-flow grid as real apartment parcels — not confined to
# leftover space — so the map reads as a mixed neighborhood instead of a
# building lot for every single square. Kept in the same flat-shape style as
# real parcels (no organic polygons — that made things unreadable last time);
# their own muted color palette (park green, plaza tan, ...) versus real
# apartments' amber is what makes it obvious they're not clickable.
const DECORATION_TYPES := ["park", "lake", "plaza", "monument", "church", "fountain", "parking", "sports", "cemetery", "building"]
const DECOR_LABELS := {
	"park": "Park", "lake": "Lake", "plaza": "Plaza", "monument": "Monument",
	"church": "Church", "fountain": "Fountain", "parking": "Parking",
	"sports": "Sports Field", "cemetery": "Cemetery", "building": "Building",
	"roundabout": "Roundabout",
}
const BLOCK_DECOR_THEMES := {
	0: ["building", "plaza"],
	1: ["park", "monument", "church"],
	2: ["park", "lake"],
	3: ["monument", "plaza", "building"],
	4: ["parking", "building", "fountain"],
	5: ["church", "monument", "cemetery"],
}


# Mostly draws from the district's own theme (keeps each tab feeling
# distinct) but sometimes pulls from the full type list, so a theme with
# only 2-3 entries doesn't repeat the exact same two icons for an entire page.
func _pick_decor_type(pool: Array, rng: RandomNumberGenerator) -> String:
	var source: Array = pool if rng.randf() < 0.65 else DECORATION_TYPES
	return source[rng.randi() % source.size()]


const DECOR_INK := Color(0.88, 0.92, 0.96, 0.95)   # bright blueprint-ink accent used for every symbol detail

func _create_decoration(kind: String, dsize: Vector2) -> Control:
	var root := Control.new()
	root.custom_minimum_size = dsize
	root.size = dsize
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.clip_contents = true   # symbol details (hatch lines, ripples, ...) must not bleed into neighboring cells
	# No opacity dimming — decorations cover roughly half the grid, so any
	# alpha reduction here read as "the whole map is dark," not "these tiles
	# aren't clickable." The amber real-apartment fill already does that job
	# by itself; decorations stay at full color/opacity now.

	match kind:
		"park":
			_decor_base(root, Color(0.16, 0.34, 0.20), Color(0.28, 0.52, 0.32))
			var rng := RandomNumberGenerator.new()
			rng.seed = int(dsize.x * 13.0 + dsize.y * 7.0)
			for i in range(3):
				var tx := rng.randf_range(8.0, dsize.x - 8.0)
				var ty := rng.randf_range(10.0, dsize.y - 6.0)
				var trunk := ColorRect.new()
				trunk.color = Color(0.45, 0.34, 0.22)
				trunk.size = Vector2(1.5, 5)
				trunk.position = Vector2(tx - 0.75, ty)
				trunk.mouse_filter = Control.MOUSE_FILTER_IGNORE
				root.add_child(trunk)
				var canopy := _decor_dot(Color(0.38, 0.68, 0.42), 4.0)
				canopy.position = Vector2(tx, ty) - Vector2(4, 8)
				root.add_child(canopy)
		"lake":
			_decor_base(root, Color(0.14, 0.30, 0.48), Color(0.30, 0.56, 0.76), 18)
			for i in range(2):
				var ripple := Line2D.new()
				var ry := dsize.y * (0.4 + i * 0.22)
				ripple.points = PackedVector2Array([
					Vector2(dsize.x * 0.2, ry), Vector2(dsize.x * 0.4, ry - 3.0),
					Vector2(dsize.x * 0.6, ry), Vector2(dsize.x * 0.8, ry - 3.0),
				])
				ripple.width = 1.2
				ripple.default_color = Color(0.55, 0.78, 0.92, 0.7)
				root.add_child(ripple)
		"plaza":
			_decor_base(root, Color(0.38, 0.36, 0.30), Color(0.55, 0.52, 0.44))
			var pv := ColorRect.new()
			pv.color = DECOR_INK
			pv.size = Vector2(1.0, dsize.y * 0.7)
			pv.position = Vector2(dsize.x * 0.5 - 0.5, dsize.y * 0.15)
			pv.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(pv)
			var ph_ := ColorRect.new()
			ph_.color = DECOR_INK
			ph_.size = Vector2(dsize.x * 0.7, 1.0)
			ph_.position = Vector2(dsize.x * 0.15, dsize.y * 0.5 - 0.5)
			ph_.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(ph_)
			var center := _decor_dot(DECOR_INK, 3.0)
			center.position = dsize * 0.5 - Vector2(3, 3)
			root.add_child(center)
		"monument":
			_decor_base(root, Color(0.26, 0.26, 0.29), Color(0.44, 0.44, 0.48))
			var obelisk := Line2D.new()
			obelisk.points = PackedVector2Array([
				Vector2(dsize.x * 0.5 - 3.0, dsize.y * 0.75), Vector2(dsize.x * 0.5, dsize.y * 0.15),
				Vector2(dsize.x * 0.5 + 3.0, dsize.y * 0.75),
			])
			obelisk.width = 1.6
			obelisk.default_color = DECOR_INK
			obelisk.closed = false
			root.add_child(obelisk)
			var base := ColorRect.new()
			base.color = DECOR_INK
			base.size = Vector2(dsize.x * 0.4, 3)
			base.position = Vector2(dsize.x * 0.3, dsize.y * 0.75)
			base.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(base)
		"church":
			_decor_base(root, Color(0.30, 0.28, 0.24), Color(0.50, 0.47, 0.40))
			var nave := ColorRect.new()
			nave.color = Color(0, 0, 0, 0)
			nave.size = Vector2(dsize.x * 0.5, dsize.y * 0.4)
			nave.position = Vector2(dsize.x * 0.25, dsize.y * 0.5)
			var nsn := StyleBoxFlat.new()
			nsn.bg_color = Color(0, 0, 0, 0)
			nsn.border_color = DECOR_INK
			nsn.set_border_width_all(1)
			nave.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(nave)
			for pts in [
				PackedVector2Array([Vector2(dsize.x * 0.5, dsize.y * 0.12), Vector2(dsize.x * 0.22, dsize.y * 0.5)]),
				PackedVector2Array([Vector2(dsize.x * 0.5, dsize.y * 0.12), Vector2(dsize.x * 0.78, dsize.y * 0.5)]),
			]:
				var roof := Line2D.new()
				roof.points = pts
				roof.width = 2.0
				roof.default_color = DECOR_INK
				root.add_child(roof)
			var cross_v := ColorRect.new()
			cross_v.color = DECOR_INK
			cross_v.size = Vector2(1.6, 8)
			cross_v.position = Vector2(dsize.x * 0.5 - 0.8, 0)
			cross_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(cross_v)
			var cross_h := ColorRect.new()
			cross_h.color = DECOR_INK
			cross_h.size = Vector2(6, 1.6)
			cross_h.position = Vector2(dsize.x * 0.5 - 3.0, 2.5)
			cross_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(cross_h)
		"fountain":
			_decor_base(root, Color(0.28, 0.28, 0.30), Color(0.46, 0.46, 0.48))
			var r := minf(dsize.x, dsize.y) * 0.26
			var ring := Panel.new()
			ring.size = Vector2(r, r) * 2.0
			ring.position = dsize * 0.5 - Vector2(r, r)
			ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var rsn := StyleBoxFlat.new()
			rsn.bg_color = Color(0, 0, 0, 0)
			rsn.border_color = Color(0.45, 0.66, 0.82)
			rsn.set_border_width_all(1)
			rsn.set_corner_radius_all(int(r))
			ring.add_theme_stylebox_override("panel", rsn)
			root.add_child(ring)
			var mid := _decor_dot(Color(0.45, 0.68, 0.85), r * 0.4)
			mid.position = dsize * 0.5 - Vector2(r, r) * 0.4
			root.add_child(mid)
			for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
				var tick := Line2D.new()
				var c := dsize * 0.5
				tick.points = PackedVector2Array([c + dir * r, c + dir * (r + 3.0)])
				tick.width = 1.2
				tick.default_color = Color(0.45, 0.66, 0.82)
				root.add_child(tick)
		"parking":
			_decor_base(root, Color(0.22, 0.22, 0.22), Color(0.38, 0.38, 0.38))
			var stripe_gap := 9.0
			var sx := stripe_gap
			while sx < dsize.x - 2.0:
				var stripe := ColorRect.new()
				stripe.color = Color(0.85, 0.85, 0.85, 0.75)
				stripe.size = Vector2(1.2, dsize.y * 0.8)
				stripe.position = Vector2(sx, dsize.y * 0.1)
				stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
				root.add_child(stripe)
				sx += stripe_gap
		"sports":
			_decor_base(root, Color(0.16, 0.34, 0.20), Color(0.85, 0.90, 0.85))
			var track := Panel.new()
			track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			track.offset_left = 3; track.offset_top = 3
			track.offset_right = -3; track.offset_bottom = -3
			track.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var tsn := StyleBoxFlat.new()
			tsn.bg_color = Color(0, 0, 0, 0)
			tsn.border_color = DECOR_INK
			tsn.set_border_width_all(1)
			tsn.set_corner_radius_all(int(minf(dsize.x, dsize.y) * 0.4))
			track.add_theme_stylebox_override("panel", tsn)
			root.add_child(track)
			var mid := ColorRect.new()
			mid.color = Color(0.85, 0.90, 0.85, 0.7)
			mid.size = Vector2(dsize.x * 0.8, 1.2)
			mid.position = Vector2(dsize.x * 0.1, dsize.y * 0.5 - 0.6)
			mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
			root.add_child(mid)
			var ctr := _decor_dot(Color(0, 0, 0, 0), minf(dsize.x, dsize.y) * 0.15)
			ctr.position = dsize * 0.5 - Vector2(1, 1) * minf(dsize.x, dsize.y) * 0.15
			var ctr_sn := StyleBoxFlat.new()
			ctr_sn.bg_color = Color(0, 0, 0, 0)
			ctr_sn.border_color = DECOR_INK
			ctr_sn.set_border_width_all(1)
			ctr_sn.set_corner_radius_all(int(minf(dsize.x, dsize.y) * 0.15))
			ctr.add_theme_stylebox_override("panel", ctr_sn)
			root.add_child(ctr)
		"cemetery":
			_decor_base(root, Color(0.24, 0.24, 0.22), Color(0.38, 0.38, 0.36))
			for r in range(2):
				for c in range(3):
					var cx := dsize.x * float(c + 1) / 4.0
					var cy := dsize.y * float(r + 1) / 3.0
					var v := ColorRect.new()
					v.color = Color(0.62, 0.60, 0.55, 0.85)
					v.size = Vector2(1.2, 6)
					v.position = Vector2(cx - 0.6, cy - 3)
					v.mouse_filter = Control.MOUSE_FILTER_IGNORE
					root.add_child(v)
					var h := ColorRect.new()
					h.color = Color(0.62, 0.60, 0.55, 0.85)
					h.size = Vector2(4, 1.2)
					h.position = Vector2(cx - 2, cy - 1.5)
					h.mouse_filter = Control.MOUSE_FILTER_IGNORE
					root.add_child(h)
		"roundabout":
			_decor_base(root, Color(0.20, 0.36, 0.22), Color(0.85, 0.90, 0.85), int(minf(dsize.x, dsize.y) * 0.5))
			var ring := Panel.new()
			var rr := minf(dsize.x, dsize.y) * 0.28
			ring.size = Vector2(rr, rr) * 2.0
			ring.position = dsize * 0.5 - Vector2(rr, rr)
			ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var rsn2 := StyleBoxFlat.new()
			rsn2.bg_color = Color(0, 0, 0, 0)
			rsn2.border_color = DECOR_INK
			rsn2.set_border_width_all(1)
			rsn2.set_corner_radius_all(int(rr))
			ring.add_theme_stylebox_override("panel", rsn2)
			root.add_child(ring)
		_:   # "building" — generic non-playable filler: diagonal hatch, same
			 # convention real architectural blueprints use for solid/existing
			 # structure that isn't meant to be edited.
			_decor_base(root, Color(0.22, 0.22, 0.24), Color(0.38, 0.38, 0.42))
			var step := 8.0
			var hx := -dsize.y
			while hx < dsize.x:
				var hatch := Line2D.new()
				hatch.points = PackedVector2Array([
					Vector2(hx, dsize.y), Vector2(hx + dsize.y, 0),
				])
				hatch.width = 1.0
				hatch.default_color = Color(0.42, 0.42, 0.46, 0.7)
				root.add_child(hatch)
				hx += step

	# A small caption naming the type — icons alone turned out too abstract to
	# reliably read at this scale, so the label is what actually guarantees
	# you can tell a plaza from a monument, not just the symbol.
	if dsize.y >= 24.0:
		var cap := Label.new()
		cap.text = DECOR_LABELS.get(kind, kind.capitalize())
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		cap.offset_top = -12
		cap.offset_bottom = -1
		# Hand-lettered like a real drafter's margin note instead of the
		# game's normal UI type — a small, cheap way to make the page read as
		# designed rather than every label sharing one generic body font.
		var hand := GameTheme.handwriting()
		if hand:
			cap.add_theme_font_override("font", hand)
			cap.add_theme_font_size_override("font_size", 13)
		else:
			cap.add_theme_font_size_override("font_size", 8)
		cap.add_theme_color_override("font_color", Color(0.90, 0.93, 0.97, 0.9))
		cap.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		cap.add_theme_constant_override("shadow_offset_x", 1)
		cap.add_theme_constant_override("shadow_offset_y", 1)
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(cap)

	return root


# A blueprint is a cyanotype: one blue sheet, everything drawn on it in
# white ink. The per-decoration fills passed in used to include near-black
# grays (0.14/0.22/0.26...) that, sitting on the blue map, read as dead dark
# patches — the "darkening" that kept showing up. Every decoration cell now
# forces its fill to a blue only slightly lighter than the map, carrying
# just a faint tint of its theme color, so nothing on the sheet is ever
# darker than the sheet itself.
const _DECOR_SHEET := Color(0.145, 0.30, 0.47)   # one step lighter than the map fill (0.11,0.24,0.40)

func _decor_base(root: Control, fill: Color, border: Color, corner_radius: int = 2) -> void:
	var p := Panel.new()
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sn := StyleBoxFlat.new()
	# Mostly the blueprint blue, only a quarter of the theme hue mixed in —
	# never the raw (often near-black) fill that was passed in.
	sn.bg_color = _DECOR_SHEET.lerp(fill, 0.25)
	sn.border_color = border.lerp(GameTheme.BP_INK, 0.35)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(corner_radius)
	p.add_theme_stylebox_override("panel", sn)
	root.add_child(p)


func _decor_dot(color: Color, radius: float) -> Control:
	var d := Panel.new()
	d.size = Vector2(radius, radius) * 2.0
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sn := StyleBoxFlat.new()
	sn.bg_color = color
	sn.set_corner_radius_all(int(radius))
	d.add_theme_stylebox_override("panel", sn)
	return d


# A straight road between manzanas, with a dashed centerline, spanning
# `length` px starting at `origin` — horizontal if horizontal=true (origin is
# its left-center point), vertical otherwise (origin is its top-center point).
func _add_road_segment(origin: Vector2, length: float, horizontal: bool) -> void:
	var road := ColorRect.new()
	road.color = Color(0.15, 0.14, 0.12, 0.85)
	road.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if horizontal:
		road.position = Vector2(origin.x, origin.y - ROAD_W * 0.5)
		road.size = Vector2(length, ROAD_W)
	else:
		road.position = Vector2(origin.x - ROAD_W * 0.5, origin.y)
		road.size = Vector2(ROAD_W, length)
	_map_content.add_child(road)

	var dash_len := 10.0
	var gap_len := 8.0
	var t := 0.0
	while t < length:
		var dash := ColorRect.new()
		dash.color = Color(0.62, 0.56, 0.44, 0.6)
		dash.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if horizontal:
			dash.position = Vector2(origin.x + t, origin.y - 1.0)
			dash.size = Vector2(dash_len, 2.0)
		else:
			dash.position = Vector2(origin.x - 1.0, origin.y + t)
			dash.size = Vector2(2.0, dash_len)
		_map_content.add_child(dash)
		t += dash_len + gap_len


# A district "block": a big tinted terrain rect with a street-name header,
# containing that district's levels grouped into fixed 2×2 "manzanas" with
# roads (and roundabouts at intersections) between them — see the placement
# loop below. Cells are fixed-size and items are centered within them, so
# roads always line up straight regardless of each item's real footprint.
func _build_district_block(start_y: float, bd: Dictionary, levels: Array, header_override: String = "") -> float:
	var bid       := bd.get("id", 0) as int
	var col       := Color(bd.get("color", "#3870A0") as String)
	var block_w   := _list_w - H_PAD * 2
	var subtitle  := bd.get("subtitle", "") as String

	var hdr := Label.new()
	hdr.text = header_override if header_override != "" else \
		"BLOQUE %d — %s" % [bid, (bd.get("name", "") as String).to_upper()] + \
		("  ·  " + subtitle if subtitle != "" else "")
	hdr.position = Vector2(H_PAD + BLOCK_PAD, start_y)
	hdr.size     = Vector2(block_w - BLOCK_PAD * 2, 16)
	hdr.add_theme_font_size_override("font_size", 10)
	hdr.add_theme_color_override("font_color", col.lightened(0.45))
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_content.add_child(hdr)

	var content_y := start_y + BLOCK_HEADER_H

	# Items are grouped 4-at-a-time into "manzanas" — a fixed 2×2 grid of
	# cells — with a real road (not just a gap) between one manzana and the
	# next, both across and down the page, and a roundabout at every
	# internal intersection. Cells are fixed-size (PARCEL_MAX_W/H, which
	# every item already fits within) so the road grid lines up perfectly
	# straight instead of needing to track variable-width rows.
	var decor_pool: Array = BLOCK_DECOR_THEMES.get(bid, DECORATION_TYPES)
	var decor_rng := RandomNumberGenerator.new()
	decor_rng.seed = bid * 104729 + 7
	var cell_w := PARCEL_MAX_W
	var cell_h := PARCEL_MAX_H
	var manzana_w := cell_w * 2.0 + MANZANA_CELL_GAP
	var manzana_h := cell_h * 2.0 + MANZANA_CELL_GAP
	var manzana_cols := maxi(1, int((block_w - BLOCK_PAD * 2.0 + ROAD_W) / (manzana_w + ROAD_W)))

	# How many manzana rows it takes to fill the whole visible page — usually
	# far more than the real levels alone would need, since most tabs have
	# only a handful of levels. Figured out BEFORE placing anything, so real
	# levels can be spread evenly across the whole grid instead of all
	# clustering into the first row or two with decorations only appearing
	# after them.
	var target_h := maxf((_map_clip.size.y if _map_clip else 0.0) - content_y - BLOCK_PAD, 0.0)
	var manzana_rows := maxi(1, int(ceil(float(levels.size()) / (4.0 * manzana_cols))))
	while float(manzana_rows) * (manzana_h + ROAD_W) < target_h and manzana_rows < 40:
		manzana_rows += 1
	var total_slots := manzana_rows * manzana_cols * 4

	# Assign each real level an evenly-spaced slot across the whole grid
	# (e.g. 5 levels across 40 slots land roughly every 8th slot) — every
	# other slot is a decoration, so apartments and decorations mix
	# throughout the page instead of "apartments on top, filler below".
	var level_slots: Dictionary = {}   # slot index -> level dict
	if levels.size() > 0:
		var step := float(total_slots) / float(levels.size())
		for i in range(levels.size()):
			var slot_idx := clampi(int(round(float(i) * step)), 0, total_slots - 1)
			while level_slots.has(slot_idx):
				slot_idx = (slot_idx + 1) % total_slots
			level_slots[slot_idx] = levels[i]

	var idx := 0
	for mrow in range(manzana_rows):
		for mcol in range(manzana_cols):
			var manzana_origin := Vector2(
				H_PAD + BLOCK_PAD + mcol * (manzana_w + ROAD_W),
				content_y + mrow * (manzana_h + ROAD_W)
			)
			var slot_offsets := [
				Vector2(0, 0), Vector2(cell_w + MANZANA_CELL_GAP, 0),
				Vector2(0, cell_h + MANZANA_CELL_GAP), Vector2(cell_w + MANZANA_CELL_GAP, cell_h + MANZANA_CELL_GAP),
			]
			for slot_i in range(4):
				var item: Dictionary
				if level_slots.has(idx):
					item = {"kind": "level", "data": level_slots[idx]}
				else:
					item = {"kind": "decor", "type": _pick_decor_type(decor_pool, decor_rng)}
				idx += 1

				# Every item fills its whole cell now — real apartment square
				# footage is still shown in its info panel once selected, but
				# sizing the grid slot to it (and centering the shrunk result)
				# left a visible gap around anything smaller than PARCEL_MAX,
				# which read as "floating cards" instead of one built-up block.
				var pw := cell_w
				var ph := cell_h

				var slot_pos: Vector2 = manzana_origin + (slot_offsets[slot_i] as Vector2)

				if item["kind"] == "level":
					var d := item["data"] as Dictionary
					var parcel := _create_parcel(d)
					parcel.position = slot_pos
					parcel.custom_minimum_size = Vector2(pw, ph)
					parcel.size = Vector2(pw, ph)
					_cards[d["id"]] = parcel
					_fill_parcel(parcel, d)
				else:
					var deco := _create_decoration(item["type"] as String, Vector2(pw, ph))
					deco.position = slot_pos
					_map_content.add_child(deco)

	# Roads between manzanas, and a roundabout at every point a horizontal
	# and a vertical road cross.
	var total_w := manzana_cols * manzana_w + maxi(manzana_cols - 1, 0) * ROAD_W
	var total_h := manzana_rows * manzana_h + maxi(manzana_rows - 1, 0) * ROAD_W
	for mrow2 in range(manzana_rows - 1):
		var ry := content_y + (mrow2 + 1) * manzana_h + mrow2 * ROAD_W + ROAD_W * 0.5
		_add_road_segment(Vector2(H_PAD + BLOCK_PAD, ry), total_w, true)
	for mcol2 in range(manzana_cols - 1):
		var rx := H_PAD + BLOCK_PAD + (mcol2 + 1) * manzana_w + mcol2 * ROAD_W + ROAD_W * 0.5
		_add_road_segment(Vector2(rx, content_y), total_h, false)
	for mrow3 in range(manzana_rows - 1):
		for mcol3 in range(manzana_cols - 1):
			var rx2 := H_PAD + BLOCK_PAD + (mcol3 + 1) * manzana_w + mcol3 * ROAD_W + ROAD_W * 0.5
			var ry2 := content_y + (mrow3 + 1) * manzana_h + mrow3 * ROAD_W + ROAD_W * 0.5
			var rb := _create_decoration("roundabout", Vector2(ROAD_W * 1.4, ROAD_W * 1.4))
			rb.position = Vector2(rx2, ry2) - Vector2(ROAD_W * 0.7, ROAD_W * 0.7)
			_map_content.add_child(rb)

	var block_bottom := content_y + total_h + BLOCK_PAD

	# Terrain backdrop behind the parcels — inserted at the header's original
	# index so it renders BEHIND everything just added for this block instead
	# of painting over the parcels (Control z-order follows child order). A
	# visible district-colored border (not just a faint fill) is what makes
	# each block read as its own neighborhood zone on the map rather than
	# just a labeled list section.
	var backdrop := Panel.new()
	backdrop.position = Vector2(H_PAD, start_y - 4.0)
	backdrop.size = Vector2(block_w, block_bottom - start_y + 4.0)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back_sn := StyleBoxFlat.new()
	back_sn.bg_color = Color(col.r, col.g, col.b, 0.14)
	back_sn.border_color = Color(col.r, col.g, col.b, 0.5)
	back_sn.set_border_width_all(1)
	back_sn.set_corner_radius_all(2)
	backdrop.add_theme_stylebox_override("panel", back_sn)
	_map_content.add_child(backdrop)
	_map_content.move_child(backdrop, hdr.get_index())

	return block_bottom


# Building footprint size, scaled from the level's real floor area/aspect so
# bigger apartments visibly read as bigger lots on the map — clamped so the
# wrap-flow layout never breaks on a level with an unusual grid shape.
# Floors don't carry their own grid_w/grid_h (that field only exists on the
# apartment as a whole, fixed at a 300×300 canvas) — the actual footprint of
# the ground floor is whatever rectangle its wall segments trace out.
# The ground floor's wall segments and their bounding box — shared by the
# map's footprint sizing (_floor_footprint_tiles) and the info panel's
# blueprint preview, so both always agree with each other and with the real
# apartment shape.
func _floor_plan_data(ld: Dictionary) -> Dictionary:
	var floors := (ld.get("apartment", {}) as Dictionary).get("floors", []) as Array
	for fd in floors:
		var f := fd as Dictionary
		if f.get("type", "") != "floor":
			continue
		var segs := f.get("segments", []) as Array
		if segs.is_empty():
			continue
		var min_x := INF
		var max_x := -INF
		var min_y := INF
		var max_y := -INF
		for sg in segs:
			var s := sg as Dictionary
			min_x = minf(min_x, minf(s.get("x1", 0.0) as float, s.get("x2", 0.0) as float))
			max_x = maxf(max_x, maxf(s.get("x1", 0.0) as float, s.get("x2", 0.0) as float))
			min_y = minf(min_y, minf(s.get("y1", 0.0) as float, s.get("y2", 0.0) as float))
			max_y = maxf(max_y, maxf(s.get("y1", 0.0) as float, s.get("y2", 0.0) as float))
		return {"segments": segs, "bounds": Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))}
	return {"segments": [], "bounds": Rect2()}


func _floor_footprint_tiles(ld: Dictionary) -> Vector2i:
	var b: Rect2 = (_floor_plan_data(ld)["bounds"] as Rect2)
	if b.size.x <= 0.0 or b.size.y <= 0.0:
		return Vector2i(20, 20)
	return Vector2i(maxi(int(b.size.x), 1), maxi(int(b.size.y), 1))


# Four short surveyor's-peg corner marks on the plot boundary, for a locked
# ("unbuilt") lot — reads as "platted but nothing built here yet" rather
# than a disabled button, and leaves the blueprint grid visible through the
# middle of the lot instead of covering it with a flat grey box. All marks
# use plain top-left positioning computed from the button's own known size,
# rather than mixing anchor corners, to keep the math unambiguous.
func _add_survey_corners(btn: Control, margin: float) -> void:
	var tick := 12.0
	var col := Color(0.30, 0.46, 0.60, 0.6)
	var w := btn.size.x
	var h := btn.size.y

	# A whisper of the same amber real apartments use once built — faint
	# enough that the blueprint grid still shows straight through (this lot
	# really is unbuilt), but tinted instead of neutral so it reads as "a
	# future apartment" rather than any decoration's own green/blue/tan hue.
	var tint := ColorRect.new()
	tint.color = Color(GameTheme.C_AMBER.r, GameTheme.C_AMBER.g, GameTheme.C_AMBER.b, 0.10)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tint.position = Vector2(margin, margin)
	tint.size = Vector2(w - margin * 2.0, h - margin * 2.0)
	btn.add_child(tint)
	var corners: Array[Vector2] = [Vector2(margin, margin), Vector2(w - margin, margin),
		Vector2(margin, h - margin), Vector2(w - margin, h - margin)]
	for c in corners:
		var to_left := c.x < w * 0.5
		var to_top := c.y < h * 0.5
		var hbar := ColorRect.new()
		hbar.color = col
		hbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbar.position = Vector2(c.x if to_left else c.x - tick, c.y)
		hbar.size = Vector2(tick, 1.0)
		btn.add_child(hbar)
		var vbar := ColorRect.new()
		vbar.color = col
		vbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbar.position = Vector2(c.x, c.y if to_top else c.y - tick)
		vbar.size = Vector2(1.0, tick)
		btn.add_child(vbar)


# ── Parcel creation ──────────────────────────────────────────────────────────
func _create_parcel(ld: Dictionary) -> Button:
	var btn := Button.new()
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.clip_text = false

	var sn := StyleBoxFlat.new()
	sn.bg_color = Color(0, 0, 0, 0)
	sn.border_color = Color(0.30, 0.46, 0.60, 0.7)
	sn.set_border_width_all(1)
	sn.set_corner_radius_all(2)
	btn.add_theme_stylebox_override("normal", sn)

	var sh := sn.duplicate() as StyleBoxFlat
	sh.border_color = GameTheme.C_AMBER
	sh.set_border_width_all(2)
	btn.add_theme_stylebox_override("hover", sh)
	btn.add_theme_stylebox_override("pressed", sh)

	# Clicking a card used to leave no lasting trace once the mouse moved
	# away again — hover/pressed are transient states, so nothing on the
	# page actually showed which apartment the info panel was describing.
	# A bright white outline (distinct from hover's amber, and from the
	# amber fill real levels already use) is _set_card_selected's job below.
	var sn_selected := sn.duplicate() as StyleBoxFlat
	sn_selected.border_color = Color(1, 1, 1, 0.95)
	sn_selected.set_border_width_all(3)
	btn.set_meta("sn_normal", sn)
	btn.set_meta("sn_selected", sn_selected)

	btn.pressed.connect(_select_level.bind(ld))

	# A slight lift on hover — before this, the only feedback was the border
	# swapping color, with zero motion anywhere on the page. Pivot is set at
	# hover time (not here) since callers still resize the button after
	# _create_parcel returns.
	btn.mouse_entered.connect(func():
		btn.pivot_offset = btn.size * 0.5
		create_tween().tween_property(btn, "scale", Vector2(1.035, 1.035), 0.12) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT))
	btn.mouse_exited.connect(func():
		create_tween().tween_property(btn, "scale", Vector2.ONE, 0.12) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT))

	_map_content.add_child(btn)
	return btn


# Swaps a card's own "normal" stylebox between its plain and highlighted
# versions — deselecting the previous card and marking the new one, so the
# blueprint always shows at a glance which apartment the info panel is
# currently describing (see _select_level).
func _set_card_selected(btn: Button, selected: bool) -> void:
	if not is_instance_valid(btn):
		return
	var meta_key := "sn_selected" if selected else "sn_normal"
	if btn.has_meta(meta_key):
		btn.add_theme_stylebox_override("normal", btn.get_meta(meta_key) as StyleBoxFlat)
	# A slow breathing glow on the selected outline — the one bit of motion
	# on this whole page that isn't tied to a hover/click, so it doesn't
	# read as a completely static tool window. Only ever one card pulsing
	# at a time; killed the instant it stops being the selected one.
	if btn.has_meta("pulse_tween"):
		var old_tw: Tween = btn.get_meta("pulse_tween")
		if is_instance_valid(old_tw):
			old_tw.kill()
	if selected and btn.has_meta("sn_selected"):
		var sel_sn: StyleBoxFlat = btn.get_meta("sn_selected")
		sel_sn.border_color.a = 0.95
		var tw := create_tween().set_loops()
		tw.tween_property(sel_sn, "border_color:a", 0.55, 0.9) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(sel_sn, "border_color:a", 0.95, 0.9) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		btn.set_meta("pulse_tween", tw)


# ── Parcel content refresh ───────────────────────────────────────────────────
func _refresh_all_cards() -> void:
	for ld in _levels_data.get("levels", []):
		var d    := ld as Dictionary
		var lid  := d["id"] as String
		var card := _cards.get(lid) as Button
		if card:
			_fill_parcel(card, d)


func _fill_parcel(btn: Button, ld: Dictionary) -> void:
	# Debug/dev-only sandbox levels (loft mechanics, sloped ceilings, balcony
	# rendering, etc.) are clutter for a real player, so they stay hidden
	# until debug mode is on.
	btn.visible = not _is_debug_level(ld) or GameState.debug_mode
	if not btn.visible:
		return

	for ch in btn.get_children():
		ch.queue_free()

	var lid       := ld["id"] as String
	var is_owned  := GameState.is_owned(lid)
	var cost      := ld.get("acquisition_cost", 0) as int
	var min_stars := ld.get("min_stars", 0) as int
	var level_visible := GameState.total_stars() >= min_stars
	var can_buy   := GameState.company_funds >= cost
	var stars     := GameState.get_stars(lid)

	var tenant := ld.get("tenant", {}) as Dictionary
	var status_line: String
	if not level_visible:
		status_line = "Locked — needs %d ★" % min_stars
	elif stars > 0:
		status_line = "★".repeat(stars) + "☆".repeat(3 - stars)
	elif is_owned:
		status_line = "Available"
	else:
		status_line = ("%d€" if can_buy else "Locked — %d€") % cost
	btn.tooltip_text = "%s — %s\n%s" % [
		ld.get("name", "") as String, tenant.get("name", "") as String, status_line,
	]

	var margin := clampf(minf(btn.size.x, btn.size.y) * 0.10, 5.0, 12.0)

	if not level_visible:
		# Locked = an unbuilt, surveyed lot: no structure fill at all (the
		# blueprint grid shows straight through), just four corner survey
		# marks — reads as "platted but not built" instead of "a disabled
		# button", and doesn't compete visually with the actually-built
		# (colored) lots around it.
		_add_survey_corners(btn, margin)
	else:
		# The building fill sits right up against the property line (just a
		# hairline in from the parcel's own border) — the wider `margin` used
		# for survey corners above read as a gap between two separate boxes
		# once the fill was actually colored in, instead of one solid lot.
		var bld_margin := 2.0
		var bld := Panel.new()
		bld.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bld.offset_left = bld_margin; bld.offset_top = bld_margin
		bld.offset_right = -bld_margin; bld.offset_bottom = -bld_margin
		bld.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bsn := StyleBoxFlat.new()
		bsn.set_corner_radius_all(1)
		bsn.set_border_width_all(1)
		# Real levels get a two-layer "keycap": a darker base filling the full
		# cell, plus a brighter face inset from the bottom-right only, so the
		# base peeks out as a visible edge of "height".
		#
		# Every state is some shade of amber, never the district color —
		# every decoration type already owns a hue (park green, lake blue,
		# plaza tan...), so a district-tinted apartment kept landing on a
		# near-identical shade of whatever decoration sat next to it. Amber is
		# the one color nothing else on this page uses (it's the game's
		# existing "important/actionable" accent — Start Game, stars, prices).
		# Owned is brightest, affordable-but-not-yet-owned is dimmer, and
		# visible-but-can't-afford-yet is dimmer still — that last one used to
		# fall back to a plain near-black gray, which is exactly what made it
		# disappear next to the equally-dark decorations.
		var depth := 4.0
		var base_dark: float
		var face_dark: float
		var border_dark: float
		if is_owned:
			base_dark = 0.45; face_dark = 0.05; border_dark = 0.0
		elif can_buy:
			base_dark = 0.55; face_dark = 0.30; border_dark = 0.15
		else:
			base_dark = 0.68; face_dark = 0.50; border_dark = 0.35
		bsn.bg_color     = GameTheme.C_AMBER.darkened(base_dark)
		bsn.border_color = Color(0, 0, 0, 0)
		bld.add_theme_stylebox_override("panel", bsn)
		btn.add_child(bld)

		var face := Panel.new()
		face.set_anchors_preset(Control.PRESET_TOP_LEFT)
		face.position = Vector2.ZERO
		face.size = Vector2(maxf(btn.size.x - bld_margin * 2.0 - depth, 1.0),
							 maxf(btn.size.y - bld_margin * 2.0 - depth, 1.0))
		face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fsn := StyleBoxFlat.new()
		fsn.set_corner_radius_all(1)
		fsn.bg_color     = GameTheme.C_AMBER.darkened(face_dark)
		fsn.border_color = GameTheme.C_AMBER if is_owned else GameTheme.C_AMBER.darkened(border_dark)
		fsn.set_border_width_all(2 if is_owned else 1)
		face.add_theme_stylebox_override("panel", fsn)
		bld.add_child(face)

	var nm := Label.new()
	nm.text = ld.get("name", "") as String
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	nm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	nm.offset_left = margin + 4; nm.offset_right = -(margin + 4)
	nm.offset_top  = margin + 3; nm.offset_bottom = -(margin + 20)
	nm.add_theme_font_size_override("font_size", 14)
	nm.add_theme_color_override("font_color",
		Color(1, 1, 1, 0.92) if level_visible else Color(0.40, 0.42, 0.46))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(nm)

	var status := Label.new()
	status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	status.offset_top    = -(margin + 20)
	status.offset_bottom = -margin
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 12)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not level_visible:
		status.text = "🔒"
		status.add_theme_color_override("font_color", Color(0.40, 0.42, 0.46))
	elif stars > 0:
		status.text = "★".repeat(stars)
		status.add_theme_color_override("font_color", GameTheme.C_AMBER)
	elif is_owned:
		status.text = "●"
		status.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	else:
		status.text = ("%d€" % cost) if can_buy else "🔒 %d€" % cost
		status.add_theme_color_override("font_color",
			Color(0.80, 0.86, 0.92) if can_buy else Color(0.44, 0.46, 0.50))
	btn.add_child(status)



# ── Info panel update ────────────────────────────────────────────────────────
func _select_level(ld: Dictionary) -> void:
	_selected_is_custom = false
	_selected = ld
	var lid      := ld["id"] as String
	_set_card_selected(_selected_card, false)
	_selected_card = _cards.get(lid) as Button
	_set_card_selected(_selected_card, true)
	var is_owned := GameState.is_owned(lid)
	var cost     := ld.get("acquisition_cost", 0) as int
	var min_st   := ld.get("min_stars", 0) as int
	var level_visible := GameState.total_stars() >= min_st
	var can_buy  := GameState.company_funds >= cost
	var stars    := GameState.get_stars(lid)
	var tenant   := ld["tenant"] as Dictionary

	_info_title.text    = ld["name"] as String
	# Budget used to sit as its own line further down, competing with
	# Requires/rent/Reward for attention when it's the one number a player
	# actually needs before picking furniture — folded into the header line
	# instead, right next to the size it's meant to be read alongside.
	_info_district.text = "%s  ·  %s  ·  Budget: %d€" % [
		ld.get("district", "?") as String,
		_sqm_label(ld),
		ld.get("starting_budget", 0) as int,
	]

	var plan := _floor_plan_data(ld)
	_blueprint_preview.set_data(plan["segments"] as Array, plan["bounds"] as Rect2, _furniture_preview_rects(ld))
	_tenant_portrait.visible = true
	_update_portrait(tenant.get("name", "?") as String)

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
	_info_budget.visible = false
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
	var tiles := _floor_footprint_tiles(ld)
	return "%.0f m²" % (float(tiles.x * tiles.y) * 0.01)  # 1 tile = 10cm × 10cm = 0.01m²


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
		GameState.set_last_active_level(lid)
		Transition.change_scene("res://scenes/Main.tscn")
	else:
		var cost := _selected.get("acquisition_cost", 0) as int
		if GameState.buy_level(lid, cost):
			Audio.play("success")
			_fill_parcel(_cards[lid] as Button, _selected)
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
	GameState.set_last_active_level(lid)
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
	# The DEBUG tab only exists while debug mode is on, so the tab rail needs
	# rebuilding too (not just the currently-shown map) — see _rebuild_tabs.
	_rebuild_tabs()
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
# Solid base fill + blueprint graph-paper grid, drawn once on the root
# Control. Every other panel (tabs, top bar, info sidebar) paints its own
# opaque background over its own region, so the map viewport — which has no
# opaque background of its own — is the only place this actually shows
# through. That's deliberate: it's what makes the map read as a blueprint
# sheet instead of plain dark UI.

# Faint horizontal streaks — same wood-grain trick MainMenu's desk
# background uses — applied to the walnut chrome (top bar, sidebar, tabs
# rail) so those read as the same material as the desk instead of a flat
# UI-toolkit gray.
func _draw_wood_grain(node: Control) -> void:
	var streak := Color(0, 0, 0, 0.05)
	var y := 6.0
	while y < node.size.y:
		node.draw_line(Vector2(0, y), Vector2(node.size.x, y), streak, 1.0)
		y += 11.0


var _sheen_tex: GradientTexture2D = null

# A soft light-from-above gradient — the actual fix for flat StyleBoxFlat
# color + border + drop shadow reading as generic UI-toolkit widgets rather
# than crafted objects. Applied ONLY to chrome buttons (tabs, sidebar
# actions) — never anything inside _map_clip, so it can't be mistaken for
# another film sitting over the blueprint.
func _draw_sheen(node: Control) -> void:
	if not _sheen_tex:
		var grad := Gradient.new()
		grad.colors = PackedColorArray([Color(1, 1, 1, 0.16), Color(1, 1, 1, 0.0)])
		grad.offsets = PackedFloat32Array([0.0, 0.6])
		_sheen_tex = GradientTexture2D.new()
		_sheen_tex.gradient = grad
		_sheen_tex.fill = GradientTexture2D.FILL_LINEAR
		_sheen_tex.fill_from = Vector2(0.5, 0.0)
		_sheen_tex.fill_to = Vector2(0.5, 1.0)
		_sheen_tex.width = 8
		_sheen_tex.height = 64
	node.draw_texture_rect(_sheen_tex, Rect2(Vector2.ZERO, node.size), false)


# Same tiny floor-plan silhouette as MainMenu's title motif — a one-room
# apartment outline with a doorway gap — so both screens share one mark.
func _draw_title_motif(node: Control) -> void:
	var r := Rect2(Vector2.ZERO, node.custom_minimum_size)
	node.draw_rect(r, GameTheme.BP_PAPER)
	var inset := r.grow(-4)
	node.draw_rect(inset, GameTheme.BP_INK, false, 1.3)
	var mid_x := inset.position.x + inset.size.x * 0.55
	node.draw_line(Vector2(mid_x, inset.position.y), Vector2(mid_x, inset.position.y + inset.size.y * 0.35), GameTheme.BP_INK, 1.3)
	node.draw_line(Vector2(mid_x, inset.position.y + inset.size.y * 0.65), Vector2(mid_x, inset.position.y + inset.size.y), GameTheme.BP_INK, 1.3)


# A cheap procedural "paper texture" — a scatter of tiny specks at a fixed
# seed (so it doesn't flicker/reshuffle on redraw), some ink-dark, some
# highlight-light, mimicking flecked kraft paper fiber instead of a flat
# color swatch.
func _draw_paper_grain(node: Control) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 91827
	var count := int(node.size.x * node.size.y / 900.0)
	for i in range(count):
		var p := Vector2(rng.randf_range(0.0, node.size.x), rng.randf_range(0.0, node.size.y))
		var dark := rng.randf() < 0.5
		var col := Color(0, 0, 0, rng.randf_range(0.04, 0.09)) if dark \
			else Color(1, 1, 1, rng.randf_range(0.05, 0.10))
		node.draw_circle(p, rng.randf_range(0.6, 1.4), col)


func _draw_blueprint_grid(node: Control) -> void:
	var vw := int(node.size.x) + 1
	var vh := int(node.size.y) + 1
	var minor := Color(0.20, 0.30, 0.45, 0.28)
	var major := Color(0.30, 0.44, 0.62, 0.45)
	for x in range(0, vw, 20):
		node.draw_line(Vector2(x, 0), Vector2(x, vh), major if x % 100 == 0 else minor, 1.0)
	for y in range(0, vh, 20):
		node.draw_line(Vector2(0, y), Vector2(vw, y), major if y % 100 == 0 else minor, 1.0)


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

	var bd := {"id": 0, "name": "Debug", "subtitle": "", "color": "#D8944A"}
	return _build_district_block(start_y, bd, debug_levels, "DEBUG LEVELS  (Ctrl+Shift+Alt+D)")


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
	_info_district.text = "Custom Level  ·  %s  ·  Budget: %d€" % [
		_sqm_label(ld), ld.get("starting_budget", 0) as int,
	]

	var plan := _floor_plan_data(ld)
	_blueprint_preview.set_data(plan["segments"] as Array, plan["bounds"] as Rect2, _furniture_preview_rects(ld))

	var tenant := ld.get("tenant", {}) as Dictionary
	if tenant.is_empty():
		_info_tenant.text = "No tenant defined"
		_tenant_portrait.visible = false
	else:
		_tenant_portrait.visible = true
		_update_portrait(tenant.get("name", "?") as String)
		var flavor := tenant.get("flavor", "") as String
		var flavor_line := "\n\"%s\"" % flavor if flavor != "" else ""
		_info_tenant.text = "%s, %d%s" % [
			tenant.get("name", "?"), tenant.get("age", 0),
			flavor_line
		]

	var funcs := tenant.get("required_functions", []) as Array
	_info_reqs.text   = ("Requires: " + ", ".join(funcs)) if not funcs.is_empty() else ""
	_info_budget.visible = false
	_info_rent.text   = ""
	_info_cost.text   = ""

	_action_btn.text     = "PLAY →"
	_action_btn.disabled = false
	_redesign_btn.visible = false
