extends Node

signal company_funds_changed(amount: int)

const RETIRE_GOAL := 10000   # total portfolio rent to retire
const SAVE_PATH   := "user://save.json"
# Bumped when the shape of the save changes, so an older file can be read
# and brought up to date instead of misread.
const SAVE_VERSION := 2
# Where the save lives; tests point it elsewhere so they never touch the
# player's own.
var save_path := SAVE_PATH
# Runs started by tools rather than by the player — the test suite and any
# scripted check, headless, or a windowed one launched with `-- --agent-save`
# — play on a fresh copy of the player's save here and never write theirs.
const AGENT_SAVE_DIR := "user://agent/"

var company_funds: int = 0
var portfolio_rent: int = 0
var completed: Dictionary = {}   # level_id -> { stars, first_time }
var owned: Array = []
var pending_level_id: String = "beach_house"
# Last level actually entered (not just selected) — lets MainMenu's Continue
# button jump straight back into it instead of always routing through
# CityMap. Persisted; deliberately separate from pending_level_id, which is
# transient and only means "the level Main.tscn should load next."
var last_active_level_id: String = ""
# Furniture-layout snapshot as of the last successful win of each level (same
# shape as Main._snapshot_all_furniture()) — lets "Revisar Plano Actual" reopen
# a completed level exactly as the player left it, instead of always starting
# from the level's original starting_furniture.
var level_layouts: Dictionary = {}
# One-shot flag set by CityMap right before switching to Main.tscn: consumed
# and cleared by Main._load_level(), never persisted (it only makes sense for
# the level about to load).
var pending_use_saved_layout: bool = false
# Projects left half-done, saved automatically as the player goes: top-level
# level id -> {at, levels, cache, pending} (see Main._autosave_now()). One
# entry per project, cleared when its apartment is rented out or started over.
var progress: Dictionary = {}
# One-shot, like pending_use_saved_layout: open pending_level_id where the
# player left it, from `progress`.
var pending_resume: bool = false
# Levels in phases: how far the player has got in each, and the flat as each
# phase they finished left it, so the map can start any phase reached again
# (CityMap's phase path), even once the apartment is rented out and its
# `progress` is gone. level id -> {reached: int, checkpoints: {"<phase>":
# var_to_str(LevelProgress.capture)}}.
var phase_saves: Dictionary = {}
# One-shot: open pending_level_id at the start of this phase (-1: as usual).
var pending_phase: int = -1
var dev_bonus_stars: int = 0

# ── Accessibility ────────────────────────────────────────────────────────────
# Skips the decorative bounce/pulse tweens (furniture placement squash, RENT
# OUT pulse, tenant-need chip pop) for players sensitive to motion — the
# underlying state change still happens instantly, only the animation is cut.
var reduce_motion: bool = false
# 3D view quality tier, as a StyleQuality.Level (0 Low, 1 Medium, 2 High).
# Room3DView listens for the change signal and applies it live.
signal graphics_quality_changed(level: int)
var graphics_quality: int = 0
# Multiplies Window.content_scale_factor — a blunt but genuinely global text/
# UI size control, since font sizes are set ad-hoc per-Label throughout the
# codebase rather than through one themed size that could be scaled centrally.
# A phone starts larger, so text and controls reach a readable, touchable size.
var default_ui_scale: float = 1.25 if OS.has_feature("mobile") else 1.0
var ui_scale: float = default_ui_scale
# "" until the player picks one in Settings: follow the device's language.
signal language_changed(lang: String)
var language: String = ""
const UI_SCALE_MIN := 0.85
const UI_SCALE_MAX := 1.35
# The only player-facing keyboard shortcut outside mouse interaction — Redo
# reuses the same key with Shift, Ctrl+Y stays as a fixed secondary alias.
var undo_keycode: int = KEY_Z

var custom_level_data: Dictionary = {}

