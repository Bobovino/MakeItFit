extends Control

# The first screen: the ajustador's drawing board, the same indigo sheet the
# plan lies on, with the title in the capsule's letter on the left and what
# to do on the right, as white cards.

var _title_box: Control = null
var _buttons: VBoxContainer = null


func _ready() -> void:
	theme = GameTheme.make()
	add_child(DeskBackdrop.new())

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 72)
	for side in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 48)
	add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 48)
	margin.add_child(row)

	# Left: the title, white letters standing on their navy extrusion.
	_title_box = VBoxContainer.new()
	_title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_title_box.add_theme_constant_override("separation", 6)
	row.add_child(_title_box)
	var title := Label.new()
	title.text = tr("MAKE IT FIT").replace(" IT", "\nIT")
	title.add_theme_font_override("font", GameTheme.font("display"))
	title.add_theme_font_size_override("font_size", 128)
	title.add_theme_constant_override("line_spacing", -52)
	title.add_theme_color_override("font_color", GameTheme.CHALK)
	title.add_theme_color_override("font_shadow_color", GameTheme.NAVY)
	title.add_theme_constant_override("shadow_offset_x", 7)
	title.add_theme_constant_override("shadow_offset_y", 8)
	_title_box.add_child(title)
	var sub := Label.new()
	sub.text = tr("Small spaces").to_upper()
	sub.add_theme_font_override("font", GameTheme.font("mono_bold"))
	sub.add_theme_font_size_override("font_size", GameTheme.FS_LABEL)
	sub.add_theme_color_override("font_color", GameTheme.CHALK)
	_title_box.add_child(sub)
	var note := Label.new()
	note.text = tr("Every request arrives by fax.") + " " + \
		tr("Make every tenant fit in their apartment, one piece of furniture at a time.")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 420
	note.add_theme_font_override("font", GameTheme.font("body"))
	note.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	note.add_theme_color_override("font_color", GameTheme.CHALK_SOFT)
	_title_box.add_child(note)

	# Right: what to do.
	_buttons = VBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.custom_minimum_size.x = 340
	_buttons.add_theme_constant_override("separation", 16)
	row.add_child(_buttons)

	var start_btn := MenuKit.menu_button(tr("Start Game"), "primary")
	start_btn.pressed.connect(_on_start)
	_buttons.add_child(start_btn)

	# Only shown once there's actually somewhere to resume — a fresh save has
	# no last_active_level_id yet, and it's cleared to a level the player
	# still owns (own_level/buy never removes entries, so no un-owning check
	# needed beyond is_owned itself matching CityMap's normal gating).
	if GameState.last_active_level_id != "" and GameState.is_owned(GameState.last_active_level_id):
		var continue_btn := MenuKit.menu_button(tr("Continue"))
		continue_btn.pressed.connect(_on_continue)
		_buttons.add_child(continue_btn)

	# Level Editor is intentionally not exposed here — it's reached only via
	# the existing dev-only Ctrl+Shift+Alt+E shortcut in CityMap.gd, same as
	# debug mode; players shouldn't see a menu path to it.
	var options_btn := MenuKit.menu_button(tr("Options"))
	options_btn.pressed.connect(func(): SettingsMenu.open(self))
	_buttons.add_child(options_btn)

	var credits_btn := MenuKit.menu_button(tr("Credits"))
	credits_btn.pressed.connect(func(): (load("res://scripts/CreditsMenu.gd") as GDScript).call("open", self))
	_buttons.add_child(credits_btn)

	# Quit as a quiet line under the cards, not another card.
	var quit_btn := Button.new()
	quit_btn.text = tr("Quit")
	quit_btn.flat = true
	quit_btn.custom_minimum_size = Vector2(0, GameTheme.TOUCH_SMALL)
	quit_btn.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	quit_btn.add_theme_color_override("font_color", GameTheme.CHALK_SOFT)
	quit_btn.add_theme_color_override("font_hover_color", GameTheme.CHALK)
	quit_btn.add_theme_color_override("font_pressed_color", GameTheme.CHALK)
	quit_btn.add_theme_color_override("font_focus_color", GameTheme.CHALK)
	quit_btn.pressed.connect(_on_quit)
	_buttons.add_child(quit_btn)

	call_deferred("_play_entrance")
	# Start is selected from the outset, so Enter starts and ↑ ↓ work at once.
	start_btn.grab_focus.call_deferred()


# The title and the cards slide in from either side when the menu opens.
func _play_entrance() -> void:
	if GameState.reduce_motion:
		return
	for pair in [[_title_box, -40.0], [_buttons, 40.0]]:
		var c := pair[0] as Control
		var to := c.position.x
		c.modulate.a = 0.0
		c.position.x = to + (pair[1] as float)
		var tw := create_tween().set_parallel(true)
		tw.tween_property(c, "modulate:a", 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(c, "position:x", to, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _on_start() -> void:
	Transition.change_scene("res://scenes/CityMap.tscn")


# Jumps straight into the last level actually entered, same as CityMap's own
# ENTER/"Revisar Plano Actual" — reopens its saved layout if it's already
# been won, otherwise starts it fresh from starting_furniture.
func _on_continue() -> void:
	var lid := GameState.last_active_level_id
	GameState.pending_level_id = lid
	GameState.pending_resume = GameState.has_progress(lid)
	GameState.pending_use_saved_layout = not GameState.pending_resume \
		and GameState.get_stars(lid) > 0 and GameState.has_level_layout(lid)
	Transition.change_scene("res://scenes/Main.tscn")


func _on_quit() -> void:
	get_tree().quit()
