extends Control
class_name Room3DView

# Low-poly 3D room view, built as a diorama from the same data the 2D
# blueprint views use (grid_w/h, wall_h, floor_depth, color). Floor furniture
# here is a first-class interactive surface, not just a "wow moment" reveal:
# it can be picked up, dragged, bought, and sold directly in 3D, going through
# the exact same Floor.can_place/snap_to_wall/place_furniture calls the 2D
# views use — there's only one source of truth (Floor), this is just another
# way to look at and edit it. Wall-mounted items aren't editable here yet.

signal closed
signal sell_requested(furniture: Furniture)   # right-click on a floor piece — Main.gd handles the refund
signal buy_confirmed(furniture: Furniture)    # a piece bought via start_buying() was placed on the floor
signal buy_confirmed_wall(furniture_id: String, edge: String, origin: Vector2i)  # ...or on a wall instead
signal buy_cancelled(furniture: Furniture)    # the same, but the purchase was backed out (Esc)
signal wall_sell_requested(edge: String, origin: Vector2i)   # right-click on a wall piece
signal furniture_moved(furniture: Furniture)   # an existing piece was dragged to a new spot and committed
signal reveal_finished   # a play_reveal() flythrough finished its scripted camera move
signal box_enter_requested(furniture: Furniture)   # a nested box was double-clicked — Main.gd steps into it
signal piece_long_pressed(furniture: Furniture)   # a finger held still on a floor piece: show its actions
signal wall_item_long_pressed(hit: Dictionary)    # ...or on a wall piece
signal showcase_stop_changed(moment_id: String, needs: Array)   # tenant showcase moved to a new stop — Main.gd rings the matching TenantCard chip(s)

const TILE_M      := 0.1     # metres per tile (10 cm) — matches the 2D views
const WALL_TILES  := 24      # matches WallInspector.WALL_HEIGHT (2.4 m ceiling)
const WALL_H_M    := WALL_TILES * TILE_M
const WALL_THICK  := 0.1

@onready var container:  SubViewportContainer = $SubViewportContainer
@onready var sub_vp:     SubViewport          = $SubViewportContainer/SubViewport
@onready var cam:        Camera3D             = $SubViewportContainer/SubViewport/World/Cam
@onready var build_root: Node3D               = $SubViewportContainer/SubViewport/World/BuildRoot
@onready var close_btn:  Button               = $CloseBtn
@onready var _sun:       DirectionalLight3D   = $SubViewportContainer/SubViewport/World/Light
@onready var _world_env: WorldEnvironment     = $SubViewportContainer/SubViewport/World/WorldEnvironment

# Diorama look (res://style/): one palette per level drives the materials,
# light, fog and backdrop. Purely presentational — picking, dragging and
# placement never read it. Set USE_DIORAMA_STYLE to false to get the previous
# plain-material rendering back.
const USE_DIORAMA_STYLE := true
var _style: StyleController = null
var _palette: LevelPalette = null
# Long lens for the styled view: nearly parallel lines, so the room reads as a
# diorama instead of a wide-angle interior. The camera is simply moved further
# back by _cam_dist_scale so the room fills the frame exactly as before —
# _dist, zoom limits, pan speed and every ray-based pick keep their meaning.
const STYLE_FOV := 26.0
var _cam_dist_scale: float = 1.0

# ── Sims-style view controls ────────────────────────────────────────────────
# Wall display: UP shows every wall at full height, DOWN lowers them all to
# stubs, CUTAWAY (the default) lowers only what is in the way — see
# _update_wall_visibility(). Static, so the choice survives this view being
# torn down and rebuilt (switching to the floor plan and back, a new level).
enum WallMode { UP, CUTAWAY, DOWN }
# i18n-const
const WALL_MODE_LABELS := ["Walls: Up", "Walls: Cutaway", "Walls: Down"]
static var wall_mode: int = WallMode.CUTAWAY
var _walls_btn: Button = null
# Q / E turn the view a quarter at a time, onto one of the four diagonal
# views; free orbit (middle-drag) is still there for anything in between.
const TURN_SECONDS := 0.28
var _turn_tween: Tween = null
var _turn_target: float = 0.0   # where a turn in progress is heading, so a second tap adds to it
const KEY_PAN_SPEED := 0.55   # W/A/S/D: fraction of the camera distance covered per second
var _travel_tween: Tween = null            # a level-transition camera move in progress, see travel_camera()
var _next_camera_state: Dictionary = {}    # see set_next_camera_state()
var _next_camera_until_ms: int = -1       # builds up to this moment apply _next_camera_state
# Inside a nested box: the apartment the box sits in, drawn giant around this
# room as inert scenery (see set_parent_scenery / _add_parent_scenery).
var _parent_scenery: Dictionary = {}
var _scenery_nodes: Array = []   # [{node: Node3D, center: Vector3}] — hidden while on the camera's side
const PLINTH_DEPTH_M := 1.6   # how far the block under the floor reaches before it has dissolved
const ACCENT_MAX_AREA_TILES := 16   # decor at most this big (e.g. 4x4 tiles) takes the accent colour

var _yaw:     float   = -45.0
var _pitch:   float   = -32.0
var _dist:    float   = 6.0
var _center:  Vector3 = Vector3.ZERO
var _dragging: bool   = false   # middle-drag — orbits yaw/pitch (Blender-style MMB)
var _panning: bool    = false   # left-drag over empty floor — translates _center
var _auto_spin: bool  = false
var _press_pos: Vector2 = Vector2.ZERO
var _press_ms := 0                       # when the current press began, for a touch long-press
var _press_moved := false                # the pointer has left the press spot since
var _buy_touch_vp := Vector2.INF         # where a finger last put the piece being bought
var _orbit_press_pos: Vector2 = Vector2.ZERO   # separate from _press_pos so a MMB click-to-recenter doesn't fight LMB click tracking
const CLICK_MOVE_THRESHOLD := 10.0   # px; was 6 — tight enough that an ordinary click's natural hand jitter routinely misfired as "dragged it", especially when the intent was just to fold/unfold a piece

# "Home" framing captured whenever a real apartment room is built — lets a
# plain middle-click (no drag) snap the camera back after free panning, since
# unlike orbit-only cameras, panning has no other way back to a lost room.
var _home_center: Vector3 = Vector3.ZERO
var _home_dist:   float   = 6.0
const HOME_YAW   := -45.0
const HOME_PITCH := -32.0
const PAN_MARGIN_M := 2.0   # how far past the room's own walls the camera target may be panned

var _reveal_playing: bool = false   # true while play_reveal()'s scripted camera move is running

# Set by Main.gd for the post-win "View Apartment" free-look mode — the level
# is already rented out, so nothing should be movable/sellable/buyable there,
# only the camera. Left unset (false) for the normal editable 3D view.
var read_only: bool = false

# Floor-furniture dragging: reach back into the live Floor this diorama was
# built from so a drag here actually moves the piece (unlike everything else
# in this file, which is throwaway presentation geometry). Wall-mounted items
# aren't draggable here, just the floor-standing boxes from _add_furniture_box.
var _apt_floor:    Floor  = null
var _room_bounds:  Rect2i = Rect2i()
var _catalog: Array = []   # furniture data array, kept for wall-item placement/validation math
var _room_w_m: float = 0.0
var _room_d_m: float = 0.0
var _furniture_entries: Array = []   # [{furniture, mesh, pos, size}]
var _dragging_furniture: bool = false
var _drag_target:   Dictionary = {}
var _drag_offset:   Vector2    = Vector2.ZERO   # tile-space grab offset
var _drag_orig_pos: Vector3    = Vector3.ZERO
var _drag_last_tile: Vector2   = Vector2.ZERO   # continuous — 3D drag is no longer grid-snapped
var _drag_rail_lock: float     = -1.0   # locked cross-axis tile coord for a rail_axis item; -1 = not on a rail

# Wall-mounted items: rendered by _add_wall_item_box, but (unlike floor
# furniture) they have no live Furniture node — Floor just tracks them as
# {origin: fid} strings per edge. Dragging/selling them here has to go
# through Floor.place_wall_item/remove_wall_item directly instead.
const WALL_HEIGHT_TILES := WALL_TILES
var _wall_item_entries: Array = []   # [{edge, origin, fid, mesh, iw, ih}]
var _dragging_wall_item: bool = false
var _drag_wall_target:   Dictionary = {}

# Buying a new item directly in 3D: Main.gd instantiates+setup()s the
# Furniture node (same as it does for the 2D purchase flow) and hands it here
# via start_buying() instead of Furniture.begin_placement(); everything after
# that — ghost follow, snap, commit — reuses the drag machinery above. The
# ghost can land on the floor OR on a wall, decided each frame by whichever
# the cursor ray is actually pointing at.
var _buying_furniture: Furniture = null
var _buying_fdata: Dictionary = {}
var _buying_mesh: MeshInstance3D = null
var _buying_on_wall: bool = false   # last hover: floor ghost or wall ghost?

# Walls between the camera and the room center are hidden so the view isn't
# blocked — each entry is {mesh: MeshInstance3D, mat: StandardMaterial3D, normal: Vector3, base: Color}.
var _wall_data: Array = []
var _grid_overlay: MeshInstance3D = null   # tile grid shown only while placing/dragging furniture
var _wall_grid_overlays: Array = []         # one grid quad per wall, same show-only-while-placing behavior
var _hitbox_highlights: Array = []          # one outline per placed floor item, shown alongside the grid
var _drag_highlight: Node3D = null          # follows the item currently being dragged (floor moves + buy-ghost)
var _cam_flat_dir: Vector3 = Vector3.ZERO   # XZ camera direction from center, set by _update_wall_visibility

# ── Placement-rejection feedback ────────────────────────────────────────────
# The 3D view reused Floor.can_place()'s true/false result but never surfaced
# *why* — no sound, no tint, no reason — so a blocked drop here just silently
# snapped back with nothing happening, unlike the 2D view's red tint + reason
# chip. _reason_label follows the cursor while dragging/buying is invalid,
# and lingers briefly (fading) after a rejected drop/confirm.
var _reason_label: Label = null
var _last_local_mouse: Vector2 = Vector2.ZERO
var _reason_flash_t: float = 0.0
const REASON_FLASH_DURATION := 1.4
var _wall_block_reason: String = ""   # set by _can_place_wall_item, mirrors Wall.get_block_reason()

# ── Foldable-item demo (single-item preview only) ──────────────────────────
# Click the item to toggle folded/extended; before the first click it loops
# on its own so the player can see the transform without touching anything.
const FOLD_LOOP_SPEED   := 1.1   # radians/sec fed into sin() — ~5.7s per cycle
const FOLD_MANUAL_SPEED := 2.2   # fold_t units/sec once the player takes over
var _foldable:    bool    = false
var _fold_auto:   bool    = true
var _fold_t:      float   = 0.0   # 0 = folded/closed, 1 = extended/open
var _fold_target: float   = 0.0
var _fold_phase:  float   = 0.0
var _fold_mesh:   MeshInstance3D = null
var _fold_closed_size: Vector3 = Vector3.ONE
var _fold_closed_pos:  Vector3 = Vector3.ZERO
var _fold_open_size:   Vector3 = Vector3.ONE
var _fold_open_pos:    Vector3 = Vector3.ZERO
var _fold_fdata: Dictionary = {}   # kept so _update_fold_visual can look up model/model_extended
var _fold_model_extended_shown: bool = false   # which of the two real models is currently applied


func _ready() -> void:
	_setup_style()
	_walls_btn = Button.new()
	_walls_btn.name = "WallModeBtn"
	_walls_btn.focus_mode = Control.FOCUS_NONE   # must never take the keyboard: Q/E/WASD belong to the view
	GameTheme.hud_button(_walls_btn)
	_walls_btn.tooltip_text = tr("How walls are shown (Home / End)\nUp: all at full height\nCutaway: only those in the way are lowered\nDown: all lowered")
	_walls_btn.anchor_left = 1.0
	_walls_btn.anchor_right = 1.0
	_walls_btn.offset_left = -232.0
	_walls_btn.offset_right = -12.0
	_walls_btn.offset_top = 76.0
	_walls_btn.offset_bottom = 76.0 + GameTheme.TOUCH_SMALL
	_walls_btn.visible = false   # shown once a room (not a single-item preview) is built
	_walls_btn.pressed.connect(func(): set_wall_mode((wall_mode + 1) % WallMode.size()))
	add_child(_walls_btn)
	close_btn.pressed.connect(func(): closed.emit())
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_container_input)


func _setup_style() -> void:
	if not USE_DIORAMA_STYLE:
		return
	# The scene's Environment is a shared sub-resource; this view restyles it,
	# so it takes its own copy rather than recolouring every other open view.
	_world_env.environment = _world_env.environment.duplicate()
	_style = StyleController.new()
	_style.name = "StyleController"
	_style.world_environment = _world_env
	_style.sun = _sun
	_style.camera = cam
	_style.level_root = build_root
	_style.room_height = WALL_H_M
	_style.floor_thickness = 0.05
	_style.manage_global_shadows = false   # shadow atlas settings are engine-wide; other views share them
	_style.palette = _palette if _palette != null else PaletteLibrary.default_palette()
	_style.quality = GameState.graphics_quality as StyleQuality.Level
	InkLines.attach(cam)
	InkLines.set_palette(_style.palette)
	GameState.graphics_quality_changed.connect(func(level: int):
		_style.quality = level as StyleQuality.Level)
	build_root.get_parent().add_child(_style)
	_cam_dist_scale = tan(deg_to_rad(cam.fov) * 0.5) / tan(deg_to_rad(STYLE_FOV) * 0.5)
	cam.fov = STYLE_FOV
	# Sun from the home camera's left: of the two walls the home view looks
	# at, one is well lit and the other still catches some light, and shadows
	# fall across open floor to the right instead of straight behind things.
	_sun.look_at_from_position(Vector3(-0.75, 0.85, 0.3) * 10.0, Vector3.ZERO, Vector3.UP)


# Picks this level's palette: its own "palette" entry if it has one, else the
# palette closest in hue to its block colour. Call before build_from_floor().
func set_level_style(level: Dictionary, levels_data: Dictionary) -> void:
	_palette = PaletteLibrary.for_level(level, levels_data)
	if _style != null and _palette != null:
		_style.palette = _palette
		InkLines.set_palette(_palette)


func _style_node(node: Node, role: StringName) -> void:
	if _style != null:
		_style.style_node(node, role)


# The model instance parented to a placeholder box, or null if it has none
# (a piece with no model file). has_meta first: get_meta with a null default
# still logs an engine error for a missing key.
func _model_of(mi: MeshInstance3D) -> Variant:
	return mi.get_meta("model_inst") if mi.has_meta("model_inst") else null


# A furniture/wall-item placeholder box that got no model stays visible as a
# plain box, so it takes the furniture tint. One that did get a model is left
# alone: it's an invisible hitbox, and its own material is what hides it.
func _style_if_bare(mi: MeshInstance3D) -> void:
	if _style != null and not is_instance_valid(_model_of(mi)):
		_style.style_node(mi, mi.get_meta("style_role", StyleController.ROLE_FURNITURE))


# The palette's accent colour is kept for small decorative pieces (a plant, a
# lamp, a stack of books): things with no function of their own and a small
# footprint. Everything else is a tint of the level hue.
func _item_role(fdata: Dictionary) -> StringName:
	var item_size := fdata.get("size", {}) as Dictionary
	var area := (item_size.get("w", 99) as int) * (item_size.get("h", 99) as int)
	if (fdata.get("functions", []) as Array).is_empty() and area <= ACCENT_MAX_AREA_TILES \
			and not fdata.get("is_nested_box", false):
		return StyleController.ROLE_ACCENT
	return StyleController.ROLE_FURNITURE


# Hands over what to draw around the room on the next build_from_floor():
#   segments  the parent floor's wall segments (tile coordinates)
#   items     [{fdata, x, y, rot_steps, is_extended}] — its furniture
#   box_rect  Rect2 in the same tiles: where this room's box sits in it
# {} (the default) means "not inside a box", and the room floats on its
# plinth as usual. Call before build_from_floor().
func set_parent_scenery(data: Dictionary) -> void:
	_parent_scenery = data


# While a piece is carried: where it can't go, on the floor (Floor.carry_hints()):
# other pieces' clearance as amber outlines, flooring it can't stand on and a
# ceiling too low for it as a red tint, and the loft's load as a label.
var _hints_for: Furniture = null
var _hint_nodes: Array = []

func _show_carry_hints(carried: Furniture) -> void:
	_hints_for = carried
	for n in _hint_nodes:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_hint_nodes.clear()
	if carried == null or not is_instance_valid(_apt_floor) or not is_instance_valid(build_root):
		return
	var hints := _apt_floor.carry_hints(carried)
	var origin := Vector2(_room_bounds.position)
	for r in hints["clearance"] as Array:
		var z := r as Rect2
		var group := _build_outline_group(z.size * TILE_M, Color(0.98, 0.78, 0.30, 0.7), HITBOX_Y + 0.003)
		group.position.x = (z.position.x - origin.x) * TILE_M
		group.position.z = (z.position.y - origin.y) * TILE_M
		build_root.add_child(group)
		_hint_nodes.append(group)
	var tiles: Array = (hints["bad_floor"] as Array) + (hints["low_ceiling"] as Array)
	if not tiles.is_empty():
		var verts := PackedVector3Array()
		for rr in RuleOverlay._runs(tiles):
			var px := rr as Rect2   # plan pixels: TILE per tile
			var x0 := (px.position.x / RuleOverlay.TILE - origin.x) * TILE_M
			var z0 := (px.position.y / RuleOverlay.TILE - origin.y) * TILE_M
			var x1 := x0 + px.size.x / RuleOverlay.TILE * TILE_M
			var z1 := z0 + px.size.y / RuleOverlay.TILE * TILE_M
			var y := HITBOX_Y + 0.002
			verts.append_array([Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1),
				Vector3(x0, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.93, 0.30, 0.24, 0.28)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		build_root.add_child(mi)
		_hint_nodes.append(mi)
	# Door swings (a red fan on the floor) and where others stand in other
	# moments (a violet outline), as on the plan.
	for s in hints.get("doors", []) as Array:
		var swing := s as Dictionary
		var hinge := ((swing["hinge"] as Vector2) - origin) * TILE_M
		var d: Vector2 = swing["dir"]
		var r := (swing["r"] as float) * TILE_M
		var a0 := atan2(0.0, d.x)
		var a1 := atan2(d.y, 0.0)
		var fan := PackedVector3Array()
		var y := HITBOX_Y + 0.003
		for i in 12:
			var p0 := Vector2(cos(lerp_angle(a0, a1, i / 12.0)), sin(lerp_angle(a0, a1, i / 12.0))) * r + hinge
			var p1 := Vector2(cos(lerp_angle(a0, a1, (i + 1) / 12.0)), sin(lerp_angle(a0, a1, (i + 1) / 12.0))) * r + hinge
			fan.append_array([Vector3(hinge.x, y, hinge.y), Vector3(p0.x, y, p0.y), Vector3(p1.x, y, p1.y)])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = fan
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.93, 0.30, 0.24, 0.30)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		build_root.add_child(mi)
		_hint_nodes.append(mi)
	for z in hints.get("moments", []) as Array:
		var zr := (z as Dictionary)["rect"] as Rect2
		var group := _build_outline_group(zr.size * TILE_M, Color(0.72, 0.56, 0.98, 0.85), HITBOX_Y + 0.004)
		group.position.x = (zr.position.x - origin.x) * TILE_M
		group.position.z = (zr.position.y - origin.y) * TILE_M
		build_root.add_child(group)
		_hint_nodes.append(group)
	var loft := hints["loft"] as Dictionary
	if not loft.is_empty():
		var lt := loft["tiles"] as Array
		var c := Vector2.ZERO
		for t in lt:
			c += Vector2(t as Vector2i)
		c = c / lt.size() + Vector2(0.5, 0.5)
		var over := (loft["load"] as float) + (loft["weight"] as float) > (loft["max"] as float)
		var label := Label3D.new()
		label.text = tr("Loft: %.0f / %.0f, this adds %.0f") % [loft["load"], loft["max"], loft["weight"]]
		label.font_size = 36
		label.pixel_size = 0.003 * clampf(maxf(_room_w_m, _room_d_m) / 2.5, 1.0, 3.0)
		label.modulate = Color(0.93, 0.30, 0.24) if over else Color(0.98, 0.78, 0.30)
		label.outline_size = 10
		label.outline_modulate = Color(0.04, 0.08, 0.14, 0.9)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.position = Vector3((c.x - origin.x) * TILE_M, WALL_H_M * 0.6, (c.y - origin.y) * TILE_M)
		build_root.add_child(label)
		_hint_nodes.append(label)


# Pieces moved away from where they started (Main._show_moved_from_home()):
# a faint outline on the floor of each one's old spot.
var _home_marks: Array = []
var _home_outlines: Array = []

func set_home_marks(marks: Array) -> void:
	if marks == _home_marks:
		return
	_home_marks = marks
	_build_home_outlines()


func _build_home_outlines() -> void:
	for n in _home_outlines:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_home_outlines.clear()
	if _room_w_m <= 0.0 or not is_instance_valid(build_root):
		return
	for m in _home_marks:
		var mark := m as Dictionary
		var size := (mark["size"] as Vector2) * TILE_M
		var group := _build_outline_group(size, Color(0.98, 0.82, 0.40, 0.8), HITBOX_Y + 0.002)
		var home := mark["home"] as Vector2
		group.position.x = (home.x - _room_bounds.position.x) * TILE_M
		group.position.z = (home.y - _room_bounds.position.y) * TILE_M
		build_root.add_child(group)
		_home_outlines.append(group)
		var cost := Label3D.new()
		cost.text = mark["cost"] as String
		cost.font_size = 36
		cost.pixel_size = 0.003 * clampf(maxf(_room_w_m, _room_d_m) / 2.5, 1.0, 3.0)
		cost.modulate = Color(0.98, 0.82, 0.40)
		cost.outline_size = 10
		cost.outline_modulate = Color(0.04, 0.08, 0.14, 0.9)
		cost.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		_flat_labels.append(cost)
		cost.position = Vector3(group.position.x + size.x * 0.5, HITBOX_Y + 0.004, group.position.z + size.y * 0.5)
		build_root.add_child(cost)
		_home_outlines.append(cost)


# Outside walls whose rules pass into a box nearest them (Main._show_outside_walls):
# each gets its name and what it does lettered on the ground just outside it,
# like a street name on the pavement (standing up, it hid the room).
var _outside_walls: Array = []
var _outside_signs: Array = []

func set_outside_walls(walls: Array) -> void:
	if walls == _outside_walls:
		return
	_outside_walls = walls
	_build_outside_signs()


func _build_outside_signs() -> void:
	for n in _outside_signs:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_outside_signs.clear()
	if _room_w_m <= 0.0 or not is_instance_valid(build_root):
		return
	for wl in _outside_walls:
		var wall := wl as Dictionary
		var ground := DESK_MAT_Y + 0.01 if _parent_scenery.is_empty() else -0.05
		var at := Vector3(_room_w_m * 0.5, ground, _room_d_m * 0.5)
		var turn := 0.0
		match wall["side"]:
			"north": at.z = -0.45
			"south": at.z = _room_d_m + 0.45
			"east":
				at.x = _room_w_m + 0.45
				turn = 90.0
			"west":
				at.x = -0.45
				turn = -90.0
		var plate3d := Label3D.new()
		plate3d.text = "%s\n%s" % [wall["name"], wall["rules"]]
		plate3d.font_size = 40
		plate3d.pixel_size = 0.0035 * clampf(maxf(_room_w_m, _room_d_m) / 2.5, 1.0, 3.0)
		plate3d.modulate = Color(0.98, 0.78, 0.36)
		plate3d.outline_size = 12
		plate3d.outline_modulate = Color(0.04, 0.08, 0.14, 0.9)
		plate3d.rotation_degrees = Vector3(-90.0, turn, 0.0)
		_flat_labels.append(plate3d)
		plate3d.double_sided = true
		plate3d.position = at
		build_root.add_child(plate3d)
		_outside_signs.append(plate3d)


# How much daylight reaches this room, 0..1: less inside a box that stands in
# the shadow of something in the flat around it (Main._compute_box_occlusion).
var _daylight := 1.0

func set_daylight(factor: float) -> void:
	_daylight = factor
	if _style != null:
		_style.daylight = factor


# ── What noise and shade do, shown on the pieces ────────────────────────────
# A piece whose noise keeps a bed from working has sound coming off it; the
# bed gets a struck-through "Zz". A box in another piece's shadow has its
# little windows dimmed, as much as less daylight gets into it. All of it
# read from what Main last worked out (Furniture._noise_*, _shade), twice a
# second.
const NOISE_COLOR := Color(0.98, 0.70, 0.22)
const AWAKE_COLOR := Color(0.93, 0.28, 0.22)
var _status_t := 0.0

func _sync_status_marks() -> void:
	for entry in _furniture_entries:
		var f := entry.get("furniture") as Furniture
		var mi := entry.get("mesh") as MeshInstance3D
		if not is_instance_valid(f) or not is_instance_valid(mi):
			continue
		var want := "awake" if (f.needs_quiet and f._noise_muted) else ("noise" if f._noise_making else "")
		if mi.get_meta("status_kind", "") != want:
			var old = mi.get_meta("status_mark") if mi.has_meta("status_mark") else null
			if is_instance_valid(old):
				(old as Node).queue_free()
			mi.set_meta("status_kind", want)
			mi.remove_meta("status_mark")
			if want != "":
				# Big enough to read from the whole room's view, in a big room too.
				var ms := clampf(maxf(_room_w_m, _room_d_m) / 2.5, 1.0, 3.0)
				var mark := _status_mark(want, ms)
				mark.position.y = (entry["size"] as Vector3).y * 0.5 + 0.12 * ms
				mi.add_child(mark)
				mi.set_meta("status_mark", mark)
		if f.is_nested_box:
			_shade_box_windows(mi, f._shade)
			_strap_box(entry, f.mobility_tier)


# A box as full as its tier: a band of tape round its walls once it is heavy
# (yellow), and a dark strap over it crosswise once it is packed full (red),
# the same as on the plan.
func _strap_box(entry: Dictionary, tier: String) -> void:
	var mi := entry["mesh"] as MeshInstance3D
	if mi.get_meta("strap_tier", "") == tier:
		return
	mi.set_meta("strap_tier", tier)
	if mi.has_meta("straps") and is_instance_valid(mi.get_meta("straps")):
		(mi.get_meta("straps") as Node).queue_free()
	mi.remove_meta("straps")
	if tier != "yellow" and tier != "red":
		return
	var straps := Node3D.new()
	straps.name = "Straps"
	mi.add_child(straps)
	mi.set_meta("straps", straps)
	# The box's own frame: mi is turned with the box, so its canonical size.
	var size: Vector3 = (mi.mesh as BoxMesh).size if mi.mesh is BoxMesh else entry["size"]
	var walls_h := size.y * 0.55   # the walls, below the roof of the house-shaped models
	var bottom := -size.y * 0.5
	var add_band := func(band_size: Vector3, pos: Vector3, col: Color) -> void:
		var band := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = band_size
		band.mesh = bm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.roughness = 0.9
		band.material_override = mat
		band.position = pos
		straps.add_child(band)
	var pad := 0.006
	add_band.call(Vector3(size.x + pad, walls_h * 0.16, size.z + pad), Vector3(0, bottom + walls_h * 0.55, 0), Furniture.TAPE_COLOR)
	if tier == "red":
		var t := maxf(size.x, size.z) * 0.09
		add_band.call(Vector3(t, walls_h + pad, size.z + pad * 2.0), Vector3(0, bottom + walls_h * 0.5, 0), Furniture.STRAP_COLOR)
		add_band.call(Vector3(size.x + pad * 2.0, walls_h + pad, t), Vector3(0, bottom + walls_h * 0.5, 0), Furniture.STRAP_COLOR)


# A floating mark: "noise" (sound arcs) or "awake" (a struck-through Zz in
# the sound), `s` times its normal size. Always drawn facing the camera and
# over whatever is in front of it.
func _status_mark(kind: String, s: float) -> Node3D:
	var root := Node3D.new()
	root.name = "StatusMark"
	var col := AWAKE_COLOR if kind == "awake" else NOISE_COLOR
	var arcs := MeshInstance3D.new()
	arcs.mesh = _sound_arcs_mesh(s)
	arcs.material_override = _mark_material(col)
	arcs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(arcs)
	if kind == "awake":
		var zz := Label3D.new()
		zz.text = "Zz"
		zz.font_size = 48
		zz.pixel_size = 0.0028 * s
		zz.modulate = col
		zz.outline_size = 10
		zz.outline_modulate = Color(1, 1, 1, 0.9)
		zz.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		zz.no_depth_test = true
		zz.render_priority = 11
		zz.outline_render_priority = 10
		root.add_child(zz)
		var strike := MeshInstance3D.new()
		var bar := QuadMesh.new()
		bar.size = Vector2(0.11, 0.012) * s
		strike.mesh = bar
		strike.material_override = _mark_material(col)
		strike.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(strike)
	return root


