extends Node
## Real 3D buildings on the 3D Earth (not on the flat political map). Pax Corporations' sites are gathered into
## cities (one point per half a degree): a city's buildings stand close together on a square grid around its
## point, the tallest in the middle, upright on the surface — as real models (models/*.glb, config/models.json),
## one MultiMesh per model, children of the Earth's node, so they turn with it.
## One fixed size, whatever the camera's height (config «здание_100м» — a 100 m building in Earth radii): the city
## always stands on the planet; flying away the player really leaves the planet with its cities below.
## Leaving the flat map, the camera turns to the longitude the map showed (Main.камера_рыскание, its scale and sign
## learnt on the first turn and kept in the settings): zooming out of America leaves the planet over America.
## The latitude/longitude direction is the game's own (checked against Pax.voxel.province_position once).

const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")             # game 0.24's English names
const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")   # Main's methods and the mod's JSON, game 0.24
const BODY := "Земля"
const REF_M := 100.0
const CITY_DEG := 0.5
const Towns := preload("res://mods/pax_corpinc3d/src/globe/towns.gd")
const Landmarks := preload("res://mods/pax_corpinc3d/src/globe/landmarks.gd")
const STREET_GAP := 1.35            # the city grid's step × the widest building: the streets run in the gaps

var mod: PaxMod
var photo: Object                   # photo.gd: which model a site gets (model_for)
var enabled := true
# Quality (settings/quality.gd sets them; the window «3D» changes them):
var limit := 0                      # buildings at most, 0 — all (headquarters of the biggest companies first)
var hq_only := false                # only the companies' headquarters
var shadows := false                # buildings cast shadows (costly on weak cards)
## The companies' buildings shown (the «Слои глобуса» switch «buildings»; the cities and landmarks have their own).
var show_companies := true:
	set(v):
		show_companies = v
		for mi in _mm.values():
			if is_instance_valid(mi):
				(mi as Node3D).visible = v
var hide_far := 0.0                 # hide the buildings when the camera is farther than this many Earth radii, 0 — never
const FRAME_RANK := {"diamond": 4, "sapphire": 3, "gold": 2, "silver": 1}
var game: PaxGame
var size_100m := 0.004              # a 100 m building, in Earth radii (exaggerated so a city is seen)
var scale_k := 1.0                  # the buildings' size × this (descent.gd: smaller as the camera comes down)
var _holder: Node3D
var _body: Node3D
var _meshes: Dictionary = {}        # model id -> {mesh, base: Transform3D, h: metres, foot: width / height}
var _mm: Dictionary = {}            # model id -> MultiMeshInstance3D
var _ver := -1
var _conv := -1
var _t := 0.0
var _count := 0
# The camera's turn when the flat map closes.
var _map_was := false
var _center := Vector2.INF          # (latitude, longitude) the map showed last
var _turn := {}                     # {target, start, applied, wait}
var city_list: Array = []           # the cities as built: {up, east, north, step, cells: [Vector2]} (roads3d.gd: streets)
var cities_version := 0
var _picks: Array = []              # [centre (the Earth's space), reach (radii), company id] of every building
var landmarks: Node3D               # the world's landmarks (landmarks.gd)
var towns: Node3D                   # the world's cities as buildings (towns.gd), under the holder
var _towns_for: Node3D              # the holder the towns were made for
var _lods: Dictionary = {}          # "id|max_tris" -> a lighter model (mesh_lod)


func setup(m: PaxMod, ph: Object) -> void:
	mod = m
	photo = ph
	var cfg: Variant = GameApi.json(m, "config/models.json", {})
	if cfg is Dictionary:
		size_100m = float((cfg as Dictionary).get("building_100m", 0.004))
	enabled = bool(m.get_setting("on", true))


func _ready() -> void:
	name = "PaxCorpInc3DGlobe"
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(g: PaxGame) -> void:
	clear()
	game = g
	_ver = -1


func clear() -> void:
	if is_instance_valid(_holder):
		_holder.queue_free()
	_holder = null
	_mm.clear()
	_ver = -1
	_count = 0


