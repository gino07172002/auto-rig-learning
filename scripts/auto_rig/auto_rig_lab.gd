extends Control
class_name AutoRigLab

const AutoRigAnalyzer = preload("res://scripts/auto_rig/auto_rig_analyzer.gd")
const ToonHumanoidFitter = preload("res://scripts/auto_rig/toon_humanoid_fitter.gd")
const FbxAnimation = preload("res://scripts/auto_rig/fbx_animation.gd")
const RecentFiles = preload("res://scripts/auto_rig/recent_files.gd")
const PoseDetector = preload("res://scripts/auto_rig/pose_detector.gd")

@onready var _path_edit: LineEdit = find_child("ModelPathEdit", true, false)
@onready var _browse_button: Button = find_child("BrowseModelButton", true, false)
@onready var _load_button: Button = find_child("LoadModelButton", true, false)
@onready var _auto_button: Button = find_child("AutoBindButton", true, false)
@onready var _detect_button: Button = find_child("DetectJointsButton", true, false)
@onready var _detect_ai_button: Button = find_child("DetectJointsAiButton", true, false)
@onready var _confirm_bind_button: Button = find_child("ConfirmBindButton", true, false)
@onready var _detection_report: Label = find_child("DetectionReportLabel", true, false)
@onready var _symmetric_joints_check: CheckBox = find_child("SymmetricJointsCheck", true, false)
@onready var _export_button: Button = find_child("ExportGlbButton", true, false)
@onready var _load_anim_button: Button = find_child("LoadAnimationButton", true, false)
@onready var _recent_model_option: OptionButton = find_child("RecentModelOption", true, false)
@onready var _recent_anim_option: OptionButton = find_child("RecentAnimationOption", true, false)
@onready var _status: Label = find_child("StatusLabel", true, false)
@onready var _bone_summary: Label = find_child("BoneSummaryLabel", true, false)
@onready var _finger_summary: Label = find_child("FingerSummaryLabel", true, false)
@onready var _quality_label: Label = find_child("RigQualityLabel", true, false)
@onready var _shoulder_scale_slider: HSlider = find_child("ShoulderScaleSlider", true, false)
@onready var _arm_scale_slider: HSlider = find_child("ArmScaleSlider", true, false)
@onready var _leg_scale_slider: HSlider = find_child("LegScaleSlider", true, false)
@onready var _finger_slider: HSlider = find_child("FingerCurlSlider", true, false)
@onready var _pose_slider: HSlider = find_child("PoseIntensitySlider", true, false)
@onready var _viewport: SubViewport = find_child("PreviewViewport", true, false)
@onready var _model_root: Node3D = find_child("ModelRoot", true, false)
@onready var _rig_overlay_root: Node3D = find_child("RigOverlayRoot", true, false)
@onready var _preview_label: Label = find_child("PreviewStateLabel", true, false)
@onready var _preview_container: SubViewportContainer = find_child("PreviewViewportContainer", true, false)
@onready var _camera: Camera3D = find_child("Camera3D", true, false)
@onready var _bone_style_option: OptionButton = find_child("BoneStyleOption", true, false)
@onready var _rig_mode_option: OptionButton = find_child("RigModeOption", true, false)
@onready var _naming_option: OptionButton = find_child("NamingOption", true, false)
@onready var _skin_method_option: OptionButton = find_child("SkinMethodOption", true, false)
@onready var _show_names_check: CheckBox = find_child("ShowNamesCheck", true, false)
@onready var _textured_check: CheckBox = find_child("TexturedCheck", true, false)
@onready var _loop_check: CheckBox = find_child("LoopCheck", true, false)
@onready var _coord_option: OptionButton = find_child("CoordOption", true, false)
@onready var _selected_bone_label: Label = find_child("SelectedBoneLabel", true, false)
@onready var _animation_play_pause_button: Button = find_child("AnimationPlayPauseButton", true, false)
@onready var _animation_timeline_slider: HSlider = find_child("AnimationTimelineSlider", true, false)
@onready var _animation_current_time_label: Label = find_child("AnimationCurrentTimeLabel", true, false)
@onready var _animation_duration_label: Label = find_child("AnimationDurationLabel", true, false)

# Bone overlay display styles, selectable in the preview toolbar.
enum BoneStyle { LINES, OCTAHEDRAL }
var _bone_style: int = BoneStyle.LINES
# When true, the per-frame preview must NOT draw the bone overlay — used while we
# capture a clean frame for AI pose detection (green rig lines break BlazePose).
var _suppress_bone_overlay: bool = false

# Which rig source is active for preview/export.
enum RigMode { IMPORTED, NONE, GENERATED }
var _rig_mode: int = RigMode.IMPORTED

# Static test poses. IDLE = the procedural walk/finger preview (default).
enum PoseMode { IDLE, TPOSE, APOSE, WAVE, CROUCH }
var _pose_mode: int = PoseMode.IDLE

# Source coordinate-system presets for imported models. Different DCC tools/engines
# orient characters differently; the chosen preset sets the base rotation applied
# to the loaded model so it stands upright and faces the camera.
#   AUTO       - keep the importer's own orientation + a 180 yaw to face front
#                (works for glTF/FBX that already import Y-up facing away).
#   Y_UP_GLTF  - Y-up, +Z forward (glTF/VRM authoring): face the camera (180 yaw).
#   Z_UP       - Z-up (some Blender/3ds Max exports): rotate -90 X to stand upright.
#   VRM_FORWARD- Y-up but already facing the camera (+Z toward viewer): no yaw flip.
enum CoordSystem { AUTO, Y_UP_GLTF, Z_UP, VRM_FORWARD }
var _coord_system: int = CoordSystem.AUTO

var _analyzer := AutoRigAnalyzer.new()
var _fitter := ToonHumanoidFitter.new()
var _loaded_scene: Node3D
var _skeleton: Skeleton3D
var _last_report: Dictionary = {}
var _overlay_mesh_instance: MeshInstance3D
var _overlay_mesh := ImmediateMesh.new()
var _line_material: StandardMaterial3D
var _octa_material: StandardMaterial3D
var _bone_labels: Array[Label3D] = []
var _show_bone_names: bool = false
var _selected_bone: int = -1
var _highlight_material: StandardMaterial3D
var _highlight_mesh := ImmediateMesh.new()
var _highlight_instance: MeshInstance3D
# Tracks where a left-press started so we can tell a click (select) from a drag.
var _left_press_pos := Vector2.ZERO
var _left_moved := false
var _phase := 0.0
var _finger_bones: Array[int] = []

