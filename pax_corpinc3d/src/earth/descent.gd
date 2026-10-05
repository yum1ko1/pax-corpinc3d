extends Node
## Down into the atmosphere. The game's camera stops at 1.25 Earth radii from the centre (≈1600 km up) and always looks
## at the planet's centre. Past that limit the wheel goes on here: «depth» 0..1 brings the camera down to a few dozen
## km over the ground (config earth.json «descent») and lifts the look from straight down to the horizon, as in a
## flight over the land: the 3D ground, the sky, the buildings of the companies. The wheel back — up again; at depth 0
## the game's camera is the game's.
## Down here the view is this mod's own: a drag moves it over the ground at a speed tied to the height (the land
## follows the cursor at 30 km as at 1600 km), the game's camera does not get the drag — nothing turns by itself
## and nothing fights over the camera. A click without a drag goes on to the game as it was. Going back up the
## game's camera is turned to where the flight ended. W A S D (Shift — faster) fly over the ground as well.
## Runs after the game's camera each frame (process_priority) and only on the Earth, with the flat map closed.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")   # Main's methods and the mod's JSON, game 0.24
const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")             # game 0.24's English keys
var mod: PaxMod
var game: PaxGame
var cfg: Dictionary = {}
var depth := 0.0                   # where the camera is now, 0 (the game's limit) .. 1 (lowest)
var target := 0.0                  # where the wheel sent it
var _active := false
var _h := 0.25                     # the camera's height over the ground now, Earth radii (_place)
var _pt := Vector3.ZERO            # the point the view hangs over (the Earth's local space, unit) — this mod's own
var _press: InputEventMouseButton  # the button held over the ground (a drag, or a click handed on to the game)
var _dragged := 0.0                # how far it moved, px (more than DRAG_PX — a drag, not a click)
const DRAG_PX := 4.0
const REPLAY := &"pax_corpinc3d_replay"


func setup(m: PaxMod) -> void:
	mod = m
	var raw: Variant = GameApi.json(m, "config/earth.json", {})
	var all: Dictionary = raw if raw is Dictionary else {}
	cfg = all.get("descent", {})
	name = "PaxCorpInc3DDescent"
	process_priority = 1000
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(g: PaxGame) -> void:
	game = g
	depth = 0.0
	target = 0.0


func _ok() -> bool:
	if game == null or not is_instance_valid(game.main) or not bool(cfg.get("enabled", true)):
		return false
	var main: Object = game.main
	if not (str(main.get("режим")) in ["body", "тело"]) or game.focused_body() != game.home_body():
		return false
	var map: Variant = main.get("полит_карта")
	return not (map is CanvasLayer and (map as CanvasLayer).visible)


## Going out with the wheel the game leaves the Earth for the system's orbits at 22 radii (Main._зум → _в_систему):
## one step too many threw the view off the planet. Here the wheel stops just short of that edge; «edge_clicks»
## (config descent) steps in a row there, within 1.5 s, go on out to the orbits as the game does.
var _edge_n := 0
var _edge_t := -10.0


func _hold_edge(event: InputEvent) -> bool:
	if _active or not (event is InputEventMouseButton):
		return false
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_WHEEL_DOWN or _over_window():
		return false
	var main: Object = game.main
	var r := float(V.pick(game.body(game.home_body()), ["radius", "радиус"], 1.0))
	var edge := r * 22.0
	var k := 1.25 if not Input.is_key_pressed(KEY_SHIFT) else pow(1.25, 4.0)   # the game's step out (Main._зум)
	if float(main.get("цель_дист")) * k < edge * 0.999:
		_edge_n = 0
		return false
	var now := Time.get_ticks_msec() / 1000.0
	_edge_n = _edge_n + 1 if now - _edge_t < 1.5 else 1
	_edge_t = now
	if _edge_n >= int(cfg.get("edge_clicks", 3)):
		_edge_n = 0
		return false   # asked for several times: on to the orbits
	main.set("цель_дист", edge * 0.97)
	get_viewport().set_input_as_handled()
	return true


## The game's camera is at its nearest: the next wheel step goes down here.
func _at_limit() -> bool:
	var main: Object = game.main
	var body: Dictionary = game.body(game.home_body())
	var r := float(V.pick(body, ["radius", "радиус"], 1.0))
	return float(main.get("цель_дист")) <= r * 1.25 * 1.002


