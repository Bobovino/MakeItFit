extends RefCounted
class_name Kits

# Modular furniture kits: a storage wall built from 0.40 m cubes and a
# sectional sofa built from 0.90 m seats (the asset pack's wall_system/ and
# modular_sofa/, see assets/models/furniture/README.txt).
#
# A composed run is ONE ordinary piece of furniture. Its catalogue entry
# ("kit": "wall" | "sofa") is the starting point, and the run's own module
# list rides along on the instance as "modules", the same way a nested box's
# child_level_id does: saves, undo and level files keep {id, x, y, ...,
# "modules": [...]}, and compose() turns that back into the full entry
# (footprint, height, price, functions, model). Everything else in the game
# (dragging, turning, selling, the tenant's needs, 2D and 3D drawing) then
# treats it like any other piece.
#
# Module records:
#   wall  {"m": "Drawer_2x1", "c": col, "r": row}  cells from the left/floor
#         plus the run-wide trims {"m": "Plinth"}, {"m": "Cap"}, {"m": "Filler"}
#   sofa  {"m": "Seat_1"} in order from left to right

const MODEL_DIR := "res://assets/models/furniture/kits/"
const PREFIX := "kit:"

const WALL_CELL_M := 0.40
const WALL_DEPTH_TILES := 3      # 0.32 m deep modules on a 10 cm grid
const WALL_MAX_COLS := 10        # 4 m
const WALL_MAX_ROWS := 6         # 2.4 m
const PLINTH_M := 0.10
const CAP_M := 0.04
const FILLER_M := 0.20

const SOFA_CELL_TILES := 9       # 0.90 m
const SOFA_MAX_MODULES := 8

# w × h in cells. "rows" limits where a module can go, [lowest, highest].
const WALL_MODULES := {
	"Cube_1x1":      {"w": 1, "h": 1, "price": 25,  "functions": ["storage"]},
	"Cube_2x1":      {"w": 2, "h": 1, "price": 40,  "functions": ["storage"]},
	"Cube_3x1":      {"w": 3, "h": 1, "price": 55,  "functions": ["storage"]},
	"Cube_1x2":      {"w": 1, "h": 2, "price": 40,  "functions": ["storage"]},
	"Cube_1x3":      {"w": 1, "h": 3, "price": 55,  "functions": ["storage"]},
	"Cube_2x2":      {"w": 2, "h": 2, "price": 70,  "functions": ["storage"]},
	"Books_1x1":     {"w": 1, "h": 1, "price": 30,  "functions": ["storage"]},
	"Bin_1x1":       {"w": 1, "h": 1, "price": 30,  "functions": ["storage"]},
	"WineRack_1x1":  {"w": 1, "h": 1, "price": 35,  "functions": ["storage"]},
	"Corner_1x1":    {"w": 1, "h": 1, "price": 25,  "functions": ["storage"]},
	"Door_1x1":      {"w": 1, "h": 1, "price": 45,  "functions": ["storage"]},
	"Door_2x1":      {"w": 2, "h": 1, "price": 75,  "functions": ["storage"]},
	"GlassDoor_1x2": {"w": 1, "h": 2, "price": 80,  "functions": ["storage"]},
	"FlapUp_2x1":    {"w": 2, "h": 1, "price": 80,  "functions": ["storage"]},
	"Drawer_1x1":    {"w": 1, "h": 1, "price": 50,  "functions": ["storage"]},
	"Drawer_2x1":    {"w": 2, "h": 1, "price": 85,  "functions": ["storage"]},
	"Basket_1x1":    {"w": 1, "h": 1, "price": 45,  "functions": ["storage"]},
	"ShoeRack_2x1":  {"w": 2, "h": 1, "price": 50,  "functions": ["storage"]},
	"Shallow_2x2":   {"w": 2, "h": 2, "price": 60,  "functions": ["storage"]},
	"Hooks_2x1":     {"w": 2, "h": 1, "price": 35,  "functions": ["dress"]},
	"Rail_2x3":      {"w": 2, "h": 3, "price": 150, "functions": ["dress", "storage"]},
	"Media_2x2":     {"w": 2, "h": 2, "price": 120, "functions": []},
	# Its flap folds down into a desk at the second row (0.74 m with a plinth).
	"Desk_2x1":      {"w": 2, "h": 1, "price": 140, "functions": ["work"], "rows": [1, 1]},
	# A seat is only a seat on the floor.
	"Bench_2x1":     {"w": 2, "h": 1, "price": 90,  "functions": ["sit", "storage"], "rows": [0, 0]},
}

