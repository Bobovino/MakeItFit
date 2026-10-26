extends Node

const FurnitureScene := preload("res://scenes/Furniture.tscn")
const Room3DViewScene := preload("res://scenes/Room3DView.tscn")
const NestedMapScript := preload("res://scripts/NestedMap.gd")
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
@onready var divider:      ColorRect     = $UI/Divider
@onready var ui_layer:     CanvasLayer   = $UI

const TILE_SIZE := 8          # pixels per grid tile — matches Floor/GridDraw
const TOP_Y     := 10.0       # slim top margin — the old full-width bar is gone; only a
							   # floating gear icon (and Test Layout, when shown) sit up here now
var BOT_Y     := 720.0      # bottom of the play area: the window's own bottom edge (see _fit_to_window)
const FIT_PCT   := 0.95       # fraction of available area to fill

# ── Play-area bounds ────────────────────────────────────────────────────────
# The floor plan / wall view / 3D view get the entire window width — the old
# always-docked Inventory sidebar that used to reserve LEFT_X's 170px is gone
# (see the furniture wheel/catalog flow below); TenantCard and the furniture
# menu button/wheel all float as overlays instead of reserved columns.
const LEFT_X  := 0.0
var RIGHT_X := 1280.0     # the window's own right edge (see _fit_to_window)

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
var _view_mode_box: HBoxContainer = null   # Floor Plan/3D segmented toggle, top right beside undo/redo/menu
var _pending_floor_ghost: Furniture = null   # the floor-placement ghost armed alongside a wall placement

# ── View mode: two ways to look at the same apartment, both reading/writing
# the same Floor data — switching modes never converts or loses anything:
#   TOPDOWN — plan only; floor furniture (things are hung on walls in VIEW3D)
#   VIEW3D  — walk around in 3D; drag items onto a wall to hang them there
enum ViewMode { TOPDOWN, VIEW3D }
var SCREEN_W := 1280.0   # full width of the play screen, same as RIGHT_X
var _view_mode: int = ViewMode.TOPDOWN
var _mode3d_view:    Control = null   # persistent 3D view for VIEW3D mode (separate from the "reveal" overlay)
var _mode3d_sell_floor: Floor = null  # which Floor _mode3d_view's sell_requested/wall_sell_requested are currently bound to — see _ensure_mode3d_view
var _walk_view_index := 0           # the 3D view's place among ui_layer's children before Walk Through raised it
var _watch_done_btn: Button  = null   # floating "back to results" button shown during free-camera Watch Again
var _post_win_view: bool = false      # true during Watch Again — level is already rented out, so editing/shortcuts are locked out; only the camera works
var _last_wall_click_by_floor: Dictionary = {}   # floor_id -> {edge, span_lo, span_hi} — for the "W" reopen-last-wall shortcut
var _furniture_menu_btn: Button = null       # persistent "Furniture" trigger — replaces the old always-docked Inventory sidebar
var _furniture_menu_backdrop: ColorRect = null   # dims the screen behind the wheel/catalog
var _mode_buttons:   Dictionary = {}  # ViewMode -> Button
var _mode_hint_lbl:  Label = null     # "click a wall" / "drag onto a wall" guidance outside the docked-pane modes
var _back_btn: Button = null          # "← Back to <parent>" — shown only inside a nested box, see _update_nested_nav()
var _breadcrumb_lbl: Label = null     # "Root > Shoebox > Shoebox Interior" — which apartment we're actually in, since nested boxes are otherwise only inferable from the mini-plan cards
var _comfort_meter: Control = null   # live gm.comfort_pct fill bar (ComfortMeter.gd) — only shown when the level actually has yellow-tier furniture placed
var _intro_modal_open: bool = false   # "NEW MECHANIC" card is up — blocks zoom/pan everywhere
var _application: TenantApplication = null   # the level's rental application, if it has one
var _application_fax: ApplicationFax = null  # the fax printing/showing it, while it is up
var _applications_shown: Dictionary = {}     # level id -> true: printed once per visit, like the intro card
var tenant_layer: TenantLayer = null          # the household living in the apartment on screen (cosmetic)
var touch_controls: TouchControls = null      # gestures and the action bar for touch play

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
# a box (by double-clicking it, or from the Map — a single click or a drag
# leaves it a plain draggable piece of furniture) pushes the CURRENT level id so leaving it can reload the parent;
# the child level's own daylight is dimmed by daylight_factor to
# model the parent's furniture blocking light into the box (see
# _compute_box_occlusion()). Both directions snapshot the level being left
# via _snapshot_level_state() and restore it on return via
# _apply_level_state_snapshot(), so furniture placed/moved/folded/sold on
# either side of a box survives round-trips, not just the authored JSON state.
var _nested_stack: Array = []
var _current_nested_daylight_factor: float = 1.0
# Same transient-var pattern as daylight above: set in _on_box_entered() from
# the PARENT's own furniture around the box, consumed once in _load_level()
# to mute needs_quiet pieces inside the child (see Furniture.gd's noise
# comments) — reset on exit exactly like daylight, same known simplification
# (doesn't re-derive what an intermediate level's own entry conditions were).
var _current_nested_noisy_from_outside: bool = false
# Same transient-var pattern again: which of the PARENT's external_zone
# "by_wall" restriction profiles (if any) applies inside the box, based on
# which of the room's 4 sides the box sat closest to when entered — moving
# the same box against a different wall of the parent (the "noisy street"
# side vs. a quiet interior wall) can subject its interior to different
# restrictions. Merged into the child's own external_restrictions in
# _load_level(), not replacing them, so a child level can still author its
# own baseline restrictions independent of where its box happens to sit.
var _current_nested_external_override: Dictionary = {}
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
# The same levels captured in full (LevelProgress: wall items, moments, built
# walls... which the cache above leaves out), restored in preference to it.
# Together they are what the autosave keeps of a project.
var _full_level_states: Dictionary = {}
var _resuming := false          # this load opens a saved project where it was left
var _autosave_dirty := false    # something changed since the last autosave
var _autosave_timer: Timer
# A project (the apartment from the map and every box inside it) is rented
# out only when all of its apartments with tenants are done. Each one's
# result is remembered as last seen on screen, with the conditions its box
# gave it (light, noise, rules from outside); see _project_status().
var _level_ok: Dictionary = {}      # level id -> {"ok": bool, "cond": Dictionary}
var _box_cond: Dictionary = {}      # child level id -> the conditions its box has now, as last seen around it
var _completing_project := false    # stepping out of the boxes to rent the whole project out
# Set while a level is being put together piece by piece (loading it,
# restoring it after a box trip or an undo): every piece put down would
# otherwise run the whole needs check again, which made stepping out of a
# box take seconds. The check runs once when the level is complete.
var _batch_refresh := false
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
# Nested navigation UI: a "Map" button (opens NestedMap, the tree of every
# apartment in this project) and a "Back" button (one level up), both on
# their own CanvasLayer — see _ensure_nested_ui_layer().
var _nested_ui_layer: CanvasLayer = null
var _map_btn: Button = null
var _map_jump_busy: bool = false   # a map jump is travelling through several apartments
# Stepping into or out of a box is shown as a short camera move, about half a
# second in all: the view pushes into the box (or pulls back from the room)
# as a veil comes down, the level is swapped behind the veil, and the new
# view settles as the veil lifts. See _travel_depart() / _travel_arrive().
const NESTED_TRAVEL_OUT := 0.25
const NESTED_TRAVEL_IN  := 0.27
var _nested_travel_busy: bool = false
# Each apartment keeps its own 3D camera (angle, zoom, where it looks): saved
# here by level id when leaving, handed back to the view when returning. See
# _hand_over_camera().
var _camera_by_level: Dictionary = {}
var _camera_before_travel: Dictionary = {}   # the camera as the player left it, before the travel move started bending it
var _travel_veil: ColorRect = null
# Reentrancy guard — blocks a second transition from starting while one is
# already tearing down/rebuilding the level.
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


# ── Filling the window ───────────────────────────────────────────────────────
# The play screen was laid out for exactly 1280 x 720, so any window that was
# not exactly 16:9 showed an unused band along one edge. It now takes the
# whole window: while this screen is up the window's contents are allowed to
# extend past the 16:9 design area, and the right and bottom edges every
# panel is placed against (RIGHT_X, BOT_Y) follow the real size.
var _window_fit_busy := false

func _fit_to_window() -> void:
	var visible := get_viewport().get_visible_rect().size
	var w := maxf(visible.x, 960.0)
	var h := maxf(visible.y, 540.0)
	if is_equal_approx(w, RIGHT_X) and is_equal_approx(h, BOT_Y):
		return
	RIGHT_X = w
	SCREEN_W = w
	BOT_Y = h
	if _floors.is_empty() or _window_fit_busy:
		return    # nothing laid out yet; the first layout will use the new edges
	_window_fit_busy = true
	_position_top_left_icons()
	_position_undo_btn()
	_position_minimap()
	if _is_furniture_menu_open():
		_position_furniture_catalog_modal()
	_position_budget_label()
	_position_comfort_meter()
	for backdrop in [_furniture_menu_backdrop]:
		if is_instance_valid(backdrop):
			(backdrop as ColorRect).offset_right = SCREEN_W
			(backdrop as ColorRect).offset_bottom = BOT_Y
	if is_instance_valid(_mode_hint_lbl):
		_mode_hint_lbl.offset_right = RIGHT_X
	if is_instance_valid(_breadcrumb_lbl):
		_breadcrumb_lbl.offset_right = RIGHT_X
	if is_instance_valid(_mode3d_view):
		_mode3d_view.offset_right = RIGHT_X
		_mode3d_view.offset_bottom = BOT_Y if _mode3d_view.first_person else _floor_pane_bottom_y()
	var fl := _floors.get(_current_floor_id) as Floor
	if fl and _view_mode == ViewMode.TOPDOWN:
		_fit_floor(fl, true)
	_update_nested_nav()
	_window_fit_busy = false


func _ready() -> void:
	# The desk the plan lies on, behind everything else on this screen.
	var desk_layer := CanvasLayer.new()
	desk_layer.layer = -10
	desk_layer.name = "Desk"
	add_child(desk_layer)
	desk_layer.add_child(DeskBackdrop.new())
	_fit_to_window()
	get_viewport().size_changed.connect(func(): _fit_to_window.call_deferred())
	GameState.pathing_rule_changed.connect(func(_on: bool): _refresh_functions())
	tenant_card.need_clicked.connect(_on_need_clicked)
	tenant_card.items_clicked.connect(_on_items_clicked)
	tenant_card.application_requested.connect(_reopen_application)
	tenant_card.project_map_requested.connect(_open_nested_map)
	tenant_layer = TenantLayer.new()
	tenant_layer.main = self
	tenant_layer.gm = gm
	tenant_layer.card = tenant_card
	add_child(tenant_layer)
	# The bar grows upward when its chips wrap (rule chips arrive after the
	# needs): everything that sits on it or under it follows.
	tenant_card.height_changed.connect(func(): _relayout_bottom_bar.call_deferred())
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
	if not result_screen.walk_through_requested.is_connected(_on_walk_through):
		result_screen.walk_through_requested.connect(_on_walk_through)
	if not result_screen.advance_level_requested.is_connected(_on_advance_level):
		result_screen.advance_level_requested.connect(_on_advance_level)
	divider.mouse_filter = Control.MOUSE_FILTER_STOP
	divider.mouse_default_cursor_shape = Control.CURSOR_VSPLIT
	if not divider.gui_input.is_connected(_on_divider_gui_input):
		divider.gui_input.connect(_on_divider_gui_input)
	Furniture.on_box_enter_requested = _enter_box_animated
	touch_controls = TouchControls.new()
	touch_controls.main = self
	add_child(touch_controls)
	Furniture.on_long_press = func(f: Furniture): touch_controls.show_piece(f)
	Furniture.on_drag_dropped = _on_furniture_dropped
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = true
	_autosave_timer.timeout.connect(_autosave_now)
	add_child(_autosave_timer)
	if GameState.pending_resume and GameState.has_progress(GameState.pending_level_id):
		_prepare_resume(GameState.get_progress(GameState.pending_level_id))
	GameState.pending_resume = false
	Furniture.on_drag_moved = _on_furniture_drag_moved
	Furniture.on_purchase_dropped = _on_purchase_dropped
	if not inventory.place_owned_requested.is_connected(_on_place_owned_requested):
		inventory.place_owned_requested.connect(_on_place_owned_requested)
	Furniture.is_in_floor_pane = func(pos: Vector2) -> bool:
		# The screen-rectangle check alone isn't enough: the Wall Inspector's
		# elevation view can occupy that exact same rectangle when open,
		# which made clicks/drags meant for it get misread as "landed on the
		# floor plan" — letting the OTHER ghost armed by the same purchase
		# (see Main.gd's _on_buy_requested) react to stale floor coordinates
		# and surface its own rejection (e.g. "Outside the room") even while
		# the player was clearly placing the item on a wall instead.
		return pos.x > LEFT_X and pos.x < RIGHT_X and pos.y > TOP_Y and pos.y < _floor_pane_bottom_y()
	_update_split(_split_y)
	_apply_ui_theme()
	_load_level(GameState.pending_level_id)


func _apply_ui_theme() -> void:
	var t := GameTheme.make_legacy()
	minimap.theme       = t
	tenant_card.theme   = t
	inventory.theme     = t

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
		_test_btn.text        = tr("Test Layout")
		_test_btn.toggle_mode = true
		GameTheme.hud_button(_test_btn)
		_test_btn.toggled.connect(_on_test_toggled)
		_test_btn.visible = false   # updated after level load
		ui_layer.add_child(_test_btn)

	# Nested/parabox levels: entering/leaving a box is now a link button
	# living right in the Minimap floor-tab strip (see _refresh_nested_links())
	# instead of a separate floating button — "which space am I looking at"
	# reads as one row: this apartment's floors, plus any box you can step
	# into, plus (if you're inside one) the way back out.

	# View-mode switcher: two ways to look at the apartment (see the ViewMode
	# enum comment). Mutually exclusive via a ButtonGroup. Sits in the
	# top-right row (see _position_view_mode_box).
	if not is_instance_valid(_view_mode_box):
		var box := HBoxContainer.new()
		box.name = "ViewModeBox"
		box.add_theme_constant_override("separation", 0)
		var group := ButtonGroup.new()
		var specs := [
			[ViewMode.TOPDOWN, tr("Floor Plan"), tr("Blueprint view — place and move furniture from above")],
			[ViewMode.VIEW3D,  "3D",         tr("Walk around and place items in 3D — drag onto a wall to hang them")],
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
			btn.custom_minimum_size = Vector2(0, GameTheme.TOUCH_SMALL)   # same height as the undo / redo / menu buttons beside it
			btn.button_pressed = (mode == _view_mode)
			btn.add_theme_font_override("font", GameTheme.font("ui"))
			btn.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
			# Segmented-control look: one connected row of cards, only the
			# outer ends rounded, the chosen one filled navy.
			btn.add_theme_stylebox_override("normal",  GameTheme.segment_style(i, specs.size(), false))
			btn.add_theme_stylebox_override("hover",   GameTheme.segment_style(i, specs.size(), false, true))
			btn.add_theme_stylebox_override("pressed", GameTheme.segment_style(i, specs.size(), true))
			btn.add_theme_stylebox_override("hover_pressed", GameTheme.segment_style(i, specs.size(), true))
			btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())
			for c in ["font_color", "font_hover_color", "font_focus_color"]:
				btn.add_theme_color_override(c, GameTheme.INK)
			btn.add_theme_color_override("font_pressed_color", GameTheme.CHALK)
			btn.add_theme_color_override("font_hover_pressed_color", GameTheme.CHALK)
			btn.pressed.connect(func():
				Audio.play("click")
				_set_view_mode(mode))
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
		_settings_btn.text = "\ueb20"
		_settings_btn.tooltip_text = tr("Menu — settings, back to projects, quit")
		GameTheme.hud_button(_settings_btn, true)
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
		_editor_back_btn.text = tr("← Back to Editor")
		_editor_back_btn.tooltip_text = tr("Return to the Level Editor, resuming the level you were testing")
		_editor_back_btn.add_theme_font_size_override("font_size", 12)
		_editor_back_btn.visible = false
		_editor_back_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_editor_back_btn.offset_left = 8.0
		# TOP_Y (10) + the Furniture button's own ~34px height + a gap —
		# this used to sit at the exact same (8, 8) spot as "🛋 Furniture",
		# fully overlapping it (that button's own position is LEFT_X+8, TOP_Y).
		_editor_back_btn.offset_top = TOP_Y
		_editor_back_btn.pressed.connect(func():
			GameState.testing_from_editor = false
			Transition.change_scene("res://scenes/LevelEditor.tscn"))
		canvas.add_child(_editor_back_btn)

	if not is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn = Button.new()
		_furniture_menu_btn.name = "FurnitureMenuBtn"
		_furniture_menu_btn.text = "\uefaf  %s  \uea62" % tr("Furniture")
		_furniture_menu_btn.tooltip_text = tr("Open or close the furniture catalogue (F)")
		# It sits at the right-hand end of the needs bar and is drawn as part
		# of it: the bar is the handle of the catalogue that opens under it.
		# It is the screen's one red button: buying is the main action.
		GameTheme.hud_button(_furniture_menu_btn)
		for state in ["normal", "hover", "pressed", "hover_pressed"]:
			var sb := (_furniture_menu_btn.get_theme_stylebox(state) as StyleBoxFlat).duplicate() as StyleBoxFlat
			sb.bg_color = GameTheme.RED if state == "normal" else GameTheme.RED.darkened(0.15)
			_furniture_menu_btn.add_theme_stylebox_override(state, sb)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			_furniture_menu_btn.add_theme_color_override(c, GameTheme.CHALK)
		_furniture_menu_btn.pressed.connect(func():
			if _is_furniture_menu_open():
				_close_furniture_menu()
			else:
				_open_furniture_menu())
		ui_layer.add_child(_furniture_menu_btn)

	if not is_instance_valid(_undo_btn):
		_undo_btn = Button.new()
		_undo_btn.name = "UndoBtn"
		_undo_btn.text = "\ueb77"
		_undo_btn.tooltip_text = tr("Undo last action (Ctrl+%s)") % OS.get_keycode_string(GameState.undo_keycode)
		GameTheme.hud_button(_undo_btn, true)
		_undo_btn.offset_top = TOP_Y + 8.0
		_undo_btn.pressed.connect(_undo_builder_action)
		ui_layer.add_child(_undo_btn)
	if not is_instance_valid(_redo_btn):
		_redo_btn = Button.new()
		_redo_btn.name = "RedoBtn"
		_redo_btn.text = "\ueb78"
		_redo_btn.tooltip_text = tr("Redo (Ctrl+Shift+%s)") % OS.get_keycode_string(GameState.undo_keycode)
		GameTheme.hud_button(_redo_btn, true)
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
	if not is_instance_valid(budget_label) or not is_instance_valid(tenant_card):
		return
	# The budget is part of the bottom bar, beside the Furniture button: what
	# you can spend sits next to where you spend it. It used to float on its
	# own above the bar's left end.
	if not budget_label.has_meta("in_bar"):
		budget_label.set_meta("in_bar", true)
		var plain := StyleBoxEmpty.new()
		plain.set_content_margin(SIDE_LEFT, 4)
		plain.set_content_margin(SIDE_RIGHT, 4)
		budget_label.add_theme_stylebox_override("normal", plain)
		budget_label.add_theme_font_override("font", GameTheme.font("mono_bold"))
		budget_label.add_theme_font_size_override("font_size", GameTheme.FS_LABEL)
		budget_label.add_theme_color_override("font_color", GameTheme.INK)
		budget_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	budget_label.offset_left = 0.0
	budget_label.reset_size()
	var w := budget_label.size.x
	var right := (_furniture_menu_btn.offset_left - 12.0) if is_instance_valid(_furniture_menu_btn) else (RIGHT_X - 12.0)
	budget_label.offset_right  = right
	budget_label.offset_left   = right - w
	budget_label.offset_top    = _bar_row_top(GameTheme.TOUCH_SMALL)
	budget_label.offset_bottom = budget_label.offset_top + GameTheme.TOUCH_SMALL
	ui_layer.move_child(budget_label, ui_layer.get_child_count() - 1)
	_position_comfort_meter()


