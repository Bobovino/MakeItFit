extends CanvasLayer
class_name KitComposer

# Builds a run from a modular kit (Kits.gd): a storage wall cell by cell, or a
# sectional sofa seat by seat. Pick a module on the left, then tap where it
# goes in the drawing; tap a module in the drawing to take it out. The
# drawing is the wall seen from the front (cells stack up from the floor), or
# the sofa seen from above (back at the top), and a 3D render of the run sits
# under it. Confirming hands the module list back to Main, which then puts
# the run on the pointer like any other purchase (or swaps it in, when an
# already placed run is being edited).
#
# Works the same with a finger: every target is at least TOUCH_SMALL.

signal confirmed(modules: Array)
signal cancelled

const KIT_COLORS := {
	"storage": Color("c8b48a"),
	"dress":   Color("b49ac8"),
	"work":    Color("8fb0d8"),
	"sit":     Color("9cc49a"),
}
const PLAIN_COLOR := Color("c9cbd6")

# Short, translatable names; the cell size is added after them.
const MODULE_NAMES := {
	"Cube_1x1": "Open cube", "Cube_2x1": "Open cube", "Cube_3x1": "Open cube",
	"Cube_1x2": "Open cube", "Cube_1x3": "Open cube", "Cube_2x2": "Open cube",
	"Books_1x1": "Books", "Bin_1x1": "Fabric bin", "WineRack_1x1": "Wine rack",
	"Corner_1x1": "Corner shelf", "Door_1x1": "Door", "Door_2x1": "Double door",
	"GlassDoor_1x2": "Glass door", "FlapUp_2x1": "Lift-up flap", "Drawer_1x1": "Drawer",
	"Drawer_2x1": "Drawer", "Basket_1x1": "Pull-out basket", "ShoeRack_2x1": "Shoe rack",
	"Shallow_2x2": "Shallow shelf", "Hooks_2x1": "Coat hooks", "Rail_2x3": "Hanging rail",
	"Media_2x2": "TV bay", "Desk_2x1": "Fold-down desk", "Bench_2x1": "Bench",
	"Arm_1": "Armrest", "Seat_1": "Seat", "Corner_1": "Corner seat", "Chaise_1": "Chaise",
	"Ottoman_1": "Ottoman", "Storage_1": "Storage ottoman", "Console_1": "Side table",
}

var _base: Dictionary = {}
var _kit := ""
var _modules: Array = []
var _budget := 0
var _editing := false
var _selected := ""

var _view: _RunView
var _thumb: TextureRect
var _info: Label
var _reason: Label
var _ok_btn: Button
var _trim_boxes: Dictionary = {}   # trim name -> CheckBox
var _thumb_serial := 0


# `budget` is what the player can spend on this run (an edited run's own
# price is already added back in).
static func open(host: Node, base: Dictionary, modules: Array, budget: int, editing: bool) -> KitComposer:
	var c := KitComposer.new()
	c._base = base
	c._kit = Kits.kit_of(base)
	c._modules = Kits.normalize(c._kit, modules)
	c._budget = budget
	c._editing = editing
	host.add_child(c)
	c._build()
	return c


