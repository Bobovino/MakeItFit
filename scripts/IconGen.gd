extends RefCounted
class_name IconGen

# Small procedural icons for the Builder tab's tool buttons — drawn as raw
# pixels rather than sourced from an external asset pack, since the icon set
# needed (wall/column/erase/balcony/bathroom/window/door/rail/reveal/pipe) is
# small, geometric, and specific enough that hand-drawing them here is both
# simpler and more precisely on-theme (matches the blueprint ink colour) than
# hunting for a matching external icon in a generic pack.

const SZ := 16
const INK := Color(0.86, 0.94, 1.00, 1.0)   # same bright blueprint ink used everywhere else


static func make(tool_id: String) -> ImageTexture:
	var img := Image.create(SZ, SZ, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match tool_id:
		"":            _select(img)
		"wall":        _wall(img)
		"column":      _column(img)
		"erase":       _erase(img)
		"balcony":     _balcony(img)
		"bathroom":    _bathroom(img)
		"window":      _window(img)
		"door":        _door(img)
		"rail":        _rail(img)
		"reveal":      _reveal(img)
		"pipe_water":  _pipe(img, Color(0.35, 0.70, 0.95, 1.0))
		"pipe_power":  _pipe(img, Color(0.95, 0.80, 0.25, 1.0))
	return ImageTexture.create_from_image(img)


static func _hline(img: Image, x0: int, x1: int, y: int, col: Color, t: int = 1) -> void:
	for yy in range(y, y + t):
		for x in range(x0, x1 + 1):
			if x >= 0 and x < SZ and yy >= 0 and yy < SZ:
				img.set_pixel(x, yy, col)


static func _vline(img: Image, x: int, y0: int, y1: int, col: Color, t: int = 1) -> void:
	for xx in range(x, x + t):
		for y in range(y0, y1 + 1):
			if xx >= 0 and xx < SZ and y >= 0 and y < SZ:
				img.set_pixel(xx, y, col)


static func _diag(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	var steps := maxi(absi(x1 - x0), absi(y1 - y0))
	for i in range(steps + 1):
		var t := float(i) / maxf(steps, 1)
		var x := int(round(lerpf(x0, x1, t)))
		var y := int(round(lerpf(y0, y1, t)))
		if x >= 0 and x < SZ and y >= 0 and y < SZ:
			img.set_pixel(x, y, col)


static func _rect_outline(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	_hline(img, x0, x1, y0, col)
	_hline(img, x0, x1, y1, col)
	_vline(img, x0, y0, y1, col)
	_vline(img, x1, y0, y1, col)


static func _fill_rect(img: Image, x0: int, y0: int, x1: int, y1: int, col: Color) -> void:
	for y in range(y0, y1 + 1):
		_hline(img, x0, x1, y, col)


static func _select(img: Image) -> void:
	# Simple arrow cursor
	var pts := [[3,2],[3,12],[6,9],[8,13],[10,12],[8,8],[12,8]]
	for p in pts:
		img.set_pixel(p[0], p[1], INK)
	_diag(img, 3, 2, 3, 12, INK)
	_diag(img, 3, 2, 12, 9, INK)
	_diag(img, 3, 12, 8, 13, INK)
	_diag(img, 6, 9, 10, 12, INK)


static func _wall(img: Image) -> void:
	_fill_rect(img, 2, 6, 13, 9, INK)


static func _column(img: Image) -> void:
	_fill_rect(img, 5, 5, 10, 10, INK)
	_diag(img, 5, 5, 10, 10, Color(0.10, 0.24, 0.40, 1.0))
	_diag(img, 10, 5, 5, 10, Color(0.10, 0.24, 0.40, 1.0))


static func _erase(img: Image) -> void:
	_diag(img, 3, 3, 12, 12, Color(0.90, 0.45, 0.35, 1.0))
	_diag(img, 3, 4, 11, 12, Color(0.90, 0.45, 0.35, 1.0))
	_diag(img, 4, 3, 12, 11, Color(0.90, 0.45, 0.35, 1.0))
	_diag(img, 12, 3, 3, 12, Color(0.90, 0.45, 0.35, 1.0))
	_diag(img, 12, 4, 4, 12, Color(0.90, 0.45, 0.35, 1.0))
	_diag(img, 11, 3, 3, 11, Color(0.90, 0.45, 0.35, 1.0))


static func _balcony(img: Image) -> void:
	# Railing: baseline + evenly spaced vertical bars
	_hline(img, 2, 13, 12, INK)
	var x := 3
	while x <= 12:
		_vline(img, x, 4, 12, INK)
		x += 3


static func _bathroom(img: Image) -> void:
	# Droplet
	_diag(img, 8, 2, 4, 9, INK)
	_diag(img, 8, 2, 12, 9, INK)
	_rect_outline(img, 4, 9, 12, 13, INK)


static func _window(img: Image) -> void:
	_rect_outline(img, 2, 2, 13, 13, INK)
	_vline(img, 7, 2, 13, INK)
	_hline(img, 2, 13, 7, INK)


static func _door(img: Image) -> void:
	_rect_outline(img, 4, 2, 11, 13, INK)
	img.set_pixel(9, 8, INK)
	img.set_pixel(9, 9, INK)


static func _rail(img: Image) -> void:
	_hline(img, 2, 13, 6, INK)
	_hline(img, 2, 13, 9, INK)
	var x := 2
	while x <= 13:
		img.set_pixel(x, 7, INK)
		img.set_pixel(x, 8, INK)
		x += 3


static func _reveal(img: Image) -> void:
	# Eye shape
	_diag(img, 2, 8, 8, 4, INK)
	_diag(img, 8, 4, 14, 8, INK)
	_diag(img, 2, 8, 8, 12, INK)
	_diag(img, 8, 12, 14, 8, INK)
	_fill_rect(img, 7, 7, 9, 9, INK)


static func _pipe(img: Image, col: Color) -> void:
	_hline(img, 2, 13, 7, col, 2)
	for x in [4, 8, 12]:
		img.set_pixel(x, 5, col)
		img.set_pixel(x, 10, col)
