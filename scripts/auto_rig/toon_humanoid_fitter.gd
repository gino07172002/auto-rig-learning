extends RefCounted
class_name ToonHumanoidFitter

const AutoRigAnalyzer = preload("res://scripts/auto_rig/auto_rig_analyzer.gd")

# Bone naming presets. Placement logic uses stable LOGICAL keys (e.g. "hips",
# "upper_arm.L", "index3.R"); the actual bone name written into the skeleton is
# resolved per preset, so the same rig can be emitted as Toon_* or as
# Blender/Rigify-style names for retargeting.
enum Naming { TOON, BLENDER }

# Skin-weight algorithm. PROXIMITY is the original per-vertex distance-to-bone
# method (fast, but weights can bleed across narrow gaps like armpits/fingers).
# HEAT_DIFFUSION relaxes weights across the mesh surface graph so they flow along
# the surface instead of jumping the gap — closer to Blender Bone Heat / Mixamo.
# Kept switchable so the old method stays available until the new one is trusted.
enum SkinMethod { PROXIMITY, HEAT_DIFFUSION }
var skin_method: int = SkinMethod.PROXIMITY

# Maps a logical key to a preset-specific bone name. Body keys are listed; finger
# keys (e.g. "index3.L") are resolved procedurally in _finger_bone_name().
const _BODY_NAMES := {
	Naming.TOON: {
		"hips": "Toon_Hips", "spine": "Toon_Spine", "chest": "Toon_Chest",
		"neck": "Toon_Neck", "head": "Toon_Head",
		"shoulder.L": "Toon_Shoulder.L", "upper_arm.L": "Toon_UpperArm.L",
		"lower_arm.L": "Toon_LowerArm.L", "hand.L": "Toon_Hand.L",
		"shoulder.R": "Toon_Shoulder.R", "upper_arm.R": "Toon_UpperArm.R",
		"lower_arm.R": "Toon_LowerArm.R", "hand.R": "Toon_Hand.R",
		"upper_leg.L": "Toon_UpperLeg.L", "lower_leg.L": "Toon_LowerLeg.L", "foot.L": "Toon_Foot.L",
		"upper_leg.R": "Toon_UpperLeg.R", "lower_leg.R": "Toon_LowerLeg.R", "foot.R": "Toon_Foot.R",
	},
	Naming.BLENDER: {
		"hips": "spine", "spine": "spine.001", "chest": "spine.002",
		"neck": "neck", "head": "head",
		"shoulder.L": "shoulder.L", "upper_arm.L": "upper_arm.L",
		"lower_arm.L": "forearm.L", "hand.L": "hand.L",
		"shoulder.R": "shoulder.R", "upper_arm.R": "upper_arm.R",
		"lower_arm.R": "forearm.R", "hand.R": "hand.R",
		"upper_leg.L": "thigh.L", "lower_leg.L": "shin.L", "foot.L": "foot.L",
		"upper_leg.R": "thigh.R", "lower_leg.R": "shin.R", "foot.R": "foot.R",
	},
}

const _FINGER_KEYS := ["Thumb", "Index", "Middle", "Ring", "Pinky"]

var _analyzer := AutoRigAnalyzer.new()

# Result of the most recent fit_skeleton() call, exposed for tests / UI.
var last_fit_info: Dictionary = {}

# Naming preset used by the next fit_skeleton() call.
var naming: int = Naming.TOON

# Manual proportion multipliers applied on top of the auto-measured fit, so the
# user can fine-tune limb sizing. 1.0 = pure auto-fit.
var shoulder_scale: float = 1.0
var arm_scale: float = 1.0
var leg_scale: float = 1.0

# Set by the last detect_joint_points()/fit, flagging which key points were
# genuinely measured from the mesh silhouette vs. fallback-guessed. Keyed by the
# same logical keys as the points dict; value is true when measured.
var last_point_measured: Dictionary = {}

# Detection summary (human-readable) for the UI: which body regions were found.
var last_detection: Dictionary = {}

