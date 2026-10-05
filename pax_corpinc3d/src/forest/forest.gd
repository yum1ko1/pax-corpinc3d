extends Node
## Trees on the 3D Earth where NASA's pictures show forest (config/forest.png: the share of forest in each 0.2° cell,
## made by tools/gen_forest.py from Blue Marble 2004 and Black Marble 2016 — no trees in the cities).
## Built for speed close to the planet:
##   • only around the point under the camera (radius_deg), in tiles of «tile_deg» degrees, built nearest first for
##     at most BUDGET_MS a frame, the tiles left behind freed;
##   • each tile is two MultiMeshes with visibility ranges (Godot's HLOD): near the camera the real model
##     (models/tree.glb, 8.8 thousand triangles), farther a 36-triangle crown of its colour, farther still nothing;
##   • tiles beyond the horizon are hidden (globe.faces), the frustum drops the rest off screen;
##   • no shadows; the camera farther than «show_r» Earth radii — no trees at all.
## The same fixed size as the buildings (globe.size_100m), children of the Earth's node — they turn with it.

const Globe := preload("res://mods/pax_corpinc3d/src/globe/globe.gd")
const BODY := "Земля"
const REF_M := 100.0
const CELL_DEG := 0.2
const STEP_SEC := 0.25               # how often the tiles around the camera are looked over
const BUDGET_MS := 3                 # tiles are built every frame for at most this long (no stutter, no long wait)

var mod: PaxMod
var globe: Object                   # globe.gd: stage_ok, size_100m, dir_of, lat_lon_of, cam_local
var game: PaxGame
# Quality (settings/quality.gd; the window «3D»):
var enabled := true
var radius_deg := 12.0              # trees around the point under the camera, degrees
var per_cell := 2.0                 # trees in a cell of full forest
# Config (config/models.json «trees»):
var height_m := 40.0
var tile_deg := 4.0
var near_r := 0.05
var far_r := 0.7
var show_r := 2.2
var min_forest := 0.2
var cone_color := Color(0.12, 0.27, 0.1)
var _file := "tree.glb"
var _map_path := "config/forest.png"

var _map := PackedByteArray()
var _mw := 0
var _mh := 0
var _tree: Dictionary = {}          # {mesh, base} — the real model, normalized to height 1; {} — not loaded yet
var _cone: Dictionary = {}          # the far stand-in
var _loaded := false
var _holder: Node3D
var _body: Node3D
var _tiles: Dictionary = {}         # "i|j" -> {near, far: MultiMeshInstance3D, n: centre, a: angular radius, count}
var _t := 0.0
var _count := 0
var _queue: Array = []              # [key, i, j] — tiles to build, the nearest first


func setup(m: PaxMod, g: Object) -> void:
	mod = m
	globe = g
	var cfg: Variant = m.load_json("config/models.json", {})
	var tc: Dictionary = (cfg as Dictionary).get("trees", {}) if cfg is Dictionary and (cfg as Dictionary).get("trees") is Dictionary else {}
	_file = str(tc.get("файл", _file))
	_map_path = str(tc.get("map", _map_path))
	height_m = float(tc.get("height_m", height_m))
	tile_deg = clampf(float(tc.get("tile_deg", tile_deg)), 1.0, 30.0)
	near_r = float(tc.get("near_r", near_r))
	far_r = float(tc.get("far_r", far_r))
	show_r = float(tc.get("show_r", show_r))
	min_forest = float(tc.get("min_forest", min_forest))
	var cc: Variant = tc.get("cone_color")
	if cc is Array and (cc as Array).size() >= 3:
		cone_color = Color(float(cc[0]), float(cc[1]), float(cc[2]))


func _ready() -> void:
	name = "PaxCorpInc3DForest"
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(g: PaxGame) -> void:
	clear()
	game = g


func clear() -> void:
	if is_instance_valid(_holder):
		_holder.queue_free()
	_holder = null
	_body = null
	_tiles.clear()
	_queue.clear()
	_count = 0


## Built again with the current quality (the tiles are made anew around the camera).
func rebuild() -> void:
	for k in _tiles.keys():
		_free_tile(str(k))
	_queue.clear()
	_count = 0
	_t = 0.0


func built_count() -> int:
	return _count


## The trees are on the screen now (the auto quality measures the frames only then).
func showing() -> bool:
	return enabled and is_instance_valid(_holder) and _holder.visible and _count > 0