func _api() -> Object:
	var api: Variant = Engine.get_meta("pax_corporations_api") if Engine.has_meta("pax_corporations_api") else null
	return api as Object if api is Object and is_instance_valid(api) and (api as Object).has_method("sites_3d") else null


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(delta)
	GameApi.perf("corpinc3d.globe.process", t0)


func _process_body(delta: float) -> void:
	if game == null or not is_instance_valid(game.main):
		return
	var api := _api()
	var mapv: Variant = game.main.get("полит_карта")
	var map_open := mapv is CanvasLayer and (mapv as CanvasLayer).visible
	_follow_map(api, map_open, delta)
	if not enabled or api == null:
		if is_instance_valid(_holder):
			_holder.visible = false
		return
	var body := game.body_node(BODY)
	if body == null:
		return
	if body != _body or not is_instance_valid(_holder):
		clear()
		_body = body
		_holder = Node3D.new()
		_holder.name = "PaxCorpInc3DCity"
		body.add_child(_holder)
	_holder.visible = not map_open and game.focused_body() == game.home_body() and not _too_far(body)
	_ensure_towns()
	if not _holder.visible:
		return
	_t += delta
	var ver := int(api.call("sites_version"))
	if ver != _ver and _t >= 0.5:
		_t = 0.0
		_ver = ver
		_build(api)


## The world's cities (towns.gd) in the holder, made once per holder; config/earth.json «towns», config/cities.json,
## config/city_layouts.json.
func _ensure_towns() -> void:
	if _towns_for == _holder:
		return
	_towns_for = _holder   # tried for this holder (built or not): never read again every frame
	var all: Variant = GameApi.json(mod, "config/earth.json", {})
	var tcfg: Dictionary = (all as Dictionary).get("towns", {}) if all is Dictionary else {}
	if not bool(tcfg.get("enabled", true)):
		return
	var data: Variant = GameApi.json(mod, "config/cities.json", {})
	var list: Array = (data as Dictionary).get("cities", []) if data is Dictionary else []
	if list.is_empty():
		return
	if is_instance_valid(towns):
		towns.queue_free()
	towns = Towns.new()
	# The real built-up cells of the big cities (Overture Maps, pax_corporations_dev/city_layouts.py).
	var lay: Variant = GameApi.json(mod, "config/city_layouts.json", {})
	towns.call("setup", mod, self, tcfg, list, lay if lay is Dictionary else {})
	_holder.add_child(towns)
	# The world's landmarks (config/landmarks.json, built in Blender).
	var lcfg: Variant = GameApi.json(mod, "config/landmarks.json", {})
	if lcfg is Dictionary and not (lcfg as Dictionary).is_empty():
		if is_instance_valid(landmarks):
			landmarks.queue_free()
		landmarks = Landmarks.new()
		landmarks.call("setup", mod, self, lcfg)
		_holder.add_child(landmarks)


## A model's mesh and its fitting (towns.gd): {mesh, base, h, foot}, {} without it.
func mesh_info(id: String) -> Dictionary:
	return _meshes[id] if _mesh(id) else {}


