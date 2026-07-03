extends SceneTree

const TestAssert = preload("res://scripts/core/test_assert.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	TestAssert.reset()
	var test = load("res://scripts/tests/test_auto_rig_lab.gd").new()
	test.test_fbx_animation_uses_target_rest_basis_for_rotation_delta()
	test.test_fbx_animation_matches_official_import_all_joint_points()
	TestAssert.finish(self, "FBX animation rotation regression")
