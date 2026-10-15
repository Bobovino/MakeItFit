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
	"fax":          "res://assets/audio/fax.wav",       # the rental application coming in
	"grumble":      "res://assets/audio/grumble.wav",   # a tenant annoyed by a placement
	"happy":        "res://assets/audio/happy.wav",     # a tenant enjoying a need that's met
	"huh":          "res://assets/audio/huh.wav",       # a tenant finding a need unmet
}
const AMBIENT_PATH := "res://assets/audio/ambient_rain.wav"

const SFX_BUS     := "SFX"
const MUSIC_BUS   := "Music"
const POOL_SIZE   := 6

var _pool:        Array[AudioStreamPlayer] = []
var _pool_next:   int = 0
var _ambient:     AudioStreamPlayer
var _streams:     Dictionary = {}   # key -> preloaded AudioStream, cached on first use

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


func play(key: String) -> void:
	var path: String = SOUNDS.get(key, "")
	if path == "" or not ResourceLoader.exists(path):
		return
	if not _streams.has(key):
		_streams[key] = load(path)
	var player := _pool[_pool_next]
	_pool_next = (_pool_next + 1) % POOL_SIZE
	player.stream = _streams[key]
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


# ── Music ────────────────────────────────────────────────────────────────────
# CC0 loops by Juhani Junkala (assets/music/LICENSE_juhani_junkala_CC0.txt).
# The project map has its own theme; a level plays the rest, shuffled, one
# after another. Asking for what is already playing changes nothing, so
# restarting a level or stepping into a box doesn't restart the track.
const MUSIC := {
	"map":   ["res://assets/music/calm1_a_place_i_call_home.ogg"],
	"level": ["res://assets/music/calm2_childhood_friends.ogg", "res://assets/music/calm3_peaceful_days.ogg",
		"res://assets/music/calm4_sand_castles.ogg", "res://assets/music/calm5_summer_memories.ogg",
		"res://assets/music/calm6_innocence.ogg"],
}
const MUSIC_DB := -9.0          # under the effects: it's a backdrop
const MUSIC_FADE := 1.6

var _music_players: Array[AudioStreamPlayer] = []
var _music_active := 0          # which of the two players is the current one
var _music_set := ""
var _music_queue: Array = []
var _music_rng := RandomNumberGenerator.new()


func play_music(set_name: String) -> void:
	if set_name == _music_set or not MUSIC.has(set_name):
		return
	_music_set = set_name
	_music_queue.clear()
	_next_track()


func stop_music() -> void:
	_music_set = ""
	for p in _music_players:
		_fade(p, -80.0, MUSIC_FADE, true)


func _ensure_music_players() -> void:
	if not _music_players.is_empty():
		return
	_music_rng.randomize()
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.bus = MUSIC_BUS
		p.volume_db = -80.0
		add_child(p)
		p.finished.connect(func():
			if p == _music_players[_music_active] and _music_set != "":
				_next_track())
		_music_players.append(p)


# Crossfades from whatever plays now to the next track of the current set.
func _next_track() -> void:
	_ensure_music_players()
	if _music_queue.is_empty():
		_music_queue = (MUSIC[_music_set] as Array).duplicate()
		for i in range(_music_queue.size() - 1, 0, -1):
			var j := _music_rng.randi_range(0, i)
			var tmp = _music_queue[i]
			_music_queue[i] = _music_queue[j]
			_music_queue[j] = tmp
	var path: String = _music_queue.pop_front()
	if not ResourceLoader.exists(path):
		return
	var stream := load(path) as AudioStream
	if stream is AudioStreamOggVorbis:
		# A one-track set loops; a playlist moves on when a track ends.
		(stream as AudioStreamOggVorbis).loop = (MUSIC[_music_set] as Array).size() == 1
	var old := _music_players[_music_active]
	_music_active = 1 - _music_active
	var new := _music_players[_music_active]
	new.stream = stream
	new.volume_db = -40.0
	new.play()
	_fade(new, MUSIC_DB, MUSIC_FADE, false)
	if old.playing:
		_fade(old, -80.0, MUSIC_FADE, true)


func _fade(p: AudioStreamPlayer, to_db: float, time: float, stop_after: bool) -> void:
	var tw := create_tween()
	tw.tween_property(p, "volume_db", to_db, time)
	if stop_after:
		tw.tween_callback(p.stop)


func _start_ambient() -> void:
	if not ResourceLoader.exists(AMBIENT_PATH):
		return
	_ambient.stream = load(AMBIENT_PATH)
	_ambient.play()


func stop_ambient() -> void:
	_ambient.stop()
