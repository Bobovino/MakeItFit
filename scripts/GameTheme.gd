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

# Blueprint-blue (cyanotype) — same values as GridDraw.gd's BP_* consts.
# Canonical source for any NEW chrome (MainMenu, CityMap) that needs to mix
# blueprint-blue with the warm desk palette above. GridDraw.gd/BlueprintPreview.gd
# keep their own local copies — leave those alone, they're stable and isolated.
const BP_PAPER    := Color(0.070, 0.150, 0.260)   # deep cyanotype blue — the drafting surface
const BP_FLOOR    := Color(0.110, 0.245, 0.385)   # lighter interior blue
const BP_INK      := Color(0.910, 0.945, 0.965)   # drafting-ink white
const BP_INK_SOFT := Color(0.640, 0.790, 0.920)
const BP_GRID_MAJ := Color(0.560, 0.780, 0.980, 0.26)


# Handwritten accent font (Caveat, OFL) — used sparingly: the APPROVED stamp,
# tenant brief notes, pencil-style annotations. Everything else stays Space
# Grotesk via the global fallback font.
static var _hand_font: Font = null

static func handwriting() -> Font:
	if _hand_font == null and ResourceLoader.exists("res://assets/fonts/Caveat.ttf"):
		_hand_font = load("res://assets/fonts/Caveat.ttf")
	return _hand_font


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

	_add_controls(t)
	return t


# The rest of the controls a menu uses. Without these they fell back to
# Godot's defaults, which are dark grey on this dark brown: a CheckBox showed
# no box, a switch only its knob, a slider's filled part looked like its
# empty one.
static func _add_controls(t: Theme) -> void:
	# Thin scrollbar on no track, so a list that scrolls doesn't grow a
	# second frame down its side.
	t.set_stylebox("scroll", "VScrollBar", _scroll_track())
	var grab := _scroll_grab(Color(0.400, 0.345, 0.270))
	t.set_stylebox("grabber", "VScrollBar", grab)
	t.set_stylebox("grabber_highlight", "VScrollBar", _scroll_grab(Color(0.560, 0.470, 0.330)))
	t.set_stylebox("grabber_pressed", "VScrollBar", _scroll_grab(C_AMBER.darkened(0.25)))

	# Switches (CheckButton) and ticks (CheckBox): flat, the whole row is the
	# hit area, the text in the body colour.
	for type in ["CheckButton", "CheckBox"]:
		var flat := StyleBoxFlat.new()
		flat.bg_color = Color(0, 0, 0, 0)
		flat.set_corner_radius_all(6)
		flat.set_content_margin(SIDE_LEFT, 0)
		flat.set_content_margin(SIDE_RIGHT, 0)
		flat.set_content_margin(SIDE_TOP, 6)
		flat.set_content_margin(SIDE_BOTTOM, 6)
		var hover := flat.duplicate() as StyleBoxFlat
		hover.bg_color = Color(1, 1, 1, 0.04)
		for st in ["normal", "pressed", "disabled"]:
			t.set_stylebox(st, type, flat)
		t.set_stylebox("hover", type, hover)
		t.set_stylebox("hover_pressed", type, hover)
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		t.set_color("font_color", type, C_TEXT)
		t.set_color("font_hover_color", type, C_TEXT)
		t.set_color("font_pressed_color", type, C_TEXT)
		t.set_color("font_hover_pressed_color", type, C_TEXT)
		t.set_color("font_focus_color", type, C_TEXT)
		t.set_color("font_disabled_color", type, C_MUTED)
		t.set_constant("h_separation", type, 10)
	t.set_icon("unchecked", "CheckButton", _switch_icon(false, false))
	t.set_icon("checked", "CheckButton", _switch_icon(true, false))
	t.set_icon("unchecked_disabled", "CheckButton", _switch_icon(false, true))
	t.set_icon("checked_disabled", "CheckButton", _switch_icon(true, true))
	t.set_icon("unchecked", "CheckBox", _tick_icon(false, false))
	t.set_icon("checked", "CheckBox", _tick_icon(true, false))
	t.set_icon("unchecked_disabled", "CheckBox", _tick_icon(false, true))
	t.set_icon("checked_disabled", "CheckBox", _tick_icon(true, true))

	# Sliders: an amber filled part up to a cream knob.
	t.set_stylebox("slider", "HSlider", _track(Color(0.300, 0.262, 0.215)))
	t.set_stylebox("grabber_area", "HSlider", _track(C_AMBER.darkened(0.15)))
	t.set_stylebox("grabber_area_highlight", "HSlider", _track(C_AMBER))
	t.set_icon("grabber", "HSlider", _knob_icon(C_PAPER, 18))
	t.set_icon("grabber_highlight", "HSlider", _knob_icon(Color(1.0, 0.97, 0.88), 20))
	t.set_icon("grabber_disabled", "HSlider", _knob_icon(C_MUTED, 18))
	t.set_constant("center_grabber", "HSlider", 0)

	# Pickers look like the buttons they are, with the list in the same
	# colours.
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		t.set_stylebox(st, "OptionButton", t.get_stylebox(st, "Button"))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color", "font_focus_color"]:
		t.set_color(c, "OptionButton", t.get_color(c, "Button"))
	t.set_color("font_hover_color", "OptionButton", C_TEXT)
	t.set_color("font_focus_color", "OptionButton", C_TEXT)
	var popup := _panel(Color(0.165, 0.145, 0.120), C_BORDER, 0)
	popup.set_content_margin_all(6)
	popup.shadow_size = 8
	t.set_stylebox("panel", "PopupMenu", popup)
	var row_hover := StyleBoxFlat.new()
	row_hover.bg_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.16)
	row_hover.set_corner_radius_all(5)
	t.set_stylebox("hover", "PopupMenu", row_hover)
	t.set_color("font_color", "PopupMenu", C_TEXT)
	t.set_color("font_hover_color", "PopupMenu", C_AMBER)
	t.set_color("font_disabled_color", "PopupMenu", C_MUTED)
	t.set_constant("v_separation", "PopupMenu", 10)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 10)
	t.set_icon("radio_checked", "PopupMenu", _knob_icon(C_AMBER, 8))
	t.set_icon("radio_unchecked", "PopupMenu", ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8)))

	# A rule between sections: one quiet line.
	var rule := StyleBoxLine.new()
	rule.color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.7)
	rule.thickness = 1
	t.set_stylebox("separator", "HSeparator", rule)