# --- Interactive joint review/editing (Detect -> adjust -> Confirm & Bind) ----
# When true, the preview shows draggable joint markers for the user to correct
# before binding, instead of a live skeleton. Joints are stored in _loaded_scene
# LOCAL space (what the fitter measures/consumes).
var _editing_joints := false
var _joint_points: Dictionary = {}        # logical key -> Vector3 (scene-local)
var _joint_measured: Dictionary = {}       # logical key -> bool
var _joint_marker_mesh := SphereMesh.new()
var _joint_markers: Dictionary = {}        # key -> MeshInstance3D under overlay
var _joint_labels: Dictionary = {}         # key -> Label3D
var _selected_joint := ""                  # key currently grabbed for dragging
var _joint_marker_mat_selected: StandardMaterial3D
var _joint_legend: Control = null          # bottom-left color legend during joint review
var _symmetric_joints := true
# When the imported model ships its own AnimationPlayer (e.g. a Blender-authored
# Walk clip), we let it drive the skeleton instead of the procedural preview.
var _anim_player: AnimationPlayer = null
var _builtin_animation := ""
# AnimationPlayer created when the user retargets an external animation FBX onto
# the loaded character's skeleton (separate from a model's own _anim_player).
var _retarget_player: AnimationPlayer = null
var _animation_paused := false
var _timeline_dragging := false
var _anim_dialog: FileDialog = null
var _file_dialog: FileDialog = null
# Persisted "recently opened" model + animation paths, for quick reload.
var _recent := RecentFiles.new()
const RECENT_MODEL := "model"
const RECENT_ANIM := "anim"
var _save_dialog: FileDialog = null
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
	_fit_window_to_screen()
	_setup_overlay()
	_load_button.pressed.connect(_load_model_from_ui)
	_auto_button.pressed.connect(_auto_bind_from_ui)
	if _detect_button != null:
		_detect_button.pressed.connect(_on_detect_joints)
	if _detect_ai_button != null:
		_detect_ai_button.pressed.connect(_on_detect_joints_ai)
	if _confirm_bind_button != null:
		_confirm_bind_button.pressed.connect(_on_confirm_bind)
	if _symmetric_joints_check != null:
		_symmetric_joints_check.button_pressed = _symmetric_joints
		_symmetric_joints_check.toggled.connect(_on_symmetric_joints_toggled)
	_setup_joint_marker_materials()
	_setup_file_dialog()
	_setup_save_dialog()
	if _browse_button != null:
		_browse_button.pressed.connect(_open_file_dialog)
	if _export_button != null:
		_export_button.pressed.connect(_open_export_dialog)
	if _load_anim_button != null:
		_load_anim_button.pressed.connect(_open_animation_dialog)
	_setup_animation_dialog()
	if _recent_model_option != null:
		_recent_model_option.item_selected.connect(_on_recent_model_selected)
	if _recent_anim_option != null:
		_recent_anim_option.item_selected.connect(_on_recent_animation_selected)
	_refresh_recent_dropdowns()
	_finger_slider.value_changed.connect(func(_v): _pose_preview(0.0))
	_pose_slider.value_changed.connect(func(_v): _pose_preview(0.0))
	if _bone_style_option != null:
		_bone_style_option.clear()
		_bone_style_option.add_item("Lines", BoneStyle.LINES)
		_bone_style_option.add_item("Octahedral (Blender)", BoneStyle.OCTAHEDRAL)
		_bone_style_option.selected = _bone_style
		_bone_style_option.item_selected.connect(_on_bone_style_selected)
	if _rig_mode_option != null:
		_rig_mode_option.clear()
		_rig_mode_option.add_item("Use imported skeleton", RigMode.IMPORTED)
		_rig_mode_option.add_item("No skeleton", RigMode.NONE)
		_rig_mode_option.add_item("Generated Toon skeleton", RigMode.GENERATED)
		_rig_mode_option.selected = _rig_mode
		_rig_mode_option.item_selected.connect(_on_rig_mode_selected)
	if _naming_option != null:
		_naming_option.clear()
		_naming_option.add_item("Toon", ToonHumanoidFitter.Naming.TOON)
		_naming_option.add_item("Blender / Rigify", ToonHumanoidFitter.Naming.BLENDER)
		_naming_option.selected = _fitter.naming
		# Re-fit the current model so the new naming takes effect immediately.
		_naming_option.item_selected.connect(_on_naming_selected)
	if _skin_method_option != null:
		_skin_method_option.clear()
		_skin_method_option.add_item("Proximity (fast)", ToonHumanoidFitter.SkinMethod.PROXIMITY)
		_skin_method_option.add_item("Heat diffusion (cleaner)", ToonHumanoidFitter.SkinMethod.HEAT_DIFFUSION)
		_skin_method_option.selected = _fitter.skin_method
		_skin_method_option.item_selected.connect(_on_skin_method_selected)
		# Clarify scope: this affects BINDING (mesh deformation), not joint detection.
		# Detected joint markers look identical under both methods — the difference
		# only shows after Confirm & Bind, when the mesh deforms in a pose.
		_skin_method_option.tooltip_text = "Skin-weight algorithm used when binding (Confirm & Bind).\nDoes not change detected joint positions — the difference\nis only visible after binding, when the mesh deforms in a pose."
	for s in [_shoulder_scale_slider, _arm_scale_slider, _leg_scale_slider]:
		if s != null:
			s.value_changed.connect(func(_v): _on_proportion_changed())
	if _show_names_check != null:
		_show_names_check.toggled.connect(_on_show_names_toggled)
	if _textured_check != null:
		_textured_check.toggled.connect(_on_textured_toggled)
	if _loop_check != null:
		_loop_check.toggled.connect(_on_loop_toggled)
	if _animation_play_pause_button != null:
		_animation_play_pause_button.pressed.connect(_on_animation_play_pause_pressed)
	if _animation_timeline_slider != null:
		_animation_timeline_slider.value_changed.connect(_on_animation_timeline_value_changed)
		_animation_timeline_slider.drag_started.connect(_on_animation_timeline_drag_started)
		_animation_timeline_slider.drag_ended.connect(_on_animation_timeline_drag_ended)
	if _coord_option != null:
		_coord_option.clear()
		_coord_option.add_item("Auto", CoordSystem.AUTO)
		_coord_option.add_item("Y-up (glTF/VRM)", CoordSystem.Y_UP_GLTF)
		_coord_option.add_item("Z-up (Blender/Max)", CoordSystem.Z_UP)
		_coord_option.add_item("VRM (faces camera)", CoordSystem.VRM_FORWARD)
		_coord_option.selected = _coord_system
		_coord_option.item_selected.connect(_on_coord_selected)
	_connect_view_button("ViewRecenter", "recenter")
	_connect_view_button("ViewFront", "front")
	_connect_view_button("ViewBack", "back")
	_connect_view_button("ViewLeft", "left")
	_connect_view_button("ViewRight", "right")
	_connect_view_button("ViewTop", "top")
	_connect_pose_button("PoseIdle", PoseMode.IDLE)
	_connect_pose_button("PoseTPose", PoseMode.TPOSE)
	_connect_pose_button("PoseAPose", PoseMode.APOSE)
	_connect_pose_button("PoseWave", PoseMode.WAVE)
	_connect_pose_button("PoseCrouch", PoseMode.CROUCH)
	# Drag/zoom the preview: route the container's mouse events to the orbit cam.
	if _preview_container != null:
		_preview_container.gui_input.connect(_on_preview_gui_input)
	_apply_orbit_camera()
	_sync_animation_timeline(true)
	# Defer so the tree finishes setting up before the restore loads a model and
	# (via the official FBX path) temporarily adds a helper scene to the tree.
	_restore_last_session.call_deferred()

# On startup, reload the most-recently used model (and re-apply the last animation
# if one is recorded), so reopening the app returns to where the user left off.
# Falls back to the scene's default model path when there's no recent model.
func _restore_last_session() -> void:
	var recent_models := _recent.get_recent(RECENT_MODEL)
	if recent_models.size() > 0:
		_path_edit.text = recent_models[0]
	_load_model_from_ui()
	# If a skeleton came up and we have a recent animation, replay it.
	if _skeleton != null:
		var recent_anims := _recent.get_recent(RECENT_ANIM)
		if recent_anims.size() > 0:
			_on_animation_file_selected(recent_anims[0])

# Ensures the window fits the usable screen and is centred. On small or DPI-scaled
# desktops the 1280x720 window can spill off-screen (left panel labels get clipped),
# so clamp the window to the screen's usable area, then centre it.
func _fit_window_to_screen() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var win := DisplayServer.window_get_size()
	var target := Vector2i(mini(win.x, usable.size.x - 16), mini(win.y, usable.size.y - 48))
	if target != win:
		DisplayServer.window_set_size(target)
	# Centre within the usable area.
	var pos := usable.position + (usable.size - DisplayServer.window_get_size()) / 2
	DisplayServer.window_set_position(Vector2i(maxi(pos.x, usable.position.x), maxi(pos.y, usable.position.y)))

# Builds the "Browse..." file picker. Uses the OS-native dialog when available
# and filters to glTF model files, with full filesystem access so external
# models (outside res://) can be picked too.
func _setup_file_dialog() -> void:
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Select a 3D model"
	# Only the supported-model filter; it becomes the dialog default. The native OS
	# dialog already provides its own "All Files" entry, so adding our own "*" here
	# just duplicated it — omit it. FBX (Mixamo/Adobe) is read natively, glTF directly.
	_file_dialog.add_filter("*.glb,*.gltf,*.fbx", "3D models (glTF / FBX)")
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

# Picker for an animation FBX to retarget onto the loaded character's skeleton.
func _setup_animation_dialog() -> void:
	_anim_dialog = FileDialog.new()
	_anim_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_anim_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_anim_dialog.use_native_dialog = true
	_anim_dialog.title = "Select an animation FBX (same skeleton)"
	_anim_dialog.add_filter("*.fbx", "FBX animation")
	_anim_dialog.file_selected.connect(_on_animation_file_selected)
	add_child(_anim_dialog)

func _open_animation_dialog() -> void:
	if _anim_dialog == null:
		return
	if _skeleton == null:
		_status.text = "Load a rigged/generated character first, then load an animation onto it"
		return
	var current := _path_edit.text.strip_edges()
	if current != "":
		var dir := _to_dir(current)
		if dir != "":
			_anim_dialog.current_dir = dir
	_anim_dialog.popup_centered_ratio(0.6)

# Parses the chosen FBX's animation and retargets it onto the current skeleton by
# bone name (both are Mixamo skeletons, so names match). Creates/replaces an
# AnimationPlayer parented next to the skeleton and plays the clip looping.
func _on_animation_file_selected(path: String) -> void:
	if _skeleton == null:
		_status.text = "No skeleton to animate"
		return
	var fa := FbxAnimation.new()
	var anim: Animation = fa.parse_animation(path, _skeleton.name, _skeleton)
	if anim == null:
		_status.text = "Could not read animation: %s" % fa.error
		return
	# A generated (Toon/Blender) rig has different bone names than the Mixamo
	# animation; remap track paths onto the target skeleton's bones so a bound rig
	# can still play the clip. Imported Mixamo rigs already match (remap is a no-op).
	_retarget_anim_to_skeleton(anim)
	# How many of the animation's tracks actually hit a bone on this skeleton?
	var matched := _count_matching_tracks(anim)
	if matched == 0:
		_status.text = "Animation has no bones matching this skeleton (different rig?)"
		return

	# Replace any previous retarget player.
	if _retarget_player != null and is_instance_valid(_retarget_player):
		_retarget_player.queue_free()
	# Stop a model's own clip so the two don't fight over the pose.
	if _anim_player != null and is_instance_valid(_anim_player):
		_anim_player.stop()
	_anim_player = null
	_builtin_animation = ""

	var player := AnimationPlayer.new()
	player.name = "RetargetAnimationPlayer"
	# Parent next to the skeleton so the animation track paths ("Skeleton3D:bone")
	# resolve relative to the player's parent.
	_skeleton.get_parent().add_child(player)
	var lib := AnimationLibrary.new()
	lib.add_animation("retarget", anim)
	player.add_animation_library("", lib)
	# Root path so "Skeleton3D:bone" is found from the player's parent.
	player.root_node = player.get_path_to(_skeleton.get_parent())
	_retarget_player = player
	_anim_player = player
	_builtin_animation = "retarget"
	player.play("retarget")
	_set_animation_paused(false)
	_apply_loop_mode()
	_sync_animation_timeline(true)
	_update_pose_controls_enabled()
	_status.text = "Playing retargeted animation '%s' (%d/%d tracks matched, %.2fs)" % [
		path.get_file(), matched, anim.get_track_count(), anim.length,
	]
	_preview_label.text = "Realtime preview: retargeted animation"
	_recent.add(RECENT_ANIM, path)
	_refresh_recent_dropdowns()