# Separate from custom_level_data on purpose — that slot is also used by
# CityMap's own "play a custom level" flow, unrelated to the Level Editor's
# own Test Level round trip. Set by LevelEditor._test_level() right before
# switching to Main.tscn; consumed (and cleared) by LevelEditor._ready() when
# the player uses Main.gd's "← Back to Editor" button to come back, so
# testing a level doesn't lose the in-progress edit session.
var editor_test_snapshot: Dictionary = {}
# Mirrors LevelEditor._editor_nav_stack at the moment "▶ Test Level" was
# pressed — if the level being tested was reached via "✎ Edit" (a nested
# level, not the top apartment), _load_from_dict() alone on the way back
# doesn't restore that history, so the "← Back to <parent>" button in the
# editor never had anything to show. Restored alongside editor_test_snapshot.
var editor_test_nav_stack: Array[String] = []

# Set true for the WHOLE test session (not just while on the root level) —
# Main.gd's "← Back to Editor" button used to only show up while
# _current_level_id == "_custom" (the root), so it vanished the instant you
# stepped into any nested box, leaving no way back except quitting to
# CityMap and reloading the level by hand. Reset to false by _go_back()
# (leaving to CityMap ends the test session) and by LevelEditor consuming
# editor_test_snapshot on the way back in.
var testing_from_editor: bool = false

# Player/debug mode toggle (Ctrl+Shift+Alt+D in CityMap) — deliberately not
# persisted to the save file, resets to off on every launch. In debug mode
# the "Debug" district's levels show up in CityMap (hidden otherwise) and
# every level gets unlocked, so a level can be opened directly for testing
# instead of playing through the whole progression to reach it.
signal debug_mode_changed(enabled: bool)
var debug_mode: bool = false

func set_debug_mode(v: bool) -> void:
	if v == debug_mode:
		return
	debug_mode = v
	debug_mode_changed.emit(v)

# Levels owned unconditionally on every launch — tutorials, debug/test content,
# and anything else that should never be gated behind a purchase. Kept
# separate from persisted `owned` so a save file never has to list them.
const DEFAULT_OWNED := ["beach_house","three_freezers","day_and_night","the_inheritance","sneeze_girl",
		"the_tower","overprotective","border_house",
		"tut_basics","debug_moments","debug_rails","debug:_rail_moments","debug:_balcony",
		"debug:_sloped_ceiling","debug:_attic","debug:_split_level","debug:_demolition","tut_builder_basics","tut_verticality",
		"twitch","calle_mayor","el_estudio_de_ana","la_pareja","el_pasillo_de_javi","zona_privada",
		"muchos_electrodomésticos",
		"mif_M","mif_A","mif_K","mif_E","mif_I1","mif_T1","mif_F","mif_I2","mif_T2"]


# Frame rate caps. Uncapped, the game drew as many frames as the screen
# allows (240 a second on a 240 Hz laptop) for a puzzle where nothing moves
# faster than a tween: the GPU ran flat out, and with the integrated GPU
# passing every frame on to the screen, the rest of the computer (typing
# included) slowed down. Behind other windows it only needs to keep its
# music and tweens going.
const FPS_ACTIVE := 60
const FPS_BACKGROUND := 10


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			Engine.max_fps = FPS_BACKGROUND
		NOTIFICATION_APPLICATION_FOCUS_IN:
			Engine.max_fps = FPS_ACTIVE


func _ready() -> void:
	# Every screen fills the window, whatever its shape: the contents are
	# allowed to extend past the 1280 x 720 design area instead of being
	# letterboxed, and each screen lays itself out against the real size
	# (see ScreenFit, Main._fit_to_window, CityMap._on_viewport_resized).
	get_tree().root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	Engine.max_fps = FPS_ACTIVE
	_apply_global_font()
	if is_agent_run():
		_use_agent_save()
	load_game()
	Loc.apply(language)
	_apply_ui_scale()
	for _lid in DEFAULT_OWNED:
		own_level(_lid)


static func is_agent_run() -> bool:
	return DisplayServer.get_name() == "headless" or "--agent-save" in OS.get_cmdline_user_args()


