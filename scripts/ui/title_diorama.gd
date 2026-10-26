extends SubViewportContainer
class_name TitleDiorama

# The title screen's little flat: a furnished corner room in the game's own
# look (palette, matte shading, ink lines), standing in the middle of the
# drawing board and swaying slowly side to side. Built from the catalogue's
# models, so it always shows the furniture as it is in the game. Draws on a
# transparent viewport over the board; takes no input.

const ROOM_W := 3.2    # metres, along X
const ROOM_D := 2.6    # along Z
const WALL_H := 2.4
const WALL_T := 0.12
const SLAB_H := 0.25
const PLINTH_H := 1.2
const SWAY_DEG := 14.0     # each way from the middle view
const SWAY_PERIOD := 16.0  # seconds for one full sway

const MODEL_DIR := "res://assets/models/furniture/styletest/"

# [model, position of its footprint centre (x, z), turn in degrees]
const PIECES := [
	["normal_bed", Vector2(0.55, 1.55), 0.0],
	["nightstand", Vector2(0.25, 0.45), 0.0],
	["wardrobe", Vector2(1.45, 0.32), 0.0],
	["desk", Vector2(2.55, 0.35), 0.0],
	["office_chair", Vector2(2.55, 0.95), 180.0],
	["desk_lamp", Vector2(2.85, 0.25), 0.0],
	["plant", Vector2(2.95, 2.3), 0.0],
	["puff", Vector2(1.7, 1.25), 0.0],
]

var _vp: SubViewport
var _level: Node3D
var _pivot: Node3D
var _cam: Camera3D
var _style: StyleController
var _t := 0.0


func _ready() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	add_child(_vp)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	_vp.add_child(sun)
	_cam = Camera3D.new()
	_cam.current = true
	_vp.add_child(_cam)
	_pivot = Node3D.new()
	_pivot.position = Vector3(ROOM_W * 0.5, 0.0, ROOM_D * 0.5)
	_vp.add_child(_pivot)
	_level = Node3D.new()
	_level.position = -_pivot.position
	_pivot.add_child(_level)
	_build_room()

	_style = StyleController.new()
	_style.world_environment = env
	_style.sun = sun
	_style.camera = _cam
	_style.level_root = _level
	_style.room_height = WALL_H
	_style.floor_thickness = SLAB_H
	_style.scene_center = Vector3(ROOM_W * 0.5, 1.0, ROOM_D * 0.5)
	_style.scene_radius = 3.0
	_style.manage_global_shadows = false
	_style.quality = GameState.graphics_quality as StyleQuality.Level
	_style.palette = PaletteLibrary.default_palette()
	_vp.add_child(_style)
	_style.style_plinth(_plinth, PLINTH_H + SLAB_H)
	# The board shows through: no backdrop behind the room.
	var backdrop := _style.get_node_or_null("StyleBackdrop") as Node3D
	if backdrop:
		backdrop.visible = false
	InkLines.attach(_cam, _vp)
	InkLines.set_palette(_cam, _style.palette)

	_frame_camera()
	var travel := Vector3(-0.8, -0.85, -0.2).normalized()
	sun.look_at_from_position(-travel * 10.0, Vector3.ZERO, Vector3.UP)


func _process(delta: float) -> void:
	if GameState.reduce_motion:
		return
	_t += delta
	_pivot.rotation.y = deg_to_rad(SWAY_DEG) * sin(_t * TAU / SWAY_PERIOD)


# Three-quarter orthographic view into the open corner, as in the game.
func _frame_camera() -> void:
	var yaw := deg_to_rad(45.0)
	var pitch := deg_to_rad(32.0)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	var center := Vector3(0.0, 0.55, 0.0)
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 9.2
	_cam.near = 0.1
	_cam.far = 60.0
	_cam.look_at_from_position(center + dir * 14.0, center, Vector3.UP)


var _plinth: MeshInstance3D

func _build_room() -> void:
	_box(Vector3(0, -SLAB_H, 0), Vector3(ROOM_W, 0, ROOM_D), StyleController.ROLE_FLOOR)
	_box(Vector3(-WALL_T, -SLAB_H, -WALL_T), Vector3(0, WALL_H, ROOM_D), StyleController.ROLE_WALL)
	# The back wall, round a window over the bed.
	var w0 := 0.15
	var w1 := 1.0
	var h0 := 0.95
	var h1 := 2.0
	_box(Vector3(0, -SLAB_H, -WALL_T), Vector3(w0, WALL_H, 0), StyleController.ROLE_WALL)
	_box(Vector3(w1, -SLAB_H, -WALL_T), Vector3(ROOM_W, WALL_H, 0), StyleController.ROLE_WALL)
	_box(Vector3(w0, -SLAB_H, -WALL_T), Vector3(w1, h0, 0), StyleController.ROLE_WALL)
	_box(Vector3(w0, h1, -WALL_T), Vector3(w1, WALL_H, 0), StyleController.ROLE_WALL)
	var glass := _box(Vector3(w0, h0, -WALL_T * 0.6), Vector3(w1, h1, -WALL_T * 0.4), StyleController.ROLE_WINDOW)
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_plinth = _box(Vector3(-WALL_T, -SLAB_H - PLINTH_H, -WALL_T), Vector3(ROOM_W, -SLAB_H, ROOM_D), &"")
	_plinth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for p in PIECES:
		_model(p[0], p[1], p[2])
	# A warm lamp by the desk.
	var bulb := OmniLight3D.new()
	bulb.position = Vector3(2.85, 0.95, 0.3)
	bulb.omni_range = 1.8
	bulb.light_energy = 0.5
	bulb.light_specular = 0.0
	bulb.add_to_group(StyleController.GROUP_PREFIX + StyleController.ROLE_GLOW)
	_level.add_child(bulb)


func _box(from: Vector3, to: Vector3, role: StringName) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = (to - from).abs()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = (from + to) * 0.5
	if role != &"":
		mi.add_to_group(StyleController.GROUP_PREFIX + role)
	_level.add_child(mi)
	return mi


# A catalogue model at its own size, its footprint centred on `at` and
# standing on the floor.
func _model(id: String, at: Vector2, yaw_deg: float) -> void:
	var path := MODEL_DIR + id + ".glb"
	if not ResourceLoader.exists(path):
		return
	var inst := (load(path) as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	holder.position = Vector3(at.x, 0.0, at.y)
	holder.rotation.y = deg_to_rad(yaw_deg)
	holder.add_child(inst)
	var box := _mesh_aabb(inst, Transform3D.IDENTITY)
	var c := box.get_center()
	inst.position = Vector3(-c.x, -box.position.y, -c.z)
	holder.add_to_group(StyleController.GROUP_PREFIX + StyleController.ROLE_FURNITURE)
	_level.add_child(holder)


func _mesh_aabb(node: Node3D, xform: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out = xform * (node as MeshInstance3D).mesh.get_aabb()
		first = false
	for child in node.get_children():
		if child is Node3D:
			var b := _mesh_aabb(child as Node3D, xform * (child as Node3D).transform)
			if b.size == Vector3.ZERO:
				continue
			out = b if first else out.merge(b)
			first = false
	return out
