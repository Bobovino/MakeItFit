extends Node
class_name GameManager

signal budget_changed(new_budget: int)
signal functions_updated(fulfilled: Array, required: Array)
signal moments_updated(results: Dictionary)

var budget: int = 3000
var current_level: Dictionary = {}
var required_functions: Array = []
var fulfilled_functions: Array = []
var moments: Array = []
var moment_results: Dictionary = {}  # moment_id -> {fulfilled:[], required:[]}
var moment_verified: Dictionary = {}  # moment_id -> bool; true once its needs were met with the real furniture state
# Zone-separation and sightline checks are level-wide, single-layout checks
# (see Floor._recalculate_zones()/has_sightline()) — with movable-tier
# furniture now able to sit somewhere different per Moment, a check run while
# "Day" is on screen says nothing about whether "Night"'s arrangement also
# satisfies them. Sticky per-moment, same philosophy as moment_verified —
# recorded by Main._refresh_functions() (the only place with a Floor
# reference) right after that Moment's furniture has been repositioned into
# place, via GameManager.record_moment_geometry(). external_zone_ok stays a
# global, non-per-moment check — external-zone + moments is a rare enough
# combination that folding it in too isn't worth the extra complexity yet.
var moment_zone_ok: Dictionary = {}       # moment_id -> bool, sticky
var moment_sightline_ok: Dictionary = {}  # moment_id -> bool, sticky

# Mobility/comfort — see Furniture.mobility_tier. A "yellow" piece sitting
# away from its authored starting position (Furniture._home_grid_pos) costs
# comfort; current-state based, so moving it back recovers it. comfort_pct
# always reflects whichever moment is currently on screen (or the single
# global layout, for a level with no moments) — for the live UI meter.
const COMFORT_COST_PER_ITEM  := 25.0
const COMFORT_WARN_THRESHOLD := 50.0
var comfort_pct: float = 100.0
var zone_separations: Array = []     # [[ [fnsA], [fnsB] ], ...] — groups that must be in separate zones
var current_zones: Array = []        # latest zone snapshot from the active floor

# Sightline requirements: [{from:[x,y], to:[x,y], must_be_clear:bool, label:String}].
# must_be_clear=true means the tenant's win condition needs a clear line
# ("ver el amanecer" from the bed to a sunrise-facing window); false means it
# must stay BLOCKED (the "overprotective parents" case — a supervision point
# must NOT have a direct line into a teen's private zone). Checked against
# Floor.has_sightline() — see Main.gd's _refresh_functions(), which is the
# only place that actually has a Floor reference to evaluate these against.
var sightline_requirements: Array = []
var sightline_ok: bool = true

# External zones & restrictions — noise/smells/birds/municipal ordinances
# from outside the apartment. Two concrete effects, kept simple on purpose:
#  - "forbidden_functions": functions an ordinance bans outright for this
#    level (e.g. a heritage-protected building forbidding "balcony").
#  - "min_boundary_distance": {function: tiles} — a function's furniture must
#    sit at least that many tiles from the outer wall (a bedroom needing
#    setback from a noisy/smelly street, or bird nests putting the kitchen
#    window off-limits for anything requiring it to be flush against a wall).
var external_restrictions: Dictionary = {}
var external_zone_ok: bool = true

var furniture_data: Dictionary = {}
var levels_data: Dictionary = {}

var allowed_furniture:   Array = []  # [] = no filter; otherwise ID whitelist
var starting_inventory:  Array = []  # [{id, count}] unplaced items player owns
var starting_furniture:  Array = []  # [{id, x, y}] items pre-placed in the apartment


func _ready() -> void:
	add_to_group("game_manager")
	furniture_data = _load_json("res://data/furniture.json")
	levels_data = _load_json("res://data/levels.json")


func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Cannot load: " + path)
		return {}
	var json := JSON.new()
	json.parse(file.get_as_text())
	return json.get_data()


