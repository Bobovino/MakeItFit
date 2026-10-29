extends HBoxContainer
class_name MomentClock

# A level's moments in the needs bar, as tabs, like the dividers of a day
# planner: the moment on screen shows its icon and name on white paper with
# a navy edge; the others show their icon on a quieter card. Each tab says
# whether that moment has everything (a green tick) or still misses
# something (a red dot). Moments can be hours, days of the week, occasions
# or routines.
#
# Clicking a tab chooses it. Main switches the moment and calls
# set_active(), so a switch made any other way (Q/E, loading) moves the tab
# too. (It was a clock face; the name stays for the scripts that use it.)

signal moment_chosen(moment_id: String)

const COMPACT_MAX := 4   # kept for callers: tabs never need the bar's spare icon
const DONE_INK := Color("27500a")

var _moments: Array = []          # [{id, label, icon}]
var _active := 0
var _done := {}                   # moment id -> whether its needs are met; none until known
var _tabs: Array = []             # one Button per moment


func setup(moments: Array, _size_px: float = 0.0) -> void:
	_moments = moments
	_active = 0
	add_theme_constant_override("separation", 4)
	for t in _tabs:
		(t as Node).queue_free()
	_tabs.clear()
	for k in _moments.size():
		var m := _moments[k] as Dictionary
		var tab := Button.new()
		tab.focus_mode = Control.FOCUS_NONE
		tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tab.tooltip_text = tr(m.get("label", "") as String)
		tab.custom_minimum_size = Vector2(0, GameTheme.TOUCH_SMALL)
		tab.add_theme_font_override("font", GameTheme.font("ui"))
		tab.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
		var mid := m.get("id", "") as String
		tab.pressed.connect(func(): moment_chosen.emit(mid))
		add_child(tab)
		_tabs.append(tab)
	_paint()


func set_active(moment_id: String) -> void:
	var k := _index_of(moment_id)
	if k < 0 or k == _active:
		return
	_active = k
	_paint()


# Which moments have all their needs met: a tick on their tab, or a red dot
# where something is missing.
func set_status(done: Dictionary) -> void:
	if done == _done:
		return
	_done = done.duplicate()
	_paint()


func active_label() -> String:
	if _moments.is_empty():
		return ""
	return (_moments[_active] as Dictionary).get("label", "") as String


func active_icon() -> String:
	if _moments.is_empty():
		return ""
	return MomentClock.icon_for(_moments[_active] as Dictionary)


# The tabs name the moment themselves: nothing for the bar to add.
func is_compact() -> bool:
	return false


func _index_of(moment_id: String) -> int:
	for k in _moments.size():
		if (_moments[k] as Dictionary).get("id", "") == moment_id:
			return k
	return -1


func _paint() -> void:
	for k in _tabs.size():
		var tab := _tabs[k] as Button
		var m := _moments[k] as Dictionary
		var on := k == _active
		var mid := m.get("id", "") as String
		var mark := ""
		var mark_col := GameTheme.INK
		if _done.has(mid):
			mark = "  \uea5e" if _done[mid] else "  \u25cf"
			mark_col = DONE_INK if _done[mid] else GameTheme.RED
		tab.text = MomentClock.icon_for(m) + ("  " + tr(m.get("label", "") as String) if on else "") + mark
		var sb := StyleBoxFlat.new()
		sb.bg_color = GameTheme.CARD if on else GameTheme.CARD_DIM
		sb.border_color = GameTheme.NAVY if on else GameTheme.INK_SOFT.lerp(GameTheme.CARD, 0.4)
		sb.set_border_width_all(2 if on else 1)
		sb.corner_radius_top_left = 8
		sb.corner_radius_top_right = 8
		sb.corner_radius_bottom_left = 2
		sb.corner_radius_bottom_right = 2
		sb.shadow_color = Color(0, 0, 0, 0.3)
		sb.shadow_size = 1
		sb.shadow_offset = Vector2(2, 3) if on else Vector2(1, 2)
		sb.set_content_margin(SIDE_LEFT, 12)
		sb.set_content_margin(SIDE_RIGHT, 12)
		sb.anti_aliasing = true
		var hover := sb.duplicate() as StyleBoxFlat
		hover.bg_color = GameTheme.CARD
		for state in ["normal", "pressed", "hover_pressed"]:
			tab.add_theme_stylebox_override(state, sb)
		tab.add_theme_stylebox_override("hover", hover)
		# The one on screen in navy; the others in the colour of how they
		# stand (green: everything there, red: something missing).
		var ink := GameTheme.INK if on else (mark_col if mark != "" else GameTheme.INK_SOFT)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			tab.add_theme_color_override(c, ink)


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
