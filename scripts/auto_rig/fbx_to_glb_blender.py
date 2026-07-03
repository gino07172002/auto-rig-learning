"""Headless Blender FBX -> glb converter for Auto Rig Lab.

Run as:  blender -b --python fbx_to_glb_blender.py -- <in.fbx> <out.glb>

Imports the FBX, bakes the import scale into the mesh/armature, and exports a
Y-up .glb that GLTFDocument (Godot) and any other glTF tool can consume. This is
the bridge that lets the tool accept Mixamo / Adobe FBX downloads, which it
otherwise cannot read.
"""

import sys
import bpy


def _argv_after_dashes():
    if "--" not in sys.argv:
        return []
    return sys.argv[sys.argv.index("--") + 1:]


def _view3d_override():
    """Build a context override targeting a 3D view.

    The FBX importer calls ``mode_set(EDIT)`` while building armatures, which
    needs a valid 3D-view context + active object. In headless runs the default
    context can be missing one, so we supply an explicit override when a window
    is available; otherwise we fall back to the plain call.
    """
    wm = bpy.data.window_managers[0] if bpy.data.window_managers else None
    if wm is None or not wm.windows:
        return None
    win = wm.windows[0]
    scr = win.screen
    areas = [a for a in scr.areas if a.type == "VIEW_3D"]
    if not areas:
        return None
    area = areas[0]
    regions = [r for r in area.regions if r.type == "WINDOW"]
    if not regions:
        return None
    return {
        "window": win,
        "screen": scr,
        "area": area,
        "region": regions[0],
        "scene": bpy.context.scene,
        "view_layer": bpy.context.view_layer,
    }


def _import_fbx(path):
    override = _view3d_override()
    if override is not None:
        with bpy.context.temp_override(**override):
            bpy.ops.import_scene.fbx(filepath=path)
    else:
        bpy.ops.import_scene.fbx(filepath=path)


def main():
    args = _argv_after_dashes()
    if len(args) < 2:
        print("ARGL_FBX_CONVERT: expected <in.fbx> <out.glb>", file=sys.stderr)
        sys.exit(2)
    in_path, out_path = args[0], args[1]

    # Start from an empty scene so nothing else lands in the export.
    bpy.ops.wm.read_homefile(use_empty=True)

    try:
        _import_fbx(in_path)
    except Exception as exc:  # noqa: BLE001 - report and fail cleanly
        print("ARGL_FBX_CONVERT: import failed: %s" % exc, file=sys.stderr)
        sys.exit(3)

    # Export everything as a Y-up glb, baking the import scale (Mixamo armatures
    # come in at 0.01) into the geometry so the result is correctly sized.
    try:
        bpy.ops.export_scene.gltf(
            filepath=out_path,
            export_format="GLB",
            export_apply=True,
            export_yup=True,
        )
    except Exception as exc:  # noqa: BLE001
        print("ARGL_FBX_CONVERT: export failed: %s" % exc, file=sys.stderr)
        sys.exit(4)

    print("ARGL_FBX_CONVERT: ok -> %s" % out_path)


if __name__ == "__main__":
    main()
