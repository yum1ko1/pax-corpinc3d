extends Node
## The photographer of Pax CorpInc3D. The game's map is a flat picture of the world, so the buildings are not put on
## a globe: each model (models/*.glb, config/models.json) is photographed once by a fixed isometric camera in a
## hidden render window (its own 3D world, the sun, soft light) and the picture is kept. Pax Corporations' map layer
## draws these pictures at the companies' sites (its «bank»: pic()). One camera scale for every model, so a tower
## stands taller than a warehouse. Pictures are made lazily — only those the map asks for, one a frame — and cached
## by (model, state). States: норма; кризис — darker; банкрот / заморожена — grey.
## Kinds without a model answer {"нет": true}: Pax Corporations then draws its own voxel picture.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")   # Main's methods and the mod's JSON, game 0.24
const PX := 512                  # the photo's side, px (the map works in 256-px units: anchors are halved)
const UNITS := 256.0

var mod: PaxMod
var ortho := 400.0               # metres the camera sees top to bottom (config «камера_м»)
var models: Dictionary = {}      # model id -> {файл, ширина_м | высота_м}
var map_hq: Dictionary = {}      # company frame -> model id
var map_kind: Dictionary = {}    # site type -> model id
var map_sector: Dictionary = {}  # industry -> {site type -> model id} («» — no model: the voxel picture)
var enabled := true
var on_ready: Callable           # func() — new pictures are there (the map redraws)

var _vp: SubViewport
var _cam: Camera3D               # the isometric camera (a tilted map)
var _cam_top: Camera3D           # the camera from above (the usual top map)
var _stage: Node3D
var _pics: Dictionary = {}       # key -> {tex, anchor, top}
var _queue: Array = []           # [key, model id, state]
var _busy := false


func setup(m: PaxMod) -> void:
	mod = m
	var cfg: Variant = GameApi.json(m, "config/models.json", {})
	if cfg is Dictionary:
		var cd: Dictionary = cfg
		ortho = float(cd.get("camera_m", 400.0))
		models = cd.get("модели", {})
		map_hq = cd.get("hqs", {})
		map_kind = cd.get("sites_list", {})
		map_sector = cd.get("by_sector", {})
	enabled = bool(m.get_setting("on", true))


func _ready() -> void:
	name = "PaxCorpInc3DPhoto"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_vp = SubViewport.new()
	_vp.size = Vector2i(PX, PX)
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.78, 0.82, 0.9)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-30, 150, 0)
	fill.light_energy = 0.35
	_vp.add_child(fill)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = ortho
	_cam.near = 1.0
	_cam.far = 5000.0
	# Isometric: from the south-east, 30° above the ground; the base sits low in the picture (as Pax Corporations').
	_cam.position = Vector3(1, 0.82, 1).normalized() * 1500.0 + Vector3(0, ortho * 0.32, 0)
	_vp.add_child(_cam)
	_cam.look_at(Vector3(0, ortho * 0.32, 0), Vector3.UP)
	# From above: straight down, north up; a building's footprint fills about half of the picture.
	_cam_top = Camera3D.new()
	_cam_top.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam_top.size = ortho * 0.62
	_cam_top.near = 1.0
	_cam_top.far = 5000.0
	_cam_top.position = Vector3(0, 2000.0, 0)
	_vp.add_child(_cam_top)
	_cam_top.look_at(Vector3.ZERO, Vector3(0, 0, -1))
	_stage = Node3D.new()
	_vp.add_child(_stage)


func _process(_delta: float) -> void:
	if not _busy and not _queue.is_empty():
		_render_next()


## The model a site gets: a headquarters by the company's frame, other sites by their type; "" — none.
func model_for(kind: String, frame: String, sector: String = "") -> String:
	var id := ""
	var by: Dictionary = map_sector.get(sector, {}) if map_sector.get(sector) is Dictionary else {}
	if by.has(kind):
		id = str(by[kind])
	elif kind == "штаб":
		id = str(map_hq.get(frame if not frame.is_empty() else "нет", map_hq.get("нет", "")))
	else:
		id = str(map_kind.get(kind, ""))
	return id if models.has(id) else ""


## The map's view (Pax Corpface's isometric map): "iso" or "top".
static func view() -> String:
	var v: Variant = Engine.get_meta("pax_map_view") if Engine.has_meta("pax_map_view") else null
	return "iso" if v is Dictionary and bool((v as Dictionary).get("iso", false)) else "top"


## The picture of a building: {tex, anchor, top} (256-px units), {} while it is being made, {"нет": true} — no model.
func pic(kind: String, frame: String, state: String, sector: String = "") -> Dictionary:
	if not enabled:
		return {"нет": true}
	var id := model_for(kind, frame, sector)
	if id.is_empty() or state == "руины":
		return {"нет": true}
	var key := id + "|" + state + "|" + view()
	if _pics.has(key):
		return _pics[key]
	for q in _queue:
		if str((q as Array)[0]) == key:
			return {}
	_queue.append([key, id, state])
	return {}


func clear() -> void:
	_pics.clear()


func _render_next() -> void:
	_busy = true
	var q: Array = _queue.pop_front()
	var key := str(q[0])
	var id := str(q[1])
	var state := str(q[2])
	var spec: Dictionary = models[id]
	var node: Node3D = mod.model("models/" + str(spec.get("файл", id + ".glb")))
	if node == null:
		mod.log_warning("3D: no model models/%s" % str(spec.get("файл", "")))
		_pics[key] = {"нет": true}
		_busy = false
		return
	for ch in _stage.get_children():
		ch.queue_free()
	_stage.add_child(node)
	# Measure the model, scale it to its real size, its base centre to the origin.
	var box := _bounds(node)
	var k := 1.0
	if spec.has("height_m"):
		k = float(spec["height_m"]) / maxf(box.size.y, 0.001)
	else:
		k = float(spec.get("width_m", 60.0)) / maxf(maxf(box.size.x, box.size.z), 0.001)
	node.scale = Vector3.ONE * k
	var c := box.get_center()
	node.position = Vector3(-c.x * k, -box.position.y * k, -c.z * k)
	var height := box.size.y * k
	var half := float(PX) / UNITS
	var cam := _cam_top if key.ends_with("|top") else _cam
	cam.current = true
	var anchor := cam.unproject_position(Vector3.ZERO) / half
	var top := cam.unproject_position(Vector3(0, height, 0)) / half
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	if not is_instance_valid(_vp):
		return
	var img := _vp.get_texture().get_image()
	match state:
		"кризис":
			img.adjust_bcs(0.72, 1.0, 0.85)
		"банкрот", "frozen_f":
			img.adjust_bcs(0.8, 0.9, 0.0)
	_pics[key] = {"tex": ImageTexture.create_from_image(img), "anchor": anchor, "top": top}
	node.queue_free()
	_busy = false
	if on_ready.is_valid():
		on_ready.call()


## The model's box in its own space: every mesh under it.
static func _bounds(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b := xf * mi.mesh.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out
