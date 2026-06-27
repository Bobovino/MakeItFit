# Make it Fit — Feature Reference

## Overview

You are a Berlin landlord. Furnish apartments to satisfy tenants, earn company funds, buy more properties, and retire when your portfolio reaches **10 000 € / month** in rent.

---

## City Map

- **35 levels** spread across 10 Berlin districts (Wedding, Kreuzberg, Prenzlauer Berg, Neukölln, Schöneberg, Mitte, Friedrichshain, Charlottenburg, Pankow, Tempelhof)
- Levels are arranged in a **7-row scrollable grid** (5 per row). Mouse-wheel to scroll.
- Each card shows the apartment name, district, acquisition cost (or READY if owned), and minimum star requirement to unlock.
- Clicking a card opens the **info panel**: tenant name, bio, budget, monthly rent, and reward.
- Pressing **ENTER** loads the level.
- Two map filter buttons in the top bar:
  - **Progress** — shows completion status and star count per level
  - **Stars** — shows replay value / best score

---

## Core Gameplay Loop

1. Enter a level from the City Map.
2. (Optionally) demolish internal walls during the **Demolition Phase**.
3. Buy furniture from the shop panel and arrange it in the apartment.
4. Satisfy all tenant requirements (needs + moments).
5. Press **RENT OUT** to complete the level.
6. Earn **CompanyFunds** and **monthly rent** added to portfolio.
7. Use funds on the City Map to buy new properties (acquisition cost).
8. Retire when portfolio rent ≥ 10 000 €/month.

---

## Apartment Editor

### Floor Plan View
- Top-down 2D grid. Tile size: 8 px per grid unit.
- The floor plan auto-scales to fill ~95% of the available area (left two-thirds of the screen).
- Multi-floor apartments have a **Minimap** in the bottom-left; click a floor label to switch. Upper floors unlock when specific furniture is placed (e.g. a Loft Bed unlocks the floor above).

### Wall Inspector (right panel)
- Click any highlighted wall edge (north / south / east / west) to open the elevation view for that wall.
- Shows furniture already placed against that wall and lets you buy/place wall items.
- Windows and radiators on a wall **block shelf placement** in their column.
- Close with ✕ to return to full floor plan mode.

### Furniture Placement
- **Floor items** are dragged from the shop list and dropped onto the grid.
- **Wall items** are bought and placed directly inside the Wall Inspector elevation view.
- Placement is blocked if:
  - Tiles are out of bounds.
  - Tiles are occupied by another piece.
  - Tiles overlap a partition wall or structural column.
  - Tiles fall inside another furniture's **ghost interaction zone** (clearance arc).
  - The piece is `tall` height and the tile is under a low sloped ceiling.
- A furniture piece must have **at least one free adjacent tile** to be considered accessible. Inaccessible pieces block the RENT OUT button.
- Sell any piece by clicking on it (sell button appears).
- Budget is deducted on buy and refunded on sell. Buy buttons **grey out** when unaffordable.

---

## Furniture Catalogue

### Floor Items
| Name | Functions | Notes |
|---|---|---|
| Bed | sleep | Standard double |
| Loft Bed | sleep | Tall — blocked by low ceilings; unlocks upper floors |
| Sofa | sit | Has a ghost clearance zone in front |
| Sofa Bed | sit + sleep (or per-moment: sit when folded, sleep when extended) | Foldable — extends downward to become a bed |
| Desk | work | Has a ghost clearance zone |
| Kitchen Unit | cook | Needs water + power connection |
| Wardrobe | storage | Tall — blocked by low ceilings |
| Ottoman | sit + storage | Compact, no clearance zone |

### Wall Items
| Name | Functions | Notes |
|---|---|---|
| Shelf | storage | Blocked by windows and radiators |
| Cabinet | storage + cook | Larger, blocked by obstacles |
| Murphy Bed | sleep | Folds out of wall, occupies floor depth when extended |
| TV | — (décor) | |
| Mirror | — (décor) | |
| Painting | — (décor) | |

---

## Tenant Requirements

Each tenant has a list of **required functions** (e.g. sleep, work, cook, sit, storage). The RENT OUT button activates only when every requirement is met by placed furniture.

### Moments
Some levels define multiple **moments** — named contexts the apartment must serve simultaneously (e.g. Day, Night, Soirée, Social). Each moment has its own list of needs.

- All moments must be fully satisfied to complete the level.
- Static furniture satisfies its functions in every moment.
- **Foldable furniture** is evaluated in its optimal state per moment: a Sofa Bed counts as `sit` for Day and `sleep` for Night — from the same placed piece.
- The TenantCard shows a grouped checklist with live ✓/✗ marks per moment.

Levels with moments: **29 – Smart Flat** (Day / Night), **34 – The Masterpiece** (Daytime / Soirée / Night), **35 – Stadtpalast** (Morning / Social / Night).

---

## Special Mechanics

### Demolition Phase
Levels that contain removable partition walls enter a **Demolition Phase** before furnishing begins. 
- Dashed partitions can be demolished for a cost deducted from your budget.
- Hatched (load-bearing) walls cannot be removed.
- Structural columns are always permanent obstacles.
- Click **Start Furnishing →** to end the phase and open the shop.

### Sloped Ceilings
Some apartments have a sloped ceiling defined along an axis (e.g. mansard roofs).
- A gradient overlay shows the ceiling height across the floor.
- `tall` furniture (Loft Bed, Wardrobe) is blocked in tiles where ceiling height < 2.0 m.
- Standard and `low` furniture can be placed anywhere.

