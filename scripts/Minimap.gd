extends PanelContainer
class_name Minimap

signal wall_selected(wall_id: String)

var _buttons: Dictionary = {}
var _labels:  Dictionary = {}   # floor_id -> base label text


func setup(floors: Array) -> void:
	var container: HBoxContainer = $HBox
	for child in container.get_children():
		child.queue_free()
	_buttons.clear()
	_labels.clear()

	for fd in floors:
		var btn := Button.new()
		btn.text = fd["label"] as String
		btn.custom_minimum_size = Vector2(90, 40)
		btn.pressed.connect(_on_floor_pressed.bind(fd["id"] as String))
		container.add_child(btn)
		_buttons[fd["id"]] = btn
		_labels[fd["id"]] = fd["label"] as String

		# Floors with an unlock condition start locked
		if fd.get("unlocked_by", "") != "":
			btn.disabled = true
			btn.text = btn.text + " (locked)"


func highlight(floor_id: String) -> void:
	for id in _buttons:
		(_buttons[id] as Button).button_pressed = (id == floor_id)


func set_floor_locked(floor_id: String, locked: bool) -> void:
	if not (floor_id in _buttons):
		return
	var btn: Button  = _buttons[floor_id] as Button
	var lbl: String  = _labels.get(floor_id, floor_id) as String
	btn.disabled = locked
	btn.text     = lbl + (" (locked)" if locked else "")


func _on_floor_pressed(floor_id: String) -> void:
	highlight(floor_id)
	wall_selected.emit(floor_id)
