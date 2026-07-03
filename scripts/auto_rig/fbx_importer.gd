extends RefCounted
class_name FbxImporter

# Builds a Godot scene (Skeleton3D + skinned MeshInstance3D) from a binary FBX,
# using FbxParser for the raw tree. Pure GDScript, no Blender dependency.
#
# Scope (minimum viable): rest skeleton + skinned meshes (vertices, normals, UVs,
# bone weights). Animation curves are not imported. Targets Mixamo / Adobe FBX
# (cm units, Y-up), which the tool's analyzer then treats like any other rig.
#
# Coordinate handling: FBX here is Y-up like Godot, so no axis swap is needed;
# we only apply the file's unit scale (Mixamo = cm => 0.01) so the figure is
# ~1.8 m tall instead of 180.

const FbxParser = preload("res://scripts/auto_rig/fbx_parser.gd")

var error := ""

# FBX object id -> parsed node, for the objects we care about.
var _models := {}        # id -> Model node (LimbNode/Mesh/Null)
var _geometries := {}    # id -> Geometry node
var _deformers := {}     # id -> Deformer node (Skin or Cluster)
var _materials := {}     # id -> Material node
var _textures := {}      # id -> Texture node
var _videos := {}        # id -> Video node (embedded image bytes in Content)
# Connection graph: child_id -> Array[parent_id], and parent_id -> Array[child_id].
var _parents := {}
var _children := {}
# OP (object-property) connections keyed by child id -> Array of property names,
# so we know whether a Texture feeds DiffuseColor / NormalMap / SpecularColor.
var _op_props := {}
var _unit_scale := 1.0
# Decoded texture cache (Video id -> ImageTexture) so shared images load once.
var _texture_cache := {}

# Parses `path` and returns a Node3D scene (caller owns it / adds to tree), or
# null on error (with `error` set).
func import_to_scene(path: String) -> Node3D:
	error = ""
	_reset_import_state()
	var parser := FbxParser.new()
	var root := parser.parse_file(path)
	if root.is_empty():
		error = parser.error
		return null

	_index_objects(root)
	_index_connections(root)
	_read_unit_scale(root)

	# Build the skeleton from the Model/LimbNode hierarchy.
	var skel := _build_skeleton()
	var scene := Node3D.new()
	scene.name = path.get_file().get_basename()
	if skel == null:
		# No skeleton: still surface meshes so the analyzer can size the model.
		var holder := Node3D.new()
		holder.name = "Meshes"
		scene.add_child(holder)
		_build_meshes(scene, null, {})
		return scene

	scene.add_child(skel)
	# Map FBX bone-model id -> Godot bone index, needed to skin meshes.
	_build_meshes(scene, skel, _bone_id_to_index)
	return scene

func _reset_import_state() -> void:
	_models.clear()
	_geometries.clear()
	_deformers.clear()
	_materials.clear()
	_textures.clear()
	_videos.clear()
	_parents.clear()
	_children.clear()
	_op_props.clear()
	_bone_id_to_index.clear()
	_texture_cache.clear()
	_unit_scale = 1.0

# --- Indexing ----------------------------------------------------------------

func _index_objects(root: Dictionary) -> void:
	var objects := FbxParser.find_child(root, "Objects")
	for c in objects.get("children", []):
		if c["props"].is_empty():
			continue
		var id: int = c["props"][0]
		match c["name"]:
			"Model":
				_models[id] = c
			"Geometry":
				_geometries[id] = c
			"Deformer":
				_deformers[id] = c
			"Material":
				_materials[id] = c
			"Texture":
				_textures[id] = c
			"Video":
				_videos[id] = c

func _index_connections(root: Dictionary) -> void:
	var conns := FbxParser.find_child(root, "Connections")
	for c in conns.get("children", []):
		var pr: Array = c["props"]
		if pr.size() < 3:
			continue
		# ["OO"/"OP", child_id, parent_id, (prop_name)]
		var child_id: int = pr[1]
		var parent_id: int = pr[2]
		_parents.get_or_add(child_id, []).append(parent_id)
		_children.get_or_add(parent_id, []).append(child_id)
		# OP connections name the material slot a texture drives (DiffuseColor, ...).
		if pr[0] == "OP" and pr.size() >= 4:
			_op_props.get_or_add(child_id, []).append(str(pr[3]))

