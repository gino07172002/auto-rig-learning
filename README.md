# Auto Rig Lab (Godot 4)

A small Godot tool for learning automatic character rigging. It detects an
existing game skeleton in an imported model, or **generates and skins** a toon
humanoid skeleton for unrigged meshes, and previews the result live.

## Features

- **Skeleton detection** — analyses a `.glb`/`.gltf` and reports bones, finger
  bones, and a rig quality score.
- **Auto-rig unrigged meshes** — generates a 49-bone toon skeleton and real
  linear-blend skin weights, rebuilding the mesh so it actually deforms.
  - Detects Z-up models and corrects them to stand upright.
  - Places arm bones along the measured limb (T-pose / A-pose / arms-down).
- **glTF round-trip** — exports the rigged result to a portable `.glb`
  (`ToonHumanoidFitter.export_to_glb`) that re-imports in Blender and Godot.
- **Live preview** — plays a model's built-in animation, or a procedural pose
  test, with an orbit camera (left-drag rotate, wheel zoom, right-drag pan).
- **Browse...** button to pick any model file.

## Running

Open the project in Godot 4.2+ and run the main scene (`scenes/auto_rig_lab.tscn`),
or from the command line:

```
godot --path . scenes/auto_rig_lab.tscn
```

## Tests

```
godot --headless --path . -s res://scripts/tests/run_auto_rig_lab_test.gd
```

The runner exits non-zero on any assertion failure.

## Test models & licensing

`assets/models/external_test/CesiumMan.glb` is a rigged sample model used by the
detection test — **CC-BY 4.0 (with trademark limitations), © 2017 Cesium**
(from the Khronos glTF-Sample-Assets repository). The `noskel/` fixtures are
generated procedurally for this project. See
`assets/models/external_test/SOURCES.md` for full attribution.
