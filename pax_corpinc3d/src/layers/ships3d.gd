extends Node3D
## Container ships on the 3D globe (config/models.json «ship»), many times larger than life so they are seen from the
## overview height:
##   on the game's sea trade routes (the political map's caravans of the kind «корабль»): «per_route» ships sail each
##   route's polyline back and forth, nose along the way;
##   at sea for the sea's sake: «ambient» ships, each on its own great circle at its own speed; over land (the height
##   map: the sea is at 0) they are hidden, so they come out of the haze only on the water.
## Shown below show_below_km of the camera's height (config/earth.json «ships»). Lives in the Earth's node (its own
## space, radius 1), like the roads and the armies.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0

var mod: PaxMod
var cfg: Dictionary = {}
var _ships: MultiMeshInstance3D
var _wakes: MultiMeshInstance3D       # a white wake behind each ship: a dark hull on the dark sea was not seen from orbit
var _ship: Dictionary = {}          # mesh_lod: {mesh, base, foot}
var _long_x := true                 # the model's length lies along its X (else Z)
var _routes: Array = []             # [{pts: Array[Vector3], len: float}]
var _ambient: Array = []            # [{axis: Vector3, start: Vector3, speed: float}]
var _sig := ""
var _time := 0.0


func setup(m: PaxMod, ships_cfg: Dictionary) -> void:
	mod = m
	cfg = ships_cfg
	name = "PaxCorpInc3DShips"
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in int(cfg.get("ambient", 70)):
		var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.35, 0.35), rng.randf_range(-1, 1)).normalized()
		var start := axis.cross(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))).normalized()
		_ambient.append({"axis": axis, "start": start, "speed": rng.randf_range(0.6, 1.4) * (1.0 if rng.randf() < 0.5 else -1.0)})


## The game's caravans; the sea ones become routes (rebuilt only when they change).
func set_caravans(list: Array, is_ship: Callable) -> void:
	var sig := ""
	var routes: Array = []
	for k in list:
		if not (k is Dictionary):
			continue
		var c: Dictionary = k
		if not bool(is_ship.call(c)):
			continue
		var raw: Variant = c.get("points", c.get("точки", []))
		if not (raw is Array) or (raw as Array).size() < 2:
			continue
		var pts: Array = []
		var length := 0.0
		for uv in raw:
			if not (uv is Vector2):
				continue
			var d := _dir(uv as Vector2)
			if not pts.is_empty():
				length += (pts[pts.size() - 1] as Vector3).angle_to(d)
			pts.append(d)
			sig += "%.3f,%.3f;" % [(uv as Vector2).x, (uv as Vector2).y]
		if pts.size() >= 2 and length > 0.0:
			routes.append({"pts": pts, "len": length})
	if sig == _sig and is_instance_valid(_ships):
		return
	_sig = sig
	_routes = routes
	_make()


static func _dir(uv: Vector2) -> Vector3:
	var lon := (uv.x - 0.5) * TAU
	var lat := PI * 0.5 - uv.y * PI
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


func _make() -> void:
	var t0 := Time.get_ticks_usec()
	_make_timed()
	GameApi.perf("corpinc3d.ships3d.make", t0)   # Pax CorpInc3D probe: where the frame goes


func _make_timed() -> void:
	if is_instance_valid(_ships):
		_ships.queue_free()
	if is_instance_valid(_wakes):
		_wakes.queue_free()
	_ships = null
	_wakes = null
	if _ship.is_empty():
		var globe: Variant = mod.get("globe")
		if globe is Object and is_instance_valid(globe):
			_ship = (globe as Object).call("mesh_lod", "ship", int(cfg.get("ship_tris", 3000)))
			var info: Dictionary = (globe as Object).call("mesh_info", "ship")
			if not info.is_empty():
				var box := (info["mesh"] as Mesh).get_aabb()
				_long_x = box.size.x >= box.size.z
	if _ship.is_empty():
		return
	var count := _routes.size() * int(cfg.get("per_route", 2)) + _ambient.size()
	if count == 0:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _ship["mesh"]
	mm.instance_count = count
	_ships = MultiMeshInstance3D.new()
	# The whole planet as its box: the box the engine counts from the first (all-zero) transforms went stale and
	# the armies, ships and jets were culled as unseen in the game (the Forward+ renderer).
	_ships.custom_aabb = AABB(Vector3(-1.3, -1.3, -1.3), Vector3(2.6, 2.6, 2.6))
	_ships.multimesh = mm
	_ships.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ships)
	var wm := MultiMesh.new()
	wm.transform_format = MultiMesh.TRANSFORM_3D
	wm.mesh = _wake_mesh()
	wm.instance_count = count
	_wakes = MultiMeshInstance3D.new()
	# The whole planet as its box: the box the engine counts from the first (all-zero) transforms went stale and
	# the armies, ships and jets were culled as unseen in the game (the Forward+ renderer).
	_wakes.custom_aabb = AABB(Vector3(-1.3, -1.3, -1.3), Vector3(2.6, 2.6, 2.6))
	_wakes.multimesh = wm
	_wakes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_wakes)


