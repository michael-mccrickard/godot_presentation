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


static func _scan_images(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		# Exported builds list "foo.png.import"; the editor lists both.
		var name := f.trim_suffix(".import")
		if name.get_extension().to_lower() in IMAGE_EXTS and not (dir + "/" + name) in out:
			out.append(dir + "/" + name)
	out.sort()
	return out
