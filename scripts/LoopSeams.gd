class_name LoopSeams
extends RefCounted

# Looped apartments (docs/design_recursive_apartments.md §2): openings in a
# flat's outer wall that lead back into the same flat. Walk out of the west
# wall, come in through the east one.
#
# A floor's level data says which openings are joined:
#
#   "loop": {"pairs": [
#       {"a": "west", "b": "east"},                          # a whole side: a torus
#       {"a": {"side": "north", "from": 6, "to": 16},        # a door-sized span...
#        "b": {"side": "south", "from": 20, "to": 30}}       # ...leads to another
#   ]}
#
# `from`/`to` are absolute tile coordinates along the wall, `to` exclusive,
# and both spans of a pair are the same length. A pair always joins OPPOSITE
# walls (west-east or north-south), so crossing a seam is a plain
# translation: nothing turns, and a piece of furniture can stand across it.
#
# The room's interior runs from the tile after the west wall to the tile
# before the east wall (the walls are one tile thick, see Floor.is_floor_tile),
# so stepping west off the first interior column lands on the last one: the
# seam has no thickness. The wall tiles of a seam are never visited, so the
# rest of the code can keep treating them as wall.

const MAX_WRAPS := 8          # a tile or rect is wrapped at most this many times
const MAX_PARTS := 24         # a rect is cut into at most this many parts

var seams: Array = []         # [{axis, lo_from, lo_to, hi_from, hi_to, shift: Vector2i}]
var bounds := Rect2i()        # the room's walls: position = west/north wall line, end = east/south
var raw: Dictionary = {}      # the level data this was built from, for saving it back


static func from_data(data: Variant, room: Rect2i) -> LoopSeams:
	if not (data is Dictionary) or ((data as Dictionary).get("pairs", []) as Array).is_empty():
		return null
	var out := LoopSeams.new()
	out.raw = (data as Dictionary).duplicate(true)
	out.bounds = room
	for p in (data as Dictionary).get("pairs", []) as Array:
		var seam := out._parse_pair(p)
		if not seam.is_empty():
			out.seams.append(seam)
	return out if not out.seams.is_empty() else null


func is_empty() -> bool:
	return seams.is_empty()


# Interior extent: first and one-past-last interior tile on each axis.
func lo_edge(axis: int) -> int:
	return (bounds.position.x if axis == 0 else bounds.position.y) + 1


func hi_edge(axis: int) -> int:
	return bounds.end.x if axis == 0 else bounds.end.y


# How far round the loop is on this axis, in tiles.
func period(axis: int) -> int:
	return hi_edge(axis) - lo_edge(axis)


func _side_axis(side: String) -> int:
	return 0 if side in ["west", "east"] else 1


func _full_span(side: String) -> Vector2i:
	var axis := _side_axis(side)
	return Vector2i(lo_edge(1 - axis), hi_edge(1 - axis))


func _parse_end(e: Variant) -> Dictionary:
	if e is String:
		var sp := _full_span(e as String)
		return {"side": e, "from": sp.x, "to": sp.y}
	if e is Dictionary:
		var d := e as Dictionary
		var side := d.get("side", "") as String
		if side not in ["north", "east", "south", "west"]:
			return {}
		var sp := _full_span(side)
		return {"side": side, "from": int(d.get("from", sp.x)), "to": int(d.get("to", sp.y))}
	return {}


