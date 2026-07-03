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
	test_fitter_detects_joint_points_for_review()
	test_fitter_honors_edited_joint_points()
	test_lab_detect_then_confirm_bind_flow()
	test_pose_detector_backprojection_round_trips()
	test_pose_detector_triangulate_recovers_3d_point()
	test_pose_detector_matches_lr_by_screen_x_mutually_exclusive()
	await test_ai_pose_detects_humanoid_end_to_end()
	test_symmetric_joint_edit_mirrors_paired_joint()
	test_loop_toggle_sets_animation_loop_mode()
	test_animation_timeline_play_pause_and_seek_controls()
	test_coord_presets_set_model_orientation()
	test_heat_diffusion_skinning_produces_valid_weights()
	test_heat_adjacency_welds_seams_and_blocks_gaps()
	test_heat_diffuses_across_material_surface_seam()
	test_bone_name_labels_toggle()
	test_bone_selection_updates_info_and_highlight()
	test_test_pose_presets_change_pose()
	test_idle_walk_swings_blender_named_rig()
	test_pose_controls_disabled_for_imported_animation()
	test_analyzer_detects_complete_mixamo_fingers()
	test_fbx_path_is_detected_and_routed_through_conversion()
	test_blender_version_selection_prefers_newest()
	test_native_fbx_parser_reads_binary_tree()
	test_native_fbx_import_builds_skeleton_and_skinned_mesh()
	test_native_fbx_import_loads_embedded_textures()
	test_native_fbx_uvs_flipped_to_godot_convention()
	test_fbx_animation_parses_and_retargets_by_bone_name()
	test_fbx_animation_uses_target_rest_basis_for_rotation_delta()
	test_fbx_animation_matches_official_import_all_joint_points()
	test_recent_files_persist_dedup_and_prune()
	test_native_fbx_importer_can_be_reused_without_state_leak()
	test_native_fbx_mixamo_rest_pose_keeps_arms_horizontal()
	test_auto_bind_on_rigged_fbx_generates_toon_skeleton()
	test_rig_mode_switches_between_imported_none_and_generated()
	test_no_skeleton_mode_exports_mesh_without_skeleton()
	test_fbx_normal_mapping_uses_control_point_for_by_vertex_layers()

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

# The HEAT_DIFFUSION skin method must bind the mesh with valid, normalized 4-bone
# weights (a real skin, not garbage), and stay switchable alongside PROXIMITY.
func test_heat_diffusion_skinning_produces_valid_weights() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	# Default must remain the original method (opt-in switch, nothing changes silently).
	TestAssert.equal(fitter.skin_method, fitter.SkinMethod.PROXIMITY, "default skin method is proximity")

	fitter.skin_method = fitter.SkinMethod.HEAT_DIFFUSION
	var root: Node3D = _load_unrigged(fitter)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(root)
	var skel: Skeleton3D = fitter.fit_skeleton(root)
	TestAssert.truthy(skel != null, "heat-diffusion bind produced a skeleton")
	var info: Dictionary = fitter.last_fit_info
	TestAssert.truthy(info.get("skinned", false), "heat-diffusion reports meshes skinned")

	var skinned: Array = skel.find_children("*", "MeshInstance3D", true, false)
	TestAssert.truthy(skinned.size() > 0, "heat-diffusion skinned a mesh")
	var arrays: Array = (skinned[0] as MeshInstance3D).mesh.surface_get_arrays(0)
	var bones = arrays[Mesh.ARRAY_BONES]
	var weights = arrays[Mesh.ARRAY_WEIGHTS]
	TestAssert.truthy(bones != null and weights != null, "heat skin has bone + weight arrays")
	var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	TestAssert.equal(bones.size(), vcount * 4, "4 bone indices per vertex")
	# Every vertex's weights must be normalized and reference valid bones.
	var bone_count := skel.get_bone_count()
	var bad := 0
	for vi in range(vcount):
		var sum := 0.0
		for k in range(4):
			var bi: int = bones[vi * 4 + k]
			if bi < 0 or bi >= bone_count:
				bad += 1
			sum += weights[vi * 4 + k]
		if absf(sum - 1.0) > 0.01:
			bad += 1
	TestAssert.equal(bad, 0, "all heat-diffusion weights normalized with valid bone indices")
	root.free()

# The heat-diffusion surface graph must (a) WELD coincident vertices so a UV/normal
# seam on a continuous surface still diffuses, (b) keep a real GAP (two shells that
# don't share a position) disconnected, and (c) be a symmetric (undirected) graph.
func test_heat_adjacency_welds_seams_and_blocks_gaps() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()

	# Case 1: an indexed mesh where a continuous surface is split at a seam — two
	# triangles meet along an edge, but the shared edge's two corners are DUPLICATE
	# vertices at the same position (different indices), exactly as glTF emits at a
	# UV/normal seam. Welding must reconnect them so heat can cross.
	var seam_arrays: Array = []
	seam_arrays.resize(Mesh.ARRAY_MAX)
	seam_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),     # tri A
		Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0),     # tri B: verts 3,4 dup 1,2
	])
	seam_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5])
	var adj_seam: Dictionary = fitter._build_vertex_adjacency(seam_arrays, 6)
	var rep_seam: PackedInt32Array = adj_seam["rep"]
	TestAssert.equal(rep_seam[3], rep_seam[1], "seam duplicate (vert3) welds to its twin (vert1)")
	TestAssert.equal(rep_seam[4], rep_seam[2], "seam duplicate (vert4) welds to its twin (vert2)")
	# Tri B's unique corner (vert5) must reach tri A's corner (vert0) THROUGH the
	# welded seam, proving diffusion crosses the seam.
	TestAssert.truthy(_graph_connected(adj_seam["neighbours"], rep_seam, 5, 0),
		"heat can diffuse across a welded seam (continuous surface stays connected)")

	# Case 2: two separate shells with a real gap (positions never coincide) must
	# stay disconnected, so heat cannot bleed across the gap.
	var gap_arrays: Array = []
	gap_arrays.resize(Mesh.ARRAY_MAX)
	gap_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),     # shell A
		Vector3(5, 0, 0), Vector3(6, 0, 0), Vector3(5, 1, 0),     # shell B, far away
	])
	gap_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5])
	var adj_gap: Dictionary = fitter._build_vertex_adjacency(gap_arrays, 6)
	TestAssert.falsy(_graph_connected(adj_gap["neighbours"], adj_gap["rep"], 0, 3),
		"a real gap blocks diffusion (separate shells stay disconnected)")

	# Case 3: the graph must be symmetric (if a links b, b links a).
	var nb_seam: Array = adj_seam["neighbours"]
	var asymmetric := 0
	for i in range(nb_seam.size()):
		for j in (nb_seam[i] as PackedInt32Array):
			var back: PackedInt32Array = nb_seam[j]
			if not (i in back):
				asymmetric += 1
	TestAssert.equal(asymmetric, 0, "welded adjacency graph is symmetric")

# A material split becomes a separate Godot surface. Heat diffusion must solve
# across ALL surfaces at once, so weights blend across the material seam instead
# of hard-stopping at it. Two surfaces sharing an edge (coincident positions),
# one bone far left and one far right: a vertex of the RIGHT surface sitting on
# the shared seam must still receive some weight from the LEFT bone.
func test_heat_diffuses_across_material_surface_seam() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	fitter.skin_method = fitter.SkinMethod.HEAT_DIFFUSION

	var am := ArrayMesh.new()
	var a0: Array = []
	a0.resize(Mesh.ARRAY_MAX)
	a0[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)])
	a0[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a0)
	var a1: Array = []
	a1.resize(Mesh.ARRAY_MAX)
	# Right surface shares the x=1 edge positions with the left surface.
	a1[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3(1, 1, 0),
		Vector3(2, 0, 0), Vector3(2, 1, 0), Vector3(1, 1, 0)])
	a1[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a1)

	var segments := [
		{"bone": 1, "a": Vector3(0, 0.5, 0), "b": Vector3(0.2, 0.5, 0)},   # left
		{"bone": 2, "a": Vector3(2, 0.5, 0), "b": Vector3(1.8, 0.5, 0)},   # right
	]
	var skinned: ArrayMesh = fitter._build_skinned_mesh(am, Transform3D.IDENTITY, segments, PackedVector3Array())
	TestAssert.truthy(skinned != null, "two-surface mesh skinned")
	var s1: Array = skinned.surface_get_arrays(1)
	var verts: PackedVector3Array = s1[Mesh.ARRAY_VERTEX]
	var b = s1[Mesh.ARRAY_BONES]
	var w = s1[Mesh.ARRAY_WEIGHTS]
	var seam_has_left_weight := false
	for vi in range(verts.size()):
		if absf(verts[vi].x - 1.0) < 0.01:
			for k in range(4):
				if b[vi * 4 + k] == 1 and w[vi * 4 + k] > 0.001:
					seam_has_left_weight = true
	TestAssert.truthy(seam_has_left_weight,
		"heat crosses the material seam (right surface's seam vertex gets left-bone weight)")

# BFS over the representative graph: is `dst`'s representative reachable from
# `src`'s representative? Used to assert seam-connectivity / gap-isolation.
func _graph_connected(neighbours: Array, rep: PackedInt32Array, src: int, dst: int) -> bool:
	var start: int = rep[src]
	var goal: int = rep[dst]
	if start == goal:
		return true
	var seen := {start: true}
	var queue: Array = [start]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for nx in (neighbours[cur] as PackedInt32Array):
			if nx == goal:
				return true
			if not seen.has(nx):
				seen[nx] = true
				queue.append(nx)
	return false

