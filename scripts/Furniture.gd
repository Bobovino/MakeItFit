extends Node2D
class_name Furniture

signal placed(furniture_node: Node2D)
signal sell_requested(furniture_node: Furniture)
signal fold_toggled
signal placement_confirmed
signal placement_cancelled

const TILE_SIZE := 8

# Set once by Main._ready() so a floor-placement ghost knows whether a click is
# actually over the floor pane — otherwise it swallows every left click on
# screen (other panels, buttons) trying to confirm placement at a stale position.
static var is_in_floor_pane: Callable = Callable()
# (furniture, screen position, the piece's centre in tiles) -> true when Main
# took the piece (dropped on a nested box, or on "Back": see
# Main._on_furniture_dropped), so the ordinary "put it down here" is skipped.
static var on_drag_dropped: Callable = Callable()
# (furniture, screen position, the piece's centre in tiles) on every move of
# a piece being dragged, so Main can show where letting go would send it.
static var on_drag_moved: Callable = Callable()
# The same question as on_drag_dropped, for a piece that is still being
# bought (a placement ghost) and was clicked down on a box or on Back: Main
# pays for it here and delivers it there.
static var on_purchase_dropped: Callable = Callable()
# What the piece being carried is hovering: 0 nothing special, 1 somewhere it
# can be sent (a box, or Back), 2 somewhere it is not allowed to go. Main sets
# it; while it is not 0, Main's own tag by the pointer does the explaining and
# the usual "blocked here" note keeps quiet.
static var transfer_hover: int = 0
# Set by Main: called with the box when the player double-clicks a nested box.
static var on_box_enter_requested: Callable = Callable()

func _play(sound: String) -> void:
	var am := get_node_or_null("/root/Audio")
	if am:
		am.play(sound)

var furniture_id: String = ""
var grid_w: int = 1
var grid_h: int = 1
# 0..3, one 90° step each — purely the *visual facing* (which side is the
# front). grid_w/grid_h already swap on every _rotate() call regardless (so
# collision/footprint has always cycled correctly through all 4 orientations
# every 2 steps); this is the piece this session was missing: a way to tell
# 0° apart from 180° (and 90° from 270°), since a plain w/h swap alone can't
# — both members of each pair have an identical bounding box.
var rot_steps: int = 0
var grid_pos: Vector2 = Vector2.ZERO   # continuous tile-space position — 3D is the source of truth
var functions: Array = []
var buy_price: int = 0
var sell_price: int = 0
var furniture_name: String = ""
var ghost_radius: int = 0   # interaction/clearance zone in tiles (0 = none)
var foldable: bool = false
var is_extended: bool = false
var extended_add_h: int = 0           # extra tiles in +Y when fully extended
var folded_functions_arr:   Array = []
var extended_functions_arr: Array = []
var moment_fold_state: Dictionary = {}   # moment_id -> bool; each moment remembers its OWN fold state
static var active_moment_id: String = "" # "" for levels without moments
# Every moment id in the currently-loaded level, set by Main._load_level()
# alongside active_moment_id — needed by the cross-moment collision check for
# red-tier (non-rail) moves, which has to look at every OTHER moment, not
# just whichever one is currently on screen.
static var all_moment_ids: Array = []
# moment_id -> display label ("day" -> "Day"), set alongside all_moment_ids —
# Wall.gd's cross-moment block-reason message reads this so the player sees
# "during 'Night'" instead of the raw id, which wouldn't always read cleanly
# for every level's own id conventions.
static var moment_labels: Dictionary = {}
var _base_grid_h: int = 1             # grid_h when folded

var height_category: String = "medium"  # "low" | "medium" | "tall"
var z_bottom: float = 0.0  # tiles from floor level
var z_top:    float = 12.0 # tiles from floor level
var needs_water:  bool = false
var needs_power:  bool = false
var zone_divider: bool = false   # acts as a soft wall for zone flood-fill
var floor_category: String = "any"   # "any" | "balcony" | "bathroom" — which tile kinds accept this piece
var wall_flush_required: bool = false   # must end up snapped flush against a wall — see Wall.can_place()
var is_stair:     bool = false
var stair_direction: String = ""   # "north" | "south" | "east" | "west"

# Weight & support — see Wall.can_place()'s mezzanine load check. Defaults to
# footprint area (a bigger piece is assumed heavier) so every catalog item
# gets a sane value without needing a manual "weight" entry; catalog data can
# still override it explicitly for anything unusually light/heavy for its size.
var weight: float = 1.0
# Only "surface" furniture (tables, desks, shelves) can host requires_surface
# items on the same tile; max_support_weight caps how much can rest on it.
var is_surface: bool = false
var max_support_weight: float = 0.0
var requires_surface: bool = false
# Height of the piece in tiles (the catalogue's wall_h, what the 3D view
# draws): how high whatever is stacked on it stands. See Floor.stack_lift().
var body_h: float = 8.0
# How many surfaces this piece stands on top of (0 = the floor); the plan
# draws it that far up so it shows over its table. Floor keeps it current.
var stack_z: int = 0
# How loaded this surface is (Floor.strain_of(), a share of
# max_support_weight; over 1 = what is being carried over it would break it).
var _strain: float = 0.0
var walkable: bool = false           # a rug: on the floor, but walked over (see Floor pathing)
# Hangs at the ceiling (a skylight): it takes no floor, stands over whatever is
# below it (its z range starts at the ceiling), and lights its own tiles from
# above, which nothing on the floor can shade (see Floor._compute_light_map).
var overhead: bool = false
# A screen hides what is behind it without darkening the room: reeded glass,
# a curtain. It stops a line of sight and divides zones like tall storage
# does, but daylight passes it. "screen_when": "extended" makes that true
# only while the piece is unfolded (a curtain drawn across).
var screen: bool = false
var screen_when: String = "always"
# A living thing that needs the window: it gives nothing while it stands in
# the dark (see _daylight_starved, set by Main), and its noise reaches further
# than a machine's (noise_radius, in tiles; 0 = the usual touching-only rule).
var needs_daylight: bool = false
var noise_radius: int = 0
var _daylight_starved: bool = false
var front: String = "any"            # side it is used from: any | long | short | n | e | s | w

# Mobility tier — how hard THIS piece is for the tenant to reposition, an
# entirely separate concept from the structural `weight` above (that one
# gates mezzanine/surface load, this one gates comfort/per-moment movement).
# "green" = freely movable, no penalty. "yellow" = movable but uncomfortable
# (see GameManager.comfort_pct). "red" = default for most furniture (sofas,
# beds, wardrobes, appliances) — shares ONE position across every Moment
# instead of getting its own per-Moment slot, exactly like ordinary furniture
# already behaves today; the exception is a red piece that's ALSO on a rail,
# which keeps sliding per-Moment same as rails always have (see moment_positions).
var mobility_tier: String = "red"
# Authored spawn position — set once in Main._spawn_furniture(), re-derived
# every time a piece is spawned (initial load, undo/redo, nested-level
# snapshot restore) so it needs no snapshot/persistence plumbing of its own.
# Comfort is current-state based: a yellow piece sitting away from this
# position costs comfort; moved back, comfort recovers.
var _home_grid_pos: Vector2 = Vector2(-1, -1)

# Nested/parabox levels: this piece is a "box" whose interior is a whole
# other apartment (see docs/design_nested_levels.md). A single click or a
# drag still treats it as ordinary furniture, so it can be repositioned and
# rotated without accidentally stepping inside; a DOUBLE-click enters it
# (see _input, and Room3DView for the 3D equivalent). Main.gd's apartment
# map (NestedMap) can also jump straight to any box's interior.
# A keepsake cannot be sold: the tenant won't part with it (an inherited
# wardrobe, a streamer's freezers). It can still be moved, rotated and
# folded like anything else — the puzzle is living around it. Set per piece
# in a level's starting_furniture ("keepsake": true), never in the catalogue.
var keepsake: bool = false
var is_nested_box: bool = false
# A box's inside as a little plan of itself, drawn on the box in place of its
# picture: {segments, bounds, furniture}, the same data BlueprintPreview takes.
# Set by Main (_recompute_box_effects); {} draws the box as a plain piece.
var interior_plan: Dictionary = {}:
	set(v):
		interior_plan = v
		queue_redraw()
var child_level_id: String = ""
# How much everything currently inside this box's child level weighs,
# combined — Main._recompute_box_effects() keeps this current whenever the
# child level's contents change (or are first read from disk, if never
# visited this session). A heavily-furnished shoebox gets harder to move
# (mobility_tier escalates) and harder to stack elsewhere (weight rises)
# than an empty one — current-state, not permanent: empty it back out and
# both recover, same philosophy as comfort.
var interior_weight: float = 0.0
const BOX_WEIGHT_YELLOW_MIN := 50.0
const BOX_WEIGHT_RED_MIN    := 150.0
# Catalog-authored baseline, captured once in setup() so apply_interior_weight()
# can always recompute from a stable starting point instead of compounding
# onto whatever the previous recompute already left behind.
var _base_weight: float = 1.0
var _base_mobility_tier: String = "red"

# Noise — a separate cross-level coupling from the light/occlusion one above.
# is_noisy (TVs, radios, kitchen appliances) and needs_quiet (beds) are
# catalog-authored; _noise_muted is live, computed-only state Main.gd sets:
# true while a needs_quiet piece sits near a noisy neighbor (an is_noisy
# piece in the same room, OR — for a piece just inside a box — an is_noisy
# piece in the PARENT room near the box's own position; symmetrically, a
# noisy box interior can mute a needs_quiet piece sitting near the box in
# the PARENT). A muted piece simply stops contributing its functions (see
# GameManager._functions_of()) until it's no longer near the source.
var is_noisy: bool = false
var needs_quiet: bool = false
var _noise_muted: bool = false
# What the noise comes from (a piece's name, here or outside the box), for
# saying why a bed stopped working; and whether this piece is keeping
# something from working right now. Both live, set with _noise_muted.
var _noise_by: String = ""
var _noise_making: bool = false
# A box only: how much daylight gets in (Main._compute_box_occlusion(), 1 =
# all of it), drawn as shade over it on the plan and as dimmer windows in 3D.
var _shade: float = 1.0


# Applies this box's current interior weight — combines it with the box's
# OWN catalog weight for anything that reads `weight` (stacking capacity,
# mezzanine load), and escalates mobility_tier as interior weight climbs
# past the thresholds above. Only meaningful for is_nested_box pieces;
# harmless no-op otherwise. `shrink` is how much the fax shrank what is
# inside (the box's footprint over the apartment's floor, see
# Main._box_shrink()): the furniture in there weighs that much less out here,
# so a furnished box still fits on a sturdy table but not on a flimsy one.
# The mobility thresholds keep reading the full interior weight.
func apply_interior_weight(w: float, shrink: float = 1.0) -> void:
	interior_weight = w
	weight = _base_weight + w * shrink
	if not is_nested_box:
		return
	var tier := Furniture.box_tier(w, _base_mobility_tier)
	if tier != mobility_tier:
		mobility_tier = tier
		queue_redraw()


# The mobility tier of a box holding `interior` worth of furniture (see the
# thresholds above), starting from `base` when it is nearly empty.
static func box_tier(interior: float, base: String) -> String:
	if interior >= BOX_WEIGHT_RED_MIN:
		return "red"
	if interior >= BOX_WEIGHT_YELLOW_MIN:
		return "yellow"
	return base

# A catalogue piece's weight: its own "weight", else its footprint in tiles
# (the same default setup() gives `weight`).
static func catalog_weight(fdata: Dictionary) -> float:
	var sz := fdata.get("size", {}) as Dictionary
	return fdata.get("weight", float((sz.get("w", 4) as int) * (sz.get("h", 4) as int))) as float


# How many floor tiles a level's apartment has, over its floors and lofts
# (a floor with no painted tiles counts its whole grid).
static func level_floor_tiles(level: Dictionary) -> int:
	var apt := level.get("apartment", {}) as Dictionary
	var gw := apt.get("grid_w", 0) as int
	var gh := apt.get("grid_h", 0) as int
	var total := 0
	for fd in apt.get("floors", []) as Array:
		var fdata := fd as Dictionary
		if fdata.get("type", "floor") as String not in ["floor", "loft"]:
			continue
		var tiles := fdata.get("floor_tiles", []) as Array
		total += tiles.size() if not tiles.is_empty() else gw * gh
	return total


# How much the fax shrank `level` to fit a box `box_w` x `box_h` tiles: the
# box's footprint over the apartment's floor. What is inside weighs that much
# less out here (see apply_interior_weight()).
static func box_shrink(box_w: int, box_h: int, level: Dictionary) -> float:
	var inner := level_floor_tiles(level)
	if inner <= 0:
		return 1.0
	return clampf(float(box_w * box_h) / inner, 0.0, 1.0)


# Rail: constrains dragging to one axis within a defined extent. rail_axis
# itself is LIVE (Ctrl-drag clears it to detach) — _home_rail_* is the
# catalog's original value, kept around forever so a detached piece can
# still be Ctrl-dragged back onto its rail later instead of losing the
# ability for good.
var rail_axis:  String = ""   # "h" | "v" | "" = free
var rail_start: int    = -1   # first valid tile offset along the rail (-1 = unclamped)
var rail_end:   int    = -1   # last valid tile offset along the rail
var _rail_lock: float  = -1.0   # locked row (h) or column (v) set on drag start
var _home_rail_axis:  String = ""
var _home_rail_start: int    = -1
var _home_rail_end:   int    = -1
var _rail_ctrl_latch: bool   = false   # true while Ctrl has already triggered one attach/detach this press — see _drag()

# Rail + moments: a rail piece can be slid into a "reveal zone" (a sub-range
# along its own rail) to grant extra functions while it sits there — e.g. a
# wardrobe pulled out of its hidden dock to fulfill "dress" during one moment,
# then slid back out of the way for another. Like moment_fold_state, each
# moment remembers its OWN position independently.
var reveal_start:     int    = -1   # rail-local coord where the reveal zone begins (-1 = none)
var reveal_end:       int    = -1   # rail-local coord where the reveal zone ends
var reveal_functions: Array  = []   # extra functions granted while inside the reveal zone
# moment_id -> Vector2 grid_pos left by the player for that specific moment.
# Originally rail-only; now written for ANY non-red-tier piece too (see
# mobility_tier) — a green/yellow piece can sit somewhere different in "Day"
# than in "Night", same mechanism a rail piece already used to slide per
# moment, just without the axis clamp for non-rail pieces. A red, non-rail
# piece never gets an entry here — it keeps exactly one shared grid_pos.
var moment_positions: Dictionary = {}