static func _scroll_track() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.content_margin_left = 3
	s.content_margin_right = 3
	return s


static func _scroll_grab(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(3)
	s.content_margin_left = 3
	s.content_margin_right = 3
	return s


static func _track(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(3)
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	s.anti_aliasing = true
	return s


# Small icons drawn here rather than shipped as files: shapes with their
# edges smoothed by coverage, from a signed distance (negative inside).
# Cached by `key`: make() runs for every menu that opens.
static var _icons: Dictionary = {}

static func _shape_icon(w: int, h: int, paint: Callable, key: String) -> ImageTexture:
	if _icons.has(key):
		return _icons[key]
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, paint.call(Vector2(x + 0.5, y + 0.5)) as Color)
	_icons[key] = ImageTexture.create_from_image(img)
	return _icons[key]


static func _round_rect_dist(p: Vector2, r: Rect2, radius: float) -> float:
	var q := (p - r.get_center()).abs() - r.size * 0.5 + Vector2(radius, radius)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius


static func _over(under: Color, top: Color, dist: float) -> Color:
	var a := clampf(0.5 - dist, 0.0, 1.0) * top.a
	var out_a := a + under.a * (1.0 - a)
	if out_a <= 0.0:
		return Color(0, 0, 0, 0)
	var rgb := (Color(top.r, top.g, top.b) * a + Color(under.r, under.g, under.b) * under.a * (1.0 - a)) / out_a
	return Color(rgb.r, rgb.g, rgb.b, out_a)


static func _switch_icon(on: bool, disabled: bool) -> ImageTexture:
	var track := Color(0.560, 0.430, 0.180) if on else Color(0.300, 0.262, 0.215)
	var knob := C_PAPER if on else Color(0.700, 0.640, 0.560)
	if disabled:
		track = track.darkened(0.45)
		knob = knob.darkened(0.45)
	var w := 40
	var h := 22
	var cx := w - 11.0 if on else 11.0
	return _shape_icon(w, h, func(p: Vector2) -> Color:
		var c := _over(Color(0, 0, 0, 0), track, _round_rect_dist(p, Rect2(1, 2, w - 2, h - 4), (h - 4) * 0.5))
		return _over(c, knob, p.distance_to(Vector2(cx, h * 0.5)) - 8.0), "switch_%s_%s" % [on, disabled])


static func _tick_icon(on: bool, disabled: bool) -> ImageTexture:
	var box := C_AMBER.darkened(0.1) if on else Color(0, 0, 0, 0)
	var edge := C_AMBER.darkened(0.1) if on else C_MUTED
	if disabled:
		box = box.darkened(0.45)
		edge = edge.darkened(0.45)
	var s := 20
	var a := Vector2(5.5, 10.5)
	var b := Vector2(8.5, 13.5)
	var c := Vector2(14.5, 6.5)
	return _shape_icon(s, s, func(p: Vector2) -> Color:
		var d := _round_rect_dist(p, Rect2(2, 2, s - 4, s - 4), 4.0)
		var col := _over(Color(0, 0, 0, 0), edge, absf(d + 0.75) - 0.75)
		col = _over(col, box, d)
		if on:
			var tick := minf(_seg_dist(p, a, b), _seg_dist(p, b, c)) - 1.1
			col = _over(col, C_BG, tick)
		return col, "tick_%s_%s" % [on, disabled])


static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))