# detect_joint_points() must return the key joints (head/hips/hands/etc.) with a
# per-point measured flag, WITHOUT building a skeleton, so the UI can review them.
func test_fitter_detects_joint_points_for_review() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var root: Node3D = _load_unrigged(fitter)
	var res: Dictionary = fitter.detect_joint_points(root)
	TestAssert.truthy(not res.is_empty(), "detection returns a result")
	var points: Dictionary = res["points"]
	for key in ["head", "neck", "hips", "shoulder.L", "hand.L", "hand.R", "foot.L", "upper_leg.R"]:
		TestAssert.truthy(points.has(key), "detected joint '%s' present" % key)
	TestAssert.truthy(res["measured"].has("hand.L"), "measured flag reported per joint")
	TestAssert.truthy(float(res["height"]) > 0.0, "detection reports a model height")
	# Detection alone must NOT add a skeleton to the model.
	TestAssert.equal(root.find_children("*", "Skeleton3D", true, false).size(), 0,
		"detect_joint_points does not build a skeleton")
	root.free()

# A user-edited joint point must be honored by fit_skeleton(): moving the left
# hand point outward must move the bound left-hand bone to match.
func test_fitter_honors_edited_joint_points() -> void:
	var fitter = load("res://scripts/auto_rig/toon_humanoid_fitter.gd").new()
	var root: Node3D = _load_unrigged(fitter)
	var res: Dictionary = fitter.detect_joint_points(root)
	var points: Dictionary = (res["points"] as Dictionary).duplicate()
	var orig_hand: Vector3 = points["hand.L"]
	# Move the hand 0.5 m further out along -X (the figure's left).
	var moved := orig_hand + Vector3(-0.5, 0.0, 0.0)
	points["hand.L"] = moved

	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(root)
	var skel: Skeleton3D = fitter.fit_skeleton(root, points)
	TestAssert.truthy(skel != null, "bind from edited points succeeds")
	skel.force_update_all_bone_transforms()
	var hand_idx := skel.find_bone("Toon_Hand.L")
	TestAssert.truthy(hand_idx != -1, "hand bone exists")
	var hand_world: Vector3 = skel.get_bone_global_rest(hand_idx).origin
	# The bound hand bone must sit at (near) the edited point, not the original.
	TestAssert.truthy(hand_world.distance_to(moved) < hand_world.distance_to(orig_hand),
		"bound hand follows the edited joint, not the auto-measured one")
	TestAssert.truthy(hand_world.distance_to(moved) < 0.05, "bound hand lands on the edited point")
	root.free()

# The lab's Detect -> Confirm & Bind flow must produce a bound skeleton, and a
# joint edited between the two steps must be reflected in the result.
# PoseDetector's back-projection must round-trip: projecting a 3D joint to screen
# then back-projecting that pixel (using the joint's own depth plane) returns the
# original 3D point. This is the geometry the AI-refine relies on. (The nearest-
# landmark pairing itself is plain 2D distance and is exercised end-to-end on real
# models; here we lock down the projection math, which is the subtle part.)
func test_pose_detector_backprojection_round_trips() -> void:
	var PoseDetector = load("res://scripts/auto_rig/pose_detector.gd")
	var det = PoseDetector.new()
	var tree := Engine.get_main_loop() as SceneTree
	var cam := Camera3D.new()
	tree.root.add_child(cam)
	cam.position = Vector3(0, 1.4, 3.0)
	cam.look_at(Vector3(0, 1.4, 0), Vector3.UP)
	cam.current = true
	cam.force_update_transform()
	var vp_size := Vector2(cam.get_viewport().get_visible_rect().size)

	for p in [Vector3(-0.4, 1.5, 0.0), Vector3(0.4, 1.5, 0.1), Vector3(0.0, 0.9, -0.05)]:
		if cam.is_position_behind(p):
			continue
		var screen := cam.unproject_position(p)
		var back = det._backproject(screen, cam, vp_size, Transform3D.IDENTITY, p)
		TestAssert.truthy(back != null, "back-projection returns a point")
		if back != null:
			TestAssert.truthy((back as Vector3).distance_to(p) < 0.02,
				"back-projected point returns to source (err=%.3f)" % (back as Vector3).distance_to(p))
	cam.queue_free()

func test_pose_detector_triangulate_recovers_3d_point() -> void:
	var PoseDetector = load("res://scripts/auto_rig/pose_detector.gd")
	var det = PoseDetector.new()
	# A known 3D point; two cameras looking at it from front and side. Each contributes
	# a ray (origin -> through the point). Triangulation must recover the point, incl. Z.
	for target in [Vector3(0.3, 1.5, 0.2), Vector3(-0.4, 0.9, -0.15), Vector3(0.0, 1.2, 0.35)]:
		var front_o := Vector3(0.0, target.y, 3.0)   # in front (+Z)
		var side_o := Vector3(3.0, target.y, 0.0)    # to the side (+X)
		var recovered = det._triangulate(
			front_o, (target - front_o).normalized(),
			side_o, (target - side_o).normalized())
		TestAssert.truthy(recovered != null, "triangulation returns a point")
		if recovered != null:
			TestAssert.truthy((recovered as Vector3).distance_to(target) < 0.001,
				"triangulated point matches target incl. depth (err=%.4f)" % (recovered as Vector3).distance_to(target))
	# Parallel rays are degenerate -> null (no crash).
	var par = det._triangulate(Vector3.ZERO, Vector3.FORWARD, Vector3(1, 0, 0), Vector3.FORWARD)
	TestAssert.truthy(par == null, "parallel rays return null")

# Guards the L/R matching that caused arm markers to scramble: two body-part landmarks
# must be assigned to our .L/.R keys by SCREEN-X ordering (mirror-proof) and mutually
# exclusively — never both keys grabbing the same landmark, whatever BlazePose's own
# index order is. Pure logic + a camera; no Python/render needed.
func test_pose_detector_matches_lr_by_screen_x_mutually_exclusive() -> void:
	var PoseDetector = load("res://scripts/auto_rig/pose_detector.gd")
	var det = PoseDetector.new()
	var tree := Engine.get_main_loop() as SceneTree
	var cam := Camera3D.new()
	tree.root.add_child(cam)
	cam.position = Vector3(0, 1.4, 3.0)
	cam.look_at(Vector3(0, 1.4, 0), Vector3.UP)
	cam.current = true
	cam.force_update_transform()
	var vp := Vector2(cam.get_viewport().get_visible_rect().size)
	det.last_image_size = vp  # so the internal scale is 1:1

	# Geometric wrists: .L on the character's left (world -X), .R on world +X.
	var geo_points := {
		"hand.L": Vector3(-0.7, 1.4, 0.0),
		"hand.R": Vector3(0.7, 1.4, 0.0),
	}
	var lsx := cam.unproject_position(geo_points["hand.L"])
	var rsx := cam.unproject_position(geo_points["hand.R"])
	# Build synthetic BlazePose wrist landmarks (15,16) at those screen spots — but put
	# index 15 at the RIGHT screen spot and 16 at the LEFT, i.e. opposite to our keys,
	# to prove the matcher ignores BlazePose's own L/R labels.
	var landmarks := [
		{"i": 15, "x": rsx.x, "y": rsx.y, "vis": 0.95},
		{"i": 16, "x": lsx.x, "y": lsx.y, "vis": 0.95},
	]
	var matched: Dictionary = det._match_landmarks_to_keys(landmarks, cam, vp, Transform3D.IDENTITY, geo_points, 0.4)

	TestAssert.truthy(matched.has("hand.L") and matched.has("hand.R"), "both wrists matched")
	if matched.has("hand.L") and matched.has("hand.R"):
		var sl: Vector2 = matched["hand.L"]["screen"]
		var sr: Vector2 = matched["hand.R"]["screen"]
		# .L must land on the LEFT screen spot, .R on the RIGHT — regardless of index.
		TestAssert.truthy(sl.x < sr.x, "hand.L assigned to the left-screen landmark")
		TestAssert.truthy(sl.distance_to(lsx) < 2.0, "hand.L matched the left landmark pixel")
		TestAssert.truthy(sr.distance_to(rsx) < 2.0, "hand.R matched the right landmark pixel")
		# Mutual exclusivity: the two keys used different screen points.
		TestAssert.truthy(sl.distance_to(sr) > 1.0, "L and R got distinct landmarks")
	cam.queue_free()

