# TODO

## `sport` is met by free floor, or by the wall gym

The old entry here said `final_01`, `final_04` and `final_05` could not be finished because no
catalogue item provides `sport`. Those levels no longer exist: the level set was replaced by the
eight Königsberg demo homes. Today only `debug_moments` asks for `sport`, and it gets it from the
Day moment's `space_needs` (enough open floor; see `GameManager.gd`'s space-needs handling).

`sport` is now also a function: the **Fold-Away Wall Gym** (`wall_gym`) provides it while
unfolded, so a level can ask for it either way.

## Space-saving furniture from the Never Too Small cross-check

From cross-checking the imported pack against Never Too Small's published design articles. All in
`data/furniture.json`, each covered by a test in `tests/run_tests.gd`:

- **Sleeping pod** (`sleeping_pod`, 2.0 x 1.1 m, 980) — a closed capsule that sleeps and stores.
  Tall and opaque: it splits zones, hides what is behind it and shades the side away from the
  window, so where it stands decides which side stays bright.
- **Reeded glass screen** (`fluted_glass_panel`) — passes daylight, stops a line of sight, splits
  zones (`"screen": true`).
- **Curtain** (`curtain`) — a screen only while drawn (`"screen_when": "extended"`); it is a
  foldable, so each Moment remembers whether it is drawn.
- **Skylight** (`skylight`, 0.8 x 1.0 m, 1400) — a shop piece that hangs at the ceiling
  (`"overhead": true`, z range above the ceiling). It takes no floor, anything can stand under
  it, it lights its own tiles from above whatever stands there, and it fits under a sloped
  ceiling. Its daylight follows the Moment's daylight like a window's.
- **Fold-away wall gym** (`wall_gym`, 1.2 x 0.3 m folded, 1.5 m deep unfolded, 450) — `sport`
  only while unfolded.
- **Magnetic wall** (`magnetic_wall`, wall item, 120) — storage with no floor depth.

Fixed on the way: a foldable whose folded side gives nothing (Murphy beds, fold-down desks and
tables, the pocket bed, the curtain) used to keep its functions and fold state the same in every
Moment, because `Furniture.gd` only switched them when `folded_functions` was non-empty. Now fold
state always decides, per Moment.

Still needs real art (placeholders in use):
- `sleeping_pod` uses `makeitfit/rental_capsule.glb` (the Capsule Pod rental box).
- `wall_gym` uses `old/WallPegboard.glb`, stretched; it has no unfold animation.
- `skylight` has no model: the 3D view draws a plain pane styled as window glass.
- `magnetic_wall` uses `makeitfit/whiteboard.glb`.

Not done:
- **Retractable courtyard roof** — level geometry, not a prop.
- **Climbing wall / ladder to a play loft** — would be a narrow `is_stair` entry, but the 3D
  stairs are drawn from the stair entries' own step sizes and lofts are level geometry; worth
  doing together with the split-level work, not as a catalogue entry alone.
- Skylights don't check for a floor above them; on a multi-storey level one could go in under
  the upper floor.

Not furniture, and a separate and much larger decision: **sloped ceilings** and **split-level
floors**, both of which are recurring devices in the source material and would be level geometry
rather than props.

## Modular furniture kits from MakeItFit_GameAssets/furniture

The external asset pack (`C:\Users\rodry\Documents\MakeItFit_GameAssets\furniture`) ships two
grid-composable kits that are NOT single-footprint props like the rest of the catalog, so they
were not imported along with the single-piece items:

- `godot_glb/wall_system/` — 27 tiling modules (0.40m cells) for building custom storage walls
  piece by piece, instead of placing one fixed prop.
- `godot_glb/modular_sofa/` — 7 modules (0.90m cells) for composing a sectional sofa.

Bringing these in needs real design work, not just an asset copy:
- A new placement mode (module-by-module grid snapping along a run, distinct from the existing
  drag-a-rectangle furniture placement).
- A new save/serialize shape for a composed run (list of modules + positions, not one `grid_pos`).
- UI for picking/placing individual modules and previewing a run.
- Decide whether this is its own build tool or an extension of the existing Inventory/CategoryWheel
  flow.

Also deferred, for the same "not a single footprint prop" reason:
- `godot_glb/stairs/` (11 space-saving staircases) — the existing `stair_n/s/e/w` catalog entries
  are tied to `is_stair`/`stair_direction` fields with a fixed footprint matched to level loft
  openings; adding new stair shapes as real alternatives means deciding footprint/price for each
  and checking they still work with that mechanic.
- `godot_glb/doors/` (7 doors/sliding panels) — there's no door-as-purchasable-furniture category
  in the game yet.
- `godot_glb/architecture/` (`FoldOutBalconyWindow`, `RoofBalconyWindow`) — upgrades to the
  existing `balcony_window` mechanic; needs a decision on whether it replaces or supplements the
  current balcony item.
