extends RefCounted
class_name ToonHumanoidFitter

const AutoRigAnalyzer = preload("res://scripts/auto_rig/auto_rig_analyzer.gd")

var _analyzer := AutoRigAnalyzer.new()

# Result of the most recent fit_skeleton() call, exposed for tests / UI.
var last_fit_info: Dictionary = {}

func load_scene_for_preview(scene_path: String) -> Node3D:
	return _analyzer.load_scene(scene_path)

# Exports an auto-rigged model tree (the Node3D returned/used by fit_skeleton,
# containing the generated Skeleton3D + skinned meshes) to a .glb file so the
# rig can round-trip into Blender or any other glTF tool. The root MUST be
# inside the SceneTree, otherwise skin/skeleton transforms are not resolved.
# Returns OK on success.
func export_to_glb(model_root: Node3D, out_path: String) -> int:
	if model_root == null:
		return ERR_INVALID_PARAMETER
	if not model_root.is_inside_tree():
		push_error("export_to_glb: model_root must be inside the SceneTree")
		return ERR_UNCONFIGURED
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(model_root, state)
	if err != OK:
		return err
	var fs_path := out_path
	if out_path.begins_with("res://") or out_path.begins_with("user://"):
		fs_path = ProjectSettings.globalize_path(out_path)
	return doc.write_to_filesystem(state, fs_path)

# Builds a toon humanoid skeleton AND binds the model meshes to it (real
# skinning, not just a floating overlay). Returns the generated Skeleton3D,
# which is added as a child of model_root with the skinned meshes re-parented
# under it.
func fit_skeleton(model_root: Node3D) -> Skeleton3D:
	last_fit_info = {}
	if model_root == null:
		return null

	# Gather meshes in model_root-LOCAL space (exclude model_root's own transform)
	# so the skeleton we add as its child lives in the exact same space.
	var mesh_entries: Array = _gather_local_entries(model_root)
	if mesh_entries.is_empty():
		return null

	# Correct Z-up models (Blender exports that skip yup conversion) to Y-up.
	# The correction is folded into every entry's transform so BOTH the bone
	# placement AND the rebuilt skinned-mesh vertices end up Y-up together. (Just
	# moving bones is not enough: at rest, linear-blend skinning reproduces the
	# original vertex positions, so the mesh must be baked into the new space.)
	if _detect_up_axis(_entries_bounds(mesh_entries)) == "Z":
		var fix := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
		for entry in mesh_entries:
			entry["transform"] = fix * (entry["transform"] as Transform3D)

	var bounds: AABB = _entries_bounds(mesh_entries)
	if bounds.size.length() <= 0.001:
		return null

	var skeleton := Skeleton3D.new()
	skeleton.name = "GeneratedToonHumanoidSkeleton"
	var points: Dictionary = _build_joint_points(bounds, mesh_entries)
	_build_bone_chains(skeleton, points, bounds.size.y)
	# Initialise the live pose to the rest pose so the skeleton (and any skinned
	# mesh) starts in bind position instead of collapsing toward the origin.
	skeleton.reset_bone_poses()
	model_root.add_child(skeleton)

	# Cache each bone's model-space rest origin and parent for skinning math.
	var bone_globals := PackedVector3Array()
	bone_globals.resize(skeleton.get_bone_count())
	for i in range(skeleton.get_bone_count()):
		bone_globals[i] = skeleton.get_bone_global_rest(i).origin

	var skinned := _skin_meshes(skeleton, mesh_entries, bone_globals)
	last_fit_info = {
		"bone_count": skeleton.get_bone_count(),
		"skinned_mesh_count": skinned,
		"vertex_count": _total_vertices(mesh_entries),
		"skinned": skinned > 0,
	}
	return skeleton

# Guesses which axis points "up" from the model bounds. A standing humanoid's
# tallest extent is its height; Blender exports are frequently Z-up (Z is the
# tall axis) while Godot fitting assumes Y-up. Returns "Y" or "Z".
func _detect_up_axis(bounds: AABB) -> String:
	var s := bounds.size
	# If Z is meaningfully taller than Y, the model is almost certainly Z-up.
	# (Humanoid auto-fit assumes an upright figure, so the tall axis is "up".)
	if s.z > s.y * 1.2 and s.z >= s.x:
		return "Z"
	return "Y"

# --- joint placement -------------------------------------------------------