## A model made lighter (towns.gd: thousands of copies): the same mesh with Godot's own simplification
## (ImporterMesh.generate_lods), the coarsest level still within max_tris triangles; {} without the model. Cached.
func mesh_lod(id: String, max_tris: int) -> Dictionary:
	var key := "%s|%d" % [id, max_tris]
	if _lods.has(key):
		return _lods[key]
	var info := mesh_info(id)
	if info.is_empty():
		return info
	var src: Mesh = info["mesh"]
	var total := 0
	for si in src.get_surface_count():
		var ia: Variant = src.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
		total += (ia as PackedInt32Array).size() / 3 if ia is PackedInt32Array else 0
	var out := ArrayMesh.new()
	for si in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(si)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and total > max_tris:
			var share := int(float(max_tris) * float((idx as PackedInt32Array).size() / 3) / float(maxi(total, 1)))
			var im := ImporterMesh.new()
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arr)
			im.generate_lods(25.0, 60.0, [])
			var best: PackedInt32Array = idx
			for l in im.get_surface_lod_count(0):
				best = im.get_surface_lod_indices(0, l)
				if best.size() / 3 <= share:
					break
			arr[Mesh.ARRAY_INDEX] = best
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(si))
	# The texture's seams keep the simplification from going far: if still too heavy, a welded copy — one vertex a
	# place, the texture's colour baked into the vertices — simplifies to the budget.
	var have := 0
	for si in out.get_surface_count():
		have += (out.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	if have > max_tris * 3 / 2:
		var welded := _welded_lod(src, max_tris)
		if welded != null:
			out = welded
	var lite := info.duplicate()
	lite["mesh"] = out
	_lods[key] = lite
	return lite


## The mesh welded by position with its texture's colours in the vertices, simplified to about max_tris.
static func _welded_lod(src: Mesh, max_tris: int) -> ArrayMesh:
	var pos := PackedVector3Array()
	var cols: Array[Color] = []
	var counts: Array[int] = []
	var tris := PackedInt32Array()
	var at := {}
	for si in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(si)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uv: Variant = arr[Mesh.ARRAY_TEX_UV]
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		var ind: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(v.size()))
		var img: Image = null
		var tint := Color.WHITE
		var m: Variant = src.surface_get_material(si)
		if m is BaseMaterial3D:
			tint = (m as BaseMaterial3D).albedo_color
			var tex := (m as BaseMaterial3D).albedo_texture
			if tex != null:
				img = tex.get_image()
				if img != null and img.is_compressed():
					img.decompress()
				if img != null and img.get_width() > 256:
					img.resize(256, maxi(1, img.get_height() * 256 / img.get_width()), Image.INTERPOLATE_BILINEAR)
		for t in range(0, ind.size() - 2, 3):
			var c := tint
			if img != null and uv is PackedVector2Array:
				var u: Vector2 = ((uv as PackedVector2Array)[ind[t]] + (uv as PackedVector2Array)[ind[t + 1]] + (uv as PackedVector2Array)[ind[t + 2]]) / 3.0
				c = tint * img.get_pixel(clampi(int(fposmod(u.x, 1.0) * img.get_width()), 0, img.get_width() - 1),
					clampi(int(fposmod(u.y, 1.0) * img.get_height()), 0, img.get_height() - 1))
			for k in 3:
				var p := v[ind[t + k]]
				var key := Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))
				var w: int = at.get(key, -1)
				if w < 0:
					w = pos.size()
					at[key] = w
					pos.append(p)
					cols.append(Color(0, 0, 0, 0))
					counts.append(0)
				cols[w] = Color(cols[w].r + c.r, cols[w].g + c.g, cols[w].b + c.b, 1.0)
				counts[w] += 1
				tris.append(w)
	if pos.is_empty():
		return null
	var vc := PackedColorArray()
	for i in pos.size():
		var n := float(maxi(counts[i], 1))
		vc.append(Color(cols[i].r / n, cols[i].g / n, cols[i].b / n, 1.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in pos.size():
		st.set_color(vc[i])
		st.add_vertex(pos[i])
	for i in tris:
		st.add_index(i)
	st.generate_normals()
	var arrays := st.commit_to_arrays()
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	im.generate_lods(60.0, 90.0, [])
	var best: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for l in im.get_surface_lod_count(0):
		best = im.get_surface_lod_indices(0, l)
		if best.size() / 3 <= max_tris:
			break
	arrays[Mesh.ARRAY_INDEX] = best
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true   # the texture's colours: read as linear they came out washed white
	mat.roughness = 0.8
	out.surface_set_material(0, mat)
	return out


## Water under a direction: the game's provinces (0 — water) when it gives them, else the height map (the sea at 0).
func is_water(dir: Vector3) -> bool:
	if game != null and is_instance_valid(game.main):
		var book: Variant = V.prop(game.main, ["пров", "provinces"])
		if not (book is Object):
			book = V.prop(V.prop(game.main, ["полит_карта"]) as Object, V.MAP["provinces"])
		if book is Object and V.has_any(book as Object, ["id_в", "id_at", "id_of"]):
			return int(V.call_any(book as Object, ["id_в", "id_at", "id_of"], [dir.normalized(), 0])) <= 0
	var earth: Variant = mod.get("earth") if mod != null else null
	if earth is Object and is_instance_valid(earth) and (earth as Object).call("height_texture") != null:
		return float((earth as Object).call("surface_radius", dir)) <= 1.0000005
	return false


## The ground's radius under a direction (towns.gd).
func ground(dir: Vector3) -> float:
	return _ground(dir)


## The buildings are shown now (the auto quality measures the frames only then).
func showing() -> bool:
	return enabled and is_instance_valid(_holder) and _holder.visible


## Built again with the current quality on the next frame.
func rebuild() -> void:
	var t0 := Time.get_ticks_usec()
	rebuild_timed()
	GameApi.perf("corpinc3d.globe.rebuild", t0)   # Pax CorpInc3D probe: where the frame goes


func rebuild_timed() -> void:
	_ver = -1


func built_count() -> int:
	return _count


## The camera farther from the Earth's centre than hide_far radii.
func _too_far(body: Node3D) -> bool:
	if hide_far <= 0.0:
		return false
	var cam := game.camera()
	if cam == null:
		return false
	var radius := body.global_transform.basis.get_scale().x
	return cam.global_position.distance_to(body.global_position) > hide_far * maxf(radius, 1e-6)


## The sites to draw: only headquarters when asked; over the limit — headquarters first, then the companies with
## the highest frames (diamond … none), the rest dropped.
func _pick(sites: Array) -> Array:
	var out: Array = sites.filter(func(d: Dictionary) -> bool: return not hq_only or str(d.get("k", "")) == "штаб")
	if limit <= 0 or out.size() <= limit:
		return out
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ha := 1 if str(a.get("k", "")) == "штаб" else 0
		var hb := 1 if str(b.get("k", "")) == "штаб" else 0
		if ha != hb:
			return ha > hb
		return int(FRAME_RANK.get(str(a.get("f", "")), 0)) > int(FRAME_RANK.get(str(b.get("f", "")), 0)))
	return out.slice(0, limit)


## The sites from Pax Corporations as cities; every building placed once (the size never changes).
func _build(api: Object) -> void:
	for mi in _mm.values():
		if is_instance_valid(mi):
			(mi as Node).queue_free()
	_mm.clear()
	_fit_convention()
	var cities := {}
	var built: Array = []
	for r in _pick(api.call("sites_3d") as Array):
		var d: Dictionary = r
		var id := str(photo.call("model_for", str(d.get("k", "")), str(d.get("f", "")), str(d.get("s", ""))))
		if id.is_empty():
			id = "office"   # every company stands somewhere: no own model — an office
		if not _mesh(id):
			continue
		var lat := float(d["lat"])
		var lon := float(d["lon"])
		var key := "%d|%d" % [roundi(lat / CITY_DEG), roundi(lon / CITY_DEG)]
		if not cities.has(key):
			cities[key] = {"lat": 0.0, "lon": 0.0, "list": []}
		var cd: Dictionary = cities[key]
		(cd["list"] as Array).append([id, str(d.get("c", ""))])   # the model and its company (a click opens it)
		cd["lat"] = float(cd["lat"]) + lat
		cd["lon"] = float(cd["lon"]) + lon
	# Transforms by model.
	var by_model := {}
	var pads: Array = []
	var picks: Array = []
	for key in cities.keys():
		var cd: Dictionary = cities[key]
		var list: Array = cd["list"]
		var n := float(list.size())
		var up := _dir(float(cd["lat"]) / n, float(cd["lon"]) / n)
		list.sort_custom(func(a, b): return float((_meshes[a[0]] as Dictionary)["h"]) > float((_meshes[b[0]] as Dictionary)["h"]))
		# The grid's step: the widest building of the city, almost touching.
		var step := 0.0
		for pair in list:
			var id: String = pair[0]
			var info: Dictionary = _meshes[id]
			step = maxf(step, size_100m * scale_k * float(info["h"]) / REF_M * float(info["foot"]))
		step *= STREET_GAP   # room for the streets between the buildings (roads3d.gd)
		var east := Vector3.UP.cross(up)
		if east.length() < 0.001:
			east = Vector3.RIGHT
		east = east.normalized()
		var north := up.cross(east).normalized()
		# The grid's cells nearest to the middle first; a cell over water (a coastal city: Chicago, Toronto) is skipped.
		var spiral := _grid(list.size() * 3)
		var cells: Array = []
		for cv in spiral:
			if cells.size() >= list.size():
				break
			var c: Vector2 = cv
			if not is_water((up + east * c.x * step + north * c.y * step).normalized()):
				cells.append(c)
		for cv in spiral:   # all water round (an island): the rest as they come
			if cells.size() >= list.size():
				break
			if not cells.has(cv):
				cells.append(cv)
		built.append({"up": up, "east": east, "north": north, "step": step, "cells": cells})
		for i in list.size():
			var id: String = list[i][0]
			var info: Dictionary = _meshes[id]
			var cell: Vector2 = cells[i]
			var pos := (up + east * cell.x * step + north * cell.y * step).normalized()
			var e2 := Vector3.UP.cross(pos)
			if e2.length() < 0.001:
				e2 = Vector3.RIGHT
			e2 = e2.normalized()
			var basis := Basis(e2, pos, e2.cross(pos).normalized())
			var k := size_100m * scale_k * float(info["h"]) / REF_M
			if not by_model.has(id):
				by_model[id] = []
			# On the ground: Earth HD raises the ground by the real heights (earth.gd surface_radius); a little sunk, so a
			# building on a slope has no gap under its downhill side.
			var foot := _ground(pos) - k * 0.08
			(by_model[id] as Array).append(Transform3D(basis.scaled(Vector3.ONE * k), pos * foot) * (info["base"] as Transform3D))
			# Grey ground under the cell (the whole cell: the blocks join, the streets run over them) — the companies'
			# quarters no longer stand on grass.
			picks.append([pos * (_ground(pos) + k * 0.5), k * 0.6, str(list[i][1])])   # centre, reach, company
			pads.append(Transform3D(basis.scaled(Vector3.ONE * step), pos * (_ground(pos) + k * 0.004)))
	if not pads.is_empty():
		_mm["_pads"] = _pads_node(pads)
	_count = 0
	for id in by_model.keys():
		var xfs: Array = by_model[id]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = (_meshes[id] as Dictionary)["mesh"]
		mm.instance_count = xfs.size()
		for j in xfs.size():
			mm.set_instance_transform(j, xfs[j])
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = show_companies
		_holder.add_child(mi)
		_mm[id] = mi
		_count += xfs.size()
	city_list = built
	_picks = picks
	cities_version += 1
	mod.log_info("3D globe: %d buildings in %d cities, %d models" % [_count, cities.size(), _mm.size()])


## The company of the building under a point of the screen ("" — none): the building nearest to the ray from the eye,
## within its reach (its height, at least a few pixels). globe_layers.gd: a click opens its dossier.
func company_at(cam: Camera3D, at: Vector2) -> String:
	if _picks.is_empty() or not is_instance_valid(_holder) or not _holder.is_visible_in_tree() or cam == null:
		return ""
	var to_local := _holder.global_transform.affine_inverse()
	var o := to_local * cam.project_ray_origin(at)
	var k := (to_local.basis * cam.project_ray_normal(at)).normalized()
	var best := ""
	var best_d := INF
	# Where the ray meets the ground (radius 1): buildings behind the planet are not hit.
	var b := o.dot(k)
	var disc := b * b - (o.dot(o) - 1.0)
	var t_ground := -b - sqrt(disc) if disc >= 0.0 else INF
	for p in _picks:
		var c: Vector3 = p[0]
		var t := (c - o).dot(k)
		if t <= 0.0 or t > t_ground + 0.002:
			continue
		var miss := (o + k * t - c).length()
		# At least ~6 px: tiny far buildings can still be hit.
		var reach := maxf(float(p[1]), t * tan(deg_to_rad(cam.fov) * 0.5) * 12.0 / maxf(get_viewport().get_visible_rect().size.y, 1.0))
		if miss <= reach and t < best_d:
			best_d = t
			best = str(p[2])
	return best


## A grey square under each cell of a company city (towns.gd has its own under the world's cities).
func _pads_node(xfs: Array) -> MultiMeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.40, 0.39, 0.37)
	m.roughness = 0.95
	plane.material = m
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = plane
	mm.instance_count = xfs.size()
	for j in xfs.size():
		mm.set_instance_transform(j, xfs[j])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = show_companies
	_holder.add_child(mi)
	return mi


