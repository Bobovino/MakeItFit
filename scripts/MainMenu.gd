extends Control

# The first screen — an architect's desk: warm wood underneath, a stack of
# paper with the title/actions printed on it, a few blueprint-blue accents
# (the corner motif, the tag-button rules) so it reads as the same visual
# language as CityMap's blueprint sheet without turning the whole screen blue.

var _paper_card: PanelContainer = null
var _title_lbl: Label = null
var _motif: Control = null


func _draw() -> void:
	# Desk wood grain — a few faint horizontal streaks, not a full grid;
	# the blueprint accent now lives in the motif icon instead of the
	# whole-screen overlay this used to be.
	var sz := get_viewport_rect().size
	var streak := Color(0, 0, 0, 0.05)
	var y := 10.0
	while y < sz.y:
		draw_line(Vector2(0, y), Vector2(sz.x, y), streak, 1.0)
		y += 14.0


func _ready() -> void:
	theme = GameTheme.make()

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = GameTheme.C_BG
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_paper_card = PanelContainer.new()
	var paper_sn := StyleBoxFlat.new()
	paper_sn.bg_color = GameTheme.C_PAPER
	paper_sn.border_color = GameTheme.C_BORDER
	paper_sn.set_border_width_all(1)
	paper_sn.set_corner_radius_all(3)
	paper_sn.shadow_color = Color(0, 0, 0, 0.35)
	paper_sn.shadow_size = 18
	paper_sn.shadow_offset = Vector2(0, 8)
	paper_sn.set_content_margin(SIDE_LEFT, 40)
	paper_sn.set_content_margin(SIDE_RIGHT, 40)
	paper_sn.set_content_margin(SIDE_TOP, 36)
	paper_sn.set_content_margin(SIDE_BOTTOM, 32)
	_paper_card.add_theme_stylebox_override("panel", paper_sn)
	center.add_child(_paper_card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	_paper_card.add_child(vbox)

	# Header row: tiny floor-plan motif + title stack — immediately signals
	# "designing tiny living spaces" instead of a generic title screen.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	vbox.add_child(header)

	_motif = Control.new()
	_motif.custom_minimum_size = Vector2(44, 44)
	_motif.draw.connect(_draw_motif.bind(_motif))
	header.add_child(_motif)

	var title_stack := VBoxContainer.new()
	title_stack.add_theme_constant_override("separation", 2)
	header.add_child(title_stack)

	_title_lbl = _add_label(title_stack, "MAKE IT FIT", 44, GameTheme.C_AMBER.darkened(0.15))
	_add_label(title_stack, "Furnish. Satisfy. Retire.", 13, GameTheme.C_MUTED)

	var rule := HSeparator.new()
	rule.add_theme_color_override("color", GameTheme.C_BORDER)
	vbox.add_child(rule)

	var hand := GameTheme.handwriting()
	var note1 := _add_label(vbox, "35 apartments across 10 Berlin districts", 14, GameTheme.C_MUTED)
	if hand:
		note1.add_theme_font_override("font", hand)
	_add_label(vbox, "Build your property portfolio. Reach 10 000€/month. Retire.", 12, GameTheme.C_MUTED)

	_spacer(vbox, 8)

	var start_btn := Button.new()
	start_btn.text = "Start Game"
	start_btn.custom_minimum_size = Vector2(280, 52)
	start_btn.add_theme_font_size_override("font_size", 16)
	var rs := GameTheme.make_rent_btn_style()
	start_btn.add_theme_stylebox_override("normal",  rs[0])
	start_btn.add_theme_stylebox_override("hover",   rs[1])
	start_btn.add_theme_stylebox_override("pressed", rs[1])
	start_btn.add_theme_color_override("font_color",       GameTheme.C_AMBER)
	start_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.72))
	start_btn.pressed.connect(_on_start)
	vbox.add_child(start_btn)
	_add_hover_lift(start_btn)

	# Only shown once there's actually somewhere to resume — a fresh save has
	# no last_active_level_id yet, and it's cleared to a level the player
	# still owns (own_level/buy never removes entries, so no un-owning check
	# needed beyond is_owned itself matching CityMap's normal gating).
	if GameState.last_active_level_id != "" and GameState.is_owned(GameState.last_active_level_id):
		var continue_btn := _make_tag_button("Continue")
		continue_btn.pressed.connect(_on_continue)
		vbox.add_child(continue_btn)
		_add_hover_lift(continue_btn)

	# Level Editor is intentionally not exposed here — it's reached only via
	# the existing dev-only Ctrl+Shift+Alt+E shortcut in CityMap.gd, same as
	# debug mode; players shouldn't see a menu path to it.
	var options_btn := _make_tag_button("Options")
	options_btn.pressed.connect(func(): SettingsMenu.open(self))
	vbox.add_child(options_btn)
	_add_hover_lift(options_btn)

	_spacer(vbox, 10)

	var quit_btn := Button.new()
	quit_btn.text = "Quit"
	quit_btn.custom_minimum_size = Vector2(0, 30)
	quit_btn.add_theme_font_size_override("font_size", 12)
	quit_btn.add_theme_color_override("font_color", GameTheme.C_MUTED)
	quit_btn.pressed.connect(_on_quit)
	vbox.add_child(quit_btn)

	# Paper-card entrance — the sheet settles onto the desk when the menu
	# opens, and the title drifts gently in place while it waits.
	call_deferred("_play_entrance")


