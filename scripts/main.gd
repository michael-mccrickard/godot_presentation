extends Control
## Glue: builds the player + authoring overlay and handles keys.
##   Space play/pause   M mark next shot   Tab show/hide authoring UI
##   The boxed shot info panel edits the transition into the shot at the playhead.
##   Left/Right seek 1s (Shift = 5s)   Home rewind   End jump to end
##   R (twice) clear all marks
##   S save now (every edit is also saved automatically)
##   C frame the camera move for the current shot (see camera_editor.gd)
## Every edit is written to presentation.json shortly after it is made.

const SAVE_RES := "res://presentation.json"    # written when running from the editor
const SAVE_USER := "user://presentation.json"  # written from an exported build
## Seconds added to a tap to compensate for your own reaction lag (negative = earlier).
const TAP_OFFSET := 0.0

# Window layout (must add up to the window height in project.godot): a black bar for
# the status line, shot info box and key hints, the 1280x720 presentation view, then
# the waveform strip.
const TOP_BAR := 196.0
const VIEW_SIZE := Vector2(1280, 720)
const WAVE_H := 116.0

const TRANSITION_NAMES := ["Cut", "Crossfade", "Wipe", "Iris", "Mask Dissolve"]
const DUR_STEP := 0.25
const DUR_MAX := 10.0
const HINTS := "Space - play/pause  |  M - mark next shot  |  C - camera  |  R R - clear marks  |  Tab - hide/show  |  wheel zoom - zoom timeline"

var player: PresentationPlayer
var wave: WaveformView
var info: Label                # status line
var hints: Label
var shot_box: PanelContainer
var cam_editor: CameraEditor
var buttons: HBoxContainer

var _save_timer: Timer
var _dirty := false
var _save_status := ""
var _armed_key := 0            # destructive keys (R) must be pressed twice
var _armed_until := 0.0
var _new_images := 0           # images picked up from the folder when loading
var _relinked_images := 0      # shots re-pointed at a renamed file
var _notice := ""              # short message shown in the status line
var _notice_until := 0.0
var _scaffold_images := 0      # > 0 when there was no presentation: offer to scaffold
var _offer: Control
var _trash_confirm: Control
var _ui_visible := true

# Shot info box widgets.
var _box_title: Label
var _box_camera: Label
var _box_note: Label
var _trans_buttons: Array[Button] = []
var _dur_label: Label
var _dur_minus: Button
var _dur_plus: Button


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

	# Camera editor covers the whole window; the timeline is hidden while it is open.
	cam_editor = CameraEditor.new()
	add_child(cam_editor)
	cam_editor.anchor_right = 1.0
	cam_editor.anchor_bottom = 1.0
	cam_editor.closed.connect(_on_camera_closed)
	cam_editor.changed.connect(_queue_save)

	# Transport buttons, top right of the black bar.
	buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	add_child(buttons)
	buttons.anchor_left = 1.0
	buttons.anchor_right = 1.0
	buttons.offset_left = -390.0
	buttons.offset_right = -12.0
	buttons.offset_top = 4.0
	buttons.offset_bottom = 34.0
	buttons.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	buttons.add_child(_make_button("|<  Rewind", "Rewind to the beginning (Home)", _rewind))
	buttons.add_child(_make_button("End  >|", "Jump to the end (End)", _to_end))
	var trash := _make_button("Trash", "Delete the whole presentation and start over (asks first)", _ask_trash)
	trash.add_theme_color_override("font_color", Color(1, 0.5, 0.45))
	trash.add_theme_color_override("font_hover_color", Color(1, 0.6, 0.55))
	buttons.add_child(trash)

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
	info.add_theme_font_size_override("font_size", 18)
	add_child(info)

	_build_shot_box()

	hints = Label.new()
	hints.position = Vector2(12, shot_box.position.y + shot_box.get_combined_minimum_size().y + 4.0)
	hints.add_theme_font_size_override("font_size", 16)
	hints.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	hints.text = HINTS
	add_child(hints)

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


# ---------------------------------------------------------------- shot info box