# Resolves a logical body-bone key to the current preset's bone name.
func _bone_name(key: String) -> String:
	return _BODY_NAMES[naming].get(key, key)

# Builds the preset-specific name for a finger segment, e.g.
# Toon: "Toon_Index3.R"; Blender: "f_index.03.R" (thumb -> "thumb.03.R").
func _finger_bone_name(finger: String, segment: int, right_side: bool) -> String:
	var suffix := "R" if right_side else "L"
	if naming == Naming.BLENDER:
		var lower := finger.to_lower()
		var stem := "thumb" if lower == "thumb" else "f_%s" % lower
		return "%s.0%d.%s" % [stem, segment, suffix]
	return "Toon_%s%d.%s" % [finger, segment, suffix]

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
# Detects the key joint points from the mesh WITHOUT building or binding a
# skeleton, so the UI can show them for review/adjustment before committing.
# Returns { "points": Dictionary(logical key -> Vector3 model-space),
#           "measured": Dictionary(key -> bool), "height": float } or {} on
# failure. The points are in model_root-LOCAL space (Z-up already corrected),
# matching what fit_skeleton() consumes.
func detect_joint_points(model_root: Node3D) -> Dictionary:
	last_point_measured = {}
	last_detection = {}
	if model_root == null:
		return {}
	var mesh_entries: Array = _gather_local_entries(model_root)
	if mesh_entries.is_empty():
		return {}
	# Correct Z-up so detected points are in the same upright space fit uses.
	if _detect_up_axis(_entries_bounds(mesh_entries)) == "Z":
		var fix := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
		for entry in mesh_entries:
			entry["transform"] = fix * (entry["transform"] as Transform3D)
	var bounds: AABB = _entries_bounds(mesh_entries)
	if bounds.size.length() <= 0.001:
		return {}
	var points: Dictionary = _build_joint_points(bounds, mesh_entries)
	return {
		"points": points,
		"measured": last_point_measured.duplicate(),
		"height": bounds.size.y,
		"detection": last_detection.duplicate(),
	}

