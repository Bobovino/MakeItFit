extends CanvasLayer
class_name ResultScreen

signal next_level_requested
signal retry_requested

@onready var title_label: Label  = $Panel/VBox/Title
@onready var body_label:  Label  = $Panel/VBox/Body
@onready var rent_bar:    Label  = $Panel/VBox/RentBar
@onready var next_btn:    Button = $Panel/VBox/NextButton
@onready var retry_btn:   Button = $Panel/VBox/RetryButton

var _stars_label: Label = null


func _ready() -> void:
	var s := StyleBoxFlat.new()
	s.bg_color     = Color(0.115, 0.100, 0.085, 0.97)
	s.border_color = Color(0.320, 0.270, 0.205)
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

	rent_bar.add_theme_font_size_override("font_size", 12)
	rent_bar.add_theme_color_override("font_color", Color(0.50, 0.76, 0.52))
	rent_bar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Stars label inserted between body and rent_bar
	_stars_label = Label.new()
	_stars_label.add_theme_font_size_override("font_size", 22)
	_stars_label.add_theme_color_override("font_color", GameTheme.C_AMBER)
	_stars_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	$Panel/VBox.add_child(_stars_label)
	$Panel/VBox.move_child(_stars_label, rent_bar.get_index())

	next_btn.custom_minimum_size  = Vector2(220, 44)
	next_btn.add_theme_font_size_override("font_size", 13)
	retry_btn.custom_minimum_size = Vector2(220, 44)
	retry_btn.add_theme_font_size_override("font_size", 13)


func show_success(stars: int, funds_earned: int, portfolio_rent: int,
		tenant_name: String, _level_rent: int) -> void:
	visible = true
	next_btn.visible  = true
	retry_btn.visible = false

	if GameState.is_retired():
		title_label.text = "RETIREMENT ACHIEVED"
		body_label.text  = "You retire.\nGen Z pays for it. As always."
		next_btn.text    = "Retire"
	else:
		title_label.text = "RENTED OUT"
		body_label.text  = (
			"Congratulations. You have successfully reduced\n%s's quality of life by 40%%." % tenant_name
		)
		next_btn.text = "Back to City"

	_animate_stars(stars)

	rent_bar.text = (
		"+%d€ CompanyFunds   |   Portfolio: %d€/mo → %d€/mo" % [
			funds_earned, portfolio_rent, GameState.RETIRE_GOAL
		]
	)


# Stars fill in one at a time with a pop — the standard puzzle-game results
# beat, instead of the rating just sitting there fully formed.
func _animate_stars(stars: int) -> void:
	_stars_label.text = "☆☆☆"
	_stars_label.pivot_offset = _stars_label.size * 0.5
	var tw := create_tween()
	for i in range(1, stars + 1):
		var filled := i
		tw.tween_interval(0.35)
		tw.tween_callback(func():
			_stars_label.text = "★".repeat(filled) + "☆".repeat(3 - filled)
			_stars_label.pivot_offset = _stars_label.size * 0.5
			Audio.play("place"))
		tw.tween_property(_stars_label, "scale", Vector2(1.35, 1.35), 0.08) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(_stars_label, "scale", Vector2.ONE, 0.15) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func show_failure(reason: String) -> void:
	visible = true
	title_label.text   = "NOT RENTED"
	body_label.text    = reason
	if _stars_label:
		_stars_label.text  = ""
	rent_bar.text      = ""
	next_btn.visible   = false
	retry_btn.visible  = true


func _on_next_pressed() -> void:
	visible = false
	next_btn.visible = true
	next_level_requested.emit()


func _on_retry_pressed() -> void:
	visible = false
	retry_requested.emit()