# --- Recent files (quick reload) ---------------------------------------------

# Rebuilds both recent dropdowns from the persisted lists. Item 0 is a static
# header ("Recent model..."), so a real entry is index >= 1; the path is stored as
# item metadata. Dead files are already pruned by RecentFiles.get_recent().
func _refresh_recent_dropdowns() -> void:
	_populate_recent(_recent_model_option, RECENT_MODEL, "Recent model...")
	_populate_recent(_recent_anim_option, RECENT_ANIM, "Recent animation...")

func _populate_recent(option: OptionButton, category: String, header: String) -> void:
	if option == null:
		return
	option.clear()
	option.add_item(header)            # index 0: placeholder header, not selectable as a load
	option.set_item_disabled(0, true)
	for p in _recent.get_recent(category):
		var idx := option.item_count
		option.add_item(p.get_file())  # show just the filename to keep it short
		option.set_item_metadata(idx, p)
		option.set_item_tooltip(idx, p)
	option.selected = 0

func _on_recent_model_selected(index: int) -> void:
	if index <= 0 or _recent_model_option == null:
		return
	var path: String = _recent_model_option.get_item_metadata(index)
	if path == null or String(path) == "":
		return
	_path_edit.text = path
	_load_model_from_ui()

func _on_recent_animation_selected(index: int) -> void:
	if index <= 0 or _recent_anim_option == null:
		return
	if _skeleton == null:
		_status.text = "Load a character first, then pick a recent animation"
		_recent_anim_option.selected = 0
		return
	var path: String = _recent_anim_option.get_item_metadata(index)
	if path == null or String(path) == "":
		return
	_on_animation_file_selected(path)

# Counts how many of the animation's tracks reference a bone present on the
# loaded skeleton (so we can warn when the rigs don't match).
func _count_matching_tracks(anim: Animation) -> int:
	var matched := 0
	for i in range(anim.get_track_count()):
		var p := String(anim.track_get_path(i))
		var bone := p.get_slice(":", 1)
		if bone != "" and _skeleton.find_bone(bone) != -1:
			matched += 1
	return matched

# Maps Mixamo bone names (mixamorig_*) to the body bones of a GENERATED rig
# (Toon_* or Blender/Rigify names), so a bound generated rig can play a Mixamo
# clip. Only the core body chain is mapped (the generated rig's fingers don't
# match Mixamo's 1:1); unmapped tracks are simply dropped.
const _MIXAMO_TO_TOON := {
	"mixamorig_Hips": "Toon_Hips", "mixamorig_Spine": "Toon_Spine",
	"mixamorig_Spine2": "Toon_Chest", "mixamorig_Neck": "Toon_Neck", "mixamorig_Head": "Toon_Head",
	"mixamorig_LeftShoulder": "Toon_Shoulder.L", "mixamorig_LeftArm": "Toon_UpperArm.L",
	"mixamorig_LeftForeArm": "Toon_LowerArm.L", "mixamorig_LeftHand": "Toon_Hand.L",
	"mixamorig_RightShoulder": "Toon_Shoulder.R", "mixamorig_RightArm": "Toon_UpperArm.R",
	"mixamorig_RightForeArm": "Toon_LowerArm.R", "mixamorig_RightHand": "Toon_Hand.R",
	"mixamorig_LeftUpLeg": "Toon_UpperLeg.L", "mixamorig_LeftLeg": "Toon_LowerLeg.L", "mixamorig_LeftFoot": "Toon_Foot.L",
	"mixamorig_RightUpLeg": "Toon_UpperLeg.R", "mixamorig_RightLeg": "Toon_LowerLeg.R", "mixamorig_RightFoot": "Toon_Foot.R",
}
const _MIXAMO_TO_BLENDER := {
	"mixamorig_Hips": "spine", "mixamorig_Spine": "spine.001",
	"mixamorig_Spine2": "spine.002", "mixamorig_Neck": "neck", "mixamorig_Head": "head",
	"mixamorig_LeftShoulder": "shoulder.L", "mixamorig_LeftArm": "upper_arm.L",
	"mixamorig_LeftForeArm": "forearm.L", "mixamorig_LeftHand": "hand.L",
	"mixamorig_RightShoulder": "shoulder.R", "mixamorig_RightArm": "upper_arm.R",
	"mixamorig_RightForeArm": "forearm.R", "mixamorig_RightHand": "hand.R",
	"mixamorig_LeftUpLeg": "thigh.L", "mixamorig_LeftLeg": "shin.L", "mixamorig_LeftFoot": "foot.L",
	"mixamorig_RightUpLeg": "thigh.R", "mixamorig_RightLeg": "shin.R", "mixamorig_RightFoot": "foot.R",
}

# Rewrites the animation's track paths so they target the loaded skeleton's bones.
# No-op when the skeleton already uses the animation's names (imported Mixamo rig).
# For a generated rig, maps mixamorig_* -> Toon_*/Blender names and drops tracks
# with no mapped bone.
func _retarget_anim_to_skeleton(anim: Animation) -> void:
	if _skeleton == null:
		return
	# If the first animated bone already exists on the skeleton, names match — done.
	for i in range(anim.get_track_count()):
		var bone := String(anim.track_get_path(i)).get_slice(":", 1)
		if bone != "":
			if _skeleton.find_bone(bone) != -1:
				return  # names already match (imported rig)
			break
	# Pick the mapping by what the skeleton actually has.
	var map: Dictionary = {}
	if _skeleton.find_bone("Toon_Hips") != -1:
		map = _MIXAMO_TO_TOON
	elif _skeleton.find_bone("spine") != -1:
		map = _MIXAMO_TO_BLENDER
	else:
		return  # unknown rig naming; leave as-is (will report 0 matches)
	# Remap each track path; remove tracks whose bone has no mapping. Iterate
	# backwards so removals don't shift indices.
	for i in range(anim.get_track_count() - 1, -1, -1):
		var p := String(anim.track_get_path(i))
		var prefix := p.get_slice(":", 0)
		var bone := p.get_slice(":", 1)
		if map.has(bone):
			anim.track_set_path(i, NodePath("%s:%s" % [prefix, map[bone]]))
		else:
			anim.remove_track(i)

func _on_model_file_selected(path: String) -> void:
	_path_edit.text = path
	_load_model_from_ui()

# Save dialog for exporting the rigged model to a portable .glb.
func _setup_save_dialog() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.use_native_dialog = true
	_save_dialog.title = "Export rigged model as glTF"
	_save_dialog.add_filter("*.glb", "glTF binary")
	_save_dialog.file_selected.connect(_on_export_path_selected)
	add_child(_save_dialog)

func _open_export_dialog() -> void:
	if _loaded_scene == null:
		_status.text = "Nothing to export: load a model first"
		return
	# Suggest a filename based on the loaded model.
	var base := _path_edit.text.get_file().get_basename()
	if base == "":
		base = "rigged_model"
	_save_dialog.current_file = "%s_rigged.glb" % base
	_save_dialog.popup_centered_ratio(0.6)

func _on_export_path_selected(path: String) -> void:
	if not path.to_lower().ends_with(".glb"):
		path += ".glb"
	var err: int = _fitter.export_to_glb(_loaded_scene, path)
	if err == OK:
		_status.text = "Exported rigged GLB to %s" % path
	else:
		_status.text = "Export failed (error %d)" % err

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
				if mb.pressed and _editing_joints:
					# In joint-edit mode, grabbing a marker drags it instead of orbiting.
					var hit := _joint_at(mb.position)
					if hit != "":
						_selected_joint = hit
						_refresh_joint_marker_colors()
						return
				_orbit_dragging = mb.pressed
				if mb.pressed:
					_left_press_pos = mb.position
					_left_moved = false
				else:
					if _selected_joint != "":
						# Finished dragging a joint marker.
						_selected_joint = ""
						_refresh_joint_marker_colors()
					elif not _left_moved and not _editing_joints:
						# Released without dragging => treat as a click to select a bone.
						_select_bone_at(mb.position)
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
		if _selected_joint != "":
			_drag_joint(_selected_joint, mm.position)
		elif _orbit_dragging:
			if mm.position.distance_to(_left_press_pos) > 4.0:
				_left_moved = true
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

# Snaps the orbit camera to a named axis-aligned view (Blender numpad-style), or
# recenters/refits on the model. The loaded model is yawed 180 to face the camera,
# so "Front" looks at the figure's face (camera on the model's front, -Z side).
func _set_view(view: String) -> void:
	match view:
		"recenter":
			_frame_orbit_on_model()
			return
		"front":
			_orbit_yaw = 0.0
			_orbit_pitch = 0.0
		"back":
			_orbit_yaw = PI
			_orbit_pitch = 0.0
		"left":
			_orbit_yaw = -PI / 2.0
			_orbit_pitch = 0.0
		"right":
			_orbit_yaw = PI / 2.0
			_orbit_pitch = 0.0
		"top":
			_orbit_yaw = 0.0
			_orbit_pitch = ORBIT_PITCH_LIMIT
	_apply_orbit_camera()

