# Levels — Design Doc

Status: **working list.** A filtered and regrouped version of the raw level brainstorm, organised
by the *system each level exercises* rather than by the order they were thought of, so that the
authoring cost of any given idea is visible at a glance.

This does not replace the raw brainstorm — half-formed ideas are worth keeping in their original
mess. What follows is only the subset that has survived a single test.

## 1. The test

**An idea is a level only if it implies a rule.** "A vampire lives here" is a skin; "this tenant
requires zero daylight" is a level, because it inverts a system that already exists. Most entries
in the raw list are skins, and a skin becomes a level the moment someone writes down the rule it
implies.

Applied honestly, a list of ~130 ideas yields roughly 25 distinct mechanics.

## 2. The theme, used as a filter

Sorting the list surfaced a pattern that was not deliberate: an unusually large share of the best
ideas are about **people whose housing forces them to become invisible** — see
`design_lore.md` §5.1. Hikikomori; hiding things from each other; the couple who officially do not
live together; parents controlling who comes and goes; the sleepwalker; the foster room; the
separated couple who cannot afford to move apart.

That is a sharper spine than "housing is expensive", and it is a useful filter on new ideas: a
level that touches it will probably be better than one that does not.

## 3. Levels that reuse systems already built

These need authoring, not engineering. They are the cheap ones and should carry most of the game.

| Level | Rule | System |
|---|---|---|
| The couple who cannot be big at once | one is full-size per Moment, and they swap | Moments |
| Partners on opposite shifts | the same space serves two inverted schedules | Moments |
| The cheap-electricity hour | the washer/dishwasher must run in a specific Moment | Moments |
| Hiding things from each other | tenant A must not see tenant B's belongings | sightlines (`must_be_clear: false`) |
| Overprotective parents | the entrance must stay in view from the living space | sightlines |
| The reading spot | a seat with a clear line to a window | sightlines |
| Hikikomori | every function must fall inside one zone — separation is impossible | zones |
| The Genkan house | a mandatory clear transition zone at the entrance | zones |
| The tenant who moves nothing | every piece is red-tier; each placement is final | mobility tiers |
| Furniture that cannot leave | four fictions, one rule — it does not fit through the door / whim / nostalgia / law | mobility tiers |
| Diógenes / the collector | nothing may be removed, and more keeps arriving | mobility tiers |
| The floor is lava | nothing may rest on the floor | stacking, surfaces, wall mounts |
| Shaq | every piece must be oversized | footprint |
| The grandmother | clearance widths on every path | `ghost_radius` |
| Caring for someone with dementia | clearance, plus hazards kept out of reach | `ghost_radius`, zones |
| The vampire | requires zero daylight — the existing requirement inverted | daylight occlusion |
| The evil genius | can cover the sun; the tenant weaponises occlusion | daylight occlusion |
| The musician | loud enough to break the neighbours' sleep | `is_noisy` / `needs_quiet` |
| Border dispute | the boundary itself is contested | external zone |
| The camper van | a box on a rail, one Moment per parked position | nesting + rails (see `design_recursive_apartments.md` §7.2) |

**Furniture that cannot leave** deserves a note: the collector, Diógenes, the widow's piano, the
inherited wardrobe and the legally-protected fitting are all *one mechanic with four fictions*.
That is good design rather than repetition — same rule, different reason to care — but they should
be authored as one family and spread across the game, not clustered.

## 4. Levels that need one new system each

Worth building only if the level justifies the system. Ordered by how much the system would be
reused elsewhere.

| Level | New system | Reuse potential |
|---|---|---|
| The sleepwalker | a route trace across the grid | high — pathing serves accessibility levels too |
| The foster room | re-solve for a sequence of tenants without rebuying | high — a whole level structure |
| The fae / the radical vegan | material axis (refuses metal / refuses wood) | medium — a new tag on the catalogue |
| Tesla | placement restricted to multiples of 3 | low — one gag, cheap to implement |
| Sócrates | no furniture of his own; maximum seating for visitors | low — inverts the budget goal |
| Clock hands over the plan | a real-time sweep invalidating regions | low, and risky in a puzzle game |

**The foster room** is the strongest level in the entire brainstorm and the one to protect: a
different child every few months, the same room, nothing rebuyable. It is structurally original
rather than merely thematic, and it is the one most likely to be remembered. It should be an
end-of-arc unlock.

