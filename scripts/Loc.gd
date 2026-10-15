extends RefCounted
class_name Loc

# Localization helpers. The catalogs are gettext files in res://locale/
# (de.po, es.po), keyed by the English text itself: anything missing from a
# catalog simply shows in English. Regenerate the template and merge new
# strings into the catalogs with `python tools/i18n.py extract`, and check
# them with `python tools/i18n.py check`.
#
# Scripts translate their own literals with tr("..."); anything that isn't a
# literal in code (level names, tenant flavour, furniture names, read from the
# JSON data files) goes through Loc.data() at the point it is shown, and the
# extractor collects those fields from the JSON directly.

const LANGUAGES := {
	"en": "English",
	"de": "Deutsch",
	"es": "Español",
}
const DEFAULT_LANGUAGE := "en"


# The language to use when the player hasn't picked one: the device's own, if
# the game has it.
static func system_language() -> String:
	var lang := OS.get_locale_language()
	return lang if LANGUAGES.has(lang) else DEFAULT_LANGUAGE


static func apply(lang: String) -> void:
	TranslationServer.set_locale(lang if LANGUAGES.has(lang) else system_language())


static func current() -> String:
	return TranslationServer.get_locale().substr(0, 2)


# Text that comes from the data files rather than from a literal in code.
static func data(text: String) -> String:
	if text == "":
		return text
	return TranslationServer.translate(text)


# Translates, in place, the player-facing fields of a freshly loaded
# levels.json, so every screen showing them gets the current language without
# its own lookup. Only for copies the game reads: the level editor loads its
# own and writes it back, so it must keep the English source. The tenant's
# English name is kept as "key_name" for things derived from it (their
# colour), which must not change with the language.
static func localize_levels(data: Dictionary) -> Dictionary:
	for b in data.get("blocks", []) as Array:
		_tr_fields(b as Dictionary, ["name", "subtitle", "intro"])
	for lv in data.get("levels", []) as Array:
		var level := lv as Dictionary
		_tr_fields(level, ["name"])
		var tenant := level.get("tenant", {}) as Dictionary
		if tenant.has("name") and not tenant.has("key_name"):
			tenant["key_name"] = tenant["name"]
		_tr_fields(tenant, ["name", "flavor"])
		for r in tenant.get("sightline_requirements", []) as Array:
			_tr_fields(r as Dictionary, ["label", "short"])
		_tr_fields(level.get("mechanic_intro", {}) as Dictionary, ["title", "body"])
		for m in level.get("moments", []) as Array:
			_tr_fields(m as Dictionary, ["label"])
		for fl in (level.get("apartment", {}) as Dictionary).get("floors", []) as Array:
			_tr_fields(fl as Dictionary, ["label"])
	return data


static func localize_furniture(data: Dictionary) -> Dictionary:
	for f in data.get("furniture", []) as Array:
		_tr_fields(f as Dictionary, ["name"])
	for p in data.get("paintable", []) as Array:
		_tr_fields(p as Dictionary, ["label"])
	return data


static func _tr_fields(d: Dictionary, keys: Array) -> void:
	for k in keys:
		if d.get(k) is String:
			d[k] = data(d[k] as String)


# Player-facing name of a need/function id ("sleep" -> "Sleep" / "Schlafen").
# Ids are data, not English text, so they get their own table instead of
# being capitalized and shown as-is.
static func need_name(id: String) -> String:
	match id:
		"sleep":       return TranslationServer.translate("Sleep", "need")
		"hygiene":     return TranslationServer.translate("Hygiene", "need")
		"cook":        return TranslationServer.translate("Cook", "need")
		"work":        return TranslationServer.translate("Work", "need")
		"sit":         return TranslationServer.translate("Sit", "need")
		"storage":     return TranslationServer.translate("Storage", "need")
		"eat":         return TranslationServer.translate("Eat", "need")
		"dine":        return TranslationServer.translate("Dine", "need")
		"social":      return TranslationServer.translate("Social", "need")
		"pet":         return TranslationServer.translate("Pet", "need")
		"dress":       return TranslationServer.translate("Dress", "need")
		"laundry":     return TranslationServer.translate("Laundry", "need")
		"balcony":     return TranslationServer.translate("Balcony", "need")
		"sport":       return TranslationServer.translate("Sport", "need")
		"loft_access": return TranslationServer.translate("Loft access", "need")
		"light":       return TranslationServer.translate("Light", "need")
		"ventilation": return TranslationServer.translate("Ventilation", "need")
	return id.capitalize()


# Player-facing name of a floor kind ("bathroom" -> "bathroom" / "Bad").
static func floor_kind_name(kind: String) -> String:
	match kind:
		"bathroom": return TranslationServer.translate("bathroom", "floor kind")
		"balcony":  return TranslationServer.translate("balcony", "floor kind")
		"normal":   return TranslationServer.translate("normal", "floor kind")
	return kind


# "a, b and c" in the current language.
static func join_list(items: Array) -> String:
	var parts: Array = items.map(func(x): return str(x))
	if parts.size() <= 1:
		return "".join(parts)
	var head := ", ".join(parts.slice(0, parts.size() - 1))
	return TranslationServer.translate("%s and %s") % [head, parts[-1]]
