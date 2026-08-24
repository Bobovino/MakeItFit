extends Node

const FurnitureScene := preload("res://scenes/Furniture.tscn")
const Room3DViewScene := preload("res://scenes/Room3DView.tscn")
const ComfortMeterScript := preload("res://scripts/ComfortMeter.gd")

@onready var gm:           GameManager  = $GameManager
@onready var room:         Node2D       = $Room
@onready var minimap:      Minimap      = $UI/TopBar/Minimap
@onready var budget_label: Label        = $UI/TopBar/Label
@onready var tenant_card:  TenantCard   = $UI/TenantCard
@onready var inventory:    Inventory    = $UI/Inventory
@onready var rent_btn:     Button       = $UI/TopBar/RentButton
@onready var view3d_btn:   Button       = $UI/TopBar/View3DButton
@onready var result_screen: ResultScreen = $ResultScreen
@onready var wall_inspector: WallInspector = $UI/WallInspector
@onready var divider:      ColorRect     = $UI/Divider
@onready var ui_layer:     CanvasLayer   = $UI

const TILE_SIZE := 8          # pixels per grid tile — matches Floor/GridDraw
const TOP_Y     := 10.0       # slim top margin — the old full-width bar is gone; only a
							   # floating gear icon (and Test Layout, when shown) sit up here now
const BOT_Y     := 720.0      # bottom of the play area — full window height now that
							   # the furniture/tenant panels are side columns, not a bottom bar
const FIT_PCT   := 0.95       # fraction of available area to fill

# ── Play-area bounds ────────────────────────────────────────────────────────
# The floor plan / wall view / 3D view get the entire window width — the old
# always-docked Inventory sidebar that used to reserve LEFT_X's 170px is gone
# (see the furniture wheel/catalog flow below); TenantCard and the furniture
# menu button/wheel all float as overlays instead of reserved columns.
const LEFT_X  := 0.0
const RIGHT_X := 1280.0

# ── Floor plan / docked-panel resizable split ──────────────────────────────
# The docked panel (Wall Inspector or the 3D preview, depending on mode) is a
# horizontal strip along the BOTTOM of the screen — the top-down plan always
# keeps the full width above it, so the divider only moves vertically.
const MIN_SPLIT_Y := 300.0   # top plan area keeps at least this much height
const MAX_SPLIT_Y := 620.0   # bottom panel keeps at least this much height
var _split_y:          float = 460.0
var _dragging_divider: bool = false
var _undo_btn: Button = null   # floating corner button over the floor plan, top-right of the play area
var _redo_btn: Button = null   # sits directly left of _undo_btn, same floating row
var _test_btn: Button = null   # floating "Test Layout" toggle, top-left — only shown for levels with foldable furniture and no moments
var _settings_btn: Button = null   # floating gear-only menu button, top-right corner
var _editor_back_btn: Button = null   # "← Back to Editor" — only visible while testing a "_custom" level from the Level Editor
var _view_mode_box: HBoxContainer = null   # floating Floor Plan/3D segmented toggle, stacked directly above the floor-tabs Minimap
var _pending_floor_ghost: Furniture = null   # the floor-placement ghost armed alongside a wall placement

# ── View mode: two ways to look at the same apartment, both reading/writing
# the same Floor data — switching modes never converts or loses anything:
#   TOPDOWN — plan only; click a highlighted wall edge to inspect it or hang items via a popup
#   VIEW3D  — walk around in 3D; drag items onto a wall to hang them there
enum ViewMode { TOPDOWN, VIEW3D }
const SCREEN_W := 1280.0   # design-resolution width every TopBar/Divider/WallInspector offset assumes
var _view_mode: int = ViewMode.TOPDOWN
var _mode3d_view:    Control = null   # persistent 3D view for VIEW3D mode (separate from the "reveal" overlay)
var _mode3d_sell_floor: Floor = null  # which Floor _mode3d_view's sell_requested/wall_sell_requested are currently bound to — see _ensure_mode3d_view
var _watch_done_btn: Button  = null   # floating "back to results" button shown during free-camera Watch Again
var _post_win_view: bool = false      # true during Watch Again — level is already rented out, so editing/shortcuts are locked out; only the camera works
var _last_wall_click_by_floor: Dictionary = {}   # floor_id -> {edge, span_lo, span_hi} — for the "W" reopen-last-wall shortcut
var _modal_backdrop: ColorRect = null # dims the screen behind WallInspector when it's shown as a modal
var _furniture_menu_btn: Button = null       # persistent "Furniture" trigger — replaces the old always-docked Inventory sidebar
var _category_wheel: CategoryWheel = null    # Sims-style radial category picker, built lazily
var _furniture_menu_backdrop: ColorRect = null   # dims the screen behind the wheel/catalog, own node so it doesn't cross-wire with _modal_backdrop's WallInspector-specific dismiss callback
var _mode_buttons:   Dictionary = {}  # ViewMode -> Button
var _mode_hint_lbl:  Label = null     # "click a wall" / "drag onto a wall" guidance outside the docked-pane modes
var _breadcrumb_lbl: Label = null     # "Root > Shoebox > Shoebox Interior" — which apartment we're actually in, since nested boxes are otherwise only inferable from the mini-plan cards
var _comfort_meter: Control = null   # live gm.comfort_pct fill bar (ComfortMeter.gd) — only shown when the level actually has yellow-tier furniture placed
var _intro_modal_open: bool = false   # "NEW MECHANIC" card is up — blocks zoom/pan everywhere

# ── Floor plan zoom/pan (layered on top of the auto-fit baseline) ─────────
const MIN_MANUAL_ZOOM := 0.4
const MAX_MANUAL_ZOOM := 4.0
var _base_scale:    float   = 1.0
var _base_position: Vector2 = Vector2.ZERO
var _manual_zoom:   float   = 1.0
var _manual_pan:    Vector2 = Vector2.ZERO
var _panning_floor: bool    = false

var _floors:            Dictionary = {}
var _loft_floors:       Dictionary = {}  # base_floor_id -> dynamically created loft Floor node
var _floor_below_id:    Dictionary = {}  # floor id -> id of the "floor"-type floor stacked below it (for the 3D ghost-floor-below reference layer)
var _current_floor_id:  String = ""
var _current_level_id:  String = ""
# Nested/parabox levels: stack of {parent_level_id, daylight_factor}. Entering
# a box (via the mini-plan panel, see _refresh_nested_plan_panel() — never by
# clicking the box itself, which needs to stay a plain draggable piece of
# furniture) pushes the CURRENT level id so leaving it can reload the parent;
# the child level's own daylight is dimmed by daylight_factor to
# model the parent's furniture blocking light into the box (see
# _compute_box_occlusion()). Both directions snapshot the level being left
# via _snapshot_level_state() and restore it on return via
# _apply_level_state_snapshot(), so furniture placed/moved/folded/sold on
# either side of a box survives round-trips, not just the authored JSON state.
var _nested_stack: Array = []
var _current_nested_daylight_factor: float = 1.0
# State cache — see _snapshot_level_state()/_apply_level_state_snapshot().
# level_id -> {budget:int, floors:{floor_id:[{id,x,y,rot_steps,is_extended}]}}
# — captured every time a nested-level transition leaves a level, so coming
# back to it (either popping out of a box, or re-entering the same box
# later) restores exactly what the player left there instead of the level's
# authored starting_furniture. Wall items (Wall.wall_items — furniture hung
# via the 2D wall-drop flow, which has no live Furniture node at all, see
# docs/design_nested_levels.md's "two placement systems" note) aren't
# captured by this snapshot; only real Furniture-backed floor items are.
var _level_state_cache: Dictionary = {}
# Every is_nested_box Furniture spawned in the CURRENTLY loaded level — lets
# _refresh_nested_links() list an "enter this box" link for each of them (not
# just the first one found), rebuilt fresh on every _load_level().
# NOTE: deliberately NOT a cached array. An earlier version tracked boxes in
# one as they spawned, which silently desynced: "Revisar Plano Actual" builds
# the cards from the starting_furniture spawn, then _restore_furniture_snapshot
# frees all of that and respawns via _restore_spawn_furniture (a separate path
# that never touched the cache) — leaving the card pointing at a freed node, so
# every click failed its is_instance_valid() check and did nothing while the
# hover tooltip still worked. Derived live from the floors instead.
func _collect_nested_boxes() -> Array[Furniture]:
	var out: Array[Furniture] = []
	for fid in _floors:
		var fl := _floors[fid] as Floor
		if not is_instance_valid(fl):
			continue
		for entry in fl.get_all_furniture():
			var fur := entry as Furniture
			if is_instance_valid(fur) and fur.is_nested_box and not fur.child_level_id.is_empty():
				out.append(fur)
	return out
# Row of small clickable blueprint-style mini-plan cards for every reachable
# "other space" — an exit-to-parent card while inside a box, plus one
# enter-this-box card per is_nested_box in the current level (both can
# appear together for arbitrary nesting depth) — floating next to the
# Minimap floor tabs. See _refresh_nested_plan_panel().
var _nested_plan_row: HBoxContainer = null
# Reentrancy guard — a card's click handler always re-resolves what to do
# from _nested_stack/_collect_nested_boxes() at click time rather than baking a
# specific action into a closure ahead of time (a captured Furniture
# reference could go stale once a transition freed it); this additionally
# blocks a second transition from starting while one is already tearing
# down/rebuilding the level.
var _nested_transition_busy: bool = false

# ── Builder tab tools (free-form geometry editing during play) ────────────
var _active_builder_tool: String    = ""    # "", "wall", "column", "erase"
var _builder_drawing:     bool      = false
var _builder_press_tile:  Vector2i  = Vector2i.ZERO
var _builder_cur_tile:    Vector2i  = Vector2i.ZERO
var _builder_ghost:       Line2D    = null
var _builder_press_consumed: bool   = false  # only consume the matching release
var _builder_pipe_tiles:  Array     = []  # Vector2i path being drawn for pipe_water/pipe_power
var _builder_pipe_ghost:  Line2D    = null
# Snapshot-based undo: shared by Builder-tool actions (walls/columns/etc.) and
# furniture actions (buy/sell/move/fold) so one Undo button/shortcut reverts
# whichever kind of change happened most recently. Builder entries are
# {"type":"builder", "floor_id", "data"} (deep copy of the Floor's
# Builder-mutable fields); furniture entries are
# {"type":"furniture", "snapshot"} (see _snapshot_all_furniture). Each is
# captured BEFORE the action it undoes.
const BUILDER_UNDO_MAX := 50
var _builder_undo_stack: Array = []
var _redo_stack: Array = []   # entries popped off _builder_undo_stack by Undo, replayed by Redo
var _last_furniture_state: Dictionary = {}   # cache of furniture state as of the last change
var _restoring_furniture: bool = false       # guards the restore's own mutations from re-triggering a push
var _paint_pieces:      Dictionary = {}  # floor_id -> {type_id: PaintedFurniture}
var _active_paint_type: String     = ""
var _painting:          bool       = false
var _last_paint_tile:   Vector2i   = Vector2i(-1, -1)
var _paint_panel:       Control    = null
var _paint_status_lbl:  Label      = null
var _floor_tile_bounds: Dictionary = {}  # floor_id -> Rect2i of painted tile content
var _active_moment_id:  String = ""
var _rent_auto_armed:   bool = false   # false while a level is still spawning its starting furniture — see _update_rent_btn()
var _level_load_id:     int  = 0       # bumped on every _load_level() call — lets an in-flight completion reveal detect a Restart Level mid-animation and bail instead of showing stale results
var _level_completed:   bool = false   # true once this level's Results screen has been shown this session — see _on_settings_btn_pressed


func _ready() -> void:
	# Floor tabs (Ground Floor/Loft/Second Floor/...) read better as a vertical
	# stack — it echoes the actual building elevation (higher floors literally
	# higher on screen) instead of a left-to-right strip, and frees up the
	# TopBar. Pulled out of TopBar entirely and floated bottom-right instead,
	# same corner the Undo/Redo buttons already anchor off of.
	minimap.set_compact(false)
	minimap.get_parent().remove_child(minimap)
	ui_layer.add_child(minimap)
	_position_minimap()
	if not gm.budget_changed.is_connected(_on_budget_changed):
		gm.budget_changed.connect(_on_budget_changed)
	if not gm.functions_updated.is_connected(_on_functions_updated):
		gm.functions_updated.connect(_on_functions_updated)
	if not gm.moments_updated.is_connected(_on_moments_updated):
		gm.moments_updated.connect(_on_moments_updated)
	if not minimap.wall_selected.is_connected(_switch_floor):
		minimap.wall_selected.connect(_switch_floor)
	if not tenant_card.moment_selected.is_connected(_on_moment_selected):
		tenant_card.moment_selected.connect(_on_moment_selected)
	if not inventory.buy_requested.is_connected(_on_buy_requested):
		inventory.buy_requested.connect(_on_buy_requested)
	if not inventory.builder_tool_selected.is_connected(_on_builder_tool_selected):
		inventory.builder_tool_selected.connect(_on_builder_tool_selected)
	rent_btn.visible = false   # superseded — completion now fires on its own, see _update_rent_btn()
	view3d_btn.visible = false   # superseded by the persistent 3D view mode
	if not result_screen.next_level_requested.is_connected(_on_next_level):
		result_screen.next_level_requested.connect(_on_next_level)
	if not result_screen.retry_requested.is_connected(_on_retry):
		result_screen.retry_requested.connect(_on_retry)
	if not result_screen.watch_again_requested.is_connected(_on_watch_again_reveal):
		result_screen.watch_again_requested.connect(_on_watch_again_reveal)
	if not result_screen.advance_level_requested.is_connected(_on_advance_level):
		result_screen.advance_level_requested.connect(_on_advance_level)
	if not wall_inspector.wall_closed.is_connected(_on_inspector_visibility_changed):
		wall_inspector.wall_closed.connect(_on_inspector_visibility_changed)
	if not wall_inspector.wall_item_placed.is_connected(_on_wall_item_placed):
		wall_inspector.wall_item_placed.connect(_on_wall_item_placed)
	divider.mouse_filter = Control.MOUSE_FILTER_STOP
	divider.mouse_default_cursor_shape = Control.CURSOR_VSPLIT
	if not divider.gui_input.is_connected(_on_divider_gui_input):
		divider.gui_input.connect(_on_divider_gui_input)
	Furniture.is_in_floor_pane = func(pos: Vector2) -> bool:
		# The screen-rectangle check alone isn't enough: the Wall Inspector's
		# elevation view can occupy that exact same rectangle when open,
		# which made clicks/drags meant for it get misread as "landed on the
		# floor plan" — letting the OTHER ghost armed by the same purchase
		# (see Main.gd's _on_buy_requested) react to stale floor coordinates
		# and surface its own rejection (e.g. "Outside the room") even while
		# the player was clearly placing the item on a wall instead.
		if wall_inspector.is_showing_wall():
			return false
		return pos.x > LEFT_X and pos.x < RIGHT_X and pos.y > TOP_Y and pos.y < _floor_pane_bottom_y()
	_update_split(_split_y)
	_apply_ui_theme()
	_load_level(GameState.pending_level_id)


