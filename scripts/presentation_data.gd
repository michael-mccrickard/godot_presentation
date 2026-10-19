class_name PresentationData
extends Resource
## The whole cartoon: an audio track plus an ordered list of shots.
## Shot order = list order; start times are assigned by tap-to-mark or dragging.
##
## In memory every path is complete (res://cartoons/<name>/images/p1_f1.png). In the
## JSON, paths inside the cartoon folder are stored relative to it: image paths
## relative to images/, the audio path relative to the folder itself. Any path that
## is already absolute (res://, user://, /...) is kept as written.

const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]

@export var audio_path := ""
@export var shots: Array[Shot] = []
## The cartoon folder (res://cartoons/<name>). Relative paths in the JSON are read
## and written against it. Empty: paths are stored as they are.
var base_dir := ""


func to_json() -> String:
	var arr := []
	for s in shots:
		var sd := s.to_dict()
		sd["image_path"] = _relative(s.image_path, _images_prefix())
		arr.append(sd)
	return JSON.stringify({"audio_path": _relative(audio_path, _base_prefix()), "shots": arr}, "\t")


static func from_json(text: String, base: String = "") -> PresentationData:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d := PresentationData.new()
	d.base_dir = base
	d.audio_path = d._resolve(parsed.get("audio_path", ""), d._base_prefix())
	for sd in parsed.get("shots", []):
		var s := Shot.from_dict(sd)
		s.image_path = d._resolve(s.image_path, d._images_prefix())
		d.shots.append(s)
	return d


func _base_prefix() -> String:
	return base_dir + "/" if base_dir != "" else ""


func _images_prefix() -> String:
	return base_dir + "/" + Cartoon.IMAGES + "/" if base_dir != "" else ""


## Complete path -> what is stored in the JSON.
static func _relative(path: String, prefix: String) -> String:
	if prefix != "" and path.begins_with(prefix):
		return path.trim_prefix(prefix)
	return path


## Stored path -> complete path. Absolute paths (and the demo's demo://) pass through.
static func _resolve(path: String, prefix: String) -> String:
	if path == "" or prefix == "" or path.contains("://") or path.begins_with("/"):
		return path
	return prefix + path


func save_json(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())  # user://cartoons/<name>/
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(to_json())
	return true


static func load_json(path: String, base: String = "") -> PresentationData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return from_json(f.get_as_text(), base)


## Builds a runnable starting point for a cartoon with no cartoon.json: its images
## (or generated test images when it has none), its soundtrack if present.
static func make_demo(cartoon: String) -> PresentationData:
	var d := PresentationData.new()
	d.base_dir = Cartoon.dir(cartoon)
	d.audio_path = Cartoon.default_audio(cartoon)

	var paths := _scan_images(Cartoon.images_dir(cartoon))
	if paths.is_empty():
		for n in 4:
			paths.append("demo://%d" % n)

	var transitions := [
		Shot.Transition.CROSSFADE, Shot.Transition.WIPE,
		Shot.Transition.IRIS, Shot.Transition.MASK_DISSOLVE,
	]
	for i in paths.size():
		var s := Shot.new()
		s.image_path = paths[i]
		if paths[0].begins_with("demo://"):
			s.start = i * 4.0  # generated demo plays by itself
		else:
			# Your own images: every shot waits for you to tap M, the first one included.
			s.start = -1.0
		# Your own images start with cuts; the generated demo shows off the transitions.
		if paths[0].begins_with("demo://") and i > 0:
			s.transition = transitions[(i - 1) % transitions.size()]
		else:
			s.transition = Shot.Transition.CUT
		s.transition_duration = 1.0
		# Your own images start as a static full frame (frame moves with C in the player).
		# Only the generated demo gets sample camera moves, to show what they look like.
		if paths[0].begins_with("demo://"):
			s.auto_fit = false
			if i % 2 == 0:  # push in toward a corner
				s.cam_start = Shot.rect_from_center(Vector2(0.5, 0.5), 1.0)
				s.cam_end = Shot.rect_from_center(Vector2(0.65, 0.4), 0.45)
			else:  # pull out
				s.cam_start = Shot.rect_from_center(Vector2(0.35, 0.6), 0.4)
				s.cam_end = Shot.rect_from_center(Vector2(0.5, 0.5), 1.0)
		d.shots.append(s)
	return d


## Name order that understands numbers: p1_f2 < p1_f10 and p2_f1 < p10_f1, so files
## do not need zero-padded names. Ties (e.g. p1_f1 vs p1_f01) fall back to the full path.
static func natural_less(a: String, b: String) -> bool:
	var c := a.get_file().get_basename().naturalnocasecmp_to(b.get_file().get_basename())
	return c < 0 if c != 0 else a < b