# Builds a toon humanoid skeleton AND binds the model meshes to it. If
# `preset_points` is supplied (e.g. user-edited joints from detect_joint_points),
# those are used verbatim instead of re-measuring, so manual adjustments stick.
func fit_skeleton(model_root: Node3D, preset_points: Dictionary = {}) -> Skeleton3D:
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
	# Use the caller's edited joints when given; otherwise measure from the mesh.
	var points: Dictionary = preset_points if not preset_points.is_empty() else _build_joint_points(bounds, mesh_entries)
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

	# Auto-measured proportions, then scaled by the manual multipliers.
	var shoulder_width: float = max(shoulder_span * 0.55, height * 0.06) * shoulder_scale
	var hip_width: float = max(hip_span * 0.45, height * 0.045)
	var foot_z: float = bounds.size.z * 0.10

	# Detect the real arm pose: where is the arm mass that extends past the torso?
	# This finds the actual hand tip on each side (T-pose -> high & wide,
	# arms-down -> low & narrow) instead of forcing a horizontal T-pose.
	var shoulder_l := Vector3(center.x - shoulder_width, shoulder_y, center.z)
	var shoulder_r := Vector3(center.x + shoulder_width, shoulder_y, center.z)
	var hand_l_res: Dictionary = _measure_hand_tip(mesh_entries, center, shoulder_width, shoulder_l, false, height)
	var hand_r_res: Dictionary = _measure_hand_tip(mesh_entries, center, shoulder_width, shoulder_r, true, height)
	var hand_l: Vector3 = hand_l_res["point"]
	var hand_r: Vector3 = hand_r_res["point"]

	# Record which key points were genuinely measured vs. guessed, for the UI.
	# Body-center points (spine chain, hips) are always derived from bounds, so
	# they count as measured; shoulders from the silhouette width; hands from the
	# arm-mass search (fallback => flagged).
	var shoulders_measured := shoulder_span > height * 0.02
	last_point_measured = {
		"hips": true, "spine": true, "chest": true, "neck": true, "head": true,
		"shoulder.L": shoulders_measured, "shoulder.R": shoulders_measured,
		"upper_arm.L": hand_l_res["measured"], "lower_arm.L": hand_l_res["measured"], "hand.L": hand_l_res["measured"],
		"upper_arm.R": hand_r_res["measured"], "lower_arm.R": hand_r_res["measured"], "hand.R": hand_r_res["measured"],
		"upper_leg.L": hip_span > height * 0.02, "lower_leg.L": true, "foot.L": true,
		"upper_leg.R": hip_span > height * 0.02, "lower_leg.R": true, "foot.R": true,
	}
	last_detection = {
		"spine": true,
		"shoulders": shoulders_measured,
		"arms.L": hand_l_res["measured"], "arms.R": hand_r_res["measured"],
		"hips": hip_span > height * 0.02,
		"legs": true,
	}
	# arm_scale lengthens/shortens the arm by scaling the shoulder->hand vector.
	hand_l = shoulder_l + (hand_l - shoulder_l) * arm_scale
	hand_r = shoulder_r + (hand_r - shoulder_r) * arm_scale

	# Distribute upper-arm / lower-arm joints along the shoulder->hand line so the
	# bones follow the limb's true direction whatever the pose.
	var upper_l := shoulder_l.lerp(hand_l, 0.34)
	var lower_l := shoulder_l.lerp(hand_l, 0.67)
	var upper_r := shoulder_r.lerp(hand_r, 0.34)
	var lower_r := shoulder_r.lerp(hand_r, 0.67)

	# leg_scale scales leg-joint heights relative to the hip (lower = longer legs).
	var hip_h: float = y0 + height * 0.52
	var knee_h: float = hip_h + (y0 + height * 0.25 - hip_h) * leg_scale
	var foot_h: float = hip_h + (y0 + height * 0.04 - hip_h) * leg_scale
	var upper_leg_h: float = hip_h + (y0 + height * 0.47 - hip_h) * leg_scale

	# Keyed by LOGICAL bone key; names are resolved per preset when bones are added.
	return {
		"hips": Vector3(center.x, y0 + height * 0.52, center.z),
		"spine": Vector3(center.x, y0 + height * 0.63, center.z),
		"chest": Vector3(center.x, y0 + height * 0.74, center.z),
		"neck": Vector3(center.x, y0 + height * 0.84, center.z),
		"head": Vector3(center.x, y0 + height * 0.93, center.z),
		"shoulder.L": shoulder_l,
		"upper_arm.L": upper_l,
		"lower_arm.L": lower_l,
		"hand.L": hand_l,
		"shoulder.R": shoulder_r,
		"upper_arm.R": upper_r,
		"lower_arm.R": lower_r,
		"hand.R": hand_r,
		"upper_leg.L": Vector3(center.x - hip_width, upper_leg_h, center.z),
		"lower_leg.L": Vector3(center.x - hip_width, knee_h, center.z),
		"foot.L": Vector3(center.x - hip_width, foot_h, center.z + foot_z),
		"upper_leg.R": Vector3(center.x + hip_width, upper_leg_h, center.z),
		"lower_leg.R": Vector3(center.x + hip_width, knee_h, center.z),
		"foot.R": Vector3(center.x + hip_width, foot_h, center.z + foot_z),
	}