# Run-wide trims for the wall: priced per started 0.80 m of run.
const WALL_TRIMS := {
	"Plinth": {"model": "Plinth_2", "price": 15},
	"Cap":    {"model": "Cap_2",    "price": 15},
	"Filler": {"model": "Filler_Half", "price": 10},   # per row, closes the right end
}

# Widths in tiles; "deep" doubles the depth (the chaise); "end" modules turn
# the run and so only go first or last; "back" says it has a backrest.
const SOFA_MODULES := {
	"Arm_1":     {"w": 2, "price": 30,  "functions": [],                 "h_m": 0.66},
	"Seat_1":    {"w": 9, "price": 120, "functions": ["sit"],            "h_m": 0.82},
	"Corner_1":  {"w": 9, "price": 150, "functions": ["sit"],            "h_m": 0.82, "end": true},
	"Chaise_1":  {"w": 9, "price": 220, "functions": ["sit"],            "h_m": 0.82, "deep": true},
	"Ottoman_1": {"w": 9, "price": 60,  "functions": ["sit"],            "h_m": 0.44},
	"Storage_1": {"w": 9, "price": 110, "functions": ["sit", "storage"], "h_m": 0.44},
	"Console_1": {"w": 2, "price": 40,  "functions": [],                 "h_m": 0.72},
}

const SELL_SHARE := 0.4


static func kit_of(fdata: Dictionary) -> String:
	return fdata.get("kit", "") as String


# Everything some run of `kit` could give.
static func all_functions(kit: String) -> Array:
	var out: Array = []
	if kit == "":
		return out
	for m in module_names(kit):
		for fn in module_info(kit, m).get("functions", []):
			if not out.has(fn):
				out.append(fn)
	return out


# The cheapest run that can be bought: one module (a sofa needs a seat).
static func min_price(kit: String) -> int:
	var best := 1 << 30
	for m in module_names(kit):
		var info := module_info(kit, m)
		if kit == "sofa" and not (info.get("functions", []) as Array).has("sit"):
			continue
		best = mini(best, int(info["price"]))
	return best


static func is_kit_model(path: String) -> bool:
	return path.begins_with(PREFIX)


static func module_names(kit: String) -> Array:
	return (WALL_MODULES if kit == "wall" else SOFA_MODULES).keys()


static func module_info(kit: String, m: String) -> Dictionary:
	if kit == "wall":
		return WALL_MODULES.get(m, {})
	return SOFA_MODULES.get(m, {})


static func model_file(kit: String, m: String) -> String:
	var dir := "wall_system/" if kit == "wall" else "modular_sofa/"
	if kit == "wall" and WALL_TRIMS.has(m):
		m = WALL_TRIMS[m]["model"]
	return MODEL_DIR + dir + m + ".glb"


# ── Wall grid helpers ────────────────────────────────────────────────────────

static func _wall_cells(modules: Array) -> Array:
	return modules.filter(func(e): return WALL_MODULES.has((e as Dictionary).get("m", "")))


static func _has_trim(modules: Array, trim: String) -> bool:
	for e in modules:
		if (e as Dictionary).get("m", "") == trim:
			return true
	return false


# Columns × rows the wall's modules span (from column 0 and the floor).
static func wall_extent(modules: Array) -> Vector2i:
	var ext := Vector2i.ZERO
	for e in _wall_cells(modules):
		var info: Dictionary = WALL_MODULES[e["m"]]
		ext.x = maxi(ext.x, int(e.get("c", 0)) + int(info["w"]))
		ext.y = maxi(ext.y, int(e.get("r", 0)) + int(info["h"]))
	return ext