# The player's save (and its backup) copied over whatever an earlier run
# left, so each run starts from where the player is, and saves land here.
func _use_agent_save() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(AGENT_SAVE_DIR))
	save_path = AGENT_SAVE_DIR + "save.json"
	for suffix in ["", ".bak", ".tmp"]:
		var mine := ProjectSettings.globalize_path(save_path + suffix)
		var theirs := ProjectSettings.globalize_path(SAVE_PATH + suffix)
		if FileAccess.file_exists(mine):
			DirAccess.remove_absolute(mine)
		if suffix != ".tmp" and FileAccess.file_exists(theirs):
			DirAccess.copy_absolute(theirs, mine)


func _apply_ui_scale() -> void:
	get_tree().root.content_scale_factor = ui_scale


func set_ui_scale(v: float) -> void:
	ui_scale = clampf(v, UI_SCALE_MIN, UI_SCALE_MAX)
	_apply_ui_scale()
	save_game()


func set_language(lang: String) -> void:
	language = lang
	Loc.apply(lang)
	language_changed.emit(Loc.current())
	save_game()


func set_reduce_motion(v: bool) -> void:
	reduce_motion = v
	save_game()




func set_graphics_quality(level: int) -> void:
	graphics_quality = clampi(level, 0, 2)
	graphics_quality_changed.emit(graphics_quality)
	save_game()


func set_undo_keycode(kc: int) -> void:
	undo_keycode = kc
	save_game()


# Sets the engine-wide fallback font once at boot. Every themed Control (none
# of GameTheme's styles set a font override) and every draw_string(ThemeDB.
# fallback_font, ...) call throughout the codebase — furniture labels, the
# blueprint title block/dimensions, wall-panel item names — all resolve to
# this same font as a result, without touching each call site individually.
# Archivo everywhere. It goes into Godot's own default theme, the last place
# every control looks. As ThemeDB.fallback_font it never showed, because the
# default theme has a font of its own (Open Sans) and that wins; on the root
# window's theme it would only reach controls whose parents are all controls,
# not the many under a CanvasLayer or a plain Node.
func _apply_global_font() -> void:
	var f := GameTheme.font("ui")
	ThemeDB.get_default_theme().default_font = f
	ThemeDB.fallback_font = f


# ── Persistence ───────────────────────────────────────────────────────────────
# Saves player profile progress (funds, rent, completed levels, purchased
# levels) plus audio settings. Transient/session-only state (pending level,
# custom level editor data, editor-test flags) is intentionally not persisted.
func save_game() -> void:
	var data := {
		"company_funds":   company_funds,
		"portfolio_rent":  portfolio_rent,
		"completed":       completed,
		"owned":           owned,
		"dev_bonus_stars": dev_bonus_stars,
		"level_layouts":   level_layouts,
		"reduce_motion":   reduce_motion,
		"ui_scale":        ui_scale,
		"language":        language,
		"undo_keycode":    undo_keycode,
		"graphics_quality": graphics_quality,
		"last_active_level_id": last_active_level_id,
		"progress":        progress,
		"phase_saves":     phase_saves,
		"save_version":    SAVE_VERSION,
		"saved_at":        Time.get_unix_time_from_system(),
	}
	var audio := get_node_or_null("/root/Audio")
	if audio:
		data["sfx_volume"]   = audio.sfx_volume
		data["music_volume"] = audio.music_volume
		data["master_volume"] = audio.master_volume
		data["audio_muted"]   = audio.muted
	_write_safely(save_path, JSON.stringify(data))


# Writes to a temporary file first and only then swaps it in, keeping the
# previous save as .bak: a phone killing the game halfway through a write
# leaves the old save (or its backup) intact rather than a truncated file.
func _write_safely(path: String, text: String) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	var real := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(real, real + ".bak")
		DirAccess.remove_absolute(real)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), real)


# The save, or its backup when the save itself is missing or unreadable, or
# older: a save swapped in but then lost (seen on Windows: the game's newest
# write survived only in .bak) still comes back. Saves from before "saved_at"
# count as oldest, so then the save itself wins as before.
func _read_save() -> Dictionary:
	var best := {}
	for path in [save_path, save_path + ".bak"]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY and (best.is_empty() \
				or float((parsed as Dictionary).get("saved_at", 0.0)) > float(best.get("saved_at", 0.0))):
			best = parsed as Dictionary
	return best


