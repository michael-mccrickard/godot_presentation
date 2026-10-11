extends Control
## Glue: builds the player + authoring overlay and handles keys.
##   Space play/pause   M mark next shot   Tab show/hide authoring UI
##   Left/Right seek 1s (Shift = 5s)   Home rewind   End jump to end
##   R (twice) clear all marks   S save now (every edit is also saved automatically)
##   C frame the camera move for the current shot (see camera_editor.gd)
## Every edit is written to presentation.json shortly after it is made.

const SAVE_RES := "res://presentation.json"    # written when running from the editor
const SAVE_USER := "user://presentation.json"  # written from an exported build
## Seconds added to a tap to compensate for your own reaction lag (negative = earlier).
const TAP_OFFSET := 0.0

# Window layout (must add up to the window height in project.godot): a black bar for
# the info text, the 1280x720 presentation view, then the waveform strip.
const TOP_BAR := 72.0
const VIEW_SIZE := Vector2(1280, 720)
const WAVE_H := 232.0

var player: PresentationPlayer
var wave: WaveformView
var info: Label
var cam_editor: CameraEditor
var buttons: HBoxContainer
var next_idx := 0

var _save_timer: Timer
var _dirty := false
var _save_status := ""
var _clear_armed_until := 0.0  # R must be pressed twice (autosave makes it permanent)


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.BLACK)  # bars around images are black
	var bg := ColorRect.new()  # the black bar above the view (and any letterboxing)
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	player = PresentationPlayer.new()
	player.set_anchors_preset(Control.PRESET_TOP_LEFT)
	player.clip_contents = true
	add_child(player)
	player.position = Vector2(0, TOP_BAR)
	player.size = VIEW_SIZE
	player.set_data(_load_or_demo())
	_sync_next_idx()

	wave = WaveformView.new()
	wave.player = player
	add_child(wave)
	wave.anchor_left = 0.0
	wave.anchor_right = 1.0
	wave.anchor_top = 1.0
	wave.anchor_bottom = 1.0
	wave.offset_left = 0.0
	wave.offset_right = 0.0
	wave.offset_top = -WAVE_H
	wave.offset_bottom = 0.0
	wave.grow_vertical = Control.GROW_DIRECTION_BEGIN
	wave.rebuild()
	wave.changed.connect(_queue_save)

	# Camera editor covers the picture area (not the waveform strip).
	cam_editor = CameraEditor.new()
	add_child(cam_editor)
	cam_editor.anchor_right = 1.0
	cam_editor.anchor_bottom = 1.0
	cam_editor.offset_bottom = -WAVE_H
	cam_editor.closed.connect(_on_camera_closed)
	cam_editor.changed.connect(_queue_save)

	# Transport buttons, top right of the black bar.
	buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	add_child(buttons)
	buttons.anchor_left = 1.0
	buttons.anchor_right = 1.0
	buttons.offset_left = -260.0
	buttons.offset_right = -12.0
	buttons.offset_top = 8.0
	buttons.offset_bottom = 40.0
	buttons.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	buttons.add_child(_make_button("|<  Rewind", "Rewind to the beginning (Home)", _rewind))
	buttons.add_child(_make_button("End  >|", "Jump to the end (End)", _to_end))

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.4
	_save_timer.timeout.connect(_flush_save)
	add_child(_save_timer)

	info = Label.new()
	info.position = Vector2(12, 6)
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_color_override("font_shadow_color", Color.BLACK)
	info.add_theme_constant_override("shadow_offset_x", 1)
	info.add_theme_constant_override("shadow_offset_y", 1)
	add_child(info)


func _load_or_demo() -> PresentationData:
	var paths := [SAVE_RES, SAVE_USER] if OS.has_feature("editor") else [SAVE_USER, SAVE_RES]
	for p in paths:
		if FileAccess.file_exists(p):
			var d := PresentationData.load_json(p)
			if d:
				return d
	return PresentationData.make_demo()


func _sync_next_idx() -> void:
	next_idx = 0
	for s in player.data.shots:
		if s.is_assigned():
			next_idx += 1
		else:
			break


func _make_button(label: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE  # so Space keeps meaning play/pause
	b.custom_minimum_size = Vector2(118, 32)
	b.pressed.connect(handler)
	return b


func _rewind() -> void:
	player.seek(0.0)
	wave.reveal(0.0)


func _to_end() -> void:
	var t := player.content_length()
	player.seek(t)
	wave.reveal(t)


func _process(_delta: float) -> void:
	var editing := cam_editor.visible
	info.modulate.a = 0.0 if editing else 1.0  # editor draws its own help line
	buttons.visible = not editing and info.visible
	if info.visible:
		var line1 := "%s  t=%.2f   next mark: shot %d/%d   %s" % [
			"PLAY" if player.is_playing else "PAUSE", player.get_time(),
			mini(next_idx + 1, player.data.shots.size()), player.data.shots.size(), _save_status]
		if Time.get_ticks_msec() / 1000.0 < _clear_armed_until:
			line1 += "   PRESS R AGAIN TO CLEAR ALL MARKS"
		info.text = line1 + "\nSpace play  M mark  C camera  R clear marks  Home/End  Tab hide  |  wheel zoom, drag markers"
		if player.last_error != "":
			info.text += "\n" + player.last_error


func _on_camera_closed(shot_index: int, preview: bool) -> void:
	var s := player.data.shots[shot_index]
	if preview and s.is_assigned():
		player.seek(s.start)
		player.play()


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if cam_editor.visible:  # camera editor owns the keyboard while it is open
		cam_editor.handle_key(k)
		get_viewport().set_input_as_handled()
		return
	var step := 5.0 if k.shift_pressed else 1.0
	match k.keycode:
		KEY_C:
			var i := player.shot_index_at(player.get_time())
			player.pause()
			cam_editor.open(player, maxi(i, 0))
		KEY_SPACE:
			player.toggle()
		KEY_M:
			_tap()
		KEY_TAB:
			wave.visible = not wave.visible
			info.visible = wave.visible
		KEY_S:
			_dirty = true
			_flush_save()
		KEY_R:
			var now := Time.get_ticks_msec() / 1000.0
			if now < _clear_armed_until:
				_clear_armed_until = 0.0
				for s in player.data.shots:
					s.start = -1.0
				next_idx = 0
				_queue_save()
			else:
				_clear_armed_until = now + 3.0
		KEY_LEFT:
			player.seek(player.get_time() - step)
			wave.reveal(player.get_time())
		KEY_RIGHT:
			player.seek(player.get_time() + step)
			wave.reveal(player.get_time())
		KEY_HOME:
			_rewind()
		KEY_END:
			_to_end()
	get_viewport().set_input_as_handled()


func _tap() -> void:
	if next_idx >= player.data.shots.size():
		return
	player.data.shots[next_idx].start = maxf(player.get_time() + TAP_OFFSET, 0.0)
	next_idx += 1
	_queue_save()


## Autosave: every edit calls this; the file is written 0.4s after the last edit.
func _queue_save() -> void:
	_dirty = true
	_save_status = "unsaved"
	_save_timer.start()


func _flush_save() -> void:
	if not _dirty:
		return
	_dirty = false
	var path := SAVE_RES if OS.has_feature("editor") else SAVE_USER
	if player.data.save_json(path):
		_save_status = "saved " + Time.get_time_string_from_system()
		print("Saved ", ProjectSettings.globalize_path(path))
	else:
		_save_status = "SAVE FAILED"


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_flush_save()  # don't lose an edit made in the last 0.4s
