# TODO

## `sport` has no provider — three levels are uncompletable

`final_01`, `final_04` and `final_05` (Friedrichshain) require the `sport` function, and no
catalogue item supplies it in `functions`, `folded_functions` or `extended_functions`. Those
levels cannot currently be finished.

`dress` had the same problem and is fixed — tagged on `wardrobe`, `sliding_wardrobe_tall`,
`dresser`, `clothes_rack`, `rolling_clothes_rack`, `vanity_desk` and `floor_mirror`, which
cleared `apr_10`, `loft_10` and `final_02`.

`sport` was deliberately left untagged: nothing in the catalogue honestly provides it, and
tagging a rug would leave the function meaningless to the player. Two ways to close it:

- **Add a catalogue entry** — a fold-away wall gym. This is wanted content anyway (it came up as
  a genuine gap when cross-checking against Never Too Small), and it can ship immediately reusing
  `WallPegboard.glb` as a placeholder model until the real one is made. Needs a price and
  footprint.
- **Reinterpret `sport` as a free-space requirement** using the existing `space_needs`/`min_free`
  machinery rather than as a function. Arguably truer — floor exercise needs clear floor, not
  equipment — but it changes those three levels' data shape and removes `sport` from the function
  vocabulary.

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
- **Curtain divider** — a `zone_divider` that opens and closes per Moment.
- **Skylight** — overhead daylight that furniture cannot block, unlike a window.
- **Magnetic wall**, **retractable courtyard roof**, **climbing wall / ladder to a play loft** —
  lower priority.

Not furniture: **sloped ceilings** and **split-level floors** are now level geometry (per-floor
`ceiling_ramps`, `floor_levels` and `step_tiles`, authored in the level editor; see
`debug:_attic` and `debug:_split_level`). Still open: lofts don't lose headroom under a slope,
the two levels sit in the Debug district rather than on the city map, and real ceilings on
their own floor tab (the ramps are plain per-floor data, ready to move there).

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