func _process(delta: float) -> void:
	if game == null or not is_instance_valid(game.main) or globe == null:
		return
	var ok := enabled and bool(globe.get("stage_ok"))
	var body := game.body_node(BODY) if ok else null
	if body == null:
		if is_instance_valid(_holder):
			_holder.visible = false
		return
	if body != _body or not is_instance_valid(_holder):
		clear()
		_body = body
		_holder = Node3D.new()
		_holder.name = "PaxCorpInc3DForest"
		body.add_child(_holder)
	var cam: Vector3 = globe.call("cam_local", body)
	if not cam.is_finite() or cam.length() > show_r:
		_holder.visible = false
		return
	_holder.visible = true
	if not _loaded:
		_load()   # the map and both meshes — once, here, not at the mod's start
		return
	if _tree.is_empty() and _cone.is_empty():
		return
	_t -= delta
	if _t <= 0.0:
		_t = STEP_SEC
		_stream(cam)
	_build_some(body)


# ---------- the tiles around the camera ----------

func _stream(cam: Vector3) -> void:
	var sub: Vector2 = globe.call("lat_lon_of", cam)
	var sub_dir := cam.normalized()
	var radius := deg_to_rad(radius_deg)
	var rows := int(round(180.0 / tile_deg))
	var cols := int(round(360.0 / tile_deg))
	var half := deg_to_rad(tile_deg) * 0.75   # a tile's angular radius (its half-diagonal, rounded up)
	var want: Array = []                      # [angle, key, i, j]
	var i0 := maxi(0, floori((sub.x - radius_deg - tile_deg + 90.0) / tile_deg))
	var i1 := mini(rows - 1, floori((sub.x + radius_deg + tile_deg + 90.0) / tile_deg))
	for i in range(i0, i1 + 1):
		for j in cols:
			var c: Vector3 = globe.call("dir_of", -90.0 + (float(i) + 0.5) * tile_deg, -180.0 + (float(j) + 0.5) * tile_deg)
			var ang := c.angle_to(sub_dir)
			if ang <= radius + half:
				want.append([ang, "%d|%d" % [i, j], i, j])
	var keep := {}
	for w in want:
		keep[str((w as Array)[1])] = true
	for k in _tiles.keys():
		if not keep.has(k):
			_free_tile(str(k))
	# The missing tiles, the nearest first (built by _build_some, a few every frame).
	want.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	_queue.clear()
	for w in want:
		var wa: Array = w
		if not _tiles.has(str(wa[1])):
			_queue.append([str(wa[1]), int(wa[2]), int(wa[3])])
	for k in _tiles.keys():
		var td: Dictionary = _tiles[k]
		var vis := Globe.faces(td["n"], cam, float(td["a"]))
		for part in ["near", "far"]:
			if is_instance_valid(td[part]):
				(td[part] as Node3D).visible = vis


