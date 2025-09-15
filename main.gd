extends Node

const LOCALAUDIO_PREFAB = preload("res://mods/BlueberryWolfi.ReelChat/Scenes/localAudio.tscn")
const REMOTE_AUDIO_PREFAB = preload("res://mods/BlueberryWolfi.ReelChat/Scenes/remoteAudio.tscn")
const OPUS_VOICE_CHAT = preload("res://mods/BlueberryWolfi.ReelChat/OpusVoiceChat.gd")
const SAVE_FILENAME = "user://webfishing_reelchat_volumes.save"

var prefabType = LOCALAUDIO_PREFAB
signal reelchat_voice(steamid, data)

var volumes = {}
var PlayerAPI
var CHANNEL = 36
var opus_voice_chat = null
var connected_players = {}  # Track players who have exchanged greetings
var greeting_sent = false   # Track if we've sent our initial greeting
var packet_timer: Timer = null
var packet_check_interval: float = 0.005  # 5ms interval

func read_packets():
	if Network.PLAYING_OFFLINE:
		return

	for i in 32:
		var packets = Steam.receiveMessagesOnChannel(CHANNEL, 8)
		if packets.size() == 0:
			break

		for packet in packets:
			if packet["payload"].size() > 0:
				var sender = packet["identity"]
				var data = bytes2var(packet.payload.decompress_dynamic(-1, Network.COMPRESSION_TYPE))
				if data.has("type"):
					handle_packet(sender, data)

func _ready():
	PlayerAPI = get_tree().root.get_node("BlueberryWolfiAPIs/PlayerAPI")
	PlayerAPI.connect("_player_added", self, "init_playeraudio")
	PlayerAPI.connect("_player_added", self, "_on_player_added")

	opus_voice_chat = OPUS_VOICE_CHAT.new()
	add_child(opus_voice_chat)

	var save = File.new()
	if save.file_exists(SAVE_FILENAME):
		save.open(SAVE_FILENAME, File.READ)
		volumes = save.get_var()
		save.close()
	else:
		save.open(SAVE_FILENAME, File.WRITE)
		save.store_var(volumes)
		save.close()

	# Wait for opus to be ready before setting up timers
	yield(get_tree().create_timer(0.1), "timeout")
	_setup_packet_timer()

	# Send greeting packet when we join a lobby
	yield(get_tree().create_timer(1.0), "timeout") # Wait a bit for lobby to initialize
	send_greeting_packet()

# Removed frame-dependent packet processing
func _setup_packet_timer():
	# Safety check - don't create timer if one already exists
	if packet_timer != null:
		return

	# Get interval from opus voice chat configuration with fallback
	if opus_voice_chat and opus_voice_chat.has_method("get_packet_timer_interval"):
		packet_check_interval = opus_voice_chat.get_packet_timer_interval() / 1000.0
	else:
		packet_check_interval = 0.005  # 5ms fallback

	# Create timer with error handling
	packet_timer = Timer.new()
	if packet_timer == null:
		print("ReelChat ERROR: Failed to create packet timer")
		return

	packet_timer.wait_time = packet_check_interval
	packet_timer.autostart = false  # Start manually after setup

	# Connect with error handling
	if not packet_timer.is_connected("timeout", self, "_on_packet_timer_timeout"):
		packet_timer.connect("timeout", self, "_on_packet_timer_timeout")

	add_child(packet_timer)

	# Start timer after everything is set up
	packet_timer.start()
	print("ReelChat: Packet timer initialized with ", packet_check_interval * 1000, "ms intervals")

func _on_packet_timer_timeout():
	if not is_inside_tree():
		return

	# Only process packets if we're actually in a lobby
	if Network.STEAM_LOBBY_ID > 0:
		read_packets()
		cleanup_disconnected_players()

func set_packet_check_interval(interval_ms: float):
	"""Set packet check interval in milliseconds (default: 5ms)"""
	if opus_voice_chat:
		opus_voice_chat.set_packet_timer_interval(interval_ms)
	packet_check_interval = interval_ms / 1000.0
	if packet_timer:
		packet_timer.wait_time = packet_check_interval
		print("ReelChat: Packet check interval updated to ", interval_ms, "ms")

func update_all_voice_timers(voice_interval_ms: float):
	"""Update voice timer intervals for all player audio instances"""
	if opus_voice_chat:
		opus_voice_chat.set_voice_timer_interval(voice_interval_ms)

	# Update all existing player audio instances
	for player in PlayerAPI.players:
		var audio_instance = player.get_node("ReelchatAudio")
		if audio_instance and audio_instance.has_method("set_voice_check_interval"):
			audio_instance.set_voice_check_interval(voice_interval_ms)

