extends Node3D
## The game's networks (the flat map's layers «дороги», «жд», «ток», «сеть») as 3D geometry on the Earth: roads with a
## raised bed, markings and traffic, railways with ballast, sleepers, rails and trains, power lines on lattice
## pylons with sagging wires, communication masts with blinking lights (shaders/roads.gdshader, config earth.json
## «roads»). Where: the game's table by province (region_nets: roads, communications, rails, power 0..1) — the
## more a province built, the denser its network; nothing where it built nothing or over the sea.
## How: every network is a grid of towns on the cube's faces (one town a cell, the cells «spacing_km» apart; where a
## city of the companies stands, that cell's town is the city — the roads leave the cities), a road joins a town to
## its neighbours right, up and across (from a city always); which of the links are built is chosen by the link itself
## (a hash) against the province's level — the same every time, so a network grows and never jumps. The links bend a
## little and are cut where they would cross the sea.
## Pieces: the faces are cut into 8×8 chunks; far ones carry the highways and railways only, coarse (screen-wide at
## least min_px pixels); the ones under a low camera everything, fine, with pylons and masts. In every city of the
## companies (globe.gd) a grid of streets runs between the buildings and joins them. Built in the
## background within a time budget a frame. Lives as a child of the Earth's node (the planet's own space, radius 1).

const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")   # game 0.24's English names
const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const ID_AT: Array = ["id_в", "id_at", "id_of"]                   # the provinces' book: the id at a direction
const KIND_HIGHWAY := 0.0
const KIND_ROAD := 0.25
const KIND_RAIL := 0.5
const KIND_WIRE := 0.75
const CHUNKS := 8
const EARTH_KM := 6371.0
const NETS: Array = [
	{"bit": 1, "channel": 0, "kind": KIND_HIGHWAY, "km": 280.0, "seed": 11, "keep0": 0.55, "keep1": 0.35, "min": 0.02, "half": 0.55, "far": true},
	{"bit": 1, "channel": 0, "kind": KIND_ROAD, "km": 80.0, "seed": 23, "keep0": 0.2, "keep1": 0.65, "min": 0.25, "half": 0.28, "far": false},
	# Rails and power lines run between real cities (config/links3d.json: the highways of map_nets.py — rails between
	# cities from 500 000, power along every highway), not over the lattice of the roads' «towns».
	{"bit": 2, "channel": 2, "kind": KIND_RAIL, "km": 330.0, "seed": 37, "keep0": 0.35, "keep1": 0.45, "min": 0.02, "half": 0.22, "far": true, "graph": "rail"},
	# Power lines are built from afar too (only the wires there; the pylons close in): near-only they were never seen
	# from the game's own zoom (~1 600 km up).
	{"bit": 8, "channel": 3, "kind": KIND_WIRE, "km": 220.0, "seed": 53, "keep0": 0.45, "keep1": 0.35, "min": 0.02, "half": 0.0, "far": true, "graph": "power"},
]

var mod: PaxMod
var game: PaxGame
var cfg: Dictionary = {}
var mat: ShaderMaterial
var mask := 3                              # the game's bits: 1 roads, 2 rails, 4 communications, 8 power
var _levels := PackedByteArray()           # 4 bytes a province id (row 0 of region_nets)
var _levels_n := 0
var _levels_sig := 0
var _chunks: Array = []                    # {face, i, j, centre, lod, want, sig, node, version}
var _building := false
var _graph: Dictionary = {}               # "face|i|j" -> [[from dir, to dir, rail]] — the cities' links by the chunk of their middle
var _pylon: Mesh
var _mast: Mesh
var _surface: Callable                     # dir -> the ground's radius (earth.surface_radius)
var _pop := PackedFloat32Array()           # 360 × 180 (a degree a cell): how built-up the land is, from the cities
var _snap: Dictionary = {}                 # "face|cx|cy|seed" -> a city's place on its face: the town there is the city
var _globe_ver := -1
var _streets: Node3D


func setup(m: PaxMod, roads_cfg: Dictionary, shader: Shader, blink: Shader) -> void:
	mod = m
	cfg = roads_cfg
	name = "PaxCorpInc3DRoads"
	mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("min_px", float(cfg.get("min_px", 1.6)))
	mat.set_shader_parameter("wire_px", float(cfg.get("wire_px", 3.0)))
	mat.set_shader_parameter("pull", float(cfg.get("pull", 0.012)))
	mat.set_shader_parameter("traffic", float(cfg.get("traffic", 1.0)))
	for f in 6:
		for i in CHUNKS:
			for j in CHUNKS:
				var u := -1.0 + (float(i) + 0.5) * 2.0 / CHUNKS
				var v := -1.0 + (float(j) + 0.5) * 2.0 / CHUNKS
				_chunks.append({"face": f, "i": i, "j": j, "centre": face_dir(f, u, v), "lod": -1, "want": -1, "sig": -1,
					"node": null, "version": 0})
	_pop_grid(GameApi.json(m, "config/cities.json", {}))
	_load_graph(GameApi.json(m, "config/links3d.json", {}))
	_pylon = _make_pylon()
	_mast = _make_mast(blink)


