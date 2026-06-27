extends RefCounted
class_name AutoRigAnalyzer

const FINGER_PATTERNS := [
	"thumb", "index", "middle", "ring", "pinky", "little",
	"f_thumb", "f_index", "f_middle", "f_ring", "f_pinky"
]

func analyze_scene_path(scene_path: String) -> Dictionary:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var absolute_path := _to_filesystem_path(scene_path)
	# Distinguish a missing file from a malformed one so the message is actionable.
	if not FileAccess.file_exists(absolute_path):
		return {
			"status": "error",
			"message": "Model file not found: %s" % scene_path,
			"has_skeleton": false,
			"bone_count": 0,
			"finger_bone_count": 0,
			"preview_ready": false,
		}
	var err := doc.append_from_file(absolute_path, state)
	if err != OK:
		return {
			"status": "error",
			"message": "Could not import %s (error %d)" % [scene_path, err],
			"has_skeleton": false,
			"bone_count": 0,
			"finger_bone_count": 0,
			"preview_ready": false,
		}

	var root := doc.generate_scene(state)
	if root == null:
		return {
			"status": "error",
			"message": "Imported scene could not be generated",
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
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var absolute_path := _to_filesystem_path(scene_path)
	if not FileAccess.file_exists(absolute_path):
		push_error("AutoRigAnalyzer.load_scene: file not found: %s" % scene_path)
		return null
	var err := doc.append_from_file(absolute_path, state)
	if err != OK:
		push_error("AutoRigAnalyzer.load_scene: import failed (%d) for %s" % [err, scene_path])
		return null
	var scene := doc.generate_scene(state)
	return scene as Node3D

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
	for side in [".l", ".r"]:
		for finger in required:
			var found := false
			for name in lower_names:
				var normalized := name.replace("f_", "")
				if normalized.find(finger) != -1 and (normalized.ends_with(side) or normalized.find(side + ".") != -1):
					found = true
					break
			if not found:
				return false
	return finger_names.size() >= 30

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
		return ProjectSettings.globalize_path(scene_path)
	return scene_path
