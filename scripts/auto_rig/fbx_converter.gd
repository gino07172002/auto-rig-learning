extends RefCounted
class_name FbxConverter

# Converts an FBX model (e.g. a Mixamo download) to a glTF binary (.glb) so the
# rest of the tool — which only speaks glTF via GLTFDocument — can load it. The
# conversion shells out to a headless Blender, which is the one FBX importer we
# can rely on across platforms.
#
# Resolution order for the Blender executable:
#   1. The `blender_override` property (tests / explicit callers).
#   2. The AUTO_RIG_LAB_BLENDER environment variable (full path to blender[.exe]).
#   3. Common per-platform install locations — newest version wins when several
#      are installed. Checked before PATH so probing a missing PATH entry can't
#      emit a spurious "could not create child process" error.
#   4. A bare "blender" resolved via PATH.
#
# Converted files are cached in user://fbx_cache under a name derived from the
# source filename + a hash of its full path (so same-named FBX files in different
# folders don't collide). A cached .glb is reused only when it's at least as new
# as the source FBX, so editing the FBX triggers a reconvert. Nothing is written
# to the user's source folder.

const CONVERT_SCRIPT_RES := "res://scripts/auto_rig/fbx_to_glb_blender.py"

var last_error := ""
# Set by callers/tests to force a specific Blender; empty = auto-detect.
var blender_override := ""

# Returns true if the path looks like an FBX we should convert.
static func is_fbx(path: String) -> bool:
	return path.to_lower().get_extension() == "fbx"

# Converts `fbx_path` (an absolute filesystem path) to a .glb and returns the
# absolute path to the cached .glb, or "" on failure (with last_error set).
func convert_to_glb(fbx_path: String) -> String:
	last_error = ""
	if not FileAccess.file_exists(fbx_path):
		last_error = "FBX not found: %s" % fbx_path
		return ""

	var out_path := _cache_path_for(fbx_path)
	# Reuse a previous conversion if it's newer than the source FBX.
	if FileAccess.file_exists(out_path):
		var src_mtime := FileAccess.get_modified_time(fbx_path)
		var glb_mtime := FileAccess.get_modified_time(out_path)
		if glb_mtime >= src_mtime:
			return out_path

	var blender := _find_blender()
	if blender == "":
		last_error = "Blender not found. Set the AUTO_RIG_LAB_BLENDER environment variable to your blender executable, or install Blender, to import FBX files."
		return ""

	var script_path := _resolved_script_path()
	if script_path == "":
		last_error = "Conversion script missing: %s" % CONVERT_SCRIPT_RES
		return ""

	# Headless Blender: blender -b --python fbx_to_glb_blender.py -- <in.fbx> <out.glb>
	var args := PackedStringArray([
		"-b", "--python", script_path, "--",
		fbx_path, out_path,
	])
	var output: Array = []
	var exit_code := OS.execute(blender, args, output, true)
	if exit_code != 0 or not FileAccess.file_exists(out_path):
		var log_text := "\n".join(output) if output.size() > 0 else "(no output)"
		last_error = "Blender FBX->glb conversion failed (exit %d).\n%s" % [exit_code, log_text]
		return ""
	return out_path

# Returns a real on-disk path to the Blender conversion script, or "" if it is
# unavailable. In the editor the res:// script is a loose file we can hand to
# Blender directly. In an exported build it lives inside the PCK (a virtual
# path OS.execute can't reach), so we read it through FileAccess and stage a copy
# under user:// that Blender can actually open.
func _resolved_script_path() -> String:
	var direct := ProjectSettings.globalize_path(CONVERT_SCRIPT_RES)
	if FileAccess.file_exists(direct):
		return direct
	var src := FileAccess.open(CONVERT_SCRIPT_RES, FileAccess.READ)
	if src == null:
		return ""
	var text := src.get_as_text()
	src.close()
	var staged := "user://fbx_to_glb_blender.py"
	var dst := FileAccess.open(staged, FileAccess.WRITE)
	if dst == null:
		return ""
	dst.store_string(text)
	dst.close()
	return ProjectSettings.globalize_path(staged)

