extends Control
class_name MomentClock

# A level's moments on a desk clock, in the needs bar: a stretch of its
# band per moment with its icon, the one on screen ringed, and a short hand
# that sweeps to whichever is chosen (see _draw). Moments can be hours, days of the week, occasions or routines;
# the clock only says "this is about time", so the slices are equal and the
# hour ticks round the rim are decoration.
#
# Click a slice to choose it (the same as the old tabs); the tooltip names
# the slice under the pointer. Main switches the moment and calls
# set_active(), so a switch made any other way (Q/E, loading) turns the hand
# too.
#
# The clock holds icons for up to COMPACT_MAX moments. With more (a week, a
# dozen routines) the slices are too thin for icons: it shows the slices
# alone, and TenantCard puts the active moment's icon beside it.

signal moment_chosen(moment_id: String)

const TICKS := 12
const COMPACT_MAX := 4
const DONE_FILL := Color("8fcfa3")      # a moment with every need met
const MISSING_FILL := Color("ee9a94")   # a moment still missing a need
const FACE := Color("fbfaf5")           # the clock's face, paper-coloured

var _moments: Array = []          # [{id, label, icon}]
var _active := 0
var _hand_angle := 0.0            # radians, 0 = twelve o'clock, clockwise
var _hover := -1
var _tween: Tween
var _done := {}                   # moment id -> whether its needs are met; none until known


func setup(moments: Array, size_px: float) -> void:
	_moments = moments
	custom_minimum_size = Vector2(size_px, size_px)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_active = 0
	_hand_angle = _slice_angle(0)
	queue_redraw()


func set_active(moment_id: String) -> void:
	var k := _index_of(moment_id)
	if k < 0 or k == _active and _hand_angle == _slice_angle(k):
		return
	_active = k
	var target := _slice_angle(k)
	# Always the short way round: from Sunday to Monday, forward.
	var delta := wrapf(target - _hand_angle, -PI, PI)
	if absf(delta) < 0.001:
		_hand_angle = target
		queue_redraw()
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	if GameState.reduce_motion or not is_inside_tree():
		_hand_angle = target
		queue_redraw()
		return
	var from := _hand_angle
	_tween = create_tween()
	_tween.tween_method(func(t: float) -> void:
		_hand_angle = from + delta * t
		queue_redraw(), 0.0, 1.0, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	queue_redraw()


# Which moments have all their needs met: their slices fill green, or red
# where something is missing.
func set_status(done: Dictionary) -> void:
	if done == _done:
		return
	_done = done.duplicate()
	queue_redraw()


func active_label() -> String:
	if _moments.is_empty():
		return ""
	return (_moments[_active] as Dictionary).get("label", "") as String


func _index_of(moment_id: String) -> int:
	for k in _moments.size():
		if (_moments[k] as Dictionary).get("id", "") == moment_id:
			return k
	return -1


# The middle of slice k, from twelve o'clock clockwise.
func _slice_angle(k: int) -> float:
	if _moments.is_empty():
		return 0.0
	return TAU * k / _moments.size()


func _point(angle: float, r: float) -> Vector2:
	return size * 0.5 + Vector2(sin(angle), -cos(angle)) * r


func _slice_at(pos: Vector2) -> int:
	var d := pos - size * 0.5
	if d.length() > size.x * 0.5 or _moments.is_empty():
		return -1
	var a := fposmod(atan2(d.x, -d.y), TAU)
	var step := TAU / _moments.size()
	return int(fposmod(a + step * 0.5, TAU) / step) % _moments.size()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var h := _slice_at((event as InputEventMouseMotion).position)
		if h != _hover:
			_hover = h
			queue_redraw()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var k := _slice_at((event as InputEventMouseButton).position)
		if k >= 0:
			accept_event()
			moment_chosen.emit((_moments[k] as Dictionary)["id"] as String)


# Too many moments for icons on the dial.
func is_compact() -> bool:
	return _moments.size() > COMPACT_MAX


func active_icon() -> String:
	if _moments.is_empty():
		return ""
	return MomentClock.icon_for(_moments[_active] as Dictionary)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
		_hover = -1
		queue_redraw()


func _get_tooltip(at_position: Vector2) -> String:
	var k := _slice_at(at_position)
	if k < 0:
		return ""
	return tr((_moments[k] as Dictionary).get("label", "") as String)


# A desk clock: a cream face in a thick navy bezel, lying on the board with
# its shadow. The moments are a band round the inside of the bezel, a
# stretch each: green when all their needs are met, red when one is
# missing, plain until known; the one on screen ringed in navy. Hour marks,
# each moment's icon on the face before its stretch, and two hands: the
# short one points at the moment on screen, the long one rests at ten past.
func _draw() -> void:
	var c := size * 0.5
	var r := size.x * 0.5 - 3.0
	draw_circle(c + Vector2(2, 3), r + 1.0, Color(0, 0, 0, 0.3))
	draw_circle(c, r, FACE)
	var n := _moments.size()
	var band_out := r - 4.0
	var band_in := r * 0.7
	if n > 0:
		var step := TAU / n
		for k in n:
			var mid := (_moments[k] as Dictionary).get("id", "") as String
			var col := GameTheme.CARD_DIM
			if _done.has(mid):
				col = DONE_FILL if _done[mid] else MISSING_FILL
			if k == _hover:
				col = col.lightened(0.25)
			var a0 := _slice_angle(k) - step * 0.5
			draw_colored_polygon(_band(a0, step, band_in, band_out), col)
		# Gaps between the stretches.
		if n > 1:
			for k in n:
				var a := _slice_angle(k) + step * 0.5
				draw_line(_point(a, band_in), _point(a, band_out), FACE, 2.0, true)
		# The one on screen, ringed.
		var ring := _band(_slice_angle(_active) - step * 0.5, step, band_in, band_out)
		ring.append(ring[0])
		draw_polyline(ring, GameTheme.NAVY, 2.0, true)
	# Hour marks inside the band, longer at twelve, three, six and nine.
	for t in TICKS:
		var a := TAU * t / TICKS
		var major := t % 3 == 0
		draw_line(_point(a, band_in - (7.0 if major else 4.0)), _point(a, band_in - 1.0),
			GameTheme.NAVY, 2.0 if major else 1.0, true)
	# Each moment's icon on the face, facing its stretch of the band.
	if n > 0 and not is_compact():
		var font := GameTheme.font("icons")
		var fs := int(clampf(r * 0.36, 11.0, 22.0))
		for k in n:
			var glyph := MomentClock.icon_for(_moments[k] as Dictionary)
			var at := _point(_slice_angle(k), band_in * (0.5 if n > 1 else 0.0))
			var w := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, at + Vector2(-w * 0.5, fs * 0.36), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				GameTheme.NAVY if k == _active else GameTheme.INK_SOFT)
	# The hands: the long one at ten past, as clocks are pictured, the short
	# one at the moment.
	draw_line(c, _point(TAU * 2.0 / 12.0, band_in - 9.0), GameTheme.INK_SOFT, 1.5, true)
	var tip := _point(_hand_angle, band_in * 0.72)
	var side := Vector2(cos(_hand_angle), sin(_hand_angle)) * 3.0
	draw_colored_polygon(PackedVector2Array([c - side, c + side, tip]), GameTheme.NAVY)
	draw_circle(c, 4.0, GameTheme.NAVY)
	draw_circle(c, 1.8, GameTheme.RED)
	# The bezel.
	draw_arc(c, r - 2.0, 0.0, TAU, 64, GameTheme.NAVY, 4.0, true)


