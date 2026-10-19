@tool
extends EditorScript
## ONE-TIME MIGRATION from the single-presentation layout to cartoon folders.
##
##   images/*                 ->  cartoons/<NAME>/images/*
##   images/common/black.png  ->  common/black.png
##   audio_path (audio.wav)   ->  cartoons/<NAME>/audio.wav
##   presentation.json        ->  cartoons/<NAME>/cartoon.json, paths made relative
##                                (the old file is kept as presentation.json.migrated)
##
## Run it: open this file in the Script editor, then File > Run (Ctrl/Cmd+Shift+X).
## The Output panel lists every step. Each image's .import file moves with it, so
## its import settings are kept; Godot re-imports the moved files afterwards.
## It refuses to run if cartoons/<NAME> already exists, so running it twice is safe.
## audio/effects/ is left where it is.

const NAME := "captain_marvel_blood_bank_robbers"
const OLD_JSON := "res://presentation.json"
const OLD_IMAGES := "res://images"

var _errors := 0


func _run() -> void:
	var dst := "res://cartoons/" + NAME
	if DirAccess.dir_exists_absolute(dst):
		printerr("Migration: %s already exists; nothing done." % dst)
		return
	if not FileAccess.file_exists(OLD_JSON):
		printerr("Migration: %s not found; nothing done." % OLD_JSON)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(OLD_JSON))
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("Migration: %s is not valid JSON; nothing done." % OLD_JSON)
		return

	DirAccess.make_dir_recursive_absolute(dst + "/images")
	DirAccess.make_dir_recursive_absolute("res://common")

	# Shared black frame.
	_move_with_import(OLD_IMAGES + "/common/black.png", "res://common/black.png")

	# Images (and their .import files).
	var moved := 0
	for f in DirAccess.get_files_at(OLD_IMAGES):
		if f.ends_with(".import"):
			continue  # moved together with its image
		if _move_with_import(OLD_IMAGES + "/" + f, dst + "/images/" + f):
			moved += 1
	print("Migration: moved %d images" % moved)

	# Soundtrack.
	var audio: String = parsed.get("audio_path", "")
	if audio.begins_with("res://") and FileAccess.file_exists(audio):
		var audio_dst := dst + "/" + audio.get_file()
		_move_with_import(audio, audio_dst)
		parsed["audio_path"] = audio.get_file()
	elif audio != "":
		print("Migration: audio %s not found; audio_path left as it was" % audio)

	# Relative image paths.
	var rewritten := 0
	for sd in parsed.get("shots", []):
		var p: String = sd.get("image_path", "")
		if p.begins_with(OLD_IMAGES + "/"):
			sd["image_path"] = p.trim_prefix(OLD_IMAGES + "/")
			rewritten += 1
	print("Migration: rewrote %d image paths" % rewritten)

	var out := FileAccess.open(dst + "/cartoon.json", FileAccess.WRITE)
	if out == null:
		printerr("Migration: could not write cartoon.json (error %d)" % FileAccess.get_open_error())
		return
	out.store_string(JSON.stringify(parsed, "\t"))
	out.close()
	_rename(OLD_JSON, OLD_JSON + ".migrated")
	var user_json := "user://presentation.json"
	if FileAccess.file_exists(user_json):
		print("Migration: note: %s (an exported build's copy) was not touched" % user_json)

	# Remove the now-empty old folders.
	for d in [OLD_IMAGES + "/common", OLD_IMAGES]:
		if FileAccess.file_exists(d + "/.DS_Store"):  # Finder's; hidden from get_files_at
			DirAccess.remove_absolute(d + "/.DS_Store")
		if DirAccess.get_files_at(d).is_empty() and DirAccess.get_directories_at(d).is_empty():
			DirAccess.remove_absolute(d)
		else:
			print("Migration: %s is not empty, left in place" % d)

	EditorInterface.get_resource_filesystem().scan()
	if _errors == 0:
		print("Migration: done. Open the cartoon from the picker when you run the project.")
	else:
		printerr("Migration: finished with %d error(s); see above." % _errors)


func _move_with_import(from: String, to: String) -> bool:
	if not _rename(from, to):
		return false
	if FileAccess.file_exists(from + ".import"):
		_rename(from + ".import", to + ".import")
	return true


func _rename(from: String, to: String) -> bool:
	var err := DirAccess.rename_absolute(from, to)
	if err != OK:
		printerr("Migration: could not move %s -> %s (error %d)" % [from, to, err])
		_errors += 1
		return false
	return true
