extends Control
## PANEL CROPPER: cuts comic pages into panel images for a cartoon.
## Run this scene from the editor (open tools/panel_cropper.tscn, press F6 / Cmd+R).
##
## 1. Choose the cartoon (top left). Panels are written to its images/ folder.
## 2. Choose the folder of pages (balloon-free pages), once per cartoon.
## 3. Draw a rectangle around each panel, in reading order (the numbers are the frame
##    numbers). The page number comes from the file name; change it in the Page box.
## 4. Export (E) writes p<page>_f<n>.png at the page's full resolution.
##
## The rectangles are kept in cartoons/<name>/crops.json, so a page can be reopened,
## adjusted and exported again (after touching up the page, say) with identical crops.

const HINTS := ("Drag: new panel   Click: select   Drag edge: resize   , / . : earlier / later   "
		+ "Del: delete   Arrows: nudge (Shift x10)   Cmd+Z: undo   [ / ]: prev / next page   "
		+ "E: export   F: fit   Wheel: zoom   Alt-drag: pan")
const CROPS_NAME := "crops.json"
const BAR_H := 108.0

var canvas: CropCanvas
var _cartoon_menu: OptionButton
var _folder_label: Label
var _page_label: Label
var _page_box: SpinBox
var _status: Label
var _hints: Label
var _folder_dialog: FileDialog

var cartoon := ""
var _cartoons: PackedStringArray
var _crops := {}                  # contents of crops.json
var _pages: Array[String] = []    # page file names in the source folder
var _page_i := -1
var _image: Image
var _save_timer: Timer
var _quiet_page_box := false
var _export_armed_until := 0.0  # a page-number clash needs E pressed twice


func _ready() -> void:
	get_window().title = "Panel Cropper"
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	canvas = CropCanvas.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.offset_top = BAR_H
	add_child(canvas)
	canvas.changed.connect(_on_rects_changed)
	canvas.selection_changed.connect(_update_status)

	_build_bar()

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.3
	_save_timer.timeout.connect(_save_crops)
	add_child(_save_timer)

	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.use_native_dialog = true
	_folder_dialog.title = "Choose the folder of pages"
	_folder_dialog.dir_selected.connect(_on_folder_chosen)
	add_child(_folder_dialog)

	_fill_cartoon_menu()
	var start := Cartoon.last_opened()
	_open_cartoon(start if start in _cartoons else (_cartoons[0] if not _cartoons.is_empty() else ""))


func _build_bar() -> void:
	var col := VBoxContainer.new()
	col.position = Vector2(12, 8)
	col.add_theme_constant_override("separation", 8)
	add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)

	row.add_child(_label("Cartoon"))
	_cartoon_menu = OptionButton.new()
	_cartoon_menu.custom_minimum_size = Vector2(260, 32)
	_cartoon_menu.focus_mode = Control.FOCUS_NONE
	_cartoon_menu.item_selected.connect(func(i): _open_cartoon(_cartoons[i]))
	row.add_child(_cartoon_menu)

	row.add_child(_button("Pages folder...", "Choose the folder of balloon-free pages", _folder_dialog_popup))
	_folder_label = _label("")
	_folder_label.custom_minimum_size = Vector2(150, 0)
	_folder_label.clip_text = true
	row.add_child(_folder_label)

	row.add_child(_button("<  Prev", "Previous page  ( [ )", _step_page.bind(-1)))
	_page_label = _label("")
	_page_label.custom_minimum_size = Vector2(170, 0)
	_page_label.clip_text = true
	row.add_child(_page_label)
	row.add_child(_button("Next  >", "Next page  ( ] )", _step_page.bind(1)))

	row.add_child(_label("Page"))
	_page_box = SpinBox.new()
	_page_box.min_value = 0
	_page_box.max_value = 9999
	_page_box.custom_minimum_size = Vector2(90, 32)
	_page_box.tooltip_text = "Page number used in the file names (p<page>_f<n>). Taken from the file name; change it here."
	_page_box.value_changed.connect(_on_page_number_changed)
	row.add_child(_page_box)

	var export := _button("Export  (E)", "Write this page's panels to the cartoon's images folder", _export)
	export.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	row.add_child(export)

	_status = _label("")
	_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	col.add_child(_status)
	_hints = _label(HINTS)
	_hints.add_theme_font_size_override("font_size", 13)
	_hints.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	col.add_child(_hints)


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _button(t: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE  # keys stay with the cropper
	b.custom_minimum_size = Vector2(0, 32)
	b.pressed.connect(handler)
	return b


# ---------------------------------------------------------------- cartoon & crops.json

func _fill_cartoon_menu() -> void:
	_cartoons = Cartoon.list()
	_cartoon_menu.clear()
	for n in _cartoons:
		_cartoon_menu.add_item(n)
	if _cartoons.is_empty():
		_cartoon_menu.add_item("(no cartoons: create one in the player)")
		_cartoon_menu.disabled = true


func _crops_path() -> String:
	return Cartoon.dir(cartoon) + "/" + CROPS_NAME


func _open_cartoon(n: String) -> void:
	_flush_save()
	cartoon = n
	_crops = {"source_dir": "", "last_page": "", "pages": {}}
	_pages.clear()
	_page_i = -1
	if cartoon == "":
		_show_page()
		return
	_cartoon_menu.select(_cartoons.find(cartoon))
	Cartoon.remember(cartoon)
	if FileAccess.file_exists(_crops_path()):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(_crops_path()))
		if typeof(parsed) == TYPE_DICTIONARY:
			_crops.merge(parsed, true)
	_load_folder(_crops.source_dir, _crops.last_page)