func _apply_ui_theme() -> void:
	var t := GameTheme.make()
	minimap.theme       = t
	tenant_card.theme   = t
	inventory.theme     = t
	wall_inspector.theme = t

	var ts := StyleBoxFlat.new()
	ts.bg_color     = Color(0.130, 0.113, 0.095, 0.98)
	ts.border_color = GameTheme.C_BORDER
	ts.set_border_width(SIDE_BOTTOM, 2)
	ts.set_content_margin_all(6)
	ts.shadow_color = Color(0, 0, 0, 0.35)
	ts.shadow_size = 6
	ts.shadow_offset = Vector2(0, 3)
	($UI/TopBarBg as Panel).add_theme_stylebox_override("panel", ts)

	budget_label.add_theme_font_size_override("font_size", 15)
	budget_label.add_theme_color_override("font_color", GameTheme.C_AMBER)
	# Budget reads as the puzzle's primary resource — give it a HUD pill of its
	# own instead of floating bare text in the bar.
	var bp := StyleBoxFlat.new()
	bp.bg_color     = Color(0.22, 0.19, 0.08)
	bp.border_color = Color(0.62, 0.54, 0.24)
	bp.set_border_width_all(1)
	bp.set_corner_radius_all(10)
	bp.anti_aliasing = true
	bp.set_content_margin(SIDE_LEFT, 12)
	bp.set_content_margin(SIDE_RIGHT, 12)
	bp.set_content_margin(SIDE_TOP, 3)
	bp.set_content_margin(SIDE_BOTTOM, 3)
	budget_label.add_theme_stylebox_override("normal", bp)
	budget_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# The old TopBar is gone — Budget now floats on its own below the
	# furniture shop panel (see _position_budget_label()), out of the way of
	# the TenantCard bar, which is already crowded once a level has more than
	# one moment or a floor-tab stack sharing that same bottom-right corner.
	if budget_label.get_parent() != ui_layer:
		if budget_label.get_parent():
			budget_label.get_parent().remove_child(budget_label)
		ui_layer.add_child(budget_label)

	var rs := GameTheme.make_rent_btn_style()
	rent_btn.add_theme_stylebox_override("normal",   rs[0])
	rent_btn.add_theme_stylebox_override("hover",    rs[1])
	rent_btn.add_theme_stylebox_override("pressed",  rs[1])
	rent_btn.add_theme_stylebox_override("disabled", rs[2])
	rent_btn.add_theme_color_override("font_color",          GameTheme.C_AMBER)
	rent_btn.add_theme_color_override("font_hover_color",    Color(1.0, 0.96, 0.72))
	rent_btn.add_theme_color_override("font_pressed_color",  Color(1.0, 0.96, 0.72))
	rent_btn.add_theme_color_override("font_disabled_color", GameTheme.C_MUTED)
	rent_btn.add_theme_font_size_override("font_size", 13)

	# The old full-width TopBar is gone — Budget/moments moved into the bottom
	# TenantCard bar, and the view-mode toggle/gear menu/Test Layout button
	# below are all floated directly on ui_layer (like Undo/Redo already were)
	# instead of living in that now-empty bar.

	# Test mode button — only visible if level has foldable furniture
	if not is_instance_valid(_test_btn):
		_test_btn = Button.new()
		_test_btn.name        = "TestBtn"
		_test_btn.text        = "Test Layout"
		_test_btn.toggle_mode = true
		_test_btn.add_theme_font_size_override("font_size", 11)
		_test_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_test_btn.toggled.connect(_on_test_toggled)
		_test_btn.visible = false   # updated after level load
		ui_layer.add_child(_test_btn)

	# Nested/parabox levels: entering/leaving a box is now a link button
	# living right in the Minimap floor-tab strip (see _refresh_nested_links())
	# instead of a separate floating button — "which space am I looking at"
	# reads as one row: this apartment's floors, plus any box you can step
	# into, plus (if you're inside one) the way back out.

	# View-mode switcher: two ways to look at the apartment (see the ViewMode
	# enum comment). Mutually exclusive via a ButtonGroup. Floats stacked
	# directly above the floor-tabs Minimap (see _position_view_mode_box).
	if not is_instance_valid(_view_mode_box):
		var box := HBoxContainer.new()
		box.name = "ViewModeBox"
		box.add_theme_constant_override("separation", 0)
		var group := ButtonGroup.new()
		var specs := [
			[ViewMode.TOPDOWN, "Floor Plan", "Blueprint view — click a highlighted wall edge to inspect it or hang items"],
			[ViewMode.VIEW3D,  "3D",         "Walk around and place items in 3D — drag onto a wall to hang them"],
		]
		for i in specs.size():
			var spec: Array = specs[i]
			var mode: int = spec[0]
			var btn := Button.new()
			btn.name          = "ViewMode%d" % mode
			btn.text          = spec[1]
			btn.tooltip_text  = spec[2]
			btn.toggle_mode   = true
			btn.button_group  = group
			btn.button_pressed = (mode == _view_mode)
			btn.add_theme_font_size_override("font_size", 11)
			# Segmented-control look: one connected pill, only the outer ends
			# rounded, with the active segment filled amber.
			var seg_n := _segment_style(Color(0.175, 0.155, 0.125), GameTheme.C_BORDER, i, specs.size())
			var seg_h := _segment_style(Color(0.19, 0.24, 0.31), GameTheme.C_BORDER, i, specs.size())
			var seg_p := _segment_style(Color(0.42, 0.36, 0.13), GameTheme.C_AMBER, i, specs.size())
			btn.add_theme_stylebox_override("normal",  seg_n)
			btn.add_theme_stylebox_override("hover",   seg_h)
			btn.add_theme_stylebox_override("pressed", seg_p)
			btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())
			btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.70))
			btn.pressed.connect(_set_view_mode.bind(mode))
			box.add_child(btn)
			_mode_buttons[mode] = btn
		_view_mode_box = box
		ui_layer.add_child(box)

	if not is_instance_valid(_settings_btn):
		_settings_btn = Button.new()
		_settings_btn.name = "SettingsBtn"
		# Icon-only now that it floats in its own corner instead of sitting in
		# a labelled bar — "Menu" spelled out next to a gear was needed there
		# to read as a button at all; alone in the corner the gear reads fine
		# by itself, same as any other icon-only HUD button.
		_settings_btn.text = "⚙"
		_settings_btn.tooltip_text = "Menu — settings, back to projects, quit"
		_settings_btn.add_theme_font_size_override("font_size", 16)
		_settings_btn.custom_minimum_size = Vector2(32, 0)
		_settings_btn.pressed.connect(_on_settings_btn_pressed)
		ui_layer.add_child(_settings_btn)

	# Only ever relevant for a level launched via the Level Editor's own
	# "▶ Test Level" (level_id == "_custom") — _go_back() deliberately always
	# routes to CityMap regardless (a real player never reaches Main via the
	# editor), so without this a designer testing a level had no way back
	# short of the Ctrl+Shift+Alt+E shortcut from CityMap, losing whatever
	# unsaved editing context they had. Visibility kept in sync in
	# _load_level(). See GameState.editor_test_snapshot for the round trip.
	if not is_instance_valid(_editor_back_btn):
		# Own CanvasLayer, same reasoning as the nested-plan row: ui_layer
		# sibling order isn't reliable once _mode3d_view's full-screen
		# viewport (or anything else) re-raises itself later — CanvasLayer
		# order IS authoritative for both drawing and input picking.
		var canvas := CanvasLayer.new()
		canvas.name  = "EditorBackLayer"
		canvas.layer = 5
		add_child(canvas)
		_editor_back_btn = Button.new()
		_editor_back_btn.name = "EditorBackBtn"
		_editor_back_btn.text = "← Back to Editor"
		_editor_back_btn.tooltip_text = "Return to the Level Editor, resuming the level you were testing"
		_editor_back_btn.add_theme_font_size_override("font_size", 12)
		_editor_back_btn.visible = false
		_editor_back_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_editor_back_btn.offset_left = 8.0
		# TOP_Y (10) + the Furniture button's own ~34px height + a gap —
		# this used to sit at the exact same (8, 8) spot as "🛋 Furniture",
		# fully overlapping it (that button's own position is LEFT_X+8, TOP_Y).
		_editor_back_btn.offset_top = TOP_Y + 34.0 + 8.0
		_editor_back_btn.pressed.connect(func():
			GameState.testing_from_editor = false
			Transition.change_scene("res://scenes/LevelEditor.tscn"))
		canvas.add_child(_editor_back_btn)

	if not is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn = Button.new()
		_furniture_menu_btn.name = "FurnitureMenuBtn"
		_furniture_menu_btn.text = "🛋 Furniture (F)"
		_furniture_menu_btn.tooltip_text = "Open the furniture menu (F)"
		_furniture_menu_btn.add_theme_font_size_override("font_size", 14)
		# Same prominent amber treatment as the Rent Out button — this is now
		# the only way into buying furniture, so it needs to read as a clearly
		# clickable primary action, not a small utility icon tucked in a corner.
		var fs := GameTheme.make_rent_btn_style()
		_furniture_menu_btn.add_theme_stylebox_override("normal",  fs[0])
		_furniture_menu_btn.add_theme_stylebox_override("hover",   fs[1])
		_furniture_menu_btn.add_theme_stylebox_override("pressed", fs[1])
		_furniture_menu_btn.add_theme_color_override("font_color",         GameTheme.C_AMBER)
		_furniture_menu_btn.add_theme_color_override("font_hover_color",   Color(1.0, 0.96, 0.72))
		_furniture_menu_btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.96, 0.72))
		_furniture_menu_btn.pressed.connect(_open_furniture_menu)
		ui_layer.add_child(_furniture_menu_btn)

	if not is_instance_valid(_undo_btn):
		_undo_btn = Button.new()
		_undo_btn.name = "UndoBtn"
		_undo_btn.text = "↶"
		_undo_btn.tooltip_text = "Undo last action (Ctrl+%s)" % OS.get_keycode_string(GameState.undo_keycode)
		_undo_btn.add_theme_font_size_override("font_size", 16)
		_undo_btn.custom_minimum_size = Vector2(32, 0)
		_undo_btn.offset_top = TOP_Y + 8.0
		_undo_btn.pressed.connect(_undo_builder_action)
		ui_layer.add_child(_undo_btn)
	if not is_instance_valid(_redo_btn):
		_redo_btn = Button.new()
		_redo_btn.name = "RedoBtn"
		_redo_btn.text = "↷"
		_redo_btn.tooltip_text = "Redo (Ctrl+Shift+%s)" % OS.get_keycode_string(GameState.undo_keycode)
		_redo_btn.add_theme_font_size_override("font_size", 16)
		_redo_btn.custom_minimum_size = Vector2(32, 0)
		_redo_btn.offset_top = TOP_Y + 8.0
		_redo_btn.pressed.connect(_redo_builder_action)
		ui_layer.add_child(_redo_btn)
	_position_furniture_menu_btn()
	_position_top_left_icons()
	_position_undo_btn()
	_position_minimap()
	_position_budget_label()
	_refresh_undo_redo_buttons()


# Floats Test Layout and the gear menu in the top-left/top-right corners —
# all that's left up here now that Budget/view-mode/tenant info moved off the
# old full-width TopBar. Test Layout stacks directly below the Furniture
# button (see _position_furniture_menu_btn) instead of sharing its slot —
# both only ever coexist on levels with foldable furniture and no moments.
func _position_top_left_icons() -> void:
	if is_instance_valid(_test_btn):
		_test_btn.offset_left = LEFT_X + 8.0
		_test_btn.offset_top  = TOP_Y
		if is_instance_valid(_furniture_menu_btn):
			_test_btn.offset_top = _furniture_menu_btn.offset_bottom + 8.0
	if is_instance_valid(_settings_btn):
		_settings_btn.offset_right = RIGHT_X - 8.0
		_settings_btn.offset_left  = _settings_btn.offset_right - (_settings_btn.custom_minimum_size.x as float)
		_settings_btn.offset_top   = TOP_Y


# Floats just above the TenantCard bar, bottom-left — the mirror image of
# Minimap/ViewModeBox stacking above the bar on the right. Used to sit pinned
# to BOT_Y instead (from when TenantCard was a right-hand column starting at
# the old LEFT_X sidebar edge), which put it directly on top of the bar's own
# leftmost need icons once TenantCard started spanning from x=0. Unlike the
# full-width bar or the shrink-wrapped Minimap/ViewModeBox, this one wants its
# own natural (unstretched) size, so reset_size() is the right tool here —
# it's only wrong when something else already fixed a wider offset_right
# first (see _position_tenant_card()'s comment).
func _position_budget_label() -> void:
	if not is_instance_valid(budget_label):
		return
	budget_label.offset_left = 8.0
	budget_label.reset_size()
	# Capture the real (small) minimum height BEFORE touching offset_top/
	# offset_bottom below — Control's offset_top/offset_bottom/size are three
	# views of the same live state, so writing offset_bottom first and then
	# reading .size.y back out returns a value already corrupted by the still-
	# stale offset_top, not the natural content height reset_size() just gave it.
	var h := budget_label.size.y
	var gap := 8.0
	budget_label.offset_bottom = tenant_card.offset_top - gap
	budget_label.offset_top    = budget_label.offset_bottom - h
	ui_layer.move_child(budget_label, ui_layer.get_child_count() - 1)
	_position_comfort_meter()


const COMFORT_METER_SIZE := Vector2(210.0, 22.0)  # wide enough for "Comfort 100% — can't rent like this"

func _ensure_comfort_meter() -> void:
	if is_instance_valid(_comfort_meter):
		return
	_comfort_meter = ComfortMeterScript.new()
	_comfort_meter.name = "ComfortMeter"
	_comfort_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_comfort_meter.custom_minimum_size = COMFORT_METER_SIZE
	_comfort_meter.size = COMFORT_METER_SIZE
	ui_layer.add_child(_comfort_meter)


# Stacks directly above the Budget pill, same "gap above whatever's below it"
# approach _position_budget_label() itself uses against tenant_card.
func _position_comfort_meter() -> void:
	if not is_instance_valid(_comfort_meter) or not _comfort_meter.visible:
		return
	if not is_instance_valid(budget_label):
		return
	var gap := 6.0
	_comfort_meter.offset_left   = 8.0
	_comfort_meter.offset_right  = 8.0 + COMFORT_METER_SIZE.x
	_comfort_meter.offset_bottom = budget_label.offset_top - gap
	_comfort_meter.offset_top    = _comfort_meter.offset_bottom - COMFORT_METER_SIZE.y
	ui_layer.move_child(_comfort_meter, ui_layer.get_child_count() - 1)


# Only worth showing on a level that actually uses the mechanic — a level
# with no yellow-tier furniture at all would just show a permanent, mute
# "Comfort 100%" that explains nothing. Called from _refresh_functions()
# alongside every other post-move recompute.
func _update_comfort_meter() -> void:
	var has_yellow := false
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			if (f as Furniture).mobility_tier == "yellow":
				has_yellow = true
				break
		if has_yellow:
			break
	if not has_yellow:
		if is_instance_valid(_comfort_meter):
			_comfort_meter.visible = false
		return
	_ensure_comfort_meter()
	_comfort_meter.visible = true
	_comfort_meter.set_value(gm.comfort_pct, gm.COMFORT_WARN_THRESHOLD)
	_position_comfort_meter()


static func _segment_style(bg: Color, border: Color, index: int, count: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.anti_aliasing = true
	s.set_content_margin(SIDE_LEFT, 12)
	s.set_content_margin(SIDE_RIGHT, 12)
	s.set_content_margin(SIDE_TOP, 5)
	s.set_content_margin(SIDE_BOTTOM, 5)
	var r_left := 9 if index == 0 else 0
	var r_right := 9 if index == count - 1 else 0
	s.corner_radius_top_left     = r_left
	s.corner_radius_bottom_left  = r_left
	s.corner_radius_top_right    = r_right
	s.corner_radius_bottom_right = r_right
	return s


func _go_back() -> void:
	# Always Projects — a real player only ever reaches Main via CityMap in
	# the first place, and the menu shouldn't offer (or silently take) a path
	# back into the Level Editor even during a designer's Test Level session.
	# Leaving this way ends the test session outright, same as quitting the
	# game mid-test would — "← Back to Editor" is the only path that resumes
	# it (see GameState.testing_from_editor).
	GameState.testing_from_editor = false
	Transition.change_scene("res://scenes/CityMap.tscn")


# Discoverable escape hatch for a bad layout (spent the budget on the wrong
# things, boxed furniture in unreachably, etc.) — an incomplete level never
# persists its furniture (GameState only saves a layout on a level a player
# has already won at least once), so this is just _load_level() again, same
# as leaving to Projects and re-entering would already do, minus the detour.
func _restart_level() -> void:
	_load_level(_current_level_id)


func _load_level(level_id: String) -> void:
	_level_load_id += 1
	var _load_gen := _level_load_id
	# GDScript has no try/finally, so an error thrown partway through a
	# nested transition would leave this stuck true and silently swallow
	# every later mini-plan click. Any completed level load means no
	# transition is in flight any more, so it's safe to clear here.
	_nested_transition_busy = false
	_current_level_id  = level_id
	if is_instance_valid(_editor_back_btn):
		# Stays visible through the WHOLE test session, not just while on the
		# root ("_custom") level — GameState.testing_from_editor is set once
		# by LevelEditor._test_level() and only cleared by leaving to
		# CityMap or actually using this button, so it survives navigating
		# into/out of any number of nested boxes in between.
		_editor_back_btn.visible = GameState.testing_from_editor
	gm.load_level(level_id)
	tenant_card.set_rented(false)
	_post_win_view   = false
	_rent_auto_armed = false
	_level_completed = false
	Furniture.read_only     = false
	WallInspector.read_only = false
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = false
	_close_furniture_menu()
	if is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn.visible = true
	_last_wall_click_by_floor.clear()
	_builder_undo_stack.clear()
	_last_furniture_state = {}
	_restoring_furniture  = true   # level-load spawning shouldn't itself become undoable

	_active_paint_type = ""
	_painting          = false
	_paint_pieces      = {}
	if is_instance_valid(_paint_panel):
		_paint_panel.queue_free()
		_paint_panel = null
	_paint_status_lbl = null

	for fid in _floors:
		var _old_floor := _floors[fid] as Floor
		# remove_child() first (immediate) — queue_free() alone is deferred to
		# end-of-frame, so the old Floor node (e.g. "fl_0" from whatever level
		# we're leaving) was still a child of `room` when the new level's own
		# "fl_0" got add_child()'d moments later in the same frame. Godot
		# auto-uniquifies the name to avoid the collision (e.g. "fl_0@2"),
		# which silently broke _fit_floor()'s `fid := apt_floor.name` lookup
		# into _floor_tile_bounds (keyed by the clean id) — falling back to
		# fitting the whole apartment grid instead of the actual room. Only
		# reproduced on a direct multi-level nested jump (skipping levels in
		# one call, fast enough that the deferred free hadn't run yet); a
		# normal single-hop transition already had enough frames in between.
		room.remove_child(_old_floor)
		_old_floor.queue_free()
	_floors.clear()
	_loft_floors.clear()
	_floor_below_id.clear()

	var level: Dictionary = gm.current_level
	var apt_data: Dictionary = level["apartment"] as Dictionary
	var floors_data: Array = apt_data["floors"]
	var apt_gw: int = apt_data.get("grid_w", 40) as int
	var apt_gh: int = apt_data.get("grid_h", 30) as int

	var _floor_z := 0  # accumulates global Z as we walk floors bottom→top
	var _last_floor_fd: Dictionary = {}  # most recent "floor"-type data, for floor-stair openings
	for fd in floors_data:
		var apt_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
		apt_floor.name = fd["id"]
		room.add_child(apt_floor)
		# grid_w/h live at apartment level now — inject before setup
		(fd as Dictionary)["grid_w"] = apt_gw
		(fd as Dictionary)["grid_h"] = apt_gh
		# Subfloor/ceiling floors have floor_tiles cleared at export time —
		# they borrow the parent floor's tiles so they draw the same outline.
		var _ftype := (fd as Dictionary).get("type", "") as String
		if _ftype in ["floor_sub", "ceiling"] and ((fd as Dictionary).get("floor_tiles", []) as Array).is_empty():
			var _pid := (fd as Dictionary).get("parent_id", "") as String
			for _pfd in floors_data:
				if (_pfd as Dictionary).get("id", "") == _pid:
					(fd as Dictionary)["floor_tiles"] = (_pfd as Dictionary).get("floor_tiles", [])
					break
		# Loft floors inherit from their parent floor:
		#  • floor_tiles    ← parent's mezzanine_tiles
		#  • stair_openings ← parent's loft-targeted stairs only
		#  • segments = []  ← forces _use_new_format = true
		if _ftype == "loft":
			var _lpid := (fd as Dictionary).get("parent_id", "") as String
			for _lpfd in floors_data:
				if (_lpfd as Dictionary).get("id", "") == _lpid:
					(fd as Dictionary)["floor_tiles"] = (_lpfd as Dictionary).get("mezzanine_tiles", [])
					var _all := (_lpfd as Dictionary).get("stairs", []) as Array
					(fd as Dictionary)["stair_openings"] = _all.filter(func(s) -> bool:
						return (s as Dictionary).get("target", "loft") != "floor")
					if not (fd as Dictionary).has("segments"):
						(fd as Dictionary)["segments"] = []
					break
			_floor_below_id[fd["id"]] = _lpid
		# Regular floors above the ground floor get floor-stair openings from the floor below
		elif _ftype == "floor" and not _last_floor_fd.is_empty():
			var _below_stairs := _last_floor_fd.get("stairs", []) as Array
			var _fso := _below_stairs.filter(func(s) -> bool:
				return (s as Dictionary).get("target", "loft") == "floor")
			if not _fso.is_empty():
				if not (fd as Dictionary).has("stair_openings"):
					(fd as Dictionary)["stair_openings"] = []
				((fd as Dictionary)["stair_openings"] as Array).append_array(_fso)
			_floor_below_id[fd["id"]] = _last_floor_fd["id"] as String
		if _ftype == "floor":
			_last_floor_fd = fd
		apt_floor.setup(fd)
		apt_floor.floor_z_offset = _floor_z
		if _ftype == "floor": _floor_z += Floor.FLOOR_HEIGHT_TILES
		apt_floor.furniture_changed.connect(_on_furniture_changed)
		apt_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(apt_floor))
		apt_floor.visible = false
		_floors[fd["id"]] = apt_floor
		if fd["id"] in _floor_below_id:
			apt_floor.below_floor = _floors.get(_floor_below_id[fd["id"]] as String) as Floor

		for sf in fd.get("starting_furniture", []):
			_spawn_furniture(sf["id"], apt_floor, sf["x"], sf["y"], sf as Dictionary)

	# Top-level starting_furniture (from level editor) → place on first ground floor
	var first_floor_node: Floor = null
	for _ffd in floors_data:
		if (_ffd as Dictionary).get("type", "") == "floor":
			var _ffid := (_ffd as Dictionary)["id"] as String
			if _ffid in _floors:
				first_floor_node = _floors[_ffid] as Floor
				break
	if first_floor_node and not gm.starting_furniture.is_empty():
		for sf in gm.starting_furniture:
			_spawn_furniture((sf as Dictionary)["id"] as String,
				first_floor_node,
				(sf as Dictionary)["x"] as int,
				(sf as Dictionary)["y"] as int,
				sf as Dictionary)

	# Nested/parabox: if this level was reached by entering a box, dim its
	# daylight by however much the parent's furniture was blocking the box
	# from outside (see _compute_box_occlusion()) — a real cross-frame effect,
	# not just cosmetic on the child's own window rendering.
	if first_floor_node and not _nested_stack.is_empty():
		first_floor_node.set_external_daylight_factor(_current_nested_daylight_factor)
	_refresh_nested_plan_panel()
	_update_breadcrumb()

	# Compute bounding box of painted tiles per floor for focused camera fit
	_floor_tile_bounds.clear()
	for _bfd in floors_data:
		var _bfd_d := _bfd as Dictionary
		var _bfid  := _bfd_d["id"] as String
		var _btype := _bfd_d.get("type", "floor") as String
		var _btiles: Array = []
		match _btype:
			"loft":
				var _bpid := _bfd_d.get("parent_id", "") as String
				for _bpfd in floors_data:
					if (_bpfd as Dictionary)["id"] == _bpid:
						_btiles = (_bpfd as Dictionary).get("mezzanine_tiles", []) as Array; break
			"floor_sub", "ceiling":
				var _bpid := _bfd_d.get("parent_id", "") as String
				for _bpfd in floors_data:
					if (_bpfd as Dictionary)["id"] == _bpid:
						_btiles = (_bpfd as Dictionary).get("floor_tiles", []) as Array; break
			_:
				_btiles = _bfd_d.get("floor_tiles", []) as Array
		if _btiles.is_empty():
			continue
		var _bx0 := 999999; var _by0 := 999999
		var _bx1 := -999999; var _by1 := -999999
		for _bt in _btiles:
			var _btx := (_bt as Array)[0] as int; var _bty := (_bt as Array)[1] as int
			_bx0 = min(_bx0, _btx); _by0 = min(_by0, _bty)
			_bx1 = max(_bx1, _btx); _by1 = max(_by1, _bty)
		_floor_tile_bounds[_bfid] = Rect2i(_bx0, _by0, _bx1 - _bx0 + 1, _by1 - _by0 + 1)

	var hidden_floors: Array = level["apartment"].get("hidden_floors", []) as Array
	minimap.setup(floors_data, hidden_floors)
	_position_minimap()
	_active_moment_id = ""
	Furniture.test_mode_active = false
	Furniture.active_moment_id = ""
	Furniture.all_moment_ids = gm.moments.map(func(m): return (m as Dictionary)["id"] as String)
	Furniture.moment_labels = {}
	for m in gm.moments:
		var md := m as Dictionary
		Furniture.moment_labels[md["id"] as String] = md.get("label", md["id"]) as String
	tenant_card.setup(level["tenant"])
	tenant_card.setup_moments(gm.moments)
	if not gm.moments.is_empty():
		var _first_mid := (gm.moments[0] as Dictionary)["id"] as String
		_on_moment_selected(_first_mid)
	inventory.setup(gm)
	var shop_list: Array = gm.furniture_data["furniture"]
	if not gm.allowed_furniture.is_empty():
		shop_list = shop_list.filter(func(f): return (f["id"] as String) in gm.allowed_furniture)
	inventory.populate(shop_list)
	if not gm.starting_inventory.is_empty():
		inventory.populate_owned(gm.starting_inventory, gm.furniture_data["furniture"])
	budget_label.text = "Budget: %d€" % gm.budget
	wall_inspector.setup(gm.furniture_data["furniture"])

	# Start on the first visible floor (skip hidden ones)
	var first_visible_id := floors_data[0]["id"] as String
	for _fd in floors_data:
		if not ((_fd as Dictionary)["id"] as String in hidden_floors):
			first_visible_id = (_fd as Dictionary)["id"] as String; break
	_switch_floor(first_visible_id)
	_update_floor_locks()
	_refresh_functions()
	_update_accessibility()

	# Auto-enable overlay for subfloor / ceiling floor types (no toggle buttons needed)
	for _afd in floors_data:
		var _aftype := (_afd as Dictionary).get("type", "") as String
		var _afid   := (_afd as Dictionary)["id"] as String
		if not _floors.has(_afid): continue
		var _agd := (_floors[_afid] as Floor).get_node_or_null("GridDraw") as GridDraw
		if _agd:
			if _aftype == "floor_sub": _agd.show_subfloor = true
			elif _aftype == "ceiling": _agd.show_ceiling  = true

	# Update test button visibility now that floors are loaded.
	# Levels with moments drive fold interaction via the moment selector instead —
	# the manual Test Layout toggle would be redundant there.
	if is_instance_valid(_test_btn):
		_test_btn.visible = _has_foldable_furniture() and gm.moments.is_empty()

	# "Revisar Plano Actual" — CityMap sets this one-shot flag right before
	# switching scenes when the player picks up a previously-won level instead
	# of a fresh one. Consumed here regardless of outcome so it never leaks
	# into the next level load.
	var _use_saved := GameState.pending_use_saved_layout
	GameState.pending_use_saved_layout = false
	if _use_saved and GameState.has_level_layout(level_id):
		_restore_furniture_snapshot(GameState.get_level_layout(level_id))
		# The restore replaced every piece of furniture (including any nested
		# box) after the cards above were built — rebuild them against what's
		# actually on the floor now.
		_refresh_nested_plan_panel()
	else:
		_restoring_furniture  = false
		_last_furniture_state = _snapshot_all_furniture()

	# _set_view_mode is normally only triggered by clicking a mode button —
	# applying it once here makes the default mode's layout (hidden/docked
	# Wall Inspector, 3D pane, divider) actually match on first load instead
	# of relying on whatever Main.tscn's static node visibility happens to be.
	_set_view_mode(_view_mode)

	var paintable := gm.current_level.get("paintable_furniture", []) as Array
	if not paintable.is_empty():
		_build_paint_panel(paintable)

	_show_mechanic_intro_if_needed()
	_refresh_undo_redo_buttons()
	# Establish the correct disabled/available baseline from however the level
	# actually loaded (freshly, or via "Revisar Plano Actual" resuming an
	# already-satisfied saved layout) BEFORE arming auto-rent, so the
	# was-disabled→now-enabled EDGE below doesn't trip the instant this loads
	# — only a real, subsequent change the player makes can fire it that way.
	# (Reopening an already-won layout still shows the Results screen once,
	# explicitly, via _show_existing_completion below — just not through this
	# edge-triggered path.)
	_update_rent_btn()
	_rent_auto_armed = true

	# "Revisar Plano Actual" reopens a level the player already won — land
	# them back on the same Results screen they saw the first time instead of
	# dropping them silently into edit mode with only a generic gear menu as
	# a cue. Fired without awaiting (never `await`ed by _load_level itself)
	# so a Restart Level pressed mid-reveal can freely re-enter _load_level
	# while this is still suspended — _show_existing_completion checks
	# _load_gen against _level_load_id after every await so a stale tail is a
	# harmless no-op instead of popping a results screen for a level that no
	# longer matches what's on screen.
	if _use_saved and gm.check_win():
		_show_existing_completion(level_id, _load_gen)


