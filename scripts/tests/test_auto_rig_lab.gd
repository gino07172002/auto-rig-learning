extends RefCounted

const TestAssert = preload("res://scripts/core/test_assert.gd")

# Unrigged humanoid used by the auto-fit tests. Prefer the in-repo fixture so
# the suite is self-contained; fall back to the original external authoring file
# if it happens to be present on a dev machine.
const UNRIGGED_MODEL := "res://assets/models/external_test/noskel/noskel_stocky_down.glb"
const UNRIGGED_MODEL_FALLBACK := "D:/blenders/knight girl/knightGirl2.glb"

# Returns a usable unrigged model path, or fails loudly if none can be found
# (instead of letting a later load() return null and produce a confusing error).
func _unrigged_model_path() -> String:
	if _file_exists(UNRIGGED_MODEL):
		return UNRIGGED_MODEL
	if _file_exists(UNRIGGED_MODEL_FALLBACK):
		return UNRIGGED_MODEL_FALLBACK
	push_error("Auto-rig tests: no unrigged model found at %s or %s" % [UNRIGGED_MODEL, UNRIGGED_MODEL_FALLBACK])
	assert(false, "missing unrigged test model")
	return ""

func _file_exists(path: String) -> bool:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ResourceLoader.exists(path) or FileAccess.file_exists(ProjectSettings.globalize_path(path))
	return FileAccess.file_exists(path)

# Loads an unrigged model for fitting, asserting the import actually produced a
# scene so callers get a clear failure rather than a null dereference.
func _load_unrigged(fitter) -> Node3D:
	var path := _unrigged_model_path()
	var root: Node3D = fitter.load_scene_for_preview(path)
	TestAssert.truthy(root != null, "unrigged model loaded from %s" % path)
	return root

func run() -> void:
	test_rig_analyzer_detects_existing_skeleton()
	test_rig_analyzer_marks_unskinned_model_as_auto_fit_candidate()
	test_auto_fitter_builds_toon_humanoid_preview_skeleton()
	test_auto_fitter_skins_mesh_to_generated_skeleton()
	test_auto_fitter_skinned_mesh_deforms_when_bone_posed()
	test_auto_rigged_model_survives_glb_export_roundtrip()
	test_lab_plays_imported_models_builtin_animation()
	test_pose_preview_keeps_imported_rig_at_rest()
	test_auto_fitter_corrects_z_up_models()
	test_auto_fitter_follows_arms_down_pose()
	test_auto_fitter_keeps_tpose_arms_horizontal()
	test_analyzer_accepts_z_up_model_as_auto_fit_candidate()
	test_auto_rig_lab_scene_has_split_rig_and_preview_workspace()
	test_bone_style_switch_changes_overlay()
	test_export_button_writes_rigged_glb()
	test_fitter_blender_naming_preset()
	test_fitter_proportion_scales_affect_rig()

# Rigged-skeleton model used for the detection tests. CesiumMan is a small
# in-repo fixture with a real skinned skeleton, so this test is self-contained.
# License: CC-BY 4.0, (c) 2017 Cesium. See assets/models/external_test/SOURCES.md.
const RIGGED_MODEL := "res://assets/models/external_test/CesiumMan.glb"

func test_rig_analyzer_detects_existing_skeleton() -> void:
	var analyzer_script = load("res://scripts/auto_rig/auto_rig_analyzer.gd")
	TestAssert.truthy(analyzer_script != null, "auto rig analyzer script exists")
	var analyzer = analyzer_script.new()
	var report: Dictionary = analyzer.analyze_scene_path(RIGGED_MODEL)
	TestAssert.equal(report.get("status", ""), "ok", "rig analysis succeeds")
	TestAssert.truthy(report.get("has_skeleton", false), "model has skeleton")
	TestAssert.truthy(report.get("bone_count", 0) > 0, "skeleton bones detected")
	TestAssert.truthy(report.get("preview_ready", false), "rig is ready for realtime preview")