func start(g: PaxGame, surface: Callable) -> void:
	game = g
	_surface = surface


## The ground's height map for the ribbons (the same as the terrain's).
func set_ground(height: Texture2D, exag: float) -> void:
	mat.set_shader_parameter("height_map", height)
	mat.set_shader_parameter("use_height_map", 1.0 if height != null else 0.0)
	mat.set_shader_parameter("height_exag", exag)


func set_sun(dir: Vector3) -> void:
	mat.set_shader_parameter("sun_dir", dir)


## The game's table (region_nets, a texture of n × 2) and the layers switched on.
func set_data(nets: Texture2D, layers_mask: int) -> void:
	if layers_mask != mask:
		mask = layers_mask
		for c in _chunks:
			_show_kinds(c)
		if is_instance_valid(_streets):
			_streets.visible = (mask & 1) != 0
	if nets == null or _building:
		return   # while a piece is built (maybe on a worker thread) the levels stay; the next call brings them
	var img := nets.get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var w := img.get_width()
	var row := data.slice(0, w * 4)
	# Levels in steps of a tenth: a network is rebuilt only when a province really built more.
	var sig := 0
	for k in range(0, row.size(), 4):
		sig = (sig * 31 + int(row[k]) / 25 + int(row[k + 1]) / 25 * 7 + int(row[k + 2]) / 25 * 13 + int(row[k + 3]) / 25 * 17) & 0x7FFFFFFF
	if sig == _levels_sig and _levels_n == w:
		return
	_levels = row
	_levels_n = w
	_levels_sig = sig
	for c in _chunks:
		c["sig"] = -1   # rebuilt in turn (the old pieces stay until then)


# ---------- which pieces, how fine ----------

func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(_delta)
	GameApi.perf("corpinc3d.roads3d.process", t0)


func _process_body(_delta: float) -> void:
	if not is_visible_in_tree() or (_levels_n == 0 and _pop.is_empty()) or game == null:
		return
	_watch_cities()
	if _ids == null:
		var earth: Variant = mod.get("earth")
		if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("ids_image"):
			_ids = (earth as Object).call("ids_image") as Image
			_has_book = _ids != null
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := global_transform.affine_inverse() * cam.global_position
	var alt := eye.length() - 1.0
	# The widening's measure from here (shaders/roads.gdshader eye_local, px_angle): far lines keep min_px pixels.
	var vh := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	mat.set_shader_parameter("eye_local", eye)
	mat.set_shader_parameter("px_angle", 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / vh)
	var size := PI * 0.5 / CHUNKS            # a chunk's angle at the face's middle
	var near_alt := float(cfg.get("near_below_km", 900.0)) / EARTH_KM
	var best: Dictionary = {}
	var best_d := INF
	for c in _chunks:
		var centre: Vector3 = c["centre"]
		var ang := centre.angle_to(eye.normalized())
		var want := -1
		if ang < acos(clampf(1.0 / maxf(eye.length(), 1.0001), -1.0, 1.0)) + size * 1.2:
			want = 0   # on the visible side
		if want == 0 and alt < near_alt and ang < size * float(cfg.get("near_chunks", 1.3)):
			want = 1
		c["want"] = want
		if want < 0 and c["node"] != null:
			(c["node"] as Node3D).visible = false
		elif want >= 0 and c["node"] != null:
			(c["node"] as Node3D).visible = true
		var stale := want >= 0 and (int(c["lod"]) != want or int(c["sig"]) != _levels_sig)
		if stale and not _building:
			var d := ang - float(want) * 10.0   # the near ones first
			if d < best_d:
				best_d = d
				best = c
	if not best.is_empty():
		_build(best)


## The companies' cities (globe.gd): the networks' towns snap to them, and their streets are built.
func _watch_cities() -> void:
	var globe: Variant = mod.get("globe")
	if not (globe is Object) or not is_instance_valid(globe):
		return
	var ver := int((globe as Object).get("cities_version"))
	if ver == _globe_ver or _building:
		return   # while a piece is built on a worker thread the cities stay as they are (it reads them)
	_globe_ver = ver
	var list: Array = (globe as Object).get("city_list")
	_snap.clear()
	for cy in list:
		var up: Vector3 = (cy as Dictionary)["up"]
		var f := face_of(up)
		for net in NETS:
			var k := EARTH_KM / float(net["km"])
			var key := "%d|%d|%d|%d" % [int(f.z), int(floor(f.x * k)), int(floor(f.y * k)), int(net["seed"])]
			if not _snap.has(key):
				_snap[key] = Vector2(f.x, f.y)
	for c in _chunks:
		c["sig"] = -1
	_build_streets(list)