**Clock hands** is the one I would cut unless prototyped early. A real-time constraint fights the
core loop, which is deliberative; the visual appeal on a blueprint is real but may not survive
contact with the puzzle.

## 5. Fourth-wall set pieces

Expensive per unit of payoff — each one is bespoke systems, art and text — and their effect
depends on rarity. **Two or three in the whole game.** Two are designed:

### 5.1 The Housing Office

The player designs the Office they work for.

The design turns on one decision: **the player is compliant, not cruel.** If the brief is "build a
maze to torment citizens", the player is the villain and it is a one-note joke. Instead the Office
has ordinary requirements — a waiting area of N seats, a given number of counters, an accessible
entrance, public separated from staff, an archive that must not face the street — and satisfying
all of them **produces the maze on its own**. Nobody chose cruelty; it fell out of the regulations.

Mechanically this is free: the Office's requirements are `functions`, `zone_separations` and
sightlines exactly like any tenant's, and the maze is emergent from the zone connectivity system
that already exists.

**The player's own desk is the best part.** After a whole game arranging space for other people,
here the player is a tenant in their own level, competing for the same floor. Put the desk by the
window and the waiting area loses it. No special mechanic — just one more piece of furniture with
needs — and the player characterises themselves by where they put it.

### 5.2 The game show and the trapdoor

A villain and a quiz-show host share an apartment, and share a trapdoor: the villain needs it for
disposal, the host needs it for the show. Same object, two Moments, two incompatible functions —
a straightforward shared-object puzzle in the existing Moments system.

The show itself needs one correction. **A trivia minigame is a different game**: it uses none of
the spatial systems, costs a full localisation pass per question, is memorised on the second run,
and tests knowledge unrelated to the one skill the game teaches.

Instead, **the questions are about this game's own rules**:

> "How many square metres does a dwelling need to be habitable?"
> "Can a wardrobe rest on a nightstand?"
> "What happens to a box when its interior weight passes 150?"

No outside knowledge, cheap to localise, funny precisely because it is a quiz show about housing
regulation — and it doubles as a **covert check that the player has understood the systems**,
which is a tutorial function disguised as a set piece.

**Falling through the trapdoor drops the player into the nested level below.** Not a fail screen —
the player is reduced and has to solve their way back up. This turns the gag into a use of the
nesting mechanic as a punishment, and it answers the open question in `design_lore.md` §7.2
(*does the player ever get reduced?*) in the best possible place: fail a question about
habitability regulations and the regulations are applied to you.

`FloorHatchStorage.glb` is already imported.

## 6. Tenant archetypes — the cull

The raw list carries a large supernatural roster: vampire, golem, changeling, elemental, ghost,
shapeshifter, magician, Ent, the collector, time-displaced, and more.

**Keep the ones that imply a rule** — vampire (zero daylight), fae (refuses metal), Tesla
(multiples of three), Sócrates (all seating, no possessions), Shaq (oversized), the collector
(nothing leaves). Each of these is a level.

**Cut or park the rest.** Golem, elemental, shapeshifter, ghost and the assorted celebrity names
are currently names without rules, and if every tenant is supernatural the housing satire stops
landing — it becomes a fantasy game with an apartment theme. Three or four fantastical tenants
across the whole game is plenty; the rest of the roster should be recognisably ordinary people in
impossible situations, which is where the game's actual power is.

Any parked name can be revived the moment somebody writes down the rule it implies.

## 7. Not levels — move these elsewhere

Good ideas competing for a different budget:

- **The Poor Things camera and iris-close transition** — presentation and transitions.
- **Optimisation leaderboard, resource conversion** — replayability layer, and a real Steam
  consideration.
- **The community map** — meta structure.
- **Deduction by elimination** (infer the tenant's needs rather than being told) — an alternate
  game mode, and an interesting one.
- **Next level changes based on how the last was solved** — campaign structure, and the most
  ambitious idea in the raw list.

## 8. What is missing

**The neighbours and the building.** Only one idea (border dispute) touches the building as a
social unit, which is a strange gap for a game about housing — especially given that bidirectional
noise and external zones are already built and would carry it.

**Money as something felt.** Nearly every idea is a peculiar tenant; very few are about being
broke, which is the premise. The box economy (`design_recursive_apartments.md` §5) is currently
the only mechanic that puts precarity in the player's hands.
