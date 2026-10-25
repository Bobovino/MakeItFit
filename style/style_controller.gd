class_name StyleController
extends Node

# Applies a LevelPalette to a level: the WorldEnvironment (ambient, fog,
# tonemap, glow), the DirectionalLight3D (colour, soft shadow), a gradient
# backdrop, a vignette, and the shared matte material on every styled mesh.
#
# Meshes opt in by ROLE, in either of two ways:
#   - put the node in a group named "style_<role>" under `level_root`
#     (style_floor, style_wall, style_furniture, style_accent, style_glow);
#     the whole subtree of that node takes the role, or
#   - call style_node(node, &"<role>") from code, for geometry built at runtime.
#
# Ghosts and fading walls use style_node_transparent() / set_node_alpha().
#
# Changing `palette` or `quality` re-applies everything. Materials are cached
# per (role, source colour), so a palette swap only rewrites a handful of
# shader uniforms rather than walking and re-materialising the level.
#
# This node must live in the same World3D as the level (inside the same
# SubViewport, if the level has its own).

const MATTE_SHADER    := preload("res://style/shaders/matte_gradient.gdshader")
const MATTE_ALPHA_SHADER := preload("res://style/shaders/matte_gradient_alpha.gdshader")
const MATTE_DOUBLE_SHADER := preload("res://style/shaders/matte_gradient_double.gdshader")
const GLASS_WALL_SHADER := preload("res://style/shaders/glass_wall.gdshader")
const BACKDROP_SHADER := preload("res://style/shaders/backdrop.gdshader")
const VIGNETTE_SHADER := preload("res://style/shaders/vignette.gdshader")

const ROLE_FLOOR     := &"floor"
const ROLE_WALL      := &"wall"
const ROLE_PARTITION := &"partition"   # interior wall: a lighter tint, so it reads apart from the perimeter
const ROLE_GLASS_WALL := &"glass_wall" # translucent wall: pale, faintly lit from within, like frosted glass
const ROLE_FURNITURE := &"furniture"
const ROLE_ACCENT    := &"accent"
const ROLE_GLOW      := &"glow"   # windows and lamps: emissive, the only things that bloom
const ROLE_WINDOW    := &"window" # window glass: glows by day, goes dark at night
const ROLE_TRIM      := &"trim"   # skirting, door leaves: a mid tint between wall and furniture
const ROLE_PLINTH    := &"plinth" # the block under the level; only via style_plinth()
const ROLE_SCENERY_FLOOR := &"scenery_floor"   # the floor of a giant apartment drawn around this one
const ROLES: Array[StringName] = [ROLE_FLOOR, ROLE_WALL, ROLE_PARTITION, ROLE_GLASS_WALL, ROLE_FURNITURE, ROLE_ACCENT, ROLE_GLOW, ROLE_WINDOW, ROLE_TRIM]
const GROUP_PREFIX := "style_"

const BACKDROP_DISTANCE := 400.0   # metres behind the camera plane; capped by the camera's far

# Night look: what `night = 1` blends the palette's light toward.
const NIGHT_SUN_COLOR      := Color(0.55, 0.62, 0.85)
const NIGHT_SUN_SCALE      := 0.1   # faint moonlight through the windows; the lamps light the room
const NIGHT_AMBIENT        := Color(0.10, 0.11, 0.20)
const NIGHT_AMBIENT_ENERGY := 0.6

signal applied(palette: LevelPalette)

@export var palette: LevelPalette:
	set(value):
		palette = value
		if is_node_ready():
			apply()

@export var quality: StyleQuality.Level = StyleQuality.Level.LOW:
	set(value):
		quality = value
		if is_node_ready():
			apply()

## 0 = the palette as authored (day), 1 = night: a dim, cool sun, dark ambient
## and a dark backdrop derived from the same palette. Windows and lamps keep
## glowing. Safe to tween.
@export_range(0.0, 1.0, 0.01) var night: float = 0.0:
	set(value):
		night = clampf(value, 0.0, 1.0)
		if is_node_ready() and palette != null:
			_apply_environment()
			_apply_light()
			_apply_backdrop()
			for entry in _materials.values():
				if entry["role"] == ROLE_WINDOW or entry["role"] == ROLE_GLASS_WALL:
					_configure_material(entry)