func _connect_view_button(node_name: String, view: String) -> void:
	var btn: Button = find_child(node_name, true, false)
	if btn != null:
		btn.pressed.connect(func(): _set_view(view))

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
	_sync_animation_timeline(false)

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
	# Remember real external files (not the bundled res:// default) for quick reload.
	if not scene_path.begins_with("res://"):
		_recent.add(RECENT_MODEL, scene_path)
		_refresh_recent_dropdowns()
	_apply_rig_mode_to_loaded_scene(report)
	_fit_loaded_scene()
	_frame_orbit_on_model()
	_cache_skeleton()
	_rebuild_bone_labels()
	_setup_builtin_animation()
	_update_pose_controls_enabled()
	_show_active_mode_summary(report)
	_apply_textured_state()
	if _builtin_animation != "":
		_preview_label.text = "Realtime preview: playing imported clip '%s'" % _builtin_animation
	elif _is_generated_active():
		_preview_label.text = "Realtime preview: generated rig + finger curl test"
	elif _rig_mode == RigMode.NONE:
		_preview_label.text = "Realtime preview: mesh only"
	else:
		_preview_label.text = "Realtime preview: idle + finger curl test"
	_pose_preview(0.0)

func _auto_bind_from_ui() -> void:
	if _rig_mode != RigMode.GENERATED:
		_rig_mode = RigMode.GENERATED
		if _rig_mode_option != null:
			_rig_mode_option.selected = RigMode.GENERATED
		_load_model_from_ui()
		return
	if _loaded_scene != null and not _is_generated_active():
		_apply_rig_mode_to_loaded_scene(_last_report)
	if _skeleton == null:
		_status.text = "Auto-bind needs a detected or generated skeleton"
		return
	_cache_skeleton()
	_rebuild_bone_labels()
	_setup_builtin_animation()
	_update_pose_controls_enabled()
	_status.text = "Auto-bound toon game rig: %d bones, %d finger controls" % [
		_skeleton.get_bone_count(),
		_finger_bones.size(),
	]
	_pose_preview(0.0)

func _apply_rig_mode_to_loaded_scene(report: Dictionary) -> void:
	_skeleton = null
	match _rig_mode:
		RigMode.NONE:
			_strip_skeletons_for_mesh_only(_loaded_scene)
			_status.text = "Loaded mesh without an active skeleton"
		RigMode.GENERATED:
			_apply_proportions_to_fitter()
			_skeleton = _fitter.fit_skeleton(_loaded_scene)
			if _skeleton != null:
				_remove_other_skeletons(_loaded_scene, _skeleton)
				_status.text = "Auto-bound toon game rig: %d bones, %d finger controls" % [
					_skeleton.get_bone_count(),
					_count_finger_bones(_skeleton),
				]
			else:
				_status.text = "Auto-bind needs mesh geometry"
		_:
			_skeleton = _find_largest_skeleton(_loaded_scene)
			if _skeleton == null and report.get("auto_fit_candidate", false):
				_apply_proportions_to_fitter()
				_skeleton = _fitter.fit_skeleton(_loaded_scene)
				_status.text = "Auto-fit preview skeleton generated from mesh bounds"

func _show_active_mode_summary(report: Dictionary) -> void:
	if _rig_mode == RigMode.NONE:
		_bone_summary.text = "Rig mode No skeleton  |  Meshes %d" % _mesh_count(_loaded_scene)
		_finger_summary.text = "Finger controls disabled"
		_quality_label.text = "Rig score -  |  Mesh export only"
		return
	if _is_generated_active():
		_bone_summary.text = "Generated Toon  |  Bones %d  |  Primary %s" % [
			_skeleton.get_bone_count(),
			_skeleton.name,
		]
		_finger_summary.text = "Generated finger controls %d" % _finger_bones.size()
		_quality_label.text = "Rig score 55/100  |  Generated skeleton"
		return
	if _skeleton != null:
		_show_report(report)

func _is_generated_active() -> bool:
	return _skeleton != null and _skeleton.name == "GeneratedToonHumanoidSkeleton"

func _count_finger_bones(skel: Skeleton3D) -> int:
	var count := 0
	for i in range(skel.get_bone_count()):
		if _analyzer.is_finger_bone_name(skel.get_bone_name(i)):
			count += 1
	return count

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
	_clear_bone_labels()
	if _retarget_player != null and is_instance_valid(_retarget_player):
		_retarget_player.queue_free()
	_retarget_player = null
	_loaded_scene = null
	_skeleton = null
	_anim_player = null
	_builtin_animation = ""
	_animation_paused = false
	_timeline_dragging = false
	_finger_bones.clear()
	_overlay_mesh.clear_surfaces()
	_highlight_mesh.clear_surfaces()
	_set_selected_bone(-1)
	_pose_mode = PoseMode.IDLE
	_cancel_joint_editing()
	_sync_animation_timeline(true)

# Tears down any in-progress joint review (markers, state) e.g. on reload.
func _cancel_joint_editing() -> void:
	_editing_joints = false
	_selected_joint = ""
	_clear_joint_markers()
	_set_joint_legend_visible(false)
	_joint_points.clear()
	_joint_measured.clear()
	if _confirm_bind_button != null:
		_confirm_bind_button.disabled = true
	if _detection_report != null:
		_detection_report.text = "Detected parts: -"

func _clear_bone_labels() -> void:
	for label in _bone_labels:
		if is_instance_valid(label):
			label.queue_free()
	_bone_labels.clear()

func _on_show_names_toggled(pressed: bool) -> void:
	_show_bone_names = pressed
	_rebuild_bone_labels()

func _on_textured_toggled(_pressed: bool) -> void:
	_apply_textured_state()

# Shows or hides the model's textures per the "Textured" checkbox. When off, each
# mesh surface is overridden with a plain matte material so the geometry reads
# clearly (handy for inspecting the silhouette / rig); when on, the override is
# cleared so the imported textured material shows again. No re-import needed.
func _apply_textured_state() -> void:
	if _loaded_scene == null:
		return
	var textured := _textured_check == null or _textured_check.button_pressed
	for node in _loaded_scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		if textured:
			mi.material_override = null
		else:
			mi.material_override = _untextured_material()

# Lazily builds the shared matte material used when textures are toggled off.
var _untextured_mat: StandardMaterial3D = null
func _untextured_material() -> StandardMaterial3D:
	if _untextured_mat == null:
		_untextured_mat = StandardMaterial3D.new()
		_untextured_mat.albedo_color = Color(0.8, 0.8, 0.82)
		_untextured_mat.roughness = 0.9
		# Double-sided like the textured material, so thin single-sided shells
		# (hair, eyelashes) don't look "see-through" / inside-out when textures off.
		_untextured_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _untextured_mat

# --- Interactive joint detection / editing -----------------------------------

# Joint markers are colored by body region (like Blender bone groups) so the user
# can read the rig at a glance; a legend in the preview's bottom-left names them.
# "Selected" overrides to bright yellow while dragging.
const _REGION_COLORS := {
	"spine": Color(0.55, 0.8, 1.0),     # torso/head — light blue
	"arm.L": Color(0.3, 0.95, 0.5),     # left arm  — green
	"arm.R": Color(1.0, 0.5, 0.45),     # right arm — red/coral
	"leg.L": Color(1.0, 0.85, 0.3),     # left leg  — yellow
	"leg.R": Color(0.8, 0.55, 1.0),     # right leg — purple
}
const _REGION_LABELS := {
	"spine": "Spine / Head", "arm.L": "Left arm", "arm.R": "Right arm",
	"leg.L": "Left leg", "leg.R": "Right leg",
}
var _region_mats := {}                  # region -> StandardMaterial3D

func _setup_joint_marker_materials() -> void:
	_joint_marker_mesh.radius = 0.03
	_joint_marker_mesh.height = 0.06
	for region in _REGION_COLORS:
		_region_mats[region] = _make_marker_mat(_REGION_COLORS[region])
	_joint_marker_mat_selected = _make_marker_mat(Color(1.0, 0.95, 0.2)) # grabbed (yellow)

func _make_marker_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true  # always visible, even inside the mesh
	return m

# Builds (once) and toggles the bottom-left color legend shown during joint review.
func _set_joint_legend_visible(visible: bool) -> void:
	if visible and _joint_legend == null:
		_joint_legend = _build_joint_legend()
	if _joint_legend != null:
		_joint_legend.visible = visible

# A small panel in the preview's bottom-left listing each region's color + name.
func _build_joint_legend() -> Control:
	if _preview_container == null:
		return null
	var panel := PanelContainer.new()
	panel.name = "JointLegend"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # don't block orbit drags
	# Anchor to the container's bottom-left with a small margin.
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.position = Vector2(8, -8)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "Joint regions"
	vbox.add_child(title)
	for region in _REGION_COLORS:
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swatch := ColorRect.new()
		swatch.color = _REGION_COLORS[region]
		swatch.custom_minimum_size = Vector2(16, 16)
		row.add_child(swatch)
		var lbl := Label.new()
		lbl.text = "  " + _REGION_LABELS[region]
		row.add_child(lbl)
		vbox.add_child(row)
	_preview_container.add_child(panel)
	return panel

# Classifies a joint key into a body region for color coding.
func _joint_region(key: String) -> String:
	var k := key.to_lower()
	if k.ends_with(".l") and ("arm" in k or "hand" in k or "shoulder" in k):
		return "arm.L"
	if k.ends_with(".r") and ("arm" in k or "hand" in k or "shoulder" in k):
		return "arm.R"
	if k.ends_with(".l") and ("leg" in k or "foot" in k):
		return "leg.L"
	if k.ends_with(".r") and ("leg" in k or "foot" in k):
		return "leg.R"
	return "spine"

