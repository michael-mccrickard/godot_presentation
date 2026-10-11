extends Control
## Glue: builds the player + authoring overlay and handles keys.
##   Space play/pause   M mark next shot   Tab show/hide authoring UI
##   Left/Right seek 1s (Shift = 5s)   Home rewind   S save   R reset all marks
##   C frame the camera move for the current shot (see camera_editor.gd)

const SAVE_RES := "res://presentation.json"    # written when running from the editor
const SAVE_USER := "user://presentation.json"  # written from an exported build
## Seconds added to a tap to compensate for your own reaction lag (negative = earlier).
const TAP_OFFSET := 0.0

var player: PresentationPlayer
var wave: WaveformView
var info: Label
var cam_editor: CameraEditor
var next_idx := 0


func _ready() -> void:
	player = PresentationPlayer.new()
	player.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(player)
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
	wave.offset_top = -200.0
	wave.offset_bottom = 0.0
	wave.grow_vertical = Control.GROW_DIRECTION_BEGIN
	wave.rebuild()

	# Camera editor covers the picture area (not the waveform strip).
	cam_editor = CameraEditor.new()
	add_child(cam_editor)
	cam_editor.anchor_right = 1.0
	cam_editor.anchor_bottom = 1.0
	cam_editor.offset_bottom = -200.0
	cam_editor.closed.connect(_on_camera_closed)

	info = Label.new()
	info.position = Vector2(12, 8)
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


func _process(_delta: float) -> void:
	info.modulate.a = 0.0 if cam_editor.visible else 1.0  # editor draws its own help line
	if info.visible:
		info.text = "%s  t=%.2f   next mark: shot %d/%d\nSpace play  M mark  C camera  S save  R reset  Tab hide  |  wheel zoom, drag markers" % [
			"PLAY" if player.is_playing else "PAUSE", player.get_time(),
			mini(next_idx + 1, player.data.shots.size()), player.data.shots.size()]
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
			_save()
		KEY_R:
			for s in player.data.shots:
				s.start = -1.0
			next_idx = 0
		KEY_LEFT:
			player.seek(player.get_time() - step)
		KEY_RIGHT:
			player.seek(player.get_time() + step)
		KEY_HOME:
			player.seek(0.0)
	get_viewport().set_input_as_handled()


func _tap() -> void:
	if next_idx >= player.data.shots.size():
		return
	player.data.shots[next_idx].start = maxf(player.get_time() + TAP_OFFSET, 0.0)
	next_idx += 1


func _save() -> void:
	var path := SAVE_RES if OS.has_feature("editor") else SAVE_USER
	if player.data.save_json(path):
		print("Saved ", ProjectSettings.globalize_path(path))
