class_name Shot
extends Resource
## One shot on the timeline. Camera rects are normalized to the image (0..1).
## Only each rect's center and width are used: width = fraction of image width
## visible, so Rect2(0,0,1,1) = whole image, Rect2(.25,.25,.5,.5) = 2x zoom on center.

enum Easing { LINEAR, SMOOTH, EASE_IN, EASE_OUT }
enum Transition { CUT, CROSSFADE, WIPE, IRIS, MASK_DISSOLVE }
## How an image sits in the frame:
##   FULL        whole image visible (bars on the short axis)
##   VERTICAL    image height fills the frame (bars at the sides, or sides clipped)
##   HORIZONTAL  image width fills the frame (bars top/bottom, or top/bottom clipped)
enum Fit { FULL, VERTICAL, HORIZONTAL }

@export var image_path := ""
## While true the shot is simply "Fit.FULL" and its rects below are ignored.
## The camera editor turns this off as soon as you change the framing.
@export var auto_fit := true
## Seconds on the audio clock. Negative = not yet assigned (tap-to-mark fills these in).
@export var start := -1.0
## Camera move length. 0 = run until the next assigned shot starts.
@export var move_duration := 0.0
@export var cam_start := Rect2(0, 0, 1, 1)
@export var cam_end := Rect2(0, 0, 1, 1)
@export var easing := Easing.SMOOTH
## Transition INTO this shot from the previous one.
@export var transition := Transition.CROSSFADE
@export var transition_duration := 1.0


func is_assigned() -> bool:
	return start >= 0.0


static func ease_value(p: float, e: int) -> float:
	p = clampf(p, 0.0, 1.0)
	match e:
		Easing.SMOOTH:
			return p * p * (3.0 - 2.0 * p)
		Easing.EASE_IN:
			return p * p
		Easing.EASE_OUT:
			return 1.0 - (1.0 - p) * (1.0 - p)
	return p


## Camera width (fraction of image width visible) for a fit mode.
static func fit_width(mode: int, img_size: Vector2, out_aspect: float) -> float:
	var horizontal := 1.0
	var vertical := img_size.y * out_aspect / maxf(img_size.x, 1.0)
	match mode:
		Fit.VERTICAL:
			return vertical
		Fit.HORIZONTAL:
			return horizontal
	return maxf(horizontal, vertical)


static func rect_from_center(center: Vector2, width: float) -> Rect2:
	# Assumes image aspect == output aspect, so normalized height == width.
	return Rect2(center - Vector2(width, width) * 0.5, Vector2(width, width))


func to_dict() -> Dictionary:
	return {
		"image_path": image_path,
		"auto_fit": auto_fit,
		"start": start,
		"move_duration": move_duration,
		"cam_start": [cam_start.position.x, cam_start.position.y, cam_start.size.x, cam_start.size.y],
		"cam_end": [cam_end.position.x, cam_end.position.y, cam_end.size.x, cam_end.size.y],
		"easing": easing,
		"transition": transition,
		"transition_duration": transition_duration,
	}


static func from_dict(d: Dictionary) -> Shot:
	var s := Shot.new()
	s.image_path = d.get("image_path", "")
	s.start = float(d.get("start", -1.0))
	s.move_duration = float(d.get("move_duration", 0.0))
	s.cam_start = _rect(d.get("cam_start", [0, 0, 1, 1]))
	s.cam_end = _rect(d.get("cam_end", [0, 0, 1, 1]))
	# Files saved before auto_fit existed: keep real framing, but a shot still at the
	# untouched default rect was never framed, so treat it as "Full".
	var untouched := s.cam_start == Rect2(0, 0, 1, 1) and s.cam_end == Rect2(0, 0, 1, 1)
	s.auto_fit = bool(d.get("auto_fit", untouched))
	s.easing = int(d.get("easing", Easing.SMOOTH))
	s.transition = int(d.get("transition", Transition.CROSSFADE))
	s.transition_duration = float(d.get("transition_duration", 1.0))
	return s


static func _rect(a: Array) -> Rect2:
	return Rect2(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
