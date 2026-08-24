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
var _pulse_t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Yellow-tier furniture is uncomfortable to move — each piece sitting away from where it started costs comfort. Move it back and comfort recovers. Below the warning line, this arrangement can't be rented out."
	set_process(false)


func set_value(pct: float, warn_threshold: float) -> void:
	_pct = pct
	_warn_threshold = warn_threshold
	set_process(_pct < _warn_threshold)
	if _pct >= _warn_threshold:
		_pulse_t = 0.0
	queue_redraw()


func _process(delta: float) -> void:
	_pulse_t += delta
	queue_redraw()


func _fill_color() -> Color:
	if _pct < _warn_threshold:
		return GameTheme.C_BAD
	if _pct < 100.0:
		return GameTheme.C_AMBER
	return GameTheme.C_GOOD


func _draw() -> void:
	var failing := _pct < _warn_threshold
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, BG_COL)
	var fill_w := size.x * clampf(_pct, 0.0, 100.0) / 100.0
	if fill_w > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(fill_w, size.y)), _fill_color())
	# A slow pulse on the border while failing is the one PASSIVE cue that
	# something's actually wrong, not just "below 100%" — the fill color
	# alone (amber vs red) is easy to read as "fine, just not perfect"
	# rather than "this blocks renting" unless it visibly draws the eye.
	var border_col := BORDER_COL
	var border_w := 1.0
	if failing:
		var pulse := (sin(_pulse_t * 4.0) + 1.0) * 0.5   # 0..1
		border_col = GameTheme.C_BAD.lerp(Color(1.0, 0.9, 0.9, 1.0), pulse * 0.6)
		border_w = 1.5 + pulse * 1.0
	draw_rect(r, border_col, false, border_w)
	var font := ThemeDB.fallback_font
	const FSIZE := 10
	var label := "Comfort %d%%" % roundi(_pct)
	if failing:
		label += " — can't rent like this"
	var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE).x
	draw_string(font, Vector2((size.x - tw) * 0.5, size.y * 0.5 + FSIZE * 0.35), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE, TEXT_COL)
