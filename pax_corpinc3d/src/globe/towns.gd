extends Node3D
## The world's cities as buildings (config/cities.json: GeoNames cities from 30 000 people, earth_maps.py cities).
## Every city has houses by its size: as many as cover about «cover» of its built-up area (a city of 30 000 — a couple,
## a million — ~65, the largest — up to max_per_city), denser and taller to the middle, each city different by its
## scatter, heights, turns and colours (the same every time). Two looks, by GPU instancing (MultiMesh):
##   far (lower than show_below_km) — a light house: a box with a darker roof, 10 triangles, ~200 000 of them;
##   near (lower than near_below_km, within near_radius_km of the point under the camera) — the small office
##   (config/models.json «office», made lighter: near_tris) on the same places; the boxes there are hidden.
## The big cities with their real shape (config/city_layouts.json — Overture Maps buildings on the houses' grid,
## pax_corporations_dev/city_layouts.py): one house in each really built-up cell, the densest first (up to
## layout_max), wider where more of the cell is under roofs, taller where its buildings are taller.
## Under every house a grey pad (pad_scale × its width): close together they join into a built-up block.
## The far set is computed on a worker thread (WorkerThreadPool): the game goes on while ~200 000 houses are placed.
## The cities of the companies (globe.gd city_list) keep their own grid: no town house stands in it; nor in the sea
## (the height map: the sea is at 0). Lives in the Earth's node (its own space, radius 1) under globe.gd's holder.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0
const FLOATS := 16                 # a MultiMesh instance with colour: 12 of the transform, 4 of the colour
const WALLS := [Color(0.86, 0.83, 0.77), Color(0.78, 0.78, 0.76), Color(0.90, 0.88, 0.84), Color(0.70, 0.66, 0.60),
	Color(0.82, 0.74, 0.66), Color(0.74, 0.76, 0.80)]

var mod: PaxMod
var globe: Object                  # globe.gd: the office (mesh_lod, mesh_info), the companies' cities
var cfg: Dictionary = {}
var _cities: Array = []            # [{dir: Vector3, pop: int, r: float (Earth radii), cells?: PackedFloat32Array}]
var _cell_km := 2.0
var _corp_ver := -1
var _ground_on := false            # the far set was placed on the 3D ground (rebuilt when that changes)
var _job: TownJob
var _far: MultiMeshInstance3D
var _far_pads: MultiMeshInstance3D
var _ranges := PackedInt32Array()  # per city: its first house and how many
var _params := PackedFloat32Array() # per house: up (3), width, tallness, yaw, ground — 7 floats
var _far_buf := PackedFloat32Array()
var _near: MultiMeshInstance3D
var _near_at := Vector3.ZERO
var _hidden: PackedInt32Array = PackedInt32Array()   # the cities whose boxes are hidden under the offices