func _parse_pair(p: Variant) -> Dictionary:
	if not (p is Dictionary):
		return {}
	var a := _parse_end((p as Dictionary).get("a"))
	var b := _parse_end((p as Dictionary).get("b"))
	if a.is_empty() or b.is_empty():
		push_warning("Loop pair %s: each end needs a side" % str(p))
		return {}
	var opposite := {"west": "east", "east": "west", "north": "south", "south": "north"}
	if opposite[a["side"]] != b["side"]:
		push_warning("Loop pair %s: only opposite walls can be joined" % str(p))
		return {}
	if (a["to"] as int) - (a["from"] as int) != (b["to"] as int) - (b["from"] as int) or (a["to"] as int) <= (a["from"] as int):
		push_warning("Loop pair %s: both openings must be the same length" % str(p))
		return {}
	var lo := a if a["side"] in ["west", "north"] else b
	var hi := b if lo == a else a
	var axis := _side_axis(a["side"] as String)
	var d := (hi["from"] as int) - (lo["from"] as int)
	return {
		"axis": axis,
		"lo_from": lo["from"], "lo_to": lo["to"],
		"hi_from": hi["from"], "hi_to": hi["to"],
		# Added to a tile that has gone out past the low (west/north) wall.
		"shift": Vector2i(period(0), d) if axis == 0 else Vector2i(d, period(1)),
	}


# The one tile inside the room that `t` is, once every seam it has gone
# through is followed. A tile past a wall where there is no seam stays where
# it is (outside the room, or in the wall).
func wrap_tile(t: Vector2i) -> Vector2i:
	for _i in MAX_WRAPS:
		var moved := false
		for s in seams:
			var ax: int = s["axis"]
			var along := t.x if ax == 0 else t.y
			var across := t.y if ax == 0 else t.x
			if along < lo_edge(ax) and across >= (s["lo_from"] as int) and across < (s["lo_to"] as int):
				t += s["shift"] as Vector2i
				moved = true
			elif along >= hi_edge(ax) and across >= (s["hi_from"] as int) and across < (s["hi_to"] as int):
				t -= s["shift"] as Vector2i
				moved = true
		if not moved:
			break
	return t


# wrap_tile() for a point on the plan (a piece's corner), keeping its
# fraction of a tile.
func wrap_point(p: Vector2) -> Vector2:
	var t := Vector2i(floori(p.x), floori(p.y))
	var w := wrap_tile(t)
	return p + Vector2(w - t)


# A rect (in tiles) cut where it crosses seams, each part moved to where it
# really is: [{rect: Rect2, shift: Vector2}] (shift = how far that part was
# moved). A rect that crosses no seam comes back whole with no shift. A part
# that sticks out past a wall only partly inside an opening is left where it
# is, so it reads as outside the room / in the wall.
func split_rect(r: Rect2) -> Array:
	var out: Array = []
	var todo: Array = [[r, Vector2.ZERO]]
	while not todo.is_empty() and out.size() + todo.size() <= MAX_PARTS:
		var item: Array = todo.pop_back()
		var cur: Rect2 = item[0]
		var acc: Vector2 = item[1]
		var cut := false
		for s in seams:
			var ax: int = s["axis"]
			var a0 := cur.position.x if ax == 0 else cur.position.y
			var a1 := cur.end.x if ax == 0 else cur.end.y
			var c0 := cur.position.y if ax == 0 else cur.position.x
			var c1 := cur.end.y if ax == 0 else cur.end.x
			var shift := Vector2(s["shift"] as Vector2i)
			var lo := float(lo_edge(ax))
			var hi := float(hi_edge(ax))
			if a0 < lo - 0.0001 and c0 >= float(s["lo_from"]) - 0.0001 and c1 <= float(s["lo_to"]) + 0.0001:
				var parts := _cut(cur, ax, lo)
				# parts[0] is past the cut (outside), parts[-1] inside.
				var out_part: Rect2 = parts[0]
				todo.append([Rect2(out_part.position + shift, out_part.size), acc + shift])
				if parts.size() > 1:
					todo.append([parts[1], acc])
				cut = true
				break
			if a1 > hi + 0.0001 and c0 >= float(s["hi_from"]) - 0.0001 and c1 <= float(s["hi_to"]) + 0.0001:
				var parts := _cut(cur, ax, hi)
				# parts[0] is below the cut (inside), parts[-1] past it.
				var past: Rect2 = parts[-1]
				todo.append([Rect2(past.position - shift, past.size), acc - shift])
				if parts.size() > 1:
					todo.append([parts[0], acc])
				cut = true
				break
		if not cut:
			out.append({"rect": cur, "shift": acc})
	return out