func _build_joint_points(bounds: AABB, mesh_entries: Array) -> Dictionary:
	var center: Vector3 = bounds.get_center()
	var height: float = bounds.size.y
	var y0: float = bounds.position.y

	# Measure the actual body silhouette at the shoulder and hip heights so the
	# limb roots sit inside the mesh instead of floating at a guessed offset.
	var shoulder_y: float = y0 + height * 0.78
	var hip_y: float = y0 + height * 0.50
	var shoulder_span: float = _measure_half_width(mesh_entries, shoulder_y, height * 0.06, center)
	var hip_span: float = _measure_half_width(mesh_entries, hip_y, height * 0.05, center)

	var shoulder_width: float = max(shoulder_span * 0.55, height * 0.06)
	var hip_width: float = max(hip_span * 0.45, height * 0.045)
	var foot_z: float = bounds.size.z * 0.10

	# Detect the real arm pose: where is the arm mass that extends past the torso?
	# This finds the actual hand tip on each side (T-pose -> high & wide,
	# arms-down -> low & narrow) instead of forcing a horizontal T-pose.
	var shoulder_l := Vector3(center.x - shoulder_width, shoulder_y, center.z)
	var shoulder_r := Vector3(center.x + shoulder_width, shoulder_y, center.z)
	var hand_l := _measure_hand_tip(mesh_entries, center, shoulder_width, shoulder_l, false, height)
	var hand_r := _measure_hand_tip(mesh_entries, center, shoulder_width, shoulder_r, true, height)

	# Distribute upper-arm / lower-arm joints along the shoulder->hand line so the
	# bones follow the limb's true direction whatever the pose.
	var upper_l := shoulder_l.lerp(hand_l, 0.34)
	var lower_l := shoulder_l.lerp(hand_l, 0.67)
	var upper_r := shoulder_r.lerp(hand_r, 0.34)
	var lower_r := shoulder_r.lerp(hand_r, 0.67)

	return {
		"Toon_Hips": Vector3(center.x, y0 + height * 0.52, center.z),
		"Toon_Spine": Vector3(center.x, y0 + height * 0.63, center.z),
		"Toon_Chest": Vector3(center.x, y0 + height * 0.74, center.z),
		"Toon_Neck": Vector3(center.x, y0 + height * 0.84, center.z),
		"Toon_Head": Vector3(center.x, y0 + height * 0.93, center.z),
		"Toon_Shoulder.L": shoulder_l,
		"Toon_UpperArm.L": upper_l,
		"Toon_LowerArm.L": lower_l,
		"Toon_Hand.L": hand_l,
		"Toon_Shoulder.R": shoulder_r,
		"Toon_UpperArm.R": upper_r,
		"Toon_LowerArm.R": lower_r,
		"Toon_Hand.R": hand_r,
		"Toon_UpperLeg.L": Vector3(center.x - hip_width, y0 + height * 0.47, center.z),
		"Toon_LowerLeg.L": Vector3(center.x - hip_width, y0 + height * 0.25, center.z),
		"Toon_Foot.L": Vector3(center.x - hip_width, y0 + height * 0.04, center.z + foot_z),
		"Toon_UpperLeg.R": Vector3(center.x + hip_width, y0 + height * 0.47, center.z),
		"Toon_LowerLeg.R": Vector3(center.x + hip_width, y0 + height * 0.25, center.z),
		"Toon_Foot.R": Vector3(center.x + hip_width, y0 + height * 0.04, center.z + foot_z),
	}

# Finds the hand tip for one side by looking at vertices that lie beyond the
# torso width on that side and taking the one furthest from the shoulder. This
# adapts to T-pose (tip high & far out), A-pose, and arms-straight-down.
func _measure_hand_tip(mesh_entries: Array, center: Vector3, shoulder_width: float, shoulder: Vector3, right_side: bool, height: float) -> Vector3:
	var sign := 1.0 if right_side else -1.0
	# Only consider the upper body so feet/legs never get mistaken for hands.
	var min_y := center.y - height * 0.25
	var threshold := shoulder_width * 1.15
	var best := shoulder
	var best_dist := 0.0
	for entry in mesh_entries:
		var xform: Transform3D = entry["transform"]
		var verts: PackedVector3Array = entry["vertices"]
		for v in verts:
			var p: Vector3 = xform * v
			var dx := (p.x - center.x) * sign
			if dx < threshold or p.y < min_y:
				continue
			var d := shoulder.distance_to(p)
			if d > best_dist:
				best_dist = d
				best = p
	# No clear arm mass found (e.g. a limbless blob): fall back to a short
	# horizontal stub so the chain is still valid but doesn't distort anything.
	if best_dist < height * 0.05:
		return shoulder + Vector3(sign * height * 0.18, 0.0, 0.0)
	return best

