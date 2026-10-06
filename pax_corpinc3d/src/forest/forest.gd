extends Node
## Trees on the 3D Earth where NASA's pictures show forest (config/forest.png: the share of forest in each 0.2° cell,
## made by pax_corporations_dev/gen_forest.py from Blue Marble 2004 and Black Marble 2016 — no trees in the cities).
## One fixed size, larger than life so a forest is seen from the game's own zoom (config/earth.json «trees»: tree_km).
## Built for speed:
##   • only around the point under the camera (radius_deg), in tiles of «tile_deg» degrees, nearest first, at most
##     BUDGET_MS a frame; the tiles left behind freed;
##   • each tile two MultiMeshes with visibility ranges (Godot's HLOD): near the camera the real model
##     (models/tree.glb), farther a 36-triangle crown of its colour, farther still nothing;
##   • tiles beyond the horizon hidden, no shadows; the camera farther than «show_r» Earth radii — no trees.
## No tree in the water: config/water.png (seas and lakes every 0.05°, tools/gen_water.py, with the relief's and the
## provinces' sea added — the Blue Marble picture had the murky Baltic as land), the provinces' map (0 — the sea), the
## height map's sea level; under the trunk and at the crown's edge (_crown_wet).
## Lives in the Earth's node (its own space, radius 1: x = cos φ sin λ, y = sin φ, z = cos φ cos λ, like the layers),
## the trees stand on the ground (earth.surface_radius). Switched by «Слои глобуса» (trees) and the quality (eco — none).

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const CELL_DEG := 0.2
const STEP_SEC := 0.25
const BUDGET_MS := 3
const EARTH_KM := 6371.0

var mod: PaxMod
var game: PaxGame
var enabled := true                 # the quality (eco and off — none)
var radius_deg := 12.0
var per_cell := 2.0
var cfg: Dictionary = {}
var _map := PackedByteArray()
var _mw := 0
var _mh := 0
var _tree: Dictionary = {}          # {mesh, base}: the model, base centre at the origin, height 1
var _crown: Dictionary = {}
var _loaded := false
var _holder: Node3D
var _parent: Node3D
var _tiles: Dictionary = {}         # "i|j" -> {near, far, n, a, count}
var _queue: Array = []
var _t := 0.0
var _count := 0


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DForest"
	process_mode = Node.PROCESS_MODE_ALWAYS
	var raw: Variant = GameApi.json(m, "config/earth.json", {})
	var all: Dictionary = raw if raw is Dictionary else {}
	cfg = all.get("trees", {}) if all.get("trees") is Dictionary else {}
	radius_deg = float(cfg.get("radius_deg", 12.0))


func start(g: PaxGame) -> void:
	clear()
	game = g


func clear() -> void:
	if is_instance_valid(_holder):
		_holder.queue_free()
	_holder = null
	_parent = null
	_tiles.clear()
	_queue.clear()
	_count = 0


func rebuild() -> void:
	for k in _tiles.keys():
		_free_tile(str(k))
	_queue.clear()
	_count = 0
	_t = 0.0


var _ids: Image
var _height_seen := -1
var _ground_seen := false
var _water := PackedByteArray()
var _ww := 0
var _wh := 0


func _wet(d: Vector3, r: float, ground_ok: bool) -> bool:
	if _ww > 0:
		var wx := clampi(int(fposmod(atan2(d.x, d.z) / TAU + 0.5, 1.0) * _ww), 0, _ww - 1)
		var wy := clampi(int(acos(clampf(d.y, -1.0, 1.0)) / PI * _wh), 0, _wh - 1)
		if _water[wy * _ww + wx] > 127:
			return true
	if _ids != null:
		var w := _ids.get_width()
		var h := _ids.get_height()
		var x := clampi(int(fposmod(atan2(d.x, d.z) / TAU + 0.5, 1.0) * w), 0, w - 1)
		var y := clampi(int(acos(clampf(d.y, -1.0, 1.0)) / PI * h), 0, h - 1)
		var c := _ids.get_pixel(x, y)
		if roundi(c.r * 255.0) + roundi(c.g * 255.0) * 256 <= 0:
			return true
	# The 3D ground at the sea's level is water as the player sees it (the coast drawn by the height map).
	return ground_ok and r <= 1.0000005


## A tree's crown over the water: four points round the trunk at the crown's radius (a tree is far larger than life —
## its crown ~3.4 km wide reached over the shore, and on an islet smaller than itself it stood in the sea).
func _crown_wet(d: Vector3, reach: float, ground_ok: bool, earth: Variant) -> bool:
	var east := Vector3.UP.cross(d)
	if east.length() < 0.001:
		return false
	east = east.normalized()
	var north := d.cross(east).normalized()
	for o in [east, -east, north, -north]:
		var p := (d + (o as Vector3) * reach).normalized()
		var r := float((earth as Object).call("surface_radius", p)) if ground_ok else 1.0
		if _wet(p, r, ground_ok):
			return true
	return false


func built_count() -> int:
	return _count