func _build_some(body: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	while not _queue.is_empty() and Time.get_ticks_msec() - t0 < BUDGET_MS:
		var q: Array = _queue.pop_front()
		if not _tiles.has(str(q[0])):
			_make_tile(str(q[0]), int(q[1]), int(q[2]), body)


func _make_tile(key: String, i: int, j: int, body: Node3D) -> void:
	var lat0 := -90.0 + float(i) * tile_deg
	var lon0 := -180.0 + float(j) * tile_deg
	var centre: Vector3 = globe.call("dir_of", lat0 + tile_deg * 0.5, lon0 + tile_deg * 0.5)
	var size := float(globe.get("size_100m")) * height_m / REF_M   # a tree's height in Earth radii
	var spots: Array = []   # [position on the unit sphere, yaw, scale]
	var n := int(round(tile_deg / CELL_DEG))
	for ci in n:
		for cj in n:
			var lat := lat0 + (float(ci) + 0.5) * CELL_DEG
			var lon := lon0 + (float(cj) + 0.5) * CELL_DEG
			var f := _forest(lat, lon)
			if f < min_forest:
				continue
			var h := hash(Vector2i(roundi(lat * 10.0), roundi(lon * 10.0)))
			var trees := int(floor(f * per_cell + _rnd(h, 0)))
			for t in trees:
				var tlat := lat + (_rnd(h, 1 + t * 4) - 0.5) * CELL_DEG
				var tlon := lon + (_rnd(h, 2 + t * 4) - 0.5) * CELL_DEG
				spots.append([globe.call("dir_of", tlat, tlon), _rnd(h, 3 + t * 4) * TAU, 0.75 + _rnd(h, 4 + t * 4) * 0.5])
	var td := {"near": null, "far": null, "n": centre, "a": deg_to_rad(tile_deg) * 0.75, "count": spots.size()}
	_tiles[key] = td
	if spots.is_empty():
		return
	var radius_w := maxf(body.global_transform.basis.get_scale().x, 1e-6)   # the Earth's radius in world units
	if not _tree.is_empty():
		td["near"] = _instances(spots, _tree, size, centre, 0.0, near_r * radius_w)
	if not _cone.is_empty():
		td["far"] = _instances(spots, _cone, size, centre, near_r * radius_w if not _tree.is_empty() else 0.0, far_r * radius_w)
	_count += spots.size()


func _instances(spots: Array, model: Dictionary, size: float, centre: Vector3, from: float, to: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = model["mesh"]
	mm.instance_count = spots.size()
	var base: Transform3D = model["base"]
	for k in spots.size():
		var s: Array = spots[k]
		var up: Vector3 = s[0]
		var east := Vector3.UP.cross(up)
		if east.length() < 0.001:
			east = Vector3.RIGHT
		east = east.normalized()
		var basis := Basis(east, up, east.cross(up).normalized()).rotated(up, float(s[1])).scaled(Vector3.ONE * size * float(s[2]))
		mm.set_instance_transform(k, Transform3D(basis, up - centre) * base)
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.position = centre
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_begin = from
	mi.visibility_range_end = to
	mi.visibility_range_end_margin = to * 0.05
	if from > 0.0:
		mi.visibility_range_begin_margin = from * 0.05
	_holder.add_child(mi)
	return mi


func _free_tile(key: String) -> void:
	var td: Dictionary = _tiles.get(key, {})
	for part in ["near", "far"]:
		if is_instance_valid(td.get(part)):
			(td[part] as Node).queue_free()
	_count -= int(td.get("count", 0))
	_tiles.erase(key)


# ---------- data ----------

## The share of forest at a point, 0..1 (the map's nearest cell).
func _forest(lat: float, lon: float) -> float:
	if _map.is_empty():
		return 0.0
	var x := clampi(int((lon + 180.0) / 360.0 * float(_mw)), 0, _mw - 1)
	var y := clampi(int((90.0 - lat) / 180.0 * float(_mh)), 0, _mh - 1)
	return float(_map[y * _mw + x]) / 255.0


## A stable pseudo-random 0..1 from a cell's hash and a slot: the same trees stand in the same places every time.
static func _rnd(h: int, slot: int) -> float:
	return float(hash(h + slot * 7919) & 0xFFFF) / 65535.0


func _load() -> void:
	_loaded = true
	var tex: Texture2D = mod.texture(_map_path)
	var img: Image = tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		mod.log_warning("3D trees: no forest map %s" % _map_path)
		return
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_L8)
	_mw = img.get_width()
	_mh = img.get_height()
	_map = img.get_data()
	var tree_mesh := _model_mesh()
	_tree = _normalized(tree_mesh)
	# The far stand-in: a rough round crown (36 triangles) of the model's own average colour, so the switch from
	# the model to it and back is hardly seen.
	var crown := SphereMesh.new()
	crown.radius = 0.42
	crown.height = 0.84
	crown.radial_segments = 6
	crown.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _average_colour(tree_mesh, cone_color)
	mat.roughness = 1.0
	crown.material = mat
	_cone = {"mesh": crown, "base": Transform3D(Basis.IDENTITY, Vector3(0, 0.58, 0))}
	mod.log_info("3D trees: forest map %dx%d, tree model %s" % [_mw, _mh, "yes" if not _tree.is_empty() else "no (cones only)"])


func _model_mesh() -> Mesh:
	var node: Node3D = mod.model("models/" + _file)
	if node == null:
		return null
	var mesh: Mesh = null
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if (n as MeshInstance3D).mesh != null:
			mesh = (n as MeshInstance3D).mesh
			break
	node.queue_free()
	return mesh


## The average colour of a mesh's first texture (its albedo × the material's colour); fallback — none.
static func _average_colour(mesh: Mesh, fallback: Color) -> Color:
	if mesh == null or mesh.get_surface_count() == 0:
		return fallback
	var mat := mesh.surface_get_material(0) as BaseMaterial3D
	if mat == null:
		return fallback
	var tex := mat.albedo_texture
	if tex == null:
		return mat.albedo_color
	var img := tex.get_image()
	if img == null or img.is_empty():
		return fallback
	if img.is_compressed():
		img.decompress()
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var c := img.get_pixel(0, 0) * mat.albedo_color
	return Color(c.r * 0.85, c.g * 0.85, c.b * 0.85)   # a crown in its own shade: a little darker than its leaves


## A mesh with its base's centre at the origin and height 1: {mesh, base}; {} — none.
static func _normalized(mesh: Mesh) -> Dictionary:
	if mesh == null:
		return {}
	var box := mesh.get_aabb()
	var h := maxf(box.size.y, 1e-6)
	var c := box.get_center()
	var base := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE / h), Vector3.ZERO) * Transform3D(Basis.IDENTITY, Vector3(-c.x, -box.position.y, -c.z))
	return {"mesh": mesh, "base": base}