static var test_mode_active: bool = false
# Set by Main.gd for the post-win "View Apartment" free-look mode — the level
# is already rented out and scored, so nothing should be draggable/sellable/
# placeable anywhere in the 2D views. Mirrors Room3DView.read_only.
static var read_only: bool = false
var _extended_conflict: bool = false
var _rail_flash_t: float = 0.0            # 1.0 -> 0.0 over RAIL_FLASH_DURATION, driven by a Tween
var _rail_flash_color: Color = Color.WHITE

var _dragging: bool = false
var _placement_mode: bool = false   # true while waiting for initial click-to-place
var _drag_offset: Vector2 = Vector2.ZERO
var _original_pos: Vector2 = Vector2.ZERO
var _landing_key := Vector3.INF   # tile and turn _landing was worked out for, while dragged
var _landing := Vector2.INF       # where it would land if let go now (Floor.landing_spot); INF: nowhere
var _landing_why := ""            # why it would land nowhere
var _press_ms := 0                       # when the current press began, for a touch long-press
var _press_moved := false                # the pointer has left the press spot since
# Main's handler for a touch long-press on a piece (TouchControls shows its
# actions: rotate, fold, sell).
static var on_long_press: Callable
var _press_pos: Vector2 = Vector2.ZERO   # viewport-space position at mouse-down, for click-vs-drag detection
const CLICK_MOVE_THRESHOLD := 10.0       # px; below this, a release counts as a click, not a drag — 4px was tight enough that an ordinary click's natural hand jitter routinely misfired as "moved it", especially when the intent was just to fold/unfold
var _wall_ref: Floor = null
var _color: Color = Color.WHITE
var _accessible: bool = true

# Real orthographic top-down render of this item's own 3D model (via the
# Thumb autoload) — fetched once in setup() and drawn in place of the hand-
# authored _draw_symbol() once it arrives, so the Floor Plan shows the
# item's actual shape instead of a generic symbol. Left null (falls back to
# _draw_symbol) until the async fetch resolves.
var _topdown_icon: Texture2D = null

# Brief "why did that fail" bubble shown after a rejected drop, once the ✗
# glyph and its live reason (drawn only while _dragging) are both gone —
# without this, a failed drop just silently snapped back with an error beep
# and no lasting explanation.
var _error_reason: String = ""
var _error_flash_t: float = 0.0
const ERROR_FLASH_DURATION := 1.4

# Same fading bubble, but for a neutral heads-up rather than a rejection —
# used when a red (heavy) piece is successfully moved, to remind the player
# that move applies to every Moment at once (it has no per-Moment slot of
# its own, see mobility_tier/has_own_moment_position()).
var _notice_reason: String = ""
var _notice_flash_t: float = 0.0
const NOTICE_FLASH_DURATION := 3.0

# Keep rect reference for mouse-over size lookup; hidden visually.
@onready var rect: ColorRect = $ColorRect
@onready var label: Label = $ColorRect/Label


func setup(data: Dictionary, apt_floor: Floor) -> void:
	furniture_id = data["id"]
	furniture_name = data["name"]
	grid_w = data["size"]["w"]
	grid_h = data["size"]["h"]
	functions = data["functions"].duplicate()
	buy_price = data["buy_price"]
	sell_price = data["sell_price"]
	ghost_radius          = data.get("ghost_radius",      0)        as int
	foldable              = data.get("foldable",          false)    as bool
	extended_add_h        = data.get("extended_add_h",    0)        as int
	folded_functions_arr  = (data.get("folded_functions",   []) as Array).duplicate()
	extended_functions_arr = (data.get("extended_functions", []) as Array).duplicate()
	# A foldable piece starts folded (is_extended = false); its live .functions
	# must reflect that from the start, not the full base list, so moment/need
	# checks don't count a state the player hasn't actually set yet.
	if foldable:
		functions = folded_functions_arr.duplicate()
	height_category       = data.get("height_category",   "medium") as String
	z_bottom = data.get("z_bottom", 0.0) as float
	match height_category:
		"low":  z_top = data.get("z_top",  6.0) as float
		"tall": z_top = data.get("z_top", 24.0) as float
		_:      z_top = data.get("z_top", 12.0) as float
	needs_water           = data.get("needs_water",       false)    as bool
	needs_power           = data.get("needs_power",       false)    as bool
	zone_divider          = data.get("zone_divider",      false)    as bool
	floor_category        = data.get("floor_category",    "any")    as String
	# Was derived straight from "animated_fold" — fine while balcony_window
	# was the only animated_fold item and also the only one that needed
	# wall-adjacency, but a floor-standing animated piece (a sofa bed, say)
	# must NOT require touching a wall just because it has a real animation
	# instead of the swap-crossfade. Explicit field now.
	wall_flush_required   = data.get("wall_flush_required", false)   as bool
	rail_axis             = data.get("rail_axis",         "")       as String
	rail_start            = data.get("rail_start",        -1)       as int
	rail_end              = data.get("rail_end",          -1)       as int
	_home_rail_axis       = rail_axis
	_home_rail_start      = rail_start
	_home_rail_end        = rail_end
	reveal_start          = data.get("reveal_start",      -1)       as int
	reveal_end            = data.get("reveal_end",        -1)       as int
	reveal_functions      = (data.get("reveal_functions", []) as Array).duplicate()
	is_stair              = data.get("is_stair",          false)    as bool
	stair_direction       = data.get("stair_direction",   "")       as String
	weight                = data.get("weight", float(grid_w * grid_h)) as float
	is_surface            = data.get("is_surface",        false)    as bool
	max_support_weight    = data.get("max_support_weight", 0.0)     as float
	requires_surface      = data.get("requires_surface",  false)    as bool
	body_h                = data.get("wall_h",            8.0)      as float
	walkable              = data.get("walkable",          false)    as bool
	overhead              = data.get("overhead",          false)    as bool
	screen                = data.get("screen",            false)    as bool
	screen_when           = data.get("screen_when",       "always") as String
	needs_daylight        = data.get("needs_daylight",    false)    as bool
	noise_radius          = data.get("noise_radius",      0)        as int
	front                 = data.get("front",             "any")    as String
	mobility_tier         = data.get("mobility_tier",     "red")    as String
	is_nested_box         = data.get("is_nested_box",     false)    as bool
	keepsake              = data.get("keepsake",          false)    as bool
	child_level_id        = data.get("child_level_id",    "")       as String
	is_noisy              = data.get("is_noisy",          false)    as bool
	needs_quiet           = data.get("needs_quiet",       false)    as bool
	_base_weight          = weight
	_base_mobility_tier   = mobility_tier
	_base_grid_h          = grid_h
	_wall_ref = apt_floor
	_color = Color("#" + data.get("color", "888888"))

	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	rect.visible = false  # drawing handled in _draw()

	queue_redraw()
	_fetch_topdown_icon(data)


func _fetch_topdown_icon(data: Dictionary) -> void:
	var cached := Thumb.get_cached_ortho("top", furniture_id)
	if cached:
		_topdown_icon = Furniture.in_pencil(cached)
		queue_redraw()
		return
	var tex: Texture2D = await Thumb.get_topdown_icon_async(data)
	if is_instance_valid(self) and tex:
		_topdown_icon = Furniture.in_pencil(tex)
		queue_redraw()


# The plan is a black-and-white sheet: a piece's top-down picture goes on it
# in pale greys, as if drawn in pencil, keeping its shape and shading but not
# its colours. Made once per picture.
static var _pencil: Dictionary = {}   # source texture's RID -> greyed copy

static func in_pencil(tex: Texture2D) -> Texture2D:
	var key := tex.get_rid()
	if _pencil.has(key):
		return _pencil[key]
	var img := tex.get_image()
	if img == null:
		return tex
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var g := lerpf(c.r * 0.30 + c.g * 0.59 + c.b * 0.11, 1.0, 0.55)
			img.set_pixel(x, y, Color(g, g, g, c.a))
	var out := ImageTexture.create_from_image(img)
	_pencil[key] = out
	return out


# A piece's fill on the white plan: light grey, a hint of its own colour.
static func paper_fill(own: Color) -> Color:
	return Color("ececec").lerp(own, 0.15)


func _screen_up() -> bool:
	return screen and (screen_when != "extended" or is_extended)


# Stops a line of sight: tall furniture, or a screen that is up.
func blocks_sight() -> bool:
	if screen:
		return _screen_up()
	return height_category == "tall"


# Stops daylight: tall furniture, but never a screen.
func blocks_light() -> bool:
	return height_category == "tall" and not screen


# Splits the floor into zones: tall storage, or a screen that is up.
func divides_zone() -> bool:
	if screen:
		return zone_divider and _screen_up()
	return zone_divider


func set_accessible(is_accessible: bool) -> void:
	if _accessible != is_accessible:
		_accessible = is_accessible
		queue_redraw()


func set_extended_conflict(conflict: bool) -> void:
	_extended_conflict = conflict
	queue_redraw()


func toggle_fold() -> bool:
	if not foldable or extended_add_h <= 0 or not _wall_ref:
		return false
	var want_extended := not (moment_fold_state.get(active_moment_id, false) as bool)
	if not _apply_fold_state(want_extended):
		return false
	moment_fold_state[active_moment_id] = want_extended
	_play("fold")
	fold_toggled.emit()
	return true


# A red (heavy) piece shares ONE position across every Moment, exactly like
# ordinary furniture always has — UNLESS it's also on a rail, which keeps
# sliding per-Moment same as rails always have. Every other tier (green/
# yellow) always gets its own per-Moment slot. See `moment_positions`.
func has_own_moment_position() -> bool:
	return mobility_tier != "red" or rail_axis != ""


# Re-applies whatever fold state THIS moment remembers (independent from
# whatever other moments are currently set to), and — for any piece that
# has_own_moment_position() — snaps it back to wherever the player left it
# for THIS moment specifically. Called when the player switches which moment
# they're viewing.
func set_moment_view(moment_id: String) -> void:
	if foldable:
		var want_extended: bool = moment_fold_state.get(moment_id, false) as bool
		if want_extended != is_extended:
			if not _apply_fold_state(want_extended):
				_apply_fold_state(false)  # doesn't fit here anymore — fall back to folded
	# Defaults to its current/spawn position the first time a moment is seen.
	if has_own_moment_position() and moment_positions.has(moment_id):
		var target: Vector2 = moment_positions[moment_id]
		if target != grid_pos and _wall_ref:
			_wall_ref.place_furniture(self, target)
			position = target * TILE_SIZE
			queue_redraw()


# True when `pos` (a grid position along this piece's own rail) sits inside
# its reveal zone — e.g. an armario pulled out of its hidden dock.
func _is_revealed_at(pos: Vector2) -> bool:
	if rail_axis == "" or reveal_start < 0 or reveal_end < 0:
		return false
	var coord := pos.x if rail_axis == "h" else pos.y
	return coord >= reveal_start and coord <= reveal_end


# Functions this piece contributes for a given moment, based on that moment's
# OWN stored fold state / rail position — independent of whichever moment is
# on screen right now.
func functions_for_moment(moment_id: String) -> Array:
	if foldable:
		var extended: bool = moment_fold_state.get(moment_id, false) as bool
		return extended_functions_arr if extended else folded_functions_arr
	if rail_axis != "" and not reveal_functions.is_empty():
		var pos: Vector2 = moment_positions.get(moment_id, grid_pos) as Vector2
		if _is_revealed_at(pos):
			var out := functions.duplicate()
			for fn in reveal_functions:
				if fn not in out:
					out.append(fn)
			return out
	return functions


func _apply_fold_state(want_extended: bool) -> bool:
	if want_extended:
		# Try to extend: check for space in the extra rows
		grid_h = _base_grid_h + extended_add_h
		if not _wall_ref.can_place(self, grid_pos):
			grid_h = _base_grid_h   # restore — no room
			return false
		is_extended = true
		functions = extended_functions_arr.duplicate()
		_wall_ref.place_furniture(self, grid_pos)
	else:
		# Fold back: shrink footprint
		grid_h = _base_grid_h
		is_extended = false
		functions = folded_functions_arr.duplicate()
		_wall_ref.place_furniture(self, grid_pos)
	rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()
	return true


func _process(delta: float) -> void:
	# Keep the drag validity tint pulsing while a piece is held
	if _dragging:
		queue_redraw()
		# A finger held still on a piece: not a move but a request for its
		# actions (what right-click and R do with a mouse).
		if TouchControls.active and not _placement_mode and not _press_moved \
				and Time.get_ticks_msec() - _press_ms > TouchControls.LONG_PRESS_MS:
			cancel_drag()
			if Furniture.on_long_press.is_valid():
				Furniture.on_long_press.call(self)
	if _error_flash_t > 0.0:
		_error_flash_t -= delta
		if _error_flash_t <= 0.0:
			_error_flash_t = 0.0
			_error_reason = ""
		queue_redraw()
	if _notice_flash_t > 0.0:
		_notice_flash_t -= delta
		if _notice_flash_t <= 0.0:
			_notice_flash_t = 0.0
			_notice_reason = ""
		queue_redraw()


func _draw() -> void:
	var w := grid_w * TILE_SIZE
	var h := grid_h * TILE_SIZE
	# On the white sheet: a light grey fill (with a hint of the piece's own
	# colour, so pieces still read apart in a packing puzzle) and a black
	# outline, its picture in pencil greys (in_pencil).
	var ink := GridDraw.PLAN_INK

	# rot_steps cycles 0..3 in quarter turns; grid_w/grid_h already swap every
	# single step (for collision/footprint), so at odd steps the "canonical"
	# (pre-rotation) size is the swapped-back w/h — this is what lets us spin
	# the fixed-orientation symbol art around its own footprint instead of
	# just squish-fitting it, so 180° actually reads as inverted rather than
	# looking identical to 0°.
	if overhead:
		_draw_overhead(float(w), float(h), ink)
		return

	var cw := float(w if rot_steps % 2 == 0 else h)
	var ch := float(h if rot_steps % 2 == 0 else w)
	var theta := deg_to_rad(rot_steps * 90.0)
	var origin := Vector2(w, h) * 0.5 - Vector2(cw, ch).rotated(theta) * 0.5
	var parts := _body_parts(float(w), float(h))
	if is_nested_box and parts.size() == 1 and _has_interior_plan():
		_draw_mini_plan(float(w), float(h), cw, ch, theta, ink)
	elif parts.size() > 1:
		_draw_split_body(parts, origin, theta, Vector2(cw, ch), ink)
	else:
		_draw_body(origin, theta, cw, ch, ink)

	# Reset so everything below (label, overlays, cotes) stays axis-aligned —
	# only the fill/hatch/symbol need to actually spin.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_overlays(w, h, ink, parts)


