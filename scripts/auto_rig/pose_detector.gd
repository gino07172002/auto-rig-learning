extends RefCounted
class_name PoseDetector

# AI-assisted joint detection. Renders the loaded model to a front image, runs
# MediaPipe BlazePose (via a Python helper) to find 33 body landmarks, and
# back-projects the ones we use into 3D joint points in the SAME format as
# ToonHumanoidFitter.detect_joint_points() — so they flow into the existing
# Detect Joints markers / edit / bind pipeline.
#
# BlazePose is far more accurate at the shoulders/wrists than the geometric
# silhouette method; we keep the geometric result for DEPTH (front view gives no
# depth) and to fill any low-confidence landmark, so this is a refinement layer
# on top, not a replacement.

const SCRIPT_RES := "res://scripts/auto_rig/blazepose_detect.py"

var error := ""
var last_confidence := {}   # joint key -> BlazePose visibility for the UI
var last_image_size := Vector2.ZERO  # pixel size of the image BlazePose processed

# Maps our logical joint key to the PAIR of BlazePose landmark indices for that
# body part (BlazePose's own left, right). We don't trust BlazePose's L/R labels
# (they follow the image, and a model may face either way).
const KEY_TO_BLAZEPOSE_PAIR := {
	"head": [0, 0],            # nose (single point)
	"shoulder.L": [11, 12], "shoulder.R": [11, 12],
	"upper_arm.L": [11, 12], "upper_arm.R": [11, 12],
	"lower_arm.L": [13, 14], "lower_arm.R": [13, 14],  # elbow
	"hand.L": [15, 16], "hand.R": [15, 16],            # wrist
	"upper_leg.L": [23, 24], "upper_leg.R": [23, 24],  # hip
	"lower_leg.L": [25, 26], "lower_leg.R": [25, 26],  # knee
	"foot.L": [27, 28], "foot.R": [27, 28],            # ankle
}

# Body-part groups sharing a BlazePose landmark pair. Each group's two landmarks are
# assigned to the two logical keys by SCREEN-X ORDERING (leftmost landmark -> the key
# whose geometric point projects leftmost), which is mirror/orientation-proof AND
# mutually exclusive (a landmark can't be grabbed by both L and R). `head` is single.
const PAIR_GROUPS := [
	{"left": "shoulder.L", "right": "shoulder.R", "lm": [11, 12]},
	{"left": "upper_arm.L", "right": "upper_arm.R", "lm": [11, 12]},
	{"left": "lower_arm.L", "right": "lower_arm.R", "lm": [13, 14]},
	{"left": "hand.L", "right": "hand.R", "lm": [15, 16]},
	{"left": "upper_leg.L", "right": "upper_leg.R", "lm": [23, 24]},
	{"left": "lower_leg.L", "right": "lower_leg.R", "lm": [25, 26]},
	{"left": "foot.L", "right": "foot.R", "lm": [27, 28]},
]
const HEAD_LANDMARK := 0

# Per-joint depth strategy for two-view detection. Verified VISUALLY by overlaying both
# on the front render: BlazePose's shoulder/elbow/wrist land ON the actual arm joints,
# while the geometric arm points over-extend past the fingertips — so BlazePose wins for
# the arm's X/Y. In a T-pose the arms point straight at the SIDE camera though, so
# side-view depth for arms is garbage; arms lie in the front plane so geometric depth is
# fine. Strategies:
#   GEOMETRIC — keep the geometric point untouched.
#   FRONT     — BlazePose X/Y from the front view, depth borrowed from geometry.
#   TRIANGULATE — front+side rays intersected for true X/Y/Z (torso-plane joints the
#               side view sees clearly: head, hips, knees, ankles).
# `upper_arm` shares BlazePose's shoulder landmark, so it stays GEOMETRIC (its geometric
# position partway down the arm is the correct bone start; BlazePose has no mid-upper-arm
# point). shoulder/elbow/wrist use BlazePose FRONT.
const DEPTH_GEOMETRIC := 0
const DEPTH_FRONT := 1
const DEPTH_TRIANGULATE := 2
const JOINT_DEPTH_STRATEGY := {
	"head": DEPTH_TRIANGULATE,
	"shoulder.L": DEPTH_FRONT, "shoulder.R": DEPTH_FRONT,
	"upper_arm.L": DEPTH_GEOMETRIC, "upper_arm.R": DEPTH_GEOMETRIC,
	"lower_arm.L": DEPTH_FRONT, "lower_arm.R": DEPTH_FRONT,
	"hand.L": DEPTH_FRONT, "hand.R": DEPTH_FRONT,
	"upper_leg.L": DEPTH_TRIANGULATE, "upper_leg.R": DEPTH_TRIANGULATE,
	"lower_leg.L": DEPTH_TRIANGULATE, "lower_leg.R": DEPTH_TRIANGULATE,
	"foot.L": DEPTH_TRIANGULATE, "foot.R": DEPTH_TRIANGULATE,
}

