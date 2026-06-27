extends RefCounted
class_name TestAssert

# Tracks assertion failures across a run. `assert(false)` alone does NOT abort
# release/headless tool scripts, so runners must consult `failure_count` (or call
# `finish()`) to fail the process — otherwise a suite can print "passed" and exit
# 0 while assertions were failing.
static var failure_count: int = 0
static var first_failure: String = ""

static func reset() -> void:
	failure_count = 0
	first_failure = ""

static func _fail(message: String) -> void:
	failure_count += 1
	if first_failure == "":
		first_failure = message
	push_error(message)
	# Still attempt the engine assert (aborts in debug builds); harmless otherwise.
	assert(false, message)

# Called by test runners after running suites. Prints a summary and quits with a
# non-zero code if anything failed, so green output always means green.
static func finish(tree: SceneTree, label: String = "Tests") -> void:
	if failure_count > 0:
		printerr("%s FAILED: %d assertion(s). First: %s" % [label, failure_count, first_failure])
		tree.quit(1)
	else:
		print("%s passed" % label)
		tree.quit(0)

static func equal(actual, expected, message: String = "") -> void:
	var matches: bool = actual == expected
	if typeof(actual) == TYPE_FLOAT or typeof(expected) == TYPE_FLOAT:
		matches = is_equal_approx(float(actual), float(expected))
	if not matches:
		_fail("%s Expected %s, got %s" % [message, str(expected), str(actual)])

static func truthy(value, message: String = "") -> void:
	if not value:
		_fail("%s Expected truthy value" % message)

static func falsy(value, message: String = "") -> void:
	if value:
		_fail("%s Expected falsy value" % message)