func load_game() -> void:
	var data := _read_save()
	if data.is_empty():
		return
	company_funds   = data.get("company_funds", company_funds) as int
	portfolio_rent  = data.get("portfolio_rent", portfolio_rent) as int
	completed       = data.get("completed", completed) as Dictionary
	owned           = (data.get("owned", owned) as Array).duplicate()
	dev_bonus_stars = data.get("dev_bonus_stars", dev_bonus_stars) as int
	level_layouts   = data.get("level_layouts", level_layouts) as Dictionary
	reduce_motion   = data.get("reduce_motion", reduce_motion) as bool
	ui_scale        = data.get("ui_scale", ui_scale) as float
	language        = data.get("language", language) as String
	undo_keycode    = data.get("undo_keycode", undo_keycode) as int
	graphics_quality = clampi(data.get("graphics_quality", graphics_quality) as int, 0, 2)
	last_active_level_id = data.get("last_active_level_id", last_active_level_id) as String
	# Version 1 saves had no progress; nothing else changed shape.
	progress = (data.get("progress", {}) as Dictionary).duplicate(true)
	phase_saves = (data.get("phase_saves", {}) as Dictionary).duplicate(true)
	_forget_missing_levels()
	var audio := get_node_or_null("/root/Audio")
	if audio:
		if data.has("sfx_volume"):
			audio.set_sfx_volume(data["sfx_volume"] as float)
		if data.has("music_volume"):
			audio.set_music_volume(data["music_volume"] as float)
		if data.has("master_volume"):
			audio.set_master_volume(data["master_volume"] as float)
		if data.has("audio_muted"):
			audio.set_muted(data["audio_muted"] as bool)


# ── Projects in progress ──────────────────────────────────────────────────────

# A project left half-done. Not one older than the flat's won layout: an
# autosave could still slip in after renting out, and the won flat should
# reopen on its results instead. (Layouts from before "at" count as newer.)
func has_progress(level_id: String) -> bool:
	if not progress.has(level_id):
		return false
	if completed.has(level_id) and has_level_layout(level_id):
		var won_at := int(get_level_layout(level_id).get("at", 0))
		return won_at > 0 and int(get_progress(level_id).get("at", 0)) > won_at
	return true


func get_progress(level_id: String) -> Dictionary:
	return progress.get(level_id, {}) as Dictionary


func set_progress(level_id: String, entry: Dictionary) -> void:
	progress[level_id] = entry
	save_game()


# The furthest phase of `level_id` (of `count`) the player may start: the
# one after the last they finished, every one once it is rented out.
func phase_reached(level_id: String, count: int) -> int:
	if count < 2:
		return 0
	if completed.has(level_id):
		return count - 1
	var at := int((phase_saves.get(level_id, {}) as Dictionary).get("reached", 0))
	if progress.has(level_id):   # saves from before phase_saves
		at = maxi(at, int(get_progress(level_id).get("phase", 0)))
	return clampi(at, 0, count - 1)


# The flat as phase `phase` of `level_id` left it when finished, as
# var_to_str(LevelProgress.capture); "" if there is none.
func phase_checkpoint(level_id: String, phase: int) -> String:
	var saved := ((phase_saves.get(level_id, {}) as Dictionary).get("checkpoints", {}) as Dictionary)
	if saved.has(str(phase)):
		return saved[str(phase)] as String
	if progress.has(level_id):   # saves from before phase_saves
		var old = str_to_var(get_progress(level_id).get("checkpoints", "{}") as String)
		if old is Dictionary and (old as Dictionary).has(phase):
			return (old as Dictionary)[phase] as String
	return ""


# Phase `phase` of `level_id` was just finished, leaving the flat as `capture`.
func save_phase_checkpoint(level_id: String, phase: int, capture: String) -> void:
	var entry := (phase_saves.get(level_id, {}) as Dictionary).duplicate(true)
	var cps := (entry.get("checkpoints", {}) as Dictionary)
	cps[str(phase)] = capture
	entry["checkpoints"] = cps
	entry["reached"] = maxi(int(entry.get("reached", 0)), phase + 1)
	phase_saves[level_id] = entry
	save_game()


