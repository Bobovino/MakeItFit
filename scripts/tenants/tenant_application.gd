extends Resource
class_name TenantApplication

# The rental application a level's household faxes over when the level
# starts: who lives there and what they ask for, line by line. One file per
# level in data/tenants/, named after the level id (":" becomes "_"). Levels
# without one show their needs bar straight away, as before.
#
# Nothing here affects whether a level is solved: the requirements come from
# levels.json and the checker as always; an application only voices them.

const DIR := "res://data/tenants/"

@export var level_id: String = ""
@export var residents: Array[TenantResident] = []
@export var lines: Array[ApplicationLine] = []
# Where the household stands when no free floor can be found for them (a
# room packed wall to wall). (-1, -1): the middle of the room.
@export var anchor_tile: Vector2i = Vector2i(-1, -1)


static func path_for(level: String) -> String:
	return DIR + level.replace(":", "_") + ".tres"


static func for_level(level: String) -> TenantApplication:
	var path := path_for(level)
	if not ResourceLoader.exists(path):
		return null
	return load(path) as TenantApplication


func printed_lines() -> Array[ApplicationLine]:
	var out: Array[ApplicationLine] = []
	for line in lines:
		if not line.hidden:
			out.append(line)
	return out


func hidden_requirements() -> Array[String]:
	var out: Array[String] = []
	for line in lines:
		if line.hidden and line.requirement not in out:
			out.append(line.requirement)
	return out


func resident(rid: StringName) -> TenantResident:
	for r in residents:
		if r.id == rid:
			return r
	return null


func speaker_name(line: ApplicationLine) -> String:
	var r := resident(line.speaker)
	return tr(r.display_name) if r else ""


# "Marisol" / "Lena and Aron" / "Jonas, Petra, Mia and Ben".
func signatories() -> String:
	return Loc.join_list(residents.map(func(r): return tr((r as TenantResident).display_name)))


# The line that voices `req_id`, or null. A moment's need is voiced by the
# line for that need ("moment:night:sleep" -> "need:sleep").
func line_for(req_id: String) -> ApplicationLine:
	var parts := req_id.split(":")
	var need_id := ("need:" + parts[2]) if parts[0] == "moment" and parts.size() > 2 else ""
	for line in lines:
		if line.requirement == req_id:
			return line
	for line in lines:
		if need_id != "" and line.requirement == need_id:
			return line
	return null