func _queue_save() -> void:
	_save_timer.start()


func _flush_save() -> void:
	if _save_timer and not _save_timer.is_stopped():
		_save_timer.stop()
		_save_crops()


func _save_crops() -> void:
	if cartoon == "":
		return
	var f := FileAccess.open(_crops_path(), FileAccess.WRITE)
	if f == null:
		_set_status("Could not write %s (error %d)" % [_crops_path(), FileAccess.get_open_error()], true)
		return
	f.store_string(JSON.stringify(_crops, "\t"))


## The saved entry for a page file: {"page": n, "rects": [[x, y, w, h], ...]}.
func _entry(file: String) -> Dictionary:
	if not _crops.pages.has(file):
		_crops.pages[file] = {"page": _page_from_name(file), "rects": []}
	return _crops.pages[file]


# ---------------------------------------------------------------- pages

func _folder_dialog_popup() -> void:
	if cartoon == "":
		_set_status("Create a cartoon first (Cartoon... in the player).", true)
		return
	if _crops.source_dir != "":
		_folder_dialog.current_dir = _crops.source_dir
	_folder_dialog.popup_centered_ratio(0.6)


func _on_folder_chosen(dir: String) -> void:
	_flush_save()
	_crops.source_dir = dir
	_load_folder(dir, "")
	_queue_save()


func _load_folder(dir: String, start_file: String) -> void:
	_pages.clear()
	if dir != "" and DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			if f.get_extension().to_lower() in PresentationData.IMAGE_EXTS:
				_pages.append(f)
		_pages.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	_folder_label.text = dir.get_file() if dir != "" else "(no folder)"
	_folder_label.tooltip_text = dir
	_page_i = maxi(_pages.find(start_file), 0) if not _pages.is_empty() else -1
	_show_page()
	if dir != "" and _pages.is_empty():
		_set_status("No images in " + dir, true)


func _step_page(step: int) -> void:
	if _pages.is_empty():
		return
	var to := clampi(_page_i + step, 0, _pages.size() - 1)
	if to != _page_i:
		_page_i = to
		_show_page()


func _show_page() -> void:
	_image = null
	var rects: Array[Rect2i] = []
	if _page_i >= 0:
		var file := _pages[_page_i]
		_image = Image.load_from_file(_crops.source_dir.path_join(file))
		for a in _entry(file).rects:
			rects.append(Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3])))
		_crops.last_page = file
		_queue_save()
		_page_label.text = "%s  (%d/%d)" % [file, _page_i + 1, _pages.size()]
		_page_label.tooltip_text = file
		_quiet_page_box = true
		_page_box.value = _entry(file).page
		_quiet_page_box = false
	else:
		_page_label.text = "(no page)"
	canvas.set_image(_image, rects)
	if _page_i >= 0 and _image == null:
		_set_status("Could not load " + _pages[_page_i], true)
	else:
		_update_status()


## Last number in the file name ("CMA 042 page 07.png" -> 7), or the page's position
## in the folder when the name has no number.
func _page_from_name(file: String) -> int:
	var re := RegEx.create_from_string("(\\d+)\\D*$")
	var m := re.search(file.get_basename())
	if m:
		return int(m.get_string(1))
	return _pages.find(file) + 1


func _on_page_number_changed(v: float) -> void:
	if _quiet_page_box or _page_i < 0:
		return
	_entry(_pages[_page_i]).page = int(v)
	_queue_save()
	_update_status()


func _on_rects_changed() -> void:
	if _page_i < 0:
		return
	var arr := []
	for r in canvas.rects:
		arr.append([r.position.x, r.position.y, r.size.x, r.size.y])
	_entry(_pages[_page_i]).rects = arr
	_queue_save()


# ---------------------------------------------------------------- export

func _page_number() -> int:
	return int(_page_box.value)


