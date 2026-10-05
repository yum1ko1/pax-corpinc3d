extends Node3D
## Airliners on the 3D globe: white jets (a model made here — fuselage, swept wings, tail, engines) that fly between
## real airports (airports3d.gd, config/airports.json): the take-off run along the runway's real heading, the climb,
## the great circle at cruise height, the approach lined up with the destination's runway, the touchdown and the roll,
## a while at the airport, then the way back. Larger than life (config/earth.json «planes»: wingspan plane_km at
## cruise, land_km on the ground — they grow as they climb, so a jet fits its runway and is still seen from orbit).
##   on the game's air routes (the political map's caravans of the kind «самолёт» and its flights): each end goes to
##   the nearest airport (within snap_deg), per_route jets a route;
##   in the sky for the sky's sake: «ambient» jets between the world's large airports.
## Shown below show_below_km of the camera's height. Lives in the Earth's node (its own space, radius 1), like the
## roads, the armies and the ships.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0

var mod: PaxMod
var cfg: Dictionary = {}
var airports: Object                # airports3d.gd
var _planes: MultiMeshInstance3D
var _mesh: ArrayMesh
var _routes: Array = []            # the game's: [{ab: Path, ba: Path, phase}]
var _ambient: Array = []           # between large airports
var _sig := ""
var _time := 0.0
var _ambient_done := false
var _air_ver := -1


## A flight's way: directions (unit), heights over the ground (Earth radii), the angle walked so far at each point.
class Path extends RefCounted:
	var pts := PackedVector3Array()
	var alt := PackedFloat32Array()
	var ground := PackedFloat32Array()
	var cum := PackedFloat32Array()
	var total := 0.0


func setup(m: PaxMod, planes_cfg: Dictionary, airports_node: Object) -> void:
	mod = m
	cfg = planes_cfg
	airports = airports_node
	name = "PaxCorpInc3DPlanes"
	_mesh = _airliner()


func _make_ambient() -> void:
	_ambient_done = true
	var big: Array = []
	for a in (airports.get("list") as Array):
		if bool((a as Dictionary)["large"]):
			big.append(a)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7171
	var want := int(cfg.get("ambient", 60))
	var tries := 0
	while _ambient.size() < want and big.size() >= 2 and tries < want * 60:
		tries += 1
		var a: Dictionary = big[rng.randi() % big.size()]
		var b: Dictionary = big[rng.randi() % big.size()]
		var ang := (a["d"] as Vector3).angle_to(b["d"] as Vector3)
		if ang < deg_to_rad(6.0) or ang > deg_to_rad(80.0):
			continue
		_ambient.append({"ab": _path(a, b), "ba": _path(b, a), "phase": rng.randf()})


static func _dir(uv: Vector2) -> Vector3:
	var lon := (uv.x - 0.5) * TAU
	var lat := PI * 0.5 - uv.y * PI
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


## The game's air routes: [[from uv, to uv]…] (rebuilt only when they change). Each end lands on its nearest airport.
func set_routes(pairs: Array) -> void:
	if airports == null:
		return
	airports.call("ensure")
	var ver := int(airports.get("version"))
	if ver != _air_ver:
		# The runways' heights are known (or changed): every way laid again on them.
		_air_ver = ver
		_ambient.clear()
		_ambient_done = false
		_sig = "-"
	if not _ambient_done:
		_make_ambient()
		_make()
	var sig := ""
	for pr in pairs:
		if pr is Array and (pr as Array).size() >= 2 and (pr as Array)[0] is Vector2 and (pr as Array)[1] is Vector2:
			sig += "%.3f,%.3f,%.3f,%.3f;" % [(pr as Array)[0].x, (pr as Array)[0].y, (pr as Array)[1].x, (pr as Array)[1].y]
	if sig == _sig and is_instance_valid(_planes):
		return
	_sig = sig
	_routes.clear()
	var snap := float(cfg.get("snap_deg", 4.0))
	for pr in pairs:
		if not (pr is Array) or (pr as Array).size() < 2 or not ((pr as Array)[0] is Vector2) or not ((pr as Array)[1] is Vector2):
			continue
		var da := _dir((pr as Array)[0])
		var db := _dir((pr as Array)[1])
		var a := _airport_at(da, db, snap)
		var b := _airport_at(db, da, snap)
		if (a["d"] as Vector3).angle_to(b["d"] as Vector3) < deg_to_rad(1.0):
			continue
		_routes.append({"ab": _path(a, b), "ba": _path(b, a), "phase": float(absi(hash(str(pr))) % 1000) / 1000.0})
	_make()