## A direction's cube face and its place there: (u, v, face) — the inverse of face_dir.
static func face_of(d: Vector3) -> Vector3:
	var a := d.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector3(d.z / a.x, d.y / a.x, 0.0 if d.x > 0.0 else 1.0)
	if a.y >= a.z:
		return Vector3(d.x / a.y, d.z / a.y, 2.0 if d.y > 0.0 else 3.0)
	return Vector3(d.x / a.z, d.y / a.z, 4.0 if d.z > 0.0 else 5.0)


## The streets of every city: the lines between the rows and columns of its buildings' grid, round the whole city.
func _build_streets(list: Array) -> void:
	if is_instance_valid(_streets):
		_streets.queue_free()
	_streets = null
	var arr := _arrays()
	var bed := float(cfg.get("bed_m", 60.0)) * 0.3
	var profile: Array = [[-1.0, -bed], [-0.8, bed], [0.8, bed], [1.0, -bed]]
	for cy in list:
		var d: Dictionary = cy
		var cells: Array = d["cells"]
		if cells.size() < 2:
			continue
		var up: Vector3 = d["up"]
		var east: Vector3 = d["east"]
		var north: Vector3 = d["north"]
		var step := float(d["step"])
		# A street runs along every side of an occupied cell; runs of such sides become one street.
		var busy := {}
		var x0 := 1 << 30
		var x1 := -(1 << 30)
		var y0 := 1 << 30
		var y1 := -(1 << 30)
		for cv in cells:
			var c := Vector2i(roundi((cv as Vector2).x), roundi((cv as Vector2).y))
			busy[c] = true
			x0 = mini(x0, c.x)
			x1 = maxi(x1, c.x)
			y0 = mini(y0, c.y)
			y1 = maxi(y1, c.y)
		var half_km := step * EARTH_KM * 0.13
		var seg_km := float(cfg.get("near_step_km", 2.5))
		for vertical in [true, false]:
			var lines := range(x0 - 1, x1 + 1) if vertical else range(y0 - 1, y1 + 1)
			var cross := range(y0, y1 + 1) if vertical else range(x0, x1 + 1)
			for li in lines:
				var start := -99999
				var last := -99999
				for cj in cross + [99999]:
					var a := Vector2i(int(li), int(cj)) if vertical else Vector2i(int(cj), int(li))
					var b := a + (Vector2i(1, 0) if vertical else Vector2i(0, 1))
					var on := int(cj) != 99999 and (busy.has(a) or busy.has(b))
					if on:
						last = int(cj)
					if on and start == -99999:
						start = int(cj)
					elif not on and start != -99999:
						var line := float(li) + 0.5
						var p0 := Vector2(line, float(start) - 0.5) if vertical else Vector2(float(start) - 0.5, line)
						var p1 := Vector2(line, float(last) + 0.5) if vertical else Vector2(float(last) + 0.5, line)
						_strip(arr, _street(up, east, north, step, p0, p1, seg_km), profile, half_km, KIND_ROAD, PackedFloat32Array())
						start = -99999
	if (arr["v"] as PackedVector3Array).is_empty():
		return
	_streets = Node3D.new()
	_streets.name = "Streets"
	_streets.add_child(_mesh_of(arr, 1))
	add_child(_streets)
	_streets.visible = (mask & 1) != 0