func _mark_material(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 12
	return mat


# Three arcs either side of a point, like sound going out both ways.
func _sound_arcs_mesh(s: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var thick := 0.009 * s
	for side in [-1.0, 1.0]:
		for r in [0.05, 0.08, 0.11]:
			var rr: float = r * s
			var steps := 6
			for i in steps:
				var a0 := lerpf(-0.85, 0.85, float(i) / steps)
				var a1 := lerpf(-0.85, 0.85, float(i + 1) / steps)
				var p0 := Vector3(side * cos(a0) * rr, sin(a0) * rr, 0.0)
				var p1 := Vector3(side * cos(a1) * rr, sin(a1) * rr, 0.0)
				var q0 := Vector3(side * cos(a0) * (rr + thick), sin(a0) * (rr + thick), 0.0)
				var q1 := Vector3(side * cos(a1) * (rr + thick), sin(a1) * (rr + thick), 0.0)
				verts.append_array([p0, p1, q1, p0, q1, q0])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# The box's windows (its model's "lamp" material, which glows) shine only as
# much as daylight gets in. Works on a copy per box, kept in step with the
# shared material it came from (which changes from day to night).
func _shade_box_windows(mi: MeshInstance3D, factor: float) -> void:
	if not mi.has_meta("model_inst") or not is_instance_valid(mi.get_meta("model_inst")):
		return
	var parts: Array = [mi.get_meta("model_inst")]
	while not parts.is_empty():
		var n := parts.pop_back() as Node
		parts.append_array(n.get_children())
		if not (n is MeshInstance3D) or (n as MeshInstance3D).mesh == null:
			continue
		var m := n as MeshInstance3D
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			if src == null or src.resource_name != "lamp":
				continue
			var cur := m.get_surface_override_material(i)
			var base: Material = cur.get_meta("shade_src") if cur != null and cur.has_meta("shade_src") else cur
			if not (base is ShaderMaterial):
				continue
			if factor >= 0.99:
				if cur != base:
					m.set_surface_override_material(i, base)
				continue
			var dim: ShaderMaterial = cur if cur != base else (base as ShaderMaterial).duplicate()
			dim.set_meta("shade_src", base)
			var energy = (base as ShaderMaterial).get_shader_parameter("emission_energy")
			# Squared: half the daylight should read as clearly dimmer windows.
			dim.set_shader_parameter("emission_energy", (energy as float if energy != null else 1.0) * factor * factor)
			m.set_surface_override_material(i, dim)


func _no_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_no_shadows(child)


# Draws the parent apartment around this room, scaled up so the box's outer
# footprint matches the room: you are standing inside the box, looking out at
# your own giant furniture. Scenery only — none of it is added to the pick or
# drag lists, it casts no shadows (the box's daylight is already modelled by
# the game's own occlusion value), and anything on the camera's side is
# hidden so it can't block the view, the same idea as lowering near walls.
# How far the camera may pull back. Inside a box the apartment around it is
# drawn giant, and pulling back far enough put the camera outside those giant
# walls, with one of them filling the screen: there, the limit is a little
# beyond the view the room opens with.
func _max_dist() -> float:
	if not _parent_scenery.is_empty():
		return minf(30.0, maxf(_home_dist * 1.5, 3.0))
	return 30.0


func _add_parent_scenery(w: float, d: float) -> bool:
	if _style == null or _parent_scenery.is_empty():
		return false
	var box: Rect2 = _parent_scenery.get("box_rect", Rect2())
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return false
	_scenery_level(_parent_scenery, 0.0, 0.0, w, d, -0.055, true)   # just under this room's own floor slab
	_style.apply()   # the scenery floor's board size depends on the scale just set
	return true


# One apartment drawn giant around a footprint (x0, z0, w, d, in view metres)
# that stands where its box stands in that apartment. Then the same again for
# the apartment THAT one stands in (data["outer"]), around its floor, and so
# on outward; the outermost one stands on the desk.
func _scenery_level(data: Dictionary, x0: float, z0: float, w: float, d: float, floor_y: float, first: bool) -> void:
	var box: Rect2 = data.get("box_rect", Rect2())
	if box.size.x <= 0.0 or box.size.y <= 0.0:
		return
	# Big enough that the box's footprint covers the whole room, so nothing
	# of the parent's can end up inside it.
	var s := maxf(w / (box.size.x * TILE_M), d / (box.size.y * TILE_M))
	var box_center := box.get_center()
	var to_view := func(tx: float, ty: float) -> Vector3:
		return Vector3((tx - box_center.x) * TILE_M * s + x0 + w * 0.5, 0.0, (ty - box_center.y) * TILE_M * s + z0 + d * 0.5)
	if first:
		_style.scenery_scale = s
	var pieces: Array = []   # for the household, see _add_parent_household

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var segments := data.get("segments", []) as Array
	for sd in segments:
		var seg := sd as Dictionary
		for p in [Vector2(seg["x1"] as float, seg["y1"] as float), Vector2(seg["x2"] as float, seg["y2"] as float)]:
			lo = lo.min(p)
			hi = hi.max(p)
	if lo.x > hi.x:
		lo = box.position - Vector2(20, 20)
		hi = box.end + Vector2(20, 20)

	# The parent's furniture, built first because the box may stand on some of
	# it: a box on a table has that table under the room, and the parent's
	# floor a table's height further down. Each piece stands on the floor or
	# on the surface under it (as Floor.support_under() decides in the game),
	# at the height that surface is drawn.
	var placed: Array = []   # [{rect, fdata, mi, height}] in the order they were stacked up
	var items: Array = []
	for it in data.get("items", []) as Array:
		var item := it as Dictionary
		var fdata := item.get("fdata", {}) as Dictionary
		var size_t := fdata.get("size", {}) as Dictionary
		var rot: int = item.get("rot_steps", 0) as int
		var tw := (size_t.get("w", 4) as float)
		var th := (size_t.get("h", 4) as float)
		var foot := Vector2(th, tw) if rot % 2 == 1 else Vector2(tw, th)
		items.append({"item": item, "fdata": fdata, "rot": rot, "tw": tw, "th": th, "foot": foot,
			"rect": Rect2(Vector2(item.get("x", 0) as float, item.get("y", 0) as float), foot)})
	var support_of := func(rect: Rect2, self_i: int) -> int:
		var best := -1
		for j in items.size():
			var o := items[j] as Dictionary
			if j != self_i and (o["fdata"] as Dictionary).get("is_surface", false) and (o["rect"] as Rect2).encloses(rect) 					and (best < 0 or (o["rect"] as Rect2).get_area() < (items[best]["rect"] as Rect2).get_area()):
				best = j
		return best
	var depth_of := func(i: int) -> int:
		var n := 0
		var cur := i
		while n < 6:
			cur = support_of.call(items[cur]["rect"], cur)
			if cur < 0:
				break
			n += 1
		return n
	var box_support: int = support_of.call(box, -1)
	var order: Array = range(items.size())
	order.sort_custom(func(a, b): return depth_of.call(a) < depth_of.call(b))
	var top_rel: Dictionary = {}   # item index -> its top above the parent's floor, as drawn
	for i in order:
		var e := items[i] as Dictionary
		var rect: Rect2 = e["rect"]
		var under_box := false
		var cur := box_support
		while cur >= 0 and not under_box:
			under_box = cur == i
			cur = support_of.call(items[cur]["rect"], cur)
		if rect.intersects(box) and not under_box:
			continue   # the box itself, and anything sharing its tiles
		var fdata := e["fdata"] as Dictionary
		var height := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2) * s
		var canon := Vector3((e["tw"] as float) * TILE_M * s, height, (e["th"] as float) * TILE_M * s)
		var sup: int = support_of.call(rect, i)
		var lift: float = top_rel.get(sup, 0.0) if sup >= 0 else 0.0
		var c: Vector3 = to_view.call(rect.get_center().x, rect.get_center().y)
		var mi := _box(canon, Vector3(c.x, lift + height * 0.5, c.z), Color("#" + (fdata.get("color", "888888") as String)))
		if first and fdata.get("is_noisy", false) and rect.grow(1.0).intersects(box):
			# What is keeping this room awake (see Main._has_noisy_neighbor).
			var noise := _status_mark("noise", s)
			noise.position.y = height * 0.5 + 0.12 * s
			mi.add_child(noise)
		mi.rotation.y = deg_to_rad((e["rot"] as int) * 90.0)
		mi.set_meta("style_role", _item_role(fdata))
		_apply_item_model(mi, _active_model_path(fdata, (e["item"] as Dictionary).get("is_extended", false) as bool), canon, fdata.get("hide_nodes", []) as Array)
		_style_if_bare(mi)
		_no_shadows(mi)
		top_rel[i] = lift + _drawn_height(mi, height)
		placed.append({"mi": mi, "c": c, "height": height, "lift": lift, "e": e})
	# The room's floor rests on the box's table: the parent's floor is that far down.
	if box_support >= 0 and top_rel.has(box_support):
		floor_y -= top_rel[box_support]
	for p in placed:
		var mi := p["mi"] as MeshInstance3D
		var c: Vector3 = p["c"]
		var e := p["e"] as Dictionary
		var height: float = p["height"]
		mi.position.y += floor_y
		_scenery_nodes.append({"node": mi, "center": c})
		pieces.append({"pos": mi.position, "mesh": mi, "rot_steps": e["rot"], "floor_y": floor_y + (p["lift"] as float),
			"size": Vector3((e["foot"] as Vector2).x * TILE_M * s, height, (e["foot"] as Vector2).y * TILE_M * s),
			"functions": (e["fdata"] as Dictionary).get("functions", [])})

	var f0: Vector3 = to_view.call(lo.x, lo.y)
	var f1: Vector3 = to_view.call(hi.x, hi.y)
	var slab := _box(Vector3(f1.x - f0.x, 0.5, f1.z - f0.z),
		Vector3((f0.x + f1.x) * 0.5, floor_y - 0.25, (f0.z + f1.z) * 0.5), Color.WHITE, StyleController.ROLE_SCENERY_FLOOR)
	_no_shadows(slab)
	# Further out: the apartment this one stands in, or the desk.
	var outer := data.get("outer", {}) as Dictionary
	if not outer.is_empty():
		_scenery_level(outer, f0.x, f0.z, f1.x - f0.x, f1.z - f0.z, floor_y - 0.5, false)
	else:
		_add_desk_around(Vector3(f0.x, floor_y - 0.5, f0.z), f1.x - f0.x, f1.z - f0.z, false)

	var wall_h := WALL_H_M * s
	var wall_t := WALL_THICK * s
	var wall_lines: Array = []   # for the household, see _add_parent_household
	for sd in segments:
		var seg := sd as Dictionary
		if seg.get("demolished", false):
			continue
		var a: Vector3 = to_view.call(seg["x1"] as float, seg["y1"] as float)
		var b: Vector3 = to_view.call(seg["x2"] as float, seg["y2"] as float)
		var along_x := absf(b.x - a.x) >= absf(b.z - a.z)
		var length := absf(b.x - a.x) if along_x else absf(b.z - a.z)
		if length < 0.01:
			continue
		var mid := (a + b) * 0.5
		wall_lines.append([Vector2(a.x, a.z), Vector2(b.x, b.z)])
		var wall := _box(Vector3(length, wall_h, wall_t) if along_x else Vector3(wall_t, wall_h, length),
			Vector3(mid.x, floor_y + wall_h * 0.5, mid.z), Color.WHITE, StyleController.ROLE_WALL)
		_no_shadows(wall)
		# Walls are lowered rather than hidden when they come in the way (see
		# _update_scenery_visibility), like the room's own walls.
		_scenery_nodes.append({"node": wall, "center": mid, "wall": true,
			"a": Vector2(a.x, a.z), "b": Vector2(b.x, b.z), "floor_y": floor_y, "h": wall_h})

	if first:
		_add_parent_household(data.get("level_id", "") as String, s, pieces, wall_lines,
			Rect2(f0.x, f0.z, f1.x - f0.x, f1.z - f0.z), Rect2(x0, z0, w, d), floor_y)


# Scenery on the camera's side of the room would sit between the camera and
# what the player is working on: hide it. `flat` is the camera's direction
# from the room, flattened (see _update_wall_visibility).
func _update_scenery_visibility(flat: Vector3) -> void:
	var room_center := Vector3(_room_w_m * 0.5, 0.0, _room_d_m * 0.5)
	# The ground line from the room to the camera: a giant wall of the
	# apartment outside that crosses it (or comes close) stands between the
	# camera and the room, and is cut down to a line on the floor, the way
	# the room's own walls are in the cutaway.
	var from := Vector2(room_center.x, room_center.z)
	var to := Vector2(cam.position.x, cam.position.z)
	var clear := maxf(_room_w_m, _room_d_m) * 0.5 + 0.6
	for sc in _scenery_nodes:
		var node: Node3D = sc["node"]
		if not is_instance_valid(node):
			continue
		if sc.get("wall", false):
			var near := Geometry2D.get_closest_points_between_segments(sc["a"], sc["b"], from, to)
			var in_way: bool = (near[0] as Vector2).distance_to(near[1]) < clear \
				and (near[1] as Vector2).distance_to(from) > 0.2
			var h: float = sc["h"]
			var k := clampf(STUB_HEIGHT_M / h, 0.0, 1.0) if in_way else 1.0
			node.visible = true
			node.scale.y = k
			node.position.y = (sc["floor_y"] as float) + h * k * 0.5
			continue
		var away: Vector3 = (sc["center"] as Vector3) - room_center
		away.y = 0.0
		node.visible = away.length() < 0.01 or away.normalized().dot(flat) < 0.2


# ── The desk ─────────────────────────────────────────────────────────────────
# A top-level apartment has no bigger apartment around it. It stands on the
# ajustador's drawing board instead, as a scale model on its base board: the
# same indigo sheet with a white grid the plan view lies on (DeskBackdrop), so
# a box sits in a flat and the flat sits on the board.
const DESK_MAT_Y := -0.20          # top of the mat, under the model's base board
const DESK_MAT_SIZE := 90.0        # metres; the fog swallows its far edges

func _desk_mat_material(square_m: float = 2.0) -> StandardMaterial3D:
	const PX := 64
	var img := Image.create(PX, PX, false, Image.FORMAT_RGB8)
	img.fill(GameTheme.INDIGO)
	var line := GameTheme.INDIGO.lerp(Color.WHITE, 0.16)
	for i in PX:
		img.set_pixel(i, 0, line)
		img.set_pixel(0, i, line)
	img.generate_mipmaps()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mat.uv1_scale = Vector3(_desk_mat_size / square_m, _desk_mat_size / square_m, 1.0)
	# Unlit and out of the fog: the same indigo from the model's feet to the
	# horizon, matching the board behind the plan view. (Lit, it went nearly
	# black by the camera and hazy grey further off.)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_fog = true
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	return mat


func _desk_part(mesh: Mesh, color: Color, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mat.metallic_specular = 0.0
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	build_root.add_child(mi)
	return mi


var _desk_mat_size := DESK_MAT_SIZE

func _add_desk_scenery(w: float, d: float) -> void:
	_add_desk_around(Vector3(0.0, DESK_MAT_Y, 0.0), w, d, true)


# The desk around a model whose footprint starts at `origin` (x, z) and
# measures w x d; origin.y is the top of the mat.
func _add_desk_around(origin: Vector3, w: float, d: float, with_board: bool) -> void:
	var mat_y := origin.y
	var ox := origin.x
	var oz := origin.z
	_desk_mat_size = maxf(DESK_MAT_SIZE, maxf(w, d) * 14.0)
	if with_board:
		var board := BoxMesh.new()
		board.size = Vector3(w + 0.5, -mat_y - 0.05, d + 0.5)
		_desk_part(board, Color(0.46, 0.38, 0.27), Vector3(ox + w * 0.5, (mat_y - 0.05) * 0.5, oz + d * 0.5))
	var plane := PlaneMesh.new()
	plane.size = Vector2(_desk_mat_size, _desk_mat_size)
	var mat_mi := MeshInstance3D.new()
	mat_mi.mesh = plane
	mat_mi.material_override = _desk_mat_material(maxf(w, d) * 0.4)
	mat_mi.position = Vector3(ox + w * 0.5, mat_y, oz + d * 0.5)
	build_root.add_child(mat_mi)


# The block the room stands on. Presentation only: it sits entirely below the
# floor and nothing picks against it.
func _add_plinth(w: float, d: float) -> void:
	if _style == null:
		return
	var mi := _box(Vector3(w, PLINTH_DEPTH_M, d), Vector3(w * 0.5, -0.05 - PLINTH_DEPTH_M * 0.5, d * 0.5), Color.WHITE)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_style.style_plinth(mi, PLINTH_DEPTH_M + 0.05)


# A piece still being bought is see-through, so it reads as "not placed yet"
# and doesn't hide the floor and furniture you're judging the fit against.
const BUY_GHOST_ALPHA := 0.6

func _ghostify(mi: MeshInstance3D) -> void:
	if _style == null:
		return
	var role: StringName = mi.get_meta("style_role", StyleController.ROLE_FURNITURE)
	var inst: Variant = _model_of(mi)
	_style.style_node_transparent(inst if is_instance_valid(inst) else mi, role, BUY_GHOST_ALPHA)


# ...and solid again once it's actually placed.
func _solidify(mi: MeshInstance3D) -> void:
	if _style == null:
		return
	var inst: Variant = _model_of(mi)
	if is_instance_valid(inst):
		_style.style_node(inst, mi.get_meta("style_role", StyleController.ROLE_FURNITURE))
	else:
		_style_if_bare(mi)


# Translucent pane colour for windows: the palette's glow colour when styled.
func _glass_color() -> Color:
	if _style != null and _style.palette != null:
		var c := _style.palette.glow_color
		return Color(c.r, c.g, c.b, 0.5)
	return Color(0.55, 0.78, 0.92, 0.55)


func _process(delta: float) -> void:
	if not _reveal_playing and _camera_keys_active():
		_key_pan(delta)
	_check_long_press()
	if _auto_spin and not _dragging:
		_yaw += delta * 18.0
		_update_camera()
	_update_wall_fade(delta)
	_update_doors(delta)
	_update_extras(delta)
	_status_t -= delta
	if _status_t <= 0.0:
		_status_t = 0.5
		_sync_status_marks()
	if is_instance_valid(_tenant) and _tenant_stops.size() > 1:
		_tenant_stop_t += delta
		if _tenant_stop_t >= TENANT_STOP_SECONDS:
			_tenant_stop_t = 0.0
			var prev_moment: String = (_tenant_stops[_tenant_stop_idx] as Dictionary).get("moment_id", "")
			_tenant_stop_idx = (_tenant_stop_idx + 1) % _tenant_stops.size()
			var stop: Dictionary = _tenant_stops[_tenant_stop_idx]
			var moment_id: String = stop.get("moment_id", "")
			if moment_id != prev_moment:
				_apply_moment_to_scene(moment_id)
			_tenant.position = stop["pos"]
			_tenant.rotation.y = stop["rot_y"]
			_tenant.set_pose(stop["pose"])
			showcase_stop_changed.emit(moment_id, stop.get("needs", []))
	if _reason_flash_t > 0.0:
		_reason_flash_t -= delta
		if is_instance_valid(_reason_label):
			var fade := clampf(_reason_flash_t / 0.4, 0.0, 1.0)
			_reason_label.modulate.a = fade
		if _reason_flash_t <= 0.0:
			_hide_reason()
	if _foldable:
		if _fold_auto:
			_fold_phase += delta * FOLD_LOOP_SPEED
			_fold_t = (sin(_fold_phase) + 1.0) * 0.5
		else:
			_fold_t = move_toward(_fold_t, _fold_target, delta * FOLD_MANUAL_SPEED)
		_update_fold_visual()


func _on_container_input(event: InputEvent) -> void:
	if _reveal_playing:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			# Double-click a nested box to step inside it. Handled before
			# anything else, so the second press neither picks the box up nor
			# starts a pan, and it works in the read-only post-win view too.
			# A single click or a drag still treats the box as furniture.
			if mb.pressed and mb.double_click and not _buying_furniture:
				var box_hit := _pick_furniture(_to_vp(mb.position))
				if not box_hit.is_empty():
					var box: Furniture = box_hit["furniture"]
					if box.is_nested_box and not box.child_level_id.is_empty():
						_hide_hover_highlight()
						box_enter_requested.emit(box)
						return
			if mb.pressed:
				_press_pos = mb.position
				_press_ms = Time.get_ticks_msec()
				_press_moved = false
				if read_only:
					# Post-win "View Apartment" mode — nothing to pick up, hang, or
					# buy, so a left-press over empty floor only ever pans.
					_panning = true
				elif _buying_furniture:
					if TouchControls.active:
						# No hover with a finger: touching moves the piece there; the
						# Place button puts it down (confirm_buy_touch()).
						_buy_touch_vp = _to_vp(mb.position)
						_update_buy_ghost(_buy_touch_vp)
						return
					_confirm_buy(_to_vp(mb.position))
					return
				else:
					var vp_pos := _to_vp(mb.position)
					var wall_hit := _pick_wall_item(vp_pos)
					if not wall_hit.is_empty():
						_begin_wall_item_drag(wall_hit, vp_pos)
					else:
						var hit := _pick_furniture(vp_pos)
						if not hit.is_empty():
							_begin_furniture_drag(hit, vp_pos)
						else:
							_panning = true
			else:
				if _dragging_furniture:
					# Mousedown always starts a "drag" the instant it lands on a
					# furniture piece (see the pressed branch above), so a plain
					# click never reaches the `elif ... _on_item_clicked()` case
					# below — it has to be handled here instead, before falling
					# through to the real drag-finish logic.
					if mb.position.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD:
						_click_furniture_no_drag()
					else:
						_finish_furniture_drag()
				elif _dragging_wall_item:
					_finish_wall_item_drag()
				elif not read_only and mb.position.distance_to(_press_pos) < CLICK_MOVE_THRESHOLD:
					_on_item_clicked(_to_vp(mb.position))
				_panning = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if read_only:
				return
			if _buying_furniture:
				_cancel_buy()
				return
			var vp_pos := _to_vp(mb.position)
			var wall_hit := _pick_wall_item(vp_pos)
			if not wall_hit.is_empty():
				_sell_wall_item(wall_hit)
				return
			var hit := _pick_furniture(vp_pos)
			if not hit.is_empty():
				_sell_furniture(hit)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(1.5, _dist - 0.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_max_dist(), _dist + 0.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_orbit_press_pos = mb.position
				_dragging = true
				_stop_turn()
			else:
				_dragging = false
				# A plain middle-click (no drag) recenters — the only way back
				# once free panning has carried the room out of view.
				if mb.position.distance_to(_orbit_press_pos) < CLICK_MOVE_THRESHOLD:
					_recenter_camera()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_press_pos) >= CLICK_MOVE_THRESHOLD:
			_press_moved = true
		_last_local_mouse = mm.position
		if _dragging:
			# Middle-drag orbits, also with a piece in hand: turning the view
			# to look at it from another side while deciding where it goes
			# (the piece follows the pointer, see _update_camera).
			_hide_hover_highlight()
			_yaw   -= mm.relative.x * 0.4
			_pitch  = clampf(_pitch - mm.relative.y * 0.4, -80.0, -5.0)
			_update_camera()
		elif _buying_furniture:
			# Skip while the cursor is over some other UI panel (e.g. the shop
			# list) instead of the 3D view itself — this script's _input()
			# receives every mouse-motion event regardless of what's drawn on
			# top, so without this guard the ghost would jump to wherever that
			# screen point happens to raycast into the room, which has nothing
			# to do with a deliberate cursor position over the room.
			if _mouse_over_own_view():
				_hide_hover_highlight()
				_update_buy_ghost(_to_vp(mm.position))
		elif _dragging_furniture:
			_hide_hover_highlight()
			_update_furniture_drag(_to_vp(mm.position))
		elif _dragging_wall_item:
			_hide_hover_highlight()
			_update_wall_item_drag(_to_vp(mm.position))
		elif _panning:
			_hide_hover_highlight()
			# Pan speed scales with _dist so it feels consistent whether zoomed
			# in close or looking at the whole apartment from far away.
			var pan_scale := _dist * 0.0022
			var right := cam.global_transform.basis.x
			var up    := cam.global_transform.basis.y
			_center -= right * mm.relative.x * pan_scale
			_center += up * mm.relative.y * pan_scale
			_center  = _clamp_pan_center(_center)
			_update_camera()
		else:
			# Idle — no drag/camera-orbit/purchase in progress, so hovering a
			# floor piece is safe to reflect: an amber outline says "this is
			# grabbable" before the player commits to a click, the same way
			# the red/green hitbox outlines already say "this is where it
			# sits"/"this is where it'd land" once a drag is under way. Skipped
			# in read-only mode — nothing is actually grabbable there.
			if not read_only:
				_update_hover(_to_vp(mm.position))


# gui_input only reliably delivers mouse/touch events here (the container
# doesn't hold keyboard focus), so Esc-to-cancel a purchase is handled through
# the normal _input() channel instead, same as Furniture.gd's 2D equivalent.
func _input(event: InputEvent) -> void:
	# Letters typed into a text box (the catalogue's search) are not camera keys.
	if event is InputEventKey and get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if _reveal_playing:
		return
	# View keys. Handled here, ahead of Main.gd's own shortcuts (this node is
	# deeper in the tree, so it sees input first): in the 3D view W/A/S/D move
	# the camera and Q/E turn it, where on the floor plan the same keys step
	# floors/moments and reopen a wall. The arrow keys still do the stepping.
	if event is InputEventKey and event.pressed and _camera_keys_active() \
			and not (event.ctrl_pressed or event.alt_pressed or event.meta_pressed):
		match event.keycode:
			KEY_Q, KEY_E:
				if not event.echo:
					_turn_view(-1 if event.keycode == KEY_Q else 1)
				get_viewport().set_input_as_handled()
				return
			KEY_HOME, KEY_END:
				if not event.echo:
					set_wall_mode(posmod(wall_mode + (-1 if event.keycode == KEY_HOME else 1), WallMode.size()))
				get_viewport().set_input_as_handled()
				return
			KEY_W, KEY_A, KEY_S, KEY_D:
				get_viewport().set_input_as_handled()   # the move itself is in _key_pan(), while held
				return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		if _buying_furniture and not _buying_on_wall:
			_buying_furniture._rotate()
			_update_buy_ghost(_to_vp(_last_local_mouse))
			get_viewport().set_input_as_handled()
			return
		elif _dragging_furniture:
			_rotate_dragged_furniture()
			get_viewport().set_input_as_handled()
			return
	if _buying_furniture and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_buy()
		get_viewport().set_input_as_handled()
	elif close_btn.visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# close_btn is only shown for the standalone single-item preview
		# (build_single_item) — the persistent room 3D view mode hides it and
		# has no "closed" concept, so this never fires there.
		closed.emit()
		get_viewport().set_input_as_handled()


# Picking / dragging helpers

# This script's _input() sees every mouse-motion event regardless of z-order —
# unlike _gui_input, nothing about another Control being drawn on top of the
# 3D view stops it from arriving here. Buy-ghost placement needs to tell the
# difference: a screen point sitting under the shop panel still raycasts to
# *something* in the room (the SubViewport spans the same rect either way),
# it's just not a position the player actually pointed at. Checked against
# gui_get_hovered_control() (the actual topmost Control under the cursor)
# rather than container's own rect, since sibling UI panels can overlap that
# rect without shrinking it.
func _mouse_over_own_view() -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	return hovered == null or hovered == self or is_ancestor_of(hovered)


func _to_vp(pos: Vector2) -> Vector2:
	var csize := container.size
	if csize.x <= 0.0 or csize.y <= 0.0:
		return pos
	return pos * (Vector2(sub_vp.size) / csize)


func _ground_hit(vp_pos: Vector2) -> Vector3:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	if absf(dir.y) < 0.0001:
		return from
	var t := -from.y / dir.y
	return from + dir * t


func _room_local_to_tile(local: Vector3) -> Vector2:
	return Vector2(local.x / TILE_M + _room_bounds.position.x,
		local.z / TILE_M + _room_bounds.position.y)


func _ray_box_t(from: Vector3, dir: Vector3, box_min: Vector3, box_max: Vector3) -> float:
	var tmin := -INF
	var tmax := INF
	for axis in range(3):
		var o: float = from[axis]
		var d: float = dir[axis]
		var mn: float = box_min[axis]
		var mx: float = box_max[axis]
		if absf(d) < 1e-6:
			if o < mn or o > mx:
				return INF
			continue
		var t1 := (mn - o) / d
		var t2 := (mx - o) / d
		if t1 > t2:
			var tmp := t1; t1 = t2; t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return INF
	if tmax < 0.0:
		return INF
	return tmin if tmin >= 0.0 else tmax


func _pick_furniture(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var best_t := INF
	var best: Dictionary = {}
	for entry in _furniture_entries:
		if not entry.has("furniture") or not entry.has("mesh") or not entry.has("pos") or not entry.has("size"):
			continue   # defensive: a malformed entry here used to hard-crash instead of just being skipped
		if not is_instance_valid(entry["furniture"]) or not is_instance_valid(entry["mesh"]):
			continue
		var pos: Vector3 = entry["pos"]
		var item_size: Vector3 = entry["size"]
		var t := _ray_box_t(from, dir, pos - item_size * 0.5, pos + item_size * 0.5)
		if t < best_t:
			best_t = t
			best = entry
	return best


func _begin_furniture_drag(hit: Dictionary, vp_pos: Vector2) -> void:
	_hide_hover_highlight()
	_drag_target        = hit
	_dragging_furniture = true
	_drag_orig_pos       = hit["pos"]
	var f: Furniture     = hit["furniture"]
	_restore_wall_hole(f)   # picking up a balcony window to move it opens the wall back up until it's dropped somewhere new
	f._rail_ctrl_latch = false
	var tile             := _room_local_to_tile(_ground_hit(vp_pos))
	_drag_offset         = Vector2(f.grid_pos.x, f.grid_pos.y) - tile
	_drag_last_tile      = f.grid_pos
	# Capture the locked cross-axis coordinate the same way Furniture._drag()
	# does for the 2D view (grid_pos.y for a horizontal rail, .x for a
	# vertical one) — without this a rail item (e.g. a wardrobe on its
	# dress-up track) could be dragged clean off its rail in 3D even though
	# the 2D view never lets that happen.
	_drag_rail_lock = -1.0
	if f.rail_axis == "h":
		_drag_rail_lock = f.grid_pos.y
	elif f.rail_axis == "v":
		_drag_rail_lock = f.grid_pos.x
	_set_grid_overlay_visible(true)
	_set_hitbox_highlights_visible(true)
	var item_size: Vector3 = hit["size"]
	_show_drag_highlight(Vector2(item_size.x, item_size.z))
	# _build_outline_group() leaves the group at the room's (0,0) corner until
	# positioned — without this, the highlight would flash there for one frame
	# (or stay there entirely if the mouse never moves before the drop),
	# looking like it belongs to some other item instead of the one in hand.
	_update_drag_highlight_pos(_drag_orig_pos.x, _drag_orig_pos.z, Vector2(item_size.x, item_size.z))


const RAIL_REATTACH_SNAP := 1.0   # tiles; how close to a rail's own line (Floor.rails) counts as close enough to Ctrl-reattach

# Mirrors Furniture.gd's own _find_rail_snap exactly — see its comment.
func _find_rail_snap(axis: String, along: float, cross: float) -> float:
	if not _apt_floor:
		return -1.0
	for rail in _apt_floor.rails:
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


func _update_furniture_drag(vp_pos: Vector2) -> void:
	# Snapped to the tile grid (1 tile = TILE_M = 0.1m) as it's dragged, so
	# placement reads as grid-locked rather than free-floating — matches the
	# 2D/wall views and makes it obvious where a piece will actually land
	# relative to everything else's hitbox.
	var tile := (_room_local_to_tile(_ground_hit(vp_pos)) + _drag_offset).round()
	var f: Furniture = _drag_target["furniture"]
	# Holding Ctrl while dragging detaches the piece from its rail for good
	# (or back on, see below) — mirroring Furniture.gd's 2D _drag(). Reuses
	# that same script's f._rail_ctrl_latch (an instance var on the
	# Furniture itself, not something Room3DView needs its own copy of) to
	# make this an EDGE trigger firing once per Ctrl press rather than every
	# single frame it's held — without it, detaching immediately put the
	# cursor back inside the reattach snap zone (still right next to the
	# rail it just left), reattaching the very next frame, which re-detached
	# the frame after, flickering for as long as Ctrl and the mouse both
	# stayed put with no way to tell which state it landed on.
	var rail_state_changed := false
	var rail_attached := false
	var ctrl_down := Input.is_key_pressed(KEY_CTRL)
	if not ctrl_down:
		f._rail_ctrl_latch = false
	elif not f._rail_ctrl_latch:
		if f.rail_axis != "" and _drag_rail_lock >= 0.0:
			f.rail_axis = ""
			f._rail_ctrl_latch = true
			rail_state_changed = true
		# The reverse: Ctrl-dragging a detached piece back near its ORIGINAL
		# rail's own line re-engages it. _home_rail_* (set once at setup(),
		# never cleared) is what makes a detach reversible instead of
		# one-way.
		elif f.rail_axis == "" and f._home_rail_axis != "":
			var line := _find_rail_snap(f._home_rail_axis, tile.x if f._home_rail_axis == "h" else tile.y, tile.y if f._home_rail_axis == "h" else tile.x)
			if line >= 0.0:
				f.rail_axis  = f._home_rail_axis
				f.rail_start = f._home_rail_start
				f.rail_end   = f._home_rail_end
				_drag_rail_lock = line
				f._rail_ctrl_latch = true
				rail_state_changed = true
				rail_attached = true
	if f.rail_axis == "h" and _drag_rail_lock >= 0.0:
		tile.y = _drag_rail_lock
		var mn_x := 0.0 if f.rail_start < 0 else float(f.rail_start)
		var mx_x := float(_apt_floor.grid_w - f.grid_w) if f.rail_end < 0 else float(f.rail_end)
		tile.x = clampf(tile.x, mn_x, mx_x)
	elif f.rail_axis == "v" and _drag_rail_lock >= 0.0:
		tile.x = _drag_rail_lock
		var mn_y := 0.0 if f.rail_start < 0 else float(f.rail_start)
		var mx_y := float(_apt_floor.grid_h - f.grid_h) if f.rail_end < 0 else float(f.rail_end)
		tile.y = clampf(tile.y, mn_y, mx_y)
	_drag_last_tile = tile
	if Furniture.on_drag_moved.is_valid():
		# Where the pointer is on the floor, not where the piece ended up: a
		# piece can't be pushed into a box, so its own centre never gets there.
		var under := _room_local_to_tile(_ground_hit(vp_pos))
		Furniture.on_drag_moved.call(f, get_viewport().get_mouse_position(), under)
		_drag_pointer_tile = under
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var item_size: Vector3 = _drag_target["size"]
	if rail_state_changed:
		_set_rail_indicator(mesh, f, Vector2(item_size.x, item_size.z))
		_flash_rail(mesh, Vector2(item_size.x, item_size.z), rail_attached)
	mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + item_size.x * 0.5
	mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + item_size.z * 0.5
	# Up onto a table or shelf when it is over one, which bows under it as if
	# it were already there.
	if _sag_preview_key != [f, tile]:
		_settle_stacked(f, tile)
	var lift := _lift_m(f, tile)
	mesh.position.y = lift + item_size.y * 0.5
	_drag_target["pos"] = mesh.position
	_update_drag_highlight_pos(mesh.position.x, mesh.position.z, Vector2(item_size.x, item_size.z))
	if is_instance_valid(_drag_highlight):
		_drag_highlight.position.y = lift

	if Furniture.transfer_hover != 0:
		_hide_reason()     # Main's tag by the pointer says what will happen
	elif _apt_floor and not _apt_floor.can_place(f, _apt_floor.snap_to_wall(f, tile)):
		_show_reason(_apt_floor.get_block_reason())
	else:
		_hide_reason()


# R while an existing item is being dragged: same call as the 2D view's
# Furniture._rotate() (swaps grid_w/grid_h, cycles rot_steps 0..3), then the
# drag ghost's box + model + hitbox are resynced in place — the tile the
# item is hovering over doesn't change, only its footprint/facing.
func _rotate_dragged_furniture() -> void:
	if _drag_target.is_empty():
		return
	var f: Furniture = _drag_target["furniture"]
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var box := mesh.mesh as BoxMesh
	var height_m: float = box.size.y
	var riders: Array = _apt_floor.riders_of(f) if is_instance_valid(_apt_floor) else []
	f._rotate()
	# What stands on it turned with it (Floor.turn_riders), where it stands.
	for r in riders:
		var re := _entry_of(r as Furniture)
		if not re.is_empty():
			_sync_entry_to_piece(re)
	if not riders.is_empty():
		_settle_stacked()
	var new_size := Vector3(f.grid_w * TILE_M, height_m, f.grid_h * TILE_M)
	box.size = new_size
	mesh.rotation.y = deg_to_rad(f.rot_steps * 90.0)
	var canon := Vector3(new_size.z, new_size.y, new_size.x) if f.rot_steps % 2 == 1 else new_size
	var fdata := _find_furniture_data(_catalog, f.furniture_id)
	if fdata.get("animated_fold", false):
		# _refit_item_model assumes the normal exact-fit-scaled model setup
		# (a "model_native" meta key _apply_item_model always sets) — this
		# item never goes through that path at all, so calling it here
		# crashed on missing metadata the instant you tried to rotate one
		# mid-drag. _apply_animated_item_model already re-derives the
		# wall-flush offset from the box's current size on every call.
		_apply_animated_item_model(mesh, fdata.get("model", "") as String, f.is_extended)
	else:
		_refit_item_model(mesh, canon)
	_drag_target["size"] = new_size
	# Re-centre on the same tile the cursor is currently over — grid_w/grid_h
	# just swapped, so the footprint anchor has to be recomputed the same way
	# _update_furniture_drag does, not left at the pre-rotation offset.
	mesh.position.x = (_drag_last_tile.x - _room_bounds.position.x) * TILE_M + new_size.x * 0.5
	mesh.position.z = (_drag_last_tile.y - _room_bounds.position.y) * TILE_M + new_size.z * 0.5
	_drag_target["pos"] = mesh.position
	_show_drag_highlight(Vector2(new_size.x, new_size.z))
	_update_drag_highlight_pos(mesh.position.x, mesh.position.z, Vector2(new_size.x, new_size.z))
	if _apt_floor and not _apt_floor.can_place(f, _apt_floor.snap_to_wall(f, _drag_last_tile)):
		_show_reason(_apt_floor.get_block_reason())
	else:
		_hide_reason()


# Mirrors Furniture.begin_placement(): Main.gd creates and setup()s the
# Furniture node for a purchase (deducting budget only once it's actually
# placed, same as the 2D flow), then hands it here instead of calling
# begin_placement() so the ghost follows the cursor in 3D instead of a 2D
# mouse position. The ghost can land on the floor or on a wall — whichever
# the cursor ray is actually pointing at each frame (see _scene_hit).
func start_buying(furniture: Furniture, fdata: Dictionary) -> void:
	_buy_touch_vp = Vector2.INF
	# Pressing Buy again before confirming/cancelling the previous ghost used
	# to just overwrite _buying_mesh, leaking the old ghost (and its pending
	# Furniture node) on screen forever. Cancel it first — this also emits
	# buy_cancelled so Main.gd's pending Furniture node gets freed too.
	if _buying_furniture:
		_cancel_buy()
	_hide_hover_highlight()
	_buying_furniture = furniture
	_buying_fdata     = fdata
	_buying_on_wall   = false
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var col := Color("#" + (fdata.get("color", "888888") as String))
	col.a = 0.55
	var box_size := Vector3(furniture.grid_w * TILE_M, height_m, furniture.grid_h * TILE_M)
	_buying_mesh = _box(box_size, Vector3(box_size.x * 0.5, box_size.y * 0.5, box_size.z * 0.5), col)
	_buying_mesh.set_meta("style_role", _item_role(fdata))
	if fdata.get("animated_fold", false):
		_apply_animated_item_model(_buying_mesh, fdata.get("model", "") as String, false)
	else:
		_apply_item_model(_buying_mesh, _active_model_path(fdata, false), box_size, fdata.get("hide_nodes", []) as Array)
	_ghostify(_buying_mesh)
	_set_grid_overlay_visible(true)
	_set_hitbox_highlights_visible(true)
	# The box above spawns at a hardcoded position near the room's own origin
	# corner (not wherever the cursor actually is) — _update_buy_ghost() only
	# ever runs off mouse-MOTION events, so if Buy was clicked from a UI panel
	# (the shop list) and the mouse hasn't moved since, that raw spawn
	# position stuck around indefinitely, showing as a ghost box sitting in
	# the room's corner overlapping real furniture there. Hide it until the
	# cursor is actually over the 3D view itself — _mouse_over_own_view()
	# guards against the other half of the same bug: this script's _input()
	# sees every mouse-motion event regardless of what UI panel is drawn on
	# top (unlike _gui_input, which the shop panel would consume first), so
	# naively raycasting from the cursor's last position the instant Buy is
	# clicked can land the ghost wherever that screen point happens to
	# project into the room — which is wherever the shop panel sits on
	# screen, not a deliberate cursor position over the room at all.
	_buying_mesh.visible = false
	if _mouse_over_own_view():
		_update_buy_ghost(_to_vp(_last_local_mouse))


func _update_buy_ghost(vp_pos: Vector2) -> void:
	var hit := _scene_hit(vp_pos)
	if hit.is_empty():
		return
	_buying_mesh.visible = true
	var iw: int = _buying_furniture.grid_w
	var box := _buying_mesh.mesh as BoxMesh
	# wall_flush_required items (the balcony window) always go through the
	# FLOOR/Furniture placement path below, snapped flush against a wall by
	# Wall.can_place()'s own check — never the separate "hang decoration on
	# a wall" system (Wall.place_wall_item / _wall_item_entries), which is a
	# plain {edge, origin, fid} data record with no Furniture node behind
	# it at all, and therefore no fold/toggle support whatsoever. Dragging
	# this item over a wall surface must NOT arm that path.
	if hit["mode"] == "wall" and not _buying_furniture.wall_flush_required:
		_buying_on_wall = true
		if not _sag_preview_key.is_empty() and _sag_preview_key[0] != null:
			_settle_stacked()   # off the floor: no surface is carrying it
		_set_grid_overlay_visible(false)
		_set_hitbox_highlights_visible(false)
		_hide_drag_highlight()
		_set_wall_grid_overlays_visible(true)
		var edge: String = hit["edge"]
		var wall_h: int = _buying_fdata.get("wall_h", 8) as int
		var depth: int  = _buying_fdata.get("floor_depth", 1) as int
		var origin := _wall_origin_from_hit(edge, hit["along_m"], hit["height_m"], iw, wall_h, _buying_fdata)
		var xf := _wall_item_mesh_transform(edge, origin, iw, wall_h, depth)
		box.size = xf["size"]
		_buying_mesh.position = xf["pos"]
		_buying_mesh.set_meta("wall_edge", edge)
		_buying_mesh.set_meta("wall_origin", origin)
		_refit_item_model(_buying_mesh, box.size)
		if not _can_place_wall_item(edge, origin, iw, wall_h, Vector2i(-999999, -999999)):
			_show_reason(_wall_block_reason)
		else:
			_hide_reason()
	else:
		_buying_on_wall = false
		_set_grid_overlay_visible(true)
		_set_hitbox_highlights_visible(true)
		_set_wall_grid_overlays_visible(false)
		# Centre the item's footprint on the cursor (matching the wall path's
		# "along_m - iw*0.5" convention below) rather than gluing its corner
		# to the raw ground-hit tile — otherwise the ghost visibly sits off
		# to one side of the cursor, worse the bigger the item is.
		#
		# Uses _ground_hit(vp_pos) directly rather than hit["pos"] — for a
		# wall_flush_required item this branch also runs when the cursor is
		# actually pointing AT a wall (that's the whole point: it forces the
		# floor path even then), and in that case `hit` is the wall-shaped
		# dict from _wall_hit_test (edge/along_m/height_m/t), which has no
		# "pos" key at all. hit["pos"] only ever exists on a genuine
		# {"mode": "floor", "pos": ...} result.
		var cursor_tile := _room_local_to_tile(_ground_hit(vp_pos))
		if Furniture.on_drag_moved.is_valid():
			Furniture.on_drag_moved.call(_buying_furniture, get_viewport().get_mouse_position(), cursor_tile)
		var tile := (cursor_tile - Vector2(iw, _buying_furniture.grid_h) * 0.5).round()
		var height_m := maxf((_buying_fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
		box.size = Vector3(iw * TILE_M, height_m, _buying_furniture.grid_h * TILE_M)
		_buying_mesh.position.x = (tile.x - _room_bounds.position.x) * TILE_M + box.size.x * 0.5
		if _apt_floor and _sag_preview_key != [_buying_furniture, tile]:
			_settle_stacked(_buying_furniture, tile)
		var buy_lift := _lift_m(_buying_furniture, tile) if _apt_floor else 0.0
		_buying_mesh.position.y = buy_lift + box.size.y * 0.5
		_buying_mesh.position.z = (tile.y - _room_bounds.position.y) * TILE_M + box.size.z * 0.5
		_buying_mesh.rotation.y = deg_to_rad(_buying_furniture.rot_steps * 90.0)
		# Fit the model into its CANONICAL (pre-rotation) box, same reasoning as
		# _add_furniture_box — the outer box already has the correct (swapped)
		# real-world footprint/position, mi.rotation.y alone spins the model to
		# match it, so 0°/180° stop looking identical.
		var rs: int = _buying_furniture.rot_steps
		var canon := Vector3(box.size.z, box.size.y, box.size.x) if rs % 2 == 1 else box.size
		if _buying_fdata.get("animated_fold", false):
			_apply_animated_item_model(_buying_mesh, _buying_fdata.get("model", "") as String, false)
		else:
			_refit_item_model(_buying_mesh, canon)
		if _apt_floor and not _apt_floor.can_place(_buying_furniture, tile):
			var reason := _apt_floor.get_block_reason()
			_show_reason(reason)
			# The ground-hit raycast isn't clipped to the room's own footprint,
			# so pointing anywhere past the walls (open ground/sky) computes a
			# perfectly valid — just very far away — 3D position. Rendering the
			# ghost box there reads as a broken floating artifact rather than
			# useful drag feedback, since there's nothing nearby to judge scale
			# or placement against. Hide the box itself in that case; the
			# reason label alone ("Outside the room") already tells the player
			# why nothing is being placed.
			if reason == tr("Outside the room"):
				_buying_mesh.visible = false
				_hide_drag_highlight()
			else:
				_show_drag_highlight(Vector2(box.size.x, box.size.z))
				_update_drag_highlight_pos(_buying_mesh.position.x, _buying_mesh.position.z, Vector2(box.size.x, box.size.z))
		else:
			_hide_reason()
			_show_drag_highlight(Vector2(box.size.x, box.size.z))
			_update_drag_highlight_pos(_buying_mesh.position.x, _buying_mesh.position.z, Vector2(box.size.x, box.size.z))
		if is_instance_valid(_drag_highlight):
			_drag_highlight.position.y = buy_lift


func _confirm_buy(vp_pos: Vector2) -> void:
	if _buying_on_wall:
		var edge: String = _buying_mesh.get_meta("wall_edge", "")
		var origin: Vector2i = _buying_mesh.get_meta("wall_origin", Vector2i.ZERO)
		var iw: int = _buying_furniture.grid_w
		var ih: int = _buying_fdata.get("wall_h", 8) as int
		if edge == "" or not _can_place_wall_item(edge, origin, iw, ih, Vector2i(-999999, -999999)):
			_flash_reason(_wall_block_reason if edge != "" else tr("Can't place here"))
			return
		_hide_reason()
		var fid := _buying_furniture.furniture_id
		if _apt_floor:
			_apt_floor.place_wall_item(edge, origin, fid)
		var depth: int = _buying_fdata.get("floor_depth", 1) as int
		var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
		var wall_ghost_mat := _buying_mesh.material_override as StandardMaterial3D
		if wall_ghost_mat:
			wall_ghost_mat.albedo_color.a = 1.0
		(_buying_mesh.mesh as BoxMesh).size = xf["size"]
		_buying_mesh.position = xf["pos"]
		_apply_item_model(_buying_mesh, _active_model_path(_buying_fdata, false), xf["size"], _buying_fdata.get("hide_nodes", []) as Array)
		_solidify(_buying_mesh)
		_wall_item_entries.append({"edge": edge, "origin": origin, "fid": fid, "mesh": _buying_mesh, "size": xf["size"]})
		_buying_furniture = null
		_buying_fdata     = {}
		_buying_mesh      = null
		_set_grid_overlay_visible(false)
		_set_wall_grid_overlays_visible(false)
		Audio.play("place")
		buy_confirmed_wall.emit(fid, edge, origin)
		return

	if not _apt_floor:
		return
	var cursor_tile := _room_local_to_tile(_ground_hit(vp_pos))
	# Clicked down on a box, or on Back: bought here, delivered there.
	if Furniture.on_purchase_dropped.is_valid() and Furniture.on_purchase_dropped.call(_buying_furniture,
			get_viewport().get_mouse_position(), cursor_tile):
		return
	var tile := (cursor_tile - Vector2(_buying_furniture.grid_w, _buying_furniture.grid_h) * 0.5).round()
	var snap_pos := _apt_floor.snap_to_wall(_buying_furniture, tile)
	if not _apt_floor.can_place(_buying_furniture, snap_pos):
		_flash_reason(_apt_floor.get_block_reason())
		return
	_hide_reason()
	_apt_floor.place_furniture(_buying_furniture, snap_pos)
	var f := _buying_furniture
	var item_size: Vector3 = (_buying_mesh.mesh as BoxMesh).size
	var ghost_mat := _buying_mesh.material_override as StandardMaterial3D
	if ghost_mat:
		ghost_mat.albedo_color.a = 1.0   # drop the semi-transparent "ghost" look now that it's placed
	var rs: int = f.rot_steps
	var canon_size := Vector3(item_size.z, item_size.y, item_size.x) if rs % 2 == 1 else item_size
	if _buying_fdata.get("animated_fold", false):
		_apply_animated_item_model(_buying_mesh, _buying_fdata.get("model", "") as String, f.is_extended, f, true)
	else:
		_apply_item_model(_buying_mesh, _active_model_path(_buying_fdata, false), canon_size, _buying_fdata.get("hide_nodes", []) as Array)
	_solidify(_buying_mesh)
	_furniture_entries.append({"furniture": f, "mesh": _buying_mesh, "pos": _buying_mesh.position, "size": item_size})
	_add_hitbox_highlight(Vector3(_buying_mesh.position.x, 0.0, _buying_mesh.position.z), Vector2(item_size.x, item_size.z), f)
	_set_rail_indicator(_buying_mesh, f, Vector2(item_size.x, item_size.z))
	_buying_furniture = null
	_buying_fdata     = {}
	_buying_mesh      = null
	_settle_stacked()
	_set_grid_overlay_visible(false)
	_set_hitbox_highlights_visible(false)
	_hide_drag_highlight()
	Audio.play("place")
	buy_confirmed.emit(f)


func _cancel_buy() -> void:
	var f := _buying_furniture
	if is_instance_valid(_buying_mesh):
		_buying_mesh.queue_free()
	_buying_furniture = null
	_buying_fdata     = {}
	_buying_mesh      = null
	_settle_stacked()   # whatever was bowing under it straightens again
	_set_grid_overlay_visible(false)
	_set_hitbox_highlights_visible(false)
	_hide_drag_highlight()
	_set_wall_grid_overlays_visible(false)
	buy_cancelled.emit(f)


# The plan marks a keepsake with a heart after its name; in 3D, where pieces
# have no labels, the heart floats above the piece itself.
func _add_keepsake_mark(mesh: Node3D, height_m: float) -> void:
	var heart := Label3D.new()
	heart.text = "\uf67c"
	heart.font_size = 64
	heart.pixel_size = 0.0022
	heart.modulate = Color(0.86, 0.22, 0.30)
	heart.outline_size = 14
	heart.outline_modulate = Color(1.0, 0.97, 0.93)
	heart.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	heart.no_depth_test = true
	heart.fixed_size = false
	heart.position = Vector3(0.0, height_m * 0.5 + 0.12, 0.0)
	mesh.add_child(heart)


# Set by Main: the current budget, so a rental box whose rent can no longer
# be repaid is refused here, before it is dropped from this view's cache.
var budget_getter: Callable

func _sell_furniture(hit: Dictionary) -> void:
	var f: Furniture = hit["furniture"]
	if f.keepsake:
		# Refused here, before the piece is dropped from this view's cache.
		_flash_reason(tr("\uf67c %s is a keepsake: it can be moved, not sold") % f.furniture_name)
		return
	if f.buy_price < 0 and budget_getter.is_valid() and (budget_getter.call() as int) < -f.buy_price:
		_flash_reason(tr("Removing %s means repaying its %d€ rent") % [f.furniture_name, -f.buy_price])
		return
	remove_furniture_entry(f)
	_set_grid_overlay_visible(false)
	_set_hitbox_highlights_visible(false)
	_hide_drag_highlight()
	sell_requested.emit(f)   # Main.gd handles the refund + apt_floor.remove_furniture


# Drops a Furniture piece from this view's own render cache (_furniture_entries)
# and frees its mesh/hitbox outline — called both for a sale initiated HERE (3D
# right-click, via _sell_furniture above) and, from Main.gd, for one initiated
# in the 2D floor plan instead. The 2D and 3D views share the same underlying
# Furniture node, but _furniture_entries is this script's OWN cache built once
# in build_from_floor() — a 2D-side sell used to free the Furniture node
# (Wall.gd's remove_furniture()) without this cache ever finding out, leaving
# a stale entry pointing at a freed instance. The next _pick_furniture() hit
# on that stale entry (e.g. just hovering nearby) then crashed trying to read
# it ("Trying to assign invalid previously freed instance").
func remove_furniture_entry(f: Furniture) -> void:
	_restore_wall_hole(f)   # a sold balcony window shouldn't leave its wall permanently open
	for i in range(_furniture_entries.size() - 1, -1, -1):
		if _furniture_entries[i]["furniture"] == f:
			var mesh: MeshInstance3D = _furniture_entries[i]["mesh"]
			if is_instance_valid(mesh):
				mesh.queue_free()
			_furniture_entries.remove_at(i)
	# The sold item's own static hitbox outline (and, if this sale happened
	# mid-drag of some other piece, the shared grid/drag-highlight overlays)
	# otherwise keep showing forever — nothing else ever turns them back off
	# once a sale short-circuits the normal drag-finish path.
	for i in range(_hitbox_highlights.size() - 1, -1, -1):
		var h = _hitbox_highlights[i]
		if is_instance_valid(h) and h.get_meta("furniture", null) == f:
			h.queue_free()
			_hitbox_highlights.remove_at(i)
	if _hover_furniture == f:
		_hide_hover_highlight()
	if _drag_target.get("furniture", null) == f:
		_drag_target = {}
		_dragging_furniture = false


# ── Wall-mounted items ──────────────────────────────────────────────────────
# Unlike floor furniture, a wall item has no live Furniture node — Floor just
# tracks {origin: furniture_id} strings per edge (see Wall.gd's wall_items).
# Dragging/selling them here goes through Floor.place_wall_item/
# remove_wall_item directly instead of a Furniture node's own API.

func _pick_wall_item(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var best_t := INF
	var best: Dictionary = {}
	for entry in _wall_item_entries:
		var mesh: MeshInstance3D = entry["mesh"]
		var pos: Vector3 = mesh.position
		var item_size: Vector3 = entry["size"]
		var t := _ray_box_t(from, dir, pos - item_size * 0.5, pos + item_size * 0.5)
		if t < best_t:
			best_t = t
			best = entry
	return best


func _begin_wall_item_drag(hit: Dictionary, vp_pos: Vector2) -> void:
	_drag_wall_target   = hit.duplicate()
	_dragging_wall_item = true
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var wh := _wall_plane_hit(hit["edge"], from, dir)
	var origin: Vector2i = hit["origin"]
	_drag_wall_target["offset_along_m"] = origin.x * TILE_M - (wh.get("along_m", 0.0) as float)
	_drag_wall_target["offset_ceil_m"]  = origin.y * TILE_M - (WALL_H_M - (wh.get("height_m", WALL_H_M) as float))
	_drag_wall_target["preview_origin"] = origin
	_set_wall_grid_overlays_visible(true)


func _update_wall_item_drag(vp_pos: Vector2) -> void:
	var edge: String = _drag_wall_target["edge"]
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var wh := _wall_plane_hit(edge, from, dir)
	if wh.is_empty():
		return
	var fid: String = _drag_wall_target["fid"]
	var fdata := _find_furniture_data(_catalog, fid)
	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 1) as int
	var ih: int = fdata.get("wall_h", 1) as int
	var along_m: float = (wh["along_m"] as float) + (_drag_wall_target["offset_along_m"] as float)
	var from_ceil_m: float = (WALL_H_M - (wh["height_m"] as float)) + (_drag_wall_target["offset_ceil_m"] as float)
	var wall_w := _wall_usable_width(edge)
	var x := clampi(int(round(along_m / TILE_M)), 0, wall_w - iw)
	var pinned: bool = (fdata.get("placement", "") as String) == "floor"
	var y := (WALL_HEIGHT_TILES - ih) if pinned else clampi(int(round(from_ceil_m / TILE_M)), 0, WALL_HEIGHT_TILES - ih)
	var origin := Vector2i(x, y)
	_drag_wall_target["preview_origin"] = origin
	var depth: int = fdata.get("floor_depth", 1) as int
	var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
	var mesh: MeshInstance3D = _drag_wall_target["mesh"]
	mesh.position = xf["pos"]

	if not _can_place_wall_item(edge, origin, iw, ih, _drag_wall_target["origin"]):
		_show_reason(_wall_block_reason)
	else:
		_hide_reason()


func _finish_wall_item_drag() -> void:
	_dragging_wall_item = false
	var edge: String = _drag_wall_target["edge"]
	var old_origin: Vector2i = _drag_wall_target["origin"]
	var new_origin: Vector2i = _drag_wall_target.get("preview_origin", old_origin)
	var fid: String = _drag_wall_target["fid"]
	var fdata := _find_furniture_data(_catalog, fid)
	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 1) as int
	var ih: int = fdata.get("wall_h", 1) as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var mesh: MeshInstance3D = _drag_wall_target["mesh"]
	var final_origin := old_origin
	if new_origin != old_origin and _apt_floor:
		_apt_floor.remove_wall_item(edge, old_origin)
		if _can_place_wall_item(edge, new_origin, iw, ih, new_origin):
			_apt_floor.place_wall_item(edge, new_origin, fid)
			final_origin = new_origin
			_hide_reason()
		else:
			_apt_floor.place_wall_item(edge, old_origin, fid)
			_flash_reason(_wall_block_reason)
	var xf := _wall_item_mesh_transform(edge, final_origin, iw, ih, depth)
	mesh.position = xf["pos"]
	for i in range(_wall_item_entries.size() - 1, -1, -1):
		if _wall_item_entries[i]["mesh"] == mesh:
			_wall_item_entries[i]["origin"] = final_origin
			_wall_item_entries[i]["size"]   = xf["size"]
	_drag_wall_target = {}
	_set_wall_grid_overlays_visible(false)


func _sell_wall_item(hit: Dictionary) -> void:
	var edge: String = hit["edge"]
	var origin: Vector2i = hit["origin"]
	var mesh: MeshInstance3D = hit["mesh"]
	for i in range(_wall_item_entries.size() - 1, -1, -1):
		if _wall_item_entries[i]["mesh"] == mesh:
			_wall_item_entries.remove_at(i)
	if is_instance_valid(mesh):
		mesh.queue_free()
	_set_wall_grid_overlays_visible(false)
	wall_sell_requested.emit(edge, origin)   # Main.gd handles apt_floor.remove_wall_item


# Ray-plane intersection against a single wall's (infinite) plane — used for
# dragging an existing wall item, where the edge is already fixed and mustn't
# flip to a different wall mid-drag just because the cursor strayed past the
# room's corner.
func _wall_plane_hit(edge: String, from: Vector3, dir: Vector3) -> Dictionary:
	var axis := "z" if edge in ["north", "south"] else "x"
	var coord := 0.0
	match edge:
		"south": coord = _room_d_m
		"east":  coord = _room_w_m
	var o: float = (from.z if axis == "z" else from.x)
	var d: float = (dir.z if axis == "z" else dir.x)
	if absf(d) < 1e-6:
		return {}
	var t := (coord - o) / d
	if t < 0.0:
		return {}
	var hit := from + dir * t
	var along: float = (hit.x if axis == "z" else hit.z)
	return {"along_m": along, "height_m": hit.y}


# Ray test against the wall planes at once — used for the buy ghost, where we
# don't know which wall (if any) the cursor is over yet. The two "near" walls
# (the ones _update_wall_visibility hides so the dollhouse cutaway doesn't
# block the view) are excluded: a ray toward the middle of the floor passes
# straight through that invisible near plane on its way from the camera, which
# would otherwise register as a (wrong) wall hit before ever reaching the
# floor and make it impossible to drop anything in the middle of the room.
func _wall_hit_test(from: Vector3, dir: Vector3) -> Dictionary:
	var normals := {
		"north": Vector3(0, 0, -1), "south": Vector3(0, 0, 1),
		"west":  Vector3(-1, 0, 0), "east":  Vector3(1, 0, 0),
	}
	var planes := [
		{"edge": "north", "axis": "z", "coord": 0.0,       "len": _room_w_m},
		{"edge": "south", "axis": "z", "coord": _room_d_m, "len": _room_w_m},
		{"edge": "west",  "axis": "x", "coord": 0.0,       "len": _room_d_m},
		{"edge": "east",  "axis": "x", "coord": _room_w_m, "len": _room_d_m},
	]
	var best_t := INF
	var best: Dictionary = {}
	for p in planes:
		var edge: String = p["edge"]
		if (normals[edge] as Vector3).dot(_cam_flat_dir) > 0.0:
			continue   # near/faded wall — not a valid drop target
		var axis: String = p["axis"]
		var o: float = (from.z if axis == "z" else from.x)
		var d: float = (dir.z if axis == "z" else dir.x)
		if absf(d) < 1e-6:
			continue
		var t := ((p["coord"] as float) - o) / d
		if t < 0.0 or t >= best_t:
			continue
		var hit := from + dir * t
		if hit.y < 0.0 or hit.y > WALL_H_M:
			continue
		var along: float = (hit.x if axis == "z" else hit.z)
		if along < 0.0 or along > (p["len"] as float):
			continue
		best_t = t
		best = {"edge": edge, "along_m": along, "height_m": hit.y, "t": t}
	return best


# Combines the ground-plane hit with the four wall-plane hits and returns
# whichever the cursor ray actually reaches first — that's "what the cursor
# is pointing at" for buy-ghost purposes.
func _scene_hit(vp_pos: Vector2) -> Dictionary:
	var from := cam.project_ray_origin(vp_pos)
	var dir  := cam.project_ray_normal(vp_pos)
	var ground_t := INF
	if absf(dir.y) > 0.0001:
		var t := -from.y / dir.y
		if t >= 0.0:
			ground_t = t
	var wall := _wall_hit_test(from, dir)
	if not wall.is_empty() and (wall["t"] as float) < ground_t:
		wall["mode"] = "wall"
		return wall
	if ground_t < INF:
		return {"mode": "floor", "pos": from + dir * ground_t}
	return {}


func _wall_usable_width(edge: String) -> int:
	if not _apt_floor:
		return 8
	# -1: see Wall.WALL_SNAP / get_adjacent_furniture's comment — the raw
	# bounds span reaches corner-tile to corner-tile, but a wall item can
	# never actually reach either corner tile.
	var raw := _room_bounds.size.x if edge in ["north", "south"] else _room_bounds.size.y
	return raw - 1


func _wall_restricted_zones(edge: String) -> Array:
	var zones: Array = []
	if not _apt_floor:
		return zones
	for wd in _apt_floor.wall_definitions:
		var d := wd as Dictionary
		if d.get("edge", "") != edge:
			continue
		if d.get("has_window", false):
			zones.append(Rect2i(d.get("window_x", 5) as int, 0, d.get("window_len", 15) as int, WALL_HEIGHT_TILES))
		if d.get("has_door", false):
			zones.append(Rect2i(d.get("door_x", 0) as int, 0, 10, WALL_HEIGHT_TILES))
	return zones


# Ceiling height (metres) at a given column of this wall's elevation —
# mirrors WallInspector._ceiling_height_m exactly, just fed from Room3DView's
# own state instead of a 2D panel's.
func _wall_ceiling_height_m(edge: String, col: int) -> float:
	if not _apt_floor or _apt_floor.sloped_ceiling.is_empty():
		return WALL_H_M
	var sc: Dictionary = _apt_floor.sloped_ceiling
	var axis: String  = sc.get("axis", "x") as String
	var low_s: int    = sc.get("low_start", 0) as int
	var high_e: int   = sc.get("high_end", 0) as int
	var min_h: float  = sc.get("min_h", 1.8) as float
	var max_h: float  = sc.get("max_h", 2.4) as float
	var span := high_e - low_s
	if span <= 0:
		return max_h
	var bounds := _room_bounds
	var progressive := (axis == "x" and edge in ["north", "south"]) \
		or (axis == "y" and edge in ["east", "west"])
	var coord: int
	if progressive:
		coord = (bounds.position.x if edge in ["north", "south"] else bounds.position.y) + col
	else:
		match edge:
			"north": coord = bounds.position.y
			"south": coord = bounds.position.y + bounds.size.y - 1
			"west":  coord = bounds.position.x
			"east":  coord = bounds.position.x + bounds.size.x - 1
			_:       coord = low_s
	var frac := clampf(float(coord - low_s) / float(span), 0.0, 1.0)
	return min_h + frac * (max_h - min_h)


func _wall_ceiling_cut_tiles(edge: String, col: int) -> int:
	if not _apt_floor or _apt_floor.sloped_ceiling.is_empty():
		return 0
	var avail_tiles := int(round(_wall_ceiling_height_m(edge, col) * 10.0))
	return clampi(WALL_HEIGHT_TILES - avail_tiles, 0, WALL_HEIGHT_TILES)


func _wall_floor_occludes(edge: String, at: Vector2i, iw: int, ih: int) -> bool:
	if not _apt_floor:
		return false
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	for entry in _apt_floor.get_adjacent_furniture(edge):
		var f: Furniture = entry["furniture"]
		var wx: int = entry["wall_x"] as int
		var fdata := _find_furniture_data(_catalog, f.furniture_id)
		if fdata.is_empty():
			continue
		var item_w: int = (f.grid_w if edge in ["north", "south"] else f.grid_h)
		var wall_h: int = fdata.get("wall_h", 5) as int
		var py_tile: int = WALL_HEIGHT_TILES - wall_h
		var sil := Rect2i(wx, py_tile, item_w, wall_h)
		if sil.intersects(item_rect):
			return true
	return false


# Mirrors WallInspector._wall_fits — restricted zones, sloped-ceiling cut,
# floor-silhouette occlusion, and overlap with other wall items on this edge.
# `ignore_origin` lets a drag-in-progress check against its own new spot
# without also comparing itself (used when the caller hasn't removed the old
# entry yet).
func _can_place_wall_item(edge: String, at: Vector2i, iw: int, ih: int, ignore_origin: Vector2i) -> bool:
	_wall_block_reason = ""
	var item_rect := Rect2i(at.x, at.y, iw, ih)
	for zone in _wall_restricted_zones(edge):
		if (zone as Rect2i).intersects(item_rect):
			_wall_block_reason = tr("Too close to a window or door")
			return false
	if _apt_floor and not _apt_floor.sloped_ceiling.is_empty():
		for tx in range(iw):
			if at.y < _wall_ceiling_cut_tiles(edge, at.x + tx):
				_wall_block_reason = tr("Ceiling too low here")
				return false
	if _wall_floor_occludes(edge, at, iw, ih):
		_wall_block_reason = tr("Blocked by furniture on the floor")
		return false
	var wall_w := _wall_usable_width(edge)
	if at.x < 0 or at.x + iw > wall_w or at.y < 0 or at.y + ih > WALL_HEIGHT_TILES:
		_wall_block_reason = tr("Doesn't fit on this wall")
		return false
	if not _apt_floor:
		return true
	var placed := _apt_floor.get_wall_items(edge)
	for tx in range(iw):
		for ty in range(ih):
			var check := Vector2i(at.x + tx, at.y + ty)
			for origin in placed:
				var o := origin as Vector2i
				if o == ignore_origin:
					continue
				var pf := _find_furniture_data(_catalog, placed[origin] as String)
				if pf.is_empty():
					continue
				var pw: int = (pf.get("size", {}) as Dictionary).get("w", 1) as int
				var ph: int = pf.get("wall_h", 1) as int
				if check.x >= o.x and check.x < o.x + pw and check.y >= o.y and check.y < o.y + ph:
					_wall_block_reason = tr("Overlaps %s") % (pf.get("name", tr("another item")) as String)
					return false
	return true


# Converts a raw ray-hit on a wall plane into a wall-local origin tile,
# clamped/magnetized the same way WallInspector._try_place snaps a click —
# `iw`/`ih` are the item's footprint (ih = wall_h, its mounted height).
func _wall_origin_from_hit(edge: String, along_m: float, height_m: float, iw: int, ih: int, fdata: Dictionary) -> Vector2i:
	var wall_w := _wall_usable_width(edge)
	var x := clampi(int(round(along_m / TILE_M - iw * 0.5)), 0, wall_w - iw)
	if x <= int(Floor.WALL_SNAP):
		x = 0
	elif wall_w - iw - x <= int(Floor.WALL_SNAP):
		x = wall_w - iw
	var pinned: bool = (fdata.get("placement", "") as String) == "floor"
	var y: int
	if pinned:
		y = WALL_HEIGHT_TILES - ih
	else:
		var from_ceiling_m := WALL_H_M - height_m
		y = clampi(int(round(from_ceiling_m / TILE_M - ih * 0.5)), 0, WALL_HEIGHT_TILES - ih)
	return Vector2i(x, y)


# Mirrors _add_wall_item_box's placement math so the buy ghost, drag preview,
# and the final placed mesh all agree on where a wall item sits.
func _wall_item_mesh_transform(edge: String, origin: Vector2i, iw: int, ih: int, depth: int) -> Dictionary:
	var iw_m    := iw * TILE_M
	var ih_m    := ih * TILE_M
	var depth_m := maxf(depth * TILE_M, 0.05)
	var top_from_floor_m := WALL_H_M - origin.y * TILE_M
	var center_y := top_from_floor_m - ih_m * 0.5
	var along    := origin.x * TILE_M + iw_m * 0.5
	# The perimeter walls are WALL_THICK deep and stand inside the room's
	# outline, so a hung piece starts at the wall's inner face, not at the
	# outline: without the offset its back 10 cm (a whole mirror, a painting,
	# a towel rail) is buried in the wall.
	var sz: Vector3
	var pos: Vector3
	match edge:
		"north":
			sz  = Vector3(iw_m, ih_m, depth_m)
			pos = Vector3(along, center_y, WALL_THICK + depth_m * 0.5)
		"south":
			sz  = Vector3(iw_m, ih_m, depth_m)
			pos = Vector3(along, center_y, _room_d_m - WALL_THICK - depth_m * 0.5)
		"west":
			sz  = Vector3(depth_m, ih_m, iw_m)
			pos = Vector3(WALL_THICK + depth_m * 0.5, center_y, along)
		_:   # "east"
			sz  = Vector3(depth_m, ih_m, iw_m)
			pos = Vector3(_room_w_m - WALL_THICK - depth_m * 0.5, center_y, along)
	return {"size": sz, "pos": pos}


var _drag_pointer_tile := Vector2(-999, -999)   # floor tile under the pointer during a drag

func _finish_furniture_drag() -> void:
	_dragging_furniture = false
	var f: Furniture = _drag_target["furniture"]
	var mesh: MeshInstance3D = _drag_target["mesh"]
	var item_size: Vector3 = _drag_target["size"]
	# Dropped on a nested box, or on "Back": Main moves the piece to that
	# apartment (see Furniture.on_drag_dropped) and it is gone from here.
	if Furniture.on_drag_dropped.is_valid() and Furniture.on_drag_dropped.call(f, get_viewport().get_mouse_position(),
			_drag_pointer_tile):
		_set_grid_overlay_visible(false)
		_set_hitbox_highlights_visible(false)
		_hide_drag_highlight()
		_settle_stacked()
		return
	var snap_pos := _apt_floor.snap_to_wall(f, _drag_last_tile) if _apt_floor else _drag_last_tile
	# Mirrors Furniture.gd's own 2D drag-end (see there for the full
	# rationale): a red (heavy), non-rail piece shares ONE position across
	# every Moment, so a move also has to clear every OTHER Moment's layout,
	# not just whichever one is being previewed in 3D right now.
	var ok := _apt_floor != null and _apt_floor.can_place(f, snap_pos)
	if ok and f.mobility_tier == "red" and f.rail_axis == "" and Furniture.test_mode_active \
			and Furniture.all_moment_ids.size() > 1:
		ok = _apt_floor.can_place_across_moments(f, snap_pos, Furniture.all_moment_ids, Furniture.active_moment_id)
	# Whatever stands on it comes along (Floor.move_with_riders); if any of it
	# can't land, nothing moves.
	var riders: Array = _apt_floor.riders_of(f) if ok else []
	if ok and not _apt_floor.move_with_riders(f, snap_pos):
		ok = false
	if ok:
		for r in riders:
			var re := _entry_of(r as Furniture)
			if re.is_empty():
				continue
			var rsize: Vector3 = re["size"]
			var rmesh := re["mesh"] as MeshInstance3D
			rmesh.position.x = ((r as Furniture).grid_pos.x - _room_bounds.position.x) * TILE_M + rsize.x * 0.5
			rmesh.position.z = ((r as Furniture).grid_pos.y - _room_bounds.position.y) * TILE_M + rsize.z * 0.5
			for h in _hitbox_highlights:
				if is_instance_valid(h) and h.get_meta("furniture", null) == r:
					h.position.x = rmesh.position.x - rsize.x * 0.5
					h.position.z = rmesh.position.z - rsize.z * 0.5
		# Without this, moving a piece in the 3D view moved it for every
		# moment at once instead of just the one currently being tested,
		# since set_moment_view() only ever restores a position it finds
		# recorded in moment_positions.
		if f.has_own_moment_position() and Furniture.test_mode_active:
			f.moment_positions[Furniture.active_moment_id] = f.grid_pos
		mesh.position.x = (snap_pos.x - _room_bounds.position.x) * TILE_M + item_size.x * 0.5
		mesh.position.z = (snap_pos.y - _room_bounds.position.y) * TILE_M + item_size.z * 0.5
		for h in _hitbox_highlights:
			if is_instance_valid(h) and h.get_meta("furniture", null) == f:
				h.position.x = mesh.position.x - item_size.x * 0.5
				h.position.z = mesh.position.z - item_size.z * 0.5
		_settle_stacked()
		Audio.play("place")
		furniture_moved.emit(f)
		_hide_reason()
	else:
		mesh.position = _drag_orig_pos
		if _apt_floor:
			_flash_reason(_apt_floor.get_block_reason())
	# _begin_furniture_drag() already restored any wall hole this item had
	# when picked up — cut a fresh one at wherever it actually landed
	# (its new spot on success, or back at its original spot if the drop
	# was rejected and it snapped back).
	var fdata := _find_furniture_data(_catalog, f.furniture_id)
	if fdata.get("animated_fold", false):
		_apply_animated_item_model(mesh, fdata.get("model", "") as String, f.is_extended, f, true)
	_drag_target["pos"] = mesh.position
	_drag_target = {}
	_settle_stacked()   # nothing carried any more: every surface bows by what is really on it
	_hide_drag_highlight()
	_set_grid_overlay_visible(false)
	_set_hitbox_highlights_visible(false)


# A real click (not a camera-drag) on the preview toggles a foldable item
# between its folded and extended shape. For non-foldable items in the
# standalone single-item preview (build_single_item — close_btn.visible is
# only true there, never in the persistent room 3D view mode) there's
# nothing to toggle, so the same "click on empty space" instead acts as a
# click-outside-the-modal dismiss, since this view has no separate
# backdrop/frame to click outside of.
func _on_item_clicked(_vp_pos: Vector2 = Vector2.ZERO) -> void:
	if not _foldable:
		if close_btn.visible:
			closed.emit()
		return
	_fold_auto   = false
	_fold_target = 0.0 if _fold_target > 0.5 else 1.0


# A plain click (no real drag) that landed on a placed foldable furniture
# piece — mousedown already armed a drag the instant it hit the piece (see
# _on_container_input), so this is where a "click" actually gets recognized
# for furniture, matching the 2D top-down view's click-to-fold interaction.
func _click_furniture_no_drag() -> void:
	var entry := _drag_target
	_drag_target = {}
	_dragging_furniture = false
	# The press that began this click showed the placement grid and outlines
	# as if a drag were starting; nothing was dragged, so put them away.
	_set_grid_overlay_visible(false)
	_set_hitbox_highlights_visible(false)
	_hide_drag_highlight()
	if entry.is_empty():
		return
	var f: Furniture = entry["furniture"]
	if f.foldable and f.toggle_fold():
		_resize_furniture_entry(entry)


# Re-derives box size/position from a placed Furniture's current grid_w/h
# (which toggle_fold() just changed) using the exact same anchoring formula
# _add_furniture_box used at placement time, then refits its model.
func _resize_furniture_entry(entry: Dictionary) -> void:
	var f: Furniture = entry["furniture"]
	var mesh: MeshInstance3D = entry["mesh"]
	var fdata := _find_furniture_data(_catalog, f.furniture_id)
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := f.grid_w * TILE_M
	var fd := f.grid_h * TILE_M
	var box_size := Vector3(fw, height_m, fd)
	var pos := Vector3(
		(f.grid_pos.x - _room_bounds.position.x) * TILE_M + fw * 0.5,
		height_m * 0.5,
		(f.grid_pos.y - _room_bounds.position.y) * TILE_M + fd * 0.5)
	(mesh.mesh as BoxMesh).size = box_size
	mesh.position = pos
	if fdata.get("animated_fold", false):
		# The two fold states are really one continuous mechanical motion
		# (a hinged window folding into a balcony), not two separate
		# models — see _apply_animated_item_model.
		_apply_animated_item_model(mesh, fdata.get("model", "") as String, f.is_extended, f, true)
	else:
		# A piece with a distinct "model_extended" (e.g. a sofa bed that should
		# actually become a bed, not just a stretched sofa) needs the whole model
		# swapped for the new fold state, not just rescaled — _refit_item_model
		# alone would keep showing the folded model at the extended size.
		_apply_item_model(mesh, _active_model_path(fdata, f.is_extended), box_size, fdata.get("hide_nodes", []) as Array)
	entry["size"] = box_size
	entry["pos"]  = pos
	_settle_stacked()


# Items whose two fold states are really one continuous mechanical motion
# (the balcony window's hinged panels) get a real baked animation instead of
# the swap-and-crossfade every other foldable piece uses. Loaded once at its
# true scale — NOT stretched to fill the grid box the way _apply_item_model
# does, since the model's own geometry already reshapes itself between
# states and rescaling it to a growing/shrinking box would fight the
# animation — then just played forward/backward from here on.
func _apply_animated_item_model(mi: MeshInstance3D, model_path: String, is_extended: bool, f: Furniture = null, finalize_wall: bool = false) -> void:
	var ap: AnimationPlayer
	var inst: Node3D
	if mi.has_meta("model_anim_player"):
		ap = mi.get_meta("model_anim_player") as AnimationPlayer
		inst = mi.get_meta("model_inst") as Node3D
	else:
		if model_path.is_empty() or not ResourceLoader.exists(model_path):
			return
		var packed := load(model_path) as PackedScene
		if not packed:
			return
		inst = packed.instantiate() as Node3D
		if not inst:
			return
		var mat := mi.material_override as StandardMaterial3D
		if mat:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.0
		mi.add_child(inst)
		_style_node(inst, mi.get_meta("style_role", StyleController.ROLE_FURNITURE))
		# Yawed 180° because the panels' built-in "open" direction pointed
		# back into the room instead of out through the wall — confirmed
		# wrong in-game, this flips it to open outward.
		inst.rotation.y = PI
		ap = _merge_animations(inst)
		mi.set_meta("model_inst", inst)
		mi.set_meta("model_anim_player", ap)
	# The model's own origin sits at its frame's floor-level, wall-flush
	# point (see the Blender build notes for balconyWindow.glb) — offset
	# down from the box's vertical CENTER (mi's own origin) to the box's
	# floor, and back to the box's wall-facing edge, matching how every
	# other item's box is anchored (wall-flush, floor-resting). Recomputed
	# on EVERY call, not just the first load: this item's box depth grows
	# when extended (toggle_fold's extended_add_h), and since the box is
	# centered on its own position, its CENTER moves outward as it grows —
	# the frame's wall-flush edge must stay pinned at the wall regardless,
	# not drift outward with that center.
	var box_size := (mi.mesh as BoxMesh).size
	inst.position = Vector3(0, -box_size.y * 0.5, -box_size.z * 0.5)
	_add_balcony_wall_gap(mi, box_size)
	# Only cut on an actually-finalized placement (a real Furniture object,
	# not the free-floating buy-ghost preview or a piece still being
	# dragged/rotated mid-move) — cutting on every preview frame would punch
	# holes in walls the player was only ever hovering over, never bought.
	if finalize_wall and is_instance_valid(f):
		_hide_wall_behind_item(mi.position, box_size, f)
	if not is_instance_valid(ap):
		return
	# The kit names its clip "open"; _merge_animations() builds "Open".
	var clip := "Open" if ap.has_animation("Open") else "open"
	if not ap.has_animation(clip):
		return
	if is_extended:
		ap.play(clip)
	else:
		ap.play(clip, -1, -1.0, true)   # negative speed + from_end = play it backward, i.e. "Close"


# Same "flat glassy decal flush against the wall" trick _add_wall_opening_overlay
# already uses for ordinary windows (there's no real cutout in any wall mesh
# in this game — see that function's own comment) — without it, the solid
# wall shows right through the frame's thin bars and the item reads as
# furniture stuck in front of an intact wall rather than an actual opening.
# Parented to `mi` so it inherits whatever wall position/rotation the
# placeholder box already has, instead of recomputing edge/x_tile like the
# window-specific version does.
func _add_balcony_wall_gap(mi: MeshInstance3D, box_size: Vector3) -> void:
	var gap: MeshInstance3D
	if mi.has_meta("wall_gap"):
		gap = mi.get_meta("wall_gap") as MeshInstance3D
	else:
		gap = MeshInstance3D.new()
		gap.mesh = BoxMesh.new()
		var mat := StandardMaterial3D.new()
		mat.albedo_color   = _glass_color()
		mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode      = BaseMaterial3D.CULL_DISABLED
		gap.material_override = mat
		mi.add_child(gap)
		mi.set_meta("wall_gap", gap)
	# Recomputed every call for the same reason as inst's own position above
	# — the box's depth (and therefore w	here its wall-flush edge sits
	# relative to its own center) changes between folded/extended states.
	(gap.mesh as BoxMesh).size = Vector3(box_size.x * 0.92, box_size.y * 0.92, 0.02)
	gap.position = Vector3(0, 0, -box_size.z * 0.5)


# balconyWindow.glb's four hinges were each keyframed as their OWN Blender
# Action, so Blender's glTF exporter — which groups exported animations by
# Action name — produced four separate clips instead of one "Open" clip
# covering the whole mechanism. Worse: each of those clips also carries a
# single-keyframe "snapshot" track for every OTHER animated object in the
# scene (a glTF-exporter quirk when multiple objects have animation_data at
# export time), so naively copying every track from every clip produces
# several tracks per NodePath — only one of which is the real, fully-keyed
# animation, the rest are stale 1-key snapshots that can silently override
# it depending on which gets processed last. Deduplicates by NodePath,
# keeping whichever candidate has the most keys, before building the merged
# Animation on a fresh AnimationPlayer (placed at the exact same spot in the
# tree, with the same root_node, as the original — track NodePaths are
# resolved relative to that and won't mean anything from a different
# position) so the whole rig can be played/reversed as one unit.
func _merge_animations(inst: Node3D) -> AnimationPlayer:
	var src_ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var new_ap := AnimationPlayer.new()
	if is_instance_valid(src_ap):
		src_ap.get_parent().add_child(new_ap)
		new_ap.root_node = src_ap.root_node
	else:
		inst.add_child(new_ap)
		return new_ap
	var merged := Animation.new()
	# path -> {"anim": Animation, "track": int} for whichever candidate track
	# on that path has the most keys seen so far.
	var best_by_path: Dictionary = {}
	for lib_name in src_ap.get_animation_library_list():
		var lib := src_ap.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			merged.length = maxf(merged.length, anim.length)
			for i in range(anim.get_track_count()):
				var path := anim.track_get_path(i)
				var key_count := anim.track_get_key_count(i)
				var prev: Dictionary = best_by_path.get(path, {})
				if prev.is_empty() or key_count > (prev["anim"] as Animation).track_get_key_count(prev["track"]):
					best_by_path[path] = {"anim": anim, "track": i, "type": anim.track_get_type(i)}
	for path in best_by_path:
		var best: Dictionary = best_by_path[path]
		var anim: Animation = best["anim"]
		var i: int = best["track"]
		var track_idx := merged.add_track(best["type"])
		merged.track_set_path(track_idx, path)
		for k in range(anim.track_get_key_count(i)):
			merged.track_insert_key(track_idx, anim.track_get_key_time(i, k), anim.track_get_key_value(i, k))
	var new_lib := AnimationLibrary.new()
	new_lib.add_animation("Open", merged)
	new_ap.add_animation_library("", new_lib)
	return new_ap


# Picks which .glb represents a piece for its current fold state — most
# foldable items just rescale their one model between sizes, but a piece can
# opt into a second, distinct model for its extended state via "model_extended"
# (e.g. a sofa bed that should become an actual bed shape, not a bigger sofa).
const OPEN_POSE_SUFFIX := "#open"

func _active_model_path(fdata: Dictionary, is_extended: bool) -> String:
	# "pose_open": the model is built folded away, but the game uses the
	# piece as an ordinary one (a coffee table), so it is always shown open.
	if fdata.get("pose_open", false) as bool:
		return (fdata.get("model", "") as String) + OPEN_POSE_SUFFIX
	if is_extended and (fdata.get("open_anim", false) as bool):
		return (fdata.get("model", "") as String) + OPEN_POSE_SUFFIX
	if is_extended:
		var ext := fdata.get("model_extended", "") as String
		if not ext.is_empty():
			return ext
	return fdata.get("model", "") as String


const FOLD_CROSSFADE_DUR := 0.35   # seconds a stale model takes to fade out after being replaced

func _update_fold_visual() -> void:
	if not is_instance_valid(_fold_mesh):
		return
	var mesh := _fold_mesh.mesh as BoxMesh
	var box_size: Vector3 = _fold_closed_size.lerp(_fold_open_size, _fold_t)
	var box_pos:  Vector3 = _fold_closed_pos.lerp(_fold_open_pos, _fold_t)
	mesh.size           = box_size
	_fold_mesh.position = box_pos
	# The two states are real, distinct Kenney models (not a single mesh that
	# can morph continuously), so the swap itself can't be a smooth vertex
	# blend — but a hard, instant cut still reads as "the sofa vanished and a
	# bed appeared out of nowhere". Instead: leave a fading ghost of the OLD
	# model in place (shrinking away over FOLD_CROSSFADE_DUR while the new one
	# fades in), so there's always visible "rastro" of what it used to be
	# through the swap instead of a pop. The box itself keeps sliding/resizing
	# every frame (below) so the model continues growing/shrinking into its
	# final state on both sides of the cut, not just snapping to it.
	var want_extended := _fold_t >= 0.5
	if want_extended != _fold_model_extended_shown:
		_spawn_fold_ghost(_fold_model_extended_shown, box_size, box_pos)
		_fold_model_extended_shown = want_extended
		_apply_item_model(_fold_mesh, _active_model_path(_fold_fdata, want_extended), box_size,
			_fold_fdata.get("hide_nodes", []) as Array)
		if _fold_mesh.has_meta("model_inst"):
			var new_inst: Node = _fold_mesh.get_meta("model_inst")
			_set_model_transparency(new_inst, 1.0)
			var tw := create_tween()
			tw.tween_method(func(t: float) -> void: _set_model_transparency(new_inst, t), 1.0, 0.0, FOLD_CROSSFADE_DUR)
	else:
		_refit_item_model(_fold_mesh, box_size)


# Every GeometryInstance3D (which MeshInstance3D is) has a built-in per-instance
# "transparency" (screen-door/dithered alpha) that fades it out without having
# to touch its own material — works uniformly across however many distinct
# materials a Kenney model's sub-meshes carry, unlike animating albedo alpha
# on each one individually.
func _set_model_transparency(node: Node, t: float) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).transparency = t
	for c in node.get_children():
		_set_model_transparency(c, t)


# Leaves a fading copy of the OUTGOING fold state's model in place at the
# moment of the swap — gives the transition visible "rastro" of the previous
# shape (e.g. the closed sofa silhouette lingering as the bed fades in) instead
# of it just vanishing the instant the new model appears.
func _spawn_fold_ghost(old_extended: bool, box_size: Vector3, box_pos: Vector3) -> void:
	var old_path := _active_model_path(_fold_fdata, old_extended)
	if old_path.is_empty():
		return
	var ghost := MeshInstance3D.new()
	ghost.position = box_pos
	var ghost_mat := StandardMaterial3D.new()
	ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_mat.albedo_color.a = 0.0
	ghost.material_override = ghost_mat
	build_root.add_child(ghost)
	_apply_item_model(ghost, old_path, box_size, _fold_fdata.get("hide_nodes", []) as Array)
	if not ghost.has_meta("model_inst"):
		ghost.queue_free()
		return
	var inst: Node = ghost.get_meta("model_inst")
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void: _set_model_transparency(inst, t), 0.0, 1.0, FOLD_CROSSFADE_DUR)
	tw.tween_callback(ghost.queue_free)


func _update_camera() -> void:
	var ry := deg_to_rad(_yaw)
	var rp := deg_to_rad(_pitch)
	var offset := Vector3(cos(rp) * sin(ry), -sin(rp), cos(rp) * cos(ry)) * _dist
	cam.position = _center + offset * _cam_dist_scale
	cam.look_at(_center, Vector3.UP)
	_update_wall_visibility(offset)
	# A piece being bought stays under the pointer while the view turns,
	# zooms or moves around it.
	if _buying_furniture != null and not TouchControls.active and _mouse_over_own_view():
		_update_buy_ghost(_to_vp(_last_local_mouse))
	if _style != null:
		_style.refresh_view()


# Keeps a left-drag pan from carrying the camera target out past the room's
# own walls — bounded to the actual apartment footprint (with a little slack
# to still frame a wall from just outside it) rather than an arbitrary fixed
# box, so it scales with whatever size room is loaded. Skipped when no real
# room is loaded yet (_room_w_m/_room_d_m both 0, e.g. the single-item preview
# modal), where an unbounded target doesn't matter.
func _clamp_pan_center(c: Vector3) -> Vector3:
	if _room_w_m <= 0.0 and _room_d_m <= 0.0:
		return c
	return Vector3(
		clampf(c.x, -PAN_MARGIN_M, _room_w_m + PAN_MARGIN_M),
		clampf(c.y, -PAN_MARGIN_M, WALL_H_M * 1.5),
		clampf(c.z, -PAN_MARGIN_M, _room_d_m + PAN_MARGIN_M)
	)


# Middle-click (no drag) — snaps back to the room's default framing. The only
# way back once a free pan has carried the room out of view, since orbiting
# alone (unlike panning) can never lose the room.
func _recenter_camera() -> void:
	if _room_w_m <= 0.0 and _room_d_m <= 0.0:
		return
	_center = _home_center
	_dist   = _home_dist
	_yaw    = HOME_YAW
	_pitch  = HOME_PITCH
	_update_camera()


# The "reveal" moment: a short scripted camera sweep over the finished room
# instead of the player's last interactive camera angle, played once on a
# successful RENT OUT (see Main.gd's _on_rent_pressed). Starts pulled back
# and low, arcs around and pushes in to the same resting angle the player
# would normally end up at — sells the "finished apartment" as a single
# continuous move instead of a static screenshot. Reuses _yaw/_pitch/_dist/
# _update_camera exactly as interactive orbiting does; the tween is just
# another writer of the same three numbers.
func play_reveal(duration: float = 3.5) -> void:
	_reveal_playing = true
	var end_yaw   := _yaw
	var end_pitch := _pitch
	var end_dist  := _dist
	var start_yaw   := end_yaw - 130.0
	var start_pitch := -14.0
	var start_dist  := end_dist * 1.85
	_yaw   = start_yaw
	_pitch = start_pitch
	_dist  = start_dist
	_update_camera()
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(func(t: float) -> void:
		_yaw   = lerpf(start_yaw, end_yaw, t)
		_pitch = lerpf(start_pitch, end_pitch, t)
		_dist  = lerpf(start_dist, end_dist, t)
		_update_camera(),
		0.0, 1.0, duration)
	await tw.finished
	_reveal_playing = false
	reveal_finished.emit()


# ── Level-transition camera moves ───────────────────────────────────────────
# Used by Main.gd when stepping into or out of a nested box, so the camera
# visibly travels with the player instead of the room just being swapped.
# Both block input for their (short) duration the same way play_reveal does,
# and both leave yaw/pitch alone — only where the camera looks and how close.

# Where the camera would sit to frame one placed piece. {} if it isn't in
# this view.
func furniture_focus(f: Furniture) -> Dictionary:
	for entry in _furniture_entries:
		if entry["furniture"] == f:
			var item_size: Vector3 = entry["size"]
			var pos: Vector3 = entry["pos"]
			return {"center": pos, "dist": maxf(item_size.x, maxf(item_size.y, item_size.z)) * 1.3 + 0.5}
	return {}


# Moves the camera from where it is to (to_center, to_dist).
func travel_camera(to_center: Vector3, to_dist: float, duration: float) -> void:
	if not _take_over_camera():
		return
	_run_camera_travel(_center, _dist, to_center, to_dist, duration)


# Starts the camera at (from_center, from_dist) and settles it on the view
# it has right now (the one the room was just built or restored with).
func arrive_camera(from_center: Vector3, from_dist: float, duration: float) -> void:
	if not _take_over_camera():
		return
	_run_camera_travel(from_center, from_dist, _center, _dist, duration)


# Stops a travel move where it is. Main.gd calls this before swapping levels,
# and every rebuild calls it too: a move left running would keep writing the
# OLD level's camera position into the new one — and since each trip starts
# from wherever the last one ended, a few trips back and forth were enough to
# leave the camera far out in empty space.
func cancel_camera_travel() -> void:
	if _travel_tween != null and _travel_tween.is_valid():
		_travel_tween.kill()
		_reveal_playing = false
	_travel_tween = null


# False if something else (the post-win reveal flythrough) owns the camera.
func _take_over_camera() -> bool:
	var ours := _travel_tween != null and _travel_tween.is_valid()
	if _reveal_playing and not ours:
		return false
	cancel_camera_travel()
	return true


func _run_camera_travel(c0: Vector3, d0: float, c1: Vector3, d1: float, duration: float) -> void:
	_reveal_playing = true
	_hide_hover_highlight()
	_center = c0
	_dist = d0
	_update_camera()
	var tw := create_tween()
	_travel_tween = tw
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(func(t: float) -> void:
		_center = c0.lerp(c1, t)
		_dist   = lerpf(d0, d1, t)
		_update_camera(),
		0.0, 1.0, duration)
	tw.finished.connect(func():
		if _travel_tween == tw:
			_travel_tween = null
			_reveal_playing = false)


# Each apartment keeps its own camera. Main.gd reads the state on the way out
# of a level and hands the state for the level being entered to
# set_next_camera_state(); the next build_from_floor() applies it. An empty
# state means "first visit": the home view, not whatever angle and zoom the
# previous apartment happened to be left at.
func get_camera_state() -> Dictionary:
	return {"yaw": _yaw, "pitch": _pitch, "dist": _dist, "center": _center}


# Loading a level can rebuild this view more than once in quick succession
# (once for the level as authored, again once the player's saved layout is
# restored), and every rebuild resets the zoom — so the state stays in force
# for a short window rather than being used up by the first build.
func set_next_camera_state(state: Dictionary) -> void:
	_next_camera_state = state
	_next_camera_until_ms = Time.get_ticks_msec() + 400


# ── Post-win tenant showcase ────────────────────────────────────────────────
# A low-poly Mii avatar that teleports between whichever placed furniture
# satisfies each moment's needs and plays a single happy bounce the whole
# time — called once from Main.gd after play_reveal() finishes. No
# pathfinding: each stop is just a furniture tile already known from
# _furniture_entries, so "moving" the tenant is a straight position snap.
const TenantMiiScript := preload("res://scripts/TenantMii.gd")
const TENANT_STOP_SECONDS := 3.0

# Which pose the tenant strikes for a given furniture function. "reach" is a
# standing pose (ReachFwd1H) for anything used from in front while upright —
# a sink, stove, counter — as opposed to "stand", which is just idling near
# it with empty hands. Anything not listed here falls back to "stand".
const FUNCTION_POSES := {
	"sleep": "lie",
	"sit": "sit",
	"work": "sit",
	"dine": "sit",
	"hygiene": "reach",
	"cook": "reach",
}

# Which poses are struck AT the furniture's own position/facing (sit in a
# chair, lie in a bed) versus STANDING IN FRONT of it, offset clear of its
# footprint and turned to face it (wash at a sink, cook at a stove). Without
# this distinction every pose was placed dead-center on the furniture's own
# origin with zero rotation, regardless of the piece's facing -- so a
# standing pose landed floating inside a sink's own volume, and a bed rotated
# by the player left the tenant lying unrotated beside it rather than on it.
const USE_STANDOFF_M := 0.34   # clearance in front of the footprint edge
# Measured (headless, bone positions): in the Lie pose's own unrotated rest
# frame, the head/foot midpoint sits this far from the root bone -- see the
# "lie" branch of _tenant_anchor_for for why this is needed at all.
const LIE_ROOT_TO_MID := Vector3(0.0, 0.0, -0.873)


# Which way the bed's pillow lies from the bed's centre, in the room's space,
# along whichever of X or Z it mostly is (Vector3.ZERO: no pillow). With two
# pillows (a trundle bed's), the upper one: the tenant lies on top.
func _pillow_dir(entry: Dictionary) -> Vector3:
	var best_y := -INF
	var best_c := Vector3.ZERO
	for box in _material_boxes(entry.get("mesh") as Node3D, "pillow"):
		if (box as AABB).end.y > best_y:
			best_y = (box as AABB).end.y
			best_c = (box as AABB).get_center()
	if best_y == -INF:
		return Vector3.ZERO
	var d: Vector3 = best_c - (entry["pos"] as Vector3)
	if absf(d.x) >= absf(d.z):
		return Vector3(signf(d.x), 0.0, 0.0) if absf(d.x) > 0.01 else Vector3.ZERO
	return Vector3(0.0, 0.0, signf(d.z))


# The bounds of every surface under `root` whose material is named with
# `needle`, in the space of root's parent (where entry["pos"] is).
func _material_boxes(root: Node3D, needle: String) -> Array:
	var out: Array = []
	if not is_instance_valid(root):
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		stack.append_array(n.get_children())
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var surfaces: Array = []
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i)
			if mat and needle in mat.resource_name.to_lower():
				surfaces.append(i)
		if surfaces.is_empty():
			continue
		# Mesh space -> the space entry["pos"] is in (the root's parent's).
		var xf := Transform3D.IDENTITY
		var walk: Node = mi
		while walk != root.get_parent() and walk is Node3D:
			xf = (walk as Node3D).transform * xf
			walk = walk.get_parent()
		for i in surfaces:
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue
			var box := AABB(verts[0], Vector3.ZERO)
			for v in verts:
				box = box.expand(v)
			out.append(xf * box)
	return out

var _tenant: Node3D = null
var _tenant_stops: Array = []   # [{pos, rot_y, pose}], one per moment (or one per furniture piece, if no moments)
var _tenant_stop_idx: int = 0
var _tenant_stop_t: float = 0.0


func start_tenant_showcase(moments: Array, tenant_color: Color = Color(0.20, 0.45, 0.85)) -> void:
	stop_tenant_showcase()
	if _furniture_entries.is_empty():
		return
	_tenant_stops = _collect_tenant_stops(moments)
	if _tenant_stops.is_empty():
		return
	_tenant = TenantMiiScript.new()
	build_root.add_child(_tenant)
	_tenant.set_tint(tenant_color)
	_tenant_stop_idx = 0
	_tenant_stop_t = 0.0
	var first: Dictionary = _tenant_stops[0]
	_apply_moment_to_scene(first.get("moment_id", ""))
	_tenant.position = first["pos"]
	_tenant.rotation.y = first["rot_y"]
	_tenant.set_pose(first["pose"])
	showcase_stop_changed.emit(first.get("moment_id", ""), first.get("needs", []))


func stop_tenant_showcase() -> void:
	if is_instance_valid(_tenant):
		_tenant.queue_free()
	_tenant = null
	_tenant_stops.clear()
	_tenant_stop_idx = 0
	_tenant_stop_t = 0.0
	showcase_stop_changed.emit("", [])   # so TenantCard un-rings whatever chip was last highlighted


func _pose_for_functions(fns: Array) -> String:
	for fn in fns:
		if FUNCTION_POSES.has(fn):
			return FUNCTION_POSES[fn]
	return "stand"


# Turns a raw _furniture_entries entry into where the tenant should actually
# stand/sit/lie and which way they should face, given the item's real
# rotation (Furniture.rot_steps, applied to the mesh as mesh.rotation.y) and
# real world-space footprint (entry["size"], already rotation-swapped -- see
# _add_furniture_box). entry["pos"] alone is the item's own CENTER at
# half its height, which is why a bare position-only stop floats a standing
# pose through a sink's volume and never turns to face anything.
# A piece of the parent apartment's scenery has no Furniture: its entry
# carries "rot_steps" and "floor_y" instead, and `scale` is the scenery's,
# for a tenant drawn that much bigger.
func _tenant_anchor_for(entry: Dictionary, pose: String, scale: float = 1.0) -> Dictionary:
	var f: Furniture = entry.get("furniture")
	var center: Vector3 = entry["pos"]
	var size: Vector3 = entry["size"]
	var steps: int = f.rot_steps if is_instance_valid(f) else entry.get("rot_steps", 0) as int
	var rot_y := deg_to_rad(steps * 90.0)
	var floor_y: float = entry.get("floor_y", 0.0)

	if pose == "lie":
		# The Lie clip's body extends along its own Z, head towards -Z
		# (measured via bone positions: head/foot are ~1.35m apart in Z, ~0m
		# in X). The head goes to the bed's pillow: the bed models don't all
		# put it at the same end (+X on most single and double beds, -Z on the
		# storage and trundle beds, the wall end on Murphy beds), and a fixed
		# quarter turn on top of rot_y laid tenants the wrong way round on
		# half of them. A bed without a pillow (sofa beds, the ottoman) gets
		# its +X end, the pillow end of the plain beds.
		var head_dir := _pillow_dir(entry)
		if head_dir == Vector3.ZERO:
			head_dir = Vector3.RIGHT.rotated(Vector3.UP, rot_y)
		var lie_rot := atan2(-head_dir.x, -head_dir.z)

		# The root bone is NOT at the body's own center-of-length -- it sits
		# ~0.87m toward the feet from the head/foot midpoint (measured via
		# bone positions at rest). Anchoring the raw root at the bed's center
		# left the head hanging almost 0.9m past the pillow end. Shifting the
		# anchor by that same offset, rotated the same way the body is,
		# brings the body's actual MIDPOINT to the bed's center instead.
		var mid_offset := LIE_ROOT_TO_MID.rotated(Vector3.UP, lie_rot) * scale

		# Rests on the mattress top (entry["size"].y, the item's real modeled
		# height), not the literal floor -- unlike Sit, whose baked hip-drop
		# already accounts for a normal seat height while keeping the root at
		# floor level, Lie assumes it's starting flat at y=0, so a bed's real
		# elevation above the floor has to be added back in here.
		var lie_pos := Vector3(center.x, floor_y + size.y, center.z) - mid_offset
		return {"pos": lie_pos, "rot_y": lie_rot, "pose": pose}

	if pose == "sit":
		# Facing the same way the chair itself faces, rather than always the
		# world's default -Z regardless of how it was placed.
		return {"pos": Vector3(center.x, floor_y, center.z), "rot_y": rot_y, "pose": pose}

	# Standing-in-front poses: step out from the footprint edge facing the
	# item's front, then turn around to face back at it. The item's front is
	# local +Z rotated by rot_y (Vector3.BACK, not the more common -Z/FORWARD
	# convention -- FORWARD sent the tenant out the wall behind items like a
	# sink instead of into the room in front of them, confirmed by playtest).
	# Since rot_y is always a multiple of 90 deg that vector's components are
	# always 0/±1, so dotting the footprint size against its absolute value
	# picks the correct half-extent to clear (the X half-width when front
	# points along X, the Z half-depth when it points
	# along Z) without needing to special-case each of the 4 facings by hand.
	var front := Vector3.BACK.rotated(Vector3.UP, rot_y)
	# The front first; if that spot is outside the room (the piece faces a
	# wall) or inside another piece, the back, then the sides. Only for this
	# room's own pieces (scale 1): the giant scenery around a box is not.
	var sides := [front, -front, front.rotated(Vector3.UP, PI * 0.5), front.rotated(Vector3.UP, -PI * 0.5)]
	var chosen := front
	if is_equal_approx(scale, 1.0) and _room_w_m > 0.0:
		for side in sides:
			var d: Vector3 = side
			var ext := absf(d.x) * size.x * 0.5 + absf(d.z) * size.z * 0.5
			if _standing_spot_free(center + d * (ext + USE_STANDOFF_M), f):
				chosen = d
				break
	var half_extent := absf(chosen.x) * size.x * 0.5 + absf(chosen.z) * size.z * 0.5
	var stand_pos := center + chosen * (half_extent + USE_STANDOFF_M * scale)
	if is_equal_approx(scale, 1.0) and _room_w_m > 0.0:
		# Never outside the walls, whatever else is in the way.
		stand_pos.x = clampf(stand_pos.x, WALL_THICK + 0.15, _room_w_m - WALL_THICK - 0.15)
		stand_pos.z = clampf(stand_pos.z, WALL_THICK + 0.15, _room_d_m - WALL_THICK - 0.15)
	return {"pos": Vector3(stand_pos.x, floor_y, stand_pos.z), "rot_y": atan2(-chosen.x, -chosen.z) if chosen != front else rot_y + PI, "pose": pose}


# Whether a tenant could stand at `p` (room space, floor level): inside the
# walls and clear of every piece's footprint but `own`'s.
func _standing_spot_free(p: Vector3, own: Variant) -> bool:
	const MARGIN := 0.15
	if p.x < WALL_THICK + MARGIN or p.x > _room_w_m - WALL_THICK - MARGIN \
			or p.z < WALL_THICK + MARGIN or p.z > _room_d_m - WALL_THICK - MARGIN:
		return false
	for e in _furniture_entries:
		if e.get("furniture") == own:
			continue
		var c: Vector3 = e["pos"]
		var s: Vector3 = e["size"]
		if absf(p.x - c.x) < s.x * 0.5 + 0.1 and absf(p.z - c.z) < s.z * 0.5 + 0.1:
			return false
	return true


# One stop per NEED (not per moment) — whichever placed furniture piece
# currently provides that specific need (functions_for_moment covers foldable
# items like a Sofa Bed, which only counts as "sleep" once actually unfolded).
# Most levels don't define moments at all (the tutorials just use a flat
# required_functions list), so with no moments the tenant instead cycles
# through every distinct placed furniture piece one at a time — otherwise it
# would resolve to a single stop and never move.
#
# Previously this returned the FIRST furniture piece matching ANY of a
# moment's needs and stopped there -- one stop per MOMENT, not per need, so a
# 5-need "Day" moment only ever showed one arbitrary piece (whichever
# satisfied the first-checked need), and the whole showcase collapsed to just
# two stops total (one per moment) instead of visiting every relevant piece
# with its own correct pose.
func _collect_tenant_stops(moments: Array) -> Array:
	var stops: Array = []
	if moments.is_empty():
		for entry in _furniture_entries:
			var f: Furniture = entry["furniture"]
			if not is_instance_valid(f):
				continue
			var anchor := _tenant_anchor_for(entry, _pose_for_functions(f.functions))
			var pos: Vector3 = anchor["pos"]
			if not stops.any(func(s): return (s["pos"] as Vector3).is_equal_approx(pos)):
				stops.append(anchor)
		return stops
	for m in moments:
		var moment_id: String = (m as Dictionary).get("id", "")
		var needs: Array = (m as Dictionary).get("needs", [])
		var moment_stops: Array = []
		for need in needs:
			var stop = _find_stop_for_need(moment_id, need)
			if stop == null:
				continue
			var pos: Vector3 = stop["pos"]
			# Same furniture piece can satisfy more than one need (a desk with
			# both "work" and "storage", say) -- dedupe by position so it isn't
			# visited twice back to back with the same pose, but keep BOTH
			# needs on the one stop that remains (used to just drop the second
			# need entirely, which would silently skip ringing its TenantCard
			# chip during the showcase even though this stop genuinely covers it).
			var existing := moment_stops.filter(func(s): return (s["pos"] as Vector3).is_equal_approx(pos))
			if existing.is_empty():
				stop["moment_id"] = moment_id
				stop["needs"] = [need]
				moment_stops.append(stop)
			else:
				(existing[0]["needs"] as Array).append(need)
		# All of THIS moment's stops in a row before moving to the next moment
		# (Day's 5 needs, then Night's 2, then back to Day) rather than
		# interleaving -- each stop's own moment_id is what the cycling logic
		# in _process() watches to know when to switch the whole scene's
		# fold/rail state and lighting over, so grouping them is what makes
		# that switch happen once per moment instead of on every single stop.
		stops += moment_stops
	return stops


func _find_stop_for_need(moment_id: String, need: String) -> Variant:
	for entry in _furniture_entries:
		var f: Furniture = entry["furniture"]
		if not is_instance_valid(f):
			continue
		var fns := f.functions_for_moment(moment_id)
		if need in fns:
			return _tenant_anchor_for(entry, _pose_for_functions(fns))
	return null


# ── The other households ────────────────────────────────────────────────────
# Only the level on screen is lived in for real (TenantLayer). The households
# next to it in the nesting are drawn as extras: the same Miis, at their own
# apartment's scale, just being there. Inside a box, the household of the
# apartment around it uses that apartment's giant furniture; in an apartment
# with boxes in it, each box's household stands at its door in miniature
# (a box is a closed little house, with no inside to see). Extras never
# path-find, speak or check anything, and take no random numbers: every few
# seconds they all move on to their next stop in a fixed order, or stay put
# with Reduce motion. Their animation stops while they are off screen. Animals
# have no Mii and are left out.
const EXTRAS_MAX := 6                # Miis besides the real household, for phones
const EXTRA_STOP_SECONDS := 6.0
const EXTRA_DOOR_GAP_M := 0.5        # between two Miis at a box's door, at their own scale
const EXTRA_CLEARANCE_M := 0.35      # a standing Mii's half-depth, at its own scale
const EXTRA_NEAR_M := 2.5            # furniture further from the box (in its apartment's metres) is out of sight
# level id -> {"residents": Array[TenantResident], "area_m2": float}, or {}
# when nobody lives there. Set by Main; without it there are no extras.
var household_of: Callable
var _extras_root: Node3D = null
var _extras: Array = []              # [{mii, scale, stops, idx, vis?, group?}]
var _box_extras: Dictionary = {}     # box mesh instance id -> {mesh, group}
var _extras_t := 0.0
var _box_scan_t := 0.0


func _clear_extras() -> void:
	if is_instance_valid(_extras_root):
		_extras_root.queue_free()
	_extras_root = null
	_extras.clear()
	_box_extras.clear()
	_extras_t = 0.0
	_box_scan_t = 0.0


# Beside build_root rather than in it, like TenantLayer's figures, so the
# style controller never restyles the Miis as furniture.
func _extras_parent() -> Node3D:
	if not is_instance_valid(_extras_root):
		_extras_root = Node3D.new()
		_extras_root.name = "TenantExtras"
		build_root.get_parent().add_child(_extras_root)
	return _extras_root


func _household(level_id: String) -> Dictionary:
	if level_id.is_empty() or not household_of.is_valid():
		return {}
	return household_of.call(level_id) as Dictionary


func _miis_of(household: Dictionary) -> Array:
	return (household.get("residents", []) as Array).filter(func(r): return (r as TenantResident).body != "animal")


# One Mii of another household, `scale` times life size, under `parent`,
# taking `stops` ({pos, rot_y, pose} in parent's space) in turn from `first`.
func _add_extra(r: TenantResident, scale: float, parent: Node3D, stops: Array, first: int) -> Dictionary:
	if _extras.size() >= EXTRAS_MAX or stops.is_empty():
		return {}
	var mii := TenantMiiScript.new() as TenantMii
	parent.add_child(mii)
	mii.set_body(r.body, r.is_feminine())
	mii.scale = Vector3.ONE * scale
	mii.set_animating(false)
	# Standing, sitting or lying (the body then reaches back along -Z), in
	# the Mii's own units.
	var notifier := VisibleOnScreenNotifier3D.new()
	notifier.aabb = AABB(Vector3(-0.5, 0.0, -2.0), Vector3(1.0, 1.8, 2.6))
	mii.add_child(notifier)
	notifier.screen_entered.connect(mii.set_animating.bind(true))
	notifier.screen_exited.connect(mii.set_animating.bind(false))
	var x := {"mii": mii, "scale": scale, "stops": stops, "idx": first % stops.size()}
	_extras.append(x)
	_pose_extra(x, false)
	return x


func _pose_extra(x: Dictionary, animate: bool) -> void:
	var mii: TenantMii = x["mii"]
	var stop: Dictionary = (x["stops"] as Array)[x["idx"]]
	var put := func() -> void:
		mii.position = stop["pos"]
		mii.rotation.y = stop["rot_y"]
		mii.set_pose(stop["pose"])
		if x.has("vis"):
			(x["vis"] as Dictionary)["center"] = stop["pos"]
	if not animate or GameState.reduce_motion:
		put.call()
		return
	var full := Vector3.ONE * (x["scale"] as float)
	var tw := mii.create_tween()
	tw.tween_property(mii, "scale", full * 0.05, 0.15).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(put)
	tw.tween_property(mii, "scale", full, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_extras(delta: float) -> void:
	_box_scan_t -= delta
	if _box_scan_t <= 0.0:
		_box_scan_t = 0.5
		_sync_box_extras()
	for rec in _box_extras.values():
		var mi := (rec as Dictionary)["mesh"] as Node3D
		var group := (rec as Dictionary)["group"] as Node3D
		if is_instance_valid(mi) and is_instance_valid(group):
			group.transform = mi.transform   # a box being dragged takes its household along
	if _extras.is_empty() or GameState.reduce_motion:
		return
	_extras_t += delta
	if _extras_t < EXTRA_STOP_SECONDS:
		return
	_extras_t = 0.0
	for x in _extras:
		if (x["stops"] as Array).size() > 1 and is_instance_valid(x["mii"]):
			x["idx"] = ((x["idx"] as int) + 1) % (x["stops"] as Array).size()
			_pose_extra(x, true)


# Keeps one household at the door of every box placed in the room, as boxes
# are bought, moved and sold.
func _sync_box_extras() -> void:
	if not household_of.is_valid():
		return
	var seen := {}
	for entry in _furniture_entries:
		var f := entry.get("furniture") as Furniture
		var mi := entry.get("mesh") as MeshInstance3D
		if not is_instance_valid(f) or not is_instance_valid(mi) or not f.is_nested_box or f.child_level_id.is_empty():
			continue
		var key := mi.get_instance_id()
		seen[key] = true
		if not _box_extras.has(key):
			_box_extras[key] = _add_box_household(f, mi)
	for key in _box_extras.keys():
		if seen.has(key):
			continue
		var group := (_box_extras[key] as Dictionary)["group"] as Node3D
		_extras = _extras.filter(func(x): return x.get("group") != group)
		if is_instance_valid(group):
			group.queue_free()
		_box_extras.erase(key)


# The box's household in a row in front of its door (the model's walnut
# surface; the box's front if it has none), facing out, at the scale that
# makes the apartment inside as big as the box.
func _add_box_household(f: Furniture, mi: MeshInstance3D) -> Dictionary:
	var group := Node3D.new()
	_extras_parent().add_child(group)
	group.transform = mi.transform
	var rec := {"mesh": mi, "group": group}
	var household := _household(f.child_level_id)
	var miis := _miis_of(household)
	var area: float = household.get("area_m2", 0.0)
	var box_mesh := mi.mesh as BoxMesh
	if miis.is_empty() or area <= 0.0 or box_mesh == null:
		return rec
	var canon := box_mesh.size
	var scale := clampf(sqrt(canon.x * canon.z / area), 0.02, 0.5)
	var out := Vector3.BACK
	var door := Vector3.ZERO
	var doors := _material_boxes(mi, "walnut")
	if not doors.is_empty():
		door = mi.transform.affine_inverse() * (doors[0] as AABB).get_center()
		out = Vector3(signf(door.x), 0.0, 0.0) if absf(door.x) / canon.x >= absf(door.z) / canon.z else Vector3(0.0, 0.0, signf(door.z))
	var side := out.rotated(Vector3.UP, PI * 0.5)
	var front := absf(out.x) * canon.x * 0.5 + absf(out.z) * canon.z * 0.5 + EXTRA_CLEARANCE_M * scale
	var stops: Array = []
	for i in miis.size():
		var along := door.dot(side) + (i - (miis.size() - 1) * 0.5) * EXTRA_DOOR_GAP_M * scale
		stops.append({"pos": out * front + side * along + Vector3(0.0, -canon.y * 0.5, 0.0),
			"rot_y": atan2(out.x, out.z), "pose": "stand"})
	for i in miis.size():
		var x := _add_extra(miis[i] as TenantResident, scale, group, stops, i)
		if not x.is_empty():
			x["group"] = group
	return rec


# The parent apartment's household, drawn as giant as the rest of it: at
# whatever of its furniture near the box they would use (in bed, on a seat,
# at the stove), and standing about the box looking in, so someone is always
# in sight from inside it. `pieces` are the scenery items as
# _tenant_anchor_for entries, `walls` its wall lines and `floor_rect` its
# floor, all in view metres; `room` is the box's footprint.
func _add_parent_household(level_id: String, s: float, pieces: Array, walls: Array, floor_rect: Rect2, room: Rect2, floor_y: float) -> void:
	var miis := _miis_of(_household(level_id))
	if miis.is_empty():
		return
	var clear := EXTRA_CLEARANCE_M * s
	var keep_out := room.grow(clear)
	var mid := Vector3(room.get_center().x, floor_y, room.get_center().y)
	var stops: Array = []
	for e in pieces:
		var fns := (e as Dictionary).get("functions", []) as Array
		if fns.is_empty():
			continue
		var stop := _tenant_anchor_for(e as Dictionary, _pose_for_functions(fns), s)
		var at: Vector3 = stop["pos"]
		if keep_out.has_point(Vector2(at.x, at.z)) or at.distance_to(mid) > EXTRA_NEAR_M * s + room.size.length() * 0.5:
			continue
		if not stops.any(func(o): return (o["pos"] as Vector3).is_equal_approx(at)):
			stops.append(stop)
	stops.sort_custom(func(a, b): return (a["pos"] as Vector3).distance_to(mid) < (b["pos"] as Vector3).distance_to(mid))
	# Around the box, on open floor: not in a piece, a wall or off the floor.
	var ring: Array = []
	for dir in [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]:
		var at: Vector3 = mid + dir * (absf(dir.x) * room.size.x * 0.5 + absf(dir.z) * room.size.y * 0.5 + clear * 2.0)
		var spot := Vector2(at.x, at.z)
		if not floor_rect.grow(-clear).has_point(spot):
			continue
		if pieces.any(func(e): return Rect2(Vector2((e["pos"] as Vector3).x, (e["pos"] as Vector3).z) - Vector2((e["size"] as Vector3).x, (e["size"] as Vector3).z) * 0.5,
				Vector2((e["size"] as Vector3).x, (e["size"] as Vector3).z)).grow(clear).has_point(spot)):
			continue
		if walls.any(func(wl): return Geometry2D.get_closest_point_to_segment(spot, wl[0], wl[1]).distance_to(spot) < clear):
			continue
		ring.append({"pos": at, "rot_y": atan2(-dir.x, -dir.z), "pose": "stand"})
	# Looking in first, then off to the nearest furniture and back.
	var all: Array = []
	for i in maxi(ring.size(), stops.size()):
		if i < ring.size():
			all.append(ring[i])
		if i < stops.size():
			all.append(stops[i])
	if all.is_empty():
		return
	var root := _extras_parent()
	for i in miis.size():
		if i >= all.size():
			break   # never two on one spot
		var first := i if all.size() < miis.size() else floori(float(i * all.size()) / miis.size())
		var x := _add_extra(miis[i] as TenantResident, s, root, all, first)
		if x.is_empty():
			continue
		var vis := {"node": x["mii"], "center": (x["mii"] as Node3D).position}
		x["vis"] = vis
		_scenery_nodes.append(vis)   # hidden on the camera's side, like the rest of the scenery


# Switches every placed piece (fold state, rail position -- Furniture.
# set_moment_view, same as the editor's own moment-tab click does) plus the
# day/night sky over to the given moment. The showcase previously only ever
# moved the TENANT between poses; a foldable sofa bed or the rail wardrobe
# would just stay in whatever state they last happened to be in, regardless
# of which moment's furniture the tenant was currently supposed to be using.
func _apply_moment_to_scene(moment_id: String) -> void:
	if moment_id == "" or not is_instance_valid(_apt_floor):
		return
	Furniture.active_moment_id = moment_id
	for f in _apt_floor.get_all_furniture():
		(f as Furniture).set_moment_view(moment_id)
	_apply_moment_lighting()


# Shrinks whichever wall(s) sit between the camera and the room down to a
# low stub — same "dollhouse cutaway" intent as fully hiding them, but a
# stub still reads as "there's a wall here" instead of the wall silently
# vanishing, which got confusing once a floor had more than one room's worth
# of walls (interior partitions, balconies, mezzanines...) all applying the
# same near-camera rule at once. This only sets each wall's *target* height
# fraction; _update_wall_fade eases toward it every frame so a wall crossing
# the threshold shrinks smoothly instead of popping instantly.
const WALL_FADE_SPEED := 6.0     # height-fraction units/sec
const STUB_HEIGHT_M   := 0.02    # a lowered wall: a line painted on the floor where it stands (a 25 cm step read as a kerb)

func _update_wall_visibility(cam_offset: Vector3) -> void:
	var flat := Vector3(cam_offset.x, 0.0, cam_offset.z)
	if flat.length() < 0.001:
		return
	flat = flat.normalized()
	_cam_flat_dir = flat
	_turn_flat_labels(flat)
	for wd in _wall_data:
		if wd.get("force_hidden", false):
			continue   # a balcony window replaced this wall outright — never fade it back in
		var target := 1.0
		match wall_mode:
			WallMode.UP:
				target = 1.0
			WallMode.DOWN:
				target = 0.0
			_:
				if wd.get("interior", false):
					# Interior walls are always down in the cutaway, drawn on
					# the floor with their doors: deciding them by where the
					# camera was centred made them come and go as it panned,
					# which read as random. Only the far outside walls stand.
					target = 0.0
				else:
					# A perimeter wall is in the way when the camera is on its
					# outside, looking in.
					target = 0.0 if (wd["normal"] as Vector3).dot(flat) > 0.0 else 1.0
		wd["target_h"] = target
	_update_scenery_visibility(flat)


func set_wall_mode(mode: int) -> void:
	wall_mode = clampi(mode, 0, WallMode.size() - 1)
	if is_instance_valid(_walls_btn):
		_walls_btn.text = tr(WALL_MODE_LABELS[wall_mode])
	if is_node_ready() and _room_w_m > 0.0:
		_update_camera()   # re-evaluates every wall against the new mode


# Whether the view's own keys (Q/E, W/A/S/D, Home/End) apply right now: a
# real room is showing (not the shop's single-item preview), and the player
# isn't typing into a text field.
func _camera_keys_active() -> bool:
	if not is_visible_in_tree() or _room_w_m <= 0.0 or _auto_spin:
		return false
	var focused := get_viewport().gui_get_focus_owner()
	return not (focused is LineEdit or focused is TextEdit)


# Turns the view a quarter turn (steps = -1 or 1) onto the nearest of the
# four diagonal views, so a couple of taps always lands on a clean angle
# however the camera was left by a free orbit.
func _turn_view(steps: int) -> void:
	# Tapping again mid-turn adds another quarter to where the turn was
	# heading, rather than re-snapping from wherever it has got to.
	var from_yaw := _turn_target if (_turn_tween != null and _turn_tween.is_valid()) else _yaw
	_stop_turn()
	var target := HOME_YAW + (roundf((from_yaw - HOME_YAW) / 90.0) + steps) * 90.0
	_turn_target = target
	if GameState.reduce_motion:
		_yaw = target
		_update_camera()
		return
	var from := _yaw
	_turn_tween = create_tween()
	_turn_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_turn_tween.tween_method(func(v: float) -> void:
		_yaw = v
		_update_camera(),
		from, target, TURN_SECONDS)


func _stop_turn() -> void:
	if _turn_tween != null and _turn_tween.is_valid():
		_turn_tween.kill()
	_turn_tween = null


# W/A/S/D slide the point the camera looks at across the floor, relative to
# the view: W away from the camera, S toward it, A/D sideways. Same limits as
# dragging the floor, and the cutaway follows along.
func _key_pan(delta: float) -> void:
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_META):
		return
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if move == Vector2.ZERO:
		return
	var right := cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var toward := Vector3(_cam_flat_dir.x, 0.0, _cam_flat_dir.z)
	_center += (right * move.x + toward * move.y).normalized() * _dist * KEY_PAN_SPEED * delta
	_center = _clamp_pan_center(_center)
	_update_camera()


# A balcony window is a permanent architectural opening, not furniture sitting
# in front of the wall — a solid wall behind it (this game otherwise has no
# real cutout system anywhere, just an overlay decal per
# _add_wall_opening_overlay) defeated the whole point of opening it. Finds
# the closest wall segment to the placed item (matched on whichever axis
# that wall's own normal points along) and replaces its plain box mesh with
# a real CSG-cut one via _rebuild_wall_with_hole, punching an actual hole
# rather than hiding the whole segment or papering over it with a decal.
func _hide_wall_behind_item(item_pos: Vector3, item_box_size: Vector3, f: Furniture) -> void:
	# Always restore this item's own previous hole (a no-op if it never cut
	# one) before searching fresh — searching while EXCLUDING the item's
	# already-owned wall (the previous approach) meant a fold toggle, which
	# moves the box's center as its depth grows/shrinks, could resolve to a
	# genuinely different "closest" wall and cut a SECOND hole for the same
	# item instead of just re-cutting the first one at its new size. That
	# left two holes per item, and _restore_wall_hole (which only undid one
	# match) couldn't fully clean either of them up on sell.
	_restore_wall_hole(f)
	var best_wd: Dictionary = {}
	var best_dist := INF
	for wd in _wall_data:
		var mesh: Node3D = wd["mesh"]   # MeshInstance3D normally, or a CSGCombiner3D if _rebuild_wall_with_hole already ran on it
		var normal: Vector3 = wd["normal"]
		var dist: float = absf(item_pos.x - mesh.position.x) if absf(normal.x) > 0.5 else absf(item_pos.z - mesh.position.z)
		if dist < best_dist:
			best_dist = dist
			best_wd = wd
	if best_wd.is_empty() or best_wd.get("has_hole", false):
		return
	_rebuild_wall_with_hole(best_wd, item_pos, item_box_size, f)


# Undoes _rebuild_wall_with_hole for whichever wall(s) the given item cut a
# hole in (normally just one, but this cleans up every match rather than
# stopping at the first — belt and braces against the item ever ending up
# owning more than one again), rebuilding the original plain wall mesh from
# the parameters cached at cut time. Called when the item is sold
# (remove_furniture_entry), picked up to be dragged elsewhere
# (_begin_furniture_drag), and at the start of every _hide_wall_behind_item
# call — neither a sold, mid-move, nor about-to-be-recut item should leave a
# permanent hole in a wall behind.
func _restore_wall_hole(f: Furniture) -> void:
	for wd in _wall_data:
		if wd.get("hole_owner", null) != f:
			continue
		var root: Node3D = wd["mesh"]
		var orig: Dictionary = wd["orig_wall"]
		if is_instance_valid(root):
			root.queue_free()
		var mesh := _add_sloped_wall(orig["length"], orig["thick"], orig["height"], orig["height"],
			orig["pos"], orig["rot_y_deg"], orig["color"], wd.get("role", StyleController.ROLE_WALL))
		wd["mesh"] = mesh
		wd.erase("has_hole")
		wd.erase("hole_owner")
		wd.erase("orig_wall")
		wd["force_hidden"] = false
		wd["target_h"] = 1.0
		wd["h"] = 1.0


# Replaces a plain wall MeshInstance3D with a CSGCombiner3D (wall box minus a
# hole box) at the exact same transform — only handles the flat-wall case
# (_wedge_mesh's h0==h1; a sloped wall's local AABB doesn't describe a
# simple box, so cutting a rectangular hole in it isn't attempted here, and
# it falls back to the old force-hide behavior instead). The wall mesh's own
# local geometry starts at a CORNER (0,0,0) and extends to
# (length, height, thick) — see _wedge_mesh — not centered, so every CSGBox3D
# below is offset by half its own size to land in the same place a piece of
# that box would have.
func _rebuild_wall_with_hole(wd: Dictionary, item_pos: Vector3, item_box_size: Vector3, f: Furniture) -> void:
	var old_mesh: MeshInstance3D = wd["mesh"]
	var aabb := old_mesh.mesh.get_aabb()
	var length := aabb.size.x
	var height := aabb.size.y
	var thick  := aabb.size.z
	if absf(aabb.size.y - wd.get("full_h", height)) > 0.01:
		# Sloped wall (or anything else whose AABB doesn't match a flat box) —
		# no clean rectangular cut to make; fall back to hiding it outright.
		wd["force_hidden"] = true
		wd["target_h"] = 0.0
		wd["h"] = 0.0
		old_mesh.scale.y = 0.001
		return
	var mat := old_mesh.material_override as StandardMaterial3D
	var color := mat.albedo_color if mat else Color(0.86, 0.83, 0.76)
	# Cached so _restore_wall_hole can rebuild the exact same plain wall back
	# if this item is later sold or picked up to move elsewhere.
	wd["orig_wall"] = {
		"length": length, "thick": thick, "height": height,
		"pos": old_mesh.position, "rot_y_deg": rad_to_deg(old_mesh.rotation.y),
		"color": color,
	}
	wd["hole_owner"] = f

	var hole_local := old_mesh.global_transform.affine_inverse() * item_pos
	var hole_w := maxf(item_box_size.x, item_box_size.z)
	var hole_h := minf(item_box_size.y, height)   # never taller than the wall itself

	var root := CSGCombiner3D.new()
	root.position = old_mesh.position
	root.rotation = old_mesh.rotation
	build_root.add_child(root)

	var wall_box := CSGBox3D.new()
	wall_box.size = Vector3(length, height, thick)
	wall_box.position = Vector3(length * 0.5, height * 0.5, thick * 0.5)
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = color
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	wall_box.material = wall_mat
	if _style != null:
		wall_box.material = _style.material_for(wd.get("role", StyleController.ROLE_WALL))
	root.add_child(wall_box)

	var hole := CSGBox3D.new()
	hole.operation = CSGShape3D.OPERATION_SUBTRACTION
	hole.size = Vector3(hole_w, hole_h, thick * 4.0)   # over-extended depth for a clean through-cut
	hole.position = Vector3(hole_local.x, hole_h * 0.5, thick * 0.5)
	root.add_child(hole)

	old_mesh.queue_free()
	wd["mesh"] = root
	wd["has_hole"] = true
	wd["force_hidden"] = true   # opt out of the camera-facing fade entirely — a CSGCombiner3D has no .scale.y stub trick, and the hole itself already does the job that fade was for


func _update_wall_fade(delta: float) -> void:
	for wd in _wall_data:
		if wd.get("force_hidden", false):
			continue
		var target: float = wd.get("target_h", 1.0)
		var h: float = wd.get("h", 1.0)
		if h == target:
			continue
		h = move_toward(h, target, delta * WALL_FADE_SPEED)
		wd["h"] = h
		var mesh: MeshInstance3D = wd["mesh"]
		var full_h: float = wd.get("full_h", WALL_H_M)
		var stub_ratio := clampf(STUB_HEIGHT_M / full_h, 0.0, 1.0)
		mesh.scale.y = lerpf(stub_ratio, 1.0, h)
		# A window squashed onto a 25 cm stub reads as clutter: drop the wall's
		# dressing once it's mostly down. (Parts die with the wall mesh if a
		# balcony hole rebuilds it, hence the validity check.)
		for part in wd.get("decor", []):
			if is_instance_valid(part):
				(part as Node3D).visible = h > 0.6
		# ...and mark where its openings are on the stub's cut face instead.
		for mark in mesh.get_meta("stub_marks", []):
			if is_instance_valid(mark):
				(mark as Node3D).visible = h <= 0.6


func _ensure_reason_label() -> void:
	if is_instance_valid(_reason_label):
		return
	_reason_label = Label.new()
	_reason_label.add_theme_font_size_override("font_size", 11)
	_reason_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.80, 0.95))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.04, 0.03, 0.88)
	bg.set_content_margin_all(4)
	bg.set_corner_radius_all(3)
	_reason_label.add_theme_stylebox_override("normal", bg)
	_reason_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reason_label.visible = false
	_reason_label.z_index = 50
	add_child(_reason_label)