func _read_unit_scale(root: Dictionary) -> void:
	_unit_scale = 0.01  # default assume cm (Mixamo)
	var settings := FbxParser.find_child(root, "GlobalSettings")
	var props := FbxParser.find_child(settings, "Properties70")
	for p in props.get("children", []):
		if p["props"].size() >= 5 and p["props"][0] == "UnitScaleFactor":
			# Value is the last property; cm => 1.0 here means file is in cm.
			var f: float = float(p["props"][p["props"].size() - 1])
			if f > 0.0:
				_unit_scale = f * 0.01
			return

# --- Skeleton ----------------------------------------------------------------

var _bone_id_to_index := {}  # FBX Model id -> Skeleton3D bone index

# Builds a Skeleton3D from Model nodes of type LimbNode (plus their root). Rest
# transforms come from each model's Lcl Translation/Rotation/Scaling.
func _build_skeleton() -> Skeleton3D:
	# Collect bone models: LimbNode, and any Null/Root that parents a LimbNode.
	var bone_ids: Array = []
	for id in _models:
		var m: Dictionary = _models[id]
		var subtype: String = m["props"][2] if m["props"].size() > 2 else ""
		if subtype == "LimbNode":
			bone_ids.append(id)
	if bone_ids.is_empty():
		return null

	# Determine parent bone for each: walk OO parents until we hit another bone
	# model (skipping non-bone intermediates). The skeleton root's parent is none.
	var bone_set := {}
	for id in bone_ids:
		bone_set[id] = true

	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	var bind_globals := _cluster_bind_globals(bone_set)

	# Order bones so parents are added before children (Skeleton3D requires it).
	var ordered := _topo_order_bones(bone_ids, bone_set)
	for id in ordered:
		var m: Dictionary = _models[id]
		var bone_name := _model_name(m)
		var idx := skel.get_bone_count()
		skel.add_bone(bone_name)
		_bone_id_to_index[id] = idx
		var parent_id := _bone_parent(id, bone_set)
		if parent_id != -1 and _bone_id_to_index.has(parent_id):
			skel.set_bone_parent(idx, _bone_id_to_index[parent_id])
		var rest := _local_transform(m)
		if bind_globals.has(id):
			var global_rest: Transform3D = bind_globals[id]
			if parent_id != -1 and bind_globals.has(parent_id):
				rest = (bind_globals[parent_id] as Transform3D).affine_inverse() * global_rest
			else:
				rest = global_rest
		skel.set_bone_rest(idx, rest)

	return skel

# Skin clusters store each bone's bind-pose global transform in TransformLink.
# Prefer that for skeleton rest reconstruction because FBX local transforms are
# split across pivots/pre-rotations/rotation orders and are easy to misapply.
func _cluster_bind_globals(bone_set: Dictionary) -> Dictionary:
	var out := {}
	for cluster_id in _deformers:
		var cluster: Dictionary = _deformers[cluster_id]
		if (cluster["props"][2] if cluster["props"].size() > 2 else "") != "Cluster":
			continue
		var bone_id := -1
		for tgt in _children.get(cluster_id, []):
			if bone_set.has(tgt):
				bone_id = tgt
				break
		if bone_id == -1 or out.has(bone_id):
			continue
		var link := FbxParser.find_child(cluster, "TransformLink")
		if link.is_empty() or link["props"].is_empty():
			continue
		var matrix = link["props"][0]
		if matrix == null or matrix.size() < 16:
			continue
		out[bone_id] = _fbx_matrix_transform(matrix)
	return out

func _fbx_matrix_transform(matrix) -> Transform3D:
	# FBX matrices are serialized row-major with translation in row 3. Godot's
	# Basis constructor takes column vectors, so transpose the 3x3 portion.
	var basis := Basis(
		Vector3(matrix[0], matrix[4], matrix[8]),
		Vector3(matrix[1], matrix[5], matrix[9]),
		Vector3(matrix[2], matrix[6], matrix[10])
	)
	var origin := Vector3(matrix[12], matrix[13], matrix[14]) * _unit_scale
	return Transform3D(basis, origin)

