class_name CameraEditor
extends Control
## Full-screen overlay for framing a shot's camera move. Shows the whole image with
## a START rect (green) and an END rect (red); the move runs from one to the other.
##   1 / 2    choose START or END rect        drag    move the rect
##   wheel    zoom the rect (Shift = fine)    0       static full frame
##   H        hold: END = START               [ / ]   previous / next shot
##   Enter    apply and preview the shot      Esc     cancel changes to this shot

signal closed(shot_index: int, preview: bool)

const MIN_WIDTH := 0.05
const COL_START := Color(0.3, 1.0, 0.4)
const COL_END := Color(1.0, 0.35, 0.3)

var player: PresentationPlayer
var idx := 0
var editing_end := false

var _backup_start := Rect2()
var _backup_end := Rect2()
var _dragging := false
var _grab := Vector2.ZERO


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE


func open(p: PresentationPlayer, shot_index: int) -> void:
	player = p
	_select(shot_index)
	visible = true


func _close(preview: bool) -> void:
	visible = false
	_dragging = false
	closed.emit(idx, preview)


func _select(i: int) -> void:
	idx = clampi(i, 0, player.data.shots.size() - 1)
	var s := _shot()
	_backup_start = s.cam_start
	_backup_end = s.cam_end
	_dragging = false
	# Re-express old rects (e.g. from the demo's square ones) with this image's true height.
	s.cam_start = _make_rect(s.cam_start.get_center(), s.cam_start.size.x)
	s.cam_end = _make_rect(s.cam_end.get_center(), s.cam_end.size.x)


func _shot() -> Shot:
	return player.data.shots[idx]


# ---------------------------------------------------------------- geometry

func _tex() -> Texture2D:
	return player._get_texture(_shot().image_path)


## Image rectangle in screen pixels (image fit inside this control, letterboxed).
func _image_rect() -> Rect2:
	var tex := _tex()
	if tex == null:
		return Rect2(Vector2.ZERO, size)
	var isz := tex.get_size()
	var sc := minf((size.x - 24.0) / isz.x, (size.y - 56.0) / isz.y)
	var disp := isz * sc
	return Rect2(Vector2((size.x - disp.x) * 0.5, 36.0 + (size.y - 56.0 - disp.y) * 0.5), disp)


## Normalised camera rect for a given centre and width (fraction of image width).
## Height follows the output aspect so what you frame is exactly what plays.
func _make_rect(center: Vector2, w: float) -> Rect2:
	var tex := _tex()
	var isz := tex.get_size() if tex else Vector2(16, 9)
	var out_aspect := float(PresentationPlayer.OUT_SIZE.x) / float(PresentationPlayer.OUT_SIZE.y)
	w = clampf(w, MIN_WIDTH, 1.0)
	var h := w * isz.x / (isz.y * out_aspect)
	# Keep the rect inside the image where it fits; centre it where it cannot.
	var cx := 0.5 if w >= 1.0 else clampf(center.x, w * 0.5, 1.0 - w * 0.5)
	var cy := 0.5 if h >= 1.0 else clampf(center.y, h * 0.5, 1.0 - h * 0.5)
	return Rect2(Vector2(cx - w * 0.5, cy - h * 0.5), Vector2(w, h))


func _active() -> Rect2:
	return _shot().cam_end if editing_end else _shot().cam_start


func _set_active(r: Rect2) -> void:
	if editing_end:
		_shot().cam_end = r
	else:
		_shot().cam_start = r


func _to_norm(screen: Vector2) -> Vector2:
	var ir := _image_rect()
	return (screen - ir.position) / ir.size


func _to_screen(r: Rect2) -> Rect2:
	var ir := _image_rect()
	return Rect2(ir.position + r.position * ir.size, r.size * ir.size)


# ---------------------------------------------------------------- input

func handle_key(k: InputEventKey) -> void:
	match k.keycode:
		KEY_1:
			editing_end = false
		KEY_2:
			editing_end = true
		KEY_0:
			_shot().cam_start = _make_rect(Vector2(0.5, 0.5), 1.0)
			_shot().cam_end = _shot().cam_start
		KEY_H:
			_shot().cam_end = _shot().cam_start
		KEY_BRACKETLEFT:
			_select(idx - 1)
		KEY_BRACKETRIGHT:
			_select(idx + 1)
		KEY_ENTER, KEY_KP_ENTER:
			_close(true)
		KEY_ESCAPE:
			_shot().cam_start = _backup_start
			_shot().cam_end = _backup_end
			_close(false)
	queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var m := _to_norm(mb.position)
				var r := _active()
				_dragging = true
				_grab = r.get_center() - m if r.has_point(m) else Vector2.ZERO
				_set_active(_make_rect(m + _grab, r.size.x))
			else:
				_dragging = false
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var factor := 0.97 if mb.shift_pressed else 0.9
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				factor = 1.0 / factor
			var r := _active()
			var m := _to_norm(mb.position)
			var w := clampf(r.size.x * factor, MIN_WIDTH, 1.0)
			# Zoom about the cursor so the point under it stays put.
			_set_active(_make_rect(m + (r.get_center() - m) * (w / r.size.x), w))
	elif e is InputEventMouseMotion and _dragging:
		var r := _active()
		_set_active(_make_rect(_to_norm((e as InputEventMouseMotion).position) + _grab, r.size.x))
	queue_redraw()


# ---------------------------------------------------------------- drawing

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.06))
	var tex := _tex()
	if tex == null:
		return
	var ir := _image_rect()
	draw_texture_rect(tex, ir, false)

	var s := _shot()
	var rs := _to_screen(s.cam_start)
	var re := _to_screen(s.cam_end)
	var act := re if editing_end else rs
	var act_col := COL_END if editing_end else COL_START

	# Dim everything outside the rect being edited.
	var dim := Color(0, 0, 0, 0.55)
	var a := act.intersection(ir)
	draw_rect(Rect2(ir.position, Vector2(ir.size.x, a.position.y - ir.position.y)), dim)
	draw_rect(Rect2(Vector2(ir.position.x, a.end.y), Vector2(ir.size.x, ir.end.y - a.end.y)), dim)
	draw_rect(Rect2(Vector2(ir.position.x, a.position.y), Vector2(a.position.x - ir.position.x, a.size.y)), dim)
	draw_rect(Rect2(Vector2(a.end.x, a.position.y), Vector2(ir.end.x - a.end.x, a.size.y)), dim)

	var font := ThemeDB.fallback_font
	# Inactive rect thin, active rect thick; path line shows the direction of travel.
	draw_rect(rs, COL_START, false, 4.0 if not editing_end else 1.5)
	draw_rect(re, COL_END, false, 4.0 if editing_end else 1.5)
	draw_line(rs.get_center(), re.get_center(), Color(1, 1, 1, 0.6), 1.5)
	draw_circle(rs.get_center(), 4.0, COL_START)
	draw_circle(re.get_center(), 4.0, COL_END)
	draw_string(font, rs.position + Vector2(6, 18), "START %.2fx" % (1.0 / s.cam_start.size.x),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_START)
	draw_string(font, re.position + Vector2(6, re.size.y - 8), "END %.2fx" % (1.0 / s.cam_end.size.x),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, COL_END)

	var mark := "at %.2fs" % s.start if s.is_assigned() else "not marked yet"
	draw_string(font, Vector2(12, 20),
			"CAMERA  shot %d/%d (%s)   editing %s   |   1 start  2 end  drag move  wheel zoom  0 full frame  H hold  [ ] shot  Enter apply+preview  Esc cancel" % [
				idx + 1, player.data.shots.size(), mark, "END" if editing_end else "START"],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, act_col)
