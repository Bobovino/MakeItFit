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

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.05, 0.09, 0.92)
	bg.size  = Vector2(1280, 720)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	bg.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed \
				and (e as InputEventMouseButton).button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			_close())

	var card := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color     = Color(0.115, 0.100, 0.085)
	cs.border_color = GameTheme.C_BORDER
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(10)
	cs.anti_aliasing = true
	cs.set_content_margin_all(24)
	cs.shadow_color = Color(0, 0, 0, 0.4)
	cs.shadow_size  = 10
	card.add_theme_stylebox_override("panel", cs)
	card.position            = Vector2(390, 110)
	card.custom_minimum_size = Vector2(500, 480)
	add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	card.add_child(vb)

	var title := Label.new()
	title.text = "CREDITS"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", GameTheme.C_AMBER)
	vb.add_child(title)

	vb.add_child(_entry("Fonts",
		"Caveat — Copyright 2014 The Caveat Project Authors\n" +
		"Space Grotesk — Copyright 2020 The Space Grotesk Project Authors\n" +
		"Licensed under the SIL Open Font License 1.1 (scripts.sil.org/OFL)"))

	vb.add_child(HSeparator.new())

	vb.add_child(_entry("Art & Sound",
		"Furniture models, interface sounds, and casino/UI audio by Kenney (kenney.nl)\n" +
		"Released under Creative Commons Zero (CC0)"))

	vb.add_child(HSeparator.new())

	vb.add_child(_entry("Ambient Rain",
		"Original work created for this project — no attribution required."))

	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(push)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.add_theme_font_size_override("font_size", 13)
	var rs := GameTheme.make_rent_btn_style()
	close_btn.add_theme_stylebox_override("normal",  rs[0])
	close_btn.add_theme_stylebox_override("hover",   rs[1])
	close_btn.add_theme_stylebox_override("pressed", rs[1])
	close_btn.add_theme_color_override("font_color", GameTheme.C_AMBER)
	close_btn.pressed.connect(_close)
	vb.add_child(close_btn)


func _entry(header: String, body: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var hdr := Label.new()
	hdr.text = header.to_upper()
	hdr.add_theme_font_size_override("font_size", 12)
	hdr.add_theme_color_override("font_color", GameTheme.C_MUTED)
	box.add_child(hdr)

	var b := Label.new()
	b.text = body
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", GameTheme.C_TEXT)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(b)

	return box


func _close() -> void:
	queue_free()
