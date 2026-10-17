extends CanvasLayer
class_name NestedMap

# Modal map of every apartment reachable from the top one: a tree with one
# node per apartment (the top apartment, then each nested box's interior
# under the apartment its box sits in). Click a node to jump there.
#
# Purely a view: Main.gd builds the tree (see Main._build_nested_tree()) and
# does the actual travelling when node_chosen fires. Each tree node is a
# Dictionary:
#   name, level_id        what to show
#   path, hops            opaque to this script, handed back in node_chosen
#   is_current            the apartment the player is in right now
#   shared                this same interior also appears elsewhere in the tree
#   enterable             false for an interior too small to step into
#   segments, bounds, furniture   BlueprintPreview data
#   children              Array of the same

signal node_chosen(path: Array, hops: Array)
signal closed

const NODE_W  := 124.0
const NODE_H  := 138.0
const GAP_X   := 18.0
const GAP_Y   := 44.0
const MAX_VIEW := Vector2(1000.0, 520.0)

var _edges: Array = []   # [[from: Vector2, to: Vector2]] in tree-canvas space


static func open(host: Node, tree: Dictionary) -> NestedMap:
	var m := NestedMap.new()
	host.add_child(m)
	m._build(tree)
	return m


func _build(tree: Dictionary) -> void:
	layer = 26   # above the settings menu's 25, so it can never open underneath it

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	ScreenFit.cover(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			_close())

	# Lay the tree out first: its size decides the card's.
	var canvas := _TreeCanvas.new()
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var leaves := _count_leaves(tree)
	var depth := _depth(tree)
	var tree_size := Vector2(
		leaves * NODE_W + (leaves - 1) * GAP_X,
		depth * NODE_H + (depth - 1) * GAP_Y)
	canvas.custom_minimum_size = tree_size
	_place(canvas, tree, 0.0, 0)
	canvas.edges = _edges

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.115, 0.100, 0.085)
	cs.border_color = GameTheme.C_BORDER
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(10)
	cs.anti_aliasing = true
	cs.set_content_margin_all(20)
	cs.shadow_color = Color(0, 0, 0, 0.4)
	cs.shadow_size = 10
	card.add_theme_stylebox_override("panel", cs)
	add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	card.add_child(vb)

	var title_row := HBoxContainer.new()
	vb.add_child(title_row)
	var title := Label.new()
	title.text = tr("APARTMENT MAP")
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = tr("Close")
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.pressed.connect(_close)
	title_row.add_child(close_btn)

	var hint := Label.new()
	hint.text = tr("Every apartment in this project. Click one to go there.")
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(hint)

	# A big tree scrolls inside the card rather than growing past the screen.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(
		minf(tree_size.x, MAX_VIEW.x) + 12.0, minf(tree_size.y, MAX_VIEW.y) + 12.0)
	scroll.add_child(canvas)
	vb.add_child(scroll)

	_center.call_deferred(card)


func _center(card: Control) -> void:
	await get_tree().process_frame
	if is_instance_valid(card):
		card.position = ((ScreenFit.size_of(card) - card.size) * 0.5).max(Vector2(4, 4))


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_close()


func _count_leaves(node: Dictionary) -> int:
	var children := node.get("children", []) as Array
	if children.is_empty():
		return 1
	var total := 0
	for c in children:
		total += _count_leaves(c as Dictionary)
	return total


func _depth(node: Dictionary) -> int:
	var deepest := 0
	for c in node.get("children", []) as Array:
		deepest = maxi(deepest, _depth(c as Dictionary))
	return deepest + 1


# Classic tidy-tree placement: each node is centred over the span its own
# leaves occupy. Returns the x centre it used, so the parent can draw its
# connector there.
func _place(canvas: Control, node: Dictionary, left: float, level: int) -> float:
	var span := _count_leaves(node) * NODE_W + (_count_leaves(node) - 1) * GAP_X
	var center_x := left + span * 0.5
	var top := level * (NODE_H + GAP_Y)
	var child_left := left
	for c in node.get("children", []) as Array:
		var child := c as Dictionary
		var child_span := _count_leaves(child) * NODE_W + (_count_leaves(child) - 1) * GAP_X
		var child_x := _place(canvas, child, child_left, level + 1)
		_edges.append([Vector2(center_x, top + NODE_H), Vector2(child_x, top + NODE_H + GAP_Y)])
		child_left += child_span + GAP_X
	var card := _make_node(node)
	card.position = Vector2(center_x - NODE_W * 0.5, top)
	canvas.add_child(card)
	return center_x