# Returns the average horizontal distance from center.x of mesh vertices that
# fall within +/- band of target_y. Used to size the body to the actual mesh.
func _measure_half_width(mesh_entries: Array, target_y: float, band: float, center: Vector3) -> float:
	var max_dx := 0.0
	var samples := 0
	for entry in mesh_entries:
		var xform: Transform3D = entry["transform"]
		var verts: PackedVector3Array = entry["vertices"]
		for v in verts:
			var p: Vector3 = xform * v
			if absf(p.y - target_y) <= band:
				max_dx = max(max_dx, absf(p.x - center.x))
				samples += 1
	if samples == 0:
		return 0.0
	return max_dx

func _build_bone_chains(skeleton: Skeleton3D, points: Dictionary, height: float) -> void:
	_add_bone_chain(skeleton, points, ["Toon_Hips", "Toon_Spine", "Toon_Chest", "Toon_Neck", "Toon_Head"], -1)
	_add_bone_chain(skeleton, points, ["Toon_Chest", "Toon_Shoulder.L", "Toon_UpperArm.L", "Toon_LowerArm.L", "Toon_Hand.L"], skeleton.find_bone("Toon_Chest"))
	_add_bone_chain(skeleton, points, ["Toon_Chest", "Toon_Shoulder.R", "Toon_UpperArm.R", "Toon_LowerArm.R", "Toon_Hand.R"], skeleton.find_bone("Toon_Chest"))
	_add_bone_chain(skeleton, points, ["Toon_Hips", "Toon_UpperLeg.L", "Toon_LowerLeg.L", "Toon_Foot.L"], skeleton.find_bone("Toon_Hips"))
	_add_bone_chain(skeleton, points, ["Toon_Hips", "Toon_UpperLeg.R", "Toon_LowerLeg.R", "Toon_Foot.R"], skeleton.find_bone("Toon_Hips"))
	_add_preview_fingers(skeleton, points["Toon_Hand.L"], false, height)
	_add_preview_fingers(skeleton, points["Toon_Hand.R"], true, height)

func _add_bone_chain(skeleton: Skeleton3D, points: Dictionary, names: Array, forced_parent: int) -> void:
	var parent := forced_parent
	for i in range(names.size()):
		var bone_name: String = names[i]
		var existing: int = skeleton.find_bone(bone_name)
		if existing != -1:
			parent = existing
			continue
		skeleton.add_bone(bone_name)
		var idx: int = skeleton.find_bone(bone_name)
		if parent != -1:
			skeleton.set_bone_parent(idx, parent)
		_set_bone_rest_from_global_point(skeleton, idx, parent, points[bone_name])
		parent = idx

func _add_preview_fingers(skeleton: Skeleton3D, hand_pos: Vector3, right_side: bool, height: float) -> void:
	var hand_name: String = "Toon_Hand.R" if right_side else "Toon_Hand.L"
	var hand_index: int = skeleton.find_bone(hand_name)
	if hand_index == -1:
		return
	var side: float = 1.0 if right_side else -1.0
	var names: Array[String] = ["Thumb", "Index", "Middle", "Ring", "Pinky"]
	for finger_i in range(names.size()):
		var spread: float = float(finger_i - 2) * height * 0.005
		var thumb_push: float = height * 0.012 if finger_i == 0 else 0.0
		var base_offset := Vector3(
			side * height * (0.010 + finger_i * 0.004 + thumb_push),
			height * (0.006 - finger_i * 0.0015),
			spread,
		)
		var parent := hand_index
		for segment in range(1, 4):
			var bone_name: String = "Toon_%s%d.%s" % [names[finger_i], segment, "R" if right_side else "L"]
			skeleton.add_bone(bone_name)
			var idx: int = skeleton.find_bone(bone_name)
			skeleton.set_bone_parent(idx, parent)
			var segment_len: float = height * (0.015 if finger_i == 0 else 0.017)
			var reach := Vector3(
				side * segment_len * segment,
				-height * 0.005 * segment,
				spread * 0.35 * segment,
			)
			_set_bone_rest_from_global_point(skeleton, idx, parent, hand_pos + base_offset + reach)
			parent = idx

func _set_bone_rest_from_global_point(skeleton: Skeleton3D, bone_index: int, parent_index: int, global_point: Vector3) -> void:
	var local_origin := global_point
	if parent_index != -1:
		local_origin = global_point - skeleton.get_bone_global_rest(parent_index).origin
	skeleton.set_bone_rest(bone_index, Transform3D(Basis(), local_origin))