const COMFORT_METER_SIZE := Vector2(140.0, 36.0)  # a gauge in the bottom bar: "Comfort 100%"

func _ensure_comfort_meter() -> void:
	if is_instance_valid(_comfort_meter):
		return
	_comfort_meter = ComfortMeterScript.new()
	_comfort_meter.name = "ComfortMeter"
	_comfort_meter.mouse_filter = Control.MOUSE_FILTER_STOP   # for its tooltip
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
	# In the bottom bar, just left of the budget. (It used to float above
	# the bar's left end.)
	_comfort_meter.offset_right  = budget_label.offset_left - 14.0
	_comfort_meter.offset_left   = _comfort_meter.offset_right - COMFORT_METER_SIZE.x
	_comfort_meter.offset_top    = _bar_row_top(COMFORT_METER_SIZE.y)
	_comfort_meter.offset_bottom = _comfort_meter.offset_top + COMFORT_METER_SIZE.y
	ui_layer.move_child(_comfort_meter, ui_layer.get_child_count() - 1)


# Where something `h` tall goes so it is centred on the needs bar's first row
# (its chips are TOUCH_SMALL tall, under the bar's 8 px top margin).
func _bar_row_top(h: float) -> float:
	return tenant_card.offset_top + 8.0 + (GameTheme.TOUCH_SMALL - h) * 0.5


# Every yellow-tier piece that sits away from where it started (and so costs
# comfort, see GameManager.compute_comfort()) shows where that was: a faint
# outline of it on its old spot, a line back to it and what it costs, on the
# plan and in 3D. When a piece starts or stops costing comfort, that is said
# once (pieces seen for the first time, on loading, are only noted).
var _moved_names: Array = []           # what is costing comfort right now, for the meter's tooltip
var _away_seen: Dictionary = {}        # furniture instance id -> whether it was away last time
var _home_marks: Array = []            # what _show_moved_from_home() last showed, for a 3D view built later

func _show_moved_from_home() -> void:
	_moved_names = []
	var all_marks: Array = []
	var moment := _active_moment_id as String
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var marks: Array = []
		for entry in fl.get_all_furniture():
			var f := entry as Furniture
			if f.mobility_tier != "yellow" or f._home_grid_pos == Vector2(-1, -1):
				continue
			var at := f.get_moment_position(moment)
			var away := at != f._home_grid_pos
			var id := f.get_instance_id()
			if _away_seen.has(id) and _away_seen[id] != away and not _restoring_furniture:
				if away:
					_toast(tr("The %s was fine where it was: moving it costs %d%% comfort. Its old spot is marked.") % [f.furniture_name, roundi(gm.COMFORT_COST_PER_ITEM)])
				else:
					_toast(tr("The %s is back where it started: comfort restored.") % f.furniture_name)
			_away_seen[id] = away
			if not away:
				continue
			_moved_names.append(f.furniture_name)
			var mark := {"home": f._home_grid_pos, "size": Vector2(f.grid_w, f.grid_h), "at": at,
				# A bare "−25%" on the plan read as nothing in particular: it says
				# what the spot is and what the percentage is of.
				"cost": tr("Started here") + "
" + tr("Comfort −%d%%") % roundi(gm.COMFORT_COST_PER_ITEM)}
			marks.append(mark)
			if fid == _current_floor_id:
				all_marks.append(mark)
		fl.set_home_marks(marks)
	_home_marks = all_marks
	if is_instance_valid(_mode3d_view):
		_mode3d_view.set_home_marks(all_marks)


# Only worth showing on a level that actually uses the mechanic — a level
# with no yellow-tier furniture at all would just show a permanent, mute
# "Comfort 100%" that explains nothing. Called from _refresh_functions()
# alongside every other post-move recompute.
func _update_comfort_meter() -> void:
	_show_moved_from_home()
	var has_yellow := false
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			if (f as Furniture).mobility_tier == "yellow":
				has_yellow = true
				break
		if has_yellow:
			break
	if not has_yellow:
		if is_instance_valid(_comfort_meter) and _comfort_meter.visible:
			_comfort_meter.visible = false
			_position_minimap()
		return
	_ensure_comfort_meter()
	var was_hidden := not _comfort_meter.visible
	_comfort_meter.visible = true
	_comfort_meter.set_value(gm.comfort_pct, gm.COMFORT_WARN_THRESHOLD)
	_comfort_meter.set_moved(_moved_names)
	if was_hidden:
		_position_minimap()   # re-lays the bar, which now reserves room for the gauge
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
	_autosave_now()
	Transition.change_scene("res://scenes/CityMap.tscn")


# Discoverable escape hatch for a bad layout (spent the budget on the wrong
# things, boxed furniture in unreachably, etc.) — an incomplete level never
# persists its furniture (GameState only saves a layout on a level a player
# has already won at least once), so this is just _load_level() again, same
# as leaving to Projects and re-entering would already do, minus the detour.
func _restart_level() -> void:
	# Starting the apartment over forgets the saved one too (the boxes inside
	# keep what was left in them, as before).
	if _nested_stack.is_empty():
		GameState.clear_progress(_current_level_id)
		_full_level_states.erase(_current_level_id)
		_level_state_cache.erase(_current_level_id)
	_autosave_dirty = false
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
	if is_instance_valid(_application_fax):
		_application_fax.queue_free()
	_application_fax = null
	if tenant_layer:
		tenant_layer.stop()
	if touch_controls:
		touch_controls.close_actions()
	if is_instance_valid(_editor_back_btn):
		# Stays visible through the WHOLE test session, not just while on the
		# root ("_custom") level — GameState.testing_from_editor is set once
		# by LevelEditor._test_level() and only cleared by leaving to
		# CityMap or actually using this button, so it survives navigating
		# into/out of any number of nested boxes in between.
		_editor_back_btn.visible = GameState.testing_from_editor
	gm.load_level(level_id)
	# Nested/parabox: merge in whatever external_zone profile the PARENT
	# assigns to the wall this box sat closest to (see _closest_wall_side()
	# and _on_box_entered()) — additive on top of the child's OWN authored
	# external_zone, not replacing it, so moving the same box to a different
	# wall changes what applies without erasing the level's own baseline.
	if not _nested_stack.is_empty() and not _current_nested_external_override.is_empty():
		var ov := _current_nested_external_override
		var ff: Array = (gm.external_restrictions.get("forbidden_functions", []) as Array).duplicate()
		for fn in ov.get("forbidden_functions", []) as Array:
			if fn not in ff:
				ff.append(fn)
		gm.external_restrictions["forbidden_functions"] = ff
		var mbd: Dictionary = (gm.external_restrictions.get("min_boundary_distance", {}) as Dictionary).duplicate()
		for fn in (ov.get("min_boundary_distance", {}) as Dictionary):
			mbd[fn] = maxi(mbd.get(fn, 0) as int, (ov["min_boundary_distance"] as Dictionary)[fn] as int)
		gm.external_restrictions["min_boundary_distance"] = mbd
	tenant_card.set_rented(false)
	_post_win_view   = false
	_rent_auto_armed = false
	_level_completed = false
	Furniture.read_only     = false
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = false
	# Stepping into a box, back out of it, or restarting keeps the catalogue
	# as the player left it; it is re-opened below once the new shop is in.
	var _reopen_catalog := _catalog_wanted
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
		# Walls are not opened from the plan any more (see _disable_plan_wall_select).
		_disable_plan_wall_select(apt_floor)
		apt_floor.visible = false
		_floors[fd["id"]] = apt_floor
		if fd["id"] in _floor_below_id:
			apt_floor.below_floor = _floors.get(_floor_below_id[fd["id"]] as String) as Floor

		_batch_refresh = true
		apt_floor.begin_batch()
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
	# not just cosmetic on the child's own window rendering. The noise
	# equivalent (_current_nested_noisy_from_outside) is applied inside
	# _recompute_box_effects() instead, since that's the one place already
	# resetting/reapplying _noise_muted every refresh — setting it here too
	# would just get immediately wiped by the _refresh_functions() call below.
	if first_floor_node and not _nested_stack.is_empty():
		first_floor_node.set_external_daylight_factor(_current_nested_daylight_factor)
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
	_application = TenantApplication.for_level(level_id)
	var hidden_reqs: Array = _application.hidden_requirements() if _application else []
	tenant_card.set_application(_application != null, hidden_reqs)
	if not gm.moments.is_empty():
		var _first_mid := (gm.moments[0] as Dictionary)["id"] as String
		_on_moment_selected(_first_mid, false)
	inventory.setup(gm)
	inventory.hidden_needs = hidden_reqs.filter(func(r): return (r as String).begins_with("need:")) \
		.map(func(r): return (r as String).trim_prefix("need:"))
	var shop_list: Array = gm.furniture_data["furniture"]
	if not gm.allowed_furniture.is_empty():
		shop_list = shop_list.filter(func(f): return (f["id"] as String) in gm.allowed_furniture)
	inventory.populate(shop_list)
	# Pieces sent here from another apartment before this one was ever opened.
	if _pending_arrivals.has(level_id):
		for arrival in _pending_arrivals[level_id] as Array:
			_add_owned(gm.starting_inventory, (arrival as Dictionary)["id"] as String, (arrival as Dictionary)["count"] as int)
		_pending_arrivals.erase(level_id)
	_refresh_owned_ui()
	if _reopen_catalog:
		_open_furniture_menu.call_deferred()
	budget_label.text = "\ueb82 %d €" % gm.budget
	budget_label.tooltip_text = tr("Budget")
	budget_label.mouse_filter = Control.MOUSE_FILTER_PASS

	# Start on the first visible floor (skip hidden ones)
	var first_visible_id := floors_data[0]["id"] as String
	for _fd in floors_data:
		if not ((_fd as Dictionary)["id"] as String in hidden_floors):
			first_visible_id = (_fd as Dictionary)["id"] as String; break
	for _bfid in _floors:
		(_floors[_bfid] as Floor).end_batch()
	_batch_refresh = false
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
		# box) after the nav buttons were set up — refresh them against
		# what's actually on the floor now.
		_update_nested_nav()
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

	if _resuming:
		_resuming = false
		_applications_shown[level_id] = true   # it was already read: no need to print it again
		_restore_level_state(level_id)
	_start_tenants()
	_show_application_if_needed()
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
	if _use_saved and _level_has_goal() and gm.check_win():
		_show_existing_completion(level_id, _load_gen)


# See _load_level's call site above for why this is fire-and-forget with a
# generation check rather than something _load_level awaits directly.
func _show_existing_completion(level_id: String, load_gen: int) -> void:
	tenant_card.set_rented(true)
	await _play_completion_reveal()
	if load_gen != _level_load_id:
		return
	_level_completed = true
	result_screen.show_success(_result_info(GameState.get_stars(level_id), 0,
		not gm.get_next_owned_level_id(level_id).is_empty()))


# What the results screen reports about the level just rented out.
func _result_info(stars: int, funds: int, has_next: bool) -> Dictionary:
	return {
		"level_name": gm.current_level.get("name", "") as String,
		"tenant": gm.current_level["tenant"]["name"],
		"rent": gm.current_level["tenant"]["monthly_rent"] as int,
		"stars": stars,
		"funds": funds,
		"portfolio": GameState.portfolio_rent,
		"has_next": has_next,
		"budget_left": gm.budget,
		"budget_start": gm.current_level.get("starting_budget", 0) as int,
	}


var _intros_shown: Dictionary = {}   # level id -> true, for this session in the play screen

# ── Completing a project ─────────────────────────────────────────────────────

# The light, noise and outside rules a box passes to the apartment inside
# it, as _on_box_entered() applies them; compared to tell whether a box
# finished earlier still counts after the apartment around it changed.
func _cond_for_box(box: Furniture) -> Dictionary:
	var side := _closest_wall_side(box._wall_ref, box)
	return {
		"light": snappedf(_compute_box_occlusion(box), 0.01),
		"noisy": _has_noisy_neighbor(box._wall_ref, box.grid_pos, box.grid_w, box.grid_h, box),
		"rules": (gm.external_restrictions.get("by_wall", {}) as Dictionary).get(side, {}),
	}


func _current_cond() -> Dictionary:
	return {
		"light": snappedf(_current_nested_daylight_factor, 0.01),
		"noisy": _current_nested_noisy_from_outside,
		"rules": _current_nested_external_override,
	}


# Notes how the apartment on screen stands, and what each of its boxes
# passes on to the apartment inside.
func _record_level_status() -> void:
	if _current_level_id == "" or _post_win_view:
		return
	var ok := (not _level_has_goal()) or (gm.check_win() and _all_furniture_accessible())
	_level_ok[_current_level_id] = {"ok": ok, "cond": _current_cond()}
	for box in _collect_nested_boxes():
		_box_cond[box.child_level_id] = _cond_for_box(box)


func _level_wants_tenant(level_id: String) -> bool:
	var ld := _lookup_level_dict(level_id)
	var tenant := ld.get("tenant", {}) as Dictionary
	return not (tenant.get("required_functions", []) as Array).is_empty() or not (ld.get("moments", []) as Array).is_empty()


# Every apartment of the project that has tenants to satisfy: the one from
# the map, and the boxes inside it, however deep.
func _project_levels() -> Array:
	var root := _root_level_id()
	var out: Array = []
	var queue: Array = [root]
	var seen := {root: true}
	while not queue.is_empty():
		var lid: String = queue.pop_front()
		if _level_wants_tenant(lid) or lid == root:
			out.append(lid)
		for child in _nested_children_of(lid):
			var cid := (child as Dictionary)["child_level_id"] as String
			if not seen.has(cid):
				seen[cid] = true
				queue.append(cid)
	return out


# Whether an apartment counts as done: as last seen on screen, and (for a box
# seen before something around it changed) under the same conditions.
func _level_done(level_id: String) -> bool:
	var st := _level_ok.get(level_id, {}) as Dictionary
	if not (st.get("ok", false) as bool):
		return false   # not ready, or never opened yet
	if level_id == _root_level_id() or level_id == _current_level_id or not _box_cond.has(level_id):
		return true
	return not _cond_change_matters(level_id, st.get("cond", {}) as Dictionary, _box_cond[level_id] as Dictionary)


# Whether what changed around a box since its apartment was finished can
# change that apartment's result: light only matters to something that needs
# daylight or space by a window, noise only to something that needs quiet,
# and outside rules always. Anything else (a bed put down beside the box)
# leaves it ready.
func _cond_change_matters(level_id: String, was: Dictionary, now: Dictionary) -> bool:
	if was.get("rules", {}) != now.get("rules", {}):
		return true
	var light_changed := not is_equal_approx(float(was.get("light", 1.0)), float(now.get("light", 1.0)))
	var noise_changed := bool(was.get("noisy", false)) != bool(now.get("noisy", false))
	if not light_changed and not noise_changed:
		return false
	var needs_light := false
	var needs_quiet := false
	for it in _child_furniture_items(level_id):
		var fdata := gm.get_furniture_by_id(str((it as Dictionary).get("id", "")))
		needs_light = needs_light or (fdata.get("needs_daylight", false) as bool)
		needs_quiet = needs_quiet or (fdata.get("needs_quiet", false) as bool)
	for m in _lookup_level_dict(level_id).get("moments", []) as Array:
		for need in ((m as Dictionary).get("space_needs", {}) as Dictionary).values():
			if need is Dictionary and (need as Dictionary).get("near_window", false):
				needs_light = true
	return (light_changed and needs_light) or (noise_changed and needs_quiet)


# For the box map: "none" (no tenants to satisfy), "ready", "todo", or
# "recheck" (it was ready, but something around its box has changed since).
func _level_state_label(level_id: String, is_root: bool) -> String:
	if not is_root and not _level_wants_tenant(level_id):
		return "none"
	if _level_done(level_id):
		return "ready"
	if ((_level_ok.get(level_id, {}) as Dictionary).get("ok", false) as bool):
		return "recheck"
	return "todo"


# {complete, done, total, pending_names}: how many of the project's
# apartments are ready, and the names of those that aren't.
func _project_status() -> Dictionary:
	var levels := _project_levels()
	var done := 0
	var pending: Array = []
	for lid in levels:
		if _level_done(lid):
			done += 1
		else:
			pending.append(_level_display_name(lid))
	var root := _root_level_id()
	var has_goal := _level_wants_tenant(root) or levels.size() > 1
	return {"complete": has_goal and done == levels.size(), "done": done, "total": levels.size(), "pending_names": pending}


# Everything is done: rent the project out from its own apartment, stepping
# out of the boxes first if the last thing finished was inside one.
func _complete_project() -> void:
	_completing_project = true
	if not _nested_stack.is_empty():
		_exit_nested_level_to(0)
		await get_tree().process_frame
	_completing_project = false
	_on_rent_pressed()


# ── Autosave ─────────────────────────────────────────────────────────────────
# The project on screen (the apartment opened from the map, and the boxes
# inside it) is saved as the player goes, so closing the game, or a phone
# dropping it in the background, loses nothing. GameState.progress keeps one
# entry per project; the map offers to continue it.

# The level opened from the map, whichever box the player is inside now.
func _root_level_id() -> String:
	if not _nested_stack.is_empty():
		return (_nested_stack[0] as Dictionary)["parent_level_id"] as String
	return _current_level_id


func _can_autosave() -> bool:
	return not _post_win_view and not GameState.testing_from_editor and _current_level_id != "" \
		and _current_level_id != "_custom" and not _restoring_furniture


# Something changed: save in a moment (one write for a burst of changes).
func _autosave_soon() -> void:
	if not _can_autosave() or _autosave_timer == null:
		return
	_autosave_dirty = true
	_autosave_timer.start(1.0)


func _autosave_now() -> void:
	if not _autosave_dirty or not _can_autosave():
		return
	_autosave_dirty = false
	if _autosave_timer:
		_autosave_timer.stop()
	_remember_level_state()
	GameState.set_progress(_root_level_id(), {
		"at": int(Time.get_unix_time_from_system()),
		"level": _current_level_id,
		"levels": var_to_str(_full_level_states),
		"cache": var_to_str(_level_state_cache),
		"pending": var_to_str(_pending_arrivals),
		"status": var_to_str({"ok": _level_ok, "box": _box_cond}),
	})


# Loads a saved project's levels before the first _load_level(), which then
# restores the one it opens (see _resuming); the boxes inside are restored
# as the player steps into them.
func _prepare_resume(entry: Dictionary) -> void:
	var levels = str_to_var(entry.get("levels", "{}") as String)
	var cache = str_to_var(entry.get("cache", "{}") as String)
	var pending = str_to_var(entry.get("pending", "{}") as String)
	if levels is Dictionary:
		_full_level_states = levels
	if cache is Dictionary:
		_level_state_cache = cache
	if pending is Dictionary:
		_pending_arrivals = pending
	var status = str_to_var(entry.get("status", "{}") as String)
	if status is Dictionary:
		_level_ok = (status as Dictionary).get("ok", {})
		_box_cond = (status as Dictionary).get("box", {})
	_resuming = true


# Remembers the level on screen before leaving it (or saving).
func _remember_level_state() -> void:
	_level_state_cache[_current_level_id] = _snapshot_level_state()
	_full_level_states[_current_level_id] = LevelProgress.capture(self)


# Puts back what the player left in `level_id`, if anything.
func _restore_level_state(level_id: String) -> void:
	if _full_level_states.has(level_id):
		LevelProgress.apply(self, _full_level_states[level_id] as Dictionary)
	elif _level_state_cache.has(level_id):
		_apply_level_state_snapshot(_level_state_cache[level_id])


func _notification(what: int) -> void:
	# The phone sends the game to the background, or the window is closing.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_autosave_now()


# The tenant's rental application prints the first time a level is opened in
# a visit (not again on restarting it or coming back out of a box, and not on
# a level already rented out); the mechanic card, if any, follows it.
func _show_application_if_needed() -> void:
	var lid := gm.current_level.get("id", "") as String
	if _application == null or lid in GameState.completed or _applications_shown.has(lid):
		_show_mechanic_intro_if_needed()
		return
	_applications_shown[lid] = true
	_application_fax = ApplicationFax.open(self, _application, tenant_card, true)
	_application_fax.closed.connect(_show_mechanic_intro_if_needed)


func _reopen_application() -> void:
	if _application == null or is_instance_valid(_application_fax) or _blocking_modal_open():
		return
	_application_fax = ApplicationFax.open(self, _application, tenant_card, false)


func _show_mechanic_intro_if_needed() -> void:
	var intro: Dictionary = gm.current_level.get("mechanic_intro", {}) as Dictionary
	if intro.is_empty():
		return
	var lid := gm.current_level.get("id", "") as String
	if lid in GameState.completed:
		return  # already played this level — skip intro
	# Once per visit to the project: coming back out of a box (or restarting)
	# reloads this level, and must not put the card up again.
	if _intros_shown.has(lid):
		return
	_intros_shown[lid] = true

	# Build fullscreen CanvasLayer overlay
	var cl := CanvasLayer.new()
	cl.layer = 20
	add_child(cl)
	_intro_modal_open = true
	cl.tree_exited.connect(func(): _intro_modal_open = false)

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	cl.add_child(bg)
	ScreenFit.cover(bg)

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
	ScreenFit.keep_centered(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.add_child(vb)

	# "NEW MECHANIC" chip
	var chip := Label.new()
	chip.text = "  %s  " % tr("NEW MECHANIC")
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
	btn.text = tr("Got it — let's go!")
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
	var rail_keys := ["rail_axis", "rail_start", "rail_end", "reveal_start", "reveal_end", "reveal_functions", "child_level_id", "keepsake"]
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
	_weigh_box(f)
	# A level can author a piece already turned ("rot_steps": quarter turns).
	var authored_rot := rail_data.get("rot_steps", 0) as int
	if authored_rot != 0:
		f.set_rot_steps(authored_rot)
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

# A box whose apartment is under MIN_NESTED_INTERIOR_M2 can't be stepped
# into. Says so (it used to just beep) and returns true when that's the case.
func _refuse_cramped_box(box: Furniture) -> bool:
	var area := _level_floor_area_m2(box.child_level_id)
	if area >= MIN_NESTED_INTERIOR_M2:
		return false
	Audio.play("error")
	_toast(tr("Too cramped to step into: %.0f m² inside, a home needs at least %.0f m²") % [area, MIN_NESTED_INTERIOR_M2], true)
	return true


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
	if _refuse_cramped_box(box):
		return
	_nested_transition_busy = true
	var factor := _compute_box_occlusion(box)
	var shade_by := _shade_by
	var noisy_outside := _has_noisy_neighbor(box._wall_ref, box.grid_pos, box.grid_w, box.grid_h, box)
	var noisy_by := _noisy_by
	var wall_side := _closest_wall_side(box._wall_ref, box)
	# Standing on a table, the box can only get as heavy as the table allows:
	# what that leaves for its contents, in their own (unshrunk) weight.
	var carry_limit := -1.0
	var carry_name := ""
	var sup := box._wall_ref.support_under(box) if is_instance_valid(box._wall_ref) else null
	if sup != null:
		var spare := sup.max_support_weight - box._wall_ref._surface_load(sup, box) - box._base_weight
		var shrink := _box_shrink(box)
		carry_limit = maxf(spare, 0.0) / shrink if shrink > 0.0 else INF
		carry_name = sup.furniture_name
	var wall_override: Dictionary = (gm.external_restrictions.get("by_wall", {}) as Dictionary).get(wall_side, {}) as Dictionary
	_remember_level_state()
	# Remembers whether the level being left was in post-win "Watch Again"
	# (tenant showcase looping in read-only 3D) so stepping back out of the
	# box can resume it — _load_level() unconditionally resets
	# _post_win_view to false for the level it's loading, which otherwise
	# silently killed the showcase the moment you stepped into any box.
	var was_showcasing := _post_win_view
	# Where the box sits in this (soon to be parent) apartment — what the 3D
	# view needs to draw that apartment around the box's interior.
	var box_floor_id := ""
	for fid in _floors:
		if _floors[fid] == box._wall_ref:
			box_floor_id = fid as String
	_nested_stack.append({
		"parent_level_id": _current_level_id,
		"daylight_factor": factor,
		"shade_by": shade_by,
		"noisy_from_outside": noisy_outside,
		"noisy_by": noisy_by,
		"was_post_win_view": was_showcasing,
		"box_floor_id": box_floor_id,
		"box_rect": Rect2(box.grid_pos, Vector2(box.grid_w, box.grid_h)),
		"box_name": box.furniture_name,
		"box_base_tier": box._base_mobility_tier,
		"carry_limit": carry_limit,
		"carry_support_name": carry_name,
	})
	_current_nested_daylight_factor = factor
	_current_nested_noisy_from_outside = noisy_outside
	_current_nested_external_override = wall_override
	_hand_over_camera(_current_level_id, box.child_level_id)
	_load_level(box.child_level_id)
	_restore_level_state(box.child_level_id)
	_autosave_soon()
	# The box's own interior gets its own tenant too — if you were watching
	# the parent's tenant use its furniture, stepping into a box shouldn't
	# just make tenants vanish. Only if the child level is itself actually
	# won (gm.check_win()) — an unfinished nested apartment has no tenant to
	# showcase yet, same as any other not-yet-completed level.
	if was_showcasing and gm.check_win():
		_on_watch_again_reveal()
	# What the flat around the box does to it, said once on the way in (the
	# dim light and the noise marks show it from then on).
	var news: Array = []
	if factor < 0.99 and shade_by != "":
		news.append(tr("Little daylight gets in here: the %s outside stands in front of the box.") % shade_by)
	if noisy_outside and noisy_by != "":
		news.append(tr("Noisy in here: the %s right outside the box keeps anyone from sleeping.") % noisy_by)
	if not wall_override.is_empty() and _wall_rules_text(wall_override) != "":
		news.append(tr("This box stands by the %s: %s.") % [_wall_side_name(wall_side, wall_override), _wall_rules_text(wall_override)])
	if not news.is_empty():
		_toast("\n".join(news))
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
			"surface": fdata.get("is_surface", false) as bool,
		})
	# Drawn in order: what stands on a table (a box, a lamp) after the table,
	# so the thumbnail shows it on top rather than hidden underneath.
	var depth := func(r: Dictionary) -> int:
		var rect := Rect2(r["x"], r["y"], r["w"], r["h"])
		var n := 0
		for o in out:
			if not is_same(o, r) and o["surface"] and Rect2(o["x"], o["y"], o["w"], o["h"]).encloses(rect):
				n += 1
		return n
	for r in out:
		r["depth"] = depth.call(r)
	var by_depth: Array = []
	for level in range(4):
		by_depth.append_array(out.filter(func(r): return mini(r["depth"], 3) == level))
	return by_depth