## The ground's radius under a direction (1 — the sea level; Earth HD's 3D ground when it is on).
func _ground(dir: Vector3) -> float:
	var earth: Variant = mod.get("earth") if mod != null else null
	if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius"):
		return float((earth as Object).call("surface_radius", dir))
	return 1.0


## The cells of a square grid from the middle outwards: the first is the centre.
static func _grid(n: int) -> Array:
	var side := int(ceil(sqrt(float(n)))) + 1
	var cells: Array = []
	for x in range(-side, side + 1):
		for y in range(-side, side + 1):
			cells.append(Vector2(x, y))
	cells.sort_custom(func(a, b): return (a as Vector2).length_squared() < (b as Vector2).length_squared())
	return cells.slice(0, n)


# ---------- the camera turns to where the map was ----------

func _follow_map(api: Object, map_open: bool, delta: float) -> void:
	if map_open:
		if api != null and api.has_method("map_center"):
			var c: Variant = api.call("map_center")
			if c is Vector2 and (c as Vector2).is_finite():
				_center = c
	elif _map_was and _center.is_finite():
		_turn = {"target": _center.y, "wait": 0.15, "step": 0}
	_map_was = map_open
	if _turn.is_empty():
		return
	_turn["wait"] = float(_turn["wait"]) - delta
	if float(_turn["wait"]) > 0.0:
		return
	var main: Object = game.main
	var yaw_v: Variant = main.get("камера_рыскание")
	if not (yaw_v is float) or not GameApi.has(main, "_поставить_камеру"):
		_turn = {}
		return
	var now := _cam_lon()
	if not is_finite(now):
		_turn = {}
		return
	var miss := wrapf(float(_turn["target"]) - now, -180.0, 180.0)
	var k := float(mod.get_setting("yaw_per_deg", 0.0))   # yaw units per degree of longitude, learnt
	match int(_turn["step"]):
		0:
			if absf(miss) < 3.0:
				_turn = {}
				return
			if k == 0.0:
				# Learn the scale and the sign: a small test turn, measured after the camera settles.
				_turn["test"] = deg_to_rad(10.0)
				_turn["before"] = now
				main.set("камера_рыскание", float(yaw_v) + float(_turn["test"]))
				GameApi.call_main(main, "_поставить_камеру")
				_turn["step"] = 1
				_turn["wait"] = 0.35
				return
			main.set("камера_рыскание", float(yaw_v) + miss * k)
			GameApi.call_main(main, "_поставить_камеру")
			_turn = {}
		1:
			var moved := wrapf(now - float(_turn["before"]), -180.0, 180.0)
			if absf(moved) < 0.5:
				mod.log_info("3D globe: the camera's yaw does not turn the view — no turn to the map's place")
				_turn = {}
				return
			k = float(_turn["test"]) / moved
			mod.set_setting("yaw_per_deg", k)
			mod.log_info("3D globe: camera yaw %.5f per degree of longitude" % k)
			main.set("камера_рыскание", float(yaw_v) + miss * k)
			GameApi.call_main(main, "_поставить_камеру")
			_turn = {}