# See _load_level's call site above for why this is fire-and-forget with a
# generation check rather than something _load_level awaits directly.
func _show_existing_completion(level_id: String, load_gen: int) -> void:
	tenant_card.set_rented(true)
	await _play_completion_reveal()
	if load_gen != _level_load_id:
		return
	_level_completed = true
	result_screen.show_success(
		GameState.get_stars(level_id),
		0,
		GameState.portfolio_rent,
		gm.current_level["tenant"]["name"],
		gm.current_level["tenant"]["monthly_rent"] as int,
		not gm.get_next_owned_level_id(level_id).is_empty())


func _show_mechanic_intro_if_needed() -> void:
	var intro: Dictionary = gm.current_level.get("mechanic_intro", {}) as Dictionary
	if intro.is_empty():
		return
	var lid := gm.current_level.get("id", "") as String
	if lid in GameState.completed:
		return  # already played this level — skip intro

	# Build fullscreen CanvasLayer overlay
	var cl := CanvasLayer.new()
	cl.layer = 20
	add_child(cl)
	_intro_modal_open = true
	cl.tree_exited.connect(func(): _intro_modal_open = false)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)

	# Card panel (480×300, centred)
	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
	cs.border_color = Color(0.30, 0.80, 0.60, 0.80)
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(6)
	cs.set_content_margin_all(28)
	card.add_theme_stylebox_override("panel", cs)
	card.position           = Vector2(400, 210)
	card.custom_minimum_size = Vector2(480, 300)
	cl.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.add_child(vb)

	# "NEW MECHANIC" chip
	var chip := Label.new()
	chip.text = "  NEW MECHANIC  "
	chip.add_theme_font_size_override("font_size", 9)
	chip.add_theme_color_override("font_color", Color(0.120, 0.100, 0.080))
	var chip_s := StyleBoxFlat.new()
	chip_s.bg_color = Color(0.30, 0.80, 0.60)
	chip_s.set_corner_radius_all(3)
	chip.add_theme_stylebox_override("normal", chip_s)
	vb.add_child(chip)

	# Title
	var title_lbl := Label.new()
	title_lbl.text = intro.get("title", "") as String
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(title_lbl)

	# Body
	var body_lbl := Label.new()
	body_lbl.text = intro.get("body", "") as String
	body_lbl.add_theme_font_size_override("font_size", 13)
	body_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(body_lbl)

	# Dismiss button
	var btn := Button.new()
	btn.text = "Got it — let's go!"
	btn.add_theme_font_size_override("font_size", 13)
	var rs := GameTheme.make_rent_btn_style()
	btn.add_theme_stylebox_override("normal",  rs[0])
	btn.add_theme_stylebox_override("hover",   rs[1])
	btn.add_theme_stylebox_override("pressed", rs[1])
	btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	btn.pressed.connect(func(): cl.queue_free())
	vb.add_child(btn)

	# Also dismiss on click outside card (a real click, not a wheel tick —
	# InputEventMouseButton covers both, and wheel scroll must never dismiss
	# or otherwise affect anything behind this modal)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			cl.queue_free())


func _spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int, rail_data: Dictionary = {}) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return null
	# Apply per-instance overrides set by the level editor (rail axis/extents,
	# or which level a nested/parabox box's interior points at).
	var rail_keys := ["rail_axis", "rail_start", "rail_end", "reveal_start", "reveal_end", "reveal_functions", "child_level_id"]
	for key in rail_keys:
		if rail_data.has(key):
			fdata = fdata.duplicate()
			break
	for key in rail_keys:
		if rail_data.has(key):
			fdata[key] = rail_data[key]
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	# Trust the explicit coordinates from the level editor; skip can_place so the
	# furniture lands exactly where the designer placed it regardless of floor-tile
	# bounds checks (the editor validated the position visually).
	apt_floor.place_furniture(f, Vector2i(gx, gy))
	# The level's authored starting position — the reference comfort scoring
	# compares a yellow piece's current position against (see mobility_tier).
	f._home_grid_pos = Vector2(gx, gy)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())
	if f.has_own_moment_position():
		f.placed.connect(func(_n): _refresh_functions())
	if fdata.get("creates_loft", false):
		_promote_to_loft(f, apt_floor)
	return f


# ─── Nested / parabox levels ──────────────────────────────────────────────
# A "box" is an ordinary placed Furniture (is_nested_box=true, see
# furniture.json) whose child_level_id points at a full separate level. Its
# interior is played as its own independent level session — a genuinely
# separate grid/floor/camera, so the child apartment's own "down" is never
# affected by the box's position/rotation in the parent (gravity preserved
# by construction, not by any explicit compensation code). See
# docs/design_nested_levels.md for the fuller design writeup and the
# alternatives that were considered (real portal rendering, live miniatures).
# A shoebox's whole point is being tiny on the outside — but its interior
# still has to be a livable apartment, not a closet. Same tile→metres
# convention as ThumbnailRenderer/Room3DView's TILE_M (10 tiles = 1m, so
# 1 tile² = 0.01 m²).
const MIN_NESTED_INTERIOR_M2 := 20.0
const TILE_M2 := 0.01

func _on_box_entered(box: Furniture) -> void:
	if _nested_transition_busy or not is_instance_valid(box) or box.child_level_id.is_empty():
		return
	# Defensive: a box pointing at the level it's already sitting in (self-
	# reference, or a cycle further back up _nested_stack) would push onto
	# the stack forever without ever actually changing level, growing an
	# extra "exit" card on every single click. Shouldn't happen now that
	# child_level_id survives every snapshot/restore path, but refuse
	# outright rather than let it happen silently if it ever does again.
	if box.child_level_id == _current_level_id:
		push_warning("Nested box points at its own level (%s) — refusing to enter" % box.child_level_id)
		return
	for ctx in _nested_stack:
		if (ctx as Dictionary)["parent_level_id"] == box.child_level_id:
			push_warning("Nested box would create a cycle back to %s — refusing to enter" % box.child_level_id)
			return
	var area := _level_floor_area_m2(box.child_level_id)
	if area < MIN_NESTED_INTERIOR_M2:
		Audio.play("error")
		push_warning("Nested level '%s' is only %.1f m² — needs at least %.0f m² to be enterable" %
			[box.child_level_id, area, MIN_NESTED_INTERIOR_M2])
		return
	_nested_transition_busy = true
	var factor := _compute_box_occlusion(box)
	_level_state_cache[_current_level_id] = _snapshot_level_state()
	# Remembers whether the level being left was in post-win "Watch Again"
	# (tenant showcase looping in read-only 3D) so stepping back out of the
	# box can resume it — _load_level() unconditionally resets
	# _post_win_view to false for the level it's loading, which otherwise
	# silently killed the showcase the moment you stepped into any box.
	var was_showcasing := _post_win_view
	_nested_stack.append({
		"parent_level_id": _current_level_id,
		"daylight_factor": factor,
		"was_post_win_view": was_showcasing,
	})
	_current_nested_daylight_factor = factor
	_load_level(box.child_level_id)
	if _level_state_cache.has(box.child_level_id):
		_apply_level_state_snapshot(_level_state_cache[box.child_level_id])
	# The box's own interior gets its own tenant too — if you were watching
	# the parent's tenant use its furniture, stepping into a box shouldn't
	# just make tenants vanish. Only if the child level is itself actually
	# won (gm.check_win()) — an unfinished nested apartment has no tenant to
	# showcase yet, same as any other not-yet-completed level.
	if was_showcasing and gm.check_win():
		_on_watch_again_reveal()
	_nested_transition_busy = false


# Looks up a level's full dict by id without loading it — "_custom" reads
# GameState's in-progress editor/test level, anything else searches
# gm.levels_data. Shared by the nested-plan panel and the min-area check.
func _lookup_level_dict(level_id: String) -> Dictionary:
	if level_id == "_custom":
		return GameState.custom_level_data
	for lv in gm.levels_data.get("levels", []) as Array:
		if (lv as Dictionary).get("id", "") == level_id:
			return lv as Dictionary
	return {}


func _level_display_name(level_id: String) -> String:
	var ld := _lookup_level_dict(level_id)
	return ld.get("name", level_id) as String


# Same wall-segment bounding-box extraction CityMap.gd's own blueprint
# preview uses (CityMap._floor_plan_data) — duplicated rather than shared
# since CityMap isn't a node Main.gd has a reference to.
func _floor_plan_data(ld: Dictionary) -> Dictionary:
	var floors := (ld.get("apartment", {}) as Dictionary).get("floors", []) as Array
	for fd in floors:
		var f := fd as Dictionary
		if f.get("type", "") != "floor":
			continue
		var segs := f.get("segments", []) as Array
		if not segs.is_empty():
			var min_x := INF; var max_x := -INF
			var min_y := INF; var max_y := -INF
			for sg in segs:
				var s := sg as Dictionary
				min_x = minf(min_x, minf(s.get("x1", 0.0) as float, s.get("x2", 0.0) as float))
				max_x = maxf(max_x, maxf(s.get("x1", 0.0) as float, s.get("x2", 0.0) as float))
				min_y = minf(min_y, minf(s.get("y1", 0.0) as float, s.get("y2", 0.0) as float))
				max_y = maxf(max_y, maxf(s.get("y1", 0.0) as float, s.get("y2", 0.0) as float))
			return {"segments": segs, "bounds": Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))}
		# No wall segments (a floor painted with just the Floor Paint tool,
		# never given real walls via Primary Wall) — fall back to the painted
		# tiles themselves so the room still reads as something on the
		# sketch instead of going completely blank.
		var tiles := f.get("floor_tiles", []) as Array
		if not tiles.is_empty():
			var tmin_x := INF; var tmax_x := -INF
			var tmin_y := INF; var tmax_y := -INF
			for t in tiles:
				var tx := (t as Array)[0] as float; var ty := (t as Array)[1] as float
				tmin_x = minf(tmin_x, tx); tmax_x = maxf(tmax_x, tx + 1.0)
				tmin_y = minf(tmin_y, ty); tmax_y = maxf(tmax_y, ty + 1.0)
			return {"segments": [], "bounds": Rect2(Vector2(tmin_x, tmin_y), Vector2(tmax_x - tmin_x, tmax_y - tmin_y))}
	return {"segments": [], "bounds": Rect2()}


# Furniture rects for the blueprint preview — prefers a cached live-state
# snapshot (see _snapshot_level_state()) over the level's authored
# starting_furniture, so the mini-plan reflects what the player actually
# built in there, not just how the level started out.
func _furniture_preview_rects_for(level_id: String, ld: Dictionary) -> Array:
	var items: Array = []
	var cached := _level_state_cache.get(level_id, {}) as Dictionary
	if not cached.is_empty():
		for fid in (cached.get("floors", {}) as Dictionary):
			items.append_array((cached["floors"] as Dictionary)[fid] as Array)
	else:
		items.append_array(ld.get("starting_furniture", []) as Array)
		for fd in (ld.get("apartment", {}) as Dictionary).get("floors", []) as Array:
			items.append_array((fd as Dictionary).get("starting_furniture", []) as Array)
	var out: Array = []
	for it in items:
		var d := it as Dictionary
		var fdata := gm.get_furniture_by_id(d.get("id", "") as String)
		if fdata.is_empty():
			continue
		var sz := fdata.get("size", {}) as Dictionary
		out.append({
			"x": d.get("x", 0) as float, "y": d.get("y", 0) as float,
			"w": float(sz.get("w", 4) as int), "h": float(sz.get("h", 4) as int),
			"color": Color("#" + (fdata.get("color", "888888") as String)),
		})
	return out


# The row holding one "mini-plan card" per reachable space — an "exit to
# parent" card when inside a box (_nested_stack non-empty), plus one "enter
# this box" card for every is_nested_box in the CURRENT level
# (_collect_nested_boxes()). Both can be true at once (a box's interior can
# itself contain another box — arbitrary nesting depth, see
# docs/design_nested_levels.md), so this is a row, not a single panel.
func _ensure_nested_plan_row() -> void:
	if is_instance_valid(_nested_plan_row):
		return
	_nested_plan_row = HBoxContainer.new()
	_nested_plan_row.name = "NestedPlanRow"
	_nested_plan_row.add_theme_constant_override("separation", 6)
	_nested_plan_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Own CanvasLayer, above ui_layer's, rather than living in ui_layer and
	# fighting for sibling order there. Several things in ui_layer re-raise
	# THEMSELVES to the end after this row is positioned (_mode3d_view's
	# full-screen input-capturing viewport, _show_watch_done_button, the
	# Inventory...), and whichever ran last won — which is why neither a
	# z_index (Control input picking goes by tree order, not z_index) nor
	# re-raising the row at load time kept these cards clickable in the
	# post-completion "Revisar Plano Actual" view. CanvasLayer order IS
	# authoritative for both drawing and input picking, so a higher layer
	# wins outright no matter what any ui_layer sibling does afterward.
	var canvas := CanvasLayer.new()
	canvas.name  = "NestedPlanLayer"
	canvas.layer = 5   # ui_layer / ResultScreen are both the default layer 1
	add_child(canvas)
	canvas.add_child(_nested_plan_row)


# mode/index identify what THIS card does at click time (re-resolved fresh,
# never a baked closure — see the stale-lambda-capture bug this replaced):
# mode "exit" always calls _exit_nested_level(); mode "enter" looks up
# _collect_nested_boxes()[index] and calls _on_box_entered() on whatever is
# there right now, re-checked for validity first.
func _make_nested_plan_card(level_id: String, label: String, mode: String, index: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "NestedPlanCard"
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.tooltip_text = "Click to step into/out of this space"
	card.set_meta("mode", mode)
	card.set_meta("index", index)
	card.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_on_nested_plan_card_clicked(card)
			get_viewport().set_input_as_handled())

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(vb)

	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(88, 0)
	vb.add_child(lbl)

	var preview := BlueprintPreview.new()
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(preview)

	var level := _lookup_level_dict(level_id)
	if not level.is_empty():
		var plan := _floor_plan_data(level)
		preview.custom_minimum_size = _nested_plan_card_size(plan["bounds"] as Rect2)
		preview.set_data(plan["segments"] as Array, plan["bounds"] as Rect2,
			_furniture_preview_rects_for(level_id, level))
	else:
		preview.custom_minimum_size = Vector2(88, 66)
	return card


