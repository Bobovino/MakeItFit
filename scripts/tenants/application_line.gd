extends Resource
class_name ApplicationLine

# One line of a rental application, in the tenant's own words, standing for
# exactly one requirement of the level (see Requirements for the ids).

# English; shown through tr() (collected by tools/i18n.py).
@export_multiline var text: String = ""
@export var requirement: String = ""
# Resident who says it; empty when the household speaks as one.
@export var speaker: StringName = &""
# Residents the requirement belongs to; empty means the whole household.
@export var owners: Array[StringName] = []
# Met for each owner (every resident when `owners` is empty) only in a room
# given to them: a bed in Lucía's room is Lucía's bed. A room shared by two
# needs it twice over. Otherwise the household's: anywhere will do.
@export var personal: bool = false
# A requirement the tenant hasn't told you about: no line is printed and its
# chip stays out of the needs bar. Revealing it is not implemented yet.
@export var hidden: bool = false