## How much of the daylight reaches the room, 0..1: the sun and the light
## coming through the windows are dimmed by it (an apartment in a box that
## stands in another piece's shadow). Nights are unchanged.
@export_range(0.0, 1.0, 0.01) var daylight: float = 1.0:
	set(value):
		daylight = clampf(value, 0.0, 1.0)
		if is_node_ready() and palette != null:
			_apply_light()
			for entry in _materials.values():
				if entry["role"] == ROLE_WINDOW or entry["role"] == ROLE_GLASS_WALL:
					_configure_material(entry)

## Pick StyleQuality.recommended() at startup instead of the value above.
@export var auto_quality: bool = false
## HIGH only: subtle far blur behind the level. Off unless asked for.
@export var high_depth_of_field: bool = false

@export_group("Scene nodes")
@export var world_environment: WorldEnvironment
@export var sun: DirectionalLight3D
@export var camera: Camera3D
## Nodes under this root that are in a "style_<role>" group get styled on apply().
@export var level_root: Node3D

@export_group("Level shape")
## Height of the vertical gradient above the floor, in metres.
@export var room_height: float = 2.4
## How far below the floor the floor slab's own side gradient runs.
@export var floor_thickness: float = 0.35
## Centre of the level relative to level_root, and its rough radius. Used to
## place the fog fade and to fit the shadow range.
@export var scene_center: Vector3 = Vector3(2.0, 1.0, 2.0)
@export var scene_radius: float = 3.5

@export_group("Look")
@export var tonemap: Environment.ToneMapper = Environment.TONE_MAPPER_FILMIC
@export var flat_shading: bool = true
## How much of its own modelled colour a furniture piece keeps (0 = every piece
## takes the palette's single furniture colour, 1 = exactly as modelled).
@export_range(0.0, 1.0, 0.01) var furniture_own_color: float = 0.95
## How much bigger than this level the scenery around it is drawn (a nested
## box's parent apartment). Scales the scenery floor's boards to match, which
## is most of what sells the size.
@export var scenery_scale: float = 1.0
## Model surfaces whose source material has one of these names are treated as
## glow surfaces (the Kenney kit names its lamp shades "lamp").
@export var glow_material_names: PackedStringArray = ["lamp"]
## Shadow atlas size/filter are global engine settings; turn this off if
## something else in the game already manages them.
@export var manage_global_shadows: bool = true

var _materials: Dictionary = {}   # cache key -> {mat: ShaderMaterial, role: StringName, src: Variant}
var _alpha_entries: Array = []    # [{ref: WeakRef, role, src}] - per-node transparent materials, not shared
var _backdrop: MeshInstance3D = null
var _vignette_layer: CanvasLayer = null
var _vignette_rect: ColorRect = null


func _ready() -> void:
	if auto_quality:
		quality = StyleQuality.recommended()
	apply()


# Keeps the backdrop quad facing the camera, far behind the level, and scaled
# to just overfill the view.
func _process(_delta: float) -> void:
	if _backdrop == null:
		return
	var cam := camera if camera != null else get_viewport().get_camera_3d()
	if cam == null:
		return
	var view_size := get_viewport().get_visible_rect().size
	var aspect := view_size.x / maxf(view_size.y, 1.0)
	var dist := minf(cam.far * 0.9, BACKDROP_DISTANCE)
	var height := cam.size if cam.projection == Camera3D.PROJECTION_ORTHOGONAL \
		else 2.0 * dist * tan(deg_to_rad(cam.fov) * 0.5)
	var xform := cam.global_transform.translated_local(Vector3(0.0, 0.0, -dist))
	# The quad is 2 x 2, so half-extents are the scale. 5% overfill.
	xform.basis = xform.basis.scaled_local(Vector3(height * aspect * 0.525, height * 0.525, 1.0))
	_backdrop.global_transform = xform


# Re-applies palette + quality to everything. Safe to call any time, e.g.
# after building or changing level geometry.
func apply() -> void:
	if palette == null or not is_inside_tree():
		return
	_apply_environment()
	_apply_light()
	_apply_backdrop()
	_apply_vignette()
	for entry in _materials.values():
		_configure_material(entry)
	for i in range(_alpha_entries.size() - 1, -1, -1):
		var alpha_mat: ShaderMaterial = (_alpha_entries[i]["ref"] as WeakRef).get_ref()
		if alpha_mat == null:
			_alpha_entries.remove_at(i)   # its node was freed
		else:
			var cfg := (_alpha_entries[i] as Dictionary).duplicate()
			cfg["mat"] = alpha_mat
			_configure_material(cfg)
	if level_root != null:
		style_tree(level_root)
	applied.emit(palette)