## The real airport nearest to a route's end; none near — a runway made up there, facing the other end.
func _airport_at(d: Vector3, other: Vector3, snap: float) -> Dictionary:
	var a: Dictionary = airports.call("nearest", d, snap, false)
	if not a.is_empty():
		return a
	var head := (other - d * d.dot(other)).normalized()
	return {"d": d, "head": head, "side": d.cross(head).normalized(), "len": float(cfg.get("runway_km", 40.0)) * 0.75 / EARTH_KM,
		"ground": 1.0, "large": false}


## Along the great circle from d in the direction «dir» (a tangent) by the angle «ang».
static func _walk(d: Vector3, dir: Vector3, ang: float) -> Vector3:
	return (d * cos(ang) + dir * sin(ang)).normalized()


## The flight a → b: the run along a's runway (the end facing b), the climb straight ahead, the great circle, the
## approach lined up with b's runway (the end facing the way in), the touchdown, the roll to the runway's end.
func _path(a: Dictionary, b: Dictionary) -> Path:
	var p := Path.new()
	var da: Vector3 = a["d"]
	var db: Vector3 = b["d"]
	var cruise := float(cfg.get("cruise", 0.012))
	var climb := float(cfg.get("climb_km", 350.0)) / EARTH_KM
	var to_b := (db - da * da.dot(db)).normalized()
	var ha: Vector3 = a["head"]
	if ha.dot(to_b) < 0.0:
		ha = -ha
	var from_a := (da - db * db.dot(da)).normalized()   # at b, towards a: the way in is the opposite
	var hb: Vector3 = b["head"]
	if hb.dot(-from_a) < 0.0:
		hb = -hb
	var la := float(a["len"]) * 0.5
	var lb := float(b["len"]) * 0.5
	var ga := float(a.get("ground", 1.0))
	var gb := float(b.get("ground", 1.0))
	var total_ang := da.angle_to(db)
	var short := clampf(total_ang / (2.0 * (climb + la + lb) + 1e-6), 0.25, 1.0)   # a short hop: lower, quicker climb
	var c1 := _walk(da, ha, la + climb * short)
	var c2 := _walk(db, -hb, lb + climb * short)
	var top := cruise * short
	_add(p, _walk(da, -ha, la), 0.0, ga)
	_add(p, _walk(da, ha, la), 0.0, ga)
	_add(p, _walk(da, ha, la + climb * short * 0.5), top * 0.45, ga)
	_add(p, c1, top * 0.85, ga)
	var mid_ang := c1.angle_to(c2)
	var n := clampi(int(rad_to_deg(mid_ang) / 2.0), 1, 90)
	for k in range(1, n):
		var t := float(k) / float(n)
		_add(p, c1.slerp(c2, t).normalized(), top, lerpf(ga, gb, t))
	_add(p, c2, top * 0.75, gb)
	_add(p, _walk(db, -hb, lb + climb * short * 0.4), top * 0.3, gb)
	_add(p, _walk(db, -hb, lb), 0.0, gb)
	_add(p, _walk(db, hb, lb * 0.8), 0.0, gb)
	return p


static func _add(p: Path, d: Vector3, alt: float, ground: float) -> void:
	if not p.pts.is_empty():
		p.total += (p.pts[p.pts.size() - 1]).angle_to(d)
	p.pts.append(d)
	p.alt.append(alt)
	p.ground.append(ground)
	p.cum.append(p.total)


