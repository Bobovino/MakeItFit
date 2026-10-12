extends CanvasLayer
class_name SettingsMenu

# Self-contained settings modal: audio (master/SFX/music volume and mute,
# wired straight to the Audio autoload's buses), 3D view quality,
# accessibility, and a confirm-gated Quit to Desktop. Usable from
# anywhere — CityMap and Main both just do `SettingsMenu.open(self)`.

signal closed

# preload (not the CreditsMenu class_name) so this works immediately without
# waiting on Godot's global script-class cache to pick up the new file.
const CreditsMenuScript := preload("res://scripts/CreditsMenu.gd")

var _rebind_btn: Button = null
var _capturing_rebind: bool = false


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
	card.position            = Vector2(390, 130)
	card.custom_minimum_size = Vector2(500, 0)
	add_child(card)

	# The list is taller in-level (navigation rows) than from the menus, so it
	# scrolls rather than run off the 720-high layout; _fit_card() sizes the
	# scroll area to its content and centres the card once that's known.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 9)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)
	_fit_card.call_deferred(card, scroll, vb)

	var title_row := HBoxContainer.new()
	vb.add_child(title_row)
	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var help_btn := Button.new()
	help_btn.text = "❓ How to Play"
	help_btn.add_theme_font_size_override("font_size", 12)
	help_btn.pressed.connect(func(): HowToPlay.open(self))
	title_row.add_child(help_btn)

	var credits_btn := Button.new()
	credits_btn.text = "🖋 Credits"
	credits_btn.add_theme_font_size_override("font_size", 12)
	credits_btn.pressed.connect(func(): CreditsMenuScript.open(self))
	title_row.add_child(credits_btn)

	# get_parent() is the host node open() added this menu under, not a
	# separately-stored reference.
	var host := get_parent()

	var audio := get_node_or_null("/root/Audio")

	vb.add_child(_section_title("AUDIO"))

	vb.add_child(_build_slider_row("Master Volume",
		audio.master_volume if audio else 1.0,
		func(v: float):
			if audio:
				audio.set_master_volume(v)
			GameState.save_game()))

	var sfx_row := _build_slider_row("SFX Volume",
		audio.sfx_volume if audio else 1.0,
		func(v: float):
			if audio:
				audio.set_sfx_volume(v)
			GameState.save_game())
	vb.add_child(sfx_row)
	# Letting go of the SFX slider plays a click, so the level can be judged
	# by ear instead of by leaving the menu to trigger a sound.
	(sfx_row.get_child(1) as HSlider).drag_ended.connect(func(_changed: bool):
		if audio:
			audio.play("click"))

	vb.add_child(_build_slider_row("Music Volume",
		audio.music_volume if audio else 0.7,
		func(v: float):
			if audio:
				audio.set_music_volume(v)
			GameState.save_game()))

	var mute_chk := CheckBox.new()
	mute_chk.text = "Mute all sound"
	mute_chk.add_theme_font_size_override("font_size", 12)
	mute_chk.button_pressed = audio.muted if audio else false
	mute_chk.toggled.connect(func(on: bool):
		if audio:
			audio.set_muted(on)
		GameState.save_game())
	vb.add_child(mute_chk)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_title("GRAPHICS"))
	_build_quality_rows(vb)

	var sep0 := HSeparator.new()
	vb.add_child(sep0)

	vb.add_child(_section_title("ACCESSIBILITY"))

	# UI scale — a blunt global zoom (see GameState._apply_ui_scale) rather
	# than a per-label font setting, since font sizes are hardcoded ad-hoc
	# throughout the codebase and there's no single themed size to scale.
	vb.add_child(_build_pct_slider_row("UI Scale", GameState.ui_scale,
		GameState.UI_SCALE_MIN, GameState.UI_SCALE_MAX,
		func(v: float): GameState.set_ui_scale(v)))

	var motion_row := HBoxContainer.new()
	motion_row.add_theme_constant_override("separation", 10)
	vb.add_child(motion_row)
	var motion_chk := CheckBox.new()
	motion_chk.text = "Reduce motion (skip pop/pulse animations)"
	motion_chk.add_theme_font_size_override("font_size", 12)
	motion_chk.button_pressed = GameState.reduce_motion
	motion_chk.toggled.connect(func(on: bool): GameState.set_reduce_motion(on))
	motion_row.add_child(motion_chk)

	var rebind_row := HBoxContainer.new()
	rebind_row.add_theme_constant_override("separation", 10)
	vb.add_child(rebind_row)
	var rebind_lbl := Label.new()
	rebind_lbl.text = "Undo key"
	rebind_lbl.add_theme_font_size_override("font_size", 13)
	rebind_lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	rebind_lbl.custom_minimum_size.x = 120
	rebind_row.add_child(rebind_lbl)
	_rebind_btn = Button.new()
	_rebind_btn.text = "Ctrl+%s  (Shift+ = Redo)" % OS.get_keycode_string(GameState.undo_keycode)
	_rebind_btn.add_theme_font_size_override("font_size", 12)
	_rebind_btn.pressed.connect(_start_rebind_capture)
	rebind_row.add_child(_rebind_btn)

	var sep := HSeparator.new()
	vb.add_child(sep)

	# Navigation — leaving the level entirely (Back/Restart), grouped
	# together and set apart from the adjustable settings above so they
	# read as "things that take you elsewhere," not more preferences to tune.
	# Only Main (an in-level session) has anywhere to go "back" to or a level
	# to restart — CityMap opening this same menu has neither, so each
	# button only appears when the host actually supports it.
	if (host and host.has_method("_go_back")) or (host and host.has_method("_restart_level")):
		var nav_title := Label.new()
		nav_title.text = "NAVIGATION"
		nav_title.add_theme_font_size_override("font_size", 13)
		nav_title.add_theme_color_override("font_color", GameTheme.C_MUTED)
		vb.add_child(nav_title)

	if host and host.has_method("_go_back"):
		var back_btn := Button.new()
		back_btn.text = "← Projects"
		back_btn.add_theme_font_size_override("font_size", 13)
		back_btn.pressed.connect(func():
			_close()
			host.call("_go_back"))
		vb.add_child(back_btn)

	# Discoverable "start over" escape hatch for a bad layout (spent the
	# budget on the wrong things, boxed something in unreachably, etc.) —
	# same click-to-arm/click-to-confirm pattern as Quit below, since it
	# throws away everything placed so far.
	if host and host.has_method("_restart_level"):
		var restart_row := VBoxContainer.new()
		restart_row.add_theme_constant_override("separation", 6)
		vb.add_child(restart_row)

		var restart_btn := Button.new()
		restart_btn.text = "↻ Restart Level"
		restart_btn.add_theme_font_size_override("font_size", 13)
		restart_row.add_child(restart_btn)

		var r_confirm_row := HBoxContainer.new()
		r_confirm_row.visible = false
		r_confirm_row.add_theme_constant_override("separation", 8)
		restart_row.add_child(r_confirm_row)

		var r_confirm_lbl := Label.new()
		r_confirm_lbl.text = "Discard this layout and start over?"
		r_confirm_lbl.add_theme_font_size_override("font_size", 12)
		r_confirm_lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
		r_confirm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r_confirm_row.add_child(r_confirm_lbl)

		var r_yes_btn := Button.new()
		r_yes_btn.text = "Yes, restart"
		r_yes_btn.add_theme_font_size_override("font_size", 12)
		r_yes_btn.add_theme_color_override("font_color", Color(0.90, 0.45, 0.35))
		r_yes_btn.pressed.connect(func():
			_close()
			host.call("_restart_level"))
		r_confirm_row.add_child(r_yes_btn)

		var r_cancel_btn := Button.new()
		r_cancel_btn.text = "Cancel"
		r_cancel_btn.add_theme_font_size_override("font_size", 12)
		r_cancel_btn.pressed.connect(func():
			r_confirm_row.visible = false
			restart_btn.visible = true)
		r_confirm_row.add_child(r_cancel_btn)

		restart_btn.pressed.connect(func():
			restart_btn.visible = false
			r_confirm_row.visible = true)

	if (host and host.has_method("_go_back")) or (host and host.has_method("_restart_level")):
		vb.add_child(HSeparator.new())

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