static func wall_width_m(modules: Array) -> float:
	return wall_extent(modules).x * WALL_CELL_M + (FILLER_M if _has_trim(modules, "Filler") else 0.0)


static func wall_height_m(modules: Array) -> float:
	return (PLINTH_M if _has_trim(modules, "Plinth") else 0.0) + wall_extent(modules).y * WALL_CELL_M \
		+ (CAP_M if _has_trim(modules, "Cap") else 0.0)


# The wall module covering cell (c, r), or -1.
static func wall_module_at(modules: Array, c: int, r: int) -> int:
	for i in modules.size():
		var e := modules[i] as Dictionary
		var info: Dictionary = WALL_MODULES.get(e.get("m", ""), {})
		if info.is_empty():
			continue
		var c0 := int(e.get("c", 0))
		var r0 := int(e.get("r", 0))
		if c >= c0 and c < c0 + int(info["w"]) and r >= r0 and r < r0 + int(info["h"]):
			return i
	return -1


# Why `m` can't go with its bottom-left cell at (c, r) in `modules`, or "".
static func wall_fit_reason(modules: Array, m: String, c: int, r: int) -> String:
	var info: Dictionary = WALL_MODULES.get(m, {})
	if info.is_empty():
		return "Unknown module"
	if c < 0 or r < 0 or c + int(info["w"]) > WALL_MAX_COLS or r + int(info["h"]) > WALL_MAX_ROWS:
		return "Doesn't fit in the wall"
	var rows: Array = info.get("rows", [])
	if not rows.is_empty() and (r < int(rows[0]) or r > int(rows[1])):
		return "Only on the floor row" if int(rows[1]) == 0 else "Only on the second row, at desk height"
	for dc in int(info["w"]):
		for dr in int(info["h"]):
			if wall_module_at(modules, c + dc, r + dr) >= 0:
				return "Something is already there"
	return ""


# ── Sofa helpers ─────────────────────────────────────────────────────────────

static func _sofa_list(modules: Array) -> Array:
	return modules.filter(func(e): return SOFA_MODULES.has((e as Dictionary).get("m", "")))


# Why `m` can't be added at `index` of the sofa run, or "".
static func sofa_fit_reason(modules: Array, m: String, index: int) -> String:
	var run := _sofa_list(modules)
	if not SOFA_MODULES.has(m):
		return "Unknown module"
	if run.size() >= SOFA_MAX_MODULES:
		return "The sofa is as long as it gets"
	var info: Dictionary = SOFA_MODULES[m]
	if info.get("end", false) and index != 0 and index != run.size():
		return "A corner only goes at an end"
	# Something put between an end corner and the edge would leave it inside.
	if index == 0 and not run.is_empty() and (SOFA_MODULES[run[0]["m"]] as Dictionary).get("end", false):
		return "A corner only goes at an end"
	if index == run.size() and run.size() > 1 and (SOFA_MODULES[run[-1]["m"]] as Dictionary).get("end", false):
		return "A corner only goes at an end"
	return ""


# ── Whole-run checks and derived data ────────────────────────────────────────

# Why `modules` isn't a run that can be bought, or "".
static func run_reason(kit: String, modules: Array) -> String:
	if kit == "wall":
		var cells := _wall_cells(modules)
		if cells.is_empty():
			return "Add at least one module"
		var placed: Array = []
		for e in cells:
			var why := wall_fit_reason(placed, e["m"], int(e.get("c", 0)), int(e.get("r", 0)))
			if why != "":
				return why
			placed.append(e)
		return ""
	var run := _sofa_list(modules)
	if run.is_empty():
		return "Add at least one module"
	var placed: Array = []
	for e in run:
		var why := sofa_fit_reason(placed, e["m"], placed.size())
		if why != "":
			return why
		placed.append(e)
	for e in run:
		if (SOFA_MODULES[e["m"]]["functions"] as Array).has("sit"):
			return ""
	return "A sofa needs at least one seat"