## Placed on a worker thread: every house's place, the far set's MultiMesh buffers.
class TownJob extends RefCounted:
	var cities: Array
	var avoid: Array
	var height: Image
	var exag := 3.5
	var size_km := 2.0
	var cover := 0.4
	var max_n := 250
	var layout_max := 300
	var cell_km := 2.0
	var pad_scale := 2.6
	var task := -1
	var ranges := PackedInt32Array()
	var params := PackedFloat32Array()
	var far := PackedFloat32Array()
	var pads := PackedFloat32Array()

	func run() -> void:
		var w_mean := size_km / EARTH_KM
		for i in cities.size():
			var c: Dictionary = cities[i]
			var pop := int(c["pop"])
			var n := clampi(int(float(pop) * 0.000653 * cover / (size_km * size_km)), 2, max_n)
			ranges.append(params.size() / 7)
			var before := params.size()
			var rng := RandomNumberGenerator.new()
			rng.seed = i * 7919 + 13
			var up: Vector3 = c["dir"]
			var east := Vector3.UP.cross(up)
			if east.length() < 0.001:
				east = Vector3.RIGHT
			east = east.normalized()
			var north := up.cross(east).normalized()
			var radius := float(c["r"])
			var big := pop >= 1000000
			var cells: PackedFloat32Array = c.get("cells", PackedFloat32Array())
			if not cells.is_empty():
				n = mini(cells.size() / 4, layout_max)
			var cell := cell_km / EARTH_KM
			for j in n:
				var p: Vector3
				var w: float
				var tall: float
				if not cells.is_empty():
					# the j-th densest real cell (the list comes sorted by cover), a little shaken inside it
					var o := j * 4
					var dx := (cells[o] + rng.randf_range(-0.25, 0.25)) * cell
					var dy := (cells[o + 1] + rng.randf_range(-0.25, 0.25)) * cell
					p = (up + east * dx + north * dy).normalized()
					w = w_mean * clampf(0.45 + sqrt(cells[o + 2] / 100.0), 0.5, 1.3)
					tall = 0.8 + clampf((cells[o + 3] - 6.0) / 20.0, 0.0, 3.5) * rng.randf_range(0.8, 1.0)
				else:
					var ang := rng.randf() * TAU
					var t := pow(rng.randf(), 0.75)
					p = (up + (east * cos(ang) + north * sin(ang)) * radius * t).normalized()
					w = w_mean * rng.randf_range(0.7, 1.3)
					var centre := 1.0 - t
					tall = 1.0 + centre * centre * (2.5 if big else 1.0) * rng.randf_range(0.5, 1.0)
				var yaw := rng.randf() * TAU
				var tint := rng.randi() % WALLS.size()
				if not _free(p):
					continue
				var ground := _ground(p)
				if height != null and ground <= 1.0000005:
					continue   # the sea
				params.append_array(PackedFloat32Array([p.x, p.y, p.z, w, tall, yaw, ground]))
				var e2 := Vector3.UP.cross(p)
				if e2.length() < 0.001:
					e2 = Vector3.RIGHT
				e2 = e2.normalized()
				var f2 := e2.cross(p).normalized()
				var ex := e2 * cos(yaw) + f2 * sin(yaw)
				var fx := f2 * cos(yaw) - e2 * sin(yaw)
				var hh := w * 0.9 * tall
				_put(far, Basis(ex * w, p * hh, fx * w), p * (ground - w * 0.03), WALLS[tint])
				var pad := w * pad_scale
				_put(pads, Basis(ex * pad, p * pad, fx * pad), p * (ground + w * 0.01), Color.WHITE)
			ranges.append((params.size() - before) / 7)

	func _free(p: Vector3) -> bool:
		for a in avoid:
			if p.angle_to(a[0] as Vector3) < float(a[1]):
				return false
		return true

	## The same ground as earth.gd surface_radius (the height map × its exaggeration), read here off the main thread.
	func _ground(n: Vector3) -> float:
		if height == null:
			return 1.0
		var w := height.get_width()
		var h := height.get_height()
		var fx := (atan2(n.x, n.z) / TAU + 0.5) * w - 0.5
		var fy := acos(clampf(n.y, -1.0, 1.0)) / PI * h - 0.5
		var x0 := int(floor(fx))
		var y0 := int(floor(fy))
		var top := lerpf(_h16(x0, y0, w, h), _h16(x0 + 1, y0, w, h), fx - x0)
		var bottom := lerpf(_h16(x0, y0 + 1, w, h), _h16(x0 + 1, y0 + 1, w, h), fx - x0)
		return 1.0 + lerpf(top, bottom, fy - y0) * 0.0010046 * exag

	func _h16(x: int, y: int, w: int, h: int) -> float:
		var c := height.get_pixel(posmod(x, w), clampi(y, 0, h - 1))
		return (roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0)) / 65535.0

	static func _put(buf: PackedFloat32Array, b: Basis, o: Vector3, col: Color) -> void:
		buf.append_array(PackedFloat32Array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z,
			col.r, col.g, col.b, col.a]))


func setup(m: PaxMod, g: Object, towns_cfg: Dictionary, list: Array, layouts: Dictionary = {}) -> void:
	mod = m
	globe = g
	cfg = towns_cfg
	name = "PaxCorpInc3DTowns"
	_cell_km = float(layouts.get("cell_km", 2.0))
	var by_place: Dictionary = {}   # "lat,lon" (3 decimals) -> [[x, y, cover %, height m], ...] densest first
	for k in layouts.keys():
		var parts := str(k).split(",")
		if parts.size() == 2 and layouts[k] is Array:
			by_place[_place(parts[0].to_float(), parts[1].to_float())] = layouts[k]
	for row in list:
		if not (row is Array) or (row as Array).size() < 3:
			continue
		var r: Array = row
		var pop := int(r[2])
		var r_km := 1.4 * sqrt(float(pop) / 3000.0 / PI)
		var city := {"dir": _dir(float(r[0]), float(r[1])), "pop": pop, "r": r_km / EARTH_KM}
		var lay: Variant = by_place.get(_place(float(r[0]), float(r[1])))
		if lay is Array:
			var rows: Array = (lay as Array).duplicate()
			rows.sort_custom(func(a, b): return float(a[2]) > float(b[2]))
			var cells := PackedFloat32Array()
			for e in rows:
				if e is Array and (e as Array).size() >= 4:
					cells.append_array(PackedFloat32Array([float(e[0]), float(e[1]), float(e[2]), float(e[3])]))
			city["cells"] = cells
		_cities.append(city)