# Runs AI pose detection and returns joint points, or {} on failure (error set).
# `geometric` is the result of ToonHumanoidFitter.detect_joint_points(); its
# points supply per-joint depth and fallback for anything BlazePose misses.
#   returns { "points": {key: Vector3}, "measured": {key: bool},
#             "height": float, "detection": {...} }
func detect(image_path: String, camera: Camera3D, viewport_size: Vector2,
		scene_xform: Transform3D, geometric: Dictionary, min_vis: float = 0.4) -> Dictionary:
	error = ""
	last_confidence = {}
	var landmarks := _run_python(image_path)
	if landmarks.is_empty():
		return {}

	var geo_points: Dictionary = geometric.get("points", {})
	var out_points: Dictionary = {}
	var out_measured: Dictionary = {}
	# Start from the geometric points so keys with no BlazePose mapping (spine,
	# neck, chest, finger placeholders) keep their measured positions.
	for key in geo_points:
		out_points[key] = geo_points[key]
		out_measured[key] = geometric.get("measured", {}).get(key, true)

	# Match BlazePose landmarks to our logical keys (mutually exclusive L/R).
	var matched := _match_landmarks_to_keys(landmarks, camera, viewport_size, scene_xform, geo_points, min_vis)
	for key in matched:
		var screen: Vector2 = matched[key]["screen"]
		var refined = _backproject(screen, camera, viewport_size, scene_xform, geo_points[key])
		if refined != null:
			out_points[key] = refined
			out_measured[key] = true

	return {
		"points": out_points,
		"measured": out_measured,
		"height": geometric.get("height", 0.0),
		"detection": _summarize(out_measured),
	}

# Two-view AI detection: triangulates each joint from a FRONT and a SIDE capture, so
# depth (Z) is measured rather than borrowed from geometry. Both captures must be taken
# with the SAME model in the SAME pose; only the camera differs. Each `*_view` is a
# Dictionary produced by `capture_view()` while that view's camera was live:
#   { rays: {key: {origin, dir}}, confidence: {key: vis} }
# Falls back to the front ray's back-projection for any joint the side view missed.
func detect_two_view(front_view: Dictionary, side_view: Dictionary,
		front_camera: Camera3D, front_viewport: Vector2, scene_xform: Transform3D,
		geometric: Dictionary, min_vis: float = 0.4) -> Dictionary:
	error = ""
	last_confidence = {}
	var geo_points: Dictionary = geometric.get("points", {})
	var out_points: Dictionary = {}
	var out_measured: Dictionary = {}
	for key in geo_points:
		out_points[key] = geo_points[key]
		out_measured[key] = geometric.get("measured", {}).get(key, true)

	var front_rays: Dictionary = front_view.get("rays", {})
	var side_rays: Dictionary = side_view.get("rays", {})
	var front_conf: Dictionary = front_view.get("confidence", {})
	if front_rays.is_empty():
		error = "front pose not detected"
		return {}

	for key in front_rays:
		var fr: Dictionary = front_rays[key]
		last_confidence[key] = front_conf.get(key, 0.0)
		var strategy: int = JOINT_DEPTH_STRATEGY.get(key, DEPTH_TRIANGULATE)
		# GEOMETRIC joints keep the geometric point (handled in the post-pass for upper_arm).
		if strategy == DEPTH_GEOMETRIC:
			continue
		var pos = null
		# TRIANGULATE joints use the side ray for real depth, when the side view saw them.
		if strategy == DEPTH_TRIANGULATE and side_rays.has(key):
			var sr: Dictionary = side_rays[key]
			pos = _triangulate(fr["origin"], fr["dir"], sr["origin"], sr["dir"])
		# FRONT joints (and any TRIANGULATE joint the side view missed) use the front
		# ray on the geometric depth plane: correct X/Y, depth borrowed from geometry.
		if pos == null and geo_points.has(key) and front_camera != null:
			pos = _backproject_world(_screen_from_ray(fr, front_camera, front_viewport),
				front_camera, front_viewport, scene_xform, geo_points[key])
		if pos != null:
			out_points[key] = scene_xform.affine_inverse() * (pos as Vector3)
			out_measured[key] = true

	# upper_arm has no BlazePose landmark of its own, so place it on the shoulder->elbow
	# line (40% down) instead of the over-extended geometric point. This keeps the whole
	# arm chain (shoulder -> upper_arm -> lower_arm -> hand) monotonic and clean.
	for side in [".L", ".R"]:
		var sh: String = "shoulder" + side
		var el: String = "lower_arm" + side
		var ua: String = "upper_arm" + side
		if out_points.has(sh) and out_points.has(el) and out_measured.get(sh, false) and out_measured.get(el, false):
			out_points[ua] = (out_points[sh] as Vector3).lerp(out_points[el], 0.4)
			out_measured[ua] = true

	return {
		"points": out_points,
		"measured": out_measured,
		"height": geometric.get("height", 0.0),
		"detection": _summarize(out_measured),
	}

