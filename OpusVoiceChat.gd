extends Node

signal opus_ready
signal opus_error(error_message)

var _opus_node = null
var _is_initialized = false
var sample_rate: int = 48000
var frame_size: int = 960
var bitrate: int = 32000
var _sample_buffer = PoolRealArray()
var _max_buffer_size = 5760

# Timer configuration for frame-independent processing
var voice_timer_interval_ms: float = 10.0  # 10ms default for voice processing
var packet_timer_interval_ms: float = 5.0  # 5ms default for packet processing

func _ready():
	initialize_opus()

func initialize_opus() -> bool:
	var lib = GDNativeLibrary.new()
	var cfg = ConfigFile.new()
	cfg.set_value("entry", "Windows.64", "./GDWeave/mods/BlueberryWolfi.ReelChat/opus_rs.dll")
	lib.config_file = cfg

	var script = NativeScript.new()
	script.library = lib
	script.resource_name = "OpusCodec"
	script.set_class_name("OpusCodec")

	_opus_node = Node.new()
	add_child(_opus_node)
	_opus_node.set_script(script)

	if _opus_node == null:
		emit_signal("opus_error", "Failed to create Opus node")
		return false

	_opus_node.initialize(sample_rate, frame_size)
	_opus_node.set_bitrate(bitrate)
	_is_initialized = true
	emit_signal("opus_ready")
	return true

func encode_steam_voice(voice_data: Dictionary) -> PoolByteArray:
	if not _is_initialized or _opus_node == null:
		return PoolByteArray()

	var decompressed_voice = Steam.decompressVoice(voice_data["buffer"], voice_data["written"], sample_rate)
	if decompressed_voice["result"] != Steam.VOICE_RESULT_OK or decompressed_voice["size"] <= 0:
		return PoolByteArray()

	var raw_pcm = decompressed_voice["uncompressed"]
	var samples_count = int(decompressed_voice["size"] / 2)
	var pcm_samples = PoolRealArray()
	pcm_samples.resize(samples_count)

	for i in range(samples_count):
		var sample_int = int(raw_pcm[i * 2]) | (int(raw_pcm[i * 2 + 1]) << 8)
		if sample_int >= 32768:
			sample_int -= 65536
		pcm_samples[i] = sample_int / 32768.0

	_sample_buffer.append_array(pcm_samples)

	if _sample_buffer.size() >= 2880:
		var frame_to_encode = PoolRealArray()
		frame_to_encode.resize(2880)
		for i in range(2880):
			frame_to_encode[i] = _sample_buffer[i]

		var remaining_buffer = PoolRealArray()
		for i in range(2880, _sample_buffer.size()):
			remaining_buffer.append(_sample_buffer[i])
		_sample_buffer = remaining_buffer

		return _opus_node.encode_pcm(frame_to_encode)

	if _sample_buffer.size() > _max_buffer_size:
		var keep_samples = _sample_buffer.size() - 2880
		var new_buffer = PoolRealArray()
		for i in range(keep_samples, _sample_buffer.size()):
			new_buffer.append(_sample_buffer[i])
		_sample_buffer = new_buffer

	return PoolByteArray()

func decode_opus_voice(opus_data: PoolByteArray) -> Dictionary:
	if not _is_initialized or _opus_node == null:
		return {"result": -1, "size": 0}

	var pcm_samples = _opus_node.decode_opus(opus_data)
	if pcm_samples.size() == 0:
		return {"result": -1, "size": 0}

	var raw_pcm = PoolByteArray()
	raw_pcm.resize(pcm_samples.size() * 2)

	for i in range(pcm_samples.size()):
		var sample_int = int(clamp(pcm_samples[i], -1.0, 1.0) * 32767.0)
		if sample_int < 0:
			sample_int += 65536
		raw_pcm[i * 2] = sample_int & 0xFF
		raw_pcm[i * 2 + 1] = (sample_int >> 8) & 0xFF

	return {
		"result": Steam.VOICE_RESULT_OK,
		"uncompressed": raw_pcm,
		"size": raw_pcm.size()
	}

func is_ready() -> bool:
	return _is_initialized and _opus_node != null

# Timer configuration functions
func set_voice_timer_interval(interval_ms: float):
	"""Set voice processing timer interval in milliseconds"""
	voice_timer_interval_ms = clamp(interval_ms, 1.0, 100.0)  # Clamp between 1-100ms
	print("ReelChat: Voice timer interval set to ", voice_timer_interval_ms, "ms")

func set_packet_timer_interval(interval_ms: float):
	"""Set packet processing timer interval in milliseconds"""
	packet_timer_interval_ms = clamp(interval_ms, 1.0, 50.0)  # Clamp between 1-50ms
	print("ReelChat: Packet timer interval set to ", packet_timer_interval_ms, "ms")

func get_voice_timer_interval() -> float:
	return voice_timer_interval_ms

func get_packet_timer_interval() -> float:
	return packet_timer_interval_ms

func get_timer_info() -> Dictionary:
	"""Get current timer configuration info"""
	return {
		"voice_interval_ms": voice_timer_interval_ms,
		"packet_interval_ms": packet_timer_interval_ms,
		"voice_frequency_hz": 1000.0 / voice_timer_interval_ms,
		"packet_frequency_hz": 1000.0 / packet_timer_interval_ms
	}

func get_encoder_info() -> String:
	if not _is_initialized or _opus_node == null:
		return "Opus not initialized"
	return _opus_node.get_encoder_info()

func set_voice_bitrate(new_bitrate: int) -> bool:
	if not _is_initialized or _opus_node == null:
		return false
	bitrate = new_bitrate
	_opus_node.set_bitrate(bitrate)
	return true