func test_rig_analyzer_marks_unskinned_model_as_auto_fit_candidate() -> void:
	var analyzer_script = load("res://scripts/auto_rig/auto_rig_analyzer.gd")
	var analyzer = analyzer_script.new()
	var report: Dictionary = analyzer.analyze_scene_path(_unrigged_model_path())
	TestAssert.equal(report.get("status", ""), "ok", "unskinned model imports")
	TestAssert.falsy(report.get("has_skeleton", true), "unskinned model has no skeleton")
	TestAssert.truthy(report.get("auto_fit_candidate", false), "unskinned humanoid can be auto-fit")
	TestAssert.truthy(report.get("mesh_count", 0) > 0, "unskinned model has meshes")

func test_auto_fitter_builds_toon_humanoid_preview_skeleton() -> void:
	var fitter_script = load("res://scripts/auto_rig/toon_humanoid_fitter.gd")
	TestAssert.truthy(fitter_script != null, "toon humanoid fitter exists")
	var fitter = fitter_script.new()
	var root: Node3D = _load_unrigged(fitter)
	var skeleton: Skeleton3D = fitter.fit_skeleton(root)
	TestAssert.truthy(skeleton != null, "generated preview skeleton exists")
	TestAssert.equal(skeleton.get_bone_count(), 49, "generated skeleton has toon game body + full fingers")
	TestAssert.truthy(skeleton.find_bone("Toon_Hand.L") != -1, "left hand bone generated")
	TestAssert.truthy(skeleton.find_bone("Toon_Index3.R") != -1, "right distal finger bone generated")
	TestAssert.truthy(skeleton.find_bone("Toon_Pinky3.L") != -1, "left pinky distal finger bone generated")
	root.free()

func test_auto_fitter_skins_mesh_to_generated_skeleton() -> void:
	var fitter_script = load("res://scripts/auto_rig/toon_humanoid_fitter.gd")
	var fitter = fitter_script.new()
	var root: Node3D = _load_unrigged(fitter)
	var skeleton: Skeleton3D = fitter.fit_skeleton(root)
	TestAssert.truthy(skeleton != null, "generated skeleton exists")
	var info: Dictionary = fitter.last_fit_info
	TestAssert.truthy(info.get("skinned", false), "fit reports meshes were skinned")
	TestAssert.truthy(info.get("skinned_mesh_count", 0) > 0, "at least one mesh skinned")

	# A skinned MeshInstance3D must live under the skeleton, carry a Skin, and
	# point its skeleton property back at the skeleton.
	var skinned: Array = skeleton.find_children("*", "MeshInstance3D", true, false)
	TestAssert.truthy(skinned.size() > 0, "skinned mesh instances parented under skeleton")
	var first: MeshInstance3D = skinned[0]
	TestAssert.truthy(first.skin != null, "skinned mesh has a Skin resource")
	TestAssert.truthy(first.get_node_or_null(first.skeleton) == skeleton, "skinned mesh points at the skeleton")

	# Bones + weights arrays must exist and weights must sum to ~1 per vertex.
	var arrays: Array = first.mesh.surface_get_arrays(0)
	var bones = arrays[Mesh.ARRAY_BONES]
	var weights = arrays[Mesh.ARRAY_WEIGHTS]
	TestAssert.truthy(bones != null and weights != null, "skinned surface has bone + weight arrays")
	var vert_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	TestAssert.equal(bones.size(), vert_count * 4, "4 bone indices per vertex")
	var w_sum: float = weights[0] + weights[1] + weights[2] + weights[3]
	TestAssert.truthy(absf(w_sum - 1.0) < 0.001, "first vertex weights normalized to 1")
	root.free()

