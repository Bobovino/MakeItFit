extends Control

const RETIRE_GOAL := 3000

var _level_names: Array = [
	"Charlottenburg Starter",
	"The Student Den",
	"Prenzlauer Loft",
	"Mitte Compact",
	"Friedrichshain Open Plan",
	"Kreuzberg Commune"
]
var _level_rents: Array = [300, 400, 450, 600, 700, 550]


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

	_add_label(vbox, "MAKE IT FIT", 52, Color(0.95, 0.88, 0.55))   # warm amber
	_add_label(vbox, "Furnish. Satisfy. Retire.", 14, Color(0.52, 0.64, 0.74))

	_spacer(vbox, 20)

	# Level list
	var level_box := VBoxContainer.new()
	level_box.add_theme_constant_override("separation", 4)
	vbox.add_child(level_box)

	var total := 0
	for i in range(_level_names.size()):
		total += _level_rents[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		level_box.add_child(row)
		var num := Label.new()
		num.text = "%d." % (i + 1)
		num.custom_minimum_size = Vector2(24, 0)
		num.add_theme_font_size_override("font_size", 12)
		num.modulate = Color(0.55, 0.50, 0.42)
		row.add_child(num)
		var name_lbl := Label.new()
		name_lbl.text = _level_names[i]
		name_lbl.custom_minimum_size = Vector2(240, 0)
		name_lbl.add_theme_font_size_override("font_size", 12)
		name_lbl.modulate = Color(0.70, 0.78, 0.86)
		row.add_child(name_lbl)
		var rent_lbl := Label.new()
		rent_lbl.text = "+%d€/mo" % _level_rents[i]
		rent_lbl.add_theme_font_size_override("font_size", 12)
		rent_lbl.modulate = Color(0.50, 0.78, 0.60)
		row.add_child(rent_lbl)

	_spacer(vbox, 4)
	var goal_lbl := Label.new()
	goal_lbl.text = "Total: %d€/month  —  Retire at %d€/month" % [total, RETIRE_GOAL]
	goal_lbl.add_theme_font_size_override("font_size", 12)
	goal_lbl.modulate = Color(0.95, 0.88, 0.55)
	goal_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(goal_lbl)

	_spacer(vbox, 24)

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

	var quit_btn := Button.new()
	quit_btn.text = "Quit"
	quit_btn.custom_minimum_size = Vector2(240, 36)
	quit_btn.add_theme_font_size_override("font_size", 12)
	quit_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	quit_btn.pressed.connect(_on_quit)
	vbox.add_child(quit_btn)


func _on_start() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")


func _on_quit() -> void:
	get_tree().quit()


func _add_label(parent: Control, text: String, size: int, col: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.modulate = col
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(lbl)


func _spacer(parent: Control, h: int) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	parent.add_child(s)