# Inside a box, the 3D view can draw the apartment the box sits in around the
# room, giant (Room3DView._add_parent_scenery). This gathers what it needs
# from the parent's saved layout — the parent itself is not loaded. {} when
# not inside a box, or when the level doesn't want it.
# On for every level; a level opts out with "show_parent": false in its data.
func _parent_scenery_data() -> Dictionary:
	if _nested_stack.is_empty():
		return {}
	var level := _lookup_level_dict(_current_level_id)
	if not (level.get("show_parent", true) as bool):
		return {}
	return _scenery_for(_nested_stack.size() - 1)


# What the apartment at _nested_stack[index] looks like from inside its box,
# with the apartment it stands in turn nested under "outer".
func _scenery_for(index: int) -> Dictionary:
	var ctx := _nested_stack[index] as Dictionary
	if not ctx.has("box_rect"):
		return {}
	var parent_id := ctx["parent_level_id"] as String
	var floor_id := ctx.get("box_floor_id", "") as String
	var segments: Array = []
	for fd in (_lookup_level_dict(parent_id).get("apartment", {}) as Dictionary).get("floors", []) as Array:
		var floor_dict := fd as Dictionary
		if str(floor_dict.get("id", "")) == floor_id:
			segments = floor_dict.get("segments", []) as Array
	var items: Array = []
	var cached := _level_state_cache.get(parent_id, {}) as Dictionary
	for it in (cached.get("floors", {}) as Dictionary).get(floor_id, []) as Array:
		var d := it as Dictionary
		var fdata := gm.get_furniture_by_id(d.get("id", "") as String)
		if fdata.is_empty():
			continue
		items.append({"fdata": fdata, "x": d.get("x", 0), "y": d.get("y", 0),
			"rot_steps": d.get("rot_steps", 0), "is_extended": d.get("is_extended", false)})
	var out := {"segments": segments, "items": items, "box_rect": ctx["box_rect"], "level_id": parent_id}
	if index > 0:
		out["outer"] = _scenery_for(index - 1)
	return out


# Who lives in an apartment other than the one on screen, for the 3D view's
# extras (Room3DView.household_of): a box's household seen from the
# apartment around it, and that apartment's seen from inside the box.
func _household_of(level_id: String) -> Dictionary:
	var app := TenantApplication.for_level(level_id)
	if app == null:
		return {}
	return {"residents": app.residents, "area_m2": _level_floor_area_m2(level_id)}


# Own CanvasLayer, above ui_layer's, rather than living in ui_layer and
# fighting for sibling order there. Several things in ui_layer re-raise
# THEMSELVES to the end (_mode3d_view's full-screen input-capturing viewport,
# _show_watch_done_button, the Inventory...), and whichever ran last won —
# neither a z_index (Control input picking goes by tree order, not z_index)
# nor re-raising kept nested navigation clickable in the post-completion
# view. CanvasLayer order IS authoritative for both drawing and input
# picking, so a higher layer wins outright.
func _ensure_nested_ui_layer() -> CanvasLayer:
	if not is_instance_valid(_nested_ui_layer):
		_nested_ui_layer = CanvasLayer.new()
		_nested_ui_layer.name = "NestedNavLayer"
		_nested_ui_layer.layer = 5   # ui_layer / ResultScreen are both the default layer 1
		add_child(_nested_ui_layer)
	return _nested_ui_layer


# The nested boxes sitting in any apartment of the tree, whether or not it is
# the one loaded right now: live Furniture for the current level, the state
# cache for one visited this session, the authored level data otherwise.
# Returns [{child_level_id, x, y}].
func _nested_children_of(level_id: String) -> Array:
	var out: Array = []
	if level_id == _current_level_id:
		for box in _collect_nested_boxes():
			out.append({"child_level_id": box.child_level_id, "x": box.grid_pos.x, "y": box.grid_pos.y})
		return out
	var items: Array = []
	var cached := _level_state_cache.get(level_id, {}) as Dictionary
	if not cached.is_empty():
		for fid in (cached.get("floors", {}) as Dictionary):
			items.append_array((cached["floors"] as Dictionary)[fid] as Array)
	else:
		var ld := _lookup_level_dict(level_id)
		items.append_array(ld.get("starting_furniture", []) as Array)
		for fd in (ld.get("apartment", {}) as Dictionary).get("floors", []) as Array:
			items.append_array((fd as Dictionary).get("starting_furniture", []) as Array)
	for it in items:
		var d := it as Dictionary
		var fdata := gm.get_furniture_by_id(d.get("id", "") as String)
		if not (fdata.get("is_nested_box", false) as bool):
			continue
		# Per-instance override first, catalog default second — same order a
		# spawned Furniture resolves it in.
		var child := str(d.get("child_level_id", fdata.get("child_level_id", "")))
		if not child.is_empty():
			out.append({"child_level_id": child, "x": d.get("x", 0) as float, "y": d.get("y", 0) as float})
	return out


# The level ids from the top apartment down to the one loaded now.
func _current_nested_path() -> Array:
	var path: Array = []
	for ctx in _nested_stack:
		path.append((ctx as Dictionary)["parent_level_id"] as String)
	path.append(_current_level_id)
	return path


# Builds the whole apartment tree for NestedMap (see its header for the node
# shape). `path` is the level ids from the top apartment to a node, `hops`
# the box taken at each step, which is what _jump_to_nested_node() replays.
func _build_nested_tree() -> Dictionary:
	# Snapshot the level on screen so its thumbnail shows what's there now,
	# not what was there when it was last left.
	_level_state_cache[_current_level_id] = _snapshot_level_state()
	var path := _current_nested_path()
	var seen: Dictionary = {}   # level id -> how many nodes show it
	var root := _nested_tree_node(path[0] as String, [path[0]], [], path, seen)
	_flag_shared_nodes(root, seen)
	return root


func _nested_tree_node(level_id: String, path: Array, hops: Array, current_path: Array, seen: Dictionary) -> Dictionary:
	seen[level_id] = (seen.get(level_id, 0) as int) + 1
	var ld := _lookup_level_dict(level_id)
	var plan := _floor_plan_data(ld)
	var node := {
		"level_id": level_id,
		"name": _level_display_name(level_id),
		"path": path,
		"hops": hops,
		"is_current": path == current_path,
		"shared": false,
		# The top apartment is always reachable; an interior has to be big
		# enough to step into (the same rule _on_box_entered() enforces).
		"enterable": path.size() == 1 or _level_floor_area_m2(level_id) >= MIN_NESTED_INTERIOR_M2,
		"segments": plan["segments"],
		"bounds": plan["bounds"],
		"furniture": _furniture_preview_rects_for(level_id, ld),
		"children": [],
		"state": _level_state_label(level_id, path.size() == 1),
	}
	if path.size() < 8:   # far deeper than any real project; stops runaway data
		for c in _nested_children_of(level_id):
			var child := c as Dictionary
			var child_id := child["child_level_id"] as String
			if path.has(child_id):
				continue   # a box pointing back up its own chain: _on_box_entered() refuses it too
			(node["children"] as Array).append(
				_nested_tree_node(child_id, path + [child_id], hops + [child], current_path, seen))
	return node


func _flag_shared_nodes(node: Dictionary, seen: Dictionary) -> void:
	node["shared"] = (seen.get(node["level_id"], 0) as int) > 1
	for c in node["children"] as Array:
		_flag_shared_nodes(c as Dictionary, seen)


func _open_nested_map() -> void:
	if _map_jump_busy or _nested_transition_busy or _nested_travel_busy:
		return
	var map := NestedMapScript.open(self, _build_nested_tree())
	map.node_chosen.connect(func(path: Array, hops: Array): _jump_to_nested_node(path, hops))


# Travels to any apartment in the tree: up to the nearest apartment the
# current one and the target share, then down through each box on the way.
# It really does pass through every apartment in between, one per frame,
# because entering a box works out the daylight and noise reaching it from
# where that box sits in its parent — skipping a step would skip that.
func _jump_to_nested_node(path: Array, hops: Array) -> void:
	if _map_jump_busy or _nested_transition_busy or _nested_travel_busy or path.is_empty():
		return
	var here := _current_nested_path()
	if path == here:
		return
	_map_jump_busy = true
	var common := 0
	while common < mini(path.size(), here.size()) and path[common] == here[common]:
		common += 1
	# The camera move should say which way we are going:
	#   down (the target is somewhere inside this apartment) — push into the
	#        box that leads there, exactly like double-clicking it;
	#   up   (the target is an apartment this one sits inside) — pull back,
	#        and arrive on the box we came out of;
	#   across (up, then down another branch) — pull back, then settle in.
	var going_down := common == here.size()
	var going_up := common == path.size()
	var first_box: Furniture = _find_box_for_hop(hops[common - 1] as Dictionary) if going_down else null
	# The veil comes down during the move: apartments passed through on the
	# way are loaded behind it, so the player sees one move, not several.
	await _travel_depart(first_box, going_down)
	if common > 0 and _nested_stack.size() > common - 1:
		_exit_nested_level_to(common - 1)
		await get_tree().process_frame
	for depth in range(maxi(common, 1), path.size()):
		var box := _find_box_for_hop(hops[depth - 1] as Dictionary)
		if box == null:
			break
		var before := _current_level_id
		_on_box_entered(box)
		if _current_level_id == before:
			break   # refused (interior too small, or a cycle)
		await get_tree().process_frame
	if going_up:
		var came_from: Furniture = null
		for candidate in _collect_nested_boxes():
			if candidate.child_level_id == (here[common] as String):
				came_from = candidate
				break
		await _travel_arrive(came_from, false)
	else:
		await _travel_arrive(null, true)
	_map_jump_busy = false


# The live box in the current apartment that a tree hop went through: same
# interior, nearest to where the tree saw it (two boxes in one apartment can
# lead to the same place).
func _find_box_for_hop(hop: Dictionary) -> Furniture:
	var box: Furniture = null
	var best := INF
	for candidate in _collect_nested_boxes():
		if candidate.child_level_id != (hop["child_level_id"] as String):
			continue
		var dist := candidate.grid_pos.distance_to(Vector2(hop["x"] as float, hop["y"] as float))
		if dist < best:
			best = dist
			box = candidate
	return box