## Boxed panel in the top bar showing the shot at the playhead. Editable: the
## transition into the shot and its duration.
func _build_shot_box() -> void:
	shot_box = PanelContainer.new()
	shot_box.position = Vector2(12, 40)
	shot_box.size = Vector2(VIEW_SIZE.x - 24.0, 0.0)  # height follows the content
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1)
	style.border_color = Color(0.45, 0.45, 0.5)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	shot_box.add_theme_stylebox_override("panel", style)
	add_child(shot_box)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	shot_box.add_child(col)

	var top := HBoxContainer.new()
	col.add_child(top)
	_box_title = Label.new()
	_box_title.add_theme_font_size_override("font_size", 20)
	_box_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box_title.clip_text = true
	top.add_child(_box_title)
	_box_camera = Label.new()
	_box_camera.add_theme_font_size_override("font_size", 18)
	top.add_child(_box_camera)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	var lead := Label.new()
	lead.text = "Transition in:"
	lead.add_theme_font_size_override("font_size", 18)
	row.add_child(lead)
	var group := ButtonGroup.new()
	var on := StyleBoxFlat.new()  # the selected transition must stand out clearly
	on.bg_color = Color(0.2, 0.42, 0.75)
	on.set_corner_radius_all(3)
	on.set_content_margin_all(4)
	for i in TRANSITION_NAMES.size():
		var b := _make_button(TRANSITION_NAMES[i], "Transition into this shot", _set_transition.bind(i))
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(110, 32)
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
		b.add_theme_color_override("font_pressed_color", Color.WHITE)
		b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
		row.add_child(b)
		_trans_buttons.append(b)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(30, 0)
	row.add_child(gap)
	var dl := Label.new()
	dl.text = "Duration:"
	dl.add_theme_font_size_override("font_size", 18)
	row.add_child(dl)
	_dur_minus = _make_button("-", "Shorter by %s s" % DUR_STEP, _nudge_duration.bind(-DUR_STEP))
	_dur_minus.custom_minimum_size = Vector2(36, 32)
	row.add_child(_dur_minus)
	_dur_label = Label.new()
	_dur_label.custom_minimum_size = Vector2(72, 0)
	_dur_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dur_label.add_theme_font_size_override("font_size", 18)
	row.add_child(_dur_label)
	_dur_plus = _make_button("+", "Longer by %s s" % DUR_STEP, _nudge_duration.bind(DUR_STEP))
	_dur_plus.custom_minimum_size = Vector2(36, 32)
	row.add_child(_dur_plus)

	_box_note = Label.new()
	_box_note.add_theme_font_size_override("font_size", 16)
	col.add_child(_box_note)


## The shot the box shows and edits: the one on screen at the playhead, or -1.
func _box_shot() -> int:
	return player.shot_index_at(player.get_time())


## True when the shot has an earlier marked shot to transition from.
func _has_transition(idx: int) -> bool:
	return idx >= 0 and player._prev_assigned(idx) >= 0


func _set_transition(kind: int) -> void:
	var idx := _box_shot()
	if not _has_transition(idx):
		return
	var s := player.data.shots[idx]
	s.transition = kind
	if kind != Shot.Transition.CUT and s.transition_duration <= 0.0:
		s.transition_duration = 1.0
	_queue_save()


func _nudge_duration(delta: float) -> void:
	var idx := _box_shot()
	if not _has_transition(idx):
		return
	var s := player.data.shots[idx]
	s.transition_duration = clampf(snappedf(s.transition_duration + delta, DUR_STEP), DUR_STEP, DUR_MAX)
	_queue_save()


func _fmt_time(t: float) -> String:
	return "%d:%05.2f" % [int(t) / 60, fmod(t, 60.0)]


func _update_shot_box() -> void:
	var idx := _box_shot()
	var shots := player.data.shots
	if idx < 0:
		_box_title.text = "No shot at the playhead"
		_box_camera.text = ""
		_box_note.text = "Nothing is marked before this time yet."
		_box_note.modulate = Color(0.7, 0.7, 0.75)
		for b in _trans_buttons:
			b.disabled = true
			b.set_pressed_no_signal(false)
		_dur_label.text = ""
		_dur_minus.disabled = true
		_dur_plus.disabled = true
		return

	var s := shots[idx]
	var title := "Shot %d/%d   %s   at %s" % [idx + 1, shots.size(), s.image_path.get_file(), _fmt_time(s.start)]
	var from := player.transition_from_index(idx, player.get_time())
	if from >= 0:
		title += "   (transitioning from %s)" % shots[from].image_path.get_file()
	_box_title.text = title

	if s.auto_fit:
		_box_camera.text = "Camera: Full frame"
	elif s.cam_start.is_equal_approx(s.cam_end):
		_box_camera.text = "Camera: Framed, no move"
	else:
		_box_camera.text = "Camera: Move"

	var editable := _has_transition(idx)
	for i in _trans_buttons.size():
		_trans_buttons[i].disabled = not editable
		_trans_buttons[i].set_pressed_no_signal(i == s.transition)
	var is_cut := s.transition == Shot.Transition.CUT
	_dur_label.text = "-" if is_cut else "%.2f s" % s.transition_duration
	_dur_minus.disabled = not editable or is_cut or s.transition_duration <= DUR_STEP
	_dur_plus.disabled = not editable or is_cut or s.transition_duration >= DUR_MAX

	# Next marker after this shot (by time), to catch transitions that overrun it.
	var next_start := INF
	for o in shots:
		if o.is_assigned() and o.start > s.start:
			next_start = minf(next_start, o.start)
	var note := ""
	var warn := false
	if not editable:
		note = "First shot: there is nothing to transition from."
	elif not is_cut and s.start + s.transition_duration > next_start:
		note = "Warning: the transition is longer than the shot (%.2f s until the next marker)." % (next_start - s.start)
		warn = true
	_box_note.text = note
	_box_note.modulate = Color(1, 0.75, 0.3) if warn else Color(0.7, 0.7, 0.75)


