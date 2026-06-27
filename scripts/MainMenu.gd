extends Control


func _draw() -> void:
	# Blueprint grid overlay on top of the background
	var sz := get_viewport_rect().size
	var step := 40.0
	var gc := Color(0.22, 0.28, 0.38, 0.35)
	for x in range(0, int(sz.x) + 1, int(step)):
		draw_line(Vector2(x, 0), Vector2(x, sz.y), gc, 0.5)
	for y in range(0, int(sz.y) + 1, int(step)):
		draw_line(Vector2(0, y), Vector2(sz.x, y), gc, 0.5)


func _ready() -> void:
	theme = GameTheme.make()

	# Background
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.08, 0.10, 0.15)   # deep navy
	add_child(bg)

	# Centered column
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 18)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(vbox)

	_add_label(vbox, "MAKE IT FIT", 52, Color(0.95, 0.88, 0.55))
	_add_label(vbox, "Furnish. Satisfy. Retire.", 14, Color(0.52, 0.64, 0.74))

	_spacer(vbox, 16)

	_add_label(vbox, "35 apartments across 10 Berlin districts", 12, Color(0.55, 0.62, 0.70))
	_add_label(vbox, "Build your property portfolio. Reach 10 000€/month. Retire.", 12, Color(0.42, 0.50, 0.58))

	_spacer(vbox, 28)

	var start_btn := Button.new()
	start_btn.text = "Start Game"
	start_btn.custom_minimum_size = Vector2(240, 52)
	start_btn.add_theme_font_size_override("font_size", 15)
	# Override with amber-tinted style for the primary CTA
	var rs := GameTheme.make_rent_btn_style()
	start_btn.add_theme_stylebox_override("normal",  rs[0])
	start_btn.add_theme_stylebox_override("hover",   rs[1])
	start_btn.add_theme_stylebox_override("pressed", rs[1])
	start_btn.add_theme_color_override("font_color",       GameTheme.C_AMBER)
	start_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.72))
	start_btn.pressed.connect(_on_start)
	vbox.add_child(start_btn)

	var editor_btn := Button.new()
	editor_btn.text = "Level Editor"
	editor_btn.custom_minimum_size = Vector2(240, 36)
	editor_btn.add_theme_font_size_override("font_size", 12)
	editor_btn.add_theme_color_override("font_color", Color(0.52, 0.74, 0.62))
	editor_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/LevelEditor.tscn"))
	vbox.add_child(editor_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit"
	quit_btn.custom_minimum_size = Vector2(240, 36)
	quit_btn.add_theme_font_size_override("font_size", 12)
	quit_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	quit_btn.pressed.connect(_on_quit)
	vbox.add_child(quit_btn)


func _on_start() -> void:
	get_tree().change_scene_to_file("res://scenes/CityMap.tscn")


func _on_quit() -> void:
	get_tree().quit()


func _add_label(parent: Control, text: String, font_size: int, col: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.modulate = col
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(lbl)


func _spacer(parent: Control, h: int) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	parent.add_child(s)