# --- skinning --------------------------------------------------------------

# Rebuilds every mesh surface with bone indices + weights derived from the
# generated skeleton, re-parents the skinned MeshInstance3D under the skeleton,
# and attaches a Skin so the renderer actually deforms the mesh. Returns the
# number of meshes successfully skinned.
func _skin_meshes(skeleton: Skeleton3D, mesh_entries: Array, bone_globals: PackedVector3Array) -> int:
	# Precompute bone segments (origin -> child origin) for nearest-segment tests.
	var segments: Array = _build_bone_segments(skeleton, bone_globals)
	var skin := _build_skin(skeleton, bone_globals)
	skeleton.set("show_rest_only", false)
	var skinned_count := 0
	var sources_to_remove: Array = []
	for entry in mesh_entries:
		var source: MeshInstance3D = entry["instance"]
		var xform: Transform3D = entry["transform"]
		var new_mesh := _build_skinned_mesh(source.mesh, xform, segments, bone_globals)
		if new_mesh == null:
			continue
		var skinned_instance := MeshInstance3D.new()
		skinned_instance.name = "%s_skinned" % source.name
		skinned_instance.mesh = new_mesh
		# Re-parenting under the skeleton + identity transform keeps the mesh in
		# model space, matching the bone rest globals we skinned against.
		skeleton.add_child(skinned_instance)
		skinned_instance.transform = Transform3D.IDENTITY
		skinned_instance.skin = skin
		skinned_instance.skeleton = skinned_instance.get_path_to(skeleton)
		sources_to_remove.append(source)
		skinned_count += 1
	# Remove the original un-skinned copies entirely (rather than hiding them):
	# toggling .visible emits the KHR_node_visibility glTF extension on export,
	# which older Blender importers reject. Removing keeps the glb portable.
	for source in sources_to_remove:
		source.get_parent().remove_child(source)
		source.queue_free()
	return skinned_count

func _build_bone_segments(skeleton: Skeleton3D, bone_globals: PackedVector3Array) -> Array:
	var segments: Array = []
	for i in range(skeleton.get_bone_count()):
		var parent := skeleton.get_bone_parent(i)
		if parent == -1:
			continue
		# Segment owned by the child bone: from parent joint to this joint.
		segments.append({
			"bone": i,
			"a": bone_globals[parent],
			"b": bone_globals[i],
		})
	return segments

func _build_skin(skeleton: Skeleton3D, bone_globals: PackedVector3Array) -> Skin:
	var skin := Skin.new()
	for i in range(skeleton.get_bone_count()):
		# Bind pose is the inverse of the bone's model-space rest transform.
		var rest_global: Transform3D = skeleton.get_bone_global_rest(i)
		skin.add_bind(i, rest_global.affine_inverse())
		skin.set_bind_name(i, skeleton.get_bone_name(i))
	return skin

