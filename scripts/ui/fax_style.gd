extends RefCounted
class_name FaxStyle

# The fax machine's look, shared by the project map's fax (CityMap) and the
# rental application that prints when a level starts (ApplicationFax).
#
# The fax is the Housing Office's shrinking machine, so it is drawn in the
# capsule's colours: a navy machine, a white sheet in navy ink, red for its
# stamps and the key that matters.

const INK := GameTheme.NAVY
const INK_SOFT := GameTheme.INK_SOFT
const STAMP_INK := GameTheme.RED
const KEY_GREEN := GameTheme.RED      # the key that goes ahead (OK, Enter)
const KEY_GREY := GameTheme.INDIGO


static func paper() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = GameTheme.CARD
	sb.set_content_margin(SIDE_LEFT, 22)
	sb.set_content_margin(SIDE_RIGHT, 22)
	sb.set_content_margin(SIDE_TOP, 18)
	sb.set_content_margin(SIDE_BOTTOM, 22)
	sb.shadow_color = Color(GameTheme.NAVY, 0.45)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 6)
	return sb


static func machine() -> StyleBoxFlat:
	var body := StyleBoxFlat.new()
	body.bg_color = GameTheme.NAVY
	body.border_color = GameTheme.NAVY.darkened(0.35)
	body.set_border_width_all(2)
	body.set_corner_radius_all(14)
	body.set_content_margin(SIDE_LEFT, 18)
	body.set_content_margin(SIDE_RIGHT, 14)
	body.set_content_margin(SIDE_TOP, 10)
	body.set_content_margin(SIDE_BOTTOM, 14)
	body.shadow_color = GameTheme.NAVY.darkened(0.45)
	body.shadow_size = 1
	body.shadow_offset = Vector2(4, 6)
	body.anti_aliasing = true
	return body


# The slot the paper comes out of.
static func slot() -> Panel:
	var s := Panel.new()
	s.custom_minimum_size = Vector2(0, 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = GameTheme.NAVY.darkened(0.6)
	sb.set_corner_radius_all(4)
	s.add_theme_stylebox_override("panel", sb)
	return s


# The little display.
static func lcd(text: String) -> Label:
	var lcd := Label.new()
	lcd.text = text
	lcd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lcd.add_theme_font_override("font", GameTheme.font("mono_bold"))
	lcd.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	lcd.add_theme_color_override("font_color", GameTheme.CHALK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = GameTheme.INDIGO_DK
	sb.border_color = GameTheme.NAVY.darkened(0.5)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(6)
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
			sb.bg_color = GameTheme.INDIGO_DK.darkened(0.3)
		sb.border_color = face.darkened(0.45)
		sb.set_border_width_all(1)
		sb.set_border_width(SIDE_BOTTOM, 1 if state == "pressed" else 4)
		sb.set_corner_radius_all(8)
		sb.set_content_margin_all(6)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.anti_aliasing = true
		btn.add_theme_stylebox_override(state, sb)
	for c in ["font_color", "font_hover_color", "font_pressed_color"]:
		btn.add_theme_color_override(c, text)
	btn.add_theme_color_override("font_disabled_color", GameTheme.CHALK_SOFT)
	btn.add_theme_font_override("font", GameTheme.font("ui"))