# Live "why can't I drop it here" chip that tracks the cursor while an
# invalid ghost is being dragged — mirrors Furniture.gd's 2D drag reason.
func _show_reason(text: String) -> void:
	if text == "":
		_hide_reason()
		return
	_ensure_reason_label()
	_reason_label.text = text
	_reason_label.modulate.a = 1.0
	_reason_label.position = _last_local_mouse + Vector2(14, 14)
	_reason_label.visible = true
	_reason_flash_t = 0.0   # a live reason always wins over a fading one


func _hide_reason() -> void:
	if is_instance_valid(_reason_label):
		_reason_label.visible = false


# Same reason chip, but lingering (with a fade) after a rejected drop/confirm
# — dragging stops immediately on release, so without this the player only
# ever got a silent snap-back with no lasting explanation, and 3D never even
# played the 2D view's error sound.
func _flash_reason(text: String) -> void:
	Audio.play("error")
	if text == "":
		return
	_ensure_reason_label()
	_reason_label.text = text
	_reason_label.modulate.a = 1.0
	_reason_label.position = _last_local_mouse + Vector2(14, 14)
	_reason_label.visible = true
	_reason_flash_t = REASON_FLASH_DURATION


# `catalog` is the furniture data array (gm.furniture_data["furniture"]).
# `below_floor`: when viewing a loft, its own base floor — rendered as a
# dim, non-interactive "ghost" layer at the correct height beneath it, so
# the player doesn't lose their bearings on what's directly underneath.
func build_from_floor(apt_floor: Floor, catalog: Array, below_floor: Floor = null) -> void:
	cancel_camera_travel()
	_stop_turn()
	if is_instance_valid(_walls_btn):
		_walls_btn.text = tr(WALL_MODE_LABELS[wall_mode])
		_walls_btn.visible = true
	_auto_spin = false
	_foldable  = false
	_fold_mesh = null
	_tenant = null
	_tenant_stops.clear()
	for c in build_root.get_children():
		c.queue_free()
	_wall_data.clear()
	_scenery_nodes.clear()
	_clear_extras()
	_wall_grid_overlays.clear()
	_hitbox_highlights.clear()
	_drag_highlight = null
	_hover_highlight = null
	_hover_furniture = null
	_furniture_entries.clear()
	_wall_item_entries.clear()
	_doors.clear()
	_hover_door = null
	_dragging_furniture = false
	_dragging_wall_item = false
	_drag_target = {}
	_drag_wall_target = {}

	_apt_floor = apt_floor
	_catalog   = catalog
	var bounds := apt_floor.get_room_bounds()
	_room_bounds = bounds
	# Every wall is one tile thick and stands on the tile row (or column) of
	# its own line, as in the plan (GridDraw, Floor.can_place): the north and
	# west walls on the room's first row and column, the south and east walls
	# on the row and column just past the last one furniture can use. So the
	# model spans one tile more than the bounds, and the far walls stand on
	# that extra tile, not on the last usable one.
	var w := (bounds.size.x + 1) * TILE_M
	var d := (bounds.size.y + 1) * TILE_M
	_room_w_m = w
	_room_d_m = d

	_center = Vector3(w * 0.5, WALL_H_M * 0.35, d * 0.5)
	_dist   = maxf(w, d) * 1.4 + 2.0
	_home_center = _center
	_home_dist   = _dist
	if _style != null:
		_style.scene_center = Vector3(w * 0.5, 1.0, d * 0.5)
		_style.scene_radius = maxf(w, d) * 0.75 + 1.0
		# The long lens wastes less of the frame on perspective, so the home
		# view can sit closer and let the room fill it. Zoom still works as before.
		# Fit the whole room, walls included, into the frame: far enough
		# back for its bounding sphere and no further. A fixed margin on
		# top of the longest side left small rooms as a speck in the middle
		# of the screen.
		var room_radius := 0.5 * Vector3(w, WALL_H_M, d).length()
		_dist = maxf(room_radius * 1.45, 2.2)
		_home_dist = _dist

	# A different apartment than last time: its own remembered camera, or the
	# home view on a first visit. (A rebuild of the SAME level keeps whatever
	# angle the player had, as before.)
	if Time.get_ticks_msec() <= _next_camera_until_ms:
		if _next_camera_state.is_empty():
			_yaw = HOME_YAW
			_pitch = HOME_PITCH
		else:
			_yaw = _next_camera_state.get("yaw", HOME_YAW) as float
			_pitch = _next_camera_state.get("pitch", HOME_PITCH) as float
			_dist = clampf(_next_camera_state.get("dist", _dist) as float, 1.5, _max_dist())
			_center = _clamp_pan_center(_next_camera_state.get("center", _center) as Vector3)

	if _style != null:
		_style.daylight = _daylight
	_add_floor(w, d)
	if below_floor == null:   # a loft shows the floor beneath it there instead
		# Inside a box the room stands on its parent's floor; otherwise it
		# floats on its own block.
		if not _add_parent_scenery(w, d):
			if _style != null:
				_add_desk_scenery(w, d)
			else:
				_add_plinth(w, d)

	# Subfloor/ceiling/roof layers only exist to carry the 2D-only pipe/duct
	# overlays (GridDraw's _draw_subfloor_layer, etc.) — they have no walls or
	# columns of their own, so building the normal room here would just be an
	# empty box with nothing in it. A label is a more honest placeholder than
	# silently rendering "nothing." A loft is NOT one of these — it has real
	# segments/columns/furniture exactly like a ground floor (2D already
	# renders it fully), so it belongs on the "build the room" side, not
	# lumped in with the label-only layers just because its type isn't
	# literally "floor".
	if apt_floor.floor_type in ["subfloor", "floor_sub", "ceiling", "roof"]:
		_add_special_layer_label(apt_floor.floor_type, w, d)
		_update_camera()
		return

	_add_walls(w, d, apt_floor.sloped_ceiling, bounds)
	_outside_signs.clear()   # freed with the rest of build_root's children
	_build_outside_signs()
	_home_outlines.clear()
	_build_home_outlines()
	_add_columns(bounds)
	_add_window_door_overlays(bounds)
	_add_rails(bounds)
	_add_reveal_zone_markers(bounds)
	_add_balcony_extras(bounds)
	_add_stairs(bounds)
	_update_camera()   # also applies initial wall visibility now that _wall_data exists

	for item in apt_floor.get_all_furniture():
		_add_piece_rail(item as Furniture, bounds)
		_add_furniture_box(item as Furniture, bounds, catalog)
	_settle_stacked()
	_rule_root = null   # freed with the rest of build_root's children
	_rebuild_rule_overlays()

	for edge in apt_floor.wall_items:
		var items: Dictionary = apt_floor.wall_items[edge] as Dictionary
		for origin in items:
			_add_wall_item_box(edge, origin as Vector2i, items[origin] as String, catalog)

	if below_floor:
		_add_ghost_floor(below_floor, bounds)

	_apply_moment_lighting()
	if _style != null:
		build_root.add_child(RoomLighting.new(self))   # sun through the windows, lamps at night