func load_level(level_id: String) -> void:
	# Custom level created in the level editor
	if level_id == "_custom" and not GameState.custom_level_data.is_empty():
		current_level = GameState.custom_level_data
		budget = current_level.get("starting_budget", 2000) as int
		moments = current_level.get("moments", []) as Array
		moment_results = {}
		moment_verified = {}
		moment_zone_ok = {}
		moment_sightline_ok = {}
		comfort_pct = 100.0
		var _tenant := (current_level.get("tenant", {}) as Dictionary)
		required_functions = _tenant.get("required_functions", []).duplicate() as Array
		zone_separations   = _tenant.get("zone_separations",   []).duplicate(true) as Array
		sightline_requirements = _tenant.get("sightline_requirements", []).duplicate(true) as Array
		sightline_ok = true
		external_restrictions = (current_level.get("external_zone", {}) as Dictionary).duplicate(true)
		external_zone_ok = true
		fulfilled_functions = []
		current_zones = []
		allowed_furniture  = (current_level.get("allowed_furniture",  []) as Array).duplicate()
		starting_inventory = (current_level.get("starting_inventory", []) as Array).duplicate(true)
		starting_furniture = (current_level.get("starting_furniture", []) as Array).duplicate(true)
		budget_changed.emit(budget)
		functions_updated.emit(fulfilled_functions, required_functions)
		if not moments.is_empty():
			moments_updated.emit(moment_results)
		return

	for level in levels_data["levels"]:
		if level["id"] == level_id:
			current_level = level
			budget = level["starting_budget"]
			moments = level.get("moments", [])
			moment_results = {}
			moment_verified = {}
			moment_zone_ok = {}
			moment_sightline_ok = {}
			comfort_pct = 100.0
			required_functions = level["tenant"]["required_functions"].duplicate()
			zone_separations   = (level.get("tenant", {}) as Dictionary).get("zone_separations", []).duplicate(true) as Array
			sightline_requirements = (level.get("tenant", {}) as Dictionary).get("sightline_requirements", []).duplicate(true) as Array
			sightline_ok = true
			external_restrictions = (level.get("external_zone", {}) as Dictionary).duplicate(true)
			external_zone_ok = true
			fulfilled_functions = []
			current_zones = []
			allowed_furniture  = (level.get("allowed_furniture",  []) as Array).duplicate()
			starting_inventory = (level.get("starting_inventory", []) as Array).duplicate(true)
			starting_furniture = (level.get("starting_furniture", []) as Array).duplicate(true)
			budget_changed.emit(budget)
			functions_updated.emit(fulfilled_functions, required_functions)
			if not moments.is_empty():
				moments_updated.emit(moment_results)
			return
	push_error("Level not found: " + level_id)


# Next level in the same authored order as CityMap/levels.json — but only if
# the player already owns it. A locked level still needs to be bought from
# CityMap first, so the Results screen's "Next Level" button falls back to
# "no next level" (caller sends the player back to CityMap instead) rather
# than jumping into a level they can't actually play yet.
func get_next_owned_level_id(current_id: String) -> String:
	var levels := levels_data.get("levels", []) as Array
	var idx := -1
	for i in range(levels.size()):
		if (levels[i] as Dictionary).get("id", "") == current_id:
			idx = i
			break
	if idx == -1 or idx + 1 >= levels.size():
		return ""
	var next_id := (levels[idx + 1] as Dictionary).get("id", "") as String
	return next_id if GameState.is_owned(next_id) else ""


func get_furniture_by_id(furniture_id: String) -> Dictionary:
	for f in furniture_data["furniture"]:
		if f["id"] == furniture_id:
			return f
	return {}


func buy_furniture(furniture_id: String) -> bool:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty() or budget < f["buy_price"]:
		return false
	var forbidden := external_restrictions.get("forbidden_functions", []) as Array
	if not forbidden.is_empty():
		for fn in (f.get("functions", []) as Array):
			if fn in forbidden:
				return false
	budget -= f["buy_price"]
	budget_changed.emit(budget)
	return true