# Finds the hand tip for one side by looking at vertices that lie beyond the
# torso width on that side and taking the one furthest from the shoulder. This
# adapts to T-pose (tip high & far out), A-pose, and arms-straight-down.
# Returns { "point": Vector3, "measured": bool } — measured is false when no arm
# mass was found and a fallback stub was used.
func _measure_hand_tip(mesh_entries: Array, center: Vector3, shoulder_width: float, shoulder: Vector3, right_side: bool, height: float) -> Dictionary:
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
		return {"point": shoulder + Vector3(sign * height * 0.18, 0.0, 0.0), "measured": false}
	return {"point": best, "measured": true}

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
	var chest := _bone_name("chest")
	var hips := _bone_name("hips")
	_add_bone_chain(skeleton, points, ["hips", "spine", "chest", "neck", "head"], -1)
	_add_bone_chain(skeleton, points, ["chest", "shoulder.L", "upper_arm.L", "lower_arm.L", "hand.L"], skeleton.find_bone(chest))
	_add_bone_chain(skeleton, points, ["chest", "shoulder.R", "upper_arm.R", "lower_arm.R", "hand.R"], skeleton.find_bone(chest))
	_add_bone_chain(skeleton, points, ["hips", "upper_leg.L", "lower_leg.L", "foot.L"], skeleton.find_bone(hips))
	_add_bone_chain(skeleton, points, ["hips", "upper_leg.R", "lower_leg.R", "foot.R"], skeleton.find_bone(hips))
	_add_preview_fingers(skeleton, points["hand.L"], false, height)
	_add_preview_fingers(skeleton, points["hand.R"], true, height)

# `keys` are LOGICAL bone keys; the actual bone name is resolved per preset.
func _add_bone_chain(skeleton: Skeleton3D, points: Dictionary, keys: Array, forced_parent: int) -> void:
	var parent := forced_parent
	for key in keys:
		var bone_name: String = _bone_name(key)
		var existing: int = skeleton.find_bone(bone_name)
		if existing != -1:
			parent = existing
			continue
		skeleton.add_bone(bone_name)
		var idx: int = skeleton.find_bone(bone_name)
		if parent != -1:
			skeleton.set_bone_parent(idx, parent)
		_set_bone_rest_from_global_point(skeleton, idx, parent, points[key])
		parent = idx

func _add_preview_fingers(skeleton: Skeleton3D, hand_pos: Vector3, right_side: bool, height: float) -> void:
	var hand_index: int = skeleton.find_bone(_bone_name("hand.R" if right_side else "hand.L"))
	if hand_index == -1:
		return
	var side: float = 1.0 if right_side else -1.0
	for finger_i in range(_FINGER_KEYS.size()):
		var spread: float = float(finger_i - 2) * height * 0.005
		var thumb_push: float = height * 0.012 if finger_i == 0 else 0.0
		var base_offset := Vector3(
			side * height * (0.010 + finger_i * 0.004 + thumb_push),
			height * (0.006 - finger_i * 0.0015),
			spread,
		)
		var parent := hand_index
		for segment in range(1, 4):
			var bone_name: String = _finger_bone_name(_FINGER_KEYS[finger_i], segment, right_side)
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
	# Heat diffusion must see the WHOLE mesh at once: a material split becomes a
	# separate Godot surface, so per-surface solving would break diffusion at every
	# material seam. Solve all surfaces together (one welded graph spanning them),
	# then scatter the result back per surface. Proximity is per-vertex, so it stays
	# per-surface. `heat_weights[s]` = {bones, weights} for surface s, or empty.
	var heat_weights: Array = []
	if skin_method == SkinMethod.HEAT_DIFFUSION:
		heat_weights = _solve_heat_for_mesh(mesh, xform, segments)
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
			baked_verts[vi] = xform * verts[vi]
		if skin_method == SkinMethod.HEAT_DIFFUSION:
			bones = heat_weights[s]["bones"]
			weights = heat_weights[s]["weights"]
		else:
			_assign_weights_proximity(baked_verts, segments, bones, weights)
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

# PROXIMITY method: per-vertex distance-to-bone weights (original behaviour).
# Fills `bones`/`weights` (4 per vertex) for every baked vertex.
func _assign_weights_proximity(baked_verts: PackedVector3Array, segments: Array, bones: PackedInt32Array, weights: PackedFloat32Array) -> void:
	for vi in range(baked_verts.size()):
		var assignment: Dictionary = _weights_for_point(baked_verts[vi], segments)
		var idx_list: Array = assignment["bones"]
		var w_list: Array = assignment["weights"]
		for k in range(4):
			bones[vi * 4 + k] = idx_list[k]
			weights[vi * 4 + k] = w_list[k]

