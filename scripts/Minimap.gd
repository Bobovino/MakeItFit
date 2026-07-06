extends PanelContainer
class_name Minimap

signal wall_selected(wall_id: String)

var _buttons: Dictionary = {}
var _labels:  Dictionary = {}   # floor_id -> base label text
var _button_group := ButtonGroup.new()


func setup(floors: Array, hidden_ids: Array = []) -> void:
	var container: VBoxContainer = $HBox
	for child in container.get_children():
		child.queue_free()
	_buttons.clear()
	_labels.clear()
	_button_group = ButtonGroup.new()

	# floors_data is authored bottom-up (ground floor first); display top-down
	# like a building directory, so reverse it — highest floor at the top.
	var ordered := floors.duplicate()
	ordered.reverse()
	for fd in ordered:
		var fid := fd["id"] as String
		if fid in hidden_ids:
			continue   # designer marked this layer as invisible to player

		var btn := Button.new()
		btn.text = fd["label"] as String
		btn.add_theme_font_size_override("font_size", 10)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		btn.toggle_mode  = true
		btn.button_group = _button_group
		btn.pressed.connect(_on_floor_pressed.bind(fid))
		container.add_child(btn)
		_buttons[fid] = btn
		_labels[fid] = fd["label"] as String

		# Floors with an unlock condition start locked
		if fd.get("unlocked_by", "") != "":
			btn.disabled = true
			btn.text = btn.text + " (locked)"

	# Hide the whole switcher when there's only one visible floor
	visible = _buttons.size() > 1


# anchor_floor_id: an existing floor whose button the new one should sit
# directly above (used for a loft floor, which sits just above its base).
# Omit to append at the bottom of the list.
func add_floor(fd: Dictionary, anchor_floor_id: String = "") -> void:
	var fid := fd["id"] as String
	if fid in _buttons:
		return
	var container: VBoxContainer = $HBox
	var btn := Button.new()
	btn.text = fd["label"] as String
	btn.add_theme_font_size_override("font_size", 10)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.toggle_mode  = true
	btn.button_group = _button_group
	btn.pressed.connect(_on_floor_pressed.bind(fid))
	container.add_child(btn)
	if anchor_floor_id in _buttons:
		container.move_child(btn, (_buttons[anchor_floor_id] as Button).get_index())
	_buttons[fid] = btn
	_labels[fid]  = fd["label"] as String
	visible = _buttons.size() > 1


func remove_floor(floor_id: String) -> void:
	if not (floor_id in _buttons):
		return
	(_buttons[floor_id] as Button).queue_free()
	_buttons.erase(floor_id)
	_labels.erase(floor_id)
	visible = _buttons.size() > 1


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