# Double-click on a box: push in on it, step inside, settle.
func _enter_box_animated(box: Furniture) -> void:
	if _nested_travel_busy or _nested_transition_busy or _map_jump_busy:
		return
	if not is_instance_valid(box) or box.child_level_id.is_empty():
		return
	# Before the camera dives in: it used to fly into a box it then couldn't enter.
	if _refuse_cramped_box(box):
		return
	_nested_travel_busy = true
	await _travel_depart(box, true)
	if is_instance_valid(box):
		_on_box_entered(box)
	await get_tree().process_frame
	await _travel_arrive(null, true)
	_nested_travel_busy = false


# Back button: pull away from this room, step out, and settle from the box
# we just came out of.
func _exit_nested_animated() -> void:
	if _nested_travel_busy or _nested_transition_busy or _map_jump_busy or _nested_stack.is_empty():
		return
	_nested_travel_busy = true
	var left_id := _current_level_id
	await _travel_depart(null, false)
	_exit_nested_level()
	await get_tree().process_frame
	var came_from: Furniture = null
	for candidate in _collect_nested_boxes():
		if candidate.child_level_id == left_id:
			came_from = candidate
			break
	await _travel_arrive(came_from, false)
	_nested_travel_busy = false


func _ensure_travel_veil() -> ColorRect:
	if not is_instance_valid(_travel_veil):
		_travel_veil = ColorRect.new()
		_travel_veil.name = "TravelVeil"
		_travel_veil.color = Color(GameTheme.C_BG.r, GameTheme.C_BG.g, GameTheme.C_BG.b, 0.0)
		_travel_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
		_travel_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var nav_layer := _ensure_nested_ui_layer()
		nav_layer.add_child(_travel_veil)
		nav_layer.move_child(_travel_veil, 0)   # under the nav buttons
	return _travel_veil


func _styled_3d_view() -> Room3DView:
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		return _mode3d_view as Room3DView
	return null


# Scales the 2D plan by `k` about a fixed screen point, relative to the
# transform (scale0, pos0) it is fitted at. k = 1 is the fitted view.
func _set_plan_zoom_about(focus: Vector2, scale0: float, pos0: Vector2, k: float) -> void:
	room.scale    = Vector2(scale0 * k, scale0 * k)
	room.position = focus - (focus - pos0) * k


func _plan_center() -> Vector2:
	return Vector2((LEFT_X + RIGHT_X) * 0.5, (TOP_Y + _floor_pane_bottom_y()) * 0.5)


func _box_plan_point(box: Furniture) -> Vector2:
	return box.get_global_transform_with_canvas() * (Vector2(box.grid_w, box.grid_h) * TILE_SIZE * 0.5)


# Saves the camera of the level being left and queues up the one for the
# level being entered, so apartments never inherit each other's view. Called
# right before every nested level swap.
func _hand_over_camera(leaving_id: String, arriving_id: String) -> void:
	if not is_instance_valid(_mode3d_view):
		_camera_before_travel = {}
		return
	var view := _mode3d_view as Room3DView
	view.cancel_camera_travel()
	_camera_by_level[leaving_id] = _camera_before_travel if not _camera_before_travel.is_empty() else view.get_camera_state()
	_camera_before_travel = {}
	view.set_next_camera_state(_camera_by_level.get(arriving_id, {}) as Dictionary)