# Returns bone ids ordered so every bone is preceded by its bone-parent, as
# Skeleton3D.set_bone_parent requires. Stable topo sort over the bone subset of
# the connection graph.
func _topo_order_bones(bone_ids: Array, bone_set: Dictionary) -> Array:
	var ordered: Array = []
	var visited := {}
	for start in bone_ids:
		# Walk up to the chain of unvisited ancestors, then emit them root-first.
		var chain: Array = []
		var id = start
		while id != -1 and bone_set.has(id) and not visited.has(id):
			chain.append(id)
			id = _bone_parent(id, bone_set)
		for j in range(chain.size() - 1, -1, -1):
			var bid = chain[j]
			if not visited.has(bid):
				visited[bid] = true
				ordered.append(bid)
	return ordered

# Finds the nearest ancestor of `id` (via OO connections) that is itself a bone.
func _bone_parent(id: int, bone_set: Dictionary) -> int:
	var queue: Array = (_parents.get(id, []) as Array).duplicate()
	var seen := {}
	while not queue.is_empty():
		var pid = queue.pop_front()
		if seen.has(pid):
			continue
		seen[pid] = true
		if pid == 0:
			continue
		if bone_set.has(pid):
			return pid
		# Walk further up through non-bone intermediates.
		for gp in _parents.get(pid, []):
			queue.append(gp)
	return -1

# Builds a bone's local rest transform from its Lcl Translation/Rotation/Scaling
# properties, applying the file unit scale to translation.
func _local_transform(model: Dictionary) -> Transform3D:
	var t := Vector3.ZERO
	var r := Vector3.ZERO   # degrees (XYZ Euler)
	var pre := Vector3.ZERO # FBX PreRotation, degrees (XYZ Euler)
	var post := Vector3.ZERO # FBX PostRotation, degrees (XYZ Euler)
	var s := Vector3.ONE
	var props := FbxParser.find_child(model, "Properties70")
	for p in props.get("children", []):
		var pr: Array = p["props"]
		if pr.is_empty():
			continue
		var n: int = pr.size()
		match pr[0]:
			"Lcl Translation":
				t = Vector3(pr[n-3], pr[n-2], pr[n-1])
			"Lcl Rotation":
				r = Vector3(pr[n-3], pr[n-2], pr[n-1])
			"PreRotation":
				pre = Vector3(pr[n-3], pr[n-2], pr[n-1])
			"PostRotation":
				post = Vector3(pr[n-3], pr[n-2], pr[n-1])
			"Lcl Scaling":
				s = Vector3(pr[n-3], pr[n-2], pr[n-1])
	var basis := _fbx_euler_basis(pre) * _fbx_euler_basis(r) * _fbx_euler_basis(post).inverse()
	basis = basis.scaled(s)
	return Transform3D(basis, t * _unit_scale)

func _fbx_euler_basis(degrees: Vector3) -> Basis:
	# Blender's FBX importer maps FBX/Maya "XYZ" Euler composition to the same
	# matrix result Godot gets from its ZYX enum convention.
	return Basis.from_euler(Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)), EULER_ORDER_ZYX)

func _model_name(model: Dictionary) -> String:
	# props[1] is "Name\x00\x01Class"; keep just the Name part.
	var raw: String = model["props"][1] if model["props"].size() > 1 else "Bone"
	var nul := raw.find(char(0))
	if nul != -1:
		raw = raw.substr(0, nul)
	# Godot's Skeleton3D forbids ':' and '/' in bone names. Mixamo uses
	# "mixamorig:Hips"; map ':' -> '_' to match how glTF import renames them too,
	# so finger/limb detection downstream sees the same names.
	raw = raw.replace(":", "_").replace("/", "_")
	if raw.strip_edges() == "":
		raw = "Bone"
	return raw

# --- Meshes + skinning -------------------------------------------------------

# Builds a MeshInstance3D per Geometry, parented under the skeleton (so skinned
# meshes deform). `bone_index` maps FBX model id -> Godot bone index.
func _build_meshes(scene: Node3D, skel: Skeleton3D, bone_index: Dictionary) -> void:
	var skin: Skin = _build_skin(skel) if skel != null else null
	for geo_id in _geometries:
		var geo: Dictionary = _geometries[geo_id]
		var mesh := _build_one_mesh(geo, skel, bone_index)
		if mesh == null:
			continue
		# Build the textured material for this geometry, if the FBX has one. Stored
		# on the mesh surface so the UI can toggle it on/off without a re-import.
		var mat := _build_material_for_geometry(geo_id)
		if mat != null:
			mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.name = "Mesh_%d" % geo_id
		if skel != null:
			skel.add_child(mi)
			mi.skin = skin
			mi.skeleton = mi.get_path_to(skel)
		else:
			scene.add_child(mi)

