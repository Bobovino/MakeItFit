class_name InkNormalPass
extends SubViewport

# A second, hidden render of the room for the ink (see InkLines): the same
# world, seen through a camera that follows the view's own every frame, in
# which each styled surface paints the direction it faces and its distance
# instead of its colour (matte_gradient.gdshaderinc, when the camera has
# PASS_FLAG). Where that direction changes sharply, two faces meet at a
# corner. Only meshes the style system painted are in it (NORMAL_LAYER):
# floor markings, glass and the Miis aren't, so they never make corners of
# their own. Since a Mii isn't there, the furniture behind it is; the
# distance is how the ink pass knows something nearer covers that furniture
# in the real image, and draws none of its corners there.

# Layer 19: meshes that take part. Layer 20: set only on this pass's camera,
# which is how the shader knows it is drawing directions. The view's own
# camera must not have it.
const NORMAL_LAYER := 1 << 18
const PASS_FLAG := 1 << 19

var source_cam: Camera3D
var source_vp: SubViewport
var _cam: Camera3D


func setup(view_cam: Camera3D, view_vp: SubViewport) -> void:
	source_cam = view_cam
	source_vp = view_vp
	world_3d = view_vp.find_world_3d()
	size = view_vp.size
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	msaa_3d = Viewport.MSAA_DISABLED
	transparent_bg = false
	# Never draws its own 2D or reads input: it only exists for its texture.
	disable_3d = false
	gui_disable_input = true
	_cam = Camera3D.new()
	_cam.cull_mask = NORMAL_LAYER | PASS_FLAG
	# Its own plain environment: no fog, glow or tone curve bending the
	# directions on their way into the texture.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.BLACK
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_cam.environment = env
	add_child(_cam)
	_cam.current = true
	view_cam.cull_mask &= ~PASS_FLAG
	_sync()


func _process(_delta: float) -> void:
	_sync()


func _sync() -> void:
	if not is_instance_valid(source_cam) or not is_instance_valid(source_vp):
		return
	if size != source_vp.size:
		size = source_vp.size
	_cam.global_transform = source_cam.global_transform
	_cam.projection = source_cam.projection
	_cam.fov = source_cam.fov
	_cam.size = source_cam.size
	_cam.near = source_cam.near
	_cam.far = source_cam.far
	_cam.h_offset = source_cam.h_offset
	_cam.v_offset = source_cam.v_offset
	_cam.keep_aspect = source_cam.keep_aspect
