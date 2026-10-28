class_name RuleOverlay
extends Node2D

# Draws the level's lines of sight on the floor plan, above the furniture.
#
# Each line runs from an eye (who is looking) to a target (what they look
# at) and carries the same number as its chip in the needs bar.
#   - green: the rule is met; red: it is not.
#   - solid: the line has to stay clear; dashed: the line has to be blocked.
#   - a cross marks whatever is blocking it.
# Fed by Floor.set_sight_lines() with GameManager.sightline_status.

const TILE := 8.0   # Floor.TILE_SIZE
const OK_COLOR  := Color(0.30, 0.86, 0.50)
const BAD_COLOR := Color(0.98, 0.36, 0.32)

var lines: Array = []
var zones: Array = []
var zone_status: Array = []

# Tints for the zones of a level that has a zone rule: red for a zone that
# breaks one, otherwise a calm colour per zone so neighbours read apart.
const ZONE_TINTS := [Color(0.36, 0.56, 0.86), Color(0.36, 0.74, 0.52), Color(0.80, 0.70, 0.30), Color(0.62, 0.48, 0.82)]

static func zone_color(index: int, conflict: bool) -> Color:
	if conflict:
		return Color(0.95, 0.30, 0.26, 0.26)
	var c: Color = ZONE_TINTS[index % ZONE_TINTS.size()]
	return Color(c.r, c.g, c.b, 0.20)


# Middle of a zone, in tiles.
static func zone_center(zone: Dictionary) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for tile in zone.get("tiles", {}) as Dictionary:
		sum += Vector2(tile as Vector2i)
		n += 1
	return (sum / float(n) + Vector2(0.5, 0.5)) if n > 0 else Vector2.ZERO


func set_zones(new_zones: Array, status: Array) -> void:
	zones = new_zones
	zone_status = status
	queue_redraw()


func set_lines(status: Array) -> void:
	lines = status
	queue_redraw()


# While a piece is carried: where it can't go (Floor.carry_hints()). Other
# pieces' clearance as soft amber zones, flooring it can't stand on and a
# ceiling too low for it as red hatching, and the loft's load with what the
# piece would add.
const NO_GO := Color(0.93, 0.30, 0.24)
const CLEARANCE := Color(0.98, 0.78, 0.30)
var carry_hints: Dictionary = {}
var _no_go_runs: Array = []     # [Rect2] in pixels, tile runs merged per row
var _low_runs: Array = []

func set_carry_hints(hints: Dictionary) -> void:
	carry_hints = hints
	_no_go_runs = _runs(hints.get("bad_floor", []) as Array)
	_low_runs = _runs(hints.get("low_ceiling", []) as Array)
	queue_redraw()


# Tiles as one rect per unbroken run along a row, in pixels.
static func _runs(tiles: Array) -> Array:
	var by_row: Dictionary = {}
	for t in tiles:
		var tv := t as Vector2i
		if not by_row.has(tv.y):
			by_row[tv.y] = []
		(by_row[tv.y] as Array).append(tv.x)
	var out: Array = []
	for y in by_row:
		var xs := by_row[y] as Array
		xs.sort()
		var start: int = xs[0]
		var prev: int = xs[0]
		for i in range(1, xs.size() + 1):
			var x: int = xs[i] if i < xs.size() else prev + 2
			if x != prev + 1:
				out.append(Rect2(Vector2(start, y) * TILE, Vector2(prev - start + 1, 1) * TILE))
				start = x
			prev = x
	return out