# Solves heat diffusion across ALL of a mesh's surfaces at once, so weights flow
# across material seams (each material is a separate Godot surface). Concatenates
# every surface's baked vertices + triangles into one combined buffer (per-surface
# index offset), runs one heat solve, then slices the result back per surface.
# Returns an Array indexed by surface: { "bones": PackedInt32Array, "weights":
# PackedFloat32Array }, each sized 4 * that surface's vertex count.
func _solve_heat_for_mesh(mesh: Mesh, xform: Transform3D, segments: Array) -> Array:
	var surface_count := mesh.get_surface_count()
	var combined_verts := PackedVector3Array()
	var combined_index := PackedInt32Array()
	var offsets := PackedInt32Array()   # combined-buffer start index per surface
	var counts := PackedInt32Array()    # vertex count per surface
	offsets.resize(surface_count)
	counts.resize(surface_count)
	for s in range(surface_count):
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		offsets[s] = combined_verts.size()
		counts[s] = verts.size()
		var base := offsets[s]
		for vi in range(verts.size()):
			combined_verts.append(xform * verts[vi])
		# Append this surface's triangles, shifted by the surface's vertex offset.
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if idx.size() > 0:
			for k in idx:
				combined_index.append(base + k)
		else:
			# Unindexed surface: sequential triangles.
			for k in range(verts.size()):
				combined_index.append(base + k)

	# One combined "arrays" payload carrying just what the solver reads.
	var combined_arrays: Array = []
	combined_arrays.resize(Mesh.ARRAY_MAX)
	combined_arrays[Mesh.ARRAY_VERTEX] = combined_verts
	combined_arrays[Mesh.ARRAY_INDEX] = combined_index

	var total := combined_verts.size()
	var all_bones := PackedInt32Array()
	var all_weights := PackedFloat32Array()
	all_bones.resize(total * 4)
	all_weights.resize(total * 4)
	_assign_weights_heat(combined_verts, combined_arrays, segments, all_bones, all_weights)

	# Slice back per surface.
	var result: Array = []
	result.resize(surface_count)
	for s in range(surface_count):
		var sb := PackedInt32Array()
		var sw := PackedFloat32Array()
		var c := counts[s]
		sb.resize(c * 4)
		sw.resize(c * 4)
		var start := offsets[s] * 4
		for k in range(c * 4):
			sb[k] = all_bones[start + k]
			sw[k] = all_weights[start + k]
		result[s] = {"bones": sb, "weights": sw}
	return result

