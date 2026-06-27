# External Test Models

Rigged/animated glTF sample models used for auto-rig cross-checking, from the
Khronos glTF-Sample-Assets repository
(https://github.com/KhronosGroup/glTF-Sample-Assets). These are **test fixtures
only**, not shipped game assets.

> Note: only `CesiumMan.glb` (and the generated `noskel/` fixtures) is committed
> here. The other rows are documented for reference; download them from the link
> above if needed. Licenses differ per model — see attribution below.

| File | Type | License |
|------|------|---------|
| CesiumMan.glb | Humanoid, skinned walk | CC-BY 4.0 (with trademark limitations) |
| Fox.glb | Quadruped, Survey/Walk/Run | mesh CC0; rig + animation + glTF conversion CC-BY 4.0 |
| BrainStem.glb | Humanoid robot, animated | Poser EULA (Smith Micro) — restrictive, not for redistribution |
| RiggedFigure.glb | Simple skinned figure | (see upstream model README) |

## Attribution

- **CesiumMan** — © 2017 Cesium. Licensed CC-BY 4.0 International (with trademark
  limitations). https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/CesiumMan
- **Fox** — model © 2014 PixelMannen (CC0); rigging & animation © 2014 tomkranis,
  glTF conversion © 2017 @AsoboStudio and @scurest (both CC-BY 4.0).
- **BrainStem** — © 2017 Smith Micro Software, Inc. (Keith Hunter), Poser EULA.

CC-BY 4.0: https://creativecommons.org/licenses/by/4.0/

## noskel/ — unrigged auto-rig fixtures

Pure-mesh humanoids (no armature, no weights) generated procedurally in Blender
to stress-test the auto-rig path. Authored for this project; no third-party
license applies. Used by the regression tests in test_auto_rig_lab.gd.

| File | Purpose |
|------|---------|
| noskel_tall_tpose.glb | Y-up T-pose — arms should stay horizontal |
| noskel_stocky_down.glb | Arms-down (A-pose) — arm bones should descend to the sides |
| noskel_zup_tpose.glb | Z-up export — auto-rig must correct it to stand upright |
| noskel_blob.glb | Limbless blob — degenerate case, must not crash |
