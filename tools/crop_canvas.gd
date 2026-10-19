class_name CropCanvas
extends Control
## Shows one comic page and the panel rectangles drawn on it.
##   Drag on empty space      new rectangle
##   Click a rectangle        select it;  drag inside to move it
##   Drag an edge or corner   resize the selected rectangle
##   Wheel / pinch            zoom around the cursor
##   Middle-drag, Alt-drag, two-finger scroll   pan
## Rectangles are in image pixels; their order is the frame order (f1, f2 ...).

signal changed            # rectangles added, moved, resized, deleted or reordered
signal selection_changed

const HANDLE_PX := 9.0    # how close (screen px) to an edge counts as grabbing it
const MIN_SIZE := 8       # smallest rectangle, image px
const UNDO_MAX := 100

var tex: ImageTexture
var img_size := Vector2i.ZERO
var rects: Array[Rect2i] = []
var selected := -1

enum Drag { NONE, CREATE, MOVE, RESIZE, PAN }
var _drag := Drag.NONE
var _scale := 1.0
var _offset := Vector2.ZERO
var _press_img := Vector2.ZERO     # mouse position at press, image px
var _press_scr := Vector2.ZERO
var _orig := Rect2i()              # rectangle being moved/resized, before the drag
var _live := Rect2i()              # rectangle being drawn
var _edge := Vector2i.ZERO         # which edges a resize moves: x -1 left / 1 right, y -1 top / 1 bottom
var _before: Array[Rect2i] = []    # state at press, for undo
var _undo: Array = []


func _ready() -> void:
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	resized.connect(fit)


func set_image(image: Image, new_rects: Array[Rect2i]) -> void:
	tex = ImageTexture.create_from_image(image) if image else null
	img_size = image.get_size() if image else Vector2i.ZERO
	rects = new_rects.duplicate()
	selected = -1
	_undo.clear()
	_drag = Drag.NONE
	fit()
	selection_changed.emit()


## Whole page in view.
func fit() -> void:
	if img_size == Vector2i.ZERO or size.x < 1 or size.y < 1:
		return
	_scale = minf(size.x / img_size.x, size.y / img_size.y) * 0.97
	_offset = (size - Vector2(img_size) * _scale) * 0.5
	queue_redraw()


func to_img(p: Vector2) -> Vector2:
	return (p - _offset) / _scale


func to_scr(p: Vector2) -> Vector2:
	return p * _scale + _offset


func _scr_rect(r: Rect2i) -> Rect2:
	return Rect2(to_scr(Vector2(r.position)), Vector2(r.size) * _scale)


# ---------------------------------------------------------------- editing

func delete_selected() -> void:
	if selected < 0:
		return
	_push_undo()
	rects.remove_at(selected)
	selected = mini(selected, rects.size() - 1)
	_changed()


## Moves the selected rectangle earlier (-1) or later (+1) in frame order.
func move_order(step: int) -> void:
	var to := selected + step
	if selected < 0 or to < 0 or to >= rects.size():
		return
	_push_undo()
	var r := rects[selected]
	rects.remove_at(selected)
	rects.insert(to, r)
	selected = to
	_changed()


func nudge(d: Vector2i) -> void:
	if selected < 0:
		return
	_push_undo()
	rects[selected] = _clamp_move(Rect2i(rects[selected].position + d, rects[selected].size))
	_changed()


func select_next(step: int) -> void:
	if rects.is_empty():
		return
	selected = posmod(selected + step, rects.size()) if selected >= 0 else 0
	queue_redraw()
	selection_changed.emit()


func deselect() -> void:
	selected = -1
	queue_redraw()
	selection_changed.emit()


func undo() -> void:
	if _undo.is_empty():
		return
	rects = _undo.pop_back()
	selected = mini(selected, rects.size() - 1)
	_changed()


func _push_undo() -> void:
	_push_state(rects)


func _push_state(state: Array[Rect2i]) -> void:
	_undo.append(state.duplicate())
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()


func _changed() -> void:
	queue_redraw()
	changed.emit()
	selection_changed.emit()


# ---------------------------------------------------------------- mouse