### Ghost Interaction Zones
When dragging furniture with a clearance requirement (Sofa, Desk, Sofa Bed), a **dotted arc** appears around it showing its interaction zone. No other furniture may overlap this zone — it represents the space needed to actually use the piece.

### Foldable Furniture / Test Layout
The Sofa Bed (and Murphy Bed) can toggle between folded and extended states.
- In the normal furnishing view they appear folded (compact footprint).
- Enable **Test Layout** (top bar button, visible when foldable furniture is present) to simulate the extended state and check for spatial conflicts.

### Wall Occlusion
In the Wall Inspector elevation view, floor furniture placed close to a wall creates a **silhouette block** — wall items cannot be placed in the tiles behind the furniture's footprint.

### Subfloor Layer
Toggle **Subfloor** in the top bar to reveal the technical layer beneath the floor:
- **Water connection points** (blue dots) and **power connection points** (yellow dots) are shown.
- Pipe routes drawn by the player connect appliances (Kitchen Unit) to their required sources.

### Ceiling Layer
Toggle **Ceiling** in the top bar to reveal the overhead layer:
- **Lighting cones** show illuminated areas.
- **HVAC duct endpoints** are shown for ventilation planning.

### Diagonal Tile Splitting
When a floor item and a wall item overlap the same visual tile in the elevation view, the tile is rendered as two triangles — one colour per item — to show the true 3D stacking without hiding either piece.

---

## Scoring

- Completion awards **1–3 stars** based on how much of the starting budget remains:
  - ≥ 40% remaining → ★★★
  - ≥ 15% remaining → ★★
  - < 15% remaining → ★
- Stars unlock subsequent levels (each level has a `min_stars` gate).
- A first-time completion adds **monthly rent** to the portfolio permanently.
- Repeated completions can improve your star rating but don't add rent again.

---

## Level Editor

An integrated level editor lets you create custom apartments and test them immediately.

- Launch via **Level Editor** on the main menu.
- **Tools**: Window, Door, Partition (click-drag), Column, Erase.
- **Grid size**: adjust width/height in tiles (1 tile = 10 cm) and press **Apply Size**.
- Right panel: level name, district, tenant info, economics, required functions.
- **Save Level** → `user://custom_levels/` as JSON. **Load Level** → popup list of saved levels.
- **Test Level** → loads your apartment directly into the furnishing editor.
- Levels saved by players use the same JSON format as built-in levels.

---

## TODO

### Paintable Furniture Tiles
Instead of placing rigid prefab furniture pieces, certain levels unlock a **tile-painting mode**: the player selects a furniture type (e.g. Bed) and paints individual grid cells to define its shape.

**Why it works:**
Real micro-apartments rely on custom-cut or built-in furniture. Letting the player sketch an L-shaped sofa around a pillar, or a long narrow kitchen counter, is both more realistic and more satisfying than trying to wedge fixed rectangles into awkward spaces. The challenge shifts from *"how do I fit this cube here"* to *"I need 20 kitchen tiles — how do I distribute them without blocking the window?"*

**Validation rules (per furniture type):**
- All painted cells must be **contiguous** (no disconnected islands).
- Each type enforces a **minimum bounding area** and **aspect-ratio limits** (e.g. a Bed must cover at least 8×5 tiles and the longer side may not exceed 3× the shorter side — ruling out the "canvas hallway" case).
- Some types require a specific **minimum dimension** on at least one axis (e.g. a Kitchen counter must be at least 2 tiles deep).
- Painted cells follow the same **placement rules** as normal furniture (partition walls, columns, ghost zones, ceiling height).

**Visual rendering:**
- Use **autotiling** (or a border-generation pass after each paint stroke) so cells look like a continuous flat-plan shape rather than a grid of identical stamps.
- Interior cells: full-fill hatch. Perimeter cells: thick border on exposed edges, thin shared edge between adjacent cells of the same piece.
- The type label (e.g. "BED") is drawn centred on the bounding box once the shape is valid.

**Level integration:**
- Levels opt in to this mechanic via `"paintable_furniture": ["bed", "kitchen"]` in the level JSON.
- Painted pieces use the same function system as normal furniture (a painted bed satisfies `sleep`, a painted kitchen satisfies `cook`).
- Budget cost is proportional to tile count (cost-per-tile set per furniture type in `furniture.json`).

### Raycasting / Line of Sight (#6)
Furniture placement could require or benefit from unobstructed sight lines (e.g. a TV must be visible from the sofa). Planned implementation: ray cast from a source tile to a target tile across the 2D grid, blocked by tall furniture and partition walls.

### Acoustics (#7)
Rooms should have an acoustic quality score based on wall materials and partition layout. Tenants sensitive to noise (e.g. home-office workers) would require a minimum acoustic rating. Planned: per-partition sound-absorption coefficient, BFS propagation from noise source tiles.

### Odors (#8)
Cooking and bathroom sources emit odour that diffuses across the floor plan. Tenants with low tolerance require physical separation (partition walls or distance). Planned: BFS diffusion with decay, blocked by closed partitions.

### 3D Result View — "Wow Moment"
After completing a level, show the furnished apartment rendered in 3D so the player can see how it actually looks. Planned as a separate `ResultScene3D.tscn` that reads the current floor grid and instantiates 3D mesh equivalents of each furniture piece. No refactor of the 2D gameplay grid is required — the 3D scene is display-only.

---

## Developer Tools (debug builds only)

| Shortcut | Screen | Effect |
|---|---|---|
| **Ctrl + D** | City Map | Unlock all 35 levels, set ★200, add 999 999 € company funds |

Debug builds are active when running from the Godot editor. Exported builds do not expose these shortcuts.