func _has_interior_plan() -> bool:
	var b: Rect2 = interior_plan.get("bounds", Rect2())
	return b.size.x > 0.0 and b.size.y > 0.0


# A box seen from the apartment it stands in: the apartment inside it, as a
# small plan of itself (walls and furniture), turned with the box.
func _draw_mini_plan(w: float, h: float, cw: float, ch: float, theta: float, ink: Color) -> void:
	var b: Rect2 = interior_plan["bounds"]
	draw_rect(Rect2(0, 0, w, h), GridDraw.PLAN_PAPER)
	var pad := 3.0
	var s := minf((cw - pad * 2.0) / b.size.x, (ch - pad * 2.0) / b.size.y)
	var c := b.get_center()
	draw_set_transform(Vector2(w, h) * 0.5, theta, Vector2.ONE)
	for fd in interior_plan.get("furniture", []) as Array:
		var r := Rect2((Vector2(fd["x"], fd["y"]) - c) * s, Vector2(fd["w"], fd["h"]) * s)
		draw_rect(r, Furniture.paper_fill(fd.get("color", Color.GRAY) as Color))
		draw_rect(r, GridDraw.PLAN_INK_SOFT, false, 0.5)
	var wall := clampf(s * 1.2, 0.75, 2.0)
	for sg in interior_plan.get("segments", []) as Array:
		var d := sg as Dictionary
		var p1 := (Vector2(d.get("x1", 0.0) as float, d.get("y1", 0.0) as float) - c) * s
		var p2 := (Vector2(d.get("x2", 0.0) as float, d.get("y2", 0.0) as float) - c) * s
		draw_line(p1, p2, ink, wall)
	if (interior_plan.get("segments", []) as Array).is_empty():
		draw_rect(Rect2((b.position - c) * s, b.size * s), ink, false, wall)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_rect(Rect2(0, 0, w, h), ink, false, 1.0)


# Where the piece's body is drawn, in its own pixels: [{dst: Rect2, src:
# Rect2}], src being that part of the piece as if nothing wrapped. Just the
# piece itself, except across a seam of a looped floor (LoopSeams), where
# the part past the seam is drawn at the opening opposite.
func _body_parts(w: float, h: float) -> Array:
	var whole := [{"dst": Rect2(0, 0, w, h), "src": Rect2(0, 0, w, h)}]
	if _wall_ref == null or _wall_ref.loop == null:
		return whole
	var corner := position / TILE_SIZE
	var cut := _wall_ref.loop.split_rect(Rect2(corner, Vector2(grid_w, grid_h)))
	if cut.size() < 2:
		return whole
	var out: Array = []
	for p in cut:
		var r: Rect2 = p["rect"]
		var shift: Vector2 = p["shift"]
		var dst := Rect2((r.position - corner) * TILE_SIZE, r.size * TILE_SIZE)
		out.append({"dst": dst, "src": Rect2(dst.position - shift * TILE_SIZE, dst.size)})
	return out


# A piece across a seam: each part filled, hatched and outlined where it is
# drawn, with its share of the top-down render. The cut edges are dashed.
func _draw_split_body(parts: Array, origin: Vector2, theta: float, canon: Vector2, ink: Color) -> void:
	var hatch := Color(ink.r, ink.g, ink.b, 0.07)
	for part in parts:
		var dst: Rect2 = part["dst"]
		var src: Rect2 = part["src"]
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_rect(dst, Furniture.paper_fill(_color))
		var hd := 6.0
		while hd < dst.size.x + dst.size.y:
			draw_line(dst.position + Vector2(maxf(0.0, hd - dst.size.y), minf(hd, dst.size.y)),
				dst.position + Vector2(minf(hd, dst.size.x), maxf(0.0, hd - dst.size.x)), hatch, 1.0, true)
			hd += 6.0
		if _topdown_icon:
			# The bit of the (turned) render that falls in this part.
			var a := (src.position - origin).rotated(-theta)
			var b := (src.end - origin).rotated(-theta)
			var creg := Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs())
			var tex := Vector2(_topdown_icon.get_size())
			draw_set_transform(origin + dst.position - src.position, theta, Vector2.ONE)
			draw_texture_rect_region(_topdown_icon, creg,
				Rect2(creg.position / canon * tex, creg.size / canon * tex))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# Outline: solid where it is the piece's own edge, dashed where the
		# seam cuts it.
		var full := Rect2(Vector2.ZERO, Vector2(grid_w, grid_h) * TILE_SIZE)
		var c := [src.position, Vector2(src.end.x, src.position.y), src.end, Vector2(src.position.x, src.end.y)]
		for i in 4:
			var p0: Vector2 = c[i]
			var p1: Vector2 = c[(i + 1) % 4]
			var own := (is_equal_approx(p0.x, p1.x) and (is_equal_approx(p0.x, full.position.x) or is_equal_approx(p0.x, full.end.x))) \
				or (is_equal_approx(p0.y, p1.y) and (is_equal_approx(p0.y, full.position.y) or is_equal_approx(p0.y, full.end.y)))
			var d := dst.position - src.position
			if own:
				draw_line(p0 + d, p1 + d, ink, 1.5)
			else:
				draw_dashed_line(p0 + d, p1 + d, Color(0.45, 0.80, 1.0, 0.95), 1.5, 3.0)


func _draw_body(origin: Vector2, theta: float, cw: float, ch: float, ink: Color) -> void:
	draw_set_transform(origin, theta, Vector2.ONE)

	draw_rect(Rect2(0, 0, cw, ch), Furniture.paper_fill(_color))
	# Subtle 45° drafting hatch over the fill — keeps the per-item colour
	# legible while making pieces read as drawn linework, not paint blocks.
	var hatch := Color(ink.r, ink.g, ink.b, 0.07)
	var hd := 6.0
	while hd < cw + ch:
		draw_line(Vector2(maxf(0.0, hd - ch), minf(hd, ch)),
			Vector2(minf(hd, cw), maxf(0.0, hd - cw)), hatch, 1.0, true)
		hd += 6.0
	draw_rect(Rect2(0, 0, cw, ch), ink, false, 1.5)

	# Real top-down render of the item's own 3D model once it's arrived (see
	# _fetch_topdown_icon) — shows its actual shape instead of a hand-authored
	# symbol. Falls back to the symbol while the render is still in flight.
	if _topdown_icon:
		draw_texture_rect(_topdown_icon, Rect2(0, 0, cw, ch), false)
	else:
		_draw_symbol(int(cw), int(ch), ink)


func _draw_overlays(w: int, h: int, ink: Color, parts: Array) -> void:
	# Across a seam: name, badges and marks go on the part that holds the
	# piece's corner, not out past the wall.
	if parts.size() > 1:
		for part in parts:
			var dst: Rect2 = part["dst"]
			if dst.position == Vector2.ZERO:
				w = int(dst.size.x)
				h = int(dst.size.y)
	if is_surface:
		_draw_strain(float(w), float(h))
	if is_nested_box and _shade < 0.99:
		_draw_shade(float(w), float(h))
	if is_nested_box:
		_draw_packing(float(w), float(h))
	if _noise_making:
		_draw_noise(float(w), float(h), Color(0.98, 0.70, 0.22))
	if needs_quiet and _noise_muted:
		_draw_kept_awake(float(w), float(h))

	# Name label: dark ink with a light halo. The piece's own ink colour is
	# close to its fill and to the white of its symbol, which left names like
	# "Bathtub" all but invisible.
	# A keepsake wears a heart after its name, so it is recognisable before
	# the player tries to sell it.
	var shown_name := (furniture_name + " \uf67c") if keepsake else furniture_name
	draw_string_outline(ThemeDB.fallback_font, Vector2(3, 9), shown_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7, 3, Color(1, 1, 1, 0.90))
	draw_string(ThemeDB.fallback_font, Vector2(3, 9), shown_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7, GameTheme.NAVY)

	# Mobility tier badge — a small always-visible dot in the corner (color
	# alone reads at any size) plus the feather-count text once there's room
	# for it to actually be legible. Without this, a placed piece's tier was
	# only ever shown in the shop tooltip before buying it — once on the
	# floor, there was no way to tell why moving it behaves the way it does.
	var tier_col: Color
	match mobility_tier:
		"green":  tier_col = Color("7fcf9d")
		"yellow": tier_col = Color("f2c14e")
		_:        tier_col = GameTheme.RED
	const BADGE_R := 3.0
	draw_circle(Vector2(w - BADGE_R - 3.0, BADGE_R + 3.0), BADGE_R, tier_col)
	var feathers := "\uee8b" if mobility_tier == "green" else ("\uee8b\uee8b" if mobility_tier == "yellow" else "\uee8b\uee8b\uee8b")
	var ffont := ThemeDB.fallback_font
	const FSIZE := 8
	var ftw := ffont.get_string_size(feathers, HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE).x
	# Feathers only where they fit beside the name: on a narrow piece they
	# were drawn straight over it ("Toilet", "Sink"). The dot alone carries
	# the same information.
	var name_w := ffont.get_string_size(furniture_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 7).x
	if w >= maxf(40.0, name_w + ftw + BADGE_R * 2 + 16.0):
		draw_string(ffont, Vector2(w - BADGE_R * 2 - 6.0 - ftw, BADGE_R * 2 + 6.0), feathers,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE, tier_col)

	# Ghost interaction zone — dashed amber outline shown while dragging
	if _dragging and ghost_radius > 0:
		var gr  := ghost_radius * TILE_SIZE
		var gc  := Color(0.95, 0.78, 0.22, 0.60)
		var pts := [Vector2(-gr, -gr), Vector2(w + gr, -gr),
					Vector2(w + gr, h + gr), Vector2(-gr, h + gr), Vector2(-gr, -gr)]
		for i in range(pts.size() - 1):
			draw_dashed_line(pts[i], pts[i + 1], gc, 1.2, 4.0)
		draw_rect(Rect2(-gr, -gr, w + gr * 2, h + gr * 2), Color(0.95, 0.78, 0.22, 0.04))

	# Foldable states
	if foldable and extended_add_h > 0:
		var ext_h := extended_add_h * TILE_SIZE
		if is_extended:
			# Show fold boundary line so user knows the base footprint
			var base_y := float(_base_grid_h * TILE_SIZE)
			draw_dashed_line(Vector2(0, base_y), Vector2(w, base_y),
				Color(ink.r, ink.g, ink.b, 0.50), 1.0, 4.0)
			# Double-click hint
			draw_string(ThemeDB.fallback_font, Vector2(3, base_y + 8),
				tr("▲ FOLD"), HORIZONTAL_ALIGNMENT_LEFT, w - 6, 6,
				Color(ink.r, ink.g, ink.b, 0.55))
		else:
			# Dashed preview of extended zone (not currently extended) — shown
			# any time this piece isn't extended, not just in Test Layout,
			# since click-to-fold now works all the time too.
			var ec    := Color(0.88, 0.10, 0.10, 0.45) if _extended_conflict else Color(0.60, 0.82, 0.98, 0.20)
			var ec_bd := Color(0.88, 0.10, 0.10, 0.85) if _extended_conflict else Color(0.66, 0.86, 1.00, 0.75)
			draw_rect(Rect2(0, h, w, ext_h), ec)
			draw_dashed_line(Vector2(0, h),         Vector2(w, h),         ec_bd, 1.5, 5.0)
			draw_dashed_line(Vector2(0, h),         Vector2(0, h + ext_h), ec_bd, 1.0, 4.0)
			draw_dashed_line(Vector2(w, h),         Vector2(w, h + ext_h), ec_bd, 1.0, 4.0)
			draw_dashed_line(Vector2(0, h + ext_h), Vector2(w, h + ext_h), ec_bd, 1.5, 5.0)
			draw_string(ThemeDB.fallback_font, Vector2(3, h + 9),
				tr("▼ CLICK TO UNFOLD"), HORIZONTAL_ALIGNMENT_LEFT, w - 6, 6,
				Color(ec_bd.r, ec_bd.g, ec_bd.b, 0.70))

	# Rail attach/detach flash — a brief expanding, fading ring at the moment
	# the state actually changes (see _flash_rail), separate from the
	# small persistent arrow glyphs below which only show the CURRENT state
	# and were too easy to miss changing.
	if _rail_flash_t > 0.0:
		var grow := 1.0 + (1.0 - _rail_flash_t) * 0.6
		var fc := Color(_rail_flash_color.r, _rail_flash_color.g, _rail_flash_color.b, _rail_flash_color.a * _rail_flash_t)
		var fw := w * grow
		var fh := h * grow
		draw_rect(Rect2((w - fw) * 0.5, (h - fh) * 0.5, fw, fh), fc, false, 2.5)

	# Rail axis indicators (small arrows at edges)
	if rail_axis == "h":
		var mid_y := h * 0.5
		var rc := Color(0.55, 0.55, 0.65, 0.85)
		draw_line(Vector2(-7, mid_y), Vector2(-2, mid_y), rc, 1.2)
		draw_line(Vector2(-7, mid_y), Vector2(-4, mid_y - 3), rc, 1.2)
		draw_line(Vector2(-7, mid_y), Vector2(-4, mid_y + 3), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 2, mid_y), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 4, mid_y - 3), rc, 1.2)
		draw_line(Vector2(w + 7, mid_y), Vector2(w + 4, mid_y + 3), rc, 1.2)
		if _dragging and _wall_ref:
			var left_b := 0                        if rail_start < 0 else rail_start
			var right_b := _wall_ref.grid_w - grid_w if rail_end   < 0 else rail_end
			var lx := float((grid_pos.x - left_b)  * TILE_SIZE)
			var rx := float((right_b - grid_pos.x)  * TILE_SIZE)
			if lx > 0:
				draw_dashed_line(Vector2(-lx, mid_y), Vector2(0, mid_y), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
			if rx > 0:
				draw_dashed_line(Vector2(w, mid_y), Vector2(w + rx, mid_y), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
	elif rail_axis == "v":
		var mid_x := w * 0.5
		var rc := Color(0.55, 0.55, 0.65, 0.85)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x, -2), rc, 1.2)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x - 3, -4), rc, 1.2)
		draw_line(Vector2(mid_x, -7), Vector2(mid_x + 3, -4), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x, h + 2), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x - 3, h + 4), rc, 1.2)
		draw_line(Vector2(mid_x, h + 7), Vector2(mid_x + 3, h + 4), rc, 1.2)
		if _dragging and _wall_ref:
			var top_b := 0                         if rail_start < 0 else rail_start
			var bot_b := _wall_ref.grid_h - grid_h  if rail_end   < 0 else rail_end
			var ty := float((grid_pos.y - top_b) * TILE_SIZE)
			var by := float((bot_b - grid_pos.y)  * TILE_SIZE)
			if ty > 0:
				draw_dashed_line(Vector2(mid_x, -ty), Vector2(mid_x, 0), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)
			if by > 0:
				draw_dashed_line(Vector2(mid_x, h), Vector2(mid_x, h + by), Color(rc.r, rc.g, rc.b, 0.50), 1.0, 4.0)

	# Blocked overlay with X — this reflects the piece's last-settled resting
	# spot (recomputed by Main._update_accessibility on furniture changes), not
	# the live drag position. Showing it while actively dragging made every
	# drag look permanently rejected, since it never matched wherever the
	# ghost currently was; the live ✓/✗ pulse below already covers "can I drop
	# here" during the drag itself.
	# The residents now act an unreachable piece out (TenantLayer._try_to_reach),
	# so this is only the quiet reminder that stays: a dashed red outline and
	# a small "no way in" sign, which a level without residents relies on.
	if not _accessible and not _dragging:
		var red := Color(0.88, 0.16, 0.12, 0.9)
		var pts := [Vector2(1, 1), Vector2(w - 1, 1), Vector2(w - 1, h - 1), Vector2(1, h - 1), Vector2(1, 1)]
		for i in 4:
			draw_dashed_line(pts[i], pts[i + 1], red, 2.0, 4.0)
		var c := Vector2(7, h - 7)
		draw_circle(c, 4.5, Color(1, 1, 1, 0.9))
		draw_arc(c, 4.5, 0.0, TAU, 16, red, 1.5, true)
		draw_line(c + Vector2(-3, 0), c + Vector2(3, 0), red, 1.8)

	# Drag validity tint — soft pulsing sage when the spot is free, terracotta
	# when blocked, so validity reads before the piece is even dropped. The
	# ✓/✗ glyph is a colorblind-safe redundant cue — same shape language the
	# tenant-needs chips already use elsewhere, so it doesn't need its own
	# legend.
	if _dragging and _wall_ref:
		# Let go here, it lands at _landing (Floor.landing_spot): right here,
		# next to here (out of a wall, off another piece), or nowhere.
		var at := Vector2(position.x / TILE_SIZE, position.y / TILE_SIZE)
		var on_floor := Furniture.transfer_hover == 0
		var nudged := on_floor and _landing != Vector2.INF and _landing != at
		var ok := Furniture.transfer_hover == 1 or (on_floor and _landing != Vector2.INF)
		var pulse := 0.14 + 0.06 * sin(Time.get_ticks_msec() * 0.008)
		var green := Color(0.35, 0.80, 0.38, pulse)
		var vc := green if ok else Color(0.90, 0.35, 0.28, pulse + 0.12)
		if nudged:
			vc = Color(0.55, 0.62, 0.70, pulse)   # where it is held: not where it goes
		for part in parts:
			draw_rect(part["dst"] as Rect2, vc)
			draw_rect(part["dst"] as Rect2, Color(vc.r, vc.g, vc.b, 0.85), false, 2.0)
		var glyph_at := Vector2(4, 12)
		if nudged:
			# Where it will land, and a dashed line from the piece to it.
			var off := (_landing - at) * TILE_SIZE
			var land := Rect2(off, Vector2(w, h))
			draw_rect(land, Color(green.r, green.g, green.b, green.a + 0.12))
			draw_rect(land, Color(green.r, green.g, green.b, 0.9), false, 2.5)
			draw_dashed_line(Vector2(w, h) * 0.5, off + Vector2(w, h) * 0.5, Color(0.16, 0.42, 0.18, 0.8), 2.0, 5.0)
			glyph_at += off
		var glyph_col := Color(0.16, 0.42, 0.18, 0.9) if ok else Color(0.55, 0.10, 0.08, 0.9)
		draw_string(ThemeDB.fallback_font, glyph_at,
			"\uea5e" if ok else "\ueb55", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, glyph_col)

		# Say *why* it's blocked, not just that it is — a bare red ✗ never told
		# the player whether it was overlap, wrong floor type, a low ceiling,
		# or another item's clearance zone, so every miss looked identical.
		if not ok and on_floor:
			var reason := _landing_why
			if reason != "":
				var rfont := ThemeDB.fallback_font
				const RSIZE := 10
				var tw := rfont.get_string_size(reason, HORIZONTAL_ALIGNMENT_LEFT, -1, RSIZE).x
				draw_rect(Rect2(0, h + 3, tw + 8, RSIZE + 6), Color(0.08, 0.04, 0.03, 0.88))
				draw_string(rfont, Vector2(4, h + 3 + RSIZE + 1), reason,
					HORIZONTAL_ALIGNMENT_LEFT, -1, RSIZE, Color(1.0, 0.85, 0.80, 0.95))

	# Same reason bubble, but after the fact — a rejected drop snaps back and
	# stops dragging immediately, so without this the player only ever saw an
	# error beep with no lasting explanation of what actually blocked it.
	elif _error_flash_t > 0.0 and _error_reason != "":
		var efont := ThemeDB.fallback_font
		const ERSIZE := 10
		var fade := clampf(_error_flash_t / 0.4, 0.0, 1.0)   # fade out over the last 0.4s
		var etw := efont.get_string_size(_error_reason, HORIZONTAL_ALIGNMENT_LEFT, -1, ERSIZE).x
		draw_rect(Rect2(0, h + 3, etw + 8, ERSIZE + 6), Color(0.08, 0.04, 0.03, 0.88 * fade))
		draw_string(efont, Vector2(4, h + 3 + ERSIZE + 1), _error_reason,
			HORIZONTAL_ALIGNMENT_LEFT, -1, ERSIZE, Color(1.0, 0.85, 0.80, 0.95 * fade))

	# Deliberately more prominent than the error bubble above (bigger text,
	# a border, an icon prefix) — this fires on a SUCCESSFUL move, so there's
	# no red tint or ✗ glyph drawing attention to it the way a rejection
	# gets; without something to make it stand out on its own, "this move
	# quietly affects every Moment" was easy to miss entirely.
	elif _notice_flash_t > 0.0 and _notice_reason != "":
		var nfont := ThemeDB.fallback_font
		const NSIZE := 13
		var nfade := clampf(_notice_flash_t / 0.6, 0.0, 1.0)   # fade out over the last 0.6s
		var ntext := "\ueb13 " + _notice_reason
		var ntw := nfont.get_string_size(ntext, HORIZONTAL_ALIGNMENT_LEFT, -1, NSIZE).x
		var nbg := Color(0.10, 0.12, 0.20, 0.92 * nfade)
		var nrect := Rect2(0, h + 3, ntw + 12, NSIZE + 10)
		draw_rect(nrect, nbg)
		draw_rect(nrect, Color(0.55, 0.72, 0.98, 0.85 * nfade), false, 1.5)
		draw_string(nfont, Vector2(6, h + 3 + NSIZE + 3), ntext,
			HORIZONTAL_ALIGNMENT_LEFT, -1, NSIZE, Color(0.85, 0.92, 1.0, 0.98 * nfade))

	# Architectural dimension cotes while dragging
	if _dragging and _wall_ref:
		_draw_cotes(float(w), float(h))