func spend(amount: int) -> void:
	budget -= amount
	budget_changed.emit(budget)


func sell_furniture(furniture_id: String) -> void:
	var f := get_furniture_by_id(furniture_id)
	if f.is_empty():
		return
	budget += f["buy_price"]
	budget_changed.emit(budget)


# Consume one starting-inventory item and return its data (or {} if unavailable).
# Called when the player places or sells a starting-inventory item.
func consume_starting_item(furniture_id: String) -> Dictionary:
	for i in range(starting_inventory.size()):
		var e := starting_inventory[i] as Dictionary
		if e["id"] == furniture_id:
			e["count"] = (e["count"] as int) - 1
			if (e["count"] as int) <= 0:
				starting_inventory.remove_at(i)
			return get_furniture_by_id(furniture_id)
	return {}


# Sell one starting-inventory item: remove it and credit sell_price to budget.
func sell_starting_item(furniture_id: String) -> bool:
	var f := consume_starting_item(furniture_id)
	if f.is_empty():
		return false
	budget += f.get("sell_price", f.get("buy_price", 0)) as int
	budget_changed.emit(budget)
	return true


# entry is either a live Furniture node (floor items — reflects its REAL
# fold state) or a plain furniture-id String (wall items, which don't fold).
# moment_id selects WHICH moment's stored fold state to read for foldable
# furniture; "" means "whatever is currently displayed" (used outside moments).
func _functions_of(entry, moment_id: String = "") -> Array:
	if entry is Furniture:
		var fur := entry as Furniture
		# Noise coupling (see Furniture.gd's is_noisy/needs_quiet/_noise_muted
		# comments) — a bed too close to a noisy neighbor (inside a box, from
		# the parent's furniture around it; or in the parent, from a noisy
		# box's own interior) simply stops contributing its functions until
		# it's no longer near the source.
		if fur.needs_quiet and fur._noise_muted:
			return []
		if moment_id != "":
			return fur.functions_for_moment(moment_id)
		return fur.functions
	var f := get_furniture_by_id(entry as String)
	return (f.get("functions", []) as Array) if not f.is_empty() else []


# Comfort for a given moment (or the single global layout when moment_id is
# "") — 100 minus COMFORT_COST_PER_ITEM for every yellow-tier piece currently
# sitting away from its authored home position. get_moment_position() already
# degrades to the plain shared grid_pos when moment_id is "" or the piece has
# no per-moment entry, so this needs no separate no-moments branch.
func compute_comfort(placed_furniture: Array, moment_id: String) -> float:
	var pct := 100.0
	for entry in placed_furniture:
		if not (entry is Furniture):
			continue
		var fur := entry as Furniture
		if fur.mobility_tier != "yellow":
			continue
		if fur._home_grid_pos == Vector2(-1, -1):
			continue   # never had a home recorded — don't penalize
		if fur.get_moment_position(moment_id) != fur._home_grid_pos:
			pct -= COMFORT_COST_PER_ITEM
	return clampf(pct, 0.0, 100.0)


# Called by Main._refresh_functions() right after `moment_id`'s furniture has
# been repositioned into place (see Furniture.set_moment_view()) — the one
# instant a level-wide geometry check (zone separations, sightlines) is
# actually valid for THAT specific moment, not whichever one happened to be
# on screen last. Sticky, same as moment_verified.
func record_moment_geometry(moment_id: String) -> void:
	if moment_id == "":
		return
	if check_zone_separations():
		moment_zone_ok[moment_id] = true
	if sightline_ok:
		moment_sightline_ok[moment_id] = true