# HEAT_DIFFUSION core: seed each vertex with its single nearest bone, then relax
# across the welded surface adjacency graph so influence flows ALONG the surface
# and cannot jump a gap (armpit, between fingers, skirt-to-leg). Approximates
# Blender Bone Heat / Mixamo skinning without a full linear solve. Operates on one
# vertex+triangle buffer; callers pass the whole mesh (all surfaces) so material
# seams diffuse too — see _solve_heat_for_mesh.
func _assign_weights_heat(baked_verts: PackedVector3Array, arrays: Array, segments: Array, bones: PackedInt32Array, weights: PackedFloat32Array) -> void:
	var n := baked_verts.size()
	var bone_count := segments.size()
	if bone_count == 0 or n == 0:
		for vi in range(n):
			weights[vi * 4] = 1.0
		return

	# Flatten segment endpoints into packed arrays so the seed loop avoids per-element
	# Dictionary lookups (segments[j]["a"]) — those dominate on dense meshes.
	var seg_a := PackedVector3Array()
	var seg_b := PackedVector3Array()
	var col_bone := PackedInt32Array()
	seg_a.resize(bone_count)
	seg_b.resize(bone_count)
	col_bone.resize(bone_count)
	for j in range(bone_count):
		seg_a[j] = segments[j]["a"]
		seg_b[j] = segments[j]["b"]
		col_bone[j] = segments[j]["bone"]
	var bone_count_eff := bone_count

	# Build the surface graph. All meshes are position-welded onto representatives
	# (sews UV/normal seams that glTF/FBX split into duplicate indices); we seed,
	# diffuse, and collapse on representatives, then expand back to duplicates.
	# A real gap (no shared vertex position) stays disconnected, so heat can't jump
	# it; seams (coincident positions) are rejoined so it can cross them.
	var adj := _build_vertex_adjacency(arrays, n)
	var neighbours: Array = adj["neighbours"]   # per-representative neighbour lists
	var rep: PackedInt32Array = adj["rep"]        # vertex index -> representative index

	# Seed each REPRESENTATIVE with 1.0 on its single nearest segment. We solve on
	# representatives (size n, but non-reps are skipped) and expand back at the end.
	var heat := PackedFloat32Array()
	heat.resize(n * bone_count_eff)
	var seed_col := PackedInt32Array()  # nearest column per representative (for pinning)
	seed_col.resize(n)
	for r in range(n):
		if rep[r] != r:
			seed_col[r] = -1
			continue
		var p: Vector3 = baked_verts[r]
		var nearest := 0
		var nearest_d := INF
		for j in range(bone_count):
			var d: float = _distance_to_segment(p, seg_a[j], seg_b[j])
			if d < nearest_d:
				nearest_d = d
				nearest = j
		seed_col[r] = nearest
		heat[r * bone_count_eff + nearest] = 1.0

	# Relax: each pass moves every representative's heat toward the average of its
	# neighbours (Laplacian smoothing), then re-injects a fraction of its original
	# nearest-bone seed (soft pinning). The pin keeps locality from washing out:
	# without it, enough passes converge a connected component toward one average
	# label. Heat only flows along graph edges, which follow the welded surface, so
	# it cannot cross a real gap (armpit, between fingers) that isn't bridged by
	# coincident geometry — while UV/normal seams on a continuous surface ARE
	# bridged by the position weld, so diffusion crosses them.
	var passes := 14 if n <= 6000 else 8
	var self_w := 0.5
	var pin := 0.25       # re-injected seed strength per pass
	var next := PackedFloat32Array()
	next.resize(n * bone_count_eff)
	for _p in range(passes):
		for r in range(n):
			if rep[r] != r:
				continue
			var base := r * bone_count_eff
			var nb: PackedInt32Array = neighbours[r]
			if nb.size() == 0:
				for j in range(bone_count_eff):
					next[base + j] = heat[base + j]
			else:
				var share := (1.0 - self_w) / float(nb.size())
				for j in range(bone_count_eff):
					next[base + j] = heat[base + j] * self_w
				for ni in nb:
					var nbase := ni * bone_count_eff
					for j in range(bone_count_eff):
						next[base + j] += heat[nbase + j] * share
			# Soft-pin: scale the smoothed row by (1 - pin) and add `pin` back onto
			# the original nearest-bone column. Since the smoothed row sums to ~1
			# (row-stochastic update of unit-sum rows), the result stays a partition
			# of unity: (1 - pin)*1 + pin == 1. This keeps each vertex anchored to its
			# own nearest bone so locality doesn't wash out over many passes.
			var sc := seed_col[r]
			if sc != -1:
				for j in range(bone_count_eff):
					next[base + j] *= (1.0 - pin)
				next[base + sc] += pin
		# Swap buffers for the next pass.
		var tmp := heat
		heat = next
		next = tmp

	# Collapse each REPRESENTATIVE to top-4 bones, then expand to every vertex that
	# welded onto it (duplicates share the representative's result).
	for vi in range(n):
		var src := rep[vi]
		var base := src * bone_count_eff
		var top_col := [0, 0, 0, 0]
		var top_val := [0.0, 0.0, 0.0, 0.0]
		for j in range(bone_count_eff):
			var v: float = heat[base + j]
			if v <= top_val[3]:
				continue
			# Insert v into the sorted top-4.
			var slot := 3
			while slot > 0 and v > top_val[slot - 1]:
				top_val[slot] = top_val[slot - 1]
				top_col[slot] = top_col[slot - 1]
				slot -= 1
			top_val[slot] = v
			top_col[slot] = j
		var total: float = top_val[0] + top_val[1] + top_val[2] + top_val[3]
		if total <= 0.0:
			bones[vi * 4] = col_bone[0]
			weights[vi * 4] = 1.0
			continue
		for k in range(4):
			bones[vi * 4 + k] = col_bone[top_col[k]]
			weights[vi * 4 + k] = top_val[k] / total