func _input(event: InputEvent) -> void:
	if event.has_meta(REPLAY) or not _ok():
		return
	if _hold_edge(event):
		return
	if not _active and _orbit(event):
		return
	if _active and _drag(event):
		return
	if _active and _wasd_key(event):
		get_viewport().set_input_as_handled()   # the game's own keys stay off while flying
		return
	if not (event is InputEventMouseButton) or not (event as InputEventMouseButton).pressed:
		return
	var mb: InputEventMouseButton = event
	if (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN) and _over_window():
		return   # the wheel over a game window scrolls the window (it took the camera up and down)
	# Lower down the wheel moves less: «step» at the game's limit, «step_low» × it near the ground.
	var step := float(cfg.get("step", 0.1)) * lerpf(1.0, float(cfg.get("step_low", 0.25)), smoothstep(0.0, 1.0, target))
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP and (depth > 0.0 or _at_limit()):
		target = clampf(target + step, 0.0, 1.0)
		get_viewport().set_input_as_handled()   # the game would count it towards opening its flat map
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and target > 0.0:
		target = clampf(target - step, 0.0, 1.0)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(delta)
	GameApi.perf("corpinc3d.descent.process", t0)


func _process_body(delta: float) -> void:
	if not _ok():
		if _active:
			_release()
		return
	if target > 0.0 or depth > 0.0 or _at_limit():
		_hold_map()
	depth = move_toward(depth, target, delta * float(cfg.get("speed", 0.9)) * maxf(absf(target - depth), 0.08) * 4.0)
	if _active and target < depth:
		_align_game_camera()   # on the way up the game's camera already hangs over the flight's point: no jump at the top
	if depth <= 0.0005 and target <= 0.0:
		if _active:
			_release()
		return
	_wasd(delta)
	_place(delta)


const WASD := [KEY_W, KEY_A, KEY_S, KEY_D]


## A W/A/S/D key while flying and no text field is being typed in.
func _wasd_key(event: InputEvent) -> bool:
	if not (event is InputEventKey) or not ((event as InputEventKey).keycode in WASD):
		return false
	var focus := get_viewport().gui_get_focus_owner()
	return not (focus is LineEdit or focus is TextEdit)


## W/S — north/south (the way the view looks), A/D — west/east; «wasd_speed» screens of ground a second, Shift × 3.
func _wasd(delta: float) -> void:
	if not _active or _pt == Vector3.ZERO:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var dir := Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if dir == Vector2.ZERO:
		return
	var cam := game.camera()
	if cam == null:
		return
	var view_h := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var px := float(cfg.get("wasd_speed", 0.5)) * view_h * delta * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_pan(-dir.normalized() * px)   # the ground goes the other way, as when pulled by the mouse


## A press, a move or a release of a mouse button over the ground while down here: this mod's drag. True — taken.
func _drag(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if not (mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]):
			return false
		if mb.pressed:
			if get_viewport().gui_get_hovered_control() != null:
				return false   # over a window or a button: theirs
			_press = mb.duplicate()
			_dragged = 0.0
			get_viewport().set_input_as_handled()
			return true
		if _press == null or mb.button_index != _press.button_index:
			return false
		get_viewport().set_input_as_handled()
		var was := _press
		_press = null
		if _dragged <= DRAG_PX:
			_replay(was, mb)   # a click: the game gets it as it was (provinces, companies, buildings)
		return true
	if event is InputEventMouseMotion and _press != null:
		var mm: InputEventMouseMotion = event
		_dragged += mm.relative.length()
		if _dragged > DRAG_PX:
			_pan(mm.relative)
		get_viewport().set_input_as_handled()
		return true
	return false


## The ground follows the cursor: a pixel is the ground's width under the camera over the screen's height.
func _pan(rel: Vector2) -> void:
	var cam := game.camera()
	if cam == null or _pt == Vector3.ZERO:
		return
	var view_h := maxf(get_viewport().get_visible_rect().size.y, 1.0)
	var k := float(cfg.get("drag_speed", 1.0)) * _h * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / view_h
	var pole := Vector3.UP                     # the Earth's local axis (north)
	var east := pole.cross(_pt)
	if east.length() < 1e-4:
		east = Vector3.RIGHT
	east = east.normalized()
	var north := _pt.cross(east).normalized()
	_pt = (_pt - east * rel.x * k + north * rel.y * k).normalized()