func _make_tag_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 40)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", GameTheme.C_TEXT)
	var ts := GameTheme.make_tag_btn_style()
	btn.add_theme_stylebox_override("normal",  ts[0])
	btn.add_theme_stylebox_override("hover",   ts[1])
	btn.add_theme_stylebox_override("pressed", ts[2])
	return btn


func _add_hover_lift(btn: Button) -> void:
	btn.pivot_offset = btn.custom_minimum_size * 0.5
	btn.mouse_entered.connect(func():
		create_tween().tween_property(btn, "scale", Vector2(1.03, 1.03), 0.12) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT))
	btn.mouse_exited.connect(func():
		create_tween().tween_property(btn, "scale", Vector2.ONE, 0.12) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT))


func _play_entrance() -> void:
	_paper_card.pivot_offset = _paper_card.size * 0.5
	_paper_card.modulate.a = 0.0
	var start_pos := _paper_card.position
	_paper_card.position.y = start_pos.y + 24
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_paper_card, "modulate:a", 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_paper_card, "position:y", start_pos.y, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	var idle := create_tween().set_loops()
	idle.tween_property(_title_lbl, "position:y", _title_lbl.position.y - 2.0, 2.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	idle.tween_property(_title_lbl, "position:y", _title_lbl.position.y, 2.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# Tiny floor-plan silhouette — a one-room apartment outline with a doorway
# gap, drawn in the blueprint palette so it reads as a small clipping from
# the same drafting board as the rest of the game, not a random logo.
func _draw_motif(node: Control) -> void:
	var r := Rect2(Vector2.ZERO, node.custom_minimum_size)
	node.draw_rect(r, GameTheme.BP_PAPER)
	var inset := r.grow(-5)
	node.draw_rect(inset, GameTheme.BP_INK, false, 1.5)
	# interior partition wall, with a doorway gap
	var mid_x := inset.position.x + inset.size.x * 0.55
	node.draw_line(Vector2(mid_x, inset.position.y), Vector2(mid_x, inset.position.y + inset.size.y * 0.35), GameTheme.BP_INK, 1.5)
	node.draw_line(Vector2(mid_x, inset.position.y + inset.size.y * 0.65), Vector2(mid_x, inset.position.y + inset.size.y), GameTheme.BP_INK, 1.5)


func _on_start() -> void:
	Transition.change_scene("res://scenes/CityMap.tscn")


# Jumps straight into the last level actually entered, same as CityMap's own
# ENTER/"Revisar Plano Actual" — reopens its saved layout if it's already
# been won, otherwise starts it fresh from starting_furniture.
func _on_continue() -> void:
	var lid := GameState.last_active_level_id
	GameState.pending_level_id = lid
	GameState.pending_use_saved_layout = \
		GameState.get_stars(lid) > 0 and GameState.has_level_layout(lid)
	Transition.change_scene("res://scenes/Main.tscn")


func _on_quit() -> void:
	get_tree().quit()


func _add_label(parent: Control, text: String, font_size: int, col: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", col)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	parent.add_child(lbl)
	return lbl


func _spacer(parent: Control, h: int) -> void:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	parent.add_child(s)