## The game's routes as lines for the 2D overlay's dashes: [[directions, heights over the sea level]…].
func route_lines() -> Array:
	var out: Array = []
	for r in _routes:
		var p: Path = r["ab"]
		var h := PackedFloat32Array()
		for i in p.pts.size():
			h.append(p.ground[i] - 1.0 + p.alt[i])
		out.append([p.pts, h])
	return out


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
	var mm := _planes.multimesh
	var i := 0
	var per := int(cfg.get("per_route", 2))
	for r in _routes:
		for j in per:
			mm.set_instance_transform(i, _xf(r, float(j) / float(per)))
			i += 1
	for a in _ambient:
		mm.set_instance_transform(i, _xf(a, 0.0))
		i += 1


## The jet of a route at this moment: a → b, a while at b, b → a, a while at a.
func _xf(r: Dictionary, offset: float) -> Transform3D:
	var speed := float(cfg.get("speed_kmh", 30000.0)) / 3600.0 / EARTH_KM   # radians a second (sped up)
	var wait := float(cfg.get("wait_s", 5.0))
	var ab: Path = r["ab"]
	var ba: Path = r["ba"]
	var t_ab := maxf(ab.total / speed, 6.0)
	var t_ba := maxf(ba.total / speed, 6.0)
	var cycle := t_ab + t_ba + wait * 2.0
	var t := fposmod(_time + (float(r.get("phase", 0.0)) + offset) * cycle, cycle)
	if t < t_ab:
		return _on(ab, t / t_ab)
	t -= t_ab
	if t < wait:
		return _on(ab, 1.0)
	t -= wait
	if t < t_ba:
		return _on(ba, t / t_ba)
	return _on(ba, 1.0)


## The jet's place and attitude at a share of its way; larger as it climbs (land_km on the runway, plane_km at cruise).
func _on(p: Path, share: float) -> Transform3D:
	var s := clampf(share, 0.0, 1.0) * p.total
	var pos := _at(p, s)
	var ahead := _at(p, minf(s + 0.002, p.total))
	var fwd := ahead - pos
	if s + 0.002 > p.total:
		fwd = pos - _at(p, maxf(s - 0.002, 0.0))
	var up := pos.normalized()
	if fwd.length() < 1e-9:
		fwd = up.cross(Vector3.UP)
	fwd = fwd.normalized()
	var x := up.cross(fwd).normalized()
	if x.length() < 0.5:
		x = Vector3.RIGHT
	var y := fwd.cross(x).normalized()
	var h := pos.length() - _ground_at(p, s)
	var cruise := float(cfg.get("cruise", 0.012))
	var k := smoothstep(0.0, cruise * 0.8, h)
	var span := lerpf(float(cfg.get("land_km", 9.0)), float(cfg.get("plane_km", 90.0)), k) / EARTH_KM
	# On the ground the wheels touch the runway: the model's middle a little over it.
	return Transform3D(Basis(x, y, fwd).scaled_local(Vector3.ONE * span), pos + up * span * 0.06)


func _seg(p: Path, s: float) -> int:
	var lo := 0
	var hi := p.cum.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if p.cum[mid] <= s:
			lo = mid
		else:
			hi = mid
	return lo


func _at(p: Path, s: float) -> Vector3:
	var i := _seg(p, s)
	var j := mini(i + 1, p.pts.size() - 1)
	var len_seg := p.cum[j] - p.cum[i]
	var t := clampf((s - p.cum[i]) / len_seg, 0.0, 1.0) if len_seg > 1e-9 else 0.0
	var d := p.pts[i].slerp(p.pts[j], t).normalized()
	var h := lerpf(p.alt[i], p.alt[j], smoothstep(0.0, 1.0, t))
	return d * (lerpf(p.ground[i], p.ground[j], t) + h)


func _ground_at(p: Path, s: float) -> float:
	var i := _seg(p, s)
	var j := mini(i + 1, p.pts.size() - 1)
	var len_seg := p.cum[j] - p.cum[i]
	var t := clampf((s - p.cum[i]) / len_seg, 0.0, 1.0) if len_seg > 1e-9 else 0.0
	return lerpf(p.ground[i], p.ground[j], t)


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
