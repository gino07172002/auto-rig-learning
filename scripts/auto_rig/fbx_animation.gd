extends RefCounted
class_name FbxAnimation

# Parses the animation in a binary FBX into a Godot Animation resource keyed by
# BONE NAME, so it can be retargeted onto any skeleton that shares those names
# (e.g. another Mixamo character — same `mixamorig:` bones). Pure GDScript, reuses
# FbxParser. Reads each bone's Lcl Translation / Lcl Rotation curves over time and
# emits position_3d / rotation_3d tracks under "%GeneralSkeleton:<bone>" paths
# that an AnimationPlayer can play on a Skeleton3D.
#
# Bone names are normalized the same way the mesh importer does (":"/"/" -> "_"),
# so "mixamorig:LeftArm" matches the imported skeleton's "mixamorig_LeftArm".

const FbxParser = preload("res://scripts/auto_rig/fbx_parser.gd")

# FBX time unit: KTime is in 1/46186158000 of a second.
const FBX_KTIME := 46186158000.0

var error := ""

# Parses `path` and returns a Godot Animation (bone-name-keyed tracks), or null.
# `skeleton_node_name` is the node name the tracks should target (the Skeleton3D's
# name as seen from the AnimationPlayer's parent), default "Skeleton3D".
#
# `target_skeleton`, when provided, means the keys are being retargeted onto a
# Godot Skeleton3D. AnimationPlayer rotation tracks for Skeleton3D bones drive the
# bone's local pose rotation, so FBX node-local rotations are converted through
# rest-relative deltas, remapped to Godot's imported bone axes, then re-anchored
# on the target rest rotation.
func parse_animation(path: String, skeleton_node_name: String = "Skeleton3D", target_skeleton: Skeleton3D = null) -> Animation:
	error = ""
	var official_anim := _parse_animation_with_fbx_document(path, skeleton_node_name, target_skeleton)
	if official_anim != null:
		return official_anim

	var parser := FbxParser.new()
	var root := parser.parse_file(path)
	if root.is_empty():
		error = parser.error
		return null

	var objects := FbxParser.find_child(root, "Objects")
	var connections := FbxParser.find_child(root, "Connections")
	if objects.is_empty():
		error = "FBX has no Objects"
		return null

	# Index objects + connection graph.
	var models := {}          # id -> Model node
	var curve_nodes := {}     # id -> AnimationCurveNode node
	var curves := {}          # id -> AnimationCurve node
	for c in objects.get("children", []):
		if c["props"].is_empty():
			continue
		var id: int = c["props"][0]
		match c["name"]:
			"Model": models[id] = c
			"AnimationCurveNode": curve_nodes[id] = c
			"AnimationCurve": curves[id] = c

	# child_id -> Array[ [parent_id, prop_name] ]
	var parent_links := {}
	# parent_id -> Array[ [child_id, prop_name] ]
	var child_links := {}
	for conn in connections.get("children", []):
		var pr: Array = conn["props"]
		if pr.size() < 3:
			continue
		var child_id: int = pr[1]
		var parent_id: int = pr[2]
		var prop: String = str(pr[3]) if pr.size() > 3 else ""
		parent_links.get_or_add(child_id, []).append([parent_id, prop])
		child_links.get_or_add(parent_id, []).append([child_id, prop])

	var unit_scale := _read_unit_scale(root)

	# For each AnimationCurveNode (a T, R, or S channel of one bone), find the bone
	# it drives and the property (Lcl Translation/Rotation/Scaling), then read its
	# X/Y/Z AnimationCurves.
	# bone_name -> { "T": {x,y,z curves}, "R": {...}, "S": {...} }
	var bone_channels := {}
	var max_time := 0.0
	for cn_id in curve_nodes:
		var target_prop := ""
		var target_model := -1
		for link in parent_links.get(cn_id, []):
			var pid: int = link[0]
			var prop: String = link[1]
			if models.has(pid) and prop != "":
				target_model = pid
				target_prop = prop
				break
		if target_model == -1:
			continue
		var channel := _prop_to_channel(target_prop)
		if channel == "":
			continue
		var bone_name := _model_name(models[target_model])

		# This curve node's X/Y/Z curves come from its child connections, tagged
		# by property "d|X" / "d|Y" / "d|Z".
		var axis_curves := {"X": null, "Y": null, "Z": null}
		for link in child_links.get(cn_id, []):
			var ccid: int = link[0]
			var cprop: String = link[1]
			if not curves.has(ccid):
				continue
			var axis := cprop.substr(cprop.length() - 1)  # "d|X" -> "X"
			if axis_curves.has(axis):
				axis_curves[axis] = curves[ccid]

		var parsed := {}
		for axis in ["X", "Y", "Z"]:
			var cur = axis_curves[axis]
			if cur != null:
				var kd := _read_curve(cur)
				parsed[axis] = kd
				if kd["times"].size() > 0:
					max_time = maxf(max_time, kd["times"][kd["times"].size() - 1])
		if not bone_channels.has(bone_name):
			bone_channels[bone_name] = {}
		bone_channels[bone_name][channel] = parsed

	if bone_channels.is_empty():
		error = "FBX has no usable animation curves"
		return null

	return _build_animation(bone_channels, models, child_links, parent_links,
		skeleton_node_name, unit_scale, max_time, target_skeleton)