func update_functions(placed_furniture: Array, extra_functions: Array = [], active_moment_id: String = "",
		free_tiles_by_moment: Dictionary = {}, free_window_tiles_by_moment: Dictionary = {}) -> void:
	fulfilled_functions = []
	for entry in placed_furniture:
		for fn in _functions_of(entry, active_moment_id):
			if fn not in fulfilled_functions:
				fulfilled_functions.append(fn)
	for fn in extra_functions:
		if fn not in fulfilled_functions:
			fulfilled_functions.append(fn)

	if moments.is_empty():
		comfort_pct = compute_comfort(placed_furniture, "")

	if not moments.is_empty():
		moment_results.clear()
		# Each moment keeps its OWN fold state per piece of furniture (a sofa
		# bed can be folded for Day and unfolded for Night at the same time) —
		# so recompute what's fulfilled separately for every moment, reading
		# THAT moment's stored state, not whichever one is on screen.
		for m in moments:
			var mid     := m["id"]    as String
			var m_needs := m["needs"] as Array
			var m_fulfilled: Array = []
			for entry in placed_furniture:
				for fn in _functions_of(entry, mid):
					if fn not in m_fulfilled:
						m_fulfilled.append(fn)
			for fn in extra_functions:
				if fn not in m_fulfilled:
					m_fulfilled.append(fn)
			# Space needs: a function satisfied by leaving enough floor open
			# (e.g. "sport") rather than by any piece of furniture — checked
			# against this moment's own free-tile count (folded pieces free
			# up more room than unfolded ones).
			var space_needs := m.get("space_needs", {}) as Dictionary
			if not space_needs.is_empty():
				var free        := free_tiles_by_moment.get(mid, 0) as int
				var free_window := free_window_tiles_by_moment.get(mid, 0) as int
				for fn in space_needs:
					var need_val = space_needs[fn]
					var min_free: int
					var near_window := false
					# Backward-compatible: a plain int means "N free tiles
					# anywhere" (e.g. "sport"); a dict opts into requiring
					# those free tiles be near a window (e.g. "ventilation",
					# "light" — a clear tile in a windowless closet shouldn't count).
					if need_val is Dictionary:
						min_free    = (need_val as Dictionary).get("min_free", 0) as int
						near_window = (need_val as Dictionary).get("near_window", false) as bool
					else:
						min_free = need_val as int
					var available := free_window if near_window else free
					if available >= min_free and fn not in m_fulfilled:
						m_fulfilled.append(fn)
			var currently_met := true
			for need in m_needs:
				if need not in m_fulfilled:
					currently_met = false
					break
			var m_comfort := compute_comfort(placed_furniture, mid)
			if mid == active_moment_id:
				comfort_pct = m_comfort
			if currently_met and m_comfort >= COMFORT_WARN_THRESHOLD:
				moment_verified[mid] = true
			moment_results[mid] = {
				"fulfilled": m_fulfilled,
				"required": m_needs,
				"verified": moment_verified.get(mid, false),
				"comfort": m_comfort,
			}
		moments_updated.emit(moment_results)

	functions_updated.emit(fulfilled_functions, required_functions)


func update_zones(zones: Array) -> void:
	current_zones = zones


# Checks the "min_boundary_distance" side of external_restrictions: any piece
# providing a restricted function must sit far enough from the outer wall.
# Called alongside update_functions/update_sightlines from Main.gd's
# _refresh_functions(), which has both the live Furniture list and Floor ref.
func update_external_zone(apt_floor, placed_furniture: Array, active_moment_id: String) -> void:
	var min_dist := external_restrictions.get("min_boundary_distance", {}) as Dictionary
	if min_dist.is_empty():
		external_zone_ok = true
		return
	for entry in placed_furniture:
		if not (entry is Furniture):
			continue
		var fur := entry as Furniture
		for fn in _functions_of(fur, active_moment_id):
			if not min_dist.has(fn):
				continue
			var need := min_dist[fn] as int
			for t in fur.get_occupied_tiles_for_moment(active_moment_id):
				if apt_floor.min_distance_to_wall(t) < need:
					external_zone_ok = false
					return
	external_zone_ok = true


