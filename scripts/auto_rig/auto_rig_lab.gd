extends Control
class_name AutoRigLab

const AutoRigAnalyzer = preload("res://scripts/auto_rig/auto_rig_analyzer.gd")
const ToonHumanoidFitter = preload("res://scripts/auto_rig/toon_humanoid_fitter.gd")

@onready var _path_edit: LineEdit = find_child("ModelPathEdit", true, false)
@onready var _browse_button: Button = find_child("BrowseModelButton", true, false)
@onready var _load_button: Button = find_child("LoadModelButton", true, false)
@onready var _auto_button: Button = find_child("AutoBindButton", true, false)
@onready var _status: Label = find_child("StatusLabel", true, false)
@onready var _bone_summary: Label = find_child("BoneSummaryLabel", true, false)
@onready var _finger_summary: Label = find_child("FingerSummaryLabel", true, false)
@onready var _quality_label: Label = find_child("RigQualityLabel", true, false)
@onready var _finger_slider: HSlider = find_child("FingerCurlSlider", true, false)
@onready var _pose_slider: HSlider = find_child("PoseIntensitySlider", true, false)
@onready var _viewport: SubViewport = find_child("PreviewViewport", true, false)
@onready var _model_root: Node3D = find_child("ModelRoot", true, false)
@onready var _rig_overlay_root: Node3D = find_child("RigOverlayRoot", true, false)
@onready var _preview_label: Label = find_child("PreviewStateLabel", true, false)
@onready var _preview_container: SubViewportContainer = find_child("PreviewViewportContainer", true, false)
@onready var _camera: Camera3D = find_child("Camera3D", true, false)
@onready var _bone_style_option: OptionButton = find_child("BoneStyleOption", true, false)

# Bone overlay display styles, selectable in the preview toolbar.
enum BoneStyle { LINES, OCTAHEDRAL }
var _bone_style: int = BoneStyle.LINES

var _analyzer := AutoRigAnalyzer.new()
var _fitter := ToonHumanoidFitter.new()
var _loaded_scene: Node3D
var _skeleton: Skeleton3D
var _last_report: Dictionary = {}
var _overlay_mesh_instance: MeshInstance3D
var _overlay_mesh := ImmediateMesh.new()
var _line_material: StandardMaterial3D
var _octa_material: StandardMaterial3D
var _phase := 0.0
var _finger_bones: Array[int] = []
# When the imported model ships its own AnimationPlayer (e.g. a Blender-authored
# Walk clip), we let it drive the skeleton instead of the procedural preview.
var _anim_player: AnimationPlayer = null
var _builtin_animation := ""
var _file_dialog: FileDialog = null
# Orbit camera state (spherical coords around _orbit_pivot).
var _orbit_yaw := 0.0
var _orbit_pitch := deg_to_rad(15.0)
var _orbit_distance := 5.4
var _orbit_pivot := Vector3(0.0, 1.0, 0.0)
var _orbit_dragging := false
var _panning := false
const ORBIT_MIN_DISTANCE := 1.2
const ORBIT_MAX_DISTANCE := 18.0
const ORBIT_PITCH_LIMIT := deg_to_rad(85.0)

func _ready() -> void:
	_setup_overlay()
	_load_button.pressed.connect(_load_model_from_ui)
	_auto_button.pressed.connect(_auto_bind_from_ui)
	_setup_file_dialog()
	if _browse_button != null:
		_browse_button.pressed.connect(_open_file_dialog)
	_finger_slider.value_changed.connect(func(_v): _pose_preview(0.0))
	_pose_slider.value_changed.connect(func(_v): _pose_preview(0.0))
	if _bone_style_option != null:
		_bone_style_option.clear()
		_bone_style_option.add_item("Lines", BoneStyle.LINES)
		_bone_style_option.add_item("Octahedral (Blender)", BoneStyle.OCTAHEDRAL)
		_bone_style_option.selected = _bone_style
		_bone_style_option.item_selected.connect(_on_bone_style_selected)
	# Drag/zoom the preview: route the container's mouse events to the orbit cam.
	if _preview_container != null:
		_preview_container.gui_input.connect(_on_preview_gui_input)
	_apply_orbit_camera()
	_load_model_from_ui()

# Builds the "Browse..." file picker. Uses the OS-native dialog when available
# and filters to glTF model files, with full filesystem access so external
# models (outside res://) can be picked too.
func _setup_file_dialog() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Select a 3D model"
	_file_dialog.add_filter("*.glb,*.gltf", "glTF models")
	_file_dialog.add_filter("*.*", "All files")
	_file_dialog.file_selected.connect(_on_model_file_selected)
	add_child(_file_dialog)

