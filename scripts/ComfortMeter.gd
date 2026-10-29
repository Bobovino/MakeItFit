extends Control

# Live fill bar for GameManager.comfort_pct — how uncomfortable the tenant is
# with however many yellow-tier (medium mobility) pieces currently sit away
# from their starting spot (see Furniture.mobility_tier). Only meant to be
# shown at all on a level that actually has yellow-tier furniture placed —
# Main.gd handles that visibility check, this just draws whatever value it's
# given.

const BG_COL     := GameTheme.CARD_DIM
const BORDER_COL := GameTheme.NAVY
const TEXT_COL   := GameTheme.INK

var _pct: float = 100.0
var _warn_threshold: float = 50.0
var _pulse_t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = tr("Comfort. Below the warning line the apartment can't be rented like this. Yellow-tier furniture is uncomfortable to move — each piece sitting away from where it started costs comfort. Move it back and comfort recovers. Below the warning line, this arrangement can't be rented out.")
	set_process(false)


# What is costing comfort right now (piece names), added to the tooltip.
func set_moved(names: Array) -> void:
	var base := tr("Comfort. Below the warning line the apartment can't be rented like this. Yellow-tier furniture is uncomfortable to move — each piece sitting away from where it started costs comfort. Move it back and comfort recovers. Below the warning line, this arrangement can't be rented out.")
	if names.is_empty():
		tooltip_text = base
	else:
		tooltip_text = base + "\n\n" + tr("Away from where it started: %s") % Loc.join_list(names)


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
		return GameTheme.RED
	if _pct < 100.0:
		return GameTheme.INK_SOFT
	return GameTheme.NAVY


# A line of the till receipt (Main's): "Comfort 100%" typed out, and under
# it a thin gauge. Below the warning line it turns red and pulses: the one
# passive cue that this blocks renting, not just "below 100%".
func _draw() -> void:
	var failing := _pct < _warn_threshold
	var font := GameTheme.font("mono")
	const FSIZE := GameTheme.FS_CAPTION
	# Short enough for the receipt; the tooltip carries the explanation.
	var label := tr("Comfort %d%%") % roundi(_pct)
	if failing:
		label += "  \ueb55"
	var ink := GameTheme.RED if failing else TEXT_COL
	draw_string(font, Vector2(0.0, FSIZE), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FSIZE, ink)
	var gauge := Rect2(0.0, size.y - 5.0, size.x, 4.0)
	draw_rect(gauge, BG_COL)
	var fill_w := gauge.size.x * clampf(_pct, 0.0, 100.0) / 100.0
	var fill := _fill_color()
	if failing:
		var pulse := (sin(_pulse_t * 4.0) + 1.0) * 0.5   # 0..1
		fill = GameTheme.RED.lerp(GameTheme.CARD, pulse * 0.5)
	if fill_w > 0.0:
		draw_rect(Rect2(gauge.position, Vector2(fill_w, gauge.size.y)), fill)
	draw_rect(gauge, BORDER_COL, false, 1.0)