func _build_skin(skel: Skeleton3D) -> Skin:
	var skin := Skin.new()
	for i in range(skel.get_bone_count()):
		var rest_global := skel.get_bone_global_rest(i)
		skin.add_bind(i, rest_global.affine_inverse())
		skin.set_bind_name(i, skel.get_bone_name(i))
	return skin

# --- Materials + embedded textures -------------------------------------------

# Builds a StandardMaterial3D for a geometry from its FBX material + embedded
# textures (diffuse -> albedo, normal -> normal map). Returns null when the FBX
# carries no usable material/texture (e.g. X Bot, which ships none).
func _build_material_for_geometry(geo_id: int) -> StandardMaterial3D:
	# Geometry connects to its Mesh Model; the Model connects to a Material.
	var material_id := -1
	for model_id in _parents.get(geo_id, []):
		if not _models.has(model_id):
			continue
		for cid in _children.get(model_id, []):
			if _materials.has(cid):
				material_id = cid
				break
		if material_id != -1:
			break
	if material_id == -1:
		return null

	# Collect textures feeding this material, keyed by the slot they drive.
	var diffuse: ImageTexture = null
	var normal: ImageTexture = null
	for tex_id in _children.get(material_id, []):
		if not _textures.has(tex_id):
			continue
		var slots: Array = _op_props.get(tex_id, [])
		var tex := _texture_from(tex_id)
		if tex == null:
			continue
		for slot in slots:
			match slot:
				"DiffuseColor", "Maya|baseColor", "BaseColor":
					diffuse = tex
				"NormalMap", "Bump", "Maya|normalCamera":
					normal = tex
	if diffuse == null and normal == null:
		return null

	var mat := StandardMaterial3D.new()
	# Render both sides. Mixamo/Adobe meshes include thin, single-sided shells
	# (hair cards, eyelashes, inner mouth) whose front faces get back-face culled,
	# making the model look "inside out" / see-through. DCC tools preview these
	# double-sided, so we match that.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if diffuse != null:
		mat.albedo_texture = diffuse
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
	return mat

# Decodes the embedded image for a Texture (via Texture -> Video -> Content) into
# an ImageTexture, cached per Video id. Returns null if no embedded image.
func _texture_from(tex_id: int) -> ImageTexture:
	# Texture connects to a Video (OO) that holds the embedded bytes.
	for vid_id in _children.get(tex_id, []):
		if not _videos.has(vid_id):
			continue
		if _texture_cache.has(vid_id):
			return _texture_cache[vid_id]
		var video: Dictionary = _videos[vid_id]
		var content := FbxParser.find_child(video, "Content")
		if content.is_empty() or content["props"].is_empty():
			continue
		var bytes = content["props"][0]
		if not (bytes is PackedByteArray) or bytes.size() < 4:
			continue
		var img := _decode_image(bytes)
		if img == null:
			continue
		var tex := ImageTexture.create_from_image(img)
		_texture_cache[vid_id] = tex
		return tex
	return null

# Decodes PNG/JPG bytes into an Image by sniffing the magic signature.
func _decode_image(bytes: PackedByteArray) -> Image:
	var img := Image.new()
	var sig := bytes.slice(0, 4).hex_encode()
	var err := ERR_FILE_UNRECOGNIZED
	if sig.begins_with("89504e47"):       # PNG
		err = img.load_png_from_buffer(bytes)
	elif sig.begins_with("ffd8"):          # JPG
		err = img.load_jpg_from_buffer(bytes)
	elif sig.begins_with("424d"):          # BMP
		err = img.load_bmp_from_buffer(bytes)
	if err != OK:
		return null
	return img

