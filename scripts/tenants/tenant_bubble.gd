extends PanelContainer
class_name TenantBubble

# A tenant's speech bubble: the requirement's icon (the same one its chip in
# the needs bar shows) and a mark for how they feel about it. Built as a
# Control so the 2D plan shows it directly and the 3D view can render it
# through a small SubViewport onto a billboard.

enum Mood { ANNOYED, HAPPY, UNSURE }

const SIZE_PX := 30   # icon size; the bubble is drawn at a fixed screen size, readable on a phone

var _tail: Polygon2D


static func make(req_id: String, mood: int) -> TenantBubble:
	var b := TenantBubble.new()
	b._build(req_id, mood)
	return b


func _build(req_id: String, mood: int) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var edge: Color = {Mood.ANNOYED: FaxStyle.STAMP_INK, Mood.HAPPY: Color(0.30, 0.56, 0.28),
		Mood.UNSURE: Color(0.45, 0.45, 0.48)}[mood]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.985, 0.975, 0.950)
	sb.border_color = edge
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(14)
	sb.set_content_margin(SIDE_LEFT, 9)
	sb.set_content_margin(SIDE_RIGHT, 9)
	sb.set_content_margin(SIDE_TOP, 5)
	sb.set_content_margin(SIDE_BOTTOM, 5)
	sb.anti_aliasing = true
	add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	if req_id != "":
		row.add_child(Requirements.make_icon(req_id, SIZE_PX))
	var mark := Label.new()
	mark.text = {Mood.ANNOYED: "!", Mood.HAPPY: "✓", Mood.UNSURE: "?"}[mood]
	mark.add_theme_font_size_override("font_size", SIZE_PX)
	mark.add_theme_color_override("font_color", edge)
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)

	_tail = Polygon2D.new()
	_tail.color = edge
	add_child(_tail)
	resized.connect(_place_tail)


func _place_tail() -> void:
	var c := size.x * 0.5
	_tail.polygon = PackedVector2Array([Vector2(c - 7, size.y - 2), Vector2(c + 7, size.y - 2), Vector2(c, size.y + 9)])