func _section_title(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", GameTheme.C_MUTED)
	return lbl


# 3D view quality. Only tiers that add something on the running renderer are
# offered (High is the SSAO tier, which this renderer may not have), and the
# line underneath says what the chosen tier turns on.
func _build_quality_rows(vb: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)

	var lbl := Label.new()
	lbl.text = "3D Quality"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.custom_minimum_size.x = 120
	row.add_child(lbl)

	var tiers := [StyleQuality.Level.LOW, StyleQuality.Level.MEDIUM]
	if StyleQuality.supports_ssao():
		tiers.append(StyleQuality.Level.HIGH)
	var current := mini(GameState.graphics_quality, tiers[-1])

	var picker := OptionButton.new()
	picker.add_theme_font_size_override("font_size", 12)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for tier in tiers:
		picker.add_item(StyleQuality.LEVEL_NAMES[tier], tier)
	picker.select(picker.get_item_index(current))
	row.add_child(picker)

	var hint := Label.new()
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	hint.text = _quality_hint(current)
	vb.add_child(hint)

	picker.item_selected.connect(func(index: int):
		var tier := picker.get_item_id(index)
		GameState.set_graphics_quality(tier)
		hint.text = _quality_hint(tier))

	vb.add_child(_section_title("EXPERIMENTAL"))
	var path_toggle := CheckButton.new()
	path_toggle.text = "Walking paths"
	path_toggle.add_theme_font_size_override("font_size", 13)
	path_toggle.add_theme_color_override("font_color", GameTheme.C_TEXT)
	path_toggle.button_pressed = GameState.pathing_rule
	path_toggle.toggled.connect(func(on: bool): GameState.set_pathing_rule(on))
	vb.add_child(path_toggle)
	var path_hint := Label.new()
	path_hint.add_theme_font_size_override("font_size", 11)
	path_hint.add_theme_color_override("font_color", GameTheme.C_MUTED)
	path_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	path_hint.text = "The tenant has to be able to walk from the door to every piece of furniture, through gaps of at least 40 cm."
	vb.add_child(path_hint)


func _quality_hint(tier: int) -> String:
	match tier:
		StyleQuality.Level.LOW:    return "Fastest. Flat lighting and shadows only."
		StyleQuality.Level.MEDIUM: return "Adds glow on lamps and windows, and a soft vignette."
		_:                         return "Adds contact shading in corners. Needs a dedicated GPU."


# Sizes the scroll area to its content (capped to fit the 720-high layout) and
# centres the card vertically. Deferred: sizes aren't known until after layout.
func _fit_card(card: PanelContainer, scroll: ScrollContainer, vb: VBoxContainer) -> void:
	await get_tree().process_frame
	if not is_instance_valid(card):
		return
	scroll.custom_minimum_size = Vector2(452, minf(vb.get_combined_minimum_size().y, 656.0))
	await get_tree().process_frame
	if is_instance_valid(card):
		card.position.y = maxf(4.0, (720.0 - card.size.y) * 0.5)


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


# Same shape as _build_slider_row but for an arbitrary [min, max] range whose
# value itself already reads naturally as a percentage (e.g. UI Scale's 1.0
# default IS 100% zoom) — shown as v*100 directly. An earlier version showed
# this as a percentage of the [min, max] *range* instead, which put the
# default 1.0 at a confusing "30%" (since 1.0 sits 30% of the way from 0.85
# to 1.35) and read as the UI being shrunk when it was actually at its
# normal size.
func _build_pct_slider_row(label_text: String, initial: float, min_v: float, max_v: float, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", GameTheme.C_TEXT)
	lbl.custom_minimum_size.x = 120
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
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


# ── Undo key rebinding ───────────────────────────────────────────────────────
func _start_rebind_capture() -> void:
	_capturing_rebind = true
	_rebind_btn.text = "Press any key…"


func _input(event: InputEvent) -> void:
	if not _capturing_rebind:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var kc := (event as InputEventKey).keycode
		# Modifier keys alone aren't a usable base key (Ctrl/Shift/Alt are
		# already the required chord prefix) — wait for a real key.
		if kc in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			return
		GameState.set_undo_keycode(kc)
		_rebind_btn.text = "Ctrl+%s  (Shift+ = Redo)" % OS.get_keycode_string(kc)
		_capturing_rebind = false
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