static func _street(up: Vector3, east: Vector3, north: Vector3, step: float, a: Vector2, b: Vector2, seg_km: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var len_km := a.distance_to(b) * step * EARTH_KM
	var n := clampi(int(len_km / seg_km), 1, 400)   # a street is never longer than a city: a guard all the same
	for i in n + 1:
		var p := a.lerp(b, float(i) / float(n))
		out.append((up + east * p.x * step + north * p.y * step).normalized())
	return out


func _show_kinds(c: Dictionary) -> void:
	var node: Variant = c["node"]
	if not (node is Node3D) or not is_instance_valid(node):
		return
	for ch in (node as Node3D).get_children():
		var bit := int((ch as Node).get_meta("bit", 0))
		(ch as Node3D).visible = bit == 0 or (mask & bit) != 0


# ---------- the networks ----------

## A direction of a cube face's point (gnomonic, u, v in −1..1).
static func face_dir(face: int, u: float, v: float) -> Vector3:
	match face:
		0:
			return Vector3(1.0, v, u).normalized()
		1:
			return Vector3(-1.0, v, u).normalized()
		2:
			return Vector3(u, 1.0, v).normalized()
		3:
			return Vector3(u, -1.0, v).normalized()
		4:
			return Vector3(u, v, 1.0).normalized()
	return Vector3(u, v, -1.0).normalized()


static func _hash(a: int, b: int, c: int, d: int) -> float:
	var x := (a * 73856093) ^ (b * 19349663) ^ (c * 83492791) ^ (d * 2654435761)
	x = (x ^ (x >> 13)) * 1274126177
	x = x ^ (x >> 16)
	return float(x & 0xFFFFFF) / 16777216.0


## A town's place on its face (face units), or Vector2.INF off the face; a city where one stands in the cell.
func _town(face: int, cx: int, cy: int, k: float, seed: int) -> Vector2:
	var city: Variant = _snap.get("%d|%d|%d|%d" % [face, cx, cy, seed])
	if city is Vector2:
		return city
	var p := Vector2((float(cx) + 0.2 + 0.6 * _hash(face, cx, cy, seed)) / k, (float(cy) + 0.2 + 0.6 * _hash(face, cx, cy, seed + 1)) / k)
	if absf(p.x) > 1.0 or absf(p.y) > 1.0:
		return Vector2.INF
	return p


func _province(d: Vector3) -> int:
	if _ids != null:
		# Our copy of the provinces (earth.gd ids_image): safe on a worker thread, and quicker than asking the game.
		var w := _ids.get_width()
		var h := _ids.get_height()
		var x := clampi(int(fposmod(atan2(d.x, d.z) / TAU + 0.5, 1.0) * w), 0, w - 1)
		var y := clampi(int(acos(clampf(d.y, -1.0, 1.0)) / PI * h), 0, h - 1)
		var c := _ids.get_pixel(x, y)
		return roundi(c.r * 255.0) + roundi(c.g * 255.0) * 256
	if game == null or not is_instance_valid(game.main):
		return 0
	var book: Variant = V.prop(game.main, ["пров", "provinces"])
	if not (book is Object):
		book = V.prop(V.prop(game.main, ["полит_карта"]) as Object, V.MAP["provinces"])
	if not (book is Object) or not V.has_any(book as Object, ID_AT):
		_has_book = false
		return 0
	_has_book = true
	return int(V.call_any(book as Object, ID_AT, [d, 0]))


## The cities' links (config/links3d.json), each filed under the chunk its middle falls in (built once, there).
func _load_graph(data: Variant) -> void:
	var list: Array = (data as Dictionary).get("links", []) if data is Dictionary else []
	for row in list:
		var r: Array = row
		var a := _latlon(float(r[0]), float(r[1]))
		var b := _latlon(float(r[2]), float(r[3]))
		var f := face_of((a + b).normalized())
		var ci := clampi(int(floor((f.x + 1.0) * 0.5 * CHUNKS)), 0, CHUNKS - 1)
		var cj := clampi(int(floor((f.y + 1.0) * 0.5 * CHUNKS)), 0, CHUNKS - 1)
		var key := "%d|%d|%d" % [int(f.z), ci, cj]
		if not _graph.has(key):
			_graph[key] = []
		(_graph[key] as Array).append([a, b, int(r[4]) == 1])


static func _latlon(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	return Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l))


## The networks where people live (config/cities.json): the people of the cities within ~1° summed by a degree's
## cell, 30 000 → 0.07, 300 000 → 0.4, 3 million → 0.8, 10 million → 1. The game's own table (region_nets) adds what
## the provinces built; without it (it is read under 0.23's names) the cities alone draw the networks.
func _pop_grid(data: Variant) -> void:
	var list: Array = (data as Dictionary).get("cities", []) if data is Dictionary else []
	if list.is_empty():
		return
	var raw := PackedFloat32Array()
	raw.resize(360 * 180)
	for row in list:
		var r: Array = row
		var y := clampi(int(floor(90.0 - float(r[0]))), 0, 179)
		var x := posmod(int(floor(float(r[1]) + 180.0)), 360)
		raw[y * 360 + x] += float(r[2])
	_pop.resize(360 * 180)
	for y in 180:
		for x in 360:
			var sum := 0.0
			for dy in range(-1, 2):
				var yy := clampi(y + dy, 0, 179)
				for dx in range(-1, 2):
					var w := 1.0 / (1.0 + float(dx * dx + dy * dy))
					sum += raw[yy * 360 + posmod(x + dx, 360)] * w
			_pop[y * 360 + x] = clampf((log(sum + 1.0) / log(10.0) - 4.3) / 2.6, 0.0, 1.0)


func _pop_level(d: Vector3) -> float:
	if _pop.is_empty():
		return 0.0
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(d.x, d.z))
	return _pop[clampi(int(floor(90.0 - lat)), 0, 179) * 360 + posmod(int(floor(lon + 180.0)), 360)]


## A network's level at a place (channel 0 roads, 1 communications, 2 rails, 3 power), 0..1: the game's province's,
## or the cities' where it is higher.
func _level_at(d: Vector3, channel: int) -> float:
	var from_people := _pop_level(d) * float([1.0, 1.0, 0.85, 0.9][channel])
	return maxf(_level(_province(d), channel), from_people)


