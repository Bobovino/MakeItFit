extends CanvasLayer
class_name SettingsMenu

# The settings screen, laid out the way game menus are: categories down the
# left, one row per setting (its name on the left, its value on the right,
# changed with ← → or the mouse), what the selected row does in the strip
# below, and at the bottom "Restore defaults" for the category and Back.
# Opened from the pause menu (PauseMenu), the title screen and the map; all
# just do `SettingsMenu.open(self)`.
#
# Every change applies, and is saved, at once: there is nothing to confirm,
# and Back, the ✕, a click outside or Esc all just close it. The window
# itself is MenuKit's; the rows are SettingRows.

signal closed

var _w: Dictionary
var _host: Node
var _capturing_rebind := false
var _rebind_row: SettingRow = null
var _page_index := 0
var _step_category: Callable


static func open(host: Node) -> SettingsMenu:
	var m := SettingsMenu.new()
	m._host = host
	host.add_child(m)
	m._build()
	return m


func _build() -> void:
	layer = 26  # over the pause menu (24) and the mechanic-intro card (20)
	_w = MenuKit.screen(self, tr("Settings"), _close, true, true)
	var reset := MenuKit.button(tr("Restore defaults"))
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(_ask_reset)
	(_w["actions"] as Control).add_child(reset)
	_step_category = MenuKit.categories(_w["nav"], [tr("General"), tr("Audio"), tr("Graphics"), tr("Accessibility")],
		func(i: int): _show_page(i))


func _show_page(i: int) -> void:
	_page_index = i
	_capturing_rebind = false
	var page: VBoxContainer = _w["page"]
	for c in page.get_children():
		page.remove_child(c)
		c.queue_free()
	match i:
		0: _general(page)
		1: _audio(page)
		2: _graphics(page)
		3: _accessibility(page)
	(_w["scroll"] as ScrollContainer).scroll_vertical = 0
	# The first row starts selected, so its description shows and the
	# keyboard has somewhere to start.
	for c in page.get_children():
		if c is SettingRow:
			(c as SettingRow).grab_focus.call_deferred()
			break


func _add(page: VBoxContainer, row: SettingRow) -> SettingRow:
	row.selected.connect(func(r: SettingRow):
		(_w["about_title"] as Label).text = r.title
		(_w["about_text"] as Label).text = r.description())
	page.add_child(row)
	return row


# ── Pages ────────────────────────────────────────────────────────────────────
func _general(page: VBoxContainer) -> void:
	var langs := [[tr("Device language"), ""]]
	for code in Loc.LANGUAGES:
		langs.append([Loc.LANGUAGES[code] as String, code])
	var in_level := _in_level()
	var about := tr("The language of all the game's text. Device language follows your phone or computer.")
	if in_level:
		about += " " + tr("The rest of the level changes language when you leave it.")
	_add(page, SettingRow.choice(tr("Language"), about, langs, GameState.language, _set_language))
	MenuKit.heading(page, tr("Experimental"))
	_add(page, SettingRow.toggle(tr("Walking paths"),
		tr("The tenant has to be able to walk from the door to every piece of furniture, through gaps of at least 40 cm."),
		GameState.pathing_rule, func(on: bool): GameState.set_pathing_rule(on)))


func _audio(page: VBoxContainer) -> void:
	var audio := get_node_or_null("/root/Audio")
	var pct := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	var sliders: Array[SettingRow] = []
	sliders.append(_add(page, SettingRow.slider(tr("Master Volume"), tr("How loud the whole game is."),
		audio.master_volume if audio else 1.0, 0.0, 1.0, 0.05, func(v: float):
			if audio:
				audio.set_master_volume(v)
			GameState.save_game(), pct)))
	var sfx := _add(page, SettingRow.slider(tr("SFX Volume"),
		tr("Clicks, placing, folding, selling and the other sounds of what you do."),
		audio.sfx_volume if audio else 1.0, 0.0, 1.0, 0.05, func(v: float):
			if audio:
				audio.set_sfx_volume(v)
			GameState.save_game(), pct))
	sliders.append(sfx)
	# Letting go of it plays a click, so the level can be judged by ear.
	sfx._slider.drag_ended.connect(func(_c: bool):
		if audio:
			audio.play("click"))
	# While muted the volumes do nothing, and say so.
	var show_muted := func(on: bool) -> void:
		for s in sliders:
			s.set_enabled(not on)
	_add(page, SettingRow.toggle(tr("Mute all sound"), tr("Silences the game without touching the volumes above."),
		audio.muted if audio else false, func(on: bool):
			if audio:
				audio.set_muted(on)
			GameState.save_game()
			show_muted.call(on)))
	show_muted.call(audio.muted if audio else false)


# 3D view quality. Only tiers that add something on the running renderer are
# offered (High is the SSAO tier, which this renderer may not have), and the
# description says what the chosen tier turns on.
func _graphics(page: VBoxContainer) -> void:
	var tiers := [StyleQuality.Level.LOW, StyleQuality.Level.MEDIUM]
	if StyleQuality.supports_ssao():
		tiers.append(StyleQuality.Level.HIGH)
	var items: Array = []
	for tier in tiers:
		items.append([tr(StyleQuality.LEVEL_NAMES[tier]), tier])
	_add(page, SettingRow.choice(tr("3D Quality"), _quality_hint, items, mini(GameState.graphics_quality, tiers[-1]),
		func(tier: int): GameState.set_graphics_quality(tier)))