# Uses Godot's built-in FBX importer as the primary animation path. It matches
# Blender/ufbx bone-axis handling, while the hand-written parser below remains a
# fallback for environments or files the official importer cannot read.
func _parse_animation_with_fbx_document(path: String, skeleton_node_name: String,
		target_skeleton: Skeleton3D) -> Animation:
	if not FileAccess.file_exists(path):
		error = "FBX not found: %s" % path
		return null

	var doc := FBXDocument.new()
	var state := FBXState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		error = "Godot FBXDocument could not read animation (error %d)" % err
		return null

	var scene := doc.generate_scene(state) as Node3D
	if scene == null:
		error = "Godot FBXDocument did not generate a scene"
		return null

	var player := _find_animation_player(scene)
	if player == null:
		scene.free()
		error = "Godot FBXDocument scene has no AnimationPlayer"
		return null

	var source_anim := _pick_animation(player)
	if source_anim == null:
		scene.free()
		error = "Godot FBXDocument scene has no usable animation tracks"
		return null

	var anim: Animation
	if target_skeleton != null:
		var source_skeleton := _find_skeleton(scene)
		if source_skeleton == null:
			scene.free()
			error = "Godot FBXDocument scene has no Skeleton3D"
			return null
		anim = _bake_official_animation_to_target(scene, player, source_anim,
			source_skeleton, skeleton_node_name, target_skeleton)
	else:
		anim = source_anim.duplicate(true) as Animation
		_retarget_track_paths(anim, skeleton_node_name, target_skeleton)
	scene.free()
	if anim.get_track_count() == 0:
		error = "Godot FBXDocument animation has no bones matching this skeleton"
		return null
	return anim

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null

func _pick_animation(player: AnimationPlayer) -> Animation:
	var best: Animation = null
	var best_track_count := 0
	for name in player.get_animation_list():
		var anim := player.get_animation(name)
		if anim == null:
			continue
		var track_count := anim.get_track_count()
		if track_count > best_track_count:
			best = anim
			best_track_count = track_count
	return best

func _retarget_track_paths(anim: Animation, skeleton_node_name: String,
		target_skeleton: Skeleton3D) -> void:
	for i in range(anim.get_track_count() - 1, -1, -1):
		var ty := anim.track_get_type(i)
		if ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_SCALE_3D:
			anim.remove_track(i)
			continue
		var bone_name := _bone_name_from_track_path(anim.track_get_path(i))
		if bone_name == "":
			anim.remove_track(i)
			continue
		if target_skeleton != null and target_skeleton.find_bone(bone_name) == -1:
			anim.remove_track(i)
			continue
		anim.track_set_path(i, NodePath("%s:%s" % [skeleton_node_name, bone_name]))

func _bone_name_from_track_path(path: NodePath) -> String:
	var p := String(path)
	if not p.contains(":"):
		return ""
	var bone_name := p.substr(p.find(":") + 1)
	bone_name = bone_name.replace(":", "_").replace("/", "_")
	return bone_name

