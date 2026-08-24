# TODO

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