## A click handed on to the game: the press and the release again, marked so they pass this mod by.
func _replay(press: InputEventMouseButton, release: InputEventMouseButton) -> void:
	var a: InputEventMouseButton = press.duplicate()
	var b: InputEventMouseButton = release.duplicate()
	a.set_meta(REPLAY, true)
	b.set_meta(REPLAY, true)
	Input.parse_input_event(a)
	Input.parse_input_event(b)


## The game counts wheel steps at its nearest camera («_у_предела», game 0.24 also its camera part's «_at_limit»)
## and opens the flat map when they add up: while the camera goes down here the count stays at zero.
func _hold_map() -> void:
	var main: Object = game.main
	if main.get("_у_предела") != null:
		main.set("_у_предела", 0)
	var nav: Variant = main.get("_camera_navigation")
	if nav is Object and is_instance_valid(nav) and (nav as Object).get("_at_limit") != null:
		(nav as Object).set("_at_limit", 0)


func _place(_delta: float) -> void:
	var cam := game.camera()
	var body := game.body_node(game.home_body())
	if cam == null or body == null:
		return
	var R := body.global_transform.basis.get_scale().x
	var centre := body.global_position
	var basis := body.global_transform.basis.orthonormalized()
	if not _active or _pt == Vector3.ZERO:
		# Going down: the flight starts over the point the game's camera hangs over (it looks at the centre).
		var from := (cam.global_position - centre).normalized()
		if from.length() < 0.5:
			return
		_pt = (basis.inverse() * from).normalized()
	_active = true
	var local_up := _pt
	var up := basis * local_up
	var ground := 1.0
	var earth: Variant = mod.get("earth")
	if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("surface_radius"):
		ground = float((earth as Object).call("surface_radius", local_up))
	# Height over the ground: from the game's limit (0.25 R) down to «lowest» (Earth radii), even in log steps.
	var hi := 0.25
	var lo := float(cfg.get("lowest", 0.13))
	var e := depth * depth * (3.0 - 2.0 * depth)
	var h := exp(lerpf(log(hi), log(lo), e))
	_h = h
	var pos := centre + up * R * (ground + h)
	# The look lifts from straight down to «horizon_pitch» degrees over the vertical, towards the planet's north
	# (or the game camera's own «up» when at a pole).
	var north := (body.global_transform.basis.y.normalized() - up * up.dot(body.global_transform.basis.y.normalized()))
	if north.length() < 0.05:
		north = cam.global_transform.basis.y - up * up.dot(cam.global_transform.basis.y)
	north = north.normalized()
	var pitch := deg_to_rad(float(cfg.get("horizon_pitch", 45.0))) * smoothstep(0.15, 1.0, depth)
	var look := -up * cos(pitch) + north * sin(pitch)
	cam.global_position = pos
	cam.look_at(pos + look, (north * cos(pitch) + up * sin(pitch)).normalized())
	_scale_buildings(e)
	cam.near = maxf(R * h * 0.02, R * 0.00002)
	cam.far = R * 6.0


## The buildings are drawn far larger than life so a city is seen from orbit; coming down they shrink towards
## «buildings_low» of that, on the same log scale as the height (in steps of ~15 % — each step places them anew).
func _scale_buildings(e: float) -> void:
	var globe: Variant = mod.get("globe")
	if not (globe is Object) or not is_instance_valid(globe):
		return
	var lk := lerpf(0.0, log(maxf(float(cfg.get("buildings_low", 0.5)), 0.001)), e)
	var k := 1.0 if e <= 0.0 else exp(snappedf(lk, 0.15))
	if absf(float((globe as Object).get("scale_k")) - k) > 0.001:
		(globe as Object).set("scale_k", k)
		(globe as Object).call("rebuild")


## The game's camera turned to look down at the flight's point (its yaw and pitch round the planet).
func _align_game_camera() -> void:
	var body := game.body_node(game.home_body())
	if body == null or _pt == Vector3.ZERO:
		return
	var n := body.global_transform.basis.orthonormalized() * _pt
	game.main.set("тангаж", clampf(asin(clampf(n.y, -1.0, 1.0)), -PITCH_MAX, PITCH_MAX))
	game.main.set("камера_рыскание", atan2(n.x, n.z))


