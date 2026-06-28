extends Node

# Drop your .wav or .ogg files in assets/audio/ and update the paths below.
# All paths are checked with ResourceLoader.exists() so missing files fail silently.
const SOUNDS := {
	"click":    "res://assets/audio/ui_click.wav",
	"place":    "res://assets/audio/place_furniture.wav",
	"rotate":   "res://assets/audio/rotate.wav",
	"error":    "res://assets/audio/error.wav",
	"sell":     "res://assets/audio/sell.wav",
	"success":  "res://assets/audio/success.wav",
	"demolish": "res://assets/audio/demolish.wav",
}
const AMBIENT_PATH := "res://assets/audio/ambient_rain.wav"
const AMBIENT_DB   := -18.0

var _sfx:     AudioStreamPlayer
var _ambient: AudioStreamPlayer


func _ready() -> void:
	_sfx = AudioStreamPlayer.new()
	add_child(_sfx)
	_ambient = AudioStreamPlayer.new()
	add_child(_ambient)


func play(_key: String) -> void:
	pass  # audio disabled


func set_sfx_volume(db: float) -> void:
	_sfx.volume_db = db


func set_ambient_volume(db: float) -> void:
	_ambient.volume_db = db


func _start_ambient() -> void:
	if not ResourceLoader.exists(AMBIENT_PATH):
		return
	_ambient.stream = load(AMBIENT_PATH)
	_ambient.play()
