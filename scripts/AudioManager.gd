extends Node

# All CC0 (public domain) — Kenney's "Interface Sounds" and "Casino Audio"
# packs; see assets/audio/LICENSE_kenney_*.txt. Paths are checked with
# ResourceLoader.exists() so a missing file fails silently instead of erroring.
const SOUNDS := {
	"click":        "res://assets/audio/click.ogg",
	"place":        "res://assets/audio/place.ogg",
	"rotate":       "res://assets/audio/rotate.ogg",
	"error":        "res://assets/audio/error.ogg",
	"sell":         "res://assets/audio/sell.ogg",
	"success":      "res://assets/audio/success.ogg",
	"demolish":     "res://assets/audio/demolish.ogg",
	# Previously unused files from the same CC0 packs — dedicated to the
	# rail attach/detach cue specifically, instead of reusing "place"/
	# "click" (both already mean something else elsewhere: buying/placing
	# furniture, generic UI clicks), so this interaction gets its own
	# distinct, consistent sound identity.
	"rail_attach":  "res://assets/audio/place_furniture.wav",
	"rail_detach":  "res://assets/audio/ui_click.wav",
	# The game's own (tools/gen_sounds.py), for what the packs had nothing for.
	"fold":         "res://assets/audio/fold.wav",      # folding or unfolding a piece
	"whoosh":       "res://assets/audio/whoosh.wav",    # stepping into or out of a box
	"fax":          "res://assets/audio/fax.wav",       # a sheet printing: an application coming in, the map's fax (recorded; LICENSE_freesound_fax.txt)
	"grumble":      "res://assets/audio/grumble.wav",   # a tenant annoyed by a placement
	"happy":        "res://assets/audio/happy.wav",     # a tenant enjoying a need that's met
	"huh":          "res://assets/audio/huh.wav",       # a tenant finding a need unmet
}
const AMBIENT_PATH := "res://assets/audio/ambient_rain.wav"

# Each sound's gain, so they sit at a common loudness: the files came from
# different packs at very different levels (measured as the loudest 50 ms
# of each). A cue the player hears constantly (click, an error when a piece
# won't fit) stays below the rare, rewarding ones (success, a happy tenant).
const GAIN_DB := {
	"click": 3.0,           # -23.5 dB as recorded, nearly lost under the rest
	"place": -1.0,
	"rotate": -2.0,
	"error": -4.5,          # clipped as recorded, and the loudest thing heard often
	"sell": 7.0,            # -23 dB as recorded
	"success": -5.5,        # still the loudest, but no longer 7 dB over everything
	"demolish": -1.0,
	"rail_attach": 10.0,    # -30 dB as recorded
	"rail_detach": -4.0,
	"fold": -3.0,
	"whoosh": 1.0,
	"fax": -5.0,
	"grumble": -2.5,
	"happy": -1.0,
	"huh": -2.5,
}
# Sounds heard over and over get a slightly different pitch each time, so a
# run of them doesn't sound mechanical.
const PITCH_JITTER := {"click": 0.05, "place": 0.06, "rotate": 0.05, "fold": 0.04, "error": 0.03}

const SFX_BUS     := "SFX"
const MUSIC_BUS   := "Music"
const POOL_SIZE   := 6

var _pool:        Array[AudioStreamPlayer] = []
var _pool_next:   int = 0
var _ambient:     AudioStreamPlayer
var _streams:     Dictionary = {}   # key -> preloaded AudioStream, cached on first use
var _rng := RandomNumberGenerator.new()   # its own, so pitch jitter never shifts the game's random sequence

var sfx_volume:   float = 1.0   # linear 0..1, persisted via GameState
var music_volume: float = 0.7
var master_volume: float = 1.0
var muted:        bool  = false


func _ready() -> void:
	_ensure_bus(SFX_BUS)
	_ensure_bus(MUSIC_BUS)

	for i in range(POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		_pool.append(p)

	_ambient = AudioStreamPlayer.new()
	_ambient.bus = MUSIC_BUS
	add_child(_ambient)

	set_sfx_volume(sfx_volume)
	set_music_volume(music_volume)
	set_master_volume(master_volume)
	set_muted(muted)


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")


# `cut`: stop this sound if it is still playing from before, rather than
# layering a second one over it (a fax printing again before the last one
# finished).
func play(key: String, cut := false) -> void:
	var path: String = SOUNDS.get(key, "")
	if path == "" or not ResourceLoader.exists(path):
		return
	if not _streams.has(key):
		_streams[key] = load(path)
	if cut:
		for p in _pool:
			if p.playing and p.stream == _streams[key]:
				p.stop()
	var player := _pool[_pool_next]
	_pool_next = (_pool_next + 1) % POOL_SIZE
	player.stream = _streams[key]
	player.volume_db = GAIN_DB.get(key, 0.0) as float
	var jitter := PITCH_JITTER.get(key, 0.0) as float
	player.pitch_scale = 1.0 + _rng.randf_range(-jitter, jitter)
	player.play()


# Linear 0..1 → dB (0 = silent, 1 = 0 dB / unity gain)
func _linear_to_db(v: float) -> float:
	return linear_to_db(clampf(v, 0.0, 1.0)) if v > 0.0 else -80.0


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	var idx := AudioServer.get_bus_index(SFX_BUS)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, _linear_to_db(sfx_volume))


func set_music_volume(v: float) -> void:
	music_volume = clampf(v, 0.0, 1.0)
	var idx := AudioServer.get_bus_index(MUSIC_BUS)
	if idx != -1:
		AudioServer.set_bus_volume_db(idx, _linear_to_db(music_volume))


# Master sits above both buses, so it scales everything without disturbing
# the SFX/Music balance the player set.
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	AudioServer.set_bus_volume_db(0, _linear_to_db(master_volume))


# Mute is separate from the sliders so unmuting returns to the same levels.
func set_muted(on: bool) -> void:
	muted = on
	AudioServer.set_bus_mute(0, on)


func _start_ambient() -> void:
	if not ResourceLoader.exists(AMBIENT_PATH):
		return
	_ambient.stream = load(AMBIENT_PATH)
	_ambient.play()


func stop_ambient() -> void:
	_ambient.stop()