# Runs BlazePose on one rendered image and returns, for each matched joint key, the
# world-space ray (camera origin + direction) through that landmark's pixel. Call this
# while `camera` is live (positioned at the desired view); the returned rays are frozen
# world-space so they can be triangulated later after the camera has moved.
#   returns { rays: {key: {origin: Vector3, dir: Vector3}}, confidence: {key: vis} }
func capture_view(image_path: String, camera: Camera3D, viewport_size: Vector2,
		scene_xform: Transform3D, geo_points: Dictionary, min_vis: float = 0.4) -> Dictionary:
	var landmarks := _run_python(image_path)
	if landmarks.is_empty():
		return {"rays": {}, "confidence": {}}
	var matched := _match_landmarks_to_keys(landmarks, camera, viewport_size, scene_xform, geo_points, min_vis)
	var rays := {}
	var conf := {}
	for key in matched:
		var screen: Vector2 = matched[key]["screen"]
		rays[key] = {
			"origin": camera.project_ray_origin(screen),
			"dir": camera.project_ray_normal(screen),
		}
		conf[key] = matched[key]["vis"]
	return {"rays": rays, "confidence": conf}

# Assigns BlazePose landmarks to our logical joint keys. For each body-part pair the two
# landmarks are ordered by screen-X and matched to the two keys ordered by their
# geometric screen-X — mirror/orientation-proof and mutually exclusive. Returns
# { key: {screen: Vector2, vis: float} } for keys that passed the confidence gate.
func _match_landmarks_to_keys(landmarks: Array, camera: Camera3D, viewport_size: Vector2,
		scene_xform: Transform3D, geo_points: Dictionary, min_vis: float) -> Dictionary:
	var out := {}
	if camera == null:
		return out
	# Scale BlazePose image pixels -> camera viewport pixels (see note in detect()).
	var scale := Vector2.ONE
	if last_image_size.x > 0.0 and last_image_size.y > 0.0:
		scale = viewport_size / last_image_size
	var lm := {}
	for entry in landmarks:
		lm[int(entry["i"])] = entry

	# Head: single landmark, no L/R ambiguity.
	if geo_points.has("head") and lm.has(HEAD_LANDMARK):
		var he: Dictionary = lm[HEAD_LANDMARK]
		var hvis := float(he["vis"])
		last_confidence["head"] = hvis
		if hvis >= min_vis:
			out["head"] = {"screen": Vector2(float(he["x"]), float(he["y"])) * scale, "vis": hvis}

	for group in PAIR_GROUPS:
		var lkey: String = group["left"]
		var rkey: String = group["right"]
		if not geo_points.has(lkey) or not geo_points.has(rkey):
			continue
		var a := int(group["lm"][0])
		var b := int(group["lm"][1])
		if not lm.has(a) or not lm.has(b):
			continue
		# Order the two landmarks by screen-X.
		var pa := Vector2(float(lm[a]["x"]), float(lm[a]["y"])) * scale
		var pb := Vector2(float(lm[b]["x"]), float(lm[b]["y"])) * scale
		var va := float(lm[a]["vis"])
		var vb := float(lm[b]["vis"])
		var left_pt := pa
		var left_vis := va
		var right_pt := pb
		var right_vis := vb
		if pa.x > pb.x:
			left_pt = pb; left_vis = vb; right_pt = pa; right_vis = va
		# Order OUR two keys by their geometric screen-X, then match left->left.
		var lx := _geo_screen_x(geo_points[lkey], camera, scene_xform)
		var rx := _geo_screen_x(geo_points[rkey], camera, scene_xform)
		var screen_left_key := lkey
		var screen_right_key := rkey
		if lx > rx:
			screen_left_key = rkey
			screen_right_key = lkey
		last_confidence[screen_left_key] = left_vis
		last_confidence[screen_right_key] = right_vis
		if left_vis >= min_vis:
			out[screen_left_key] = {"screen": left_pt, "vis": left_vis}
		if right_vis >= min_vis:
			out[screen_right_key] = {"screen": right_pt, "vis": right_vis}
	return out

