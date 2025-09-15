extends Node

const MUTE_ICON = preload("res://mods/BlueberryWolfi.ReelChat/Assets/mic_mute.png")
const UNMUTE_ICON = preload("res://mods/BlueberryWolfi.ReelChat/Assets/mic_unmute.png")
const MUTE_SOUND = preload("res://mods/BlueberryWolfi.ReelChat/Assets/mic_mute.ogg")
const UNMUTE_SOUND = preload("res://mods/BlueberryWolfi.ReelChat/Assets/mic_unmute.ogg")
const CHANNEL = 36
const SAVE_FILENAME = "user://webfishing_reelchat_volumes.save"

var steam_id = Network.STEAM_ID
var current_sample_rate: int = 48000
var has_loopback: bool = true
var is_voice_toggled: bool = false
var use_optimal_sample_rate: bool = false
var local_voice_generator: AudioStreamGenerator = null
var local_voice_buffer: PoolByteArray = PoolByteArray()
var slider_window_opened: bool = false
var slider_window_scene = preload("res://mods/BlueberryWolfi.ReelChat/Scenes/volumeSliderWindow.tscn")
var slider_window_instance: Node = null
var current_ui
var mic_icon
var mic_sound
var tween
var opus_voice_chat = null
var voice_timer: Timer = null
var voice_check_interval: float = 0.01  # 10ms intervals for smooth audio (100Hz)
var debug_voice_checks: bool = false  # Set to true for debugging timer performance

onready var PlayerAPI = get_tree().root.get_node("BlueberryWolfiAPIs/PlayerAPI")
onready var KeybindAPI = get_tree().root.get_node("BlueberryWolfiAPIs/KeybindsAPI")
onready var Reelchat = get_tree().root.get_node("BlueberryWolfiReelChat")
onready var entities = get_tree().current_scene.get_node("Viewport/main/entities")

func _ready():
	local_voice_generator = AudioStreamGenerator.new()
	local_voice_generator.mix_rate = current_sample_rate
	$Voice.stream = local_voice_generator
	$Voice.play()

	yield(get_tree().create_timer(0.5), "timeout")
	var toggle_mic_signal = KeybindAPI.register_keybind({
		"action_name": "toggle_mic",
		"title": "Toggle Mic",
		"key": KEY_F,
	})

	var pushtalk_mic_signal = KeybindAPI.register_keybind({
		"action_name": "toggle_ptt",
		"title": "Toggle Push to Talk",
		"key": KEY_T,
	})

	var open_slider_window_signal = KeybindAPI.register_keybind({
		"action_name": "open_slider_window",
		"title": "Open Reelchat Volume Control Window",
		"key": KEY_L,
	})

	KeybindAPI.connect(toggle_mic_signal, self, "_on_toggle_voice_pressed")
	KeybindAPI.connect(pushtalk_mic_signal, self, "_on_to_talk_button_down")
	KeybindAPI.connect(pushtalk_mic_signal + "_up", self, "_on_to_talk_button_up")
	KeybindAPI.connect(open_slider_window_signal, self, "_on_open_slider_window_pressed")

	_init_ui()
	_setup_voice_timer()

func set_opus_voice_chat(opus_ref):
	opus_voice_chat = opus_ref

func _setup_voice_timer():
	# Safety check - don't create timer if one already exists
	if voice_timer != null:
		return

	# Get interval from opus voice chat configuration with fallback
	if opus_voice_chat and opus_voice_chat.has_method("get_voice_timer_interval"):
		voice_check_interval = opus_voice_chat.get_voice_timer_interval() / 1000.0
	else:
		voice_check_interval = 0.01  # 10ms fallback

	voice_timer = Timer.new()
	voice_timer.wait_time = voice_check_interval
	voice_timer.autostart = false  # Start manually after setup

	# Connect with error handling
	if not voice_timer.is_connected("timeout", self, "_on_voice_timer_timeout"):
		voice_timer.connect("timeout", self, "_on_voice_timer_timeout")

	add_child(voice_timer)

	# Start timer after everything is set up
	voice_timer.start()
	print("ReelChat: Voice timer initialized with ", voice_check_interval * 1000, "ms intervals")