func _gui_input(e: InputEvent) -> void:
	if tex == null:
		return
	var mb := e as InputEventMouseButton
	if mb:
		if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_zoom_at(mb.position, 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE or (mb.button_index == MOUSE_BUTTON_LEFT and mb.alt_pressed and mb.pressed):
			_drag = Drag.PAN if mb.pressed else Drag.NONE
			_press_scr = mb.position
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				grab_focus()
				_press(mb.position)
			else:
				_release()
		accept_event()
		return
	var mm := e as InputEventMouseMotion
	if mm:
		_motion(mm.position)
		accept_event()
		return
	var pan := e as InputEventPanGesture  # two-finger scroll on a trackpad
	if pan:
		_offset -= pan.delta * 12.0
		queue_redraw()
		accept_event()
		return
	var mag := e as InputEventMagnifyGesture  # pinch
	if mag:
		_zoom_at(mag.position, mag.factor)
		accept_event()


func _zoom_at(p: Vector2, f: float) -> void:
	var s := clampf(_scale * f, 0.02, 16.0)
	_offset = p - (p - _offset) * (s / _scale)
	_scale = s
	queue_redraw()


func _press(p: Vector2) -> void:
	_press_scr = p
	_press_img = to_img(p)
	_before = rects.duplicate()
	if selected >= 0:
		var edge := _edge_at(p, selected)
		if edge != Vector2i.ZERO:
			_drag = Drag.RESIZE
			_edge = edge
			_orig = rects[selected]
			return
	var hit := _rect_at(p)
	if hit >= 0:
		selected = hit
		_drag = Drag.MOVE
		_orig = rects[hit]
		selection_changed.emit()
	else:
		selected = -1
		_drag = Drag.CREATE
		_live = Rect2i(_clamp_point(_press_img), Vector2i.ZERO)
		selection_changed.emit()
	queue_redraw()


func _motion(p: Vector2) -> void:
	var img := to_img(p)
	var d := Vector2i((img - _press_img).round())
	match _drag:
		Drag.PAN:
			_offset += p - _press_scr
			_press_scr = p
		Drag.CREATE:
			var a := _clamp_point(_press_img)
			var b := _clamp_point(img)
			_live = Rect2i(Vector2i(mini(a.x, b.x), mini(a.y, b.y)), (b - a).abs())
		Drag.MOVE:
			rects[selected] = _clamp_move(Rect2i(_orig.position + d, _orig.size))
		Drag.RESIZE:
			rects[selected] = _resized(d)
		Drag.NONE:
			_update_cursor(p)
			return
	queue_redraw()


func _release() -> void:
	match _drag:
		Drag.CREATE:
			if _live.size.x >= MIN_SIZE and _live.size.y >= MIN_SIZE:
				_push_state(_before)
				rects.append(_live)
				selected = rects.size() - 1
				_changed()
		Drag.MOVE, Drag.RESIZE:
			if rects != _before:
				_push_state(_before)
				_changed()
	_drag = Drag.NONE
	_live = Rect2i()
	queue_redraw()


func _resized(d: Vector2i) -> Rect2i:
	var l := _orig.position.x
	var t := _orig.position.y
	var r := _orig.end.x
	var b := _orig.end.y
	if _edge.x < 0:
		l = clampi(l + d.x, 0, r - MIN_SIZE)
	elif _edge.x > 0:
		r = clampi(r + d.x, l + MIN_SIZE, img_size.x)
	if _edge.y < 0:
		t = clampi(t + d.y, 0, b - MIN_SIZE)
	elif _edge.y > 0:
		b = clampi(b + d.y, t + MIN_SIZE, img_size.y)
	return Rect2i(l, t, r - l, b - t)


func _clamp_point(p: Vector2) -> Vector2i:
	return Vector2i(clampi(roundi(p.x), 0, img_size.x), clampi(roundi(p.y), 0, img_size.y))


func _clamp_move(r: Rect2i) -> Rect2i:
	r.position.x = clampi(r.position.x, 0, img_size.x - r.size.x)
	r.position.y = clampi(r.position.y, 0, img_size.y - r.size.y)
	return r


## Topmost rectangle under the point (later ones are drawn on top), or -1.
func _rect_at(p: Vector2) -> int:
	for i in range(rects.size() - 1, -1, -1):
		if _scr_rect(rects[i]).has_point(p):
			return i
	return -1


## Which edges of rectangle i the point grabs, or ZERO.
func _edge_at(p: Vector2, i: int) -> Vector2i:
	var r := _scr_rect(i_rect(i))
	if not r.grow(HANDLE_PX).has_point(p):
		return Vector2i.ZERO
	var e := Vector2i.ZERO
	if absf(p.x - r.position.x) <= HANDLE_PX:
		e.x = -1
	elif absf(p.x - r.end.x) <= HANDLE_PX:
		e.x = 1
	if absf(p.y - r.position.y) <= HANDLE_PX:
		e.y = -1
	elif absf(p.y - r.end.y) <= HANDLE_PX:
		e.y = 1
	return e


func i_rect(i: int) -> Rect2i:
	return rects[i]


func _update_cursor(p: Vector2) -> void:
	var e := _edge_at(p, selected) if selected >= 0 else Vector2i.ZERO
	if e.x != 0 and e.y != 0:
		mouse_default_cursor_shape = CURSOR_FDIAGSIZE if e.x == e.y else CURSOR_BDIAGSIZE
	elif e.x != 0:
		mouse_default_cursor_shape = CURSOR_HSIZE
	elif e.y != 0:
		mouse_default_cursor_shape = CURSOR_VSIZE
	elif _rect_at(p) >= 0:
		mouse_default_cursor_shape = CURSOR_MOVE
	else:
		mouse_default_cursor_shape = CURSOR_CROSS


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.16, 0.16, 0.18))
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(_offset, Vector2(img_size) * _scale), false)
	var font := get_theme_default_font()
	for i in rects.size():
		var r := _scr_rect(rects[i])
		var sel := i == selected
		var col := Color(0.2, 0.85, 1.0) if sel else Color(1.0, 0.85, 0.1)
		draw_rect(r, Color(col, 0.10))
		draw_rect(r, col, false, 3.0 if sel else 2.0)
		var label := "f%d" % (i + 1)
		var fs := 22
		var ts := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var tag := Rect2(r.position + Vector2(3, 3), ts + Vector2(10, 4))
		draw_rect(tag, Color(0, 0, 0, 0.75))
		draw_string(font, tag.position + Vector2(5, ts.y - 2), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		if sel:
			for c in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
				draw_rect(Rect2(c - Vector2(5, 5), Vector2(10, 10)), col)
	if _drag == Drag.CREATE and _live.size != Vector2i.ZERO:
		draw_rect(_scr_rect(_live), Color(1, 1, 1, 0.9), false, 2.0)