# ---------------------------------------------------------------- modal dialogs

## Dimmed full-window overlay with a centred panel. Returns [overlay, content box];
## the caller adds a body and a button row to the box.
func _make_modal(title_text: String, border: Color) -> Array:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP  # blocks the UI underneath
	add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640, 0)
	var style := StyleBoxFlat.new()  # opaque, so the text is readable over any image
	style.bg_color = Color(0.11, 0.11, 0.13)
	style.border_color = border
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
	title.text = title_text
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)
	return [overlay, box]


func _modal_body(box: VBoxContainer, text: String) -> void:
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(596, 0)
	body.text = text
	box.add_child(body)


func _modal_row(box: VBoxContainer) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	return row


# ---------------------------------------------------------------- trash

func _ask_trash() -> void:
	if _trash_confirm:
		_trash_confirm.queue_free()
	var m := _make_modal("Trash this presentation?", Color(0.85, 0.35, 0.3))
	_trash_confirm = m[0]
	var box: VBoxContainer = m[1]
	_modal_body(box, "This deletes every marker, camera framing and transition, and starts over "
			+ "from the images in images/, exactly as on first run.\n\n"
			+ "A copy of the current file is kept as presentation.json.bak.")
	var row := _modal_row(box)
	var no := _make_button("Cancel  (Esc)", "Keep the presentation", _cancel_trash)
	no.custom_minimum_size = Vector2(170, 36)
	row.add_child(no)
	var yes := _make_button("Delete and start over", "Cannot be undone (except from the .bak copy)", _do_trash)
	yes.custom_minimum_size = Vector2(210, 36)
	yes.add_theme_color_override("font_color", Color(1, 0.5, 0.45))
	row.add_child(yes)
	player.pause()


func _cancel_trash() -> void:
	_trash_confirm.queue_free()
	_trash_confirm = null


func _do_trash() -> void:
	_cancel_trash()
	# Drop any pending autosave of the old presentation.
	_save_timer.stop()
	_dirty = false
	var path := SAVE_RES if OS.has_feature("editor") else SAVE_USER
	if FileAccess.file_exists(path):
		var old := FileAccess.get_file_as_string(path)
		if old.strip_edges() != "":
			var bak := FileAccess.open(path + ".bak", FileAccess.WRITE)
			if bak:
				bak.store_string(old)
	# An empty file counts as no presentation, so a restart also starts fresh.
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("")
	f = null
	_save_status = ""
	# Re-run the first-run sequence.
	player.set_data(PresentationData.make_demo())
	wave.rebuild()
	player.seek(0.0)
	wave.reveal(0.0)
	_scaffold_images = PresentationData.image_count("res://images")
	if _offer:
		_offer.queue_free()
		_offer = null
	if _scaffold_images > 0:
		_build_offer()
	_show_notice("presentation trashed (old copy in %s.bak)" % path.get_file(), 15.0)


# ---------------------------------------------------------------- scaffold offer

## Modal question shown when there was no saved presentation but there are images.
func _build_offer() -> void:
	var m := _make_modal("New presentation", Color(0.45, 0.45, 0.5))
	_offer = m[0]
	var box: VBoxContainer = m[1]
	_modal_body(box, ("No saved presentation was found, and images/ has %d images.\n\n"
			+ "Scaffold a presentation from them? Every image becomes a shot, in name order, "
			+ "%s seconds each, joined by cuts. You can retime shots afterwards by dragging "
			+ "their markers.\n\n"
			+ "Or start empty: every shot is unmarked, and you tap M to mark each one, starting with the first.") % [
			_scaffold_images, _fmt_seconds(PresentationData.SCAFFOLD_SECONDS)])
	var row := _modal_row(box)
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
	# The camera editor draws its own help line over the top bar.
	var ui_on := _ui_visible and not cam_editor.visible
	info.visible = ui_on
	hints.visible = ui_on
	shot_box.visible = ui_on
	buttons.visible = ui_on
	wave.visible = _ui_visible and not cam_editor.visible
	if ui_on:
		_update_shot_box()
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
				"CLEAR ALL MARKS"]
		if player.last_error != "":
			line1 += "   " + player.last_error
		info.text = line1


func _on_camera_closed(shot_index: int, preview: bool) -> void:
	var s := player.data.shots[shot_index]
	if preview and s.is_assigned():
		player.seek(s.start)
		player.play()


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed:
		return
	if _trash_confirm:  # the trash question owns the keyboard; only Esc does anything
		if k.keycode == KEY_ESCAPE and not k.echo:
			_cancel_trash()
		get_viewport().set_input_as_handled()
		return
	# Held arrow keys repeat in the camera editor (fine crop); nothing else repeats.
	if k.echo and not (cam_editor.visible and k.keycode in [KEY_UP, KEY_DOWN]):
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
			_ui_visible = not _ui_visible
		KEY_S:
			_dirty = true
			_flush_save()
		KEY_R:
			if _confirm(KEY_R):
				for s in player.data.shots:
					s.start = -1.0
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
