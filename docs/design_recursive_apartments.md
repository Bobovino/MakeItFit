# Recursive Apartments — Design Doc

Status: **draft, no implementation started**. Written to be read before any code changes to
`Wall.gd` (`has_sightline()`, `_recalculate_zones()`, `can_place()`) or `Main.gd`'s nested-box
entry path. Assumes `docs/design_nested_levels.md` has been read — nesting itself is **built**;
this doc is about the two things nesting deliberately does *not* do yet.

## 1. Two different mechanics

These get conflated in conversation because both are "recursion," but they are separate
features with different costs and different puzzles:

| | **Looping** | **Self-containment** |
|---|---|---|
| Idea | The apartment's exits wrap back to its own entrances | The apartment contains a scaled copy of itself |
| Depth | Finite — one space, wrapped | Infinite (needs a termination rule) |
| Scale | 1:1, no shrinking | ~8× linear shrink per level |
| Cost | Low — two functions change | High — needs convergence semantics |
| Puzzle | Spatial: does it fit in a space with no outside? | Consequential: is this layout stable under itself? |

Both are worth building. They are independent — neither blocks the other.

## 2. Looping — the apartment with no outside

Every door/opening on the boundary maps to another opening on the same grid. Walk out one,
come in another. There is no exterior. Thematically this is the game's central joke taken to
its limit: `<0 m²`.

### 2.1 What it does to the existing systems

Three systems change behaviour, and all three changes are *small* because of decisions already
made elsewhere in the codebase:

**Furniture can collide with its own tail.** This is the headline mechanic and the reason to
build it. A 10-tile sofa placed across the seam of a 10-tile loop wraps around and overlaps
itself. "Does it fit" stops being a question about walls and becomes a question about whether
the piece is shorter than the universe. No other game in this genre has this, and it is a pure
expression of the title.

Touches `Wall.can_place()`: tile lookups wrap, and a piece's own wrapped tiles must be checked
against each other, not just against other furniture. This is the most invasive of the three
changes and the one to prototype first, since it is where the mechanic lives or dies.

**Sightlines wrap.** `Wall.has_sightline()` (Wall.gd:1494) is already a Bresenham walk over
grid tiles — purely logical, no physics raycast, exactly as `design_nested_levels.md` §4
committed to. Wrapping is: wrap `x0`/`y0` at the boundary and continue, with a step budget to
terminate (a ray that never hits anything would otherwise circle forever). The desk can now see
the bed the long way round, so `must_be_clear` requirements stop being readable at a glance.

**Zone separation changes meaning.** Correcting an earlier assumption: `check_zone_separations()`
(GameManager.gd:418) is **not** distance-based. It is connectivity-based — zones are BFS
flood-fill connected components (`Wall._recalculate_zones()`, Wall.gd:1167, with `zone_divider`
furniture acting as walls), and a separation fails when one zone contains a function from both
groups.

This makes looping *better* than a distance metric would. A wrapping door **merges two
components into one zone**, so a bedroom and kitchen that look comfortably far apart on the
blueprint are silently the same zone, and the separation requirement fails. The fix the player
discovers is to place a `zone_divider` across the seam — which costs them the very floor space
the loop was supposed to save. That is a good trade to hand a player.

Implementation is a one-line change to the BFS neighbour function.

### 2.2 What it gives the player

- **Light routing.** Sun in the window, out the door, back in the far door — light a windowless
  corner by aiming it around the loop.
- **A real reason to use `zone_divider`.** Currently a niche flag; in a looped level it is the
  primary tool for controlling connectivity.
- **Legible novelty.** The rule is one sentence ("the doors connect to each other") and every
  consequence follows from it. Compare self-containment below, which is much harder to teach.

### 2.3 Schema sketch

```jsonc
{
  "id": "loop:_first",
  "apartment": {
    "grid_w": 20, "grid_h": 12,
    "loop": {                       // absent = today's behaviour, no wrapping
      "pairs": [
        { "a": "west", "b": "east" },          // classic torus wrap
        { "a": { "side": "north", "from": 2, "to": 5 },
          "b": { "side": "north", "from": 12, "to": 15 } }   // partial: two doors on the same wall
      ]
    }
  }
}
```

Full-side pairs give a torus. Partial spans give the more interesting case — a door on the
north wall that leads back in through another door on the north wall, which is the version
that reads as "a door to somewhere else in the same flat" rather than as an abstract wrap.

Open: whether a wrap can also *rotate* (west edge → north edge). Cheap in the tile math,
potentially very confusing to read on a blueprint. Recommend shipping axis-aligned pairs only
in v1.

## 3. Self-containment — the apartment inside itself

The box in the apartment contains **this apartment**. Whatever you place appears inside it, and
inside that, forever.

### 3.1 Why it is a mechanic and not just eye candy

The obvious framing — "look, it recurses" — is observational, not a decision. But this game
already has something that makes self-reference *consequential*: the cross-frame coupling
mechanics built on top of nesting (daylight occlusion, bidirectional noise, interior weight →
box mobility tier, wall-side external-zone override).

**Self-reference turns every one of those couplings into a feedback loop.**

Worked example, daylight. Today `_compute_box_occlusion()` measures how much parent furniture
blocks the box's light and hands the child a `daylight_factor`. If the child *is* the parent:

