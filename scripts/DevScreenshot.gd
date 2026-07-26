extends Node

# Dev-only screenshot hotkey — Ctrl+Shift+Alt+S dumps the current frame to a
# fixed path inside the project directory, so a screenshot can be grabbed
# directly (no window-focus/OS automation needed, which has been unreliable
# in this dev environment). Always overwrites the same file rather than
# timestamping, since the only consumer is "what does the screen look like
# right now." Never active outside a debug build — same guard Main.gd/
# CityMap.gd already use for their own dev-only shortcuts.
const SCREENSHOT_DIR  := "res://dev_screenshots"
const SCREENSHOT_PATH := SCREENSHOT_DIR + "/latest.png"


func _unhandled_key_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if not (event is InputEventKey):
		return
	var ke := event as InputEventKey
	if not (ke.pressed and not ke.echo):
		return
	if ke.keycode == KEY_S and ke.ctrl_pressed and ke.shift_pressed and ke.alt_pressed:
		get_viewport().set_input_as_handled()
		_take_screenshot()


func _take_screenshot() -> void:
	var abs_dir := ProjectSettings.globalize_path(SCREENSHOT_DIR)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)
	# One frame's worth of compositor lag on the viewport texture is
	# irrelevant here (nothing is animating fast enough for it to matter for
	# a manual dev screenshot), so no need to await a frame before reading it.
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(SCREENSHOT_PATH)
	if err == OK:
		print("[DevScreenshot] Saved: %s" % ProjectSettings.globalize_path(SCREENSHOT_PATH))
	else:
		push_error("[DevScreenshot] Failed to save screenshot (error %d)" % err)