# Re-evaluates every sightline_requirements entry against the live floor
# layout. Called from Main.gd's _refresh_functions() (the only place holding
# a real Floor reference) every time furniture changes.
func update_sightlines(apt_floor) -> void:
	if sightline_requirements.is_empty():
		sightline_ok = true
		return
	for req in sightline_requirements:
		var r := req as Dictionary
		var from_arr := r.get("from", [0, 0]) as Array
		var to_arr   := r.get("to",   [0, 0]) as Array
		var from_tile := Vector2i(from_arr[0] as int, from_arr[1] as int)
		var to_tile   := Vector2i(to_arr[0]   as int, to_arr[1]   as int)
		var clear: bool = apt_floor.has_sightline(from_tile, to_tile)
		var must_be_clear := r.get("must_be_clear", true) as bool
		if clear != must_be_clear:
			sightline_ok = false
			return
	sightline_ok = true


func _zone_fns_for_moment(zone: Dictionary, m_needs: Array) -> Array:
	var fns: Array = []
	for fid in zone.get("furniture_ids", []) as Array:
		var fd := get_furniture_by_id(fid)
		if fd.is_empty():
			continue
		var use_fns: Array
		var has_states: bool = not (fd.get("folded_functions", []) as Array).is_empty()
		if fd.get("foldable", false) and has_states:
			var ext_funcs := fd.get("extended_functions", []) as Array
			var fld_funcs := fd.get("folded_functions",   []) as Array
			var use_ext   := ext_funcs.any(func(fn): return fn in m_needs)
			use_fns = ext_funcs if use_ext else fld_funcs
		else:
			use_fns = fd.get("functions", []) as Array
		for fn in use_fns:
			if fn not in fns:
				fns.append(fn)
	return fns


func check_zone_separations() -> bool:
	if zone_separations.is_empty():
		return true
	# Build list of (moment_needs) to check — one entry per moment, or a single empty entry if no moments
	var needs_list: Array = []
	if moments.is_empty():
		needs_list.append([])  # no moment filtering
	else:
		for m in moments:
			needs_list.append((m as Dictionary).get("needs", []) as Array)

	for sep in zone_separations:
		var group_a := sep[0] as Array
		var group_b := sep[1] as Array
		for m_needs in needs_list:
			for zone in current_zones:
				var z_fns := _zone_fns_for_moment(zone as Dictionary, m_needs) \
					if not (m_needs as Array).is_empty() \
					else (zone as Dictionary).get("functions", []) as Array
				var has_a := group_a.any(func(fn): return fn in z_fns)
				var has_b := group_b.any(func(fn): return fn in z_fns)
				if has_a and has_b:
					return false
	return true


func check_win() -> bool:
	if not external_zone_ok:
		return false
	if moments.is_empty():
		if not check_zone_separations():
			return false
		if not sightline_ok:
			return false
		for req in required_functions:
			if req not in fulfilled_functions:
				return false
		return true
	# Each moment must have been genuinely satisfied at some point — the player
	# actually set the furniture correctly for it (folded for Day, unfolded for
	# Night, etc), with zone separations and sightlines ALSO valid for that
	# moment's own arrangement (see record_moment_geometry() — a movable-tier
	# piece can sit in a different zone per moment, so a single global check
	# can't stand in for every moment the way it can when there are none).
	# Since a shared foldable/movable piece can't be in two states at once,
	# this checks "was ever verified", not "is true right now".
	for m in moments:
		var mid := m["id"] as String
		if not moment_verified.get(mid, false):
			return false
		if not moment_zone_ok.get(mid, false):
			return false
		if not moment_sightline_ok.get(mid, false):
			return false
	return true


func calculate_stars() -> int:
	var starting := current_level.get("starting_budget", 1) as int
	if starting <= 0:
		return 1
	var pct := float(budget) / float(starting)
	if pct >= 0.40:
		return 3
	elif pct >= 0.15:
		return 2
	else:
		return 1


func get_funds_reward() -> int:
	var base := current_level.get("funds_base_reward", 0) as int
	var bonus := int(budget * 0.20)
	return base + bonus
