class_name PresentationPlayer
extends Control
## Generic player. Every frame: t = audio clock -> pick shots -> camera = f(t) -> draw.
## Because the picture is a pure function of t, seeking/scrubbing just changes t.

const OUT_SIZE := Vector2i(1920, 1080)

var data: PresentationData
var audio: AudioStreamPlayer
var is_playing := false
var last_error := ""

var _vp: Array[SubViewport] = []
var _spr: Array[Sprite2D] = []
var _mat: ShaderMaterial
var _tex_cache := {}
var _paused_time := 0.0
var _free_clock := 0.0  # fallback clock when there is no audio stream
var _hold := 0          # frames to trust _paused_time right after play/seek


func _ready() -> void:
	audio = AudioStreamPlayer.new()
	add_child(audio)
	audio.finished.connect(_on_audio_finished)

	# Two offscreen layers (A = outgoing, B = incoming) rendered at native output size.
	for i in 2:
		var vp := SubViewport.new()
		vp.size = OUT_SIZE
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var s := Sprite2D.new()
		s.centered = false
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		vp.add_child(s)
		_vp.append(vp)
		_spr.append(s)

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/transition.gdshader")
	_mat.set_shader_parameter("tex_a", _vp[0].get_texture())
	_mat.set_shader_parameter("tex_b", _vp[1].get_texture())
	_mat.set_shader_parameter("mask_tex", _make_mask())
	rect.material = _mat


func set_data(d: PresentationData) -> void:
	data = d
	_tex_cache.clear()
	if data.audio_path != "" and ResourceLoader.exists(data.audio_path):
		audio.stream = load(data.audio_path)
	else:
		audio.stream = null
	is_playing = false
	_paused_time = 0.0
	_free_clock = 0.0


# ---------------------------------------------------------------- clock

## End of the authored content: audio length, or last shot start + 4s with no audio.
func content_length() -> float:
	if audio.stream:
		return audio.stream.get_length()
	# No audio: the last shot lasts as long as the one before it (4s if it is the only one).
	var last := -1.0  # latest marker time
	var prev := -1.0  # the one before it
	for s in data.shots:
		if not s.is_assigned():
			continue
		if s.start > last:
			prev = last
			last = s.start
		elif s.start > prev and s.start < last:
			prev = s.start
	var tail := 4.0
	if prev >= 0.0:
		tail = maxf(last - prev, 1.0)
	return maxf(last, 0.0) + tail


## With no audio the timeline keeps growing ahead of the clock, so you can keep
## tapping marks past the last shot without the "show" ending.
func total_length() -> float:
	if audio.stream:
		return audio.stream.get_length()
	return maxf(content_length(), maxf(_free_clock, _paused_time) + 5.0)


func get_time() -> float:
	if not is_playing or _hold > 0:
		return _paused_time
	if audio.stream == null:
		return _free_clock
	# Audio is the master clock, corrected for mix buffer position and output latency.
	return maxf(0.0, audio.get_playback_position()
			+ AudioServer.get_time_since_last_mix()
			- AudioServer.get_output_latency())


func play() -> void:
	if is_playing:
		return
	if _paused_time >= total_length() - 0.05:
		_paused_time = 0.0
	if audio.stream:
		audio.play(_paused_time)
	_free_clock = _paused_time
	_hold = 3
	is_playing = true


func pause() -> void:
	if not is_playing:
		return
	_paused_time = get_time()
	if audio.stream:
		audio.stop()  # stop() does not emit "finished"
	is_playing = false


func toggle() -> void:
	if is_playing:
		pause()
	else:
		play()


func seek(t: float) -> void:
	t = clampf(t, 0.0, total_length())
	_paused_time = t
	_free_clock = t
	if is_playing and audio.stream:
		audio.play(t)
	_hold = 3


func _on_audio_finished() -> void:
	is_playing = false
	_paused_time = total_length()


func _process(delta: float) -> void:
	if data == null:
		return
	if _hold > 0:
		_hold -= 1
	if is_playing and audio.stream == null:
		_free_clock += delta
	render(get_time())


# ---------------------------------------------------------------- rendering