func _accessibility(page: VBoxContainer) -> void:
	# UI scale — a blunt global zoom (see GameState._apply_ui_scale) rather
	# than a per-label font setting, since font sizes are hardcoded ad-hoc
	# throughout the codebase. Shown as the zoom itself (1.0 = 100%), and
	# applied when the slider is let go: zooming while dragging moved the
	# slider out from under the pointer.
	var pct := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	var row := _add(page, SettingRow.slider(tr("UI Scale"), tr("Makes all text and buttons bigger or smaller."),
		GameState.ui_scale, GameState.UI_SCALE_MIN, GameState.UI_SCALE_MAX, 0.05, func(_v: float): pass, pct))
	var slider := row._slider
	var dragging := [false]
	slider.drag_started.connect(func(): dragging[0] = true)
	slider.drag_ended.connect(func(_c: bool):
		dragging[0] = false
		GameState.set_ui_scale(slider.value))
	slider.value_changed.connect(func(v: float):
		if not dragging[0]:
			GameState.set_ui_scale(v))
	_add(page, SettingRow.toggle(tr("Reduce motion"),
		tr("Skips the pop, bounce and pulse animations. Everything still happens, just without the movement."),
		GameState.reduce_motion, func(on: bool): GameState.set_reduce_motion(on)))
	_rebind_row = _add(page, SettingRow.action(tr("Undo key"),
		tr("Ctrl with this key undoes, Ctrl+Shift with it redoes. Press Enter, then the new key."),
		_undo_key_text(GameState.undo_keycode), func(): _start_rebind_capture()))


func _quality_hint(tier: int) -> String:
	match tier:
		StyleQuality.Level.LOW:    return tr("Fastest. Flat lighting and shadows only.")
		StyleQuality.Level.MEDIUM: return tr("Adds glow on lamps and windows, and a soft vignette.")
		_:                         return tr("Adds contact shading in corners. Needs a dedicated GPU.")


# Most text is set once when a screen is built, so a new language needs the
# screen rebuilt: outside a level that is just a reload; inside one it would
# throw away the layout in progress, so the level keeps its text until the
# player leaves it and only the menus are rebuilt straight away.
func _set_language(code: String) -> void:
	GameState.set_language(code)
	var host := _host
	_close()
	if _in_level():
		if host.has_method("rebuild"):
			host.call("rebuild")
		var again := SettingsMenu.open(host)
		again._focus_language.call_deferred()
	else:
		Transition.change_scene(get_tree().current_scene.scene_file_path)


func _focus_language() -> void:
	for c in (_w["page"] as Control).get_children():
		if c is SettingRow:
			(c as SettingRow).grab_focus()
			return


func _in_level() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.scene_file_path == "res://scenes/Main.tscn"


# ── Defaults ─────────────────────────────────────────────────────────────────
# For the category on screen. The language stays: resetting it would reload
# the screen, and nobody resets audio to get their language changed.
func _ask_reset() -> void:
	var names := [tr("General"), tr("Audio"), tr("Graphics"), tr("Accessibility")]
	MenuKit.dialog(self, tr("Restore defaults"),
		tr("Put every %s setting back the way the game came?") % names[_page_index],
		tr("Restore"), _reset_page, false)


func _reset_page() -> void:
	var audio := get_node_or_null("/root/Audio")
	match _page_index:
		0:
			GameState.set_pathing_rule(false)
		1:
			if audio:
				audio.set_master_volume(1.0)
				audio.set_sfx_volume(1.0)
				audio.set_muted(false)
			GameState.save_game()
		2:
			GameState.set_graphics_quality(StyleQuality.recommended())
		3:
			GameState.set_ui_scale(GameState.default_ui_scale)
			GameState.set_reduce_motion(false)
			GameState.set_undo_keycode(KEY_Z)
	_show_page(_page_index)


# ── Undo key rebinding ───────────────────────────────────────────────────────
func _undo_key_text(kc: int) -> String:
	return tr("Ctrl+%s  (Shift+ = Redo)") % OS.get_keycode_string(kc)


func _start_rebind_capture() -> void:
	_capturing_rebind = true
	_rebind_row.set_text(tr("Press any key…"))


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if get_child_count() > 0 and get_child(-1) is CanvasLayer:
		return   # a question is up (MenuKit.dialog): it has the keys
	if _capturing_rebind:
		# Modifier keys alone aren't a usable base key (Ctrl/Shift/Alt are
		# already the required chord prefix): wait for a real key. Esc keeps
		# the old one.
		if key.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
			return
		if key.keycode != KEY_ESCAPE:
			GameState.set_undo_keycode(key.keycode)
		_rebind_row.set_text(_undo_key_text(GameState.undo_keycode))
		_capturing_rebind = false
		get_viewport().set_input_as_handled()
		return
	match key.keycode:
		KEY_ESCAPE:
			_close()
		KEY_Q, KEY_PAGEUP:
			_step_category.call(-1)
		KEY_E, KEY_PAGEDOWN:
			_step_category.call(1)
		_:
			return
	get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
