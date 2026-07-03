extends SceneTree

const AutoRigLabTests = preload("res://scripts/tests/test_auto_rig_lab.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var tests := AutoRigLabTests.new()
	tests.test_symmetric_joint_edit_mirrors_paired_joint()
	print("Symmetric joint regression passed")
	quit()