# "Detect Joints" pressed: measure the key joints from the mesh and show them as
# draggable markers for review, WITHOUT building a skeleton yet.
func _on_detect_joints() -> void:
	if _loaded_scene == null:
		_status.text = "Load a model first"
		return
	_apply_proportions_to_fitter()
	var res: Dictionary = _fitter.detect_joint_points(_loaded_scene)
	if res.is_empty():
		_status.text = "Joint detection needs mesh geometry"
		return
	# Drop any live skeleton so markers own the preview.
	_skeleton = null
	_overlay_mesh.clear_surfaces()
	_clear_bone_labels()
	_joint_points = res["points"].duplicate()
	_joint_measured = res["measured"].duplicate()
	_editing_joints = true
	_rebuild_joint_markers()
	_set_joint_legend_visible(true)
	if _confirm_bind_button != null:
		_confirm_bind_button.disabled = false
	_show_detection_report(res.get("detection", {}))
	_status.text = "Joints detected — drag any marker to correct it, then Confirm & Bind"
	_preview_label.text = "Joint review: drag the colored markers, then Confirm & Bind"

# "Detect (AI pose)" — renders the model front-on, runs BlazePose, and refines the
# geometric joints (shoulders/elbows/wrists/knees/ankles) with the AI landmarks.
# Falls back to pure geometric detection when Python/MediaPipe isn't available.
func _on_detect_joints_ai() -> void:
	if _loaded_scene == null:
		_status.text = "Load a model first"
		return
	_apply_proportions_to_fitter()
	var geo: Dictionary = _fitter.detect_joint_points(_loaded_scene)
	if geo.is_empty():
		_status.text = "Joint detection needs mesh geometry"
		return
	_status.text = "Running AI pose detection (front + side)..."
	var detector := PoseDetector.new()
	var xform: Transform3D = _loaded_scene.global_transform
	var geo_points: Dictionary = geo.get("points", {})

	# FRONT capture. The model is yawed 180 to face the default orbit, so the "back"
	# view actually looks at the figure's front/face — best case for pose detection.
	var front_img: Image = await _capture_clean_frame("back")
	if front_img == null:
		_status.text = "AI pose failed: couldn't capture the front frame. Try again, or use '1. Detect Joints (review)'."
		return
	var front_path := ProjectSettings.globalize_path("user://_pose_front.png")
	front_img.save_png(front_path)
	var front_size := Vector2(front_img.get_width(), front_img.get_height())
	# Freeze the front view's world rays WHILE the camera is at this view.
	var front_view: Dictionary = detector.capture_view(front_path, _camera, front_size, xform, geo_points)
	if front_view.get("rays", {}).is_empty():
		_status.text = "AI pose failed: %s\n(Use '1. Detect Joints (review)' for geometric detection.)" % detector.error
		return

	# SIDE capture (left) for depth triangulation. If it fails we still fall back to
	# single-view back-projection per joint, so this is best-effort, not required.
	var side_img: Image = await _capture_clean_frame("left")
	var side_view: Dictionary = {"rays": {}, "confidence": {}}
	if side_img != null:
		var side_path := ProjectSettings.globalize_path("user://_pose_side.png")
		side_img.save_png(side_path)
		var side_size := Vector2(side_img.get_width(), side_img.get_height())
		# NOTE: capture_view must run while _camera is still at the side view; _set_view
		# in _capture_clean_frame left it there, and _capture_clean_frame restores view
		# only via the caller below, so read rays now before restoring.
		side_view = detector.capture_view(side_path, _camera, side_size, xform, geo_points)
	# Restore the front view for the marker-review that follows.
	_set_view("back")

	var res: Dictionary = detector.detect_two_view(
		front_view, side_view, _camera, front_size, xform, geo, 0.4)
	if res.is_empty():
		_status.text = "AI pose failed: %s\n(Use '1. Detect Joints (review)' for geometric detection.)" % detector.error
		return

	# Measure how much AI actually moved the joints vs the geometric baseline.
	var refined := 0
	var total_move := 0.0
	var gp: Dictionary = geo.get("points", {})
	for k in res["points"]:
		if gp.has(k):
			var d: float = (gp[k] as Vector3).distance_to(res["points"][k])
			if d > 0.005:
				refined += 1
				total_move += d

	_skeleton = null
	_overlay_mesh.clear_surfaces()
	_clear_bone_labels()
	_joint_points = res["points"].duplicate()
	_joint_measured = res["measured"].duplicate()
	_editing_joints = true
	_rebuild_joint_markers()
	_set_joint_legend_visible(true)
	if _confirm_bind_button != null:
		_confirm_bind_button.disabled = false
	_show_detection_report(res.get("detection", {}))
	var avg_cm: float = (total_move / maxi(refined, 1)) * 100.0
	_status.text = "AI pose: refined %d joints (avg %.1f cm from geometric) — drag to adjust, then Confirm & Bind" % [refined, avg_cm]
	_preview_label.text = "Joint review (AI-assisted): drag markers, then Confirm & Bind"

# Snaps the preview to `view`, suppresses the green bone overlay (which breaks
# BlazePose), waits for a clean rendered frame, and returns its Image (or null on
# failure). Leaves the camera at `view` so callers can read its rays before moving it.
func _capture_clean_frame(view: String):
	_set_view(view)
	var overlay := _rig_overlay_root
	var overlay_was_visible := overlay.visible if overlay != null else false
	if overlay != null:
		overlay.visible = false
	# The per-frame preview (_pose_preview) redraws the bone overlay every frame, so
	# hiding the node isn't enough — this flag makes the redraw a no-op and clears the
	# mesh so BlazePose sees a clean body.
	_suppress_bone_overlay = true
	_overlay_mesh.clear_surfaces()
	# The first grab after a view change can be empty/black; retry a few frames.
	var img: Image = null
	for _attempt in range(8):
		await get_tree().process_frame
		var vp_tex := _viewport.get_texture()
		if vp_tex != null:
			var candidate := vp_tex.get_image()
			if candidate != null and candidate.get_width() > 0:
				img = candidate
				break
	_suppress_bone_overlay = false
	if overlay != null:
		overlay.visible = overlay_was_visible
	return img

# Formats the detection summary into the report label so the user sees, at a
# glance, which body regions were found vs. only guessed.
func _show_detection_report(detection: Dictionary) -> void:
	if _detection_report == null:
		return
	if detection.is_empty():
		_detection_report.text = "Detected parts: -"
		return
	var ok: Array = []
	var guessed: Array = []
	for key in detection:
		if detection[key]:
			ok.append(key)
		else:
			guessed.append(key)
	var text := "Detected: %s" % ", ".join(ok)
	if not guessed.is_empty():
		text += "\nGuessed (check these): %s" % ", ".join(guessed)
	_detection_report.text = text