# Screen-X of a scene-local point (large negative if behind the camera, so it sorts
# consistently). Used only for L/R ordering.
func _geo_screen_x(geo_local: Vector3, camera: Camera3D, scene_xform: Transform3D) -> float:
	var world: Vector3 = scene_xform * geo_local
	if camera.is_position_behind(world):
		return -INF
	return camera.unproject_position(world).x

# Closest point between two world-space rays (skew-line midpoint). Returns a world
# Vector3, or null if the rays are near-parallel (degenerate).
func _triangulate(o1: Vector3, d1: Vector3, o2: Vector3, d2: Vector3):
	var da := d1.normalized()
	var db := d2.normalized()
	var r := o1 - o2
	var a := da.dot(da)      # = 1
	var b := da.dot(db)
	var c := da.dot(r)
	var e := db.dot(db)      # = 1
	var f := db.dot(r)
	var denom := a * e - b * b
	if absf(denom) < 0.00001:
		return null           # rays parallel — can't triangulate
	var s := (b * f - c * e) / denom
	var t := (a * f - b * c) / denom
	var p1 := o1 + da * s
	var p2 := o2 + db * t
	return (p1 + p2) * 0.5

# Projects a stored world ray back to a screen pixel (used for single-view fallback).
func _screen_from_ray(ray: Dictionary, camera: Camera3D, _viewport: Vector2) -> Vector2:
	var pt: Vector3 = (ray["origin"] as Vector3) + (ray["dir"] as Vector3)
	return camera.unproject_position(pt)

# Back-projects a 2D screen point (image pixels) to 3D scene-local space, keeping
# the DEPTH of `geo_local` (a scene-local reference point) — the front view fixes
# X/Y, geometry fixes Z. Returns a scene-local Vector3, or null on failure.
func _backproject(screen_px: Vector2, camera: Camera3D, viewport_size: Vector2,
		scene_xform: Transform3D, geo_local: Vector3):
	var world = _backproject_world(screen_px, camera, viewport_size, scene_xform, geo_local)
	if world == null:
		return null
	return scene_xform.affine_inverse() * (world as Vector3)

# Same as _backproject but returns a WORLD-space point (or null). Used by the two-view
# fallback, which converts to scene-local itself.
func _backproject_world(screen_px: Vector2, camera: Camera3D, viewport_size: Vector2,
		scene_xform: Transform3D, geo_local: Vector3):
	if camera == null or viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return null
	var ray_origin := camera.project_ray_origin(screen_px)
	var ray_dir := camera.project_ray_normal(screen_px)
	# Plane through the geometric point, facing the camera; intersect the ray.
	var geo_world: Vector3 = scene_xform * geo_local
	var plane_normal := -camera.global_transform.basis.z
	var denom := ray_dir.dot(plane_normal)
	if absf(denom) < 0.00001:
		return null
	var t := (geo_world - ray_origin).dot(plane_normal) / denom
	if t <= 0.0:
		return null
	return ray_origin + ray_dir * t

