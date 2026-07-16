extends PanelContainer
class_name Minimap

signal wall_selected(wall_id: String)

var _buttons: Dictionary = {}
var _labels:  Dictionary = {}   # floor_id -> base label text
var _button_group := ButtonGroup.new()

# Compact mode: this same script drives both the old tall vertical stack (a
# BottomBar sidebar) and a horizontal strip that fits in the 46px TopBar. Set
# before setup()/add_floor() so buttons are built with the right sizing.
var _compact: bool = false


# Call before setup() to lay buttons out left-to-right at TopBar height
# instead of stacked vertically.
func set_compact(compact: bool) -> void:
	_compact = compact
	var container := $HBox as BoxContainer
	container.vertical = not compact
	# Vertical mode is anchored to a fixed bottom-right corner (see Main.gd),
	# generously sized so it never has to grow as floors are added/removed —
	# bottom-aligning the buttons inside that box keeps the stack flush with
	# that corner regardless of how many floors the current level has, instead
	# of drifting up from an empty gap left below a short stack.
	container.alignment = BoxContainer.ALIGNMENT_END if not compact else BoxContainer.ALIGNMENT_BEGIN


func setup(floors: Array, hidden_ids: Array = []) -> void:
	var container: BoxContainer = $HBox
	for child in container.get_children():
		child.queue_free()
	_buttons.clear()
	_labels.clear()
	_button_group = ButtonGroup.new()

	# floors_data is authored bottom-up (ground floor first). In the old
	# vertical stack (BottomBar sidebar), that's displayed top-down like a
	# building directory — highest floor at the top — so it's reversed. In
	# the horizontal TopBar strip, "up" reads left-to-right instead, so the
	# lowest floor belongs at the left and the array's natural bottom-up
	# order is already correct as-is.
	var ordered := floors.duplicate()
	if not _compact:
		ordered.reverse()
	for fd in ordered:
		var fid := fd["id"] as String
		if fid in hidden_ids:
			continue   # designer marked this layer as invisible to player

		var btn := Button.new()
		btn.text = fd["label"] as String
		btn.add_theme_font_size_override("font_size", 9 if _compact else 10)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		if _compact:
			btn.custom_minimum_size.y = 30
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


# Bottom-to-top floor id order as currently shown (visible floors only,
# including any dynamically added loft floors) — used by Main.gd's Up/Down
# floor-switching shortcut so it steps through exactly what the tabs show.
func get_floor_order() -> Array:
	var order: Array = []
	for child in ($HBox as BoxContainer).get_children():
		for fid in _buttons:
			if _buttons[fid] == child:
				order.append(fid)
				break
	return order


# anchor_floor_id: an existing floor whose button the new one should sit
# directly above (used for a loft floor, which sits just above its base).
# Omit to append at the bottom of the list.
func add_floor(fd: Dictionary, anchor_floor_id: String = "") -> void:
	var fid := fd["id"] as String
	if fid in _buttons:
		return
	var container: BoxContainer = $HBox
	var btn := Button.new()
	btn.text = fd["label"] as String
	btn.add_theme_font_size_override("font_size", 9 if _compact else 10)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if _compact:
		btn.custom_minimum_size.y = 30
	btn.toggle_mode  = true
	btn.button_group = _button_group
	btn.pressed.connect(_on_floor_pressed.bind(fid))
	container.add_child(btn)
	if anchor_floor_id in _buttons:
		var anchor_index := (_buttons[anchor_floor_id] as Button).get_index()
		# Vertical stack lists top-down (above = earlier index); the compact
		# horizontal strip now runs low-to-high left-to-right (above = later
		# index, i.e. further right), so "sits above" places it on the
		# opposite side of the anchor depending on orientation.
		container.move_child(btn, anchor_index if not _compact else anchor_index + 1)
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
