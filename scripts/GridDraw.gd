extends Node2D
class_name GridDraw

const TILE_SIZE    := 8
const FLOOR_COLOR  := Color(0.93, 0.90, 0.83, 1.0)   # warm drafting-paper cream
const WALL_COLOR   := Color(0.16, 0.13, 0.10, 1.0)   # dark charcoal ink
const GRID_MINOR   := Color(0.55, 0.52, 0.44, 0.22)  # subtle warm grid
const GRID_MAJOR   := Color(0.45, 0.42, 0.34, 0.50)  # metre markers
const DOOR_COLOR   := Color(0.62, 0.40, 0.18, 1.0)   # warm chestnut
const WINDOW_COLOR := Color(0.42, 0.68, 0.88, 0.85)  # sky blue pane
const EDGE_HOVER   := Color(1.0, 0.88, 0.2, 0.55)
const EDGE_ACTIVE  := Color(1.0, 0.60, 0.0, 1.0)
const WALL_THICK   := 6.0
const EDGE_W       := 10.0   # clickable strip width — must match Wall.gd EDGE_MARGIN
const METER_TILES  := 10

var _hovered_edge: String = ""
var _active_edge:  String = ""
var _gm: GameManager = null


func set_active_edge(edge: String) -> void:
	if _active_edge != edge:
		_active_edge = edge
		queue_redraw()


func _ready() -> void:
	_gm = get_tree().get_first_node_in_group("game_manager") as GameManager
	var parent := get_parent() as Floor
	if parent:
		parent.furniture_changed.connect(queue_redraw)


func _process(_delta: float) -> void:
	var parent: Floor = get_parent() as Floor
	if not parent or not parent.visible:
		if _hovered_edge != "":
			_hovered_edge = ""
			queue_redraw()
		return
	var mouse := to_local(get_global_mouse_position())
	var rw := parent.grid_w * TILE_SIZE
	var rh := parent.grid_h * TILE_SIZE
	var new_hover := ""
	# Detect hover within EDGE_W on either side of the wall line
	if mouse.y >= -EDGE_W and mouse.y <= EDGE_W and mouse.x >= 0 and mouse.x <= rw:
		new_hover = "north"
	elif mouse.y >= rh - EDGE_W and mouse.y <= rh + EDGE_W and mouse.x >= 0 and mouse.x <= rw:
		new_hover = "south"
	elif mouse.x >= -EDGE_W and mouse.x <= EDGE_W and mouse.y > EDGE_W and mouse.y < rh - EDGE_W:
		new_hover = "west"
	elif mouse.x >= rw - EDGE_W and mouse.x <= rw + EDGE_W and mouse.y > EDGE_W and mouse.y < rh - EDGE_W:
		new_hover = "east"
	if new_hover != _hovered_edge:
		_hovered_edge = new_hover
		queue_redraw()


func _draw() -> void:
	var parent: Floor = get_parent() as Floor
	if not parent:
		return
	var w := parent.grid_w
	var h := parent.grid_h
	var rw := w * TILE_SIZE
	var rh := h * TILE_SIZE

	draw_rect(Rect2(0, 0, rw, rh), FLOOR_COLOR)

	# Minor grid (every tile = 10 cm)
	for x in range(w + 1):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh), GRID_MINOR, 0.5)
	for y in range(h + 1):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE), GRID_MINOR, 0.5)

	# Major grid (every 10 tiles = 1 m)
	for x in range(0, w + 1, METER_TILES):
		draw_line(Vector2(x * TILE_SIZE, 0), Vector2(x * TILE_SIZE, rh), GRID_MAJOR, 1.0)
	for y in range(0, h + 1, METER_TILES):
		draw_line(Vector2(0, y * TILE_SIZE), Vector2(rw, y * TILE_SIZE), GRID_MAJOR, 1.0)

	# Outer wall lines
	draw_line(Vector2(0,  0),  Vector2(rw, 0),  WALL_COLOR, WALL_THICK)
	draw_line(Vector2(0,  rh), Vector2(rw, rh), WALL_COLOR, WALL_THICK)
	draw_line(Vector2(0,  0),  Vector2(0,  rh), WALL_COLOR, WALL_THICK)
	draw_line(Vector2(rw, 0),  Vector2(rw, rh), WALL_COLOR, WALL_THICK)

	# Hover glow — only when not already the active edge
	if _hovered_edge != "" and _hovered_edge != _active_edge:
		match _hovered_edge:
			"north": draw_line(Vector2(0, 0),  Vector2(rw, 0),  EDGE_HOVER, WALL_THICK + 2.0)
			"south": draw_line(Vector2(0, rh), Vector2(rw, rh), EDGE_HOVER, WALL_THICK + 2.0)
			"west":  draw_line(Vector2(0, 0),  Vector2(0, rh),  EDGE_HOVER, WALL_THICK + 2.0)
			"east":  draw_line(Vector2(rw, 0), Vector2(rw, rh), EDGE_HOVER, WALL_THICK + 2.0)

	# Active wall glow — drawn last so it sits on top of the wall line
	if _active_edge != "":
		var glow_outer := Color(EDGE_ACTIVE.r, EDGE_ACTIVE.g, EDGE_ACTIVE.b, 0.35)
		match _active_edge:
			"north":
				draw_line(Vector2(0, 0),  Vector2(rw, 0),  glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, 0),  Vector2(rw, 0),  EDGE_ACTIVE, WALL_THICK + 1.0)
			"south":
				draw_line(Vector2(0, rh), Vector2(rw, rh), glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, rh), Vector2(rw, rh), EDGE_ACTIVE, WALL_THICK + 1.0)
			"west":
				draw_line(Vector2(0, 0),  Vector2(0, rh),  glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(0, 0),  Vector2(0, rh),  EDGE_ACTIVE, WALL_THICK + 1.0)
			"east":
				draw_line(Vector2(rw, 0), Vector2(rw, rh), glow_outer,  WALL_THICK + 8.0)
				draw_line(Vector2(rw, 0), Vector2(rw, rh), EDGE_ACTIVE, WALL_THICK + 1.0)

	for wall_def in parent.wall_definitions:
		_draw_wall_feature(wall_def, w, h)

	_draw_wall_items(parent, rw, rh)


