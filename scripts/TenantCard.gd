extends PanelContainer
class_name TenantCard

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: VBoxContainer = $VBox/Checklist

# flat-list mode
var _check_rows: Dictionary = {}

# Suppresses the ✓-pop animation for the burst of updates right after a level
# loads — only flips caused by the player's own actions should celebrate.
var _setup_ticks: int = 0

# moment mode
var _moments: Array = []
var _moment_check_rows: Dictionary = {}  # moment_id -> { need -> Label }


func _ready() -> void:
	tenant_name_label.add_theme_font_size_override("font_size", 14)
	tenant_name_label.add_theme_color_override("font_color", GameTheme.C_AMBER)

	flavor_label.add_theme_font_size_override("font_size", 10)
	flavor_label.add_theme_color_override("font_color", GameTheme.C_MUTED)
	flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	rent_label.add_theme_font_size_override("font_size", 12)
	rent_label.add_theme_color_override("font_color", Color(0.50, 0.76, 0.52))

	checklist_container.add_theme_constant_override("separation", 5)


func setup(tenant: Dictionary) -> void:
	tenant_name_label.text = "%s, %d" % [tenant["name"], int(str(tenant["age"]))]
	flavor_label.text = tenant["flavor"]
	rent_label.text = "%d€ / month" % tenant["monthly_rent"]
	_moments = []
	_setup_ticks = Time.get_ticks_msec()
	_build_checklist(tenant["required_functions"])


func setup_moments(moments: Array) -> void:
	_moments = moments
	if moments.is_empty():
		return
	_build_moment_checklist()


func _clear_checklist() -> void:
	for child in checklist_container.get_children():
		checklist_container.remove_child(child)
		child.queue_free()
	_check_rows.clear()
	_moment_check_rows.clear()


func _build_checklist(required: Array) -> void:
	_clear_checklist()
	var hdr := _make_section_label("NEEDS")
	checklist_container.add_child(hdr)
	for func_name in required:
		var row := _make_need_row(func_name, false)
		checklist_container.add_child(row)
		_check_rows[func_name] = row


func _build_moment_checklist() -> void:
	_clear_checklist()
	_moment_check_rows = {}
	for m in _moments:
		var mid   := m["id"]    as String
		var label := m["label"] as String
		var needs := m["needs"] as Array

		var hdr := _make_section_label(label.to_upper())
		checklist_container.add_child(hdr)

		_moment_check_rows[mid] = {}
		for func_name in needs:
			var row := _make_need_row(func_name, false)
			checklist_container.add_child(row)
			(_moment_check_rows[mid] as Dictionary)[func_name] = row


func _make_section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	return lbl


func _make_need_row(func_name: String, satisfied: bool) -> Label:
	var row := Label.new()
	row.add_theme_font_size_override("font_size", 11)
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_set_need_row(row, func_name, satisfied)
	return row


# Objective chips: a filled green pill when solved, a dim red-outline pill when
# pending — the puzzle "goal list" reads at a glance instead of as plain text.
static func _chip_style(satisfied: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if satisfied:
		s.bg_color     = Color(0.12, 0.30, 0.17)
		s.border_color = Color(0.34, 0.68, 0.40)
	else:
		s.bg_color     = Color(0.24, 0.11, 0.12)
		s.border_color = Color(0.55, 0.25, 0.26)
	s.set_border_width_all(1)
	s.set_corner_radius_all(9)
	s.anti_aliasing = true
	s.set_content_margin(SIDE_LEFT, 9)
	s.set_content_margin(SIDE_RIGHT, 9)
	s.set_content_margin(SIDE_TOP, 3)
	s.set_content_margin(SIDE_BOTTOM, 3)
	return s


func _set_need_row(row: Label, func_name: String, satisfied: bool) -> void:
	var was_satisfied := row.get_meta("satisfied", false) as bool
	row.set_meta("satisfied", satisfied)
	row.add_theme_stylebox_override("normal", _chip_style(satisfied))
	if satisfied:
		row.text = "✓  " + func_name.capitalize()
		row.add_theme_color_override("font_color", Color(0.62, 0.88, 0.64))
		if not was_satisfied and Time.get_ticks_msec() - _setup_ticks > 800:
			_pop_chip(row)
	else:
		row.text = "✗  " + func_name.capitalize()
		row.add_theme_color_override("font_color", Color(0.90, 0.52, 0.50))


# Little scale-pop when an objective flips to solved — the classic bit of
# puzzle-game feedback that makes ticking a goal feel earned.
func _pop_chip(row: Label) -> void:
	Audio.play("place")
	row.pivot_offset = row.size * 0.5
	row.scale = Vector2.ONE
	var tw := row.create_tween()
	tw.tween_property(row, "scale", Vector2(1.22, 1.22), 0.09) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(row, "scale", Vector2.ONE, 0.14) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func update_checks(fulfilled: Array, required: Array) -> void:
	if not _moments.is_empty():
		return  # moment levels drive via update_moments
	for func_name in required:
		if not (func_name in _check_rows):
			continue
		_set_need_row(_check_rows[func_name] as Label, func_name, func_name in fulfilled)


func update_moments(results: Dictionary) -> void:
	if _moments.is_empty():
		return
	for m in _moments:
		var mid    := m["id"]    as String
		var needs  := m["needs"] as Array
		if not _moment_check_rows.has(mid):
			continue
		var rows   := _moment_check_rows[mid] as Dictionary
		var mdata  := results.get(mid, {}) as Dictionary
		var mfulfilled := mdata.get("fulfilled", []) as Array
		for func_name in needs:
			if rows.has(func_name):
				_set_need_row(rows[func_name] as Label, func_name, func_name in mfulfilled)
