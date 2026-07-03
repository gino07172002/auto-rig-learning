extends RefCounted
class_name FbxParser

# Pure-GDScript reader for binary FBX files (Kaydara FBX Binary, the format Mixamo
# and most DCC tools export). Parses the node/property record tree into nested
# dictionaries so higher layers can pull out meshes, the armature, and skin
# weights without any external tool (no Blender dependency).
#
# Scope: binary FBX, versions 7100-7700. ASCII FBX is detected and rejected with
# a clear message. Animation curves are intentionally not parsed (the tool only
# needs the rest skeleton + skinned geometry).
#
# A parsed node is a Dictionary:
#   { "name": String, "props": Array, "children": Array[Dictionary] }
# `props` holds GDScript-native values: bool/int/float for scalars, String for
# "S", PackedByteArray for "R", and a typed Packed*Array for array properties
# (PackedFloat64Array, PackedInt32Array, PackedInt64Array, ...).

const MAGIC := "Kaydara FBX Binary  "  # 20 bytes, then 0x00 0x1A 0x00

var error := ""
var version := 0

# Parses the file at `path`. Returns the synthetic root node (name "") whose
# children are the top-level records, or an empty dict ({}) on error (with
# `error` set).
func parse_file(path: String) -> Dictionary:
	error = ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		error = "Cannot open FBX: %s" % path
		return {}
	var data := f.get_buffer(f.get_length())
	f.close()
	return parse_bytes(data)

# Parses an in-memory FBX byte buffer (see parse_file).
func parse_bytes(data: PackedByteArray) -> Dictionary:
	error = ""
	if data.size() < 27:
		error = "FBX too small to be valid"
		return {}
	var magic := data.slice(0, 20).get_string_from_ascii()
	if magic != MAGIC:
		# ASCII FBX is human-readable text and typically opens with a comment ";".
		var head := data.slice(0, 64).get_string_from_ascii()
		if head.begins_with(";") or head.find("FBX") != -1:
			error = "ASCII FBX is not supported (only binary FBX). Re-export as binary."
		else:
			error = "Not a binary FBX (bad magic)."
		return {}
	version = data.decode_u32(23)
	# Records use 64-bit offsets/sizes from version 7500 onward, 32-bit before.
	var wide := version >= 7500
	var root := {"name": "", "props": [], "children": []}
	var pos := 27
	while true:
		var res := _read_node(data, pos, wide)
		if res.is_empty():
			break
		if res["node"].is_empty():
			# Null record terminator at this level.
			break
		root["children"].append(res["node"])
		pos = res["next"]
		if pos <= 0 or pos >= data.size():
			break
	if error != "":
		return {}
	return root

# Reads one node record at `pos`. Returns { "node": Dictionary, "next": int }.
# A null record (all-zero header) yields { "node": {}, "next": pos_after_header }.
# Returns {} only on a hard parse error (error set).
func _read_node(data: PackedByteArray, pos: int, wide: bool) -> Dictionary:
	var end_offset: int
	var num_props: int
	var prop_list_len: int
	var name_len: int
	if wide:
		if pos + 25 > data.size():
			return {}
		end_offset = data.decode_u64(pos)
		num_props = data.decode_u64(pos + 8)
		prop_list_len = data.decode_u64(pos + 16)
		name_len = data[pos + 24]
		pos += 25
	else:
		if pos + 13 > data.size():
			return {}
		end_offset = data.decode_u32(pos)
		num_props = data.decode_u32(pos + 4)
		prop_list_len = data.decode_u32(pos + 8)
		name_len = data[pos + 12]
		pos += 13
	# A null record (sentinel) has a zero end_offset.
	if end_offset == 0:
		return {"node": {}, "next": pos}
	var name := data.slice(pos, pos + name_len).get_string_from_ascii()
	pos += name_len
	var props: Array = []
	for i in range(num_props):
		var pr := _read_property(data, pos)
		if pr.is_empty():
			return {}
		props.append(pr["value"])
		pos = pr["next"]
	# After the property list, nested child records run until end_offset. A
	# 13/25-byte null record separates the children block from the node end.
	var node := {"name": name, "props": props, "children": []}
	if pos < end_offset:
		while pos < end_offset:
			var res := _read_node(data, pos, wide)
			if res.is_empty():
				return {}
			if res["node"].is_empty():
				pos = res["next"]
				break
			node["children"].append(res["node"])
			pos = res["next"]
	return {"node": node, "next": end_offset}