func _shown() -> bool:
	var layers: Variant = mod.get("layers")
	if not enabled or not bool(cfg.get("enabled", true)) or not (layers is Object) or not is_instance_valid(layers):
		return false
	if not bool((layers as Object).get("active")):
		return false
	var sw: Variant = (layers as Object).get("switches")
	return not (sw is Object) or bool((sw as Object).call("is_on", "trees"))


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(delta)
	GameApi.perf("corpinc3d.forest.process", t0)


func _process_body(delta: float) -> void:
	var earth: Variant = mod.get("earth")
	var node: Variant = (earth as Object).call("node") if earth is Object and is_instance_valid(earth) else null
	if not _shown() or not (node is Node3D):
		if is_instance_valid(_holder):
			_holder.visible = false
		return
	if node != _parent or not is_instance_valid(_holder):
		clear()
		_parent = node
		_holder = Node3D.new()
		_holder.name = "PaxCorpInc3DForestTrees"
		(node as Node3D).add_child(_holder)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var local := (node as Node3D).global_transform.affine_inverse() * cam.global_position
	if local.length() > float(cfg.get("show_r", 2.2)):
		_holder.visible = false
		return
	_holder.visible = true
	if not _loaded:
		_load()
		return
	# The provinces' map came (read on a worker thread by earth.gd): the tiles made before it, with the water mask
	# alone, are made again with it — the trees stood in the sea where the mask was wrong (the Baltic, the skerries).
	if _ids == null and earth is Object and (earth as Object).has_method("ids_image"):
		_ids = (earth as Object).call("ids_image") as Image
		if _ids != null and not _tiles.is_empty():
			rebuild()
	# The ground came (the height map is read on a worker thread): the trees stand on it again.
	var hv := int((earth as Object).get("height_version")) if earth is Object else 0
	var ground_now := (earth as Object).call("height_texture") != null if earth is Object else false
	if hv != _height_seen or ground_now != _ground_seen:
		_height_seen = hv
		_ground_seen = ground_now
		rebuild()
	if _tree.is_empty() and _crown.is_empty():
		return
	_t -= delta
	if _t <= 0.0:
		_t = STEP_SEC
		_stream(local)
	_build_some(node as Node3D)


static func dir_of(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	return Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l))


## A patch around n (unit), a radians wide, seen from cam (the Earth's space): not beyond the horizon.
static func faces(n: Vector3, cam: Vector3, a: float) -> bool:
	var d := cam.length()
	if d <= 1.0:
		return true
	var horizon := acos(clampf(1.0 / d, -1.0, 1.0))
	return acos(clampf(n.dot(cam) / d, -1.0, 1.0)) <= horizon + a + 0.03


func _stream(cam: Vector3) -> void:
	var sub := cam.normalized()
	var sub_lat := rad_to_deg(asin(clampf(sub.y, -1.0, 1.0)))
	var tile := clampf(float(cfg.get("tile_deg", 4.0)), 1.0, 30.0)
	var rows := int(round(180.0 / tile))
	var cols := int(round(360.0 / tile))
	var half := deg_to_rad(tile) * 0.75
	var radius := deg_to_rad(radius_deg)
	var want: Array = []
	var i0 := maxi(0, floori((sub_lat - radius_deg - tile + 90.0) / tile))
	var i1 := mini(rows - 1, floori((sub_lat + radius_deg + tile + 90.0) / tile))
	for i in range(i0, i1 + 1):
		for j in cols:
			var c := dir_of(-90.0 + (float(i) + 0.5) * tile, -180.0 + (float(j) + 0.5) * tile)
			var ang := c.angle_to(sub)
			if ang <= radius + half:
				want.append([ang, "%d|%d" % [i, j], i, j])
	var keep := {}
	for w in want:
		keep[str((w as Array)[1])] = true
	for k in _tiles.keys():
		if not keep.has(k):
			_free_tile(str(k))
	want.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	_queue.clear()
	for w in want:
		var wa: Array = w
		if not _tiles.has(str(wa[1])):
			_queue.append([str(wa[1]), int(wa[2]), int(wa[3])])
	for k in _tiles.keys():
		var td: Dictionary = _tiles[k]
		var vis := faces(td["n"], cam, float(td["a"]))
		for part in ["near", "far"]:
			if is_instance_valid(td[part]):
				(td[part] as Node3D).visible = vis


