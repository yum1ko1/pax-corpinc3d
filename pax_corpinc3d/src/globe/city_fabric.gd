extends RefCounted
## The fabric of a company city (globe.gd _build): the companies' quarters no longer stand alone on grey pads — round
## them the city goes on in blocks of the same grid, as many as the real city's people ask (config/cities.json, the
## largest city within 0.6°: 35 000 people a block, the companies' own quarters ×2 at least), the outline ragged like a
## real city's, none over water. A block: 3 × 3 lots in the middle, 2 × 2 farther out; a house a lot — taller to the
## centre (now and then a tower), lower to the edge, walls of the cities' colours (towns.gd WALLS); now and then a
## square of green instead of a block (a park). The blocks join the city's cells, so roads3d.gd runs the streets
## between them too and towns.gd keeps its own houses out. Everything by a hash of the place: the same every time.

const Towns := preload("res://mods/pax_corpinc3d/src/globe/towns.gd")

var _pops: Array = []               # [direction, people] of the world's cities (config/cities.json)


func load_cities(raw: Variant) -> void:
	_pops.clear()
	for row in ((raw as Dictionary).get("cities", []) if raw is Dictionary else []):
		var r: Array = row
		if r.size() >= 3 and float(r[2]) >= 100000.0:
			var p := deg_to_rad(float(r[0]))
			var l := deg_to_rad(float(r[1]))
			_pops.append([Vector3(cos(p) * sin(l), sin(p), cos(p) * cos(l)), float(r[2])])


## The people of the largest real city near «up» (0 — none known).
func people_near(up: Vector3) -> float:
	var best := 0.0
	var lim := deg_to_rad(0.6)
	for c in _pops:
		if float(c[1]) > best and up.angle_to(c[0] as Vector3) < lim:
			best = float(c[1])
	return best


static func _h(x: int, y: int, s: int) -> float:
	var v := (x * 73856093) ^ (y * 19349663) ^ (s * 83492791)
	v = (v ^ (v >> 13)) * 1274126177
	v = v ^ (v >> 16)
	return float(v & 0xFFFFFF) / 16777216.0


## A city's blocks round its companies' cells. Returns {blocks: [Vector2], houses: [[Transform3D, Color]], pads:
## [Transform3D], parks: [Transform3D]}. «ground» — func(dir) -> radius, «water» — func(dir) -> bool.
func build(up: Vector3, east: Vector3, north: Vector3, step: float, cells: Array, house_k: float, scale: float,
		ground: Callable, water: Callable) -> Dictionary:
	var out := {"blocks": [], "houses": [], "pads": [], "parks": []}
	var people := people_near(up)
	var want := clampi(int(people / 35000.0 * scale), cells.size() * 2, int(300.0 * scale) + cells.size())
	if want <= cells.size():
		return out
	var busy := {}
	for cv in cells:
		busy[Vector2i(roundi((cv as Vector2).x), roundi((cv as Vector2).y))] = true
	var reach := sqrt(float(want) / PI) * 1.2 + 1.0
	var seed := int(absi(hash(Vector3i(roundi(up.x * 1e4), roundi(up.y * 1e4), roundi(up.z * 1e4)))) % 100000)
	var side := int(ceil(reach)) + 2
	var spiral: Array = []
	for x in range(-side, side + 1):
		for y in range(-side, side + 1):
			spiral.append(Vector2i(x, y))
	spiral.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return Vector2(a).length_squared() < Vector2(b).length_squared())
	var left := want - cells.size()
	for c: Vector2i in spiral:
		if left <= 0:
			break
		if busy.has(c):
			continue
		var q := Vector2(c).length() / reach
		# A ragged edge: farther out, more blocks left empty.
		if _h(c.x, c.y, seed) > 1.15 - q * q * 0.9:
			continue
		var centre := (up + east * float(c.x) * step + north * float(c.y) * step).normalized()
		if bool(water.call(centre)):
			continue
		left -= 1
		(out["blocks"] as Array).append(Vector2(c))
		var e2 := Vector3.UP.cross(centre)
		if e2.length() < 0.001:
			e2 = Vector3.RIGHT
		e2 = e2.normalized()
		var basis := Basis(e2, centre, e2.cross(centre).normalized())
		var g := float(ground.call(centre))
		if _h(c.x, c.y, seed + 1) < 0.07 and q > 0.25:
			(out["parks"] as Array).append(Transform3D(basis.scaled(Vector3.ONE * step), centre * (g + step * 0.002)))
			continue
		(out["pads"] as Array).append(Transform3D(basis.scaled(Vector3.ONE * step), centre * (g + step * 0.002)))
		var lots := 3 if q < 0.55 else 2
		var lot := step * 0.74 / float(lots)    # the block's inner part: the streets keep the rest
		for i in lots:
			for j in lots:
				var hx := _h(c.x * 7 + i, c.y * 7 + j, seed + 2)
				var hy := _h(c.x * 7 + i, c.y * 7 + j, seed + 3)
				var ox := (float(i) - float(lots - 1) * 0.5) * lot + (hx - 0.5) * lot * 0.12
				var oy := (float(j) - float(lots - 1) * 0.5) * lot + (hy - 0.5) * lot * 0.12
				var at := (centre + e2 * ox + basis.z * oy).normalized()
				var w := lot * (0.6 + 0.25 * hx)
				var d := lot * (0.6 + 0.25 * hy)
				var tall := house_k * lerpf(1.5, 0.3, clampf(q, 0.0, 1.0)) * (0.55 + 0.9 * _h(c.x + i, c.y + j, seed + 4))
				if q < 0.35 and _h(c.x + i * 3, c.y + j * 5, seed + 5) < 0.12:
					tall *= 2.6   # a tower among the blocks of the middle
				var col: Color = Towns.WALLS[int(_h(c.x * 3 + i, c.y * 5 + j, seed + 6) * Towns.WALLS.size()) % Towns.WALLS.size()]
				var b2 := Basis(e2 * w, at * tall, basis.z * d)
				(out["houses"] as Array).append([Transform3D(b2, at * (float(ground.call(at)) - tall * 0.02)), col])
	return out
