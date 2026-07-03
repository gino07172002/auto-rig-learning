extends SceneTree

const OUTPUT_PATH := "res://_auto_rig_lab_capture.png"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var output_path := OUTPUT_PATH
	var model_path := ""
	var anim_path := ""
	var seek_time := -1.0
	var full_ui := false
	var yaw := INF
	var pitch := INF
	var auto_bind := false
	var rig_mode := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
		elif arg.begins_with("--model="):
			model_path = arg.trim_prefix("--model=")
		elif arg.begins_with("--anim="):
			anim_path = arg.trim_prefix("--anim=")
		elif arg.begins_with("--time="):
			seek_time = arg.trim_prefix("--time=").to_float()
		elif arg == "--full-ui":
			full_ui = true
		elif arg.begins_with("--yaw="):
			yaw = deg_to_rad(arg.trim_prefix("--yaw=").to_float())
		elif arg.begins_with("--pitch="):
			pitch = deg_to_rad(arg.trim_prefix("--pitch=").to_float())
		elif arg == "--auto-bind":
			auto_bind = true
		elif arg.begins_with("--rig-mode="):
			rig_mode = arg.trim_prefix("--rig-mode=").to_lower()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab := scene.instantiate()
	root.add_child(lab)
	if model_path != "":
		await process_frame
		var path_edit: LineEdit = lab.find_child("ModelPathEdit", true, false)
		path_edit.text = model_path
		lab._load_model_from_ui()
		if rig_mode != "":
			match rig_mode:
				"imported":
					lab._on_rig_mode_selected(lab.RigMode.IMPORTED)
				"none":
					lab._on_rig_mode_selected(lab.RigMode.NONE)
				"generated":
					lab._on_rig_mode_selected(lab.RigMode.GENERATED)
		elif auto_bind:
			await process_frame
			lab._auto_bind_from_ui()
		if anim_path != "":
			await process_frame
			lab._on_animation_file_selected(anim_path)
			if seek_time >= 0.0:
				await process_frame
				var player: AnimationPlayer = lab._retarget_player
				if player != null:
					player.speed_scale = 0.0
					player.seek(seek_time, true)
					player.advance(0.0)
					print("Capture animation position: %.4f" % player.current_animation_position)
		if yaw != INF:
			lab._orbit_yaw = yaw
		if pitch != INF:
			lab._orbit_pitch = pitch
		if yaw != INF or pitch != INF:
			lab._apply_orbit_camera()
	for i in 90:
		await process_frame
	# Capture from the lab's own SubViewport rather than the root window so the
	# script works under any rendering driver and never depends on a window swap.
	var preview_viewport: SubViewport = lab.find_child("PreviewViewport", true, false)
	var source_texture := root.get_texture() if full_ui else (preview_viewport.get_texture() if preview_viewport != null else root.get_texture())
	var image := source_texture.get_image() if source_texture != null else null
	if image == null:
		push_error("Capture failed: no rendered image available (headless dummy renderer cannot produce textures)")
		quit(1)
		return
	image.save_png(output_path)
	print("Saved auto rig lab capture: %s" % ProjectSettings.globalize_path(output_path))
	quit()
