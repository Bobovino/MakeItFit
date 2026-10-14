extends Node3D

# Standalone look-dev scene for the diorama style. Builds a small apartment
# (floor slab, two walls, a window, a lamp, box furniture and a few of the
# real kit models) and lets you flip between every palette in
# res://style/palettes/ to compare them. Touches nothing in the game itself.
#
#   1-9          pick a palette          Tab / Right / Left   cycle palettes
#   Q            cycle quality           H                    toggle this text
#   D            toggle depth of field (High only)
#   G            cycle ghost alpha (transparent shader variant)
#   N            toggle night
#
# Dropping a new LevelPalette .tres into the palettes folder adds it here.
#
# For unattended checks, `-- --shots=<dir>` saves one PNG per palette and
# quality tier into <dir> and quits. `--override=fog_strength=0,light_energy=0`
# forces numeric palette properties on every palette, for A/B comparisons;
# `--tonemap=0` switches to a linear tonemapper for measuring; `--dof` turns
# the High tier's depth of field on.

const MODEL_DIR   := "res://assets/models/furniture/old/"   # the test room was dressed with the earlier kit models

const ROOM_W := 4.0    # metres, along X
const ROOM_D := 3.2    # along Z
const WALL_H := 2.4
const WALL_T := 0.12
const SLAB_H := 0.35
const PLINTH_H := 1.6

@onready var _style: StyleController = $StyleController
@onready var _level: Node3D = $Level
@onready var _cam: Camera3D = $Camera
@onready var _sun: DirectionalLight3D = $Sun
@onready var _hud: Label = $HUD/Label

var _palettes: Array[LevelPalette] = []
var _index := 0
var _ghosts: Array[Node3D] = []
var _plinth: MeshInstance3D = null
var _ghost_alpha := 0.45


func _ready() -> void:
	_build_apartment()
	_frame_camera()
	_load_palettes()
	_style.room_height = WALL_H
	_style.floor_thickness = SLAB_H
	_style.scene_center = Vector3(ROOM_W * 0.5, 1.0, ROOM_D * 0.5)
	_style.scene_radius = 3.2
	if not _palettes.is_empty():
		_style.palette = _palettes[0]   # the setter applies it
	_style.style_plinth(_plinth, PLINTH_H + SLAB_H)
	# Ghosts are styled by call, not by group, so they keep the transparent variant.
	for g in _ghosts:
		_style.style_node_transparent(g, StyleController.ROLE_FURNITURE, _ghost_alpha)
	_update_hud()
	for arg in OS.get_cmdline_user_args():
		if arg == "--dof":
			_style.high_depth_of_field = true
			_style.apply()
		if arg.begins_with("--tonemap="):
			_style.tonemap = arg.trim_prefix("--tonemap=").to_int() as Environment.ToneMapper
		if arg.begins_with("--override="):
			for pair in arg.trim_prefix("--override=").split(","):
				var kv := pair.split("=")
				for p in _palettes:
					p.set(kv[0], kv[1].to_float())
			_style.apply()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_run_shots(arg.trim_prefix("--shots="))


func _unhandled_key_input(event: InputEvent) -> void:
	var ke := event as InputEventKey
	if ke == null or not ke.pressed or ke.echo:
		return
	if ke.keycode >= KEY_1 and ke.keycode <= KEY_9:
		_select(ke.keycode - KEY_1)
	elif ke.keycode == KEY_TAB or ke.keycode == KEY_RIGHT:
		_select((_index + 1) % maxi(_palettes.size(), 1))
	elif ke.keycode == KEY_LEFT:
		_select((_index - 1 + _palettes.size()) % maxi(_palettes.size(), 1))
	elif ke.keycode == KEY_Q:
		_style.quality = ((_style.quality + 1) % StyleQuality.Level.size()) as StyleQuality.Level
		_update_hud()
	elif ke.keycode == KEY_D:
		_style.high_depth_of_field = not _style.high_depth_of_field
		_style.apply()
		_update_hud()
	elif ke.keycode == KEY_G:
		_ghost_alpha = 0.2 if _ghost_alpha > 0.7 else _ghost_alpha + 0.25
		for g in _ghosts:
			_style.set_node_alpha(g, _ghost_alpha)
	elif ke.keycode == KEY_N:
		create_tween().tween_property(_style, "night", 0.0 if _style.night > 0.5 else 1.0, 0.6)
	elif ke.keycode == KEY_H:
		_hud.visible = not _hud.visible


func _select(i: int) -> void:
	if i < 0 or i >= _palettes.size():
		return
	_index = i
	_style.palette = _palettes[i]
	_update_hud()


