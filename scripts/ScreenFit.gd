class_name ScreenFit
extends RefCounted

# Helpers for screens that were laid out for the 1280 x 720 design size and
# now have to sit correctly in a window of any shape.
#
#   cover(bg)             a full-screen backdrop covers the whole window,
#                         whatever its size, and keeps doing so on resize.
#   keep_centered(card)   a card placed at a fixed spot in the 1280 x 720
#                         layout keeps its place relative to the window's
#                         centre: it moves by half of whatever the window has
#                         over (or under) the design size.

const DESIGN := Vector2(1280, 720)


static func cover(bg: Control) -> void:
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


static func keep_centered(card: Control) -> void:
	card.set_meta("design_pos", card.position)
	var apply := func():
		if not is_instance_valid(card) or not card.is_inside_tree():
			return
		var extra := card.get_viewport().get_visible_rect().size - DESIGN
		card.position = (card.get_meta("design_pos") as Vector2) + extra * 0.5
	if card.is_inside_tree():
		_hook(card, apply)
	else:
		card.tree_entered.connect(func(): _hook(card, apply), CONNECT_ONE_SHOT)


static func _hook(card: Control, apply: Callable) -> void:
	apply.call()
	card.get_viewport().size_changed.connect(apply)
	card.tree_exiting.connect(func():
		var vp := card.get_viewport()
		if vp and vp.size_changed.is_connected(apply):
			vp.size_changed.disconnect(apply))


# The window's size in layout units.
static func size_of(node: Node) -> Vector2:
	return node.get_viewport().get_visible_rect().size