# A piece up at the ceiling is drawn the way a plan shows what is overhead:
# a dashed outline with its diagonals, so the furniture under it stays
# readable, and a pale wash of the daylight it lets in.
func _draw_overhead(w: float, h: float, ink: Color) -> void:
	draw_rect(Rect2(0, 0, w, h), Color(1.0, 0.96, 0.70, 0.18))
	var c := Color(ink.r, ink.g, ink.b, 0.85)
	var pts := [Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h), Vector2(0, 0)]
	for i in range(pts.size() - 1):
		draw_dashed_line(pts[i], pts[i + 1], c, 1.2, 5.0)
	draw_dashed_line(Vector2(0, 0), Vector2(w, h), Color(c, 0.45), 1.0, 5.0)
	draw_dashed_line(Vector2(w, 0), Vector2(0, h), Color(c, 0.45), 1.0, 5.0)
	draw_string_outline(ThemeDB.fallback_font, Vector2(3, 9), furniture_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7, 3, Color(1, 1, 1, 0.90))
	draw_string(ThemeDB.fallback_font, Vector2(3, 9), furniture_name,
		HORIZONTAL_ALIGNMENT_LEFT, w - 6, 7, GameTheme.NAVY)


func _draw_symbol(w: int, h: int, ink: Color) -> void:
	var s  := Color(ink.r, ink.g, ink.b, 0.48)
	var lw := 1.0

	match furniture_id:
		"normal_bed", "high_bed":
			# Pillow band across the top, centre body line
			var ph := minf(h * 0.28, 18.0)
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph),         Vector2(w - 3, ph), s, lw)
			draw_line(Vector2(w * 0.5, ph + 3), Vector2(w * 0.5, h - 3), s, lw)

		"sofa", "sofa_bed":
			# Thick backrest bar at top, cushion outlines below
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.26), s, false, lw)
			var seat_y := h * 0.30
			var cw     := (w - 6) / 3.0
			for i in range(3):
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), Color(s.r, s.g, s.b, 0.10))
				draw_rect(Rect2(3 + i * cw, seat_y, cw, h - seat_y - 3), s, false, lw)
			if furniture_id == "sofa_bed":
				draw_dashed_line(Vector2(4, h * 0.55), Vector2(w - 4, h * 0.55), s, lw)

		"desk":
			# Desk surface implied by outline; chair seat + arc backrest below
			var ch   := h * 0.28
			var cy   := h - ch - 3.0
			var csz  := minf(w * 0.40, 24.0)
			var cx   := (w - csz) * 0.5
			draw_rect(Rect2(cx, cy, csz, ch), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(cx, cy, csz, ch), s, false, lw)
			# backrest arc
			draw_arc(Vector2(cx + csz * 0.5, cy), csz * 0.5, PI, TAU, 12, s, lw)

		"kitchen":
			# Four hob circles
			var rr := minf(w * 0.10, h * 0.16)
			var pts := [Vector2(w * 0.27, h * 0.35), Vector2(w * 0.73, h * 0.35),
						Vector2(w * 0.27, h * 0.72), Vector2(w * 0.73, h * 0.72)]
			for pt in pts:
				draw_circle(pt, rr * 0.45, Color(s.r, s.g, s.b, 0.15))
				draw_arc(pt, rr, 0, TAU, 14, s, lw)
			# Sink outline (top-right quadrant)
			draw_rect(Rect2(w * 0.55, h * 0.08, w * 0.38, h * 0.22), s, false, lw)

		"wardrobe":
			# Two door panels with handles
			draw_line(Vector2(w * 0.5, 4), Vector2(w * 0.5, h - 4), s, lw)
			draw_circle(Vector2(w * 0.5 - 4, h * 0.50), 1.8, s)
			draw_circle(Vector2(w * 0.5 + 4, h * 0.50), 1.8, s)

		"ottoman":
			# Cushion cross
			draw_line(Vector2(4, h * 0.50), Vector2(w - 4, h * 0.50), s, lw)
			draw_line(Vector2(w * 0.50, 4), Vector2(w * 0.50, h - 4), s, lw)

		"wall_cabinet":
			draw_line(Vector2(w * 0.5, 3), Vector2(w * 0.5, h - 3), s, lw)

		"storage_bed":
			var ph := minf(h * 0.28, 18.0)
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph),           Vector2(w - 3, ph), s, lw)
			draw_line(Vector2(w * 0.5, ph + 3), Vector2(w * 0.5, h - 3), s, lw)
			# Storage drawers at bottom
			var drawer_y := h * 0.72
			draw_rect(Rect2(4, drawer_y, w - 8, h - drawer_y - 3), Color(s.r, s.g, s.b, 0.12))
			draw_line(Vector2(w * 0.5, drawer_y), Vector2(w * 0.5, h - 3), s, lw * 0.7)
			draw_circle(Vector2(w * 0.5 - 6, (drawer_y + h) * 0.5), 1.5, s)
			draw_circle(Vector2(w * 0.5 + 6, (drawer_y + h) * 0.5), 1.5, s)

		"bunk_bed":
			# Lower bunk
			var ph := h * 0.28
			draw_rect(Rect2(3, 3, w - 6, ph - 3), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, ph), Vector2(w - 3, ph), s, lw)
			# Upper bunk divider
			draw_line(Vector2(3, h * 0.5), Vector2(w - 3, h * 0.5), s, lw)
			var ph2 := h * 0.5 + h * 0.14
			draw_rect(Rect2(3, h * 0.5 + 3, w - 6, ph2 - h * 0.5 - 3), Color(s.r, s.g, s.b, 0.14))
			draw_line(Vector2(3, ph2), Vector2(w - 3, ph2), s, lw)
			# Ladder
			draw_line(Vector2(w - 5, ph), Vector2(w - 5, h * 0.5), s, lw)
			for i in range(3):
				var ry := ph + float(i + 1) * (h * 0.5 - ph) / 4.0
				draw_line(Vector2(w - 8, ry), Vector2(w - 2, ry), s, lw * 0.7)

		"futon":
			# Like a sofa but simpler / flatter
			draw_rect(Rect2(3, 3, w - 6, h * 0.20), Color(s.r, s.g, s.b, 0.20))
			draw_rect(Rect2(3, 3, w - 6, h * 0.20), s, false, lw)
			draw_rect(Rect2(3, h * 0.24, w - 6, h - h * 0.24 - 3), Color(s.r, s.g, s.b, 0.10))
			draw_dashed_line(Vector2(4, h * 0.50), Vector2(w - 4, h * 0.50), s, lw)

		"puff":
			# Circle inside square
			var cx := w * 0.5; var cy := h * 0.5
			var r := minf(w, h) * 0.38
			draw_circle(Vector2(cx, cy), r, Color(s.r, s.g, s.b, 0.18))
			draw_arc(Vector2(cx, cy), r, 0, TAU, 16, s, lw)
			draw_circle(Vector2(cx, cy), r * 0.25, s)

		"stool":
			# Simple cross + circle
			var cx := w * 0.5; var cy := h * 0.5
			draw_circle(Vector2(cx, cy), minf(w, h) * 0.35, Color(s.r, s.g, s.b, 0.18))
			draw_arc(Vector2(cx, cy), minf(w, h) * 0.35, 0, TAU, 12, s, lw)

		"lounge_chair":
			draw_rect(Rect2(3, 3, w - 6, h * 0.28), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.28), s, false, lw)
			draw_rect(Rect2(3, h * 0.32, w - 6, h - h * 0.32 - 3), Color(s.r, s.g, s.b, 0.10))
			draw_rect(Rect2(3, h * 0.32, w - 6, h - h * 0.32 - 3), s, false, lw)

		"barcelona_chair":
			# Iconic cross-leg symbol
			draw_rect(Rect2(3, 3, w - 6, h * 0.32), Color(s.r, s.g, s.b, 0.22))
			draw_rect(Rect2(3, 3, w - 6, h * 0.32), s, false, lw)
			draw_line(Vector2(3, h * 0.35), Vector2(w * 0.5, h - 3), s, lw)
			draw_line(Vector2(w - 3, h * 0.35), Vector2(w * 0.5, h - 3), s, lw)

		"small_desk":
			var ch := h * 0.32
			var cy := h - ch - 3.0
			var csz := minf(w * 0.45, 20.0)
			var cx := (w - csz) * 0.5
			draw_rect(Rect2(cx, cy, csz, ch), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(cx, cy, csz, ch), s, false, lw)
			draw_arc(Vector2(cx + csz * 0.5, cy), csz * 0.5, PI, TAU, 10, s, lw)

		"murphy_desk":
			# Fold symbol — dashed desk surface + hinge arrow
			draw_dashed_line(Vector2(2, h * 0.5), Vector2(w - 2, h * 0.5), s, lw, 3.0)
			draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			draw_line(Vector2(2, h * 0.5), Vector2(w * 0.35, h * 0.85), s, lw * 0.7)

		"dining_table":
			# Table rectangle with chairs on sides
			var mx := w * 0.5; var my := h * 0.5
			var tw := w * 0.55; var th := h * 0.50
			draw_rect(Rect2(mx - tw * 0.5, my - th * 0.5, tw, th), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(mx - tw * 0.5, my - th * 0.5, tw, th), s, false, lw)
			# Chairs (small rects top and bottom)
			for ci in range(2):
				var cx2 := mx + (ci - 0.5) * tw * 0.7
				draw_rect(Rect2(cx2 - 4, my - th * 0.5 - 5, 8, 4), s, false, lw * 0.7)
				draw_rect(Rect2(cx2 - 4, my + th * 0.5 + 1, 8, 4), s, false, lw * 0.7)

		"coffee_table":
			draw_rect(Rect2(4, 4, w - 8, h - 8), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(4, 4, w - 8, h - 8), s, false, lw)

		"bookshelf":
			# Vertical shelves with books
			var num_shelves := 3
			for si in range(num_shelves):
				var shelf_y := 3.0 + float(si) * (h - 6.0) / float(num_shelves)
				draw_line(Vector2(3, shelf_y), Vector2(w - 3, shelf_y), s, lw)
			# Book spines
			var book_w := (w - 6) / 5.0
			for bi in range(5):
				draw_line(Vector2(3 + bi * book_w + book_w * 0.5, 3),
						  Vector2(3 + bi * book_w + book_w * 0.5, h - 3), Color(s.r, s.g, s.b, 0.35), lw * 0.6)

		"pantry":
			# Tall cabinet with handle
			draw_line(Vector2(w * 0.5, 3), Vector2(w * 0.5, h - 3), s, lw)
			draw_circle(Vector2(w * 0.5 - 3, h * 0.5), 1.5, s)
			draw_circle(Vector2(w * 0.5 + 3, h * 0.5), 1.5, s)
			draw_line(Vector2(3, h * 0.33), Vector2(w - 3, h * 0.33), Color(s.r, s.g, s.b, 0.40), lw * 0.6)
			draw_line(Vector2(3, h * 0.66), Vector2(w - 3, h * 0.66), Color(s.r, s.g, s.b, 0.40), lw * 0.6)

		"kitchen_small":
			# 2 hobs instead of 4
			var rr := minf(w * 0.14, h * 0.20)
			for pt in [Vector2(w * 0.30, h * 0.50), Vector2(w * 0.70, h * 0.50)]:
				draw_circle(pt, rr * 0.45, Color(s.r, s.g, s.b, 0.15))
				draw_arc(pt, rr, 0, TAU, 12, s, lw)
			draw_rect(Rect2(w * 0.20, h * 0.08, w * 0.60, h * 0.22), s, false, lw)

		"wall_hanger":
			# Row of hook pegs
			var n_pegs := maxi(2, int(w / 8))
			var spacing := float(w - 4) / float(n_pegs - 1)
			for pi in range(n_pegs):
				var px := 2.0 + pi * spacing
				draw_line(Vector2(px, 1), Vector2(px, h - 1), s, lw)
				draw_arc(Vector2(px, h - 1), 2.0, 0, PI, 8, s, lw)

		"stairs":
			# Stair treads — horizontal lines stepping diagonally
			var n_treads := maxi(3, int(h / 8))
			var tread_h  := float(h - 4) / float(n_treads)
			for ti in range(n_treads):
				var ty := 2.0 + ti * tread_h
				var tx_end := 2.0 + float(ti + 1) / float(n_treads) * (w - 4)
				draw_line(Vector2(2, ty), Vector2(tx_end, ty), s, lw)
				draw_line(Vector2(tx_end, ty), Vector2(tx_end, ty + tread_h), s, lw)
			draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			draw_line(Vector2(w - 2, 2), Vector2(w - 2, h - 2), s, lw * 0.5)

		"plant":
			# Circle with stem
			draw_circle(Vector2(w * 0.5, h * 0.40), minf(w, h) * 0.32, Color(s.r, s.g, s.b, 0.25))
			draw_arc(Vector2(w * 0.5, h * 0.40), minf(w, h) * 0.32, 0, TAU, 14, s, lw)
			draw_line(Vector2(w * 0.5, h * 0.72), Vector2(w * 0.5, h - 2), s, lw)

		"toilet":
			# Tank rectangle at top, oval bowl below, flush dot
			var tk_h := h * 0.36
			draw_rect(Rect2(3, 3, w - 6, tk_h), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, 3, w - 6, tk_h), s, false, lw)
			draw_circle(Vector2(w * 0.5, 3 + tk_h * 0.5), 2.0, Color(s.r, s.g, s.b, 0.35))
			var bwl_y := 3 + tk_h + 2
			var bwl_h := h - bwl_y - 3
			var bwl_r := minf((w - 8) * 0.5, bwl_h * 0.5)
			var bwl_c := Vector2(w * 0.5, bwl_y + bwl_h * 0.5)
			draw_arc(bwl_c, bwl_r, 0, TAU, 16, s, lw)
			draw_arc(bwl_c, bwl_r * 0.45, 0, TAU, 12, Color(s.r, s.g, s.b, 0.22), lw)

		"sink":
			# Basin rect with drain dot and cross faucet
			var bsx := 4.0; var bsy := 3.0
			var bsw := w - 8.0; var bsh := h - 6.0
			draw_rect(Rect2(bsx, bsy, bsw, bsh), Color(s.r, s.g, s.b, 0.14))
			draw_rect(Rect2(bsx, bsy, bsw, bsh), s, false, lw)
			draw_circle(Vector2(w * 0.5, bsy + bsh * 0.62), 1.5, Color(s.r, s.g, s.b, 0.40))
			var fc := Vector2(w * 0.5, bsy + 4)
			draw_circle(fc, 2.0, s)
			draw_line(fc + Vector2(-5, 0), fc + Vector2(5, 0), s, lw)
			draw_line(fc + Vector2(0, -3), fc + Vector2(0, 4), s, lw)

		"shower":
			# Square stall, corner drain, showerhead arc, rain grid
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.10))
			draw_rect(Rect2(3, 3, w - 6, h - 6), s, false, lw)
			draw_circle(Vector2(7, h - 7), 2.0, Color(s.r, s.g, s.b, 0.40))
			draw_arc(Vector2(w - 6, 6), (w - 12) * 0.45, PI * 0.5, PI, 10, s, lw)
			draw_circle(Vector2(w - 6, 6), 2.5, Color(s.r, s.g, s.b, 0.30))
			for ri in range(3):
				for ci in range(3):
					draw_circle(Vector2(w * 0.28 + float(ci) * w * 0.14,
							h * 0.40 + float(ri) * h * 0.14), 1.0, Color(s.r, s.g, s.b, 0.28))

		"towel_rack":
			# Horizontal bar with end brackets and towel fold
			var my := h * 0.5
			draw_line(Vector2(5, my), Vector2(w - 5, my), s, lw * 1.5)
			draw_line(Vector2(5,   my - 2), Vector2(5,   my + 2), s, lw)
			draw_line(Vector2(w-5, my - 2), Vector2(w-5, my + 2), s, lw)
			draw_line(Vector2(w * 0.5, my - 2), Vector2(w * 0.5, my + 2),
					  Color(s.r, s.g, s.b, 0.28), lw)

		"murphy_bed":
			# Wall-mounted fold-down bed: wall rail at top, pillow band, folded panel with pivot
			draw_rect(Rect2(2, 2, w - 4, 4), s, false, lw)                             # wall-mount rail
			var mph := minf(h * 0.30, 18.0)
			draw_rect(Rect2(3, 7, w - 6, mph), Color(s.r, s.g, s.b, 0.18))             # pillow fill
			draw_line(Vector2(3, 7 + mph), Vector2(w - 3, 7 + mph), s, lw)              # pillow divider
			draw_line(Vector2(w * 0.5, 7 + mph), Vector2(w * 0.5, h - 4), s, lw)       # centre spine
			draw_line(Vector2(4, h - 4),  Vector2(w - 4, h - 4),  s, lw)               # foot rail
			draw_circle(Vector2(4.0, 6.0),  2.0, s)                                      # hinge L
			draw_circle(Vector2(w - 4.0, 6.0), 2.0, s)                                   # hinge R

		"bathtub":
			# Oval tub inside rectangle; faucet dot at one end
			var bw := w - 8.0; var bh := h - 8.0
			var bx := 4.0; var by := 4.0
			draw_rect(Rect2(bx, by, bw, bh), Color(s.r, s.g, s.b, 0.14))
			draw_rect(Rect2(bx, by, bw, bh), s, false, lw)
			# Inner oval
			draw_arc(Vector2(w * 0.5, h * 0.5), bw * 0.38, 0, TAU, 18, Color(s.r, s.g, s.b, 0.30), lw)
			# Faucet dot at head end
			draw_circle(Vector2(w * 0.5, by + 4.0), 2.0, s)

		"tv":
			# Screen with thin bezel and stand legs
			var sw := w - 6.0; var sh := h * 0.72
			var sx := 3.0;     var sy := 3.0
			draw_rect(Rect2(sx, sy, sw, sh), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(sx, sy, sw, sh), s, false, lw)
			# Screen glare diagonal
			draw_line(Vector2(sx + 4, sy + 3), Vector2(sx + sw * 0.35, sy + sh * 0.40),
					  Color(s.r, s.g, s.b, 0.25), lw)
			# Stand base
			var stx := w * 0.5
			draw_line(Vector2(stx, sy + sh), Vector2(stx, h - 3), s, lw)
			draw_line(Vector2(stx - 6, h - 3), Vector2(stx + 6, h - 3), s, lw)

		"wall_shelf":
			# Three horizontal shelves with end brackets
			var n := 3
			for si in range(n):
				var sy2 := 3.0 + float(si) * (h - 6.0) / float(n) + (h - 6.0) / float(n) * 0.5
				draw_line(Vector2(3, sy2), Vector2(w - 3, sy2), s, lw)
				draw_line(Vector2(3, sy2), Vector2(3, sy2 - 3), s, lw * 0.7)       # bracket L
				draw_line(Vector2(w - 3, sy2), Vector2(w - 3, sy2 - 3), s, lw * 0.7) # bracket R

		"mirror":
			# Oval reflection surface with cross glare
			var mr := minf(w - 8.0, h - 8.0) * 0.5
			var mc := Vector2(w * 0.5, h * 0.5)
			draw_circle(mc, mr, Color(s.r, s.g, s.b, 0.12))
			draw_arc(mc, mr, 0, TAU, 20, s, lw)
			draw_arc(mc, mr, 0, TAU, 20, s, lw)
			# Glare lines
			draw_line(mc + Vector2(-mr * 0.5, -mr * 0.5),
					  mc + Vector2(-mr * 0.22, -mr * 0.22), Color(s.r, s.g, s.b, 0.35), lw)

		"stair_n", "stair_s", "stair_e", "stair_w":
			var n_treads := maxi(3, int(maxf(w, h) / 8))
			if furniture_id in ["stair_n", "stair_s"]:
				# Treads horizontal, stepping upward (N = head at top)
				var tread_h := float(h - 4) / float(n_treads)
				var dir_flip := 1.0 if furniture_id == "stair_n" else -1.0
				for ti in range(n_treads):
					var ti_eff := ti if dir_flip > 0 else (n_treads - 1 - ti)
					var ty := 2.0 + ti_eff * tread_h
					var tx_end := 2.0 + float(ti + 1) / float(n_treads) * (w - 4)
					draw_line(Vector2(2, ty), Vector2(tx_end, ty), s, lw)
					draw_line(Vector2(tx_end, ty), Vector2(tx_end, ty + tread_h), s, lw)
				draw_line(Vector2(2, 2), Vector2(2, h - 2), s, lw)
			else:
				# Treads vertical, stepping rightward (E = head at right)
				var tread_w := float(w - 4) / float(n_treads)
				var dir_flip := 1.0 if furniture_id == "stair_e" else -1.0
				for ti in range(n_treads):
					var ti_eff := ti if dir_flip > 0 else (n_treads - 1 - ti)
					var tx := 2.0 + ti_eff * tread_w
					var ty_end := 2.0 + float(ti + 1) / float(n_treads) * (h - 4)
					draw_line(Vector2(tx, 2), Vector2(tx, ty_end), s, lw)
					draw_line(Vector2(tx, ty_end), Vector2(tx + tread_w, ty_end), s, lw)
				draw_line(Vector2(2, 2), Vector2(w - 2, 2), s, lw)

		"loft_bed":
			# Two-level: lower living area + upper sleep platform (ladder on side)
			draw_line(Vector2(3, h * 0.5), Vector2(w - 3, h * 0.5), s, lw)
			var ph := minf(h * 0.20, 14.0)
			draw_rect(Rect2(3, 3, w - 6, ph), Color(s.r, s.g, s.b, 0.18))
			draw_line(Vector2(3, 3 + ph), Vector2(w - 3, 3 + ph), s, lw)
			draw_line(Vector2(w * 0.5, 3 + ph), Vector2(w * 0.5, h * 0.5 - 2), s, lw)
			draw_line(Vector2(w - 5, 3 + ph), Vector2(w - 5, h * 0.5), s, lw)
			for ri in range(3):
				var ry := 3.0 + ph + float(ri + 1) * (h * 0.5 - 3.0 - ph) / 4.0
				draw_line(Vector2(w - 8, ry), Vector2(w - 2, ry), s, lw * 0.7)

		"wall_plant", "painting":
			# Simple rect outline for wall deco
			draw_rect(Rect2(2, 2, w - 4, h - 4), Color(s.r, s.g, s.b, 0.20))

		# ── Rugs / mats ──────────────────────────────────────────────────────
		"rug", "bedroom_rug", "bath_mat":
			# Outer border + inner parallel stripes
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, 3, w - 6, h - 6), s, false, lw)
			var n_stripes := maxi(2, int((h - 10) / 5))
			for si in range(1, n_stripes):
				var sy := 6.0 + float(si) * float(h - 12) / float(n_stripes)
				draw_line(Vector2(6, sy), Vector2(w - 6, sy), Color(s.r, s.g, s.b, 0.30), lw * 0.7)
			# Corner tassels
			for cx in [4.0, w - 4.0]:
				for cy in [4.0, h - 4.0]:
					draw_circle(Vector2(cx, cy), 1.5, Color(s.r, s.g, s.b, 0.50))

		# ── Lamps ─────────────────────────────────────────────────────────────
		"floor_lamp", "desk_lamp":
			var cx2 := w * 0.5
			var stem_top := h * 0.20
			var shade_r := minf(w * 0.38, h * 0.20)
			# Stem
			draw_line(Vector2(cx2, h - 3), Vector2(cx2, stem_top + shade_r), s, lw)
			# Base
			draw_line(Vector2(cx2 - 4, h - 3), Vector2(cx2 + 4, h - 3), s, lw)
			# Shade (arc + bottom line)
			draw_arc(Vector2(cx2, stem_top + shade_r), shade_r, PI, TAU, 14, s, lw)
			draw_line(Vector2(cx2 - shade_r, stem_top + shade_r),
					  Vector2(cx2 + shade_r, stem_top + shade_r), s, lw)
			# Glow fill
			draw_circle(Vector2(cx2, stem_top + shade_r * 0.6), shade_r * 0.5,
					Color(s.r, s.g, s.b, 0.12))

		# ── Fridge ────────────────────────────────────────────────────────────
		"fridge":
			# Freezer compartment at top (~30%), fridge body below
			var divider_y := h * 0.30
			draw_line(Vector2(3, divider_y), Vector2(w - 3, divider_y), s, lw)
			# Door handle on right side
			var hx := w - 5.0
			draw_line(Vector2(hx, divider_y + 3), Vector2(hx, h * 0.75), s, lw * 1.5)

		# ── Drawers furniture (dresser, filing cabinet, nightstand, tv_stand) ─
		"dresser", "filing_cabinet", "nightstand", "tv_stand", "bathroom_cabinet":
			var n_drawers := maxi(2, int(h / 10))
			var drawer_h := float(h - 4) / float(n_drawers)
			for di in range(n_drawers):
				var dy := 2.0 + di * drawer_h
				draw_line(Vector2(3, dy + drawer_h), Vector2(w - 3, dy + drawer_h), s, lw * 0.8)
				# Drawer handle
				var mid_x := w * 0.5
				draw_line(Vector2(mid_x - 3, dy + drawer_h * 0.55),
						  Vector2(mid_x + 3, dy + drawer_h * 0.55), s, lw * 1.2)

		# ── Clothes rack ──────────────────────────────────────────────────────
		"clothes_rack":
			# Horizontal bar across top third
			var bar_y := h * 0.30
			draw_line(Vector2(3, bar_y), Vector2(w - 3, bar_y), s, lw * 1.5)
			# Vertical supports at ends
			draw_line(Vector2(3, bar_y), Vector2(3, h - 3), s, lw)
			draw_line(Vector2(w - 3, bar_y), Vector2(w - 3, h - 3), s, lw)
			# Hangers (triangle arcs)
			var n_hangers := maxi(2, int((w - 8) / 8))
			for hi2 in range(n_hangers):
				var hx2 := 6.0 + hi2 * float(w - 12) / float(n_hangers - 1) if n_hangers > 1 else w * 0.5
				draw_arc(Vector2(hx2, bar_y), 3.5, PI * 0.1, PI * 0.9, 8,
						Color(s.r, s.g, s.b, 0.55), lw * 0.8)
				draw_line(Vector2(hx2, bar_y + 3.5), Vector2(hx2 - 3, bar_y + 9), s, lw * 0.7)
				draw_line(Vector2(hx2, bar_y + 3.5), Vector2(hx2 + 3, bar_y + 9), s, lw * 0.7)

		# ── Planter box ───────────────────────────────────────────────────────
		"planter_box":
			# Soil fill + plant stems + dots
			draw_rect(Rect2(3, h * 0.5, w - 6, h * 0.45), Color(s.r, s.g, s.b, 0.20))
			var n_plants := maxi(2, int((w - 6) / 10))
			for pi2 in range(n_plants):
				var px := 5.0 + pi2 * float(w - 10) / float(n_plants - 1) if n_plants > 1 else w * 0.5
				var py_soil := h * 0.5
				draw_line(Vector2(px, py_soil), Vector2(px, py_soil - h * 0.30), s, lw)
				draw_circle(Vector2(px, py_soil - h * 0.30), 2.5, Color(s.r, s.g, s.b, 0.30))

		# ── Sun lounger ───────────────────────────────────────────────────────
		"sun_lounger":
			# Reclined rectangle with head rest bump
			var hr_w := w * 0.18
			draw_rect(Rect2(3, h * 0.20, hr_w, h * 0.60), Color(s.r, s.g, s.b, 0.25))
			draw_rect(Rect2(3 + hr_w, h * 0.30, w - hr_w - 6, h * 0.40),
					Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(3, h * 0.20, hr_w, h * 0.60), s, false, lw)
			draw_rect(Rect2(3 + hr_w, h * 0.30, w - hr_w - 6, h * 0.40), s, false, lw)
			# Leg lines
			for lx in [6.0, w - 6.0]:
				draw_line(Vector2(lx, h * 0.70), Vector2(lx, h - 3), s, lw * 0.7)

		# ── Laundry basket ────────────────────────────────────────────────────
		"laundry_basket":
			# Tapered body + oval opening at top
			var bx := w * 0.10; var by := h * 0.25
			draw_rect(Rect2(bx, by, w - bx * 2, h - by - 3), Color(s.r, s.g, s.b, 0.18))
			draw_rect(Rect2(bx, by, w - bx * 2, h - by - 3), s, false, lw)
			var ell_pts: PackedVector2Array = PackedVector2Array()
			for _ai in range(13):
				var ang := _ai * TAU / 12.0
				ell_pts.append(Vector2(w * 0.5 + (w - bx * 2) * 0.45 * cos(ang), (by + 3) + 3.5 * sin(ang)))
			ell_pts.append(ell_pts[0])
			draw_polyline(ell_pts, Color(s.r, s.g, s.b, 0.55), lw)
			# Weave lines
			var n_weave := 3
			for wi in range(1, n_weave + 1):
				var wy := by + float(wi) * (h - by - 3) / float(n_weave + 1)
				draw_line(Vector2(bx + 2, wy), Vector2(w - bx - 2, wy),
						Color(s.r, s.g, s.b, 0.25), lw * 0.7)

		# ── Whiteboard ────────────────────────────────────────────────────────
		"whiteboard":
			draw_rect(Rect2(2, 2, w - 4, h - 4), Color(s.r, s.g, s.b, 0.15))
			# Writing lines
			for li in range(2):
				var ly := 4.0 + float(li) * (h - 8) / 2.0 + (h - 8) / 4.0
				draw_line(Vector2(5, ly), Vector2(w - 5, ly), Color(s.r, s.g, s.b, 0.35), lw * 0.7)

		# ── Kitchen island / outdoor table / side table ───────────────────────
		"kitchen_island", "outdoor_table", "side_table":
			# Surface with a thin inset and seam lines
			draw_rect(Rect2(3, 3, w - 6, h - 6), Color(s.r, s.g, s.b, 0.15))
			# Centre seam
			if w > h:
				draw_line(Vector2(w * 0.5, 5), Vector2(w * 0.5, h - 5), s, lw * 0.5)
			else:
				draw_line(Vector2(5, h * 0.5), Vector2(w - 5, h * 0.5), s, lw * 0.5)

		# ── Seats (office chair, outdoor chair, bar stool) ────────────────────
		"office_chair", "outdoor_chair", "bar_stool":
			var cr := minf(w, h) * 0.38
			var cc := Vector2(w * 0.5, h * 0.55)
			draw_circle(cc, cr, Color(s.r, s.g, s.b, 0.20))
			draw_arc(cc, cr, 0, TAU, 16, s, lw)
			# Back
			draw_arc(Vector2(w * 0.5, h * 0.18), w * 0.30, PI * 0.1, PI * 0.9, 10, s, lw)

		# ── Floor mirror ──────────────────────────────────────────────────────
		"floor_mirror":
			var mr2 := minf(w - 6.0, h * 0.60) * 0.5
			var mc2 := Vector2(w * 0.5, h * 0.40)
			draw_rect(Rect2(mc2.x - mr2, mc2.y - mr2 * 1.4, mr2 * 2, mr2 * 2.8),
					Color(s.r, s.g, s.b, 0.12))
			draw_rect(Rect2(mc2.x - mr2, mc2.y - mr2 * 1.4, mr2 * 2, mr2 * 2.8),
					s, false, lw)
			# Glare line
			draw_line(mc2 + Vector2(-mr2 * 0.3, -mr2 * 0.5),
					  mc2 + Vector2(-mr2 * 0.1, -mr2 * 0.2),
					  Color(s.r, s.g, s.b, 0.35), lw)
			# Stand base
			draw_line(Vector2(w * 0.5 - 4, h - 3), Vector2(w * 0.5 + 4, h - 3), s, lw)
			draw_line(Vector2(w * 0.5, mc2.y + mr2 * 1.4), Vector2(w * 0.5, h - 3), s, lw * 0.8)

		# ── Towel set (wall) / kitchen rack (wall) ────────────────────────────
		"towel_set":
			# Folded towel stacks
			var n_towels := maxi(1, int((w - 4) / 8))
			for ti2 in range(n_towels):
				var tx2 := 3.0 + ti2 * float(w - 6) / float(n_towels)
				var tw2 := float(w - 6) / float(n_towels) - 2
				draw_rect(Rect2(tx2, 2, tw2, h - 4), Color(s.r, s.g, s.b, 0.22))
				draw_line(Vector2(tx2, h * 0.5), Vector2(tx2 + tw2, h * 0.5),
						Color(s.r, s.g, s.b, 0.35), lw * 0.7)

		"kitchen_rack":
			# Horizontal rod with hanging hooks
			var ry2 := h * 0.35
			draw_line(Vector2(3, ry2), Vector2(w - 3, ry2), s, lw * 1.5)
			var n_hooks := maxi(2, int((w - 6) / 7))
			for hi3 in range(n_hooks):
				var hx3 := 5.0 + hi3 * float(w - 10) / float(n_hooks - 1) if n_hooks > 1 else w * 0.5
				draw_line(Vector2(hx3, ry2), Vector2(hx3, ry2 + (h - ry2) * 0.6), s, lw * 0.8)
				draw_arc(Vector2(hx3, ry2 + (h - ry2) * 0.6), 2.0,
						PI * 0.5, PI * 1.5, 6, Color(s.r, s.g, s.b, 0.55), lw * 0.8)