func _bake_official_animation_to_target(scene: Node3D, player: AnimationPlayer,
		source_anim: Animation, source_skeleton: Skeleton3D,
		skeleton_node_name: String, target_skeleton: Skeleton3D) -> Animation:
	var baked := Animation.new()
	baked.length = source_anim.length
	baked.loop_mode = source_anim.loop_mode

	var bones := _animated_bones(source_anim, source_skeleton, target_skeleton)
	var times := _animation_key_times(source_anim)
	if bones.is_empty() or times.is_empty():
		return baked

	var tree := Engine.get_main_loop() as SceneTree
	var added_to_tree := false
	if tree != null and scene.get_parent() == null:
		tree.root.add_child(scene)
		added_to_tree = true

	var clip_name := ""
	for name in player.get_animation_list():
		if player.get_animation(name) == source_anim:
			clip_name = name
			break
	if clip_name == "":
		clip_name = player.get_animation_list()[0]

	var pos_tracks := {}
	var rot_tracks := {}
	for bone_name in bones:
		var pos_track := baked.add_track(Animation.TYPE_POSITION_3D)
		baked.track_set_path(pos_track, NodePath("%s:%s" % [skeleton_node_name, bone_name]))
		pos_tracks[bone_name] = pos_track
		var rot_track := baked.add_track(Animation.TYPE_ROTATION_3D)
		baked.track_set_path(rot_track, NodePath("%s:%s" % [skeleton_node_name, bone_name]))
		rot_tracks[bone_name] = rot_track

	player.play(clip_name)
	for tm in times:
		player.seek(tm, true)
		player.advance(0.0)
		for bone_name in bones:
			var src_idx: int = source_skeleton.find_bone(bone_name)
			var src_global: Transform3D = source_skeleton.get_bone_global_pose(src_idx)
			var src_parent := source_skeleton.get_bone_parent(src_idx)
			var desired_local := src_global
			if src_parent != -1:
				var src_parent_global: Transform3D = source_skeleton.get_bone_global_pose(src_parent)
				desired_local = src_parent_global.affine_inverse() * src_global
			baked.position_track_insert_key(pos_tracks[bone_name], tm, desired_local.origin)
			baked.rotation_track_insert_key(rot_tracks[bone_name], tm,
				desired_local.basis.get_rotation_quaternion().normalized())

	player.stop()
	if added_to_tree:
		tree.root.remove_child(scene)
	return baked

func _animated_bones(_anim: Animation, source_skeleton: Skeleton3D,
		target_skeleton: Skeleton3D) -> Array[String]:
	var out: Array[String] = []
	for i in range(source_skeleton.get_bone_count()):
		var bone_name := source_skeleton.get_bone_name(i)
		if target_skeleton.find_bone(bone_name) != -1:
			out.append(bone_name)
	return out

func _animation_key_times(anim: Animation) -> PackedFloat32Array:
	var seen := {0.0: true, anim.length: true}
	for i in range(anim.get_track_count()):
		var ty := anim.track_get_type(i)
		if ty != Animation.TYPE_POSITION_3D and ty != Animation.TYPE_ROTATION_3D and ty != Animation.TYPE_SCALE_3D:
			continue
		for k in range(anim.track_get_key_count(i)):
			seen[anim.track_get_key_time(i, k)] = true
	var out := PackedFloat32Array()
	for tm in seen:
		out.append(float(tm))
	out.sort()
	return out

# Maps an FBX target property to a TRS channel letter.
func _prop_to_channel(prop: String) -> String:
	match prop:
		"Lcl Translation": return "T"
		"Lcl Rotation": return "R"
		"Lcl Scaling": return "S"
	return ""