# First half of a transition: the camera leaves. Toward `box` when stepping
# in (entering), straight back from the room otherwise. Works in whichever
# view is showing. Reduce-motion skips the whole thing.
# The moves are stopped dead when the time is up rather than left to finish
# on their own: the level is swapped right after, and a move still running
# would carry on steering the new level's camera.
func _travel_depart(box: Furniture, entering: bool) -> void:
	Audio.play("whoosh")
	var view := _styled_3d_view()
	_camera_before_travel = view.get_camera_state() if view != null else {}
	if GameState.reduce_motion:
		return
	var veil := _ensure_travel_veil()
	veil.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks mid-move
	var tw := create_tween().set_parallel(true)
	tw.tween_property(veil, "color:a", 1.0, NESTED_TRAVEL_OUT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if view != null:
		var focus := view.furniture_focus(box) if (entering and is_instance_valid(box)) else {}
		if not focus.is_empty():
			view.travel_camera(focus["center"], focus["dist"], NESTED_TRAVEL_OUT)
		else:
			view.travel_camera(view._center, view._dist * 1.9, NESTED_TRAVEL_OUT)
	else:
		var scale0 := room.scale.x
		var pos0 := room.position
		var focus_pt := _box_plan_point(box) if (entering and is_instance_valid(box)) else _plan_center()
		var k_to := 3.2 if entering else 0.5
		tw.tween_method(func(k: float) -> void: _set_plan_zoom_about(focus_pt, scale0, pos0, k),
			1.0, k_to, NESTED_TRAVEL_OUT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await get_tree().create_timer(NESTED_TRAVEL_OUT).timeout
	tw.kill()
	veil.color.a = 1.0
	if is_instance_valid(view):
		view.cancel_camera_travel()


# Second half: the camera arrives in the level that was just loaded and
# settles on that level's own view. Stepping in, the new room grows into
# place (the push inward continues); stepping out, the view starts on `box`
# — the one we came out of — and pulls back.
func _travel_arrive(box: Furniture, entering: bool) -> void:
	var veil := _ensure_travel_veil()
	if GameState.reduce_motion:
		veil.color.a = 0.0
		veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	var tw := create_tween().set_parallel(true)
	tw.tween_property(veil, "color:a", 0.0, NESTED_TRAVEL_IN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var view := _styled_3d_view()
	var plan_scale := room.scale.x
	var plan_pos := room.position
	var plan_focus := _box_plan_point(box) if (not entering and is_instance_valid(box)) else _plan_center()
	if view != null:
		var focus := view.furniture_focus(box) if is_instance_valid(box) else {}
		if not entering and not focus.is_empty():
			view.arrive_camera(focus["center"], focus["dist"], NESTED_TRAVEL_IN)
		else:
			view.arrive_camera(view._center, view._dist * (1.9 if entering else 0.6), NESTED_TRAVEL_IN)
	else:
		var k_from := 0.5 if entering else 3.2
		_set_plan_zoom_about(plan_focus, plan_scale, plan_pos, k_from)
		tw.tween_method(func(k: float) -> void: _set_plan_zoom_about(plan_focus, plan_scale, plan_pos, k),
			k_from, 1.0, NESTED_TRAVEL_IN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await get_tree().create_timer(NESTED_TRAVEL_IN).timeout
	# Land exactly on the fitted view whatever the last tween step reached.
	tw.kill()
	veil.color.a = 0.0
	if view == null:
		_set_plan_zoom_about(plan_focus, plan_scale, plan_pos, 1.0)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE


# Total walkable floor area (m²) of a level's "floor"/"loft" floors, WITHOUT
# actually loading it — same floor_tiles/grid_w/grid_h fallback convention as
# Wall.gd's count_free_tiles_for_moment() (empty floor_tiles = whole grid is
# floor). Used to reject entering a nested box whose interior is too small
# before tearing down the current level to try.
func _level_floor_area_m2(level_id: String) -> float:
	var level := _lookup_level_dict(level_id)
	if level.is_empty():
		return 0.0
	return Furniture.level_floor_tiles(level) * TILE_M2


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
	_remember_level_state()
	_current_nested_daylight_factor = 1.0
	_current_nested_noisy_from_outside = false
	_current_nested_external_override = {}
	_hand_over_camera(_current_level_id, target_id)
	_load_level(target_id)
	_restore_level_state(target_id)
	_autosave_soon()
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
			if fur.keepsake:
				item["keepsake"] = true   # per-instance, like child_level_id above
			items.append(item)
		floors_snap[fid] = items
	return {"budget": gm.budget, "floors": floors_snap, "owned": gm.starting_inventory.duplicate(true)}


# Wipes whatever the just-completed _load_level() spawned from the level's
# authored starting_furniture and replaces it with a previously captured
# _snapshot_level_state() — restoring the player's actual layout instead of
# the level's default one.
func _apply_level_state_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	gm.budget = snapshot.get("budget", gm.budget) as int
	gm.budget_changed.emit(gm.budget)
	if snapshot.has("owned"):
		gm.starting_inventory = (snapshot["owned"] as Array).duplicate(true)
		_refresh_owned_ui()
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
	_batch_refresh = true
	var floors_snap := snapshot.get("floors", {}) as Dictionary
	for fid in _floors:
		var fl := _floors[fid] as Floor
		fl.begin_batch()
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
	for fid in _floors:
		(_floors[fid] as Floor).end_batch()
	_batch_refresh = false
	_refresh_functions()
	_rent_auto_armed = _was_armed
	_update_rent_btn()
	# Every Furniture node was just replaced. The 3D view was built from the
	# ones _load_level() spawned, so without a rebuild it keeps drawing
	# meshes for furniture that no longer exists and can't pick any of the
	# real pieces — nothing could be dragged, sold, or (for a nested box)
	# stepped into after coming back to a level.
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_ensure_mode3d_view()


# How much daylight reaches the box's interior from outside, given the
# PARENT apartment's own furniture around the box's footprint — the concrete
# form of "un mueble del apartamento grande puede tapar la luz al apartamento
# pequeño de dentro". Scans a one-tile ring around the box for the tallest
# nearby piece: a "tall" neighbor blocks most of the light (this is a closed
# box after all, blocked doubly so), "medium" dims it partway, otherwise the
# box gets full daylight.
#
# A box standing on a table or shelf takes its light from where it really is:
# what it stands on doesn't shade it, and neither does anything whose top is
# below the box (a chair beside the table, a low cabinet beside the dresser).
var _shade_by := ""   # what shaded the box _compute_box_occlusion() looked at last ("" = nothing)

# Every piece with a tile in the one-tile ring around `pos` (gw x gh) on
# `fl`, other than `exclude`. With `carried` (a piece being dragged or
# bought, its corner at `carried_at`): as if it already stood there instead
# of where it is now.
func _ring_pieces(fl: Floor, pos: Vector2, gw: int, gh: int, exclude: Furniture,
		carried: Furniture = null, carried_at: Variant = null) -> Array:
	var out: Array = []
	var x0 := floori(pos.x) - 1
	var y0 := floori(pos.y) - 1
	var x1 := x0 + gw + 2
	var y1 := y0 + gh + 2
	for x in range(x0, x1):
		for y in range(y0, y1):
			if x >= x0 + 1 and x < x1 - 1 and y >= y0 + 1 and y < y1 - 1:
				continue
			for f in fl._placed_list(Vector2i(x, y)):
				if f != exclude and f != carried and not (f in out):
					out.append(f)
	if carried != null and carried_at != null and carried != exclude \
			and Rect2(Vector2(x0, y0), Vector2(x1 - x0, y1 - y0)).intersects(Rect2(carried_at as Vector2, Vector2(carried.grid_w, carried.grid_h))):
		out.append(carried)
	return out


func _compute_box_occlusion(box: Furniture, carried: Furniture = null, carried_at: Variant = null) -> float:
	_shade_by = ""
	var fl := box._wall_ref
	if not is_instance_valid(fl):
		return 1.0
	var under := _supports_under(fl, box.grid_pos, box.grid_w, box.grid_h, box)
	var base := fl.stack_lift(box)
	var worst := "low"
	for f in _ring_pieces(fl, box.grid_pos, box.grid_w, box.grid_h, box, carried, carried_at):
		var fur := f as Furniture
		if fur in under:
			continue
		var lift := fl.stack_lift(fur, carried_at if fur == carried else null)
		if base > 0.0 and lift + fur.body_h <= base:
			continue
		if fur.blocks_light():
			if worst != "tall":
				_shade_by = fur.furniture_name
			worst = "tall"
		elif fur.height_category == "medium" and worst == "low":
			worst = "medium"
			_shade_by = fur.furniture_name
	match worst:
		"tall":   return 0.15
		"medium": return 0.55
		_:        return 1.0


# True if any is_noisy piece sits in the 1-tile ring immediately around
# `pos`/`gw`x`gh` on `fl` (excluding `exclude` itself) — same ring-scan shape
# as _compute_box_occlusion() above, just checking for noise instead of
# height. Used both directions: parent furniture around a box (checked
# against the PARENT's fl before entering), and a box's own noisy interior
# affecting the PARENT's furniture around it (checked against the PARENT's
# fl using the box's own position, from the outside).
# Which of the room's 4 sides `box` currently sits closest to, by centre
# distance to each wall of the room's bounding rect — used to look up a
# per-wall external_zone restriction profile for a nested box (see
# _current_nested_external_override's comment). A real building's noisy
# street side / quiet courtyard side / smelly-alley side are usually
# specific WALLS, not a uniform ring around the whole apartment the way
# light/noise occlusion are, so this measures against one side at a time
# rather than reusing the ring-scan shape those two use.
# A box's mobility tier rises as it is furnished (Furniture.box_tier()). The
# tape and straps on it show where it stands; the moment it changes is also
# said once, whether that happens out here (a box's tier read as it is now)
# or inside it while furnishing (from what is in this apartment right now).
# Keyed by the box's apartment, which outlives the box nodes (they are made
# again every time a level loads), so nothing is said on loading.
var _box_tier_seen: Dictionary = {}   # child level id -> tier last seen

func _note_box_tiers() -> void:
	for box in _collect_nested_boxes():
		_note_box_tier(box.child_level_id, box.furniture_name, box.mobility_tier)
	if not _nested_stack.is_empty():
		var ctx := _nested_stack[-1] as Dictionary
		_note_box_tier(_current_level_id, ctx.get("box_name", tr("This box")) as String,
			Furniture.box_tier(_carried_weight(), ctx.get("box_base_tier", "green") as String), true)


func _note_box_tier(level_id: String, box_name: String, tier: String, from_inside: bool = false) -> void:
	var seen := _box_tier_seen.get(level_id, "") as String
	_box_tier_seen[level_id] = tier
	if seen == "" or seen == tier:
		return
	var order := ["green", "yellow", "red"]
	if order.find(tier) < order.find(seen):
		_toast(tr("%s is lighter again: easier to move.") % box_name)
	elif tier == "yellow":
		_toast(tr("%s is getting heavy: moving it away from where it started now costs comfort.") % box_name, from_inside)
	else:
		_toast(tr("%s is packed full: it now stays in one place for every moment of the day.") % box_name, from_inside)


# What an outside-wall profile (external_zone.by_wall[side]) does to a box
# standing nearest that wall, in words: "Sleep at least 0.8 m from the wall
# · No Work". "" when it does nothing.
func _wall_rules_text(profile: Dictionary) -> String:
	var parts: Array = []
	for fn in profile.get("forbidden_functions", []) as Array:
		parts.append(tr("No %s") % Loc.need_name(fn as String))
	var dist := profile.get("min_boundary_distance", {}) as Dictionary
	for fn in dist:
		parts.append(tr("%s at least %.1f m from the wall") % [Loc.need_name(fn as String), (dist[fn] as float) * 0.1])
	return " · ".join(parts)


# The name a wall's outside goes by: its profile's label ("Busy street"), or
# which side of the flat it is.
func _wall_side_name(side: String, profile: Dictionary) -> String:
	var label := profile.get("label", "") as String
	if label != "":
		return tr(label)
	match side:
		"north": return tr("North side")
		"east":  return tr("East side")
		"south": return tr("South side")
	return tr("West side")


# Shows every outside wall that has a profile, on the plan (a plate outside
# it) and in 3D (a sign outside it), and links each box to the wall whose
# rules it takes inside: a dashed line on the plan, following a box that is
# being carried (`carried`, its corner at `at`).
var _outside_walls: Array = []   # what _show_outside_walls() last showed, for a 3D view built later

func _show_outside_walls(carried: Furniture = null, at: Variant = null) -> void:
	var by_wall := gm.external_restrictions.get("by_wall", {}) as Dictionary
	var walls: Array = []
	var looped: Array = []   # sides that are all seam on a looped floor: no outside there
	for lfid in _floors:
		if (_floors[lfid] as Floor).loop != null:
			looped.append_array((_floors[lfid] as Floor).loop.looped_sides())
	for side in ["north", "east", "south", "west"]:
		if not by_wall.has(side) or side in looped:
			continue
		var p := by_wall[side] as Dictionary
		var rules := _wall_rules_text(p)
		walls.append({"side": side, "name": _wall_side_name(side, p),
			"rules": tr("boxes here: %s") % rules if rules != "" else tr("nothing extra for boxes here")})
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var links: Array = []
		if not walls.is_empty():
			for box in _collect_nested_boxes():
				if box._wall_ref != fl:
					continue
				var held := box == carried and at != null
				var side := _closest_wall_side(fl, box, at if held else null)
				if not by_wall.has(side):
					continue
				var corner: Vector2 = at as Vector2 if held else box.grid_pos
				links.append({"from": corner + Vector2(box.grid_w, box.grid_h) * 0.5, "side": side, "held": held})
		fl.set_outside_walls(walls, links)
	_outside_walls = walls
	if is_instance_valid(_mode3d_view):
		_mode3d_view.set_outside_walls(walls)


func _closest_wall_side(fl: Floor, box: Furniture, at: Variant = null) -> String:
	var b := fl.get_room_bounds()
	var corner: Vector2 = box.grid_pos if at == null else at as Vector2
	var cx := corner.x + box.grid_w * 0.5
	var cy := corner.y + box.grid_h * 0.5
	var d_west  := cx - b.position.x
	var d_east  := (b.position.x + b.size.x) - cx
	var d_north := cy - b.position.y
	var d_south := (b.position.y + b.size.y) - cy
	# A side of a looped flat that is all seam has no outside behind it: the
	# box takes the rules of the nearest wall that does. None at all: "".
	if fl.loop != null:
		var looped := fl.loop.looped_sides()
		if looped.size() >= 4:
			return ""
		if "west" in looped: d_west = INF
		if "east" in looped: d_east = INF
		if "north" in looped: d_north = INF
		if "south" in looped: d_south = INF
	var m := minf(minf(d_west, d_east), minf(d_north, d_south))
	if m == d_west:
		return "west"
	if m == d_east:
		return "east"
	if m == d_north:
		return "north"
	return "south"


# What a footprint at `pos` would stand on: the surface under it, the one
# under that, and so on down to the floor (empty on the floor).
func _supports_under(fl: Floor, pos: Vector2, gw: int, gh: int, exclude: Furniture) -> Array:
	var out: Array = []
	var cur := fl._surface_support_at(fl._rect_tiles(pos, gw, gh), exclude)
	while cur != null and cur not in out:
		out.append(cur)
		cur = fl.support_under(cur)
	return out


# A box standing on something noisy hears it as well as one beside it, even
# when that table is no bigger than the box and so not in the ring.
var _noisy_by := ""   # the noisy piece _has_noisy_neighbor() found last
var _noisy_piece: Furniture = null

func _has_noisy_neighbor(fl: Floor, pos: Vector2, gw: int, gh: int, exclude: Furniture,
		carried: Furniture = null, carried_at: Variant = null) -> bool:
	_noisy_by = ""
	_noisy_piece = null
	if not is_instance_valid(fl):
		return false
	for sup in _supports_under(fl, pos, gw, gh, exclude):
		if (sup as Furniture).is_noisy and sup != carried:
			_noisy_by = (sup as Furniture).furniture_name
			_noisy_piece = sup
			return true
	for f in _ring_pieces(fl, pos, gw, gh, exclude, carried, carried_at):
		var fur := f as Furniture
		if fur.is_noisy:
			_noisy_by = fur.furniture_name
			_noisy_piece = fur
			return true
	return false


# While a piece is carried over the plan or in 3D (Floor.carry_preview, with
# its corner at `at`), every box shows the shade and noise it would get if
# the piece were put down there: the hatch and dimmed windows, and the sound
# coming off the piece. `carried` null puts everything back as it really is.
var _carry_previewing := false
var _carry_preview_args: Array = []   # [carried, at] while previewing

func _preview_carry(carried: Furniture, at: Variant) -> void:
	if carried == null or at == null or not is_instance_valid(carried):
		if _carry_previewing:
			_carry_previewing = false
			_carry_preview_args = []
			_recompute_box_effects()
		return
	_carry_previewing = true
	_carry_preview_args = [carried, at]
	_apply_carry_preview(carried, at)


# The preview itself; also put back on top by _recompute_box_effects(), which
# moving the piece over the plan sets off and which works out the real state.
func _apply_carry_preview(carried: Furniture, at: Variant) -> void:
	if carried.is_nested_box:
		_show_outside_walls(carried, at)
	var boxes := _collect_nested_boxes()
	if boxes.is_empty():
		return
	var making: Dictionary = {}   # piece -> true while it would keep a box's bed awake
	for box in boxes:
		if box == carried or not is_instance_valid(box._wall_ref) or box._wall_ref != carried._wall_ref:
			continue
		box._shade = _compute_box_occlusion(box, carried, at)
		if _child_has_bed(box.child_level_id) and _has_noisy_neighbor(box._wall_ref, box.grid_pos, box.grid_w, box.grid_h, box, carried, at) \
				and is_instance_valid(_noisy_piece):
			making[_noisy_piece] = true
		box.queue_redraw()
	# Only the noise between pieces and boxes is previewed; a pet's or a noisy
	# box's own reach stays as it is.
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			var fur := f as Furniture
			if fur.is_noisy and not fur.is_nested_box and fur.noise_radius <= 0:
				var now := making.has(fur)
				if now != fur._noise_making:
					fur._noise_making = now
					fur.queue_redraw()
	if carried.is_noisy and carried._noise_making != making.has(carried):
		carried._noise_making = making.has(carried)
		carried.queue_redraw()
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_mode3d_view._sync_status_marks()


# Everything currently in a child level's floors — the live per-session
# cache if we've visited it this session, else its authored
# starting_furniture straight from disk. Shared by the interior-weight and
# interior-noise computations below, since both just need "what's in there
# right now" without caring which source it came from.
func _child_furniture_items(child_level_id: String) -> Array:
	if _level_state_cache.has(child_level_id):
		var out: Array = []
		var snap := _level_state_cache[child_level_id] as Dictionary
		for fid in snap.get("floors", {}) as Dictionary:
			out.append_array((snap["floors"] as Dictionary)[fid] as Array)
		return out
	var child_dict := _lookup_level_dict(child_level_id)
	var out2: Array = []
	out2.append_array(child_dict.get("starting_furniture", []) as Array)
	for fd in (child_dict.get("apartment", {}) as Dictionary).get("floors", []) as Array:
		out2.append_array((fd as Dictionary).get("starting_furniture", []) as Array)
	return out2


func _compute_child_interior_weight(child_level_id: String) -> float:
	var total := 0.0
	for item in _child_furniture_items(child_level_id):
		var fdata := gm.get_furniture_by_id((item as Dictionary).get("id", "") as String)
		if fdata.is_empty():
			continue
		total += Furniture.catalog_weight(fdata)
	return total


func _child_has_bed(child_level_id: String) -> bool:
	for item in _child_furniture_items(child_level_id):
		if gm.get_furniture_by_id((item as Dictionary).get("id", "") as String).get("needs_quiet", false) as bool:
			return true
	return false


func _compute_child_is_noisy(child_level_id: String) -> bool:
	for item in _child_furniture_items(child_level_id):
		var fdata := gm.get_furniture_by_id((item as Dictionary).get("id", "") as String)
		if fdata.get("is_noisy", false) as bool:
			return true
	return false


# Keeps every is_nested_box on the CURRENT floor's weight/tier and noise
# effects current — called from the top of _refresh_functions(), so it runs
# on every furniture change (moving the box itself, or moving furniture near
# it) as well as on level load/exit, without needing its own separate set of
# call sites. Resets mutes first each pass (current-state based, same
# philosophy as comfort: a box that's no longer noisy shouldn't leave stale
# mutes behind on furniture that's since moved away or was never really its
# fault to begin with).
func _recompute_box_effects() -> void:
	_apply_carry_limit()
	var was_muted: Dictionary = {}   # piece -> whether noise kept it from working before this pass
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			var fur := f as Furniture
			was_muted[fur] = fur._noise_muted
			fur._noise_muted = false
			fur._noise_by = ""
			fur._noise_making = false
	_recompute_pet_effects()
	# Direction 1 (parent noise -> child): if we're currently INSIDE a box
	# that had a noisy neighbor outside it when we entered, every needs_quiet
	# piece in here is muted — set once at entry (_on_box_entered), applied
	# fresh on every recompute same as everything else in this function.
	if not _nested_stack.is_empty() and _current_nested_noisy_from_outside:
		var source := (_nested_stack[-1] as Dictionary).get("noisy_by", "") as String
		for fid in _floors:
			for f in (_floors[fid] as Floor).get_all_furniture():
				if (f as Furniture).needs_quiet:
					(f as Furniture)._noise_muted = true
					(f as Furniture)._noise_by = source
	# Direction 2 (child noise -> parent): a box whose OWN interior is noisy
	# mutes needs_quiet furniture near it in THIS (parent) room.
	for box in _collect_nested_boxes():
		if box.child_level_id.is_empty():
			continue
		box.apply_interior_weight(_compute_child_interior_weight(box.child_level_id), _box_shrink(box))
		box.is_noisy = _compute_child_is_noisy(box.child_level_id)
		if box.is_noisy and is_instance_valid(box._wall_ref):
			_mute_quiet_neighbors(box._wall_ref, box)
		# How much daylight reaches it, for the plan's shade and the 3D view's
		# dimmed windows.
		box._shade = _compute_box_occlusion(box)
		# Noise right outside a box with a bed in it keeps that bed from
		# working (see _on_box_entered): the piece making it shows it here too.
		if is_instance_valid(box._wall_ref) and _has_noisy_neighbor(box._wall_ref, box.grid_pos, box.grid_w, box.grid_h, box) 				and _child_has_bed(box.child_level_id) and is_instance_valid(_noisy_piece):
			_noisy_piece._noise_making = true
	_note_box_tiers()
	_show_outside_walls()
	if _carry_previewing and _carry_preview_args.size() == 2 and is_instance_valid(_carry_preview_args[0]):
		_apply_carry_preview(_carry_preview_args[0], _carry_preview_args[1])
	# A bed that just stopped working because of noise says why, once (a piece
	# that only now appeared, on loading or stepping into a box, doesn't: the
	# marks show it, and stepping in already said so).
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			var fur := f as Furniture
			if fur._noise_muted and was_muted.has(fur) and not was_muted[fur] and fur._noise_by != "":
				_toast(tr("%s can't be slept in: the %s is too noisy.") % [fur.furniture_name, fur._noise_by], true)
			fur.queue_redraw()


# Inside a box that stands on a table, nothing new can go in that would make
# the box too heavy for that table (Floor.carry_limit); anywhere else, no limit.
func _apply_carry_limit() -> void:
	var ctx: Dictionary = _nested_stack[-1] if not _nested_stack.is_empty() else {}
	Floor.carry_limit = ctx.get("carry_limit", -1.0) as float
	Floor.carry_support_name = ctx.get("carry_support_name", "") as String
	Floor.carried_weight = _carried_weight
	Floor.carry_preview = _preview_carry


# The limit is static: it must not outlive the game it belongs to (the level
# editor's floors and the tests share it).
func _exit_tree() -> void:
	Floor.carry_limit = -1.0
	Floor.carried_weight = Callable()
	Floor.carry_preview = Callable()


# What everything in the current apartment weighs, the way the box outside
# counts it (catalogue weights, see _compute_child_interior_weight()).
func _carried_weight() -> float:
	var total := 0.0
	for fid in _floors:
		for f in (_floors[fid] as Floor).get_all_furniture():
			total += (f as Furniture)._base_weight
	return total


# A box weighs what is in it from the moment it exists, not only from the
# next refresh: a box being bought onto a table has to be weighed full.
func _weigh_box(f: Furniture) -> void:
	if f.is_nested_box and not f.child_level_id.is_empty():
		f.apply_interior_weight(_compute_child_interior_weight(f.child_level_id), _box_shrink(f))


# How much the fax shrank the apartment in `box`: the box's footprint over
# that apartment's floor, both in tiles. What is inside weighs that much less
# out here (see Furniture.apply_interior_weight()).
func _box_shrink(box: Furniture) -> float:
	return Furniture.box_shrink(box.grid_w, box.grid_h, _lookup_level_dict(box.child_level_id))


func _mute_quiet_neighbors(fl: Floor, box: Furniture) -> void:
	var x0 := floori(box.grid_pos.x) - 1
	var y0 := floori(box.grid_pos.y) - 1
	var x1 := x0 + box.grid_w + 2
	var y1 := y0 + box.grid_h + 2
	for x in range(x0, x1):
		for y in range(y0, y1):
			var inside := x >= x0 + 1 and x < x1 - 1 and y >= y0 + 1 and y < y1 - 1
			if inside:
				continue
			for f in fl._placed_list(Vector2i(x, y)):
				var fur := f as Furniture
				if fur != box and fur.needs_quiet:
					fur._noise_muted = true
					fur._noise_by = box.furniture_name
					box._noise_making = true


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
		"label": tr("%s (Loft)") % base_floor.floor_label,
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
	_disable_plan_wall_select(loft_floor)
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
	_start_tenants()


# The tenants move in on the floor on screen; nobody lives there during the
# post-win showcase, which has its own figure.
func _start_tenants() -> void:
	if tenant_layer == null:
		return
	tenant_layer.start(null if _post_win_view else _application, _floors.get(_current_floor_id) as Floor,
		_mode3d_view if is_instance_valid(_mode3d_view) else null)


# ── Touch (TouchControls calls these) ─────────────────────────────────────────

# The line of help at the top of each view, in mouse-and-keyboard or touch terms.
func _plan_hint() -> String:
	if TouchControls.active:
		return tr("Drag furniture to move it · hold a piece to rotate, fold or sell it · pinch to zoom")
	return tr("Drag furniture to move it · R rotates a piece · Switch to 3D to hang things on walls")


func _view3d_hint() -> String:
	if TouchControls.active:
		return tr("Drag items onto the floor or a wall · hold a piece for its options · pinch to zoom, twist to turn")
	return tr("Drag items onto the floor or a wall · R rotates a piece · Q/E turn the view · WASD move it")


# Two fingers: pinch, drag and twist. The plan ignores the twist.
func touch_gesture(zoom: float, pan: Vector2, twist: float, center: Vector2) -> void:
	if _blocking_modal_open():
		return
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_mode3d_view.touch_camera(zoom, pan, twist)
		return
	_zoom_floor(_manual_zoom * (zoom - 1.0), center)
	_manual_pan += pan
	_apply_room_transform()


# A second finger landed: whatever the first one had started is called off.
func touch_cancel_pointer() -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if fl:
		for c in fl.get_children():
			if c is Furniture:
				(c as Furniture).cancel_drag()
	if _xfer_dragging and not _xfer_purchase:
		_end_transfer_cues()
	if is_instance_valid(_mode3d_view):
		_mode3d_view.touch_cancel_drag()


# The piece being bought on the plan, if any.
func _placing_piece() -> Furniture:
	var fl := _floors.get(_current_floor_id) as Floor
	if fl:
		for c in fl.get_children():
			if c is Furniture and (c as Furniture)._placement_mode:
				return c
	return null


func touch_is_placing() -> bool:
	if is_instance_valid(_mode3d_view) and _view_mode == ViewMode.VIEW3D and _mode3d_view.is_buying():
		return true
	return _placing_piece() != null


func touch_rotate_placing() -> void:
	if is_instance_valid(_mode3d_view) and _view_mode == ViewMode.VIEW3D and _mode3d_view.is_buying():
		_mode3d_view.rotate_buying()
	elif _placing_piece():
		_placing_piece()._rotate()


func touch_confirm_placing() -> void:
	if is_instance_valid(_mode3d_view) and _view_mode == ViewMode.VIEW3D and _mode3d_view.is_buying():
		_mode3d_view.confirm_buy_touch()
	elif _placing_piece():
		_placing_piece().confirm_placement()


func touch_cancel_placing() -> void:
	if is_instance_valid(_mode3d_view) and _view_mode == ViewMode.VIEW3D and _mode3d_view.is_buying():
		_mode3d_view.cancel_buying()
	elif _placing_piece():
		_placing_piece().cancel_placement()


# Rotate a placed piece where it stands (R over it, with a mouse); turned
# back if the new footprint doesn't fit there.
func touch_rotate_piece(f: Furniture) -> void:
	if not is_instance_valid(f) or Furniture.read_only:
		return
	var fl := f._wall_ref
	if fl == null or not fl.is_registered(f):
		return
	f._rotate()
	if not fl.can_place(f, f.grid_pos):
		var why := fl.get_block_reason()
		for i in 3:
			f._rotate(true)
		Audio.play("error")
		_set_mode_hint(why)
		return
	f.placed.emit(f)
	if _view_mode == ViewMode.VIEW3D:
		_ensure_mode3d_view()


func touch_fold_piece(f: Furniture) -> void:
	if not is_instance_valid(f) or Furniture.read_only:
		return
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_mode3d_view.touch_fold(f)
	else:
		f.toggle_fold()


func touch_sell_piece(f: Furniture) -> void:
	if not is_instance_valid(f) or Furniture.read_only:
		return
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_mode3d_view.touch_sell(f)
	else:
		_on_sell_pressed(f, f._wall_ref)


func touch_sell_wall_item(hit: Dictionary) -> void:
	if is_instance_valid(_mode3d_view) and not Furniture.read_only:
		_mode3d_view.touch_sell_wall_item(hit)


# The action bar sits just above the needs bar.
func touch_bar_bottom() -> float:
	return tenant_card.get_global_rect().position.y if is_instance_valid(tenant_card) else get_viewport().get_visible_rect().size.y


# Whether a piece is in the player's hand: being dragged or bought, in either
# view. The tenants keep out of the way meanwhile.
func is_placing_furniture() -> bool:
	if is_instance_valid(_pending_floor_ghost) or _xfer_dragging:
		return true
	if is_instance_valid(_mode3d_view) and (_mode3d_view._dragging_furniture or _mode3d_view._dragging_wall_item \
			or _mode3d_view._buying_furniture != null):
		return true
	var fl := _floors.get(_current_floor_id) as Floor
	if fl:
		for c in fl.get_children():
			if c is Furniture and ((c as Furniture)._dragging or (c as Furniture)._placement_mode):
				return true
	return false


# Recomputes the "fit to view" baseline (scale/position) for the given floor.
# `reset_view`: true on an actual floor switch (snaps back to fit, clearing
# any manual zoom/pan); false when only the available width changed (e.g.
# dragging the floor/wall split), which re-fits without losing the player's
# current zoom/pan.
func _fit_floor(apt_floor: Floor, reset_view: bool = false) -> void:
	const H_PAD  := 32.0
	const V_PAD  := 24.0
	const PAD_T  := 3     # tile padding around apartment content

	# The top of the pane belongs to the title and hint line, and to
	# anything the plan draws just above its own top wall (the slope banner
	# on sloped-ceiling levels). Fitting the plan from the very top put those
	# on top of each other.
	const HEADER_H := 40.0
	var avail_w := (RIGHT_X - LEFT_X) - H_PAD * 2
	var avail_h := (_floor_pane_bottom_y() - TOP_Y - HEADER_H) - V_PAD * 2

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
		TOP_Y + HEADER_H + V_PAD + (avail_h - fh * s) * 0.5 - off_y * s
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
	var right_edge := RIGHT_X
	if not minimap.has_meta("docked"):
		# One piece with the bar: the same white card, edged in navy where it
		# rises out of it.
		minimap.set_meta("docked", true)
		var tab := StyleBoxFlat.new()
		tab.bg_color = GameTheme.CARD
		tab.border_color = GameTheme.NAVY
		tab.set_border_width(SIDE_TOP, 2)
		tab.set_border_width(SIDE_LEFT, 2)
		tab.corner_radius_top_left = 12
		tab.set_content_margin_all(8)
		tab.anti_aliasing = true
		minimap.add_theme_stylebox_override("panel", tab)
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
	var gap       := 0.0
	minimap.offset_bottom = _hud_stack_top() - gap
	minimap.offset_top    = minimap.offset_bottom - content_h
	ui_layer.move_child(minimap, ui_layer.get_child_count() - 1)
	_position_view_mode_box()


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
	tenant_card.offset_right = RIGHT_X
	var reserve := 10.0 + FURNITURE_BTN_W + 12.0 + 14.0   # edge, Furniture button, gaps
	if is_instance_valid(budget_label):
		reserve += budget_label.get_combined_minimum_size().x
	if is_instance_valid(_comfort_meter) and _comfort_meter.visible:
		reserve += COMFORT_METER_SIZE.x + 14.0
	tenant_card.set_right_reserve(reserve)
	var content_h := maxf(tenant_card.get_combined_minimum_size().y, 38.0)
	# Flush with the bottom edge while the catalogue is shut. When it opens,
	# the bar rides on top of it: the bar is the catalogue's own header.
	var strip_h := 0.0
	if is_instance_valid(inventory) and inventory.visible:
		strip_h = maxf(CATALOG_STRIP_H, inventory.get_combined_minimum_size().y)
	tenant_card.offset_bottom = BOT_Y - strip_h
	tenant_card.offset_top    = tenant_card.offset_bottom - content_h
	_position_furniture_menu_btn()


# The Floor Plan/3D segmented toggle floats directly above whatever's next in
# the bottom-right stack — the Minimap floor tabs when there's more than one
# floor, or the TenantCard bar itself (touching it, no dead gap) when Minimap
# has hidden itself for a single-floor level.
func _position_view_mode_box() -> void:
	if not is_instance_valid(_view_mode_box):
		return
	# Top right, at the left end of the redo / undo / menu row: the things
	# that change how you look at the apartment sit together (the 3D view's
	# own Walls button lands directly underneath). It used to float in the
	# bottom-right corner above the floor tabs, attached to nothing.
	var right_edge := RIGHT_X - 8.0
	for btn in [_settings_btn, _undo_btn, _redo_btn]:
		if is_instance_valid(btn) and (btn as Button).visible:
			right_edge = minf(right_edge, (btn as Button).offset_left - 10.0)
	# Same approach as _position_minimap(): fix the left edge, let
	# reset_size() measure the real width, then re-pin to the right edge.
	_view_mode_box.offset_left  = right_edge - 180.0
	_view_mode_box.offset_right = right_edge
	_view_mode_box.reset_size()
	var content := _view_mode_box.size
	_view_mode_box.offset_right  = right_edge
	_view_mode_box.offset_left   = right_edge - maxf(content.x, 60.0)
	_view_mode_box.offset_top    = TOP_Y
	_view_mode_box.offset_bottom = TOP_Y + maxf(content.y, GameTheme.TOUCH_SMALL)
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
	_position_view_mode_box()   # it sits against this row


# ── View mode switcher ──────────────────────────────────────────────────────
func _set_view_mode(mode: int) -> void:
	# Switching is still allowed during post-win "View Apartment" — the player
	# should be able to look at the Floor Plan/Wall view same as 3D, just not
	# edit anything there. Furniture.read_only (set
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
			_set_mode_hint(_plan_hint())
		ViewMode.VIEW3D:
			# Wall items are placed/moved directly in the 3D view (drag onto
			# a wall).
			room.visible    = false
			divider.visible = false
			_ensure_mode3d_view(true)
			_set_mode_hint(_view3d_hint())

	var fl := _floors.get(_current_floor_id) as Floor
	if fl and mode != ViewMode.VIEW3D:
		_fit_floor(fl, false)
	_position_undo_btn()
	_position_minimap()


# Persistent 3D view used by VIEW3D mode — distinct from the quick full-screen
# "reveal" opened by the 3D-view TopBar button, which stays a one-off overlay.
# This one fits the same TOP_Y..BOT_Y band the 2D floor plan normally uses, so
# budget/inventory/tenant-needs stay visible and usable while working in 3D.
# `if_changed`: coming back from the Floor Plan to the view kept from before,
# skip rebuilding the room (most of the cost of the switch) when nothing it
# is built from changed meanwhile (_mode3d_signature). Every other caller
# rebuilds.
var _mode3d_built_sig: Array = []

func _ensure_mode3d_view(if_changed := false) -> void:
	var fl := _floors.get(_current_floor_id) as Floor
	if not fl:
		return
	var reused := is_instance_valid(_mode3d_view)
	if is_instance_valid(_mode3d_view) and not _mode3d_view.visible:
		_mode3d_view.set_active(true)
	if not is_instance_valid(_mode3d_view):
		_mode3d_view = Room3DViewScene.instantiate()
		ui_layer.add_child(_mode3d_view)
		_mode3d_view.anchor_left   = 0.0
		_mode3d_view.anchor_top    = 0.0
		_mode3d_view.anchor_right  = 0.0
		_mode3d_view.anchor_bottom = 0.0
		if _mode3d_view.has_node("CloseBtn"):
			(_mode3d_view.get_node("CloseBtn") as Control).visible = false
		_mode3d_view.piece_long_pressed.connect(func(f: Furniture): touch_controls.show_piece(f))
		_mode3d_view.wall_item_long_pressed.connect(func(hit: Dictionary): touch_controls.show_wall_item(hit))
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
		# Deferred: entering rebuilds the level, and this signal fires from
		# inside the view's own input handler.
		_mode3d_view.box_enter_requested.connect(func(box: Furniture):
			_enter_box_animated.call_deferred(box))
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
		_mode3d_view.budget_getter = func() -> int: return gm.budget
		_mode3d_view.wall_sell_requested.connect(_on_wall_sell_pressed.bind(fl))
		_mode3d_sell_floor = fl
	_mode3d_view.offset_left   = LEFT_X
	_mode3d_view.offset_top    = TOP_Y
	_mode3d_view.offset_right  = RIGHT_X
	_mode3d_view.offset_bottom = _floor_pane_bottom_y()
	var sig := _mode3d_signature(fl)
	if not (if_changed and reused and sig == _mode3d_built_sig):
		_build_mode3d_view(fl)
		_mode3d_built_sig = sig
	if tenant_layer:
		tenant_layer.attach_3d(_mode3d_view)
	_after_mode3d_view_shown()


# What the 3D room is built from, to tell whether a kept view is still right.
func _mode3d_signature(fl: Floor) -> Array:
	var paint := {}
	var painted: Dictionary = _paint_pieces.get(fl.floor_id, {})
	for type_id in painted:
		if is_instance_valid(painted[type_id]):
			paint[type_id] = (painted[type_id].tiles as Array).hash()
	return [fl.get_instance_id(), gm.current_level.get("id", ""), _snapshot_all_furniture(), fl.wall_items.hash(),
		fl.segments.hash(), fl.floor_mask.hash(), paint, _active_moment_id, _post_win_view,
		_current_nested_daylight_factor, _nested_stack.size(), _floor_below_id.get(fl.floor_id, "")]


func _build_mode3d_view(fl: Floor) -> void:
	var below_floor: Floor = null
	if fl.floor_id in _floor_below_id:
		below_floor = _floors.get(_floor_below_id[fl.floor_id] as String) as Floor
	# Set on every (re)build, not only at creation: the view can be new (it
	# would come up editable) or kept from before, and during post-win "View
	# Apartment" tabbing away and back must not reopen editing/selling.
	_mode3d_view.read_only = _post_win_view
	_mode3d_view.set_level_style(gm.current_level, gm.levels_data)
	_mode3d_view.set_parent_scenery(_parent_scenery_data())
	_mode3d_view.set_daylight(_current_nested_daylight_factor if not _nested_stack.is_empty() else 1.0)
	_mode3d_view._outside_walls = _outside_walls   # signs built with the room
	_mode3d_view._home_marks = _home_marks
	_mode3d_view.household_of = _household_of
	# Hand the rule overlays over before the build, so a view created (or
	# rebuilt) after the last refresh still shows them.
	_mode3d_view._rule_sight = gm.sightline_status
	_mode3d_view._rule_zones = fl.zones
	_mode3d_view._rule_zone_status = fl.zone_status
	_mode3d_view.build_from_floor(fl, gm.furniture_data["furniture"], below_floor)


func _after_mode3d_view_shown() -> void:
	# _teardown_mode3d_view() stops the tenant showcase when the player steps
	# out to the Floor Plan, so during "Watch Again" (_post_win_view) tabbing
	# over and back would lose it with no way back short of re-opening Watch
	# Again from the results screen. Restart it here too, the same way
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


# Back to the Floor Plan: the 3D view is switched off and kept, not freed
# (Room3DView.set_active), and _ensure_mode3d_view() switches it back on,
# rebuilding it only if the flat changed meanwhile.
func _teardown_mode3d_view() -> void:
	if tenant_layer:
		tenant_layer.attach_3d(null)
	if is_instance_valid(_mode3d_view):
		_mode3d_view.stop_tenant_showcase()
		_mode3d_view.set_active(false)


# ── Sims-style furniture menu: wheel (categories) → Inventory (catalog) ────
# Top-left corner, symmetric with Settings/Undo/Redo in the top-right —
# Test Layout stacks below it (see _position_top_left_icons) instead of
# sharing the slot, freeing the top-center band for the wall-edge hint
# without the two competing for the same visual space. Also openable via the
# F key (see _input) — same "click it or press a key" access The Sims itself
# offers for its own build/buy mode; pressing F opens the wheel at the cursor
# instead of this button's fixed position (see _open_furniture_menu).
const FURNITURE_BTN_W := 190.0

func _position_furniture_menu_btn() -> void:
	if not is_instance_valid(_furniture_menu_btn) or not is_instance_valid(tenant_card):
		return
	var owned := _owned_count() if gm != null else 0
	var w := FURNITURE_BTN_W
	var h := float(GameTheme.TOUCH_SMALL)
	_furniture_menu_btn.offset_right  = RIGHT_X - 12.0
	_furniture_menu_btn.offset_left   = _furniture_menu_btn.offset_right - w
	_furniture_menu_btn.offset_top    = _bar_row_top(h)
	_furniture_menu_btn.offset_bottom = _furniture_menu_btn.offset_top + h
	_furniture_menu_btn.text = "\uefaf  %s%s  %s" % [tr("Furniture"), ("  \ueb68%d" % owned) if owned > 0 else "", "\uea5f" if _is_furniture_menu_open() else "\uea62"]
	ui_layer.move_child(_furniture_menu_btn, ui_layer.get_child_count() - 1)
	_position_budget_label()


# Opens the furniture catalogue (the "Furniture" button, or F): a strip
# docked above the needs bar. It does not cover the apartment and it stays
# open while pieces are bought and placed. `_at_cursor` is left over from the
# radial wheel this replaced and is ignored.
func _open_furniture_menu(_at_cursor: bool = false) -> void:
	if _post_win_view:
		return
	if not inventory.close_requested.is_connected(_close_furniture_menu):
		inventory.close_requested.connect(_close_furniture_menu)
	if not inventory.visible:
		Audio.play("click")
	inventory.open_catalog()
	_catalog_wanted = true
	_relayout_for_catalog()


# A need chip in the bar was clicked: open the strip on what provides it.
func _on_need_clicked(need: String) -> void:
	if _post_win_view:
		return
	if not inventory.close_requested.is_connected(_close_furniture_menu):
		inventory.close_requested.connect(_close_furniture_menu)
	inventory.show_need(need)
	_catalog_wanted = true
	_relayout_for_catalog()


# A counted need was clicked ("3 freezers"): open the strip on the pieces
# that count for it.
func _on_items_clicked(number: int) -> void:
	if _post_win_view or number < 1 or number > gm.required_items.size():
		return
	var req := gm.required_items[number - 1] as Dictionary
	if not inventory.close_requested.is_connected(_close_furniture_menu):
		inventory.close_requested.connect(_close_furniture_menu)
	inventory.show_items(req.get("of", []) as Array, tr(req.get("label", "") as String))
	_catalog_wanted = true
	_relayout_for_catalog()


# The strip takes the bottom of the play area while it is open: the plan and
# the 3D view give that height up, and the floating HUD pieces that sit on
# the needs bar move up to sit on the strip instead.
const CATALOG_STRIP_H := 180.0

func _relayout_for_catalog() -> void:
	_position_minimap()            # places the needs bar (above the strip when open) and the view toggle
	_position_furniture_catalog_modal()
	_position_budget_label()
	ui_layer.move_child(inventory, ui_layer.get_child_count() - 1)
	_position_furniture_menu_btn()
	if is_instance_valid(_mode3d_view):
		_mode3d_view.offset_bottom = _floor_pane_bottom_y()
	if _view_mode == ViewMode.TOPDOWN:
		var fl := _floors.get(_current_floor_id) as Floor
		if fl:
			_fit_floor(fl, true)


var _bar_relayout_busy := false

func _relayout_bottom_bar() -> void:
	if _bar_relayout_busy or not is_instance_valid(tenant_card) or _floors.is_empty():
		return
	_bar_relayout_busy = true
	_position_minimap()
	_position_watch_done_btn()
	if _is_furniture_menu_open():
		_position_furniture_catalog_modal()
		if is_instance_valid(_mode3d_view):
			_mode3d_view.offset_bottom = _floor_pane_bottom_y()
	_position_budget_label()
	_position_comfort_meter()
	_bar_relayout_busy = false


# Top edge of whatever sits along the bottom of the screen right now.
func _hud_stack_top() -> float:
	return tenant_card.offset_top


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


func _position_furniture_catalog_modal() -> void:
	inventory.offset_left   = LEFT_X
	inventory.offset_right  = RIGHT_X
	inventory.offset_top    = tenant_card.offset_bottom
	inventory.offset_bottom = BOT_Y


# True while either the radial category wheel or the filtered item grid
# (Inventory) is showing — the two screens the "F" shortcut/Furniture button
# cycle through. Used so pressing F again closes whichever of those is open
# instead of only ever opening.
func _is_furniture_menu_open() -> bool:
	return is_instance_valid(inventory) and inventory.visible


var _catalog_wanted := false   # the player has the catalogue open (survives a level load)

func _close_furniture_menu() -> void:
	_catalog_wanted = false
	var was_open := is_instance_valid(inventory) and inventory.visible
	if is_instance_valid(_furniture_menu_backdrop):
		_furniture_menu_backdrop.visible = false
	inventory.visible = false
	if was_open:
		Audio.play("click")
		_relayout_for_catalog()


func _reraise_furniture_menu_nodes() -> void:
	if is_instance_valid(_furniture_menu_backdrop):
		ui_layer.move_child(_furniture_menu_backdrop, ui_layer.get_child_count() - 1)
	ui_layer.move_child(inventory, ui_layer.get_child_count() - 1)


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
		_breadcrumb_lbl.add_theme_font_override("font", GameTheme.font("display"))
		_breadcrumb_lbl.add_theme_font_size_override("font_size", GameTheme.FS_TITLE)
		_breadcrumb_lbl.add_theme_color_override("font_color", GameTheme.CHALK)
		_breadcrumb_lbl.add_theme_color_override("font_shadow_color", GameTheme.NAVY)
		_breadcrumb_lbl.add_theme_constant_override("shadow_offset_x", 3)
		_breadcrumb_lbl.add_theme_constant_override("shadow_offset_y", 3)
		_breadcrumb_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_breadcrumb_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(_breadcrumb_lbl)
	var parts: Array[String] = []
	for ctx in _nested_stack:
		parts.append(_level_display_name((ctx as Dictionary)["parent_level_id"] as String))
	parts.append(_level_display_name(_current_level_id))
	_breadcrumb_lbl.text = "  \uea61  ".join(parts).to_upper()
	var span := _top_free_span()
	_breadcrumb_lbl.offset_left   = span.x
	_breadcrumb_lbl.offset_right  = span.y
	_breadcrumb_lbl.offset_top    = TOP_Y
	_breadcrumb_lbl.offset_bottom = TOP_Y + 40.0
	_breadcrumb_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_breadcrumb_lbl.visible = true
	ui_layer.move_child(_breadcrumb_lbl, ui_layer.get_child_count() - 1)
	_update_nested_nav()


# Nested navigation, top left under the Furniture button:
#   Map   opens NestedMap — shown whenever this project has any box in it.
#   Back  steps up one level — shown only while inside a box.
# Double-clicking a box is the way in (Furniture.gd / Room3DView.gd); these
# cover going up, and reaching boxes that are far away or awkward to click.
func _update_nested_nav() -> void:
	var nav_layer := _ensure_nested_ui_layer()
	if not is_instance_valid(_map_btn):
		_map_btn = _make_nav_button("\ueae7  " + tr("Map"))
		_map_btn.name = "NestedMapBtn"
		_map_btn.tooltip_text = tr("See every apartment in this project and jump to any of them")
		_map_btn.pressed.connect(_open_nested_map)
		nav_layer.add_child(_map_btn)
	if not is_instance_valid(_back_btn):
		_back_btn = _make_nav_button(tr("Back"))
		_back_btn.name = "BackToParentBtn"
		_back_btn.tooltip_text = tr("Step back out to the apartment this box sits in")
		_back_btn.pressed.connect(_exit_nested_animated)
		nav_layer.add_child(_back_btn)

	_map_btn.visible = not _nested_stack.is_empty() or not _collect_nested_boxes().is_empty()
	_back_btn.visible = not _nested_stack.is_empty()
	var x := LEFT_X + 8.0
	var y := TOP_Y
	if is_instance_valid(_test_btn) and _test_btn.visible:
		y = _test_btn.offset_top + _test_btn.size.y + 8.0   # Test Layout already sits under the Furniture button
	if _map_btn.visible:
		_map_btn.reset_size()
		_map_btn.position = Vector2(x, y)
		x += _map_btn.size.x + 6.0
	if _back_btn.visible:
		var parent_id := (_nested_stack[-1] as Dictionary)["parent_level_id"] as String
		_back_btn.text = "\uea60  " + _level_display_name(parent_id)
		_back_btn.reset_size()
		_back_btn.position = Vector2(x, y)


func _make_nav_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	GameTheme.hud_button(btn)
	return btn


func _set_mode_hint(text: String) -> void:
	# A level with a nested box in it gets told how to get inside.
	if text != "" and not _collect_nested_boxes().is_empty():
		# Kept to what is particular to boxes: the full line ran under the
		# buttons in the top-right corner.
		text = tr("Double-click a box to enter · drop a piece on a box to put it inside · R rotates a piece")
	if text != "" and not _nested_stack.is_empty():
		# Inside a box the Map and Back buttons sit top-left, under where
		# this line would run: keep it to the one thing that is new here.
		text = tr("Drop a piece on “Back” to send it out · R rotates a piece")
	if text == "":
		if is_instance_valid(_mode_hint_lbl):
			_mode_hint_lbl.visible = false
		return
	if not is_instance_valid(_mode_hint_lbl):
		_mode_hint_lbl = Label.new()
		_mode_hint_lbl.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
		_mode_hint_lbl.add_theme_color_override("font_color", GameTheme.CHALK_SOFT)
		_mode_hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_mode_hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ui_layer.add_child(_mode_hint_lbl)
	_mode_hint_lbl.text = text
	var span := _top_free_span()
	_mode_hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mode_hint_lbl.offset_left   = span.x
	_mode_hint_lbl.offset_right  = span.y
	_mode_hint_lbl.offset_top    = TOP_Y + 40.0
	_mode_hint_lbl.offset_bottom = TOP_Y + 84.0
	_mode_hint_lbl.visible = true
	ui_layer.move_child(_mode_hint_lbl, ui_layer.get_child_count() - 1)


# The stretch of the top edge, centred on the screen, that the title and the
# hint can use without running under the buttons in the top-right corner:
# x is its left edge, y its right edge.
func _top_free_span() -> Vector2:
	var right := RIGHT_X - 8.0
	for c in [_view_mode_box, _redo_btn, _undo_btn, _settings_btn]:
		if is_instance_valid(c) and (c as Control).visible:
			right = minf(right, (c as Control).offset_left - 16.0)
	var mid := (LEFT_X + RIGHT_X) * 0.5
	var half := maxf(minf(mid - LEFT_X - 16.0, right - mid), 120.0)
	return Vector2(mid - half, mid + half)


# Right-click removal of a wall-mounted item dropped directly in the 3D view —
# mirrors WallInspector._remove_wall_at (no refund, matching that 2D behavior).
func _on_wall_sell_pressed(edge: String, origin: Vector2i, apt_floor: Floor) -> void:
	Audio.play("sell")
	_autosave_soon()
	apt_floor.remove_wall_item(edge, origin)
	_refresh_functions()


# ── Floor plan zoom (mouse wheel) / pan (middle-drag) ──────────────────────
# The plan is always the full window now — TOPDOWN is the only mode that
# shows it at all (VIEW3D hides it entirely).
func _floor_pane_right_x() -> float:
	return RIGHT_X


func _floor_pane_bottom_y() -> float:
	if is_instance_valid(inventory) and inventory.visible:
		return tenant_card.offset_top
	return BOT_Y


# Any full-screen modal that should freeze zoom/pan everywhere while it's up:
# the "NEW MECHANIC" intro card, the application fax, the catalogue's backdrop
# and the win/fail result screen.
func _blocking_modal_open() -> bool:
	return _intro_modal_open \
		or is_instance_valid(_application_fax) \
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


# Clicking a wall on the floor plan used to open it in the Wall Inspector (a
# flat elevation view for hanging things). The 3D view does that job directly
# now — drag a piece onto a wall — so the plan no longer offers it: the
# floor's wall_edge_clicked signal is left unconnected and the hover
# highlight that advertised it is switched off. The inspector's own code
# (the 2D Wall Inspector it opened is gone; _on_wall_edge_clicked now just
# switches to 3D).
func _disable_plan_wall_select(fl: Floor) -> void:
	if is_instance_valid(fl) and is_instance_valid(fl.grid_draw):
		fl.grid_draw.wall_select_enabled = false


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
	Audio.play("click")
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
		_set_mode_hint(tr("No wall inspected on this floor yet"))
		return
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	_on_wall_edge_clicked(last["edge"] as String, last["span_lo"] as int, last["span_hi"] as int, apt_floor)


# ── Moving furniture between an apartment and the boxes inside it ────────────
# Drag a piece onto a nested box and let go: it goes into that box's
# apartment. Inside a box, drag a piece onto the "Back to …" button: it goes
# out to the apartment the box stands in. Either way the piece arrives as an
# "owned" piece in the other apartment's catalogue, to be put down there at
# no charge — where it fits over there is still the player's problem.
#
# What cannot travel: keepsakes (they stay in their flat), boxes themselves,
# and staircases.
var _pending_arrivals: Dictionary = {}   # level id -> [{id, count}] for apartments not opened yet
var _place_owned_next := false

func _add_owned(list: Array, fid: String, count: int = 1) -> void:
	for entry in list:
		if (entry as Dictionary)["id"] == fid:
			(entry as Dictionary)["count"] = ((entry as Dictionary)["count"] as int) + count
			return
	list.append({"id": fid, "count": count})


func _refresh_owned_ui() -> void:
	inventory.populate_owned(gm.starting_inventory, gm.furniture_data["furniture"])
	_position_furniture_menu_btn()      # its "owned" count
	_announce_owned.call_deferred()


# Where a piece let go at this spot is headed: {level_id, name}, or {}.
func _transfer_target_at(f: Furniture, screen_pos: Vector2, center_tile: Vector2) -> Dictionary:
	if is_instance_valid(_back_btn) and _back_btn.visible and not _nested_stack.is_empty() \
			and _back_btn.get_global_rect().grow(6.0).has_point(screen_pos):
		var parent_id := (_nested_stack[-1] as Dictionary)["parent_level_id"] as String
		return {"level_id": parent_id, "name": _level_display_name(parent_id)}
	for box in _collect_nested_boxes():
		if box == f or box._wall_ref != f._wall_ref:
			continue
		if Rect2(box.grid_pos, Vector2(box.grid_w, box.grid_h)).has_point(center_tile):
			return {"level_id": box.child_level_id, "name": box.furniture_name}
	return {}


# Furniture.on_drag_dropped: true when the piece was sent elsewhere.
func _on_furniture_dropped(f: Furniture, screen_pos: Vector2, center_tile: Vector2) -> bool:
	if not is_instance_valid(f) or _post_win_view:
		return false
	var target := _transfer_target_at(f, screen_pos, center_tile)
	if target.is_empty():
		return false
	_end_transfer_cues()
	var why := _transfer_refusal(f)
	if why != "":
		Audio.play("error")
		_toast(why, true)
		return false   # falls through to the ordinary drop, which puts it back
	var fid := f.furniture_id
	var piece_name := f.furniture_name
	var fl := f._wall_ref as Floor
	fl.remove_furniture(f)
	if is_instance_valid(_mode3d_view):
		_mode3d_view.remove_furniture_entry(f)
	f.queue_free()
	_deliver_piece(fid, piece_name, target)
	return true


# Pets. A caged bird sings: anything that needs quiet within its reach gets
# none (beds stop counting as somewhere to sleep). And it needs the window:
# standing in the dark it gives nothing, and the player is told why, once
# each time it happens.
const DAYLIGHT_NEEDED := 0.30

func _recompute_pet_effects() -> void:
	for fid in _floors:
		var fl := _floors[fid] as Floor
		var all: Array = fl.get_all_furniture()
		for entry in all:
			var pet := entry as Furniture
			if pet.needs_daylight:
				# The light that reaches it: the brightest tile right beside
				# it. (The tile under a piece is in that piece's own shade.)
				var px := floori(pet.grid_pos.x)
				var py := floori(pet.grid_pos.y)
				var reaching := 0.0
				for x in range(px - 1, px + pet.grid_w + 1):
					for y in range(py - 1, py + pet.grid_h + 1):
						if x < px or x >= px + pet.grid_w or y < py or y >= py + pet.grid_h:
							reaching = maxf(reaching, fl.get_light(Vector2i(x, y)))
				var starved := reaching < DAYLIGHT_NEEDED
				if starved and not pet._daylight_starved:
					_toast(tr("%s needs daylight: stand it where the window's light reaches.") % pet.furniture_name, true)
				pet._daylight_starved = starved
			if pet.noise_radius <= 0 or not pet.is_noisy:
				continue
			var reach := Rect2(pet.grid_pos, Vector2(pet.grid_w, pet.grid_h)).grow(float(pet.noise_radius))
			for other in all:
				var q := other as Furniture
				if q != pet and q.needs_quiet and reach.intersects(Rect2(q.grid_pos, Vector2(q.grid_w, q.grid_h))):
					q._noise_muted = true
					q._noise_by = pet.furniture_name
					pet._noise_making = true


# Hands a piece to another apartment: it joins that apartment's owned pieces,
# and unless Shift is held the player goes along with it in hand.
func _deliver_piece(fid: String, piece_name: String, target: Dictionary, bought: bool = false) -> void:
	var to_id := target["level_id"] as String
	if _level_state_cache.has(to_id):
		var snap := _level_state_cache[to_id] as Dictionary
		if not snap.has("owned"):
			snap["owned"] = []
		_add_owned(snap["owned"] as Array, fid)
	else:
		if not _pending_arrivals.has(to_id):
			_pending_arrivals[to_id] = []
		_add_owned(_pending_arrivals[to_id] as Array, fid)
	# The move spans two apartments; undo only knows about this one.
	_builder_undo_stack.clear()
	_redo_stack.clear()
	_refresh_undo_redo_buttons()
	Audio.play("place")
	_refresh_functions()
	if Input.is_key_pressed(KEY_SHIFT):
		var msg := tr("Bought %s  →  %s.   It is waiting under “Owned” in the catalogue there.") if bought \
			else tr("Sent %s  →  %s.   It is waiting under “Owned” in the catalogue there.")
		_toast(msg % [piece_name, target["name"]])
	else:
		_follow_transfer.call_deferred(to_id, fid, piece_name)


# Furniture.on_purchase_dropped: a piece still being bought was clicked down
# on a box (or on Back). It is paid for out of THIS apartment's budget and
# delivered to that one — buying a lodger a wardrobe their own budget can't
# stretch to. True when that happened.
var _pending_purchase: Dictionary = {}    # {fid, owned} for the placement in progress

func _on_purchase_dropped(f: Furniture, screen_pos: Vector2, center_tile: Vector2) -> bool:
	if not is_instance_valid(f) or _post_win_view or _pending_purchase.is_empty():
		return false
	var target := _transfer_target_at(f, screen_pos, center_tile)
	if target.is_empty():
		return false
	_end_transfer_cues()
	var why := _transfer_refusal(f)
	if why != "":
		Audio.play("error")
		_toast(why, true)
		return true     # swallowed: the click was on a box, not a place to put it down
	var fid := _pending_purchase["fid"] as String
	var owned := _pending_purchase["owned"] as bool
	var piece_name := f.furniture_name
	_pending_purchase = {}
	_settle_placement(fid, owned)          # this apartment pays (or gives up its owned piece)
	# Put the ghost away; the purchase was already settled above, and
	# cancelling a ghost never charges or refunds anything.
	if _view_mode == ViewMode.VIEW3D and is_instance_valid(_mode3d_view):
		_mode3d_view._cancel_buy()
	else:
		f.cancel_placement()
	_deliver_piece(fid, piece_name, target, not owned)
	return true


# Travels to the apartment a piece was just sent to and puts that piece on
# the pointer. Backing out (Esc) leaves it under "Owned" there.
func _follow_transfer(to_id: String, fid: String, piece_name: String) -> void:
	if _nested_transition_busy or _nested_travel_busy or _map_jump_busy:
		return
	if not _nested_stack.is_empty() and ((_nested_stack[-1] as Dictionary)["parent_level_id"] as String) == to_id:
		await _exit_nested_animated()
	else:
		var door: Furniture = null
		for box in _collect_nested_boxes():
			if box.child_level_id == to_id:
				door = box
				break
		if door == null:
			return
		await _enter_box_animated(door)
	if _current_level_id != to_id:
		return
	_owned_announced_for = _level_load_id     # the piece in hand says it already
	await get_tree().process_frame
	_on_place_owned_requested(fid)
	_toast(tr("%s came with you. Click to put it down  ·  Esc leaves it under “Owned”.") % piece_name)


func _process(_delta: float) -> void:
	_update_carry_icon()
	if not _xfer_dragging:
		return
	if _xfer_purchase:
		# A piece being bought follows the pointer with no button held; its
		# cues last until it is put down or backed out of.
		if not is_instance_valid(_xfer_piece) or not (_xfer_piece._placement_mode \
				or (is_instance_valid(_mode3d_view) and _mode3d_view._buying_furniture == _xfer_piece)):
			_end_transfer_cues()
	elif not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_transfer_cues()


# While a piece just picked in the catalogue is still over the catalogue (or
# anywhere off the plan), its ghost on the plan is hidden: the piece's picture
# rides at the pointer instead, so a click in the shop shows at once that
# the piece is in hand.
var _carry_layer: CanvasLayer = null
var _carry_icon: Control = null
var _carry_fid := ""

func _update_carry_icon() -> void:
	var ghost := _pending_floor_ghost
	var carrying := is_instance_valid(ghost) and ghost._placement_mode and not ghost.visible
	if not carrying:
		if is_instance_valid(_carry_icon):
			_carry_icon.visible = false
		return
	if not is_instance_valid(_carry_layer):
		_carry_layer = CanvasLayer.new()
		_carry_layer.layer = 30
		add_child(_carry_layer)
	if _carry_fid != ghost.furniture_id or not is_instance_valid(_carry_icon):
		if is_instance_valid(_carry_icon):
			_carry_icon.queue_free()
		_carry_fid = ghost.furniture_id
		var tex: Texture2D = Thumb.get_cached(_carry_fid)
		if tex:
			var rect := TextureRect.new()
			rect.texture = tex
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			rect.custom_minimum_size = Vector2(72, 72)
			rect.size = Vector2(72, 72)
			_carry_icon = rect
		else:
			_carry_icon = Inventory._make_item_icon(gm.get_furniture_by_id(_carry_fid), 56.0)
		_carry_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_carry_icon.modulate.a = 0.85
		_carry_layer.add_child(_carry_icon)
	_carry_icon.visible = true
	var sz := _carry_icon.size if _carry_icon.size != Vector2.ZERO else _carry_icon.custom_minimum_size
	_carry_icon.position = _carry_layer.get_viewport().get_mouse_position() - sz * 0.5


func _transfer_refusal(f: Furniture) -> String:
	if f.keepsake:
		return tr("\uf67c %s is a keepsake: it stays in this flat") % f.furniture_name
	if f.is_nested_box:
		return tr("A box can't go inside another apartment")
	if f.is_stair:
		return tr("Stairs can't move to another apartment")
	return ""


# ── What the player sees while carrying a piece ──────────────────────────────
# The moment a piece is picked up, every place it could be sent lights up:
# each box gets a green outline, and inside a box the Back button turns into
# a labelled drop target. Over one of them, a tag by the pointer says exactly
# what letting go will do, or why it won't.
var _xfer_dragging := false
var _xfer_tag: PanelContainer = null
var _xfer_outlines: Array = []      # [{box: Furniture, line: Line2D}]
var _xfer_back_text := ""
var _xfer_purchase := false         # the piece being carried is one being bought
var _xfer_piece: Furniture = null

func _on_furniture_drag_moved(f: Furniture, screen_pos: Vector2, center_tile: Vector2) -> void:
	if not is_instance_valid(f) or _post_win_view:
		return
	if not _xfer_dragging:
		_begin_transfer_cues(f)
	var target := _transfer_target_at(f, screen_pos, center_tile)
	var to_parent := not target.is_empty() and not _nested_stack.is_empty() \
		and (target["level_id"] as String) == ((_nested_stack[-1] as Dictionary)["parent_level_id"] as String) \
		and _back_btn.get_global_rect().grow(6.0).has_point(screen_pos)
	for entry in _xfer_outlines:
		var box: Furniture = entry["box"]
		var line: Line2D = entry["line"]
		if not is_instance_valid(box) or not is_instance_valid(line):
			continue
		var hot := not target.is_empty() and not to_parent and box.child_level_id == (target["level_id"] as String)
		line.width = 5.0 if hot else 2.5
		line.default_color = Color(0.45, 1.0, 0.62) if hot else Color(0.35, 0.86, 0.52, 0.75)
	if is_instance_valid(_back_btn) and _back_btn.visible:
		_back_btn.modulate = Color(1.35, 1.35, 1.0) if to_parent else Color(1, 1, 1)
	if target.is_empty():
		Furniture.transfer_hover = 0
		if is_instance_valid(_xfer_tag):
			_xfer_tag.visible = false
		return
	var why := _transfer_refusal(f)
	var text := why
	if why == "":
		if _xfer_purchase and not (not _pending_purchase.is_empty() and (_pending_purchase["owned"] as bool)):
			# Paid for here, delivered there.
			text = tr("%s  Buy it for %s  ·  %d€ from this budget") % ["←" if to_parent else "→", target["name"], f.buy_price]
		else:
			text = (tr("←  Take out to %s") if to_parent else tr("→  Take into %s")) % target["name"]
		text += "\n" + tr("Shift: send it without going")
	Furniture.transfer_hover = 2 if why != "" else 1
	f.queue_redraw()
	_show_transfer_tag(text, why != "", screen_pos)


func _begin_transfer_cues(f: Furniture) -> void:
	_xfer_dragging = true
	_xfer_piece = f
	_xfer_purchase = f._placement_mode or (is_instance_valid(_mode3d_view) and _mode3d_view._buying_furniture == f)
	if _transfer_refusal(f) != "":
		return     # nothing to offer this piece; the tag explains if it is tried
	for box in _collect_nested_boxes():
		if box == f or box._wall_ref != f._wall_ref:
			continue
		var line := Line2D.new()
		var w := box.grid_w * float(TILE_SIZE)
		var h := box.grid_h * float(TILE_SIZE)
		line.points = PackedVector2Array([Vector2(-2, -2), Vector2(w + 2, -2), Vector2(w + 2, h + 2), Vector2(-2, h + 2)])
		line.closed = true
		line.width = 2.5
		line.default_color = Color(0.35, 0.86, 0.52, 0.75)
		line.z_index = 30
		box.add_child(line)
		_xfer_outlines.append({"box": box, "line": line})
	if is_instance_valid(_back_btn) and _back_btn.visible and not _nested_stack.is_empty():
		_xfer_back_text = _back_btn.text
		var parent_id := (_nested_stack[-1] as Dictionary)["parent_level_id"] as String
		_back_btn.text = (tr("←  Click here to buy it for %s") if _xfer_purchase else tr("←  Drop here to send to %s")) % _level_display_name(parent_id)
		_back_btn.reset_size()


func _end_transfer_cues() -> void:
	if not _xfer_dragging:
		return
	_xfer_dragging = false
	Furniture.transfer_hover = 0
	for entry in _xfer_outlines:
		if is_instance_valid(entry["line"]):
			(entry["line"] as Line2D).queue_free()
	_xfer_outlines.clear()
	if is_instance_valid(_xfer_tag):
		_xfer_tag.visible = false
	if is_instance_valid(_back_btn):
		_back_btn.modulate = Color(1, 1, 1)
		if _xfer_back_text != "":
			_back_btn.text = _xfer_back_text
			_back_btn.reset_size()
	_xfer_back_text = ""


func _show_transfer_tag(text: String, refused: bool, at: Vector2) -> void:
	if not is_instance_valid(_xfer_tag):
		_xfer_tag = PanelContainer.new()
		_xfer_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_xfer_tag.z_index = 200
		var lbl := Label.new()
		lbl.name = "Text"
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_xfer_tag.add_child(lbl)
		ui_layer.add_child(_xfer_tag)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.30, 0.10, 0.09, 0.96) if refused else Color(0.07, 0.24, 0.15, 0.96)
	sb.border_color = Color(0.98, 0.42, 0.36) if refused else Color(0.45, 1.0, 0.62)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(7)
	_xfer_tag.add_theme_stylebox_override("panel", sb)
	var label := _xfer_tag.get_node("Text") as Label
	label.text = text
	label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.84) if refused else Color(0.86, 1.0, 0.90))
	_xfer_tag.visible = true
	_xfer_tag.reset_size()
	var pos := at + Vector2(18, 18)
	pos.x = clampf(pos.x, 4.0, RIGHT_X - _xfer_tag.size.x - 4.0)
	pos.y = clampf(pos.y, 4.0, BOT_Y - _xfer_tag.size.y - 4.0)
	_xfer_tag.position = pos
	ui_layer.move_child(_xfer_tag, ui_layer.get_child_count() - 1)


# A short message across the bottom of the play area, above the bar. For
# things that just happened and need saying once.
var _toast_panel: PanelContainer = null
var _toast_tween: Tween = null

func _toast(text: String, bad: bool = false) -> void:
	if not is_instance_valid(_toast_panel):
		_toast_panel = PanelContainer.new()
		_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var lbl := Label.new()
		lbl.name = "Text"
		lbl.add_theme_font_size_override("font_size", 14)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_toast_panel.add_child(lbl)
		ui_layer.add_child(_toast_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.28, 0.10, 0.09, 0.96) if bad else Color(0.06, 0.13, 0.22, 0.96)
	sb.border_color = Color(0.98, 0.42, 0.36) if bad else GameTheme.C_AMBER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.set_content_margin(SIDE_LEFT, 16)
	sb.set_content_margin(SIDE_RIGHT, 16)
	sb.set_content_margin(SIDE_TOP, 9)
	sb.set_content_margin(SIDE_BOTTOM, 9)
	_toast_panel.add_theme_stylebox_override("panel", sb)
	var label := _toast_panel.get_node("Text") as Label
	label.text = text
	label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.84) if bad else Color(1.0, 0.95, 0.78))
	_toast_panel.visible = true
	_toast_panel.modulate.a = 1.0
	_toast_panel.reset_size()
	_toast_panel.position = Vector2((RIGHT_X - _toast_panel.size.x) * 0.5, _hud_stack_top() - _toast_panel.size.y - 14.0)
	ui_layer.move_child(_toast_panel, ui_layer.get_child_count() - 1)
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(3.2)
	_toast_tween.tween_property(_toast_panel, "modulate:a", 0.0, 0.5)
	_toast_tween.tween_callback(func(): _toast_panel.visible = false)