func _open_file_dialog() -> void:
	if _file_dialog == null:
		return
	# Start browsing from the current path's directory when it points somewhere real.
	var current := _path_edit.text.strip_edges()
	if current != "":
		var dir := _to_dir(current)
		if dir != "":
			_file_dialog.current_dir = dir
	# Non-native dialogs need an explicit size; native ones ignore it.
	_file_dialog.popup_centered_ratio(0.6)

func _on_model_file_selected(path: String) -> void:
	_path_edit.text = path
	_load_model_from_ui()

# Resolves a model path (res:// or absolute) to a filesystem directory for the
# dialog's starting location, or "" if it cannot be determined.
func _to_dir(path: String) -> String:
	var fs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		fs_path = ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(fs_path):
		return fs_path.get_base_dir()
	var base := fs_path.get_base_dir()
	if DirAccess.dir_exists_absolute(base):
		return base
	return ""

# Orbit (left-drag), zoom (wheel) and pan (middle/right-drag) for the preview.
func _on_preview_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				_orbit_dragging = mb.pressed
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_zoom_orbit(-1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_zoom_orbit(1)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbit_dragging:
			_orbit_yaw -= mm.relative.x * 0.01
			_orbit_pitch = clampf(_orbit_pitch + mm.relative.y * 0.01, -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT)
			_apply_orbit_camera()
		elif _panning:
			_pan_orbit(mm.relative)

# Shifts the pivot in the camera's screen plane (right/up), so right/middle drag
# slides the framing — handy for inspecting an off-centre detail like a hand.
func _pan_orbit(screen_delta: Vector2) -> void:
	if _camera == null:
		return
	# Scale pan speed with distance so it feels consistent at any zoom.
	var speed := _orbit_distance * 0.0018
	var right := _camera.global_transform.basis.x
	var up := _camera.global_transform.basis.y
	_orbit_pivot += (-right * screen_delta.x + up * screen_delta.y) * speed
	_apply_orbit_camera()

func _zoom_orbit(direction: int) -> void:
	# Multiplicative zoom feels natural across the whole distance range.
	_orbit_distance = clampf(_orbit_distance * (1.0 + 0.12 * direction), ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE)
	_apply_orbit_camera()

# Places the camera on a sphere around the pivot from yaw/pitch/distance.
func _apply_orbit_camera() -> void:
	if _camera == null:
		return
	var offset := Vector3(
		cos(_orbit_pitch) * sin(_orbit_yaw),
		sin(_orbit_pitch),
		cos(_orbit_pitch) * cos(_orbit_yaw),
	) * _orbit_distance
	_camera.position = _orbit_pivot + offset
	_camera.look_at(_orbit_pivot, Vector3.UP)

# Re-centres the orbit pivot on the freshly loaded model and picks a distance
# that frames it, while keeping the user's current view angle.
func _frame_orbit_on_model() -> void:
	if _loaded_scene == null:
		return
	var aabb: AABB = _calculate_aabb(_loaded_scene)
	if aabb.size.length() <= 0.001:
		return
	_orbit_pivot = aabb.position + aabb.size * 0.5
	var radius: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * 0.5
	# Distance to fit the model in view for the camera's FOV, with a small margin.
	var fov_rad: float = deg_to_rad(_camera.fov) if _camera != null else deg_to_rad(34.0)
	_orbit_distance = clampf(radius / maxf(sin(fov_rad * 0.5), 0.05) * 1.3, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE)
	_apply_orbit_camera()

func _process(delta: float) -> void:
	_phase += delta
	_pose_preview(delta)

func _load_model_from_ui() -> void:
	var scene_path: String = _path_edit.text.strip_edges()
	var report: Dictionary = _analyzer.analyze_scene_path(scene_path)
	_last_report = report
	_show_report(report)
	_clear_model()
	if report.get("status", "") != "ok":
		_preview_label.text = "No skinned rig available for animation preview"
		return
	if not report.get("preview_ready", false) and not report.get("auto_fit_candidate", false):
		_preview_label.text = "Model loaded, but no humanoid rig candidate was found"
		return
	var scene: Node = _analyzer.load_scene(scene_path)
	if scene == null:
		_status.text = "Import generated no scene"
		return

	_loaded_scene = scene as Node3D
	_model_root.add_child(_loaded_scene)
	_skeleton = _find_largest_skeleton(_loaded_scene)
	if _skeleton == null and report.get("auto_fit_candidate", false):
		_skeleton = _fitter.fit_skeleton(_loaded_scene)
		_status.text = "Auto-fit preview skeleton generated from mesh bounds"
	_fit_loaded_scene()
	_frame_orbit_on_model()
	_cache_skeleton()
	_setup_builtin_animation()
	if report.get("auto_fit_candidate", false) and _skeleton != null:
		_bone_summary.text = "Generated preview  |  Bones %d  |  Primary %s" % [
			_skeleton.get_bone_count(),
			_skeleton.name,
		]
		_finger_summary.text = "Generated finger controls %d  |  Skin weights pending" % _finger_bones.size()
		_quality_label.text = "Rig score 55/100  |  Preview skeleton, skin weights pending"
	if _builtin_animation != "":
		_preview_label.text = "Realtime preview: playing imported clip '%s'" % _builtin_animation
	elif report.get("auto_fit_candidate", false):
		_preview_label.text = "Realtime preview: generated rig + finger curl test"
	else:
		_preview_label.text = "Realtime preview: idle + finger curl test"
	_pose_preview(0.0)

func _auto_bind_from_ui() -> void:
	if _loaded_scene != null and _skeleton == null and _last_report.get("auto_fit_candidate", false):
		_skeleton = _fitter.fit_skeleton(_loaded_scene)
	if _skeleton == null:
		_status.text = "Auto-bind needs a detected or generated skeleton"
		return
	_cache_skeleton()
	_status.text = "Auto-bound toon game rig: %d bones, %d finger controls" % [
		_skeleton.get_bone_count(),
		_finger_bones.size(),
	]
	_pose_preview(0.0)

func _show_report(report: Dictionary) -> void:
	if report.get("status", "") != "ok":
		_status.text = report.get("message", "Analysis failed")
		_bone_summary.text = "Bones: -"
		_finger_summary.text = "Fingers: -"
		_quality_label.text = "Rig score: -"
		return
	_status.text = report.get("message", "Rig analysis complete")
	_bone_summary.text = "Skeletons %d  |  Bones %d  |  Primary %s" % [
		report.get("skeleton_count", 0),
		report.get("bone_count", 0),
		report.get("skeleton_name", ""),
	]
	_finger_summary.text = "Finger bones %d  |  Toon-game ready %s" % [
		report.get("finger_bone_count", 0),
		"yes" if report.get("toon_game_ready", false) else "needs review",
	]
	_quality_label.text = "Rig score %d/100  |  Fingers %s" % [
		report.get("quality_score", 0),
		"complete" if report.get("finger_complete", false) else "incomplete",
	]

func _clear_model() -> void:
	for child in _model_root.get_children():
		child.queue_free()
	_loaded_scene = null
	_skeleton = null
	_anim_player = null
	_builtin_animation = ""
	_finger_bones.clear()
	_overlay_mesh.clear_surfaces()

func _fit_loaded_scene() -> void:
	if _loaded_scene == null:
		return
	# Up-axis correction (for Z-up models) is baked into the model's child
	# geometry by the fitter, so a plain yaw to face the camera is safe here.
	_loaded_scene.rotation = Vector3(0.0, deg_to_rad(180.0), 0.0)
	_loaded_scene.scale = Vector3.ONE
	var aabb: AABB = _calculate_aabb(_loaded_scene)
	if aabb.size.length() <= 0.001:
		return
	var max_axis: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
	if max_axis > 0.0:
		var scale_factor: float = 2.2 / max_axis
		_loaded_scene.scale = Vector3.ONE * scale_factor
		aabb = _calculate_aabb(_loaded_scene)
	# Centre vertically so the whole figure sits in view regardless of pivot.
	_loaded_scene.position = Vector3(0.0, -aabb.position.y - aabb.size.y * 0.5, 0.0)

func _calculate_aabb(root: Node) -> AABB:
	var found := false
	var bounds := AABB()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null:
			continue
		if mesh_instance.mesh == null:
			continue
		var local_aabb: AABB = mesh_instance.mesh.get_aabb()
		var transformed: AABB = mesh_instance.global_transform * local_aabb
		if not found:
			bounds = transformed
			found = true
		else:
			bounds = bounds.merge(transformed)
	return bounds

func _find_largest_skeleton(root: Node) -> Skeleton3D:
	var best: Skeleton3D = null
	for node in root.find_children("*", "Skeleton3D", true, false):
		var skel := node as Skeleton3D
		if best == null or skel.get_bone_count() > best.get_bone_count():
			best = skel
	return best

func _cache_skeleton() -> void:
	_finger_bones.clear()
	if _skeleton == null:
		return
	for i in range(_skeleton.get_bone_count()):
		if _analyzer.is_finger_bone_name(_skeleton.get_bone_name(i)):
			_finger_bones.append(i)

# Detects a model-supplied AnimationPlayer and starts a looping clip if one is
# present, preferring a locomotion-style clip (walk/run/idle) over the first.
func _setup_builtin_animation() -> void:
	_anim_player = null
	_builtin_animation = ""
	if _loaded_scene == null:
		return
	var player := _find_animation_player(_loaded_scene)
	if player == null:
		return
	var clip := _pick_animation(player)
	if clip == "":
		return
	# Loop the clip so the preview keeps cycling rather than stopping on frame 1.
	var anim := player.get_animation(clip)
	if anim != null and anim.loop_mode == Animation.LOOP_NONE:
		anim.loop_mode = Animation.LOOP_LINEAR
	_anim_player = player
	_builtin_animation = clip
	player.play(clip)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null

func _pick_animation(player: AnimationPlayer) -> String:
	var list := player.get_animation_list()
	if list.is_empty():
		return ""
	for preferred in ["walk", "run", "idle"]:
		for clip in list:
			if String(clip).to_lower().find(preferred) != -1:
				return clip
	return list[0]

func _pose_preview(_delta: float) -> void:
	if _skeleton == null:
		return
	# When the model carries its own animation, let the AnimationPlayer own the
	# pose entirely; we only refresh the bone overlay so it tracks the clip.
	if _anim_player != null and _anim_player.is_playing():
		_update_rig_overlay()
		return
	var curl: float = deg_to_rad(float(_finger_slider.value))
	var pose_amount: float = float(_pose_slider.value)
	var walk: float = sin(_phase * 3.0) * pose_amount
	# Reset to the full rest pose (position + rotation), so neutral is exactly
	# rest even if an animation previously moved bones. Offsets below are then
	# applied as pose ROTATION (relative to rest); using the rest basis as the
	# neutral rotation would double-apply on imported rigs with non-identity rest.
	_skeleton.reset_bone_poses()
	for bone_index in _finger_bones:
		var bone_name: String = _skeleton.get_bone_name(bone_index).to_lower()
		var side: float = -1.0 if bone_name.ends_with(".r") or bone_name.find("_r_") != -1 else 1.0
		var twist: float = 0.18 * side if bone_name.find("thumb") != -1 else 0.0
		_skeleton.set_bone_pose_rotation(
			bone_index,
			Quaternion(Vector3.RIGHT, curl) * Quaternion(Vector3.FORWARD, twist)
		)
	_swing_named_bone("DEF-upper_arm.L", walk * 0.35)
	_swing_named_bone("DEF-upper_arm.R", -walk * 0.35)
	_swing_named_bone("DEF-thigh.L", -walk * 0.25)
	_swing_named_bone("DEF-thigh.R", walk * 0.25)
	_swing_named_bone("Toon_UpperArm.L", walk * 0.35)
	_swing_named_bone("Toon_UpperArm.R", -walk * 0.35)
	_swing_named_bone("Toon_UpperLeg.L", -walk * 0.25)
	_swing_named_bone("Toon_UpperLeg.R", walk * 0.25)
	_update_rig_overlay()

func _swing_named_bone(bone_name: String, angle: float) -> void:
	if _skeleton == null:
		return
	var idx: int = _skeleton.find_bone(bone_name)
	if idx == -1:
		return
	# Offset on top of rest; neutral pose is identity (set above this frame).
	_skeleton.set_bone_pose_rotation(idx, Quaternion(Vector3.RIGHT, angle))

func _setup_overlay() -> void:
	_overlay_mesh_instance = MeshInstance3D.new()
	_overlay_mesh_instance.name = "LiveBoneOverlay"
	_overlay_mesh_instance.mesh = _overlay_mesh
	# Lines: unshaded green, drawn over the mesh (no depth test) like a debug rig.
	_line_material = StandardMaterial3D.new()
	_line_material.resource_name = "RigOverlayGreen"
	_line_material.albedo_color = Color(0.15, 1.0, 0.48, 0.95)
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.no_depth_test = true
	# Octahedral: shaded grey solid so the bone cones read as 3D, like Blender.
	# Drawn over the mesh (no depth test) with back-face culling so the rig is
	# visible "in front" of the body like Blender's default bone display.
	_octa_material = StandardMaterial3D.new()
	_octa_material.resource_name = "RigOverlayOcta"
	_octa_material.albedo_color = Color(0.62, 0.62, 0.64)
	_octa_material.cull_mode = BaseMaterial3D.CULL_BACK
	_octa_material.no_depth_test = true
	_octa_material.roughness = 1.0
	# Emission lifts the unlit/back-facing facets toward an even mid-grey so the
	# bones read like Blender's display instead of going near-black at glancing
	# angles. A little real shading remains so adjacent facets stay distinct.
	_octa_material.emission_enabled = true
	_octa_material.emission = Color(0.5, 0.5, 0.52)
	_octa_material.emission_energy_multiplier = 0.55
	_overlay_mesh_instance.material_override = _line_material
	_rig_overlay_root.add_child(_overlay_mesh_instance)

func _on_bone_style_selected(index: int) -> void:
	_bone_style = index
	_overlay_mesh_instance.material_override = _octa_material if _bone_style == BoneStyle.OCTAHEDRAL else _line_material
	_update_rig_overlay()

func _update_rig_overlay() -> void:
	if _skeleton == null or _rig_overlay_root == null:
		return
	# Each entry is [head_local, tail_local] for one bone (parent joint -> joint).
	var segments: Array = _bone_segments_local()
	_overlay_mesh.clear_surfaces()
	if _bone_style == BoneStyle.OCTAHEDRAL:
		_draw_octahedral_bones(segments)
	else:
		_draw_line_bones(segments)

# Collects each bone as a [head, tail] pair in _rig_overlay_root local space.
func _bone_segments_local() -> Array:
	var segments: Array = []
	for i in range(_skeleton.get_bone_count()):
		var parent_index := _skeleton.get_bone_parent(i)
		if parent_index == -1:
			continue
		var parent_origin: Vector3 = _skeleton.get_bone_global_pose(parent_index).origin
		var child_origin: Vector3 = _skeleton.get_bone_global_pose(i).origin
		if parent_origin.is_zero_approx() and child_origin.is_zero_approx():
			parent_origin = _skeleton.get_bone_global_rest(parent_index).origin
			child_origin = _skeleton.get_bone_global_rest(i).origin
		var head: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * parent_origin)
		var tail: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * child_origin)
		segments.append([head, tail])
	return segments