func _build() -> void:
	layer = 26
	MenuKit._backdrop(self, _cancel)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	ScreenFit.cover(center)

	var card := PanelContainer.new()
	card.theme = GameTheme.make()
	card.add_theme_stylebox_override("panel", MenuKit._card_style(MenuKit.PANEL_BG, 14, 0))
	center.add_child(card)
	var vb := MenuKit._margins(VBoxContainer.new(), 22, 12, 22, 18)
	card.add_child(vb.get_parent())
	vb.add_theme_constant_override("separation", 10)
	vb.custom_minimum_size = Vector2(1120, 620)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	vb.add_child(head)
	head.add_child(GameTheme.title_label(_base.get("name", "") as String))
	var hint := Label.new()
	hint.text = tr("Pick a module, then tap where it goes. Tap a module in the drawing to take it out.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hint.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION)
	hint.add_theme_color_override("font_color", GameTheme.INK_SOFT)
	head.add_child(hint)
	var x := MenuKit.close_button(_cancel)
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(x)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(body)
	body.add_child(_build_palette())

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(right)
	_view = _RunView.new()
	_view.composer = self
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.custom_minimum_size = Vector2(560, 300)
	right.add_child(_view)

	var under := HBoxContainer.new()
	under.add_theme_constant_override("separation", 16)
	right.add_child(under)
	var thumb_box := PanelContainer.new()
	thumb_box.add_theme_stylebox_override("panel", GameTheme.card_style(GameTheme.CARD_DIM, 10, 4, Vector2.ZERO))
	under.add_child(thumb_box)
	_thumb = TextureRect.new()
	_thumb.custom_minimum_size = Vector2(190, 140)
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb_box.add_child(_thumb)

	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	under.add_child(side)
	if _kit == "wall":
		var trims := HBoxContainer.new()
		trims.add_theme_constant_override("separation", 18)
		side.add_child(trims)
		for pair in [["Plinth", tr("Plinth")], ["Cap", tr("Cornice")], ["Filler", tr("End filler")]]:
			var cb := CheckBox.new()
			cb.text = pair[1]
			cb.focus_mode = Control.FOCUS_NONE
			cb.custom_minimum_size.y = GameTheme.TOUCH_SMALL
			cb.button_pressed = _has(pair[0])
			var trim: String = pair[0]
			cb.toggled.connect(func(on: bool): _set_trim(trim, on))
			trims.add_child(cb)
			_trim_boxes[trim] = cb
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	side.add_child(_info)
	_reason = Label.new()
	_reason.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	_reason.add_theme_color_override("font_color", GameTheme.RED)
	side.add_child(_reason)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	vb.add_child(foot)
	var clear := MenuKit.button(tr("Clear"))
	clear.pressed.connect(func():
		_modules = _modules.filter(func(e): return Kits.WALL_TRIMS.has((e as Dictionary)["m"])) if _kit == "wall" else []
		_changed())
	foot.add_child(clear)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	var cancel := MenuKit.button(tr("Cancel"))
	cancel.pressed.connect(_cancel)
	foot.add_child(cancel)
	_ok_btn = MenuKit.button("", "primary")
	_ok_btn.pressed.connect(_confirm)
	foot.add_child(_ok_btn)
	_changed()


func _build_palette() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 6)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var group := ButtonGroup.new()
	for m in Kits.module_names(_kit):
		var info := Kits.module_info(_kit, m)
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s  %s   %d€" % [module_label(_kit, m), _size_text(_kit, m), int(info["price"])]
		var fns: Array = info.get("functions", [])
		if not fns.is_empty():
			b.tooltip_text = ", ".join(fns.map(func(fn): return Loc.need_name(str(fn))))
		GameTheme.hud_button(b)
		b.add_theme_font_size_override("font_size", GameTheme.FS_CAPTION + 2)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggled.connect(func(on: bool):
			if on:
				_selected = m
				Audio.play("click")
				if _view:   # not yet, while the palette is first built
					_view.queue_redraw())
		list.add_child(b)
		if _selected == "":
			_selected = m
			b.button_pressed = true
	return scroll


static func module_label(kit: String, m: String) -> String:
	return TranslationServer.translate(MODULE_NAMES.get(m, m) as String)


static func _size_text(kit: String, m: String) -> String:
	var info := Kits.module_info(kit, m)
	if kit == "wall":
		return "%d×%d" % [int(info["w"]), int(info["h"])]
	return "%.2f m" % (int(info["w"]) * 0.1)


func _has(trim: String) -> bool:
	for e in _modules:
		if (e as Dictionary)["m"] == trim:
			return true
	return false


func _set_trim(trim: String, on: bool) -> void:
	_modules = _modules.filter(func(e): return (e as Dictionary)["m"] != trim)
	if on:
		_modules.append({"m": trim})
	_changed()


# ── Editing the run (called by the drawing) ──────────────────────────────────

func wall_tap(c: int, r: int) -> void:
	var hit := Kits.wall_module_at(_modules, c, r)
	if hit >= 0:
		_modules.remove_at(hit)
		Audio.play("sell")
		_changed()
		return
	var spot := wall_spot_for(c, r)
	if spot.x < 0:
		Audio.play("error")
		_reason.text = tr(Kits.wall_fit_reason(_modules, _selected, c, r))
		return
	_modules.append({"m": _selected, "c": spot.x, "r": spot.y})
	Audio.play("place")
	_changed()


# Where the selected module would go to cover cell (c, r): (c, r) itself as
# its bottom-left corner if it fits, else the nearest corner that still
# covers the tapped cell. (-1, -1) if none does.
func wall_spot_for(c: int, r: int) -> Vector2i:
	var info := Kits.module_info("wall", _selected)
	if info.is_empty():
		return Vector2i(-1, -1)
	for dr in int(info["h"]):
		for dc in int(info["w"]):
			if Kits.wall_fit_reason(_modules, _selected, c - dc, r - dr) == "":
				return Vector2i(c - dc, r - dr)
	return Vector2i(-1, -1)


