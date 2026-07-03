# Review request: heat-diffusion skin weighting

## Round 4 — fixes applied to round-3 findings

- **Finding 1 (material seam across separate surfaces still didn't diffuse)** —
  correct catch: the weld only saw one surface at a time, so a material split (=
  separate Godot surface) stayed disconnected. Heat now solves across the WHOLE
  mesh: new `_solve_heat_for_mesh` concatenates every surface's baked vertices +
  triangles into one buffer (per-surface index offset), runs a single heat solve,
  then slices weights back per surface. Proximity stays per-surface (it's
  per-vertex, order-independent). New regression test
  `test_heat_diffuses_across_material_surface_seam` builds a 2-surface mesh whose
  surfaces share a seam edge and asserts the right surface's seam vertex receives
  left-bone weight (impossible with the old per-surface solve).
- **Finding 2 (stale comment said indexed meshes use index buffer directly)** —
  comment at the top of the heat solve corrected to state all meshes are
  position-welded; seams rejoin, real gaps stay disconnected.

## Round 3 — fixes applied to round-2 findings

- **Finding 1 (graph tests claimed but not in repo)** — the targeted regression
  tests are now real and wired into `run()`:
  `test_auto_rig_lab.gd::test_heat_adjacency_welds_seams_and_blocks_gaps` (+ helper
  `_graph_connected`). It asserts: a seam (duplicate verts at one position) welds
  and stays diffusible; a real gap (separate shells, no shared position) stays
  disconnected; the adjacency graph is symmetric. (My round-2 verification had been
  done in a throwaway script — fair catch.)
- **Finding 2 (index-only graph breaks diffusion at UV/normal/material seams)** —
  confirmed real and severe: on our meshes 10–73% of vertices are seam duplicates
  (noskel glTF = 72.8%, X Bot FBX = 10.5%). `_build_vertex_adjacency` now
  **position-welds ALL meshes** (not just unindexed) before building the graph, so
  a continuous surface split at a seam rejoins. This does NOT reintroduce the
  round-1 gap-bleed bug: welding only merges vertices sharing a position to ~0.1mm,
  which a deliberate gap (armpit / finger spacing in rest pose) never does. Verified
  on the 72.8%-split noskel mesh: welded graph collapses to a few large components
  (biggest = 60% of reps) instead of hundreds of seam islands, and the gap test
  above still passes.

## Round 2 — fixes applied to the previous review's findings

All three findings from the last review are addressed (in `toon_humanoid_fitter.gd`):

- **Finding 1 (weld bridged disconnected geometry)** — `_build_vertex_adjacency`
  now uses the **index buffer verbatim for indexed meshes (rep == identity, no
  weld)**, so separate shells stay disconnected and the "can't cross a gap"
  guarantee is strict surface topology. Position-welding is used ONLY for
  unindexed triangle soup. (Our native FBX + glTF imports are indexed, so real
  models always take the strict path.)
- **Finding 2 (asymmetric/order-dependent weld graph)** — the graph is now built
  on **representatives only, with symmetric edges**; the heat solver seeds,
  relaxes, and collapses on representatives, then **expands the result back to all
  welded duplicates**. No more one-directional inheritance.
- **Finding 3 (seeds not pinned -> locality washes out)** — each pass now **soft-
  pins** every vertex back toward its original nearest-bone seed (`pin = 0.25`),
  scaling the smoothed row by `(1 - pin)` and re-adding `pin` on the seed column,
  which keeps the row a partition of unity (sum == 1) while anchoring locality.
  Comments/claims softened accordingly.

Empirically verified: indexed separate shells stay disconnected; welded soup graph
is symmetric and bridges shared corners; heat weights stay normalized (bad_norm=0)
and still use fewer bones than proximity (16 vs 23). Full suite passes.

Please re-check the three areas above, plus the new soft-pin math (does
`(1-pin)*row + pin*e_seed` preserve sum==1 given the smoothed row already sums to
1, and is `pin = 0.25` a reasonable anchor strength?).

---

Please verify the **correctness of the new heat-diffusion skinning algorithm** and
that the old method is untouched. This is the skin-weight upgrade meant to bring
our generated toon-rig closer to Blender Bone Heat / Mixamo (surface-following
weights instead of pure proximity, so they don't bleed across gaps like armpits,
between fingers, or skirt-to-leg).

## What changed

All in `scripts/auto_rig/toon_humanoid_fitter.gd`:

- **New switch** (`toon_humanoid_fitter.gd:17-18`): `enum SkinMethod { PROXIMITY, HEAT_DIFFUSION }`,
  `var skin_method := SkinMethod.PROXIMITY` (default = old behaviour, opt-in only).
- **Branch point** (`_build_skinned_mesh`, ~line 484): per surface, calls either
  `_assign_weights_proximity()` (old code, refactored verbatim into a wrapper) or
  `_assign_weights_heat()` (new). Vertex baking, normals, materials, Skin building
  are unchanged.
- **`_assign_weights_proximity`** (line 509): wraps the original per-vertex
  `_weights_for_point()` loop — should be behaviourally identical to before.
- **`_assign_weights_heat`** (line 524): the new algorithm (details below).
- **`_build_vertex_adjacency`** (line 626) + **`_build_position_weld`** (line 675):
  surface graph construction.

UI: `scenes/auto_rig_lab.tscn` adds a "Skin weights" `OptionButton`
(`SkinMethodOption`); `auto_rig_lab.gd` `_on_skin_method_selected()` sets
`_fitter.skin_method` and re-binds a generated rig so old vs new can be compared live.

Test: `scripts/tests/test_auto_rig_lab.gd::test_heat_diffusion_skinning_produces_valid_weights`.

## Algorithm (what to verify)

`_assign_weights_heat(baked_verts, arrays, segments, bones, weights)`:

1. **Seed** — each vertex gets heat `1.0` on its single nearest bone *segment*
   (parent-joint → joint line), found by `_distance_to_segment` with no sort.
   Heat is one flat `PackedFloat32Array` of size `n * bone_count` (column j == segment j).
2. **Adjacency** — `_build_vertex_adjacency` builds per-vertex neighbour lists from
   the triangle index buffer; for unindexed "triangle soup" it first welds vertices
   by quantized position (`_build_position_weld`, 0.1 mm grid) so coincident corners
   act as one graph node and heat can cross triangle/seam boundaries.
3. **Relax** — `passes` Laplacian smoothing iterations (14, or 8 when n > 6000),
   ping-ponging two flat buffers (no per-iteration allocation). Each vertex keeps
   `self_w = 0.5` of its own heat and distributes the rest equally among neighbours.
   Isolated vertices (no neighbours) keep their own row.
4. **Collapse** — per vertex, take the top-4 strongest columns, normalize to sum 1,
   write `bones`/`weights`.

## Specific things I want checked

1. **Correctness of the diffusion math** — is the self/neighbour split
   (`self_w` + even neighbour share summing to 1) a valid Laplacian relaxation?
   Does it converge to sensible surface-following weights, or can it oversmooth /
   wash out the seed so a vertex ends up dominated by the wrong bone?
2. **The gap-blocking claim** — does heat genuinely fail to cross an unconnected
   gap (armpit, between fingers)? i.e. is adjacency strictly surface-topological,
   with no accidental bridge (e.g. position-weld merging two *separate* surfaces
   that happen to touch)? The 0.1 mm weld tolerance — too loose / too tight?
3. **Top-4 collapse + normalization** — every vertex must end with 4 valid bone
   indices and weights summing to 1.0 (LBS requirement). Edge cases: fewer than 4
   non-zero columns, all-zero row (fallback to `col_bone[0]` weight 1.0), a vertex
   whose nearest segment's bone never appears after diffusion.
4. **Unindexed-mesh path** — `_build_position_weld` + the "inherit representative's
   neighbours" step. Is the welded graph correct? Any vertex that should diffuse but
   gets isolated?
5. **Proximity path is truly unchanged** — confirm `_assign_weights_proximity` +
   `_weights_for_point` produce the same output as before the refactor.
6. **Perf / scaling** — relaxation is O(passes · n · bone_count · avg_degree) in
   GDScript. ~2.4 s for 2944 verts, ~9-11 s for 8k. Is the flat-buffer ping-pong the
   right structure, or is there a clearly better approach (sparse per-vertex active
   set, since most of the `bone_count`-wide row stays zero)? Note: I previously tried
   a "nearest-K compact column" variant but the per-vertex sort dominated; current
   code uses full `bone_count` columns with an unsorted nearest-segment seed.

## How to validate empirically

- Default must stay PROXIMITY (nothing changes unless the user switches).
- Run the suite: `D:\Tools\Godot\godot.cmd --headless --path . -s res://scripts/tests/run_auto_rig_lab_test.gd`
  (expect `Auto rig lab tests passed`).
- Bind `res://assets/models/external_test/noskel/noskel_tall_tpose.glb` with each
  method; for HEAT_DIFFUSION expect normalized 4-bone weights and *fewer distinct
  bones used* than proximity (cleaner, more localized influence — I measured 16 vs 23).
- To check no gap-bleed: pose `Toon_UpperArm.L` down hard and compare armpit
  deformation between the two methods.

## Known / accepted

- Heat is slower than proximity (it's a one-off bind, not realtime); dense meshes
  reduce passes to stay responsive. The generated rig targets *unrigged* low/mid-poly
  models — an already-rigged dense mesh (e.g. Maria) takes the imported path, not this.
- `ObjectDB instances leaked at exit` warning is pre-existing, unrelated.