# `r` cut at `at` along axis `ax`: [below] / [below, above] / [above].
func _cut(r: Rect2, ax: int, at: float) -> Array:
	var a0 := r.position.x if ax == 0 else r.position.y
	var a1 := r.end.x if ax == 0 else r.end.y
	if at <= a0 or at >= a1:
		return [r]
	if ax == 0:
		return [Rect2(r.position.x, r.position.y, at - a0, r.size.y), Rect2(at, r.position.y, a1 - at, r.size.y)]
	return [Rect2(r.position.x, r.position.y, r.size.x, at - a0), Rect2(r.position.x, at, r.size.x, a1 - at)]


# True when the parts of a cut rect overlap each other: a piece longer than
# the loop runs into its own tail.
static func parts_overlap(parts: Array) -> bool:
	for i in parts.size():
		for j in range(i + 1, parts.size()):
			var a: Rect2 = parts[i]["rect"]
			var b: Rect2 = parts[j]["rect"]
			var x := a.intersection(b)
			if x.size.x > 0.0001 and x.size.y > 0.0001:
				return true
	return false


# Where else `t` shows up as seen from inside: `t` moved once round each seam
# either way, and round two seams at once. Used for lines of sight that go
# the long way round.
func images_of(t: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [t]
	for s in seams:
		var sh := s["shift"] as Vector2i
		var more: Array[Vector2i] = []
		for img in out:
			more.append(img + sh)
			more.append(img - sh)
		out.append_array(more)
	return out


# The seams as lines on the plan, both openings of each, for drawing:
# [{side, from, to, pair: int}] in tile coordinates along the wall.
func openings() -> Array:
	var out: Array = []
	for i in seams.size():
		var s: Dictionary = seams[i]
		var ax: int = s["axis"]
		out.append({"side": "west" if ax == 0 else "north", "from": s["lo_from"], "to": s["lo_to"], "pair": i})
		out.append({"side": "east" if ax == 0 else "south", "from": s["hi_from"], "to": s["hi_to"], "pair": i})
	return out


# Whether the wall tile `t` (on the room's outer wall line) is part of an
# opening.
func is_opening_tile(t: Vector2i) -> bool:
	for o in openings():
		var side := o["side"] as String
		var along := t.y if side in ["west", "east"] else t.x
		var line := 0
		match side:
			"west": line = bounds.position.x
			"east": line = bounds.end.x
			"north": line = bounds.position.y
			"south": line = bounds.end.y
		var fixed := t.x if side in ["west", "east"] else t.y
		if fixed == line and along >= (o["from"] as int) and along < (o["to"] as int):
			return true
	return false


# Which outer walls are entirely seams (a fully looped side has no outside).
func looped_sides() -> Array:
	var out: Array = []
	for o in openings():
		var sp := _full_span(o["side"] as String)
		if (o["from"] as int) <= sp.x and (o["to"] as int) >= sp.y:
			out.append(o["side"])
	return out


# Patch-to-patch links across the seams for a walker who needs a `size` x
# `size` patch of floor (Floor.WALK_WIDTH): a patch flush against an opening
# leads to the patch flush against the other one. {Vector2i: [Vector2i]}
# keyed by patch top-left tile.
func patch_links(size: int) -> Dictionary:
	var out: Dictionary = {}
	for s in seams:
		var ax: int = s["axis"]
		var d := (s["hi_from"] as int) - (s["lo_from"] as int)
		var lo_a := lo_edge(ax)
		var hi_a := hi_edge(ax) - size
		for c in range(s["lo_from"] as int, (s["lo_to"] as int) - size + 1):
			var a := Vector2i(lo_a, c) if ax == 0 else Vector2i(c, lo_a)
			var b := Vector2i(hi_a, c + d) if ax == 0 else Vector2i(c + d, hi_a)
			if not out.has(a): out[a] = []
			if not out.has(b): out[b] = []
			(out[a] as Array).append(b)
			(out[b] as Array).append(a)
	return out