func sofa_tap_module(index: int) -> void:
	_modules.remove_at(index)
	Audio.play("sell")
	_changed()


func sofa_tap_end(at_start: bool) -> void:
	var index := 0 if at_start else _modules.size()
	var why := Kits.sofa_fit_reason(_modules, _selected, index)
	if why != "":
		Audio.play("error")
		_reason.text = tr(why)
		return
	_modules.insert(index, {"m": _selected})
	Audio.play("place")
	_changed()


func _changed() -> void:
	_modules = Kits.normalize(_kit, _modules) if _kit == "sofa" else _modules
	var fd := {} if _run_empty() else Kits.compose(_base, _modules)
	var why := Kits.run_reason(_kit, _modules)
	var price := Kits.price_of(_kit, _modules)
	if why == "" and price > _budget:
		why = tr("Costs %d€ — you have %d€") % [price, _budget]
	else:
		why = tr(why)
	_reason.text = why
	if why == "" and not fd.is_empty():
		var sz := fd["size"] as Dictionary
		var fns: Array = fd["functions"]
		var gives := ", ".join(fns.map(func(fn): return Loc.need_name(str(fn)))) if not fns.is_empty() else tr("nothing the tenant needs")
		_info.text = tr("%.2f m wide, %.2f m deep, %.2f m tall. Gives: %s") % [
			int(sz["w"]) * 0.1, int(sz["h"]) * 0.1, float(Kits.footprint(_kit, fd["modules"])["h_m"]), gives]
	else:
		_info.text = ""
	_ok_btn.text = (tr("Update · %d€") if _editing else tr("Buy · %d€")) % price
	_ok_btn.disabled = why != ""
	_view.queue_redraw()
	_refresh_thumb()


func _refresh_thumb() -> void:
	_thumb_serial += 1
	var serial := _thumb_serial
	if _run_empty():
		_thumb.texture = null
		return
	var fd := Kits.compose(_base, _modules)
	var tex: Texture2D = await Thumb.get_icon_async(fd)
	if is_instance_valid(self) and serial == _thumb_serial:
		_thumb.texture = tex


# No module in the run yet (trims alone don't count). compose() would fill
# an empty run with the catalogue's default one.
func _run_empty() -> bool:
	return (Kits._wall_cells(_modules) if _kit == "wall" else Kits._sofa_list(_modules)).is_empty()


func _confirm() -> void:
	if _ok_btn.disabled:
		return
	var mods := Kits.normalize(_kit, _modules)
	queue_free()
	confirmed.emit(mods)


func _cancel() -> void:
	queue_free()
	cancelled.emit()


func _unhandled_input(event: InputEvent) -> void:
	if MenuKit.is_escape(event):
		get_viewport().set_input_as_handled()
		_cancel()


func color_for(m: String) -> Color:
	for fn in Kits.module_info(_kit, m).get("functions", []):
		if KIT_COLORS.has(fn):
			return KIT_COLORS[fn]
	return PLAIN_COLOR


