extends CanvasLayer
class_name SettingsMenu

# Self-contained settings window: language, sound (master/SFX/music volume and
# mute, wired straight to the Audio autoload's buses), 3D view quality,
# accessibility, the experimental walking-paths rule, and leaving the level
# or the game. Usable from anywhere — CityMap, MainMenu and Main all just do
# `SettingsMenu.open(self)`. The window itself is MenuKit's.
#
# Every change applies (and is saved) at once, so there is nothing to
# confirm: Close, the ✕, a click outside and Esc all just close it. Only the
# actions that throw something away ask first.

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

	var w := MenuKit.modal(self, tr("SETTINGS"), 560.0, _close)
	var body: VBoxContainer = w["body"]
	var footer: HBoxContainer = w["footer"]

	# get_parent() is the host node open() added this menu under, not a
	# separately-stored reference.
	var host := get_parent()

	# Leaving the level first: it is what a player opening this mid-level is
	# most often after. Only Main has a level to leave or restart; CityMap
	# and the title screen get neither.
	var can_back := host != null and host.has_method("_go_back")
	var can_restart := host != null and host.has_method("_restart_level")
	if can_back or can_restart:
		var nav := MenuKit.section(body, tr("NAVIGATION"))
		var bar := HBoxContainer.new()
		bar.add_theme_constant_override("separation", 8)
		nav.add_child(bar)
		if can_back:
			var back_btn := MenuKit.button(tr("← Projects"))
			back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			back_btn.pressed.connect(func():
				_close()
				host.call("_go_back"))
			bar.add_child(back_btn)
		if can_restart:
			# Throws away everything placed so far, so it asks first.
			var restart_btn := MenuKit.button(tr("↻ Restart Level"))
			restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			restart_btn.pressed.connect(func():
				MenuKit.confirm(bar, tr("Discard this layout and start over?"), tr("Yes, restart"), func():
					_close()
					host.call("_restart_level")))
			bar.add_child(restart_btn)

	var lang := MenuKit.section(body, tr("LANGUAGE"))
	_build_language_row(lang, host)

	var audio := get_node_or_null("/root/Audio")
	var sound := MenuKit.section(body, tr("AUDIO"))
	var pct := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	var sliders: Array[HSlider] = []
	sliders.append(MenuKit.slider_row(sound, tr("Master Volume"), audio.master_volume if audio else 1.0,
		0.0, 1.0, 0.01, func(v: float):
			if audio:
				audio.set_master_volume(v)
			GameState.save_game(), pct))
	var sfx := MenuKit.slider_row(sound, tr("SFX Volume"), audio.sfx_volume if audio else 1.0,
		0.0, 1.0, 0.01, func(v: float):
			if audio:
				audio.set_sfx_volume(v)
			GameState.save_game(), pct)
	sliders.append(sfx)
	# Letting go of the SFX slider plays a click, so the level can be judged
	# by ear instead of by leaving the menu to trigger a sound.
	sfx.drag_ended.connect(func(_changed: bool):
		if audio:
			audio.play("click"))
	sliders.append(MenuKit.slider_row(sound, tr("Music Volume"), audio.music_volume if audio else 0.7,
		0.0, 1.0, 0.01, func(v: float):
			if audio:
				audio.set_music_volume(v)
			GameState.save_game(), pct))
	# While muted the volumes do nothing: they say so by greying out.
	var show_muted := func(on: bool) -> void:
		for s in sliders:
			s.editable = not on
			s.get_parent().modulate.a = 0.45 if on else 1.0
	MenuKit.switch_row(sound, tr("Mute all sound"), audio.muted if audio else false, func(on: bool):
		if audio:
			audio.set_muted(on)
		GameState.save_game()
		show_muted.call(on))
	show_muted.call(audio.muted if audio else false)

	var gfx := MenuKit.section(body, tr("GRAPHICS"))
	_build_quality_rows(gfx)

	var access := MenuKit.section(body, tr("ACCESSIBILITY"))
	# UI scale — a blunt global zoom (see GameState._apply_ui_scale) rather
	# than a per-label font setting, since font sizes are hardcoded ad-hoc
	# throughout the codebase and there's no single themed size to scale.
	# Shown as the zoom itself (1.0 = 100%), not as a share of the slider's
	# range, which once put the normal size at a confusing "30%". It applies
	# on release: zooming while dragging moved the slider out from under the
	# pointer.
	var dragging := [false]
	var scale_slider := MenuKit.slider_row(access, tr("UI Scale"), GameState.ui_scale,
		GameState.UI_SCALE_MIN, GameState.UI_SCALE_MAX, 0.01, func(v: float):
			if not dragging[0]:
				GameState.set_ui_scale(v), pct)
	scale_slider.drag_started.connect(func(): dragging[0] = true)
	scale_slider.drag_ended.connect(func(_changed: bool):
		dragging[0] = false
		GameState.set_ui_scale(scale_slider.value))
	MenuKit.switch_row(access, tr("Reduce motion (skip pop/pulse animations)"), GameState.reduce_motion,
		func(on: bool): GameState.set_reduce_motion(on))
	_rebind_btn = MenuKit.button(_undo_key_text(GameState.undo_keycode))
	_rebind_btn.pressed.connect(_start_rebind_capture)
	MenuKit.row(access, tr("Undo key"), _rebind_btn)

	var lab := MenuKit.section(body, tr("EXPERIMENTAL"))
	MenuKit.switch_row(lab, tr("Walking paths"), GameState.pathing_rule,
		func(on: bool): GameState.set_pathing_rule(on))
	MenuKit.hint(lab, tr("The tenant has to be able to walk from the door to every piece of furniture, through gaps of at least 40 cm."))

	# Quitting the whole game is rare and drastic: last in the list, and it
	# asks first.
	var quit_bar := HBoxContainer.new()
	body.add_child(quit_bar)
	var quit_btn := MenuKit.button(tr("Quit to Desktop"), "danger")
	quit_btn.pressed.connect(func():
		MenuKit.confirm(quit_bar, tr("Quit for real?"), tr("Yes, quit"), func(): get_tree().quit()))
	quit_bar.add_child(quit_btn)

	var help_btn := MenuKit.button(tr("❓ How to Play"))
	help_btn.pressed.connect(func(): HowToPlay.open(self))
	footer.add_child(help_btn)
	var credits_btn := MenuKit.button(tr("🖋 Credits"))
	credits_btn.pressed.connect(func(): CreditsMenuScript.open(self))
	footer.add_child(credits_btn)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(push)
	var close_btn := MenuKit.button(tr("Close"), "primary")
	close_btn.custom_minimum_size.x = 120
	close_btn.pressed.connect(_close)
	footer.add_child(close_btn)


