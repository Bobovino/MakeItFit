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

## 5. Recursion as economy — boxes that pay

Everything above treats nesting as a *constraint*. Today that is all it is: a box costs floor
space, steals light, adds noise, and gets heavier until it can't be moved. It never gives the
player anything. That asymmetry is why nesting currently reads as a side objective rather than
part of the main loop.

The fix is to let the player **place a box to solve a budget problem**. A box with a tenant in
it is income rather than expense — but the tenant inside has needs of their own, so buying your
way out of a shortfall means taking on another puzzle.

### 5.1 Rent, not a loan

The obvious version — a lump sum now, "you owe a puzzle later" — is a debt: paid once, then
inert. Better is a **standing income conditional on the inner tenant staying satisfied**.

That framing is worth the difference because it makes the existing coupling mechanics load-
bearing. Block the box's window while arranging the outer tenant's sofa and the interior loses
daylight — and the rent stops. Put the TV near the box and the bed inside stops counting for
noise. Fill the box and it goes red-tier and can never be repositioned again.

So the bet isn't "solve one more puzzle." It's **keep two puzzles compatible at once**, using
systems that already exist and already talk to each other. Difficulty scales without authoring:
each additional box competes with the previous ones for light, quiet and floor.

### 5.2 Three ways this breaks

**No eviction valve → unwinnable saves.** If a box can't be removed, a player who over-extends
has no move except restarting the level. There must be a way to pull one out at a penalty
(partial refund, reputation, whatever the meta ends up being). This is the single most important
safety mechanism in the whole idea.

**Fatigue.** Interiors must get *smaller and simpler* with depth, never harder. If each box is a
full-weight level, one level becomes five and players quit mid-chain. Budget the total puzzle
mass of a chain, not of each link.

**The degenerate fill.** If a box is reliably net-positive, the optimal play is to carpet the
floor in boxes. The brakes already exist — boxes occupy parent floor and degrade each other via
light/noise/weight — but the curve needs tuning so that the third or fourth box stops paying for
itself.

### 5.3 The missing implementation piece

`child_level_id` is a **per-placement** field in each level's `starting_furniture`, not a catalog
field on `shoebox_apartment` (confirmed in `levels.json`: `debug:_nested_child` sets it, the
catalog entry does not). Boxes are therefore authored today, with their interiors chosen by hand.

For a shop-bought box, the interior has to come from somewhere. Recommended: a **pool of small
pre-authored interiors** tagged by rent yield and difficulty, drawn from on purchase. Not
procedural generation — fifteen to twenty hand-made small interiors is plenty, and hand-made is
the only way the inner puzzles stay worth solving.

### 5.4 The arc this produces

The player starts trying to house one person in 35 m² and ends up the landlord of a block of
drawers in someone's living room. That arc needs no scripting — it emerges from a series of
individually reasonable financial decisions, which makes it land far harder than a written
narrative would.

It is also the thesis of the whole game stated as a mechanic: the answer to not having enough
room is always to put someone smaller inside.

## 6. Further couplings worth prototyping

**Level-type variety.** Nesting and recursion are different level *kinds*, not a single ladder.
Some levels are ordinary nested apartments (a box containing a different apartment), some are
looping, some are self-contained, each with its own depth cap. Mixing them across a district
keeps the mechanic from becoming routine, and the economy in §5 applies to all three.

**Apartments on rails.** `rail_axis` already gives per-Moment sliding positions to furniture. A
*box* on a rail means the nested apartment itself slides between Moments — the interior's
daylight, noise and external-zone profile all change depending on where the parent's rail has
parked it. Nearly free: the box is already Furniture, and `moment_positions` already handles the
per-Moment storage. The interesting authoring case is a rail that moves the box past a window,
so the interior gets sun in one Moment and none in the other.

**Cross-scale furniture transfer.** Let the player move a piece from the parent apartment down
into a child that has run out of budget — a hand-me-down instead of a purchase. The rule that
makes it a mechanic rather than a cheat: **weight is conserved across the transfer.**

At roughly 8× linear scale per depth, volume — and therefore weight — scales by about 512×. A
sofa at `weight: 10` in the parent arrives in the child weighing on the order of 5,000, against
existing thresholds of `BOX_WEIGHT_RED_MIN = 150` and surface capacities of 8–25. The numbers
already work out without tuning:

- it is instantly and permanently red-tier — it will never be moved again once placed
- it can never be stacked on anything, and nothing meaningful can be stacked on it
- it will overload a mezzanine outright

So a bail-out from upstairs is real help that arrives as a permanent obstruction. The exact
multiplier matters less than its size — any large factor produces the same qualitative result,
because the existing thresholds are so low.

This is also the mother-and-daughter metaphor expressed as a rule: what you hand down is
furniture the next one can never get rid of.

## 7. Suggested build order

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

**The economy (§5) is not gated behind any of this.** It needs only ordinary nesting, which
already ships — a purchasable box, a pool of interiors, conditional rent and an eviction valve.
It is the highest-value item in this document and the cheapest to reach, so it should probably
be built *before* step 1 rather than after step 6. Recursion then arrives into a loop that
already has a reason to care about boxes.

Of §6's three, **rails are nearly free** (the box is already Furniture with `moment_positions`)
and worth doing alongside the economy. **Cross-scale transfer** should wait until the economy
exists, since its whole point is bailing out a child that has run out of money.