## Name with every number reduced to its value, ignoring folder case and extension, so
## "p1_f01.png" and "p1_f1.jpg" have the same key. Used to recognise a renamed file.
static func name_key(path: String) -> String:
	var base := path.get_file().get_basename().to_lower()
	var out := ""
	var run := ""
	for ch in base + " ":
		if ch >= "0" and ch <= "9":
			run += ch
		else:
			if run != "":
				out += str(int(run))
				run = ""
			out += ch
	return out.strip_edges()


## Seconds each shot lasts in a scaffolded presentation.
const SCAFFOLD_SECONDS := 2.0


## Black frame copied in to bookend the images, so a presentation can fade in from
## and out to black. p0_f0 sorts before every other image, zzz after all of them.
const BLACK_SOURCE := Cartoon.COMMON + "/black.png"
const BLACK_BOOKENDS := ["p0_f0.png", "zzz.png"]


## Copies BLACK_SOURCE into `dir` as each of BLACK_BOOKENDS (overwriting). Called by
## the first-run setup, before the images are scanned. Returns how many were written.
static func add_black_bookends(dir: String) -> int:
	var bytes := PackedByteArray()
	if FileAccess.file_exists(BLACK_SOURCE):
		bytes = FileAccess.get_file_as_bytes(BLACK_SOURCE)
	if bytes.is_empty() and ResourceLoader.exists(BLACK_SOURCE):
		# Exported build: only the imported texture is packed, so re-encode it.
		var tex: Texture2D = load(BLACK_SOURCE)
		if tex:
			bytes = tex.get_image().save_png_to_buffer()
	if bytes.is_empty():
		push_warning("Black bookends: could not read " + BLACK_SOURCE)
		return 0
	var written := 0
	for name in BLACK_BOOKENDS:
		var path: String = dir + "/" + name
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_warning("Black bookends: could not write %s (error %d)" % [path, FileAccess.get_open_error()])
			continue
		f.store_buffer(bytes)
		f.close()
		written += 1
	return written


## How many images `dir` holds.
static func image_count(dir: String) -> int:
	return _scan_images(dir).size()


## A complete starting point: every image of the cartoon, in name order, one shot
## each, SCAFFOLD_SECONDS long, joined by hard cuts, framed Full. Retime by dragging markers.
static func make_scaffold(cartoon: String, seconds: float = SCAFFOLD_SECONDS) -> PresentationData:
	var d := PresentationData.new()
	d.base_dir = Cartoon.dir(cartoon)
	d.audio_path = Cartoon.default_audio(cartoon)
	var i := 0
	for p in _scan_images(Cartoon.images_dir(cartoon)):
		var s := Shot.new()
		s.image_path = p
		s.start = i * seconds
		s.transition = Shot.Transition.CUT
		d.shots.append(s)
		i += 1
	return d


## Brings the shot list up to date with the images in `dir`. Returns
## {"added": n, "relinked": n}.
##  - An image no shot uses becomes a new, unmarked shot, placed by name: right after
##    the last shot whose name sorts at or before it.
##  - A shot whose file is gone, but whose name matches a new file apart from zero
##    padding or extension (p1_f1.png -> p1_f01.png), is pointed at the new file instead
##    of creating a duplicate, so its marks and framing are kept.
## Existing shots are never reordered or removed.
func add_new_images(dir: String) -> Dictionary:
	var on_disk := _scan_images(dir)
	var on_disk_set := {}
	for p in on_disk:
		on_disk_set[p] = true
	var known := {}
	for s in shots:
		known[s.image_path] = true

	var added := 0
	var relinked := 0
	for p in on_disk:
		if known.has(p):
			continue
		# Renamed file? Reuse the shot whose old file is missing and whose name matches.
		var key := name_key(p)
		var adopted := false
		for s in shots:
			if s.image_path.begins_with(dir) and not on_disk_set.has(s.image_path) \
					and name_key(s.image_path) == key:
				s.image_path = p
				known[p] = true
				relinked += 1
				adopted = true
				break
		if adopted:
			continue
		var n := Shot.new()
		n.image_path = p
		n.start = -1.0
		n.transition = Shot.Transition.CUT
		n.transition_duration = 1.0
		var at := 0
		for i in shots.size():
			if not natural_less(p, shots[i].image_path):  # shot sorts at or before p
				at = i + 1
		shots.insert(at, n)
		known[p] = true
		added += 1
	return {"added": added, "relinked": relinked}


static func _scan_images(dir: String) -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		# Exported builds list "foo.png.import"; the editor lists both.
		var name := f.trim_suffix(".import")
		if name.get_extension().to_lower() in IMAGE_EXTS and not (dir + "/" + name) in out:
			out.append(dir + "/" + name)
	out.sort_custom(natural_less)
	return out
