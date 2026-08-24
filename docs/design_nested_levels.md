# Nested / Parabox Levels — Design Doc

Status: **draft, no implementation started**. Written to be read before any code changes to Room3DView.gd, GameState.gd, or the level JSON schema.

## 1. The mechanic, restated

A "box" is a placeable object in a parent apartment. The box's interior is not a
model — it *is* an entire other apartment (its own grid, walls, furniture,
tenant, moments), rendered at a smaller scale so it fits inside the box's
footprint. Boxes can nest arbitrarily deep (a box inside a box inside a box),
same as Patrick's Parabox.

Two things make this more than "a apartment drawn small inside a prop":

- **The box is a real object in the parent grid.** It has a footprint, it can
  be pushed/moved/rotated by the player like any furniture, and (per your
  example) it can be dragged in front of a window to block light reaching
  the small apartment inside it.
- **Each nested apartment keeps its own "down."** Rotating or repositioning
  the box in the parent grid must not tip over the furniture inside it — the
  child apartment's floor stays "the floor" from the child's own point of
  view, independent of the box's orientation in the parent. This is the
  "conservar la gravedad original" requirement.

## 2. Data model

Today a level's playable space is a single `apartment: { floors: [...],
grid_w, grid_h }` object (see `data/levels.json`). The floors array already
supports multiple named floors per apartment (ground floor, ceiling, roof),
built from wall segments, so the grid/wall/furniture pipeline is reusable
as-is for a nested apartment — a nested apartment is structurally the same
kind of object as a top-level one.

Proposed schema addition — a new furniture category, `"placement": "box"`:

```jsonc
{
  "id": "shoebox_small",
  "placement": "box",
  "size": { "w": 6, "h": 6 },      // footprint in the PARENT grid, tiles
  "box_interior": {
    "apartment": { /* full apartment object, same shape as a level's */ },
    "tenant": { /* optional — a nested apartment can have its own tenant */ },
    "moments": []
  },
  "buy_price": 0,                    // boxes are probably level-authored, not shop-bought, at least initially
  "model": "res://assets/models/furniture/shoebox.glb"
}
```

Key decision: **the nested apartment's data lives inside the box furniture
instance**, not as a separate top-level `levels.json` entry. A box is placed
per-level (like `starting_furniture`), and its interior travels with it —
if the player moves the box, the interior moves with it; if they could
(later) pick the box up and carry it between levels, the interior comes too.
This also makes recursion trivial: `box_interior.apartment`'s own
`starting_furniture` can itself contain a `"placement": "box"` item.

## 3. Rendering approach

Recommendation: **recursive scale-down, not portal rendering.**

A true Parabox-style renderer (peering into the box and seeing its contents
at 1:1 scale through a "window") needs render-to-texture portals and
matching physics per portal. This game's rooms are static geometry with a
single orbit camera per level, not a first-person walk-through — a much
cheaper option fits:

- The box's `MeshInstance3D` gets a child `Node3D` holding a fully
  instantiated miniature of the child apartment's 3D scene (same
  `Room3DView`-style wall/floor/furniture builder, just invoked recursively
  on `box_interior.apartment` instead of the top-level level data).
- That child `Node3D` is uniformly scaled down so the child apartment's
  full `grid_w × grid_h` footprint fits inside the box's own declared
  `size.w × size.h` (plus a wall-thickness margin so you can see the child's
  walls). E.g. child_scale = box_size_m / max(child_grid_w, child_grid_h) *
  TILE_M.
- **Orientation is decoupled**: the child `Node3D`'s own rotation is reset
  to identity in box-local space every frame (or rather, never inherits the
  box's rotation beyond position) — only inherits the box's *position*, not
  its rotation. If the box is rotated 90°/180° by the player, the miniature
  interior does NOT rotate with it; it stays upright. This gets you "gravity
  preserved" for free, since nothing about the child scene's own up-axis is
  touched.
- "Entering" a box (click to open) swaps the camera/view to load
  `box_interior.apartment` as if it were its own level — reusing the
  existing level-load path — with a "close box" affordance to pop back out.
  This is the cheap 90% of the mechanic and needs no portal rendering at
  all.

This means **two different representations of the same child apartment
coexist**: the full-size one used while "inside" it (normal Room3DView), and
the miniature decorative one rendered inside the box mesh while viewing the
parent. They need to stay in sync (furniture state, moments) but don't need
to be the literally same scene tree — the miniature can just be rebuilt
from the same JSON/state whenever it's dirtied (fold toggled, item moved),
same as how the shop's `ThumbnailRenderer` re-renders on demand rather than
keeping a live camera feed.

## 4. Cross-frame interactions (light, sightlines)

This is the part that doesn't fall out for free from "just nest the scene
tree and scale it," because a normal Godot raycast against the miniature
child's (tiny, scaled) collision shapes would produce geometrically correct
but practically useless results (a ray traveling through 6 tiles of
miniaturized child-apartment space isn't the same distance/occlusion as 6
tiles of real child-apartment space).

Recommended approach: **sightline checks are logical, not physical raycasts
through the live 3D scene.** Model each apartment (top-level or nested) as
its own 2D occupancy grid (this already conceptually exists for wall
placement). A sightline / light path is computed as a sequence of grid
segments:

1. Trace the ray in the *source* apartment's grid until it would exit
   through a window/opening, or hit an opaque obstruction (existing
   per-level occlusion check — extend the "sightlines with height-blocking"
   mechanic you listed separately to produce a per-tile blocked/clear
   result, not just a boolean visible/not-visible).
2. If the ray exits through a box's window and that box is a container for a
   nested apartment, **re-enter the trace inside the child apartment's own
   grid**, translating the parent's exit point/direction into the child
   grid's coordinate frame (using the box's declared "which wall faces
   outward" mapping — needs one explicit convention, e.g. box's north wall
   in parent-space = child apartment's own north wall).
3. Recurse for arbitrarily deep nesting.

This keeps the physics/lighting model dimension-agnostic (a "tile" of light
occlusion means the same thing whether it's in a full-size level or three
levels deep inside boxes), and reuses whatever the flat-case sightline
system already needs to compute (segment-by-segment occlusion with height
comparison) — nesting is just "don't stop the trace at the box wall, jump
grids and keep going." This is the natural point where nested levels and
the sightline/blocking mechanic you listed together are NOT separable —
the whole reason nesting is interesting per your example is that this
cross-frame trace exists.

The other three mechanics you listed (furniture weight/support, free
cells/ventilation, external zone restrictions) don't have this coupling —
they can be designed and built independently, later, as their own systems
that happen to also apply inside nested apartments once nesting exists.

## 5. Open questions to settle before writing code

1. **Entry/exit UX**: click the box to "zoom into" it and edit as a normal
   level, with an explicit "back to parent" button? Or an always-visible
   nested viewport you can edit in-place without a modal transition?
2. **Can the player create boxes**, or are they level-authored set pieces
   (a level ships with a fixed box + fixed interior, and the player's job
   is to arrange the OUTER apartment around it)? This changes whether
   `box_interior` needs a shop/economy of its own (rent, tenant happiness)
   or is just static dressing for round 1.
3. **Does a nested apartment have its own tenant/rent/moments**, fully
   independent progression like a real level, or is it always a "prop
   apartment" with no economic loop of its own (only affects the parent's
   score via light-blocking etc.)?
4. **Box wall-facing convention** — which parent-box wall corresponds to
   which child-apartment wall, for the cross-frame sightline trace in §4,
   needs one fixed rule (simplest: box's "front" face, as placed, always
   maps to child apartment's "south" wall; rotating the box in the parent
   remaps which parent-wall is "front" but never touches the child's own
   layout).
5. **Recursion depth limit** — unbounded nesting is conceptually clean but
   the miniature-render approach in §3 gets visually useless past 2-3
   levels (everything shrinks geometrically). Worth capping at a fixed
   depth (e.g. 3) for both rendering and sightline-trace performance
   reasons, unless depth itself is meant to be a puzzle mechanic.

## 6a. Implementation note (post-build)

Entry/exit ended up NOT being "click the box" as originally sketched in §3 —
a box needs to behave like any other draggable piece of furniture so the
player can reposition it in the parent apartment without accidentally
stepping inside it. Instead, entering/leaving is only ever done through a
small mini-plan panel (a real blueprint-style top-down sketch, reusing
`BlueprintPreview.gd` — the same one CityMap's level cards use) floating
next to the Minimap floor tabs: it shows the *other* space's plan (the box's
interior while looking at the parent, or the parent's plan while inside the
box) and switches on click. `Main._current_level_boxes` tracks every
is_nested_box instance in the currently loaded level so the panel knows what
to offer.

Built as described above, with one addition beyond the original plan: level
state now round-trips across a nested transition. `Main._snapshot_level_state()`
captures every real (Furniture-backed) floor item's id/position/rotation/fold
state plus budget whenever a level is about to be torn down for a transition
(entering a box, or leaving one), keyed by level id in `_level_state_cache`;
`_apply_level_state_snapshot()` replaces whatever the fresh JSON load just
spawned with that cached layout if one exists. This means re-entering the
same box later resumes exactly where the player left its interior, and
returning to the parent restores whatever they'd built there before
entering — not just each level's authored starting state.

A minimum interior size is enforced: `Main.MIN_NESTED_INTERIOR_M2 := 20.0`
(the reverse-Parabox punchline — tiny on the outside, still a livable
apartment on the inside). `_level_floor_area_m2()` computes a candidate
child level's floor area from its JSON (without loading it — same
floor_tiles/grid_w*grid_h fallback convention as `Wall.count_free_tiles_for_moment()`)
and `_on_box_entered()` refuses entry below that, so an under-sized custom
level a player authors as a box interior is silently rejected (audio-only
feedback) rather than crashing or half-loading.

Known gap: `Wall.wall_items` entries (furniture hung via the 2D wall-drop
flow — a plain Dictionary with no live Furniture node, see this doc's
original "two placement systems" framing) aren't captured by the snapshot,
only real Furniture-backed floor items are.

## 6. Suggested build order (once the above is settled)

1. Schema: add `"placement": "box"` + `box_interior` to furniture.json /
   level authoring, no rendering yet — just data + a debug level with one
   box.
2. Entry/exit flow: clicking a box loads its `box_interior.apartment`
   through the existing level-load path (reusing Main.gd's `_load_level`),
   with a way back to the parent. No miniature rendering yet — box just
   looks like an opaque prop from outside until this UX is nailed down.
3. Miniature rendering inside the box mesh (§3), orientation-decoupled.
4. Cross-frame sightline trace (§4) — needs the flat-case sightline/height-
   blocking system to exist first (separate mechanic, build that before
   attempting the recursive version).
5. Recursion (box-inside-a-box) — should mostly fall out of 1-3 being
   written generically, but verify explicitly with a 2-deep debug level.
