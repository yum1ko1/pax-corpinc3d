extends Node3D
## Real airports on the 3D Earth (config/airports.json — OurAirports, tools/gen_airports.py: the large airports with
## scheduled flights, the medium ones where a country has no large one): a runway along the real longest runway's
## heading with its centre line and threshold marks, a taxiway beside it, an apron with the terminal and a control
## tower. Larger than life like everything here (config/earth.json «airports»: runway_km), so the 3D jets
## (planes3d.gd) that take off and land on them are seen. GPU instancing: one MultiMesh a part.
## Shown below show_below_km of the camera's height; switched by «Слои глобуса» (airports). Lives in the Earth's node
## (its own space, radius 1: x = cos φ sin λ, y = sin φ, z = cos φ cos λ), on the 3D ground (earth.surface_radius).

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_KM := 6371.0

var mod: PaxMod
var cfg: Dictionary = {}
var list: Array = []                # [{d, head, side, len, iata, name, city, large, ground}]
var _parts: Array = []              # MultiMeshInstance3D
var _built := false
var _ground_on := false
var version := 0                    # +1 a build: the jets lay their ways again (the runways' heights changed)


func setup(m: PaxMod, air_cfg: Dictionary) -> void:
	mod = m
	cfg = air_cfg
	name = "PaxCorpInc3DAirports"
	var raw: Variant = GameApi.json(m, "config/airports.json", {})
	for row in ((raw as Dictionary).get("airports", []) if raw is Dictionary else []):
		var r: Array = row
		if r.size() < 9:
			continue
		var d := _ll(float(r[0]), float(r[1]))
		var east := Vector3.UP.cross(d)
		if east.length() < 1e-4:
			east = Vector3.RIGHT
		east = east.normalized()
		var north := d.cross(east).normalized()
		var hd := deg_to_rad(float(r[5]))
		var head := (north * cos(hd) + east * sin(hd)).normalized()
		var large := int(r[8]) == 1
		list.append({"d": d, "head": head, "side": d.cross(head).normalized(), "iata": str(r[2]), "name": str(r[3]),
			"city": str(r[4]), "large": large,
			"len": float(cfg.get("runway_km", 40.0)) * (1.0 if large else 0.75) / EARTH_KM, "ground": 1.0})


static func _ll(lat: float, lon: float) -> Vector3:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	return Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l))


## Whether a point stands on an airport's ground: its runway, the taxiway and the terminal side (a box along the runway,
## not a circle — the cities round real airports keep their houses). a: [d, head, side, len] or the list's entry.
static func covers(d: Vector3, head: Vector3, side: Vector3, length: float, p: Vector3, margin: float = 0.0) -> bool:
	var rel := p - d * d.dot(p)
	var along := rel.dot(head)
	var across := rel.dot(side)
	return absf(along) < length * 0.55 + margin and across > -3.5 / EARTH_KM - margin and across < 12.0 / EARTH_KM + margin


## The airport nearest to a direction within max_deg ({} — none there).
func nearest(d: Vector3, max_deg: float = 4.0, large_only: bool = false) -> Dictionary:
	var best: Dictionary = {}
	var best_a := deg_to_rad(max_deg)
	var dn := d.normalized()
	for a in list:
		if large_only and not bool(a["large"]):
			continue
		var ang := dn.angle_to(a["d"] as Vector3)
		if ang < best_a:
			best_a = ang
			best = a
	return best


## Built now if it was not, or if the 3D ground came or went since (the runways lie on it).
func ensure() -> void:
	var earth: Variant = mod.get("earth")
	# The 3D ground is up when the Himalaya stands above the sea level (earth.surface_radius gives 1 until then).
	var ground_on := earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius") \
		and float((earth as Object).call("surface_radius", _ll(28.0, 87.0))) > 1.0001
	if not _built or ground_on != _ground_on:
		_ground_on = ground_on
		_build(earth)


func _process(_delta: float) -> void:
	if list.is_empty() or not is_visible_in_tree():
		return
	ensure()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt_km := ((global_transform.affine_inverse() * cam.global_position).length() - 1.0) * EARTH_KM
	var show := alt_km < float(cfg.get("show_below_km", 6000.0))
	for p in _parts:
		if is_instance_valid(p):
			(p as Node3D).visible = show


