# TODO

## `sport` is met by free floor, not furniture

The old entry here said `final_01`, `final_04` and `final_05` could not be finished because no
catalogue item provides `sport`. Those levels no longer exist: the level set was replaced by the
eight Königsberg demo homes. Today only `debug_moments` asks for `sport`, and it gets it from the
Day moment's `space_needs` (enough open floor; see `GameManager.gd`'s space-needs handling), so
no current level needs a `sport` provider.

If a future level wants `sport` as a function instead, it needs a catalogue item; the fold-away
wall gym under "Missing space-saving furniture" below would fill that.

## Missing space-saving furniture worth modelling

From cross-checking the imported pack against Never Too Small's published design articles. The
pack already covers most of the canon; these are the real gaps, ordered by how much existing
mechanics they activate:

- **Sleeping pod** — a closed sleeping capsule with integrated storage. This is the nesting
  mechanic as it exists in real architecture: a room inside a room that occupies floor and blocks
  or admits light depending on placement. Highest value of the set.
- **Fluted / translucent glass panel** — passes daylight, blocks sightline. A new *combination* of
  two systems that already exist, so close to free. Note `GlassPartition_Sliding` is already
  imported but is clear glass, which passes both.
- **Fold-away wall gym** — a wall-mounted workout station that folds flat, so it would provide
  `sport` only when unfolded. Came up as a real gap against Never Too Small. `WallPegboard.glb`
  could stand in as the model until a proper one exists; it still needs a price and footprint.
- **Curtain divider** — a `zone_divider` that opens and closes per Moment.
- **Skylight** — overhead daylight that furniture cannot block, unlike a window.
- **Magnetic wall**, **retractable courtyard roof**, **climbing wall / ladder to a play loft** —
  lower priority.

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