# Reads an AnimationCurve into { "times": PackedFloat32Array (seconds),
# "values": PackedFloat32Array }.
func _read_curve(curve: Dictionary) -> Dictionary:
	var times := PackedFloat32Array()
	var values := PackedFloat32Array()
	var kt := FbxParser.find_child(curve, "KeyTime")
	var kv := FbxParser.find_child(curve, "KeyValueFloat")
	if kt.is_empty() or kv.is_empty() or kt["props"].is_empty() or kv["props"].is_empty():
		return {"times": times, "values": values}
	var t_arr = kt["props"][0]   # PackedInt64Array (ktime)
	var v_arr = kv["props"][0]   # PackedFloat32Array
	var n := mini(t_arr.size(), v_arr.size())
	times.resize(n)
	values.resize(n)
	for i in range(n):
		times[i] = float(t_arr[i]) / FBX_KTIME
		values[i] = v_arr[i]
	return {"times": times, "values": values}

# Builds the Animation resource: one position_3d + one rotation_3d track per bone
# that has T or R channels. Values are sampled onto a shared, sorted key timeline.
func _build_animation(bone_channels: Dictionary, models: Dictionary, child_links: Dictionary,
		parent_links: Dictionary, skeleton_node_name: String, unit_scale: float, max_time: float,
		target_skeleton: Skeleton3D) -> Animation:
	var anim := Animation.new()
	anim.length = maxf(max_time, 0.0001)
	anim.loop_mode = Animation.LOOP_LINEAR

	for bone_name in bone_channels:
		var channels: Dictionary = bone_channels[bone_name]
		var base_path := "%s:%s" % [skeleton_node_name, bone_name]

		# Position track (from T channel), scaled to metres.
		if channels.has("T"):
			var t_times := _channel_times(channels["T"])
			if t_times.size() > 0:
				var pos_track := anim.add_track(Animation.TYPE_POSITION_3D)
				anim.track_set_path(pos_track, NodePath(base_path))
				for tm in t_times:
					var v := _sample_vec(channels["T"], tm) * unit_scale
					anim.position_track_insert_key(pos_track, tm, v)

		# Rotation track (from R channel) -> Godot bone local pose rotation.
		# FBX stores node-local animation in its own bind basis, so convert the FBX
		# local pose into a delta, remap that delta to Godot's imported bone axes,
		# and apply it on top of the target rest rotation.
		if channels.has("R"):
			var r_times := _channel_times(channels["R"])
			if r_times.size() > 0:
				var pre := Vector3.ZERO
				var post := Vector3.ZERO
				var fbx_rest := Quaternion.IDENTITY
				var model_id := _find_model_id_for_bone(models, bone_name)
				if model_id != -1:
					var pp := _read_pre_post(models[model_id])
					pre = pp["pre"]
					post = pp["post"]
					fbx_rest = _fbx_local_rotation(pre, pp["rest_rotation"], post)
				var rot_track := anim.add_track(Animation.TYPE_ROTATION_3D)
				anim.track_set_path(rot_track, NodePath(base_path))
				for tm in r_times:
					var euler := _sample_vec(channels["R"], tm)  # degrees
					var fbx_pose := _fbx_local_rotation(pre, euler, post)
					var q := fbx_pose
					if target_skeleton != null and model_id != -1:
						var delta := fbx_rest.inverse() * fbx_pose
						var bone_idx := target_skeleton.find_bone(bone_name)
						var target_rest := Quaternion.IDENTITY
						if bone_idx != -1:
							target_rest = target_skeleton.get_bone_rest(bone_idx).basis.get_rotation_quaternion()
						q = target_rest * _fbx_delta_to_godot_pose(delta, bone_name)
					anim.rotation_track_insert_key(rot_track, tm, q.normalized())
	return anim

# Remaps an FBX-local pose delta into Godot's imported bone axes. Mixamo's bones
# import with a bone-local basis that differs from the FBX node basis; this fixed
# component remap matches what Blender's FBX importer produces (validated against
# Blender hand/wrist world poses). The right-arm chain mirrors differently.
func _fbx_delta_to_godot_pose(q: Quaternion, bone_name: String = "") -> Quaternion:
	if _is_right_arm_tree_bone(bone_name):
		return Quaternion(q.z, -q.x, -q.y, q.w)
	return Quaternion(-q.z, q.y, -q.x, q.w)