## The ground under an airport (its runway lies there; the jets roll on it).
func ground_of(a: Dictionary) -> float:
	return float(a.get("ground", 1.0))


func _build(earth: Variant) -> void:
	_built = true
	version += 1
	for p in _parts:
		if is_instance_valid(p):
			(p as Node).queue_free()
	_parts.clear()
	var has_ground := earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius")
	for a in list:
		a["ground"] = float((earth as Object).call("surface_radius", a["d"])) if has_ground else 1.0
	var km := 1.0 / EARTH_KM
	var w := float(cfg.get("runway_w_km", 2.4)) * km
	# [colour, per airport: [along (share of the runway), across (km), up (km), length (share), width (km), height (km)]]
	var asphalt := Color(0.16, 0.16, 0.18)
	var white := Color(0.95, 0.95, 0.92)
	var concrete := Color(0.62, 0.62, 0.6)
	var terminal := Color(0.82, 0.84, 0.88)
	var glass := Color(0.25, 0.42, 0.6)
	var specs: Array = [
		[asphalt, [[0.0, 0.0, 0.0, 1.0, w * EARTH_KM, 0.06]]],                                  # the runway
		[concrete, [[0.0, 3.4, 0.0, 0.85, 1.4, 0.05], [0.0, 1.7, 0.0, 0.04, 1.6, 0.05], [0.4, 1.7, 0.0, 0.04, 1.6, 0.05],
			[-0.4, 1.7, 0.0, 0.04, 1.6, 0.05], [0.05, 6.3, 0.0, 0.42, 4.6, 0.04]]],             # taxiway, links, apron
		[white, [[-0.47, 0.0, 0.03, 0.03, w * EARTH_KM * 0.8, 0.07], [0.47, 0.0, 0.03, 0.03, w * EARTH_KM * 0.8, 0.07],
			[-0.3, 0.0, 0.03, 0.08, 0.18, 0.07], [-0.12, 0.0, 0.03, 0.08, 0.18, 0.07], [0.06, 0.0, 0.03, 0.08, 0.18, 0.07],
			[0.24, 0.0, 0.03, 0.08, 0.18, 0.07]]],                                               # thresholds, centre line
		[terminal, [[0.05, 8.9, 0.0, 0.34, 2.2, 1.3], [-0.2, 7.2, 0.0, 0.03, 1.0, 0.5], [0.0, 7.2, 0.0, 0.03, 1.0, 0.5],
			[0.2, 7.2, 0.0, 0.03, 1.0, 0.5], [-0.28, 8.4, 0.0, 0.016, 0.5, 3.6]]],              # terminal, piers, tower
		[glass, [[0.05, 8.9, 1.3, 0.34, 2.0, 0.25], [-0.28, 8.4, 3.6, 0.03, 1.1, 0.8]]],      # roof glass, the tower's cab
	]
	for spec in specs:
		var col: Color = spec[0]
		var parts: Array = spec[1]
		var xfs: Array = []
		for a in list:
			var d: Vector3 = a["d"]
			var head: Vector3 = a["head"]
			var side: Vector3 = a["side"]
			var length := float(a["len"])
			var g := float(a["ground"])
			for pv in parts:
				var p: Array = pv
				var at := (d + head * float(p[0]) * length + side * float(p[1]) * km).normalized()
				var up := at
				var basis := Basis(side, up, head)
				var size := Vector3(float(p[4]) * km, float(p[5]) * km, float(p[3]) * length)
				var centre := at * (g + float(p[2]) * km + size.y * 0.5)
				xfs.append(Transform3D(basis.scaled_local(size), centre))
		_parts.append(_multi(col, xfs))


func _multi(col: Color, xfs: Array) -> MultiMeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.85
	m.emission_enabled = true
	m.emission = col * 0.25        # seen from orbit, and at night
	box.material = m
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
	var mi := MultiMeshInstance3D.new()
	# The whole planet as its box: the box the engine counts from the first (all-zero) transforms went stale and
	# the armies, ships and jets were culled as unseen in the game (the Forward+ renderer).
	mi.custom_aabb = AABB(Vector3(-1.3, -1.3, -1.3), Vector3(2.6, 2.6, 2.6))
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi
