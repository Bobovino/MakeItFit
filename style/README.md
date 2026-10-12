# Diorama style (`res://style/`)

A data-driven low-poly look for the 3D view: one milky hue per level, matte
flat-shaded surfaces with a soft vertical gradient, one tinted sun with soft
tinted shadows, a gradient backdrop, and a pale fog toward the far edge.

The game's 3D view (`Room3DView`) uses it. To look at it in isolation, open
one of the scenes in `test/` and press F6.

| File | What it is |
| --- | --- |
| `level_palette.gd` | `LevelPalette` resource: every colour and strength for one level. |
| `style_controller.gd` | `StyleController` node: applies a palette and a quality tier. |
| `style_quality.gd` | `StyleQuality`: Low / Medium / High and renderer checks. |
| `shaders/matte_gradient.gdshader` | The shared opaque surface shader. |
| `shaders/matte_gradient_alpha.gdshader` | Transparent variant, for ghosts and fading walls. |
| `shaders/matte_gradient.gdshaderinc` | The body both variants include. Edit the look here. |
| `shaders/matte_gradient_double.gdshader` | Double-sided variant, used for walls. |
| `palette_library.gd` | `PaletteLibrary`: finds palettes by name and picks one per level. |
| `shaders/backdrop.gdshader` | Full-screen gradient behind the level. |
| `shaders/vignette.gdshader` | Hue-tinted vignette (Medium and up). |
| `palettes/*.tres` | Teal, Slate, Terracotta, Ochre, Sage, Plum, Dusty Rose. |
| `test/style_test.tscn` | Test apartment. `1`-`9` or `Tab` switch palette, `Q` cycles quality, `D` toggles depth of field, `G` cycles ghost alpha, `H` hides the text. |

| `test/room3d_probe.tscn` | The real `Room3DView` on a throwaway room. `1`-`9` palette, `N` day/night. |

## In the game

`Room3DView` creates its own `StyleController` and styles floor, walls,
columns, balcony pieces, furniture models and the below-floor ghost layer.
Camera, picking, dragging and placement are untouched.

- **Which palette a level gets:** add `"palette": "ochre"` (the `.tres` file
  name) to the level in `levels.json` to choose one. Without it, the level
  takes the palette closest in hue to its block colour. The level editor's
  preview and the shop's item preview use `teal`.
- **Floating block:** a plinth under the floor dissolves downward into the
  backdrop (`style.style_plinth(node, depth)`). A loft shows the floor
  beneath it there instead.
- **Inside a nested box:** the apartment the box sits in is drawn giant
  around the room, as scenery (no shadows, not clickable, hidden on the
  camera's side), and the room stands on its floor instead of the plinth.
  One level up only. On for every level; a level opts out with
  `"show_parent": false` in its data.
- **Each apartment has its own camera:** angle, zoom and pan are remembered
  per level, and a first visit starts on the home view.
- **View controls:** Q/E turn the view a quarter at a time, W/A/S/D move
  it, middle-drag still orbits freely. A "Walls" button (Home/End) switches
  between Up, Cutaway and Down. In Cutaway, an interior wall drops only
  when it stands between the camera and the spot the camera is centred on.
- **Long lens:** the styled view uses a 26 degree field of view with the
  camera moved back to match, and frames the room a little tighter. Orbit,
  zoom and pan work as before.
- **Windows, doors, skirting:** built from each wall segment's own
  `has_window` / `has_door` data, on both faces of the wall, plus a skirting
  board on every wall. They are dressing only: the wall is not cut, and they
  hide while a wall is lowered to a stub. Window glass glows by day and goes
  dim at night.
- **Cut walls:** the top of every wall is a flat light face, so a wall
  lowered for the camera reads as a clean slice. On a lowered wall, a
  window shows as a plan-style symbol on that cut face (glass colour with a
  dark centre line and end ticks) and a door as a dark band between two
  accent ticks.
- **Floorboards:** subtle tone bands on the floor, 2 tiles wide, set per
  palette with `floor_pattern` (0 turns them off).
- **Accent colour** goes to small decor: pieces with no function and a
  footprint of at most 4x4 tiles (plants, lamps, books). Change the rule in
  `Room3DView._item_role()`.
- **Night moments** set `StyleController.night` to 1: the same palette with a
  dim cool sun, dark ambient and dark backdrop. Lamps keep glowing.
- **Placement ghost:** a piece being bought is see-through until placed.
- **Quality** comes from Settings > Graphics (`GameState.graphics_quality`)
  and applies live.
- **Left as they were, on purpose:** stairs (their colour says where they
  lead), rail markers, and grid and hitbox outlines.
- **Off switch:** `USE_DIORAMA_STYLE` at the top of `scripts/Room3DView.gd`.

## Apply a palette to a level

1. Add a `Node` with `style_controller.gd` in the same 3D world as the level
   (inside the same `SubViewport` if the level has its own).
2. In the inspector, assign **World Environment**, **Sun**, **Camera** and
   **Level Root**, and set **Palette** to one of the `.tres` files.
3. Tell it what each mesh is. Either put nodes in a group, which covers the
   node and everything under it:

   | Group | Used for |
   | --- | --- |
   | `style_floor` | Floor, the lightest large surface |
   | `style_wall` | Walls, ceiling, light-coloured parts (drawn double-sided) |
| `style_partition` | Interior walls: a lighter tint, so they read apart from the perimeter |
   | `style_furniture` | Large furniture, darker tint of the hue |
   | `style_accent` | Small, important objects only |
   | `style_glow` | Lamps (emissive; lights in this group take the glow colour) |
| `style_window` | Window glass: glows by day, dim at night |
| `style_trim` | Skirting, door leaves: a tint between wall and furniture |

   or, for geometry built in code:

   ```gdscript
   style.style_node(mesh_instance, StyleController.ROLE_WALL)
   ```

4. Set **Level shape** (`scene_center`, `scene_radius`, `room_height`) so the
   fog fade and the shadow range fit the level.

If the camera moves or zooms, call `style.refresh_view()` so the fog fade and
shadow range follow it. For night, set or tween `style.night` from 0 to 1.

Swap palettes at runtime with `style.palette = load("res://style/palettes/ochre.tres")`.
Call `style.apply()` after adding or rebuilding geometry.

Imported models keep their own light/dark material relationships: each
surface's original colour is remapped onto the palette (`material_contrast`,
`keep_source_color`). Surfaces whose source material is named `lamp` are
treated as glow surfaces; change that list in **Glow Material Names**.

