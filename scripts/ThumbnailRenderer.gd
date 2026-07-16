extends Node
# Autoload "Thumb" — renders each furniture piece's real 3D model to a still
# catalog-photo-style icon (angled 3/4 view), instead of the flat color
# swatch/footprint chip the shop used before. One shared SubViewport does the
# rendering; results are cached per furniture id so each model is only ever
# rendered once per session.

const RENDER_SIZE := 128

# Real-world scale for the top-down/elevation renders below — matches
# Room3DView's TILE_M so a rendered icon composites at the same scale as
# everything else in the Floor Plan / Wall View (tile-accurate, not just
# "fit to the model's own bounding box" like the angled catalog photo above).
const TILE_M := 0.1
const ORTHO_PX_PER_M := 120.0
const ORTHO_MAX_PX := 480

var _sub_vp: SubViewport
var _holder: Node3D
var _cam: Camera3D
var _cache: Dictionary = {}       # cache_key ("cat:id" / "top:id" / "front:id") -> Texture2D
var _pending: Dictionary = {}     # cache_key -> Array[Callable] awaiting this key's render
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
	return _cache.get("cat:" + furniture_id) as Texture2D


# Same idea as get_cached() above, for the top-down/elevation renders —
# mode is "top" or "front".
func get_cached_ortho(mode: String, furniture_id: String) -> Texture2D:
	return _cache.get(mode + ":" + furniture_id) as Texture2D


# Renders (or returns the cached render of) furniture_id's 3D model as an
# angled catalog-photo icon. Safe to call many times concurrently — requests
# for the same id share one render, and only one render runs at a time (the
# shared SubViewport can't render two models at once).
func get_icon_async(fdata: Dictionary) -> Texture2D:
	var fid := fdata.get("id", "") as String
	if fid == "":
		return null
	var model_path := fdata.get("model", "") as String
	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return null
	return await _dispatch("cat:" + fid, "cat", model_path)


# Real orthographic top-down render of the model, framed to the item's actual
# floor footprint (grid_w × grid_h tiles, in metres) — used so the Floor Plan/
# Wall View/shop tooltip show the item's real shape (a round toilet bowl, a
# chair's actual silhouette, ...) instead of a hand-authored generic symbol.
func get_topdown_icon_async(fdata: Dictionary) -> Texture2D:
	var fid := fdata.get("id", "") as String
	var model_path := fdata.get("model", "") as String
	if fid == "" or model_path.is_empty() or not ResourceLoader.exists(model_path):
		return null
	var sz := fdata.get("size", {}) as Dictionary
	var span_x := (sz.get("w", 4) as int) * TILE_M
	var span_z := (sz.get("h", 4) as int) * TILE_M
	return await _dispatch("top:" + fid, "top", model_path, span_x, span_z)


# Real orthographic front-elevation render, framed to the item's actual
# width × wall-height (tiles, in metres) — same idea as the top-down render
# above, but for the Wall View's side-on silhouette.
func get_elevation_icon_async(fdata: Dictionary) -> Texture2D:
	var fid := fdata.get("id", "") as String
	var model_path := fdata.get("model", "") as String
	if fid == "" or model_path.is_empty() or not ResourceLoader.exists(model_path):
		return null
	var sz := fdata.get("size", {}) as Dictionary
	var span_x := (sz.get("w", 4) as int) * TILE_M
	var span_y := (fdata.get("wall_h", 8) as int) * TILE_M
	return await _dispatch("front:" + fid, "front", model_path, span_x, span_y)


# Shared concurrency-safe cache/queue: requests for the same key share one
# render, and only one render runs at a time across ALL three render kinds
# (the shared SubViewport/holder can't render two models at once).
func _dispatch(cache_key: String, kind: String, model_path: String, span_a: float = 0.0, span_b: float = 0.0) -> Texture2D:
	if _cache.has(cache_key):
		return _cache[cache_key]
	if _pending.has(cache_key):
		# GDScript lambdas capture locals by value, so a plain bool/var written
		# inside the callback would never be visible to this awaiting loop —
		# use a one-element Array as a mutable cell shared with the callback.
		var cell := [null, false]   # [result, got]
		var cb := func(tex: Texture2D):
			cell[0] = tex
			cell[1] = true
		(_pending[cache_key] as Array).append(cb)
		while not cell[1]:
			await get_tree().process_frame
		return cell[0]

	_pending[cache_key] = []
	while _busy:
		await get_tree().process_frame
	_busy = true
	var tex: Texture2D = null
	match kind:
		"cat":   tex = await _render(model_path)
		"top":   tex = await _render_ortho(model_path, "top", span_a, span_b)
		"front": tex = await _render_ortho(model_path, "front", span_a, span_b)
	_busy = false
	if tex:
		_cache[cache_key] = tex
	for cb in (_pending[cache_key] as Array):
		(cb as Callable).call(tex)
	_pending.erase(cache_key)
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


# Real-scale orthographic render — "top" looks straight down (matches the
# Floor Plan's north-up orientation), "front" looks straight on (matches the
# Wall View's side-on silhouette). span_a/span_b are the real-world width ×
# depth (top) or width × wall-height (front) in metres, framed to those
# EXACT declared dimensions (not just "fit to the model's own bounding box")
# so a slightly undersized model still reads as occupying its full tile
# footprint, same as it does in actual gameplay. The output texture's pixel
# aspect matches span_a:span_b exactly, so it composites at true scale
# instead of being squashed into a fixed square.
func _render_ortho(model_path: String, mode: String, span_a: float, span_b: float) -> Texture2D:
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
	inst.position -= center

	var w_px := clampi(int(round(maxf(span_a, 0.05) * ORTHO_PX_PER_M)), 8, ORTHO_MAX_PX)
	var h_px := clampi(int(round(maxf(span_b, 0.05) * ORTHO_PX_PER_M)), 8, ORTHO_MAX_PX)
	_sub_vp.size = Vector2i(w_px, h_px)
	# Resizing a SubViewport's render target doesn't take effect on the very
	# next frame it's read back — without this, the catalog renderer (which
	# never resizes, always RENDER_SIZE×RENDER_SIZE) works fine, but this one
	# would capture the old/blank texture at the new Image dimensions.
	await get_tree().process_frame
	await get_tree().process_frame

	var dist := maxf(box.size.length(), 1.0) * 4.0
	_cam.size = span_b * 1.06   # vertical extent; horizontal follows from the viewport's own w:h aspect
	if mode == "top":
		_cam.position = Vector3(0.0, dist, 0.0)
		_cam.look_at(Vector3.ZERO, Vector3(0.0, 0.0, -1.0))
	else:
		_cam.position = Vector3(0.0, 0.0, dist)
		_cam.look_at(Vector3.ZERO, Vector3.UP)

	_sub_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _sub_vp.get_texture().get_image()
	inst.queue_free()
	_sub_vp.size = Vector2i(RENDER_SIZE, RENDER_SIZE)   # restore for the catalog-photo renderer
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