# ── Ghost reference layer (floor directly below a loft) ────────────────────
# Flat grey, translucent, no models/textures and never added to any of the
# pick/drag lists — purely a "here's what's underneath" cue, not a second
# interactive floor. Positioned using the LOFT's own bounds (not the below
# floor's bounds) so tile coordinates line up: a mezzanine and its base
# floor share the same absolute apartment grid, they just each report a
# different sub-rectangle of it via get_room_bounds().
const GHOST_COLOR := Color(0.55, 0.56, 0.58)
const GHOST_ALPHA := 0.22

func _add_ghost_floor(below_floor: Floor, bounds: Rect2i) -> void:
	var y_off := -Floor.FLOOR_HEIGHT_TILES * TILE_M
	var w := bounds.size.x * TILE_M
	var d := bounds.size.y * TILE_M

	_make_ghost(_box(Vector3(w, 0.05, d), Vector3(w * 0.5, y_off - 0.025, d * 0.5), GHOST_COLOR))

	for seg in below_floor.segments:
		if (seg as Dictionary).get("demolished", false):
			continue
		var x1: int = seg["x1"]; var y1: int = seg["y1"]
		var x2: int = seg["x2"]; var y2: int = seg["y2"]
		var lx1 := (x1 - bounds.position.x) * TILE_M
		var lz1 := (y1 - bounds.position.y) * TILE_M
		var lx2 := (x2 - bounds.position.x) * TILE_M
		var lz2 := (y2 - bounds.position.y) * TILE_M
		var length := Vector2(lx2 - lx1, lz2 - lz1).length()
		if length < 0.001:
			continue
		var horizontal := absf(lz2 - lz1) < 0.001
		var seg_size := Vector3(length, WALL_H_M, WALL_THICK) if horizontal else Vector3(WALL_THICK, WALL_H_M, length)
		var mid := Vector3((lx1 + lx2) * 0.5, y_off + WALL_H_M * 0.5, (lz1 + lz2) * 0.5)
		_make_ghost(_box(seg_size, mid, GHOST_COLOR))

	for item in below_floor.get_all_furniture():
		var f := item as Furniture
		var fw := f.grid_w * TILE_M
		var fd := f.grid_h * TILE_M
		var height_m := maxf(f.z_top / 10.0, 0.2)   # 10 tiles/m, see FLOOR_HEIGHT_TILES
		var lx := (f.grid_pos.x - bounds.position.x) * TILE_M + fw * 0.5
		var lz := (f.grid_pos.y - bounds.position.y) * TILE_M + fd * 0.5
		_make_ghost(_box(Vector3(fw, height_m, fd), Vector3(lx, y_off + height_m * 0.5, lz), GHOST_COLOR))

	_add_ghost_stairs(below_floor, bounds)


