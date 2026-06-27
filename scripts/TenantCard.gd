extends PanelContainer
class_name TenantCard

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: VBoxContainer = $VBox/Checklist

# flat-list mode
var _check_rows: Dictionary = {}

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


func setup(tenant: Dictionary) -> void:
	tenant_name_label.text = "%s, %d" % [tenant["name"], tenant["age"]]
	flavor_label.text = tenant["flavor"]
	rent_label.text = "%d€ / month" % tenant["monthly_rent"]
	_moments = []
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
	_set_need_row(row, func_name, satisfied)
	return row


func _set_need_row(row: Label, func_name: String, satisfied: bool) -> void:
	if satisfied:
		row.text = "✓  " + func_name
		row.add_theme_color_override("font_color", Color(0.38, 0.72, 0.42))
	else:
		row.text = "✗  " + func_name
		row.add_theme_color_override("font_color", Color(0.78, 0.28, 0.28))


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
