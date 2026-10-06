extends RefCounted
## «inc3d check» — what the 3D Earth's parts really are in the running game, one line each: in the scene or not, under
## which parent, shown or hidden, how many copies, where the first copy is against the camera (in its view or not,
## how far). The parts that work (trees, buildings) next to the ones never seen (armies, ships, jets), so the
## difference shows. «inc3d cube» puts bright test blocks (300 km) under the camera point: under the Earth's node and
## under the armies' node — if a block is not seen there, nothing under that node is drawn.
## Written for the player to send one screenshot instead of a hunt in the dark (the test bench is not the game 0.24).

static func report(app: Node) -> String:
	var out: PackedStringArray = []
	var g: PaxGame = app.get("game")
	if g == null:
		return "no world"
	var cam := g.camera()
	var vcam: Camera3D = app.get_viewport().get_camera_3d() if app.is_inside_tree() else null
	out.append("camera: game %s, viewport %s, same %s, cull_mask %d" % [_name(cam), _name(vcam), cam == vcam, cam.cull_mask if cam != null else -1])
	var earth: Variant = app.get("earth")
	var node: Variant = (earth as Object).call("node") if earth is Object and is_instance_valid(earth) else null
	var body := g.body_node(g.home_body())
	out.append("earth node: %s, body node %s, same %s, scale %.3f, layers %d" % [_name(node), _name(body), node == body,
		(node as Node3D).global_transform.basis.get_scale().x if node is Node3D else 0.0,
		(node as VisualInstance3D).layers if node is VisualInstance3D else -1])
	var layers: Variant = app.get("layers")
	if layers is Object and is_instance_valid(layers):
		var l: Object = layers
		out.append("layers: active %s; %s" % [l.get("active"), str(l.call("diag"))])
		for key in ["armies", "ships", "planes", "airports", "roads"]:
			out.append(_part(key, l.get(key), node, cam))
	var forest: Variant = app.get("forest")
	if forest is Object and is_instance_valid(forest):
		out.append(_part("trees", (forest as Object).get("_holder"), node, cam))
	var globe: Variant = app.get("globe")
	if globe is Object and is_instance_valid(globe):
		out.append(_part("buildings", (globe as Object).get("_holder"), node, cam))
	return "\n".join(out)


static func _name(n: Variant) -> String:
	return str((n as Node).get_path()) if n is Node and is_instance_valid(n) and (n as Node).is_inside_tree() else ("not in the scene" if n is Node else "none")


## One part: its node and its first few drawn things (MultiMesh: the first copy).
static func _part(key: String, n: Variant, earth_node: Variant, cam: Camera3D) -> String:
	if n == null or not (n is Node) or not is_instance_valid(n):
		return "%s: none" % key
	var node: Node = n
	var s := "%s: in scene %s, parent is the Earth %s, shown %s" % [key, node.is_inside_tree(), node.get_parent() == earth_node,
		node.is_visible_in_tree() if node is Node3D and node.is_inside_tree() else false]
	var seen := 0
	for c in node.find_children("*", "GeometryInstance3D", true, false):
		if seen >= 3:
			break
		seen += 1
		var gi := c as GeometryInstance3D
		var count := 1
		var p := gi.global_position
		if gi is MultiMeshInstance3D:
			var mm := (gi as MultiMeshInstance3D).multimesh
			count = mm.instance_count if mm != null else 0
			if count > 0:
				p = gi.global_transform * mm.get_instance_transform(0).origin
		var in_view := cam != null and gi.is_inside_tree() and cam.is_position_in_frustum(p)
		var dist := cam.global_position.distance_to(p) if cam != null and gi.is_inside_tree() else -1.0
		s += "\n   %s ×%d shown %s layers %d, first in view %s at %.2f, range %.1f–%.1f, box %s" % [gi.name, count,
			gi.is_visible_in_tree() if gi.is_inside_tree() else false, gi.layers, in_view, dist,
			gi.visibility_range_begin, gi.visibility_range_end, gi.custom_aabb.size]
	if seen == 0:
		s += " — nothing drawn under it"
	return s


## Bright blocks under the point below the camera: one under the Earth's node, one under the armies' node.
static func cubes(app: Node) -> String:
	var g: PaxGame = app.get("game")
	var earth: Variant = app.get("earth")
	var node: Variant = (earth as Object).call("node") if earth is Object and is_instance_valid(earth) else null
	if g == null or not (node is Node3D) or g.camera() == null:
		return "no Earth node or camera"
	var n3: Node3D = node
	var local := (n3.global_transform.affine_inverse() * g.camera().global_position).normalized()
	var out: PackedStringArray = []
	var layers: Variant = app.get("layers")
	var armies: Variant = (layers as Object).get("armies") if layers is Object else null
	var parents := [["Earth", n3, Color(1, 0, 1)], ["armies", armies, Color(0, 1, 1)]]
	var side := Vector3.UP.cross(local).normalized() if absf(local.y) < 0.99 else Vector3.RIGHT
	for i in parents.size():
		var pr: Array = parents[i]
		if not (pr[1] is Node3D) or not is_instance_valid(pr[1]):
			out.append("%s: no node" % pr[0])
			continue
		var cube := MeshInstance3D.new()
		cube.name = "PaxCorpInc3DTestCube"
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * (300.0 / 6371.0)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = pr[2]
		bm.material = m
		cube.mesh = bm
		cube.position = (local + side * (0.05 * float(i * 2 - 1))).normalized() * 1.03
		(pr[1] as Node3D).add_child(cube)
		app.get_tree().create_timer(60.0).timeout.connect(cube.queue_free)
		out.append("%s: a %s block for 60 s, %s" % [pr[0], "magenta" if i == 0 else "cyan", "in the scene" if cube.is_inside_tree() else "NOT in the scene (its parent is not)"])
	return "\n".join(out)
