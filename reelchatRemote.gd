extends Node

var current_sample_rate: int = 48000
var use_optimal_sample_rate: bool = false
var local_voice_generator: AudioStreamGenerator = null
var local_voice_buffer: PoolByteArray = PoolByteArray()
var opus_voice_chat = null

onready var PlayerAPI = get_tree().root.get_node("BlueberryWolfiAPIs/PlayerAPI")

func _receive_net(steamid, data):
	var steamid_int = int(steamid)
	if PlayerData.players_muted.has(steamid_int):
		return
	var type: String = (data["type"]).trim_prefix("reelchat_")
	match type:
		"voice_packet":
			if int(get_parent().owner_id) == steamid_int:
				process_voice_data(data.voice_data, steamid_int)
		"greeting", "greeting_response":
			# These are handled by the main node, but you can log them here if needed
			pass

func _ready():
	get_tree().root.get_node("BlueberryWolfiReelChat").connect("reelchat_voice", self, "_receive_net")
	local_voice_generator = AudioStreamGenerator.new()
	local_voice_generator.mix_rate = current_sample_rate
	$Voice.stream = local_voice_generator
	$Voice.play()

func set_opus_voice_chat(opus_ref):
	opus_voice_chat = opus_ref

func get_sample_rate():
	current_sample_rate = Steam.getVoiceOptimalSampleRate() if use_optimal_sample_rate else 48000

func process_voice_data(voice_data: Dictionary, steamid: int):
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