func _export() -> void:
	if _image == null:
		_set_status("No page to export.", true)
		return
	if canvas.rects.is_empty():
		_set_status("Draw a rectangle around each panel first.", true)
		return
	var page := _page_number()
	var other := _other_page_with(page)
	var now := Time.get_ticks_msec() / 1000.0
	if other != "" and now > _export_armed_until:
		_export_armed_until = now + 4.0
		_set_status("Page %d is also set for %s; exporting would overwrite its panels. Press E again to export anyway." % [page, other], true)
		return
	_export_armed_until = 0.0
	var dest := Cartoon.images_dir(cartoon)
	DirAccess.make_dir_recursive_absolute(dest)
	var failed := 0
	for i in canvas.rects.size():
		var path := dest + "/p%d_f%d.png" % [page, i + 1]
		var err := _image.get_region(canvas.rects[i]).save_png(path)
		if err != OK:
			failed += 1
			push_warning("Could not write %s (error %d)" % [path, err])
	_flush_save()
	_save_crops()

	# Files from an earlier export that this one did not replace.
	var leftovers: Array[String] = []
	var re := RegEx.create_from_string("^p(\\d+)_f(\\d+)\\.(\\w+)$")
	for f in DirAccess.get_files_at(dest):
		var m := re.search(f)
		if m == null or int(m.get_string(1)) != page:
			continue
		var n := int(m.get_string(2))
		var ext := m.get_string(3).to_lower()
		if n > canvas.rects.size() or ext != "png":  # e.g. an older p3_f7, or p3_f1.jpeg
			leftovers.append(f)
	var msg := "Exported %d panel(s) as p%d_f1 .. p%d_f%d.png to %s/images" % [
			canvas.rects.size() - failed, page, page, canvas.rects.size(), cartoon]
	if failed > 0:
		msg += "   %d FAILED (see Output)" % failed
	if not leftovers.is_empty():
		msg += "   Also in the folder, not from this export: " + ", ".join(leftovers)
	_set_status(msg, failed > 0 or not leftovers.is_empty(), 20.0)
	print(msg)


## Another page file with this page number and panels drawn: exporting both would
## overwrite each other's files. Returns its file name, or "".
func _other_page_with(page: int) -> String:
	for file in _crops.pages:
		if file != _pages[_page_i] and int(_crops.pages[file].page) == page and not _crops.pages[file].rects.is_empty():
			return file
	return ""


# ---------------------------------------------------------------- status & keys

var _status_until := 0.0


func _set_status(t: String, warn := false, seconds := 8.0) -> void:
	_status.text = t
	_status.add_theme_color_override("font_color", Color(1, 0.7, 0.35) if warn else Color(0.6, 1, 0.65))
	_status_until = Time.get_ticks_msec() / 1000.0 + seconds


func _update_status() -> void:
	if Time.get_ticks_msec() / 1000.0 < _status_until:
		return
	_status.remove_theme_color_override("font_color")
	_status.add_theme_color_override("font_color", Color(0.75, 0.75, 0.8))
	if cartoon == "":
		_status.text = "No cartoons yet. Create one with Cartoon... in the player, then reopen this tool."
	elif _crops.source_dir == "":
		_status.text = "Choose the folder of pages (Pages folder...)."
	elif canvas.selected >= 0:
		var r := canvas.rects[canvas.selected]
		_status.text = "Selected: p%d_f%d   %d x %d px at (%d, %d)" % [
				_page_number(), canvas.selected + 1, r.size.x, r.size.y, r.position.x, r.position.y]
	else:
		_status.text = "%d panel(s) on this page.  Export writes them as p%d_f1 ... to %s/images" % [
				canvas.rects.size(), _page_number(), cartoon]


func _process(_d: float) -> void:
	if _status_until > 0.0 and Time.get_ticks_msec() / 1000.0 >= _status_until:
		_status_until = 0.0
		_update_status()


## Keys are taken in _input, before the GUI, because arrows and Tab would otherwise
## move keyboard focus between buttons. Typing in the Page box is left alone.
func _input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		if k.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
			get_viewport().gui_release_focus()  # done typing the page number
			get_viewport().set_input_as_handled()
		return
	var step := 10 if k.shift_pressed else 1
	var cmd := k.meta_pressed or k.ctrl_pressed
	match k.keycode:
		KEY_Z when cmd:
			canvas.undo()
		KEY_DELETE, KEY_BACKSPACE:
			canvas.delete_selected()
		KEY_LEFT:
			canvas.nudge(Vector2i(-step, 0))
		KEY_RIGHT:
			canvas.nudge(Vector2i(step, 0))
		KEY_UP:
			canvas.nudge(Vector2i(0, -step))
		KEY_DOWN:
			canvas.nudge(Vector2i(0, step))
		KEY_COMMA:
			canvas.move_order(-1)
		KEY_PERIOD:
			canvas.move_order(1)
		KEY_TAB:
			canvas.select_next(-1 if k.shift_pressed else 1)
		KEY_ESCAPE:
			canvas.deselect()
		KEY_BRACKETLEFT, KEY_PAGEUP:
			_step_page(-1)
		KEY_BRACKETRIGHT, KEY_PAGEDOWN:
			_step_page(1)
		KEY_E:
			_export()
		KEY_F:
			canvas.fit()
		_:
			return
	get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_flush_save()