func _load_palettes() -> void:
	_palettes = PaletteLibrary.all()
	if _palettes.is_empty():
		push_warning("No LevelPalette resources found in %s" % PaletteLibrary.PALETTE_DIR)


func _update_hud() -> void:
	var names: PackedStringArray = []
	for i in _palettes.size():
		var label := "%d %s" % [i + 1, _palettes[i].display_name]
		names.append("[%s]" % label if i == _index else label)
	_hud.text = "%s\nQuality (Q): %s  -  %s\nRenderer: %s" % [
		"   ".join(names),
		StyleQuality.LEVEL_NAMES[_style.quality],
		StyleQuality.describe(_style.quality, _style.high_depth_of_field),
		StyleQuality.rendering_method()]


# Fixed three-quarter orthographic view, looking into the open corner.
func _frame_camera() -> void:
	var center := Vector3(ROOM_W * 0.5, 0.85, ROOM_D * 0.5)
	var yaw := deg_to_rad(45.0)
	var pitch := deg_to_rad(33.0)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 6.4
	_cam.near = 0.1
	_cam.far = 60.0
	_cam.look_at_from_position(center + dir * 12.0, center, Vector3.UP)
	# Sun from the camera's right and well off the view axis. A sun behind the
	# camera lights both walls evenly but throws every shadow straight behind
	# its object, where this camera can't see it; side-on, shadows land on
	# open floor and the two walls separate into a lit one and a shaded one.
	var travel := Vector3(-0.8, -0.85, -0.2).normalized()
	_sun.look_at_from_position(center - travel * 10.0, center, Vector3.UP)


func _build_apartment() -> void:
	# Floor slab: thick, so the level reads as a floating block.
	_box("Floor", Vector3(0, -SLAB_H, 0), Vector3(ROOM_W, 0, ROOM_D), StyleController.ROLE_FLOOR)

	# West wall, and a north wall built around a window opening.
	_box("WallWest", Vector3(-WALL_T, -SLAB_H, -WALL_T), Vector3(0, WALL_H, ROOM_D), StyleController.ROLE_WALL)
	var win_x0 := 1.4
	var win_x1 := 2.8
	var win_y0 := 0.95
	var win_y1 := 2.0
	_box("WallNorthLeft",  Vector3(0, -SLAB_H, -WALL_T),      Vector3(win_x0, WALL_H, 0), StyleController.ROLE_WALL)
	_box("WallNorthRight", Vector3(win_x1, -SLAB_H, -WALL_T), Vector3(ROOM_W, WALL_H, 0), StyleController.ROLE_WALL)
	_box("WallNorthSill",  Vector3(win_x0, -SLAB_H, -WALL_T), Vector3(win_x1, win_y0, 0), StyleController.ROLE_WALL)
	_box("WallNorthHead",  Vector3(win_x0, win_y1, -WALL_T),  Vector3(win_x1, WALL_H, 0), StyleController.ROLE_WALL)
	var glass := _box("Window", Vector3(win_x0, win_y0, -WALL_T * 0.6), Vector3(win_x1, win_y1, -WALL_T * 0.4), StyleController.ROLE_WINDOW)
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Large furniture as plain boxes.
	_box("Wardrobe", Vector3(0.05, 0, 0.1), Vector3(0.65, 2.0, 1.25), StyleController.ROLE_FURNITURE)
	_box("BedFrame", Vector3(0.08, 0, 1.75), Vector3(2.1, 0.3, 3.1), StyleController.ROLE_FURNITURE)
	_box("Mattress", Vector3(0.14, 0.3, 1.81), Vector3(2.04, 0.46, 3.04), StyleController.ROLE_WALL)   # light tint, like bedding
	_box("Pillow",   Vector3(0.22, 0.46, 2.0), Vector3(0.62, 0.56, 2.85), StyleController.ROLE_PARTITION)
	_box("DeskTop",   Vector3(1.5, 0.7, 0.08),  Vector3(2.7, 0.75, 0.68), StyleController.ROLE_FURNITURE)
	_box("DeskLegL",  Vector3(1.5, 0, 0.08),    Vector3(1.56, 0.7, 0.68), StyleController.ROLE_FURNITURE)
	_box("DeskLegR",  Vector3(2.64, 0, 0.08),   Vector3(2.7, 0.7, 0.68),  StyleController.ROLE_FURNITURE)

	# Accent: only the small things the player should notice.
	_box("AccentBox", Vector3(2.25, 0.75, 0.28), Vector3(2.5, 0.89, 0.48), StyleController.ROLE_ACCENT)

	# Floor lamp: pole + glowing shade + a small warm light.
	_box("LampPole",  Vector3(3.58, 0, 0.38),    Vector3(3.62, 1.4, 0.42), StyleController.ROLE_FURNITURE)
	var shade := _box("LampShade", Vector3(3.45, 1.4, 0.25), Vector3(3.75, 1.68, 0.55), StyleController.ROLE_GLOW)
	shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bulb := OmniLight3D.new()
	bulb.name = "LampLight"
	bulb.position = Vector3(3.6, 1.35, 0.4)
	bulb.omni_range = 2.2
	bulb.light_energy = 0.7
	bulb.light_specular = 0.0
	bulb.add_to_group(StyleController.GROUP_PREFIX + StyleController.ROLE_GLOW)
	_level.add_child(bulb)

	# A few real kit models, to check the palette mapping on imported meshes
	# (no vertex colours, several materials each).
	_model("SofaBed.glb",     1.7, Vector3(3.0, 0, 2.6), 180.0, StyleController.ROLE_FURNITURE)
	_model("StackableChairs_x3.glb",      0.5, Vector3(2.0, 0, 1.05), 180.0, StyleController.ROLE_FURNITURE)
	_model("FloorLamp.glb", 0.22, Vector3(1.75, 0.75, 0.38), 0.0, StyleController.ROLE_FURNITURE)
	_model("PlantLadderShelf.glb",    0.4, Vector3(3.6, 0, 1.35), 0.0, StyleController.ROLE_ACCENT)


	# The block the level stands on, dissolving downward into the backdrop.
	_plinth = _box("Plinth", Vector3(-WALL_T, -SLAB_H - PLINTH_H, -WALL_T), Vector3(ROOM_W, -SLAB_H, ROOM_D), &"")
	_plinth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Placement ghosts: a box and a kit model on the transparent variant.
	_ghosts.append(_box("GhostBox", Vector3(0.9, 0, 1.3), Vector3(1.4, 0.5, 1.65), &""))
	var ghost_model := _model("Bookshelf.glb", 0.8, Vector3(2.95, 0, 1.75), 90.0, &"")
	if ghost_model != null:
		_ghosts.append(ghost_model)