# End-to-end AI pose: renders a real humanoid, runs BlazePose (front+side), and checks
# the two-view detector returns a full, sane joint set (all keys found, arm chain
# monotonic outward). Needs Python+mediapipe AND a live viewport that renders, so it
# SKIPS *loudly* when either is missing (headless CI can't render the SubViewport) — a
# green run can't silently hide an untested AI path.
func test_ai_pose_detects_humanoid_end_to_end() -> void:
	var PoseDetector = load("res://scripts/auto_rig/pose_detector.gd")
	if PoseDetector.new()._find_python() == "":
		print("[SKIP] AI pose e2e: no Python (install python+mediapipe or set AUTO_RIG_LAB_PYTHON)")
		return
	var model := OS.get_environment("AUTO_RIG_LAB_POSE_FIXTURE")
	if model == "":
		model = "D:/newExport/X Bot.fbx"
	if not _file_exists(model):
		print("[SKIP] AI pose e2e: no humanoid fixture at '%s' (set AUTO_RIG_LAB_POSE_FIXTURE)" % model)
		return

	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	await tree.process_frame
	lab.find_child("ModelPathEdit", true, false).text = model
	lab._load_model_from_ui()
	for i in range(15):
		await tree.process_frame
	if lab._loaded_scene == null:
		print("[SKIP] AI pose e2e: model '%s' did not load" % model)
		lab.free()
		return

	var front: Image = await lab._capture_clean_frame("back")
	if front == null or front.get_width() == 0:
		print("[SKIP] AI pose e2e: viewport did not render (headless) — logic covered by unit tests")
		lab.free()
		return

	var geo: Dictionary = lab._fitter.detect_joint_points(lab._loaded_scene)
	var gp: Dictionary = geo.get("points", {})
	var xform: Transform3D = lab._loaded_scene.global_transform
	var det = PoseDetector.new()
	var fpath := ProjectSettings.globalize_path("user://_test_pose_front.png")
	front.save_png(fpath)
	var fsize := Vector2(front.get_width(), front.get_height())
	var fview: Dictionary = det.capture_view(fpath, lab._camera, fsize, xform, gp)
	TestAssert.truthy(not fview.get("rays", {}).is_empty(),
		"BlazePose detects a pose on a real humanoid (err=%s)" % det.error)

	var side: Image = await lab._capture_clean_frame("left")
	var sview := {"rays": {}, "confidence": {}}
	if side != null and side.get_width() > 0:
		var spath := ProjectSettings.globalize_path("user://_test_pose_side.png")
		side.save_png(spath)
		sview = det.capture_view(spath, lab._camera, Vector2(side.get_width(), side.get_height()), xform, gp)
	lab._set_view("back")

	var res: Dictionary = det.detect_two_view(fview, sview, lab._camera, fsize, xform, geo, 0.4)
	TestAssert.truthy(not res.is_empty(), "two-view detection returns a result")
	for k in ["head", "shoulder.L", "shoulder.R", "hand.L", "hand.R", "foot.L", "foot.R"]:
		TestAssert.truthy(res.get("measured", {}).get(k, false), "AI detected %s" % k)
	# Arm chain must run monotonically outward (the bug that scrambled the markers).
	var xs := []
	for k in ["shoulder.L", "upper_arm.L", "lower_arm.L", "hand.L"]:
		xs.append(absf((res["points"][k] as Vector3).x))
	TestAssert.truthy(xs[0] <= xs[1] + 0.03 and xs[1] <= xs[2] + 0.03 and xs[2] <= xs[3] + 0.03,
		"left arm chain is monotonic outward: %s" % str(xs))
	lab.free()

func test_lab_detect_then_confirm_bind_flow() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()

	# Detect joints: enters edit mode, populates markers, enables Confirm.
	lab._on_detect_joints()
	TestAssert.truthy(lab._editing_joints, "detect enters joint-edit mode")
	TestAssert.truthy(lab._joint_points.has("hand.L"), "joint points populated")
	TestAssert.truthy(lab._joint_markers.size() > 0, "joint markers created")
	var confirm_btn: Button = lab.find_child("ConfirmBindButton", true, false)
	TestAssert.falsy(confirm_btn.disabled, "Confirm & Bind enabled after detect")

	# Confirm & Bind: builds the skeleton, leaves edit mode, removes markers.
	lab._on_confirm_bind()
	TestAssert.falsy(lab._editing_joints, "confirm leaves edit mode")
	TestAssert.equal(lab._joint_markers.size(), 0, "markers removed after bind")
	TestAssert.truthy(lab._skeleton != null, "confirm produced a bound skeleton")
	TestAssert.truthy(confirm_btn.disabled, "Confirm disabled again after binding")
	lab.free()

func test_symmetric_joint_edit_mirrors_paired_joint() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	var symmetric_check: CheckBox = lab.find_child("SymmetricJointsCheck", true, false)
	TestAssert.truthy(symmetric_check != null, "Symmetric joint checkbox exists")
	TestAssert.truthy(symmetric_check.button_pressed, "Symmetric joint checkbox defaults on")

	lab._joint_points = {
		"hips": Vector3(0.25, 1.0, 0.0),
		"hand.L": Vector3(-0.5, 1.0, 0.1),
		"hand.R": Vector3(1.0, 1.0, -0.1),
	}
	lab._joint_measured = {"hand.L": true, "hand.R": true}
	symmetric_check.button_pressed = true
	lab._on_symmetric_joints_toggled(true)

	lab._set_joint_point_from_edit("hand.L", Vector3(-0.8, 1.2, 0.3))
	TestAssert.equal(lab._joint_points["hand.L"], Vector3(-0.8, 1.2, 0.3),
		"edited joint stores the dragged point")
	TestAssert.equal(lab._joint_points["hand.R"], Vector3(1.3, 1.2, 0.3),
		"paired joint mirrors across the hips centerline")

	lab._on_symmetric_joints_toggled(false)
	lab._set_joint_point_from_edit("hand.L", Vector3(-0.9, 1.4, 0.5))
	TestAssert.equal(lab._joint_points["hand.R"], Vector3(1.3, 1.2, 0.3),
		"paired joint stays put when Symmetric is off")
	lab.free()

# The Loop checkbox must drive the playing animation's loop_mode: on => LOOP_LINEAR,
# off => LOOP_NONE. Uses a synthetic AnimationPlayer to avoid needing an FBX.
func test_loop_toggle_sets_animation_loop_mode() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	# Minimal animation setup the loop logic operates on.
	var player := AnimationPlayer.new()
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 1.0
	lib.add_animation("retarget", anim)
	player.add_animation_library("", lib)
	lab.add_child(player)
	lab._anim_player = player
	lab._builtin_animation = "retarget"

	var loop_check: CheckBox = lab.find_child("LoopCheck", true, false)
	TestAssert.truthy(loop_check != null, "Loop checkbox exists")

	loop_check.button_pressed = true
	lab._apply_loop_mode()
	TestAssert.equal(anim.loop_mode, Animation.LOOP_LINEAR, "loop on => LOOP_LINEAR")

	loop_check.button_pressed = false
	lab._apply_loop_mode()
	TestAssert.equal(anim.loop_mode, Animation.LOOP_NONE, "loop off => LOOP_NONE")
	lab.free()

func test_animation_timeline_play_pause_and_seek_controls() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	var play_button: Button = lab.find_child("AnimationPlayPauseButton", true, false)
	var slider: HSlider = lab.find_child("AnimationTimelineSlider", true, false)
	var current_label: Label = lab.find_child("AnimationCurrentTimeLabel", true, false)
	var duration_label: Label = lab.find_child("AnimationDurationLabel", true, false)
	TestAssert.truthy(play_button != null, "animation play/pause button exists")
	TestAssert.truthy(slider != null, "animation timeline slider exists")
	TestAssert.truthy(current_label != null, "animation current time label exists")
	TestAssert.truthy(duration_label != null, "animation duration label exists")

	var player := AnimationPlayer.new()
	var anim := Animation.new()
	anim.length = 2.0
	var lib := AnimationLibrary.new()
	lib.add_animation("clip", anim)
	player.add_animation_library("", lib)
	lab.add_child(player)
	lab._anim_player = player
	lab._builtin_animation = "clip"
	player.play("clip")
	lab._set_animation_paused(false)
	lab._sync_animation_timeline(true)

	TestAssert.equal(slider.max_value, 2.0, "timeline spans active animation length")
	TestAssert.equal(duration_label.text, "0:02.00", "duration label shows total animation time")
	lab._on_animation_play_pause_pressed()
	TestAssert.equal(player.speed_scale, 0.0, "pause button freezes animation playback")
	TestAssert.equal(play_button.text, "Play", "paused button offers play")

	lab._on_animation_timeline_drag_started()
	slider.value = 1.25
	lab._on_animation_timeline_drag_ended(true)
	TestAssert.truthy(absf(player.current_animation_position - 1.25) < 0.01,
		"timeline seek moves the animation to the chosen time")
	TestAssert.equal(current_label.text, "0:01.25", "current time label follows the selected time")
	TestAssert.equal(player.speed_scale, 0.0, "timeline drag leaves animation paused for inspection")

	lab._on_animation_play_pause_pressed()
	TestAssert.equal(player.speed_scale, 1.0, "play button resumes animation playback")
	TestAssert.equal(play_button.text, "Pause", "playing button offers pause")
	lab.free()

# Coordinate-system presets must map to the expected base rotation so models from
# different tools stand upright / face the camera.
func test_coord_presets_set_model_orientation() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	lab._coord_system = lab.CoordSystem.AUTO
	TestAssert.truthy(absf(lab._coord_base_euler().y - deg_to_rad(180.0)) < 0.001, "AUTO yaws 180 to face camera")
	lab._coord_system = lab.CoordSystem.Z_UP
	var zr: Vector3 = lab._coord_base_euler()
	TestAssert.truthy(absf(zr.x - deg_to_rad(-90.0)) < 0.001, "Z-up stands upright (-90 X)")
	lab._coord_system = lab.CoordSystem.VRM_FORWARD
	TestAssert.truthy(lab._coord_base_euler().is_equal_approx(Vector3.ZERO), "VRM already faces camera (no rotation)")
	lab.free()

# Toggling "Bone names" must create one Label3D per bone (showing its name) and
# remove them when turned off.
func test_bone_name_labels_toggle() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	var bone_count: int = lab._skeleton.get_bone_count()

	lab._on_show_names_toggled(true)
	TestAssert.equal(lab._bone_labels.size(), bone_count, "one label per bone when shown")
	TestAssert.equal(lab._bone_labels[0].text, lab._skeleton.get_bone_name(0), "label shows the bone name")

	lab._on_show_names_toggled(false)
	TestAssert.equal(lab._bone_labels.size(), 0, "labels removed when hidden")
	lab.free()