func _build_some(node: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	while not _queue.is_empty() and Time.get_ticks_msec() - t0 < BUDGET_MS:
		var q: Array = _queue.pop_front()
		if not _tiles.has(str(q[0])):
			_make_tile(str(q[0]), int(q[1]), int(q[2]), node)


func _make_tile(key: String, i: int, j: int, node: Node3D) -> void:
	var tile := clampf(float(cfg.get("tile_deg", 4.0)), 1.0, 30.0)
	var lat0 := -90.0 + float(i) * tile
	var lon0 := -180.0 + float(j) * tile
	var centre := dir_of(lat0 + tile * 0.5, lon0 + tile * 0.5)
	var size := float(cfg.get("tree_km", 8.0)) / EARTH_KM   # a tree's height, Earth radii (fixed, larger than life)
	var min_forest := float(cfg.get("min_forest", 0.2))
	var earth: Variant = mod.get("earth")
	var ground_ok := earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius")
	# Water under a tree: the provinces' map (earth.gd ids_image: 0 — sea and lakes), else the height map's sea level.
	# A cell of forest.png is 0.2° (~20 km): on a coast or by a lake half its trees stood in the water.
	if _ids == null and earth is Object and is_instance_valid(earth) and (earth as Object).has_method("ids_image"):
		_ids = (earth as Object).call("ids_image") as Image
	var spots: Array = []
	var n := int(round(tile / CELL_DEG))
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
				var d := dir_of(lat + (_rnd(h, 1 + t * 4) - 0.5) * CELL_DEG, lon + (_rnd(h, 2 + t * 4) - 0.5) * CELL_DEG)
				var r := float((earth as Object).call("surface_radius", d)) if ground_ok else 1.0
				if _wet(d, r, ground_ok) or _crown_wet(d, size * 0.42, ground_ok, earth):
					continue
				spots.append([d, r, _rnd(h, 3 + t * 4) * TAU, 0.75 + _rnd(h, 4 + t * 4) * 0.5])
	var td := {"near": null, "far": null, "n": centre, "a": deg_to_rad(tile) * 0.75, "count": spots.size()}
	_tiles[key] = td
	if spots.is_empty():
		return
	var rw := maxf(node.global_transform.basis.get_scale().x, 1e-6)   # the Earth's radius in world units
	var near_r := float(cfg.get("near_r", 0.05))
	var far_r := float(cfg.get("far_r", 0.7))
	if not _tree.is_empty():
		td["near"] = _instances(spots, _tree, size, centre, 0.0, near_r * rw)
	if not _crown.is_empty():
		td["far"] = _instances(spots, _crown, size, centre, near_r * rw if not _tree.is_empty() else 0.0, far_r * rw)
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
		var basis := Basis(east, up, east.cross(up).normalized()).rotated(up, float(s[2])).scaled(Vector3.ONE * size * float(s[3]))
		mm.set_instance_transform(k, Transform3D(basis, up * float(s[1]) - centre) * base)
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


func _forest(lat: float, lon: float) -> float:
	if _map.is_empty():
		return 0.0
	var x := clampi(int((lon + 180.0) / 360.0 * float(_mw)), 0, _mw - 1)
	var y := clampi(int((90.0 - lat) / 180.0 * float(_mh)), 0, _mh - 1)
	return float(_map[y * _mw + x]) / 255.0


static func _rnd(h: int, slot: int) -> float:
	return float(hash(h + slot * 7919) & 0xFFFF) / 65535.0


func _load() -> void:
	_loaded = true
	var img: Image = null
	var bytes: Variant = mod.read_bytes(str(cfg.get("map", "config/forest.png")))
	if bytes is PackedByteArray and not (bytes as PackedByteArray).is_empty():
		img = Image.new()
		if img.load_png_from_buffer(bytes) != OK:
			img = null
	if img == null or img.is_empty():
		mod.log_warning("3D trees: no forest map")
		return
	img.convert(Image.FORMAT_L8)
	_mw = img.get_width()
	_mh = img.get_height()
	_map = img.get_data()
	# The water mask (config/water.png, tools/gen_water.py: seas and lakes every 0.05°): no tree stands in it.
	var wb: Variant = mod.read_bytes(str(cfg.get("water", "config/water.png")))
	if wb is PackedByteArray and not (wb as PackedByteArray).is_empty():
		var wi := Image.new()
		if wi.load_png_from_buffer(wb) == OK and not wi.is_empty():
			wi.convert(Image.FORMAT_L8)
			_ww = wi.get_width()
			_wh = wi.get_height()
			_water = wi.get_data()
	var mesh := _model_mesh()
	_tree = _normalized(mesh)
	var crown := SphereMesh.new()
	crown.radius = 0.42
	crown.height = 0.84
	crown.radial_segments = 6
	crown.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _average_colour(mesh, Color(0.12, 0.27, 0.1))
	mat.roughness = 1.0
	crown.material = mat
	_crown = {"mesh": crown, "base": Transform3D(Basis.IDENTITY, Vector3(0, 0.58, 0))}
	mod.log_info("3D trees: forest map %dx%d, tree model %s" % [_mw, _mh, "yes" if not _tree.is_empty() else "no (crowns only)"])


func _model_mesh() -> Mesh:
	var node: Node3D = mod.model("models/" + str(cfg.get("файл", cfg.get("file", "tree.glb"))))
	if node == null:
		return null
	var mesh: Mesh = null
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if (n as MeshInstance3D).mesh != null:
			mesh = (n as MeshInstance3D).mesh
			break
	node.queue_free()
	return mesh


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
	return Color(c.r * 0.85, c.g * 0.85, c.b * 0.85)


static func _normalized(mesh: Mesh) -> Dictionary:
	if mesh == null:
		return {}
	var box := mesh.get_aabb()
	var h := maxf(box.size.y, 1e-6)
	var c := box.get_center()
	var base := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE / h), Vector3.ZERO) * Transform3D(Basis.IDENTITY, Vector3(-c.x, -box.position.y, -c.z))
	return {"mesh": mesh, "base": base}