# Call when the camera moves or zooms: re-fits the fog fade and the shadow
# range to the new view. Cheap.
func refresh_view() -> void:
	if palette == null or not is_inside_tree():
		return
	_apply_view_ranges()


# The shared opaque material for a role, for things that aren't
# MeshInstance3Ds (a CSG shape's `material`, for example).
func material_for(role: StringName) -> ShaderMaterial:
	return _material_for(role, null)


# Styles every node under `root` that sits in a "style_<role>" group.
func style_tree(root: Node) -> void:
	for role in ROLES:
		for n in get_tree().get_nodes_in_group(GROUP_PREFIX + role):
			if n == root or root.is_ancestor_of(n):
				style_node(n, role)


# Gives `node` and its whole subtree the shared matte material for `role`.
# Lights under a glow node take the palette's glow colour.
func style_node(node: Node, role: StringName) -> void:
	_style_subtree(node, role, _material_for)


# Same, but with the transparent variant: for placement ghosts and fading
# walls. The materials are private to this subtree (so its alpha is its own),
# still follow palette changes, and are dropped when the nodes are freed.
# Change the alpha afterwards with set_node_alpha(). Don't also put the node
# in a "style_<role>" group, or apply() will restyle it opaque.
func style_node_transparent(node: Node, role: StringName, alpha: float) -> void:
	var local: Dictionary = {}
	_style_subtree(node, role, func(r: StringName, src: Variant) -> ShaderMaterial:
		src = _flat_role_src(r, src)
		var key := _material_key(r, src)
		if not local.has(key):
			var mat := ShaderMaterial.new()
			mat.shader = MATTE_ALPHA_SHADER
			mat.set_shader_parameter("alpha", alpha)
			_alpha_entries.append({"ref": weakref(mat), "role": r, "src": src})
			_configure_material({"mat": mat, "role": r, "src": src})
			local[key] = mat
		return local[key])


# Styles `node` as the block the level stands on: a deeper tint of the wall
# colour that dissolves into the backdrop toward its bottom, which is what
# makes the level read as a floating diorama. `depth` is how far below the
# floor the block reaches, in metres.
func style_plinth(node: Node, depth: float) -> void:
	_style_subtree(node, ROLE_PLINTH, func(r: StringName, _src: Variant) -> ShaderMaterial:
		var mat := ShaderMaterial.new()
		mat.shader = MATTE_ALPHA_SHADER
		mat.set_shader_parameter("alpha", 1.0)
		var entry := {"ref": weakref(mat), "role": r, "src": null, "fade_depth": depth}
		_alpha_entries.append(entry)
		var cfg := entry.duplicate()
		cfg["mat"] = mat
		_configure_material(cfg)
		return mat)


# Sets the alpha of every transparent style material under `node`.
func set_node_alpha(node: Node, alpha: float) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mats: Array = [mi.material_override]
		for i in mi.get_surface_override_material_count():
			mats.append(mi.get_surface_override_material(i))
		for m in mats:
			if m is ShaderMaterial and (m as ShaderMaterial).shader == MATTE_ALPHA_SHADER:
				(m as ShaderMaterial).set_shader_parameter("alpha", alpha)
	for child in node.get_children():
		set_node_alpha(child, alpha)


# `provider` is func(role, source_colour_or_null) -> ShaderMaterial.
func _style_subtree(node: Node, role: StringName, provider: Callable) -> void:
	if node.is_in_group(InkCorners.GROUP):
		return   # the ink keeps its own material
	if node is MeshInstance3D:
		_style_mesh(node as MeshInstance3D, role, provider)
	elif node is Light3D and role == ROLE_GLOW and palette != null:
		(node as Light3D).light_color = palette.glow_color
	for child in node.get_children():
		_style_subtree(child, role, provider)