func clear_progress(level_id: String) -> void:
	if progress.erase(level_id):
		save_game()


func set_last_active_level(level_id: String) -> void:
	last_active_level_id = level_id
	save_game()


func own_level(level_id: String) -> void:
	if level_id not in owned:
		owned.append(level_id)


func is_owned(level_id: String) -> bool:
	return level_id in owned


func buy_level(level_id: String, cost: int) -> bool:
	if company_funds < cost:
		return false
	company_funds -= cost
	own_level(level_id)
	company_funds_changed.emit(company_funds)
	save_game()
	return true


func complete_level(level_id: String, stars: int, funds_earned: int, monthly_rent: int) -> void:
	var first_time := level_id not in completed
	if first_time or completed[level_id]["stars"] < stars:
		completed[level_id] = {"stars": stars}
	if first_time:
		portfolio_rent += monthly_rent
	company_funds += funds_earned
	company_funds_changed.emit(company_funds)
	save_game()


func get_stars(level_id: String) -> int:
	return completed.get(level_id, {}).get("stars", 0) as int


func save_level_layout(level_id: String, snapshot: Dictionary) -> void:
	snapshot["level_fp"] = level_fingerprint(level_id)
	snapshot["at"] = int(Time.get_unix_time_from_system())
	level_layouts[level_id] = snapshot
	save_game()


# A won layout is only reopened while the level is still the one it was
# won in; after an update redrew it, the level starts fresh. (Layouts saved
# before fingerprints existed are trusted.)
func has_level_layout(level_id: String) -> bool:
	if not level_id in level_layouts:
		return false
	var fp := (level_layouts[level_id] as Dictionary).get("level_fp", "") as String
	return fp == "" or fp == level_fingerprint(level_id)


func get_level_layout(level_id: String) -> Dictionary:
	return level_layouts.get(level_id, {}) as Dictionary


func total_stars() -> int:
	var n := dev_bonus_stars
	for k in completed:
		n += completed[k]["stars"] as int
	return n


func dev_unlock_all(all_ids: Array) -> void:
	for lid in all_ids:
		own_level(lid as String)
	dev_bonus_stars = 200
	company_funds   = 999999
	company_funds_changed.emit(company_funds)


func is_retired() -> bool:
	return portfolio_rent >= RETIRE_GOAL


# ── Surviving updates ─────────────────────────────────────────────────────────
# An update can redraw a level, or drop one. What the save holds about a
# level that is gone is forgotten on load (stars earned stay earned), and a
# saved layout carries a fingerprint of the level it was made in, so a
# redrawn level can tell (LevelProgress.apply, has_level_layout).

var _levels_raw: Dictionary = {}   # level id -> its entry in levels.json, as authored

func _level_entry(level_id: String) -> Dictionary:
	if _levels_raw.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://data/levels.json"))
		if parsed is Dictionary:
			for lv in (parsed as Dictionary).get("levels", []) as Array:
				_levels_raw[(lv as Dictionary).get("id", "")] = lv
	return _levels_raw.get(level_id, {}) as Dictionary


func level_exists(level_id: String) -> bool:
	return not _level_entry(level_id).is_empty()


# Changes whenever the level's authored data does; "" for a level that
# isn't in levels.json (one made in the editor).
func level_fingerprint(level_id: String) -> String:
	var entry := _level_entry(level_id)
	if entry.is_empty():
		return ""
	return JSON.stringify(entry, "", true).md5_text()


func _forget_missing_levels() -> void:
	for dict in [progress, level_layouts, phase_saves]:
		for lid in (dict as Dictionary).keys():
			if not level_exists(lid):
				(dict as Dictionary).erase(lid)
	if last_active_level_id != "" and not level_exists(last_active_level_id):
		last_active_level_id = ""
	if not level_exists(pending_level_id):
		pending_level_id = "beach_house"