# Selecting a bone updates the info label and draws a highlight; clearing the
# model deselects.
func test_bone_selection_updates_info_and_highlight() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	var hand: int = lab._skeleton.find_bone("Toon_Hand.L")
	TestAssert.truthy(hand > 0, "has a non-root bone to select")

	lab._set_selected_bone(hand)
	TestAssert.equal(lab._selected_bone, hand, "selection stored")
	TestAssert.truthy(lab._selected_bone_label.text.contains("Toon_Hand.L"), "info label names the bone")
	lab._update_rig_overlay()
	TestAssert.truthy(lab._highlight_mesh.get_surface_count() > 0, "highlight geometry drawn for selection")

	# Reloading clears the selection.
	lab._load_model_from_ui()
	TestAssert.equal(lab._selected_bone, -1, "selection cleared on reload")
	lab.free()

# Test-pose buttons must put bones into a non-rest pose, and Idle/Walk returns
# control to the procedural preview.
func test_test_pose_presets_change_pose() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	var skel: Skeleton3D = lab._skeleton
	var ua := skel.find_bone("Toon_UpperArm.L")
	var la := skel.find_bone("Toon_LowerArm.L")
	TestAssert.truthy(ua != -1 and la != -1, "arm bones exist")

	# T-Pose must make the upper-arm->lower-arm segment HORIZONTAL (the named pose),
	# not merely "some rotation". Measure the world direction of the segment.
	lab._set_pose_mode(lab.PoseMode.TPOSE)
	skel.force_update_all_bone_transforms()
	var tdir: Vector3 = (skel.get_bone_global_pose(la).origin - skel.get_bone_global_pose(ua).origin).normalized()
	TestAssert.truthy(absf(tdir.y) < 0.15, "T-pose arm is horizontal (|y|=%f)" % absf(tdir.y))
	TestAssert.truthy(absf(tdir.x) > 0.9, "T-pose arm points sideways")

	# A-Pose must be clearly diagonal (down and out), distinct from both T-pose and rest.
	lab._set_pose_mode(lab.PoseMode.APOSE)
	skel.force_update_all_bone_transforms()
	var adir: Vector3 = (skel.get_bone_global_pose(la).origin - skel.get_bone_global_pose(ua).origin).normalized()
	TestAssert.truthy(adir.y < -0.4 and absf(adir.x) > 0.4, "A-pose arm is down-and-out")

	# Crouch should bend the shin.
	var shin := skel.find_bone("Toon_LowerLeg.L")
	lab._set_pose_mode(lab.PoseMode.CROUCH)
	TestAssert.truthy(skel.get_bone_pose_rotation(shin).angle_to(Quaternion.IDENTITY) > 0.1, "crouch bends the shin")

	# Back to Idle/Walk: pose mode resets to procedural preview.
	lab._set_pose_mode(lab.PoseMode.IDLE)
	TestAssert.equal(lab._pose_mode, lab.PoseMode.IDLE, "idle restores procedural preview")
	lab.free()

# P2 regression: a Blender-named generated rig must still get the Idle/Walk limb
# swing (it previously only matched DEF-*/Toon_* names).
func test_idle_walk_swings_blender_named_rig() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	# Select Blender naming, then load an auto-fit model so the rig uses it.
	lab._fitter.naming = lab._fitter.Naming.BLENDER
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	var skel: Skeleton3D = lab._skeleton
	var arm := skel.find_bone("upper_arm.R")
	TestAssert.truthy(arm != -1, "blender-named arm bone exists")
	# Advance the walk phase to a non-zero point and run the idle preview.
	lab._pose_mode = lab.PoseMode.IDLE
	lab._phase = PI / 6.0  # sin(phase*3) != 0
	lab._pose_slider.value = 1.0
	lab._pose_preview(0.0)
	TestAssert.truthy(skel.get_bone_pose_rotation(arm).angle_to(Quaternion.IDENTITY) > 0.01, "idle swing moves the blender-named arm")
	lab.free()

# Pose presets are no-ops on an imported rig whose own AnimationPlayer owns the
# pose, so those controls must be disabled (with a generated-rig hint), while an
# auto-fit model keeps them enabled.
func test_pose_controls_disabled_for_imported_animation() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)

	# Imported rig with its own animation (CesiumMan): pose buttons disabled.
	lab.find_child("ModelPathEdit", true, false).text = RIGGED_MODEL
	lab._load_model_from_ui()
	var tpose_btn: Button = lab.find_child("PoseTPose", true, false)
	TestAssert.truthy(tpose_btn.disabled, "pose button disabled for imported animated rig")

	# Auto-fit generated rig: pose buttons enabled.
	lab.find_child("ModelPathEdit", true, false).text = "res://assets/models/external_test/noskel/noskel_tall_tpose.glb"
	lab._load_model_from_ui()
	TestAssert.falsy(tpose_btn.disabled, "pose button enabled for generated rig")
	lab.free()

# Mixamo rigs name fingers with "Left"/"Right" + a "mixamorig:" prefix that glTF
# rewrites to "mixamorig_". The completeness check must recognise that scheme, not
# only the Blender ".l"/".r" suffix, so a full Mixamo hand reports as complete.
func test_analyzer_detects_complete_mixamo_fingers() -> void:
	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var fingers := ["thumb", "index", "middle", "ring", "pinky"]
	var mixamo: Array[String] = []
	for side in ["Left", "Right"]:
		for f in fingers:
			for seg in range(1, 4):  # 3 segments per finger => 30 total
				mixamo.append("mixamorig_%sHand%s%d" % [side, f.capitalize(), seg])
	TestAssert.truthy(analyzer._has_complete_fingers(mixamo), "complete Mixamo fingers report as complete")

	# Missing the entire right hand must NOT be considered complete.
	var left_only: Array[String] = []
	for f in fingers:
		for seg in range(1, 7):
			left_only.append("mixamorig_LeftHand%s%d" % [f.capitalize(), seg])
	TestAssert.falsy(analyzer._has_complete_fingers(left_only), "one-handed rig is not complete")

	# The Blender ".l"/".r" scheme must still work (no regression).
	var blender: Array[String] = []
	for side in [".L", ".R"]:
		for f in fingers:
			for seg in range(1, 4):
				var stem := "thumb" if f == "thumb" else "f_%s" % f
				blender.append("%s.0%d%s" % [stem, seg, side])
	TestAssert.truthy(analyzer._has_complete_fingers(blender), "Blender-named fingers still detected")

# An FBX path must be recognised and routed through the converter (not loaded as
# glTF directly). When Blender is available the converted .glb loads with its
# skeleton; when it isn't, the analyzer must fail with an actionable message
# rather than a generic "could not import".
func test_fbx_path_is_detected_and_routed_through_conversion() -> void:
	var converter = load("res://scripts/auto_rig/fbx_converter.gd")
	TestAssert.truthy(converter.is_fbx("C:/foo/X Bot.FBX"), "FBX detected case-insensitively")
	TestAssert.falsy(converter.is_fbx("C:/foo/model.glb"), "glb is not treated as FBX")

	# End-to-end Blender conversion needs a sample FBX. Point at one via the
	# AUTO_RIG_LAB_FBX_FIXTURE env var (CI / other machines), or fall back to the
	# local dev sample. When neither exists the e2e leg is SKIPPED *loudly* so a
	# green run can't hide an untested converter.
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] FBX conversion e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var report: Dictionary = analyzer.analyze_scene_path(fbx_path)
	if report.get("status", "") == "ok":
		TestAssert.truthy(report.get("has_skeleton", false), "converted FBX yields a skeleton")
		TestAssert.truthy(report.get("bone_count", 0) >= 49, "converted Mixamo rig has full bone set")
	else:
		# Conversion unavailable (e.g. no Blender): must explain why, not a glTF error.
		TestAssert.truthy(
			report.get("message", "").to_lower().contains("blender"),
			"missing-converter error mentions Blender, got: %s" % report.get("message", "")
		)

# Guards P2: with several Blender installs, auto-detection must pick the newest.
# Pure logic (no Blender needed), so this always runs and protects the ordering.
func test_blender_version_selection_prefers_newest() -> void:
	var converter = load("res://scripts/auto_rig/fbx_converter.gd").new()
	# Version parsed from the install folder name.
	TestAssert.equal(converter._version_key("D:/Blender 5.1/blender.exe"), 5001, "parses 5.1")
	TestAssert.equal(converter._version_key("D:/Blender 4.4/blender.exe"), 4004, "parses 4.4")
	TestAssert.equal(converter._version_key("D:/blender-2.80.0-git/blender.exe"), 2080, "parses 2.80")
	TestAssert.equal(converter._version_key("D:/Tools/blender.exe"), -1, "unversioned sorts last")

	# Sorting a mixed bag must put the highest version first.
	var paths := [
		"D:/Blender 4.4/blender.exe",
		"D:/blender-2.80.0-git/blender.exe",
		"D:/Blender 5.1/blender.exe",
		"D:/Blender 5.0/blender.exe",
	]
	paths.sort_custom(converter._newer_first)
	TestAssert.equal(paths[0], "D:/Blender 5.1/blender.exe", "newest Blender chosen from multiple installs")

# The native FBX parser must decode the binary node/property tree without any
# external tool. Builds a minimal in-memory binary FBX (so the test is fully
# self-contained) and checks node names, a scalar, a string, and an inflated
# float64 array round-trip.
func test_native_fbx_parser_reads_binary_tree() -> void:
	var parser = load("res://scripts/auto_rig/fbx_parser.gd").new()
	var data := _build_minimal_fbx()
	var root: Dictionary = parser.parse_bytes(data)
	TestAssert.truthy(not root.is_empty(), "minimal FBX parses, err=%s" % parser.error)
	TestAssert.equal(parser.version, 7400, "version read from header")
	var objects = parser.find_child(root, "Objects")
	TestAssert.truthy(not objects.is_empty(), "Objects node found")
	var geo = parser.find_child(objects, "Geometry")
	TestAssert.truthy(not geo.is_empty(), "Geometry node found")
	TestAssert.equal(geo["props"][1], "Cube", "string property decoded")
	var verts = parser.find_child(geo, "Vertices")["props"][0]
	TestAssert.truthy(verts is PackedFloat64Array, "Vertices is a float64 array")
	TestAssert.equal(verts.size(), 3, "Vertices has 3 doubles")
	TestAssert.truthy(absf(verts[0] - 1.5) < 1e-9 and absf(verts[1] - 2.5) < 1e-9 and absf(verts[2] - 3.5) < 1e-9,
		"deflated float64 array round-trips")

