class_name FurnitureColors
extends RefCounted

# Colours a player can give a piece of furniture once a level is rented out
# (Decorate, in the 3D view). A piece has up to two parts to colour, read from
# its model's materials by name: its wood, and its own colour (fabric, paint,
# lacquer). Metal, glass, ceramic, bedding and plants keep what they were
# modelled with. The choice is kept on the piece (Furniture.colors: part ->
# Color) and applied where the 3D style reads each material's colour
# (StyleController, through the "recolor" meta Room3DView sets on a piece).

const WOOD := &"wood"
const COLOUR := &"colour"

const WOOD_MATERIALS := ["M_oak", "M_walnut", "M_pine", "M_wicker"]
const FIXED_MATERIALS := ["M_chrome", "M_brass", "M_steel", "M_iron", "M_black", "M_ceramic", "M_glass",
	"M_mirror", "M_screen", "lamp", "M_water", "M_rubber", "M_tape", "M_stone", "M_worktop", "M_white",
	"M_mattress", "M_pillow", "M_leaf", "M_leaf_dark", "M_leaf_lime", "M_cardboard"]

# The swatches offered for each part.
const PALETTES := {
	COLOUR: ["f2e6cf", "9db48a", "3f8f8c", "2f4a7a", "d9a93a", "e07a5f", "e8a6b8", "4a4a4f"],
	WOOD: ["d8b47c", "b08848", "6b4a2e", "eeeae2", "2b2b2b"],
}
# i18n-const
const PART_NAMES := ["Colour", "Wood"]


# Which part a model material belongs to, or &"" for one that keeps its colour.
static func part_of(material_name: String) -> StringName:
	if material_name in FIXED_MATERIALS or material_name == "":
		return &""
	if material_name in WOOD_MATERIALS:
		return WOOD
	return COLOUR


static func part_label(part: StringName) -> String:
	return PART_NAMES[0] if part == COLOUR else PART_NAMES[1]


# A material's colour once its part has been given `target`: the target, a
# little lighter or darker as the original was lighter or darker than the
# middle, so a sofa's back, seat and cushions still read apart.
static func recolor(src: Color, target: Color) -> Color:
	const MID := 0.5
	var lum := src.get_luminance()
	var out := target.lightened((lum - MID) * 0.7) if lum > MID else target.darkened((MID - lum) * 0.7)
	out.a = src.a
	return out


# The recolourer Room3DView hangs on a piece's 3D model: (material name, its
# colour) -> the colour to draw it with. Reads the piece's choice when called,
# so re-styling the model after a change is enough.
static func recolorer(f: Furniture) -> Callable:
	return func(material_name: String, src: Color) -> Color:
		if not is_instance_valid(f):
			return src
		var part := part_of(material_name)
		if part == &"" or not f.colors.has(part):
			return src
		return recolor(src, f.colors[part] as Color)