## The longitude the camera looks from (the direction from the Earth's centre to the camera, in its own space).
func _cam_lon() -> float:
	var body := game.body_node(BODY)
	var cam := game.camera()
	if body == null or cam == null:
		return NAN
	var local := (body.global_transform.affine_inverse() * cam.global_position).normalized()
	return _lon_of(local)


## The mesh of a model, normalized: the base's centre at the origin, height 1. false — no such model.
func _mesh(id: String) -> bool:
	if _meshes.has(id):
		return not (_meshes[id] as Dictionary).is_empty()
	var models: Dictionary = photo.get("models")
	if not models.has(id):
		_meshes[id] = {}
		return false
	var spec: Dictionary = models[id]
	var node: Node3D = mod.model("models/" + str(spec.get("файл", id + ".glb")))
	var mesh: Mesh = null
	if node != null:
		for n in node.find_children("*", "MeshInstance3D", true, false):
			if (n as MeshInstance3D).mesh != null:
				mesh = (n as MeshInstance3D).mesh
				break
		node.queue_free()
	if mesh == null:
		_meshes[id] = {}
		return false
	var box := mesh.get_aabb()
	var h := maxf(box.size.y, 1e-6)
	var c := box.get_center()
	var base := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE / h), Vector3.ZERO) * Transform3D(Basis.IDENTITY, Vector3(-c.x, -box.position.y, -c.z))
	var metres := float(spec.get("height_m", 0.0))
	if metres <= 0.0:
		metres = float(spec.get("width_m", 60.0)) * h / maxf(maxf(box.size.x, box.size.z), 1e-6)
	_meshes[id] = {"mesh": mesh, "base": base, "h": metres, "foot": maxf(box.size.x, box.size.z) / h}
	return true


