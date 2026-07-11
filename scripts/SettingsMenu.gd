extends CanvasLayer
class_name SettingsMenu

# Self-contained settings modal: SFX/Music volume sliders (wired straight to
# the Audio autoload's buses) and a confirm-gated Quit to Desktop. Usable from
# anywhere — CityMap and Main both just do `SettingsMenu.open(self)`.

signal closed


static func open(host: Node) -> SettingsMenu:
	var m := SettingsMenu.new()
	host.add_child(m)
	m._build()
	return m


func _build() -> void:
	layer = 25  # above the mechanic-intro card (20) in case both ever stack

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.88)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_close())

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
	cs.border_color = GameTheme.C_BORDER
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(10)
	cs.anti_aliasing = true
	cs.set_content_margin_all(24)
	cs.shadow_color = Color(0, 0, 0, 0.4)
	cs.shadow_size  = 10
	card.add_theme_stylebox_override("panel", cs)
	card.position            = Vector2(440, 220)
	card.custom_minimum_size = Vector2(400, 260)
	add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.add_child(vb)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(title)

	var audio := get_node_or_null("/root/Audio")

	vb.add_child(_build_slider_row("SFX Volume",
		audio.sfx_volume if audio else 1.0,
		func(v: float):
			if audio:
				audio.set_sfx_volume(v)
			GameState.save_game()))

	vb.add_child(_build_slider_row("Music Volume",
		audio.music_volume if audio else 0.7,
		func(v: float):
			if audio:
				audio.set_music_volume(v)
			GameState.save_game()))

	var sep := HSeparator.new()
	vb.add_child(sep)

	# Quit to Desktop — click once to arm, click again to confirm
	var quit_row := VBoxContainer.new()
	quit_row.add_theme_constant_override("separation", 6)
	vb.add_child(quit_row)

	var quit_btn := Button.new()
	quit_btn.text = "Quit to Desktop"
	quit_btn.add_theme_font_size_override("font_size", 13)
	quit_row.add_child(quit_btn)

	var confirm_row := HBoxContainer.new()
	confirm_row.visible = false
	confirm_row.add_theme_constant_override("separation", 8)
	quit_row.add_child(confirm_row)

	var confirm_lbl := Label.new()
	confirm_lbl.text = "Quit for real?"
	confirm_lbl.add_theme_font_size_override("font_size", 12)
	confirm_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	confirm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_row.add_child(confirm_lbl)

	var yes_btn := Button.new()
	yes_btn.text = "Yes, quit"
	yes_btn.add_theme_font_size_override("font_size", 12)
	yes_btn.add_theme_color_override("font_color", Color(0.90, 0.45, 0.35))
	yes_btn.pressed.connect(func(): get_tree().quit())
	confirm_row.add_child(yes_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 12)
	cancel_btn.pressed.connect(func():
		confirm_row.visible = false
		quit_btn.visible = true)
	confirm_row.add_child(cancel_btn)

	quit_btn.pressed.connect(func():
		quit_btn.visible = false
		confirm_row.visible = true)

	# Bottom spacer + Close
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(push)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	var rs := GameTheme.make_rent_btn_style()
	close_btn.add_theme_stylebox_override("normal",  rs[0])
	close_btn.add_theme_stylebox_override("hover",   rs[1])
	close_btn.add_theme_stylebox_override("pressed", rs[1])
	close_btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	close_btn.pressed.connect(_close)
	vb.add_child(close_btn)


func _build_slider_row(label_text: String, initial: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.custom_minimum_size.x = 120
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step       = 0.01
	slider.value      = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var pct := Label.new()
	pct.text = "%d%%" % int(round(initial * 100.0))
	pct.add_theme_font_size_override("font_size", 12)
	pct.add_theme_color_override("font_color", GameTheme.C_MUTED)
	pct.custom_minimum_size.x = 40
	row.add_child(pct)

	slider.value_changed.connect(func(v: float):
		pct.text = "%d%%" % int(round(v * 100.0))
		on_change.call(v))

	return row


func _close() -> void:
	closed.emit()
	queue_free()