func _draw_wall_items(parent: Floor, rw: int, rh: int) -> void:
	if not _gm:
		return
	for edge in parent.wall_items:
		var items: Dictionary = parent.wall_items[edge] as Dictionary
		for origin in items:
			var o     := origin as Vector2i
			var fid   : String = items[origin] as String
			var fdata  := _gm.get_furniture_by_id(fid)
			if fdata.is_empty():
				continue
			var iw: int    = fdata["size"]["w"] as int
			var depth: int = fdata.get("floor_depth", 1) as int
			var col        := Color("#" + (fdata.get("color", "aaaaaa") as String))
			col.a = 0.85
			match edge:
				"north":
					draw_rect(Rect2(o.x * TILE_SIZE, 0, iw * TILE_SIZE, depth * TILE_SIZE), col)
					draw_rect(Rect2(o.x * TILE_SIZE, 0, iw * TILE_SIZE, depth * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"south":
					var ry := rh - depth * TILE_SIZE
					draw_rect(Rect2(o.x * TILE_SIZE, ry, iw * TILE_SIZE, depth * TILE_SIZE), col)
					draw_rect(Rect2(o.x * TILE_SIZE, ry, iw * TILE_SIZE, depth * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"west":
					draw_rect(Rect2(0, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE), col)
					draw_rect(Rect2(0, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)
				"east":
					var rx := rw - depth * TILE_SIZE
					draw_rect(Rect2(rx, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE), col)
					draw_rect(Rect2(rx, o.x * TILE_SIZE, depth * TILE_SIZE, iw * TILE_SIZE),
						Color(0, 0, 0, 0.40), false, 1.0)


func _draw_wall_feature(wall_def: Dictionary, w: int, h: int) -> void:
	var edge: String = wall_def.get("edge", "")
	var rw := w * TILE_SIZE
	var rh := h * TILE_SIZE

	if wall_def.get("has_door", false):
		var dx: int = wall_def.get("door_x", 0) as int
		var gap := TILE_SIZE * 10   # door = 1 m wide
		var arc_col := Color(DOOR_COLOR.r, DOOR_COLOR.g, DOOR_COLOR.b, 0.40)
		match edge:
			"north":
				draw_rect(Rect2(dx * TILE_SIZE + 1, -1, gap - 2, WALL_THICK + 2), FLOOR_COLOR)
				draw_line(Vector2(dx * TILE_SIZE, 0), Vector2(dx * TILE_SIZE, gap), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx * TILE_SIZE, 0), gap, 0, PI * 0.5, 20, arc_col, 1.0)
			"south":
				draw_rect(Rect2(dx * TILE_SIZE + 1, rh - 1, gap - 2, WALL_THICK + 2), FLOOR_COLOR)
				draw_line(Vector2(dx * TILE_SIZE, rh), Vector2(dx * TILE_SIZE, rh - gap), DOOR_COLOR, 1.2)
				draw_arc(Vector2(dx * TILE_SIZE, rh), gap, -PI * 0.5, 0, 20, arc_col, 1.0)
			"west":
				draw_rect(Rect2(-1, dx * TILE_SIZE + 1, WALL_THICK + 2, gap - 2), FLOOR_COLOR)
				draw_line(Vector2(0, dx * TILE_SIZE), Vector2(gap, dx * TILE_SIZE), DOOR_COLOR, 1.2)
				draw_arc(Vector2(0, dx * TILE_SIZE), gap, 0, PI * 0.5, 20, arc_col, 1.0)
			"east":
				draw_rect(Rect2(rw - 1, dx * TILE_SIZE + 1, WALL_THICK + 2, gap - 2), FLOOR_COLOR)
				draw_line(Vector2(rw, dx * TILE_SIZE), Vector2(rw - gap, dx * TILE_SIZE), DOOR_COLOR, 1.2)
				draw_arc(Vector2(rw, dx * TILE_SIZE), gap, PI * 0.5, PI, 20, arc_col, 1.0)

	if wall_def.get("has_window", false):
		var wx: int = wall_def.get("window_x", 0) as int
		var wl: int = wall_def.get("window_len", 15) as int
		match edge:
			"north": draw_rect(Rect2(wx * TILE_SIZE + 1, -1, wl * TILE_SIZE - 2, WALL_THICK + 2), WINDOW_COLOR)
			"south": draw_rect(Rect2(wx * TILE_SIZE + 1, rh - 1, wl * TILE_SIZE - 2, WALL_THICK + 2), WINDOW_COLOR)
			"west":  draw_rect(Rect2(-1, wx * TILE_SIZE + 1, WALL_THICK + 2, wl * TILE_SIZE - 2), WINDOW_COLOR)
			"east":  draw_rect(Rect2(rw - 1, wx * TILE_SIZE + 1, WALL_THICK + 2, wl * TILE_SIZE - 2), WINDOW_COLOR)