# Picks the cached .glb path for a source FBX. Uses a hash of the source path so
# two different "X Bot.fbx" files in different folders don't collide.
func _cache_path_for(fbx_path: String) -> String:
	var base := fbx_path.get_file().get_basename()
	var key := str(hash(fbx_path))
	var dir := "user://fbx_cache"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return ProjectSettings.globalize_path("%s/%s_%s.glb" % [dir, base, key])

# Locates a Blender executable, or "" if none is found.
func _find_blender() -> String:
	if blender_override != "" and FileAccess.file_exists(blender_override):
		return blender_override
	var env := OS.get_environment("AUTO_RIG_LAB_BLENDER")
	if env != "" and FileAccess.file_exists(env):
		return env
	# Prefer a concrete install location (no false ERROR log from probing a
	# missing PATH entry); pick the NEWEST version when several are installed so
	# users don't silently get an older FBX importer. Fall back to a bare
	# "blender" resolved via PATH.
	var candidates: Array = []
	for candidate in _platform_candidates():
		if FileAccess.file_exists(candidate):
			candidates.append(candidate)
	if candidates.size() > 0:
		candidates.sort_custom(_newer_first)
		return candidates[0]
	if _blender_on_path():
		return "blender"
	return ""

# Orders two Blender executable paths so the newer version sorts first. The
# version is parsed from the install folder name (e.g. "Blender 5.1",
# "blender-2.80.0-..."); unparseable paths sort last.
func _newer_first(a: String, b: String) -> bool:
	return _version_key(a) > _version_key(b)

# Extracts a comparable version number from a Blender path's folder name. Returns
# major*1000 + minor (e.g. 5.1 -> 5001, 2.80 -> 2080), or -1 when no version is
# found so such paths sort after any real version.
func _version_key(path: String) -> int:
	var folder := path.get_base_dir().get_file()
	var regex := RegEx.new()
	regex.compile("(\\d+)\\.(\\d+)")
	var m := regex.search(folder)
	if m == null:
		return -1
	return int(m.get_string(1)) * 1000 + int(m.get_string(2))

# True if a bare "blender" resolves via PATH. Checked by scanning PATH entries
# ourselves so a missing executable doesn't emit an engine "could not create
# child process" error (which OS.execute logs unconditionally).
func _blender_on_path() -> bool:
	var exe := "blender.exe" if OS.get_name() == "Windows" else "blender"
	var sep := ";" if OS.get_name() == "Windows" else ":"
	for entry in OS.get_environment("PATH").split(sep, false):
		if FileAccess.file_exists("%s/%s" % [entry, exe]):
			return true
	return false

# All Blender executables found at common install locations for this OS, in no
# particular order (the caller sorts by version to pick the newest).
func _platform_candidates() -> Array:
	var found: Array = []
	var roots: Array = []
	match OS.get_name():
		"Windows":
			roots = [
				"C:/Program Files/Blender Foundation",
				"C:/Program Files (x86)/Blender Foundation",
			]
			_collect_blender_under(roots, "blender.exe", found)
			# Loose installs sometimes drop a versioned folder at the drive root.
			_collect_blender_under(["D:/", "C:/"], "blender.exe", found, false)
		"macOS":
			found.append("/Applications/Blender.app/Contents/MacOS/Blender")
		_:
			found.append("/usr/bin/blender")
			found.append("/usr/local/bin/blender")
			found.append("/snap/bin/blender")
	return found

# Scans each root for "blender.exe" one (or, when recurse, two) levels deep,
# appending any hits. Keeps the search shallow so it stays fast.
func _collect_blender_under(roots: Array, exe: String, out: Array, recurse: bool = true) -> void:
	for root in roots:
		if not DirAccess.dir_exists_absolute(root):
			continue
		var direct := "%s/%s" % [root, exe]
		if FileAccess.file_exists(direct):
			out.append(direct)
		var dir := DirAccess.open(root)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if dir.current_is_dir() and not name.begins_with("."):
				var sub := "%s/%s/%s" % [root, name, exe]
				if FileAccess.file_exists(sub):
					out.append(sub)
				if recurse:
					# One more level (e.g. "Blender 4.2/blender.exe").
					var sub2 := "%s/%s" % [root, name]
					_collect_blender_under([sub2], exe, out, false)
			name = dir.get_next()
		dir.list_dir_end()
