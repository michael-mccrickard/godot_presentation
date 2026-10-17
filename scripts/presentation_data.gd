class_name PresentationData
extends Resource
## The whole presentation: an audio track plus an ordered list of shots.
## Shot order = list order; start times are assigned by tap-to-mark or dragging.

const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]

@export var audio_path := ""
@export var shots: Array[Shot] = []


func to_json() -> String:
	var arr := []
	for s in shots:
		arr.append(s.to_dict())
	return JSON.stringify({"audio_path": audio_path, "shots": arr}, "\t")


static func from_json(text: String) -> PresentationData:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var d := PresentationData.new()
	d.audio_path = parsed.get("audio_path", "")
	for sd in parsed.get("shots", []):
		d.shots.append(Shot.from_dict(sd))
	return d


func save_json(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(to_json())
	return true


static func load_json(path: String) -> PresentationData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return from_json(f.get_as_text())


## Builds a runnable demo: images from res://images (or generated test images),
## audio from res://audio/track.wav if present, evenly spaced starts.
static func make_demo() -> PresentationData:
	var d := PresentationData.new()
	if ResourceLoader.exists("res://audio/track.wav"):
		d.audio_path = "res://audio/track.wav"

	var paths := _scan_images("res://images")
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
			# Your own images: shot 1 at 0, the rest wait for you to tap M.
			s.start = 0.0 if i == 0 else -1.0
		s.transition = Shot.Transition.CUT if i == 0 else transitions[(i - 1) % transitions.size()]
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


## How many images `dir` holds.
static func image_count(dir: String) -> int:
	return _scan_images(dir).size()


## A complete starting point: every image in `dir`, in name order, one shot each,
## SCAFFOLD_SECONDS long, joined by hard cuts, framed Full. Retime by dragging markers.
static func make_scaffold(dir: String = "res://images", seconds: float = SCAFFOLD_SECONDS) -> PresentationData:
	var d := PresentationData.new()
	if ResourceLoader.exists("res://audio/track.wav"):
		d.audio_path = "res://audio/track.wav"
	var i := 0
	for p in _scan_images(dir):
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
		n.transition = Shot.Transition.CROSSFADE
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
	for f in DirAccess.get_files_at(dir):
		# Exported builds list "foo.png.import"; the editor lists both.
		var name := f.trim_suffix(".import")
		if name.get_extension().to_lower() in IMAGE_EXTS and not (dir + "/" + name) in out:
			out.append(dir + "/" + name)
	out.sort_custom(natural_less)
	return out