func _style_mesh(mi: MeshInstance3D, role: StringName, provider: Callable) -> void:
	if mi.mesh == null:
		return
	if mi.mesh is PrimitiveMesh or mi.material_override != null:
		# Boxes, quads etc. have one surface and no meaningful source colour.
		# A mesh that already carries an override is treated the same way,
		# since that override would hide any per-surface material anyway.
		mi.material_override = provider.call(role, null)
		return
	# Imported models: one material per surface, keeping the light/dark
	# relationship between the model's own materials. The source colour is
	# read from the mesh resource itself, never from the override this method
	# sets, so re-styling after a palette change stays stable.
	for i in mi.mesh.get_surface_count():
		var src_mat := mi.mesh.surface_get_material(i)
		var surface_role := role
		var src: Variant = null
		if src_mat != null:
			if role != ROLE_GLOW and glow_material_names.has(src_mat.resource_name):
				surface_role = ROLE_GLOW
			elif src_mat is BaseMaterial3D:
				src = (src_mat as BaseMaterial3D).albedo_color
		mi.set_surface_override_material(i, provider.call(surface_role, src))


# Floor, wall and glow are one flat palette colour: ignore the source colour.
func _flat_role_src(role: StringName, src: Variant) -> Variant:
	if role != ROLE_FURNITURE and role != ROLE_ACCENT:
		return null
	return src


func _material_key(role: StringName, src: Variant) -> String:
	return "%s|%s" % [role, (src as Color).to_html(false) if src != null else "-"]


func _material_for(role: StringName, src: Variant) -> ShaderMaterial:
	src = _flat_role_src(role, src)
	var key := _material_key(role, src)
	if _materials.has(key):
		return _materials[key]["mat"]
	var mat := ShaderMaterial.new()
	mat.shader = MATTE_DOUBLE_SHADER if (role == ROLE_WALL or role == ROLE_PARTITION) else MATTE_SHADER
	if role == ROLE_GLASS_WALL:
		mat.shader = GLASS_WALL_SHADER      # see-through and reeded: its own shader
	var entry := {"mat": mat, "role": role, "src": src}
	_materials[key] = entry
	_configure_material(entry)
	return mat


func _configure_material(entry: Dictionary) -> void:
	if palette == null:
		return
	var mat: ShaderMaterial = entry["mat"]
	var role: StringName = entry["role"]
	var base_y := level_root.global_position.y if level_root != null else 0.0
	var strength := palette.gradient_strength
	mat.set_shader_parameter("tint", _surface_color(role, entry["src"]))
	mat.set_shader_parameter("shadow_tint", palette.shadow_tint)
	mat.set_shader_parameter("shadow_fill", palette.shadow_fill)
	mat.set_shader_parameter("flat_shading", flat_shading)
	if role == ROLE_SCENERY_FLOOR:
		# One even tone, a touch under the room's own floor so the room reads
		# as sitting on it.
		mat.set_shader_parameter("grad_bottom", 0.9)
		mat.set_shader_parameter("grad_top", 0.9)
	elif role == ROLE_FLOOR:
		# The floor's top face stays at full brightness (it has to be the
		# lightest large surface); only the slab's sides darken downward.
		mat.set_shader_parameter("grad_y_min", base_y - floor_thickness)
		mat.set_shader_parameter("grad_y_max", base_y - 0.01)
		mat.set_shader_parameter("grad_bottom", 1.0 - strength * 1.5)
		mat.set_shader_parameter("grad_top", 1.0)
	elif role == ROLE_PLINTH:
		var depth: float = entry.get("fade_depth", 1.5)
		mat.set_shader_parameter("grad_y_min", base_y - depth)
		mat.set_shader_parameter("grad_y_max", base_y)
		mat.set_shader_parameter("grad_bottom", 1.0 - strength * 1.5)
		mat.set_shader_parameter("grad_top", 1.0)
		mat.set_shader_parameter("fade_y_min", base_y - depth)
		mat.set_shader_parameter("fade_y_max", base_y - depth * 0.25)
	else:
		mat.set_shader_parameter("grad_y_min", base_y)
		mat.set_shader_parameter("grad_y_max", base_y + room_height)
		mat.set_shader_parameter("grad_bottom", 1.0 - strength)
		mat.set_shader_parameter("grad_top", 1.0 + strength * 0.25)
	mat.set_shader_parameter("pattern_strength",
		palette.floor_pattern if (role == ROLE_FLOOR or role == ROLE_SCENERY_FLOOR) else 0.0)
	mat.set_shader_parameter("plank_width", 0.2 * (scenery_scale if role == ROLE_SCENERY_FLOOR else 1.0))
	# Walls show a light, flat cut face on top.
	mat.set_shader_parameter("top_tint", palette.cut_color)
	mat.set_shader_parameter("top_tint_amount", 1.0 if (role == ROLE_WALL or role == ROLE_PARTITION or role == ROLE_GLASS_WALL) else 0.0)
	if role == ROLE_GLOW:
		mat.set_shader_parameter("emission", palette.glow_color)
		mat.set_shader_parameter("emission_energy", palette.glow_energy)
	elif role == ROLE_GLASS_WALL:
		# Light is coming through it: a soft glow by day, almost none at night.
		mat.set_shader_parameter("emission", palette.glow_color.lerp(_night_glass(), night))
		mat.set_shader_parameter("emission_energy", lerpf(palette.glow_energy * 0.16 * daylight, 0.0, night))
	elif role == ROLE_WINDOW:
		# Daylight coming in; at night the glass is a dim pane of night sky,
		# still faintly self-lit so it never drops to a black hole.
		mat.set_shader_parameter("emission", palette.glow_color.lerp(_night_glass(), night))
		mat.set_shader_parameter("emission_energy", lerpf(palette.glow_energy * lerpf(0.25, 1.0, daylight), 0.5, night))
	else:
		mat.set_shader_parameter("emission_energy", 0.0)