# Box spanning two corners (metres, level space), put in the role's group
# (an empty role leaves it ungrouped, for the caller to style).
func _box(node_name: String, from: Vector3, to: Vector3, role: StringName) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = (to - from).abs()
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.position = (from + to) * 0.5
	if role != &"":
		mi.add_to_group(StyleController.GROUP_PREFIX + role)
	_level.add_child(mi)
	return mi


# Kit model scaled uniformly so its footprint's long side is `width` metres,
# standing on `pos`. Sized from its first mesh, as Room3DView does, because
# the kit's accessory sub-meshes carry odd baked transforms.
func _model(file: String, width: float, pos: Vector3, yaw_deg: float, role: StringName) -> Node3D:
	var path := MODEL_DIR + file
	if not ResourceLoader.exists(path):
		push_warning("Style test: missing model %s" % path)
		return null
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	holder.name = file.get_basename()
	holder.position = pos
	holder.rotation.y = deg_to_rad(yaw_deg)
	holder.add_child(inst)
	var aabb := _first_mesh_aabb(inst, Transform3D.IDENTITY)
	var longest := maxf(aabb.size.x, aabb.size.z)
	if longest > 0.0001:
		var s := width / longest
		inst.scale = Vector3.ONE * s
		var c := aabb.get_center()
		inst.position = Vector3(-c.x * s, -aabb.position.y * s, -c.z * s)
	if role != &"":
		holder.add_to_group(StyleController.GROUP_PREFIX + role)
	_level.add_child(holder)
	return holder


func _first_mesh_aabb(node: Node3D, xform: Transform3D) -> AABB:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return xform * (node as MeshInstance3D).mesh.get_aabb()
	for child in node.get_children():
		if child is Node3D:
			var found := _first_mesh_aabb(child as Node3D, xform * (child as Node3D).transform)
			if found.size != Vector3.ZERO:
				return found
	return AABB()


func _run_shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for q in StyleQuality.Level.size():
		_style.quality = q as StyleQuality.Level
		for i in _palettes.size():
			_select(i)
			for _f in 4:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var file := "%s/%s_%s.png" % [dir, _palettes[i].resource_path.get_file().get_basename(), StyleQuality.LEVEL_NAMES[q].to_lower()]
			get_viewport().get_texture().get_image().save_png(file)
			print("[StyleTest] saved ", file)
	get_tree().quit()
