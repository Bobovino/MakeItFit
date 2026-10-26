extends CanvasLayer
class_name PauseMenu

# What Esc (or the gear) opens, in a level and on the project map: a short
# list, the way games have it, with going back to what you were doing
# first and selected, so Esc-Enter or Esc-Esc both return you. Settings
# and How to Play open over it and come back to it; leaving or restarting
# the level is here too, and what can't be undone asks first. Credits live
# on the title screen, which the map's menu goes back to.
#
# The host decides what is on offer: a level (Main) has _restart_level and
# _go_back; any host may have more.

signal closed

var _host: Node
var _first: Button


static func open(host: Node) -> PauseMenu:
	var m := PauseMenu.new()
	m._host = host
	host.add_child(m)
	m._build()
	return m


func _build() -> void:
	layer = 24
	for c in get_children():
		c.queue_free()
	MenuKit._backdrop(self, _close)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	ScreenFit.cover(center)

	var card := PanelContainer.new()
	card.theme = GameTheme.make()
	card.add_theme_stylebox_override("panel", MenuKit._card_style(MenuKit.PANEL_BG, 14, 0))
	center.add_child(card)
	var vb := MenuKit._margins(VBoxContainer.new(), 26, 12, 26, 24)
	card.add_child(vb.get_parent())
	vb.add_theme_constant_override("separation", 8)
	vb.custom_minimum_size.x = 380

	var head := HBoxContainer.new()
	vb.add_child(head)
	var t := GameTheme.title_label(tr("Menu"))
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var x := MenuKit.close_button(_close)
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(x)

	var in_level := _host != null and _host.has_method("_restart_level")
	_first = _entry(vb, tr("Continue"), "primary", _close)
	_entry(vb, tr("Settings"), "", func(): _over(SettingsMenu.open(self)))
	_entry(vb, tr("How to Play"), "", func(): _over(HowToPlay.open(self)))
	_gap(vb)
	# On the map: back to the title screen (Continue, Credits and the rest).
	if not in_level:
		_entry(vb, tr("Title screen"), "", func():
			_close()
			Transition.change_scene("res://scenes/MainMenu.tscn"))
	if in_level:
		_entry(vb, tr("Restart Level"), "", func():
			MenuKit.dialog(self, tr("Restart Level"), tr("Discard this layout and start over?"),
				tr("Yes, restart"), func():
					_close()
					_host.call("_restart_level")))
		if _host.has_method("_go_back"):
			_entry(vb, tr("Back to Projects"), "", func():
				_close()
				_host.call("_go_back"))
	_entry(vb, tr("Quit Game"), "danger", func():
		MenuKit.dialog(self, tr("Quit Game"), tr("Quit for real?"), tr("Yes, quit"),
			func(): get_tree().quit()))
	_first.grab_focus.call_deferred()


func _entry(vb: VBoxContainer, text: String, kind: String, on_press: Callable) -> Button:
	var b := MenuKit.menu_button(text, kind)
	b.pressed.connect(on_press)   # MenuKit's button clicks by itself
	vb.add_child(b)
	return b


func _gap(vb: VBoxContainer) -> void:
	var g := Control.new()
	g.custom_minimum_size.y = 8
	vb.add_child(g)


# A window opened over this one hands the selection back when it closes.
func _over(child: Node) -> void:
	var back_to := get_viewport().gui_get_focus_owner()
	child.tree_exited.connect(func():
		if is_instance_valid(back_to) and back_to.is_inside_tree():
			back_to.grab_focus())


# The language changed: the same menu again, in the new one.
func rebuild() -> void:
	_build()


func _input(event: InputEvent) -> void:
	if MenuKit.is_escape(event):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
