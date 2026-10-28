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

Not furniture: **sloped ceilings** and **split-level floors** are now level geometry (per-floor
`ceiling_ramps`, `floor_levels` and `step_tiles`, authored in the level editor; see
`debug:_attic` and `debug:_split_level`). Still open: lofts don't lose headroom under a slope,
the two levels sit in the Debug district rather than on the city map, and real ceilings on
their own floor tab (the ramps are plain per-floor data, ready to move there).

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

## Special moves: crawl, climb, squeeze, tried by the player in first person

Idea, not built. Reaching things in a small flat sometimes takes moves the walking check doesn't
know: crawling under a loft, climbing over the bed to the window, squeezing sideways past a
wardrobe. Rather than simulating those, let the player do them.

- **Ordinary moves stay automatic.** Walking (and probably sidestepping) is checked instantly as
  now; nobody walks those routes by hand.
- **Hard spots become a "maybe".** When the only way through needs a special move, the check
  answers neither yes nor no: the need's chip gets a "try it" (footprint) icon and the stretch is
  outlined on the plan. Only where it is plausible: a 10 cm gap is just blocked.
- **The player tries it.** The chip drops them into first person (`Room3DView.enter_first_person`)
  at the start of that stretch, with the special controls shown (crouch, crawl, climb). Through:
  confirmed. Stuck: blocked, back to the plan to rearrange.
- **A confirmed stretch stays confirmed** until a piece next to it moves; then it is "try it"
  again. Moving something across the room doesn't undo it.
- **Each move has fixed body sizes**, the same in first person and in the check (say walking
  ~60 cm wide at full height, sidestepping ~35 cm, crouching ~1.2 m high, crawling ~70 cm high and
  ~50 cm wide), so the player can't get through what the rules call closed, and a way through the
  rules don't know is a gap in the rules, not proof.
- **It costs comfort**, like a heavy piece moved by hand between moments: a route that needs
  crawling works, but the tenant pays every day ("Crawls to bed: comfort −15%").
- **A level can't be finished with an untried "maybe".** The level validator counts a "maybe" as
  solvable, so levels stay checkable without playing them.

First prototype: the beach house. A spot reachable only by crawling or climbing over the bed,
crouch and crawl in the walk-through, the check marking that route "try it", the chip that drops
you there, and the confirmation kept until something nearby moves.