# ---------- latitude and longitude on the Earth's node ----------

## The candidate conventions of a sphere's map (x, y, z from latitude φ and longitude λ).
func _dir(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	var c := cos(p)
	match _conv:
		1:
			return Vector3(c * cos(l), sin(p), c * sin(l))
		2:
			return Vector3(-c * cos(l), sin(p), c * sin(l))
		3:
			return Vector3(c * sin(l), sin(p), c * cos(l))
		4:
			return Vector3(-c * sin(l), sin(p), -c * cos(l))
		5:
			return Vector3(c * sin(l), sin(p), -c * cos(l))
		6:
			return Vector3(-c * sin(l), sin(p), c * cos(l))
		7:
			return Vector3(-c * cos(l), sin(p), -c * sin(l))
	return Vector3(c * cos(l), sin(p), -c * sin(l))   # 0: Godot's sphere UV


## The longitude of a direction on the Earth's node (the inverse of _dir).
func _lon_of(v: Vector3) -> float:
	var best := 0.0
	var err := INF
	var lat := rad_to_deg(asin(clampf(v.y, -1.0, 1.0)))
	for lon in range(-180, 180, 2):
		var e := _dir(lat, float(lon)).distance_to(v)
		if e < err:
			err = e
			best = float(lon)
	for d in range(-10, 11):
		var l2 := best + float(d) * 0.2
		var e2 := _dir(lat, l2).distance_to(v)
		if e2 < err:
			err = e2
			best = l2
	return best


## Which convention the game uses: compared on a few provinces with Pax.voxel.province_position (the game's own).
func _fit_convention() -> void:
	if _conv >= 0:
		return
	# 3 is the game's own mapping (planet_surface.gdshaderinc sph_uv: u = atan(x, z) / 2π + 0.5): the default when the
	# game cannot be asked.
	_conv = 3
	var vox: Variant = Pax.get("voxel")
	if not (vox is Object) or not (vox as Object).has_method("province_position"):
		mod.log_info("3D globe: no province_position — the game's sphere mapping (3)")
		return
	var regs: Variant = Pax.json("res://data/regions2.json", {})
	var list: Array = (regs as Dictionary).get("regions", (regs as Dictionary).get("регионы", [])) if regs is Dictionary else []
	var probes: Array = []
	for i in range(0, list.size(), maxi(1, list.size() / 8)):
		if list[i] is Dictionary:
			probes.append(list[i])
	if probes.is_empty():
		mod.log_info("3D globe: no provinces to compare — the game's sphere mapping (3)")
		return
	var best := 3
	var best_err := INF
	for conv in 8:
		_conv = conv
		var err := 0.0
		for r in probes:
			var rd: Dictionary = r
			var real: Variant = (vox as Object).call("province_position", BODY, int(rd.get("id", 0)), 1.0)
			if real is Vector3:
				err += (real as Vector3).normalized().distance_to(_dir(float(rd.get("ш", 0.0)), float(rd.get("д", 0.0))))
		if err < best_err:
			best_err = err
			best = conv
	_conv = best
	mod.log_info("3D globe: sphere mapping %d (error %.3f over %d provinces)" % [best, best_err, probes.size()])
