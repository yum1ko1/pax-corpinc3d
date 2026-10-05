extends Node3D
## Airliners on the 3D globe: white jets (a model made here — fuselage, swept wings, tail, engines), many times larger
## than life so they are seen from the overview height (config/earth.json «planes»: wingspan plane_km).
##   on the game's air routes (the political map's caravans of the kind «самолёт» and its flights): per_route jets fly
##   each route there and back, along the same arc the dashed line of the route draws (lift);
##   in the sky for the sky's sake: «ambient» jets between the world's big cities (config/cities.json).
## They were a white dot on the 2D overlay — players did not read it as a plane.
## Shown below show_below_km of the camera's height. Lives in the Earth's node (its own space, radius 1), like the
## roads, the armies and the ships.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0

var mod: PaxMod
var cfg: Dictionary = {}
var _planes: MultiMeshInstance3D
var _mesh: ArrayMesh
var _routes: Array = []            # [{a: Vector3, b: Vector3, ang: float}] — the game's
var _ambient: Array = []           # the same between big cities
var _sig := ""
var _time := 0.0


func setup(m: PaxMod, planes_cfg: Dictionary) -> void:
	mod = m
	cfg = planes_cfg
	name = "PaxCorpInc3DPlanes"
	_mesh = _airliner()
	var raw: Variant = GameApi.json(m, "config/cities.json", {})
	var big: Array = []
	for row in ((raw as Dictionary).get("cities", []) if raw is Dictionary else []):
		var r: Array = row
		if r.size() >= 3:
			big.append([float(r[2]), _ll(float(r[0]), float(r[1]))])
	big.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) > float(y[0]))
	big = big.slice(0, 80)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7171
	var want := int(cfg.get("ambient", 40))
	var tries := 0
	while _ambient.size() < want and big.size() >= 2 and tries < want * 40:
		tries += 1
		var a: Vector3 = (big[rng.randi() % big.size()] as Array)[1]
		var b: Vector3 = (big[rng.randi() % big.size()] as Array)[1]
		var ang := a.angle_to(b)
		if ang < deg_to_rad(12.0) or ang > deg_to_rad(110.0):
			continue
		_ambient.append({"a": a, "b": b, "ang": ang, "phase": rng.randf()})


static func _ll(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	return Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l))


static func _dir(uv: Vector2) -> Vector3:
	var lon := (uv.x - 0.5) * TAU
	var lat := PI * 0.5 - uv.y * PI
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


## The game's air routes: [[from uv, to uv]…] (rebuilt only when they change).
func set_routes(pairs: Array) -> void:
	var sig := ""
	var routes: Array = []
	for pr in pairs:
		if not (pr is Array) or (pr as Array).size() < 2 or not ((pr as Array)[0] is Vector2) or not ((pr as Array)[1] is Vector2):
			continue
		var a := _dir((pr as Array)[0])
		var b := _dir((pr as Array)[1])
		var ang := a.angle_to(b)
		if ang < 0.002:
			continue
		sig += "%.3f,%.3f,%.3f,%.3f;" % [(pr as Array)[0].x, (pr as Array)[0].y, (pr as Array)[1].x, (pr as Array)[1].y]
		routes.append({"a": a, "b": b, "ang": ang, "phase": float(absi(hash(sig)) % 1000) / 1000.0})
	if sig == _sig and is_instance_valid(_planes):
		return
	_sig = sig
	_routes = routes
	_make()


func _make() -> void:
	if is_instance_valid(_planes):
		_planes.queue_free()
	_planes = null
	var count := _routes.size() * int(cfg.get("per_route", 2)) + _ambient.size()
	if count == 0 or _mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _mesh
	mm.instance_count = count
	_planes = MultiMeshInstance3D.new()
	_planes.name = "Jets"
	_planes.multimesh = mm
	_planes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_planes)


func count() -> int:
	return _planes.multimesh.instance_count if is_instance_valid(_planes) else 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(delta)
	GameApi.perf("corpinc3d.planes3d.process", t0)


func _process_timed(delta: float) -> void:
	if not is_instance_valid(_planes) or not is_visible_in_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt_km := ((global_transform.affine_inverse() * cam.global_position).length() - 1.0) * EARTH_KM
	_planes.visible = alt_km < float(cfg.get("show_below_km", 30000.0))
	if not _planes.visible:
		return
	_time += delta
	var span := float(cfg.get("plane_km", 45.0)) / EARTH_KM
	var speed := float(cfg.get("speed_kmh", 30000.0)) / 3600.0 / EARTH_KM   # radians a second (sped up)
	var mm := _planes.multimesh
	var i := 0
	var per := int(cfg.get("per_route", 2))
	for r in _routes:
		for j in per:
			mm.set_instance_transform(i, _xf(r, float(j) / float(per), speed, span))
			i += 1
	for a in _ambient:
		mm.set_instance_transform(i, _xf(a, 0.0, speed, span))
		i += 1


## The jet on a route at this moment: there and back, along the route's arc (the same lift as the dashed line).
func _xf(r: Dictionary, offset: float, speed: float, span: float) -> Transform3D:
	var ang := float(r["ang"])
	var trip := maxf(ang / speed, 6.0)   # seconds one way
	var s := fposmod(_time / trip + float(r.get("phase", 0.0)) + offset, 2.0)
	var forward := s < 1.0
	var t := s if forward else 2.0 - s
	var a: Vector3 = r["a"] if forward else r["b"]
	var b: Vector3 = r["b"] if forward else r["a"]
	if not forward:
		t = 1.0 - t
	var p := _on_arc(a, b, ang, t)
	var q := _on_arc(a, b, ang, minf(t + 0.01, 1.0)) if t < 0.99 else p + (p - _on_arc(a, b, ang, t - 0.01))
	var fwd := q - p
	var up := p.normalized()
	if fwd.length() < 1e-9:
		fwd = up.cross(Vector3.UP)
	fwd = fwd.normalized()
	var x := up.cross(fwd).normalized()
	if x.length() < 0.5:
		x = Vector3.RIGHT
	var y := fwd.cross(x).normalized()
	return Transform3D(Basis(x, y, fwd).scaled_local(Vector3.ONE * span), p)


