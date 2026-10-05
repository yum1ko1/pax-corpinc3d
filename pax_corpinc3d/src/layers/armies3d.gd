extends Node3D
## The armies on the 3D globe (globe_layers.gd hands it the game's units every frame): where an army stands, an
## armoured car (config/models.json «humvee») and three soldiers («soldier»), many times larger than life so they are
## seen from the overview height, on a ring in the army's country's colour. The models have no skeleton: the soldiers
## move whole — one keeps watch and looks around, one bends to some work and straightens up, one walks a patrol round
## the car with a step; each army in its own phase. GPU instancing (MultiMesh), the models made lighter (mesh_lod).
## Shown below show_below_km of the camera's height (config/earth.json «armies»). Lives in the Earth's node (its own
## space, radius 1), like the roads.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0

var mod: PaxMod
var cfg: Dictionary = {}
var _soldiers: MultiMeshInstance3D
var _cars: MultiMeshInstance3D
var _rings: MultiMeshInstance3D
var _groups: Array = []            # [{p: Vector3, e: Vector3, n: Vector3, yaw: float, phase: float, ground: float, col: Color}]
var _sig := ""
var _soldier: Dictionary = {}      # mesh_lod: {mesh, base, foot}
var _car: Dictionary = {}
var _time := 0.0


func setup(m: PaxMod, armies_cfg: Dictionary) -> void:
	mod = m
	cfg = armies_cfg
	name = "PaxCorpInc3DArmies"