## Land or sea: the game's provinces (0 — the sea); without them the height map (the sea is at 0).
func _land(d: Vector3) -> bool:
	if _province(d) > 0:
		return true
	if _has_book:
		return false
	return _surface.is_valid() and float(_surface.call(d)) > 1.000002


var _has_book := false
var _ids: Image                    # the provinces' ids (earth.gd ids_image), read on the worker threads too


## A province's level of a network (channel 0 roads, 1 communications, 2 rails, 3 power), 0..1.
func _level(pid: int, channel: int) -> float:
	if pid <= 0 or pid >= _levels_n:
		return 0.0
	return float(_levels[pid * 4 + channel]) / 255.0


## The link's way over the ground: directions every step_km, bending a little; empty if it crosses the sea.
func _way(a: Vector3, b: Vector3, step_km: float, bend_seed: float) -> PackedVector3Array:
	var ang := a.angle_to(b)
	var n := clampi(int(ang * EARTH_KM / step_km), 2, 2000)
	var side := a.cross(b).normalized()
	var amp := ang * 0.06 * (bend_seed - 0.5) * 2.0
	var out := PackedVector3Array()
	var check := maxi(1, int(n / maxf(ang * EARTH_KM / 12.0, 1.0)))   # the sea is looked for every ~12 km
	for i in n + 1:
		var t := float(i) / float(n)
		var d := a.slerp(b, t)
		d = (d + side * amp * sin(PI * t) + side * amp * 0.35 * sin(TAU * t)).normalized()
		if (i % check == 0 or i == n) and not _land(d):
			return PackedVector3Array()
		out.append(d)
	return out


func _build(c: Dictionary) -> void:
	_building = true
	var lod := int(c["want"])
	var version := int(c["version"]) + 1
	c["version"] = version
	var out := {}
	if _threads_on() and _ids != null:
		# On a worker thread (WorkerThreadPool): the game goes on; the pieces are made into nodes here when ready.
		var task := WorkerThreadPool.add_task(_compute.bind(c, lod, out), false, "pax_corpinc3d roads")
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
	else:
		_compute(c, lod, out)
	if int(c["version"]) != version or not is_inside_tree():
		_building = false
		return
	_finish(c, lod, out["parts"], out["pylons"], out["masts"])
	_building = false


## Threads for the mods' heavy work (Pax Corptimizer's «Многопоточность»: Engine meta «pax_threads», on by default).
static func _threads_on() -> bool:
	return not Engine.has_meta(&"pax_threads") or bool(Engine.get_meta(&"pax_threads"))


## A piece's geometry: pure work over our own data (the ids image, the levels, the height map), no game or scene
## calls — it runs on a worker thread. out: {parts, pylons, masts}.
func _compute(c: Dictionary, lod: int, out: Dictionary) -> void:
	var face := int(c["face"])
	var u0 := -1.0 + float(c["i"]) * 2.0 / CHUNKS
	var u1 := u0 + 2.0 / CHUNKS
	var v0 := -1.0 + float(c["j"]) * 2.0 / CHUNKS
	var v1 := v0 + 2.0 / CHUNKS
	var near := lod == 1
	var parts: Dictionary = {}   # bit -> {arrays}
	var pylons: Array = []       # Transform3D
	var masts: Array = []
	var nets: Array = NETS
	for net in nets:
		if not near and not bool(net["far"]):
			continue
		if net.has("graph"):
			_graph_links(net, face, int(c["i"]), int(c["j"]), near, parts, pylons)
			continue
		var k := EARTH_KM / float(net["km"])
		var seed := int(net["seed"])
		var cx0 := int(floor(u0 * k))
		var cx1 := int(floor(u1 * k))
		var cy0 := int(floor(v0 * k))
		var cy1 := int(floor(v1 * k))
		var step_km := float(cfg.get("near_step_km", 2.5)) if near else float(cfg.get("far_step_km", 30.0))
		for cx in range(cx0, cx1):
			for cy in range(cy0, cy1):
				var ta := _town(face, cx, cy, k, seed)
				if ta == Vector2.INF:
					continue
				var da := face_dir(face, ta.x, ta.y)
				var diag := Vector2i(1, 1) if _hash(face, cx, cy, seed + 7) < 0.5 else Vector2i(1, -1)
				for li in 3:
					var off: Vector2i = [Vector2i(1, 0), Vector2i(0, 1), diag][li]
					var tb := _town(face, cx + off.x, cy + off.y, k, seed)
					if tb == Vector2.INF:
						continue
					var db := face_dir(face, tb.x, tb.y)
					var mid := (da + db).normalized()
					var lv := _level_at(mid, int(net["channel"]))
					if lv < float(net["min"]):
						continue
					var keep := float(net["keep0"]) + float(net["keep1"]) * lv
					if li == 2:
						keep *= 0.35
					if _snap.has("%d|%d|%d|%d" % [face, cx, cy, seed]) or _snap.has("%d|%d|%d|%d" % [face, cx + off.x, cy + off.y, seed]):
						keep = 1.0   # every road out of a city is built
					if _hash(face, cx * 4 + li, cy, seed + 3) >= keep:
						continue
					var way := _way(da, db, step_km, _hash(face, cx, cy * 4 + li, seed + 5))
					if way.is_empty():
						continue
					var bit := int(net["bit"])
					if not parts.has(bit):
						parts[bit] = _arrays()
					if float(net["kind"]) == KIND_WIRE:
						_add_power(parts[bit], way, pylons)
					else:
						_add_ribbon(parts[bit], way, float(net["half"]) * float(cfg.get("width", 1.8)), float(net["kind"]), near)
	# Communication masts: towns of a fine grid where the province has a network.
	if near:
		var km := 60.0
		var k := EARTH_KM / km
		for cx in range(int(floor(u0 * k)), int(floor(u1 * k))):
			for cy in range(int(floor(v0 * k)), int(floor(v1 * k))):
				var t := _town(face, cx, cy, k, 71)
				if t == Vector2.INF:
					continue
				var d := face_dir(face, t.x, t.y)
				var lv := _level_at(d, 1)
				if lv < 0.02 or _hash(face, cx, cy, 73) > 0.15 + 0.6 * lv:
					continue
				masts.append(_stand(d, Vector3.ZERO, float(cfg.get("mast_m", 600.0))))
	out["parts"] = parts
	out["pylons"] = pylons
	out["masts"] = masts