# Maps a model's own material colour onto the palette: lighter source
# materials drift toward the floor tint, darker ones toward a deeper shade of
# the role colour, so parts stay distinguishable while staying on-hue.
func _surface_color(role: StringName, src: Variant) -> Color:
	var base: Color
	match role:
		ROLE_FLOOR:  base = palette.floor_color
		ROLE_WALL:   base = palette.wall_color
		ROLE_PARTITION: base = palette.wall_color.lerp(palette.floor_color, 0.6)
		# Pale by day; at night there is nothing behind it to light it, so
		# it falls back toward the ordinary wall colour.
		ROLE_GLASS_WALL: base = palette.floor_color.lerp(Color(0.55, 0.92, 0.90), 0.6).lerp(palette.wall_color.darkened(0.15), night * 0.6)
		ROLE_ACCENT: base = palette.accent_color
		ROLE_PLINTH: base = palette.wall_color.lerp(palette.furniture_color, 0.35)
		ROLE_SCENERY_FLOOR: base = palette.floor_color.lerp(palette.wall_color, 0.6)
		ROLE_GLOW:   base = palette.glow_color
		ROLE_WINDOW: base = palette.glow_color.lerp(_night_glass(), night)
		ROLE_TRIM:   base = palette.wall_color.lerp(palette.furniture_color, 0.5)
		_:           base = palette.furniture_color
	if src == null:
		return base
	var src_color: Color = src
	var lum := src_color.get_luminance()
	var k := palette.material_contrast
	var out: Color
	if lum >= 0.5:
		out = base.lerp(palette.floor_color, (lum - 0.5) * 2.0 * k)
	else:
		out = base.darkened((0.5 - lum) * 2.0 * k * 0.6)
	var keep := palette.keep_source_color
	if role == ROLE_FURNITURE or role == ROLE_ACCENT:
		# Furniture keeps most of the colour it was modelled with, pulled a
		# little toward the level's hue so the room still reads as one place.
		keep = maxf(keep, furniture_own_color)
	out = out.lerp(src_color, keep)
	out.a = 1.0
	return out


# Distance from the camera plane to the level centre, along the view axis.
func _focus_depth() -> float:
	if camera == null:
		return 10.0
	var center := scene_center
	if level_root != null:
		center = level_root.global_transform * scene_center
	return -(camera.global_transform.affine_inverse() * center).z