# ── The drawing ──────────────────────────────────────────────────────────────
# The wall from the front, or the sofa from above; tapped to edit.
class _RunView extends Control:
	var composer: KitComposer
	var _hover := Vector2(-1, -1)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			_hover = (event as InputEventMouseMotion).position
			queue_redraw()
		elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed \
				and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_tap((event as InputEventMouseButton).position)
			accept_event()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			_hover = Vector2(-1, -1)
			queue_redraw()

	func _tap(p: Vector2) -> void:
		if composer._kit == "wall":
			var cell := _wall_cell_at(p)
			if cell.x >= 0:
				composer.wall_tap(cell.x, cell.y)
			return
		var hit := _sofa_hit(p)
		if hit == -1:
			composer.sofa_tap_end(true)
		elif hit == -2:
			composer.sofa_tap_end(false)
		elif hit >= 0:
			composer.sofa_tap_module(hit)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), GameTheme.BP_PAPER)
		if composer._kit == "wall":
			_draw_wall()
		else:
			_draw_sofa()

	# Wall: WALL_MAX_COLS × WALL_MAX_ROWS cells, row 0 on the floor line.
	func _wall_geom() -> Dictionary:
		var cols := Kits.WALL_MAX_COLS + 0.5
		var rows := Kits.WALL_MAX_ROWS + 0.5
		var s := floorf(minf((size.x - 40.0) / cols, (size.y - 40.0) / rows))
		var origin := Vector2((size.x - cols * s) * 0.5, size.y - 20.0)   # bottom-left of cell (0, 0)
		var plinth := Kits.PLINTH_M / Kits.WALL_CELL_M * s if composer._has("Plinth") else 0.0
		return {"s": s, "o": origin, "plinth": plinth}

	func _cell_rect(g: Dictionary, c: float, r: float, w: float, h: float) -> Rect2:
		var s: float = g["s"]
		var o: Vector2 = g["o"]
		return Rect2(o.x + c * s, o.y - g["plinth"] - (r + h) * s, w * s, h * s)

	func _wall_cell_at(p: Vector2) -> Vector2i:
		var g := _wall_geom()
		var s: float = g["s"]
		var o: Vector2 = g["o"]
		var c := floori((p.x - o.x) / s)
		var r := floori((o.y - g["plinth"] - p.y) / s)
		if c < 0 or r < 0 or c >= Kits.WALL_MAX_COLS or r >= Kits.WALL_MAX_ROWS:
			return Vector2i(-1, -1)
		return Vector2i(c, r)

	func _draw_wall() -> void:
		var g := _wall_geom()
		var s: float = g["s"]
		var o: Vector2 = g["o"]
		var ink := GameTheme.BP_INK
		var font := ThemeDB.fallback_font
		# The floor and the empty cells.
		draw_line(Vector2(8, o.y), Vector2(size.x - 8, o.y), ink, 2.0)
		for c in Kits.WALL_MAX_COLS:
			for r in Kits.WALL_MAX_ROWS:
				var cr := _cell_rect(g, c, r, 1, 1)
				draw_rect(cr.grow(-2), Color(GameTheme.BP_GRID_MAJ, 0.10))
				draw_rect(cr.grow(-2), GameTheme.BP_GRID_MAJ, false, 1.0)
		var ext := Kits.wall_extent(composer._modules)
		var width_cells := ext.x + (0.5 if composer._has("Filler") else 0.0)
		if composer._has("Plinth") and ext.x > 0:
			draw_rect(Rect2(o.x, o.y - g["plinth"], width_cells * s, g["plinth"]), Color("8a7a5c"))
		if composer._has("Cap") and ext.x > 0:
			var top := _cell_rect(g, 0, ext.y, width_cells, 0)
			draw_rect(Rect2(top.position.x - 3, top.position.y - 6, top.size.x + 6, 6), Color("8a7a5c"))
		if composer._has("Filler"):
			for r in ext.y:
				var fr := _cell_rect(g, ext.x, r, 0.5, 1)
				draw_rect(fr.grow(-1), Color("b8a888"))
		for e in composer._modules:
			var m: String = (e as Dictionary)["m"]
			var info := Kits.module_info("wall", m)
			if info.is_empty():
				continue
			var rr := _cell_rect(g, int(e["c"]), int(e["r"]), int(info["w"]), int(info["h"]))
			draw_rect(rr.grow(-2), composer.color_for(m))
			draw_rect(rr.grow(-2), GameTheme.NAVY, false, 2.0)
			draw_string(font, rr.position + Vector2(6, 18), KitComposer.module_label("wall", m),
				HORIZONTAL_ALIGNMENT_LEFT, rr.size.x - 10, 13, GameTheme.NAVY)
		# What a tap here would do.
		if _hover.x >= 0:
			var cell := _wall_cell_at(_hover)
			if cell.x >= 0 and Kits.wall_module_at(composer._modules, cell.x, cell.y) < 0:
				var info := Kits.module_info("wall", composer._selected)
				var spot := composer.wall_spot_for(cell.x, cell.y)
				var ok := spot.x >= 0
				if not ok:
					spot = cell
				var gr := _cell_rect(g, spot.x, spot.y, int(info.get("w", 1)), int(info.get("h", 1)))
				var col := GameTheme.C_GOOD if ok else GameTheme.C_BAD
				draw_rect(gr.grow(-2), Color(col, 0.35))
				draw_rect(gr.grow(-2), col, false, 2.0)
			elif cell.x >= 0:
				var hit: Dictionary = composer._modules[Kits.wall_module_at(composer._modules, cell.x, cell.y)]
				var info := Kits.module_info("wall", hit["m"])
				var gr := _cell_rect(g, int(hit["c"]), int(hit["r"]), int(info["w"]), int(info["h"]))
				draw_rect(gr.grow(-2), GameTheme.C_BAD, false, 3.0)
		# Dimension: the run's width.
		if ext.x > 0:
			var wtxt := "%.2f m" % Kits.wall_width_m(composer._modules)
			draw_string(font, Vector2(o.x, o.y + 16), wtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ink)

	# Sofa: from above, back at the top, with a "+" slot at each end.
	func _sofa_geom() -> Dictionary:
		var run := composer._modules
		var total := 0
		for e in run:
			total += int(Kits.SOFA_MODULES[e["m"]]["w"])
		var span := total + 2 * Kits.SOFA_CELL_TILES + 8   # both slots and a gap each side
		var s := minf((size.x - 40.0) / span, (size.y - 60.0) / (2 * Kits.SOFA_CELL_TILES))
		var x0 := (size.x - span * s) * 0.5 + (Kits.SOFA_CELL_TILES + 4) * s
		return {"s": s, "x0": x0, "y0": 30.0, "total": total}

	# Index of the module under p; -1 the left slot, -2 the right slot, -3 nothing.
	func _sofa_hit(p: Vector2) -> int:
		var g := _sofa_geom()
		var s: float = g["s"]
		var x0: float = g["x0"]
		var y0: float = g["y0"]
		var slot_w := Kits.SOFA_CELL_TILES * s
		if p.y < y0 or p.y > y0 + 2 * Kits.SOFA_CELL_TILES * s:
			return -3
		if p.x >= x0 - 4 * s - slot_w and p.x < x0 - 4 * s:
			return -1
		var x := x0
		for i in composer._modules.size():
			var info: Dictionary = Kits.SOFA_MODULES[composer._modules[i]["m"]]
			var w := int(info["w"]) * s
			var d := Kits.SOFA_CELL_TILES * s * (2 if info.get("deep", false) else 1)
			if p.x >= x and p.x < x + w and p.y < y0 + d:
				return i
			x += w
		if p.x >= x + 4 * s and p.x < x + 4 * s + slot_w:
			return -2
		return -3

	func _draw_sofa() -> void:
		var g := _sofa_geom()
		var s: float = g["s"]
		var x0: float = g["x0"]
		var y0: float = g["y0"]
		var ink := GameTheme.BP_INK
		var font := ThemeDB.fallback_font
		var hover_hit := _sofa_hit(_hover) if _hover.x >= 0 else -3
		# The wall it backs onto.
		draw_line(Vector2(8, y0 - 3), Vector2(size.x - 8, y0 - 3), ink, 2.0)
		var cell := Kits.SOFA_CELL_TILES * s
		var x := x0
		var run := composer._modules
		for i in run.size():
			var m: String = run[i]["m"]
			var info: Dictionary = Kits.SOFA_MODULES[m]
			var w := int(info["w"]) * s
			var d := cell * (2 if info.get("deep", false) else 1)
			var rr := Rect2(x, y0, w, d)
			draw_rect(rr.grow(-1), composer.color_for(m))
			# Back cushion along the wall, and the corner's second back.
			if float(info["h_m"]) > 0.7 and w > 4 * s:
				draw_rect(Rect2(x, y0, w, 2.2 * s), Color(GameTheme.NAVY, 0.30))
				if info.get("end", false) and run.size() > 1:
					var bx := x if i == 0 else x + w - 1.6 * s
					draw_rect(Rect2(bx, y0, 1.6 * s, d), Color(GameTheme.NAVY, 0.30))
			draw_rect(rr.grow(-1), GameTheme.NAVY, false, 2.0)
			if hover_hit == i:
				draw_rect(rr.grow(-1), GameTheme.C_BAD, false, 3.0)
			if w > 4 * s:
				draw_string(font, rr.position + Vector2(6, d - 8), KitComposer.module_label("sofa", m),
					HORIZONTAL_ALIGNMENT_LEFT, w - 10, 13, GameTheme.NAVY)
			x += w
		# The two places a module can be added.
		var slots := [Rect2(x0 - 4 * s - cell, y0, cell, cell), Rect2(x + 4 * s, y0, cell, cell)]
		for k in 2:
			var ok := Kits.sofa_fit_reason(run, composer._selected, 0 if k == 0 else run.size()) == ""
			var col := GameTheme.C_GOOD if ok else GameTheme.C_MUTED
			var r: Rect2 = slots[k]
			var hot := hover_hit == (-1 if k == 0 else -2)
			draw_rect(r.grow(-2), Color(col, 0.30 if hot else 0.12))
			draw_rect(r.grow(-2), col, false, 2.0)
			draw_string(font, r.get_center() + Vector2(-8, 10), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)
		if g["total"] > 0:
			draw_string(font, Vector2(x0, y0 + 2 * cell + 22), "%.2f m" % (int(g["total"]) * 0.1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ink)