func test_auto_fitter_skinned_mesh_deforms_when_bone_posed() -> void:
	# Verifies real deformation: posing a bone must move the vertices bound to it.
	# We reproduce the GPU skin transform on the CPU (bind pose * bone global pose)
	# and confirm a strongly-weighted vertex actually shifts.
	var fitter_script = load("res://scripts/auto_rig/toon_humanoid_fitter.gd")
	var fitter = fitter_script.new()
	var root: Node3D = _load_unrigged(fitter)
	var skeleton: Skeleton3D = fitter.fit_skeleton(root)
	# Skeleton must be inside a tree (and explicitly updated) for global pose math.
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(root)
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()

	var skinned: Array = skeleton.find_children("*", "MeshInstance3D", true, false)
	var mesh_instance: MeshInstance3D = skinned[0]
	var skin: Skin = mesh_instance.skin
	var arrays: Array = mesh_instance.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones = arrays[Mesh.ARRAY_BONES]
	var weights = arrays[Mesh.ARRAY_WEIGHTS]

	# Find the most dominantly-weighted (bone, vertex) pair, excluding the root
	# bone (rotating the root moves everything trivially). Model-agnostic so it
	# works for any unrigged fixture, not one with a specific limb layout.
	var best_bone := -1
	var best_vi := -1
	var best_weight := 0.0
	for vi in range(verts.size()):
		for k in range(4):
			var bone: int = bones[vi * 4 + k]
			var w: float = weights[vi * 4 + k]
			if bone != -1 and skeleton.get_bone_parent(bone) != -1 and w > best_weight:
				best_weight = w
				best_bone = bone
				best_vi = vi
	TestAssert.truthy(best_bone != -1 and best_vi != -1, "found a dominantly-bound vertex")

	var rest_pos: Vector3 = _skinned_vertex(skeleton, skin, verts, bones, weights, best_vi)
	# Rotate the bone meaningfully and recompute.
	skeleton.set_bone_pose_rotation(best_bone, Quaternion(Vector3.FORWARD, deg_to_rad(60.0)))
	skeleton.force_update_all_bone_transforms()
	var posed_pos: Vector3 = _skinned_vertex(skeleton, skin, verts, bones, weights, best_vi)
	var delta: float = rest_pos.distance_to(posed_pos)
	TestAssert.truthy(delta > 0.01, "posing bone '%s' deforms the bound vertex (delta=%f)" % [skeleton.get_bone_name(best_bone), delta])

	root.free()

# Computes the CPU-skinned world position of one vertex, matching how the GPU
# applies linear blend skinning: sum_k weight_k * (bone_pose_k * bind_k * v).
func _skinned_vertex(skeleton: Skeleton3D, skin: Skin, verts: PackedVector3Array, bones, weights, vi: int) -> Vector3:
	var v: Vector3 = verts[vi]
	var result := Vector3.ZERO
	for k in range(4):
		var w: float = weights[vi * 4 + k]
		if w <= 0.0:
			continue
		var bone: int = bones[vi * 4 + k]
		var bind: Transform3D = _bind_for_bone(skin, bone)
		var pose: Transform3D = skeleton.get_bone_global_pose(bone)
		result += (pose * bind * v) * w
	return result

func _bind_for_bone(skin: Skin, bone: int) -> Transform3D:
	for i in range(skin.get_bind_count()):
		if skin.get_bind_bone(i) == bone:
			return skin.get_bind_pose(i)
	return Transform3D.IDENTITY

# Cross-tool interop guard: an auto-rigged model must export to a portable .glb
# (the same path Blender consumes) and re-import with its skeleton, fingers, and
# skinned meshes intact. This protects the Godot<->Blender roundtrip.
func test_auto_rigged_model_survives_glb_export_roundtrip() -> void:
	var fitter_script = load("res://scripts/auto_rig/toon_humanoid_fitter.gd")
	var fitter = fitter_script.new()
	var root: Node3D = _load_unrigged(fitter)
	var skeleton: Skeleton3D = fitter.fit_skeleton(root)
	TestAssert.truthy(skeleton != null, "auto-rig produced a skeleton")
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(root)
	skeleton.force_update_all_bone_transforms()

	var out_path := "user://_roundtrip_test.glb"
	var err: int = fitter.export_to_glb(root, out_path)
	TestAssert.equal(err, OK, "auto-rigged model exports to glb")
	TestAssert.truthy(FileAccess.file_exists(ProjectSettings.globalize_path(out_path)), "glb file written")

	# Re-import through the same analyzer Godot uses for any external model.
	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var report: Dictionary = analyzer.analyze_scene_path(out_path)
	TestAssert.equal(report.get("status", ""), "ok", "exported glb re-imports cleanly")
	TestAssert.truthy(report.get("has_skeleton", false), "skeleton survives the roundtrip")
	TestAssert.truthy(report.get("bone_count", 0) >= 49, "all bones survive the roundtrip")
	TestAssert.equal(report.get("finger_bone_count", 0), 30, "all finger bones survive the roundtrip")
	TestAssert.truthy(report.get("preview_ready", false), "roundtripped rig is still preview-ready")

	root.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))

