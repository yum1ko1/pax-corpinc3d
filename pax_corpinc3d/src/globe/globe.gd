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

const BODY := "Земля"
const REF_M := 100.0
const CITY_DEG := 0.5
const AFTER_INTRO := 3.0            # seconds after the game's opening flight before anything is built

var mod: PaxMod
var photo: Object                   # photo.gd: which model a site gets (model_for)
var enabled := true
# Quality (settings/quality.gd sets them; the window «3D» changes them):
var limit := 0                      # buildings at most, 0 — all (headquarters of the biggest companies first)
var hq_only := false                # only the companies' headquarters
var shadows := false                # buildings cast shadows (costly on weak cards)
var hide_far := 0.0                 # hide the buildings when the camera is farther than this many Earth radii, 0 — never
const FRAME_RANK := {"diamond": 4, "sapphire": 3, "gold": 2, "silver": 1}
var game: PaxGame
var size_100m := 0.004              # a 100 m building, in Earth radii (exaggerated so a city is seen)
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
# The game's opening flight to the player's country (Main.заставка): nothing is loaded, built or turned while it runs
# and for AFTER_INTRO seconds after — the heavy models loaded in the middle of the flight crashed the game.
var _calm := AFTER_INTRO


func setup(m: PaxMod, ph: Object) -> void:
	mod = m
	photo = ph
	var cfg: Variant = m.load_json("config/models.json", {})
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
	_calm = AFTER_INTRO
	_turn = {}


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
	if game == null or not is_instance_valid(game.main):
		return
	if _intro():
		_calm = AFTER_INTRO
		_turn = {}
		if is_instance_valid(_holder):
			_holder.visible = false
		return
	if _calm > 0.0:
		_calm -= delta
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
	if not _holder.visible:
		return
	_t += delta
	var ver := int(api.call("sites_version"))
	if ver != _ver and _t >= 0.5:
		if _build(api):
			_t = 0.0
			_ver = ver


## The game's opening flight is on the screen.
func _intro() -> bool:
	return is_instance_valid(game.main.get("заставка"))


## The buildings are shown now (the auto quality measures the frames only then).
func showing() -> bool:
	return enabled and is_instance_valid(_holder) and _holder.visible


## Built again with the current quality on the next frame.
func rebuild() -> void:
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
## false — not built yet: a model was loaded this frame (one a frame, so the game never freezes on all of them).
func _build(api: Object) -> bool:
	var sites: Array = []
	for r in _pick(api.call("sites_3d") as Array):
		var d: Dictionary = r
		var lat := float(d.get("lat", NAN))
		var lon := float(d.get("lon", NAN))
		if not is_finite(lat) or not is_finite(lon):
			continue
		var id := str(photo.call("model_for", str(d.get("k", "")), str(d.get("f", "")), str(d.get("s", ""))))
		if id.is_empty():
			id = "office"   # every company stands somewhere: no own model — an office
		if not _meshes.has(id):
			_mesh(id)
			return false
		sites.append([id, lat, lon])
	for mi in _mm.values():
		if is_instance_valid(mi):
			(mi as Node).queue_free()
	_mm.clear()
	_fit_convention()
	var cities := {}
	for site in sites:
		var id: String = site[0]
		if not _mesh(id):
			continue
		var lat: float = site[1]
		var lon: float = site[2]
		var key := "%d|%d" % [roundi(lat / CITY_DEG), roundi(lon / CITY_DEG)]
		if not cities.has(key):
			cities[key] = {"lat": 0.0, "lon": 0.0, "list": []}
		var cd: Dictionary = cities[key]
		(cd["list"] as Array).append(id)
		cd["lat"] = float(cd["lat"]) + lat
		cd["lon"] = float(cd["lon"]) + lon
	# Transforms by model.
	var by_model := {}
	for key in cities.keys():
		var cd: Dictionary = cities[key]
		var list: Array = cd["list"]
		var n := float(list.size())
		var up := _dir(float(cd["lat"]) / n, float(cd["lon"]) / n)
		list.sort_custom(func(a, b): return float((_meshes[a] as Dictionary)["h"]) > float((_meshes[b] as Dictionary)["h"]))
		# The grid's step: the widest building of the city, almost touching.
		var step := 0.0
		for id in list:
			var info: Dictionary = _meshes[id]
			step = maxf(step, size_100m * float(info["h"]) / REF_M * float(info["foot"]))
		step *= 1.04
		var east := Vector3.UP.cross(up)
		if east.length() < 0.001:
			east = Vector3.RIGHT
		east = east.normalized()
		var north := up.cross(east).normalized()
		var cells := _grid(list.size())
		for i in list.size():
			var id: String = list[i]
			var info: Dictionary = _meshes[id]
			var cell: Vector2 = cells[i]
			var pos := (up + east * cell.x * step + north * cell.y * step).normalized()
			var e2 := Vector3.UP.cross(pos)
			if e2.length() < 0.001:
				e2 = Vector3.RIGHT
			e2 = e2.normalized()
			var basis := Basis(e2, pos, e2.cross(pos).normalized())
			var k := size_100m * float(info["h"]) / REF_M
			if not by_model.has(id):
				by_model[id] = []
			(by_model[id] as Array).append(Transform3D(basis.scaled(Vector3.ONE * k), pos) * (info["base"] as Transform3D))
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
		_holder.add_child(mi)
		_mm[id] = mi
		_count += xfs.size()
	mod.log_info("3D globe: %d buildings in %d cities, %d models" % [_count, cities.size(), _mm.size()])
	return true


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
	if not (yaw_v is float) or not main.has_method("_поставить_камеру"):
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
				main.call("_поставить_камеру")
				_turn["step"] = 1
				_turn["wait"] = 0.35
				return
			main.set("камера_рыскание", float(yaw_v) + miss * k)
			main.call("_поставить_камеру")
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
			main.call("_поставить_камеру")
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
	_conv = 0
	var vox: Variant = Pax.get("voxel")
	if not (vox is Object) or not (vox as Object).has_method("province_position"):
		mod.log_info("3D globe: no province_position — the standard sphere mapping")
		return
	var regs: Variant = Pax.json("res://data/regions2.json", {})
	var list: Array = (regs as Dictionary).get("регионы", []) if regs is Dictionary else []
	var probes: Array = []
	for i in range(0, list.size(), maxi(1, list.size() / 8)):
		if list[i] is Dictionary:
			probes.append(list[i])
	var best := 0
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
