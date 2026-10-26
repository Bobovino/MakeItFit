extends Control
class_name MomentClock

# A level's moments on a clock face, in the needs bar: one slice per moment
# with its icon, the active one filled, and a hand that sweeps to whichever
# is chosen. Moments can be hours, days of the week, occasions or routines;
# the clock only says "this is about time", so the slices are equal and the
# hour ticks round the rim are decoration.
#
# Click a slice to choose it (the same as the old tabs); the tooltip names
# the slice under the pointer. Main switches the moment and calls
# set_active(), so a switch made any other way (Q/E, loading) turns the hand
# too.
#
# The small clock in the bar holds icons for up to COMPACT_MAX moments. With
# more (a week, a dozen routines) the slices are too thin for icons: it
# shows the slices alone, and a click asks for the large clock instead
# (open_requested), which TenantCard shows over the screen with every
# moment's icon and name (show_labels).

signal moment_chosen(moment_id: String)
signal open_requested

const RIM := 2.0
const TICKS := 12
const COMPACT_MAX := 4

var show_labels := false          # the large clock: names under the icons

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


# Which moments have all their needs met: a green mark on the rim of their
# slice, a red one where something is missing.
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
			if is_compact():
				open_requested.emit()
			else:
				moment_chosen.emit((_moments[k] as Dictionary)["id"] as String)


# Too many moments for icons in the small clock.
func is_compact() -> bool:
	return not show_labels and _moments.size() > COMPACT_MAX


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


func _draw() -> void:
	var c := size * 0.5
	var r := size.x * 0.5 - RIM
	draw_circle(c, r, GameTheme.CARD)
	var n := _moments.size()
	if n == 0:
		return
	var step := TAU / n
	# Slices: the active one filled navy, the hovered one tinted.
	for k in n:
		if k != _active and k != _hover:
			continue
		var a0 := _slice_angle(k) - step * 0.5
		var pts := PackedVector2Array([c])
		var segs := maxi(6, int(24.0 / n))
		for s in segs + 1:
			pts.append(_point(a0 + step * s / segs, r))
		draw_colored_polygon(pts, GameTheme.NAVY if k == _active else GameTheme.CARD_DIM)
	# Dividers between slices.
	if n > 1:
		for k in n:
			var a := _slice_angle(k) + step * 0.5
			draw_line(c, _point(a, r), GameTheme.INK_SOFT, 1.0, true)
	# Hour ticks round the rim.
	for t in TICKS:
		var a := TAU * t / TICKS
		draw_line(_point(a, r - 4.0), _point(a, r), GameTheme.INK, 1.5, true)
	draw_arc(c, r, 0.0, TAU, 64, GameTheme.NAVY, RIM * 2.0, true)
	# Status marks on the rim, one per slice.
	var mr := clampf(r * 0.13, 4.0, 11.0)
	for k in n:
		var mid := (_moments[k] as Dictionary).get("id", "") as String
		if not _done.has(mid):
			continue
		# Done is also smaller, so the two read apart without colour.
		var at := _point(_slice_angle(k), r)
		var dr := mr * (0.6 if _done[mid] else 1.0)
		draw_circle(at, dr + 1.5, GameTheme.CARD)
		draw_circle(at, dr, GameTheme.OK if _done[mid] else GameTheme.RED)
	# Icons, out in each slice; on the large clock, each with its name.
	var font := GameTheme.font("icons")
	var fs := int(clampf(r * (0.62 if n <= 2 else 0.52 if n <= 4 else 0.40), 12.0, 30.0))
	if show_labels:
		fs = int(clampf(r * 1.5 / maxf(n, 4.0), 22.0, 44.0))
	var text_font := GameTheme.font("ui")
	var tfs := GameTheme.FS_CAPTION
	for k in n:
		if is_compact():
			break
		var col := GameTheme.CHALK if k == _active else GameTheme.INK
		var glyph := MomentClock.icon_for(_moments[k] as Dictionary)
		var at := _point(_slice_angle(k), r * (0.62 if show_labels else 0.64 if n > 1 else 0.0))
		var w := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, at + Vector2(-w * 0.5, fs * 0.36), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		if show_labels:
			var label := tr((_moments[k] as Dictionary).get("label", "") as String)
			# As wide as the slice where the name sits, shrinking a long name
			# to fit rather than cutting it.
			var room := 2.0 * r * 0.66 * sin(minf(step * 0.5, PI * 0.5)) - 14.0
			var lfs := tfs
			while lfs > 11 and text_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x > room:
				lfs -= 1
			var tw := minf(text_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs).x, room)
			draw_string(text_font, at + Vector2(-tw * 0.5, fs * 0.36 + lfs + 6.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, room, lfs, col)
	# The hand, short like an hour hand so it points at the icon without
	# covering it, in the main-action red so it shows on navy and white.
	var tip := _point(_hand_angle, r * 0.38)
	draw_line(c, tip, GameTheme.NAVY, 5.0, true)
	draw_line(c, tip, GameTheme.RED, 3.0, true)
	draw_circle(c, 4.5, GameTheme.NAVY)
	draw_circle(c, 2.0, GameTheme.RED)


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