func _build_one_mesh(geo: Dictionary, skel: Skeleton3D, bone_index: Dictionary) -> ArrayMesh:
	var verts_raw = _array_of(geo, "Vertices")          # PackedFloat64Array, xyz triples
	var poly_idx = _array_of(geo, "PolygonVertexIndex") # PackedInt32Array, neg = poly end
	if verts_raw == null or poly_idx == null:
		return null

	# Control points (unique vertices), scaled to metres.
	var control_points: Array[Vector3] = []
	control_points.resize(verts_raw.size() / 3)
	for i in range(control_points.size()):
		control_points[i] = Vector3(verts_raw[i*3], verts_raw[i*3+1], verts_raw[i*3+2]) * _unit_scale

	# Per control-point skin: arrays of (bone_index, weight), filled from clusters.
	var cp_bones: Array = []
	var cp_weights: Array = []
	if skel != null:
		cp_bones.resize(control_points.size())
		cp_weights.resize(control_points.size())
		for i in range(control_points.size()):
			cp_bones[i] = PackedInt32Array()
			cp_weights[i] = PackedFloat32Array()
		_gather_skin(geo, bone_index, cp_bones, cp_weights)

	# Normals/UVs. Mixamo uses both ByPolygonVertex and ByVertice normal layers.
	var normals = _layer_array(geo, "LayerElementNormal", "Normals")
	var normal_index = _layer_array(geo, "LayerElementNormal", "NormalsIndex")
	var normal_mapping: String = _layer_text(geo, "LayerElementNormal", "MappingInformationType")
	var normal_reference: String = _layer_text(geo, "LayerElementNormal", "ReferenceInformationType")
	var uvs = _layer_array(geo, "LayerElementUV", "UV")
	var uv_index = _layer_array(geo, "LayerElementUV", "UVIndex")
	var uv_mapping: String = _layer_text(geo, "LayerElementUV", "MappingInformationType")
	var uv_reference: String = _layer_text(geo, "LayerElementUV", "ReferenceInformationType")

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Walk polygons, triangulating fans. pv = running polygon-vertex counter.
	var poly_start := 0
	var pv := 0
	var face: Array = []  # control-point indices for the current polygon
	var face_pv: Array = []  # polygon-vertex indices for the current polygon
	for k in range(poly_idx.size()):
		var ci: int = poly_idx[k]
		var end := ci < 0
		if end:
			ci = ~ci  # bitwise NOT decodes the last index of the polygon
		face.append(ci)
		face_pv.append(k)
		if end:
			# Fan-triangulate this polygon.
			for tri in range(1, face.size() - 1):
				_emit_vertex(st, face[0], face_pv[0], control_points, normals, normal_index, normal_mapping, normal_reference, uvs, uv_index, uv_mapping, uv_reference, cp_bones, cp_weights, skel)
				_emit_vertex(st, face[tri], face_pv[tri], control_points, normals, normal_index, normal_mapping, normal_reference, uvs, uv_index, uv_mapping, uv_reference, cp_bones, cp_weights, skel)
				_emit_vertex(st, face[tri+1], face_pv[tri+1], control_points, normals, normal_index, normal_mapping, normal_reference, uvs, uv_index, uv_mapping, uv_reference, cp_bones, cp_weights, skel)
			face.clear()
			face_pv.clear()

	if normals == null:
		st.generate_normals()
	st.index()
	return st.commit()

# Emits one vertex into the SurfaceTool: position (+ normal/uv/skin) for control
# point `cp` at polygon-vertex slot `pvi`.
func _emit_vertex(st: SurfaceTool, cp: int, pvi: int, control_points: Array,
		normals, normal_index, normal_mapping: String, normal_reference: String,
		uvs, uv_index, uv_mapping: String, uv_reference: String,
		cp_bones: Array, cp_weights: Array, skel: Skeleton3D) -> void:
	if skel != null and cp < cp_bones.size():
		var b: PackedInt32Array = cp_bones[cp]
		var w: PackedFloat32Array = cp_weights[cp]
		var bones4 := PackedInt32Array([0, 0, 0, 0])
		var weights4 := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		var total := 0.0
		for j in range(min(4, b.size())):
			bones4[j] = b[j]
			weights4[j] = w[j]
			total += w[j]
		if total > 0.0:
			for j in range(4):
				weights4[j] /= total
		st.set_bones(bones4)
		st.set_weights(weights4)
	var normal := _normal_for_vertex(normals, normal_index, normal_mapping, normal_reference, cp, pvi)
	if normal.length_squared() > 0.0:
		st.set_normal(normal)
	var uv := _uv_for_vertex(uvs, uv_index, uv_mapping, uv_reference, cp, pvi)
	if uv.x != INF:
		st.set_uv(uv)
	st.add_vertex(control_points[cp])