# The same run, cleaned: unknown entries dropped, the wall shifted so its
# leftmost module starts at column 0, trims listed once and last.
static func normalize(kit: String, modules: Array) -> Array:
	if kit == "sofa":
		return _sofa_list(modules).map(func(e): return {"m": e["m"]})
	var cells := _wall_cells(modules)
	var min_c := WALL_MAX_COLS
	for e in cells:
		min_c = mini(min_c, int(e.get("c", 0)))
	var out: Array = []
	for e in cells:
		out.append({"m": e["m"], "c": int(e.get("c", 0)) - min_c, "r": int(e.get("r", 0))})
	for trim in WALL_TRIMS:
		if _has_trim(modules, trim):
			out.append({"m": trim})
	return out


static func price_of(kit: String, modules: Array) -> int:
	var total := 0
	if kit == "wall":
		for e in _wall_cells(modules):
			total += int(WALL_MODULES[e["m"]]["price"])
		var spans := ceili(wall_width_m(modules) / (2.0 * WALL_CELL_M) - 0.001)
		var rows := wall_extent(modules).y
		if _has_trim(modules, "Plinth"):
			total += int(WALL_TRIMS["Plinth"]["price"]) * spans
		if _has_trim(modules, "Cap"):
			total += int(WALL_TRIMS["Cap"]["price"]) * spans
		if _has_trim(modules, "Filler"):
			total += int(WALL_TRIMS["Filler"]["price"]) * rows
		return total
	for e in _sofa_list(modules):
		total += int(SOFA_MODULES[e["m"]]["price"])
	return total


static func functions_of(kit: String, modules: Array) -> Array:
	var out: Array = []
	var list := _wall_cells(modules) if kit == "wall" else _sofa_list(modules)
	for e in list:
		for fn in module_info(kit, e["m"]).get("functions", []):
			if not out.has(fn):
				out.append(fn)
	return out


# Width × depth in tiles and height in metres.
static func footprint(kit: String, modules: Array) -> Dictionary:
	if kit == "wall":
		return {"w": maxi(1, roundi(wall_width_m(modules) * 10.0)), "h": WALL_DEPTH_TILES,
			"h_m": wall_height_m(modules)}
	var w := 0
	var deep := false
	var top := 0.0
	for e in _sofa_list(modules):
		var info: Dictionary = SOFA_MODULES[e["m"]]
		w += int(info["w"])
		deep = deep or info.get("deep", false)
		top = maxf(top, float(info["h_m"]))
	return {"w": maxi(1, w), "h": SOFA_CELL_TILES * (2 if deep else 1), "h_m": top}


static func model_path(kit: String, modules: Array) -> String:
	return PREFIX + kit + ":" + JSON.stringify(modules)


# The full furniture entry for `base` (a "kit" catalogue entry) composed of
# `modules`; its catalogue default when `modules` is empty.
static func compose(base: Dictionary, modules: Array = []) -> Dictionary:
	var kit := kit_of(base)
	if kit == "":
		return base
	if modules.is_empty():
		modules = base.get("modules", []) as Array
	modules = normalize(kit, modules)
	var d := base.duplicate(true)
	var fp := footprint(kit, modules)
	var price := price_of(kit, modules)
	d["modules"] = modules
	d["size"] = {"w": fp["w"], "h": fp["h"]}
	var tiles_h := maxi(1, ceili(float(fp["h_m"]) * 10.0 - 0.001))
	d["wall_h"] = tiles_h
	d["z_top"] = tiles_h
	if kit == "wall":
		d["height_category"] = "tall" if tiles_h >= 16 else ("medium" if tiles_h >= 8 else "low")
	d["functions"] = functions_of(kit, modules)
	d["buy_price"] = price
	d["sell_price"] = roundi(price * SELL_SHARE)
	d["model"] = model_path(kit, modules)
	d.erase("weight")   # a longer run weighs more: Furniture takes it from the footprint
	return d


