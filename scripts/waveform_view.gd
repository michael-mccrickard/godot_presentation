class_name WaveformView
extends Control
## Zoomable waveform + shot markers. Wheel = zoom at cursor, Shift+wheel = pan,
## click = seek (drag to scrub), drag a marker to retime that shot.

## Emitted when a marker was moved (so the presentation can be saved).
signal changed

const PEAKS_PER_SEC := 100
const GRAB_PX := 8.0

var player: PresentationPlayer
var peaks := PackedFloat32Array()
var view_start := 0.0
var view_len := 30.0

var _drag_idx := -1
var _scrubbing := false


func _ready() -> void:
	custom_minimum_size.y = 80
	mouse_filter = Control.MOUSE_FILTER_STOP


func rebuild() -> void:
	peaks = _build_peaks(player.audio.stream)
	view_start = 0.0
	view_len = 30.0 if player.audio.stream == null else clampf(player.total_length(), 1.0, 30.0)


## Scroll the view (if needed) so time t is visible, e.g. after a rewind or jump to end.
func reveal(t: float) -> void:
	if t < view_start or t > view_start + view_len:
		view_start = t - view_len * 0.1
	_clamp_view()


## Only uncompressed AudioStreamWAV exposes raw samples. Import WAVs with
## Compress Mode = Disabled (default); convert mp3/ogg to wav for the waveform.
func _build_peaks(stream: AudioStream) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not (stream is AudioStreamWAV):
		return out
	var wav := stream as AudioStreamWAV
	var bps := 0
	if wav.format == AudioStreamWAV.FORMAT_16_BITS:
		bps = 2
	elif wav.format == AudioStreamWAV.FORMAT_8_BITS:
		bps = 1
	else:
		push_warning("Waveform: unsupported WAV format (use uncompressed PCM).")
		return out
	var bytes := wav.data
	var frame_bytes := bps * (2 if wav.stereo else 1)
	var frames := bytes.size() / frame_bytes
	var bin_frames := maxi(wav.mix_rate / PEAKS_PER_SEC, 1)
	var n_bins := frames / bin_frames + 1
	var step := maxi(bin_frames / 32, 1)  # subsample inside each bin for speed
	out.resize(n_bins)
	for b in n_bins:
		var peak := 0.0
		var f := b * bin_frames
		var f_end := mini(f + bin_frames, frames)
		while f < f_end:
			var o := f * frame_bytes
			var v: float
			if bps == 2:
				v = absf(bytes.decode_s16(o) / 32768.0)
			else:
				v = absf(bytes.decode_s8(o) / 128.0)
			peak = maxf(peak, v)
			f += step
		out[b] = peak
	return out


func time_to_x(t: float) -> float:
	return (t - view_start) / view_len * size.x


func x_to_time(x: float) -> float:
	return view_start + x / size.x * view_len


func _process(_delta: float) -> void:
	if player == null or player.data == null:
		return
	if player.is_playing:  # page the view to follow the playhead
		var t := player.get_time()
		if t > view_start + view_len or t < view_start:
			view_start = t - view_len * 0.1
	_clamp_view()
	queue_redraw()


func _clamp_view() -> void:
	var total := maxf(player.total_length(), 1.0)
	view_len = clampf(view_len, 1.0, maxf(total, 30.0))
	view_start = clampf(view_start, 0.0, maxf(total - view_len, 0.0))


func _draw() -> void:
	if player == null or player.data == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.07, 0.09))
	var mid := size.y * 0.5

	# Time ruler: pick a tick spacing that is at least ~80px apart.
	var tick := 1.0
	for cand in [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0]:
		tick = cand
		if cand / view_len * size.x >= 80.0:
			break
	var t_tick := ceilf(view_start / tick) * tick
	while t_tick < view_start + view_len:
		var tx := time_to_x(t_tick)
		draw_line(Vector2(tx, 0), Vector2(tx, size.y), Color(1, 1, 1, 0.08))
		draw_string(ThemeDB.fallback_font, Vector2(tx + 3, size.y - 6), "%d:%02d" % [int(t_tick) / 60, int(t_tick) % 60],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.6, 0.65))
		t_tick += tick

	if peaks.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(12, mid), "No audio waveform - timeline only. Play (Space) and tap M to mark each shot.",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.6, 0.6, 0.65))
	else:
		for x in int(size.x):
			var b0 := int(x_to_time(x) * PEAKS_PER_SEC)
			var b1 := maxi(int(x_to_time(x + 1.0) * PEAKS_PER_SEC), b0 + 1)
			var pk := 0.0
			for b in range(maxi(b0, 0), mini(b1, peaks.size())):
				pk = maxf(pk, peaks[b])
			if pk > 0.0:
				draw_line(Vector2(x, mid - pk * mid * 0.9), Vector2(x, mid + pk * mid * 0.9), Color(0.35, 0.65, 0.95))

	# Shot markers (a shot's start == its marker)
	var font := ThemeDB.fallback_font
	for i in player.data.shots.size():
		var s := player.data.shots[i]
		if not s.is_assigned():
			continue
		var x := time_to_x(s.start)
		if x < -2 or x > size.x + 2:
			continue
		var col := Color(1.0, 0.8, 0.25) if i != _drag_idx else Color(1, 1, 1)
		draw_line(Vector2(x, 0), Vector2(x, size.y), col, 2.0)
		draw_string(font, Vector2(x + 4, 16), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)

	var px := time_to_x(player.get_time())
	draw_line(Vector2(px, 0), Vector2(px, size.y), Color(1, 0.3, 0.3), 2.0)


func _marker_at(x: float) -> int:
	var best := -1
	var best_d := GRAB_PX
	for i in player.data.shots.size():
		var s := player.data.shots[i]
		if s.is_assigned():
			var d := absf(time_to_x(s.start) - x)
			if d <= best_d:
				best_d = d
				best = i
	return best


func _gui_input(e: InputEvent) -> void:
	if player == null or player.data == null:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed:
				return
			if mb.shift_pressed:
				view_start += (-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1) * view_len * 0.1
			else:
				var t_at := x_to_time(mb.position.x)
				view_len *= 0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
				view_len = clampf(view_len, 1.0, maxf(player.total_length(), 30.0))
				view_start = t_at - mb.position.x / size.x * view_len
			_clamp_view()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_idx = _marker_at(mb.position.x)
				if _drag_idx < 0:
					_scrubbing = true
					player.seek(x_to_time(mb.position.x))
			else:
				if _drag_idx >= 0:
					changed.emit()
				_drag_idx = -1
				_scrubbing = false
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _drag_idx >= 0:
			var shots := player.data.shots
			var t := clampf(x_to_time(mm.position.x), 0.0, player.total_length())
			# Keep order: stay between the neighbouring assigned markers.
			for j in range(_drag_idx - 1, -1, -1):
				if shots[j].is_assigned():
					t = maxf(t, shots[j].start + 0.01)
					break
			for j in range(_drag_idx + 1, shots.size()):
				if shots[j].is_assigned():
					t = minf(t, shots[j].start - 0.01)
					break
			shots[_drag_idx].start = t
		elif _scrubbing:
			player.seek(x_to_time(mm.position.x))
