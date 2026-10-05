extends Node3D
## The Earth's ground as real geometry: a cube-sphere of 6 faces × N×N chunks, each with levels of detail (config
## earth.json «terrain»): far chunks coarse, the ones under the camera fine — a few km between vertices, enough to see
## a mountain from its side. The vertices are plain directions on the unit sphere; shaders/earth.gdshader raises them
## by the height map (the same material as the Earth's, so every uniform the game sets reaches the chunks too).
## The finest level is built only for the chunks near the camera (one a frame) and dropped when the camera leaves.
## Lives as a child of the Earth's node: the planet's own sphere is hidden while the chunks are there (earth.gd).

var mat: Material
var faces := 6
var n_side := 8                      # chunks along a face's side
var levels: Array = [32, 128, 256]   # quads along a chunk's side, coarse → fine
var near_k: Array = [0.0, 9.0, 3.0]  # a level is used when the camera is closer than k × the chunk's size
var _chunks: Array = []              # {centre: Vector3, size: float, lods: [MeshInstance3D or null], face, i, j}
var _queue: Array = []               # [chunk index, level] waiting to be built (one a frame)
var _t := 0.0


func setup(m: Material, cfg: Dictionary) -> void:
	mat = m
	n_side = int(cfg.get("chunks_per_face", n_side))
	if cfg.get("levels") is Array:
		levels = cfg["levels"]
	if cfg.get("near") is Array:
		near_k = cfg["near"]
	name = "PaxCorpInc3DTerrain"
	for f in faces:
		for i in n_side:
			for j in n_side:
				var c := _face_point(f, (float(i) + 0.5) / n_side * 2.0 - 1.0, (float(j) + 0.5) / n_side * 2.0 - 1.0)
				_chunks.append({"centre": c, "size": PI / 2.0 / float(n_side), "lods": [], "face": f, "i": i, "j": j})
	# The coarsest level everywhere at once (the whole planet is always drawn by something).
	for k in _chunks.size():
		_build(k, 0)


func set_material(m: Material) -> void:
	mat = m
	for c in _chunks:
		for mi in (c as Dictionary)["lods"]:
			if mi is MeshInstance3D and is_instance_valid(mi):
				(mi as MeshInstance3D).material_override = m


## Every frame: which level each chunk shows by the camera's distance (in the Earth's radii); missing fine levels are
## queued, far ones freed.
func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or not is_visible_in_tree():
		return
	var inv := global_transform.affine_inverse()
	var eye := inv * cam.global_position          # the camera in the Earth's local space (radius 1)
	for k in _chunks.size():
		var c: Dictionary = _chunks[k]
		var d := eye.distance_to(c["centre"] as Vector3) / float(c["size"])
		var want := 0
		for lv in range(levels.size() - 1, 0, -1):
			if d < float(near_k[lv]):
				want = lv
				break
		# Back side of the planet: the coarse level is enough (it is hidden anyway).
		if (c["centre"] as Vector3).dot(eye.normalized()) < -0.2:
			want = 0
		var lods: Array = c["lods"]
		var have := want
		while have > 0 and (have >= lods.size() or not (lods[have] is MeshInstance3D)):
			if not _queue.has([k, have]):
				_queue.append([k, have])
			have -= 1
		for lv in lods.size():
			var mi: Variant = lods[lv]
			if mi is MeshInstance3D:
				(mi as MeshInstance3D).visible = lv == have
		# Fine levels far from the camera are freed (memory).
		if lods.size() > 2 and lods[2] is MeshInstance3D and d > float(near_k[2]) * 3.0:
			(lods[2] as MeshInstance3D).queue_free()
			lods[2] = null
	if not _queue.is_empty():
		var q: Array = _queue.pop_front()
		_build(int(q[0]), int(q[1]))


func _build(k: int, lv: int) -> void:
	var c: Dictionary = _chunks[k]
	var lods: Array = c["lods"]
	while lods.size() <= lv:
		lods.append(null)
	if lods[lv] is MeshInstance3D:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(int(c["face"]), int(c["i"]), int(c["j"]), int(levels[lv]))
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = lv == 0
	add_child(mi)
	lods[lv] = mi


## A chunk's grid of q×q quads on its cube face, pushed onto the sphere, with a skirt (vertex colour black) round it.
func _mesh(face: int, ci: int, cj: int, q: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var n := q + 1
	verts.resize(n * n + 4 * n)
	cols.resize(n * n + 4 * n)
	var u0 := float(ci) / n_side * 2.0 - 1.0
	var v0 := float(cj) / n_side * 2.0 - 1.0
	var du := 2.0 / n_side / q
	var white := Color(1, 1, 1)
	var black := Color(0, 0, 0)
	for y in n:
		for x in n:
			var p := _face_point(face, u0 + du * x, v0 + du * y)
			verts[y * n + x] = p
			cols[y * n + x] = white
	# Front faces outward whatever the face's handedness (checked on a render: the other order showed the planet's
	# far half from the inside).
	var outward := (verts[1] - verts[0]).cross(verts[n] - verts[0]).dot(verts[0]) > 0.0
	for y in q:
		for x in q:
			var a := y * n + x
			if outward:
				idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
			else:
				idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	# Skirts: each edge's vertices again, flagged; a strip between the edge and its copy.
	var base := n * n
	var edges := [[0, 1, 0], [n * (n - 1), 1, 1], [0, n, 2], [n - 1, n, 3]]
	for e in edges:
		var start: int = e[0]
		var step: int = e[1]
		var which: int = e[2]
		for t in n:
			var src := start + step * t
			verts[base + which * n + t] = verts[src]
			cols[base + which * n + t] = black
		for t in q:
			var a2 := start + step * t
			var b2 := start + step * (t + 1)
			var sa := base + which * n + t
			var sb := sa + 1
			idx.append_array([a2, sa, b2, b2, sa, sb, a2, b2, sa, b2, sb, sa])   # both windings: no culling gap
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# The shader raises the ground by up to ~4 % (exaggerated heights): a looser box, so nothing is culled too early.
	var box := m.get_aabb()
	m.custom_aabb = box.grow(0.05)
	return m


## A point of a cube face (u, v in −1..1) on the unit sphere — the even mapping (cells keep their size near corners).
static func _face_point(face: int, u: float, v: float) -> Vector3:
	var p: Vector3
	match face:
		0: p = Vector3(1, v, -u)
		1: p = Vector3(-1, v, u)
		2: p = Vector3(u, 1, -v)
		3: p = Vector3(u, -1, v)
		4: p = Vector3(u, v, 1)
		_: p = Vector3(-u, v, -1)
	var x2 := p.x * p.x
	var y2 := p.y * p.y
	var z2 := p.z * p.z
	return Vector3(p.x * sqrt(1.0 - y2 / 2.0 - z2 / 2.0 + y2 * z2 / 3.0),
		p.y * sqrt(1.0 - z2 / 2.0 - x2 / 2.0 + z2 * x2 / 3.0),
		p.z * sqrt(1.0 - x2 / 2.0 - y2 / 2.0 + x2 * y2 / 3.0))
