class_name Cartoon
extends RefCounted
## Where a cartoon's files live. Every cartoon is one folder under ROOT:
##
##   res://cartoons/<name>/
##       cartoon.json     shot list, timings, framing, transitions
##       audio.wav        the soundtrack (any .wav in the folder works; audio.wav wins)
##       images/          the stills: p1_f1.png, p1_f2.png ...
##
## Paths inside cartoon.json are relative to the cartoon folder ("p1_f1.png",
## "audio.wav"), so a cartoon folder can be renamed, moved, or copied as a unit.

const ROOT := "res://cartoons"
const JSON_NAME := "cartoon.json"
const IMAGES := "images"
const AUDIO_NAME := "audio.wav"
const SETTINGS := "user://settings.cfg"
## Shared files used by every cartoon (the black bookend frame).
const COMMON := "res://common"


## Cartoon folder names, in name order (numbers compared as numbers).
static func list() -> PackedStringArray:
	var out: Array[String] = []
	if DirAccess.dir_exists_absolute(ROOT):
		for d in DirAccess.get_directories_at(ROOT):
			if not d.begins_with("."):
				out.append(d)
	out.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	return PackedStringArray(out)


static func exists(name: String) -> bool:
	return name != "" and DirAccess.dir_exists_absolute(dir(name))


static func dir(name: String) -> String:
	return ROOT + "/" + name


static func images_dir(name: String) -> String:
	return dir(name) + "/" + IMAGES


## The file read and written for this cartoon. Running from the editor it is the
## project copy (so it can be committed); an exported build cannot write to res://,
## so it keeps its own copy in user:// and falls back to the packed one to start.
static func save_path(name: String) -> String:
	return json_res(name) if OS.has_feature("editor") else json_user(name)


static func json_res(name: String) -> String:
	return dir(name) + "/" + JSON_NAME


static func json_user(name: String) -> String:
	return "user://cartoons/%s/%s" % [name, JSON_NAME]


## Soundtrack for a new cartoon: audio.wav if present, else the first .wav in the
## folder, else none. An existing cartoon.json names its own file in audio_path.
static func default_audio(name: String) -> String:
	var d := dir(name)
	if ResourceLoader.exists(d + "/" + AUDIO_NAME):
		return d + "/" + AUDIO_NAME
	var wavs: Array[String] = []
	for f in DirAccess.get_files_at(d):
		var n := f.trim_suffix(".import")  # exported builds list only the .import
		if n.get_extension().to_lower() == "wav" and not n in wavs:
			wavs.append(n)
	wavs.sort()
	return d + "/" + wavs[0] if not wavs.is_empty() else ""


## A usable folder name: not empty, no slashes or other characters files can't have.
static func valid_name(name: String) -> bool:
	return name.strip_edges() != "" and name.is_valid_filename() and not name.begins_with(".")


## Makes the folder skeleton (<name>/images/). Only possible from the editor.
static func create(name: String) -> Error:
	return DirAccess.make_dir_recursive_absolute(images_dir(name))


## --cartoon=<name> on the command line (after "--" for an exported build), or "".
static func from_command_line() -> String:
	for a in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if a.begins_with("--cartoon="):
			return a.trim_prefix("--cartoon=")
	return ""


static func last_opened() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) != OK:
		return ""
	return cfg.get_value("cartoon", "last", "")


static func remember(name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)  # keep anything else in the file
	cfg.set_value("cartoon", "last", name)
	cfg.save(SETTINGS)