func _make_ghost(mi: MeshInstance3D) -> void:
	var mat := mi.material_override as StandardMaterial3D
	if mat:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = GHOST_ALPHA
	if _style != null:
		_style.style_node_transparent(mi, StyleController.ROLE_WALL, GHOST_ALPHA)
	mi.set_meta("is_ghost", true)


# ── Day/Night lighting ──────────────────────────────────────────────────────
# The moment system (DAY/NIGHT tenant needs, per-moment fold/rail state) had
# no visual counterpart in 3D — switching moments only updated checklist
# icons, the room itself stayed lit identically. Keyed off the active
# moment's own id/label rather than a hardcoded "day"/"night" pair so any
# moment whose name contains "night" gets the dim preset, everything else
# (including levels with no moments at all) gets the normal daylight rig.
const _DAY_SUN_ENERGY   := 1.1
const _DAY_SUN_COLOR    := Color(1.0, 1.0, 1.0)
const _DAY_AMBIENT      := Color(0.9, 0.9, 0.95)
const _DAY_AMBIENT_NRG  := 0.45
const _DAY_BG           := Color(0.85, 0.87, 0.9)
const _NIGHT_SUN_ENERGY  := 0.12
const _NIGHT_SUN_COLOR   := Color(0.55, 0.62, 0.85)
const _NIGHT_AMBIENT     := Color(0.10, 0.11, 0.20)
const _NIGHT_AMBIENT_NRG := 0.30
const _NIGHT_BG          := Color(0.04, 0.05, 0.10)


