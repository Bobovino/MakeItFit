extends Node
# Autoload "Thumb" — renders each furniture piece's real 3D model to a still
# catalog-photo-style icon (angled 3/4 view), instead of the flat color
# swatch/footprint chip the shop used before. One shared SubViewport does the
# rendering; results are cached per furniture id so each model is only ever
# rendered once per session.

const RENDER_SIZE := 128

var _sub_vp: SubViewport
var _holder: Node3D
var _cam: Camera3D
var _cache: Dictionary = {}       # furniture_id -> Texture2D
var _pending: Dictionary = {}     # furniture_id -> Array[Callable] awaiting this id's render
var _busy: bool = false


func _ready() -> void:
	_sub_vp = SubViewport.new()
	_sub_vp.size = Vector2i(RENDER_SIZE, RENDER_SIZE)
	_sub_vp.transparent_bg = true
	_sub_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sub_vp.own_world_3d = true
	add_child(_sub_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.58)
	env.ambient_light_energy = 1.0
	var wenv := WorldEnvironment.new()
	wenv.environment = env
	_sub_vp.add_child(wenv)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	light.light_energy = 1.1
	_sub_vp.add_child(light)

	_holder = Node3D.new()
	_sub_vp.add_child(_holder)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_sub_vp.add_child(_cam)


# Returns a cached icon immediately if we already have one, else null (caller
# should fall back to a placeholder and call get_icon_async to fetch it).
func get_cached(furniture_id: String) -> Texture2D:
	return _cache.get(furniture_id) as Texture2D


# Renders (or returns the cached render of) furniture_id's 3D model as an
# angled catalog-photo icon. Safe to call many times concurrently — requests
# for the same id share one render, and only one render runs at a time (the
# shared SubViewport can't render two models at once).
func get_icon_async(fdata: Dictionary) -> Texture2D:
	var fid := fdata.get("id", "") as String
	if fid == "":
		return null
	if _cache.has(fid):
		return _cache[fid]
	var model_path := fdata.get("model", "") as String
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return null

	if _pending.has(fid):
		# GDScript lambdas capture locals by value, so a plain bool/var written
		# inside the callback would never be visible to this awaiting loop —
		# use a one-element Array as a mutable cell shared with the callback.
		var cell := [null, false]   # [result, got]
		var cb := func(tex: Texture2D):
			cell[0] = tex
			cell[1] = true
		(_pending[fid] as Array).append(cb)
		while not cell[1]:
			await get_tree().process_frame
		return cell[0]

	_pending[fid] = []
	while _busy:
		await get_tree().process_frame
	_busy = true
	var tex := await _render(model_path)
	_busy = false
	if tex:
		_cache[fid] = tex
	for cb in (_pending[fid] as Array):
		(cb as Callable).call(tex)
	_pending.erase(fid)
	return tex


func _render(model_path: String) -> Texture2D:
	var packed := load(model_path) as PackedScene
	if not packed:
		return null
	var inst := packed.instantiate() as Node3D
	if not inst:
		return null
	_holder.add_child(inst)

	var box := _combined_aabb(inst)
	if box.size.length() < 0.0001:
		inst.queue_free()
		return null

	var center := box.get_center()
	inst.position -= center   # re-center the model on the holder's origin

	# Frame a 3/4-angle "catalog photo" shot: camera offset equally on X/Z,
	# elevated, always far enough back to fit the model's largest extent.
	var radius := box.size.length() * 0.5
	var dist := maxf(radius * 2.4, 0.6)
	_cam.size = radius * 2.05
	_cam.position = Vector3(dist, dist * 0.85, dist)
	_cam.look_at(Vector3.ZERO, Vector3.UP)

	_sub_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _sub_vp.get_texture().get_image()
	inst.queue_free()
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


# Combined AABB (in `node`'s local space) across every MeshInstance3D
# descendant — more robust than "first mesh found" for multi-mesh models
# (e.g. a bed with a separate pillow mesh).
func _combined_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var have_box := false
	var stack: Array = [[node, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var entry: Array = stack.pop_back()
		var n: Node3D = entry[0]
		var xform: Transform3D = entry[1]
		if n is MeshInstance3D and (n as MeshInstance3D).mesh:
			var mesh_box: AABB = xform * (n as MeshInstance3D).mesh.get_aabb()
			if have_box:
				box = box.merge(mesh_box)
			else:
				box = mesh_box
				have_box = true
		for child in n.get_children():
			if child is Node3D:
				stack.append([child, xform * (child as Node3D).transform])
	return box
