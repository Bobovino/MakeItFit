extends Node2D
class_name Floor

signal furniture_changed
signal wall_edge_clicked(edge: String)

const TILE_SIZE := 8
const EDGE_MARGIN := 10
const WALL_DEPTH := 8  # tiles within this distance count as "against the wall"

var floor_id: String = ""
var floor_label: String = ""
var grid_w: int = 8
var grid_h: int = 6
var wall_definitions: Array = []

var _placed: Dictionary = {}      # Vector2i -> Furniture
var wall_items: Dictionary = {}   # "north" -> { Vector2i origin -> fid }

@onready var grid_draw: GridDraw = $GridDraw


func set_active_wall_edge(edge: String) -> void:
	if grid_draw:
		grid_draw.set_active_edge(edge)


func setup(floor_data: Dictionary) -> void:
	floor_id = floor_data["id"]
	floor_label = floor_data["label"]
	grid_w = floor_data["grid_w"]
	grid_h = floor_data["grid_h"]
	wall_definitions = floor_data.get("walls", [])
	if grid_draw:
		grid_draw.queue_redraw()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var local := to_local(get_viewport().get_mouse_position())
	var rw := grid_w * TILE_SIZE
	var rh := grid_h * TILE_SIZE
	# Only trigger if click is near the border, outside the inner tiles
	if local.x < -EDGE_MARGIN or local.x > rw + EDGE_MARGIN:
		return
	if local.y < -EDGE_MARGIN or local.y > rh + EDGE_MARGIN:
		return
	if local.y < EDGE_MARGIN and local.x > 0 and local.x < rw:
		wall_edge_clicked.emit("north")
		get_viewport().set_input_as_handled()
	elif local.y > rh - EDGE_MARGIN and local.x > 0 and local.x < rw:
		wall_edge_clicked.emit("south")
		get_viewport().set_input_as_handled()
	elif local.x < EDGE_MARGIN and local.y > 0 and local.y < rh:
		wall_edge_clicked.emit("west")
		get_viewport().set_input_as_handled()
	elif local.x > rw - EDGE_MARGIN and local.y > 0 and local.y < rh:
		wall_edge_clicked.emit("east")
		get_viewport().set_input_as_handled()


func can_place(furniture: Furniture, at: Vector2i) -> bool:
	for x in range(furniture.grid_w):
		for y in range(furniture.grid_h):
			var tile := Vector2i(at.x + x, at.y + y)
			if tile.x < 0 or tile.x >= grid_w:
				return false
			if tile.y < 0 or tile.y >= grid_h:
				return false
			if tile in _placed and _placed[tile] != furniture:
				return false
	return true


func place_furniture(furniture: Furniture, at: Vector2i) -> void:
	_remove_from_grid(furniture)
	for x in range(furniture.grid_w):
		for y in range(furniture.grid_h):
			_placed[Vector2i(at.x + x, at.y + y)] = furniture
	furniture.grid_pos = at
	furniture.position = Vector2(at.x * TILE_SIZE, at.y * TILE_SIZE)
	furniture_changed.emit()


func remove_furniture(furniture: Furniture) -> void:
	_remove_from_grid(furniture)
	furniture.queue_free()
	furniture_changed.emit()


func _remove_from_grid(furniture: Furniture) -> void:
	var to_remove: Array = []
	for tile in _placed:
		if _placed[tile] == furniture:
			to_remove.append(tile)
	for tile in to_remove:
		_placed.erase(tile)


func find_free_spot(w: int, h: int) -> Vector2i:
	for y in range(grid_h - h + 1):
		for x in range(grid_w - w + 1):
			var clear := true
			for dy in range(h):
				for dx in range(w):
					if Vector2i(x + dx, y + dy) in _placed:
						clear = false
						break
				if not clear:
					break
			if clear:
				return Vector2i(x, y)
	return Vector2i.ZERO


func place_wall_item(edge: String, origin: Vector2i, fid: String) -> void:
	if not (edge in wall_items):
		wall_items[edge] = {}
	wall_items[edge][origin] = fid
	furniture_changed.emit()


func remove_wall_item(edge: String, origin: Vector2i) -> void:
	if edge in wall_items:
		wall_items[edge].erase(origin)
	furniture_changed.emit()


func get_wall_items(edge: String) -> Dictionary:
	if not (edge in wall_items):
		wall_items[edge] = {}
	return wall_items[edge]   # returns a live reference


func get_all_furniture_ids() -> Array:
	var seen: Array = []
	var ids: Array = []
	for tile in _placed:
		var f: Furniture = _placed[tile] as Furniture
		if f not in seen:
			seen.append(f)
			ids.append(f.furniture_id)
	return ids


func get_all_wall_item_ids() -> Array:
	var ids: Array = []
	for edge in wall_items:
		var items: Dictionary = wall_items[edge]
		for origin in items:
			var fid: String = items[origin] as String
			if fid not in ids:
				ids.append(fid)
	return ids


func get_adjacent_furniture(edge: String) -> Array:
	# Returns [{furniture, wall_x}] for pieces whose footprint touches this wall edge
	var result: Array = []
	var seen: Array = []
	for tile in _placed:
		var f: Furniture = _placed[tile] as Furniture
		if f in seen:
			continue
		var adjacent := false
		var wall_x := 0
		match edge:
			"north":
				if f.grid_pos.y < WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.x
			"south":
				if f.grid_pos.y + f.grid_h > grid_h - WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.x
			"west":
				if f.grid_pos.x < WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.y
			"east":
				if f.grid_pos.x + f.grid_w > grid_w - WALL_DEPTH:
					adjacent = true
					wall_x = f.grid_pos.y
		if adjacent:
			seen.append(f)
			result.append({"furniture": f, "wall_x": wall_x})
	return result


func get_all_furniture() -> Array:
	var seen: Array = []
	for tile in _placed:
		var f: Furniture = _placed[tile] as Furniture
		if f not in seen:
			seen.append(f)
	return seen


func get_inaccessible_furniture() -> Array:
	var result: Array = []
	for f in get_all_furniture():
		if not _has_adjacent_free(f):
			result.append(f)
	return result


func _has_adjacent_free(f: Furniture) -> bool:
	var x0 := f.grid_pos.x
	var y0 := f.grid_pos.y
	var x1 := x0 + f.grid_w
	var y1 := y0 + f.grid_h
	for x in range(x0, x1):
		if y0 > 0 and Vector2i(x, y0 - 1) not in _placed:
			return true
		if y1 < grid_h and Vector2i(x, y1) not in _placed:
			return true
	for y in range(y0, y1):
		if x0 > 0 and Vector2i(x0 - 1, y) not in _placed:
			return true
		if x1 < grid_w and Vector2i(x1, y) not in _placed:
			return true
	return false
