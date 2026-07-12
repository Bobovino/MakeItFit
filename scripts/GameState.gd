extends Node

signal company_funds_changed(amount: int)

const RETIRE_GOAL := 10000   # total portfolio rent to retire
const SAVE_PATH   := "user://save.json"

var company_funds: int = 0
var portfolio_rent: int = 0
var completed: Dictionary = {}   # level_id -> { stars, first_time }
var owned: Array = []
var pending_level_id: String = "level_01"
# Furniture-layout snapshot as of the last successful win of each level (same
# shape as Main._snapshot_all_furniture()) — lets "Revisar Plano Actual" reopen
# a completed level exactly as the player left it, instead of always starting
# from the level's original starting_furniture.
var level_layouts: Dictionary = {}
# One-shot flag set by CityMap right before switching to Main.tscn: consumed
# and cleared by Main._load_level(), never persisted (it only makes sense for
# the level about to load).
var pending_use_saved_layout: bool = false
var dev_bonus_stars: int = 0

# ── Accessibility ────────────────────────────────────────────────────────────
# Skips the decorative bounce/pulse tweens (furniture placement squash, RENT
# OUT pulse, tenant-need chip pop) for players sensitive to motion — the
# underlying state change still happens instantly, only the animation is cut.
var reduce_motion: bool = false
# Multiplies Window.content_scale_factor — a blunt but genuinely global text/
# UI size control, since font sizes are set ad-hoc per-Label throughout the
# codebase rather than through one themed size that could be scaled centrally.
var ui_scale: float = 1.0
const UI_SCALE_MIN := 0.85
const UI_SCALE_MAX := 1.35
# The only player-facing keyboard shortcut outside mouse interaction — Redo
# reuses the same key with Shift, Ctrl+Y stays as a fixed secondary alias.
var undo_keycode: int = KEY_Z

var custom_level_data: Dictionary = {}
var testing_from_editor: bool = false  # set by LevelEditor._test_level(); back btn returns to editor
var resume_editor:       bool = false  # set by Main._go_back(); LevelEditor reloads custom_level_data

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
const DEFAULT_OWNED := ["tut_basics","debug_moments","debug_rails","debug:_rail_moments","debug:_balcony",
		"debug:_sloped_ceiling","debug:_demolition","tut_builder_basics","tut_verticality",
		"twitch","calle_mayor","el_estudio_de_ana","la_pareja","el_pasillo_de_javi","zona_privada",
		"muchos_electrodomésticos",
		"mif_M","mif_A","mif_K","mif_E","mif_I1","mif_T1","mif_F","mif_I2","mif_T2"]


func _ready() -> void:
	_apply_global_font()
	load_game()
	_apply_ui_scale()
	for _lid in DEFAULT_OWNED:
		own_level(_lid)


func _apply_ui_scale() -> void:
	get_tree().root.content_scale_factor = ui_scale


func set_ui_scale(v: float) -> void:
	ui_scale = clampf(v, UI_SCALE_MIN, UI_SCALE_MAX)
	_apply_ui_scale()
	save_game()


func set_reduce_motion(v: bool) -> void:
	reduce_motion = v
	save_game()


func set_undo_keycode(kc: int) -> void:
	undo_keycode = kc
	save_game()


# Sets the engine-wide fallback font once at boot. Every themed Control (none
# of GameTheme's styles set a font override) and every draw_string(ThemeDB.
# fallback_font, ...) call throughout the codebase — furniture labels, the
# blueprint title block/dimensions, wall-panel item names — all resolve to
# this same font as a result, without touching each call site individually.
func _apply_global_font() -> void:
	const FONT_PATH := "res://assets/fonts/SpaceGrotesk.ttf"
	if ResourceLoader.exists(FONT_PATH):
		ThemeDB.fallback_font = load(FONT_PATH)


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
		"undo_keycode":    undo_keycode,
	}
	var audio := get_node_or_null("/root/Audio")
	if audio:
		data["sfx_volume"]   = audio.sfx_volume
		data["music_volume"] = audio.music_volume
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data))


func load_game() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data := parsed as Dictionary
	company_funds   = data.get("company_funds", company_funds) as int
	portfolio_rent  = data.get("portfolio_rent", portfolio_rent) as int
	completed       = data.get("completed", completed) as Dictionary
	owned           = (data.get("owned", owned) as Array).duplicate()
	dev_bonus_stars = data.get("dev_bonus_stars", dev_bonus_stars) as int
	level_layouts   = data.get("level_layouts", level_layouts) as Dictionary
	reduce_motion   = data.get("reduce_motion", reduce_motion) as bool
	ui_scale        = data.get("ui_scale", ui_scale) as float
	undo_keycode    = data.get("undo_keycode", undo_keycode) as int
	var audio := get_node_or_null("/root/Audio")
	if audio:
		if data.has("sfx_volume"):
			audio.set_sfx_volume(data["sfx_volume"] as float)
		if data.has("music_volume"):
			audio.set_music_volume(data["music_volume"] as float)


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
	level_layouts[level_id] = snapshot
	save_game()


func has_level_layout(level_id: String) -> bool:
	return level_id in level_layouts


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
