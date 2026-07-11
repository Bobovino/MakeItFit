extends RefCounted
class_name GameTheme

# Palette — "drafting desk at dusk": warm charcoal-umber chrome so the cool
# cyanotype blueprint reads as a document lying on a warm desk, not wallpaper.
const C_BG      := Color(0.145, 0.125, 0.105)   # desk shadow (warm charcoal)
const C_BG2     := Color(0.195, 0.170, 0.140)   # raised surfaces / buttons (walnut)
const C_BORDER  := Color(0.320, 0.270, 0.205)   # warm taupe
const C_AMBER   := Color(0.960, 0.800, 0.450)   # honey amber accent
const C_TEXT    := Color(0.910, 0.865, 0.780)   # warm cream body text
const C_MUTED   := Color(0.580, 0.520, 0.440)   # warm gray-brown secondary
const C_PAPER   := Color(0.955, 0.930, 0.870)   # manila cream — paper cards, stamps
const C_GOOD    := Color(0.560, 0.780, 0.470)   # sage green — valid / success
const C_BAD     := Color(0.900, 0.475, 0.400)   # terracotta — invalid / error


static func make() -> Theme:
	var t := Theme.new()

	# PanelContainer
	t.set_stylebox("panel", "PanelContainer", _panel(C_BG, C_BORDER, 8))

	# Button states
	t.set_stylebox("normal",   "Button", _btn(C_BG2,                       C_BORDER,                  1))
	t.set_stylebox("hover",    "Button", _btn(Color(0.245, 0.210, 0.165),  Color(0.760, 0.620, 0.340), 1))
	t.set_stylebox("pressed",  "Button", _btn(Color(0.290, 0.230, 0.130),  C_AMBER,                   1))
	t.set_stylebox("disabled", "Button", _btn(Color(0.130, 0.115, 0.100),  Color(0.240, 0.205, 0.165), 1))
	t.set_stylebox("focus",    "Button", _btn(Color(0.245, 0.210, 0.165),  Color(0.760, 0.620, 0.340), 1))

	t.set_color("font_color",          "Button", C_TEXT)
	t.set_color("font_hover_color",    "Button", C_AMBER)
	t.set_color("font_pressed_color",  "Button", C_AMBER)
	t.set_color("font_disabled_color", "Button", C_MUTED)
	t.set_color("font_focus_color",    "Button", C_AMBER)
	t.set_constant("outline_size",     "Button", 0)

	# Label
	t.set_color("font_color", "Label", C_TEXT)

	# ScrollContainer — transparent background
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

	# VScrollBar (tiny, unobtrusive)
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = C_BG2
	sb_bg.set_content_margin_all(0)
	var sb_grab := StyleBoxFlat.new()
	sb_grab.bg_color = Color(0.400, 0.345, 0.270)
	sb_grab.set_content_margin_all(2)
	sb_grab.corner_radius_top_left    = 2
	sb_grab.corner_radius_top_right   = 2
	sb_grab.corner_radius_bottom_left = 2
	sb_grab.corner_radius_bottom_right = 2
	t.set_stylebox("scroll",         "VScrollBar", sb_bg)
	t.set_stylebox("grabber",        "VScrollBar", sb_grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", sb_grab)
	t.set_stylebox("grabber_pressed",   "VScrollBar", sb_grab)

	return t


static func make_rent_btn_style() -> Array:
	# Returns [normal, hover, disabled] StyleBoxFlat for the Rent Out button
	var n := _btn(Color(0.420, 0.310, 0.110), C_AMBER, 2)
	n.set_content_margin(SIDE_LEFT, 24)
	n.set_content_margin(SIDE_RIGHT, 24)
	n.set_content_margin(SIDE_TOP, 8)
	n.set_content_margin(SIDE_BOTTOM, 8)
	n.shadow_size = 8
	n.shadow_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.25)
	var h := _btn(Color(0.540, 0.400, 0.130), Color(1.0, 0.92, 0.62), 2)
	h.set_content_margin(SIDE_LEFT, 24)
	h.set_content_margin(SIDE_RIGHT, 24)
	h.set_content_margin(SIDE_TOP, 8)
	h.set_content_margin(SIDE_BOTTOM, 8)
	h.shadow_size = 10
	h.shadow_color = Color(1.0, 0.92, 0.62, 0.35)
	var d := _btn(Color(0.130, 0.115, 0.100), Color(0.240, 0.205, 0.165), 1)
	d.set_content_margin(SIDE_LEFT, 24)
	d.set_content_margin(SIDE_RIGHT, 24)
	d.set_content_margin(SIDE_TOP, 8)
	d.set_content_margin(SIDE_BOTTOM, 8)
	d.shadow_size = 0
	return [n, h, d]


static func _panel(bg: Color, border: Color, margin: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(2)
	s.set_content_margin_all(margin + 4)
	s.set_corner_radius_all(10)
	s.anti_aliasing = true
	s.shadow_color = Color(0, 0, 0, 0.30)
	s.shadow_size = 12
	s.shadow_offset = Vector2(0, 5)
	return s


static func _btn(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_content_margin(SIDE_LEFT, 12)
	s.set_content_margin(SIDE_RIGHT, 12)
	s.set_content_margin(SIDE_TOP, 6)
	s.set_content_margin(SIDE_BOTTOM, 6)
	s.set_corner_radius_all(8)
	s.anti_aliasing = true
	s.shadow_color = Color(0, 0, 0, 0.25)
	s.shadow_size = 3
	s.shadow_offset = Vector2(0, 2)
	return s


# Small rounded "chip" stylebox — used for item-row cards, category tags, etc.
static func make_card_stylebox(bg: Color, border: Color, radius: int = 10) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	s.set_content_margin(SIDE_LEFT, 8)
	s.set_content_margin(SIDE_RIGHT, 8)
	s.set_content_margin(SIDE_TOP, 6)
	s.set_content_margin(SIDE_BOTTOM, 6)
	return s