# Scales the card's blueprint preview to the level's actual floor area (in
# tiles, 10 tiles = 1m — same convention as everywhere else) so a big
# apartment reads as a bigger card than a small one, instead of every level
# getting the same fixed-size thumbnail regardless of how large it actually
# is. Sized by sqrt(area) (a linear "how big does this room feel" measure,
# not raw area) and clamped so neither a tiny nor a huge level breaks the
# floating row's layout.
const NESTED_CARD_MIN_DIM := 56.0
const NESTED_CARD_MAX_DIM := 150.0
const NESTED_CARD_PX_PER_SQRT_TILE := 2.4

func _nested_plan_card_size(bounds: Rect2) -> Vector2:
	var area := maxf(bounds.size.x * bounds.size.y, 1.0)
	var dim := clampf(sqrt(area) * NESTED_CARD_PX_PER_SQRT_TILE, NESTED_CARD_MIN_DIM, NESTED_CARD_MAX_DIM)
	var aspect := bounds.size.y / maxf(bounds.size.x, 1.0)
	if aspect >= 1.0:
		return Vector2(dim / aspect, dim)
	return Vector2(dim, dim * aspect)


func _on_nested_plan_card_clicked(card: PanelContainer) -> void:
	if _nested_transition_busy or not is_instance_valid(card):
		return
	var mode := card.get_meta("mode", "") as String
	if mode == "exit":
		var idx := card.get_meta("index", -1) as int
		_exit_nested_level_to(idx)
	elif mode == "enter":
		var idx := card.get_meta("index", -1) as int
		var boxes := _collect_nested_boxes()
		if idx >= 0 and idx < boxes.size():
			_on_box_entered(boxes[idx])


# Rebuilds every card in the row from scratch: one "exit to" card per level
# currently above this one on _nested_stack — not just the immediate parent,
# so two levels deep in a box shows a way back to EITHER the box one level up
# OR the top-level apartment directly, instead of forcing one click per level
# — plus one "enter" card per is_nested_box in the current level. Both sides
# can appear together (a box's interior containing its own box).
func _refresh_nested_plan_panel() -> void:
	_ensure_nested_plan_row()
	# remove_child (not just queue_free, which is deferred) so the old cards
	# are actually gone from get_children() before the fresh ones below are
	# added — otherwise every refresh call left the previous set still
	# parented until end of frame and the row just kept accumulating cards,
	# shifting everything left on each click instead of replacing them.
	for c in _nested_plan_row.get_children():
		_nested_plan_row.remove_child(c)
		c.queue_free()

	# Nearest ancestor first (leftmost) — the immediate parent is the most
	# likely destination, furthest ones (e.g. the top apartment) trail after.
	for i in range(_nested_stack.size() - 1, -1, -1):
		var target_id := (_nested_stack[i] as Dictionary)["parent_level_id"] as String
		_nested_plan_row.add_child(
			_make_nested_plan_card(target_id, "↩ " + _level_display_name(target_id), "exit", i))

	var boxes := _collect_nested_boxes()
	for i in boxes.size():
		var box := boxes[i]
		_nested_plan_row.add_child(_make_nested_plan_card(
			box.child_level_id, "↪ " + _level_display_name(box.child_level_id), "enter", i))

	_nested_plan_row.visible = _nested_plan_row.get_child_count() > 0
	_position_nested_plan_panel()


# Stacks directly above whatever's currently on top of the bottom-right
# column (ViewModeBox, or Minimap if ViewModeBox is hidden, or the
# TenantCard bar itself as a last resort) — same approach _position_view_mode_box()
# and _position_minimap() already use for each other.
func _position_nested_plan_panel() -> void:
	if not is_instance_valid(_nested_plan_row) or not _nested_plan_row.visible:
		return
	var right_edge := RIGHT_X - 8.0
	_nested_plan_row.offset_right = right_edge
	_nested_plan_row.offset_left  = right_edge - 230.0   # room for two cards side by side
	_nested_plan_row.reset_size()
	var content_w := maxf(_nested_plan_row.size.x, 90.0)
	_nested_plan_row.offset_left = right_edge - content_w
	var content_h := maxf(_nested_plan_row.size.y, 90.0)
	var top_of_stack: float
	if is_instance_valid(_view_mode_box) and _view_mode_box.visible:
		top_of_stack = _view_mode_box.offset_top
	elif is_instance_valid(minimap) and minimap.visible:
		top_of_stack = minimap.offset_top
	else:
		top_of_stack = tenant_card.offset_top
	_nested_plan_row.offset_bottom = top_of_stack - 8.0
	_nested_plan_row.offset_top    = _nested_plan_row.offset_bottom - content_h


# Total walkable floor area (m²) of a level's "floor"/"loft" floors, WITHOUT
# actually loading it — same floor_tiles/grid_w/grid_h fallback convention as
# Wall.gd's count_free_tiles_for_moment() (empty floor_tiles = whole grid is
# floor). Used to reject entering a nested box whose interior is too small
# before tearing down the current level to try.
func _level_floor_area_m2(level_id: String) -> float:
	var level := _lookup_level_dict(level_id)
	if level.is_empty():
		return 0.0
	var apt := level.get("apartment", {}) as Dictionary
	var gw := apt.get("grid_w", 0) as int
	var gh := apt.get("grid_h", 0) as int
	var total_tiles := 0
	for fd in apt.get("floors", []) as Array:
		var fdata := fd as Dictionary
		if fdata.get("type", "floor") as String not in ["floor", "loft"]:
			continue
		var tiles := fdata.get("floor_tiles", []) as Array
		total_tiles += tiles.size() if not tiles.is_empty() else gw * gh
	return total_tiles * TILE_M2


# Pops the stack all the way down to (and including) _nested_stack[index],
# landing on that ancestor directly — index doesn't have to be the last
# entry, so this also covers jumping straight from two levels deep to the
# top apartment in one click, skipping the level(s) in between.
func _exit_nested_level_to(index: int) -> void:
	if _nested_transition_busy or index < 0 or index >= _nested_stack.size():
		return
	_nested_transition_busy = true
	var ctx := _nested_stack[index] as Dictionary
	var target_id := ctx["parent_level_id"] as String
	var resume_post_win := ctx.get("was_post_win_view", false) as bool
	_nested_stack.resize(index)
	_level_state_cache[_current_level_id] = _snapshot_level_state()
	_current_nested_daylight_factor = 1.0
	_load_level(target_id)
	if _level_state_cache.has(target_id):
		_apply_level_state_snapshot(_level_state_cache[target_id])
	# _load_level() always resets _post_win_view to false — if the level
	# we're landing back on was in "Watch Again" (tenant showcase looping in
	# read-only 3D) before we stepped into the box, resume that exactly the
	# way _on_watch_again_reveal() first starts it, instead of leaving the
	# player looking at a silently-reset, editable, showcase-less level.
	if resume_post_win:
		_on_watch_again_reveal()
	_nested_transition_busy = false


# Convenience for the common single-level case (used nowhere critical
# anymore now the cards each carry their own target index, kept for clarity
# at call sites that only ever mean "one level up").
func _exit_nested_level() -> void:
	_exit_nested_level_to(_nested_stack.size() - 1)


# Captures every real (Furniture-backed) floor item across every floor of the
# CURRENT level, plus budget — enough to fully restore what the player left
# behind when a nested-level transition is about to tear this level down.
func _snapshot_level_state() -> Dictionary:
	var floors_snap: Dictionary = {}
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var items: Array = []
		for entry in fl.get_all_furniture():
			var fur := entry as Furniture
			var item := {
				"id": fur.furniture_id,
				"x": fur.grid_pos.x,
				"y": fur.grid_pos.y,
				"rot_steps": fur.rot_steps,
				"is_extended": fur.is_extended,
			}
			# A nested box's child_level_id is a per-instance override (set in
			# the level editor, or hand-authored like debug:_nested_child's
			# second shoebox pointing at debug:_nested_grandchild) — it lives
			# on the Furniture instance, not the catalog entry, so it has to
			# be captured here too or a restore below reverts it to the
			# catalog default, silently repointing the box at the wrong
			# level (or, worse, at itself if the catalog default happens to
			# be this same level).
			if fur.is_nested_box:
				item["child_level_id"] = fur.child_level_id
			items.append(item)
		floors_snap[fid] = items
	return {"budget": gm.budget, "floors": floors_snap}


# Wipes whatever the just-completed _load_level() spawned from the level's
# authored starting_furniture and replaces it with a previously captured
# _snapshot_level_state() — restoring the player's actual layout instead of
# the level's default one.
func _apply_level_state_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	gm.budget = snapshot.get("budget", gm.budget) as int
	gm.budget_changed.emit(gm.budget)
	# Freeing then respawning furniture one-by-one below fires
	# furniture_changed → _refresh_functions() → _update_rent_btn() on every
	# single step, and an in-between state (partway through respawning) can
	# spuriously look "complete" for a moment even when the final state
	# won't be — with _rent_auto_armed already true (set at the end of the
	# _load_level() call that happens right before this one runs), that edge
	# was firing the completion reveal on ordinary nested-level navigation.
	# Disarm for the duration of the rebuild, same as _load_level() already
	# does for its own initial spawn, and only re-evaluate once at the end.
	var _was_armed := _rent_auto_armed
	_rent_auto_armed = false
	var floors_snap := snapshot.get("floors", {}) as Dictionary
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for entry in fl.get_all_furniture().duplicate():
			var fur := entry as Furniture
			fl.remove_furniture(fur)
			fur.queue_free()
		for item in (floors_snap.get(fid, []) as Array):
			var d := item as Dictionary
			# d itself doubles as the override dict _spawn_furniture already
			# supports for rail_axis/etc — child_level_id (see
			# _snapshot_level_state()) rides along the same mechanism so a
			# restored box keeps pointing at whatever level it was actually
			# linked to, not the catalog's default.
			var f := _spawn_furniture(d["id"] as String, fl, roundi(d["x"] as float), roundi(d["y"] as float), d)
			if not is_instance_valid(f):
				continue
			var rs := d.get("rot_steps", 0) as int
			if rs != 0:
				f.set_rot_steps(rs)
			if d.get("is_extended", false) as bool and f.foldable:
				f.toggle_fold()
	_refresh_functions()
	_rent_auto_armed = _was_armed
	_update_rent_btn()


# How much daylight reaches the box's interior from outside, given the
# PARENT apartment's own furniture around the box's footprint — the concrete
# form of "un mueble del apartamento grande puede tapar la luz al apartamento
# pequeño de dentro". Scans a one-tile ring around the box for the tallest
# nearby piece: a "tall" neighbor blocks most of the light (this is a closed
# box after all, blocked doubly so), "medium" dims it partway, otherwise the
# box gets full daylight.
func _compute_box_occlusion(box: Furniture) -> float:
	var fl := box._wall_ref
	if not is_instance_valid(fl):
		return 1.0
	var x0 := floori(box.grid_pos.x) - 1
	var y0 := floori(box.grid_pos.y) - 1
	var x1 := x0 + box.grid_w + 2
	var y1 := y0 + box.grid_h + 2
	var worst := "low"
	for x in range(x0, x1):
		for y in range(y0, y1):
			var tile := Vector2i(x, y)
			var inside_box := x >= x0 + 1 and x < x1 - 1 and y >= y0 + 1 and y < y1 - 1
			if inside_box:
				continue
			for f in fl._placed_list(tile):
				var fur := f as Furniture
				if fur == box:
					continue
				if fur.height_category == "tall":
					worst = "tall"
				elif fur.height_category == "medium" and worst != "tall":
					worst = "medium"
	match worst:
		"tall":   return 0.15
		"medium": return 0.55
		_:        return 1.0


# ─── Runtime loft/mezzanine floors ────────────────────────────────────────────
# Loft/bunk beds carve out a mezzanine: the bed itself moves onto its own
# navigable "loft" floor (so it can be furnished around, from above), while the
# base floor keeps only a mezzanine-tile shadow marking where the slab sits —
# freeing those tiles for other furniture (desk, sofa, wardrobe...) underneath.

func _get_or_create_loft_floor(base_floor: Floor) -> Floor:
	var loft_id := base_floor.floor_id + "_loft"
	if loft_id in _floors and is_instance_valid(_floors[loft_id]):
		return _floors[loft_id] as Floor

	var floor_tiles: Array = []
	if not base_floor.floor_mask.is_empty():
		for t in base_floor.floor_mask:
			floor_tiles.append([(t as Vector2i).x, (t as Vector2i).y])
	else:
		var b := base_floor.get_room_bounds()
		for x in range(b.position.x, b.position.x + b.size.x):
			for y in range(b.position.y, b.position.y + b.size.y):
				floor_tiles.append([x, y])

	# Perimeter segments so wall edges can be clicked/inspected like any other floor
	var rb := base_floor.get_room_bounds()
	var rx0 := rb.position.x; var ry0 := rb.position.y
	var rx1 := rb.position.x + rb.size.x; var ry1 := rb.position.y + rb.size.y
	var loft_segments := [
		{"x1": rx0, "y1": ry0, "x2": rx1, "y2": ry0, "primary": true, "demolished": false},
		{"x1": rx1, "y1": ry0, "x2": rx1, "y2": ry1, "primary": true, "demolished": false},
		{"x1": rx1, "y1": ry1, "x2": rx0, "y2": ry1, "primary": true, "demolished": false},
		{"x1": rx0, "y1": ry1, "x2": rx0, "y2": ry0, "primary": true, "demolished": false},
	]

	var fd := {
		"id": loft_id,
		"label": base_floor.floor_label + " (Loft)",
		"type": "loft",
		"parent_id": base_floor.floor_id,
		"grid_w": base_floor.grid_w,
		"grid_h": base_floor.grid_h,
		"floor_tiles": floor_tiles,
		"segments": loft_segments,
	}

	var loft_floor: Floor = load("res://scenes/Wall.tscn").instantiate() as Floor
	loft_floor.name = loft_id
	room.add_child(loft_floor)
	loft_floor.setup(fd)
	loft_floor.floor_z_offset = base_floor.floor_z_offset + Floor.FLOOR_HEIGHT_TILES / 2
	loft_floor.furniture_changed.connect(_on_furniture_changed)
	loft_floor.furniture_changed.connect(_on_loft_furniture_changed.bind(base_floor, loft_floor))
	loft_floor.wall_edge_clicked.connect(_on_wall_edge_clicked.bind(loft_floor))
	loft_floor.visible = false
	_floors[loft_id] = loft_floor
	_loft_floors[base_floor.floor_id] = loft_floor

	if _floor_tile_bounds.has(base_floor.floor_id):
		_floor_tile_bounds[loft_id] = _floor_tile_bounds[base_floor.floor_id]
	else:
		_floor_tile_bounds[loft_id] = base_floor.get_room_bounds()

	minimap.add_floor({"id": loft_id, "label": fd["label"]}, base_floor.floor_id)
	_position_minimap()
	return loft_floor


func _promote_to_loft(f: Furniture, base_floor: Floor) -> void:
	var loft_floor := _get_or_create_loft_floor(base_floor)
	var at := f.grid_pos
	if not loft_floor.can_place(f, at):
		return  # leave it on the base floor rather than risk an overlap up top

	base_floor._remove_from_grid(f)
	base_floor.remove_child(f)
	loft_floor.add_child(f)
	f._wall_ref = loft_floor
	loft_floor.place_furniture(f, at)

	if f.sell_requested.is_connected(_on_sell_pressed.bind(base_floor)):
		f.sell_requested.disconnect(_on_sell_pressed.bind(base_floor))
	f.sell_requested.connect(_on_sell_pressed.bind(loft_floor))


func _sync_loft_masks(base_floor: Floor, loft_floor: Floor) -> void:
	var tiles: Dictionary = {}
	for item in loft_floor.get_all_furniture():
		var f := item as Furniture
		var fdata := gm.get_furniture_by_id(f.furniture_id)
		if fdata.get("creates_loft", false):
			for t in f.get_occupied_tiles():
				tiles[t] = true
	base_floor.mezzanine_mask = tiles.duplicate()
	if base_floor.grid_draw:
		base_floor.grid_draw.queue_redraw()
	if tiles.is_empty():
		_remove_loft_floor(base_floor)


func _remove_loft_floor(base_floor: Floor) -> void:
	var loft_id := base_floor.floor_id + "_loft"
	if not (loft_id in _floors):
		return
	var loft_floor := _floors[loft_id] as Floor
	if not loft_floor.get_all_furniture().is_empty():
		return
	if _current_floor_id == loft_id:
		_switch_floor(base_floor.floor_id)
	_floors.erase(loft_id)
	_loft_floors.erase(base_floor.floor_id)
	_floor_tile_bounds.erase(loft_id)
	minimap.remove_floor(loft_id)
	loft_floor.queue_free()


func _on_loft_furniture_changed(base_floor: Floor, loft_floor: Floor) -> void:
	_sync_loft_masks(base_floor, loft_floor)


func _switch_floor(floor_id: String) -> void:
	if _current_floor_id in _floors:
		(_floors[_current_floor_id] as Floor).visible = false
	_current_floor_id = floor_id
	if floor_id in _floors:
		var apt_floor := _floors[floor_id] as Floor
		apt_floor.visible = true
		_fit_floor(apt_floor, true)
	minimap.highlight(floor_id)
	# The 2D `room` node's per-floor visibility toggle above does nothing for
	# the 3D view — it only ever shows whatever floor it was last built from,
	# so switching floor tabs (e.g. base <-> the loft a bunk/loft bed creates)
	# while already in 3D mode silently kept showing the stale floor. Rebuild
	# it for the newly-selected floor.
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()


# Recomputes the "fit to view" baseline (scale/position) for the given floor.
# `reset_view`: true on an actual floor switch (snaps back to fit, clearing
# any manual zoom/pan); false when only the available width changed (e.g.
# dragging the floor/wall split), which re-fits without losing the player's
# current zoom/pan.
func _fit_floor(apt_floor: Floor, reset_view: bool = false) -> void:
	const H_PAD  := 32.0
	const V_PAD  := 24.0
	const PAD_T  := 3     # tile padding around apartment content

	var avail_w := (RIGHT_X - LEFT_X) - H_PAD * 2
	var avail_h := (_floor_pane_bottom_y() - TOP_Y) - V_PAD * 2

	var fw: float; var fh: float
	var off_x := 0.0;   var off_y := 0.0

	var fid := apt_floor.name as String
	if _floor_tile_bounds.has(fid):
		var bounds := _floor_tile_bounds[fid] as Rect2i
		fw    = float((bounds.size.x + PAD_T * 2) * TILE_SIZE)
		fh    = float((bounds.size.y + PAD_T * 2) * TILE_SIZE)
		off_x = float((bounds.position.x - PAD_T) * TILE_SIZE)
		off_y = float((bounds.position.y - PAD_T) * TILE_SIZE)
	else:
		fw = apt_floor.grid_w * float(TILE_SIZE)
		fh = apt_floor.grid_h * float(TILE_SIZE)

	var s := minf(avail_w * FIT_PCT / fw, avail_h * FIT_PCT / fh)
	s = minf(s, 5.0)  # prevent over-zoom on tiny apartments

	_base_scale    = s
	_base_position = Vector2(
		LEFT_X + H_PAD + (avail_w - fw * s) * 0.5 - off_x * s,
		TOP_Y + V_PAD + (avail_h - fh * s) * 0.5 - off_y * s
	)
	if reset_view:
		_manual_zoom = 1.0
		_manual_pan  = Vector2.ZERO
	_apply_room_transform()


func _apply_room_transform() -> void:
	var total := _base_scale * _manual_zoom
	room.scale    = Vector2(total, total)
	room.position = _base_position + _manual_pan


# ── Floor plan / docked-panel split divider drag ───────────────────────────
func _on_divider_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_dragging_divider = (event as InputEventMouseButton).pressed


func _update_split(y: float) -> void:
	_split_y = clampf(y, MIN_SPLIT_Y, MAX_SPLIT_Y)
	var fl := _floors.get(_current_floor_id) as Floor
	if fl:
		_fit_floor(fl, false)
	_position_undo_btn()
	_position_minimap()