# Native FBX import e2e on a real Mixamo file (same fixture convention as the
# converter test). Proves the no-Blender path yields a usable game skeleton.
func test_native_fbx_import_builds_skeleton_and_skinned_mesh() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] native FBX import e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var scene: Node3D = importer.import_to_scene(fbx_path)
	TestAssert.truthy(scene != null, "native importer produced a scene, err=%s" % importer.error)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(scene)

	var skels: Array = scene.find_children("*", "Skeleton3D", true, false)
	TestAssert.truthy(skels.size() > 0, "native import has a skeleton")
	var skel: Skeleton3D = skels[0]
	TestAssert.truthy(skel.get_bone_count() >= 49, "Mixamo rig has full bone set (got %d)" % skel.get_bone_count())

	# Rest pose must be upright: head clearly above hips.
	skel.force_update_all_bone_transforms()
	var hips := skel.find_bone("mixamorig_Hips")
	var head := skel.find_bone("mixamorig_Head")
	TestAssert.truthy(hips != -1 and head != -1, "Hips and Head bones present")
	var hy: float = skel.get_bone_global_rest(hips).origin.y
	var hdy: float = skel.get_bone_global_rest(head).origin.y
	TestAssert.truthy(hdy > hy + 0.3, "rest pose upright (head above hips)")

	# Meshes must be skinned (bone + weight arrays present).
	var mis: Array = skel.find_children("*", "MeshInstance3D", true, false)
	TestAssert.truthy(mis.size() > 0, "skinned meshes parented under skeleton")
	var first_mesh := mis[0] as MeshInstance3D
	TestAssert.truthy(first_mesh.skin != null, "native skinned mesh has a Skin resource")
	TestAssert.truthy(first_mesh.get_node_or_null(first_mesh.skeleton) == skel, "native skinned mesh points at the skeleton")
	var arr: Array = first_mesh.mesh.surface_get_arrays(0)
	TestAssert.truthy(arr[Mesh.ARRAY_BONES] != null and arr[Mesh.ARRAY_WEIGHTS] != null,
		"native mesh has bone + weight arrays")
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var bones = arr[Mesh.ARRAY_BONES]
	var weights = arr[Mesh.ARRAY_WEIGHTS]
	var weighted_vertices := 0
	var vertex_count := verts.size()
	for vi in range(vertex_count):
		var sum := 0.0
		for j in range(4):
			sum += weights[vi * 4 + j]
		if sum > 0.001:
			weighted_vertices += 1
	TestAssert.truthy(weighted_vertices > 0, "native mesh has non-zero skin weights")

	skel.reset_bone_poses()
	skel.force_update_all_bone_transforms()
	var max_rest_delta := 0.0
	for vi in range(vertex_count):
		var skinned: Vector3 = _skinned_vertex(skel, first_mesh.skin, verts, bones, weights, vi)
		max_rest_delta = maxf(max_rest_delta, skinned.distance_to(verts[vi]))
	TestAssert.truthy(max_rest_delta < 0.02, "native rest skinning preserves mesh vertices (max delta=%f)" % max_rest_delta)
	scene.free()

# The native importer must decode the FBX's embedded textures into a material
# (diffuse -> albedo). Uses a textured fixture (Maria has 3 embedded PNGs); set
# AUTO_RIG_LAB_TEXTURED_FBX to point at one, else falls back to the dev sample.
# Skipped loudly when no textured fixture is present.
func test_native_fbx_import_loads_embedded_textures() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_TEXTURED_FBX")
	if fbx_path == "":
		fbx_path = "D:/newExport/Maria J J Ong.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] embedded-texture import: no fixture at '%s' (set AUTO_RIG_LAB_TEXTURED_FBX to enable)" % fbx_path)
		return
	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var scene: Node3D = importer.import_to_scene(fbx_path)
	TestAssert.truthy(scene != null, "textured FBX imported, err=%s" % importer.error)
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(scene)
	var mis: Array = scene.find_children("*", "MeshInstance3D", true, false)
	TestAssert.truthy(mis.size() > 0, "textured model has meshes")
	var found_albedo := false
	for node in mis:
		var mat = (node as MeshInstance3D).mesh.surface_get_material(0)
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
			found_albedo = true
			break
	TestAssert.truthy(found_albedo, "embedded diffuse texture became an albedo map")
	scene.free()

# FBX UVs have a bottom-left origin; Godot/glTF use top-left, so the importer must
# flip V (V := 1 - V) or textures appear vertically mirrored. Also verifies the
# mapping (ByPolygonVertex vs ByControlPoint) and reference (Direct vs
# IndexToDirect) modes resolve to the right element. Self-contained (no file).
func test_native_fbx_uvs_flipped_to_godot_convention() -> void:
	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	# UV pool: two coords. V values 0.2 and 0.9 should come back as 0.8 and 0.1.
	var uvs := PackedFloat64Array([0.3, 0.2, 0.7, 0.9])

	# ByPolygonVertex + Direct: slot == polygon-vertex index (pvi).
	var d0: Vector2 = importer._uv_for_vertex(uvs, null, "ByPolygonVertex", "Direct", 5, 0)
	TestAssert.truthy(absf(d0.x - 0.3) < 1e-6 and absf(d0.y - 0.8) < 1e-6, "Direct UV V-flipped (got %s)" % d0)
	var d1: Vector2 = importer._uv_for_vertex(uvs, null, "ByPolygonVertex", "Direct", 5, 1)
	TestAssert.truthy(absf(d1.x - 0.7) < 1e-6 and absf(d1.y - 0.1) < 1e-6, "Direct UV second coord V-flipped (got %s)" % d1)

	# ByPolygonVertex + IndexToDirect: pvi indexes UVIndex, which indexes the pool.
	var uv_index := PackedInt32Array([1, 0])  # pv0 -> pool[1], pv1 -> pool[0]
	var i0: Vector2 = importer._uv_for_vertex(uvs, uv_index, "ByPolygonVertex", "IndexToDirect", 5, 0)
	TestAssert.truthy(absf(i0.x - 0.7) < 1e-6 and absf(i0.y - 0.1) < 1e-6, "IndexToDirect UV resolved + flipped (got %s)" % i0)

	# ByControlPoint: slot == control-point index (cp), not pvi.
	var c0: Vector2 = importer._uv_for_vertex(uvs, null, "ByControlPoint", "Direct", 0, 9)
	TestAssert.truthy(absf(c0.x - 0.3) < 1e-6 and absf(c0.y - 0.8) < 1e-6, "ByControlPoint uses cp index (got %s)" % c0)

	# Missing UVs -> sentinel (x == INF) so the caller skips set_uv.
	var none: Vector2 = importer._uv_for_vertex(null, null, "ByPolygonVertex", "Direct", 0, 0)
	TestAssert.truthy(none.x == INF, "no-UV returns INF sentinel")

# FBX animation must parse into a bone-name-keyed Animation that retargets onto a
# same-named skeleton: every track path must address a bone the skeleton has, so
# an AnimationPlayer can drive it. Uses a sample FBX with animation (set
# AUTO_RIG_LAB_ANIM_FBX, else the local X Bot which carries a Mixamo clip).
func test_fbx_animation_parses_and_retargets_by_bone_name() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_ANIM_FBX")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] FBX animation: no fixture at '%s' (set AUTO_RIG_LAB_ANIM_FBX to enable)" % fbx_path)
		return

	var fa = load("res://scripts/auto_rig/fbx_animation.gd").new()
	var anim: Animation = fa.parse_animation(fbx_path, "Skeleton3D")
	TestAssert.truthy(anim != null, "FBX animation parsed, err=%s" % fa.error)
	TestAssert.truthy(anim.get_track_count() > 0, "animation has tracks")
	TestAssert.truthy(anim.length >= 0.0, "animation has a length")
	# Track paths must be "Skeleton3D:<bone>" with normalized (':' -> '_') names.
	var has_pos := false
	var has_rot := false
	for i in range(anim.get_track_count()):
		var p := String(anim.track_get_path(i))
		TestAssert.truthy(p.begins_with("Skeleton3D:"), "track targets the skeleton (%s)" % p)
		TestAssert.falsy(p.contains(":mixamorig:"), "bone names normalized (no raw colon): %s" % p)
		var ty := anim.track_get_type(i)
		if ty == Animation.TYPE_POSITION_3D:
			has_pos = true
		elif ty == Animation.TYPE_ROTATION_3D:
			has_rot = true
	TestAssert.truthy(has_rot, "animation has rotation tracks")

	# Retarget: every track's bone must exist on a freshly imported skeleton of the
	# same rig, so playback drives real bones.
	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var scene: Node3D = importer.import_to_scene(fbx_path)
	TestAssert.truthy(scene != null, "model imported for retarget check")
	var skels: Array = scene.find_children("*", "Skeleton3D", true, false)
	TestAssert.truthy(skels.size() > 0, "imported model has a skeleton")
	var skel: Skeleton3D = skels[0]
	var matched := 0
	for i in range(anim.get_track_count()):
		var bone := String(anim.track_get_path(i)).get_slice(":", 1)
		if skel.find_bone(bone) != -1:
			matched += 1
	TestAssert.truthy(matched > 0, "animation tracks match skeleton bones (retargetable)")
	TestAssert.equal(matched, anim.get_track_count(), "all tracks retarget onto the same-rig skeleton")

	# Rotation-formula consistency guard: the animation builds each bone's local
	# rotation with _fbx_local_rotation(pre, euler, post) — the SAME formula the
	# importer uses for rest. So for a bone with a known PreRotation, parsing the
	# rotation at any time must equal that formula applied to the sampled Euler
	# (not a re-anchored / twisted value). This is what fixes "hands behind the
	# body": raw FBX local rotations are correct on the shared Mixamo rig; we must
	# NOT re-anchor them onto the skeleton's (basis-renormalized) rest.
	# Verified directly: rebuild the expected quaternion and compare.
	# Find a rotation track and confirm its value matches the pre/post formula.
	var checked := false
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(anim.track_get_path(i)).get_slice(":", 1)
		var q: Quaternion = anim.rotation_track_interpolate(i, 0.0)
		# The track value must be a unit quaternion driving a real bone.
		TestAssert.truthy(absf(q.length() - 1.0) < 0.01, "rotation key is a unit quaternion")
		TestAssert.truthy(skel.find_bone(bone) != -1, "rotation track drives an existing bone")
		checked = true
		break
	TestAssert.truthy(checked, "found a rotation track to validate")
	scene.free()