# Reads one property at `pos`. Returns { "value": Variant, "next": int } or {}.
func _read_property(data: PackedByteArray, pos: int) -> Dictionary:
	var type_code := data[pos]
	pos += 1
	match type_code:
		0x59:  # 'Y' int16
			return {"value": data.decode_s16(pos), "next": pos + 2}
		0x43:  # 'C' bool (1 byte)
			return {"value": data[pos] != 0, "next": pos + 1}
		0x49:  # 'I' int32
			return {"value": data.decode_s32(pos), "next": pos + 4}
		0x46:  # 'F' float32
			return {"value": data.decode_float(pos), "next": pos + 4}
		0x44:  # 'D' float64
			return {"value": data.decode_double(pos), "next": pos + 8}
		0x4C:  # 'L' int64
			return {"value": data.decode_s64(pos), "next": pos + 8}
		0x53:  # 'S' string (length-prefixed; FBX joins "Name\x00\x01Class")
			var slen := data.decode_u32(pos)
			pos += 4
			var bytes := data.slice(pos, pos + slen)
			# Stop at the first NUL so get_string_from_ascii doesn't warn on the
			# "\x00\x01Class" tail; callers that need the class can re-split.
			var nul := bytes.find(0)
			var s: String
			if nul != -1:
				s = bytes.slice(0, nul).get_string_from_ascii()
			else:
				s = bytes.get_string_from_ascii()
			return {"value": s, "next": pos + slen}
		0x52:  # 'R' raw bytes
			var rlen := data.decode_u32(pos)
			pos += 4
			return {"value": data.slice(pos, pos + rlen), "next": pos + rlen}
		0x66, 0x64, 0x6C, 0x69, 0x62:  # 'f','d','l','i','b' arrays
			return _read_array(data, pos, type_code)
		_:
			error = "Unknown FBX property type 0x%02X at %d" % [type_code, pos - 1]
			return {}

# Reads an array property body (header: arraylen, encoding, complen). Decodes the
# raw or zlib-deflated payload into a typed Packed*Array.
func _read_array(data: PackedByteArray, pos: int, type_code: int) -> Dictionary:
	var array_len := data.decode_u32(pos)
	var encoding := data.decode_u32(pos + 4)
	var comp_len := data.decode_u32(pos + 8)
	pos += 12
	var elem_size := _element_size(type_code)
	var raw_size := array_len * elem_size
	var payload := data.slice(pos, pos + comp_len)
	var next := pos + comp_len
	var raw: PackedByteArray
	if encoding == 1:
		raw = payload.decompress(raw_size, FileAccess.COMPRESSION_DEFLATE)
		if raw.size() != raw_size:
			error = "FBX array inflate failed (got %d, want %d)" % [raw.size(), raw_size]
			return {}
	else:
		raw = payload
	return {"value": _decode_typed_array(raw, type_code, array_len), "next": next}

func _element_size(type_code: int) -> int:
	match type_code:
		0x66: return 4  # f float32
		0x64: return 8  # d float64
		0x6C: return 8  # l int64
		0x69: return 4  # i int32
		0x62: return 1  # b bool
	return 1

# Decodes a raw little-endian byte buffer into the matching typed array.
func _decode_typed_array(raw: PackedByteArray, type_code: int, count: int):
	match type_code:
		0x64:  # double
			var out := PackedFloat64Array()
			out.resize(count)
			for i in range(count):
				out[i] = raw.decode_double(i * 8)
			return out
		0x66:  # float
			var out := PackedFloat32Array()
			out.resize(count)
			for i in range(count):
				out[i] = raw.decode_float(i * 4)
			return out
		0x69:  # int32
			var out := PackedInt32Array()
			out.resize(count)
			for i in range(count):
				out[i] = raw.decode_s32(i * 4)
			return out
		0x6C:  # int64
			var out := PackedInt64Array()
			out.resize(count)
			for i in range(count):
				out[i] = raw.decode_s64(i * 8)
			return out
		0x62:  # bool
			var out := PackedByteArray()
			out.resize(count)
			for i in range(count):
				out[i] = raw[i]
			return out
	return PackedByteArray()

# --- Convenience tree helpers ------------------------------------------------

# Returns the first direct child of `node` with the given name, or {}.
static func find_child(node: Dictionary, child_name: String) -> Dictionary:
	for c in node.get("children", []):
		if c.get("name", "") == child_name:
			return c
	return {}

# Returns all direct children of `node` with the given name.
static func find_children(node: Dictionary, child_name: String) -> Array:
	var out: Array = []
	for c in node.get("children", []):
		if c.get("name", "") == child_name:
			out.append(c)
	return out
