extends RefCounted
class_name AutoRigAnalyzer

const FbxConverter = preload("res://scripts/auto_rig/fbx_converter.gd")
const FbxImporter = preload("res://scripts/auto_rig/fbx_importer.gd")

const FINGER_PATTERNS := [
	"thumb", "index", "middle", "ring", "pinky", "little",
	"f_thumb", "f_index", "f_middle", "f_ring", "f_pinky"
]

# Surfaces the reason an FBX could not be loaded (native parse error, or — for the
# Blender fallback — converter trouble) so the UI can show it. Cleared per load.
var last_convert_error := ""

var _converter := FbxConverter.new()

func analyze_scene_path(scene_path: String) -> Dictionary:
	last_convert_error = ""
	var root := _load_root(scene_path)
	if root == null:
		var msg := "Could not import %s" % scene_path
		if last_convert_error != "":
			msg = last_convert_error
		return {
			"status": "error",
			"message": msg,
			"has_skeleton": false,
			"bone_count": 0,
			"finger_bone_count": 0,
			"preview_ready": false,
		}

	var skeletons: Array[Skeleton3D] = []
	_collect_skeletons(root, skeletons)
	var mesh_count := _count_meshes(root)
	var bounds := _calculate_aabb(root)
	var primary: Skeleton3D = null
	for skel in skeletons:
		if primary == null or skel.get_bone_count() > primary.get_bone_count():
			primary = skel

	var bone_names: Array[String] = []
	var finger_names: Array[String] = []
	if primary != null:
		for i in range(primary.get_bone_count()):
			var bone_name := primary.get_bone_name(i)
			bone_names.append(bone_name)
			if is_finger_bone_name(bone_name):
				finger_names.append(bone_name)
	var finger_complete := _has_complete_fingers(finger_names)
	var quality_score := _score_rig(primary != null, bone_names.size(), finger_names.size(), finger_complete)

	var report := {
		"status": "ok",
		"message": "Rig detected" if primary != null else "No skeleton detected",
		"has_skeleton": primary != null,
		"skeleton_count": skeletons.size(),
		"skeleton_name": primary.name if primary != null else "",
		"mesh_count": mesh_count,
		"bounds_size": bounds.size,
		"bone_count": bone_names.size(),
		"finger_bone_count": finger_names.size(),
		"finger_complete": finger_complete,
		"finger_bones": finger_names,
		"quality_score": quality_score,
		"preview_ready": primary != null and bone_names.size() > 0,
		# Humanoid-ish if it has no rig, has geometry, and its tallest axis (Y for
		# Y-up, Z for Z-up exports) is clearly longer than its width.
		"auto_fit_candidate": primary == null and mesh_count > 0 and max(bounds.size.y, bounds.size.z) > bounds.size.x,
		"toon_game_ready": primary != null and finger_names.size() >= 6,
	}
	root.free()
	return report

func load_scene(scene_path: String) -> Node3D:
	last_convert_error = ""
	var scene := _load_root(scene_path)
	if scene == null and last_convert_error != "":
		push_error("AutoRigAnalyzer.load_scene: %s" % last_convert_error)
	return scene

# Loads a model path to a scene root, choosing the reader by extension:
#   - .fbx  -> native FbxImporter (pure GDScript, no external tools). On parse
#             failure it falls back to the Blender converter (glTF round-trip).
#   - other -> GLTFDocument (.glb/.gltf), with res:// PCK staging.
# Returns the scene Node3D (caller owns it), or null with last_convert_error set.
func _load_root(scene_path: String) -> Node3D:
	var fs_path := _to_filesystem_path(scene_path)
	if FbxConverter.is_fbx(fs_path):
		# Prefer Godot's official FBXDocument: its bone rest (Y-along-bone, from the
		# same ufbx math used for animation) is consistent with retargeted animation,
		# so skinned limbs don't twist. Our hand-written parser is the fallback for
		# files/environments the official importer can't read, then Blender as a last
		# resort.
		var official := _load_fbx_official(fs_path)
		if official != null:
			return official
		var importer := FbxImporter.new()
		var scene := importer.import_to_scene(fs_path)
		if scene != null:
			return scene
		var native_err := importer.error
		var glb := _resolve_model_path(scene_path)
		if glb != "" and FileAccess.file_exists(glb):
			return _load_gltf(glb)
		last_convert_error = native_err if native_err != "" else _converter.last_error
		return null
	return _load_gltf(fs_path)

# Loads an FBX through Godot's built-in FBXDocument (mesh + skeleton + textures),
# or null if it can't read the file. Applies the same double-sided material fix
# the native importer uses so thin shells (hair/eyelashes) don't look see-through.
func _load_fbx_official(absolute_path: String) -> Node3D:
	if not FileAccess.file_exists(absolute_path):
		return null
	var doc := FBXDocument.new()
	var state := FBXState.new()
	var err := doc.append_from_file(absolute_path, state)
	if err != OK:
		return null
	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		return null
	_make_meshes_double_sided(scene)
	return scene