func _apply_environment() -> void:
	if world_environment == null:
		return
	if world_environment.environment == null:
		world_environment.environment = Environment.new()
	var env := world_environment.environment

	# The gradient is the backdrop mesh; this flat colour is only what shows
	# if that mesh is ever missing.
	env.background_mode = Environment.BG_COLOR
	env.background_color = palette.fog_color.lerp(_night_backdrop(0.6), night)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = palette.ambient_color.lerp(palette.shadow_tint.lerp(NIGHT_AMBIENT, 0.25), night)
	env.ambient_light_energy = lerpf(palette.ambient_energy, NIGHT_AMBIENT_ENERGY, night)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	env.tonemap_mode = tonemap
	env.tonemap_white = 1.0 if tonemap == Environment.TONE_MAPPER_LINEAR else 4.0
	env.adjustment_enabled = true
	env.adjustment_brightness = palette.brightness

	# Depth fog between two planes: clear in front of the level, fading to
	# the palette colour toward its far edge. No sun scatter, no volumetrics.
	env.fog_enabled = palette.fog_strength > 0.0
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = palette.fog_color.lerp(_night_backdrop(0.6), night)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.0
	env.fog_aerial_perspective = 0.0
	env.fog_sky_affect = 0.0
	env.fog_density = palette.fog_strength
	env.fog_depth_curve = 1.0
	_apply_view_ranges()

	StyleQuality.apply_environment(env, quality)
	StyleQuality.apply_camera(camera, quality, high_depth_of_field, _focus_depth(), scene_radius)
	if camera != null:
		StyleQuality.apply_viewport(camera.get_viewport(), quality)
	if manage_global_shadows:
		StyleQuality.apply_global_shadows(quality)


# Everything that depends on where the camera is relative to the level.
func _apply_view_ranges() -> void:
	var depth := _focus_depth()
	if world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		env.fog_depth_begin = maxf(depth - scene_radius * 0.3, 0.0)
		env.fog_depth_end = maxf(depth, 0.0) + scene_radius * 2.2
	if sun != null:
		# One cascade fitted tightly around the level keeps a small atlas sharp.
		sun.directional_shadow_max_distance = maxf(depth, 0.0) + scene_radius * 1.5


# Dark version of the level hue, used for the backdrop and fog at night.
func _night_backdrop(darken: float) -> Color:
	return palette.shadow_tint.darkened(darken)


func _night_glass() -> Color:
	return palette.shadow_tint.lerp(NIGHT_SUN_COLOR, 0.35)


func _apply_light() -> void:
	if sun == null:
		return
	sun.light_color = palette.light_color.lerp(NIGHT_SUN_COLOR, night)
	sun.light_energy = lerpf(palette.light_energy * daylight, palette.light_energy * NIGHT_SUN_SCALE, night)
	sun.light_specular = 0.0
	sun.shadow_enabled = true
	sun.shadow_blur = 0.6   # fairly crisp: graphic shadows, not smudges
	sun.shadow_bias = 0.15
	sun.shadow_normal_bias = 2.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_apply_view_ranges()
	# The level sits near the far end of that range; the default fade would
	# dissolve its shadows.
	sun.directional_shadow_fade_start = 1.0


func _apply_backdrop() -> void:
	if _backdrop == null:
		_backdrop = MeshInstance3D.new()
		_backdrop.name = "StyleBackdrop"
		var quad := QuadMesh.new()
		quad.size = Vector2(2.0, 2.0)
		_backdrop.mesh = quad
		var mat := ShaderMaterial.new()
		mat.shader = BACKDROP_SHADER
		_backdrop.material_override = mat
		_backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_backdrop)
	var bmat := _backdrop.material_override as ShaderMaterial
	bmat.set_shader_parameter("top_color", palette.background_top.lerp(_night_backdrop(0.7), night))
	bmat.set_shader_parameter("bottom_color", palette.background_bottom.lerp(_night_backdrop(0.35), night))
	bmat.set_shader_parameter("center_lift", lerpf(0.08, 0.02, night))


func _apply_vignette() -> void:
	var wanted := quality >= StyleQuality.Level.MEDIUM and palette.vignette_strength > 0.0
	if _vignette_layer == null:
		if not wanted:
			return
		_vignette_layer = CanvasLayer.new()
		_vignette_layer.name = "StyleVignette"
		_vignette_layer.layer = 0
		_vignette_rect = ColorRect.new()
		_vignette_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_vignette_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = VIGNETTE_SHADER
		_vignette_rect.material = mat
		_vignette_layer.add_child(_vignette_rect)
		add_child(_vignette_layer)
	_vignette_layer.visible = wanted
	var vmat := _vignette_rect.material as ShaderMaterial
	vmat.set_shader_parameter("color", palette.vignette_color)
	vmat.set_shader_parameter("strength", palette.vignette_strength)