func _is_night_moment() -> bool:
	var mid := Furniture.active_moment_id.to_lower()
	return mid.find("night") != -1


func _apply_moment_lighting() -> void:
	var night := _is_night_moment()
	var sun_energy: float  = _NIGHT_SUN_ENERGY  if night else _DAY_SUN_ENERGY
	var sun_color: Color   = _NIGHT_SUN_COLOR   if night else _DAY_SUN_COLOR
	var ambient: Color     = _NIGHT_AMBIENT     if night else _DAY_AMBIENT
	var ambient_nrg: float = _NIGHT_AMBIENT_NRG if night else _DAY_AMBIENT_NRG
	var bg: Color          = _NIGHT_BG          if night else _DAY_BG
	if _style != null:
		# Styled: day is the level palette as authored, night is the same
		# palette dimmed and cooled by the StyleController.
		var night_target := 1.0 if night else 0.0
		if GameState.reduce_motion:
			_style.night = night_target
		else:
			create_tween().tween_property(_style, "night", night_target, 0.6)
		return
	var env := _world_env.environment
	if GameState.reduce_motion:
		_sun.light_energy = sun_energy
		_sun.light_color  = sun_color
		env.ambient_light_color  = ambient
		env.ambient_light_energy = ambient_nrg
		env.background_color     = bg
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_sun, "light_energy", sun_energy, 0.6)
	tw.tween_property(_sun, "light_color",  sun_color,  0.6)
	tw.tween_property(env,  "ambient_light_color",  ambient,     0.6)
	tw.tween_property(env,  "ambient_light_energy", ambient_nrg, 0.6)
	tw.tween_property(env,  "background_color",     bg,          0.6)


# Product-shot mode: a single item on a small floor pad, slowly auto-rotating,
# with no walls. `fdata` is one entry from the furniture catalog (a Dictionary
# with size/wall_h/color etc, the same shape build_from_floor reads).
func build_single_item(fdata: Dictionary) -> void:
	_auto_spin = true
	_yaw   = -30.0
	_pitch = -22.0
	_foldable  = fdata.get("foldable", false) as bool
	_fold_mesh = null
	for c in build_root.get_children():
		c.queue_free()
	_wall_data.clear()
	_scenery_nodes.clear()
	_clear_extras()
	if _style != null:
		var item_dims := fdata.get("size", {}) as Dictionary
		_style.scene_center = Vector3.ZERO
		_style.scene_radius = maxf(item_dims.get("w", 5) as float, item_dims.get("h", 5) as float) * TILE_M * 1.5 + 0.5
		_style.night = 0.0

	var iw: int = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
	var ih: int = (fdata.get("size", {}) as Dictionary).get("h", 5) as int
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := iw * TILE_M
	var fd := ih * TILE_M
	var col := Color("#" + (fdata.get("color", "888888") as String))

	if _foldable:
		# `extended_add_h` (tiles) is the same field the 2D game uses to grow a
		# foldable item's footprint when deployed — reuse it here so the demo
		# matches the item's real folded/extended sizes.
		const OPEN_THICK := 0.15   # generic "lying flat" thickness — no per-item field for this
		var add_h: int = fdata.get("extended_add_h", 6) as int
		var closed_depth := fd
		var open_depth   := (ih + add_h) * TILE_M

		var pad := maxf(fw, maxf(open_depth, height_m)) * 1.7
		_center = Vector3(0.0, height_m * 0.35, open_depth * 0.25)
		_dist   = maxf(fw, maxf(open_depth, height_m)) * 2.4 + 1.0

		_box(Vector3(pad, 0.05, pad), Vector3(0.0, -0.025, 0.0), Color(0.93, 0.90, 0.83), StyleController.ROLE_FLOOR)

		# Backdrop "wall" for context — the panel folds up flush against it.
		var wall_z := -pad * 0.2
		_box(Vector3(fw * 1.3, height_m * 1.15, 0.05), Vector3(0.0, height_m * 0.575, wall_z), Color(0.86, 0.83, 0.76), StyleController.ROLE_WALL)

		_fold_closed_size = Vector3(fw, height_m, closed_depth)
		_fold_closed_pos  = Vector3(0.0, height_m * 0.5, wall_z + closed_depth * 0.5 + 0.03)
		_fold_open_size   = Vector3(fw, OPEN_THICK, open_depth)
		_fold_open_pos    = Vector3(0.0, OPEN_THICK * 0.5, wall_z + open_depth * 0.5 + 0.05)

		_fold_t      = 0.0
		_fold_target = 0.0
		_fold_auto   = true
		_fold_phase  = 0.0
		_fold_fdata  = fdata
		_fold_model_extended_shown = false
		_fold_mesh = _box(_fold_closed_size, _fold_closed_pos, col)
		# Show the item's real closed-state model instead of leaving this a bare
		# colored box — _update_fold_visual() swaps it for the open-state model
		# (model_extended) as the demo animates past the halfway point.
		_apply_item_model(_fold_mesh, _active_model_path(fdata, false), _fold_closed_size, fdata.get("hide_nodes", []) as Array)
	else:
		var pad := maxf(fw, fd) * 1.6
		_center = Vector3(0.0, height_m * 0.4, 0.0)
		_dist   = maxf(fw, maxf(fd, height_m)) * 2.2 + 1.0
		_box(Vector3(pad, 0.05, pad), Vector3(0.0, -0.025, 0.0), Color(0.93, 0.90, 0.83), StyleController.ROLE_FLOOR)
		var item_size := Vector3(fw, height_m, fd)
		var item_mi := _box(item_size, Vector3(0.0, height_m * 0.5, 0.0), col)
		item_mi.set_meta("style_role", _item_role(fdata))
		_apply_item_model(item_mi, _active_model_path(fdata, false), item_size, fdata.get("hide_nodes", []) as Array)
		_style_if_bare(item_mi)

	_update_camera()


func _find_furniture_data(catalog: Array, fid: String) -> Dictionary:
	for f in catalog:
		if (f as Dictionary).get("id", "") == fid:
			return f as Dictionary
	return {}


# `role` (a StyleController.ROLE_*) restyles the box with the level palette.
# Left empty for furniture placeholders, whose own material doubles as the
# switch that hides them once a model is applied.
func _box(box_size: Vector3, pos: Vector3, color: Color, role: StringName = &"") -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	build_root.add_child(mi)
	if role != &"":
		_style_node(mi, role)
	return mi


# Swaps a placeholder box's own surface for a real model (the studio's own
# Space-Saving Furniture Kit — see assets/models/furniture/README.txt), fitted
# to the box and grounded/centered inside it. `mi`
# keeps its existing transform/size as the pick/drag/fold anchor the rest of
# this script already relies on — only its own mesh surface is removed, the
# model renders as a child instead. No-op (box stays visible) if the item has
# no "model" entry or the file can't be loaded.
func _apply_item_model(mi: MeshInstance3D, model_path: String, box_size: Vector3, hide_nodes: Array = []) -> void:
	# Clear a previously-applied model (re-fit case, e.g. re-running this on
	# an already-modeled drag ghost) before possibly adding a fresh one.
	if mi.has_meta("model_inst"):
		var old_inst: Node = mi.get_meta("model_inst")
		if old_inst and is_instance_valid(old_inst):
			old_inst.queue_free()
		mi.set_meta("model_inst", null)

	# _active_model_path() marks "show this model unfolded" with a suffix.
	var open_pose := model_path.ends_with(OPEN_POSE_SUFFIX)
	model_path = model_path.trim_suffix(OPEN_POSE_SUFFIX)
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return
	var packed := load(model_path) as PackedScene
	if not packed:
		return
	var inst := packed.instantiate() as Node3D
	if not inst:
		return
	# A foldable piece is shown unfolded by posing the model at the end of
	# its own "open" clip before it is measured, so the open shape is what
	# gets fitted to the unfolded footprint.
	if open_pose:
		var poser := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if poser != null and poser.has_animation("open"):
			poser.play("open")
			poser.seek(poser.get_animation("open").length, true)
			poser.pause()
	# Measured across every part of the model (a carcass, doors, legs, a
	# mattress), not just the first one.
	var native := _combined_aabb(inst)
	if native.size.x <= 0.0001 or native.size.y <= 0.0001 or native.size.z <= 0.0001:
		inst.queue_free()
		return
	# Keep the placeholder box as the mesh (some callers keep resizing it every
	# frame while dragging) but make it invisible — the model renders instead.
	var mat := mi.material_override as StandardMaterial3D
	if mat:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.0
	mi.add_child(inst)
	_style_node(inst, mi.get_meta("style_role", StyleController.ROLE_FURNITURE))
	# Some shared models cover more than one item (e.g. the bunk-bed model
	# doubles as the Loft Bed) — a piece can list child node names to hide so
	# it reads as a distinct silhouette without needing its own separate file.
	for node_name in hide_nodes:
		var n := inst.find_child(node_name as String, true, false)
		if n is Node3D:
			(n as Node3D).visible = false
	mi.set_meta("model_inst", inst)
	mi.set_meta("model_native", native)
	_refit_item_model(mi, box_size)


# Cheap per-frame rescale of an already-instantiated model (used while a drag
# ghost is resizing, e.g. swapping between floor and wall placement) — avoids
# reloading/reinstantiating the whole .glb every frame.
const MODEL_HEIGHT_GIVE := 1.35

func _refit_item_model(mi: MeshInstance3D, box_size: Vector3) -> void:
	# An animated-fold piece (futon, sofa bed) carries a model but is never
	# exact-fit scaled, so it has no "model_native" box to refit from. The
	# buy ghost's wall branch calls this for every piece; without the second
	# check, hovering one of those over a wall errored on every mouse move.
	if not mi.has_meta("model_inst") or not mi.has_meta("model_native"):
		return
	var inst: Node3D = mi.get_meta("model_inst")
	if not inst or not is_instance_valid(inst):
		return
	var native: AABB = mi.get_meta("model_native")
	# Non-uniform: scale each axis independently so the rendered model's
	# silhouette exactly fills box_size — the same box the hitbox highlight
	# draws and can_place() collides against. A uniform fit (scaling by
	# whichever axis was tightest) trusted the model's native proportions to
	# roughly match the catalog's tile footprint, but they routinely don't
	# (a "Bed" model sized nothing like 19x9 tiles), leaving it rattling
	# around inside a hitbox 2-3x its visible size — which is what's actually
	# confusing, not a slightly-off aspect ratio. Exact fit wins here.
	#
	# Some models are authored with their long axis along local Z instead of
	# X (bedSingle.glb's real body is ~1.1m along Z, ~0.56m along X, while
	# the catalog's box is 1.9m along X, 0.9m along Z) — fitting X-to-X and
	# Z-to-Z directly then stretches the short axis into the long one,
	# rendering a bed 3x too wide. Detect that mismatch by comparing which
	# axis is "long" on each side and, if they disagree, swap which box
	# dimension each native axis targets and yaw the model 90° to match.
	var box_x_is_long    := box_size.x    >= box_size.z
	var native_x_is_long := native.size.x >= native.size.z
	var swapped := box_x_is_long != native_x_is_long
	var scale_v: Vector3
	var rot_y: float
	if swapped:
		scale_v = Vector3(box_size.z / native.size.x, box_size.y / native.size.y, box_size.x / native.size.z)
		rot_y = PI * 0.5
	else:
		scale_v = Vector3(box_size.x / native.size.x, box_size.y / native.size.y, box_size.z / native.size.z)
		rot_y = 0.0
	# The footprint is exact (it is what the piece collides with); the height
	# follows the model's own proportions instead of the catalogue's number,
	# within a third either way, so a piece is never squashed flat or pulled
	# into a tower to match a height written for a different model.
	var proportional := sqrt(scale_v.x * scale_v.z)
	scale_v.y = clampf(scale_v.y, proportional / MODEL_HEIGHT_GIVE, proportional * MODEL_HEIGHT_GIVE)
	inst.scale = scale_v
	inst.rotation.y = rot_y
	var local_center := Vector3(
		(native.position.x + native.size.x * 0.5) * scale_v.x, 0.0,
		(native.position.z + native.size.z * 0.5) * scale_v.z)
	var world_center := Basis(Vector3.UP, rot_y) * local_center
	inst.position = Vector3(
		-world_center.x,
		-box_size.y * 0.5 - native.position.y * scale_v.y,
		-world_center.z)


# Bounding box across every mesh in the model, in the model's own space.
func _combined_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var have_box := false
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var n: Node3D = entry[0]
		var xform: Transform3D = entry[1]
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mesh_box: AABB = xform * (n as MeshInstance3D).mesh.get_aabb()
			box = box.merge(mesh_box) if have_box else mesh_box
			have_box = true
		for child in n.get_children():
			if child is Node3D:
				stack.append([child, xform * (child as Node3D).transform])
	return box


func _add_floor(w: float, d: float) -> void:
	_box(Vector3(w, 0.05, d), Vector3(w * 0.5, -0.025, d * 0.5), Color(0.93, 0.90, 0.83), StyleController.ROLE_FLOOR)
	_add_grid_overlay(w, d)