# Forces all surfaces to render double-sided (CULL_DISABLED). Mixamo/Adobe meshes
# include thin single-sided shells whose back-face culling makes them look
# inside-out / see-through; matching the native importer's behaviour.
func _make_meshes_double_sided(root: Node) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var mat := mi.mesh.surface_get_material(s)
			if mat is BaseMaterial3D:
				(mat as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED

# Loads a glTF (.glb/.gltf) file path into a scene, or null on failure.
func _load_gltf(absolute_path: String) -> Node3D:
	if not FileAccess.file_exists(absolute_path):
		last_convert_error = "Model file not found: %s" % absolute_path
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(absolute_path, state)
	if err != OK:
		last_convert_error = "Could not import glTF (error %d)" % err
		return null
	return doc.generate_scene(state) as Node3D

func is_finger_bone_name(bone_name: String) -> bool:
	var lower := bone_name.to_lower()
	for pattern in FINGER_PATTERNS:
		if lower.find(pattern) != -1:
			return true
	return false

func _has_complete_fingers(finger_names: Array[String]) -> bool:
	var lower_names: Array[String] = []
	for name in finger_names:
		lower_names.append(name.to_lower())
	var required: Array[String] = ["thumb", "index", "middle", "ring", "pinky"]
	# "left"/"right" => Mixamo style (mixamorig_LeftHandIndex1); ".l"/".r" =>
	# Blender/Rigify suffix style. A rig needs all five fingers on BOTH sides.
	for side in [["left", ".l"], ["right", ".r"]]:
		for finger in required:
			var found := false
			for name in lower_names:
				if name.find(finger) != -1 and _side_matches(name, side[0], side[1]):
					found = true
					break
			if not found:
				return false
	return finger_names.size() >= 30

# True if a finger bone name belongs to the given side under any supported naming
# scheme: Mixamo embeds "left"/"right" in the name (mixamorig_LeftHandIndex1),
# while Blender/Rigify uses a ".l"/".r" suffix (f_index.03.r). Matched on the
# lower-cased name; `word` is "left"/"right", `suffix` is ".l"/".r".
func _side_matches(lower_name: String, word: String, suffix: String) -> bool:
	if lower_name.find(word) != -1:
		return true
	var normalized := lower_name.replace("f_", "")
	return normalized.ends_with(suffix) or normalized.find(suffix + ".") != -1

func _score_rig(has_skeleton: bool, bone_count: int, finger_count: int, finger_complete: bool) -> int:
	if not has_skeleton:
		return 20
	var score := 40
	if bone_count >= 19:
		score += 20
	if bone_count <= 180:
		score += 10
	if finger_count >= 30:
		score += 20
	if finger_complete:
		score += 10
	return clampi(score, 0, 100)

func _collect_skeletons(node: Node, out: Array[Skeleton3D]) -> void:
	if node is Skeleton3D:
		out.append(node)
	for child in node.get_children():
		_collect_skeletons(child, out)

func _count_meshes(root: Node) -> int:
	var count := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			count += 1
	return count

func _calculate_aabb(root: Node) -> AABB:
	var found := false
	var bounds := AABB()
	var result := _merge_mesh_bounds(root, Transform3D.IDENTITY, found, bounds)
	return result["bounds"]

func _merge_mesh_bounds(node: Node, parent_transform: Transform3D, found: bool, bounds: AABB) -> Dictionary:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		var transformed: AABB = local_transform * mesh_instance.mesh.get_aabb()
		if not found:
			bounds = transformed
			found = true
		else:
			bounds = bounds.merge(transformed)
	for child in node.get_children():
		var result := _merge_mesh_bounds(child, local_transform, found, bounds)
		found = result["found"]
		bounds = result["bounds"]
	return {"found": found, "bounds": bounds}

func _to_filesystem_path(scene_path: String) -> String:
	if scene_path.begins_with("res://") or scene_path.begins_with("user://"):
		var globalized := ProjectSettings.globalize_path(scene_path)
		# In an exported build, res:// assets live inside the PCK, so globalize_path
		# points at a file that isn't on disk. GLTFDocument.append_from_file needs a
		# real path, so stage the asset out to user:// and use that instead.
		if scene_path.begins_with("res://") and not FileAccess.file_exists(globalized):
			var staged := _stage_packed_asset(scene_path)
			if staged != "":
				return staged
		return globalized
	return scene_path

# Copies a res:// asset (readable via FileAccess even from inside a PCK) to a
# real file under user:// and returns its absolute path, or "" on failure. Cached
# by filename so repeated loads don't rewrite it.
func _stage_packed_asset(res_path: String) -> String:
	var staged := "user://staged_assets/%s" % res_path.get_file()
	var staged_abs := ProjectSettings.globalize_path(staged)
	if FileAccess.file_exists(staged_abs):
		return staged_abs
	var src := FileAccess.open(res_path, FileAccess.READ)
	if src == null:
		return ""
	var bytes := src.get_buffer(src.get_length())
	src.close()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://staged_assets"))
	var dst := FileAccess.open(staged, FileAccess.WRITE)
	if dst == null:
		return ""
	dst.store_buffer(bytes)
	dst.close()
	return staged_abs

# Resolves a model path to a loadable glTF on disk. glTF paths pass straight
# through; an FBX (e.g. a Mixamo download) is transparently converted to a cached
# .glb via Blender so the rest of the tool can read it. Returns the absolute path
# to load, or "" with last_convert_error set when an FBX cannot be converted.
func _resolve_model_path(scene_path: String) -> String:
	last_convert_error = ""
	var absolute_path := _to_filesystem_path(scene_path)
	if not FbxConverter.is_fbx(absolute_path):
		return absolute_path
	var glb := _converter.convert_to_glb(absolute_path)
	if glb == "":
		last_convert_error = _converter.last_error
		return ""
	return glb
