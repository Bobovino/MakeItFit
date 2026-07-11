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


func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true
	_rect.mouse_filter = Control.MOUSE_FILTER_STOP   # swallow clicks mid-fade
	var tw := create_tween()
	tw.tween_property(_rect, "color:a", 1.0, FADE_OUT)
	tw.tween_callback(func():
		get_tree().change_scene_to_file(path)
		_busy = false
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE)
