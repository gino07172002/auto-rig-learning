extends RefCounted
class_name RecentFiles

# Persists "recently opened" file paths across sessions, so the user can reload a
# model or animation without re-browsing. Stored as a ConfigFile in user:// (the
# per-user data dir in an exported build), keyed by category ("model" / "anim").
# Most-recent first, de-duplicated, capped to MAX_ENTRIES.

const SAVE_PATH := "user://recent_files.cfg"
const SECTION := "recent"
const MAX_ENTRIES := 8

var _config := ConfigFile.new()

func _init() -> void:
	# Missing file is fine (first run); other errors leave an empty config.
	_config.load(SAVE_PATH)

# Returns the recent paths for a category (most-recent first), filtered to ones
# that still exist on disk so the list never offers a dead entry.
func get_recent(category: String) -> PackedStringArray:
	_config.load(SAVE_PATH)  # always read the latest on-disk state
	var raw: PackedStringArray = _config.get_value(SECTION, category, PackedStringArray())
	var alive := PackedStringArray()
	for p in raw:
		if FileAccess.file_exists(p):
			alive.append(p)
	# Persist the pruned list if anything was dropped.
	if alive.size() != raw.size():
		_config.set_value(SECTION, category, alive)
		_config.save(SAVE_PATH)
	return alive

# Records `path` as the most-recent entry for `category` and saves immediately.
func add(category: String, path: String) -> void:
	if path.strip_edges() == "":
		return
	# Reload from disk first so we merge with the latest saved state instead of
	# overwriting it. Without this, a stale or empty in-memory config (e.g. another
	# app instance saved since we loaded, or the initial load failed) would wipe the
	# OTHER category and any entries we hadn't seen — which dropped recents to one.
	_config.load(SAVE_PATH)
	var list: PackedStringArray = _config.get_value(SECTION, category, PackedStringArray())
	# Move-to-front: drop any existing occurrence, then prepend.
	var rebuilt := PackedStringArray([path])
	for p in list:
		if p != path and rebuilt.size() < MAX_ENTRIES:
			rebuilt.append(p)
	_config.set_value(SECTION, category, rebuilt)
	_config.save(SAVE_PATH)