# When an imported model carries its own AnimationPlayer (e.g. a Blender-authored
# Walk clip), the lab should detect it, prefer a locomotion clip, loop it, and
# play it instead of the procedural preview.
func test_lab_plays_imported_models_builtin_animation() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	# Build a minimal skinned-ish model: skeleton + AnimationPlayer with two clips.
	var model := Node3D.new()
	var skel := Skeleton3D.new()
	skel.add_bone("Root")
	model.add_child(skel)
	var player := AnimationPlayer.new()
	var lib := AnimationLibrary.new()
	lib.add_animation("TPose", Animation.new())
	lib.add_animation("Walk", Animation.new())
	player.add_animation_library("", lib)
	model.add_child(player)

	# Inject as the lab's loaded scene and run the detection path.
	lab._loaded_scene = model
	lab._skeleton = skel
	lab._setup_builtin_animation()

	TestAssert.equal(lab._builtin_animation, "Walk", "lab prefers the locomotion clip")
	TestAssert.truthy(lab._anim_player != null, "lab captured the model's AnimationPlayer")
	TestAssert.truthy(lab._anim_player.is_playing(), "lab is playing the imported clip")
	TestAssert.equal(player.get_animation("Walk").loop_mode, Animation.LOOP_LINEAR, "clip is looped for preview")

	lab.free()

# Regression for the pose-preview neutral-pose bug: on a rig whose bones have
# non-identity REST orientations (e.g. an imported CesiumMan), the idle preview
# must leave each bone at its rest pose, not double-apply the rest basis.
func test_pose_preview_keeps_imported_rig_at_rest() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = RIGGED_MODEL
	lab._load_model_from_ui()

	var skel: Skeleton3D = lab._skeleton
	TestAssert.truthy(skel != null, "imported rig has a skeleton")
	# Confirm the fixture actually has non-identity rest (else this test is vacuous).
	var has_non_identity := false
	for i in range(skel.get_bone_count()):
		if skel.get_bone_rest(i).basis.get_rotation_quaternion().angle_to(Quaternion.IDENTITY) > 0.01:
			has_non_identity = true
			break
	TestAssert.truthy(has_non_identity, "fixture has non-identity rest bones")

	# Neutral preview: sliders at 0, no built-in animation driving the pose.
	lab._anim_player = null
	lab._finger_slider.value = 0.0
	lab._pose_slider.value = 0.0
	lab._phase = 0.0
	lab._pose_preview(0.0)
	skel.force_update_all_bone_transforms()

	# Every bone's posed global transform must match its rest global transform.
	var max_err := 0.0
	for i in range(skel.get_bone_count()):
		var rest_o: Vector3 = skel.get_bone_global_rest(i).origin
		var pose_o: Vector3 = skel.get_bone_global_pose(i).origin
		max_err = maxf(max_err, rest_o.distance_to(pose_o))
	TestAssert.truthy(max_err < 0.001, "neutral preview keeps bones at rest (max_err=%f)" % max_err)
	lab.free()

# A Z-up model (Blender export without yup conversion) must be auto-corrected to
# Y-up so the rigged figure stands up: head clearly above hips, body taller than
# it is deep. Without the fix the figure lies on its side.
func test_auto_fitter_corrects_z_up_models() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var model: Node3D = fitter.load_scene_for_preview("res://assets/models/external_test/noskel/noskel_zup_tpose.glb")
	TestAssert.truthy(model != null, "z-up fixture loads")
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(model)
	var skel: Skeleton3D = fitter.fit_skeleton(model)
	skel.force_update_all_bone_transforms()

	var hips_y: float = skel.get_bone_global_rest(skel.find_bone("Toon_Hips")).origin.y
	var head_y: float = skel.get_bone_global_rest(skel.find_bone("Toon_Head")).origin.y
	TestAssert.truthy(head_y > hips_y + 0.3, "head sits well above hips (figure is upright)")

	# The skinned rest mesh should now be taller (Y) than deep (Z) after correction.
	var skinned: Array = skel.find_children("*", "MeshInstance3D", true, false)
	var aabb: AABB = skinned[0].mesh.get_aabb()
	TestAssert.truthy(aabb.size.y > aabb.size.z, "corrected mesh is taller than it is deep")
	model.free()

