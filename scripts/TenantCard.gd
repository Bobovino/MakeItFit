extends PanelContainer
class_name TenantCard

@onready var tenant_name_label: Label = $VBox/TenantName
@onready var flavor_label: Label = $VBox/Flavor
@onready var rent_label: Label = $VBox/Rent
@onready var checklist_container: VBoxContainer = $VBox/Checklist

var _check_rows: Dictionary = {}


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
	_build_checklist(tenant["required_functions"])


func _build_checklist(required: Array) -> void:
	for child in checklist_container.get_children():
		checklist_container.remove_child(child)
		child.queue_free()
	_check_rows.clear()

	var hdr := Label.new()
	hdr.text = "NEEDS"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	checklist_container.add_child(hdr)

	for func_name in required:
		var row := Label.new()
		row.text = "✗  " + func_name
		row.add_theme_font_size_override("font_size", 11)
		row.add_theme_color_override("font_color", Color(0.78, 0.28, 0.28))
		checklist_container.add_child(row)
		_check_rows[func_name] = row


func update_checks(fulfilled: Array, required: Array) -> void:
	for func_name in required:
		if not (func_name in _check_rows):
			continue
		var row: Label = _check_rows[func_name]
		if func_name in fulfilled:
			row.text = "✓  " + func_name
			row.add_theme_color_override("font_color", Color(0.38, 0.72, 0.42))
		else:
			row.text = "✗  " + func_name
			row.add_theme_color_override("font_color", Color(0.78, 0.28, 0.28))