## A network along the cities' links of this chunk (rails: only the rail links), where the province has built it.
func _graph_links(net: Dictionary, face: int, i: int, j: int, near: bool, parts: Dictionary, pylons: Array) -> void:
	var step_km := float(cfg.get("near_step_km", 2.5)) if near else float(cfg.get("far_step_km", 30.0))
	var rail_only := str(net["graph"]) == "rail"
	var n := 0
	for l in _graph.get("%d|%d|%d" % [face, i, j], []):
		var link: Array = l
		if rail_only and not bool(link[2]):
			continue
		var da: Vector3 = link[0]
		var db: Vector3 = link[1]
		var mid := (da + db).normalized()
		if _level_at(mid, int(net["channel"])) < float(net["min"]):
			continue
		n += 1
		var way := _way(da, db, step_km, _hash(face, i * 31 + n, j, int(net["seed"]) + 5))
		if way.is_empty():
			continue
		var bit := int(net["bit"])
		if not parts.has(bit):
			parts[bit] = _arrays()
		if float(net["kind"]) == KIND_WIRE:
			_add_power(parts[bit], way, pylons if near else [])
		else:
			_add_ribbon(parts[bit], way, float(net["half"]) * float(cfg.get("width", 1.8)), float(net["kind"]), near)


func _arrays() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(), "uv2": PackedVector2Array(),
		"c": PackedColorArray(), "i": PackedInt32Array()}


## A ribbon along a way: the profile across (x −1..1 with the height over the ground at each), a column per point.
func _add_ribbon(arr: Dictionary, way: PackedVector3Array, half_km: float, kind: float, near: bool) -> void:
	var profile: Array
	var bed := float(cfg.get("bed_m", 60.0))
	if not near:
		profile = [[-1.0, 0.0], [1.0, 0.0]]
	elif kind == KIND_RAIL:
		profile = [[-1.0, -bed * 0.4], [-0.62, bed * 0.8], [0.62, bed * 0.8], [1.0, -bed * 0.4]]
	else:
		profile = [[-1.0, -bed * 0.4], [-0.85, bed * 0.6], [0.85, bed * 0.6], [1.0, -bed * 0.4]]
	_strip(arr, way, profile, half_km, kind, PackedFloat32Array())


func _strip(arr: Dictionary, way: PackedVector3Array, profile: Array, half_km: float, kind: float, heights: PackedFloat32Array) -> void:
	var v: PackedVector3Array = arr["v"]
	var nn: PackedVector3Array = arr["n"]
	var uv: PackedVector2Array = arr["uv"]
	var uv2: PackedVector2Array = arr["uv2"]
	var col: PackedColorArray = arr["c"]
	var idx: PackedInt32Array = arr["i"]
	var cols := profile.size()
	var base := v.size()
	var along := 0.0
	var colour := Color(kind, 0.0, 0.0, 1.0)
	for i in way.size():
		var d := way[i]
		var prev := way[maxi(i - 1, 0)]
		var next := way[mini(i + 1, way.size() - 1)]
		var side := d.cross(next - prev).normalized()
		if i > 0:
			along += way[i - 1].angle_to(d) * EARTH_KM
		var lift := heights[i] if heights.size() > i else 0.0
		for p in profile:
			v.append(d)
			nn.append(side)
			uv.append(Vector2(float(p[0]), along))
			uv2.append(Vector2(half_km, float(p[1]) + lift))
			col.append(colour)
	for i in way.size() - 1:
		for k in cols - 1:
			var a := base + i * cols + k
			var b := a + cols
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	arr["v"] = v
	arr["n"] = nn
	arr["uv"] = uv
	arr["uv2"] = uv2
	arr["c"] = col
	arr["i"] = idx


