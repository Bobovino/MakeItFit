extends RefCounted
class_name FaxStyle

# The fax machine's look, shared by the project map's fax (CityMap) and the
# rental application that prints when a level starts (ApplicationFax).

const INK := Color(0.16, 0.15, 0.14)
const INK_SOFT := Color(0.40, 0.38, 0.35)
const STAMP_INK := Color(0.62, 0.22, 0.18)
const KEY_GREEN := Color(0.22, 0.56, 0.36)
const KEY_GREY := Color(0.42, 0.44, 0.47)


static func paper() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.965, 0.955, 0.925)
	sb.set_content_margin(SIDE_LEFT, 18)
	sb.set_content_margin(SIDE_RIGHT, 18)
	sb.set_content_margin(SIDE_TOP, 16)
	sb.set_content_margin(SIDE_BOTTOM, 20)
	sb.shadow_color = Color(0, 0, 0, 0.30)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(2, 3)
	return sb


static func machine() -> StyleBoxFlat:
	var body := StyleBoxFlat.new()
	body.bg_color = Color(0.205, 0.215, 0.230)
	body.border_color = Color(0.11, 0.12, 0.13)
	body.set_border_width_all(2)
	body.set_corner_radius_all(14)
	body.set_content_margin(SIDE_LEFT, 18)
	body.set_content_margin(SIDE_RIGHT, 18)
	body.set_content_margin(SIDE_TOP, 12)
	body.set_content_margin(SIDE_BOTTOM, 16)
	body.shadow_color = Color(0, 0, 0, 0.45)
	body.shadow_size = 12
	body.shadow_offset = Vector2(3, 6)
	body.anti_aliasing = true
	return body


# The slot the paper comes out of.
static func slot() -> Panel:
	var s := Panel.new()
	s.custom_minimum_size = Vector2(0, 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.04, 0.05)
	sb.set_corner_radius_all(4)
	s.add_theme_stylebox_override("panel", sb)
	return s


# The little green display.
static func lcd(text: String) -> Label:
	var lcd := Label.new()
	lcd.text = text
	lcd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lcd.add_theme_font_size_override("font_size", 11)
	lcd.add_theme_color_override("font_color", Color(0.20, 0.34, 0.16))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.62, 0.74, 0.52)
	sb.border_color = Color(0.10, 0.11, 0.10)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(4)
	lcd.add_theme_stylebox_override("normal", sb)
	return lcd


# A key on the machine: a raised cap in `face`, pressed in when clicked.
static func key(btn: Button, face: Color, text: Color) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = face
		if state == "hover":
			sb.bg_color = face.lightened(0.12)
		elif state == "pressed":
			sb.bg_color = face.darkened(0.15)
		elif state == "disabled":
			sb.bg_color = Color(0.30, 0.31, 0.33)
		sb.border_color = face.darkened(0.45)
		sb.set_border_width_all(1)
		sb.set_border_width(SIDE_BOTTOM, 1 if state == "pressed" else 4)
		sb.set_corner_radius_all(7)
		sb.set_content_margin_all(6)
		sb.anti_aliasing = true
		btn.add_theme_stylebox_override(state, sb)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		btn.add_theme_color_override(c, text)
	btn.add_theme_color_override("font_disabled_color", Color(0.60, 0.60, 0.60))
