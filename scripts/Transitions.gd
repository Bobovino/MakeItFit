extends CanvasLayer
# Autoload "Transition" — quick fade-to-black scene changes so screens don't
# hard-cut. Call Transition.change_scene(path) anywhere a raw
# get_tree().change_scene_to_file(path) used to be.

const FADE_OUT := 0.16
const FADE_IN  := 0.22

var _rect: ColorRect
var _busy := false


func _ready() -> void:
	layer = 100
	_rect = ColorRect.new()
	_rect.color = Color(0.06, 0.05, 0.04, 0.0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	# Every fresh scene opens with a fade-in from black
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if node == get_tree().current_scene and _rect.color.a > 0.0:
		var tw := create_tween()
		tw.tween_property(_rect, "color:a", 0.0, FADE_IN)


# Starts loading a scene the player is likely to open next, on a background
# thread, so change_scene() finds it ready. The level scene's scripts take
# over a second and a half to load the first time in a session; the title
# screen and the map ask for it as soon as they open.
var _warming: Dictionary = {}   # path -> true while requested, then its PackedScene

func prewarm(path: String) -> void:
	if _warming.has(path) or ResourceLoader.has_cached(path):
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		_warming[path] = true


func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	_rect.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks mid-fade
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", 1.0, FADE_OUT)
	tw.tween_callback(func():
		var warmed = _warming.get(path)
		if warmed is bool:
			# Still loading, or done: either way take it from the loader
			# (waits for the rest, if any).
			warmed = ResourceLoader.load_threaded_get(path)
			_warming[path] = warmed   # kept, so a later visit is cached too
		if warmed is PackedScene:
			get_tree().change_scene_to_packed(warmed)
		else:
			get_tree().change_scene_to_file(path)
		_busy = false
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE)