# ── 3D ───────────────────────────────────────────────────────────────────────

# Where each model of the run goes, in the kit's own space: x along the run,
# y up, z from the back (0) to the front. Each: {file, pos, scale_x}.
static func layout(kit: String, modules: Array) -> Array:
	var out: Array = []
	if kit == "wall":
		var base_y := PLINTH_M if _has_trim(modules, "Plinth") else 0.0
		var ext := wall_extent(modules)
		for e in _wall_cells(modules):
			out.append({"file": model_file(kit, e["m"]), "scale_x": 1.0,
				"pos": Vector3(int(e["c"]) * WALL_CELL_M, base_y + int(e["r"]) * WALL_CELL_M, 0.0)})
		var width := wall_width_m(modules)
		if _has_trim(modules, "Filler"):
			for r in ext.y:
				out.append({"file": model_file(kit, "Filler"), "scale_x": 1.0,
					"pos": Vector3(ext.x * WALL_CELL_M, base_y + r * WALL_CELL_M, 0.0)})
		# Trims come 0.80 m long; the last one is cut to what's left.
		for trim in ["Plinth", "Cap"]:
			if not _has_trim(modules, trim):
				continue
			var y := 0.0 if trim == "Plinth" else base_y + ext.y * WALL_CELL_M
			var x := 0.0
			while x < width - 0.001:
				var piece := minf(2.0 * WALL_CELL_M, width - x)
				out.append({"file": model_file(kit, trim), "scale_x": piece / (2.0 * WALL_CELL_M),
					"pos": Vector3(x, y, 0.0)})
				x += piece
		return out
	var run := _sofa_list(modules)
	var x := 0.0
	for i in run.size():
		var m: String = run[i]["m"]
		var info: Dictionary = SOFA_MODULES[m]
		var w_m := int(info["w"]) * 0.1
		# The corner's second back is on its right: mirrored when it starts the run.
		var mirror: bool = info.get("end", false) and i == 0 and run.size() > 1
		out.append({"file": model_file(kit, m), "scale_x": -1.0 if mirror else 1.0,
			"pos": Vector3(x + (w_m if mirror else 0.0), 0.0, 0.0)})
		x += w_m
	return out


static func model_exists(path: String) -> bool:
	if is_kit_model(path):
		return true
	return not path.is_empty() and ResourceLoader.exists(path)


# A model as a fresh node: a .glb, or a "kit:" run assembled from its modules.
static func instantiate_model(path: String) -> Node3D:
	if not is_kit_model(path):
		if path.is_empty() or not ResourceLoader.exists(path):
			return null
		var packed := load(path) as PackedScene
		return packed.instantiate() as Node3D if packed else null
	var rest := path.trim_prefix(PREFIX)
	var colon := rest.find(":")
	if colon < 0:
		return null
	var kit := rest.substr(0, colon)
	var parsed = JSON.parse_string(rest.substr(colon + 1))
	if not parsed is Array:
		return null
	return build_node(kit, parsed as Array)


static func build_node(kit: String, modules: Array) -> Node3D:
	var root := Node3D.new()
	root.name = "KitRun"
	for part in layout(kit, modules):
		var packed := load(part["file"]) as PackedScene
		if not packed:
			continue
		var inst := packed.instantiate() as Node3D
		inst.position = part["pos"]
		inst.scale.x = part["scale_x"]
		root.add_child(inst)
	# An invisible box over the run's whole footprint: the 3D view and the
	# thumbnails fit a model by its bounds, and gaps left in a wall (or the
	# open front of a chaise run) must not shrink or stretch the run.
	var fp := footprint(kit, modules)
	var size := Vector3(float(fp["w"]) * 0.1, float(fp["h_m"]), float(fp["h"]) * 0.1)
	var marker := MeshInstance3D.new()
	marker.name = "KitBounds"
	var box := BoxMesh.new()
	box.size = size
	marker.mesh = box
	marker.position = size * 0.5
	marker.visible = false
	root.add_child(marker)
	return root