func _draw_cotes(fW: float, fH: float) -> void:
	var gx := int(position.x / TILE_SIZE)
	var gy := int(position.y / TILE_SIZE)

	var d_n := gy
	var d_s := _wall_ref.grid_h - gy - grid_h
	var d_w := gx
	var d_e := _wall_ref.grid_w - gx - grid_w

	const COL  := Color(0.18, 0.58, 0.90, 0.82)
	const FS   := 7
	const TICK := 4.0
	const OFF  := 8.0
	var font := ThemeDB.fallback_font

	# ── Own-size cotes (just outside the furniture edges) ──────────────────
	# Width — horizontal line above
	draw_line(Vector2(0, -OFF), Vector2(fW, -OFF), COL, 0.7)
	draw_line(Vector2(0,  -OFF - TICK), Vector2(0,  -OFF + TICK), COL, 1.0)
	draw_line(Vector2(fW, -OFF - TICK), Vector2(fW, -OFF + TICK), COL, 1.0)
	draw_string(font, Vector2(fW * 0.5 - 9, -OFF - 2),
		"%.1fm" % (float(grid_w) * 0.1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	# Height — vertical line left
	draw_line(Vector2(-OFF, 0), Vector2(-OFF, fH), COL, 0.7)
	draw_line(Vector2(-OFF - TICK, 0),  Vector2(-OFF + TICK, 0),  COL, 1.0)
	draw_line(Vector2(-OFF - TICK, fH), Vector2(-OFF + TICK, fH), COL, 1.0)
	draw_string(font, Vector2(-OFF - 16, fH * 0.5 + 3),
		"%.1fm" % (float(grid_h) * 0.1),
		HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	# ── Distance-to-wall cotes ─────────────────────────────────────────────
	if d_n > 0:
		var px := float(d_n * TILE_SIZE)
		var mx := fW * 0.5
		draw_line(Vector2(mx, 0), Vector2(mx, -px), COL, 0.55)
		draw_line(Vector2(mx - TICK, 0),   Vector2(mx + TICK, 0),   COL, 0.8)
		draw_line(Vector2(mx - TICK, -px), Vector2(mx + TICK, -px), COL, 0.8)
		draw_string(font, Vector2(mx + 3, -px * 0.5 + 3),
			"%.1fm" % (d_n * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_s > 0:
		var px := float(d_s * TILE_SIZE)
		var mx := fW * 0.5
		draw_line(Vector2(mx, fH), Vector2(mx, fH + px), COL, 0.55)
		draw_line(Vector2(mx - TICK, fH),      Vector2(mx + TICK, fH),      COL, 0.8)
		draw_line(Vector2(mx - TICK, fH + px), Vector2(mx + TICK, fH + px), COL, 0.8)
		draw_string(font, Vector2(mx + 3, fH + px * 0.5 + 3),
			"%.1fm" % (d_s * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_w > 0:
		var px := float(d_w * TILE_SIZE)
		var my := fH * 0.5
		draw_line(Vector2(0, my), Vector2(-px, my), COL, 0.55)
		draw_line(Vector2(0,   my - TICK), Vector2(0,   my + TICK), COL, 0.8)
		draw_line(Vector2(-px, my - TICK), Vector2(-px, my + TICK), COL, 0.8)
		draw_string(font, Vector2(-px * 0.5 - 10, my - 2),
			"%.1fm" % (d_w * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)

	if d_e > 0:
		var px := float(d_e * TILE_SIZE)
		var my := fH * 0.5
		draw_line(Vector2(fW, my), Vector2(fW + px, my), COL, 0.55)
		draw_line(Vector2(fW,      my - TICK), Vector2(fW,      my + TICK), COL, 0.8)
		draw_line(Vector2(fW + px, my - TICK), Vector2(fW + px, my + TICK), COL, 0.8)
		draw_string(font, Vector2(fW + px * 0.5 - 8, my - 2),
			"%.1fm" % (d_e * 0.1), HORIZONTAL_ALIGNMENT_LEFT, -1, FS, COL)


func set_grid_pos(gx: float, gy: float) -> void:
	grid_pos = Vector2(gx, gy)
	position = Vector2(gx * TILE_SIZE, gy * TILE_SIZE)


func get_occupied_tiles() -> Array:
	var tiles: Array = []
	var origin := Vector2i(floori(grid_pos.x), floori(grid_pos.y))
	for x in range(grid_w):
		for y in range(grid_h):
			tiles.append(Vector2i(origin.x + x, origin.y + y))
	return tiles


# Where this piece sits for a given moment — its own moment_positions entry
# if it has_own_moment_position() and one's been recorded, else its single
# shared grid_pos (the correct fallback for both "never moved for this
# moment yet" and "red, non-rail — always shares one position").
# Records a move made while a moment is on screen. A plain move puts it
# there in every moment (the default). `only_here` (Shift held on dropping
# it) moves it for the moment on screen only: every other moment that had
# no place of its own yet keeps the one it had, `from`, so moving it at
# night doesn't move it by day. Pieces that share one place in every moment
# (red ones) have nothing to record. Returns what was done, for the notice:
# "" when nothing.
func record_moment_move(from: Vector2, only_here := false) -> String:
	if not has_own_moment_position() or not Furniture.test_mode_active or Furniture.all_moment_ids.size() < 2:
		return ""
	for mid in Furniture.all_moment_ids:
		if not only_here:
			moment_positions[mid] = grid_pos
		elif not moment_positions.has(mid):
			moment_positions[mid] = from
	moment_positions[Furniture.active_moment_id] = grid_pos
	if not only_here:
		return tr("Moved for every moment")
	return tr("Moved for %s only") % tr(Furniture.moment_labels.get(Furniture.active_moment_id, Furniture.active_moment_id) as String)


func get_moment_position(moment_id: String) -> Vector2:
	if has_own_moment_position() and moment_positions.has(moment_id):
		return moment_positions[moment_id]
	return grid_pos


# Rect2 footprint for a given moment — cheap pairwise-overlap form of
# get_occupied_tiles_for_moment(), used by cross-moment collision checks
# (see Wall.can_place_across_moments()) that don't need individual tiles.
func get_moment_rect(moment_id: String) -> Rect2:
	var h := grid_h
	if foldable and extended_add_h > 0:
		var extended: bool = moment_fold_state.get(moment_id, false) as bool
		h = (_base_grid_h + extended_add_h) if extended else _base_grid_h
	return Rect2(get_moment_position(moment_id), Vector2(grid_w, h))


# Footprint this piece would have for a given moment's OWN stored fold state
# and position, without touching its real current grid_h/position. Used for
# free-space checks (e.g. "sport" needs enough open floor) that must account
# for a foldable piece being unfolded in one moment but folded in another,
# or a movable piece sitting somewhere different per moment.
func get_occupied_tiles_for_moment(moment_id: String) -> Array:
	var h := grid_h
	if foldable and extended_add_h > 0:
		var extended: bool = moment_fold_state.get(moment_id, false) as bool
		h = (_base_grid_h + extended_add_h) if extended else _base_grid_h
	var pos: Vector2 = get_moment_position(moment_id)
	var origin := Vector2i(floori(pos.x), floori(pos.y))
	var tiles: Array = []
	for x in range(grid_w):
		for y in range(h):
			tiles.append(Vector2i(origin.x + x, origin.y + y))
	return tiles


func _input(event: InputEvent) -> void:
	# Double-click a nested box to step inside. Checked before the read-only
	# gate because entering isn't an edit (the mini-plan cards allow it in the
	# post-win view too), and before the drag code so the second press doesn't
	# pick the box up. Deferred: entering tears this level down, this node
	# included.
	if is_nested_box and not _placement_mode and not child_level_id.is_empty() \
			and event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).double_click \
			and Furniture.on_box_enter_requested.is_valid() \
			and not get_viewport().is_input_handled() and is_visible_in_tree() \
			and _contains_screen_point((event as InputEventMouseButton).position) \
			and (not Furniture.is_in_floor_pane.is_valid() or Furniture.is_in_floor_pane.call((event as InputEventMouseButton).position)):
		get_viewport().set_input_as_handled()
		Furniture.on_box_enter_requested.call_deferred(self)
		return
	if Furniture.read_only:
		return
	# ── Placement mode: furniture follows cursor until click or Esc ───────────
	if _placement_mode:
		if get_viewport().is_input_handled():
			return
		if event is InputEventMouseMotion:
			_drag(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if Furniture.is_in_floor_pane.is_valid() and not Furniture.is_in_floor_pane.call(event.position):
				return   # click landed on another panel (e.g. Wall Inspector) — let it through
			if TouchControls.active:
				# A finger has no hover: touching moves the piece there, and it
				# is put down with the Place button (see confirm_placement()).
				_drag(event.position)
				get_viewport().set_input_as_handled()
				return
			confirm_placement(event.position)
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			cancel_placement()
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
			_rotate()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R and _is_mouse_over() and not _rider_covers(get_viewport().get_mouse_position()):
			_rotate()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			# The press's own position, not the live pointer: a finger has no
			# hover, so the pointer is still wherever the last touch left it.
			if event.pressed and _contains_screen_point(event.position) and not _rider_covers(event.position):
				_press_pos = event.position
				_press_ms = Time.get_ticks_msec()
				_press_moved = false
				_start_drag(event.position)
			elif _dragging and not event.pressed:
				var release_pos: Vector2 = (event as InputEventMouseButton).position
				var was_click: bool = release_pos.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD
				if was_click and foldable:
					_dragging = false
					z_index = stack_z
					if _wall_ref:
						_wall_ref.grid_draw.show_grid = false
						_wall_ref.grid_draw.queue_redraw()
					position = _original_pos
					queue_redraw()
					toggle_fold()
				else:
					_end_drag(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if _is_mouse_over() and not _rider_covers(event.position):
				sell_requested.emit(self)
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		if (event as InputEventMouseMotion).position.distance_to(_press_pos) >= CLICK_MOVE_THRESHOLD:
			_press_moved = true
		_drag(event.position)


# Whether a viewport-space point (an input event's position) lands on this
# piece's footprint. Uses the event's own position rather than the live
# pointer, so it stays right even if the pointer has moved on since.
func _contains_screen_point(screen_pos: Vector2) -> bool:
	var local := get_global_transform_with_canvas().affine_inverse() * screen_pos
	return Rect2(Vector2.ZERO, Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)).has_point(local)


# Whether something standing on this piece (a lamp, a box on a table) is
# under that point: every piece hears every click, so the table lets the one
# on top of it take it instead of being picked up, sold or turned as well.
func _rider_covers(screen_pos: Vector2) -> bool:
	if not is_surface or not _wall_ref or not _wall_ref.is_registered(self):
		return false
	for r in _wall_ref.riders_of(self):
		if is_instance_valid(r) and (r as Furniture)._contains_screen_point(screen_pos):
			return true
	return false


func set_strain(ratio: float) -> void:
	if not is_equal_approx(ratio, _strain):
		_strain = ratio
		queue_redraw()


# A surface under strain, on the plan: its long edges pull in toward the
# middle like a beam drawn under load, amber as it fills, red with a crack
# when what is being carried over it would break it. (In 3D it bows instead.)
func _draw_strain(w: float, h: float) -> void:
	if _strain <= Floor.STRAIN_FROM:
		return
	var over := _strain > 1.0 + 0.0001
	var t := clampf((_strain - Floor.STRAIN_FROM) / (1.0 - Floor.STRAIN_FROM), 0.0, 1.0)
	var col := Color(0.98, 0.72, 0.22).lerp(Color(0.93, 0.26, 0.18), t)
	var along_x := w >= h
	var span := w if along_x else h
	var across := h if along_x else w
	var depth := across * (0.28 if over else lerpf(0.05, 0.16, t))
	for side in [0.0, 1.0]:
		var pts := PackedVector2Array()
		for i in 13:
			var u := i / 12.0
			var pull: float = depth * 4.0 * u * (1.0 - u) * (1.0 - 2.0 * side)
			var a := u * span
			var b: float = side * across + pull
			pts.append(Vector2(a, b) if along_x else Vector2(b, a))
		draw_polyline(pts, col, 2.5 if over else 2.0, true)
		if over:
			# A crack where the edge gives, pointing into the piece.
			var dir: float = 1.0 - 2.0 * side
			var crack := PackedVector2Array()
			for k in 4:
				var a2 := span * 0.5 + (2.5 if k % 2 == 0 else -2.5)
				var b2: float = side * across + (depth + 1.0 + k * 3.0) * dir
				crack.append(Vector2(a2, b2) if along_x else Vector2(b2, a2))
			draw_polyline(crack, col, 1.5, true)


# How full a box is, on the plan: taped shut once what is inside makes it
# heavy (yellow tier), strapped crosswise once it is packed full (red), and a
# thin gauge along its bottom edge filling toward the next of those.
const TAPE_COLOR := Color(0.80, 0.66, 0.42, 0.95)
const STRAP_COLOR := Color(0.22, 0.16, 0.12, 0.95)

func _draw_packing(w: float, h: float) -> void:
	# Drawn as a little plan, the box keeps its plan clear: no tape or straps.
	var plain := not _has_interior_plan()
	if plain and (mobility_tier == "yellow" or mobility_tier == "red"):
		var band := maxf(2.0, h * 0.12)
		draw_rect(Rect2(0, h * 0.5 - band * 0.5, w, band), TAPE_COLOR)
	if plain and mobility_tier == "red":
		var strap := maxf(2.0, w * 0.10)
		draw_rect(Rect2(w * 0.5 - strap * 0.5, 0, strap, h), STRAP_COLOR)
		draw_rect(Rect2(0, h * 0.5 - strap * 0.5, w, strap), STRAP_COLOR)
	var fill := clampf(interior_weight / BOX_WEIGHT_RED_MIN, 0.0, 1.0)
	var gauge := Rect2(2, h - 4, w - 4, 2.5)
	draw_rect(gauge, Color(0.04, 0.08, 0.14, 0.7))
	var col := GameTheme.C_GOOD if mobility_tier == "green" else (GameTheme.C_AMBER if mobility_tier == "yellow" else GameTheme.C_BAD)
	draw_rect(Rect2(gauge.position, Vector2(gauge.size.x * fill, gauge.size.y)), col)
	var mark := gauge.position.x + gauge.size.x * (BOX_WEIGHT_YELLOW_MIN / BOX_WEIGHT_RED_MIN)
	draw_line(Vector2(mark, gauge.position.y - 1), Vector2(mark, gauge.end.y + 1), Color(1, 1, 1, 0.8), 1.0)


# A box in another piece's shadow, on the plan: shade over it, darker the
# less daylight gets in.
func _draw_shade(w: float, h: float) -> void:
	var dark := (1.0 - _shade) * 0.6
	if _has_interior_plan():   # a light tint only, so its plan still reads
		draw_rect(Rect2(0, 0, w, h), Color(0.02, 0.03, 0.08, dark * 0.4))
		return
	draw_rect(Rect2(0, 0, w, h), Color(0.02, 0.03, 0.08, dark))
	var hatch := Color(0.02, 0.03, 0.08, dark + 0.15)
	var d := 3.0
	while d < w + h:
		draw_line(Vector2(maxf(0.0, d - h), minf(d, h)), Vector2(minf(d, w), maxf(0.0, d - w)), hatch, 1.0, true)
		d += 3.0


# Sound coming off a piece: arcs either side of its top corner.
func _draw_noise(w: float, h: float, col: Color) -> void:
	var c := Vector2(w - 6.0, 6.0)
	for r in [3.0, 5.5, 8.0]:
		draw_arc(c, r, -0.7, 0.7, 6, col, 1.5, true)
		draw_arc(c, r, PI - 0.7, PI + 0.7, 6, col, 1.5, true)
	draw_circle(c, 1.5, col)


# A bed noise keeps anyone from sleeping in: a struck-through "Zz" and the
# sound reaching it.
func _draw_kept_awake(w: float, h: float) -> void:
	var red := Color(0.93, 0.28, 0.22)
	var font := ThemeDB.fallback_font
	var at := Vector2(w * 0.5 - 7.0, h * 0.5 + 5.0)
	draw_string_outline(font, at, "Zz", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color(1, 1, 1, 0.85))
	draw_string(font, at, "Zz", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, red)
	draw_line(at + Vector2(-2, -4), at + Vector2(16, -4), red, 2.0, true)
	_draw_noise(w, h, red)


func _is_mouse_over() -> bool:
	var local_mouse := get_local_mouse_position()
	var sz := Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	return Rect2(Vector2.ZERO, sz).has_point(local_mouse)


func _start_drag(mouse_pos: Vector2) -> void:
	_dragging = true
	_drag_offset = position - _wall_ref.to_local(mouse_pos)
	_original_pos = position
	_landing_key = Vector3.INF   # the room may have changed since the last drag
	_landing = grid_pos   # picked up from where it stands
	_landing_why = ""
	z_index = 10
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = true
		_wall_ref.grid_draw.wall_cue = wall_flush_required   # light up the walls it can go against
		_wall_ref.grid_draw.queue_redraw()
	# Lock rail axis on drag start
	if rail_axis == "h":
		_rail_lock = grid_pos.y
	elif rail_axis == "v":
		_rail_lock = grid_pos.x
	_rail_ctrl_latch = false
	queue_redraw()


const RAIL_REATTACH_SNAP := 1.0   # tiles; how close to a rail's own line (Floor.rails) counts as close enough to Ctrl-reattach

# Looks up whether `along`/`cross` (in the given axis's own frame — for "h",
# along=x/cross=y; for "v", along=y/cross=x) sits near enough to one of the
# level's actual rail lines to re-engage it, returning that rail's fixed
# line coordinate, or -1 if none match closely enough.
func _find_rail_snap(axis: String, along: float, cross: float) -> float:
	if not _wall_ref:
		return -1.0
	for rail in _wall_ref.rails:
		var rd := rail as Dictionary
		var x1: int = rd.get("x1", 0) as int
		var y1: int = rd.get("y1", 0) as int
		var x2: int = rd.get("x2", 0) as int
		var y2: int = rd.get("y2", 0) as int
		var is_h := (y1 == y2)
		if (axis == "h") != is_h:
			continue
		var line: float = float(y1) if is_h else float(x1)
		var lo: float = float(mini(x1, x2)) if is_h else float(mini(y1, y2))
		var hi: float = float(maxi(x1, x2)) if is_h else float(maxi(y1, y2))
		if absf(cross - line) <= RAIL_REATTACH_SNAP and along >= lo - RAIL_REATTACH_SNAP and along <= hi + RAIL_REATTACH_SNAP:
			return line
	return -1.0


const RAIL_FLASH_DURATION := 0.4

# Distinct sound per direction (attach reuses "place" — something clicking
# into position — detach uses "click", a plainer neutral sound) plus a
# brief expanding-ring flash drawn in _draw() below, since the persistent
# outline alone (added/removed silently) turned out too easy to miss at the
# actual moment the state changed.
func _flash_rail(attached: bool) -> void:
	Audio.play("rail_attach" if attached else "rail_detach")
	_rail_flash_color = Color(0.22, 0.70, 0.78, 1.0) if attached else Color(0.85, 0.55, 0.20, 1.0)
	_rail_flash_t = 1.0
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void: _rail_flash_t = t; queue_redraw(), 1.0, 0.0, RAIL_FLASH_DURATION)


func _drag(mouse_pos: Vector2) -> void:
	if not _wall_ref:
		return
	# Buying an item arms BOTH a floor ghost (this one) and a Wall Inspector
	# ghost at once, so the player can drop it into whichever panel they
	# actually click into (see Main.gd's _on_buy_requested). The click
	# handler below already ignores clicks that land outside the floor pane
	# for that reason — but until now this continuous mouse-motion reposition
	# had no such gate, so this ghost kept tracking/re-validating stray
	# floor-plan coordinates from wherever the cursor was over the OTHER
	# panel, and could surface its own rejection reason (e.g. "Outside the
	# room") even while the player was clearly placing the item on a wall.
	if Furniture.is_in_floor_pane.is_valid() and not Furniture.is_in_floor_pane.call(mouse_pos):
		if _placement_mode:
			visible = false   # Main carries it at the pointer until it reaches the plan
		return
	visible = true
	var target := _wall_ref.to_local(mouse_pos) + _drag_offset
	var tx := target.x / TILE_SIZE
	var ty := target.y / TILE_SIZE
	if Furniture.on_drag_moved.is_valid():
		Furniture.on_drag_moved.call(self, mouse_pos, Vector2(tx + grid_w * 0.5, ty + grid_h * 0.5))
	# Holding Ctrl while dragging pops the piece off its rail for good (or
	# back on, see below) — rail_axis is cleared/restored on this instance
	# only. _rail_ctrl_latch makes this an EDGE trigger (fires once per
	# Ctrl press, not every single frame it's held): without it, detaching
	# immediately put the cursor back inside the reattach snap zone (it's
	# still right next to the rail it just left), which reattached on the
	# very next frame, which then re-detached the frame after that, and so
	# on for as long as Ctrl and the mouse both stayed put — a rapid
	# flicker that left no way to tell which state it actually ended up in.
	var ctrl_down := Input.is_key_pressed(KEY_CTRL)
	if not ctrl_down:
		_rail_ctrl_latch = false
	elif not _rail_ctrl_latch:
		if rail_axis != "" and _rail_lock >= 0:
			rail_axis = ""
			_rail_ctrl_latch = true
			_flash_rail(false)
		# The reverse: Ctrl-dragging a detached piece back near its ORIGINAL
		# rail's own line (from the level's Floor.rails, not just wherever
		# the piece happened to be sitting) re-engages it. _home_rail_*
		# survives a detach specifically so this is always possible, not a
		# one-way trip.
		elif rail_axis == "" and _home_rail_axis != "":
			var line := _find_rail_snap(_home_rail_axis, tx if _home_rail_axis == "h" else ty, ty if _home_rail_axis == "h" else tx)
			if line >= 0.0:
				rail_axis  = _home_rail_axis
				rail_start = _home_rail_start
				rail_end   = _home_rail_end
				_rail_lock = line
				_rail_ctrl_latch = true
				_flash_rail(true)
	if rail_axis == "h" and _rail_lock >= 0:
		ty = _rail_lock
		var mn_x := 0.0                              if rail_start < 0 else float(rail_start)
		var mx_x := float(_wall_ref.grid_w - grid_w) if rail_end   < 0 else float(rail_end)
		tx = clampf(tx, mn_x, mx_x)
	elif rail_axis == "v" and _rail_lock >= 0:
		tx = _rail_lock
		var mn_y := 0.0                              if rail_start < 0 else float(rail_start)
		var mx_y := float(_wall_ref.grid_h - grid_h) if rail_end   < 0 else float(rail_end)
		ty = clampf(ty, mn_y, mx_y)
	elif _wall_ref.loop == null:
		tx = clampf(tx, 0.0, float(_wall_ref.grid_w - grid_w))
		ty = clampf(ty, 0.0, float(_wall_ref.grid_h - grid_h))
	# The 2D top-down plan snaps to whole tiles (matching the drawn grid) —
	# only the 3D view keeps continuous, fractional placement. Without this,
	# a piece follows the raw mouse position and can end up sitting between
	# gridlines, making the grid purely decorative here.
	tx = round(tx)
	ty = round(ty)
	if rail_axis == "" and _wall_ref.loop != null:
		# A looped floor: pushed past a seam, the piece carries on from the
		# opening opposite (drawn in two parts while it stands across).
		var wrapped := _wall_ref.wrap_point(Vector2(tx, ty))
		tx = clampf(wrapped.x, 0.0, float(_wall_ref.grid_w - 1))
		ty = clampf(wrapped.y, 0.0, float(_wall_ref.grid_h - 1))
	position = Vector2(tx * TILE_SIZE, ty * TILE_SIZE)
	# Where it would land if let go here (Floor.landing_spot, as the drop
	# does), worked out again only when the tile or the turn changes. The
	# floor's own previews (light, weight on a table) follow the landing spot.
	var key := Vector3(tx, ty, rot_steps)
	if key != _landing_key:
		_landing_key = key
		_landing = _wall_ref.landing_spot(self, _wall_ref.snap_to_wall(self, Vector2(tx, ty)), not _placement_mode)
		_landing_why = _wall_ref.get_block_reason() if _landing == Vector2.INF else ""
	var lands := _landing if _landing != Vector2.INF and Furniture.transfer_hover == 0 else Vector2(tx, ty)
	_wall_ref.set_floor_drag_ghost(self, lands.x, lands.y)
	queue_redraw()


# Silent variant of _rotate() — no sound, no re-placement against the wall —
# used to restore a saved rot_steps value (see Main.gd's nested-level state
# snapshot/restore) without replaying the rotate gesture's side effects.
func set_rot_steps(n: int) -> void:
	n = ((n % 4) + 4) % 4
	var changed := false
	while rot_steps != n:
		rot_steps = (rot_steps + 1) % 4
		var new_w := grid_h
		var new_h := grid_w
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
		changed = true
	# Dimensions just swapped under whatever footprint the floor already has
	# registered at grid_pos (from the initial, un-rotated spawn) — re-place
	# so the occupancy grid matches the new w/h, same as _rotate() does.
	# Only for a piece that is on the floor's books: see _rotate().
	if changed and _wall_ref and _wall_ref.is_registered(self):
		_wall_ref.place_furniture(self, grid_pos)
	queue_redraw()


func _rotate(quiet: bool = false) -> void:
	if not quiet:
		_play("rotate")
	rot_steps = (rot_steps + 1) % 4
	var new_w := grid_h
	var new_h := grid_w
	# Re-register on the floor only if this piece is already placed there. A
	# piece still being bought (R pressed while the ghost follows the cursor,
	# in the plan or in 3D) is not on the floor yet, and place_furniture()
	# would put it there — unvalidated, wherever grid_pos happens to be. If
	# the purchase was then cancelled, or dropped on a wall instead, the node
	# was freed while still on the floor's books, and every later refresh
	# (comfort, functions, accessibility, undo) tripped over the dead entry.
	if _wall_ref and _wall_ref.is_registered(self):
		var cx := clampf(grid_pos.x, 0.0, float(_wall_ref.grid_w - new_w))
		var cy := clampf(grid_pos.y, 0.0, float(_wall_ref.grid_h - new_h))
		# What stands on it turns with it (Floor.turn_riders).
		var riders := _wall_ref.riders_of(self) if is_surface else []
		var old_pos := grid_pos
		var old_w := grid_w
		_wall_ref.begin_batch()
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
		_wall_ref.place_furniture(self, Vector2(cx, cy))
		_wall_ref.turn_riders(self, riders, old_pos, old_w)
		_wall_ref.end_batch()
	else:
		grid_w = new_w
		grid_h = new_h
		rect.size = Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE)
	queue_redraw()


func _end_drag(_mouse_pos: Vector2) -> void:
	_dragging = false
	z_index = stack_z
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = false
		_wall_ref.grid_draw.queue_redraw()
		_wall_ref.clear_floor_drag_ghost()
	queue_redraw()
	var snapped_x := position.x / TILE_SIZE
	var snapped_y := position.y / TILE_SIZE
	if Furniture.on_drag_dropped.is_valid() and Furniture.on_drag_dropped.call(self, get_viewport().get_mouse_position(),
			Vector2(snapped_x + grid_w * 0.5, snapped_y + grid_h * 0.5)):
		return
	var snap_pos := _wall_ref.snap_to_wall(self, Vector2(snapped_x, snapped_y)) if _wall_ref else Vector2(snapped_x, snapped_y)

	# Put down where it can't stand, it lands at the nearest spot where it
	# can (Floor.landing_spot). A red (heavy), non-rail piece shares ONE
	# position across every Moment (see mobility_tier/has_own_moment_position())
	# — moving it is a global edit, so it also has to stay clear of wherever
	# any OTHER piece sits during every OTHER Moment.
	var ok := false
	var nudged := false
	if _wall_ref:
		var land := _wall_ref.landing_spot(self, snap_pos, true)
		ok = land != Vector2.INF
		if ok:
			nudged = land != snap_pos
			snap_pos = land

	# Whatever stands on it comes along; if any of that can't land, nothing moves.
	if ok and not _wall_ref.move_with_riders(self, snap_pos):
		ok = false
	if ok:
		var said := record_moment_move(_original_pos / TILE_SIZE, Input.is_key_pressed(KEY_SHIFT))
		if said == "" and mobility_tier == "red" and rail_axis == "" and Furniture.test_mode_active \
				and Furniture.all_moment_ids.size() > 1:
			said = tr("Moved for every moment")
		if said == "" and nudged:
			said = tr("Moved to where it fits")
		if said != "":
			_notice_reason = said
			_notice_flash_t = NOTICE_FLASH_DURATION
		_play("place")
		_pop_on_place()
		placed.emit(self)
	else:
		_play("error")
		position = _original_pos
		if _wall_ref and _wall_ref.has_method("get_block_reason"):
			var reason := _wall_ref.get_block_reason() as String
			if reason != "":
				_error_reason = reason
				_error_flash_t = ERROR_FLASH_DURATION
				queue_redraw()


# Placement "thunk": quick squash-and-settle around the piece's own centre —
# the classic tactile beat that makes dropping a piece feel like it landed.
func _pop_on_place() -> void:
	if GameState.reduce_motion:
		return
	var center := Vector2(grid_w * TILE_SIZE, grid_h * TILE_SIZE) * 0.5
	var base_pos := position
	scale = Vector2(1.12, 1.12)
	position = base_pos - center * 0.12
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "scale", Vector2.ONE, 0.16) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "position", base_pos, 0.16) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Puts a piece being bought down where it stands. `screen_pos` is where the
# player clicked (or, by touch, the piece's own centre on screen), for drops
# on a box or on Back. Returns whether it went down.
func confirm_placement(screen_pos: Vector2 = Vector2.INF) -> bool:
	if not _placement_mode:
		return false
	if screen_pos == Vector2.INF:
		screen_pos = get_global_transform_with_canvas() * (Vector2(grid_w, grid_h) * TILE_SIZE * 0.5)
	var sx := position.x / TILE_SIZE
	var sy := position.y / TILE_SIZE
	if Furniture.on_purchase_dropped.is_valid() and Furniture.on_purchase_dropped.call(self, screen_pos,
			Vector2(sx + grid_w * 0.5, sy + grid_h * 0.5)):
		return true
	var snap_pos := _wall_ref.snap_to_wall(self, Vector2(sx, sy)) if _wall_ref else Vector2(sx, sy)
	if _wall_ref:
		snap_pos = _wall_ref.landing_spot(self, snap_pos)
	if not _wall_ref or snap_pos == Vector2.INF:
		_play("error")
		if _wall_ref:
			_error_reason = _wall_ref.get_block_reason()
			_error_flash_t = ERROR_FLASH_DURATION
		return false
	_placement_mode = false
	_dragging = false
	_wall_ref.place_furniture(self, snap_pos)
	_wall_ref.grid_draw.show_grid = false
	_wall_ref.grid_draw.queue_redraw()
	_play("place")
	_pop_on_place()
	placement_confirmed.emit()
	queue_redraw()
	return true


# Lets go of a piece being dragged without moving it (a second finger came
# down to zoom, or a long-press turned out to be a request for its actions).
func cancel_drag() -> void:
	if not _dragging or _placement_mode:
		return
	_dragging = false
	z_index = stack_z
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = false
		_wall_ref.grid_draw.queue_redraw()
		_wall_ref.clear_floor_drag_ghost()
	position = _original_pos
	queue_redraw()


func cancel_placement() -> void:
	if not _placement_mode:
		return
	_placement_mode = false
	_dragging = false
	_play("click")
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = false
		_wall_ref.grid_draw.queue_redraw()
	placement_cancelled.emit()
	if _wall_ref:
		_wall_ref.clear_floor_drag_ghost()   # a table it was held over stops showing its weight
		_wall_ref.forget_furniture(self)   # never leave a freed node on the floor's books
	queue_free()


func begin_placement(apt_floor: Floor, mouse_pos: Vector2) -> void:
	_wall_ref       = apt_floor
	_placement_mode = true
	_dragging       = true
	_drag_offset    = -Vector2(grid_w, grid_h) * TILE_SIZE * 0.5
	_landing_key    = Vector3.INF
	z_index         = 10
	if _wall_ref:
		_wall_ref.grid_draw.show_grid = true
		_wall_ref.grid_draw.wall_cue = wall_flush_required   # light up the walls it can go against
		_wall_ref.grid_draw.queue_redraw()
	_drag(mouse_pos)
	queue_redraw()