static func _place(lat: float, lon: float) -> String:
	return "%.3f,%.3f" % [lat, lon]


static func _dir(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	return Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l))


func _exit_tree() -> void:
	if _job != null and _job.task >= 0:
		WorkerThreadPool.wait_for_task_completion(_job.task)
		_job = null


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(_delta)
	GameApi.perf("corpinc3d.towns.process", t0)   # Pax CorpInc3D probe: where the frame goes


func _process_timed(_delta: float) -> void:
	if _cities.is_empty() or not is_visible_in_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var earth: Variant = mod.get("earth")
	var height: Image = null
	if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("height_image"):
		height = (earth as Object).call("height_image") as Image
	var ver := int(globe.get("cities_version"))
	if (ver != _corp_ver or (height != null) != _ground_on) and _job == null:
		_corp_ver = ver
		_ground_on = height != null
		_start(height, earth)
	if _job != null and _job.task >= 0 and WorkerThreadPool.is_task_completed(_job.task):
		WorkerThreadPool.wait_for_task_completion(_job.task)
		_finish()
	var inv := global_transform.affine_inverse()
	var eye := inv * cam.global_position
	var alt_km := (eye.length() - 1.0) * EARTH_KM
	var show := alt_km < float(cfg.get("show_below_km", 3500.0))
	var near := alt_km < float(cfg.get("near_below_km", 1100.0))
	if is_instance_valid(_far):
		_far.visible = show
	if is_instance_valid(_far_pads):
		_far_pads.visible = show
	if near and not _params.is_empty():
		var under := eye.normalized()
		if _near == null or under.angle_to(_near_at) * EARTH_KM > float(cfg.get("rebuild_km", 300.0)):
			_near_at = under
			_build_near(under)
	elif is_instance_valid(_near):
		_drop_near()


func _start(height: Image, earth: Variant) -> void:
	var job := TownJob.new()
	job.cities = _cities
	job.avoid = _read_avoid()
	job.height = height
	if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("height_exag"):
		job.exag = float((earth as Object).call("height_exag"))
	job.size_km = float(cfg.get("building_km", 2.0))
	job.cover = float(cfg.get("cover", 0.4))
	job.max_n = int(cfg.get("max_per_city", 250))
	job.layout_max = int(cfg.get("layout_max", 300))
	job.cell_km = _cell_km
	job.pad_scale = float(cfg.get("pad_scale", 2.6))
	_job = job
	if Engine.has_meta(&"pax_threads") and not bool(Engine.get_meta(&"pax_threads")):
		job.run()   # Pax Corptimizer switched the threads off: here and now (a pause)
		_finish()
		return
	job.task = WorkerThreadPool.add_task(job.run, false, "pax_corpinc3d towns")


func _finish() -> void:
	var t0 := Time.get_ticks_usec()
	_finish_timed()
	GameApi.perf("corpinc3d.towns.finish", t0)   # Pax CorpInc3D probe: where the frame goes


func _finish_timed() -> void:
	var job := _job
	_job = null
	_drop_near()
	for n in [_far, _far_pads]:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_ranges = job.ranges
	_params = job.params
	_far_buf = job.far
	_hidden = PackedInt32Array()
	var count := _params.size() / 7
	_far = _multi(_box_mesh(), count, _far_buf)
	_far_pads = _multi(_pad_mesh(), count, job.pads)
	mod.log_info("3D towns: %d houses in %d cities" % [count, _cities.size()])


func _multi(mesh: Mesh, count: int, buf: PackedFloat32Array) -> MultiMeshInstance3D:
	if count == 0:
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.buffer = buf
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## The companies' cities: [up, reach] — no town house in their grids.
func _read_avoid() -> Array:
	var out: Array = []
	var list: Variant = globe.get("city_list")
	if not (list is Array):
		return out
	for c in list:
		var d: Dictionary = c
		var reach := 0.0
		for cv in d["cells"]:
			reach = maxf(reach, (cv as Vector2).length())
		out.append([d["up"], (reach + 1.5) * float(d["step"])])
	return out


