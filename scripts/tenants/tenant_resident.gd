extends Resource
class_name TenantResident

# One member of a household: a person, or an animal that lives there too.
# Lines in a TenantApplication are spoken by a resident. For now who owns a
# requirement is only used to give it a voice; the checker still treats every
# requirement as the household's.

@export var id: StringName = &""
# English; shown through tr() (collected by tools/i18n.py).
@export var display_name: String = ""
@export_enum("adult", "teen", "child", "animal") var body: String = "adult"
# Which Mii they get in 3D; "any" lets their id decide.
@export_enum("any", "fem", "masc") var look: String = "any"


func is_feminine() -> bool:
	if look != "any":
		return look == "fem"
	return absi(String(id).hash()) % 2 == 0
