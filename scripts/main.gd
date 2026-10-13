extends Control
## Glue: builds the player + authoring overlay and handles keys.
##   Space play/pause   M mark next shot   Tab show/hide authoring UI
##   Left/Right seek 1s (Shift = 5s)   Home rewind   End jump to end
##   O (twice) re-sort the unmarked shots by name   R (twice) clear all marks
##   S save now (every edit is also saved automatically)
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

var _save_timer: Timer
var _dirty := false
var _save_status := ""
var _armed_key := 0            # destructive keys (R, O) must be pressed twice
var _armed_until := 0.0
var _new_images := 0           # images picked up from the folder when loading
var _relinked_images := 0      # shots re-pointed at a renamed file
var _notice := ""              # short message shown in the status line
var _notice_until := 0.0
var _scaffold_images := 0      # > 0 when there was no presentation: offer to scaffold
var _offer: Control


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
	if _new_images > 0 or _relinked_images > 0:
		var parts: Array[String] = []
		if _new_images > 0:
			parts.append("%d new image(s) added by name, unmarked" % _new_images)
		if _relinked_images > 0:
			parts.append("%d renamed image(s) relinked" % _relinked_images)
		_show_notice(", ".join(parts), 20.0)
		print(_notice)
		_queue_save()

	info = Label.new()
	info.position = Vector2(12, 6)
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_color_override("font_shadow_color", Color.BLACK)
	info.add_theme_constant_override("shadow_offset_x", 1)
	info.add_theme_constant_override("shadow_offset_y", 1)
	add_child(info)

	if _scaffold_images > 0:
		_build_offer()  # last, so it sits on top of everything


func _load_or_demo() -> PresentationData:
	var paths := [SAVE_RES, SAVE_USER] if OS.has_feature("editor") else [SAVE_USER, SAVE_RES]
	for p in paths:
		if not FileAccess.file_exists(p):
			continue
		var text := FileAccess.get_file_as_string(p)
		if text.strip_edges() == "":
			continue  # an empty file counts as no file
		var d := PresentationData.from_json(text)
		if d:
			# Images added to / renamed in the folder since the file was saved.
			var r := d.add_new_images("res://images")
			_new_images = r.added
			_relinked_images = r.relinked
			return d
		# Not valid JSON. Autosave would overwrite it, so keep a copy first.
		var bak := FileAccess.open(p + ".broken", FileAccess.WRITE)
		if bak:
			bak.store_string(text)
			_show_notice("%s was not valid JSON; kept a copy as %s.broken" % [p.get_file(), p.get_file()], 30.0)
			push_warning(_notice)
	# No usable presentation: start from the images, and offer to scaffold them.
	_scaffold_images = PresentationData.image_count("res://images")
	return PresentationData.make_demo()


# ---------------------------------------------------------------- scaffold offer

## Modal question shown when there was no saved presentation but there are images.
func _build_offer() -> void:
	_offer = Control.new()
	_offer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_offer.mouse_filter = Control.MOUSE_FILTER_STOP  # blocks the UI underneath
	add_child(_offer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
	var style := StyleBoxFlat.new()  # opaque, so the text is readable over any image
	style.bg_color = Color(0.11, 0.11, 0.13)
	style.border_color = Color(0.45, 0.45, 0.5)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var title := Label.new()
	title.text = "New presentation"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(596, 0)
	body.text = ("No saved presentation was found, and images/ has %d images.\n\n"
			+ "Scaffold a presentation from them? Every image becomes a shot, in name order, "
			+ "%s seconds each, joined by cuts. You can retime shots afterwards by dragging "
			+ "their markers.\n\n"
			+ "Or start empty: the first shot is placed at 0:00 and you tap M to mark the rest.") % [
			_scaffold_images, _fmt_seconds(PresentationData.SCAFFOLD_SECONDS)]
	box.add_child(body)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	var skip := _make_button("Start empty  (Esc)", "Keep the shots unmarked", _decline_scaffold)
	skip.custom_minimum_size = Vector2(170, 36)
	row.add_child(skip)
	var yes := _make_button("Scaffold  (Enter)", "Create all shots, 2 seconds each, with cuts", _accept_scaffold)
	yes.custom_minimum_size = Vector2(170, 36)
	row.add_child(yes)


func _accept_scaffold() -> void:
	_offer.hide()
	player.set_data(PresentationData.make_scaffold())
	wave.rebuild()
	player.seek(0.0)
	_show_notice("scaffolded %d shots, %s s each, cuts" % [
			player.data.shots.size(), _fmt_seconds(PresentationData.SCAFFOLD_SECONDS)], 15.0)
	_queue_save()


func _fmt_seconds(x: float) -> String:
	return str(int(x)) if is_equal_approx(x, roundf(x)) else str(x)


func _decline_scaffold() -> void:
	_offer.hide()


## Index of the first shot with no marker yet (the one `M` will mark), or the shot
## count when every shot is marked.
func _next_unmarked() -> int:
	var shots := player.data.shots
	for i in shots.size():
		if not shots[i].is_assigned():
			return i
	return shots.size()


func _show_notice(text: String, seconds: float) -> void:
	_notice = text
	_notice_until = Time.get_ticks_msec() / 1000.0 + seconds


## True on the second press of the same key within 3 seconds.
func _confirm(keycode: int) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if _armed_key == keycode and now < _armed_until:
		_armed_key = 0
		return true
	_armed_key = keycode
	_armed_until = now + 3.0
	return false


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
		var nxt := _next_unmarked()
		var nxt_name := "-"
		if nxt < player.data.shots.size():
			nxt_name = player.data.shots[nxt].image_path.get_file().get_basename()
		var line1 := "%s  t=%.2f   next mark: %s (%d/%d)   %s" % [
			"PLAY" if player.is_playing else "PAUSE", player.get_time(),
			nxt_name, mini(nxt + 1, player.data.shots.size()), player.data.shots.size(), _save_status]
		var now := Time.get_ticks_msec() / 1000.0
		if now < _notice_until:
			line1 += "   " + _notice
		if now < _armed_until:
			line1 += "   PRESS %s AGAIN TO %s" % [
				OS.get_keycode_string(_armed_key),
				"CLEAR ALL MARKS" if _armed_key == KEY_R else "RE-SORT UNMARKED SHOTS BY NAME"]
		info.text = line1 + "\nSpace play  M mark  C camera  O sort  R clear marks  Home/End  Tab hide  |  wheel zoom, drag markers"
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
	if _offer and _offer.visible:  # the scaffold question owns the keyboard
		if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_accept_scaffold()
		elif k.keycode == KEY_ESCAPE:
			_decline_scaffold()
		get_viewport().set_input_as_handled()
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
			if _confirm(KEY_R):
				for s in player.data.shots:
					s.start = -1.0
				_queue_save()
		KEY_O:
			if _confirm(KEY_O):
				var moved := player.data.sort_unmarked_by_name()
				_show_notice("re-sorted: %d unmarked shot(s) moved" % moved if moved > 0
						else "unmarked shots were already in name order", 8.0)
				if moved > 0:
					_queue_save()
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
	var i := _next_unmarked()
	if i >= player.data.shots.size():
		return
	player.data.shots[i].start = maxf(player.get_time() + TAP_OFFSET, 0.0)
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