func render(t: float) -> void:
	last_error = ""
	var idx := shot_index_at(t)
	if idx < 0:
		_spr[0].visible = false
		_spr[1].visible = false
		_mat.set_shader_parameter("mode", 1)
		_mat.set_shader_parameter("progress", 1.0)
		return

	var shot := data.shots[idx]
	var prev := _prev_assigned(idx)
	var prog := 1.0
	var a_idx := idx
	if prev >= 0 and shot.transition != Shot.Transition.CUT \
			and shot.transition_duration > 0.0 and t < shot.start + shot.transition_duration:
		a_idx = prev
		prog = clampf((t - shot.start) / shot.transition_duration, 0.0, 1.0)

	_apply(0, a_idx, t)
	_apply(1, idx, t)
	_mat.set_shader_parameter("mode", shot.transition)
	_mat.set_shader_parameter("progress", prog)


func shot_index_at(t: float) -> int:
	var best := -1
	for i in data.shots.size():
		var s := data.shots[i]
		if s.is_assigned() and s.start <= t:
			if best < 0 or s.start >= data.shots[best].start:
				best = i
	return best


func _prev_assigned(idx: int) -> int:
	for j in range(idx - 1, -1, -1):
		if data.shots[j].is_assigned():
			return j
	return -1


func _move_end(idx: int) -> float:
	var s := data.shots[idx]
	if s.move_duration > 0.0:
		return s.start + s.move_duration
	for j in range(idx + 1, data.shots.size()):
		if data.shots[j].is_assigned():
			return data.shots[j].start
	return content_length()


## Camera state is a pure function of t: center lerps linearly, zoom (width) in log space.
func camera_at(idx: int, t: float) -> Dictionary:
	var s := data.shots[idx]
	if s.auto_fit:
		var tex := _get_texture(s.image_path)
		var isz := tex.get_size() if tex else Vector2(OUT_SIZE)
		return {"center": Vector2(0.5, 0.5),
				"width": Shot.fit_width(Shot.Fit.FULL, isz, float(OUT_SIZE.x) / OUT_SIZE.y)}
	var span := maxf(_move_end(idx) - s.start, 0.001)
	var p := Shot.ease_value((t - s.start) / span, s.easing)
	var w0 := maxf(s.cam_start.size.x, 0.0001)
	var w1 := maxf(s.cam_end.size.x, 0.0001)
	return {
		"center": s.cam_start.get_center().lerp(s.cam_end.get_center(), p),
		"width": exp(lerpf(log(w0), log(w1), p)),
	}


func _apply(layer: int, idx: int, t: float) -> void:
	var spr := _spr[layer]
	var tex := _get_texture(data.shots[idx].image_path)
	if tex == null:
		spr.visible = false
		last_error = "Could not load image: " + data.shots[idx].image_path
		return
	var cam := camera_at(idx, t)
	var img_size := tex.get_size()
	var sc: float = OUT_SIZE.x / (cam.width * img_size.x)
	spr.texture = tex
	spr.scale = Vector2(sc, sc)
	spr.position = Vector2(OUT_SIZE) * 0.5 - cam.center * img_size * sc
	spr.visible = true


# ---------------------------------------------------------------- assets

func _get_texture(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if path.begins_with("demo://"):
		tex = _make_demo_texture(int(path.get_slice("//", 1)))
	elif path.begins_with("res://"):
		tex = load(path)  # import as Lossless + mipmaps for best quality
	else:
		var img := Image.load_from_file(path)
		if img:
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		push_warning("Could not load image: " + path)
	_tex_cache[path] = tex
	return tex


func _make_demo_texture(n: int) -> Texture2D:
	var w := 2560
	var h := 1440
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	var hue := fmod(n * 0.23, 1.0)
	img.fill(Color.from_hsv(hue, 0.5, 0.35))
	var line := Color.from_hsv(hue, 0.3, 0.85)
	for x in range(0, w, 128):
		img.fill_rect(Rect2i(x, 0, 4, h), line)
	for y in range(0, h, 128):
		img.fill_rect(Rect2i(0, y, w, 4), line)
	img.fill_rect(Rect2i(900 + n * 120, 480, 320, 320), Color.from_hsv(fmod(hue + 0.5, 1.0), 0.8, 0.95))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _make_mask() -> Texture2D:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.012
	return ImageTexture.create_from_image(noise.get_image(256, 256))  # normalized 0..1