# Resolves the UV for a control point `cp` at polygon-vertex slot `pvi`, honouring
# the layer's mapping (ByPolygonVertex vs ByVertice/ByControlPoint) and reference
# (Direct vs IndexToDirect) modes, and flipping V to Godot's convention. FBX UVs
# have their origin at the bottom-left; Godot/glTF use top-left, so V := 1 - V —
# without this the texture appears vertically mirrored ("UV跑掉"). Returns a
# Vector2 with x==INF when no UV is available.
func _uv_for_vertex(uvs, uv_index, mapping: String, reference: String, cp: int, pvi: int) -> Vector2:
	if uvs == null:
		return Vector2(INF, INF)
	# Index into the per-element stream: by polygon-vertex (default) or by control point.
	var slot := pvi
	if mapping == "ByVertice" or mapping == "ByVertex" or mapping == "ByControlPoint":
		slot = cp
	# IndexToDirect adds a layer of indirection through UVIndex.
	if reference == "IndexToDirect" or reference == "Index":
		if uv_index == null or slot < 0 or slot >= uv_index.size():
			return Vector2(INF, INF)
		slot = uv_index[slot]
	if slot < 0 or slot * 2 + 1 >= uvs.size():
		return Vector2(INF, INF)
	return Vector2(uvs[slot * 2], 1.0 - uvs[slot * 2 + 1])

# Fills per-control-point bone/weight lists from the Skin/Cluster deformers bound
# to this geometry. Each Cluster names one bone (via OO connection to its Model).
func _gather_skin(geo: Dictionary, bone_index: Dictionary, cp_bones: Array, cp_weights: Array) -> void:
	var geo_id: int = geo["props"][0]
	# Geometry <- Skin <- Cluster (children in the connection graph).
	for skin_id in _children.get(geo_id, []):
		if not _deformers.has(skin_id):
			continue
		var skin: Dictionary = _deformers[skin_id]
		if (skin["props"][2] if skin["props"].size() > 2 else "") != "Skin":
			continue
		for cluster_id in _children.get(skin_id, []):
			if not _deformers.has(cluster_id):
				continue
			var cluster: Dictionary = _deformers[cluster_id]
			if (cluster["props"][2] if cluster["props"].size() > 2 else "") != "Cluster":
				continue
			# The cluster's bone = the Model it connects to.
			var bone_idx := -1
			for tgt in _children.get(cluster_id, []):
				if bone_index.has(tgt):
					bone_idx = bone_index[tgt]
					break
			if bone_idx == -1:
				continue
			var idxs = _array_of(cluster, "Indexes")
			var wts = _array_of(cluster, "Weights")
			if idxs == null or wts == null:
				continue
			for n in range(idxs.size()):
				var cp: int = idxs[n]
				if cp < 0 or cp >= cp_bones.size():
					continue
				var bones_for_cp: PackedInt32Array = cp_bones[cp]
				var weights_for_cp: PackedFloat32Array = cp_weights[cp]
				bones_for_cp.append(bone_idx)
				weights_for_cp.append(wts[n])
				cp_bones[cp] = bones_for_cp
				cp_weights[cp] = weights_for_cp

func _normal_for_vertex(normals, normal_index, mapping: String, reference: String, cp: int, pvi: int) -> Vector3:
	if normals == null:
		return Vector3.ZERO
	var slot := pvi
	if mapping == "ByVertice" or mapping == "ByVertex":
		slot = cp
	if reference == "IndexToDirect" and normal_index != null:
		if slot < 0 or slot >= normal_index.size():
			return Vector3.ZERO
		slot = normal_index[slot]
	if slot < 0 or slot * 3 + 2 >= normals.size():
		return Vector3.ZERO
	return Vector3(normals[slot * 3], normals[slot * 3 + 1], normals[slot * 3 + 2]).normalized()

# --- small helpers -----------------------------------------------------------

func _array_of(node: Dictionary, child_name: String):
	var c := FbxParser.find_child(node, child_name)
	if c.is_empty() or c["props"].is_empty():
		return null
	return c["props"][0]

func _layer_array(geo: Dictionary, layer_name: String, value_name: String):
	var layer := FbxParser.find_child(geo, layer_name)
	if layer.is_empty():
		return null
	return _array_of(layer, value_name)

func _layer_text(geo: Dictionary, layer_name: String, value_name: String) -> String:
	var layer := FbxParser.find_child(geo, layer_name)
	if layer.is_empty():
		return ""
	var c := FbxParser.find_child(layer, value_name)
	if c.is_empty() or c["props"].is_empty():
		return ""
	return str(c["props"][0])
