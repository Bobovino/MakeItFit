extends RefCounted
class_name Requirements

# Stable ids for the requirements a level shows in its needs bar, so data
# (an application line) can point at one:
#
#   need:<function>          a furniture need ("need:sleep"); on a level with
#                            moments, that need in every moment that has it
#   moment:<moment>:<fn>     the need in one moment only ("moment:night:sleep")
#   sight:<n>                the n-th line of sight (1-based, as numbered on
#                            the plan and on its chip)
#   zones:<n>                the n-th zone separation (1-based)
#
# These name what the checker (GameManager) already evaluates; nothing here
# changes how a level is solved.

const ICON_DIR := "res://assets/icons/requirements/"


# Every id the needs bar of `level` (a levels.json entry) can show.
static func ids_for_level(level: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var tenant := level.get("tenant", {}) as Dictionary
	var moments := level.get("moments", []) as Array
	if moments.is_empty():
		for fn in tenant.get("required_functions", []) as Array:
			_add(out, "need:" + str(fn))
	else:
		for m in moments:
			for fn in (m as Dictionary).get("needs", []) as Array:
				_add(out, "need:" + str(fn))
				_add(out, "moment:%s:%s" % [(m as Dictionary)["id"], fn])
	for i in (tenant.get("sightline_requirements", []) as Array).size():
		_add(out, "sight:%d" % (i + 1))
	for i in (tenant.get("zone_separations", []) as Array).size():
		_add(out, "zones:%d" % (i + 1))
	return out


static func _add(list: Array[String], id: String) -> void:
	if id not in list:
		list.append(id)


# The icon key of a requirement: its function for needs, else its kind.
static func icon_key(id: String) -> String:
	var parts := id.split(":")
	match parts[0]:
		"need":   return parts[1] if parts.size() > 1 else ""
		"moment": return parts[2] if parts.size() > 2 else ""
	return parts[0]


# A drawn icon when assets/icons/requirements/<key>.png exists (the final
# icon pack drops in there), else null and callers fall back to glyph().
static func icon(id: String) -> Texture2D:
	var path := ICON_DIR + icon_key(id) + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


static func glyph(id: String) -> String:
	var key := icon_key(id)
	match key:
		"sight": return "👁"
		"zones": return "🚧"
	return TenantCard.NEED_GLYPH.get(key, "❔") as String


# A control showing the requirement's icon at `px` pixels.
static func make_icon(id: String, px: int) -> Control:
	var tex := icon(id)
	if tex:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(px, px)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return rect
	var lbl := Label.new()
	lbl.text = glyph(id)
	lbl.add_theme_font_size_override("font_size", px)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


# Whether each requirement is met right now, by id, read from what the
# checker last computed (GameManager, after Main._refresh_functions()).
# Moments: a moment's need is read from that moment's own results; "need:x"
# is met only when every moment asking for x has it.
static func status(gm: GameManager) -> Dictionary:
	var out := {}
	var level := gm.current_level
	if gm.moments.is_empty():
		for fn in (level.get("tenant", {}) as Dictionary).get("required_functions", []) as Array:
			out["need:" + str(fn)] = fn in gm.fulfilled_functions
	else:
		for m in gm.moments:
			var mid := (m as Dictionary)["id"] as String
			var got := ((gm.moment_results.get(mid, {}) as Dictionary).get("fulfilled", []) as Array)
			for fn in (m as Dictionary).get("needs", []) as Array:
				var ok: bool = fn in got
				out["moment:%s:%s" % [mid, fn]] = ok
				out["need:" + str(fn)] = ok and out.get("need:" + str(fn), true)
	for i in gm.sightline_status.size():
		out["sight:%d" % (i + 1)] = (gm.sightline_status[i] as Dictionary).get("ok", true)
	for i in gm.zone_separations.size():
		out["zones:%d" % (i + 1)] = gm._separation_ok(gm.zone_separations[i] as Array)
	return out

