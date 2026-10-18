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

Not furniture, and a separate and much larger decision: **sloped ceilings** and **split-level
floors**, both of which are recurring devices in the source material and would be level geometry
rather than props.

## Modular furniture kits — follow-ups

The storage wall (`wall_system/`, 0.40 m cells) and the sectional sofa (`modular_sofa/`, 0.90 m
cells) are in the ordinary shop, one piece per module (`wallkit_*`, `sofakit_*`, all under the
Modular tab and on the category wheel). Each is bought and placed like any piece; wall modules
are surfaces, so a wall is built by stacking modules on one another. Left open:

- **Stacking needs full support.** A module only stands on one piece that covers its whole
  footprint, so a two-wide module can't bridge two one-wide cubes (the game's surface rule).
- **A stacked wall is a pile of low pieces** as far as light, sightlines and loft headroom are
  concerned: each module is judged by its own height, not the height of the stack.
- **Nothing keeps the desk or bench module at a sensible height**: a fold-down desk on the floor
  still counts for work.
- `Corner_1` (sofa) has its second back on its right only; there is no mirrored version, so a
  corner on the left end is the same piece turned.
- Module animations (drawers, doors, the ottoman lid) are not played.
- Prices and functions per module are a first pass.

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