## The game's units (the political map's list): [{uv, colour, …}]. Rebuilt only when they moved or changed.
func set_units(list: Array) -> void:
	var sig := ""
	for a in list:
		if a is Dictionary and (a as Dictionary).get("uv") is Vector2:
			var uv: Vector2 = (a as Dictionary)["uv"]
			sig += "%.4f,%.4f;" % [uv.x, uv.y]
	if sig == _sig:
		return
	_sig = sig
	var globe: Variant = mod.get("globe")
	var earth: Variant = mod.get("earth")
	_groups.clear()
	for a in list:
		if not (a is Dictionary) or not ((a as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = a
		var uv: Vector2 = d["uv"]
		var lon := (uv.x - 0.5) * TAU
		var lat := PI * 0.5 - uv.y * PI
		var p := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
		var e := Vector3.UP.cross(p)
		if e.length() < 0.001:
			e = Vector3.RIGHT
		e = e.normalized()
		var n := p.cross(e).normalized()
		var h := absi(hash(Vector2i(roundi(uv.x * 1e5), roundi(uv.y * 1e5))))
		var ground := 1.0
		if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius"):
			ground = float((earth as Object).call("surface_radius", p))
		var col: Variant = d.get("colour", d.get("color", d.get("цвет", Color.GRAY)))
		_groups.append({"p": p, "e": e, "n": n, "yaw": float(h % 6283) / 1000.0, "phase": float((h / 7) % 1000) / 100.0,
			"ground": ground, "col": col if col is Color else Color.GRAY})
	if _soldier.is_empty() and globe is Object and is_instance_valid(globe):
		_soldier = (globe as Object).call("mesh_lod", "soldier", int(cfg.get("soldier_tris", 3000)))
		_car = (globe as Object).call("mesh_lod", "humvee", int(cfg.get("car_tris", 4000)))
	_make()


func _make() -> void:
	var t0 := Time.get_ticks_usec()
	_make_timed()
	GameApi.perf("corpinc3d.armies3d.make", t0)   # Pax CorpInc3D probe: where the frame goes


func _make_timed() -> void:
	for n in [_soldiers, _cars, _rings]:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_soldiers = null
	_cars = null
	_rings = null
	if _groups.is_empty():
		return
	if not _soldier.is_empty():
		_soldiers = _multi(_soldier["mesh"] as Mesh, _groups.size() * 3, false)
	if not _car.is_empty():
		_cars = _multi(_car["mesh"] as Mesh, _groups.size(), false)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.72
	ring.outer_radius = 1.0
	ring.rings = 48
	ring.ring_segments = 6
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	ring.material = m
	_rings = _multi(ring, _groups.size(), true)
	var car_km := float(cfg.get("car_km", 3.0)) / EARTH_KM
	for i in _groups.size():
		var g: Dictionary = _groups[i]
		var b := _frame(g, float(g["yaw"]))
		var at: Vector3 = (g["p"] as Vector3) * float(g["ground"])
		if _cars != null:
			var hc := car_km / maxf(float(_car["foot"]), 0.1)
			_cars.multimesh.set_instance_transform(i, Transform3D(b.scaled_local(Vector3.ONE * hc), at) * (_car["base"] as Transform3D))
		var r := car_km * 1.6
		_rings.multimesh.set_instance_transform(i, Transform3D(b.scaled_local(Vector3(r, r * 0.08, r)), at + (g["p"] as Vector3) * car_km * 0.03))
		_rings.multimesh.set_instance_color(i, (g["col"] as Color).lightened(0.25))
	_animate()


func _multi(mesh: Mesh, count: int, colors: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## The army's own frame on the ground, turned by yaw: X — right, Y — up, Z — X × Y.
static func _frame(g: Dictionary, yaw: float) -> Basis:
	var up: Vector3 = g["p"]
	var right: Vector3 = (g["e"] as Vector3) * cos(yaw) + (g["n"] as Vector3) * sin(yaw)
	return Basis(right, up, right.cross(up))


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(delta)
	GameApi.perf("corpinc3d.armies3d.process", t0)   # Pax CorpInc3D probe: where the frame goes


func _process_timed(delta: float) -> void:
	if _groups.is_empty() or not is_visible_in_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt_km := ((global_transform.affine_inverse() * cam.global_position).length() - 1.0) * EARTH_KM
	var show := alt_km < float(cfg.get("show_below_km", 2500.0))
	for n in [_soldiers, _cars, _rings]:
		if is_instance_valid(n):
			(n as Node3D).visible = show
	if show:
		_time += delta
		_animate()


## The soldiers this frame: 0 keeps watch (turns his head and body slowly), 1 works (bends forward and back),
## 2 walks a patrol round the car (a step's bob and sway).
func _animate() -> void:
	if not is_instance_valid(_soldiers) or _soldier.is_empty():
		return
	var car_km := float(cfg.get("car_km", 3.0)) / EARTH_KM
	var sh := float(cfg.get("soldier_km", 1.4)) / EARTH_KM   # a soldier's height
	var base: Transform3D = _soldier["base"]
	for i in _groups.size():
		var g: Dictionary = _groups[i]
		var t := _time + float(g["phase"])
		var yaw := float(g["yaw"])
		var up: Vector3 = g["p"]
		var at: Vector3 = up * float(g["ground"])
		var b0 := _frame(g, yaw)
		# 0 — on guard at the car's front corner, looking round.
		var look := _frame(g, yaw + 0.9 * sin(t * 0.6) + 0.3 * sin(t * 1.7))
		var breath := 1.0 + 0.02 * sin(t * 2.4)
		var p0 := at + b0.x * car_km * 0.7 + b0.z * car_km * 0.9
		_soldiers.multimesh.set_instance_transform(i * 3, Transform3D(look.scaled_local(Vector3(sh, sh * breath, sh)), p0) * base)
		# 1 — at work by the car's side: bends forward (up to 35°), straightens, again.
		var bend := deg_to_rad(35.0) * pow(0.5 + 0.5 * sin(t * 1.9), 2.0)
		var wb := _frame(g, yaw + PI * 0.5)
		wb = Basis(wb.x, wb.y, wb.z).rotated(wb.x.normalized(), bend)
		var p1 := at - b0.x * car_km * 0.75 + b0.z * car_km * 0.1
		_soldiers.multimesh.set_instance_transform(i * 3 + 1, Transform3D(wb.scaled_local(Vector3.ONE * sh), p1) * base)
		# 2 — a patrol on a circle round the car, facing the way he walks; a step's bob and sway.
		var a := t * 0.35
		var rad := car_km * 1.25
		var pos := at + (b0.x * cos(a) + b0.z * sin(a)) * rad
		var step := absf(sin(t * 5.0))
		var walk := _frame(g, yaw - a)
		walk = walk.rotated(walk.z.normalized(), 0.05 * sin(t * 5.0))
		pos += up * sh * 0.05 * step
		_soldiers.multimesh.set_instance_transform(i * 3 + 2, Transform3D(walk.scaled_local(Vector3.ONE * sh), pos) * base)