## The wake: a white V on the water behind the stern, fading out (local: x across, z forward, the ship's length 1).
static func _wake_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts := [[Vector3(0.0, 0.0, 0.0), 0.85], [Vector3(-0.45, 0.0, -2.6), 0.0], [Vector3(0.45, 0.0, -2.6), 0.0], [Vector3(0.0, 0.0, -1.6), 0.25]]
	for tri in [[0, 1, 3], [0, 3, 2]]:
		for k in tri:
			var pv: Array = pts[k]
			st.set_color(Color(1, 1, 1, float(pv[1])))
			st.set_normal(Vector3.UP)
			st.add_vertex(pv[0])
	var mesh := st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	return mesh


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(delta)
	GameApi.perf("corpinc3d.ships3d.process", t0)   # Pax CorpInc3D probe: where the frame goes


func _process_timed(delta: float) -> void:
	if not is_instance_valid(_ships) or not is_visible_in_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt_km := ((global_transform.affine_inverse() * cam.global_position).length() - 1.0) * EARTH_KM
	_ships.visible = alt_km < float(cfg.get("show_below_km", 2500.0))
	if is_instance_valid(_wakes):
		_wakes.visible = _ships.visible
	if not _ships.visible:
		return
	_time += delta
	var earth: Variant = mod.get("earth")
	var has_ground := earth is Object and is_instance_valid(earth) and (earth as Object).call("height_texture") != null
	var length := float(cfg.get("ship_km", 5.0)) / EARTH_KM
	var speed := float(cfg.get("speed_kmh", 9000.0)) / 3600.0 / EARTH_KM   # radians a second (sped up, as the game's time)
	var mm := _ships.multimesh
	var i := 0
	var per := int(cfg.get("per_route", 2))
	for r in _routes:
		var pts: Array = r["pts"]
		var total := float(r["len"])
		for j in per:
			# Back and forth along the route: the way there, then back, each ship half a trip apart.
			var s := fposmod(_time * speed / total + float(j) / float(per), 2.0)
			var forward := s < 1.0
			var at := (s if forward else 2.0 - s) * total
			var place := _along(pts, at)
			var p: Vector3 = place[0]
			var head: Vector3 = place[1] if forward else -(place[1] as Vector3)
			mm.set_instance_transform(i, _xf(p, head, length))
			_set_wake(i, p, head, length)
			i += 1
	for a in _ambient:
		var ang := _time * speed * float(a["speed"])
		var p := (a["start"] as Vector3).rotated(a["axis"] as Vector3, ang)
		var head := (a["axis"] as Vector3).cross(p).normalized() * signf(float(a["speed"]))
		var land := has_ground and float((earth as Object).call("surface_radius", p)) > 1.0000005
		mm.set_instance_transform(i, _xf(p, head, 0.0 if land else length))
		_set_wake(i, p, head, 0.0 if land else length)
		i += 1


func _set_wake(i: int, p: Vector3, head: Vector3, length: float) -> void:
	if not is_instance_valid(_wakes):
		return
	if length <= 0.0 or head.length() < 0.001:
		_wakes.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), p))
		return
	var up := p.normalized()
	var fwd := (head - up * up.dot(head)).normalized()
	var side := up.cross(fwd).normalized()
	var stern := up * (1.0 + length * 0.012) - fwd * length * 0.5
	_wakes.multimesh.set_instance_transform(i, Transform3D(Basis(side, up, fwd).scaled_local(Vector3.ONE * length), stern))


## A point at an arc length along the polyline (radians) and the way there: [position, heading].
static func _along(pts: Array, at: float) -> Array:
	var left := at
	for k in range(1, pts.size()):
		var a: Vector3 = pts[k - 1]
		var b: Vector3 = pts[k]
		var seg := a.angle_to(b)
		if left <= seg or k == pts.size() - 1:
			var t := clampf(left / maxf(seg, 1e-9), 0.0, 1.0)
			var p := a.slerp(b, t).normalized()
			var head := (b - a).normalized()
			head = (head - p * p.dot(head)).normalized()
			return [p, head]
		left -= seg
	return [pts[0], Vector3.UP]


## The ship at p heading along «head», its length «length» (0 — hidden): its long axis along the way, on the sea.
func _xf(p: Vector3, head: Vector3, length: float) -> Transform3D:
	if length <= 0.0 or head.length() < 0.001:
		return Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), p)
	var side := p.cross(head).normalized()
	var fwd := side.cross(p).normalized()
	var h := length / maxf(float(_ship["foot"]), 0.1)   # the model's height unit for this length
	var b := Basis(fwd, p, fwd.cross(p)) if _long_x else Basis(side, p, side.cross(p))
	return Transform3D(b.scaled_local(Vector3.ONE * h), p * (1.0 + length * 0.02)) * (_ship["base"] as Transform3D)