## A power line: pylons every pylon_km along the way, two wires between their arms, sagging.
func _add_power(arr: Dictionary, way: PackedVector3Array, pylons: Array) -> void:
	var tower_m := float(cfg.get("pylon_m", 500.0))
	var spacing := float(cfg.get("pylon_km", 9.0))
	var total := 0.0
	var marks: Array = [0]   # indices of the way's points where pylons stand
	var since := 0.0
	for i in range(1, way.size()):
		var seg := way[i - 1].angle_to(way[i]) * EARTH_KM
		total += seg
		since += seg
		if since >= spacing or i == way.size() - 1:
			marks.append(i)
			since = 0.0
	var arm := tower_m * 0.32 / 1000.0 / EARTH_KM     # the arm's reach, Earth radii
	for m in marks:
		var i := int(m)
		var d := way[i]
		var next := way[mini(i + 1, way.size() - 1)] if i < way.size() - 1 else d + (d - way[i - 1])
		pylons.append(_stand(d, next - d, tower_m))
	for wv in [-1.0, 1.0]:
		var w := float(wv)
		for s in marks.size() - 1:
			var a := int(marks[s])
			var b := int(marks[s + 1])
			var part := PackedVector3Array()
			var heights := PackedFloat32Array()
			for i in range(a, b + 1):
				var d := way[i]
				var prev := way[maxi(i - 1, 0)]
				var nxt := way[mini(i + 1, way.size() - 1)]
				var side := d.cross(nxt - prev).normalized()
				part.append((d + side * arm * w).normalized())
				var t := float(i - a) / float(maxi(b - a, 1))
				heights.append(tower_m * 0.86 - tower_m * 0.18 * 4.0 * t * (1.0 - t))
			_strip(arr, part, [[-1.0, 0.0], [1.0, 0.0]], 0.004, KIND_WIRE, heights)


## A standing thing's place: on the ground at d, up along d, facing along «ahead», height h_m.
func _stand(d: Vector3, ahead: Vector3, h_m: float) -> Transform3D:
	var up := d.normalized()
	var fwd := (ahead - up * ahead.dot(up))
	if fwd.length() < 1e-9:
		fwd = up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	fwd = fwd.normalized()
	var right := up.cross(fwd).normalized()
	var s := h_m / 1000.0 / EARTH_KM
	var r := float(_surface.call(up)) if _surface.is_valid() else 1.0
	return Transform3D(Basis(right * s, up * s, fwd * s), up * r)


func _finish(c: Dictionary, lod: int, parts: Dictionary, pylons: Array, masts: Array) -> void:
	var old: Variant = c["node"]
	var node := Node3D.new()
	for bit in parts:
		var arr: Dictionary = parts[bit]
		if not (arr["v"] as PackedVector3Array).is_empty():
			node.add_child(_mesh_of(arr, int(bit)))
	if not pylons.is_empty():
		node.add_child(_instances(_pylon, pylons, 8))
	if not masts.is_empty():
		node.add_child(_instances(_mast, masts, 4))
	add_child(node)
	if old is Node3D and is_instance_valid(old):
		(old as Node3D).queue_free()
	c["node"] = node
	c["lod"] = lod
	c["sig"] = _levels_sig
	_show_kinds(c)


func _mesh_of(arr: Dictionary, bit: int) -> MeshInstance3D:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = arr["v"]
	a[Mesh.ARRAY_NORMAL] = arr["n"]
	a[Mesh.ARRAY_TEX_UV] = arr["uv"]
	a[Mesh.ARRAY_TEX_UV2] = arr["uv2"]
	a[Mesh.ARRAY_COLOR] = arr["c"]
	a[Mesh.ARRAY_INDEX] = arr["i"]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	mesh.custom_aabb = mesh.get_aabb().grow(0.02)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_meta("bit", bit)
	return mi


func _instances(mesh: Mesh, list: Array, bit: int) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])
	var mmi := MultiMeshInstance3D.new()
	# The whole planet as its box: the box the engine counts from the first (all-zero) transforms went stale and
	# the armies, ships and jets were culled as unseen in the game (the Forward+ renderer).
	mmi.custom_aabb = AABB(Vector3(-1.3, -1.3, -1.3), Vector3(2.6, 2.6, 2.6))
	mmi.multimesh = mm
	mmi.set_meta("bit", bit)
	return mmi


# ---------- the models: a lattice pylon and a mast (built here, unit height) ----------