# An arms-down (A-pose) model must get arm bones that descend to the sides, not a
# forced horizontal T-pose. We check the hand bone is well below the shoulder.
func test_auto_fitter_follows_arms_down_pose() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var model: Node3D = fitter.load_scene_for_preview("res://assets/models/external_test/noskel/noskel_stocky_down.glb")
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(model)
	var skel: Skeleton3D = fitter.fit_skeleton(model)
	skel.force_update_all_bone_transforms()
	var shoulder_y: float = skel.get_bone_global_rest(skel.find_bone("Toon_Shoulder.L")).origin.y
	var hand_y: float = skel.get_bone_global_rest(skel.find_bone("Toon_Hand.L")).origin.y
	TestAssert.truthy(hand_y < shoulder_y - 0.2, "arms-down pose: hand drops below the shoulder")
	model.free()

# Sanity check on the T-pose case so the arm-pose detection isn't biased: a real
# T-pose should keep the hand roughly at shoulder height, reaching outward.
func test_auto_fitter_keeps_tpose_arms_horizontal() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var model: Node3D = fitter.load_scene_for_preview("res://assets/models/external_test/noskel/noskel_tall_tpose.glb")
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(model)
	var skel: Skeleton3D = fitter.fit_skeleton(model)
	skel.force_update_all_bone_transforms()
	var shoulder := skel.get_bone_global_rest(skel.find_bone("Toon_Shoulder.L")).origin
	var hand := skel.get_bone_global_rest(skel.find_bone("Toon_Hand.L")).origin
	TestAssert.truthy(absf(hand.y - shoulder.y) < 0.35, "t-pose hand stays near shoulder height")
	TestAssert.truthy(absf(hand.x - shoulder.x) > 0.3, "t-pose hand reaches outward")
	model.free()

func test_analyzer_accepts_z_up_model_as_auto_fit_candidate() -> void:
	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var r: Dictionary = analyzer.analyze_scene_path("res://assets/models/external_test/noskel/noskel_zup_tpose.glb")
	TestAssert.equal(r.get("status", ""), "ok", "z-up model imports")
	TestAssert.truthy(r.get("auto_fit_candidate", false), "z-up tall model is an auto-fit candidate")

# The Blender naming preset must emit Blender/Rigify-style bone names instead of
# Toon_*, while keeping the same bone count and structure.
func test_fitter_blender_naming_preset() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	fitter.naming = fitter.Naming.BLENDER
	var root: Node3D = _load_unrigged(fitter)
	var skeleton: Skeleton3D = fitter.fit_skeleton(root)
	TestAssert.truthy(skeleton != null, "blender-named skeleton generated")
	TestAssert.equal(skeleton.get_bone_count(), 49, "same bone count across presets")
	# Blender-style names present, Toon names absent.
	TestAssert.truthy(skeleton.find_bone("upper_arm.L") != -1, "blender upper_arm.L exists")
	TestAssert.truthy(skeleton.find_bone("forearm.R") != -1, "blender forearm.R exists")
	TestAssert.truthy(skeleton.find_bone("thigh.L") != -1, "blender thigh.L exists")
	TestAssert.truthy(skeleton.find_bone("f_index.03.R") != -1, "blender finger f_index.03.R exists")
	TestAssert.truthy(skeleton.find_bone("Toon_Hand.L") == -1, "no Toon names under blender preset")
	root.free()