func _owned_count() -> int:
	var n := 0
	for entry in gm.starting_inventory:
		n += (entry as Dictionary)["count"] as int
	return n


# On arriving somewhere pieces are waiting, say so once.
var _owned_announced_for := -1

func _announce_owned() -> void:
	var n := _owned_count()
	if n <= 0 or _owned_announced_for == _level_load_id:
		return
	_owned_announced_for = _level_load_id
	_toast(tr_n("%d piece is waiting for you here: open Furniture, it is first under “Owned”.",
		"%d pieces are waiting for you here: open Furniture, they are first under “Owned”.", n) % n)


func _on_place_owned_requested(furniture_id: String) -> void:
	var have := false
	for entry in gm.starting_inventory:
		if (entry as Dictionary)["id"] == furniture_id and ((entry as Dictionary)["count"] as int) > 0:
			have = true
	if not have:
		return
	_place_owned_next = true
	_on_buy_requested(furniture_id)
	_place_owned_next = false


# Settles a placement: an owned piece comes off the owned list, anything
# else is paid for.
func _settle_placement(furniture_id: String, owned: bool) -> void:
	if owned:
		gm.consume_starting_item(furniture_id)
		_refresh_owned_ui()
	else:
		gm.buy_furniture(furniture_id)


func _on_buy_requested(furniture_id: String) -> void:
	# The catalogue strip stays open: buy, place, buy the next one.
	var owned := _place_owned_next
	# Clicking another piece while one is still being placed swaps it: the
	# first is put back, not left following the pointer underneath.
	if is_instance_valid(_pending_floor_ghost) and _pending_floor_ghost._placement_mode:
		_pending_floor_ghost.cancel_placement()
	_pending_floor_ghost = null
	# Same in 3D, and before the new purchase's handlers are connected below:
	# Room3DView.start_buying() would cancel the old one itself, but its
	# buy_cancelled signal would then reach the NEW handlers too, which free
	# the new piece at once, so the second click seemed to do nothing.
	if is_instance_valid(_mode3d_view) and _mode3d_view._buying_furniture != null:
		_mode3d_view._cancel_buy()
	_pending_purchase = {"fid": furniture_id, "owned": owned}
	var apt_floor := _floors.get(_current_floor_id) as Floor
	if not apt_floor:
		return
	var fdata := gm.get_furniture_by_id(furniture_id)
	if fdata.is_empty():
		return
	if not owned and gm.budget < (fdata.get("buy_price", 0) as int):
		return
	# Each rental box is one particular tenant's home, so an apartment takes
	# one of each.
	if fdata.get("rental", false) as bool:
		for box in _collect_nested_boxes():
			if box.furniture_id == furniture_id:
				Audio.play("error")
				_set_mode_hint(tr("%s is already renting here — pick a different box.") % (fdata.get("name", "") as String))
				return
	# Something that only goes on a wall can't be placed from the plan now
	# that walls aren't opened there: go to the 3D view, where it can be
	# dragged straight onto one.
	if (fdata.get("placement", "floor") as String) == "wall" and _view_mode != ViewMode.VIEW3D:
		_set_view_mode(ViewMode.VIEW3D)
	# Every item can go on the floor or on a wall — arm both placements at once.
	# Whichever the player actually clicks into completes the purchase; the other
	# is cancelled automatically.
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	_weigh_box(f)
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
			_settle_placement(furniture_id, owned)
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed()
		h["wall_confirmed"] = func(_fid: String, _edge: String, _origin: Vector2i):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_cancelled.disconnect(h["cancelled"])
			apt_floor.forget_furniture(f)   # never leave a freed node on the floor's books
			f.queue_free()   # the floor ghost was never used — it landed on a wall instead
			_settle_placement(furniture_id, owned)
			_refresh_functions()
			_on_furniture_action_changed()
		h["cancelled"] = func(_f: Furniture):
			_mode3d_view.buy_confirmed.disconnect(h["confirmed"])
			_mode3d_view.buy_confirmed_wall.disconnect(h["wall_confirmed"])
			apt_floor.forget_furniture(f)
			f.queue_free()
			_refresh_functions()
		_mode3d_view.buy_confirmed.connect(h["confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_confirmed_wall.connect(h["wall_confirmed"], CONNECT_ONE_SHOT)
		_mode3d_view.buy_cancelled.connect(h["cancelled"], CONNECT_ONE_SHOT)
		_mode3d_view.start_buying(f, fdata)
	else:
		f.placement_confirmed.connect(func():
			_settle_placement(furniture_id, owned)
			_pending_floor_ghost = null
			if fdata.get("creates_loft", false):
				_promote_to_loft(f, apt_floor)
			_refresh_functions()
			_on_furniture_action_changed())
		f.placement_cancelled.connect(func():
			_pending_floor_ghost = null
			_refresh_functions())
		f.begin_placement(apt_floor, get_viewport().get_mouse_position())
		_pending_floor_ghost = f

	_refresh_functions()


func _on_sell_pressed(furniture: Furniture, apt_floor: Floor) -> void:
	# A keepsake stays. (The 3D view checks this itself before it drops the
	# piece from its own cache; this is the plan's path and the backstop.)
	if is_instance_valid(furniture) and furniture.keepsake:
		Audio.play("error")
		_set_mode_hint(tr("\uf67c %s is a keepsake: it can be moved, not sold.") % furniture.furniture_name)
		return
	# Taking a rental box back out means handing its rent back.
	if is_instance_valid(furniture) and furniture.buy_price < 0 and gm.budget < -furniture.buy_price:
		Audio.play("error")
		_set_mode_hint(tr("Removing %s means repaying its %d€ rent — you only have %d€.") % [
			furniture.furniture_name, -furniture.buy_price, gm.budget])
		return
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
	if _batch_refresh:
		return
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
	if _batch_refresh:
		return
	# Keeps every box's weight/tier/noise effects current before anything
	# below reads functions or weight — covers level load, entering/exiting a
	# box, AND every ordinary furniture move, since this already runs on all
	# of those (see _recompute_box_effects()'s own comment for why it lives
	# here instead of its own separate call sites).
	_recompute_box_effects()
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
		# The rules that aren't furniture needs, shown where the player looks:
		# lines on the plan, lines and zone tints in 3D, chips in the bar.
		apt_floor.set_sight_lines(gm.sightline_status)
		apt_floor.set_zone_status(gm.zone_status())
		tenant_card.update_rules(gm.rule_status())
		if is_instance_valid(_mode3d_view):
			_mode3d_view.set_rule_overlays(gm.sightline_status, apt_floor.zones, apt_floor.zone_status)
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
	budget_label.text = "\ueb82 %d €" % new_budget


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
# A level that asks for nothing (the inside of a rental box) has nothing to
# complete, so it never shows the "rented out" screen.
func _level_has_goal() -> bool:
	return not gm.required_functions.is_empty() or not gm.moments.is_empty()


func _update_rent_btn() -> void:
	var was_disabled := rent_btn.disabled
	var was_ok_here := (_level_ok.get(_current_level_id, {}) as Dictionary).get("ok", false) as bool
	_record_level_status()
	var status := _project_status()
	rent_btn.disabled = not status["complete"]
	tenant_card.set_rent_available(not rent_btn.disabled)
	tenant_card.set_project_status(status["done"], status["total"], status["pending_names"])
	var ok_here := (_level_ok.get(_current_level_id, {}) as Dictionary).get("ok", false) as bool
	if _rent_auto_armed and not _post_win_view and ok_here and not was_ok_here and not status["complete"] \
			and _level_has_goal():
		# This apartment is done, but the project isn't: say what's left.
		Audio.play("success")
		_toast(tr("This apartment is ready. Still to furnish: %s") % Loc.join_list(status["pending_names"]))
	# _rent_auto_armed stays false until _load_level() has finished spawning
	# the level's starting furniture and synced this same baseline — otherwise
	# resuming an already-satisfied saved layout ("Revisar Plano Actual")
	# would trip this edge the instant it loads, replaying the completion
	# screen before the player has done anything. _post_win_view means we're
	# in the read-only "Watch Again" replay of an already-completed level.
	if _rent_auto_armed and was_disabled and not rent_btn.disabled and not _post_win_view and not _completing_project:
		_complete_project()


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
			result_screen.show_failure(tr("The tenant isn't comfortable with this arrangement.\nToo much furniture has been rearranged — try keeping heavier pieces closer to where they started."))
		else:
			var unmet: PackedStringArray = []
			for rule in gm.rule_status():
				if not ((rule as Dictionary)["ok"] as bool):
					unmet.append((rule as Dictionary)["label"] as String)
			if unmet.is_empty():
				result_screen.show_failure(tr("Not every need on the bar is ticked yet."))
			else:
				result_screen.show_failure(tr("Still missing:"), Array(unmet))
		_refresh_undo_redo_buttons()
		return
	if not _all_furniture_accessible():
		Audio.play("error")
		if Floor.pathing_enabled:
			var stuck: PackedStringArray = []
			for fid in _floors:
				for f in (_floors[fid] as Floor).get_inaccessible_furniture():
					stuck.append((f as Furniture).furniture_name)
			result_screen.show_failure(tr("The tenant can't walk to: %s.\nLeave a path at least 40 cm wide from the door to the side each piece is used from.") % ", ".join(stuck))
		else:
			result_screen.show_failure(tr("Some furniture is completely blocked.\nLeave at least 1 tile of walking space around it."))
		_refresh_undo_redo_buttons()
		return

	Audio.play("success")

	var stars       := gm.calculate_stars()
	var funds       := gm.get_funds_reward()
	var level_rent  := gm.current_level["tenant"]["monthly_rent"] as int

	GameState.complete_level(_current_level_id, stars, funds, level_rent)
	GameState.save_level_layout(_current_level_id, _snapshot_all_furniture())
	_level_ok.clear()
	_box_cond.clear()
	# Rented out: nothing left half-done here.
	if _nested_stack.is_empty():
		GameState.clear_progress(_current_level_id)
		_autosave_dirty = false
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
	result_screen.show_success(_result_info(stars, funds,
		not gm.get_next_owned_level_id(completed_level_id).is_empty()))
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
	var tenant: Dictionary = gm.current_level.get("tenant", {})
	var tenant_name: String = tenant.get("key_name", tenant.get("name", "Tenant"))
	var hue := float(tenant_name.hash() % 360) / 360.0
	var color := Color.from_hsv(hue, 0.55, 0.85)
	_mode3d_view.start_tenant_showcase(gm.moments, color)




# `sound` is off only for the moment a level opens on.
func _on_moment_selected(moment_id: String, sound: bool = true) -> void:
	if sound and moment_id != _active_moment_id:
		Audio.play("click")
		_autosave_soon()
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
	if tenant_layer:
		tenant_layer.resync()


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
	if tenant_layer:
		tenant_layer.note_activity(event)
	# While the player is typing (the catalogue's search box), letters are
	# text, not shortcuts. Escape still closes the catalogue.
	if event is InputEventKey and get_viewport().gui_get_focus_owner() is LineEdit:
		var typed := event as InputEventKey
		if typed.pressed and typed.keycode == KEY_ESCAPE and _is_furniture_menu_open():
			_close_furniture_menu()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var ke := event as InputEventKey
		# Esc opens the menu. It only gets this far when nothing else wanted
		# it: a piece being placed or bought cancels on Esc first, and the
		# menu and the other windows close themselves on it.
		if ke.pressed and not ke.echo and ke.keycode == KEY_ESCAPE:
			if is_instance_valid(_application_fax):
				_application_fax.skip_or_close()
			elif not _intro_modal_open and not result_screen.visible:
				_on_settings_btn_pressed()
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
	if tenant_layer:
		tenant_layer.stop()
	Furniture.read_only     = true
	_set_view_mode(ViewMode.VIEW3D)
	if is_instance_valid(_mode3d_view):
		_mode3d_view.read_only = true
	_start_tenant_showcase()
	_close_furniture_menu()
	if is_instance_valid(_furniture_menu_btn):
		_furniture_menu_btn.visible = false
	_refresh_undo_redo_buttons()
	_show_watch_done_button()


# "Walk Through" on the Results screen: the same read-only look around as
# View Apartment, but at eye height inside the flat (Room3DView's first-person
# mode), over the whole window with the HUD out of the way. Esc goes straight
# back to the results.
func _on_walk_through() -> void:
	_on_watch_again_reveal()
	if not is_instance_valid(_mode3d_view) or not _mode3d_view.enter_first_person():
		return   # nowhere to stand: stays the ordinary View Apartment
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.visible = false
	_mode3d_view.offset_left   = 0.0
	_mode3d_view.offset_top    = 0.0
	_mode3d_view.offset_right  = RIGHT_X
	_mode3d_view.offset_bottom = BOT_Y
	_walk_view_index = _mode3d_view.get_index()
	ui_layer.move_child(_mode3d_view, ui_layer.get_child_count() - 1)
	if not _mode3d_view.first_person_exited.is_connected(_on_walk_through_exited):
		_mode3d_view.first_person_exited.connect(_on_walk_through_exited)


func _on_walk_through_exited() -> void:
	if is_instance_valid(_mode3d_view):
		_mode3d_view.offset_left   = LEFT_X
		_mode3d_view.offset_top    = TOP_Y
		_mode3d_view.offset_right  = RIGHT_X
		_mode3d_view.offset_bottom = _floor_pane_bottom_y()
		# Back under the HUD it was raised over.
		ui_layer.move_child(_mode3d_view, mini(_walk_view_index, ui_layer.get_child_count() - 1))
	_close_watch_again()


func _show_watch_done_button() -> void:
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.queue_free()
	_watch_done_btn = Button.new()
	_watch_done_btn.text = tr("\ueb55 Back to Results")
	_watch_done_btn.add_theme_font_size_override("font_size", 13)
	_watch_done_btn.custom_minimum_size = Vector2(200, 40)
	ui_layer.add_child(_watch_done_btn)
	# Centered on the play area (not the whole window) and sat below the
	# diorama's resting position, rather than tucked in the top-left corner
	# where it competed with the Builder tool panel.
	_position_watch_done_btn()
	# Same reasoning as Inventory in _ensure_mode3d_view: the 3D view is a
	# later sibling in this same CanvasLayer, so a freshly added Control has
	# to be moved after it explicitly or the 3D view's opaque background
	# paints over it and swallows its clicks.
	ui_layer.move_child(_watch_done_btn, ui_layer.get_child_count() - 1)
	_watch_done_btn.pressed.connect(_close_watch_again)


# Centred on the play area, just above the needs bar: the bar grows a row
# when its chips wrap (the apartments chip, rules), and a fixed height left
# the button sitting on top of it.
func _position_watch_done_btn() -> void:
	if not is_instance_valid(_watch_done_btn):
		return
	var center_x := (LEFT_X + RIGHT_X) * 0.5
	var bar_top := tenant_card.get_global_rect().position.y if is_instance_valid(tenant_card) else BOT_Y
	_watch_done_btn.offset_left   = center_x - 100.0
	_watch_done_btn.offset_right  = center_x + 100.0
	_watch_done_btn.offset_bottom = bar_top - 14.0
	_watch_done_btn.offset_top    = bar_top - 54.0


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
	PauseMenu.open(self)


# Shared by the floating "Back to Results" button above and the gear menu
# (_on_settings_btn_pressed) — both need to exit free-look the same way.
func _close_watch_again() -> void:
	if is_instance_valid(_watch_done_btn):
		_watch_done_btn.queue_free()
		_watch_done_btn = null
	_post_win_view = false
	_start_tenants()
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
	chip.text = "  %s  " % tr("CUSTOM BUILD")
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
	hint.text = tr("LMB paint · RMB erase")
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(0.45, 0.48, 0.52))
	header.add_child(hint)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 4)
	vb.add_child(btn_row)

	var bg_group := ButtonGroup.new()

	var move_btn := Button.new()
	move_btn.text           = tr("Move")
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
		btn.text         = tr("%s  %d€/tile") % [lbl, cpt]
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
	_autosave_soon()
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
				"wall", "glass_wall", "rail", "reveal":
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
			if _builder_drawing and (_active_builder_tool == "wall" or _active_builder_tool == "glass_wall"):
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
			"wall", "glass_wall", "rail", "reveal":
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
	_autosave_soon()   # the build happens right after this; the save, a moment later
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
	_update_nested_nav()   # buying or selling a box changes whether the Map button applies
	if not _last_furniture_state.is_empty():
		_builder_undo_stack.append({"type": "furniture", "snapshot": _last_furniture_state})
		if _builder_undo_stack.size() > BUILDER_UNDO_MAX:
			_builder_undo_stack.pop_front()
		_redo_stack.clear()
		_refresh_undo_redo_buttons()
	_last_furniture_state = _snapshot_all_furniture()
	_autosave_soon()
	# Once the checker has caught up with this change (it runs from other
	# handlers of the same signals), the tenants react to it.
	if tenant_layer:
		tenant_layer.request_commit()


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
			if f.keepsake:
				entry["keepsake"] = true
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
	_batch_refresh = true
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
		fl.begin_batch()
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
		fl.end_batch()
	_restoring_furniture = false
	_batch_refresh = false
	_last_furniture_state = _snapshot_all_furniture()
	_refresh_functions()
	if tenant_layer:
		tenant_layer.resync()
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
	if override_data.get("keepsake", false):
		fdata = fdata.duplicate()
		fdata["keepsake"] = true
	var f: Furniture = FurnitureScene.instantiate() as Furniture
	apt_floor.add_child(f)
	f.setup(fdata, apt_floor)
	_weigh_box(f)
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
	fl.add_segment(ps.x, ps.y, pe.x, pe.y, _active_builder_tool == "glass_wall")
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
		_paint_status_lbl.text = tr("Paint tiles on the floor")
		return
	var piece := _paint_pieces[floor_id][_active_paint_type] as PaintedFurniture
	if not is_instance_valid(piece):
		return
	_paint_status_lbl.text = piece.validation_message()
	var valid := piece.is_valid()
	_paint_status_lbl.add_theme_color_override("font_color",
		Color(0.38, 0.72, 0.48) if valid else Color(0.65, 0.38, 0.30))
