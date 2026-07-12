extends CanvasLayer
class_name ResultScreen

signal next_level_requested     # "Back to Projects" (also doubles as "Retire" at the retirement goal)
signal retry_requested
signal watch_again_requested    # "View Apartment" — close this modal and hand the player free camera control
signal advance_level_requested  # "Next Level" — load the next owned level directly, skipping CityMap

@onready var title_label: Label  = $Panel/VBox/Title
@onready var body_label:  Label  = $Panel/VBox/Body
@onready var rent_bar:    Label  = $Panel/VBox/RentBar
@onready var next_btn:    Button = $Panel/VBox/NextButton
@onready var retry_btn:   Button = $Panel/VBox/RetryButton

# Built dynamically (not in Main.tscn) — same reasoning as CreditsMenu.gd this
# session: avoids waiting on Godot's editor to notice scene-file changes.
var watch_btn:   Button = null
var advance_btn: Button = null

var _stars_label: Label = null
var _stamp: Label = null


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

	# Inserted right above NextButton, in this order: View Apartment, then
	# Next Level, then the existing Back to Projects/Retry — "keep looking"
	# and "move on" read as options offered before the exit action, not after.
	watch_btn = Button.new()
	watch_btn.text = "🔍 View Apartment"
	watch_btn.custom_minimum_size = Vector2(220, 44)
	watch_btn.add_theme_font_size_override("font_size", 13)
	watch_btn.pressed.connect(func(): watch_again_requested.emit())
	$Panel/VBox.add_child(watch_btn)
	$Panel/VBox.move_child(watch_btn, next_btn.get_index())

	advance_btn = Button.new()
	advance_btn.text = "Next Level →"
	advance_btn.custom_minimum_size = Vector2(220, 44)
	advance_btn.add_theme_font_size_override("font_size", 13)
	advance_btn.pressed.connect(func():
		visible = false
		advance_level_requested.emit())
	$Panel/VBox.add_child(advance_btn)
	$Panel/VBox.move_child(advance_btn, next_btn.get_index())

	# "APPROVED" rubber stamp — slams down tilted over the panel's top-right
	# corner on success, like a permit office signing off on the drawing.
	_stamp = Label.new()
	_stamp.text = "APPROVED"
	var hand := GameTheme.handwriting()
	if hand:
		_stamp.add_theme_font_override("font", hand)
	_stamp.add_theme_font_size_override("font_size", 30)
	_stamp.add_theme_color_override("font_color", Color(0.780, 0.320, 0.260, 0.90))
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0)
	st.border_color = Color(0.780, 0.320, 0.260, 0.85)
	st.set_border_width_all(3)
	st.set_corner_radius_all(6)
	st.set_content_margin(SIDE_LEFT, 12)
	st.set_content_margin(SIDE_RIGHT, 12)
	st.set_content_margin(SIDE_TOP, 2)
	st.set_content_margin(SIDE_BOTTOM, 2)
	st.anti_aliasing = true
	_stamp.add_theme_stylebox_override("normal", st)
	_stamp.rotation_degrees = -9.0
	_stamp.visible = false
	_stamp.z_index = 10
	# A direct child of Panel (a PanelContainer) gets its position silently
	# overridden on every layout pass — Containers auto-position ALL direct
	# children, ignoring anything set manually, so the stamp would only sit
	# where we put it until the next resize/re-sort (e.g. toggling `visible`
	# for Watch Again) snapped it back to wherever the Container's own layout
	# rules put a second child. Parenting it to the CanvasLayer instead (not
	# a Container) makes the manual position stick permanently.
	add_child(_stamp)


func _slam_stamp() -> void:
	var panel := $Panel as Control
	_stamp.visible = true
	# The label reports size 0 until it has been laid out once — force it to
	# shrink-wrap its text NOW so pivot/position math uses the real box.
	_stamp.reset_size()
	await get_tree().process_frame
	_stamp.reset_size()
	_stamp.pivot_offset = _stamp.size * 0.5
	_stamp.position = panel.position + Vector2(panel.size.x - _stamp.size.x - 30, 16)
	_stamp.scale = Vector2(2.4, 2.4)
	_stamp.modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_stamp, "scale", Vector2.ONE, 0.22) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)
	tw.tween_property(_stamp, "modulate", Color(1, 1, 1, 1), 0.18)
	tw.chain().tween_callback(func(): Audio.play("demolish"))


func show_success(stars: int, funds_earned: int, portfolio_rent: int,
		tenant_name: String, _level_rent: int, has_next_level: bool = false) -> void:
	visible = true
	next_btn.visible    = true
	retry_btn.visible   = false
	watch_btn.visible   = true
	advance_btn.visible = has_next_level

	if GameState.is_retired():
		title_label.text = "RETIREMENT ACHIEVED"
		body_label.text  = "You retire.\nGen Z pays for it. As always."
		next_btn.text    = "Retire"
		advance_btn.visible = false
	else:
		title_label.text = "RENTED OUT"
		body_label.text  = (
			"Congratulations. You have successfully reduced\n%s's quality of life by 40%%." % tenant_name
		)
		next_btn.text = "Back to Projects"

	_animate_stars(stars)
	call_deferred("_slam_stamp")

	rent_bar.text = (
		"+%d€ Studio Funds   |   Portfolio: %d€/mo → %d€/mo" % [
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
	if _stamp:
		_stamp.visible = false
	title_label.text   = "NOT RENTED"
	body_label.text    = reason
	if _stars_label:
		_stars_label.text  = ""
	rent_bar.text      = ""
	next_btn.visible    = false
	retry_btn.visible   = true
	watch_btn.visible   = false
	advance_btn.visible = false


func _on_next_pressed() -> void:
	visible = false
	next_btn.visible = true
	next_level_requested.emit()


func _on_retry_pressed() -> void:
	visible = false
	retry_requested.emit()