# A stretch of the band from angle `a0`, `step` long, between radii.
func _band(a0: float, step: float, r_in: float, r_out: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var segs := maxi(4, int(32.0 * step / TAU) + 2)
	for s in segs + 1:
		pts.append(_point(a0 + step * s / segs, r_out))
	for s in range(segs, -1, -1):
		pts.append(_point(a0 + step * s / segs, r_in))
	return pts


# Tabler icons a moment can name in its "icon" field, by name.
const ICONS := {
	"sun": "", "moon": "", "sunrise": "", "sunset": "",
	"moon-stars": "", "coffee": "", "briefcase": "", "book": "",
	"glass-full": "", "confetti": "", "users": "", "calendar": "",
	"calendar-week": "ﴰ", "home": "", "bed": "", "zzz": "",
	"cake": "", "gift": "", "barbell": "", "device-tv": "",
	"school": "", "shopping-cart": "", "heart": "", "star": "",
	"clock": "", "tools-kitchen-2": "", "music": "", "beach": "",
	"snowflake": "", "plant": "", "paw": "", "baby-carriage": "",
	"sparkles": "", "shirt": "",
}

# Without an "icon", one guessed from the moment's id and label; a clock if
# nothing matches.
# Checked in order: a weekday or "birthday" before plain "day".
const GUESSES := [
	["night", "moon"], ["noche", "moon"], ["nacht", "moon"], ["sleep", "zzz"],
	["morning", "sunrise"], ["evening", "sunset"],
	["monday", "briefcase"], ["tuesday", "calendar"], ["wednesday", "calendar"],
	["thursday", "calendar"], ["friday", "glass-full"], ["saturday", "beach"], ["sunday", "bed"],
	["weekend", "beach"], ["week", "calendar-week"], ["birthday", "cake"], ["holiday", "beach"],
	["day", "sun"],
	["work", "briefcase"], ["office", "briefcase"], ["study", "school"],
	["book", "book"], ["host", "glass-full"], ["dinner", "tools-kitchen-2"], ["party", "confetti"],
	["guest", "users"], ["visit", "users"], ["christmas", "gift"],
	["dress", "shirt"], ["gym", "barbell"], ["sport", "barbell"], ["tv", "device-tv"],
	["baby", "baby-carriage"], ["pet", "paw"], ["dog", "paw"], ["normal", "home"], ["home", "home"],
	["winter", "snowflake"], ["summer", "beach"],
]


static func icon_for(moment: Dictionary) -> String:
	var name := moment.get("icon", "") as String
	if ICONS.has(name):
		return ICONS[name]
	var text := ("%s %s" % [moment.get("id", ""), moment.get("label", "")]).to_lower()
	for g in GUESSES:
		if (g[0] as String) in text:
			return ICONS[g[1]]
	return ICONS["clock"]