static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, t: float) -> void:
	var ax := (b - a).normalized()
	var ref := Vector3.UP if absf(ax.y) < 0.9 else Vector3.RIGHT
	var s1 := ax.cross(ref).normalized() * t
	var s2 := ax.cross(s1).normalized() * t
	var c: Array[Vector3] = [a + s1 + s2, a + s1 - s2, a - s1 - s2, a - s1 + s2]
	var e: Array[Vector3] = [b + s1 + s2, b + s1 - s2, b - s1 - s2, b - s1 + s2]
	for k in 4:
		var k2 := (k + 1) % 4
		var n: Vector3 = ((c[k] + c[k2]) * 0.5 - a).normalized()
		st.set_normal(n)
		st.add_vertex(c[k])
		st.add_vertex(e[k])
		st.add_vertex(c[k2])
		st.add_vertex(c[k2])
		st.add_vertex(e[k])
		st.add_vertex(e[k2])


static func _make_pylon() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var t := 0.008
	var base := 0.1
	var top := 0.025
	var legs: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			legs.append([Vector3(sx * base, 0.0, sz * base), Vector3(sx * top, 0.92, sz * top)])
	for l in legs:
		_beam(st, (l as Array)[0], (l as Array)[1], t)
	# Braces: zig-zags on each side, every eighth of the height.
	for k in 8:
		var y0 := float(k) / 8.0 * 0.92
		var y1 := float(k + 1) / 8.0 * 0.92
		var w0 := lerpf(base, top, y0 / 0.92)
		var w1 := lerpf(base, top, y1 / 0.92)
		for side in 4:
			var s := 1.0 if side < 2 else -1.0
			var a: Vector3
			var b: Vector3
			if side % 2 == 0:
				a = Vector3(-w0, y0, s * w0)
				b = Vector3(w1, y1, s * w1)
			else:
				a = Vector3(s * w0, y0, -w0)
				b = Vector3(s * w1, y1, w1)
			if k % 2 == 1:
				a.x = -a.x if side % 2 == 0 else a.x
				b.x = -b.x if side % 2 == 0 else b.x
				a.z = -a.z if side % 2 == 1 else a.z
				b.z = -b.z if side % 2 == 1 else b.z
			_beam(st, a, b, t * 0.5)
	# The arms that carry the wires, and the earth wire's peak.
	_beam(st, Vector3(-0.34, 0.86, 0.0), Vector3(0.34, 0.86, 0.0), t)
	_beam(st, Vector3(-0.34, 0.86, 0.0), Vector3(-top, 0.78, 0.0), t * 0.6)
	_beam(st, Vector3(0.34, 0.86, 0.0), Vector3(top, 0.78, 0.0), t * 0.6)
	_beam(st, Vector3(-0.22, 0.7, 0.0), Vector3(0.22, 0.7, 0.0), t * 0.8)
	_beam(st, Vector3(0.0, 0.92, 0.0), Vector3(0.0, 1.0, 0.0), t * 0.7)
	for xv in [-0.34, 0.34, -0.22, 0.22]:
		var x := float(xv)
		var y := 0.86 if absf(x) > 0.3 else 0.7
		_beam(st, Vector3(x, y, 0.0), Vector3(x, y - 0.05, 0.0), t * 1.4)   # the insulators
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.58, 0.6, 0.62)
	m.metallic = 0.6
	m.roughness = 0.45
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh


static func _make_mast(blink: Shader) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var t := 0.006
	for k in 3:
		var a := TAU * float(k) / 3.0
		_beam(st, Vector3(cos(a), 0.0, sin(a)) * 0.035, Vector3(cos(a), 0.0, sin(a)) * 0.012 + Vector3(0, 0.97, 0), t)
	for k in 10:
		var y := float(k) / 10.0 * 0.95
		var r := lerpf(0.035, 0.012, y / 0.97)
		for j in 3:
			var a0 := TAU * float(j) / 3.0
			var a1 := TAU * float(j + 1) / 3.0
			_beam(st, Vector3(cos(a0) * r, y, sin(a0) * r), Vector3(cos(a1) * r, y + 0.05, sin(a1) * r), t * 0.5)
	# Dishes.
	for j in 3:
		var a := TAU * float(j) / 3.0 + 0.5
		_beam(st, Vector3(cos(a) * 0.02, 0.8, sin(a) * 0.02), Vector3(cos(a) * 0.06, 0.8, sin(a) * 0.06), 0.02)
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.85, 0.86)
	m.metallic = 0.3
	m.roughness = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	# The red light on top, blinking (a surface of its own).
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	_beam(st2, Vector3(0, 0.97, 0), Vector3(0, 1.0, 0), 0.02)
	var light := st2.commit(mesh as ArrayMesh)
	var lm := ShaderMaterial.new()
	lm.shader = blink
	light.surface_set_material(1, lm)
	return light