# Most text is set once when a screen is built, so a new language needs the
# screen rebuilt: outside a level that is just a reload; inside one it would
# throw away the layout in progress, so the level keeps its text until the
# player leaves it and only this menu is rebuilt straight away.
func _build_language_row(rows: VBoxContainer, host: Node) -> void:
	var items := [[tr("Device language"), ""]]
	for code in Loc.LANGUAGES:
		items.append([Loc.LANGUAGES[code] as String, code])
	var picker := MenuKit.picker(items, GameState.language)
	MenuKit.row(rows, tr("Language"), picker)
	var in_level := _in_level()
	if in_level:
		MenuKit.hint(rows, tr("The rest of the level changes language when you leave it."))
	picker.item_selected.connect(func(index: int):
		GameState.set_language(picker.get_item_metadata(index) as String)
		_close()
		if in_level:
			SettingsMenu.open(host)
		else:
			Transition.change_scene(get_tree().current_scene.scene_file_path))


func _in_level() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.scene_file_path == "res://scenes/Main.tscn"


# 3D view quality. Only tiers that add something on the running renderer are
# offered (High is the SSAO tier, which this renderer may not have), and the
# line underneath says what the chosen tier turns on.
func _build_quality_rows(rows: VBoxContainer) -> void:
	var tiers := [StyleQuality.Level.LOW, StyleQuality.Level.MEDIUM]
	if StyleQuality.supports_ssao():
		tiers.append(StyleQuality.Level.HIGH)
	var current := mini(GameState.graphics_quality, tiers[-1])
	var items: Array = []
	for tier in tiers:
		items.append([tr(StyleQuality.LEVEL_NAMES[tier]), tier])
	var picker := MenuKit.picker(items, current)
	MenuKit.row(rows, tr("3D Quality"), picker)
	var hint := MenuKit.hint(rows, _quality_hint(current))
	picker.item_selected.connect(func(index: int):
		var tier := picker.get_item_metadata(index) as int
		GameState.set_graphics_quality(tier)
		hint.text = _quality_hint(tier))


func _quality_hint(tier: int) -> String:
	match tier:
		StyleQuality.Level.LOW:    return tr("Fastest. Flat lighting and shadows only.")
		StyleQuality.Level.MEDIUM: return tr("Adds glow on lamps and windows, and a soft vignette.")
		_:                         return tr("Adds contact shading in corners. Needs a dedicated GPU.")


func _undo_key_text(kc: int) -> String:
	return tr("Ctrl+%s  (Shift+ = Redo)") % OS.get_keycode_string(kc)


# ── Undo key rebinding ───────────────────────────────────────────────────────
func _start_rebind_capture() -> void:
	_capturing_rebind = true
	_rebind_btn.text = tr("Press any key…")


func _input(event: InputEvent) -> void:
	# Esc closes the menu (it is also what opens it, from the game and the
	# map), or, while a key is being picked, just stops picking.
	if not _capturing_rebind:
		if MenuKit.is_escape(event):
			_close()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		var kc := (event as InputEventKey).keycode
		# Modifier keys alone aren't a usable base key (Ctrl/Shift/Alt are
		# already the required chord prefix) — wait for a real key.
		if kc in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			return
		if kc != KEY_ESCAPE:
			GameState.set_undo_keycode(kc)
		_rebind_btn.text = _undo_key_text(GameState.undo_keycode)
		_capturing_rebind = false
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