# Runs the Python BlazePose helper on `image_path`; returns the landmark array or
# [] on error (with `error` set).
func _run_python(image_path: String) -> Array:
	var python := _find_python()
	if python == "":
		error = "Python not found. Install Python + `pip install mediapipe` for AI pose detection, or set AUTO_RIG_LAB_PYTHON."
		return []
	var script_path := _resolved_script_path()
	if script_path == "":
		error = "Pose script missing: %s" % SCRIPT_RES
		return []
	var args := PackedStringArray([script_path, image_path])
	var output: Array = []
	var code := OS.execute(python, args, output, true)
	var text := "\n".join(output) if output.size() > 0 else ""
	# The helper prints a single JSON line; find it (skip any warnings/log lines).
	var json_line := _last_json_line(text)
	if json_line == "":
		error = "Pose helper produced no JSON (exit %d).\n%s" % [code, text]
		return []
	var parsed = JSON.parse_string(json_line)
	if typeof(parsed) != TYPE_DICTIONARY:
		error = "Could not parse pose output"
		return []
	if not parsed.get("ok", false):
		error = "Pose detection: %s" % parsed.get("error", "unknown error")
		return []
	last_image_size = Vector2(float(parsed.get("width", 0.0)), float(parsed.get("height", 0.0)))
	return parsed.get("landmarks", [])

func _last_json_line(text: String) -> String:
	var best := ""
	for line in text.split("\n", false):
		var s := line.strip_edges()
		if s.begins_with("{") and s.ends_with("}"):
			best = s  # keep the last JSON-looking line
	return best

# Locates a Python executable: env override, then common names on PATH, then
# common Windows install locations (an exported build may not inherit PATH).
func _find_python() -> String:
	var env := OS.get_environment("AUTO_RIG_LAB_PYTHON")
	if env != "" and FileAccess.file_exists(env):
		return env
	for name in ["python", "python3", "py"]:
		if _python_runs(name):
			return name
	for candidate in _python_candidates():
		if FileAccess.file_exists(candidate) and _python_runs(candidate):
			return candidate
	return ""

# Common Windows Python locations (user + machine installs, py launcher).
func _python_candidates() -> Array:
	if OS.get_name() != "Windows":
		return ["/usr/bin/python3", "/usr/local/bin/python3"]
	var out: Array = []
	var localapp := OS.get_environment("LOCALAPPDATA")
	if localapp != "":
		# Store Python + standard user installs (newest-ish versions first).
		out.append("%s/Microsoft/WindowsApps/python.exe" % localapp)
		for ver in ["313", "312", "311", "310"]:
			out.append("%s/Programs/Python/Python%s/python.exe" % [localapp, ver])
	for ver in ["313", "312", "311", "310"]:
		out.append("C:/Python%s/python.exe" % ver)
		out.append("C:/Program Files/Python%s/python.exe" % ver)
	out.append("C:/Windows/py.exe")
	return out

func _python_runs(exe: String) -> bool:
	var output: Array = []
	var code := OS.execute(exe, PackedStringArray(["--version"]), output, true)
	return code == 0

# Resolves the res:// python script to a path the OS can actually execute. In the
# editor res:// is a loose file on disk, so its globalized path runs directly. In an
# exported build res:// lives INSIDE the PCK — globalize_path returns a dist-relative
# path that doesn't exist on disk (that produced "python: can't open file
# …/dist/scripts/…"), so we must copy the script out to user:// and run that copy.
func _resolved_script_path() -> String:
	# In an exported build, always stage to user:// (res:// is packed, not on disk).
	if not OS.has_feature("editor"):
		return _stage_script_to_user()
	var direct := ProjectSettings.globalize_path(SCRIPT_RES)
	if FileAccess.file_exists(direct):
		return direct
	return _stage_script_to_user()

# Copies the packed script out to user:// and returns its absolute path ("" on error).
func _stage_script_to_user() -> String:
	var src := FileAccess.open(SCRIPT_RES, FileAccess.READ)
	if src == null:
		return ""
	var text := src.get_as_text()
	src.close()
	var staged := "user://blazepose_detect.py"
	var dst := FileAccess.open(staged, FileAccess.WRITE)
	if dst == null:
		return ""
	dst.store_string(text)
	dst.close()
	return ProjectSettings.globalize_path(staged)

func _summarize(measured: Dictionary) -> Dictionary:
	return {
		"spine": true,
		"shoulders": measured.get("shoulder.L", false) and measured.get("shoulder.R", false),
		"arms.L": measured.get("hand.L", false),
		"arms.R": measured.get("hand.R", false),
		"hips": measured.get("upper_leg.L", false) and measured.get("upper_leg.R", false),
		"legs": measured.get("foot.L", false) and measured.get("foot.R", false),
	}