func _draw_line_bones(segments: Array) -> void:
	_overlay_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for seg in segments:
		_overlay_mesh.surface_add_vertex(seg[0])
		_overlay_mesh.surface_add_vertex(seg[1])
	_overlay_mesh.surface_end()

# Draws each bone as Blender's octahedral shape: a double pyramid with a square
# "shoulder" ring near the head, tapering to points at head and tail.
func _draw_octahedral_bones(segments: Array) -> void:
	_overlay_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for seg in segments:
		var head: Vector3 = seg[0]
		var tail: Vector3 = seg[1]
		var axis := tail - head
		var length := axis.length()
		if length < 0.0001:
			continue
		var dir := axis / length
		# Build a basis perpendicular to the bone for the square shoulder ring.
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var side := dir.cross(up).normalized()
		var other := dir.cross(side).normalized()
		var radius := length * 0.1
		var ring_center := head + dir * radius
		# Four shoulder vertices around the ring.
		var r0 := ring_center + side * radius
		var r1 := ring_center + other * radius
		var r2 := ring_center - side * radius
		var r3 := ring_center - other * radius
		# Top pyramid (head -> ring) and bottom pyramid (ring -> tail).
		_octa_tri(head, r0, r1)
		_octa_tri(head, r1, r2)
		_octa_tri(head, r2, r3)
		_octa_tri(head, r3, r0)
		_octa_tri(tail, r1, r0)
		_octa_tri(tail, r2, r1)
		_octa_tri(tail, r3, r2)
		_octa_tri(tail, r0, r3)
	_overlay_mesh.surface_end()

func _octa_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	# Emit a flat-shaded triangle (normal from its own winding) so facets read 3D.
	var n := (b - a).cross(c - a).normalized()
	_overlay_mesh.surface_set_normal(n)
	_overlay_mesh.surface_add_vertex(a)
	_overlay_mesh.surface_set_normal(n)
	_overlay_mesh.surface_add_vertex(b)
	_overlay_mesh.surface_set_normal(n)
	_overlay_mesh.surface_add_vertex(c)
