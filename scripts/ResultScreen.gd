extends CanvasLayer
class_name ResultScreen

signal next_level_requested
signal retry_requested

const RETIRE_GOAL := 3000

@onready var title_label: Label = $Panel/VBox/Title
@onready var body_label: Label = $Panel/VBox/Body
@onready var rent_bar: Label = $Panel/VBox/RentBar
@onready var next_btn: Button = $Panel/VBox/NextButton
@onready var retry_btn: Button = $Panel/VBox/RetryButton


func _ready() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.09, 0.11, 0.16, 0.97)
	s.border_color = Color(0.22, 0.28, 0.36)
	s.set_border_width_all(1)
	s.set_content_margin_all(40)
	($Panel as Control).add_theme_stylebox_override("panel", s)
	($Panel as Control).theme = GameTheme.make()

	title_label.add_theme_font_size_override("font_size", 28)
	title_label.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	body_label.add_theme_font_size_override("font_size", 13)
	body_label.add_theme_color_override("font_color", Color(0.75, 0.72, 0.65))
	body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	rent_bar.add_theme_font_size_override("font_size", 11)
	rent_bar.add_theme_color_override("font_color", Color(0.50, 0.76, 0.52))
	rent_bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	next_btn.custom_minimum_size = Vector2(220, 44)
	next_btn.add_theme_font_size_override("font_size", 13)
	retry_btn.custom_minimum_size = Vector2(220, 44)
	retry_btn.add_theme_font_size_override("font_size", 13)


func show_success(monthly_rent: int, tenant_name: String, _rent_earned: int) -> void:
	visible = true
	if monthly_rent >= RETIRE_GOAL:
		title_label.text = "RETIREMENT ACHIEVED"
		body_label.text = "You retire.\nGen Z pays for it. As always."
		next_btn.text = "Retire"
		retry_btn.visible = false
	else:
		title_label.text = "RENTED OUT"
		body_label.text = (
			"Congratulations. You have successfully reduced\n%s's quality of life by 40%%." % tenant_name
		)
		next_btn.text = "Next Apartment"
		retry_btn.visible = false

	rent_bar.text = "Passive income: %d€ / %d€ per month" % [monthly_rent, RETIRE_GOAL]


func show_failure(reason: String) -> void:
	visible = true
	title_label.text = "NOT RENTED"
	body_label.text = reason
	next_btn.visible = false
	retry_btn.visible = true


func _on_next_pressed() -> void:
	visible = false
	next_level_requested.emit()


func _on_retry_pressed() -> void:
	visible = false
	retry_requested.emit()
