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
	layer = 26  # over the pause menu (24) and the settings screen

	var w := MenuKit.screen(self, tr("Credits"), _close, false, false, Vector2(720, 520))
	var page: VBoxContainer = w["page"]
	page.add_theme_constant_override("separation", 22)

	page.add_child(_entry(tr("Fonts"),
		"Caveat — Copyright 2014 The Caveat Project Authors\n" +
		"Space Grotesk — Copyright 2020 The Space Grotesk Project Authors\n" +
		tr("Licensed under the SIL Open Font License 1.1 (scripts.sil.org/OFL)")))

	page.add_child(_entry(tr("Art & Sound"),
		tr("Interface sounds and casino/UI audio by Kenney (kenney.nl)") + "\n" +
		tr("Released under Creative Commons Zero (CC0)")))

	page.add_child(_entry(tr("Ambient Rain"),
		tr("Original work created for this project — no attribution required.")))


func _entry(header: String, body: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	MenuKit.heading(box, header)
	MenuKit.text(box, body)
	return box


func _close() -> void:
	queue_free()


# Esc closes this window.
func _input(event: InputEvent) -> void:
	if MenuKit.is_escape(event):
		_close()
		get_viewport().set_input_as_handled()
