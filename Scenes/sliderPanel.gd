extends Node

onready var slider: HSlider = $HSlider
onready var line: LineEdit = $LineEdit
onready var Reelchat = get_tree().root.get_node("BlueberryWolfiReelChat")

var steam_id
var voice: AudioStreamPlayer3D

func _on_text_entered(new_text: String):
	var new_value = float(new_text) if new_text.is_valid_float() else Reelchat.volumes[steam_id]
	slider.value = new_value

func _on_slider_value_changed(value):
	line.text = str(value)
	Reelchat.volumes[steam_id] = value
	var volume_value = value - 1.0
	voice.unit_db = 36.0 * volume_value if volume_value > 0 else volume_value * 80.0
