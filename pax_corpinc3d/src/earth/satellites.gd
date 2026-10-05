extends Node
## The Earth's satellites in a new look (config/models.json «satellite»): every satellite and station of the game
## (_is_satellite: the kind «спутник», every «станция», the ISS-like ones too; not the arks) keeps flying as the game flies them, but their own model is
## hidden and ours stands in its place every frame (the same position, turn and size — its largest side fitted to the
## game's span: config/earth.json «satellites».scale, 1.8 of the game's unit — body and both panels). Hidden are the
## parts inside the game's node, not the node: the game sets the node's «visible» itself every frame (Main.gd), so a
## hidden node came back and both models were drawn one in another. Ours is seen while the game's node is.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")

var mod: PaxMod
var game: PaxGame
var cfg: Dictionary = {}
var shown := true                  # the «Слои глобуса» switch «satellites»
var _ours: Dictionary = {}          # the game's node → [our node, the body's name]
var _scan := 0.0


func setup(m: PaxMod) -> void:
	mod = m
	var raw: Variant = GameApi.json(m, "config/earth.json", {})
	cfg = (raw as Dictionary).get("satellites", {}) if raw is Dictionary else {}
	name = "PaxCorpInc3DSatellites"


func start(g: PaxGame) -> void:
	game = g


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(delta)
	GameApi.perf("corpinc3d.satellites.process", t0)   # Pax CorpInc3D probe: where the frame goes


func _process_timed(delta: float) -> void:
	if game == null or not is_instance_valid(game.main) or not bool(cfg.get("enabled", true)):
		return
	_scan -= delta
	if _scan <= 0.0:
		_scan = 1.0
		_find()
	for node in _ours.keys():
		var pair: Array = _ours[node]
		var mine: Node3D = pair[0]
		if not is_instance_valid(node) or not is_instance_valid(mine):
			if is_instance_valid(mine):
				mine.queue_free()
			_ours.erase(node)
			continue
		var n3: Node3D = node
		var open := bool(V.pick(game.body(str(pair[1])), ["открыт", "open", "discovered"], true))
		if _scan >= 0.999:
			_hide_parts(n3, false)   # once a second: parts the game added since
		mine.visible = shown and open and n3.is_visible_in_tree()
		if mine.visible:
			mine.global_transform = n3.global_transform


## The satellites among the bodies, a new model for each one not dressed yet.
func _find() -> void:
	for body_name in game.body_names():
		var b: Dictionary = game.body(body_name)
		if not _is_satellite(b):
			continue
		var node: Variant = V.pick(b, ["узел", "node"])
		if not (node is Node3D) or not is_instance_valid(node) or _ours.has(node):
			continue
		var mine := _model()
		if mine == null:
			return
		var parent := (node as Node3D).get_parent()
		if parent == null:
			continue
		parent.add_child(mine)
		_ours[node] = [mine, body_name]
		_hide_parts(node as Node3D, false)


## Every artificial body in orbit gets the new model: satellites (kind «спутник») and every station — the ISS-like
## ones too (before only the stations marked «исз» were dressed, the rest kept the game's cylinders and trusses).
## The arks (ковчег) are ships, not satellites: they keep their own look.
static func _is_satellite(b: Dictionary) -> bool:
	var name_l := str(V.pick(b, ["имя", "name"], "")).to_lower()
	if name_l.contains("ковчег") or name_l.begins_with("ark"):
		return false
	var kind := str(V.pick(b, ["вид", "kind", "type"], "")).to_lower()
	var genus := str(V.pick(b, ["род", "genus", "class"], "")).to_lower()
	for w in ["спутник", "satellite", "станция", "station", "исз"]:
		if kind.contains(w) or genus.contains(w):
			return true
	return V.pick(b, ["станция", "station"]) is Dictionary


## The game's own model: every drawn part inside its node off (or back on).
static func _hide_parts(n: Node3D, show: bool) -> void:
	for ch in n.find_children("*", "VisualInstance3D", true, false):
		if (ch as VisualInstance3D).visible != show:
			(ch as VisualInstance3D).visible = show


## Our model, its middle at the origin, its largest side = the game's unit × scale (the game scales the node).
func _model() -> Node3D:
	var m: Node3D = mod.model("models/satellite.glb")
	if m == null:
		return null
	var box := AABB()
	var first := true
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		var bb := (mi as MeshInstance3D).transform * mesh.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	var holder := Node3D.new()
	holder.name = "PaxCorpInc3DSatellite"
	var side := maxf(maxf(box.size.x, box.size.y), maxf(box.size.z, 1e-6))
	var k := float(cfg.get("scale", 1.0)) / side
	m.scale = Vector3.ONE * k
	m.position = -box.get_center() * k
	holder.add_child(m)
	return holder


func restore() -> void:
	for node in _ours.keys():
		if is_instance_valid(node):
			_hide_parts(node as Node3D, true)
		var mine: Variant = (_ours[node] as Array)[0]
		if is_instance_valid(mine):
			(mine as Node).queue_free()
	_ours.clear()


func _exit_tree() -> void:
	restore()