func get_timer_status() -> Dictionary:
	"""Get current timer status for debugging"""
	var status = {}
	if opus_voice_chat:
		status = opus_voice_chat.get_timer_info()
	status["packet_timer_active"] = packet_timer != null and not packet_timer.is_stopped()
	return status

func _exit_tree():
	if packet_timer:
		packet_timer.queue_free()
		packet_timer = null

func init_playeraudio(player):
	if player.name == "player":
		prefabType = LOCALAUDIO_PREFAB
	elif player.name.begins_with("@player@"):
		prefabType = REMOTE_AUDIO_PREFAB

	var playeraudioInstance = prefabType.instance()

	if playeraudioInstance.has_method("set_opus_voice_chat"):
		playeraudioInstance.set_opus_voice_chat(opus_voice_chat)

	if !volumes.has(player):
		volumes[player] = 1.0

	var voice: AudioStreamPlayer3D = playeraudioInstance.get_node("Voice")
	var volume_value = volumes[player] - 1.0
	voice.unit_db = 36.0 * volume_value if volume_value > 0 else volume_value * 80.0

	player.add_child(playeraudioInstance)

func handle_packet(sender, data):
	var packet_type = data.get("type", "").trim_prefix("reelchat_")

	match packet_type:
		"greeting":
			handle_greeting_packet(sender, data)
		"greeting_response":
			handle_greeting_response(sender, data)
		_:
			# Only emit voice packets if we have a connection with this player
			if connected_players.has(sender) or packet_type == "voice_packet":
				emit_signal("reelchat_voice", sender, data)

func send_greeting_packet():
	if Network.PLAYING_OFFLINE or Network.STEAM_LOBBY_ID <= 0:
		return

	greeting_sent = true
	var greeting_data = {
		"steamid": Network.STEAM_ID,
		"type": "reelchat_greeting",
		"voice_data": {
			"player_name": Steam.getPersonaName(),
			"timestamp": OS.get_unix_time()
		}
	}

	# Send greeting to all players in lobby
	Network._send_P2P_Packet(greeting_data, "all", 2, CHANNEL)
	print("ReelChat: Sent greeting packet to lobby")

func handle_greeting_packet(sender, data):
	if sender == Network.STEAM_ID:
		return  # Ignore our own greeting

	print("ReelChat: Received greeting from player ", sender)
	connected_players[sender] = {
		"name": data.voice_data.get("player_name", "Unknown"),
		"timestamp": data.voice_data.get("timestamp", OS.get_unix_time())
	}

	# Send greeting response
	send_greeting_response(sender)

func send_greeting_response(target_steamid):
	var response_data = {
		"steamid": Network.STEAM_ID,
		"type": "reelchat_greeting_response",
		"voice_data": {
			"player_name": Steam.getPersonaName(),
			"timestamp": OS.get_unix_time()
		}
	}

	Network._send_P2P_Packet(response_data, int(target_steamid), 2, CHANNEL)
	print("ReelChat: Sent greeting response to player ", target_steamid)

func handle_greeting_response(sender, data):
	if sender == Network.STEAM_ID:
		return  # Ignore our own response

	print("ReelChat: Received greeting response from player ", sender)
	connected_players[sender] = {
		"name": data.voice_data.get("player_name", "Unknown"),
		"timestamp": data.voice_data.get("timestamp", OS.get_unix_time())
	}

func is_player_connected(steamid):
	return connected_players.has(steamid)

func cleanup_disconnected_players():
	# Remove players who are no longer in the lobby
	var current_lobby_members = Network.WEB_LOBBY_MEMBERS
	var players_to_remove = []

	for steamid in connected_players.keys():
		if not current_lobby_members.has(steamid):
			players_to_remove.append(steamid)

	for steamid in players_to_remove:
		connected_players.erase(steamid)
		print("ReelChat: Removed disconnected player ", steamid)

func get_connected_players_count():
	return connected_players.size()

func reset_connections():
	connected_players.clear()
	greeting_sent = false
	print("ReelChat: Reset all player connections")

func _on_player_added(player):
	# When a new player is added, send a greeting if we haven't already
	if not greeting_sent and Network.STEAM_LOBBY_ID > 0:
		yield(get_tree().create_timer(0.5), "timeout")  # Small delay
		send_greeting_packet()