# Pins the floor-tab stack to the bottom-right corner of the play area, just
# left of the floating TenantCard column (same right_edge math as the Undo/
# Redo buttons). Sized generously tall and bottom-aligned (see Minimap.gd's
# set_compact) so it stays flush with that corner whether the level has 2
# floors or 6, instead of resizing itself and drifting around.
func _position_minimap() -> void:
	if not is_instance_valid(minimap):
		return
	_position_tenant_card()
	# Stacked bottom-right, directly above the TenantCard bar now that it
	# spans the bottom edge instead of sitting in a right-hand column.
	var right_edge := RIGHT_X - 8.0
	minimap.offset_right  = right_edge
	minimap.offset_left   = right_edge - 100.0   # rough placeholder — reset_size() below measures the real width
	# Shrink-wrapped to however many floor buttons the current level actually
	# has (reset_size() forces a fresh layout pass first) — a fixed tall box
	# left a big empty panel above a short 2-floor stack.
	minimap.reset_size()
	# reset_size() (Control.size = Vector2()) recomputes offset_RIGHT from
	# offset_left + minimum width, since anchor_left is the reference point —
	# it does NOT stretch offset_left leftward to accommodate a wider floor
	# name like "Ground Floor Mezzanine". Left uncorrected, a floor label
	# wider than the 100px placeholder above pushes the panel's right edge
	# past RIGHT_X, spilling text off the edge of the screen (exactly what
	# happened here). Re-pin offset_right to right_edge and derive offset_left
	# from the now-measured natural width instead of trusting the placeholder.
	var content_w := maxf(minimap.size.x, 60.0)
	minimap.offset_right = right_edge
	minimap.offset_left  = right_edge - content_w
	# Minimap.gd hides itself outright for a single-floor level (visible =
	# _buttons.size() > 1) — reserving its usual height/margin anyway left a
	# dead empty gap between the TenantCard bar and whatever floats above it
	# with nothing actually in it. Collapse the reserved band to zero so the
	# next thing up (ViewModeBox) touches the bar instead.
	var content_h := maxf(minimap.size.y, 40.0) if minimap.visible else 0.0
	var gap       := 8.0 if minimap.visible else 0.0
	minimap.offset_bottom = tenant_card.offset_top - gap
	minimap.offset_top    = minimap.offset_bottom - content_h
	ui_layer.move_child(minimap, ui_layer.get_child_count() - 1)
	_position_view_mode_box()
	_position_nested_plan_panel()


# TenantCard is now a bottom status bar (moments/needs + Budget), left-
# anchored and capped well short of the full play-area width — sized to
# whatever height its own content needs (like Minimap's shrink-wrap below).
func _position_tenant_card() -> void:
	if not is_instance_valid(tenant_card):
		return
	tenant_card.offset_left  = LEFT_X
	# Capped instead of stretched all the way to RIGHT_X — spanning the full
	# reclaimed width (once the docked Inventory sidebar went away) ran the
	# bar's own background directly under the Minimap/ViewModeBox floating in
	# the bottom-right corner, reading as visual clutter even though nothing
	# was actually overlapping. NOT reset_size() here — unlike Minimap/
	# ViewModeBox (which want to shrink to their natural content width), this
	# bar's own HFlowContainer rows wrap to whatever width they're given, so
	# reset_size() would collapse it to a single narrow column and force many
	# extra wrapped rows instead of measuring a natural unwrapped width.
	# get_combined_minimum_size() alone re-measures children at the CURRENT
	# (already-fixed-width) rect without touching offsets.
	tenant_card.offset_right = LEFT_X + minf(700.0, RIGHT_X - LEFT_X)
	var content_h := maxf(tenant_card.get_combined_minimum_size().y, 36.0)
	# Flush with the true bottom edge, no margin — this is a HUD bar sitting
	# on the screen's own edge (matching how the old TopBar sat flush at the
	# top), not a floating card that wants breathing room around it.
	tenant_card.offset_bottom = BOT_Y
	tenant_card.offset_top    = BOT_Y - content_h


# The Floor Plan/3D segmented toggle floats directly above whatever's next in
# the bottom-right stack — the Minimap floor tabs when there's more than one
# floor, or the TenantCard bar itself (touching it, no dead gap) when Minimap
# has hidden itself for a single-floor level.
func _position_view_mode_box() -> void:
	if not is_instance_valid(_view_mode_box):
		return
	# Same approach as _position_minimap(): fix left/right BEFORE reset_size()
	# (which recomputes size from offset_left, so reading offset_right back
	# out afterward isn't reliable) and only use the post-reset_size() height.
	var right_edge := RIGHT_X - 8.0
	_view_mode_box.offset_right = right_edge
	_view_mode_box.offset_left  = right_edge - 180.0
	_view_mode_box.reset_size()
	var content_h := maxf(_view_mode_box.size.y, 24.0)
	var gap := 8.0 if minimap.visible else 0.0
	_view_mode_box.offset_bottom = minimap.offset_top - gap
	_view_mode_box.offset_top    = _view_mode_box.offset_bottom - content_h
	ui_layer.move_child(_view_mode_box, ui_layer.get_child_count() - 1)


# Keeps the floating Undo/Redo buttons pinned to the top-right corner of the
# play area, just left of the gear menu button (both float independently now
# that the old full-width TopBar is gone).
func _position_undo_btn() -> void:
	if not is_instance_valid(_undo_btn):
		return
	var right_edge := RIGHT_X - 8.0
	if is_instance_valid(_settings_btn):
		right_edge = _settings_btn.offset_left - 8.0
	_undo_btn.offset_right = right_edge
	_undo_btn.offset_left  = right_edge - (_undo_btn.custom_minimum_size.x as float)
	_undo_btn.offset_top   = TOP_Y
	# The 3D view (and other full-width overlays) get added to ui_layer after
	# these buttons, which would otherwise draw over them and block their
	# clicks — settings_btn, _test_btn and budget_label need the same
	# re-raise as undo/redo, they were just missing here (that's why the
	# gear, Test Layout, and the budget counter could each vanish behind the
	# 3D view, e.g. every time a level restarts while already in 3D mode).
	if is_instance_valid(_settings_btn):
		ui_layer.move_child(_settings_btn, ui_layer.get_child_count() - 1)
	if is_instance_valid(_test_btn):
		ui_layer.move_child(_test_btn, ui_layer.get_child_count() - 1)
	_position_budget_label()
	ui_layer.move_child(_undo_btn, ui_layer.get_child_count() - 1)
	if is_instance_valid(_redo_btn):
		_redo_btn.offset_right = _undo_btn.offset_left - 6.0
		_redo_btn.offset_left  = _redo_btn.offset_right - (_redo_btn.custom_minimum_size.x as float)
		_redo_btn.offset_top   = _undo_btn.offset_top
		ui_layer.move_child(_redo_btn, ui_layer.get_child_count() - 1)


# ── View mode switcher ──────────────────────────────────────────────────────
func _set_view_mode(mode: int) -> void:
	# Switching is still allowed during post-win "View Apartment" — the player
	# should be able to look at the Floor Plan/Wall view same as 3D, just not
	# edit anything there. Furniture.read_only/WallInspector.read_only (set
	# alongside _post_win_view) are what actually lock out editing in those
	# views; this function only ever controls which view is showing.
	#
	# Mid-placement (a floor ghost still following the cursor after Buy),
	# switching away tears down the view the ghost's own _input() and the
	# Wall Inspector overlay both depend on — the ghost was left dangling
	# with no way to confirm/cancel it cleanly. Block the switch outright
	# instead; the player just needs to place or Esc-cancel first.
	if mode != _view_mode and is_instance_valid(_pending_floor_ghost):
		# The pressed button's own ButtonGroup already flipped its visual
		# state before this handler ran — snap it back since the mode isn't
		# actually changing.
		for m in _mode_buttons:
			(_mode_buttons[m] as Button).button_pressed = (m == _view_mode)
		return
	_view_mode = mode
	for m in _mode_buttons:
		(_mode_buttons[m] as Button).button_pressed = (m == mode)

	match mode:
		ViewMode.TOPDOWN:
			_teardown_mode3d_view()
			room.visible    = true
			divider.visible = false
			# `.visible` stays true for the idle placeholder panel too (it's only
			# ever hidden by its own close button) — is_showing_wall() is the
			# actual "a wall is open" check, otherwise the modal+backdrop would
			# cover the top-down plan immediately on switching into this mode.
			if wall_inspector.is_showing_wall():
				_position_wall_inspector_modal()
				_set_mode_hint("")
			else:
				wall_inspector.hide()
				_hide_modal_backdrop()
				_set_mode_hint("Click a highlighted wall edge on the plan to inspect it or hang items")
		ViewMode.VIEW3D:
			# Wall items are placed/moved directly in the 3D view here (drag onto
			# a wall) — there's no 2D Wall Inspector panel in this mode at all.
			room.visible    = false
			divider.visible = false
			wall_inspector.hide()
			_hide_modal_backdrop()
			_ensure_mode3d_view()
			_set_mode_hint("Drop items on the floor, or drag them onto a wall to hang them · Press R to rotate")

	var fl := _floors.get(_current_floor_id) as Floor
	if fl and mode != ViewMode.VIEW3D:
		_fit_floor(fl, false)
	_position_undo_btn()
	_position_minimap()


# Persistent 3D view used by VIEW3D mode — distinct from the quick full-screen
# "reveal" opened by the 3D-view TopBar button, which stays a one-off overlay.
# This one fits the same TOP_Y..BOT_Y band the 2D floor plan normally uses, so
# budget/inventory/tenant-needs stay visible and usable while working in 3D.
func _ensure_mode3d_view() -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if not is_instance_valid(_mode3d_view):
		_mode3d_view = Room3DViewScene.instantiate()
		ui_layer.add_child(_mode3d_view)
		_mode3d_view.anchor_left   = 0.0
		_mode3d_view.anchor_top    = 0.0
		_mode3d_view.anchor_right  = 0.0
		_mode3d_view.anchor_bottom = 0.0
		if _mode3d_view.has_node("CloseBtn"):
			(_mode3d_view.get_node("CloseBtn") as Control).visible = false
		_mode3d_view.furniture_moved.connect(func(f: Furniture):
			_on_furniture_action_changed()
			# Mirrors the 2D drag-end path (f.placed above, gated the same way):
			# a piece with its own per-Moment position (rail-mounted, or any
			# green/yellow piece) can depend on exactly where it sits (the
			# day/night "dress" reveal wardrobe, or zone membership for a
			# repositioned piece), so moving one in 3D has to re-run the needs
			# check same as it does in 2D. This was missing entirely for 3D --
			# sliding a reveal wardrobe into its zone there correctly recorded
			# the new moment_positions entry, but nothing ever re-checked
			# whether that satisfied the moment, so the level could never
			# actually be won that way.
			if f.has_own_moment_position():
				_refresh_functions())
		_mode3d_view.showcase_stop_changed.connect(func(moment_id: String, needs: Array):
			if moment_id == "":
				tenant_card.clear_showcase_highlight()
			else:
				tenant_card.highlight_showcase_need(moment_id, needs))
	# sell_requested/wall_sell_requested are bound to a specific Floor via
	# .bind(fl) — but _mode3d_view is a persistent node reused across floor
	# switches AND level restarts, while the Floor it was last bound to gets
	# queue_free()'d out from under it (restart) or is simply the wrong floor
	# now (switching floors). Rebinding only inside the "just created" branch
	# above meant every sale after either of those fired into a stale,
	# strongly-typed Floor argument — Room3DView had already removed the 3D
	# piece by the time that call errored, so the item visually vanished but
	# _on_sell_pressed never reached gm.sell_furniture() to refund the budget.
	if _mode3d_sell_floor != fl:
		if is_instance_valid(_mode3d_sell_floor):
			var old_sell := _on_sell_pressed.bind(_mode3d_sell_floor)
			var old_wall := _on_wall_sell_pressed.bind(_mode3d_sell_floor)
			if _mode3d_view.sell_requested.is_connected(old_sell):
				_mode3d_view.sell_requested.disconnect(old_sell)
			if _mode3d_view.wall_sell_requested.is_connected(old_wall):
				_mode3d_view.wall_sell_requested.disconnect(old_wall)
		_mode3d_view.sell_requested.connect(_on_sell_pressed.bind(fl))
		_mode3d_view.wall_sell_requested.connect(_on_wall_sell_pressed.bind(fl))
		_mode3d_sell_floor = fl
	_mode3d_view.offset_left   = LEFT_X
	_mode3d_view.offset_top    = TOP_Y
	_mode3d_view.offset_right  = RIGHT_X
	_mode3d_view.offset_bottom = BOT_Y
	var below_floor: Floor = null
	if fl.floor_id in _floor_below_id:
		below_floor = _floors.get(_floor_below_id[fl.floor_id] as String) as Floor
	# _teardown_mode3d_view() (called when switching to Floor Plan) frees this
	# node entirely — switching back to 3D recreates it from scratch, which
	# would otherwise silently reset read_only to its default (false) and
	# reopen editing/selling the instant you tabbed away and back during
	# post-win "View Apartment".
	_mode3d_view.read_only = _post_win_view
	_mode3d_view.build_from_floor(fl, gm.furniture_data["furniture"], below_floor)
	# _teardown_mode3d_view() (see the comment above) frees the whole node,
	# tenant and all, whenever the player steps out to the Floor Plan -- so
	# during "Watch Again" (_post_win_view), tabbing over and back silently
	# lost the tenant showcase loop with no way back short of re-opening
	# Watch Again from the results screen. Restart it here too, the same way
	# _on_watch_again_reveal() starts it the first time.
	if _post_win_view:
		_start_tenant_showcase()
	# The 3D view's rect fully contains TenantCard's corner (both are direct
	# UI children), so appending it here — same CanvasLayer, later sibling —
	# would otherwise draw over the card and hide it completely. Re-assert
	# TenantCard (and, via _position_undo_btn, Undo/Redo) above it every time,
	# regardless of which of this function's several callers triggered the
	# (re)build.
	ui_layer.move_child(tenant_card, ui_layer.get_child_count() - 1)
	# Inventory floats as a centered catalog modal now (see
	# _position_furniture_catalog_modal), but it's still a same-CanvasLayer
	# sibling added before the 3D view — same fix as TenantCard above: keep it
	# (and the wheel/backdrop) the topmost siblings so the catalog and its Buy
	# buttons stay visible and clickable in 3D mode.
	ui_layer.move_child(inventory, ui_layer.get_child_count() - 1)
	if is_instance_valid(_furniture_menu_btn):
		ui_layer.move_child(_furniture_menu_btn, ui_layer.get_child_count() - 1)
	_reraise_furniture_menu_nodes()
	_position_undo_btn()
	_position_minimap()


func _teardown_mode3d_view() -> void:
	if is_instance_valid(_mode3d_view):
		_mode3d_view.queue_free()
	_mode3d_view = null
	_mode3d_sell_floor = null   # the next _ensure_mode3d_view() builds a brand new node with no connections yet — force a fresh bind regardless of which floor it lands on


# TOPDOWN shows the Wall Inspector as a centered modal (with a dismiss-on-tap
# backdrop) rather than a docked panel — VIEW3D handles walls directly in the
# 3D pane instead (drag onto a wall), so this modal only ever appears in
# TOPDOWN mode.
func _position_wall_inspector_modal() -> void:
	if not is_instance_valid(_modal_backdrop):
		_modal_backdrop = ColorRect.new()
		_modal_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
		_modal_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
		_modal_backdrop.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
				wall_inspector.close_btn.pressed.emit())
		ui_layer.add_child(_modal_backdrop)
		ui_layer.move_child(_modal_backdrop, wall_inspector.get_index())
	_modal_backdrop.offset_left   = 0.0
	_modal_backdrop.offset_top    = 0.0
	_modal_backdrop.offset_right  = SCREEN_W
	_modal_backdrop.offset_bottom = BOT_Y
	_modal_backdrop.visible = true

	# Size the modal to the wall's actual aspect ratio instead of a fixed
	# 760x480 box — a fixed box left tall, empty letterboxing on whichever
	# side didn't match the wall's proportions, and dominated the screen even
	# for a small wall, hiding the top-down plan behind it for no reason.
	const MAX_MW := 720.0
	const MAX_MH := 420.0
	const MIN_MW := 380.0
	const MIN_MH := 220.0
	const PAD := 40.0   # room for title bar + panel margins
	var content_w: float = wall_inspector._wall_w() * WallInspector.TILE_SIZE
	var content_h: float = WallInspector.WALL_HEIGHT * WallInspector.TILE_SIZE
	var fit := minf((MAX_MW - PAD) / content_w, (MAX_MH - PAD) / content_h)
	fit = minf(fit, 2.0)   # never blow up a tiny wall to fill the whole box either
	var MW := clampf(content_w * fit + PAD, MIN_MW, MAX_MW)
	var MH := clampf(content_h * fit + PAD, MIN_MH, MAX_MH)
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	wall_inspector.offset_left   = center_x - MW * 0.5
	wall_inspector.offset_bottom = BOT_Y - 20.0
	wall_inspector.offset_right  = center_x + MW * 0.5
	wall_inspector.offset_top    = BOT_Y - 20.0 - MH


func _hide_modal_backdrop() -> void:
	if is_instance_valid(_modal_backdrop):
		_modal_backdrop.visible = false


# ── Sims-style furniture menu: wheel (categories) → Inventory (catalog) ────
# Top-left corner, symmetric with Settings/Undo/Redo in the top-right —
# Test Layout stacks below it (see _position_top_left_icons) instead of
# sharing the slot, freeing the top-center band for the wall-edge hint
# without the two competing for the same visual space. Also openable via the
# F key (see _input) — same "click it or press a key" access The Sims itself
# offers for its own build/buy mode; pressing F opens the wheel at the cursor
# instead of this button's fixed position (see _open_furniture_menu).
func _position_furniture_menu_btn() -> void:
	if not is_instance_valid(_furniture_menu_btn):
		return
	var w := 150.0
	_furniture_menu_btn.offset_left   = LEFT_X + 8.0
	_furniture_menu_btn.offset_right  = LEFT_X + 8.0 + w
	_furniture_menu_btn.offset_top    = TOP_Y
	_furniture_menu_btn.offset_bottom = TOP_Y + 34.0


# at_cursor: true opens the wheel centered on the mouse (used by the F-key
# shortcut — the wheel appears wherever the player was already looking, like
# The Sims' own build/buy mode); false (the "Furniture" button's own click)
# keeps it at its usual fixed spot in the middle of the play area, since a
# button click's "cursor position" is just wherever that button happens to be.
func _open_furniture_menu(at_cursor: bool = false) -> void:
	if _post_win_view:
		return
	_ensure_furniture_menu_backdrop()
	_ensure_category_wheel()
	var center := get_viewport().get_mouse_position() if at_cursor \
		else Vector2((LEFT_X + RIGHT_X) * 0.5, (TOP_Y + BOT_Y) * 0.5)
	_position_category_wheel(center)
	_furniture_menu_backdrop.visible = true
	_category_wheel.visible = true
	inventory.visible = false
	_reraise_furniture_menu_nodes()


func _ensure_furniture_menu_backdrop() -> void:
	if is_instance_valid(_furniture_menu_backdrop):
		return
	_furniture_menu_backdrop = ColorRect.new()
	_furniture_menu_backdrop.name = "FurnitureMenuBackdrop"
	_furniture_menu_backdrop.color = Color(0.0, 0.0, 0.0, 0.55)
	_furniture_menu_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_furniture_menu_backdrop.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_close_furniture_menu())
	_furniture_menu_backdrop.offset_left   = 0.0
	_furniture_menu_backdrop.offset_top    = 0.0
	_furniture_menu_backdrop.offset_right  = SCREEN_W
	_furniture_menu_backdrop.offset_bottom = BOT_Y
	_furniture_menu_backdrop.visible = false
	ui_layer.add_child(_furniture_menu_backdrop)


