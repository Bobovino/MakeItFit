class_name LevelPalette
extends Resource

# One level's whole colour mood, as data. A level is built around ONE
# desaturated, slightly milky hue: the floor is its lightest tint, walls a
# light tint, large furniture a darker tint, and a single contrasting accent
# is kept for small, important objects. StyleController reads this and pushes
# it into the environment, the sun, the backdrop and every styled material.
#
# To add a palette: duplicate one of the .tres files in res://style/palettes/,
# rename it, and change the colours in the inspector. Nothing else to wire up.

@export var display_name: String = "Palette"

@export_group("Surfaces")
## Lightest large surface in the level.
@export var floor_color: Color = Color(0.9, 0.93, 0.92)
## Light tint of the level hue. Also used for light-coloured furniture parts.
@export var wall_color: Color = Color(0.79, 0.86, 0.84)
## Darker tint of the same hue, for large furniture.
@export var furniture_color: Color = Color(0.37, 0.56, 0.55)
## Contrasting colour, reserved for small, important objects.
@export var accent_color: Color = Color(0.88, 0.45, 0.29)
## How much darker surfaces get toward the floor (0 = flat paper).
@export_range(0.0, 0.6, 0.01) var gradient_strength: float = 0.28
## Tone variation between floorboards (0 = plain floor). Keep it subtle.
@export_range(0.0, 0.3, 0.01) var floor_pattern: float = 0.07
## How much of a model's own light/dark material variation survives the
## recolour, so a sofa's cushions still read apart from its frame.
@export_range(0.0, 1.0, 0.01) var material_contrast: float = 0.55
## How much of a model's original material hue leaks through (0 = fully on-palette).
@export_range(0.0, 1.0, 0.01) var keep_source_color: float = 0.08

@export_group("Light")
@export var light_color: Color = Color(1.0, 0.96, 0.9)
@export_range(0.0, 4.0, 0.01) var light_energy: float = 1.1
## Ambient light, tinted toward the level hue.
@export var ambient_color: Color = Color(0.75, 0.84, 0.83)
@export_range(0.0, 2.0, 0.01) var ambient_energy: float = 0.5
## Darker version of the level hue. Shadows and unlit faces are filled with
## this instead of going neutral grey/black.
@export var shadow_tint: Color = Color(0.18, 0.37, 0.4)
## Strength of that fill. Higher = lighter, more coloured shadows.
@export_range(0.0, 1.0, 0.01) var shadow_fill: float = 0.5

@export_group("Atmosphere")
## Backdrop gradient, both hazier versions of the level hue: the deeper one
## at the top, the palest at the bottom, where the level's block dissolves.
@export var background_top: Color = Color(0.49, 0.69, 0.69)
@export var background_bottom: Color = Color(0.83, 0.9, 0.89)
## Colour the far edges of the diorama fade toward.
@export var fog_color: Color = Color(0.83, 0.89, 0.88)
## Maximum fog opacity at the far edge. Keep low: readability comes first.
@export_range(0.0, 1.0, 0.01) var fog_strength: float = 0.16
## Mild lift so the scene reads high-key (1 = untouched).
@export_range(0.8, 1.3, 0.01) var brightness: float = 1.06

@export_group("Glow and vignette")
## Colour of windows and lamps (the only things that glow).
@export var glow_color: Color = Color(1.0, 0.91, 0.72)
## Emission strength of windows/lamps. Above ~1.5 they bloom on Medium/High.
@export_range(0.0, 6.0, 0.01) var glow_energy: float = 2.2
@export var vignette_color: Color = Color(0.14, 0.28, 0.3)
@export_range(0.0, 1.0, 0.01) var vignette_strength: float = 0.25
