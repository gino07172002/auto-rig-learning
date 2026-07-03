extends SceneTree

const AutoRigLabTests = preload("res://scripts/tests/test_auto_rig_lab.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var tests := AutoRigLabTests.new()
	tests.test_animation_timeline_play_pause_and_seek_controls()
	print("Animation timeline regression passed")
	quit()
