extends Node

const SLIDER_PREFAB = preload("res://mods/BlueberryWolfi.ReelChat/Scenes/sliderPanel.tscn")

onready var Reelchat = get_tree().root.get_node("BlueberryWolfiReelChat")
onready var PlayerAPI = get_tree().root.get_node("BlueberryWolfiAPIs/PlayerAPI")

# Players tab container
onready var slider_container: VBoxContainer = $TabContainer/Players/ScrollContainer/VBoxContainer

# Settings tab controls
onready var loopback_check: CheckBox = $TabContainer/Settings/VBoxContainer/LoopbackCheck
onready var pitch_slider: HSlider = $TabContainer/Settings/VBoxContainer/HBox/PitchSlider
onready var pitch_value: Label = $TabContainer/Settings/VBoxContainer/HBox/PitchValue

func _get_local_player_id() -> int:
	if PlayerAPI and PlayerAPI.local_player:
		return int(PlayerAPI.local_player.owner_id)
	return int(Network.STEAM_ID)

func _get_local_audio_node() -> Node:
	if PlayerAPI and PlayerAPI.local_player:
		return PlayerAPI.local_player.get_node_or_null("ReelchatAudio")
	return null

func _get_local_voice_node() -> AudioStreamPlayer3D:
	var local_audio = _get_local_audio_node()
	if local_audio:
		return local_audio.get_node_or_null("Voice")
	return null

func add_slider_with_name(id: int, name: String):
	var player: Node = PlayerAPI.get_player_from_steamid(str(id))
	if !player:
		return

	var instance = SLIDER_PREFAB.instance()
	var name_label: RichTextLabel = instance.get_node("NameLabel")

	slider_container.add_child(instance)
	name_label.text = name
	instance.steam_id = id
	instance.voice = player.get_node("ReelchatAudio/Voice")

	if !Reelchat.volumes.has(id):
		Reelchat.volumes[id] = 1.0
	instance.slider.value = Reelchat.volumes[id]
	instance.name = "slider" + str(id)

func _ready():
	# Initialize settings controls from current state
	var local_audio = _get_local_audio_node()
	var has_loopback_now: bool = false
	if local_audio:
		has_loopback_now = local_audio.has_loopback
	loopback_check.pressed = has_loopback_now

	var local_voice = _get_local_voice_node()
	if local_voice:
		pitch_slider.value = local_voice.pitch_scale
		pitch_value.text = str(round(pitch_slider.value * 100.0) / 100.0) + "x"
	else:
		pitch_slider.value = 1.0
		pitch_value.text = "1.0x"

	# Populate players list
	var local_id = _get_local_player_id()
	for player in Network.WEB_LOBBY_MEMBERS:
		if player != local_id:
			add_slider_with_name(player, Steam.getFriendPersonaName(player))

	# Add local slider if loopback is enabled
	if has_loopback_now:
		_add_or_update_local_slider(local_id)

func _add_or_update_local_slider(local_id: int):
	var node_name = "slider" + str(local_id)
	var existing = slider_container.get_node_or_null(node_name)
	if existing:
		return
	# Prefer showing "You" for the local user
	add_slider_with_name(local_id, "You")

func _remove_local_slider(local_id: int):
	var node_name = "slider" + str(local_id)
	var existing = slider_container.get_node_or_null(node_name)
	if existing:
		existing.queue_free()

func _on_LoopbackCheck_toggled(pressed: bool):
	var local_audio = _get_local_audio_node()
	if local_audio and local_audio.has("has_loopback"):
		local_audio.has_loopback = pressed
	var local_id = _get_local_player_id()
	if pressed:
		_add_or_update_local_slider(local_id)
	else:
		_remove_local_slider(local_id)

func _on_PitchSlider_value_changed(value: float):
	pitch_value.text = str(round(value * 100.0) / 100.0) + "x"
	var local_voice = _get_local_voice_node()
	if local_voice:
		# Adjust local playback pitch (affects how you hear yourself)
		local_voice.pitch_scale = value