# A tile-aligned grid, hidden by default and only shown while a piece is
# being bought or dragged on the floor — mirrors GridDraw.gd's 2D show_grid
# behavior so the player gets the same placement guide in 3D. One tileable
# texture (1 game tile per texture repeat) stretched over the whole floor via
# uv1_scale, so the lines land exactly on tile boundaries regardless of room
# size.
func _add_grid_overlay(w: float, d: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(w, d)
	quad.orientation = PlaneMesh.FACE_Y
	_grid_overlay = MeshInstance3D.new()
	_grid_overlay.mesh = quad
	_grid_overlay.position = Vector3(w * 0.5, 0.002, d * 0.5)
	_grid_overlay.visible = false
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _grid_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.uv1_scale = Vector3(w / TILE_M, d / TILE_M, 1.0)
	_grid_overlay.material_override = mat
	build_root.add_child(_grid_overlay)


var _grid_tex_cache: ImageTexture = null

func _grid_texture() -> ImageTexture:
	if _grid_tex_cache:
		return _grid_tex_cache
	const N := 32
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var line_col := Color(0.15, 0.35, 0.55, 0.55)
	for x in range(N):
		img.set_pixel(x, 0, line_col)
	for y in range(N):
		img.set_pixel(0, y, line_col)
	_grid_tex_cache = ImageTexture.create_from_image(img)
	return _grid_tex_cache


func _set_grid_overlay_visible(v: bool) -> void:
	if is_instance_valid(_grid_overlay):
		_grid_overlay.visible = v


# Same tile grid, applied flat against a wall face — a child of the wall's own
# MeshInstance3D so it inherits that wall's position/rotation for free, offset
# outward along local Z (the wall's thickness axis) just enough to clear
# z-fighting. Uses the taller of the wall's two slope-corner heights when the
# ceiling is sloped, which slightly overhangs the low corner — an acceptable
# guide, not a precise fit.
func _add_wall_grid(parent_mi: MeshInstance3D, length: float, height: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(length, height)
	quad.orientation = PlaneMesh.FACE_Z
	var overlay := MeshInstance3D.new()
	overlay.mesh = quad
	overlay.position = Vector3(length * 0.5, height * 0.5, WALL_THICK + 0.005)
	overlay.visible = false
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _grid_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.uv1_scale = Vector3(length / TILE_M, height / TILE_M, 1.0)
	overlay.material_override = mat
	parent_mi.add_child(overlay)
	_wall_grid_overlays.append(overlay)


# Builds a free-standing outline (4 thin boxes rather than a filled quad, so
# it reads as "this item's tile boundary" without obscuring the grid lines or
# the model itself) for the given footprint, in room-local floor space
# (origin at the footprint's near corner, not its center). Shared by the
# static per-item highlights and the single "currently dragging" outline
# that follows the ghost.
func _build_outline_group(footprint: Vector2, col: Color, y: float) -> Node3D:
	const T := 0.015   # line thickness, m
	var group := Node3D.new()
	group.position.y = y
	var edges := [
		{"size": Vector3(footprint.x + T, 0.001, T), "pos": Vector3(footprint.x * 0.5, 0.0, 0.0)},
		{"size": Vector3(footprint.x + T, 0.001, T), "pos": Vector3(footprint.x * 0.5, 0.0, footprint.y)},
		{"size": Vector3(T, 0.001, footprint.y + T), "pos": Vector3(0.0, 0.0, footprint.y * 0.5)},
		{"size": Vector3(T, 0.001, footprint.y + T), "pos": Vector3(footprint.x, 0.0, footprint.y * 0.5)},
	]
	for e in edges:
		var mesh := BoxMesh.new()
		mesh.size = e["size"]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = e["pos"]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = col
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mat
		group.add_child(mi)
	return group


# A rail-bound piece had no persistent 3D indication that it's actually
# constrained to a rail at all — only the rail itself (_add_rails) and the
# 2D view's own small arrow glyphs (Furniture.gd's _draw()) ever showed it.
# Adds/removes a small always-visible teal outline (same color as the rail
# itself) as a child of the item's own placeholder mesh, so it moves/rotates
# with it automatically and gets freed for free when the mesh does (sold).
const RAIL_INDICATOR_COLOR := Color(0.22, 0.70, 0.78, 0.9)

const RAIL_FLASH_DURATION := 0.4

# A brief expanding, fading ring at the moment a rail attach/detach actually
# happens, plus a distinct sound per direction — the persistent indicator
# above only shows the CURRENT state and turned out too easy to miss
# changing, same issue _flash_rail solves on the 2D side (Furniture.gd).
# Parented to `mesh` so it's cleaned up automatically if the piece gets
# sold/re-dragged mid-flash.
func _flash_rail(mesh: MeshInstance3D, footprint: Vector2, attached: bool) -> void:
	Audio.play("rail_attach" if attached else "rail_detach")
	var col := RAIL_INDICATOR_COLOR if attached else Color(0.85, 0.55, 0.20, 1.0)
	# `mesh` is centered on its OWN vertical middle (its box's Y size * 0.5,
	# per _add_furniture_box/_confirm_buy), not its base — a plain small
	# constant y here (as a previous version used) put the ring at the
	# item's mid-height instead of the floor it's meant to read as coming
	# from. Subtracting half the box's own height re-grounds it.
	var half_h := (mesh.mesh as BoxMesh).size.y * 0.5
	var group := _build_outline_group(footprint, col, -half_h + 0.014)
	group.position.x -= footprint.x * 0.5
	group.position.z -= footprint.y * 0.5
	mesh.add_child(group)
	var mats: Array = []
	for child in group.get_children():
		var m := (child as MeshInstance3D).material_override as StandardMaterial3D
		if m:
			mats.append(m)
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		group.scale = Vector3(1.0 + (1.0 - t) * 0.6, 1.0, 1.0 + (1.0 - t) * 0.6)
		for m in mats:
			(m as StandardMaterial3D).albedo_color.a = col.a * t
	, 1.0, 0.0, RAIL_FLASH_DURATION)
	tw.tween_callback(group.queue_free)


func _set_rail_indicator(mesh: MeshInstance3D, f: Furniture, footprint: Vector2) -> void:
	if mesh.has_meta("rail_indicator"):
		var old = mesh.get_meta("rail_indicator")
		if is_instance_valid(old):
			old.queue_free()
		mesh.set_meta("rail_indicator", null)
	if f.rail_axis == "":
		return
	# Same re-grounding as _flash_rail above — `mesh` is centered on its own
	# mid-height, not its base.
	var half_h := (mesh.mesh as BoxMesh).size.y * 0.5
	var group := _build_outline_group(footprint, RAIL_INDICATOR_COLOR, -half_h + 0.01)
	group.position.x -= footprint.x * 0.5
	group.position.z -= footprint.y * 0.5
	mesh.add_child(group)
	mesh.set_meta("rail_indicator", group)


const HITBOX_Y := 0.006   # just above the grid overlay's own 0.002 offset
const HITBOX_COLOR := Color(0.95, 0.25, 0.2, 0.85)     # red — where an item currently sits
const DRAG_HITBOX_COLOR := Color(0.3, 0.9, 0.35, 0.9)  # green — where the dragged item would land
const HOVER_HITBOX_COLOR := Color(0.98, 0.82, 0.35, 0.6)  # amber — "this is grabbable"

# Traced around an existing floor item's footprint — shown alongside the grid
# overlay so a piece being placed can be checked against every other item's
# hitbox at a glance, not just guessed at. Stays put while that item is being
# dragged elsewhere (see _drag_highlight) so the player can compare the old
# and new spots side by side.
func _add_hitbox_highlight(local_pos: Vector3, footprint: Vector2, owner_furniture: Furniture = null) -> void:
	var group := _build_outline_group(footprint, HITBOX_COLOR, HITBOX_Y)
	group.position.x = local_pos.x - footprint.x * 0.5
	group.position.z = local_pos.z - footprint.y * 0.5
	group.visible = false
	group.set_meta("footprint", footprint)
	if owner_furniture:
		group.set_meta("furniture", owner_furniture)
	build_root.add_child(group)
	_hitbox_highlights.append(group)


func _set_hitbox_highlights_visible(v: bool) -> void:
	for h in _hitbox_highlights:
		if is_instance_valid(h):
			h.visible = v


# The single "where this would land" outline for whatever's currently being
# bought or dragged on the floor — separate from the static per-item
# highlights above so the player can see both the old spot (still red) and
# the new one (green) at the same time while dragging an existing piece.
func _show_drag_highlight(footprint: Vector2) -> void:
	if is_instance_valid(_drag_highlight) and _drag_highlight.get_meta("footprint", Vector2.ZERO) == footprint:
		_drag_highlight.visible = true
		return
	_hide_drag_highlight()
	_drag_highlight = _build_outline_group(footprint, DRAG_HITBOX_COLOR, HITBOX_Y + 0.001)
	_drag_highlight.set_meta("footprint", footprint)
	build_root.add_child(_drag_highlight)


func _update_drag_highlight_pos(center_x: float, center_z: float, footprint: Vector2) -> void:
	if not is_instance_valid(_drag_highlight):
		return
	_drag_highlight.position.x = center_x - footprint.x * 0.5
	_drag_highlight.position.z = center_z - footprint.y * 0.5


func _hide_drag_highlight() -> void:
	if is_instance_valid(_drag_highlight):
		_drag_highlight.queue_free()
	_drag_highlight = null


# Idle-hover outline — separate from _drag_highlight (which only exists once
# a drag/buy/wall-drop is actually under way) so the player gets a "this is
# grabbable" cue on the piece their cursor is over BEFORE they click, not
# only after.
var _hover_highlight: Node3D = null
var _hover_furniture: Furniture = null

func _update_hover(vp_pos: Vector2) -> void:
	_hover_door = _door_under(vp_pos) if not (_dragging_furniture or _buying_furniture != null) else null
	var hit := _pick_furniture(vp_pos)
	if hit.is_empty():
		_hide_hover_highlight()
		return
	var f: Furniture = hit["furniture"]
	if f == _hover_furniture and is_instance_valid(_hover_highlight):
		return
	_hide_hover_highlight()
	var pos: Vector3       = hit["pos"]
	var item_size: Vector3 = hit["size"]
	_hover_highlight = _build_outline_group(Vector2(item_size.x, item_size.z), HOVER_HITBOX_COLOR, HITBOX_Y + 0.002)
	_hover_highlight.position.x = pos.x - item_size.x * 0.5
	_hover_highlight.position.z = pos.z - item_size.z * 0.5
	build_root.add_child(_hover_highlight)
	_hover_furniture = f
	container.tooltip_text = tr("Double-click to step inside") if (f.is_nested_box and not f.child_level_id.is_empty()) else ""


func _hide_hover_highlight() -> void:
	if is_instance_valid(_hover_highlight):
		_hover_highlight.queue_free()
	_hover_highlight = null
	_hover_furniture = null


func _set_wall_grid_overlays_visible(v: bool) -> void:
	for ov in _wall_grid_overlays:
		if is_instance_valid(ov):
			ov.visible = v


const RAIL_H_M     := 0.9
const RAIL_THICK_M := 0.03

# Structural columns: floor-to-ceiling posts. can_place() already treats
# their tile as blocked (Wall.gd), so this is purely visual — without it a
# column you can't place furniture on is invisible, which reads as a bug
# rather than "there's a pillar here."
func _add_columns(bounds: Rect2i) -> void:
	if not _apt_floor:
		return
	const COL_COLOR := Color(0.86, 0.94, 1.00)
	for c in _apt_floor.columns:
		var cd := c as Dictionary
		var cx: int = cd.get("x", 0) as int
		var cy: int = cd.get("y", 0) as int
		var local_x := (cx - bounds.position.x) * TILE_M
		var local_z := (cy - bounds.position.y) * TILE_M
		_box(Vector3(TILE_M, WALL_H_M, TILE_M),
			Vector3(local_x + TILE_M * 0.5, WALL_H_M * 0.5, local_z + TILE_M * 0.5), COL_COLOR, StyleController.ROLE_WALL)


# Stairs (from Floor.stairs_data — geometry-only, no furniture object) were
# never rendered in 3D at all: the 2D plan (GridDraw's direction-aware block
# with tread nosings) had no 3D counterpart, so a stair rect just looked like
# empty floor. A staircase placed with LevelEditor's Stairs tool (see its
# STAIR_STEP_DEPTH/STAIR_WIDTH constants) already has a walkable, real-sized
# footprint — so the fix is just to cut THAT rect into treads and stay
# strictly inside it, not to invent extra run past its edges.
#
# A staircase is one physical object shared by the two floors it connects —
# it must NOT be built twice (once as a real flight on its own floor, again
# as a second "new" flight on the floor it arrives at, per _apt_floor.
# stair_openings). The floor it arrives at instead gets a translucent ghost
# of the SAME flight from _add_ghost_floor (below), shifted up so its top
# step touches this floor's underside — see _add_ghost_stairs.
const STAIR_STEP_DEPTH_TILES := 2   # matches LevelEditor.gd's STAIR_STEP_DEPTH
const STAIR_LOFT_COL  := Color(0.52, 0.60, 0.82)
const STAIR_FLOOR_COL := Color(0.78, 0.58, 0.22)

func _add_stairs(bounds: Rect2i) -> void:
	if not _apt_floor:
		return
	var full_h := Floor.FLOOR_HEIGHT_TILES * TILE_M
	for entry in _apt_floor.stairs_data:
		# A staircase placed as furniture brings its own model, drawn with the
		# rest of the furniture; the plain block flight is for stairs that
		# have none (the level's own, or a piece whose model is missing).
		var stair_f: Variant = (entry as Dictionary).get("furniture")
		if is_instance_valid(stair_f):
			var stair_model := _find_furniture_data(_catalog, (stair_f as Furniture).furniture_id).get("model", "") as String
			if not stair_model.is_empty() and ResourceLoader.exists(stair_model):
				continue
		# The level's own stairs use the catalogue's staircase model for their
		# direction, fitted to their footprint; the block flight only if it
		# is missing.
		if _add_stair_model(entry as Dictionary, bounds, full_h):
			continue
		_add_stair_flight(entry as Dictionary, bounds, full_h, 0.0, false)


func _add_stair_model(ed: Dictionary, bounds: Rect2i, full_h: float) -> bool:
	var dir := ed.get("direction", "north") as String
	var path := "res://assets/models/furniture/makeitfit/stair_%s.glb" % dir.substr(0, 1)
	if not ResourceLoader.exists(path):
		return false
	var r := ed["rect"] as Rect2i
	var size := Vector3(r.size.x * TILE_M, full_h, r.size.y * TILE_M)
	var pos := Vector3((r.position.x - bounds.position.x) * TILE_M + size.x * 0.5, full_h * 0.5,
		(r.position.y - bounds.position.y) * TILE_M + size.z * 0.5)
	var mi := _box(size, pos, STAIR_FLOOR_COL)
	mi.set_meta("style_role", StyleController.ROLE_FURNITURE)
	_apply_item_model(mi, path, size, [])
	_style_if_bare(mi)
	return true


func _add_stair_flight(ed: Dictionary, bounds: Rect2i, full_h: float,
		y_offset: float, ghost: bool) -> void:
	var r := ed["rect"] as Rect2i
	var dir := ed.get("direction", "north") as String
	var tgt := ed.get("target", "loft") as String
	var col := STAIR_LOFT_COL if tgt == "loft" else STAIR_FLOOR_COL
	var rx := r.position.x * TILE_M
	var rz := r.position.y * TILE_M
	var rw := r.size.x * TILE_M
	var rd := r.size.y * TILE_M
	var axis_len_tiles := (r.size.y if dir in ["north", "south"] else r.size.x)
	var num_steps := maxi(axis_len_tiles / STAIR_STEP_DEPTH_TILES, 1)
	var step_h := full_h / num_steps
	var step_depth_m := (axis_len_tiles * TILE_M) / num_steps   # fills the rect exactly, no overflow
	for i in range(num_steps):
		var top_h := (i + 1) * step_h
		var along0 := i * step_depth_m   # 0 = the low (entry) end of the run
		var local_x: float
		var local_z: float
		var step_size: Vector3
		match dir:
			"north":   # ascends toward -z; low end at the south (max z) edge
				local_x = rx; local_z = rz + rd - along0 - step_depth_m
				step_size = Vector3(rw, top_h, step_depth_m)
			"south":   # ascends toward +z
				local_x = rx; local_z = rz + along0
				step_size = Vector3(rw, top_h, step_depth_m)
			"east":    # ascends toward +x
				local_x = rx + along0; local_z = rz
				step_size = Vector3(step_depth_m, top_h, rd)
			_:         # west: ascends toward -x
				local_x = rx + rw - along0 - step_depth_m; local_z = rz
				step_size = Vector3(step_depth_m, top_h, rd)
		local_x -= bounds.position.x * TILE_M
		local_z -= bounds.position.y * TILE_M
		var mi := _box(step_size, Vector3(local_x + step_size.x * 0.5, y_offset + top_h * 0.5, local_z + step_size.z * 0.5), col)
		if ghost:
			_make_ghost(mi)


# The translucent flight of stairs a floor's own _add_stairs left off at its
# own top — shifted up by a full floor height so the last step lands exactly
# at y=0 (this floor's underside), giving a "the stairs continue below you"
# cue on the floor a staircase arrives at, without building a second solid
# flight (see _add_stairs).
func _add_ghost_stairs(below_floor: Floor, bounds: Rect2i) -> void:
	var full_h := Floor.FLOOR_HEIGHT_TILES * TILE_M
	var y_off := -full_h
	# below_floor may have stairs going to more than one place (e.g. the
	# ground floor's stairs go both to its own loft AND to the next floor
	# up) — only the flight that actually arrives at THIS floor belongs here.
	var want_target := "loft" if _apt_floor.floor_type == "loft" else "floor"
	for entry in below_floor.stairs_data:
		var ed := entry as Dictionary
		if (ed.get("target", "loft") as String) != want_target:
			continue
		_add_stair_flight(ed, bounds, full_h, y_off, true)


# Windows/doors are only used for restricted-zone math (blocking wall-item
# placement near them) — there's no actual cutout in the wall mesh. A flat
# decal at roughly the right band reads as "there's an opening here" without
# needing to rebuild the wall geometry with a real hole in it.
func _add_window_door_overlays(_bounds: Rect2i) -> void:
	if not _apt_floor:
		return
	for wd in _apt_floor.wall_definitions:
		var d := wd as Dictionary
		var edge: String = d.get("edge", "") as String
		if edge == "":
			continue
		if d.get("has_window", false):
			_add_wall_opening_overlay(edge, d.get("window_x", 0) as int, d.get("window_len", 15) as int,
				0.9, 1.9, _glass_color())
		if d.get("has_door", false):
			_add_wall_opening_overlay(edge, d.get("door_x", 0) as int, 10,
				0.0, 2.0, Color(0.08, 0.09, 0.11, 0.85))


func _add_wall_opening_overlay(edge: String, x_tile: int, len_tiles: int, y0_m: float, y1_m: float, color: Color) -> void:
	var w_m := len_tiles * TILE_M
	var h_m := y1_m - y0_m
	var along := x_tile * TILE_M + w_m * 0.5
	var center_y := y0_m + h_m * 0.5
	var depth_m := 0.02
	var sz: Vector3
	var pos: Vector3
	match edge:
		"north":
			sz  = Vector3(w_m, h_m, depth_m)
			pos = Vector3(along, center_y, depth_m * 0.5 + 0.001)
		"south":
			sz  = Vector3(w_m, h_m, depth_m)
			pos = Vector3(along, center_y, _room_d_m - depth_m * 0.5 - 0.001)
		"west":
			sz  = Vector3(depth_m, h_m, w_m)
			pos = Vector3(depth_m * 0.5 + 0.001, center_y, along)
		_:   # "east"
			sz  = Vector3(depth_m, h_m, w_m)
			pos = Vector3(_room_w_m - depth_m * 0.5 - 0.001, center_y, along)
	var mi := _box(sz, pos, color)
	var mat := mi.material_override as StandardMaterial3D
	if mat:
		mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode     = BaseMaterial3D.CULL_DISABLED


# Reveal zones (the sub-range of a rail a piece must sit in to count as
# "revealed" for a moment's needs) get a glowing floor outline — otherwise
# the only way to know where one is is to check the 2D view.
# Rails (the sliding track a rail-locked item like a dress-up wardrobe is
# constrained to) had no 3D representation at all — only GridDraw.gd's 2D
# floor plan drew them (a dashed teal double-line channel), so in 3D a
# rail-bound piece just looked like it was placed on ordinary floor with no
# visible reason it can only slide one way. Reproduces that same look with
# actual geometry instead of one flat tinted strip: two thin continuous side
# rails plus perpendicular tie marks every tile, like a literal train track
# — reads as "dashed" at a glance without an actual dashed-line shader.
func _add_rails(bounds: Rect2i) -> void:
	if not _apt_floor:
		return
	for rail in _apt_floor.rails:
		var rd := rail as Dictionary
		var x1: int = rd.get("x1", 0) as int
		var y1: int = rd.get("y1", 0) as int
		var x2: int = rd.get("x2", 0) as int
		var y2: int = rd.get("y2", 0) as int
		var is_h_r := (y1 == y2)
		# A piece riding this rail draws its own track under itself (see
		# _add_piece_rail); drawing the authored one too would double it.
		var ridden := false
		for item in _apt_floor.get_all_furniture():
			var rider := item as Furniture
			if rider.rail_axis != ("h" if is_h_r else "v"):
				continue
			var lo := rider.grid_pos.y if is_h_r else rider.grid_pos.x
			var span := rider.grid_h if is_h_r else rider.grid_w
			var line := float(y1 if is_h_r else x1)
			if line >= lo and line < lo + span:
				ridden = true
				break
		if ridden:
			continue
		var local_x := (mini(x1, x2) - bounds.position.x) * TILE_M
		var local_z := (mini(y1, y2) - bounds.position.y) * TILE_M
		var length := (absi(x2 - x1) + 1) * TILE_M if is_h_r else (absi(y2 - y1) + 1) * TILE_M
		var channel_w := (absi(y2 - y1) + 1) * TILE_M if is_h_r else (absi(x2 - x1) + 1) * TILE_M
		var center := (local_z + channel_w * 0.5) if is_h_r else (local_x + channel_w * 0.5)
		_add_track(is_h_r, local_x if is_h_r else local_z, length, center, 0.16)


# ── Rule overlays: lines of sight and zones ──────────────────────────────────
# The 3D counterpart of RuleOverlay (the plan's lines) and GridDraw's zone
# tints. Main hands over the current state after every change.
const SIGHT_OK_COLOR  := Color(0.25, 0.85, 0.48)
const SIGHT_BAD_COLOR := Color(0.98, 0.34, 0.30)
const EYE_HEIGHT := 1.45   # metres

var _rule_root: Node3D = null
var _rule_sight: Array = []
var _rule_zones: Array = []
var _rule_zone_status: Array = []   # per zone {conflict, label}; empty when the level has no zone rule

func set_rule_overlays(sight: Array, zones: Array, zone_status: Array = []) -> void:
	_rule_sight = sight
	_rule_zones = zones
	_rule_zone_status = zone_status
	_rebuild_rule_overlays()


func _rule_point(tile: Vector2i, height: float) -> Vector3:
	return Vector3((tile.x - _room_bounds.position.x + 0.5) * TILE_M, height,
		(tile.y - _room_bounds.position.y + 0.5) * TILE_M)


func _rule_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true          # a line of sight stays readable through furniture
	mat.render_priority = 5
	if color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _rule_beam(a: Vector3, b: Vector3, thick: float, color: Color) -> void:
	var length := a.distance_to(b)
	if length < 0.001:
		return
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(thick, thick, length)
	mi.mesh = mesh
	mi.material_override = _rule_mat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rule_root.add_child(mi)
	mi.position = (a + b) * 0.5
	mi.look_at_from_position(mi.position, b, Vector3.UP if absf((b - a).normalized().y) < 0.99 else Vector3.RIGHT)


func _rule_ball(at: Vector3, radius: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	mi.mesh = mesh
	mi.material_override = _rule_mat(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = at
	_rule_root.add_child(mi)


func _rebuild_rule_overlays() -> void:
	if is_instance_valid(_rule_root):
		_rule_root.queue_free()
	_rule_root = null
	if not is_instance_valid(build_root) or _apt_floor == null:
		return
	var zone_rules := not _rule_zone_status.is_empty()
	if _rule_sight.is_empty() and _rule_zones.size() < 2 and not zone_rules:
		return
	_rule_root = Node3D.new()
	build_root.add_child(_rule_root)

	for i in _rule_sight.size():
		var s := _rule_sight[i] as Dictionary
		var col: Color = SIGHT_OK_COLOR if (s["ok"] as bool) else SIGHT_BAD_COLOR
		var from := _rule_point(s["from"], EYE_HEIGHT)
		var to := _rule_point(s["to"], EYE_HEIGHT)
		var seen_to := to
		if s["block"] != null:
			seen_to = _rule_point(s["block"], EYE_HEIGHT)
		if s["must_be_clear"] as bool:
			_rule_beam(from, seen_to, 0.035, col)
		else:
			# Dashed: this line is meant to be cut.
			var total := from.distance_to(seen_to)
			var dir := (seen_to - from).normalized() if total > 0.001 else Vector3.ZERO
			var t := 0.0
			while t < total:
				_rule_beam(from + dir * t, from + dir * minf(t + 0.16, total), 0.035, col)
				t += 0.3
		if s["block"] != null:
			_rule_beam(seen_to, to, 0.014, Color(col.r, col.g, col.b, 0.35))
			for d in [Vector3(0.11, 0.11, 0.0), Vector3(0.11, -0.11, 0.0), Vector3(0.0, 0.11, 0.11), Vector3(0.0, -0.11, 0.11)]:
				_rule_beam(seen_to - d, seen_to + d, 0.035, col)
		# The eye stands on a post so it is clear where on the floor it is;
		# the target is a ring of small balls would be noise, so: one ball.
		_rule_beam(_rule_point(s["from"], 0.02), from, 0.02, Color(col.r, col.g, col.b, 0.7))
		_rule_ball(from, 0.10, col)
		_rule_beam(_rule_point(s["to"], 0.02), to, 0.02, Color(col.r, col.g, col.b, 0.7))
		_rule_ball(to, 0.06, col)
		var num := Label3D.new()
		num.text = str(i + 1)
		num.font_size = 56
		num.pixel_size = 0.0022
		num.modulate = Color(0.04, 0.10, 0.08)
		num.outline_size = 10
		num.outline_modulate = col
		num.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		num.no_depth_test = true
		num.render_priority = 6
		num.position = from + Vector3(0.0, 0.22, 0.0)
		_rule_root.add_child(num)

	# Zones: the same tints the plan uses, painted on the floor as one image.
	if _rule_zones.size() > 1 or zone_rules:
		var w := _room_bounds.size.x
		var h := _room_bounds.size.y
		var img := Image.create(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8)
		var any := false
		for zi in _rule_zones.size():
			var z := _rule_zones[zi] as Dictionary
			var fns := z.get("functions", []) as Array
			var zc := Color(0, 0, 0, 0)
			if   "sleep" in fns:                    zc = Color(0.36, 0.52, 0.82, 0.30)
			elif "cook"  in fns:                    zc = Color(0.82, 0.42, 0.28, 0.30)
			elif "sit"   in fns or "dine" in fns:   zc = Color(0.78, 0.68, 0.28, 0.30)
			elif "work"  in fns:                    zc = Color(0.32, 0.70, 0.42, 0.30)
			if zone_rules:
				# Same colours and name plates as the plan (see RuleOverlay).
				var st := (_rule_zone_status[zi] as Dictionary) if zi < _rule_zone_status.size() else {"conflict": false, "label": ""}
				var conflict := st["conflict"] as bool
				zc = RuleOverlay.zone_color(zi, conflict)
				zc.a *= 1.6
				var text := st["label"] as String
				if text != "":
					var c2 := RuleOverlay.zone_center(z)
					var plate := Label3D.new()
					plate.text = ("\ueb55 " + text) if conflict else text
					plate.font_size = 44
					plate.pixel_size = 0.0042
					plate.modulate = SIGHT_BAD_COLOR if conflict else Color(0.92, 0.96, 1.0)
					plate.outline_size = 12
					plate.outline_modulate = Color(0.04, 0.08, 0.14)
					plate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
					plate.no_depth_test = true
					plate.render_priority = 6
					plate.position = Vector3((c2.x - _room_bounds.position.x) * TILE_M, 0.35, (c2.y - _room_bounds.position.y) * TILE_M)
					_rule_root.add_child(plate)
			if zc.a <= 0.0:
				continue
			for tile in z.get("tiles", {}) as Dictionary:
				var t := tile as Vector2i
				var px := t.x - _room_bounds.position.x
				var py := t.y - _room_bounds.position.y
				if px >= 0 and py >= 0 and px < w and py < h:
					img.set_pixel(px, py, zc)
					any = true
		if any:
			var quad := QuadMesh.new()
			quad.size = Vector2(w * TILE_M, h * TILE_M)
			quad.orientation = PlaneMesh.FACE_Y
			var zmi := MeshInstance3D.new()
			zmi.mesh = quad
			zmi.position = Vector3(w * TILE_M * 0.5, 0.008, h * TILE_M * 0.5)
			var zmat := StandardMaterial3D.new()
			zmat.albedo_texture = ImageTexture.create_from_image(img)
			zmat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			zmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			zmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			zmi.material_override = zmat
			zmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_rule_root.add_child(zmi)


# A piece that slides (a wardrobe, a rolling cart) gets the track it rides
# drawn on the floor under it, end to end, so it is clear in 3D that it only
# moves one way and how far. The plan shows the same thing with arrows.
func _add_piece_rail(f: Furniture, bounds: Rect2i) -> void:
	if f.rail_axis == "" or not _apt_floor:
		return
	var room := _apt_floor.get_room_bounds()
	var is_h := f.rail_axis == "h"
	var first: float       # tile where the track starts
	var last: float        # tile just past its end
	if is_h:
		first = float(room.position.x + 1) if f.rail_start < 0 else float(f.rail_start)
		last = float(room.position.x + room.size.x) if f.rail_end < 0 else float(f.rail_end + f.grid_w)
	else:
		first = float(room.position.y + 1) if f.rail_start < 0 else float(f.rail_start)
		last = float(room.position.y + room.size.y) if f.rail_end < 0 else float(f.rail_end + f.grid_h)
	if last <= first:
		return
	var origin := float(bounds.position.x if is_h else bounds.position.y)
	var cross := (f.grid_pos.y - bounds.position.y + f.grid_h * 0.5) if is_h \
		else (f.grid_pos.x - bounds.position.x + f.grid_w * 0.5)
	var depth := (f.grid_h if is_h else f.grid_w) * TILE_M
	_add_track(is_h, (first - origin) * TILE_M, (last - first) * TILE_M, cross * TILE_M, clampf(depth * 0.3, 0.06, 0.2))


# Two rails with sleepers between them, lying on the floor. `along0` and
# `length` run along the track; `center` is its middle line across; `gauge`
# is how far each rail sits from that line. All in metres, room-local.
func _add_track(is_h: bool, along0: float, length: float, center: float, gauge: float) -> void:
	const RAIL_LINE_COLOR := Color(0.10, 0.52, 0.62, 1.0)
	const RAIL_TIE_COLOR  := Color(0.10, 0.52, 0.62, 0.55)
	const RAIL_BED_COLOR  := Color(0.22, 0.70, 0.78, 0.16)
	const Y_LVL      := 0.012   # clear of the floor and its plank pattern
	const LINE_THICK := 0.028
	const TIE_EVERY  := 0.2
	var mid := along0 + length * 0.5
	var bed_w := gauge * 2.0 + 0.08
	_add_rail_decal(Vector3(length, 0.002, bed_w) if is_h else Vector3(bed_w, 0.002, length),
		Vector3(mid, Y_LVL - 0.003, center) if is_h else Vector3(center, Y_LVL - 0.003, mid), RAIL_BED_COLOR)
	for side in [-1.0, 1.0]:
		var size := Vector3(length, 0.004, LINE_THICK) if is_h else Vector3(LINE_THICK, 0.004, length)
		var pos := Vector3(mid, Y_LVL, center + side * gauge) if is_h else Vector3(center + side * gauge, Y_LVL, mid)
		_add_rail_decal(size, pos, RAIL_LINE_COLOR)
	var t := TIE_EVERY * 0.5
	while t < length:
		var tie_size := Vector3(LINE_THICK * 0.7, 0.003, gauge * 2.0) if is_h else Vector3(gauge * 2.0, 0.003, LINE_THICK * 0.7)
		var tie_pos := Vector3(along0 + t, Y_LVL - 0.001, center) if is_h else Vector3(center, Y_LVL - 0.001, along0 + t)
		_add_rail_decal(tie_size, tie_pos, RAIL_TIE_COLOR)
		t += TIE_EVERY
	# A buffer stop at each end.
	for end_at in [along0, along0 + length]:
		var stop_size := Vector3(LINE_THICK, 0.02, gauge * 2.0 + LINE_THICK) if is_h else Vector3(gauge * 2.0 + LINE_THICK, 0.02, LINE_THICK)
		var stop_pos := Vector3(end_at, Y_LVL + 0.008, center) if is_h else Vector3(center, Y_LVL + 0.008, end_at)
		_add_rail_decal(stop_size, stop_pos, RAIL_LINE_COLOR)


func _add_rail_decal(size: Vector3, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var quad := BoxMesh.new()
	quad.size = size
	mi.mesh = quad
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	build_root.add_child(mi)


func _add_reveal_zone_markers(bounds: Rect2i) -> void:
	if not _apt_floor:
		return
	const REVEAL_COLOR := Color(0.95, 0.85, 0.25, 0.9)
	for rz in _apt_floor.reveal_zones:
		var d := rz as Dictionary
		var x1: int = d.get("x1", 0) as int
		var y1: int = d.get("y1", 0) as int
		var x2: int = d.get("x2", 0) as int
		var y2: int = d.get("y2", 0) as int
		var local_x := (mini(x1, x2) - bounds.position.x) * TILE_M
		var local_z := (mini(y1, y2) - bounds.position.y) * TILE_M
		var w_m := (absi(x2 - x1) + 1) * TILE_M
		var dd_m := (absi(y2 - y1) + 1) * TILE_M
		var group := _build_outline_group(Vector2(w_m, dd_m), REVEAL_COLOR, 0.008)
		group.position.x = local_x
		group.position.z = local_z
		build_root.add_child(group)


# Placeholder for the subfloor/ceiling/roof layers, which only exist to carry
# 2D-only pipe/duct overlays and have no walls or columns of their own.
func _add_special_layer_label(floor_type: String, w: float, d: float) -> void:
	var names := {
		"ceiling":   tr("Ceiling / Ducts"),
		"subfloor":  tr("Building Subfloor"),
		"floor_sub": tr("Floor Subfloor / Pipes"),
		"roof":      tr("Roof"),
	}
	var lbl := Label3D.new()
	lbl.text = (names.get(floor_type, floor_type.capitalize()) as String) + "\n" + tr("(view in 2D for detail)")
	lbl.font_size = 48
	lbl.modulate = Color(0.35, 0.40, 0.48)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.pixel_size = 0.005
	lbl.position = Vector3(w * 0.5, WALL_H_M * 0.5, d * 0.5)
	build_root.add_child(lbl)


# Balconies/bathroom nooks are floor_kind-tagged tiles that sit OUTSIDE the
# wall-bounds rectangle _add_floor already covers (see Wall.gd's
# _prune_floor_mask_to_walls) — without this they'd be invisible in 3D even
# though they're walkable. Each one also gets a railing along any edge that
# borders a non-floor (exterior) tile, mirroring GridDraw's 2D balcony rail.
func _add_balcony_extras(bounds: Rect2i) -> void:
	if not _apt_floor or _apt_floor.floor_kind.is_empty():
		return
	var floor_col := Color(0.93, 0.90, 0.83)
	var rail_col  := Color(0.9, 0.92, 0.95)
	for tile in _apt_floor.floor_kind:
		var t := tile as Vector2i
		var local_x := (t.x - bounds.position.x) * TILE_M
		var local_z := (t.y - bounds.position.y) * TILE_M
		if not bounds.has_point(t):
			_box(Vector3(TILE_M, 0.05, TILE_M),
				Vector3(local_x + TILE_M * 0.5, -0.025, local_z + TILE_M * 0.5), floor_col, StyleController.ROLE_FLOOR)
		if (_apt_floor.floor_kind[tile] as String) != "balcony":
			continue
		var edges := [
			[Vector2i(t.x, t.y - 1), Vector3(local_x + TILE_M * 0.5, 0.0, local_z), true],
			[Vector2i(t.x, t.y + 1), Vector3(local_x + TILE_M * 0.5, 0.0, local_z + TILE_M), true],
			[Vector2i(t.x - 1, t.y), Vector3(local_x, 0.0, local_z + TILE_M * 0.5), false],
			[Vector2i(t.x + 1, t.y), Vector3(local_x + TILE_M, 0.0, local_z + TILE_M * 0.5), false],
		]
		for e in edges:
			var ntile: Vector2i = e[0]
			var center: Vector3 = e[1]
			var horizontal: bool = e[2]
			if _apt_floor.is_floor_tile(ntile):
				continue
			var rail_size := Vector3(TILE_M, RAIL_H_M, RAIL_THICK_M) if horizontal \
				else Vector3(RAIL_THICK_M, RAIL_H_M, TILE_M)
			_box(rail_size, center + Vector3(0.0, RAIL_H_M * 0.5, 0.0), rail_col, StyleController.ROLE_WALL)


# Ceiling height (metres) at a given absolute world tile coordinate along the
# slope axis — same formula GridDraw/WallInspector use for the 2D contour.
func _sloped_height_m(sc: Dictionary, coord_tile: float) -> float:
	var low_s  := sc.get("low_start", 0) as float
	var high_e := sc.get("high_end", 0) as float
	var min_h  := sc.get("min_h", 1.8) as float
	var max_h  := sc.get("max_h", 2.4) as float
	var span := high_e - low_s
	if span <= 0.0:
		return max_h
	var frac := clampf((coord_tile - low_s) / span, 0.0, 1.0)
	return min_h + frac * (max_h - min_h)


# A wall as a "wedge" prism: rectangular cross-section whose top edge rises
# linearly from h0 (local x=0) to h1 (local x=length) — degenerates to a
# plain box when h0 == h1, so it doubles as the flat-ceiling case too.
func _wedge_mesh(length: float, thick: float, h0: float, h1: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a0 := Vector3(0.0, 0.0, 0.0)
	var b0 := Vector3(0.0, h0, 0.0)
	var c0 := Vector3(length, h1, 0.0)
	var d0 := Vector3(length, 0.0, 0.0)
	var a1 := Vector3(0.0, 0.0, thick)
	var b1 := Vector3(0.0, h0, thick)
	var c1 := Vector3(length, h1, thick)
	var d1 := Vector3(length, 0.0, thick)
	# Winding isn't hardened per-face (materials render double-sided instead),
	# so these just need to be planar quads, not a specific orientation.
	var faces := [
		[a0, d0, d1, a1],   # bottom
		[b0, b1, c1, c0],   # slanted top
		[a0, b0, c0, d0],   # front (z=0)
		[d1, c1, b1, a1],   # back (z=thick)
		[a1, b1, b0, a0],   # left end (x=0)
		[d0, c0, c1, d1],   # right end (x=length)
	]
	for quad in faces:
		var p0: Vector3 = quad[0]
		var p1: Vector3 = quad[1]
		var p2: Vector3 = quad[2]
		var p3: Vector3 = quad[3]
		var n := (p1 - p0).cross(p2 - p0).normalized()
		st.set_normal(n); st.add_vertex(p0)
		st.set_normal(n); st.add_vertex(p1)
		st.set_normal(n); st.add_vertex(p2)
		st.set_normal(n); st.add_vertex(p0)
		st.set_normal(n); st.add_vertex(p2)
		st.set_normal(n); st.add_vertex(p3)
	return st.commit()


func _add_sloped_wall(length: float, thick: float, h0: float, h1: float,
		pos: Vector3, rot_y_deg: float, color: Color, role: StringName = StyleController.ROLE_WALL) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _wedge_mesh(length, thick, h0, h1)
	mi.position = pos
	mi.rotation.y = deg_to_rad(rot_y_deg)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	build_root.add_child(mi)
	_style_node(mi, role)
	if role == StyleController.ROLE_GLASS_WALL:
		# Daylight passes a glass wall, so it throws no shadow of its own.
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if _style != null:
		# Skirting board along both faces, so the wall meets the floor on a line.
		_wall_part(mi, 0.0, length, 0.0, SKIRTING_H_M, -SKIRTING_DEPTH_M, 0.0, StyleController.ROLE_TRIM)
		_wall_part(mi, 0.0, length, 0.0, SKIRTING_H_M, thick, thick + SKIRTING_DEPTH_M, StyleController.ROLE_TRIM)
	return mi


# ── Windows, doors, skirting (styled view only) ─────────────────────────────
# Dressing built from thin boxes parented to a wall's mesh, in the wall's own
# space: x runs along the wall from its low end, y is up, z crosses its
# thickness (0 on one face, WALL_THICK on the other). Being children, they
# move, fade and get freed with the wall. Purely visual — the wall is not cut
# and nothing here takes part in picking or placement.
const SKIRTING_H_M     := 0.08
const SKIRTING_DEPTH_M := 0.015
const WINDOW_Y0_M      := 0.9
const WINDOW_Y1_M      := 1.9
const DOOR_LEN_TILES   := 10    # matches Wall.gd / WallInspector.gd
const DOOR_H_M         := 2.0

func _wall_part(wall: MeshInstance3D, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float, role: StringName) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3(absf(x1 - x0), absf(y1 - y0), absf(z1 - z0))
	var part := MeshInstance3D.new()
	part.mesh = box
	part.position = Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	part.set_meta("wall_part_role", role)   # RoomLighting finds the windows by it
	wall.add_child(part)
	_style_node(part, role)
	return part


# Builds the window and door a segment declares (has_window / has_door, the
# same fields the 2D plan and the wall inspector read), on both faces of the
# wall. Returns the parts so the wall's fade can hide them while it is cut
# down to a stub.
func _add_wall_openings(wall: MeshInstance3D, seg: Dictionary, wall_h: float) -> Array:
	var parts: Array = []
	if _style == null:
		return parts
	_add_stub_marks(wall, seg, wall_h)
	# [z at the wall face, direction pointing out of the wall] for each face.
	for face in [[0.0, -1.0], [WALL_THICK, 1.0]]:
		var z: float = face[0]
		var out: float = face[1]
		if seg.get("has_window", false) and wall_h >= WINDOW_Y0_M + 0.5:
			var x0 := (seg.get("window_pos", 0) as float) * TILE_M
			var x1 := x0 + (seg.get("window_len", 10) as float) * TILE_M
			var y0 := WINDOW_Y0_M
			var y1 := minf(WINDOW_Y1_M, wall_h - 0.12)
			const BAR := 0.045
			parts.append(_wall_part(wall, x0, x1, y0, y1, z, z + out * 0.012, StyleController.ROLE_WINDOW))
			parts.append(_wall_part(wall, x0 - BAR, x0, y0, y1, z, z + out * 0.035, StyleController.ROLE_FLOOR))
			parts.append(_wall_part(wall, x1, x1 + BAR, y0, y1, z, z + out * 0.035, StyleController.ROLE_FLOOR))
			parts.append(_wall_part(wall, x0 - BAR, x1 + BAR, y1, y1 + BAR, z, z + out * 0.035, StyleController.ROLE_FLOOR))
			parts.append(_wall_part(wall, x0 - BAR * 1.8, x1 + BAR * 1.8, y0 - BAR, y0, z, z + out * 0.07, StyleController.ROLE_FLOOR))   # sill
			if x1 - x0 >= 0.8:
				var mid := (x0 + x1) * 0.5
				parts.append(_wall_part(wall, mid - 0.015, mid + 0.015, y0, y1, z, z + out * 0.03, StyleController.ROLE_FLOOR))
		if seg.get("has_door", false):
			var x0 := (seg.get("door_pos", 0) as float) * TILE_M
			var x1 := x0 + DOOR_LEN_TILES * TILE_M
			var y1 := minf(DOOR_H_M, wall_h - 0.06)
			const JAMB := 0.05
			parts.append(_wall_part(wall, x0 - JAMB, x0, 0.0, y1, z, z + out * 0.04, StyleController.ROLE_FLOOR))
			parts.append(_wall_part(wall, x1, x1 + JAMB, 0.0, y1, z, z + out * 0.04, StyleController.ROLE_FLOOR))
			parts.append(_wall_part(wall, x0 - JAMB, x1 + JAMB, y1, y1 + JAMB, z, z + out * 0.04, StyleController.ROLE_FLOOR))
			if out == _door_out(seg):
				# The face it opens towards: the leaf, hinged at the doorway's
				# start (as on the plan), swings out of the wall into the room.
				var pivot := Node3D.new()
				pivot.name = "DoorLeaf"
				pivot.position = Vector3(x0, 0.0, z)
				wall.add_child(pivot)
				var leaf := _wall_part(wall, x0, x1, 0.0, y1, z, z + out * 0.03, StyleController.ROLE_TRIM)
				var knob := _wall_part(wall, x1 - 0.14, x1 - 0.10, 0.95, 1.07, z + out * 0.03, z + out * 0.06, StyleController.ROLE_ACCENT)
				for p in [leaf, knob]:
					var keep := (p as Node3D).position - pivot.position
					wall.remove_child(p)
					pivot.add_child(p)
					(p as Node3D).position = keep
				parts.append(pivot)
				_doors.append({"wall": wall, "pivot": pivot, "open_deg": -90.0 * out,
					"center_local": Vector3((x0 + x1) * 0.5, 1.0, WALL_THICK * 0.5), "t": 0.0, "back": []})
			else:
				# The other face: the back of the door, which goes when it opens.
				var back := _wall_part(wall, x0, x1, 0.0, y1, z, z + out * 0.02, StyleController.ROLE_TRIM)
				parts.append(back)
				_pending_door_backs.append(back)
	if seg.get("has_door", false) and not _doors.is_empty() and (_doors[-1] as Dictionary)["wall"] == wall:
		var door := _doors[-1] as Dictionary
		door["back"] = _pending_door_backs.duplicate()
		# The doorway behind the leaf: dark, so the open door shows a way through.
		var x0d := (seg.get("door_pos", 0) as float) * TILE_M
		var y1d := minf(DOOR_H_M, wall_h - 0.06)
		var hole := MeshInstance3D.new()
		var hb := BoxMesh.new()
		hb.size = Vector3(DOOR_LEN_TILES * TILE_M, y1d, WALL_THICK + 0.01)
		hole.mesh = hb
		var dark := StandardMaterial3D.new()
		dark.albedo_color = Color(0.10, 0.09, 0.08)
		dark.roughness = 1.0
		hole.material_override = dark
		hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		build_root.add_child(hole)
		hole.transform = wall.transform * Transform3D(Basis.IDENTITY, Vector3(x0d + DOOR_LEN_TILES * TILE_M * 0.5, y1d * 0.5, WALL_THICK * 0.5))
		parts.append(hole)
	_pending_door_backs.clear()
	return parts


# Text lying on the floor (a moved piece's old spot, an outside wall's name)
# is turned to read the right way up from wherever the camera is: fixed, it
# was upside down or mirrored from half the angles.
var _flat_labels: Array = []

func _turn_flat_labels(flat: Vector3) -> void:
	var yaw := atan2(flat.x, flat.z)
	for i in range(_flat_labels.size() - 1, -1, -1):
		var l = _flat_labels[i]
		if not is_instance_valid(l):
			_flat_labels.remove_at(i)
			continue
		(l as Node3D).rotation = Vector3(-PI * 0.5, yaw, 0.0)


# Doors that open (Room3DView builds one per swing door): each swings open
# while a resident is next to it or the pointer is over it, and shuts after.
# [{wall, pivot, open_deg, center_local, t (0 shut .. 1 open), back: [parts]}]
var _doors: Array = []
var _pending_door_backs: Array = []
var _hover_door: Variant = null
const DOOR_SWING_SPEED := 2.5   # of a full swing, per second
const DOOR_NEAR_M := 0.75       # a resident this close to the doorway opens it

# Which face of the wall the door opens towards (+1: the wall's own +z face).
# door_side is +1 for south / east on the plan; a horizontal wall's +z is
# south, a vertical one's +z is west (it is turned -90°).
func _door_out(seg: Dictionary) -> float:
	var side := 1.0 if (seg.get("door_side", 1) as int) > 0 else -1.0
	if (seg.get("door_type", "swing") as String) == "sliding":
		return 0.0   # a sliding door has no leaf to swing
	return side if (seg["y1"] == seg["y2"]) else -side


func _update_doors(delta: float) -> void:
	if _doors.is_empty():
		return
	var tenants := build_root.get_parent().get_node_or_null("Tenants") if is_instance_valid(build_root) else null
	for d in _doors:
		var door := d as Dictionary
		var wall := door["wall"] as MeshInstance3D
		var pivot := door["pivot"] as Node3D
		if not is_instance_valid(wall) or not is_instance_valid(pivot):
			continue
		var center: Vector3 = wall.transform * (door["center_local"] as Vector3)
		var want := 1.0 if is_same(_hover_door, door) else 0.0
		if want == 0.0 and tenants != null:
			for p in tenants.get_children():
				var at := build_root.to_local((p as Node3D).global_position)
				if Vector2(at.x - center.x, at.z - center.z).length() < DOOR_NEAR_M:
					want = 1.0
					break
		var t := move_toward(door["t"] as float, want, delta * DOOR_SWING_SPEED)
		if is_equal_approx(t, door["t"] as float) and t == want:
			continue
		door["t"] = t
		var eased := t * t * (3.0 - 2.0 * t)
		pivot.rotation.y = deg_to_rad((door["open_deg"] as float) * eased)
		for b in door["back"] as Array:
			if is_instance_valid(b):
				(b as Node3D).visible = t < 0.05 and wall.scale.y > 0.6


# The door under the pointer, if any (only while nothing is being carried).
func _door_under(vp_pos: Vector2) -> Variant:
	var from := cam.project_ray_origin(vp_pos)
	var dir := cam.project_ray_normal(vp_pos)
	from = build_root.to_local(from)
	dir = build_root.global_transform.basis.inverse() * dir
	var best: Variant = null
	var best_t := INF
	for d in _doors:
		var door := d as Dictionary
		var wall := door["wall"] as MeshInstance3D
		if not is_instance_valid(wall) or wall.scale.y < 0.6:
			continue
		var c: Vector3 = wall.transform * (door["center_local"] as Vector3)
		var half := Vector3(0.55, 1.0, 0.55)
		var t := _ray_box_t(from, dir, c - half, c + half)
		if t < best_t:
			best_t = t
			best = door
	return best


# When a wall is lowered to a stub its window and door are hidden, which
# would leave no sign that an opening is there — and a door you can't see is a
# door you might block. Each opening gets a short coloured band on the stub's
# cut face instead: a plan-style window symbol for a window, a dark band
# between accent ticks for a door. Shown only while the wall is down; kept on the wall
# as "stub_marks" meta for the fade to toggle.
func _add_stub_marks(wall: MeshInstance3D, seg: Dictionary, wall_h: float) -> void:
	var marks: Array = []
	# Sized in the wall's unscaled space so that, once the wall is squashed to
	# STUB_HEIGHT_M, the band is about 1.5 cm thick.
	var band := 0.015 * wall_h / STUB_HEIGHT_M
	var z0 := -0.012
	var z1 := WALL_THICK + 0.012
	if seg.get("has_window", false):
		var x0 := (seg.get("window_pos", 0) as float) * TILE_M
		var x1 := x0 + (seg.get("window_len", 10) as float) * TILE_M
		# Drawn like a window on a floor plan: the glass colour across the
		# wall, a dark line down its middle and a dark tick at each end, so
		# it stands out against the light cut face.
		var zm := WALL_THICK * 0.5
		marks.append(_wall_part(wall, x0, x1, wall_h, wall_h + band, z0, z1, StyleController.ROLE_WINDOW))
		marks.append(_wall_part(wall, x0, x1, wall_h, wall_h + band * 1.5, zm - 0.012, zm + 0.012, StyleController.ROLE_FURNITURE))
		marks.append(_wall_part(wall, x0 - 0.03, x0, wall_h, wall_h + band * 1.5, z0, z1, StyleController.ROLE_FURNITURE))
		marks.append(_wall_part(wall, x1, x1 + 0.03, wall_h, wall_h + band * 1.5, z0, z1, StyleController.ROLE_FURNITURE))
	if seg.get("has_door", false):
		# Drawn on the floor as on the plan: the doorway's threshold, and for
		# a swing door its open leaf and the arc it sweeps; for a sliding one
		# its track. Flat on the floor, so the wall being squashed doesn't
		# change it.
		var x0 := (seg.get("door_pos", 0) as float) * TILE_M
		var x1 := x0 + DOOR_LEN_TILES * TILE_M
		# 5 mm over the floor once the wall is squashed down (they are its children).
		var y := 0.005 * wall_h / STUB_HEIGHT_M
		# A gap in the painted wall line, as on a plan: floor laid over the
		# lowered wall where the doorway is.
		marks.append(_wall_part(wall, x0, x1, wall_h, wall_h + 0.003 * wall_h / STUB_HEIGHT_M, z0, z1, StyleController.ROLE_FLOOR))
		var out := _door_out(seg)
		if out != 0.0:
			var zf := WALL_THICK if out > 0.0 else 0.0
			var r := DOOR_LEN_TILES * TILE_M
			marks.append(_wall_part(wall, x0, x0 + 0.03, 0.0, y, zf, zf + out * r, StyleController.ROLE_WALL))   # the leaf, open
			var verts := PackedVector3Array()
			for i in 16:
				var a0 := PI * 0.5 * i / 16.0
				var a1 := PI * 0.5 * (i + 1) / 16.0
				var p0 := Vector3(x0 + cos(a0) * r, y, zf + out * sin(a0) * r)
				var p1 := Vector3(x0 + cos(a1) * r, y, zf + out * sin(a1) * r)
				var q0 := Vector3(x0 + cos(a0) * (r - 0.02), y, zf + out * sin(a0) * (r - 0.02))
				var q1 := Vector3(x0 + cos(a1) * (r - 0.02), y, zf + out * sin(a1) * (r - 0.02))
				verts.append_array([p0, p1, q1, p0, q1, q0])
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			var arc_mesh := ArrayMesh.new()
			arc_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var arc := MeshInstance3D.new()
			arc.mesh = arc_mesh
			arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			wall.add_child(arc)
			_style_node(arc, StyleController.ROLE_WALL)
			arc.add_to_group("style_" + String(StyleController.ROLE_WALL))
			marks.append(arc)
		else:
			# A sliding door: its leaf, half across the gap, beside the wall.
			marks.append(_wall_part(wall, x0, x1 * 0.5 + x0 * 0.5, 0.0, y * 2.0, z0 - 0.07, z0 - 0.04, StyleController.ROLE_WALL))
	for m in marks:
		(m as Node3D).visible = false
	wall.set_meta("stub_marks", marks)


# `sc` is Floor.sloped_ceiling ({} if the room has a flat ceiling). One
# MeshInstance3D per actual wall segment (perimeter AND interior partitions)
# instead of a fixed north/south/west/east box around the room's bounding
# rect — a multi-room floor (an L-shape, an interior partition with a door,
# etc.) used to render as if it were a plain rectangle, silently dropping
# every wall that wasn't one of the outer four. Segments running along the
# slope axis get a slanted top edge; the other orientation gets a constant
# height matching the ceiling at that segment's fixed position — mirrors the
# 2D GridDraw/WallInspector cut logic, just per-segment instead of per-side.
func _add_walls(_w: float, _d: float, sc: Dictionary, bounds: Rect2i) -> void:
	var col          := Color(0.86, 0.83, 0.76)
	var interior_col := Color(0.90, 0.87, 0.80)   # faint warm tint hints "removable partition"
	var has_slope := not sc.is_empty()
	var axis: String = sc.get("axis", "x") as String
	var bx0 := bounds.position.x; var bx1 := bounds.position.x + bounds.size.x
	var by0 := bounds.position.y; var by1 := bounds.position.y + bounds.size.y

	for sd in _apt_floor.segments:
		var seg := sd as Dictionary
		if seg.get("demolished", false):
			continue
		var x1: int = seg["x1"]; var y1: int = seg["y1"]
		var x2: int = seg["x2"]; var y2: int = seg["y2"]
		var is_primary := seg.get("primary", false) as bool
		var wall_col := col if is_primary else interior_col
		# Styled, the "removable partition" hint is a lighter tint of the wall colour.
		var wall_role := StyleController.ROLE_WALL if is_primary else StyleController.ROLE_PARTITION
		if seg.get("translucent", false) as bool:
			wall_role = StyleController.ROLE_GLASS_WALL
			wall_col = Color(0.78, 0.93, 0.92)

		if y1 == y2 and x1 != x2:
			# Horizontal run along world X, fixed at world Z = line_z.
			var xs := mini(x1, x2); var xe := maxi(x1, x2)
			var length := (xe - xs) * TILE_M
			var h0 := WALL_H_M; var h1 := WALL_H_M
			if has_slope:
				if axis == "x":
					h0 = _sloped_height_m(sc, xs); h1 = _sloped_height_m(sc, xe)
				else:
					h0 = _sloped_height_m(sc, y1); h1 = h0
			var local_x := (xs - bounds.position.x) * TILE_M
			var line_z  := (y1 - bounds.position.y) * TILE_M
			# An interior wall drawn from (or to) the perimeter stops at the
			# perimeter wall's inner face, not inside it: its end used to
			# poke out through the outside, which shows on a glass wall.
			# (The east wall stands past the room's last column, so a wall
			# running to it already stops at its inner face.)
			if y1 != by0 and y1 != by1:
				if xs == bx0:
					local_x += WALL_THICK
					length -= WALL_THICK
			elif y1 == by1 and xe == bx1:
				length += WALL_THICK   # the south wall fills the corner with the east one
			var pos_z: float; var normal: Vector3
			if y1 == by0:
				pos_z = 0.0; normal = Vector3(0, 0, -1)                       # north perimeter
			elif y1 == by1:
				pos_z = line_z; normal = Vector3(0, 0, 1)                     # south perimeter
			else:
				pos_z = line_z - WALL_THICK * 0.5; normal = Vector3(0, 0, -1) # interior partition
			var mi := _add_sloped_wall(length, WALL_THICK, h0, h1, Vector3(local_x, 0.0, pos_z), 0.0, wall_col, wall_role)
			_wall_data.append({"mesh": mi, "normal": normal, "full_h": maxf(h0, h1), "role": wall_role,
				"decor": _add_wall_openings(mi, seg, minf(h0, h1)),
				"interior": y1 != by0 and y1 != by1,
				"a": Vector3(local_x, 0.0, pos_z + WALL_THICK * 0.5),
				"b": Vector3(local_x + length, 0.0, pos_z + WALL_THICK * 0.5)})
			_add_wall_grid(mi, length, maxf(h0, h1))

		elif x1 == x2 and y1 != y2:
			# Vertical run along world Z, fixed at world X = line_x.
			var ys := mini(y1, y2); var ye := maxi(y1, y2)
			var length := (ye - ys) * TILE_M
			var h0 := WALL_H_M; var h1 := WALL_H_M
			if has_slope:
				if axis == "y":
					h0 = _sloped_height_m(sc, ys); h1 = _sloped_height_m(sc, ye)
				else:
					h0 = _sloped_height_m(sc, x1); h1 = h0
			var local_z := (ys - bounds.position.y) * TILE_M
			var line_x  := (x1 - bounds.position.x) * TILE_M
			if x1 != bx0 and x1 != bx1:      # as for horizontal runs, above
				if ys == by0:
					local_z += WALL_THICK
					length -= WALL_THICK
			var pos_x: float; var normal: Vector3
			if x1 == bx0:
				pos_x = WALL_THICK; normal = Vector3(-1, 0, 0)                # west perimeter
			elif x1 == bx1:
				pos_x = line_x + WALL_THICK; normal = Vector3(1, 0, 0)        # east perimeter
			else:
				pos_x = line_x + WALL_THICK * 0.5; normal = Vector3(-1, 0, 0) # interior partition
			var mi := _add_sloped_wall(length, WALL_THICK, h0, h1, Vector3(pos_x, 0.0, local_z), -90.0, wall_col, wall_role)
			_wall_data.append({"mesh": mi, "normal": normal, "full_h": maxf(h0, h1), "role": wall_role,
				"decor": _add_wall_openings(mi, seg, minf(h0, h1)),
				"interior": x1 != bx0 and x1 != bx1,
				"a": Vector3(pos_x - WALL_THICK * 0.5, 0.0, local_z),
				"b": Vector3(pos_x - WALL_THICK * 0.5, 0.0, local_z + length)})
			_add_wall_grid(mi, length, maxf(h0, h1))


# ── Stacking: pieces standing on tables and shelves ─────────────────────────
# Floor.support_under() says which surface a piece rests on; here it is lifted
# onto the top of that surface as drawn (the model's own height, which can be
# a little off the catalogue's wall_h, see _refit_item_model), so it sits on
# the table rather than inside it.

func _entry_of(f: Furniture) -> Dictionary:
	for entry in _furniture_entries:
		if entry.get("furniture") == f:
			return entry
	return {}


# Height of the piece as drawn: its model's, or its box's if it has none.
func _drawn_height(mi: MeshInstance3D, box_h: float) -> float:
	if mi.has_meta("model_inst") and mi.has_meta("model_native"):
		var inst := mi.get_meta("model_inst") as Node3D
		if is_instance_valid(inst):
			return (mi.get_meta("model_native") as AABB).size.y * inst.scale.y
	return box_h


# Where the top of `f` is in the view, in metres above the floor.
func _top_m(f: Furniture) -> float:
	var entry := _entry_of(f)
	if entry.is_empty() or not is_instance_valid(entry.get("mesh")):
		return (_apt_floor.stack_lift(f) + f.body_h) * TILE_M
	var mi := entry["mesh"] as MeshInstance3D
	var box_h := (entry["size"] as Vector3).y
	return mi.position.y - box_h * 0.5 + _drawn_height(mi, box_h)


# How high `f` stands when its corner is at `at` (where it is now if null):
# on the top of what it stands on, as far down as that top is bowed there.
func _lift_m(f: Furniture, at: Variant = null) -> float:
	if not is_instance_valid(_apt_floor):
		return 0.0
	var sup := _apt_floor.support_under(f, at)
	if sup == null:
		return 0.0
	var corner: Vector2 = f.grid_pos if at == null else at as Vector2
	var cx := (corner.x - _room_bounds.position.x + f.grid_w * 0.5) * TILE_M
	var cz := (corner.y - _room_bounds.position.y + f.grid_h * 0.5) * TILE_M
	return _top_m(sup) - _sag_at(_entry_of(sup), cx, cz)


# ── Bowing: a loaded surface sags ───────────────────────────────────────────
# A table, desk or shelf bows under what stands on it once it is past
# SAG_FROM of what it can hold, a little more as it fills, and clearly too
# much (SAG_OVER_M) when a piece being carried over it would break it: the
# weight limit, shown on the furniture itself rather than as a number. Only
# the top bends (legs and plinths stay put), deepest in the middle, and
# whatever stands on it sinks with it. Done by bending a copy of the model's
# meshes, only when the sag changes.
const SAG_FROM := Floor.STRAIN_FROM   # share of max_support_weight before anything shows
const SAG_FULL_M := 0.03    # metres of sag in the middle when exactly full
const SAG_OVER_M := 0.07    # ... when what is being carried over it would break it
const SAG_SPAN_M := 1.2     # surfaces at least this long bow fully; shorter ones less

# How far `sup` should sag in the middle. `carried` (being dragged or bought,
# its corner at `carried_at`) counts on the surface it is over and no longer
# on the one it was lifted off.
func _sag_for(sup: Furniture, entry: Dictionary, carried: Furniture = null, carried_at: Variant = null) -> float:
	if sup.max_support_weight <= 0.0 or not entry.has("mesh") or not (entry["mesh"] as Node).has_meta("model_inst"):
		return 0.0
	var ratio := _apt_floor.strain_of(sup, carried, carried_at)
	if ratio <= SAG_FROM:
		return 0.0
	var size: Vector3 = entry["size"]
	var span := clampf(maxf(size.x, size.z) / SAG_SPAN_M, 0.4, 1.0)
	if ratio > 1.0 + 0.0001:
		return SAG_OVER_M * span
	var t := (ratio - SAG_FROM) / (1.0 - SAG_FROM)
	return SAG_FULL_M * span * t * t * (3.0 - 2.0 * t)


# Share of the sag at a point (room metres) on a surface: all of it in the
# middle, none at the edges.
func _sag_shape(entry: Dictionary, x: float, z: float) -> float:
	var pos: Vector3 = entry["pos"]
	var size: Vector3 = entry["size"]
	var u := (x - pos.x) / maxf(size.x * 0.5, 0.001)
	var v := (z - pos.z) / maxf(size.z * 0.5, 0.001)
	return maxf(0.0, 1.0 - u * u) * maxf(0.0, 1.0 - v * v)


func _sag_at(entry: Dictionary, x: float, z: float) -> float:
	if entry.is_empty():
		return 0.0
	return (entry.get("sag", 0.0) as float) * _sag_shape(entry, x, z)


# Bends the model of a surface piece down by `sag` in the middle (straight
# again at 0). Each of its meshes keeps its original to bend from.
func _apply_sag(entry: Dictionary, sag: float) -> void:
	var mi := entry["mesh"] as MeshInstance3D
	if not mi.has_meta("model_inst") or not is_instance_valid(mi.get_meta("model_inst")):
		return
	var key := [snappedf(sag, 0.0005), mi.transform]
	if mi.get_meta("sag_key", []) == key:
		return
	mi.set_meta("sag_key", key)
	var size: Vector3 = entry["size"]
	var bottom := mi.position.y - size.y * 0.5
	var height := maxf(_drawn_height(mi, size.y), 0.01)
	var room_inv := build_root.global_transform.affine_inverse()
	var parts: Array = [mi.get_meta("model_inst")]
	while not parts.is_empty():
		var n := parts.pop_back() as Node
		parts.append_array(n.get_children())
		if not (n is MeshInstance3D):
			continue
		var m := n as MeshInstance3D
		if not m.has_meta("sag_orig"):
			if sag <= 0.0 or m.mesh == null:
				continue
			m.set_meta("sag_orig", m.mesh)
		var orig := m.get_meta("sag_orig") as Mesh
		if sag <= 0.0:
			m.mesh = orig
			continue
		var to_room := room_inv * m.global_transform
		var down := to_room.basis.inverse() * Vector3.DOWN
		# These models are low-poly: a tabletop is a slab with vertices only at
		# its corners, where the sag is nothing. Its top part is cut finer once
		# (kept for every later bend) so there is something to bend.
		if not m.has_meta("sag_fine"):
			m.set_meta("sag_fine", _finer_top(orig, to_room, bottom + height * 0.45))
		var fine := m.get_meta("sag_fine") as Array   # surface arrays, one per surface
		var bent := ArrayMesh.new()
		for i in fine.size():
			var arrays := (fine[i] as Array).duplicate()
			var verts: PackedVector3Array = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate()
			for k in verts.size():
				var p := to_room * verts[k]
				var up := clampf((p.y - bottom) / height, 0.0, 1.0)
				var d := sag * _sag_shape(entry, p.x, p.z) * up * up
				if d > 0.0:
					verts[k] += down * d
			arrays[Mesh.ARRAY_VERTEX] = verts
			bent.add_surface_from_arrays(orig.surface_get_primitive_type(i), arrays)
			bent.surface_set_material(i, orig.surface_get_material(i))
		m.mesh = bent


const SAG_EDGE_M := 0.07   # edges above the bend line get cut down to about this long

# `mesh`'s surfaces as arrays, with every triangle edge that lies above
# `above_y` (room metres, through `to_room`) and is longer than SAG_EDGE_M
# cut in half, again and again, until none is. An edge is cut the same way
# in every triangle that has it, so the surface stays closed. Surfaces that
# aren't plain triangles, or that carry bones, are left as they are.
func _finer_top(mesh: Mesh, to_room: Transform3D, above_y: float) -> Array:
	var out: Array = []
	for si in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(si)
		if mesh.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES or arrays[Mesh.ARRAY_BONES] != null:
			out.append(arrays)
			continue
		# Plain Arrays: the helpers below add to them, and a lambda would only
		# be adding to its own copy of a packed array.
		var buf := {
			"v": Array(arrays[Mesh.ARRAY_VERTEX]),
			"n": Array(arrays[Mesh.ARRAY_NORMAL]) if arrays[Mesh.ARRAY_NORMAL] != null else [],
			"t": Array(arrays[Mesh.ARRAY_TANGENT]) if arrays[Mesh.ARRAY_TANGENT] != null else [],
			"c": Array(arrays[Mesh.ARRAY_COLOR]) if arrays[Mesh.ARRAY_COLOR] != null else [],
			"uv": Array(arrays[Mesh.ARRAY_TEX_UV]) if arrays[Mesh.ARRAY_TEX_UV] != null else [],
			"uv2": Array(arrays[Mesh.ARRAY_TEX_UV2]) if arrays[Mesh.ARRAY_TEX_UV2] != null else [],
		}
		var vs: Array = buf["v"]
		var tris: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vs.size()))
		var mids: Dictionary = {}   # Vector2i(lo, hi) vertex pair -> the vertex halfway along it
		var mid_of := func(a: int, b: int) -> int:
			var key := Vector2i(mini(a, b), maxi(a, b))
			if mids.has(key):
				return mids[key]
			vs.append(((vs[a] as Vector3) + (vs[b] as Vector3)) * 0.5)
			var ns: Array = buf["n"]
			if not ns.is_empty():
				ns.append(((ns[a] as Vector3) + (ns[b] as Vector3)).normalized())
			var ts: Array = buf["t"]
			if not ts.is_empty():
				for c in 4:
					ts.append(((ts[a * 4 + c] as float) + (ts[b * 4 + c] as float)) * 0.5)
			var cs: Array = buf["c"]
			if not cs.is_empty():
				cs.append((cs[a] as Color).lerp(cs[b] as Color, 0.5))
			for k in ["uv", "uv2"]:
				var us: Array = buf[k]
				if not us.is_empty():
					us.append(((us[a] as Vector2) + (us[b] as Vector2)) * 0.5)
			mids[key] = vs.size() - 1
			return vs.size() - 1
		var long := func(a: int, b: int) -> bool:
			var pa := to_room * (vs[a] as Vector3)
			var pb := to_room * (vs[b] as Vector3)
			return maxf(pa.y, pb.y) > above_y and pa.distance_to(pb) > SAG_EDGE_M
		for pass_i in 8:
			var next := PackedInt32Array()
			var cut := false
			for t in range(0, tris.size(), 3):
				var v := [tris[t], tris[t + 1], tris[t + 2]]
				var flags := [long.call(v[0], v[1]), long.call(v[1], v[2]), long.call(v[2], v[0])]
				var n := int(flags[0]) + int(flags[1]) + int(flags[2])
				if n == 0:
					next.append_array(v)
					continue
				cut = true
				# Turn the triangle so its cut edges come first: 1 cut -> edge 0;
				# 2 cuts -> edges 0 and 1.
				var r := 0
				if n == 1:
					r = flags.find(true)
				elif n == 2:
					r = [1, 2, 0][flags.find(false)]
				var a: int = v[r]
				var b: int = v[(r + 1) % 3]
				var c: int = v[(r + 2) % 3]
				var ab: int = mid_of.call(a, b)
				if n == 1:
					next.append_array([a, ab, c, ab, b, c])
					continue
				var bc: int = mid_of.call(b, c)
				if n == 2:
					next.append_array([a, ab, bc, ab, b, bc, a, bc, c])
					continue
				var ca: int = mid_of.call(c, a)
				next.append_array([a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca])
			tris = next
			if not cut:
				break
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(vs)
		if not (buf["n"] as Array).is_empty(): arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(buf["n"])
		if not (buf["t"] as Array).is_empty(): arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array(buf["t"])
		if not (buf["c"] as Array).is_empty(): arrays[Mesh.ARRAY_COLOR] = PackedColorArray(buf["c"])
		if not (buf["uv"] as Array).is_empty(): arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(buf["uv"])
		if not (buf["uv2"] as Array).is_empty(): arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array(buf["uv2"])
		arrays[Mesh.ARRAY_INDEX] = tris
		out.append(arrays)
	return out


# Redraws a placed piece where and how it now is on the floor (position,
# turn, footprint), after something other than the player's own drag moved it.
func _sync_entry_to_piece(entry: Dictionary) -> void:
	var f := entry["furniture"] as Furniture
	var mesh := entry["mesh"] as MeshInstance3D
	var height_m: float = (entry["size"] as Vector3).y
	var new_size := Vector3(f.grid_w * TILE_M, height_m, f.grid_h * TILE_M)
	(mesh.mesh as BoxMesh).size = new_size
	mesh.rotation.y = deg_to_rad(f.rot_steps * 90.0)
	var fdata := _find_furniture_data(_catalog, f.furniture_id)
	if fdata.get("animated_fold", false):
		_apply_animated_item_model(mesh, fdata.get("model", "") as String, f.is_extended)
	else:
		_refit_item_model(mesh, Vector3(new_size.z, new_size.y, new_size.x) if f.rot_steps % 2 == 1 else new_size)
	mesh.position.x = (f.grid_pos.x - _room_bounds.position.x) * TILE_M + new_size.x * 0.5
	mesh.position.z = (f.grid_pos.y - _room_bounds.position.y) * TILE_M + new_size.z * 0.5
	entry["size"] = new_size
	entry["pos"] = mesh.position
	for i in range(_hitbox_highlights.size() - 1, -1, -1):
		var h = _hitbox_highlights[i]
		if is_instance_valid(h) and h.get_meta("furniture", null) == f:
			h.queue_free()
			_hitbox_highlights.remove_at(i)
	_add_hitbox_highlight(Vector3(mesh.position.x, 0.0, mesh.position.z), Vector2(new_size.x, new_size.z), f)
	(_hitbox_highlights[-1] as Node3D).visible = _dragging_furniture   # shown alongside the others mid-drag


# Puts every placed piece at its height: on the floor, or on what it stands
# on (lowest first, so a lamp on a box on a table lands on the box), with
# every surface bowed by its load. The piece in hand is left alone; while one
# is carried (`carried`, its corner at `carried_at`) the surface under it
# bows as if it were already put down there.
var _sag_preview_key: Array = []

func _settle_stacked(carried: Furniture = null, carried_at: Variant = null) -> void:
	if not is_instance_valid(_apt_floor):
		return
	_sag_preview_key = [carried, carried_at]
	if Floor.carry_preview.is_valid():
		Floor.carry_preview.call(carried, carried_at)
	if carried != _hints_for:
		_show_carry_hints(carried)
	var order := _furniture_entries.filter(func(e): return is_instance_valid(e.get("furniture")) and is_instance_valid(e.get("mesh")))
	order.sort_custom(func(a, b): return _apt_floor.stack_lift(a["furniture"]) < _apt_floor.stack_lift(b["furniture"]))
	for entry in order:
		var f := entry["furniture"] as Furniture
		if f.is_surface:
			entry["sag"] = _sag_for(f, entry, carried, carried_at)
	for entry in order:
		if _dragging_furniture and is_same(entry, _drag_target):
			continue
		var f := entry["furniture"] as Furniture
		var mi := entry["mesh"] as MeshInstance3D
		var lift := _lift_m(f)
		mi.position.y = lift + (entry["size"] as Vector3).y * 0.5
		entry["pos"] = mi.position
		if f.is_surface:
			_apply_sag(entry, entry.get("sag", 0.0) as float)
		for h in _hitbox_highlights:
			if is_instance_valid(h) and h.get_meta("furniture", null) == f:
				h.position.y = lift


func _add_furniture_box(f: Furniture, bounds: Rect2i, catalog: Array) -> void:
	var fdata := _find_furniture_data(catalog, f.furniture_id)
	var height_m := maxf((fdata.get("wall_h", 8) as float) * TILE_M, 0.2)
	var fw := f.grid_w * TILE_M
	var fd := f.grid_h * TILE_M
	var local_x := (f.grid_pos.x - bounds.position.x) * TILE_M + fw * 0.5
	var local_z := (f.grid_pos.y - bounds.position.y) * TILE_M + fd * 0.5
	var col := Color("#" + (fdata.get("color", "888888") as String))
	# The model is fit into its CANONICAL (pre-rotation) box so its natural
	# proportions are preserved at every facing, then the whole box is spun
	# to match the item's actual (already-swapped) footprint — fitting the
	# model straight into the swapped fw/fd box instead would squish it and
	# made 0°/180° (and 90°/270°) render identically, since swapping twice
	# yields the same box size either way.
	var cw := f.grid_h * TILE_M if f.rot_steps % 2 == 1 else fw
	var cd := f.grid_w * TILE_M if f.rot_steps % 2 == 1 else fd
	var box_size := Vector3(fw, height_m, fd)
	var canon_size := Vector3(cw, height_m, cd)
	var pos  := Vector3(local_x, height_m * 0.5, local_z)
	var mi   := _box(canon_size, Vector3.ZERO, col)
	mi.set_meta("style_role", _item_role(fdata))
	mi.position = pos
	mi.rotation.y = deg_to_rad(f.rot_steps * 90.0)
	if fdata.get("animated_fold", false):
		_apply_animated_item_model(mi, fdata.get("model", "") as String, f.is_extended, f, true)
	else:
		_apply_item_model(mi, _active_model_path(fdata, f.is_extended), canon_size, fdata.get("hide_nodes", []) as Array)
	_style_if_bare(mi)
	if f.keepsake:
		_add_keepsake_mark(mi, height_m)
	_furniture_entries.append({"furniture": f, "mesh": mi, "pos": pos, "size": box_size})
	_add_hitbox_highlight(Vector3(local_x, 0.0, local_z), Vector2(fw, fd), f)
	_set_rail_indicator(mi, f, Vector2(fw, fd))


# `origin` is wall-local: origin.x along the wall, origin.y from the TOP of
# the wall (0 = ceiling, WALL_TILES = floor) — matches WallInspector.
func _add_wall_item_box(edge: String, origin: Vector2i, fid: String, catalog: Array) -> void:
	var fdata := _find_furniture_data(catalog, fid)
	if fdata.is_empty():
		return
	var iw: int    = (fdata.get("size", {}) as Dictionary).get("w", 5) as int
	var ih: int    = fdata.get("wall_h", 5) as int
	var depth: int = fdata.get("floor_depth", 1) as int
	var col := Color("#" + (fdata.get("color", "888888") as String))
	var xf := _wall_item_mesh_transform(edge, origin, iw, ih, depth)
	var mi := _box(xf["size"], xf["pos"], col)
	mi.set_meta("style_role", _item_role(fdata))
	_apply_item_model(mi, _active_model_path(fdata, false), xf["size"], fdata.get("hide_nodes", []) as Array)
	_style_if_bare(mi)
	_wall_item_entries.append({"edge": edge, "origin": origin, "fid": fid, "mesh": mi, "size": xf["size"]})


# ── Touch (see TouchControls) ────────────────────────────────────────────────

# A finger held still on a piece asks for its actions instead of moving it.
func _check_long_press() -> void:
	if not TouchControls.active or not (_dragging_furniture or _dragging_wall_item):
		return
	if _press_moved or Time.get_ticks_msec() - _press_ms < TouchControls.LONG_PRESS_MS:
		return
	if _dragging_furniture:
		var f: Furniture = _drag_target["furniture"]
		touch_cancel_drag()
		piece_long_pressed.emit(f)
	else:
		var hit := _drag_wall_target.duplicate()
		touch_cancel_drag()
		wall_item_long_pressed.emit(hit)


# Pinch (zoom > 1 means fingers apart), two-finger drag and twist.
func touch_camera(zoom: float, pan_px: Vector2, twist_deg: float) -> void:
	if zoom > 0.0:
		# The same far limit as the mouse wheel's (a closer one inside a box,
		# where that limit exists).
		var far: float = call("_max_dist") if has_method("_max_dist") else 30.0
		_dist = clampf(_dist / zoom, 1.5, far)
	_yaw -= twist_deg
	var pan_scale := _dist * 0.0022
	_center -= cam.global_transform.basis.x * pan_px.x * pan_scale
	_center += cam.global_transform.basis.y * pan_px.y * pan_scale
	_center = _clamp_pan_center(_center)
	_update_camera()


# Lets go of whatever a finger had started, leaving everything as it was.
func touch_cancel_drag() -> void:
	_panning = false
	if _dragging_furniture and not _drag_target.is_empty():
		var f: Furniture = _drag_target["furniture"]
		var mesh: MeshInstance3D = _drag_target["mesh"]
		_dragging_furniture = false
		mesh.position = _drag_orig_pos
		var fdata := _find_furniture_data(_catalog, f.furniture_id)
		if fdata.get("animated_fold", false):
			_apply_animated_item_model(mesh, fdata.get("model", "") as String, f.is_extended, f, true)
		_drag_target = {}
		_hide_drag_highlight()
		_hide_reason()
		_set_grid_overlay_visible(false)
		_set_hitbox_highlights_visible(false)
		_settle_stacked()
	elif _dragging_wall_item:
		_drag_wall_target["preview_origin"] = _drag_wall_target["origin"]
		_finish_wall_item_drag()


func is_buying() -> bool:
	return _buying_furniture != null


func confirm_buy_touch() -> void:
	if _buying_furniture:
		_confirm_buy(_buy_touch_vp if _buy_touch_vp != Vector2.INF else _to_vp(_last_local_mouse))


func rotate_buying() -> void:
	if _buying_furniture and not _buying_on_wall:
		_buying_furniture._rotate()
		_update_buy_ghost(_buy_touch_vp if _buy_touch_vp != Vector2.INF else _to_vp(_last_local_mouse))


func cancel_buying() -> void:
	if _buying_furniture:
		_cancel_buy()
	_buy_touch_vp = Vector2.INF


func _entry_for(f: Furniture) -> Dictionary:
	for entry in _furniture_entries:
		if (entry as Dictionary).get("furniture") == f:
			return entry
	return {}


func touch_fold(f: Furniture) -> void:
	var entry := _entry_for(f)
	if not entry.is_empty() and f.toggle_fold():
		_resize_furniture_entry(entry)


func touch_sell(f: Furniture) -> void:
	var entry := _entry_for(f)
	if not entry.is_empty():
		_sell_furniture(entry)


func touch_sell_wall_item(hit: Dictionary) -> void:
	if not hit.is_empty():
		_sell_wall_item(hit)