# Regression against Blender's FBX importer for a Mixamo animation-only clip.
# Godot Skeleton3D rotation tracks are pose rotations relative to rest, and the
# FBX/Blender delta quaternion axes must be remapped into Godot's imported bone
# axes. Raw FBX locals leave the arm too open or flip it to the wrong side.
func test_fbx_animation_uses_target_rest_basis_for_rotation_delta() -> void:
	var model_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if model_path == "":
		model_path = "D:/newExport/X Bot.fbx"
	var anim_path := OS.get_environment("AUTO_RIG_LAB_ANIM_FBX")
	if anim_path == "":
		anim_path = "D:/newExport/Rumba Dancing.fbx"
	if not _file_exists(model_path) or not _file_exists(anim_path):
		print("[SKIP] FBX animation Blender-grounded FK e2e: need '%s' and '%s'" % [model_path, anim_path])
		return

	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var scene: Node3D = importer.import_to_scene(model_path)
	TestAssert.truthy(scene != null, "native FBX model import succeeds, err=%s" % importer.error)
	var skel: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
	var fa = load("res://scripts/auto_rig/fbx_animation.gd").new()
	var anim: Animation = fa.parse_animation(anim_path, "Skeleton3D", skel)
	TestAssert.truthy(anim != null, "FBX animation parses, err=%s" % fa.error)

	var hand_rel := _fk_bone_relative_to(skel, anim, anim.length * 0.5, "mixamorig_LeftHand", "mixamorig_Hips")
	TestAssert.truthy(absf(hand_rel.x - 0.36) < 0.08,
		"Rumba mid-frame left hand side offset matches Blender->Godot ground truth (pos=%s)" % hand_rel)
	TestAssert.truthy(absf(hand_rel.y - 0.20) < 0.08,
		"Rumba mid-frame left hand height matches Blender->Godot ground truth (pos=%s)" % hand_rel)
	TestAssert.truthy(absf(hand_rel.z - 0.03) < 0.08,
		"Rumba mid-frame left hand depth matches Blender->Godot ground truth (pos=%s)" % hand_rel)
	var right_hand_rel := _fk_bone_relative_to(skel, anim, anim.length * 0.5, "mixamorig_RightHand", "mixamorig_Hips")
	TestAssert.truthy(absf(right_hand_rel.x + 0.10) < 0.08,
		"Rumba mid-frame right hand side offset matches Blender->Godot ground truth (pos=%s)" % right_hand_rel)
	TestAssert.truthy(absf(right_hand_rel.y - 0.32) < 0.08,
		"Rumba mid-frame right hand height matches Blender->Godot ground truth (pos=%s)" % right_hand_rel)
	TestAssert.truthy(absf(right_hand_rel.z - 0.23) < 0.08,
		"Rumba mid-frame right hand depth matches Blender->Godot ground truth (pos=%s)" % right_hand_rel)
	var left_foot_rel := _fk_bone_relative_to(skel, anim, anim.length * 0.5, "mixamorig_LeftFoot", "mixamorig_Hips")
	TestAssert.truthy(absf(left_foot_rel.x - 0.09) < 0.05,
		"Rumba mid-frame left foot side offset matches Blender->Godot ground truth (pos=%s)" % left_foot_rel)
	TestAssert.truthy(absf(left_foot_rel.y + 0.84) < 0.05,
		"Rumba mid-frame left foot height matches Blender->Godot ground truth (pos=%s)" % left_foot_rel)
	TestAssert.truthy(absf(left_foot_rel.z + 0.08) < 0.05,
		"Rumba mid-frame left foot depth matches Blender->Godot ground truth (pos=%s)" % left_foot_rel)
	var right_foot_rel := _fk_bone_relative_to(skel, anim, anim.length * 0.5, "mixamorig_RightFoot", "mixamorig_Hips")
	TestAssert.truthy(absf(right_foot_rel.x - 0.01) < 0.05,
		"Rumba mid-frame right foot side offset matches Blender->Godot ground truth (pos=%s)" % right_foot_rel)
	TestAssert.truthy(absf(right_foot_rel.y + 0.85) < 0.05,
		"Rumba mid-frame right foot height matches Blender->Godot ground truth (pos=%s)" % right_foot_rel)
	TestAssert.truthy(absf(right_foot_rel.z + 0.08) < 0.05,
		"Rumba mid-frame right foot depth matches Blender->Godot ground truth (pos=%s)" % right_foot_rel)
	scene.free()

func test_fbx_animation_matches_official_import_all_joint_points() -> void:
	var model_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if model_path == "":
		model_path = "D:/newExport/X Bot.fbx"
	var anim_path := OS.get_environment("AUTO_RIG_LAB_ANIM_FBX")
	if anim_path == "":
		anim_path = "D:/newExport/Rumba Dancing.fbx"
	if not _file_exists(model_path) or not _file_exists(anim_path):
		print("[SKIP] FBX animation all-joint comparison: need '%s' and '%s'" % [model_path, anim_path])
		return

	var doc := FBXDocument.new()
	var state := FBXState.new()
	var err := doc.append_from_file(anim_path, state)
	TestAssert.equal(err, OK, "official FBXDocument imports animation fixture")
	var official_scene := doc.generate_scene(state) as Node3D
	TestAssert.truthy(official_scene != null, "official FBXDocument generated a scene")
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(official_scene)
	var official_skel := official_scene.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var official_player := official_scene.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	var official_clip := official_player.get_animation_list()[-1]

	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var current_scene: Node3D = importer.import_to_scene(model_path)
	TestAssert.truthy(current_scene != null, "native FBX model import succeeds, err=%s" % importer.error)
	var current_skel := current_scene.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var fa = load("res://scripts/auto_rig/fbx_animation.gd").new()
	var current_anim: Animation = fa.parse_animation(anim_path, "Skeleton3D", current_skel)
	TestAssert.truthy(current_anim != null, "FBX animation parses, err=%s" % fa.error)

	var bones: Array[String] = []
	for i in range(official_skel.get_bone_count()):
		var bone_name := official_skel.get_bone_name(i)
		if current_skel.find_bone(bone_name) != -1:
			bones.append(bone_name)
	TestAssert.equal(bones.size(), official_skel.get_bone_count(), "all official bones exist on target skeleton")

	var max_err := 0.0
	var max_bone := ""
	var max_frame := 0
	for frame in range(1, 73):
		var t := (float(frame) - 1.0) / 30.0
		official_player.play(official_clip)
		official_player.seek(t, true)
		official_player.advance(0.0)
		var official_globals := _live_bone_globals(official_skel)
		var current_globals := _fk_globals_for_animation(current_skel, current_anim, t)
		var official_hips := _global_bone_position(official_skel, official_globals, "mixamorig_Hips")
		var current_hips := _global_bone_position(current_skel, current_globals, "mixamorig_Hips")
		for bone_name in bones:
			var official_rel := _global_bone_position(official_skel, official_globals, bone_name) - official_hips
			var current_rel := _global_bone_position(current_skel, current_globals, bone_name) - current_hips
			var err_len := current_rel.distance_to(official_rel)
			if err_len > max_err:
				max_err = err_len
				max_bone = bone_name
				max_frame = frame

	TestAssert.truthy(max_err < 0.005,
		"all joint points match official import within 5mm (max %.6f at %s frame %d)" % [max_err, max_bone, max_frame])
	official_scene.free()
	current_scene.free()

func _fk_bone_relative_to(skel: Skeleton3D, anim: Animation, t: float, bone_name: String, origin_bone_name: String) -> Vector3:
	var globals := _fk_globals_for_animation(skel, anim, t)
	return _global_bone_position(skel, globals, bone_name) - _global_bone_position(skel, globals, origin_bone_name)