func _draw_carry_hints(font: Font) -> void:
	if carry_hints.is_empty():
		return
	# Where a door swings open: a red quarter circle nothing can stand in.
	for s in carry_hints.get("doors", []) as Array:
		var swing := s as Dictionary
		var hinge := (swing["hinge"] as Vector2) * TILE
		var d: Vector2 = swing["dir"]
		var r := (swing["r"] as float) * TILE
		var a0 := atan2(0.0, d.x)
		var a1 := atan2(d.y, 0.0)
		var fan := PackedVector2Array([hinge])
		for i in 13:
			var a := lerp_angle(a0, a1, i / 12.0)
			fan.append(hinge + Vector2(cos(a), sin(a)) * r)
		draw_colored_polygon(fan, Color(NO_GO.r, NO_GO.g, NO_GO.b, 0.20))
		draw_polyline(fan.slice(1), Color(NO_GO.r, NO_GO.g, NO_GO.b, 0.7), 1.5, true)
	# Where others stand in the other moments of the day (unfolded, moved),
	# with their clearance, named by the moment.
	for z in carry_hints.get("moments", []) as Array:
		var zone := z as Dictionary
		var zr := Rect2((zone["rect"] as Rect2).position * TILE, (zone["rect"] as Rect2).size * TILE)
		var mc := Color(0.72, 0.56, 0.98)
		draw_rect(zr, Color(mc.r, mc.g, mc.b, 0.12))
		var c := [zr.position, Vector2(zr.end.x, zr.position.y), zr.end, Vector2(zr.position.x, zr.end.y), zr.position]
		for i in 4:
			draw_dashed_line(c[i], c[i + 1], Color(mc.r, mc.g, mc.b, 0.8), 1.5, 4.0)
		var text := zone["label"] as String
		draw_string_outline(font, zr.position + Vector2(3, 10), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color(0.04, 0.08, 0.14, 0.85))
		draw_string(font, zr.position + Vector2(3, 10), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, mc)
	for r in carry_hints.get("clearance", []) as Array:
		var z := Rect2((r as Rect2).position * TILE, (r as Rect2).size * TILE)
		draw_rect(z, Color(CLEARANCE.r, CLEARANCE.g, CLEARANCE.b, 0.07))
		var c := [z.position, Vector2(z.end.x, z.position.y), z.end, Vector2(z.position.x, z.end.y), z.position]
		for i in 4:
			draw_dashed_line(c[i], c[i + 1], Color(CLEARANCE.r, CLEARANCE.g, CLEARANCE.b, 0.55), 1.2, 3.0)
	for runs in [_no_go_runs, _low_runs]:
		for r in runs:
			draw_rect(r as Rect2, Color(NO_GO.r, NO_GO.g, NO_GO.b, 0.16))
	if not _low_runs.is_empty():
		var area := _low_runs[0] as Rect2
		for r in _low_runs:
			area = area.merge(r as Rect2)
		var text := tr("Ceiling too low here")
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var at := area.get_center() + Vector2(-tw * 0.5, 4)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color(0.04, 0.08, 0.14, 0.85))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, NO_GO)
	var loft := carry_hints.get("loft", {}) as Dictionary
	if not loft.is_empty():
		var tiles := loft["tiles"] as Array
		var area := Rect2(Vector2(tiles[0] as Vector2i) * TILE, Vector2.ONE * TILE)
		for t in tiles:
			area = area.merge(Rect2(Vector2(t as Vector2i) * TILE, Vector2.ONE * TILE))
		var over := (loft["load"] as float) + (loft["weight"] as float) > (loft["max"] as float)
		var col := NO_GO if over else CLEARANCE
		draw_rect(area, col, false, 1.5)
		var text := tr("Loft: %.0f / %.0f, this adds %.0f") % [loft["load"], loft["max"], loft["weight"]]
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		var at := Vector2(area.get_center().x - tw * 0.5, area.position.y + 12)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color(0.04, 0.08, 0.14, 0.85))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)


# Pieces moved away from where they started, costing comfort: a faint dashed
# outline on the old spot, a dashed line from the piece back to it, and what
# it costs, written on the old spot.
const HOME_COLOR := Color(0.98, 0.82, 0.40)
var home_marks: Array = []      # [{home: Vector2 tiles, size: Vector2 tiles, at: Vector2 tiles, cost: String}]

func set_home_marks(marks: Array) -> void:
	if marks == home_marks:
		return
	home_marks = marks
	queue_redraw()