| pass | factor |
|---|---|
| 0 | 1.00 (authored) |
| 1 | 0.60 (a wardrobe half-blocks the window) |
| 2 | 0.36 |
| 3 | 0.216 |
| … | → 0 |

That layout spirals to darkness. Move the wardrobe clear of the window and the factor is 1.0,
which maps to 1.0, which is stable forever.

So a layout is no longer just "does it fit" — it is **is this arrangement stable under its own
consequences?** Some converge to a livable fixed point. Others run away: a noisy TV placed near
the box mutes the `needs_quiet` bed inside, and the bed inside is *the same bed*.

This is a genuine puzzle, it is decision-rich, and it is only possible because the coupling
systems already exist. It is also, usefully, the answer to the termination problem in §3.2 —
the recursion terminates because the *numbers* converge, not because of an arbitrary cap.

### 3.2 The termination rule

Self-reference is currently **refused outright** (Main.gd:1062–1068):

```gdscript
if box.child_level_id == _current_level_id:
    push_warning("Nested box points at its own level (%s) — refusing to enter")
    return
for ctx in _nested_stack:
    if ctx["parent_level_id"] == box.child_level_id:
        push_warning("Nested box would create a cycle back to %s — refusing to enter")
        return
```

That was correct when written — the comment notes the stack would grow forever. Unlocking this
means replacing both guards with something principled. Proposed:

1. **Coupling values are iterated to convergence, not recursed.** Compute the fixed point of
   each coupling numerically (repeat until the delta is under an epsilon, or a hard cap of ~8
   passes), then apply the converged value once. No stack growth, no per-frame cost that scales
   with depth. This belongs in `_recompute_box_effects()`, which already runs at the top of
   `_refresh_functions()` and is already the single source of truth for mute/occlusion state.
2. **A runaway coupling is a fail state with a specific message**, not a crash or a silent zero.
   "This arrangement puts itself in the dark" is a legible, teachable failure.
3. **Entry depth is separately capped** (visual/UX concern, unrelated to the maths) — a player
   stepping into the same apartment repeatedly should be capped at 2–3 pushes, since past that
   the mini-plan card row becomes unreadable.

Note that convergence and entry are decoupled: the *simulation* is a fixed point computed
without ever loading a level, and *entering* is a UX affordance with its own cap.

### 3.3 A pleasing consequence

Self-containment is the only case where interior area exactly equals exterior area. The
`MIN_NESTED_INTERIOR_M2 := 20.0` check in `_on_box_entered()` is satisfied *precisely* rather
than approximately, and the reverse-Parabox punchline the whole nesting feature was built around
("tiny on the outside, still a livable apartment inside") becomes literally, exactly true.

### 3.4 Honest assessment

Weaker as a system than looping, stronger as a set piece. The fixed-point puzzle is real but
hard to teach — the player must understand that their change feeds back into itself before any
of it reads as fair. Recommend a small number of late-game showpiece levels rather than a whole
district, plus the final shot of the Steam trailer (the camera pulls back out of the box into
the apartment it just left).

## 4. Open questions

1. **Does a looped apartment still have an exterior for `external_zone` purposes?** Noise/smell
   ordinances assume an outside. Simplest answer: a fully-looped level has no `external_zone`
   block at all, and levels that want both use partial loops (§2.3) with some boundary left
   genuinely outside.
2. **What does the 3D view show through a looping door?** Cheapest honest answer is a flat
   blueprint-blue plane, matching the game's existing abstraction, rather than attempting a
   portal render. Worth prototyping before committing — a door to nowhere may read as a bug.
3. **Can furniture be dragged *through* a seam mid-drag**, or must it be dropped whole? Dropping
   whole is far simpler and probably reads better; dragging through is the more delightful toy.
4. **Do the two features compose?** A looped apartment that also contains itself is coherent on
   paper and almost certainly a bad first target. Explicitly out of scope for v1 of either.
5. **Tenant pathing.** If tenant walk paths are ever more than cosmetic, they need the same wrap
   treatment as sightlines, and the same step budget.

## 5. Suggested build order

Looping first — it is cheaper, more teachable, and its self-collision mechanic is the more
distinctive of the two.

1. **Schema + wrapped placement.** `loop.pairs` parsing and `Wall.can_place()` wrap, including
   self-overlap. Ship a `debug:_loop_placement` level whose whole point is a sofa that is too
   long for its own loop. This is the prototype that decides whether the feature is fun.
2. **Wrapped zones.** One-line BFS neighbour change in `_recalculate_zones()`, plus a
   `debug:_loop_zones` level where an innocuous-looking layout merges bedroom and kitchen.
3. **Wrapped sightlines.** `has_sightline()` wrap + step budget; extend the existing
   `debug:_sightlines` level rather than authoring a new one.
4. **Blueprint rendering of a seam.** Needs to be legible in `BlueprintPreview.gd` too, since
   those plans are how the player reads a level before entering it.
5. **Self-containment: converged couplings.** Fixed-point iteration inside
   `_recompute_box_effects()`, with the runaway case surfacing as a specific failure message.
   No entry allowed yet — the simulation is observable from outside the box first.
6. **Self-containment: entry.** Relax the Main.gd:1062 guards to a depth cap once the maths is
   proven and the mini-plan card row handles repeated identical entries sensibly.