# (Re)creates one draggable sphere marker + label per joint under the overlay.
func _rebuild_joint_markers() -> void:
	_clear_joint_markers()
	if not _editing_joints:
		return
	for key in _joint_points:
		var marker := MeshInstance3D.new()
		marker.mesh = _joint_marker_mesh
		marker.material_override = _marker_material_for(key)
		_rig_overlay_root.add_child(marker)
		_joint_markers[key] = marker
		var label := Label3D.new()
		label.text = _joint_short_label(key)
		label.font_size = 22
		label.outline_size = 6
		label.modulate = Color(0.9, 0.95, 1.0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.0005
		_rig_overlay_root.add_child(label)
		_joint_labels[key] = label
	_update_joint_marker_positions()

func _clear_joint_markers() -> void:
	for m in _joint_markers.values():
		if is_instance_valid(m):
			m.queue_free()
	for l in _joint_labels.values():
		if is_instance_valid(l):
			l.queue_free()
	_joint_markers.clear()
	_joint_labels.clear()

func _marker_material_for(key: String) -> StandardMaterial3D:
	if key == _selected_joint:
		return _joint_marker_mat_selected
	return _region_mats.get(_joint_region(key), _region_mats["spine"])

# Converts a joint's scene-local point to world space and positions its marker +
# label (parented under the overlay root, like the bone overlay does).
func _update_joint_marker_positions() -> void:
	if _loaded_scene == null:
		return
	var scene_xform := _loaded_scene.global_transform
	for key in _joint_markers:
		var world: Vector3 = scene_xform * _joint_points[key]
		var local: Vector3 = _rig_overlay_root.to_local(world)
		_joint_markers[key].position = local
		if _joint_labels.has(key):
			_joint_labels[key].position = local + Vector3(0.04, 0.04, 0.0)

# Short human label for a joint marker (e.g. "shoulder.L" -> "sh.L").
func _joint_short_label(key: String) -> String:
	return key

# Returns the joint key whose marker is nearest the clicked point (within a pixel
# radius), or "" if none. Container-space position, like _select_bone_at.
func _joint_at(container_pos: Vector2) -> String:
	if _camera == null or _preview_container == null or _loaded_scene == null:
		return ""
	var cont_size := _preview_container.size
	var vp_size := Vector2(_viewport.size)
	if cont_size.x <= 0.0 or cont_size.y <= 0.0:
		return ""
	var vp_pos := Vector2(container_pos.x / cont_size.x * vp_size.x, container_pos.y / cont_size.y * vp_size.y)
	var scene_xform := _loaded_scene.global_transform
	var best := ""
	var best_dist := 26.0  # pick radius in viewport pixels
	for key in _joint_points:
		var world: Vector3 = scene_xform * _joint_points[key]
		if _camera.is_position_behind(world):
			continue
		var screen := _camera.unproject_position(world)
		var d := screen.distance_to(vp_pos)
		if d < best_dist:
			best_dist = d
			best = key
	return best

# Moves the grabbed joint so it follows the cursor: cast the mouse ray and meet a
# plane through the joint that faces the camera, then store the result back in
# scene-LOCAL space (so binding consumes the edited value).
func _drag_joint(key: String, container_pos: Vector2) -> void:
	if _camera == null or _loaded_scene == null or not _joint_points.has(key):
		return
	var cont_size := _preview_container.size
	var vp_size := Vector2(_viewport.size)
	if cont_size.x <= 0.0 or cont_size.y <= 0.0:
		return
	var vp_pos := Vector2(container_pos.x / cont_size.x * vp_size.x, container_pos.y / cont_size.y * vp_size.y)
	var scene_xform := _loaded_scene.global_transform
	var joint_world: Vector3 = scene_xform * _joint_points[key]
	# Drag plane: through the joint, normal toward the camera.
	var normal := -_camera.global_transform.basis.z
	var ray_origin := _camera.project_ray_origin(vp_pos)
	var ray_dir := _camera.project_ray_normal(vp_pos)
	var denom := ray_dir.dot(normal)
	if absf(denom) < 0.00001:
		return
	var t := (joint_world - ray_origin).dot(normal) / denom
	if t <= 0.0:
		return
	var new_world := ray_origin + ray_dir * t
	# Back to scene-local; this is what fit_skeleton consumes.
	_set_joint_point_from_edit(key, scene_xform.affine_inverse() * new_world)
	_update_joint_marker_positions()

func _set_joint_point_from_edit(key: String, point: Vector3) -> void:
	if not _joint_points.has(key):
		return
	_joint_points[key] = point
	_joint_measured[key] = true
	if not _symmetric_joints:
		return
	var pair := _paired_joint_key(key)
	if pair == "" or not _joint_points.has(pair):
		return
	var center_x := _joint_mirror_center_x(key, pair)
	_joint_points[pair] = Vector3(center_x * 2.0 - point.x, point.y, point.z)
	_joint_measured[pair] = true

func _paired_joint_key(key: String) -> String:
	if key.ends_with(".L"):
		return key.substr(0, key.length() - 2) + ".R"
	if key.ends_with(".R"):
		return key.substr(0, key.length() - 2) + ".L"
	return ""

func _joint_mirror_center_x(key: String, pair: String) -> float:
	if _joint_points.has("hips"):
		return (_joint_points["hips"] as Vector3).x
	if _joint_points.has("spine"):
		return (_joint_points["spine"] as Vector3).x
	if _joint_points.has(key) and _joint_points.has(pair):
		return (((_joint_points[key] as Vector3).x) + ((_joint_points[pair] as Vector3).x)) * 0.5
	return 0.0

func _refresh_joint_marker_colors() -> void:
	for key in _joint_markers:
		_joint_markers[key].material_override = _marker_material_for(key)

# Confirm & Bind: build the skeleton from the (possibly edited) joint points.
func _on_confirm_bind() -> void:
	if _loaded_scene == null or _joint_points.is_empty():
		_status.text = "Detect joints first"
		return
	_editing_joints = false
	_clear_joint_markers()
	_set_joint_legend_visible(false)
	if _confirm_bind_button != null:
		_confirm_bind_button.disabled = true
	# Switch to generated-rig mode and bind using the edited points.
	_rig_mode = RigMode.GENERATED
	if _rig_mode_option != null:
		_rig_mode_option.selected = RigMode.GENERATED
	_apply_proportions_to_fitter()
	_skeleton = _fitter.fit_skeleton(_loaded_scene, _joint_points)
	if _skeleton == null:
		_status.text = "Bind failed: need mesh geometry"
		return
	_remove_other_skeletons(_loaded_scene, _skeleton)
	_cache_skeleton()
	_rebuild_bone_labels()
	_update_pose_controls_enabled()
	_apply_textured_state()
	_status.text = "Bound rig from reviewed joints: %d bones, %d finger controls" % [
		_skeleton.get_bone_count(),
		_finger_bones.size(),
	]
	_preview_label.text = "Realtime preview: bound from reviewed joints"
	_pose_preview(0.0)

# Creates one Label3D per bone (parented under the overlay root) when names are
# shown; frees them otherwise. Positions are refreshed each frame in the overlay.
func _rebuild_bone_labels() -> void:
	_clear_bone_labels()
	if not _show_bone_names or _skeleton == null or _rig_overlay_root == null:
		return
	for i in range(_skeleton.get_bone_count()):
		var label := Label3D.new()
		label.text = _skeleton.get_bone_name(i)
		label.font_size = 28
		label.outline_size = 8
		label.modulate = Color(1.0, 0.95, 0.4)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.0006
		_rig_overlay_root.add_child(label)
		_bone_labels.append(label)
	_update_bone_label_positions()

func _update_bone_label_positions() -> void:
	if _skeleton == null:
		return
	var bone_globals := _live_bone_global_poses()
	for i in range(min(_bone_labels.size(), _skeleton.get_bone_count())):
		var origin: Vector3 = (bone_globals[i] as Transform3D).origin
		var world: Vector3 = _skeleton.global_transform * origin
		_bone_labels[i].position = _rig_overlay_root.to_local(world)

func _fit_loaded_scene() -> void:
	if _loaded_scene == null:
		return
	# Orient per the chosen source coordinate system so the figure stands upright
	# and faces the camera. Generated/auto-fit rigs already bake an up-axis fix into
	# the geometry, so AUTO just yaws to face front.
	_loaded_scene.rotation = _coord_base_euler()
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

# Base rotation (Euler radians) for the loaded model per the coordinate preset.
func _coord_base_euler() -> Vector3:
	match _coord_system:
		CoordSystem.Z_UP:
			# Z-up source: stand upright (-90 X), then face the camera (180 Y).
			return Vector3(deg_to_rad(-90.0), deg_to_rad(180.0), 0.0)
		CoordSystem.VRM_FORWARD:
			# Already faces the camera (+Z toward viewer): no yaw flip.
			return Vector3.ZERO
		_:
			# AUTO / Y_UP_GLTF: Y-up facing away -> yaw 180 to face the camera.
			return Vector3(0.0, deg_to_rad(180.0), 0.0)

# Re-applies the chosen coordinate preset to the current model.
func _on_coord_selected(index: int) -> void:
	_coord_system = index
	if _loaded_scene != null:
		_fit_loaded_scene()
		_frame_orbit_on_model()

func _on_loop_toggled(_pressed: bool) -> void:
	_apply_loop_mode()

func _on_symmetric_joints_toggled(pressed: bool) -> void:
	_symmetric_joints = pressed

func _on_animation_play_pause_pressed() -> void:
	_set_animation_paused(not _animation_paused)

func _on_animation_timeline_drag_started() -> void:
	_timeline_dragging = true
	_set_animation_paused(true)

func _on_animation_timeline_drag_ended(_value_changed: bool) -> void:
	if _animation_timeline_slider != null:
		_seek_active_animation(float(_animation_timeline_slider.value))
	_timeline_dragging = false
	_set_animation_paused(true)
	_sync_animation_timeline(true)

func _on_animation_timeline_value_changed(value: float) -> void:
	if _timeline_dragging:
		_seek_active_animation(value)
		_sync_animation_timeline(true)

func _set_animation_paused(paused: bool) -> void:
	_animation_paused = paused
	if _anim_player != null and is_instance_valid(_anim_player) and _builtin_animation != "":
		if not _anim_player.is_playing():
			_anim_player.play(_builtin_animation)
		_anim_player.speed_scale = 0.0 if paused else 1.0
	_update_animation_controls_enabled()

func _seek_active_animation(time_sec: float) -> void:
	if _anim_player == null or not is_instance_valid(_anim_player) or _builtin_animation == "":
		return
	var anim := _anim_player.get_animation(_builtin_animation)
	if anim == null:
		return
	var clamped := clampf(time_sec, 0.0, anim.length)
	if not _anim_player.is_playing():
		_anim_player.play(_builtin_animation)
	_anim_player.seek(clamped, true)
	_anim_player.advance(0.0)
	_update_rig_overlay()

func _sync_animation_timeline(force: bool = false) -> void:
	var anim := _active_animation()
	var has_anim := anim != null and _anim_player != null and is_instance_valid(_anim_player) and _builtin_animation != ""
	if not has_anim:
		if _animation_timeline_slider != null:
			_animation_timeline_slider.editable = false
			_animation_timeline_slider.value = 0.0
			_animation_timeline_slider.max_value = 0.0
		if _animation_current_time_label != null:
			_animation_current_time_label.text = "0:00.00"
		if _animation_duration_label != null:
			_animation_duration_label.text = "0:00.00"
		_update_animation_controls_enabled()
		return

	var length := maxf(anim.length, 0.0)
	if _animation_timeline_slider != null:
		_animation_timeline_slider.editable = true
		if force or not is_equal_approx(float(_animation_timeline_slider.max_value), length):
			_animation_timeline_slider.max_value = length
		if not _timeline_dragging:
			_animation_timeline_slider.value = clampf(_anim_player.current_animation_position, 0.0, length)
	if _animation_current_time_label != null:
		var current := _anim_player.current_animation_position
		if _animation_timeline_slider != null and _timeline_dragging:
			current = float(_animation_timeline_slider.value)
		_animation_current_time_label.text = _format_animation_time(current)
	if _animation_duration_label != null:
		_animation_duration_label.text = _format_animation_time(length)
	_update_animation_controls_enabled()

func _update_animation_controls_enabled() -> void:
	var has_anim := _active_animation() != null
	if _animation_play_pause_button != null:
		_animation_play_pause_button.disabled = not has_anim
		_animation_play_pause_button.text = "Play" if _animation_paused or not has_anim else "Pause"
	if _animation_timeline_slider != null:
		_animation_timeline_slider.editable = has_anim

func _active_animation() -> Animation:
	if _anim_player == null or not is_instance_valid(_anim_player) or _builtin_animation == "":
		return null
	return _anim_player.get_animation(_builtin_animation)

func _format_animation_time(seconds: float) -> String:
	var total_centiseconds := maxi(0, int(round(seconds * 100.0)))
	var minutes := int(total_centiseconds / 6000)
	var secs := int(total_centiseconds / 100) % 60
	var centis := total_centiseconds % 100
	return "%d:%02d.%02d" % [minutes, secs, centis]

# Sets the loop mode of whatever animation is currently playing (retargeted clip
# or a model's built-in clip) to match the Loop checkbox, and restarts playback if
# it had stopped at the end.
func _apply_loop_mode() -> void:
	var loop: bool = _loop_check == null or _loop_check.button_pressed
	if _anim_player == null or not is_instance_valid(_anim_player):
		return
	if _builtin_animation == "":
		return
	var anim := _anim_player.get_animation(_builtin_animation)
	if anim == null:
		return
	anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	# If looping was just turned on while the clip sat finished, resume it.
	if loop and not _animation_paused and not _anim_player.is_playing():
		_anim_player.play(_builtin_animation)

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

func _remove_other_skeletons(root: Node, keep: Skeleton3D) -> void:
	for node in root.find_children("*", "Skeleton3D", true, false):
		var skel := node as Skeleton3D
		if skel == null or skel == keep:
			continue
		var parent := skel.get_parent()
		if parent != null:
			parent.remove_child(skel)
		skel.queue_free()

func _strip_skeletons_for_mesh_only(root: Node3D) -> void:
	if root == null:
		return
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		var world := mi.global_transform
		var parent := mi.get_parent()
		if parent != root:
			if parent != null:
				parent.remove_child(mi)
			root.add_child(mi)
		mi.global_transform = world
		mi.skin = null
		mi.skeleton = NodePath("")
	for node in root.find_children("*", "Skeleton3D", true, false):
		var skel := node as Skeleton3D
		if skel == null:
			continue
		var parent := skel.get_parent()
		if parent != null:
			parent.remove_child(skel)
		skel.queue_free()

func _mesh_count(root: Node) -> int:
	if root == null:
		return 0
	return root.find_children("*", "MeshInstance3D", true, false).size()

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
	if _loaded_scene == null or _rig_mode != RigMode.IMPORTED:
		return
	var player := _find_animation_player(_loaded_scene)
	if player == null:
		return
	var clip := _pick_animation(player)
	if clip == "":
		return
	_anim_player = player
	_builtin_animation = clip
	player.play(clip)
	_set_animation_paused(false)
	# Honor the Loop checkbox (defaults to looping) for the built-in clip too.
	_apply_loop_mode()
	_sync_animation_timeline(true)

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
	if _pose_mode == PoseMode.IDLE:
		# Swing limbs across all supported naming schemes (DEF-* rigify, Toon_*,
		# Blender upper_arm/thigh) so the idle preview works on any generated rig.
		_swing_limb(["DEF-upper_arm.L", "Toon_UpperArm.L", "upper_arm.L"], walk * 0.35)
		_swing_limb(["DEF-upper_arm.R", "Toon_UpperArm.R", "upper_arm.R"], -walk * 0.35)
		_swing_limb(["DEF-thigh.L", "Toon_UpperLeg.L", "thigh.L"], -walk * 0.25)
		_swing_limb(["DEF-thigh.R", "Toon_UpperLeg.R", "thigh.R"], walk * 0.25)
	else:
		_apply_test_pose(_pose_mode)
	_update_rig_overlay()

func _swing_named_bone(bone_name: String, angle: float) -> void:
	if _skeleton == null:
		return
	var idx: int = _skeleton.find_bone(bone_name)
	if idx == -1:
		return
	# Offset on top of rest; neutral pose is identity (set above this frame).
	_skeleton.set_bone_pose_rotation(idx, Quaternion(Vector3.RIGHT, angle))

# Swings the first bone whose name matches any of `names` (covers naming presets).
func _swing_limb(names: Array, angle: float) -> void:
	for n in names:
		if _skeleton.find_bone(n) != -1:
			_swing_named_bone(n, angle)
			return

# Rotates a named bone about an arbitrary local axis (offset on top of rest).
func _pose_bone(bone_name: String, axis: Vector3, degrees: float) -> void:
	if _skeleton == null:
		return
	var idx: int = _skeleton.find_bone(bone_name)
	if idx == -1:
		return
	_skeleton.set_bone_pose_rotation(idx, Quaternion(axis.normalized(), deg_to_rad(degrees)))

# Tries each preset's bone name across the supported naming schemes so poses work
# on both Toon and Blender generated rigs.
func _pose_limb(keys: Array, axis: Vector3, degrees: float) -> void:
	for k in keys:
		if _skeleton.find_bone(k) != -1:
			_pose_bone(k, axis, degrees)
			return

# Aims a bone so the segment from it to its first child points along a target
# WORLD direction, regardless of the bone's rest orientation. This makes poses
# absolute ("arm horizontal") instead of relative deltas on top of rest.
func _aim_limb(keys: Array, target_world_dir: Vector3) -> void:
	for k in keys:
		var idx: int = _skeleton.find_bone(k)
		if idx != -1:
			_aim_bone(idx, target_world_dir)
			return

func _aim_bone(idx: int, target_world_dir: Vector3) -> void:
	var child := _first_child_bone(idx)
	if child == -1:
		return
	# Rest direction of the bone->child segment, in skeleton (model) space.
	var rest_dir: Vector3 = (_skeleton.get_bone_global_rest(child).origin - _skeleton.get_bone_global_rest(idx).origin)
	if rest_dir.length() < 0.0001:
		return
	rest_dir = rest_dir.normalized()
	var target := target_world_dir.normalized()
	# Rotation (in model space) that turns the rest direction onto the target.
	var model_rot := _rotation_between(rest_dir, target)
	# Convert that model-space rotation into this bone's LOCAL pose rotation:
	# pose_local = rest_basis^-1 * parent_global^-1 * model_rot * parent_global * rest_basis... but
	# since rest pose has identity bases here, the bone's rest global basis is its
	# parent chain's accumulated basis (identity for generated rigs). We express
	# the aim relative to the parent's global rest basis.
	var parent := _skeleton.get_bone_parent(idx)
	var parent_basis := Basis()
	if parent != -1:
		parent_basis = _skeleton.get_bone_global_rest(parent).basis
	var rest_basis: Basis = _skeleton.get_bone_rest(idx).basis
	# Desired model-space basis for this bone = model_rot applied to its rest global basis.
	var rest_global_basis: Basis = _skeleton.get_bone_global_rest(idx).basis
	var desired_global := Basis(model_rot) * rest_global_basis
	var local_basis := (parent_basis * rest_basis).inverse() * desired_global
	_skeleton.set_bone_pose_rotation(idx, local_basis.get_rotation_quaternion())

func _first_child_bone(idx: int) -> int:
	for i in range(_skeleton.get_bone_count()):
		if _skeleton.get_bone_parent(i) == idx:
			return i
	return -1

# Shortest-arc quaternion rotating unit vector `from` onto unit vector `to`.
func _rotation_between(from: Vector3, to: Vector3) -> Quaternion:
	var d := from.dot(to)
	if d > 0.9999:
		return Quaternion.IDENTITY
	if d < -0.9999:
		# 180 deg: pick any perpendicular axis.
		var axis := from.cross(Vector3.UP)
		if axis.length() < 0.001:
			axis = from.cross(Vector3.RIGHT)
		return Quaternion(axis.normalized(), PI)
	var axis := from.cross(to).normalized()
	return Quaternion(axis, acos(clampf(d, -1.0, 1.0)))

func _connect_pose_button(node_name: String, mode: int) -> void:
	var btn: Button = find_child(node_name, true, false)
	if btn != null:
		btn.pressed.connect(func(): _set_pose_mode(mode))

func _set_pose_mode(mode: int) -> void:
	_pose_mode = mode
	_pose_preview(0.0)

# Pose presets and naming only affect GENERATED rigs we drive ourselves. When an
# imported model's own AnimationPlayer owns the pose, disable those controls (and
# explain why) so the UI doesn't offer no-ops.
func _update_pose_controls_enabled() -> void:
	var owned_by_anim: bool = _anim_player != null and _anim_player.is_playing()
	var generated: bool = _is_generated_active()
	var pose_usable: bool = generated and not owned_by_anim
	for node_name in ["PoseIdle", "PoseTPose", "PoseAPose", "PoseWave", "PoseCrouch"]:
		var btn: Button = find_child(node_name, true, false)
		if btn != null:
			btn.disabled = not pose_usable
	if _naming_option != null:
		# Naming changes require re-generating, so only meaningful for generated rigs.
		_naming_option.disabled = not generated
	var pose_label: Label = find_child("PoseToolbarLabel", true, false)
	if pose_label != null:
		pose_label.text = "Test pose:" if pose_usable else "Test pose: (generated rigs only)"

# Applies a static demo pose by rotating upper-arm / forearm / thigh / shin
# bones. Bone names cover the Toon and Blender presets used by the generated rig.
# Poses use ABSOLUTE world-space aim directions (model space: +X = figure's left
# side, -X = right side, +Y = up, -Y = down), so the result is the named pose
# regardless of the bone rest orientation.
func _apply_test_pose(mode: int) -> void:
	const L_OUT := Vector3.LEFT      # toward the figure's left hand (+X)
	const R_OUT := Vector3.RIGHT     # toward the figure's right hand (-X)
	var down := Vector3.DOWN
	match mode:
		PoseMode.TPOSE:
			# Upper arms straight out to the sides, horizontal.
			_aim_limb(["Toon_UpperArm.L", "upper_arm.L"], L_OUT)
			_aim_limb(["Toon_UpperArm.R", "upper_arm.R"], R_OUT)
		PoseMode.APOSE:
			# Arms ~45 deg down and out.
			_aim_limb(["Toon_UpperArm.L", "upper_arm.L"], (L_OUT + down).normalized())
			_aim_limb(["Toon_UpperArm.R", "upper_arm.R"], (R_OUT + down).normalized())
		PoseMode.WAVE:
			# Right upper arm up-and-out, forearm pointing up (a raised wave).
			_aim_limb(["Toon_UpperArm.R", "upper_arm.R"], (R_OUT + Vector3.UP).normalized())
			_aim_limb(["Toon_LowerArm.R", "forearm.R"], Vector3.UP)
		PoseMode.CROUCH:
			# Thighs forward+down, shins back+down -> bent-knee crouch.
			_aim_limb(["Toon_UpperLeg.L", "thigh.L"], (down + Vector3.FORWARD).normalized())
			_aim_limb(["Toon_UpperLeg.R", "thigh.R"], (down + Vector3.FORWARD).normalized())
			_aim_limb(["Toon_LowerLeg.L", "shin.L"], (down + Vector3.BACK).normalized())
			_aim_limb(["Toon_LowerLeg.R", "shin.R"], (down + Vector3.BACK).normalized())

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

	# Separate overlay for the selected-bone highlight (bright, drawn on top).
	_highlight_instance = MeshInstance3D.new()
	_highlight_instance.name = "SelectedBoneHighlight"
	_highlight_instance.mesh = _highlight_mesh
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.albedo_color = Color(1.0, 0.55, 0.05)
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.no_depth_test = true
	_highlight_instance.material_override = _highlight_material
	_rig_overlay_root.add_child(_highlight_instance)

# Picks the bone whose joint projects nearest to the clicked screen point and
# selects it (highlight + info). Click position is in the container's space.
func _select_bone_at(container_pos: Vector2) -> void:
	if _skeleton == null or _camera == null or _preview_container == null:
		return
	# Map container-local position to the SubViewport's pixel space.
	var cont_size := _preview_container.size
	var vp_size := Vector2(_viewport.size)
	if cont_size.x <= 0.0 or cont_size.y <= 0.0:
		return
	var vp_pos := Vector2(container_pos.x / cont_size.x * vp_size.x, container_pos.y / cont_size.y * vp_size.y)

	var best := -1
	var best_dist := 24.0  # max pick radius in viewport pixels
	var bone_globals := _live_bone_global_poses()
	for i in range(_skeleton.get_bone_count()):
		var world: Vector3 = _skeleton.global_transform * (bone_globals[i] as Transform3D).origin
		if _camera.is_position_behind(world):
			continue
		var screen: Vector2 = _camera.unproject_position(world)
		var d := screen.distance_to(vp_pos)
		if d < best_dist:
			best_dist = d
			best = i
	if best != -1:
		_set_selected_bone(best)

func _set_selected_bone(index: int) -> void:
	_selected_bone = index
	if _selected_bone_label == null:
		return
	if index == -1:
		_selected_bone_label.text = "Bone: -"
		return
	var name := _skeleton.get_bone_name(index)
	var parent_idx := _skeleton.get_bone_parent(index)
	var parent_name := _skeleton.get_bone_name(parent_idx) if parent_idx != -1 else "(root)"
	_selected_bone_label.text = "Bone: %s | %s | #%d" % [name, parent_name, index]

# Switching naming only matters for generated (auto-fit) rigs; re-run the load so
# the skeleton is rebuilt with the chosen preset's bone names.
func _on_naming_selected(index: int) -> void:
	_fitter.naming = index
	if _is_generated_active():
		_load_model_from_ui()

# Switching skin-weight algorithm only affects generated rigs (the fitter does the
# skinning). Re-bind the current one so the user can compare old vs new directly.
func _on_skin_method_selected(index: int) -> void:
	_fitter.skin_method = index
	var label := "Proximity" if index == ToonHumanoidFitter.SkinMethod.PROXIMITY else "Heat diffusion"
	if _is_generated_active():
		_status.text = "Re-binding with %s skin weights..." % label
		_load_model_from_ui()
	else:
		_status.text = "Skin weights set to %s (applies on next bind)" % label

# Pushes the proportion sliders into the fitter (no-op if sliders are absent).
func _apply_proportions_to_fitter() -> void:
	if _shoulder_scale_slider != null:
		_fitter.shoulder_scale = float(_shoulder_scale_slider.value)
	if _arm_scale_slider != null:
		_fitter.arm_scale = float(_arm_scale_slider.value)
	if _leg_scale_slider != null:
		_fitter.leg_scale = float(_leg_scale_slider.value)

# Proportions only affect generated (auto-fit) rigs; re-run the fit to apply.
func _on_proportion_changed() -> void:
	if _is_generated_active():
		_load_model_from_ui()

func _on_bone_style_selected(index: int) -> void:
	_bone_style = index
	_overlay_mesh_instance.material_override = _octa_material if _bone_style == BoneStyle.OCTAHEDRAL else _line_material
	_update_rig_overlay()

func _on_rig_mode_selected(index: int) -> void:
	_rig_mode = index
	if _rig_mode_option != null and _rig_mode_option.selected != index:
		_rig_mode_option.selected = index
	if _path_edit != null and _path_edit.text.strip_edges() != "":
		_load_model_from_ui()

func _update_rig_overlay() -> void:
	if _skeleton == null or _rig_overlay_root == null:
		return
	if _suppress_bone_overlay:
		# Keep the overlay empty while capturing a clean frame for AI detection.
		_overlay_mesh.clear_surfaces()
		return
	# Each entry is [head_local, tail_local] for one bone (parent joint -> joint).
	var segments: Array = _bone_segments_local()
	_overlay_mesh.clear_surfaces()
	if _bone_style == BoneStyle.OCTAHEDRAL:
		_draw_octahedral_bones(segments)
	else:
		_draw_line_bones(segments)
	if _show_bone_names:
		_update_bone_label_positions()
	_update_selection_highlight()

# Draws the selected bone's segment as a thick bright marker over the rig.
func _update_selection_highlight() -> void:
	_highlight_mesh.clear_surfaces()
	if _selected_bone <= 0 or _skeleton == null or _selected_bone >= _skeleton.get_bone_count():
		return
	var parent_idx := _skeleton.get_bone_parent(_selected_bone)
	if parent_idx == -1:
		return
	var bone_globals := _live_bone_global_poses()
	var head: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * (bone_globals[parent_idx] as Transform3D).origin)
	var tail: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * (bone_globals[_selected_bone] as Transform3D).origin)
	# A small box around the joint + a line along the bone, so it pops out.
	_highlight_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var r := head.distance_to(tail) * 0.12 + 0.02
	for corner in [Vector3(r,r,r), Vector3(-r,r,r), Vector3(-r,-r,r), Vector3(r,-r,r), Vector3(r,r,r)]:
		_highlight_mesh.surface_add_vertex(tail + corner)
	_highlight_mesh.surface_end()
	_highlight_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_highlight_mesh.surface_add_vertex(head)
	_highlight_mesh.surface_add_vertex(tail)
	_highlight_mesh.surface_end()

# Collects each bone as a [head, tail] pair in _rig_overlay_root local space.
func _bone_segments_local() -> Array:
	var segments: Array = []
	var bone_globals := _live_bone_global_poses()
	for i in range(_skeleton.get_bone_count()):
		var parent_index := _skeleton.get_bone_parent(i)
		if parent_index == -1:
			continue
		var parent_origin: Vector3 = (bone_globals[parent_index] as Transform3D).origin
		var child_origin: Vector3 = (bone_globals[i] as Transform3D).origin
		if parent_origin.is_zero_approx() and child_origin.is_zero_approx():
			parent_origin = _skeleton.get_bone_global_rest(parent_index).origin
			child_origin = _skeleton.get_bone_global_rest(i).origin
		var head: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * parent_origin)
		var tail: Vector3 = _rig_overlay_root.to_local(_skeleton.global_transform * child_origin)
		segments.append([head, tail])
	return segments

func _live_bone_global_poses() -> Array:
	var globals: Array = []
	if _skeleton == null:
		return globals
	globals.resize(_skeleton.get_bone_count())
	for i in range(_skeleton.get_bone_count()):
		globals[i] = _skeleton.get_bone_global_pose(i)
	return globals

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