static func _knob_icon(c: Color, size: int) -> ImageTexture:
	var mid := Vector2(size, size) * 0.5
	var r := size * 0.5 - 1.0
	return _shape_icon(size, size, func(p: Vector2) -> Color:
		var col := _over(Color(0, 0, 0, 0), Color(0, 0, 0, 0.35), p.distance_to(mid + Vector2(0, 0.8)) - r)
		return _over(col, c, p.distance_to(mid) - r + 0.6), "knob_%s_%d" % [c.to_html(), size])


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


# "Furniture tag / drafting label" button for the title screen's paper
# sheet: a slightly darker paper chip with a thin ink rule, for the secondary
# actions (Continue, Options) under the amber Start. A dark game button there
# read as a hole cut in the paper.
const TAG_INK := Color(0.300, 0.240, 0.180)   # its text: dark sepia ink

static func make_tag_btn_style() -> Array:
	var n := StyleBoxFlat.new()
	n.bg_color = C_PAPER.darkened(0.05)
	n.border_color = Color(0.560, 0.490, 0.400)
	n.set_border_width_all(1)
	n.set_corner_radius_all(4)
	n.anti_aliasing = true
	n.set_content_margin(SIDE_LEFT, 18)
	n.set_content_margin(SIDE_RIGHT, 18)
	n.set_content_margin(SIDE_TOP, 9)
	n.set_content_margin(SIDE_BOTTOM, 9)
	n.shadow_color = Color(0, 0, 0, 0.10)
	n.shadow_size = 2
	n.shadow_offset = Vector2(0, 1)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = C_PAPER.darkened(0.10)
	h.border_color = C_AMBER.darkened(0.35)
	h.shadow_size = 5
	h.shadow_offset = Vector2(0, 2)
	var p := n.duplicate() as StyleBoxFlat
	p.bg_color = C_PAPER.darkened(0.14)
	p.shadow_size = 0
	p.set_content_margin(SIDE_TOP, 10)
	return [n, h, p]


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
