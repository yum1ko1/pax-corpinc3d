extends Node3D
## The world's landmarks (config/landmarks.json, models/landmarks/<id>.glb — built in Blender by
## pax_corporations_dev/landmarks_blender.py): each stands where it really is, on the 3D ground, «scale» times larger
## than life (so it is seen from the overview height), facing north. Shown below show_below_km of the camera's
## height. Lives in the Earth's node (its own space, radius 1) under globe.gd's holder, like the cities.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const EARTH_M := 6371000.0
const Towns := preload("res://mods/pax_corpinc3d/src/globe/towns.gd")

var mod: PaxMod
var globe: Object
var cfg: Dictionary = {}
var _placed := false


func setup(m: PaxMod, g: Object, landmarks_cfg: Dictionary) -> void:
	mod = m
	globe = g
	cfg = landmarks_cfg
	name = "PaxCorpInc3DLandmarks"


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_timed(_delta)
	GameApi.perf("corpinc3d.landmarks.process", t0)   # Pax CorpInc3D probe: where the frame goes


func _process_timed(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if not _placed:
		_placed = true
		_place_all()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var alt_km := ((global_transform.affine_inverse() * cam.global_position).length() - 1.0) * EARTH_M / 1000.0
	var show := alt_km < float(cfg.get("show_below_km", 2600.0))
	for c in get_children():
		(c as Node3D).visible = show


func _place_all() -> void:
	var k := float(cfg.get("scale", 30.0))
	var all: Dictionary = cfg.get("landmarks", {})
	for id in all.keys():
		var d: Dictionary = all[id]
		var model: Node3D = mod.model("models/landmarks/%s.glb" % str(id))
		if model == null:
			continue
		var up := Towns._dir(float(d.get("lat", 0.0)), float(d.get("lon", 0.0)))
		var east := Vector3.UP.cross(up)
		if east.length() < 0.001:
			east = Vector3.RIGHT
		east = east.normalized()
		var north := up.cross(east).normalized()
		var yaw := deg_to_rad(float(d.get("yaw", 0.0)))
		var ex := east * cos(yaw) + north * sin(yaw)
		var nx := north * cos(yaw) - east * sin(yaw)
		var s := k / EARTH_M   # a metre of the model in Earth radii, times the scale
		var ground := float(globe.call("ground", up)) if globe != null and globe.has_method("ground") else 1.0
		var holder := Node3D.new()
		holder.name = str(id)
		holder.transform = Transform3D(Basis(ex * s, up * s, -nx * s), up * ground)
		holder.add_child(model)
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(holder)
	mod.log_info("3D landmarks: %d" % get_child_count())