## A point of the arc a → b at share t: the great circle, lifted in the middle (cruise) — globe_layers' _arc.
func _on_arc(a: Vector3, b: Vector3, ang: float, t: float) -> Vector3:
	var d := a.slerp(b, t).normalized()
	var lift := float(cfg.get("lift", 0.03)) * sin(PI * t) * clampf(ang * 2.0, 0.05, 1.0)
	return d * (1.0 + float(cfg.get("ground_lift", 0.002)) + lift)


# ---------- the model ----------

## An airliner 1 wide (wingspan), nose along +Z, up +Y: a fuselage with a nose and a tail cone, swept wings, the tail's
## fin and stabilizers, two engines under the wings. Flat faces, white with a blue line on the fin.
static func _airliner() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var white := Color(0.95, 0.96, 0.98)
	var grey := Color(0.7, 0.72, 0.76)
	var blue := Color(0.2, 0.4, 0.85)
	# Fuselage: an octagonal tube from z −0.42 to 0.36, a nose cone to 0.5, a tail cone to −0.5.
	var rad := 0.045
	var ring_at := func(z: float, r: float, yoff: float) -> Array:
		var out: Array = []
		for k in 8:
			var an := TAU * float(k) / 8.0 + PI / 8.0
			out.append(Vector3(cos(an) * r, sin(an) * r + yoff, z))
		return out
	var rings := [ring_at.call(0.5, 0.004, 0.0), ring_at.call(0.42, rad * 0.75, 0.0), ring_at.call(0.34, rad, 0.0),
		ring_at.call(-0.3, rad, 0.0), ring_at.call(-0.44, rad * 0.55, 0.02), ring_at.call(-0.5, 0.006, 0.03)]
	for ri in range(1, rings.size()):
		var r0: Array = rings[ri - 1]
		var r1: Array = rings[ri]
		for k in 8:
			var k2 := (k + 1) % 8
			_quad(st, r0[k], r0[k2], r1[k2], r1[k], white)
	# Wings: swept back, a little dihedral.
	for side: float in [1.0, -1.0]:
		var root_lead := Vector3(0.03 * side, -0.01, 0.14)
		var root_trail := Vector3(0.03 * side, -0.01, -0.06)
		var tip_lead := Vector3(0.5 * side, 0.025, -0.13)
		var tip_trail := Vector3(0.5 * side, 0.025, -0.21)
		_slab(st, root_lead, tip_lead, tip_trail, root_trail, 0.012, white)
		# Stabilizers.
		_slab(st, Vector3(0.02 * side, 0.01, -0.36), Vector3(0.17 * side, 0.02, -0.45), Vector3(0.17 * side, 0.02, -0.49),
			Vector3(0.02 * side, 0.01, -0.47), 0.008, white)
		# An engine under the wing.
		var ex := 0.17 * side
		_box(st, Vector3(ex, -0.045, 0.08), Vector3(0.022, 0.022, 0.07), grey)
	# The fin: swept, with a blue band.
	_slab_v(st, Vector3(0.0, 0.04, -0.3), Vector3(0.0, 0.19, -0.44), Vector3(0.0, 0.19, -0.5), Vector3(0.0, 0.04, -0.48), 0.008, blue)
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.45
	mat.metallic = 0.15
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.45, 0.48)   # white from orbit, and seen on the night side too
	mesh.surface_set_material(0, mat)
	return mesh


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length() < 1e-12:
		return
	n = n.normalized()
	for v in [a, b, c]:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(v)


## A quad seen from both sides (thin parts must not vanish from below).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	_tri(st, a, b, c, col)
	_tri(st, a, c, d, col)
	_tri(st, a, c, b, col)
	_tri(st, a, d, c, col)


## A flat horizontal plate (a wing) with a thickness: its top, bottom and edges.
static func _slab(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, th: float, col: Color) -> void:
	var up := Vector3(0, th * 0.5, 0)
	_hexa(st, [a + up, b + up, c + up, d + up, a - up, b - up, c - up, d - up], col)


## A flat vertical plate (the fin).
static func _slab_v(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, th: float, col: Color) -> void:
	var side := Vector3(th * 0.5, 0, 0)
	_hexa(st, [a + side, b + side, c + side, d + side, a - side, b - side, c - side, d - side], col)


static func _box(st: SurfaceTool, c: Vector3, h: Vector3, col: Color) -> void:
	var p := [c + Vector3(-h.x, h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
		c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(-h.x, -h.y, -h.z)]
	_hexa(st, p, col)


## Eight corners (the top four, then the bottom four under them): six faces, each both ways.
static func _hexa(st: SurfaceTool, p: Array, col: Color) -> void:
	_quad(st, p[0], p[1], p[2], p[3], col)
	_quad(st, p[4], p[7], p[6], p[5], col)
	for k in 4:
		var k2 := (k + 1) % 4
		_quad(st, p[k], p[k + 4], p[k2 + 4], p[k2], col)