# Manual proportion multipliers must measurably change joint placement: a wider
# shoulder scale pushes the shoulder bone further out; a larger leg scale lowers
# the foot.
func test_fitter_proportion_scales_affect_rig() -> void:
	var base = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var root_a: Node3D = _load_unrigged(base)
	var skel_a: Skeleton3D = base.fit_skeleton(root_a)
	var base_shoulder_x: float = absf(skel_a.get_bone_global_rest(skel_a.find_bone("Toon_Shoulder.L")).origin.x)
	var base_foot_y: float = skel_a.get_bone_global_rest(skel_a.find_bone("Toon_Foot.L")).origin.y
	root_a.free()

	var wide = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	wide.shoulder_scale = 1.6
	wide.leg_scale = 1.4
	var root_b: Node3D = _load_unrigged(wide)
	var skel_b: Skeleton3D = wide.fit_skeleton(root_b)
	var wide_shoulder_x: float = absf(skel_b.get_bone_global_rest(skel_b.find_bone("Toon_Shoulder.L")).origin.x)
	var wide_foot_y: float = skel_b.get_bone_global_rest(skel_b.find_bone("Toon_Foot.L")).origin.y
	root_b.free()

	TestAssert.truthy(wide_shoulder_x > base_shoulder_x + 0.01, "shoulder scale widens the shoulders")
	TestAssert.truthy(wide_foot_y < base_foot_y - 0.01, "leg scale lowers the foot")

func test_auto_rig_lab_scene_has_split_rig_and_preview_workspace() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	TestAssert.truthy(scene != null, "auto rig lab scene exists")
	var root = scene.instantiate()
	TestAssert.truthy(root.find_child("AutoRigPanel", true, false) != null, "left auto-rig panel exists")
	TestAssert.truthy(root.find_child("PreviewViewport", true, false) != null, "right realtime preview exists")
	TestAssert.truthy(root.find_child("LoadModelButton", true, false) != null, "model import control exists")
	TestAssert.truthy(root.find_child("FingerCurlSlider", true, false) != null, "finger fine-tune slider exists")
	TestAssert.truthy(root.find_child("RigQualityLabel", true, false) != null, "rig quality label exists")
	TestAssert.truthy(root.find_child("RigOverlayRoot", true, false) != null, "skeleton overlay root exists")
	TestAssert.truthy(root.find_child("BoneStyleOption", true, false) != null, "bone style dropdown exists")
	TestAssert.truthy(root.find_child("ExportGlbButton", true, false) != null, "export glb button exists")
	root.free()

# The Export button must write a valid .glb that re-imports with its skeleton,
# exercising the full load -> rig -> export-via-UI path.
func test_export_button_writes_rigged_glb() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	TestAssert.truthy(lab._skeleton != null, "model rigged before export")

	var out_path := ProjectSettings.globalize_path("user://_ui_export_test.glb")
	lab._on_export_path_selected(out_path)
	TestAssert.truthy(FileAccess.file_exists(out_path), "export button wrote a glb file")

	# Re-import to confirm the exported rig is valid.
	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var report: Dictionary = analyzer.analyze_scene_path(out_path)
	TestAssert.equal(report.get("status", ""), "ok", "exported glb re-imports")
	TestAssert.truthy(report.get("has_skeleton", false), "exported glb has a skeleton")
	lab.free()
	DirAccess.remove_absolute(out_path)

# The bone overlay must switch between Lines and the Blender-style octahedral
# (grey cone) display without error, and actually rebuild the overlay geometry.
func test_bone_style_switch_changes_overlay() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	var overlay: MeshInstance3D = lab._overlay_mesh_instance
	TestAssert.truthy(overlay != null, "overlay mesh instance exists")

	lab._on_bone_style_selected(lab.BoneStyle.LINES)
	TestAssert.truthy(overlay.mesh.get_surface_count() > 0, "lines style produces geometry")
	TestAssert.truthy(overlay.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES, "lines style draws line primitives")

	lab._on_bone_style_selected(lab.BoneStyle.OCTAHEDRAL)
	TestAssert.truthy(overlay.mesh.get_surface_count() > 0, "octahedral style produces geometry")
	TestAssert.equal(overlay.mesh.surface_get_primitive_type(0), Mesh.PRIMITIVE_TRIANGLES, "octahedral style draws triangles")
	TestAssert.truthy(overlay.material_override == lab._octa_material, "octahedral material applied")
	lab.free()