func _make_node(node: Dictionary) -> Control:
	var is_current := node.get("is_current", false) as bool
	var enterable := node.get("enterable", true) as bool

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(NODE_W, NODE_H)
	btn.size = Vector2(NODE_W, NODE_H)
	btn.disabled = is_current or not enterable
	var normal := GameTheme.make_card_stylebox(Color(0.165, 0.145, 0.120), GameTheme.C_BORDER, 8)
	var hover := GameTheme.make_card_stylebox(Color(0.230, 0.195, 0.140), GameTheme.C_AMBER, 8)
	var here := GameTheme.make_card_stylebox(Color(0.270, 0.215, 0.115), GameTheme.C_AMBER, 8)
	here.set_border_width_all(2)
	btn.add_theme_stylebox_override("normal", here if is_current else normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_stylebox_override("disabled", here if is_current else normal)
	if is_current:
		btn.tooltip_text = tr("You are here")
	elif not enterable:
		btn.tooltip_text = tr("Too small inside to step into")
	else:
		btn.tooltip_text = tr("Go to %s") % (node.get("name", "") as String)
	btn.pressed.connect(func():
		node_chosen.emit(node.get("path", []) as Array, node.get("hops", []) as Array)
		_close())

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 6; vb.offset_right = -6; vb.offset_top = 5; vb.offset_bottom = -5
	vb.add_theme_constant_override("separation", 3)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = node.get("name", "") as String
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", GameTheme.C_AMBER if is_current else GameTheme.C_TEXT)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_lbl.max_lines_visible = 2
	name_lbl.custom_minimum_size = Vector2(0, 28)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_lbl)

	# Whether this apartment's tenants are satisfied: the project is rented
	# out only when every one of them is.
	var state := node.get("state", "none") as String
	if state != "none":
		var st := Label.new()
		st.add_theme_font_size_override("font_size", 10)
		st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		match state:
			"ready":
				st.text = "\uea5e " + tr("Ready")
				st.add_theme_color_override("font_color", Color(0.56, 0.85, 0.50))
			"recheck":
				st.text = "⟳ " + tr("Check again")
				st.add_theme_color_override("font_color", GameTheme.C_AMBER)
			_:
				st.text = "\ueb55 " + tr("To furnish")
				st.add_theme_color_override("font_color", Color(0.90, 0.48, 0.42))
		vb.add_child(st)

	# Blueprint thumbnail, letterboxed into a fixed box so every node is the
	# same size and the tree stays a regular grid.
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0, 74)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(holder)
	var preview := BlueprintPreview.new()
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bounds := node.get("bounds", Rect2()) as Rect2
	var aspect := bounds.size.y / maxf(bounds.size.x, 1.0) if bounds.size.x > 0.0 else 0.75
	preview.custom_minimum_size = Vector2(98, 98 * aspect) if aspect <= 74.0 / 98.0 else Vector2(74 / aspect, 74)
	preview.set_data(node.get("segments", []) as Array, bounds, node.get("furniture", []) as Array)
	holder.add_child(preview)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 9)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_current:
		tag.text = tr("You are here")
		tag.add_theme_color_override("font_color", GameTheme.C_AMBER)
	elif node.get("shared", false):
		# Two boxes can point at one interior; it is the same room both times.
		tag.text = tr("Same room as another box")
		tag.add_theme_color_override("font_color", GameTheme.C_MUTED)
	elif not enterable:
		tag.text = tr("Too small to enter")
		tag.add_theme_color_override("font_color", GameTheme.C_MUTED)
	vb.add_child(tag)
	return btn


func _close() -> void:
	closed.emit()
	queue_free()


# Draws the connectors behind the node cards: down from the parent, across,
# down into the child.
class _TreeCanvas extends Control:
	var edges: Array = []

	func _draw() -> void:
		for e in edges:
			var from: Vector2 = e[0]
			var to: Vector2 = e[1]
			var mid_y := (from.y + to.y) * 0.5
			draw_polyline(PackedVector2Array([from, Vector2(from.x, mid_y), Vector2(to.x, mid_y), to]),
				GameTheme.C_BORDER.lightened(0.25), 2.0, true)