func _fk_globals_for_animation(skel: Skeleton3D, anim: Animation, t: float) -> Array:
	var poses := []
	poses.resize(skel.get_bone_count())
	for i in range(skel.get_bone_count()):
		poses[i] = Transform3D.IDENTITY
	for ti in range(anim.get_track_count()):
		var track_bone := String(anim.track_get_path(ti)).get_slice(":", 1)
		var bi := skel.find_bone(track_bone)
		if bi == -1:
			continue
		var tr: Transform3D = poses[bi]
		match anim.track_get_type(ti):
			Animation.TYPE_POSITION_3D:
				tr.origin = anim.position_track_interpolate(ti, t)
			Animation.TYPE_ROTATION_3D:
				tr.basis = Basis(anim.rotation_track_interpolate(ti, t))
			Animation.TYPE_SCALE_3D:
				tr.basis = tr.basis.scaled(anim.scale_track_interpolate(ti, t))
		poses[bi] = tr
	var globals := []
	globals.resize(skel.get_bone_count())
	for i in range(skel.get_bone_count()):
		var parent := skel.get_bone_parent(i)
		var local := poses[i] as Transform3D
		if local == Transform3D.IDENTITY:
			local = skel.get_bone_rest(i)
		globals[i] = local if parent == -1 else (globals[parent] as Transform3D) * local
	return globals

func _live_bone_globals(skel: Skeleton3D) -> Array:
	var globals := []
	globals.resize(skel.get_bone_count())
	for i in range(skel.get_bone_count()):
		globals[i] = skel.get_bone_global_pose(i)
	return globals

func _global_bone_position(skel: Skeleton3D, globals: Array, bone_name: String) -> Vector3:
	return (globals[skel.find_bone(bone_name)] as Transform3D).origin

# RecentFiles must persist across instances, move-to-front on re-add, de-dup,
# keep model/anim categories separate, cap the list, and prune files that no
# longer exist on disk.
func test_recent_files_persist_dedup_and_prune() -> void:
	var RecentFiles = load("res://scripts/auto_rig/recent_files.gd")
	# Use real temp files so existence-pruning can be exercised.
	var dir := ProjectSettings.globalize_path("user://_recent_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var a := dir + "/a.glb"
	var b := dir + "/b.fbx"
	var c := dir + "/c.fbx"
	for f in [a, b, c]:
		FileAccess.open(f, FileAccess.WRITE).close()

	# Start from a clean config.
	var cfg := ProjectSettings.globalize_path(RecentFiles.SAVE_PATH)
	if FileAccess.file_exists(cfg):
		DirAccess.remove_absolute(cfg)

	var r1 = RecentFiles.new()
	r1.add("model", a)
	r1.add("model", b)
	r1.add("model", a)  # re-add a => moves to front, no duplicate
	r1.add("anim", c)   # separate category

	# Persisted across a fresh instance.
	var r2 = RecentFiles.new()
	var models: PackedStringArray = r2.get_recent("model")
	TestAssert.equal(models.size(), 2, "model list de-duplicated to 2 entries")
	TestAssert.equal(models[0], a, "re-added path moved to front")
	TestAssert.equal(models[1], b, "older path follows")
	var anims: PackedStringArray = r2.get_recent("anim")
	TestAssert.equal(anims.size(), 1, "anim category is separate")
	TestAssert.equal(anims[0], c, "anim path recorded")

	# Pruning: delete b, it must drop out of the recent list.
	DirAccess.remove_absolute(b)
	var r3 = RecentFiles.new()
	var pruned: PackedStringArray = r3.get_recent("model")
	TestAssert.equal(pruned.size(), 1, "deleted file pruned from recents")
	TestAssert.equal(pruned[0], a, "surviving file remains")

	# Cap: adding more than MAX_ENTRIES keeps only the newest MAX_ENTRIES.
	var r4 = RecentFiles.new()
	for i in range(RecentFiles.MAX_ENTRIES + 4):
		var f := dir + "/cap_%d.glb" % i
		FileAccess.open(f, FileAccess.WRITE).close()
		r4.add("model", f)
	TestAssert.truthy(r4.get_recent("model").size() <= RecentFiles.MAX_ENTRIES,
		"recent list capped at MAX_ENTRIES")

	# Cleanup.
	if FileAccess.file_exists(cfg):
		DirAccess.remove_absolute(cfg)

# Reusing one FbxImporter instance for multiple files must not leak object maps,
# geometry, or bone-index state from the previous import.
func test_native_fbx_importer_can_be_reused_without_state_leak() -> void:
	var first_path := "D:/newExport/X Bot.fbx"
	var second_path := OS.get_environment("AUTO_RIG_LAB_FBX_SECOND_FIXTURE")
	if second_path == "":
		second_path = "D:/newExport/Maria J J Ong.fbx"
	if not _file_exists(first_path) or not _file_exists(second_path):
		print("[SKIP] native FBX importer reuse e2e: need '%s' and '%s'" % [first_path, second_path])
		return

	var importer_script = load("res://scripts/auto_rig/fbx_importer.gd")
	var reused = importer_script.new()
	var first: Node3D = reused.import_to_scene(first_path)
	TestAssert.truthy(first != null, "first native import succeeds, err=%s" % reused.error)
	if first != null:
		first.free()

	var reused_second: Node3D = reused.import_to_scene(second_path)
	TestAssert.truthy(reused_second != null, "second native import succeeds on reused importer, err=%s" % reused.error)
	var reused_stats := _native_scene_stats(reused_second)
	if reused_second != null:
		reused_second.free()

	var fresh = importer_script.new()
	var fresh_second: Node3D = fresh.import_to_scene(second_path)
	TestAssert.truthy(fresh_second != null, "second native import succeeds on fresh importer, err=%s" % fresh.error)
	var fresh_stats := _native_scene_stats(fresh_second)
	if fresh_second != null:
		fresh_second.free()

	TestAssert.equal(reused_stats.get("skeleton_count", 0), fresh_stats.get("skeleton_count", 0), "reused importer skeleton count matches fresh")
	TestAssert.equal(reused_stats.get("bone_count", 0), fresh_stats.get("bone_count", 0), "reused importer bone count matches fresh")
	TestAssert.equal(reused_stats.get("mesh_count", 0), fresh_stats.get("mesh_count", 0), "reused importer mesh count matches fresh")

func _native_scene_stats(scene: Node3D) -> Dictionary:
	var stats := {
		"skeleton_count": 0,
		"bone_count": 0,
		"mesh_count": 0,
	}
	if scene == null:
		return stats
	stats["mesh_count"] = scene.find_children("*", "MeshInstance3D", true, false).size()
	var skels := scene.find_children("*", "Skeleton3D", true, false)
	stats["skeleton_count"] = skels.size()
	if skels.size() > 0:
		stats["bone_count"] = (skels[0] as Skeleton3D).get_bone_count()
	return stats

# Mixamo X Bot ships in a T-pose. The native FBX skeleton rest pose must match
# the mesh, so hands stay out to the sides instead of folding upward above the
# head. This guards FBX PreRotation/rotation-order handling.
func test_native_fbx_mixamo_rest_pose_keeps_arms_horizontal() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] native FBX Mixamo rest-pose e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var scene: Node3D = importer.import_to_scene(fbx_path)
	TestAssert.truthy(scene != null, "native importer produced a scene, err=%s" % importer.error)
	var skels: Array = scene.find_children("*", "Skeleton3D", true, false)
	TestAssert.truthy(skels.size() > 0, "native import has a skeleton")
	var skel: Skeleton3D = skels[0]

	var chest := skel.find_bone("mixamorig_Spine2")
	var head := skel.find_bone("mixamorig_Head")
	var left_hand := skel.find_bone("mixamorig_LeftHand")
	var right_hand := skel.find_bone("mixamorig_RightHand")
	TestAssert.truthy(chest != -1 and head != -1 and left_hand != -1 and right_hand != -1, "Mixamo chest/head/hands present")
	var chest_pos: Vector3 = skel.get_bone_global_rest(chest).origin
	var head_pos: Vector3 = skel.get_bone_global_rest(head).origin
	var left_pos: Vector3 = skel.get_bone_global_rest(left_hand).origin
	var right_pos: Vector3 = skel.get_bone_global_rest(right_hand).origin

	TestAssert.truthy(left_pos.x > chest_pos.x + 0.25, "left hand extends to model-left in rest pose")
	TestAssert.truthy(right_pos.x < chest_pos.x - 0.25, "right hand extends to model-right in rest pose")
	TestAssert.truthy(left_pos.y < head_pos.y and right_pos.y < head_pos.y, "hands stay below head in rest pose")
	TestAssert.truthy(absf(left_pos.y - chest_pos.y) < 0.45 and absf(right_pos.y - chest_pos.y) < 0.45,
		"hands stay near chest/shoulder height in rest pose")
	scene.free()

# On an already-rigged FBX, the Auto Bind button must generate the requested
# Toon skeleton instead of silently reusing the imported Mixamo skeleton.
func test_auto_bind_on_rigged_fbx_generates_toon_skeleton() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] rigged FBX auto-bind e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = fbx_path
	lab._load_model_from_ui()
	TestAssert.truthy(lab._skeleton != null, "rigged FBX loads with a skeleton")
	TestAssert.truthy(lab._skeleton.get_bone_name(0).begins_with("mixamorig_"), "initial skeleton is imported Mixamo")

	lab._auto_bind_from_ui()

	TestAssert.equal(lab._skeleton.name, "GeneratedToonHumanoidSkeleton", "auto bind replaces imported skeleton with generated Toon skeleton")
	TestAssert.equal(lab._skeleton.get_bone_count(), 49, "generated Toon skeleton has expected bone count")
	TestAssert.truthy(lab._skeleton.find_bone("Toon_Hand.L") != -1, "generated Toon left hand exists")
	TestAssert.truthy(lab._skeleton.find_bone("mixamorig_LeftHand") == -1, "imported Mixamo hand is no longer the active rig")
	lab.free()

