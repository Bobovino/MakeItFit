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
# Cosmetic for now: the checker only knows household-wide requirements.
@export var owners: Array[StringName] = []
# A requirement the tenant hasn't told you about: no line is printed and its
# chip stays out of the needs bar. Revealing it is not implemented yet.
@export var hidden: bool = false