func _is_right_arm_tree_bone(bone_name: String) -> bool:
	return bone_name.contains("Right") and (bone_name.contains("Shoulder") or bone_name.contains("Arm") or bone_name.contains("Hand"))

# Collects the sorted union of key times across a channel's X/Y/Z curves.
func _channel_times(channel: Dictionary) -> PackedFloat32Array:
	var set := {}
	for axis in ["X", "Y", "Z"]:
		if channel.has(axis):
			for t in (channel[axis]["times"] as PackedFloat32Array):
				set[t] = true
	var out := PackedFloat32Array()
	for t in set:
		out.append(t)
	out.sort()
	return out

# Samples a channel's X/Y/Z at time `t` (linear interpolation per axis).
func _sample_vec(channel: Dictionary, t: float) -> Vector3:
	return Vector3(
		_sample_axis(channel.get("X"), t),
		_sample_axis(channel.get("Y"), t),
		_sample_axis(channel.get("Z"), t),
	)

func _sample_axis(curve, t: float) -> float:
	if curve == null:
		return 0.0
	var times: PackedFloat32Array = curve["times"]
	var values: PackedFloat32Array = curve["values"]
	var n := times.size()
	if n == 0:
		return 0.0
	if t <= times[0]:
		return values[0]
	if t >= times[n - 1]:
		return values[n - 1]
	# Binary search for the bracketing keys.
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if times[mid] <= t:
			lo = mid
		else:
			hi = mid
	var span := times[hi] - times[lo]
	if span <= 0.0:
		return values[lo]
	var f := (t - times[lo]) / span
	return lerpf(values[lo], values[hi], f)

# Local rotation basis = pre * R(euler) * post^-1, matching the mesh importer's
# rest construction, returned as a quaternion.
func _fbx_local_rotation(pre: Vector3, euler_deg: Vector3, post: Vector3) -> Quaternion:
	var basis := _euler_basis(pre) * _euler_basis(euler_deg) * _euler_basis(post).inverse()
	return basis.get_rotation_quaternion()

func _euler_basis(degrees: Vector3) -> Basis:
	# Blender's FBX importer interprets FBX/Maya "XYZ" Euler as a matrix order
	# matching Godot's ZYX enum convention.
	return Basis.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)), EULER_ORDER_ZYX)

func _read_pre_post(model: Dictionary) -> Dictionary:
	var pre := Vector3.ZERO
	var post := Vector3.ZERO
	var rest_rotation := Vector3.ZERO  # the model's default Lcl Rotation (rest)
	var props := FbxParser.find_child(model, "Properties70")
	for p in props.get("children", []):
		var pr: Array = p["props"]
		if pr.is_empty():
			continue
		var n: int = pr.size()
		if pr[0] == "PreRotation":
			pre = Vector3(pr[n-3], pr[n-2], pr[n-1])
		elif pr[0] == "PostRotation":
			post = Vector3(pr[n-3], pr[n-2], pr[n-1])
		elif pr[0] == "Lcl Rotation":
			rest_rotation = Vector3(pr[n-3], pr[n-2], pr[n-1])
	return {"pre": pre, "post": post, "rest_rotation": rest_rotation}

func _find_model_id_for_bone(models: Dictionary, bone_name: String) -> int:
	for id in models:
		if _model_name(models[id]) == bone_name:
			return id
	return -1

func _model_name(model: Dictionary) -> String:
	var raw: String = model["props"][1] if model["props"].size() > 1 else "Bone"
	var nul := raw.find(char(0))
	if nul != -1:
		raw = raw.substr(0, nul)
	raw = raw.replace(":", "_").replace("/", "_")
	if raw.strip_edges() == "":
		raw = "Bone"
	return raw

func _read_unit_scale(root: Dictionary) -> float:
	var settings := FbxParser.find_child(root, "GlobalSettings")
	var props := FbxParser.find_child(settings, "Properties70")
	for p in props.get("children", []):
		if p["props"].size() >= 5 and p["props"][0] == "UnitScaleFactor":
			var f: float = float(p["props"][p["props"].size() - 1])
			if f > 0.0:
				return f * 0.01
	return 0.01