# Builds the surface graph for heat diffusion. Returns:
#   { "neighbours": Array  — per-representative neighbour lists (PackedInt32Array),
#     "rep":        PackedInt32Array — vertex index -> representative index }
#
# Vertices are welded by quantized position onto a representative, then edges are
# added symmetrically between the representatives of each triangle's corners. The
# weld is essential: glTF/FBX split a single continuous surface into multiple
# vertex indices at every UV / normal / material seam (often the majority of
# vertices), so an index-buffer-only graph would be shattered into disconnected
# islands and heat could not diffuse across a seam. Welding by exact position
# rejoins those duplicates without bridging a real GAP — two surfaces only merge
# if they share a vertex position to ~0.1mm, which a deliberate gap (armpit,
# finger spacing in a rest pose) does not. So this both fixes seam diffusion AND
# keeps separated shells apart.
func _build_vertex_adjacency(arrays: Array, vertex_count: int) -> Dictionary:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var indexed := indices.size() > 0

	# Weld coincident positions onto a shared representative (sews UV/normal seams).
	var rep := _build_position_weld(arrays[Mesh.ARRAY_VERTEX])

	var sets: Array = []
	sets.resize(vertex_count)
	for i in range(vertex_count):
		sets[i] = {}

	var tri_count := indices.size() / 3 if indexed else vertex_count / 3
	for t in range(tri_count):
		var ia := indices[t * 3] if indexed else t * 3
		var ib := indices[t * 3 + 1] if indexed else t * 3 + 1
		var ic := indices[t * 3 + 2] if indexed else t * 3 + 2
		# Map every corner onto its weld representative.
		var a: int = rep[ia]
		var b: int = rep[ib]
		var c: int = rep[ic]
		if a >= vertex_count or b >= vertex_count or c >= vertex_count:
			continue
		# Symmetric edges between the triangle's representative corners.
		if a != b:
			(sets[a] as Dictionary)[b] = true
			(sets[b] as Dictionary)[a] = true
		if b != c:
			(sets[b] as Dictionary)[c] = true
			(sets[c] as Dictionary)[b] = true
		if a != c:
			(sets[a] as Dictionary)[c] = true
			(sets[c] as Dictionary)[a] = true

	var neighbours: Array = []
	neighbours.resize(vertex_count)
	for i in range(vertex_count):
		var arr := PackedInt32Array()
		for k in (sets[i] as Dictionary):
			arr.append(k)
		neighbours[i] = arr
	return {"neighbours": neighbours, "rep": rep}

# Maps each vertex index to a representative index for all vertices sharing its
# position (quantized), so duplicated seam/corner vertices act as one node.
func _build_position_weld(verts: PackedVector3Array) -> PackedInt32Array:
	var weld := PackedInt32Array()
	weld.resize(verts.size())
	var seen := {}
	for i in range(verts.size()):
		var p: Vector3 = verts[i]
		# Quantize to ~0.1 mm so floating-point duplicates collapse together.
		var key := "%d_%d_%d" % [roundi(p.x * 10000.0), roundi(p.y * 10000.0), roundi(p.z * 10000.0)]
		if seen.has(key):
			weld[i] = seen[key]
		else:
			seen[key] = i
			weld[i] = i
	return weld

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
