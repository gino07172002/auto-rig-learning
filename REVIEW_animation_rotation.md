# Bug to solve: retargeted FBX animation has limbs spread too wide (~15-20° off)

## Symptom

Loading an external Mixamo animation FBX (e.g. "Rumba Dancing.fbx") onto an
imported Mixamo character plays, but the **arms are spread out near a T-pose**
instead of bent in front of the chest like the source clip. The animation IS
moving (LeftArm rotates ~57° from frame 0 to mid), but the hands end up too far
out to the sides and slightly behind, not curled toward the body.

Cross-checked against Blender's own FBX importer (ground truth) — see numbers
below; our per-bone local rotation is ~15-20° off.

## Where the code is

- `scripts/auto_rig/fbx_animation.gd` — parses the FBX animation into a Godot
  `Animation`. The rotation track is built in `_build_animation()`; each key uses
  `_fbx_local_rotation(pre, euler, post)` which returns
  `Basis(pre_euler) * Basis(euler) * Basis(post_euler).inverse()` as a quaternion
  (XYZ Euler order), i.e. the RAW FBX local rotation. No rest re-anchoring.
- `scripts/auto_rig/fbx_importer.gd` `_local_transform()` builds each bone's REST
  with the SAME formula: `pre * Lcl_rest * post^-1`, translation * unit_scale.
- The Animation's ROTATION_3D tracks are played by an AnimationPlayer in
  `auto_rig_lab.gd::_on_animation_file_selected()`, targeting bone paths
  "Skeleton3D:mixamorig_<bone>".

Both the animation and the character are the same Mixamo rig (bone names match,
`:` normalized to `_`). The importer's rest world positions MATCH Blender exactly
(verified: our LeftArm global rest = (0.152, 1.441, -0.055); Blender, after Y/Z
swap, = (0.153, 1.429, -0.062)). So the skeleton/rest is correct — the issue is
purely the **animation rotation values**.

## Key fact discovered

Godot's `set_bone_rest` re-normalizes the basis, so reading a bone's rest
rotation back does NOT equal the quaternion we stored:
- importer `_local_transform` for Spine returns quat (x,y,z,w) = (-0.080, 0, 0, 0.997)
- but `skeleton.get_bone_rest(spine).basis.get_rotation_quaternion()` = (+0.080, 0, 0, 0.997)
- LeftArm: stored (-0.0246, 0.0026, 0.1035, …) reads back as (0.0026, 0.1035, -0.0246, …)

So feeding raw FBX local rotations as ROTATION_3D track values is inconsistent
with the skeleton's actual (re-normalized) rest.

## Godot ROTATION_3D semantics

Godot's rotation track value is the bone's ABSOLUTE local pose rotation (it
replaces the rest rotation), NOT a delta on top of rest.

## Ground-truth numbers from Blender (Rumba Dancing.fbx, frame 36 of 72)

Blender, LeftArm:
- `pose_bone.matrix_basis` (delta relative to rest), quat wxyz = (0.9554, 0.2269, 0.1850, -0.0385)
- full bone-local pose (parent.matrix^-1 * pb.matrix), quat wxyz = (0.9724, 0.1366, 0.1814, -0.0531)
  (NOTE: Blender bone-local uses Y-along-bone convention, so its components are
  NOT directly comparable to Godot's rest-basis convention — axis remap needed.)

Our importer, LeftArm REST local rotation (Godot), quat wxyz = (0.9943, 0.0026, 0.1035, -0.0246)

Derived "correct" Godot local pose = our_rest_local * blender_matrix_basis_delta
  = wxyz (0.9293, 0.2286, 0.2774, -0.0848)

Our animation currently produces for LeftArm @mid: wxyz (0.9787, 0.1239, 0.1637, -0.0021)
  → **20.9° off** from the derived-correct value above.

Also computed `fbx_delta = fbx_rest^-1 * fbx_anim` (our formula's implied delta):
  wxyz (0.945, 0.256, 0.184, +0.092)
vs Blender's matrix_basis delta: wxyz (0.9554, 0.2269, 0.1850, -0.0385)
  → **15.3° off**, and note the Z component has the OPPOSITE SIGN (+0.092 vs -0.038).

FK hand positions (relative to hips), mid-frame:
- Ours:    LeftHand (-0.59, 0.24, 0.08)   |X| = 0.59  (too far out)
- Blender: LeftHand ( 0.35, -0.03, 0.20)  |X| = 0.35  (and opposite X sign)

## What I suspect (for Codex to confirm or refute)

1. The correct Godot track value is `rest_local * delta`, where `delta` is the
   animation's rotation relative to rest. Blender's `matrix_basis` is exactly that
   delta — and `rest_local * matrix_basis` reproduces the right pose.
2. Our `fbx_delta = fbx_rest^-1 * fbx_anim` is in the WRONG coordinate frame /
   axis convention vs Blender's delta (15.3° off, Z sign flipped). Likely an
   Euler-order or pre/post-rotation composition error, OR the delta needs to be
   expressed in the bone's rest-basis frame: `delta_bonespace = rest^-1 * (fbx_rest^-1 * fbx_anim) * rest`
   or similar conjugation.
3. History (please don't re-introduce): an earlier "re-anchor" attempt used
   `q = godot_rest * (fbx_rest^-1 * fbx_anim)` and made hands go BEHIND the body;
   reverting to raw FBX rotations made arms spread wide (current state). Neither is
   right — the delta's coordinate frame is the open question.

## How to validate a fix

- Blender MCP is available (Blender 5.1) with Rumba Dancing.fbx importable; use it
  as ground truth: import, `scene.frame_set(36)`, read `pose_bone.matrix` / world
  bone positions, compare.
- Sample fixtures: model `D:/newExport/X Bot.fbx` (or Maria), animation
  `D:/newExport/Rumba Dancing.fbx`.
- A correct fix should make FK hand position at mid match Blender's (|X|≈0.35,
  hands forward/in toward the chest), within a few cm.
- Run the suite: `D:\Tools\Godot\godot.cmd --headless --path . -s res://scripts/tests/run_auto_rig_lab_test.gd`
  (expect "Auto rig lab tests passed"). Add a regression test using FK + the
  Blender-derived expected positions (env-gated fixture like the other anim tests).

## Constraint

Keep it pure GDScript (no Blender dependency at runtime). Blender is only for
deriving/validating the correct math, not a runtime requirement.
