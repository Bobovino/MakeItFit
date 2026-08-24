extends Control
class_name CategoryWheel

# Sims-style radial category picker — navigation only, never places a specific
# item. Wedges = Inventory.SUB_CATEGORIES (minus "All", which lives on the
# center hub instead) plus one small Builder wedge. Main.gd owns sizing
# (offset_left/top/right/bottom) and centers this square Control over the
# play area; all geometry below is derived from `size` so it adapts to
# whatever square Main gives it instead of hardcoding pixel radii.

signal category_chosen(id: String)
signal cancelled

const HOVER_GROW := 6.0
const BUILDER_ID := "Builder"

var _wedges: Array = []   # [{id, glyph, start, end}]
var _hover_index: int = -1
var _hub_hover: bool = false
var _hub_label: String = "All"   # shows the hovered wedge's name — glyphs alone (esp. Transformable's 🔀) aren't identifiable without it


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_wedges()
	resized.connect(queue_redraw)


func _build_wedges() -> void:
	var main_cats: Array = Inventory.SUB_CATEGORIES.filter(func(s): return s != "All")
	var n := main_cats.size()
	# Builder gets half the angular width of a normal category wedge, per
	# design direction ("una cuña builder pero muy pequeña").
	var unit := TAU / (n as float + 0.5)
	var start := -PI / 2.0
	_wedges.clear()
	for cat in main_cats:
		_wedges.append({
			"id": cat, "glyph": Inventory.SUB_CATEGORY_GLYPH.get(cat, "?"),
			"start": start, "end": start + unit,
		})
		start += unit
	_wedges.append({
		"id": BUILDER_ID, "glyph": "🛠",
		"start": start, "end": start + unit * 0.5,
	})


func _outer_radius() -> float:
	return minf(size.x, size.y) * 0.5 - 20.0


func _inner_radius() -> float:
	return _outer_radius() * 0.32


func _draw() -> void:
	var center := size * 0.5
	var inner_r := _inner_radius()
	var outer_r := _outer_radius()
	for i in _wedges.size():
		var w: Dictionary = _wedges[i]
		var hovered := (i == _hover_index)
		var wedge_outer := outer_r + (HOVER_GROW if hovered else 0.0)
		var pts := PackedVector2Array()
		var steps := 20
		for s in steps + 1:
			var a: float = lerp(w["start"] as float, w["end"] as float, float(s) / steps)
			pts.append(center + Vector2(inner_r, 0).rotated(a))
		for s in steps + 1:
			var a: float = lerp(w["end"] as float, w["start"] as float, float(s) / steps)
			pts.append(center + Vector2(wedge_outer, 0).rotated(a))
		var col: Color = GameTheme.C_AMBER if hovered else Color(0.30, 0.26, 0.16, 0.95)
		draw_colored_polygon(pts, col)
		var outline := pts.duplicate()
		outline.append(outline[0])
		draw_polyline(outline, Color(0, 0, 0, 0.55), 2.0, true)

		var mid_a: float = ((w["start"] as float) + (w["end"] as float)) * 0.5
		var mid_r := (inner_r + wedge_outer) * 0.5
		var gp := center + Vector2(mid_r, 0).rotated(mid_a)
		var font := ThemeDB.fallback_font
		var fsize := 22 if (w["id"] as String) != BUILDER_ID else 14
		var txt := w["glyph"] as String
		var txt_size := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
		draw_string(font, gp - txt_size * 0.5 + Vector2(0, txt_size.y * 0.35), txt,
			HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)

	var hub_col: Color = GameTheme.C_AMBER if _hub_hover else Color(0.20, 0.18, 0.12, 0.95)
	draw_circle(center, inner_r, hub_col)
	draw_arc(center, inner_r, 0, TAU, 32, Color(0, 0, 0, 0.55), 2.0, true)
	var hub_font := ThemeDB.fallback_font
	# Longer names ("Transformable") need a smaller size to fit the hub's fixed
	# diameter than short ones ("All", "Living") do.
	var hub_fsize: int = clampi(int(13.0 * 6.0 / maxf(_hub_label.length(), 6.0)), 8, 13)
	var hub_size := hub_font.get_string_size(_hub_label, HORIZONTAL_ALIGNMENT_CENTER, -1, hub_fsize)
	draw_string(hub_font, center - hub_size * 0.5 + Vector2(0, hub_size.y * 0.35), _hub_label,
		HORIZONTAL_ALIGNMENT_CENTER, -1, hub_fsize)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_handle_click((event as InputEventMouseButton).position)


func _angle_in_wedge(a: float, w: Dictionary) -> bool:
	var span := fposmod((w["end"] as float) - (w["start"] as float), TAU)
	var rel := fposmod(a - (w["start"] as float), TAU)
	return rel <= span


func _wedge_at(pos: Vector2) -> int:
	var center := size * 0.5
	var d := pos - center
	var a := d.angle()
	for i in _wedges.size():
		if _angle_in_wedge(a, _wedges[i]):
			return i
	return -1


func _update_hover(pos: Vector2) -> void:
	var center := size * 0.5
	var r := (pos - center).length()
	var prev_hub := _hub_hover
	var prev_idx := _hover_index
	_hub_hover = r <= _inner_radius()
	_hover_index = -1 if _hub_hover or r > _outer_radius() + HOVER_GROW else _wedge_at(pos)
	_hub_label = (_wedges[_hover_index] as Dictionary)["id"] as String if _hover_index >= 0 else "All"
	if prev_hub != _hub_hover or prev_idx != _hover_index:
		queue_redraw()


func _handle_click(pos: Vector2) -> void:
	var center := size * 0.5
	var r := (pos - center).length()
	if r <= _inner_radius():
		category_chosen.emit("All")
		return
	if r > _outer_radius() + HOVER_GROW:
		cancelled.emit()
		return
	var idx := _wedge_at(pos)
	if idx >= 0:
		category_chosen.emit((_wedges[idx] as Dictionary)["id"] as String)
	else:
		cancelled.emit()
