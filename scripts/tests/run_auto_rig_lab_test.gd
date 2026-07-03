extends SceneTree

const TestAssert = preload("res://scripts/core/test_assert.gd")

func _init() -> void:
	# Defer so the SceneTree is established as the main loop before tests run;
	# the skinning deformation test needs a live tree for bone pose math.
	call_deferred("_run")

func _run() -> void:
	TestAssert.reset()
	var test = load("res://scripts/tests/test_auto_rig_lab.gd").new()
	# run() may await (e.g. the AI-pose e2e renders frames), so await it before
	# tallying, or finish() would run before async tests complete.
	await test.run()
	# Exits non-zero (and prints FAILED) if any assertion failed, so a green
	# message and exit 0 reliably mean the suite actually passed.
	TestAssert.finish(self, "Auto rig lab tests")