func _ensure_category_wheel() -> void:
	if is_instance_valid(_category_wheel):
		return
	_category_wheel = CategoryWheel.new()
	_category_wheel.name = "CategoryWheel"
	_category_wheel.category_chosen.connect(_on_wheel_category_chosen)
	_category_wheel.cancelled.connect(_close_furniture_menu)
	_category_wheel.visible = false
	ui_layer.add_child(_category_wheel)


const WHEEL_SIZE := 420.0

# Centers the wheel on `center`, clamped so it never spills off the play area
# — needed now that it can open at the cursor (see _open_furniture_menu)
# instead of always at the same fixed, already-in-bounds spot.
func _position_category_wheel(center: Vector2) -> void:
	var half := WHEEL_SIZE * 0.5
	var cx := clampf(center.x, LEFT_X + half, RIGHT_X - half)
	var cy := clampf(center.y, TOP_Y + half, BOT_Y - half)
	_category_wheel.offset_left   = cx - half
	_category_wheel.offset_right  = cx + half
	_category_wheel.offset_top    = cy - half
	_category_wheel.offset_bottom = cy + half


func _on_wheel_category_chosen(id: String) -> void:
	_category_wheel.visible = false
	if id == "Builder":
		inventory.open_for_category(Inventory.Category.BUILDER, "All")
	else:
		inventory.open_for_category(Inventory.Category.FURNITURE, id)
	_position_furniture_catalog_modal()
	_reraise_furniture_menu_nodes()


# Floating centered catalog — same centering approach as
# _position_wall_inspector_modal() above, just without that function's
# content-aspect-ratio sizing (Inventory's own ScrollContainer handles
# overflow instead).
func _position_furniture_catalog_modal() -> void:
	var w := 340.0
	var h := clampf(BOT_Y - TOP_Y - 40.0, 300.0, 640.0)
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	inventory.offset_left   = center_x - w * 0.5
	inventory.offset_right  = center_x + w * 0.5
	inventory.offset_top    = TOP_Y + 20.0
	inventory.offset_bottom = inventory.offset_top + h


# True while either the radial category wheel or the filtered item grid
# (Inventory) is showing — the two screens the "F" shortcut/Furniture button
# cycle through. Used so pressing F again closes whichever of those is open
# instead of only ever opening.
func _is_furniture_menu_open() -> bool:
	return (is_instance_valid(_category_wheel) and _category_wheel.visible) \
		or (is_instance_valid(inventory) and inventory.visible)


func _close_furniture_menu() -> void:
	if is_instance_valid(_category_wheel):
		_category_wheel.visible = false
	if is_instance_valid(_furniture_menu_backdrop):
		_furniture_menu_backdrop.visible = false
	inventory.visible = false


func _reraise_furniture_menu_nodes() -> void:
	if is_instance_valid(_furniture_menu_backdrop):
		ui_layer.move_child(_furniture_menu_backdrop, ui_layer.get_child_count() - 1)
	ui_layer.move_child(inventory, ui_layer.get_child_count() - 1)
	if is_instance_valid(_category_wheel):
		ui_layer.move_child(_category_wheel, ui_layer.get_child_count() - 1)


# Neither mode has a permanent docked Wall Inspector to hint at wall access
# — this small banner fills that gap. Empty text hides it (used whenever a
# wall is already open, or in VIEW3D where the hint text says something else).
# Which apartment we're actually looking at right now, spelled out as a
# "Root > Shoebox > Shoebox Interior" trail — otherwise the only way to tell
# was to read it off the mini-plan cards' labels, which isn't always visible
# (e.g. a level with no boxes of its own shows no cards at all).
func _update_breadcrumb() -> void:
	if not is_instance_valid(_breadcrumb_lbl):
		_breadcrumb_lbl = Label.new()
		_breadcrumb_lbl.add_theme_font_size_override("font_size", 11)
		_breadcrumb_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_breadcrumb_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_breadcrumb_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(_breadcrumb_lbl)
	var parts: Array[String] = []
	for ctx in _nested_stack:
		parts.append(_level_display_name((ctx as Dictionary)["parent_level_id"] as String))
	parts.append(_level_display_name(_current_level_id))
	_breadcrumb_lbl.text = " > ".join(parts)
	_breadcrumb_lbl.offset_left   = LEFT_X
	_breadcrumb_lbl.offset_right  = RIGHT_X
	_breadcrumb_lbl.offset_top    = TOP_Y
	_breadcrumb_lbl.offset_bottom = TOP_Y + 14.0
	_breadcrumb_lbl.visible = true
	ui_layer.move_child(_breadcrumb_lbl, ui_layer.get_child_count() - 1)


func _set_mode_hint(text: String) -> void:
	if text == "":
		if is_instance_valid(_mode_hint_lbl):
			_mode_hint_lbl.visible = false
		return
	if not is_instance_valid(_mode_hint_lbl):
		_mode_hint_lbl = Label.new()
		_mode_hint_lbl.add_theme_font_size_override("font_size", 12)
		_mode_hint_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		_mode_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_mode_hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(_mode_hint_lbl)
	_mode_hint_lbl.text = text
	_mode_hint_lbl.offset_left   = LEFT_X
	_mode_hint_lbl.offset_right  = RIGHT_X
	_mode_hint_lbl.offset_top    = TOP_Y + 14.0
	_mode_hint_lbl.offset_bottom = TOP_Y + 34.0
	_mode_hint_lbl.visible = true
	ui_layer.move_child(_mode_hint_lbl, ui_layer.get_child_count() - 1)


# Right-click removal of a wall-mounted item dropped directly in the 3D view —
# mirrors WallInspector._remove_wall_at (no refund, matching that 2D behavior).
func _on_wall_sell_pressed(edge: String, origin: Vector2i, apt_floor: Floor) -> void:
	apt_floor.remove_wall_item(edge, origin)
	_refresh_functions()


# ── Floor plan zoom (mouse wheel) / pan (middle-drag) ──────────────────────
# The plan is always the full window now — TOPDOWN is the only mode that
# shows it at all (VIEW3D hides it entirely).
func _floor_pane_right_x() -> float:
	return RIGHT_X


func _floor_pane_bottom_y() -> float:
	return BOT_Y


# Any full-screen modal that should freeze zoom/pan everywhere while it's up:
# the "NEW MECHANIC" intro card, the Wall Inspector's modal backdrop (Top-Down
# mode), and the win/fail result screen.
func _blocking_modal_open() -> bool:
	return _intro_modal_open \
		or (is_instance_valid(_modal_backdrop) and _modal_backdrop.visible) \
		or (is_instance_valid(_furniture_menu_backdrop) and _furniture_menu_backdrop.visible) \
		or result_screen.visible


func _handle_view_input(event: InputEvent) -> void:
	# The 3D view and the Top-Down modal's Wall Inspector each own independent
	# zoom/camera state (Room3DView._dist, WallInspector._zoom) — never let the
	# floor-plan zoom (_manual_zoom) react to scroll/pan meant for those views.
	if _view_mode == ViewMode.VIEW3D:
		return
	if _blocking_modal_open():
		return
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		var in_bounds := mbe.position.x > LEFT_X and mbe.position.x < _floor_pane_right_x() and mbe.position.y > TOP_Y and mbe.position.y < _floor_pane_bottom_y()
		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP and mbe.pressed and in_bounds:
			_zoom_floor(0.15, mbe.position)
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN and mbe.pressed and in_bounds:
			_zoom_floor(-0.15, mbe.position)
		elif mbe.button_index == MOUSE_BUTTON_MIDDLE:
			_panning_floor = mbe.pressed and in_bounds
	elif event is InputEventMouseMotion and _panning_floor:
		_manual_pan += (event as InputEventMouseMotion).relative
		_apply_room_transform()


func _zoom_floor(delta: float, cursor_pos: Vector2) -> void:
	var old_total := _base_scale * _manual_zoom
	_manual_zoom = clampf(_manual_zoom + delta, MIN_MANUAL_ZOOM, MAX_MANUAL_ZOOM)
	var new_total := _base_scale * _manual_zoom
	if new_total == old_total:
		return
	# Keep the point under the cursor fixed while zooming
	var focus_world := (cursor_pos - room.position) / old_total
	room.position  = cursor_pos - focus_world * new_total
	room.scale     = Vector2(new_total, new_total)
	_manual_pan    = room.position - _base_position


func _on_wall_edge_clicked(edge: String, span_lo: int, span_hi: int, apt_floor: Floor) -> void:
	for fid in _floors:
		var fl := _floors[fid] as Floor
		fl.set_active_wall_edge("" if fl != apt_floor else edge)
	# Remembered per floor (not globally) so the "W" shortcut reopens the
	# wall that was actually last inspected on whichever floor you're
	# currently looking at, not wherever you happened to click last overall.
	_last_wall_click_by_floor[apt_floor.floor_id] = {
		"edge": edge, "span_lo": span_lo, "span_hi": span_hi,
	}
	# Clicking a wall edge jumps into the 3D view — replaces the old 2D Wall
	# Inspector modal entirely. VIEW3D already handles walls directly (drag
	# items onto them) with no 2D panel at all. There's no scripted camera
	# orbit onto the specific wall (removed — needed constant per-room tuning
	# and free orbiting already covers the same need); players position
	# themselves manually from here.
	if _view_mode != ViewMode.VIEW3D:
		_set_view_mode(ViewMode.VIEW3D)


# Up/W and Down/S shortcuts — step to the floor directly above/below in the
# same order the Minimap tabs show, so the shortcut always matches what
# clicking a tab would do (including dynamically added loft floors).
func _step_floor(direction: int) -> void:
	var order := minimap.get_floor_order()
	var idx := order.find(_current_floor_id)
	if idx == -1:
		return
	var next_idx := idx + direction
	if next_idx < 0 or next_idx >= order.size():
		return
	_switch_floor(order[next_idx] as String)


# Left/A and Right/D shortcuts — step to the previous/next moment tab.
func _step_moment(direction: int) -> void:
	if gm.moments.is_empty():
		return
	var idx := -1
	for i in range(gm.moments.size()):
		if (gm.moments[i] as Dictionary).get("id", "") == _active_moment_id:
			idx = i
			break
	var next_idx: int = clampi((idx if idx != -1 else 0) + direction, 0, gm.moments.size() - 1)
	var next_id := (gm.moments[next_idx] as Dictionary).get("id", "") as String
	if next_id != "":
		_on_moment_selected(next_id)


# "Q" shortcut — reopen (or re-focus, now that wall clicks jump into 3D) the
# last wall inspected on the current floor, without having to re-find and
# re-click the same edge on the plan. Works from either view mode now: there's
# no separate 2D wall state to be "already in" any more.
func _reopen_last_wall() -> void:
	var last := _last_wall_click_by_floor.get(_current_floor_id, {}) as Dictionary
	if last.is_empty():
		_set_mode_hint("No wall inspected on this floor yet")
		return
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	_on_wall_edge_clicked(last["edge"] as String, last["span_lo"] as int, last["span_hi"] as int, apt_floor)


func _on_inspector_visibility_changed() -> void:
	if not wall_inspector.visible:
		for fid in _floors:
			(_floors[fid] as Floor).set_active_wall_edge("")
		_hide_modal_backdrop()
		if _view_mode == ViewMode.TOPDOWN:
			_set_mode_hint("Click a highlighted wall edge on the plan to inspect it or hang items")


func _on_wall_item_placed(furniture_id: String) -> void:
	gm.buy_furniture(furniture_id)
	# The wall placement won — cancel the parallel floor-placement ghost so it
	# doesn't linger following the mouse (and can't be placed a second time for free).
	if is_instance_valid(_pending_floor_ghost):
		_pending_floor_ghost.cancel_placement()
	_pending_floor_ghost = null
	_refresh_functions()


