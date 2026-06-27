extends SceneTree

const OUTPUT_PATH := "res://_auto_rig_lab_capture.png"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var output_path := OUTPUT_PATH
	var model_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_path = arg.trim_prefix("--output=")
		elif arg.begins_with("--model="):
			model_path = arg.trim_prefix("--model=")
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/auto_rig_lab.tscn")
	var lab := scene.instantiate()
	root.add_child(lab)
	if model_path != "":
		await process_frame
		var path_edit: LineEdit = lab.find_child("ModelPathEdit", true, false)
		path_edit.text = model_path
		lab._load_model_from_ui()
	for i in 90:
		await process_frame
	# Capture from the lab's own SubViewport rather than the root window so the
	# script works under any rendering driver and never depends on a window swap.
	var preview_viewport: SubViewport = lab.find_child("PreviewViewport", true, false)
	var source_texture := preview_viewport.get_texture() if preview_viewport != null else root.get_texture()
	var image := source_texture.get_image() if source_texture != null else null
	if image == null:
		push_error("Capture failed: no rendered image available (headless dummy renderer cannot produce textures)")
		quit(1)
		return
	image.save_png(output_path)
	print("Saved auto rig lab capture: %s" % ProjectSettings.globalize_path(output_path))
	quit()