func _build_skinned_mesh(mesh: Mesh, xform: Transform3D, segments: Array, bone_globals: PackedVector3Array) -> ArrayMesh:
	if mesh == null:
		return null
	var out := ArrayMesh.new()
	for s in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var bones := PackedInt32Array()
		var weights := PackedFloat32Array()
		bones.resize(verts.size() * 4)
		weights.resize(verts.size() * 4)
		# Bake the entry transform into the stored vertices so the REST mesh lives
		# in the same (corrected, e.g. Y-up) space as the bones. Linear-blend
		# skinning reproduces the rest mesh at rest, so this is what makes an
		# up-axis fix actually reorient the visible geometry.
		var baked_verts := PackedVector3Array()
		baked_verts.resize(verts.size())
		for vi in range(verts.size()):
			var world_v: Vector3 = xform * verts[vi]
			baked_verts[vi] = world_v
			var assignment: Dictionary = _weights_for_point(world_v, segments)
			var idx_list: Array = assignment["bones"]
			var w_list: Array = assignment["weights"]
			for k in range(4):
				bones[vi * 4 + k] = idx_list[k]
				weights[vi * 4 + k] = w_list[k]
		arrays[Mesh.ARRAY_VERTEX] = baked_verts
		# Rotate normals by the same basis so lighting stays correct.
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var rotated := PackedVector3Array()
			rotated.resize(normals.size())
			for ni in range(normals.size()):
				rotated[ni] = (xform.basis * normals[ni]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = rotated
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := mesh.surface_get_material(s)
		if mat != null:
			out.surface_set_material(s, mat)
	if out.get_surface_count() == 0:
		return null
	return out

# Assigns up to 4 bone weights to a point. Only bones within a falloff band of
# the nearest one contribute, so distant parts (skirt hem, hair tips) bind
# cleanly to their closest bone instead of smearing across the whole skeleton.
# Returns {"bones": [4 ints], "weights": [4 floats]}.
func _weights_for_point(point: Vector3, segments: Array) -> Dictionary:
	# Score every segment by distance, keep the closest few.
	var scored: Array = []
	for seg in segments:
		var d: float = _distance_to_segment(point, seg["a"], seg["b"])
		scored.append({"bone": seg["bone"], "dist": d})
	scored.sort_custom(func(x, y): return x["dist"] < y["dist"])

	var bones: Array = [0, 0, 0, 0]
	var weights: Array = [0.0, 0.0, 0.0, 0.0]
	var take: int = min(4, scored.size())
	if take == 0:
		weights[0] = 1.0
		return {"bones": bones, "weights": weights}

	# Blend only with neighbours close to the nearest bone. The band scales with
	# the nearest distance so limbs (tight) and loose geometry (skirt) both get a
	# sensible local blend rather than a global average.
	var nearest: float = scored[0]["dist"]
	var band: float = nearest * 1.6 + 0.02

	var raw: Array = []
	var picked: Array = []
	var total := 0.0
	for i in range(take):
		var d: float = scored[i]["dist"]
		if i > 0 and d > band:
			break
		# Smooth (1 - d/band)^2 falloff: nearest dominates, transitions are soft,
		# and a bone exactly at the band edge contributes nothing.
		var t: float = clampf(d / band, 0.0, 1.0)
		var w: float = (1.0 - t) * (1.0 - t) + 0.0001
		raw.append(w)
		picked.append(scored[i]["bone"])
		total += w
	for i in range(picked.size()):
		bones[i] = picked[i]
		weights[i] = raw[i] / total
	return {"bones": bones, "weights": weights}

func _distance_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)

# --- mesh gathering --------------------------------------------------------

# Gathers meshes in model_root-LOCAL space by walking the children with an
# identity base, so model_root's own transform is excluded. The generated
# skeleton (added as a child of model_root) then shares this exact space.
func _gather_local_entries(model_root: Node3D) -> Array:
	var out: Array = []
	for child in model_root.get_children():
		_collect_mesh_entries(child, Transform3D.IDENTITY, out)
	return out

# Rotates the model's geometry -90deg about X (Z-up -> Y-up) by composing the
# fix into each direct child's transform, so it lands in model_root-local space
# alongside the skeleton (avoids double-applying model_root's own rotation).
func _apply_axis_fix_to_model(model_root: Node3D) -> void:
	var fix := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
	for child in model_root.get_children():
		if child is Node3D:
			(child as Node3D).transform = fix * (child as Node3D).transform

func _collect_mesh_entries(node: Node, parent_transform: Transform3D, out: Array) -> void:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		out.append({
			"instance": mesh_instance,
			"transform": local_transform,
			# All surfaces' vertices, so silhouette/joint measurement sees the
			# whole mesh (multi-material glTF puts limbs on separate surfaces).
			"vertices": _all_surface_vertices(mesh_instance.mesh),
		})
	for child in node.get_children():
		_collect_mesh_entries(child, local_transform, out)

func _all_surface_vertices(mesh: Mesh) -> PackedVector3Array:
	var combined := PackedVector3Array()
	for s in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts != null and not verts.is_empty():
			combined.append_array(verts)
	return combined

func _entries_bounds(mesh_entries: Array) -> AABB:
	var found := false
	var bounds := AABB()
	for entry in mesh_entries:
		var xform: Transform3D = entry["transform"]
		var local_aabb: AABB = (entry["instance"] as MeshInstance3D).mesh.get_aabb()
		var transformed: AABB = xform * local_aabb
		if not found:
			bounds = transformed
			found = true
		else:
			bounds = bounds.merge(transformed)
	return bounds

func _total_vertices(mesh_entries: Array) -> int:
	var total := 0
	for entry in mesh_entries:
		total += (entry["vertices"] as PackedVector3Array).size()
	return total

func _calculate_aabb(root: Node) -> AABB:
	var entries: Array = []
	_collect_mesh_entries(root, Transform3D.IDENTITY, entries)
	return _entries_bounds(entries)
