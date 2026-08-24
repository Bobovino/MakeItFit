extends Control

# Live fill bar for GameManager.comfort_pct — how uncomfortable the tenant is
# with however many yellow-tier (medium mobility) pieces currently sit away
# from their starting spot (see Furniture.mobility_tier). Only meant to be
# shown at all on a level that actually has yellow-tier furniture placed —
# Main.gd handles that visibility check, this just draws whatever value it's
# given.

const BG_COL     := Color(0.16, 0.14, 0.12, 0.9)
const BORDER_COL := Color(0.35, 0.32, 0.28, 0.9)
const TEXT_COL   := Color(0.93, 0.90, 0.86, 0.95)

var _pct: float = 100.0
var _warn_threshold: float = 50.0


func set_value(pct: float, warn_threshold: float) -> void:
	_pct = pct
	_warn_threshold = warn_threshold
	queue_redraw()


func _fill_color() -> Color:
	if _pct < _warn_threshold:
		return GameTheme.C_BAD
	if _pct < 100.0:
		return GameTheme.C_AMBER
	return GameTheme.C_GOOD


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, BG_COL)
	var fill_w := size.x * clampf(_pct, 0.0, 100.0) / 100.0
	if fill_w > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(fill_w, size.y)), _fill_color())
	draw_rect(r, BORDER_COL, false, 1.0)
	var font := ThemeDB.fallback_font
	const FSIZE := 10
	var label := "Comfort %d%%" % roundi(_pct)
	var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE).x
	draw_string(font, Vector2((size.x - tw) * 0.5, size.y * 0.5 + FSIZE * 0.35), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE, TEXT_COL)