func _on_voice_timer_timeout():
	# Safety checks to prevent crashes
	if not is_inside_tree() or not is_voice_toggled:
		return

	if debug_voice_checks:
		print("ReelChat: Voice check at ", OS.get_ticks_msec())

	check_for_voice()

func set_voice_check_interval(interval_ms: float):
	"""Set voice check interval in milliseconds (default: 10ms)"""
	voice_check_interval = interval_ms / 1000.0
	if voice_timer:
		voice_timer.wait_time = voice_check_interval
		print("ReelChat: Voice check interval updated to ", interval_ms, "ms")

func _exit_tree():
	if voice_timer:
		if voice_timer.is_connected("timeout", self, "_on_voice_timer_timeout"):
			voice_timer.disconnect("timeout", self, "_on_voice_timer_timeout")
		voice_timer.stop()
		voice_timer.queue_free()
		voice_timer = null

func _init_ui():
	current_ui = preload("res://mods/BlueberryWolfi.ReelChat/Scenes/reelchatUI.tscn").instance()
	get_tree().root.get_node("playerhud/main/in_game").add_child(current_ui)
	mic_icon = current_ui.get_node("mic_icon")
	mic_sound = current_ui.get_node("mic_sound")
	tween = Tween.new()
	current_ui.add_child(tween)

func _ui_tween_size(ui, factor):
	tween.interpolate_property(
		ui,
		"rect_scale",
		mic_icon.rect_scale,
		mic_icon.rect_scale * factor,
		1.0,
		Tween.TRANS_ELASTIC,
		Tween.EASE_OUT
	)

# Removed frame-dependent voice processing

func _send_net(type: String, data: Dictionary = {}, target = "all"):
	var complete_data: Dictionary = { "steamid": Network.STEAM_ID, "type": ("reelchat_%s" % type), "voice_data": data}

	if target in ["all", "steamlobby"]:
		emit_signal("reelchat_voice", Network.STEAM_ID, complete_data)

		# For voice packets, only send to connected players
		if type == "voice_packet":
			_send_to_connected_players(complete_data)
		else:
			Network._send_P2P_Packet(complete_data, target, 2, CHANNEL)
	elif int(target) == Network.STEAM_ID:
		emit_signal("reelchat_voice", target, complete_data)
	else:
		Network._send_P2P_Packet(complete_data, int(target), 2, CHANNEL)

func _send_to_connected_players(data: Dictionary):
	var main_node = get_tree().root.get_node("BlueberryWolfiReelChat")
	if not main_node:
		return

	# If no connected players, fall back to sending to all
	# if main_node.connected_players.size() == 0:
	#	Network._send_P2P_Packet(data, "all", 2, CHANNEL)
	#	return

	# Send to each connected player individually
	for steamid in main_node.connected_players.keys():
		Network._send_P2P_Packet(data, int(steamid), 2, CHANNEL)

func _on_loopback_pressed():
	has_loopback = not has_loopback

func _on_optimal_pressed():
	use_optimal_sample_rate = not use_optimal_sample_rate

func is_busy():
	if not PlayerAPI: return true
	if not is_instance_valid(PlayerAPI.local_player): return true
	if PlayerAPI.local_player.busy: return true
	return false

func _on_toggle_voice_pressed():
	if is_busy(): return
	is_voice_toggled = not is_voice_toggled
	change_voice_status()

func _on_to_talk_button_down():
	if is_busy(): return
	is_voice_toggled = true
	change_voice_status()

func _on_to_talk_button_up():
	if is_busy(): return
	is_voice_toggled = false
	change_voice_status()