func _on_buy_requested(furniture_id: String) -> void:
	_close_furniture_menu()   # Sims-style flow: picking an item returns to the apartment view immediately
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return
	if gm.budget < (fdata.get("buy_price", 0) as int):
		return
	# Every item can go on the floor or on a wall — arm both placements at once.
	# Whichever the player actually clicks into completes the purchase; the other
	# is cancelled automatically.
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())   # repositioning-drag commits
	# A freshly bought item has no authored starting position — its "home"
	# for comfort-scoring purposes is simply wherever the player first sets
	# it down, so it starts fully comfortable and only costs comfort if
	# dragged away from there afterward.
	f.placed.connect(func(_n):
		if f._home_grid_pos == Vector2(-1, -1):
			f._home_grid_pos = f.grid_pos)
	if f.has_own_moment_position():
		f.placed.connect(func(_n): _refresh_functions())

	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		# 3D-primary mode: the floor ghost (`f`) is armed, but the player can
		# just as easily drop the item on a wall instead — Room3DView decides
		# which happened and fires the matching signal below. There's no 2D
		# floor plan or Wall Inspector on screen to race against here.
		#
		# The three handlers below disconnect each other once one of them
		# fires. GDScript locals declared with `var` and reassigned via
		# `x = func(): ...` do NOT reliably close over each other by live
		# reference when a lambda refers to a sibling var assigned later (or
		# to itself) in the same statement block — a `Dictionary` is used as
		# a shared mutable box instead, since its *contents* are looked up at
		# call time rather than captured at closure-creation time.
		var h := {}
		h["confirmed"] = func(_f: Furniture):
			_mode3d_view.buy_confirmed_wall.disconnect(h["wall_confirmed"])
			_mode3d_view.buy_cancelled.disconnect(h["cancelled"])
			gm.buy_furniture(furniture_id)
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed()
		h["wall_confirmed"] = func(_fid: String, _edge: String, _origin: Vector2i):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_cancelled.disconnect(h["cancelled"])
			f.queue_free()   # the floor ghost was never used — it landed on a wall instead
			gm.buy_furniture(furniture_id)
			_refresh_functions()
			_on_furniture_action_changed()
		h["cancelled"] = func(_f: Furniture):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_confirmed_wall.disconnect(h["wall_confirmed"])
			f.queue_free()
			_refresh_functions()
		_mode3d_view.buy_confirmed.connect(h["confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_confirmed_wall.connect(h["wall_confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_cancelled.connect(h["cancelled"], CONNECT_ONE_SHOT)
		_mode3d_view.start_buying(f, fdata)
	else:
		f.placement_confirmed.connect(func():
			gm.buy_furniture(furniture_id)
			_pending_floor_ghost = null
			wall_inspector.cancel_selection()
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed())
		f.placement_cancelled.connect(func():
			_pending_floor_ghost = null
			_refresh_functions())
		f.begin_placement(apt_floor, get_viewport().get_mouse_position())
		_pending_floor_ghost = f
		# wall_flush_required items (the balcony window) always place through
		# THIS floor-ghost path — Wall.can_place() itself enforces the "must
		# be flush against a wall" rule — never Wall Inspector's separate
		# "hang decoration on a wall" system, which stores a plain
		# {edge, origin, fid} record with no Furniture node behind it and so
		# no fold/toggle support at all (confirmed: that's the very thing
		# that made a placed balcony window impossible to open/close).
		if wall_inspector.is_showing_wall() and not f.wall_flush_required:
			wall_inspector.select_item(furniture_id)

	_refresh_functions()


func _on_sell_pressed(furniture: Furniture, apt_floor: Floor) -> void:
	Audio.play("sell")
	gm.sell_furniture(furniture.furniture_id)
	apt_floor.remove_furniture(furniture)
	# This handler also runs for a sale initiated in 3D itself (Room3DView's
	# own sell_requested), where it's already dropped from _furniture_entries —
	# but a 2D-initiated sale never told the (separately cached, persistent)
	# 3D view's render cache, leaving a stale entry pointing at the now-freed
	# node that crashed the next time the 3D view hit-tested near it.
	if is_instance_valid(_mode3d_view):
		_mode3d_view.remove_furniture_entry(furniture)
	_refresh_functions()
	_on_furniture_action_changed()   # push pre-sell state, cache the new post-sell state


func _on_furniture_changed() -> void:
	_refresh_functions()
	_update_floor_locks()
	_update_accessibility()
	# NOTE: deliberately NOT hooking undo-tracking here — this signal also
	# fires during an uncommitted 2D buy ghost-preview (set_floor_drag_ghost),
	# once per mouse-move, which flooded the undo stack with intermediate
	# states and could even crash (a snapshot taken mid-drag over some other
	# not-yet-settled furniture). Undo tracking hooks the precise, one-shot
	# signals instead: placement_confirmed, placed, fold_toggled, plus
	# explicit calls around sell and the 3D buy/move paths.


func _refresh_functions() -> void:
	# Floor items are passed as live Furniture nodes so foldable pieces report
	# their REAL current state (folded/extended), not just what they're capable
	# of. Wall items have no live node, so they stay id-based.
	var all_entries: Array = []
	for fid in _floors:
		var fl := _floors[fid] as Floor
		all_entries += fl.get_all_furniture()
		all_entries += fl.get_all_wall_item_ids()
	var extra_fns: Array = []
	for floor_id in _paint_pieces:
		for type_id in _paint_pieces[floor_id]:
			var piece := _paint_pieces[floor_id][type_id] as PaintedFurniture
			if is_instance_valid(piece) and piece.is_valid():
				for fn in piece.functions:
					if fn not in extra_fns:
						extra_fns.append(fn)
	var free_tiles_by_moment: Dictionary = {}
	var free_window_tiles_by_moment: Dictionary = {}
	for m in gm.moments:
		var mid := (m as Dictionary)["id"] as String
		var total := 0
		var total_window := 0
		for fid in _floors:
			var fl := _floors[fid] as Floor
			# Only real navigable floors — skip ceiling/subfloor/roof layers,
			# which have no real footprint and would otherwise fall back to
			# the full apartment grid size.
			if fl.floor_type in ["floor", "loft"]:
				total += fl.count_free_tiles_for_moment(mid)
				total_window += fl.count_free_window_tiles_for_moment(mid)
		free_tiles_by_moment[mid] = total
		free_window_tiles_by_moment[mid] = total_window
	gm.update_functions(all_entries, extra_fns, _active_moment_id, free_tiles_by_moment, free_window_tiles_by_moment)
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if apt_floor:
		gm.update_zones(apt_floor.zones)
		gm.update_sightlines(apt_floor)
		gm.update_external_zone(apt_floor, all_entries, _active_moment_id)
		# Zone separations/sightlines are level-wide checks against whatever's
		# CURRENTLY on screen — with per-moment furniture positions now
		# possible, that's only valid for _active_moment_id specifically. Every
		# call site that repositions furniture for a moment (_on_moment_selected,
		# _load_level's initial spawn) already runs _refresh_functions()
		# afterward, so this always sees a freshly-correct layout for whichever
		# moment is active right now.
		gm.record_moment_geometry(_active_moment_id)
	_update_comfort_meter()


func _on_budget_changed(new_budget: int) -> void:
	budget_label.text = "Budget: %d€" % new_budget


func _on_functions_updated(fulfilled: Array, required: Array) -> void:
	tenant_card.update_checks(fulfilled, required)
	_update_rent_btn()


func _on_moments_updated(results: Dictionary) -> void:
	tenant_card.update_moments(results)
	_update_rent_btn()


# The RENT OUT button is gone — the instant every requirement flips green,
# the level just finishes on its own instead of waiting for the player to
# notice and click a "finish" button. rent_btn itself is long since invisible
# (superseded by the TenantCard bar), kept only as a convenient bool holder
# for the previous/current satisfied state so the edge below has something to
# compare against.
func _update_rent_btn() -> void:
	var was_disabled := rent_btn.disabled
	rent_btn.disabled = not gm.check_win() or not _all_furniture_accessible()
	tenant_card.set_rent_available(not rent_btn.disabled)
	# _rent_auto_armed stays false until _load_level() has finished spawning
	# the level's starting furniture and synced this same baseline — otherwise
	# resuming an already-satisfied saved layout ("Revisar Plano Actual")
	# would trip this edge the instant it loads, replaying the completion
	# screen before the player has done anything. _post_win_view means we're
	# in the read-only "Watch Again" replay of an already-completed level.
	if _rent_auto_armed and was_disabled and not rent_btn.disabled and not _post_win_view:
		_on_rent_pressed()


func _update_accessibility() -> void:
	var blocked: Array = []
	for fid in _floors:
		blocked += (_floors[fid] as Floor).get_inaccessible_furniture()
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			(f as Furniture).set_accessible(f not in blocked)


func _all_furniture_accessible() -> bool:
	for fid in _floors:
		if (_floors[fid] as Floor).get_inaccessible_furniture().size() > 0:
			return false
	return true


func _on_rent_pressed() -> void:
	if not gm.check_win():
		Audio.play("error")
		if gm.comfort_pct < gm.COMFORT_WARN_THRESHOLD:
			result_screen.show_failure("The tenant isn't comfortable with this arrangement.\nToo much furniture has been rearranged — try keeping heavier pieces closer to where they started.")
		else:
			result_screen.show_failure("Not all tenant requirements are met.\nTry again.")
		_refresh_undo_redo_buttons()
		return
	if not _all_furniture_accessible():
		Audio.play("error")
		result_screen.show_failure("Some furniture is completely blocked.\nLeave at least 1 tile of walking space around it.")
		_refresh_undo_redo_buttons()
		return

	Audio.play("success")

	var stars       := gm.calculate_stars()
	var funds       := gm.get_funds_reward()
	var level_rent  := gm.current_level["tenant"]["monthly_rent"] as int

	GameState.complete_level(_current_level_id, stars, funds, level_rent)
	GameState.save_level_layout(_current_level_id, _snapshot_all_furniture())
	tenant_card.set_rented(true)

	var completed_level_id := _current_level_id
	var _load_gen := _level_load_id
	await _play_completion_reveal()
	# A Restart Level (or leaving to Projects) pressed mid-reveal calls
	# _load_level again, bumping _level_load_id — bail instead of popping a
	# results screen for a level that's already been reset out from under it.
	if _load_gen != _level_load_id:
		return

	_level_completed = true
	result_screen.show_success(
		stars,
		funds,
		GameState.portfolio_rent,
		gm.current_level["tenant"]["name"],
		level_rent,
		not gm.get_next_owned_level_id(completed_level_id).is_empty()
	)
	_refresh_undo_redo_buttons()


# The "wow" moment on a successful RENT OUT — a short scripted camera sweep
# through the finished apartment (Room3DView.play_reveal) instead of jumping
# straight to the results screen. Switches into 3D mode if the player was
# still on the Floor Plan so there's always something to actually show; skips
# entirely under Reduce Motion, same as the settings menu's other animations.
func _play_completion_reveal() -> void:
	if GameState.reduce_motion:
		return
	_set_view_mode(ViewMode.VIEW3D)
	if is_instance_valid(_mode3d_view):
		await _mode3d_view.play_reveal()
		_start_tenant_showcase()


# Level data has no per-tenant color field, so one is derived from the
# tenant's name — stable across replays of the same level, and gives each
# tenant a distinct-enough look without needing new content authoring.
func _start_tenant_showcase() -> void:
	if not is_instance_valid(_mode3d_view):
		return
	var tenant_name: String = gm.current_level.get("tenant", {}).get("name", "Tenant")
	var hue := float(tenant_name.hash() % 360) / 360.0
	var color := Color.from_hsv(hue, 0.55, 0.85)
	_mode3d_view.start_tenant_showcase(gm.moments, color)




func _on_moment_selected(moment_id: String) -> void:
	_active_moment_id = moment_id
	tenant_card.highlight_moment(moment_id)
	# Selecting a moment enables the same fold/unfold interaction Test Layout
	# does — the player still has to click each piece themselves to match the
	# moment's needs; nothing is toggled automatically here.
	Furniture.test_mode_active = true
	Furniture.active_moment_id = moment_id
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for f in fl.get_all_furniture():
			var fur := f as Furniture
			if fur.foldable or fur.has_own_moment_position():
				# Re-apply THIS moment's own remembered fold state / position —
				# a sofa bed unfolded for Night stays unfolded there even if Day
				# has it folded; a wardrobe pulled out on its rail for one moment
				# stays out there even if another moment has it tucked away; a
				# green/yellow chair left by the window for one moment stays
				# there even if another moment has it back at the desk.
				fur.set_moment_view(moment_id)
			if fur.foldable:
				fur.set_extended_conflict(fl.check_extended_conflict(fur))
			fur.queue_redraw()
	# queue_redraw() above only repaints the 2D Node2D furniture — the 3D
	# diorama is a separate set of MeshInstance3D nodes built once from a
	# snapshot of the floor, so switching moments while looking at the 3D
	# view left it showing the pre-switch fold/rail state until you left
	# and came back. Rebuilding here keeps it in sync immediately.
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()
	_refresh_functions()


func _on_test_toggled(pressed: bool) -> void:
	Furniture.test_mode_active = pressed
	# Click-to-fold works all the time now, not just in Test Layout, so a
	# piece's fold state is real/persistent furnishing state rather than a
	# throwaway preview — toggling this button off no longer forces every
	# foldable piece back closed the way it used to.
	for fid in _floors:
		var fl := _floors[fid] as Floor
		for f in fl.get_all_furniture():
			var fur := f as Furniture
			if fur.foldable:
				fur.set_extended_conflict(fl.check_extended_conflict(fur))
			fur.queue_redraw()
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()
	if not pressed:
		_refresh_functions()


func _has_foldable_furniture() -> bool:
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			if (f as Furniture).foldable:
				return true
	return false


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode == KEY_ESCAPE \
				and is_instance_valid(_furniture_menu_backdrop) and _furniture_menu_backdrop.visible:
			_close_furniture_menu()
			get_viewport().set_input_as_handled()
			return
		# Undo key is remappable (Settings → Accessibility); Redo is always the
		# same key + Shift, plus the fixed Ctrl+Y alias below.
		if ke.pressed and not ke.echo and not _post_win_view and ke.keycode == GameState.undo_keycode and (ke.ctrl_pressed or ke.meta_pressed):
			if ke.shift_pressed:
				_redo_builder_action()
			else:
				_undo_builder_action()
			get_viewport().set_input_as_handled()
			return
		if ke.pressed and not ke.echo and not _post_win_view and ke.keycode == KEY_Y and (ke.ctrl_pressed or ke.meta_pressed):
			_redo_builder_action()
			get_viewport().set_input_as_handled()
			return
		# Quick-access shortcuts — skip while the Results screen is up (its own
		# buttons take precedence) and while a Builder/paint tool is capturing
		# keys for something else (T/W/number keys are rare enough in that
		# context that the tool's own use of them, if any, should win).
		if ke.pressed and not ke.echo and not result_screen.visible \
				and _active_paint_type == "" and _active_builder_tool == "" \
				and not (ke.ctrl_pressed or ke.meta_pressed or ke.alt_pressed):
			if ke.keycode == KEY_T:
				_set_view_mode(ViewMode.VIEW3D if _view_mode == ViewMode.TOPDOWN else ViewMode.TOPDOWN)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_Q:
				_reopen_last_wall()
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_F and not _post_win_view:
				if _is_furniture_menu_open():
					_close_furniture_menu()
				else:
					_open_furniture_menu(true)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode >= KEY_1 and ke.keycode <= KEY_9:
				var _midx := ke.keycode - KEY_1
				if _midx < gm.moments.size():
					var _mid := (gm.moments[_midx] as Dictionary).get("id", "") as String
					if _mid != "":
						_on_moment_selected(_mid)
						get_viewport().set_input_as_handled()
						return
			if ke.keycode == KEY_UP or ke.keycode == KEY_W:
				_step_floor(1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_DOWN or ke.keycode == KEY_S:
				_step_floor(-1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_LEFT or ke.keycode == KEY_A:
				_step_moment(-1)
				get_viewport().set_input_as_handled()
				return
			if ke.keycode == KEY_RIGHT or ke.keycode == KEY_D:
				_step_moment(1)
				get_viewport().set_input_as_handled()
				return
	if _dragging_divider:
		if event is InputEventMouseMotion:
			_update_split((event as InputEventMouseMotion).position.y)
		elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
				and not (event as InputEventMouseButton).pressed:
			_dragging_divider = false
		return
	if _active_paint_type != "":
		_handle_paint_input(event)
		return
	if _active_builder_tool != "":
		_handle_builder_input(event)
		return
	_handle_view_input(event)


func _on_next_level() -> void:
	Transition.change_scene("res://scenes/CityMap.tscn")


func _on_retry() -> void:
	_load_level(_current_level_id)


# "View Apartment" on the Results screen — just closes the modal and hands
# full camera control back to the player (orbit/zoom/pan freely, same as the
# normal 3D view), like tabbing out to the post-game map in an RTS. Does NOT
# replay the scripted camera sweep — that already played once right after
# RENT OUT; this is "let me look around," not "show me the intro again." A
# small floating button is the only way back, since the Results panel stays
# hidden the whole time so it doesn't block the view.
func _on_watch_again_reveal() -> void:
	result_screen.visible = false
	_post_win_view = true
	Furniture.read_only     = true
	WallInspector.read_only = true
	_set_view_mode(ViewMode.VIEW3D)
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = true
	_start_tenant_showcase()
	_close_furniture_menu()
	if is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn.visible = false
	_refresh_undo_redo_buttons()
	_show_watch_done_button()


func _show_watch_done_button() -> void:
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.queue_free()
	_watch_done_btn = Button.new()
	_watch_done_btn.text = "✕ Back to Results"
	_watch_done_btn.add_theme_font_size_override("font_size", 13)
	_watch_done_btn.custom_minimum_size = Vector2(200, 40)
	ui_layer.add_child(_watch_done_btn)
	# Centered on the play area (not the whole window) and sat below the
	# diorama's resting position, rather than tucked in the top-left corner
	# where it competed with the Builder tool panel.
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	_watch_done_btn.offset_left   = center_x - 100.0
	_watch_done_btn.offset_right  = center_x + 100.0
	_watch_done_btn.offset_top    = BOT_Y - 90.0
	_watch_done_btn.offset_bottom = BOT_Y - 50.0
	# Same reasoning as Inventory in _ensure_mode3d_view: the 3D view is a
	# later sibling in this same CanvasLayer, so a freshly added Control has
	# to be moved after it explicitly or the 3D view's opaque background
	# paints over it and swallows its clicks.
	ui_layer.move_child(_watch_done_btn, ui_layer.get_child_count() - 1)
	_watch_done_btn.pressed.connect(_close_watch_again)


# Once this level's been rented out, the gear icon's job stops being "open
# settings" and becomes "get back to the Results screen" — same target as the
# floating "Back to Results" button, just reachable from anywhere afterward
# instead of only during free-look. Deliberate: Settings has no other entry
# point from here once this flips, but the alternative (a stray gear icon
# that reopens generic Settings instead of the level you just won) is what
# this replaces, per explicit direction.
func _on_settings_btn_pressed() -> void:
	if _level_completed:
		if _post_win_view:
			_close_watch_again()
		else:
			result_screen.visible = true
		return
	SettingsMenu.open(self)


# Shared by the floating "Back to Results" button above and the gear menu
# (_on_settings_btn_pressed) — both need to exit free-look the same way.
func _close_watch_again() -> void:
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.queue_free()
		_watch_done_btn = null
	_post_win_view = false
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = false
		_mode3d_view.stop_tenant_showcase()
	if is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn.visible = true
	result_screen.visible = true
	_refresh_undo_redo_buttons()


# "Next Level" on the Results screen — loads the next owned level directly
# instead of detouring through CityMap. get_next_owned_level_id() already
# returned non-empty when the button became visible, but re-check here since
# nothing stops the player sitting on the Results screen indefinitely first.
func _on_advance_level() -> void:
	var next_id := gm.get_next_owned_level_id(_current_level_id)
	if next_id.is_empty():
		Transition.change_scene("res://scenes/CityMap.tscn")
		return
	GameState.pending_level_id = next_id
	GameState.pending_use_saved_layout = false
	GameState.set_last_active_level(next_id)
	Transition.change_scene("res://scenes/Main.tscn")


func _update_floor_locks() -> void:
	var floors_data: Array = gm.current_level["apartment"]["floors"]
	for fd in floors_data:
		var unlock_by := fd.get("unlocked_by", "") as String
		if unlock_by.is_empty():
			continue
		var floor_id  := fd["id"] as String
		var unlocked  := _any_floor_has(unlock_by)
		minimap.set_floor_locked(floor_id, not unlocked)
		if not unlocked and _current_floor_id == floor_id:
			_switch_floor((floors_data[0] as Dictionary)["id"] as String)


func _any_floor_has(furniture_id: String) -> bool:
	for fid in _floors:
		for pid in (_floors[fid] as Floor).get_all_furniture_ids():
			if pid == furniture_id:
				return true
	return false


# ─── Paint mode ───────────────────────────────────────────────────────────────

func _build_paint_panel(types: Array) -> void:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color     = Color(0.115, 0.100, 0.085, 0.97)
	sb.border_color = Color(0.290, 0.245, 0.190)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchor(SIDE_LEFT,   0.0)
	panel.set_anchor(SIDE_TOP,    0.0)
	panel.set_anchor(SIDE_RIGHT,  1.0)
	panel.set_anchor(SIDE_BOTTOM, 0.0)
	panel.offset_left   = 868
	panel.offset_right  = -4
	panel.offset_top    = TOP_Y + 6
	panel.offset_bottom = TOP_Y + 92
	$UI.add_child(panel)
	_paint_panel = panel

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	panel.add_child(vb)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)

	var chip := Label.new()
	chip.text = "  CUSTOM BUILD  "
	chip.add_theme_font_size_override("font_size", 9)
	chip.add_theme_color_override("font_color", Color(0.08, 0.08, 0.12))
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.36, 0.50, 0.66)
	cs.set_corner_radius_all(3)
	cs.set_content_margin(SIDE_LEFT, 4);  cs.set_content_margin(SIDE_RIGHT, 4)
	cs.set_content_margin(SIDE_TOP, 2);   cs.set_content_margin(SIDE_BOTTOM, 2)
	chip.add_theme_stylebox_override("normal", cs)
	header.add_child(chip)

	var hint := Label.new()
	hint.text = "LMB paint · RMB erase"
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.45, 0.48, 0.52))
	header.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	vb.add_child(btn_row)

	var bg_group := ButtonGroup.new()

	var move_btn := Button.new()
	move_btn.text           = "Move"
	move_btn.toggle_mode    = true
	move_btn.button_group   = bg_group
	move_btn.button_pressed = true
	move_btn.add_theme_font_size_override("font_size", 11)
	move_btn.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60))
	move_btn.toggled.connect(func(on: bool):
		if on: _set_paint_tool(""))
	btn_row.add_child(move_btn)

	var paintable_data := gm.furniture_data.get("paintable", []) as Array
	for type_id: String in types:
		var cfg := Dictionary()
		for pd in paintable_data:
			if (pd as Dictionary).get("id", "") == type_id:
				cfg = pd as Dictionary
				break
		if cfg.is_empty():
			continue
		var ca  := cfg.get("color", [0.5, 0.5, 0.5]) as Array
		var col := Color(ca[0] as float, ca[1] as float, ca[2] as float)
		var lbl := cfg.get("label", type_id) as String
		var cpt := cfg.get("cost_per_tile", 30) as int
		var btn := Button.new()
		btn.text         = "%s  %d€/tile" % [lbl, cpt]
		btn.toggle_mode  = true
		btn.button_group = bg_group
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", col)
		var tid := type_id
		btn.toggled.connect(func(on: bool):
			if on: _set_paint_tool(tid))
		btn_row.add_child(btn)

	_paint_status_lbl = Label.new()
	_paint_status_lbl.text = ""
	_paint_status_lbl.add_theme_font_size_override("font_size", 9)
	_paint_status_lbl.add_theme_color_override("font_color", Color(0.45, 0.48, 0.52))
	vb.add_child(_paint_status_lbl)


func _set_paint_tool(type_id: String) -> void:
	_active_paint_type = type_id
	_painting          = false
	_last_paint_tile   = Vector2i(-1, -1)
	_update_paint_status()


func _handle_paint_input(event: InputEvent) -> void:
	if not event is InputEventMouse:
		return
	var mp := (event as InputEventMouse).position
	if mp.x < LEFT_X or mp.x > _floor_pane_right_x() or mp.y < TOP_Y or mp.y > _floor_pane_bottom_y():
		return

	get_viewport().set_input_as_handled()

	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	var local := fl.to_local(mp)
	var tx    := int(local.x / float(TILE_SIZE))
	var ty    := int(local.y / float(TILE_SIZE))

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_painting = true
				if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
					_apply_paint(Vector2i(tx, ty), true)
			else:
				_painting          = false
				_last_paint_tile   = Vector2i(-1, -1)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
				_apply_paint(Vector2i(tx, ty), false)
	elif event is InputEventMouseMotion and _painting:
		if tx >= 0 and tx < fl.grid_w and ty >= 0 and ty < fl.grid_h:
			var tile := Vector2i(tx, ty)
			if tile != _last_paint_tile:
				_apply_paint(tile, true)


func _apply_paint(tile: Vector2i, on: bool) -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if on and _tile_has_column(fl, tile.x, tile.y):
		return
	var piece := _get_or_create_paint_piece(_active_paint_type, fl)
	if piece.has_tile(tile) == on:
		_last_paint_tile = tile
		return
	if on:
		if gm.budget < piece.cost_per_tile:
			Audio.play("error")
			return
		piece.set_tile(tile, true)
		gm.budget -= piece.cost_per_tile
		gm.budget_changed.emit(gm.budget)
	else:
		piece.set_tile(tile, false)
		gm.budget += piece.cost_per_tile
		gm.budget_changed.emit(gm.budget)
	_last_paint_tile = tile
	_refresh_functions()
	_update_paint_status()


# ── Builder tab tools ───────────────────────────────────────────────────────
# Free-form geometry editing during play (walls/columns/erase for now).
# Unlike the paid pre-furnish Demolition Phase (which removes the LEVEL's
# pre-existing walls at a cost), these are the player's own construction —
# free to add and free to undo, same as arranging furniture is free.

func _on_builder_tool_selected(tool_id: String) -> void:
	_cancel_builder_drawing()
	_active_builder_tool = tool_id
	for fid in _floors:
		(_floors[fid] as Floor).input_suppressed = (tool_id != "")
	# Pipe routes/connection points live on every Floor but are normally only
	# rendered on the (player-inaccessible, hidden_floors) subfloor layer —
	# show them directly on the current floor's own plan while a pipe tool
	# is active, since that's the floor the routes are actually being drawn
	# and read against (get_unconnected_needs checks furniture on this same
	# floor, not a separate subfloor node).
	# Keep pipes visible for "erase" too — Erase is the shared removal tool
	# for everything the Builder tab adds, including pipe routes.
	var show_pipes := tool_id == "pipe_water" or tool_id == "pipe_power" or tool_id == "erase"
	var cur_fl := _floors.get(_current_floor_id) as Floor
	if cur_fl:
		var gd := cur_fl.get_node_or_null("GridDraw") as GridDraw
		if gd:
			gd.show_subfloor = show_pipes
			gd.queue_redraw()


func _builder_tile_at(fl: Floor) -> Vector2i:
	var local := fl.to_local(get_viewport().get_mouse_position())
	return Vector2i(floori(local.x / Floor.TILE_SIZE), floori(local.y / Floor.TILE_SIZE))