## The near look: the office on the places of the houses of the cities around the point under the camera; their boxes
## are hidden (scaled to nothing in the far buffer) and come back when the camera leaves.
func _build_near(under: Vector3) -> void:
	var t0 := Time.get_ticks_usec()
	_build_near_timed(under)
	GameApi.perf("corpinc3d.towns.build_near", t0)   # Pax CorpInc3D probe: where the frame goes


func _build_near_timed(under: Vector3) -> void:
	_drop_near()
	var info: Dictionary = globe.call("mesh_lod", str(cfg.get("model", "office")), int(cfg.get("near_tris", 800)))
	if info.is_empty() or not is_instance_valid(_far):
		return
	var base: Transform3D = info["base"]
	var foot := float(info["foot"])
	var reach := float(cfg.get("near_radius_km", 1200.0)) / EARTH_KM
	var xfs: Array = []
	var buf := _far.multimesh.buffer
	for i in _cities.size():
		if (( _cities[i] as Dictionary)["dir"] as Vector3).angle_to(under) > reach:
			continue
		var first := _ranges[i * 2]
		var n := _ranges[i * 2 + 1]
		if n == 0:
			continue
		_hidden.append(i)
		for j in range(first, first + n):
			var k := j * 7
			var p := Vector3(_params[k], _params[k + 1], _params[k + 2])
			var w := _params[k + 3]
			var tall := _params[k + 4]
			var yaw := _params[k + 5]
			var ground := _params[k + 6]
			var e2 := Vector3.UP.cross(p)
			if e2.length() < 0.001:
				e2 = Vector3.RIGHT
			e2 = e2.normalized()
			var f2 := e2.cross(p).normalized()
			var ex := e2 * cos(yaw) + f2 * sin(yaw)
			var fx := f2 * cos(yaw) - e2 * sin(yaw)
			var h := w / maxf(foot, 0.1)
			xfs.append(Transform3D(Basis(ex * h, p * h * tall, fx * h), p * (ground - h * 0.05)) * base)
			for q in 12:
				buf[j * FLOATS + q] = 0.0   # the box under the office: nothing
	_far.multimesh.buffer = buf
	if xfs.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = info["mesh"]
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	_near = MultiMeshInstance3D.new()
	_near.multimesh = mm
	_near.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_near)


func _drop_near() -> void:
	if is_instance_valid(_near):
		_near.queue_free()
	_near = null
	if _hidden.is_empty() or not is_instance_valid(_far):
		_hidden = PackedInt32Array()
		return
	var buf := _far.multimesh.buffer
	for i in _hidden:
		var first := _ranges[i * 2]
		for j in range(first, first + _ranges[i * 2 + 1]):
			for q in 12:
				buf[j * FLOATS + q] = _far_buf[j * FLOATS + q]
	_far.multimesh.buffer = buf
	_hidden = PackedInt32Array()


## The far house: a unit box (0..1 up), light walls and a darker roof (the colour of each house is its instance's).
static func _box_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := [Vector3(-0.5, 0, -0.5), Vector3(0.5, 0, -0.5), Vector3(0.5, 0, 0.5), Vector3(-0.5, 0, 0.5)]
	var wall := Color(1, 1, 1)
	var roof := Color(0.55, 0.53, 0.5)
	for i in 4:
		var a: Vector3 = c[i]
		var b: Vector3 = c[(i + 1) % 4]
		var nrm := ((a + b) * 0.5).normalized()
		for v in [a, b, b + Vector3.UP, a, b + Vector3.UP, a + Vector3.UP]:
			st.set_color(wall)
			st.set_normal(nrm)
			st.add_vertex(v as Vector3)
	for v in [c[0], c[2], c[1], c[0], c[3], c[2]]:
		st.set_color(roof)
		st.set_normal(Vector3.UP)
		st.add_vertex((v as Vector3) + Vector3.UP)
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.85
	m.cull_mode = BaseMaterial3D.CULL_DISABLED   # either winding: the box is seen from outside only anyway
	mesh.surface_set_material(0, m)
	return mesh


func _pad_mesh() -> PlaneMesh:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	var c: Array = cfg.get("pad_color", [0.40, 0.39, 0.37])
	m.albedo_color = Color(float(c[0]), float(c[1]), float(c[2]))
	m.roughness = 0.95
	plane.material = m
	return plane