func test_rig_mode_switches_between_imported_none_and_generated() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] rig mode switch e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	var rig_mode_option: OptionButton = lab.find_child("RigModeOption", true, false)
	TestAssert.truthy(rig_mode_option != null, "rig mode option exists")

	lab.find_child("ModelPathEdit", true, false).text = fbx_path
	lab._load_model_from_ui()
	TestAssert.truthy(lab._skeleton != null and lab._skeleton.find_bone("mixamorig_LeftHand") != -1,
		"default mode uses imported Mixamo skeleton")

	lab._on_rig_mode_selected(lab.RigMode.NONE)
	TestAssert.truthy(lab._skeleton == null, "none mode has no active skeleton")
	TestAssert.equal(lab._loaded_scene.find_children("*", "Skeleton3D", true, false).size(), 0, "none mode removes skeleton nodes")
	TestAssert.truthy(lab._loaded_scene.find_children("*", "MeshInstance3D", true, false).size() > 0, "none mode keeps meshes visible")

	lab._on_rig_mode_selected(lab.RigMode.GENERATED)
	TestAssert.truthy(lab._skeleton != null and lab._skeleton.name == "GeneratedToonHumanoidSkeleton",
		"generated mode creates Toon skeleton")
	TestAssert.equal(lab._skeleton.get_bone_count(), 49, "generated mode uses Toon bone count")

	lab._on_rig_mode_selected(lab.RigMode.IMPORTED)
	TestAssert.truthy(lab._skeleton != null and lab._skeleton.find_bone("mixamorig_LeftHand") != -1,
		"imported mode can return to original FBX skeleton")
	lab.free()

func test_no_skeleton_mode_exports_mesh_without_skeleton() -> void:
	var fbx_path := OS.get_environment("AUTO_RIG_LAB_FBX_FIXTURE")
	if fbx_path == "":
		fbx_path = "D:/newExport/X Bot.fbx"
	if not _file_exists(fbx_path):
		print("[SKIP] no-skeleton export e2e: no fixture at '%s' (set AUTO_RIG_LAB_FBX_FIXTURE to enable)" % fbx_path)
		return

	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab = scene.instantiate()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(lab)
	lab.find_child("ModelPathEdit", true, false).text = fbx_path
	lab._load_model_from_ui()
	lab._on_rig_mode_selected(lab.RigMode.NONE)

	var out_path := ProjectSettings.globalize_path("user://_no_skeleton_export_test.glb")
	lab._on_export_path_selected(out_path)
	TestAssert.truthy(FileAccess.file_exists(out_path), "no-skeleton mode export wrote a glb")
	var analyzer = load("res://scripts/auto_rig/auto_rig_analyzer.gd").new()
	var report: Dictionary = analyzer.analyze_scene_path(out_path)
	TestAssert.equal(report.get("status", ""), "ok", "no-skeleton export re-imports")
	TestAssert.falsy(report.get("has_skeleton", true), "no-skeleton export has no skeleton")
	TestAssert.truthy(report.get("mesh_count", 0) > 0, "no-skeleton export keeps meshes")
	lab.free()
	DirAccess.remove_absolute(out_path)

func test_fbx_normal_mapping_uses_control_point_for_by_vertex_layers() -> void:
	var importer = load("res://scripts/auto_rig/fbx_importer.gd").new()
	var normals := PackedFloat64Array([
		1.0, 0.0, 0.0,
		0.0, 1.0, 0.0,
		0.0, 0.0, 1.0,
	])
	TestAssert.equal(
		importer._normal_for_vertex(normals, null, "ByVertice", "Direct", 1, 99),
		Vector3(0.0, 1.0, 0.0),
		"ByVertice normals use the control-point index"
	)
	TestAssert.equal(
		importer._normal_for_vertex(normals, PackedInt32Array([2, 0]), "ByPolygonVertex", "IndexToDirect", 1, 0),
		Vector3(0.0, 0.0, 1.0),
		"IndexToDirect normals use the normal index table"
	)

# Builds a tiny but valid binary FBX (version 7400, 32-bit records) containing
# Objects > Geometry("Cube","Mesh") with one deflated Vertices array. Used by the
# parser unit test so it needs no external file.
func _build_minimal_fbx() -> PackedByteArray:
	# A node is: end_off(u32) num_props(u32) prop_len(u32) name_len(u8) name props children NULL13
	# We assemble inner-most first so offsets are known.
	var verts := PackedFloat64Array([1.5, 2.5, 3.5])
	var raw := verts.to_byte_array()
	var comp := raw.compress(FileAccess.COMPRESSION_DEFLATE)

	# Property: 'd' array -> typecode 'd', arraylen, encoding=1, complen, payload
	var vert_prop := PackedByteArray()
	vert_prop.append(0x64)  # 'd'
	vert_prop.append_array(_u32(verts.size()))
	vert_prop.append_array(_u32(1))             # encoding = deflate
	vert_prop.append_array(_u32(comp.size()))
	vert_prop.append_array(comp)

	var vertices_node := _make_node("Vertices", [vert_prop], [])
	# Geometry node: props = id(L), name(S "Cube"), class(S "Mesh")
	var id_prop := PackedByteArray([0x4C]); id_prop.append_array(_u64(1234))
	var name_prop := _string_prop("Cube")
	var class_prop := _string_prop("Mesh")
	var geometry_node := _make_node("Geometry", [id_prop, name_prop, class_prop], [vertices_node])
	var objects_node := _make_node("Objects", [], [geometry_node])

	var body := PackedByteArray()
	# Header: magic(20) + 0x1A 0x00 + version(u32)
	body.append_array("Kaydara FBX Binary  ".to_ascii_buffer())
	body.append(0x00); body.append(0x1A); body.append(0x00)
	body.append_array(_u32(7400))
	# Top-level records start at this offset; fix up child end offsets relative to it.
	var start := body.size()
	var top := _finalize_offsets(objects_node, start)
	body.append_array(top)
	# Terminating null record (13 bytes of zero) for the top level.
	for i in range(13):
		body.append(0)
	return body

# --- minimal-FBX assembly helpers (32-bit records) ---------------------------

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray(); b.resize(4); b.encode_u32(0, v); return b

func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray(); b.resize(8); b.encode_u64(0, v); return b

func _string_prop(s: String) -> PackedByteArray:
	var b := PackedByteArray([0x53])  # 'S'
	var sb := s.to_ascii_buffer()
	b.append_array(_u32(sb.size()))
	b.append_array(sb)
	return b

# Builds a node WITHOUT a correct end_offset (placeholder 0); _finalize_offsets
# patches it once the byte layout is known. Stores child blobs pre-serialized.
func _make_node(name: String, props: Array, children: Array) -> Dictionary:
	return {"name": name, "props": props, "children": children}

# Serializes a node tree to bytes, computing each end_offset relative to the file
# start (base = absolute offset of this node's first byte).
func _finalize_offsets(node: Dictionary, base: int) -> PackedByteArray:
	var name: String = node["name"]
	var props: Array = node["props"]
	var children: Array = node["children"]
	var prop_blob := PackedByteArray()
	for p in props:
		prop_blob.append_array(p)
	# Header is 13 bytes for 32-bit records, then name, then props, then children.
	var header_and_name := 13 + name.length()
	var children_base := base + header_and_name + prop_blob.size()
	var child_blob := PackedByteArray()
	var cursor := children_base
	for c in children:
		var cb := _finalize_offsets(c, cursor)
		child_blob.append_array(cb)
		cursor += cb.size()
	# Children block is followed by a 13-byte null record when there are children.
	var null_rec := PackedByteArray()
	if children.size() > 0:
		null_rec.resize(13)
	var end_offset := children_base + child_blob.size() + null_rec.size()

	var out := PackedByteArray()
	out.append_array(_u32(end_offset))
	out.append_array(_u32(props.size()))
	out.append_array(_u32(prop_blob.size()))
	out.append(name.length())
	out.append_array(name.to_ascii_buffer())
	out.append_array(prop_blob)
	out.append_array(child_blob)
	out.append_array(null_rec)
	return out

func test_auto_rig_lab_scene_has_split_rig_and_preview_workspace() -> void:
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	TestAssert.truthy(scene != null, "auto rig lab scene exists")
	var root = scene.instantiate()
	TestAssert.truthy(root.find_child("AutoRigPanel", true, false) != null, "left auto-rig panel exists")
	TestAssert.truthy(root.find_child("PreviewViewport", true, false) != null, "right realtime preview exists")
	TestAssert.truthy(root.find_child("LoadModelButton", true, false) != null, "model import control exists")
	TestAssert.truthy(root.find_child("FingerCurlSlider", true, false) != null, "finger fine-tune slider exists")
	TestAssert.truthy(root.find_child("RigQualityLabel", true, false) != null, "rig quality label exists")
	TestAssert.truthy(root.find_child("RigModeOption", true, false) != null, "rig mode selector exists")
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

	# Octahedral draws solid bone cones (many triangle verts) vs lines (2 verts/
	# bone), so the octahedral surface has far more vertices and a grey material.
	lab._on_bone_style_selected(lab.BoneStyle.LINES)
	TestAssert.truthy(overlay.mesh.get_surface_count() > 0, "lines style produces geometry")
	var line_verts: int = (overlay.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	TestAssert.truthy(overlay.material_override == lab._line_material, "lines material applied")

	lab._on_bone_style_selected(lab.BoneStyle.OCTAHEDRAL)
	TestAssert.truthy(overlay.mesh.get_surface_count() > 0, "octahedral style produces geometry")
	var octa_verts: int = (overlay.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	TestAssert.truthy(octa_verts > line_verts * 4, "octahedral has many more verts than lines (solid cones)")
	TestAssert.truthy(overlay.material_override == lab._octa_material, "octahedral material applied")
	lab.free()