## Ghosts and fading walls

Semi-transparent pieces use the transparent variant, styled by call rather
than by group (a grouped node is restyled opaque on every `apply()`):

```gdscript
style.style_node_transparent(ghost, StyleController.ROLE_FURNITURE, 0.45)
style.set_node_alpha(ghost, 1.0)   # later: fade, or make it solid
```

These materials belong to that node alone, follow palette changes, and are
released when the node is freed. Once a ghost is placed for good, call
`style_node()` on it to move it back to the cheaper opaque shader.

## Add a new palette

Duplicate a file in `res://style/palettes/`, rename it, edit the colours in
the inspector. That is the whole job: the test scene lists every palette in
that folder automatically.

Guidelines that keep it airy rather than sugary: keep saturation low and
values high on floor/wall/background, put the saturation in `furniture_color`
and `accent_color` only, make `shadow_tint` a dark version of the hue (never
grey), and pick an accent from the opposite side of the colour wheel.

## Change quality

The default is **Low**.

```gdscript
style.quality = StyleQuality.Level.LOW      # base look only (default)
style.quality = StyleQuality.Level.MEDIUM   # + glow on windows/lamps, vignette
style.quality = StyleQuality.Level.HIGH     # + SSAO, and DOF if high_depth_of_field is on
```

`auto_quality = true` picks Low on mobile/web and Medium elsewhere. Effects
the running renderer cannot do are skipped silently, and
`StyleQuality.describe(level)` says what is really active.

| Effect | Forward+ | Mobile | Compatibility |
| --- | --- | --- | --- |
| Base look, fog, shadows, tonemap | yes | yes | yes |
| Glow, vignette (Medium) | yes | yes | yes |
| SSAO (High) | yes | no | off (the engine supports it, but it stipples walls with this look) |
| Depth of field (High, opt-in) | yes | yes | no |

Depth of field runs without errors on Forward+ and Mobile, but with an
orthographic camera and a level only a few metres deep it softens the back
corner by about a pixel. It is not worth its cost here; leave it off.

The shadow atlas is 1024 on Low and 2048 otherwise. Those are engine-wide
settings; turn off **Manage Global Shadows** if something else owns them.

## Vertex colours

None of the current models have vertex colours, so the shader falls back to
the palette tint plus a world-height gradient (darker near the floor). A mesh
that does have vertex colours gets them multiplied in automatically, which
lets you bake a per-object gradient or darken crevices by hand.

To paint them in Blender:

1. Select the mesh, open **Object Data Properties > Color Attributes**, add
   one with domain **Face Corner** and type **Byte Color**.
2. Switch to **Vertex Paint** mode. Paint in greys: white leaves the palette
   colour untouched, darker greys shade it. For a quick gradient, in Edit
   Mode select the bottom faces and use **Paint > Set Vertex Colors** with a
   mid grey, then blur.
3. Export glTF with **Mesh > Attributes > Vertex Colors** enabled (in
   Blender 4.2+ set *Use Vertex Color* to **Active**).
4. Reimport in Godot. No material changes needed.

Paint shading only, not hue, so the model still follows every palette.

## Renderer notes

- The project runs on **Compatibility**. That renderer draws a shadowed light
  in a second pass that is blended after tonemapping, so the same light
  energy lands brighter than on Forward+/Mobile. The shader compensates with
  a per-renderer constant (`LAMBERT` in `matte_gradient.gdshader`); the three
  renderers look close but not identical. Judge final colours on the
  renderer you ship.
- Without glow (Low), Compatibility clamps to LDR, so windows and lamps read
  as plain light surfaces rather than bright ones.
- Shadows cannot be given a colour directly in Godot 4. The tint comes from
  the shader filling unlit areas with `shadow_tint`, plus the tinted ambient.
- A sun placed behind the camera hides every shadow behind its object. Keep
  it well to one side.
- The gradient is in world height, shared by the whole level, not per object.
- Transparent pieces use a depth prepass, so a ghost never shows its own
  back faces, but two overlapping ghosts will not blend through each other.