func _handle_builder_input(event: InputEvent) -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		if mbe.button_index != MOUSE_BUTTON_LEFT:
			return
		if mbe.pressed:
			if mbe.position.x <= LEFT_X or mbe.position.x >= _floor_pane_right_x() or mbe.position.y < TOP_Y or mbe.position.y > _floor_pane_bottom_y():
				return
			_builder_press_consumed = true
			var tile := _builder_tile_at(fl)
			match _active_builder_tool:
				"wall", "rail", "reveal":
					_builder_press_tile = tile
					_builder_cur_tile   = tile
					_builder_drawing    = true
					_update_builder_ghost(fl)
				"column":
					var already := false
					for c in fl.columns:
						if (c["x"] as int) == tile.x and (c["y"] as int) == tile.y:
							already = true
							break
					if already or fl.can_place_column(tile.x, tile.y):
						_push_builder_undo(fl)
						fl.toggle_column(tile.x, tile.y)
						Audio.play("place")
						_refresh_functions()
					else:
						Audio.play("error")
				"erase":
					var local := fl.to_local(get_viewport().get_mouse_position())
					_push_builder_undo(fl)
					if fl.erase_near(local, tile):
						Audio.play("demolish")
						_refresh_functions()
					else:
						_builder_undo_stack.pop_back()  # nothing erased — drop the wasted snapshot
				"balcony", "bathroom":
					_builder_drawing  = true
					_builder_cur_tile = tile
					_push_builder_undo(fl)  # one snapshot per stroke, not per tile painted
					_paint_floor_tile(fl, tile, _active_builder_tool)
				"window":
					var local_w := fl.to_local(get_viewport().get_mouse_position())
					var idx_w := fl.find_segment_near(local_w, 1.5)
					if idx_w >= 0:
						_push_builder_undo(fl)
						if fl.toggle_window_on_segment(idx_w):
							Audio.play("place")
							_refresh_functions()
						else:
							_builder_undo_stack.pop_back()
							Audio.play("error")
					else:
						Audio.play("error")
				"door":
					var local_d := fl.to_local(get_viewport().get_mouse_position())
					var idx_d := fl.find_segment_near(local_d, 1.5)
					if idx_d >= 0:
						_push_builder_undo(fl)
						if fl.toggle_door_on_segment(idx_d):
							Audio.play("place")
							_refresh_functions()
						else:
							_builder_undo_stack.pop_back()
							Audio.play("error")
					else:
						Audio.play("error")
				"pipe_water", "pipe_power":
					_builder_drawing    = true
					_builder_pipe_tiles = [tile]
					_update_builder_pipe_ghost(fl)
			# Consume the event so Floor.gd's own _input() (wall-edge-click
			# detection, used by the normal Select mode) doesn't also react
			# to the same press/release and pop open the Wall Inspector.
			get_viewport().set_input_as_handled()
		elif _builder_press_consumed:
			# Only swallow the release that matches a press we actually
			# handled — otherwise a release over UI (e.g. a Builder-tab
			# button click that started elsewhere) gets eaten here too,
			# since _input() runs before Control._gui_input and leaves the
			# button's own click never firing.
			_builder_press_consumed = false
			if _builder_drawing and _active_builder_tool == "wall":
				_commit_builder_wall(fl)
			elif _builder_drawing and _active_builder_tool == "rail":
				_commit_builder_rail(fl)
			elif _builder_drawing and _active_builder_tool == "reveal":
				_commit_builder_reveal(fl)
			elif _builder_drawing and (_active_builder_tool == "pipe_water" or _active_builder_tool == "pipe_power"):
				_commit_builder_pipe(fl)
			_builder_drawing = false
			_clear_builder_ghost()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _builder_drawing:
		var tile := _builder_tile_at(fl)
		match _active_builder_tool:
			"wall", "rail", "reveal":
				# Axis-snap to whichever direction has moved further, same as
				# LevelEditor's wall-drawing preview.
				if absi(tile.x - _builder_press_tile.x) >= absi(tile.y - _builder_press_tile.y):
					tile.y = _builder_press_tile.y
				else:
					tile.x = _builder_press_tile.x
				_builder_cur_tile = tile
				_update_builder_ghost(fl)
			"pipe_water", "pipe_power":
				if _builder_pipe_tiles.is_empty() or tile != _builder_pipe_tiles[-1]:
					_builder_pipe_tiles.append(tile)
					_update_builder_pipe_ghost(fl)
			"balcony", "bathroom":
				if tile != _builder_cur_tile:
					_builder_cur_tile = tile
					_paint_floor_tile(fl, tile, _active_builder_tool)


# ── Builder tab undo ──────────────────────────────────────────────────────
# Snapshot-based rather than per-tool inverse operations: every commit action
# for every tool (wall/column/erase/paint/window/door/rail/reveal/pipe) only
# ever touches these six Floor fields, so capturing all six before a mutation
# and restoring them wholesale on undo covers every tool with one mechanism.
func _push_builder_undo(fl: Floor) -> void:
	_builder_undo_stack.append(_capture_builder_entry(fl))
	if _builder_undo_stack.size() > BUILDER_UNDO_MAX:
		_builder_undo_stack.pop_front()
	_redo_stack.clear()   # a fresh action invalidates whatever was undone before it
	_refresh_undo_redo_buttons()


func _capture_builder_entry(fl: Floor) -> Dictionary:
	return {
		"type": "builder",
		"floor_id": fl.name,
		"data": {
			"segments":         fl.segments.duplicate(true),
			"columns":          fl.columns.duplicate(true),
			"floor_kind":       fl.floor_kind.duplicate(true),
			"rails":            fl.rails.duplicate(true),
			"reveal_zones":     fl.reveal_zones.duplicate(true),
			"pipe_routes":      fl.pipe_routes.duplicate(true),
		},
	}


func _apply_builder_entry(entry: Dictionary) -> void:
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if not fl:
		return
	var data := entry["data"] as Dictionary
	fl.segments     = (data["segments"] as Array).duplicate(true)
	fl.columns      = (data["columns"] as Array).duplicate(true)
	fl.floor_kind   = (data["floor_kind"] as Dictionary).duplicate(true)
	fl.rails        = (data["rails"] as Array).duplicate(true)
	fl.reveal_zones = (data["reveal_zones"] as Array).duplicate(true)
	fl.pipe_routes  = (data["pipe_routes"] as Array).duplicate(true)
	if fl.has_method("_compute_light_map"):
		fl._compute_light_map()
	if fl.grid_draw:
		fl.grid_draw.queue_redraw()
	_refresh_functions()


func _undo_builder_action() -> void:
	if _builder_undo_stack.is_empty():
		return
	var entry := _builder_undo_stack.pop_back() as Dictionary
	if (entry.get("type", "builder") as String) == "furniture":
		_redo_stack.append({"type": "furniture", "snapshot": _snapshot_all_furniture()})
		_restore_furniture_snapshot(entry["snapshot"] as Dictionary)
		_refresh_undo_redo_buttons()
		return
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if fl:
		_redo_stack.append(_capture_builder_entry(fl))
	_apply_builder_entry(entry)
	Audio.play("click")
	_refresh_undo_redo_buttons()


func _redo_builder_action() -> void:
	if _redo_stack.is_empty():
		return
	var entry := _redo_stack.pop_back() as Dictionary
	if (entry.get("type", "builder") as String) == "furniture":
		_builder_undo_stack.append({"type": "furniture", "snapshot": _snapshot_all_furniture()})
		_restore_furniture_snapshot(entry["snapshot"] as Dictionary)
		Audio.play("click")
		_refresh_undo_redo_buttons()
		return
	var fl := _floors.get(entry["floor_id"] as String) as Floor
	if fl:
		_builder_undo_stack.append(_capture_builder_entry(fl))
	_apply_builder_entry(entry)
	Audio.play("click")
	_refresh_undo_redo_buttons()


# Also locked out whenever the Results modal is up (or during the post-win
# "View Apartment" free-look) — undoing/redoing a level that's already been
# scored and saved makes no sense, in ANY view mode (floor plan, wall view,
# or 3D), not just whichever one happened to be active when RENT OUT was hit.
func _refresh_undo_redo_buttons() -> void:
	var locked := result_screen.visible or _post_win_view
	if is_instance_valid(_undo_btn):
		_undo_btn.disabled = locked or _builder_undo_stack.is_empty()
	if is_instance_valid(_redo_btn):
		_redo_btn.disabled = locked or _redo_stack.is_empty()


# ── Furniture undo (buy/sell/move/fold) ──────────────────────────────────
# Called once, right after each real commit (never from Wall.gd's own
# furniture_changed — that also fires during an uncommitted buy-ghost preview,
# once per mouse-move, which would flood the stack and can even snapshot a
# not-yet-settled piece). The state cached from the PREVIOUS call is exactly
# "how things were right before this change", so: push that, then re-cache
# the new current state for next time. Hooked from precise one-shot signals
# (placement_confirmed, placed, fold_toggled, furniture_moved) plus explicit
# calls around sell and the 3D buy paths.
func _on_furniture_action_changed() -> void:
	if _restoring_furniture:
		return
	if not _last_furniture_state.is_empty():
		_builder_undo_stack.append({"type": "furniture", "snapshot": _last_furniture_state})
		if _builder_undo_stack.size() > BUILDER_UNDO_MAX:
			_builder_undo_stack.pop_front()
		_redo_stack.clear()
		_refresh_undo_redo_buttons()
	_last_furniture_state = _snapshot_all_furniture()


func _snapshot_all_furniture() -> Dictionary:
	var floors_data := {}
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var furn := []
		for item in fl.get_all_furniture():
			var f := item as Furniture
			var entry := {
				"id": f.furniture_id, "x": f.grid_pos.x, "y": f.grid_pos.y,
				"extended": f.is_extended,
			}
			# Same reasoning as _snapshot_level_state(): a nested box's
			# child_level_id is a per-instance override, not part of the
			# catalog entry — undoing/redoing past a step that touched this
			# floor would otherwise silently repoint the box at its catalog
			# default (see _restore_spawn_furniture()).
			if f.is_nested_box:
				entry["child_level_id"] = f.child_level_id
			# _home_grid_pos is the level's TRUE authored starting position,
			# not whatever (x,y) this particular undo step happens to restore
			# to — capture it explicitly so comfort scoring (which compares
			# current position against home) doesn't get silently reset to
			# "comfortable" by an unrelated undo/redo on this floor.
			entry["home_x"] = f._home_grid_pos.x
			entry["home_y"] = f._home_grid_pos.y
			furn.append(entry)
		floors_data[fid] = {
			"furniture":   furn,
			"wall_items": (fl.wall_items as Dictionary).duplicate(true),
		}
	return {"funds": gm.budget, "floors": floors_data}


func _restore_furniture_snapshot(snap: Dictionary) -> void:
	_restoring_furniture = true
	gm.budget = snap["funds"] as int
	gm.budget_changed.emit(gm.budget)
	var floors_data := snap["floors"] as Dictionary
	var touched_current := false
	for fid in floors_data:
		var fl := _floors.get(fid) as Floor
		if not fl:
			continue   # a loft floor removed in between — rare edge case, skipped
		var fd := floors_data[fid] as Dictionary
		# A single undo/redo step only ever changes one floor (one tool action
		# happened on one floor) — tearing down and respawning every OTHER
		# floor's furniture too (destroy + re-instantiate + re-setup each
		# piece) was the actual cost here, multiplied by every floor in the
		# apartment on every single step. Skip any floor whose snapshot
		# already matches its current state.
		if _floor_matches_furniture_snapshot(fl, fd):
			continue
		if fid == _current_floor_id:
			touched_current = true
		for item in fl.get_all_furniture().duplicate():
			# remove_furniture() (not a raw queue_free) so the Floor's own grid
			# bookkeeping is cleaned up too — otherwise later code that iterates
			# placed furniture (zone/light-map recompute, moment checks, ...)
			# can still trip over the stale reference before its deferred free
			# actually runs.
			fl.remove_furniture(item as Furniture)
		fl.wall_items.clear()
		for e in (fd["furniture"] as Array):
			var ed := e as Dictionary
			var f := _restore_spawn_furniture(ed["id"] as String, fl, int(ed["x"]), int(ed["y"]), ed)
			if f and (ed.get("extended", false) as bool) and f.foldable:
				f._apply_fold_state(true)
		var wall_items := fd["wall_items"] as Dictionary
		for edge in wall_items:
			var items := wall_items[edge] as Dictionary
			for origin in items:
				fl.place_wall_item(edge, origin as Vector2i, items[origin] as String)
	_restoring_furniture = false
	_last_furniture_state = _snapshot_all_furniture()
	_refresh_functions()
	if _view_mode == ViewMode.VIEW3D and touched_current:
		_ensure_mode3d_view()
	Audio.play("click")


# True if a floor's live furniture + wall items already equal what the
# snapshot wants — lets _restore_furniture_snapshot skip the (expensive)
# destroy/respawn cycle for every floor an undo/redo step didn't touch.
func _floor_matches_furniture_snapshot(fl: Floor, fd: Dictionary) -> bool:
	var furn := []
	for item in fl.get_all_furniture():
		var f := item as Furniture
		var entry := {"id": f.furniture_id, "x": f.grid_pos.x, "y": f.grid_pos.y, "extended": f.is_extended}
		if f.is_nested_box:
			entry["child_level_id"] = f.child_level_id
		furn.append(entry)
	return furn == (fd["furniture"] as Array) and (fl.wall_items as Dictionary) == (fd["wall_items"] as Dictionary)


# Same as _spawn_furniture but never auto-promotes onto a loft floor — used
# during undo restore, where the snapshot already records each piece on
# whichever floor (base or loft) it actually ended up on, so re-triggering
# the auto-promotion would try to move it a second time.
func _restore_spawn_furniture(furniture_id: String, apt_floor: Floor, gx: int, gy: int, override_data: Dictionary = {}) -> Furniture:
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return null
	# child_level_id is a per-instance override (see _snapshot_all_furniture())
	# — without re-applying it here, undoing/redoing past a step touching
	# this floor silently repointed a nested box at its catalog default.
	if override_data.has("child_level_id"):
		fdata = fdata.duplicate()
		fdata["child_level_id"] = override_data["child_level_id"]
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	apt_floor.place_furniture(f, Vector2i(gx, gy))
	# home_x/home_y (see _snapshot_all_furniture()) is the level's true
	# authored starting position — fall back to (gx,gy) only for snapshots
	# taken before this field existed.
	f._home_grid_pos = Vector2(override_data.get("home_x", gx) as float, override_data.get("home_y", gy) as float)
	f.sell_requested.connect(_on_sell_pressed.bind(apt_floor))
	f.fold_toggled.connect(_refresh_functions)
	f.fold_toggled.connect(_on_furniture_action_changed)
	f.placed.connect(func(_n): _on_furniture_action_changed())
	if f.has_own_moment_position():
		f.placed.connect(func(_n): _refresh_functions())
	return f


func _paint_floor_tile(fl: Floor, tile: Vector2i, kind: String) -> void:
	if tile.x < 0 or tile.y < 0 or tile.x >= fl.grid_w or tile.y >= fl.grid_h:
		return
	fl.paint_floor_kind(tile, kind)
	Audio.play("place")


func _commit_builder_wall(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_segment(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_segment(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")
	_refresh_functions()


func _commit_builder_rail(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_rail(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_rail(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")


func _commit_builder_reveal(fl: Floor) -> void:
	var ps := _builder_press_tile
	var pe := _builder_cur_tile
	if ps == pe:
		return
	if not fl.can_add_reveal_zone(ps.x, ps.y, pe.x, pe.y):
		Audio.play("error")
		return
	_push_builder_undo(fl)
	fl.add_reveal_zone(ps.x, ps.y, pe.x, pe.y)
	Audio.play("place")


func _commit_builder_pipe(fl: Floor) -> void:
	var pipe_type := "water" if _active_builder_tool == "pipe_water" else "power"
	if _builder_pipe_tiles.size() < 2:
		_builder_pipe_tiles = []
		_clear_builder_pipe_ghost()
		return
	_push_builder_undo(fl)
	fl.add_pipe_route(pipe_type, _builder_pipe_tiles.duplicate())
	Audio.play("place")
	_builder_pipe_tiles = []
	_clear_builder_pipe_ghost()


func _update_builder_pipe_ghost(fl: Floor) -> void:
	if not is_instance_valid(_builder_pipe_ghost):
		_builder_pipe_ghost = Line2D.new()
		_builder_pipe_ghost.width = 2.5
		_builder_pipe_ghost.default_color = Color(0.95, 0.65, 0.25, 0.9)
		fl.add_child(_builder_pipe_ghost)
	var pts := PackedVector2Array()
	for t in _builder_pipe_tiles:
		pts.append((Vector2(t) + Vector2(0.5, 0.5)) * Floor.TILE_SIZE)
	_builder_pipe_ghost.points = pts


func _clear_builder_pipe_ghost() -> void:
	if is_instance_valid(_builder_pipe_ghost):
		_builder_pipe_ghost.queue_free()
	_builder_pipe_ghost = null


func _update_builder_ghost(fl: Floor) -> void:
	if not is_instance_valid(_builder_ghost):
		_builder_ghost = Line2D.new()
		_builder_ghost.width = 3.0
		_builder_ghost.default_color = Color(0.95, 0.65, 0.25, 0.9)
		fl.add_child(_builder_ghost)
	_builder_ghost.points = PackedVector2Array([
		Vector2(_builder_press_tile) * Floor.TILE_SIZE,
		Vector2(_builder_cur_tile)   * Floor.TILE_SIZE,
	])


func _clear_builder_ghost() -> void:
	if is_instance_valid(_builder_ghost):
		_builder_ghost.queue_free()
	_builder_ghost = null


func _cancel_builder_drawing() -> void:
	_builder_drawing = false
	_builder_press_consumed = false
	_builder_pipe_tiles = []
	_clear_builder_ghost()
	_clear_builder_pipe_ghost()


func _get_or_create_paint_piece(type_id: String, fl: Floor) -> PaintedFurniture:
	var floor_id := _current_floor_id
	if floor_id not in _paint_pieces:
		_paint_pieces[floor_id] = {}
	if type_id not in _paint_pieces[floor_id]:
		var piece := PaintedFurniture.new()
		var paintable_data := gm.furniture_data.get("paintable", []) as Array
		for pd in paintable_data:
			var cfg := pd as Dictionary
			if cfg.get("id", "") == type_id:
				piece.type_id        = type_id
				piece.display_label  = cfg.get("label",          type_id) as String
				piece.functions      = cfg.get("functions",      []).duplicate() as Array
				piece.cost_per_tile  = cfg.get("cost_per_tile",  30)  as int
				piece.min_tiles      = cfg.get("min_tiles",      16)  as int
				piece.max_aspect     = cfg.get("max_aspect",     3.5) as float
				piece.min_short_side = cfg.get("min_short_side", 4)   as int
				var ca := cfg.get("color", [0.5, 0.5, 0.5]) as Array
				piece.tile_color     = Color(ca[0] as float, ca[1] as float, ca[2] as float)
				break
		fl.add_child(piece)
		_paint_pieces[floor_id][type_id] = piece
	return _paint_pieces[floor_id][type_id] as PaintedFurniture


func _tile_has_column(fl: Floor, tx: int, ty: int) -> bool:
	for c in fl.columns:
		var cd := c as Dictionary
		if cd.get("x", -1) == tx and cd.get("y", -1) == ty:
			return true
	return false


func _update_paint_status() -> void:
	if not is_instance_valid(_paint_status_lbl):
		return
	if _active_paint_type.is_empty():
		_paint_status_lbl.text = ""
		return
	var floor_id := _current_floor_id
	if floor_id not in _paint_pieces or _active_paint_type not in _paint_pieces[floor_id]:
		_paint_status_lbl.text = "Paint tiles on the floor"
		return
	var piece := _paint_pieces[floor_id][_active_paint_type] as PaintedFurniture
	if not is_instance_valid(piece):
		return
	_paint_status_lbl.text = piece.validation_message()
	var valid := piece.is_valid()
	_paint_status_lbl.add_theme_color_override("font_color",
		Color(0.38, 0.72, 0.48) if valid else Color(0.65, 0.38, 0.30))