func _draw_home_marks(font: Font) -> void:
	for m in home_marks:
		var mark := m as Dictionary
		var home := Rect2((mark["home"] as Vector2) * TILE, (mark["size"] as Vector2) * TILE)
		var now := Rect2((mark["at"] as Vector2) * TILE, (mark["size"] as Vector2) * TILE)
		var faint := Color(HOME_COLOR.r, HOME_COLOR.g, HOME_COLOR.b, 0.75)
		draw_rect(home, Color(HOME_COLOR.r, HOME_COLOR.g, HOME_COLOR.b, 0.10))
		# What stood there: the piece itself seen from above, faint.
		var icon: Texture2D = Thumb.get_cached_ortho("top", mark.get("id", "") as String)
		if icon:
			var turned := int(mark.get("rot", 0)) % 2 == 1
			draw_set_transform(home.get_center(), PI * 0.5 * int(mark.get("rot", 0)), Vector2.ONE)
			var sz := Vector2(home.size.y, home.size.x) if turned else home.size
			draw_texture_rect(icon, Rect2(-sz * 0.5, sz), false, Color(1, 1, 1, 0.35))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var c := [home.position, Vector2(home.end.x, home.position.y), home.end, Vector2(home.position.x, home.end.y), home.position]
		for i in 4:
			draw_dashed_line(c[i], c[i + 1], faint, 1.5, 4.0)
		draw_dashed_line(now.get_center(), home.get_center(), Color(0.04, 0.08, 0.14, 0.6), 4.0, 6.0)
		draw_dashed_line(now.get_center(), home.get_center(), faint, 1.8, 6.0)
		var lines := (mark["cost"] as String).split("
")
		for li in lines.size():
			var line := lines[li]
			var tw := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			var at := home.get_center() + Vector2(-tw * 0.5, 4 + (li - (lines.size() - 1) * 0.5) * 11)
			draw_string_outline(font, at, line, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color(0.04, 0.08, 0.14, 0.85))
			draw_string(font, at, line, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, HOME_COLOR)


# Outside walls with rules for the boxes nearest them: a plate just outside
# each such wall with its name and what it does, and a dashed line from each
# box to the wall it takes those rules from.
const OUTSIDE_COLOR := Color(0.98, 0.78, 0.36)
var outside_walls: Array = []   # [{side, name, rules}]
var box_links: Array = []       # [{from: Vector2 tiles, side, held}]
var room: Rect2i = Rect2i()

func set_outside(walls: Array, links: Array, bounds: Rect2i) -> void:
	if walls == outside_walls and links == box_links and bounds == room:
		return
	outside_walls = walls
	box_links = links
	room = bounds
	queue_redraw()


# Middle of a wall of the room, in plan pixels, and which way is out.
func _wall_mid(side: String) -> Array:
	var r := Rect2(Vector2(room.position) * TILE, Vector2(room.size) * TILE)
	match side:
		"north": return [Vector2(r.get_center().x, r.position.y), Vector2.UP]
		"south": return [Vector2(r.get_center().x, r.end.y), Vector2.DOWN]
		"east":  return [Vector2(r.end.x, r.get_center().y), Vector2.RIGHT]
	return [Vector2(r.position.x, r.get_center().y), Vector2.LEFT]


func _draw_outside(font: Font) -> void:
	var r := Rect2(Vector2(room.position) * TILE, Vector2(room.size) * TILE)
	for l in box_links:
		var link := l as Dictionary
		var from := (link["from"] as Vector2) * TILE
		var side := link["side"] as String
		var to := Vector2(from.x, r.position.y) if side == "north" else Vector2(from.x, r.end.y) if side == "south" \
			else Vector2(r.end.x, from.y) if side == "east" else Vector2(r.position.x, from.y)
		var w := 2.5 if link["held"] else 1.5
		draw_dashed_line(from, to, Color(0.04, 0.08, 0.14, 0.7), w + 2.5, 6.0)
		draw_dashed_line(from, to, OUTSIDE_COLOR, w, 6.0)
		draw_circle(to, 3.5, OUTSIDE_COLOR)
	for wl in outside_walls:
		var wall := wl as Dictionary
		var mid: Array = _wall_mid(wall["side"] as String)
		var at: Vector2 = mid[0]
		var out: Vector2 = mid[1]
		var title := wall["name"] as String
		var rules := wall["rules"] as String
		var tw := maxf(font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x,
			font.get_string_size(rules, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x)
		# Turned along a side wall, so it lies alongside it like the others.
		var angle := 0.0 if out.y != 0.0 else (-PI * 0.5 if out.x < 0.0 else PI * 0.5)
		# Just inside the wall: outside it, the plan's edges and the screen's
		# bars cut it off.
		draw_set_transform(at - out * 15.0, angle, Vector2.ONE)
		var plate := Rect2(Vector2(-tw * 0.5 - 4, -11), Vector2(tw + 8, 22))
		draw_rect(plate, Color(0.04, 0.08, 0.14, 0.62))
		draw_rect(plate, Color(OUTSIDE_COLOR.r, OUTSIDE_COLOR.g, OUTSIDE_COLOR.b, 0.7), false, 1.0)
		draw_string(font, Vector2(-tw * 0.5, -1), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, OUTSIDE_COLOR)
		draw_string(font, Vector2(-tw * 0.5, 8), rules, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.92, 0.94, 1.0))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _center(tile: Vector2i) -> Vector2:
	return (Vector2(tile) + Vector2(0.5, 0.5)) * TILE


# _center() for a point given in tiles that need not be whole.
func _pt(tile: Vector2) -> Vector2:
	return (tile + Vector2(0.5, 0.5)) * TILE


func _draw() -> void:
	var font := ThemeDB.fallback_font
	_draw_carry_hints(font)
	_draw_home_marks(font)
	_draw_outside(font)
	# Zone name plates: what each zone holds, and a warning on one that
	# holds two things that must be apart.
	for zi in mini(zones.size(), zone_status.size()):
		var st := zone_status[zi] as Dictionary
		var text := st["label"] as String
		if text == "":
			continue
		var conflict := st["conflict"] as bool
		if conflict:
			text = "\ueb55 " + text
		var at := RuleOverlay.zone_center(zones[zi] as Dictionary) * TILE
		var tsz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		var plate := Rect2(at - Vector2(tsz.x * 0.5 + 6, 10), Vector2(tsz.x + 12, 18))
		draw_rect(plate, Color(0.04, 0.08, 0.14, 0.82))
		draw_rect(plate, BAD_COLOR if conflict else Color(0.75, 0.86, 0.96, 0.8), false, 1.0)
		draw_string(font, at + Vector2(-tsz.x * 0.5, 3.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			BAD_COLOR if conflict else Color(0.90, 0.95, 1.0))
	for i in lines.size():
		var s := lines[i] as Dictionary
		var from := _center(s["from"])
		var to := _center(s["to"])
		var col: Color = OK_COLOR if (s["ok"] as bool) else BAD_COLOR
		var halo := Color(0.04, 0.08, 0.14, 0.75)
		var must_clear := s["must_be_clear"] as bool
		# What the eye actually sees: as far as the first thing in the way.
		var seen_to := to
		if s["block"] != null:
			seen_to = _center(s["block"])
		var route := s.get("route", []) as Array
		if not route.is_empty():
			# Seen the long way round a looped flat: each stretch, out through
			# one seam and in through the other, with a dot where it passes.
			for leg in route:
				var a := _pt(leg[0])
				var b := _pt(leg[1])
				if must_clear:
					draw_line(a, b, halo, 5.0)
					draw_line(a, b, col, 2.5)
				else:
					draw_dashed_line(a, b, halo, 5.0, 7.0)
					draw_dashed_line(a, b, col, 2.5, 7.0)
			for li in range(1, route.size()):
				draw_circle(_pt(route[li][0]), 3.5, halo)
				draw_circle(_pt(route[li][0]), 2.2, col)
				draw_circle(_pt(route[li - 1][1]), 3.5, halo)
				draw_circle(_pt(route[li - 1][1]), 2.2, col)
		elif must_clear:
			draw_line(from, seen_to, halo, 5.0)
			draw_line(from, seen_to, col, 2.5)
		else:
			draw_dashed_line(from, seen_to, halo, 5.0, 7.0)
			draw_dashed_line(from, seen_to, col, 2.5, 7.0)
		if s["block"] != null:
			# The part that is cut off, faint, and a cross on what cuts it.
			draw_dashed_line(seen_to, to, Color(col.r, col.g, col.b, 0.35), 1.5, 4.0)
			var x := 5.0
			for d in [Vector2(x, x), Vector2(x, -x)]:
				draw_line(seen_to - d, seen_to + d, halo, 5.0)
				draw_line(seen_to - d, seen_to + d, col, 2.5)
		# Target: a ring.
		draw_circle(to, 6.5, halo)
		draw_arc(to, 5.0, 0.0, TAU, 20, col, 2.0)
		draw_circle(to, 1.6, col)
		# Eye: a filled disc with the line's number.
		draw_circle(from, 8.5, halo)
		draw_circle(from, 7.0, col)
		var label := str(i + 1)
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
		draw_string(font, from + Vector2(-sz.x * 0.5, 3.5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.05, 0.10, 0.08))