## Over the Earth in orbit (not flying low here):
##   the right button's drag turns the camera round the planet as the game does, but up to PITCH_MAX (86°) instead
##   of the game's 77° — the poles can be looked at from above;
##   a click on the Earth no longer jumps to a satellite or a moon that happens to be behind it on the screen (the
##   game picks a body near the cursor whatever is in front): the click is then told to the game as a drag.
const PITCH_MAX := 1.5


func _orbit(event: InputEvent) -> bool:
	var main: Object = game.main
	if event is InputEventMouseMotion and ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		if get_viewport().gui_get_hovered_control() != null and _over_window():
			return false
		var rel := (event as InputEventMouseMotion).relative
		main.set("камера_рыскание", float(main.get("камера_рыскание")) - rel.x * 0.006)
		main.set("тангаж", clampf(float(main.get("тангаж")) + rel.y * 0.005, -PITCH_MAX, PITCH_MAX))
		if GameApi.has(main, "_поставить_камеру"):
			GameApi.call_main(main, "_поставить_камеру")
		get_viewport().set_input_as_handled()
		return true
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and not (event as InputEventMouseButton).pressed and float(main.get("протащили")) < 6.0:
		var at := (event as InputEventMouseButton).position
		var hit := _earth_hit(at)
		if hit < 0.0:
			return false
		if GameApi.has(main, "_метка_под_курсором"):
			var mark: Variant = GameApi.call_main(main, "_метка_под_курсором", [at])
			if mark is Dictionary and not (mark as Dictionary).is_empty():
				return false   # a mark on the Earth: the game opens it
		if not GameApi.has(main, "_тело_под_курсором"):
			return false
		var j := int(GameApi.call_main(main, "_тело_под_курсором", [at]))
		var bodies: Variant = main.get("тела")
		if j < 0 or not (bodies is Array) or j >= (bodies as Array).size():
			return false
		var node: Variant = V.pick((bodies as Array)[j], ["узел", "node"])
		var cam := game.camera()
		if node is Node3D and cam != null and cam.global_position.distance_to((node as Node3D).global_position) > hit:
			main.set("протащили", 6.0)   # behind the Earth: not a click for the game
	return false


## The distance from the camera to the Earth under a point of the screen, −1 off the planet.
func _earth_hit(at: Vector2) -> float:
	var cam := game.camera()
	var body := game.body_node(game.home_body())
	if cam == null or body == null:
		return -1.0
	var r := body.global_transform.basis.get_scale().x
	var o := cam.project_ray_origin(at)
	var k := cam.project_ray_normal(at)
	var oc := o - body.global_position
	var b := oc.dot(k)
	var disc := b * b - (oc.dot(oc) - r * r)
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t > 0.0 else -1.0


## Back at the game's own camera, turned to where the flight ended (the same turn Pax Corporations' «show on the
## map» gives the globe: pitch — the point's height over the equator, yaw — its turn round the axis).
func _release() -> void:
	_scale_buildings(0.0)
	_active = false
	depth = 0.0
	target = 0.0
	_press = null
	if game == null or not is_instance_valid(game.main):
		return
	var main: Object = game.main
	var body := game.body_node(game.home_body())
	if body != null and _pt != Vector3.ZERO:
		var n := body.global_transform.basis.orthonormalized() * _pt
		main.set("тангаж", asin(clampf(n.y, -1.0, 1.0)))
		main.set("камера_рыскание", atan2(n.x, n.z))
	_pt = Vector3.ZERO
	if GameApi.has(main, "_поставить_камеру"):
		GameApi.call_main(main, "_поставить_камеру")


## The cursor is over a window or a button, not over the planet (a full-screen catcher of the game lets it through).
func _over_window() -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered == null:
		return false
	var node: Node = hovered
	while node != null:
		if node is BaseButton or node is PanelContainer or node is Panel or node is LineEdit or node is ScrollContainer or node is ItemList or node is RichTextLabel:
			return true
		node = node.get_parent()
	var r := hovered.get_global_rect()
	var view := get_viewport().get_visible_rect().size
	return not (r.size.x >= view.x * 0.9 and r.size.y >= view.y * 0.9)
