extends CanvasLayer

# Third-party asset attribution, reachable from Settings. The two fonts (SIL
# OFL 1.1) are the only assets here with an actual attribution requirement —
# see assets/fonts/LICENSE_*_OFL.txt — everything Kenney-sourced is CC0
# (credit requested, not required, per assets/audio/LICENSE_kenney_*.txt and
# assets/models/furniture/LICENSE.txt). Listed together anyway since Kenney's
# assets are most of the game's furniture/sound and crediting them costs
# nothing. ambient_rain.wav is original work made for this project — no
# attribution owed, not listed.
#
# No class_name — instantiated straight off a preloaded script resource by
# SettingsMenu.gd so it works immediately without waiting on Godot's global
# script-class cache to notice a brand new file.

static func open(host: Node) -> CanvasLayer:
	var m := CanvasLayer.new()
	m.set_script(load("res://scripts/CreditsMenu.gd"))
	host.add_child(m)
	m.call("_build")
	return m


func _build() -> void:
	layer = 26  # above SettingsMenu (25), since it's opened from there

	var w := MenuKit.modal(self, tr("CREDITS"), 520.0, _close)
	var body: VBoxContainer = w["body"]

	body.add_child(_entry(tr("Fonts"),
		"Caveat — Copyright 2014 The Caveat Project Authors
" +
		"Space Grotesk — Copyright 2020 The Space Grotesk Project Authors
" +
		tr("Licensed under the SIL Open Font License 1.1 (scripts.sil.org/OFL)")))

	body.add_child(_entry(tr("Art & Sound"),
		tr("Interface sounds and casino/UI audio by Kenney (kenney.nl)") + "
" +
		tr("Released under Creative Commons Zero (CC0)")))

	body.add_child(_entry(tr("Ambient Rain"),
		tr("Original work created for this project — no attribution required.")))

	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(w["footer"] as Control).add_child(push)
	var close_btn := MenuKit.button(tr("Close"), "primary")
	close_btn.custom_minimum_size.x = 120
	close_btn.pressed.connect(_close)
	(w["footer"] as Control).add_child(close_btn)


func _entry(header: String, body: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var hdr := Label.new()
	hdr.text = header.to_upper()
	hdr.add_theme_font_size_override("font_size", MenuKit.FONT_SECTION)
	hdr.add_theme_color_override("font_color", GameTheme.C_AMBER.darkened(0.3))
	box.add_child(hdr)
	MenuKit.text(box, body)
	return box


func _close() -> void:
	queue_free()


# Esc closes this window.
func _input(event: InputEvent) -> void:
	if MenuKit.is_escape(event):
		_close()
		get_viewport().set_input_as_handled()