func change_voice_status():
	Steam.setInGameVoiceSpeaking(Network.STEAM_ID, is_voice_toggled)

	if is_voice_toggled:
		mic_icon.texture = UNMUTE_ICON
		mic_sound.stream = UNMUTE_SOUND
		mic_sound.play()
		_ui_tween_size(mic_icon, 5)
		Steam.startVoiceRecording()
	else:
		mic_icon.texture = MUTE_ICON
		mic_sound.stream = MUTE_SOUND
		mic_sound.play()
		_ui_tween_size(mic_icon, 1)
		Steam.stopVoiceRecording()

func check_for_voice():
	var available_voice: Dictionary = Steam.getAvailableVoice()
	if available_voice["result"] == Steam.VOICE_RESULT_OK and available_voice["buffer"] > 0:
		var voice_data: Dictionary = Steam.getVoice()
		if voice_data["result"] == Steam.VOICE_RESULT_OK and voice_data["written"]:
			if opus_voice_chat and opus_voice_chat.is_ready():
				var opus_encoded = opus_voice_chat.encode_steam_voice(voice_data)
				if opus_encoded.size() > 0:
					var opus_voice_data = {
						"buffer": opus_encoded,
						"written": opus_encoded.size(),
						"is_opus": true
					}
					_send_net("voice_packet", opus_voice_data, "all")
					if has_loopback:
						process_voice_data(opus_voice_data)


func get_sample_rate():
	current_sample_rate = Steam.getVoiceOptimalSampleRate() if use_optimal_sample_rate else 48000

func process_voice_data(voice_data: Dictionary):
	get_sample_rate()

	var decompressed_voice: Dictionary
	var is_opus = voice_data.get("is_opus", false)

	if is_opus and opus_voice_chat and opus_voice_chat.is_ready():
		decompressed_voice = opus_voice_chat.decode_opus_voice(voice_data["buffer"])
	else:
		decompressed_voice = Steam.decompressVoice(voice_data["buffer"], voice_data["written"], current_sample_rate)

	if decompressed_voice["result"] == Steam.VOICE_RESULT_OK and decompressed_voice["size"] > 0:
		local_voice_buffer = decompressed_voice["uncompressed"]
		var samples_to_add: int = int(decompressed_voice["size"] / 2)
		var buffer: PoolVector2Array = PoolVector2Array()

		for i in range(samples_to_add):
			var sample_int: int = int(local_voice_buffer[i * 2]) | (int(local_voice_buffer[i * 2 + 1]) << 8)
			if sample_int >= 32768:
				sample_int -= 65536
			var sample_float: float = sample_int / 32768.0
			buffer.append(Vector2(sample_float, sample_float))

		var playback = $Voice.get_stream_playback() as AudioStreamGeneratorPlayback
		if playback.can_push_buffer(buffer.size()):
			playback.push_buffer(buffer)

func _on_open_slider_window_pressed():
	if slider_window_opened:
		var save = File.new()
		save.open(SAVE_FILENAME, File.WRITE)
		save.store_var(Reelchat.volumes)
		save.close()
		slider_window_instance.queue_free()
		slider_window_instance = null
	else:
		var player_hud = get_node_or_null("/root/playerhud")
		var main_control: Control = player_hud.get_node_or_null("main")

		if main_control and main_control.get_focus_owner():
			return

		slider_window_instance = slider_window_scene.instance()
		player_hud.add_child(slider_window_instance)

	slider_window_opened = !slider_window_opened

func get_connection_status():
	var main_node = get_tree().root.get_node("BlueberryWolfiReelChat")
	if not main_node:
		return "ReelChat main node not found"

	var status = "ReelChat Connections:\n"
	status += "Connected players: %d\n" % main_node.connected_players.size()

	for steamid in main_node.connected_players.keys():
		var player_info = main_node.connected_players[steamid]
		status += "- %s (%s)\n" % [player_info.get("name", "Unknown"), steamid]

	return status
