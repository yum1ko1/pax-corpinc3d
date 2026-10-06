extends CanvasLayer
## The flat map's layers on the 3D Earth, for play from orbit with the flat map closed (or turned off).
## The data is the game's own: the political map (Main.полит_карта) keeps it — roads and rails by province, trade
## routes, air routes, armies, battles, the front, bases, operations, extraction sites, the provinces' indicators, the
## markers and lines — but the game refreshes it only while that map is open; here it is asked to every
## «refresh_s» seconds while the globe is shown.
## The networks (roads, rails, power, communications) are 3D geometry on the ground itself (roads3d.gd, from the game's
## table region_nets); the rest is drawn here over the 3D view, each thing where it is on the globe,
## the planet's far side hidden, the air routes as arcs above the ground. Which of them — the «Слои глобуса»
## switches (layer_switches.gd, Tab over the globe), not the flat map's «Слои» window any more.
## Layer −2: over the 3D view, under the corporations (−1) and the game's interface.

const HIDDEN := Vector2(-100000.0, -100000.0)
const ICONS := ["сеть", "ток", "здоровье", "образование", "безопасность", "коррупция"]
const Roads3D := preload("res://mods/pax_corpinc3d/src/layers/roads3d.gd")
const Armies3D := preload("res://mods/pax_corpinc3d/src/layers/armies3d.gd")
const Ships3D := preload("res://mods/pax_corpinc3d/src/layers/ships3d.gd")
const Planes3D := preload("res://mods/pax_corpinc3d/src/layers/planes3d.gd")
const Airports3D := preload("res://mods/pax_corpinc3d/src/layers/airports3d.gd")
const CountryFocus := preload("res://mods/pax_corpinc3d/src/layers/country_focus.gd")
const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")             # game 0.24's English keys
const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")   # Main's methods, 0.24 names
const LayerSwitches := preload("res://mods/pax_corpinc3d/src/layers/layer_switches.gd")

var mod: PaxMod
var game: PaxGame
var cfg: Dictionary = {}
var active := false
var _canvas: Control
var _since := 999.0
var _since_nets := 999.0
var _units_t := 0.0
var _roads_ground: Variant = null
var _told_diag := false
var _day := -1
var _time := 0.0
var _hover: Dictionary = {}          # {pos, lines: [String]}
var _hits: Array = []                # [{pos, r, lines}]
var _tab_catcher: Node             # TabCatcher: the last child of the root
var focus: CountryFocus               # a second click on the chosen country: the ring, the drop, its regions' map
var ships: Ships3D                    # container ships at sea (a child of the Earth's node while shown)
var planes: Planes3D                  # airliners on the air routes and between big cities (the same)
var airports: Airports3D              # the real airports they take off from and land on (the same)
var armies: Armies3D                  # the armies as 3D soldiers and cars (a child of the Earth's node while shown)
var roads: Roads3D                    # the networks as 3D geometry (a child of the Earth's node while shown)
var labels_on := true                # the cities' names (config/cities.json): switches «labels»
var switches: LayerSwitches          # «Слои глобуса»: every layer on and off (layer_switches.gd)
var _units: Array = []               # the armies as read from the game itself (when its map's list is not refreshed)
var _cities: Array = []              # [{dir, pop, en, ru, cap}] by people, the largest first
var _capitals: Array = []            # the same of the capitals only
var _nets: Texture2D
var _nets_told := false

# The view of this frame.
var _cam: Camera3D
var _centre := Vector3.ZERO
var _basis := Basis.IDENTITY
var _r := 1.0
var _eye := Vector3.ZERO
var _px_per_rad := 1.0


func setup(m: PaxMod) -> void:
	mod = m
	var raw: Variant = GameApi.json(m, "config/earth.json", {})
	var all: Dictionary = raw if raw is Dictionary else {}
	cfg = all.get("layers", {})
	name = "PaxCorpInc3DLayers"
	layer = -2
	process_priority = 1001        # after the game's camera and the descent
	visible = false
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_all)
	add_child(_canvas)
	focus = CountryFocus.new()
	focus.setup(m)
	add_child(focus)
	switches = LayerSwitches.new()
	switches.setup(m)
	add_child(switches)
	labels_on = bool(m.get_setting("city_labels", true))
	var cdata: Variant = GameApi.json(m, "config/cities.json", {})
	for row in ((cdata as Dictionary).get("cities", []) if cdata is Dictionary else []):
		var r: Array = row
		if r.size() < 7:
			continue
		var lat := deg_to_rad(float(r[0]))
		var lon := deg_to_rad(float(r[1]))
		var c := {"dir": Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)), "pop": int(r[2]), "en": str(r[4]),
			"ru": str(r[5]), "cap": int(r[6]) == 1}
		_cities.append(c)
		if bool(c["cap"]):
			_capitals.append(c)
	var all_roads: Dictionary = all.get("roads", {})
	if bool(all_roads.get("enabled", true)):
		roads = Roads3D.new()
		roads.setup(m, all_roads, m.shader("shaders/roads.gdshader"), m.shader("shaders/blink.gdshader"))
	var all_armies: Dictionary = all.get("armies", {})
	if bool(all_armies.get("enabled", true)):
		armies = Armies3D.new()
		armies.setup(m, all_armies)
	var all_ships: Dictionary = all.get("ships", {})
	if bool(all_ships.get("enabled", true)):
		ships = Ships3D.new()
		ships.setup(m, all_ships)
	var all_air: Dictionary = all.get("airports", {})
	if bool(all_air.get("enabled", true)):
		airports = Airports3D.new()
		airports.setup(m, all_air)
	var all_planes: Dictionary = all.get("planes", {})
	if bool(all_planes.get("enabled", true)) and airports != null:
		planes = Planes3D.new()
		planes.setup(m, all_planes, airports)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for n in [roads, armies, ships, planes, airports]:
			if n != null and is_instance_valid(n) and (n as Node).get_parent() == null:
				(n as Node).free()


func start(g: PaxGame) -> void:
	game = g
	focus.start(g)
	if roads != null:
		var earth: Variant = mod.get("earth")
		roads.start(g, Callable(earth, "surface_radius") if earth is Object and is_instance_valid(earth) else Callable())
	_since = 999.0
	_since_nets = 999.0


func _map() -> CanvasLayer:
	if game == null or not is_instance_valid(game.main):
		return null
	var raw: Variant = game.main.get("полит_карта")
	return raw if raw is CanvasLayer else null


func _wanted() -> bool:
	if game == null or not is_instance_valid(game.main) or not bool(cfg.get("enabled", true)):
		return false
	if not (str(game.main.get("режим")) in ["body", "тело"]) or game.focused_body() != game.home_body():
		return false
	var map := _map()
	if map == null or map.visible:
		return false
	return game.camera() != null and game.body_node(game.home_body()) != null


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(delta)
	GameApi.perf("corpinc3d.globe_layers.process", t0)


func _process_body(delta: float) -> void:
	var on := _wanted()
	if on != active:
		active = on
		visible = on
		if not on:
			switches.hide_window()
		_since_nets = 999.0
	_place_roads(on)
	if not on:
		return
	_keep_catcher()
	_time += delta
	if not _told_diag and _time > 30.0:
		_told_diag = true
		mod.log_info("3D layers: " + diag())
	_measure()
	_refresh(delta)
	labels_on = switches.is_on("labels")
	if armies != null:
		armies.visible = switches.is_on("armies3d")
		armies.set_units(units())
	if ships != null:
		ships.visible = switches.is_on("ships")
		ships.set_caravans(_list("caravans"), func(c: Dictionary) -> bool: return V.is_kind(str(V.field(c, "вид", "")), "корабль"))
	if airports != null:
		airports.visible = switches.is_on("airports")
	if planes != null:
		planes.visible = switches.is_on("flights")
		planes.set_routes(_air_routes())
	_canvas.queue_redraw()


# ---------- the game's data ----------

func _refresh(delta: float) -> void:
	var main: Object = game.main
	var map := _map()
	_since += delta
	_since_nets += delta
	var day := game.day()
	if (_since >= float(cfg.get("refresh_s", 2.0)) or day != _day) and _refresher().is_valid():
		_since = 0.0
		_day = day
		_refresher().call()   # armies, battles, front, bases, operations, routes, sites, the economy's indicators
	_units_t -= delta
	if _units_t <= 0.0:
		_units_t = float(cfg.get("refresh_s", 2.0))
		# The armies straight from the game as well: in 0.24 the map's refresh is renamed (or fills nothing while the
		# flat map is closed) — the 3D armies must not wait for the flat map to be opened.
		if _list("units").is_empty():
			_units = _read_units()
	if _since_nets >= float(cfg.get("nets_s", 4.0)):
		_since_nets = 0.0
		if _nets_refresher().is_valid():
			_nets_refresher().call()
		var mat: Variant = V.prop(map, V.MAP["material"])
		var nets: Variant = (mat as ShaderMaterial).get_shader_parameter("region_nets") if mat is ShaderMaterial else null
		if not (nets is Texture2D):
			# Game 0.24: the table straight from the game — the provinces' book draws it from the provinces' networks.
			var book: Variant = map.get("пров")
			if book is Object and is_instance_valid(book) and GameApi.has(main, "_сети_провинций"):
				var nw: Variant = GameApi.call_main(main, "_сети_провинций")
				if nw is Dictionary:
					nets = V.call_any(book as Object, ["networks_texture", "текстура_сетей"], [nw])
		_nets = nets if nets is Texture2D else null
		if not _nets_told:
			_nets_told = true
			mod.log_info("3D roads: networks table %s" % ("%dx%d" % [_nets.get_width(), _nets.get_height()] if _nets != null else "none"))
	if roads != null:
		roads.set_data(_nets, switches.nets_mask())   # our switches, not the flat map's «Слои» (gone or renamed in 0.24)


## The 3D networks live in the Earth's node (its rotation, its radius 1) while the globe is shown.
func _place_roads(on: bool) -> void:
	if roads == null and armies == null and ships == null and planes == null and airports == null:
		return
	var earth: Variant = mod.get("earth")
	var node: Variant = (earth as Object).call("node") if earth is Object and is_instance_valid(earth) and (earth as Object).has_method("node") else null
	var parent: Node = node if on and node is Node3D else null
	if parent == null:
		for n in [roads, armies, ships, planes, airports]:
			if n != null and (n as Node).get_parent() != null:
				(n as Node).get_parent().remove_child(n)
		return
	if roads != null and roads.get_parent() != parent:
		if roads.get_parent() != null:
			roads.get_parent().remove_child(roads)
		parent.add_child(roads)
		roads.set_ground((earth as Object).call("height_texture") as Texture2D, float((earth as Object).call("height_exag")))
	if roads != null:
		roads.set_sun((earth as Object).call("sun_dir") as Vector3)
		# The height map comes later now (read on a worker thread): the roads are laid on it when it is there.
		var ht: Variant = (earth as Object).call("height_texture")
		if ht != _roads_ground:
			_roads_ground = ht
			roads.set_ground(ht as Texture2D, float((earth as Object).call("height_exag")))
	for n in [armies, ships, planes, airports]:
		if n != null and (n as Node).get_parent() != parent:
			if (n as Node).get_parent() != null:
				(n as Node).get_parent().remove_child(n)
			parent.add_child(n)


## The armies to show: the map's list where the game still fills it, else read from the game's armies (0.24).
func units() -> Array:
	var from_map := _list("units")
	return from_map if not from_map.is_empty() else _units


## The air routes for the 3D jets: the caravans of the kind «самолёт» (first and last point) and the flights.
func _air_routes() -> Array:
	var out: Array = []
	for k in _list("caravans"):
		if k is Dictionary and V.is_kind(str(V.field(k, "вид", "")), "самолёт"):
			var pts: Variant = V.field(k, "точки", [])
			if pts is Array and (pts as Array).size() >= 2:
				out.append([(pts as Array)[0], (pts as Array)[(pts as Array).size() - 1]])
	for f in _list("flights"):
		if f is Dictionary and V.field(f, "а") is Vector2 and V.field(f, "б") is Vector2:
			out.append([V.field(f, "а"), V.field(f, "б")])
	return out


## The game's refresh of the flat map's data (armies, battles, routes, extraction sites, the economy's indicators —
## the game does it only while that map is open): Main._армии_на_карту on an older game, found under its new name in
## 0.24 (GameApi.discover, told to the journal once).
var _refresh_cb := Callable()
var _refresh_looked := false
var _nets_cb := Callable()
var _nets_looked := false


func _refresher() -> Callable:
	if _refresh_looked:
		return _refresh_cb
	if game == null or not is_instance_valid(game.main):
		return Callable()
	_refresh_looked = true
	var main: Object = game.main
	if GameApi.has(main, "_армии_на_карту"):
		_refresh_cb = func() -> void: GameApi.call_main(main, "_армии_на_карту")
		mod.log_info("3D layers: the map's data refreshed by Main._армии_на_карту")
		return _refresh_cb
	var why: Array = []
	_refresh_cb = GameApi.discover(main, ["армии_на_карту", "units_to_map", "armies_to_map", "refresh_map_units", "update_map_units"],
		["army_map_view", "map_view", "political_map_view", "map_layers", "map_data"], why)
	mod.log_info("3D layers: the map's data refresh — %s" % ", ".join(why))
	return _refresh_cb


func _nets_refresher() -> Callable:
	if _nets_looked:
		return _nets_cb
	if game == null or not is_instance_valid(game.main):
		return Callable()
	_nets_looked = true
	var main: Object = game.main
	if GameApi.has(main, "_обновить_сети_карты"):
		_nets_cb = func() -> void: GameApi.call_main(main, "_обновить_сети_карты")
		return _nets_cb
	var why: Array = []
	_nets_cb = GameApi.discover(main, ["обновить_сети", "сети_карты", "map_nets", "networks_to_map", "refresh_nets", "update_nets"],
		["army_map_view", "map_view", "political_map_view", "map_layers", "networks"], why)
	mod.log_info("3D layers: the networks' refresh — %s" % ", ".join(why))
	return _nets_cb


## The armies straight from the game (Main.армии / armies → its units), as the flat map lists them: {uv, цвет, наш,
## люди, имя, подпись, цель_uv}. Seen: ours, our allies and those at war with us (as the game shows them).
func _read_units() -> Array:
	var out: Array = []
	if game == null or not is_instance_valid(game.main):
		return out
	var list: Variant = _units_list()
	if not (list is Array):
		return out
	var colours := {}
	var me := game.country()
	for f in game.factions():
		if f is Dictionary:
			colours[str(V.field(f, "имя", ""))] = V.field(f, "цвет", Color.GRAY)
	var home := game.home_body()
	for o in list:
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var pid := int(V.pick(d, ["province", "провинция"], 0))
		if pid <= 0:
			continue
		var whose := str(V.pick(d, ["whose", "owner", "чей"], ""))
		var ours := bool(V.pick(d, ["ours", "own", "наш"], whose == me))
		if not ours and not game.at_war(whose) and game.relation(whose) < 0.75:
			continue
		var n := game.province_direction(home, pid)
		if n.length() < 1e-6:
			continue
		n = n.normalized()
		var uv := Vector2(atan2(n.x, n.z) / TAU + 0.5, acos(clampf(n.y, -1.0, 1.0)) / PI)
		var target: Variant = null
		var path: Variant = V.pick(d, ["path", "путь"], [])
		if ours and path is Array and not (path as Array).is_empty():
			var t := game.province_direction(home, int((path as Array)[-1]))
			if t.length() > 1e-6:
				t = t.normalized()
				target = Vector2(atan2(t.x, t.z) / TAU + 0.5, acos(clampf(t.y, -1.0, 1.0)) / PI)
		var col: Variant = colours.get(whose, Color.GRAY)
		out.append({"uv": uv, "цвет": col if col is Color else Color.GRAY, "наш": ours,
			"люди": float(V.pick(d, ["humans", "people", "люди"], 0.0)), "имя": str(V.pick(d, ["name", "имя"], "")),
			"подпись": whose, "цель_uv": target, "в_бою": false})
	return out


## The game's own list of armies: Main.армии.отряды on an older game; in 0.24 the names may be English — the known
## ones first, then any Array of the armies' host whose entries look like units (a province and people or an owner).
var _units_prop := ""


func _units_list() -> Variant:
	var host: Variant = V.prop(game.main, ["армии", "armies", "army", "military"])
	if not (host is Object) or not is_instance_valid(host):
		return null
	var h: Object = host
	if not _units_prop.is_empty():
		return h.get(_units_prop)
	for n in ["отряды", "units", "detachments", "squads", "troops", "forces"]:
		if h.get(n) is Array:
			_units_prop = n
			return h.get(n)
	for p in h.get_property_list():
		var v: Variant = h.get(str(p["name"]))
		if v is Array and not (v as Array).is_empty() and (v as Array)[0] is Dictionary:
			var d: Dictionary = (v as Array)[0]
			if (d.has("province") or d.has("провинция")) and (d.has("humans") or d.has("люди") or d.has("whose") or d.has("чей")):
				_units_prop = str(p["name"])
				mod.log_info("3D armies: the game's units are Main.армии.%s" % _units_prop)
				return v
	return null


## For the console (inc3d layers) and the journal: what the layers read and what the 3D parts hold.
func diag() -> String:
	var parts: Array = []
	parts.append("active %s, map %s" % [active, _map() != null])
	for k in ["units", "caravans", "flights", "bases", "indicators", "mines", "battles"]:
		parts.append("%s %d" % [k, _list(k).size()])
	var own: Variant = _units_list() if game != null else null
	parts.append("game units %s (%s), shown %d" % [str((own as Array).size()) if own is Array else "—", _units_prop, units().size()])
	parts.append("refresh %s" % ("found" if _refresher().is_valid() else "none"))
	for pair in [["armies3d", armies], ["ships3d", ships], ["planes3d", planes]]:
		var n: Variant = pair[1]
		var where := "—"
		if n != null and is_instance_valid(n):
			var cnt := 0
			for c in (n as Node).get_children():
				if c is MultiMeshInstance3D and (c as MultiMeshInstance3D).multimesh != null:
					cnt += (c as MultiMeshInstance3D).multimesh.instance_count
			where = "%d in %s" % [cnt, "the Earth" if (n as Node).is_inside_tree() else "nowhere"]
		parts.append("%s %s" % [pair[0], where])
	parts.append("nets table %s" % ("yes" if _nets != null else "no"))
	return ", ".join(parts)


func _list(key: String) -> Array:
	var raw: Variant = V.prop(_map(), V.MAP[key])
	return raw if raw is Array else []


## Tab over the globe: the «Слои» window opens and closes here. The game catches Tab in Main._input and opens the flat
## map; _input goes to the scene tree's nodes from the last one up, and the mods' nodes stand before the game's scene —
## so a small catcher is kept the root's last child (TabCatcher) and hears Tab first.
class TabCatcher extends Node:
	var layers: Object

	func _input(event: InputEvent) -> void:
		if is_instance_valid(layers):
			layers.call("_tab", event)


func _keep_catcher() -> void:
	var root := get_tree().root if is_inside_tree() else null
	if root == null:
		return
	if not is_instance_valid(_tab_catcher):
		var c := TabCatcher.new()
		c.name = "PaxCorpInc3DTab"
		c.layers = self
		_tab_catcher = c
	if _tab_catcher.get_parent() != root:
		root.add_child.call_deferred(_tab_catcher)
	elif _tab_catcher.get_index() != root.get_child_count() - 1:
		root.move_child(_tab_catcher, -1)


func _exit_tree() -> void:
	if is_instance_valid(_tab_catcher):
		_tab_catcher.queue_free()

func _tab(event: InputEvent) -> bool:
	if not active or not (event is InputEventKey):
		return false
	var k: InputEventKey = event
	if not (k.pressed and not k.echo and k.keycode == KEY_TAB):
		return false
	switches.toggle_window()   # «Слои глобуса»: every layer of the globe, ours and the game's
	get_viewport().set_input_as_handled()
	return true


func _input(event: InputEvent) -> void:
	if _tab(event):
		return
	if active and event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_click(event as InputEventMouseButton)
	if active and event is InputEventMouseMotion:
		_hover = {}
		var at := (event as InputEventMouseMotion).position
		var best := INF
		for h in _hits:
			var d := at.distance_to(h["pos"] as Vector2)
			if d <= float(h["r"]) and d < best:
				best = d
				_hover = h
		if _hover.is_empty() and _on_planet_ui(at):
			_hover = _company_hover(at)


## Over a company's 3D building: its bubble (Pax Corporations company_brief: name, country and industry, value and
## the week's change, status, «click — the dossier»). The lines kept per company for a few seconds.
var _briefs: Dictionary = {}         # company id -> [lines, time]


func _company_hover(at: Vector2) -> Dictionary:
	var globe: Variant = mod.get("globe")
	if _cam == null or not (globe is Object) or not is_instance_valid(globe) or not (globe as Object).has_method("company_at"):
		return {}
	var cid := str((globe as Object).call("company_at", _cam, at))
	if cid.is_empty():
		return {}
	var now := Time.get_ticks_msec()
	var kept: Variant = _briefs.get(cid)
	if not (kept is Array) or now - int((kept as Array)[1]) > 3000:
		var api: Variant = Engine.get_meta("pax_corporations_api") if Engine.has_meta("pax_corporations_api") else null
		var lines: Variant = (api as Object).call("company_brief", cid) if api is Object and is_instance_valid(api) and (api as Object).has_method("company_brief") else []
		kept = [lines if lines is Array else [], now]
		_briefs[cid] = kept
	var ls: Array = (kept as Array)[0]
	return {} if ls.is_empty() else {"pos": at, "r": 0.0, "lines": ls, "bubble": true}


## A click on the planet (not on a window, not a drag): the country under it is selected (earth.gd select_country,
## its own light in the shader); a click on the sea, on no one's land or on the same country again clears it. The
## click goes on to the game as before.
var _press_at := Vector2(-1, -1)


func _click(e: InputEventMouseButton) -> void:
	if e.pressed:
		_press_at = e.position if _on_planet_ui(e.position) else Vector2(-1, -1)
		return
	if _press_at.x < 0.0 or e.position.distance_to(_press_at) > 4.0:
		return
	_press_at = Vector2(-1, -1)
	# A company's building: its dossier (Pax Corporations), the country stays as it was.
	var globe: Variant = mod.get("globe")
	if globe is Object and is_instance_valid(globe) and (globe as Object).has_method("company_at"):
		var cid := str((globe as Object).call("company_at", _cam, e.position))
		var api: Variant = Engine.get_meta("pax_corporations_api") if Engine.has_meta("pax_corporations_api") else null
		if not cid.is_empty() and api is Object and is_instance_valid(api) and (api as Object).has_method("open_company_3d"):
			(api as Object).call("open_company_3d", cid)
			return
	var earth: Variant = mod.get("earth")
	if not (earth is Object) or not is_instance_valid(earth) or not (earth as Object).has_method("select_country"):
		return
	var d := _local_at(e.position)
	var owner_name := ""
	if d != Vector3.ZERO:
		var book: Variant = V.prop(game.main, ["пров", "provinces"])
		if not (book is Object):
			book = V.prop(_map(), V.MAP["provinces"])
		if book is Object and is_instance_valid(book):
			var id := int(V.call_any(book as Object, ["id_в", "id_at", "id_of"], [d, 0]))
			if id > 0:
				owner_name = game.province_owner(game.home_body(), id)   # the mods' API; then the book's own names
				if owner_name.is_empty():
					owner_name = str(V.call_any(book as Object, ["чья", "owner_of", "owner", "whose"], [id]))
				if owner_name == "<null>":
					owner_name = ""
	if not owner_name.is_empty() and owner_name == str((earth as Object).get("selected")):
		_play_focus(owner_name, earth as Object)   # a second click: the ring, the drop and the country's regions
		return
	if owner_name == str((earth as Object).get("selected")):
		owner_name = ""
	(earth as Object).call("select_country", owner_name)
	# Its card with the statistics (Pax Corporations, in the country's world step's look); "" closes it.
	var capi: Variant = Engine.get_meta("pax_corporations_api") if Engine.has_meta("pax_corporations_api") else null
	if capi is Object and is_instance_valid(capi) and (capi as Object).has_method("open_country_card"):
		(capi as Object).call("open_country_card", owner_name)


## The country on the screen: the middle and the reach of its provinces in view; the focus plays there.
func _play_focus(country: String, earth: Object) -> void:
	var body := game.home_body()
	var pts: Array = []
	var mid := Vector3.ZERO
	for id in game.provinces_of(body, country):
		var d := game.province_direction(body, int(id)).normalized()
		mid += d
		var s := _at(d)
		if s != HIDDEN:
			pts.append(s)
	if pts.is_empty():
		return
	var c := Vector2.ZERO
	for p in pts:
		c += p as Vector2
	c /= float(pts.size())
	var r := 0.0
	for p in pts:
		r = maxf(r, c.distance_to(p as Vector2))
	var col: Variant = earth.call("_faction_color", country)
	# The screen middle's offset from the country's own middle, kept while it plays (the anchor follows the globe).
	var at_mid := _at(mid.normalized()) if mid.length() > 1e-4 else HIDDEN
	var off := c - at_mid if at_mid != HIDDEN else Vector2.ZERO
	var dir := mid.normalized()
	var anchor := func() -> Vector2:
		var p := _at(dir)
		return p + off if p != HIDDEN else HIDDEN
	focus.play(country, col if col is Color else Color(0.6, 0.8, 1.0), c, r * 1.15 + 30.0, anchor if at_mid != HIDDEN else Callable())


## The cursor is over the planet, not over a window or a button (a full-screen catcher of the game lets it through).
func _on_planet_ui(at: Vector2) -> bool:
	var hovered := get_viewport().gui_get_hovered_control()
	if hovered == null:
		return true
	var node: Node = hovered
	while node != null:
		if node is BaseButton or node is PanelContainer or node is LineEdit or node is ScrollContainer:
			return false
		node = node.get_parent()
	var r := hovered.get_global_rect()
	var view := get_viewport().get_visible_rect().size
	return r.size.x >= view.x * 0.9 and r.size.y >= view.y * 0.9


## The Earth's own direction (radius 1) under a point of the screen, ZERO off the planet.
func _local_at(at: Vector2) -> Vector3:
	if _cam == null:
		return Vector3.ZERO
	var o := _cam.project_ray_origin(at)
	var k := _cam.project_ray_normal(at)
	var oc := o - _centre
	var b := oc.dot(k)
	var c := oc.dot(oc) - _r * _r
	var disc := b * b - c
	if disc < 0.0:
		return Vector3.ZERO
	var t := -b - sqrt(disc)
	if t < 0.0:
		return Vector3.ZERO
	return (_basis.inverse() * ((o + k * t - _centre) / _r)).normalized()


# ---------- the globe's projection ----------

func _measure() -> void:
	_cam = game.camera()
	var xf := game.body_node(game.home_body()).global_transform
	_centre = xf.origin
	_r = xf.basis.get_scale().x
	_basis = xf.basis.orthonormalized()
	_eye = _cam.global_position
	var view := get_viewport().get_visible_rect().size
	var f := view.y * 0.5 / tan(deg_to_rad(_cam.fov) * 0.5)
	_px_per_rad = _r * f / maxf(_eye.distance_to(_centre) - _r, _r * 0.001)


static func _dir(uv: Vector2) -> Vector3:
	var lon := (uv.x - 0.5) * TAU
	var lat := PI * 0.5 - uv.y * PI
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


## A direction of the Earth (its own space) at a height (Earth radii) on the screen; HIDDEN behind the planet.
func _at(d: Vector3, lift: float = 0.0) -> Vector2:
	var n := _basis * d
	var p := _centre + n * _r * (1.0 + lift)
	if _cam.is_position_behind(p):
		return HIDDEN
	# Hidden by the planet: the ray from the eye meets the sphere before the point.
	var to := p - _eye
	var dist := to.length()
	var k := to / dist
	var oc := _eye - _centre
	var b := oc.dot(k)
	var c := oc.dot(oc) - _r * _r * 0.999
	var disc := b * b - c
	if disc > 0.0 and -b - sqrt(disc) < dist - _r * 0.002:
		return HIDDEN
	return _cam.unproject_position(p)


func _uv(uv: Vector2) -> Vector2:
	return _at(_dir(uv))


static func _hidden(s: Vector2) -> bool:
	return s.x < -50000.0


func _on_screen(s: Vector2, margin: float = 40.0) -> bool:
	return not _hidden(s) and Rect2(Vector2(-margin, -margin), _canvas.size + Vector2(margin, margin) * 2.0).has_point(s)


## Points along the great circle a → b (and up to «lift» Earth radii above the ground in the middle, for flights).
func _arc(a: Vector2, b: Vector2, lift: float = 0.0) -> PackedVector2Array:
	var da := _dir(a)
	var db := _dir(b)
	var ang := da.angle_to(db)
	var steps := clampi(int(ang / deg_to_rad(1.0)), 2, 90)
	var out := PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		var d := da.slerp(db, t) if ang > 1e-5 else da
		out.append(_at(d, lift * sin(PI * t) * clampf(ang * 2.0, 0.05, 1.0)))
	return out


## A polyline with the hidden parts left out; dashed when «dash» > 0 (px).
func _polyline(pts: PackedVector2Array, col: Color, w: float, dash: float = 0.0) -> void:
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		if _hidden(a) or _hidden(b) or not (_on_screen(a, 200.0) or _on_screen(b, 200.0)):
			continue
		if dash > 0.0:
			_canvas.draw_dashed_line(a, b, col, w, dash, true)
		else:
			_canvas.draw_line(a, b, col, w, true)


## The point at a share of a polyline, HIDDEN if that part is hidden.
static func _along(pts: PackedVector2Array, t: float) -> Vector2:
	if pts.size() < 2:
		return HIDDEN
	var f := clampf(t, 0.0, 1.0) * float(pts.size() - 1)
	var i := mini(int(f), pts.size() - 2)
	if _hidden(pts[i]) or _hidden(pts[i + 1]):
		return HIDDEN
	return pts[i].lerp(pts[i + 1], f - float(i))


# ---------- drawing ----------

func _draw_all() -> void:
	var t0 := Time.get_ticks_usec()
	_draw_all_body()
	GameApi.perf("corpinc3d.globe_layers.draw_all", t0)


func _draw_all_body() -> void:
	_hits.clear()
	if not active or _cam == null:
		return
	var zoom := TAU * _px_per_rad / maxf(_canvas.size.x, 1.0)   # the flat map's «зум»: the world's width in screens
	# Every layer by the «Слои глобуса» switches (layer_switches.gd).
	if switches.is_on("trade"):
		_draw_trade()
	if switches.is_on("flights"):
		_draw_flights()
	if switches.is_on("marks"):
		_draw_lines()
	# The front and the armies' operations: their segments between the provinces' centres read as red zigzags over
	# the land — off by default, close in only.
	if switches.is_on("front") and zoom >= float(cfg.get("front_from_zoom", 4.0)):
		_draw_front()
		_draw_operations()
	if switches.is_on("sites") and zoom >= float(cfg.get("sites_from_zoom", 2.5)):
		_draw_sites()
	var icons: Array = switches.icon_names()
	if not icons.is_empty() and zoom >= float(cfg.get("icons_from_zoom", 3.0)):
		_draw_indicators(icons)
	if labels_on:
		_draw_labels(zoom)
	if switches.is_on("airports"):
		_draw_airports(zoom)
	if switches.is_on("bases"):
		_draw_bases()
	if switches.is_on("battles"):
		_draw_battles()
	if switches.is_on("armies"):
		_draw_armies()
	if switches.is_on("marks"):
		_draw_marks()
	_draw_tip()


## The trade routes as dashed lines on the ground (air routes as white arcs above it). What runs along them is 3D now:
## ships (ships3d.gd), jets (planes3d.gd), trucks in the roads' traffic — the moving dots of the 2D overlay are gone.
func _draw_trade() -> void:
	for k in _list("caravans"):
		if not (k is Dictionary):
			continue
		var c: Dictionary = k
		var pts: Array = V.field(c, "точки", [])
		if pts.size() < 2:
			continue
		var kind := str(V.field(c, "вид", ""))
		var air := V.is_kind(kind, "самолёт")
		if air and planes != null:
			continue   # drawn with the flights: along the jets' own way, airport to airport
		# Air routes white, not in the carrier country's colour (coloured arcs read as borders and fronts).
		var col: Color = Color.WHITE if air else V.field(c, "цвет", Color.WHITE)
		var path := PackedVector2Array()
		if air:
			path = _arc(pts[0], pts[pts.size() - 1], _air_lift())
		else:
			for i in range(1, pts.size()):
				var seg := _arc(pts[i - 1], pts[i])
				if i > 1:
					seg.remove_at(0)
				path.append_array(seg)
		_polyline(path, Color(col, 0.45 if air else 0.5), 1.4, 7.0)


func _draw_flights() -> void:
	if planes != null:
		# The jets' own ways (planes3d.gd): from the runway of one real airport to the runway of another.
		for line in planes.route_lines():
			var dirs: PackedVector3Array = (line as Array)[0]
			var hs: PackedFloat32Array = (line as Array)[1]
			var pts := PackedVector2Array()
			for i in dirs.size():
				pts.append(_at(dirs[i], hs[i]))
			_polyline(pts, Color(1, 1, 1, 0.4), 1.2, 6.0)
		return
	for f in _list("flights"):
		if not (f is Dictionary):
			continue
		var d: Dictionary = f
		if not (V.field(d, "а") is Vector2 and V.field(d, "б") is Vector2):
			continue
		_polyline(_arc(V.field(d, "а"), V.field(d, "б"), _air_lift()), Color(1, 1, 1, 0.3), 1.0, 6.0)


## The airports' codes (IATA) with a plane sign, close in: the large ones first, no label over another.
func _draw_airports(zoom: float) -> void:
	if airports == null or zoom < float(cfg.get("airports_from_zoom", 7.0)):
		return
	var font := _canvas.get_theme_default_font()
	var placed: Array = []
	var shown := 0
	for pass_i in 2:
		for a in airports.list:
			if bool((a as Dictionary)["large"]) != (pass_i == 0):
				continue
			if shown >= 70:
				return
			var s := _at((a as Dictionary)["d"] as Vector3, float((a as Dictionary)["ground"]) - 1.0)
			if not _on_screen(s, 0.0):
				continue
			var label := "✈ " + str((a as Dictionary)["iata"])
			var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			var rect := Rect2(s + Vector2(-tw * 0.5, 8), Vector2(tw, 14)).grow(2.0)
			var free := true
			for r in placed:
				if (r as Rect2).intersects(rect):
					free = false
					break
			if not free:
				continue
			placed.append(rect)
			shown += 1
			_canvas.draw_string_outline(font, rect.position + Vector2(2, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.8))
			_canvas.draw_string(font, rect.position + Vector2(2, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.75, 0.9, 1.0))
			_hits.append({"pos": rect.get_center(), "r": tw * 0.5 + 4.0, "lines": [str((a as Dictionary)["name"]), str((a as Dictionary)["city"])]})


## The air routes' arc height — the same the 3D jets fly at (config «planes» lift).
func _air_lift() -> float:
	return float(planes.cfg.get("lift", 0.03)) if planes != null else 0.03


func _draw_lines() -> void:
	for l in _list("lines"):
		if l is Dictionary and V.field((l as Dictionary), "а") is Vector2 and V.field((l as Dictionary), "б") is Vector2:
			var d: Dictionary = l
			_polyline(_arc(V.field(d, "а"), V.field(d, "б")), Color(V.field(d, "цвет", Color.WHITE)), 2.0)


func _draw_front() -> void:
	var earth: Variant = mod.get("earth")
	if earth is Object and is_instance_valid(earth) and bool((earth as Object).get("front_on")):
		return   # the ground's shader draws it along the borders (earth.gd _update_front)
	for pair in _list("front"):
		if pair is Array and (pair as Array).size() >= 2:
			_polyline(_arc((pair as Array)[0], (pair as Array)[1]), Color(0.95, 0.3, 0.25, 0.45), 1.5)


func _draw_operations() -> void:
	for o in _list("operations"):
		if not (o is Dictionary):
			continue
		var d: Dictionary = o
		var pts: Array = V.field(d, "точки", [])
		var col: Color = V.field(d, "цвет", Color.WHITE)
		var path := PackedVector2Array()
		for i in range(1, pts.size()):
			path.append_array(_arc(pts[i - 1], pts[i]))
		_polyline(path, Color(col.lightened(0.3), 0.7), 2.0)
		if path.size() >= 2:
			var tip := path[path.size() - 1]
			var back := path[maxi(path.size() - 4, 0)]
			if _on_screen(tip) and not _hidden(back) and tip.distance_to(back) > 1.0:
				var dir := (tip - back).normalized()
				var side := Vector2(-dir.y, dir.x)
				_canvas.draw_colored_polygon(PackedVector2Array([tip + dir * 6.0, tip - dir * 8.0 + side * 7.0, tip - dir * 8.0 - side * 7.0]), Color(col.lightened(0.3), 0.95))


func _draw_sites() -> void:
	for p in _list("mines"):
		if not (p is Dictionary) or not ((p as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = p
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		var ours := bool(V.field(d, "наш", false))
		var col := _site_color(str(V.field(d, "вид", "")))
		_canvas.draw_rect(Rect2(s - Vector2(5, 5), Vector2(10, 10)), Color(0, 0, 0, 0.6))
		_canvas.draw_rect(Rect2(s - Vector2(4, 4), Vector2(8, 8)), col if ours else Color(col, 0.5))
		_hits.append({"pos": s, "r": 8.0, "lines": [str(V.field(d, "имя", "")), str(V.field(d, "подпись", ""))]})


static func _site_color(kind: String) -> Color:
	match kind:
		"нефть", "газ":
			return Color(0.25, 0.25, 0.28)
		"уголь":
			return Color(0.45, 0.4, 0.35)
		"уран":
			return Color(0.45, 0.95, 0.35)
		"золото":
			return Color(1.0, 0.82, 0.25)
		"железо", "металлы":
			return Color(0.75, 0.45, 0.35)
		"вода":
			return Color(0.4, 0.7, 1.0)
	return Color(0.8, 0.8, 0.85)


## The provinces' indicators as the game's flat map shows them — an icon each (a cross for health, a cap for
## education, a shield for safety, scales for honest power, a mast for communications, a bolt for the power grid) on
## a disc of its grade's colour (red → yellow → green) with the grade's arc around; no data — a grey disc. Hover: what
## it is and the value. Plain coloured dots were not understood.
const IND_ICONS := {"здоровье": "health", "образование": "education", "безопасность": "safety", "коррупция": "corruption",
	"сеть": "comms", "ток": "power"}
var _ind_tex: Dictionary = {}


func _ind_icon(key: String) -> Texture2D:
	if not _ind_tex.has(key):
		_ind_tex[key] = GameApi.picture(mod, "textures/ui/ind_%s.svg" % str(IND_ICONS.get(key, "health")), 0.5)
	return _ind_tex[key] as Texture2D


func _draw_indicators(keys: Array) -> void:
	var r := 10.0
	for p in _list("indicators"):
		if not (p is Dictionary) or not bool(V.field((p as Dictionary), "наш", false)):
			continue
		var d: Dictionary = p
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		for i in keys.size():
			var key := str(keys[i])
			var q := float(V.pick(d, V.LAYER.get(key, [key]), -1.0))
			var raw := q
			if key == "коррупция" and q >= 0.0:
				q = 1.0 - q
			var c := s + Vector2((float(i) - float(keys.size() - 1) * 0.5) * r * 2.4, -r * 2.2)
			_canvas.draw_circle(c, r + 1.5, Color(0, 0, 0, 0.7))
			var tex := _ind_icon(key)
			var box := Rect2(c - Vector2(r, r) * 0.62, Vector2(r, r) * 1.24)
			if q < 0.0:
				_canvas.draw_circle(c, r, Color(0.22, 0.23, 0.26))
				if tex != null:
					_canvas.draw_texture_rect(tex, box, false, Color(1, 1, 1, 0.35))
			else:
				_canvas.draw_circle(c, r, _grade(q).darkened(0.25))
				_canvas.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + TAU * clampf(q, 0.0, 1.0), 24, Color(1, 1, 1, 0.9), 1.6, true)
				if tex != null:
					_canvas.draw_texture_rect(tex, box, false, Color.WHITE)
			var name := mod.tr_key("pax_corpinc3d_ind_" + str(IND_ICONS.get(key, key)))
			var value := mod.tr_key("pax_corpinc3d_ind_none") if raw < 0.0 else "%d%%" % roundi(clampf(raw, 0.0, 1.0) * 100.0)
			_hits.append({"pos": c, "r": r + 1.5, "lines": [name, value]})


static func _grade(q: float) -> Color:
	if q < 0.5:
		return Color(0.85, 0.2, 0.15).lerp(Color(0.95, 0.8, 0.2), clampf(q * 2.0, 0.0, 1.0))
	return Color(0.95, 0.8, 0.2).lerp(Color(0.25, 0.85, 0.35), clampf((q - 0.5) * 2.0, 0.0, 1.0))


## The cities' names, as in Terra Invicta: the more the camera comes in, the smaller the cities named (the whole globe
## — megacities only; at the game's nearest zoom — from ~100 000 people); the font by the city's size, capitals with a
## star and always (from a little closer than the whole globe); no name over another.
func _draw_labels(zoom: float) -> void:
	var font := _canvas.get_theme_default_font()
	var ru := TranslationServer.get_locale().begins_with("ru")
	var min_pop := clampf(1.2e7 / maxf(zoom * zoom, 0.01), 50000.0, 8.0e6)
	var placed: Array = []
	var shown := 0
	var max_n := int(cfg.get("labels_max", 90))
	for pass_i in 2:
		var list: Array = _capitals if pass_i == 0 else _cities
		if pass_i == 0 and zoom < float(cfg.get("capitals_from_zoom", 1.4)):
			continue
		for c in list:
			if shown >= max_n:
				return
			var pop := int(c["pop"])
			if pass_i == 1 and float(pop) < min_pop:
				break
			if pass_i == 1 and bool(c["cap"]):
				continue
			var s := _at(c["dir"] as Vector3)
			if not _on_screen(s, 0.0):
				continue
			var cap := bool(c["cap"])
			var label := str(c["ru"]) if ru and not str(c["ru"]).is_empty() else str(c["en"])
			var fs := int(clampf(10.0 + 2.4 * log(maxf(float(pop), 1.0) / 1.0e5) / log(10.0), 10.0, 18.0)) + (2 if cap else 0)
			var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var rect := Rect2(s + Vector2(6, -fs * 0.8), Vector2(tw + 4.0, fs * 1.1)).grow(2.0)
			var free := true
			for r in placed:
				if (r as Rect2).intersects(rect):
					free = false
					break
			if not free:
				continue
			placed.append(rect)
			shown += 1
			if cap:
				_star(s, 5.5, Color(1.0, 0.86, 0.45))
			else:
				_canvas.draw_circle(s, 2.5, Color(0, 0, 0, 0.7))
				_canvas.draw_circle(s, 1.8, Color(1, 1, 1, 0.95))
			var at := s + Vector2(7, fs * 0.3)
			_canvas.draw_string_outline(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.75))
			_canvas.draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.95, 0.85) if cap else Color(1, 1, 1, 0.92))


func _star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + TAU * float(i) / 10.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	_canvas.draw_colored_polygon(pts, Color(0, 0, 0, 0.6))
	var inner := PackedVector2Array()
	for p in pts:
		inner.append(c + (p - c) * 0.78)
	_canvas.draw_colored_polygon(inner, col)


## A base like on the game's flat map: a rounded plate in the owner's colour, a gold edge for ours, a fortress on it
## (half seen while it is being built). It was a bare coloured square that read as nothing.
var _base_icon: Texture2D
var _base_style: StyleBoxFlat


func _draw_bases() -> void:
	if _base_icon == null:
		_base_icon = GameApi.picture(mod, "textures/ui/base.svg", 0.75)
		_base_style = StyleBoxFlat.new()
		_base_style.set_corner_radius_all(5)
		_base_style.set_border_width_all(2)
		_base_style.shadow_size = 3
		_base_style.shadow_color = Color(0, 0, 0, 0.45)
	for b in _list("bases"):
		if not (b is Dictionary) or not ((b as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = b
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		var col: Color = V.field(d, "цвет", Color.WHITE)
		var ours := bool(V.field(d, "наш", false))
		var rect := Rect2(s + Vector2(-12, 14), Vector2(24, 24))
		_base_style.bg_color = col.lerp(Color(0.1, 0.1, 0.12), 0.5)
		_base_style.border_color = Color(1.0, 0.85, 0.35) if ours else Color(0, 0, 0, 0.9)
		_canvas.draw_style_box(_base_style, rect)
		if _base_icon != null:
			_canvas.draw_texture_rect(_base_icon, rect.grow(-4.0), false,
				Color(1, 1, 1, 0.45) if bool(V.field(d, "строится", false)) else Color.WHITE)


func _draw_battles() -> void:
	var font := _canvas.get_theme_default_font()
	for b in _list("battles"):
		if not (b is Dictionary) or not ((b as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = b
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		var r := 13.0
		var beat := 0.5 + 0.5 * sin(_time * 4.0)
		_canvas.draw_circle(s, r + 3.0 + beat * 2.0, Color(0.95, 0.25, 0.2, 0.35))
		_canvas.draw_circle(s, r, Color(V.field(d, "цвет_а", Color.RED)))
		var share := clampf(float(V.field(d, "ход", 0.5)), 0.0, 1.0)
		var pts := PackedVector2Array([s])
		for i in 25:
			var a := -PI * 0.5 + TAU * share * float(i) / 24.0
			pts.append(s + Vector2(cos(a), sin(a)) * r)
		if share > 0.01:
			_canvas.draw_colored_polygon(pts, Color(V.field(d, "цвет_д", Color.BLUE)))
		_canvas.draw_arc(s, r, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 1.5, true)
		_canvas.draw_string(font, s + Vector2(-7, 5), "⚔", HORIZONTAL_ALIGNMENT_CENTER, 14, 13, Color.WHITE)


func _draw_armies() -> void:
	var font := _canvas.get_theme_default_font()
	var placed: Array = []    # screen rects already used: a stack in the same place moves a row down
	for a in units():
		if not (a is Dictionary) or not ((a as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = a
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		var ours := bool(V.field(d, "наш", false))
		var col: Color = V.field(d, "цвет", Color.GRAY)
		var target: Variant = V.field(d, "цель_uv")
		if ours and target is Vector2:
			_polyline(_arc(d["uv"], target), Color(1, 1, 1, 0.5), 1.5, 5.0)
		var text := _people(float(V.field(d, "люди", 0.0)))
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 14.0
		# Above the 3D car and soldiers (armies3d.gd), not over them; a line down to the place.
		var rect := Rect2(s + Vector2(-w * 0.5, -22 - float(cfg.get("army_chip_lift", 46.0))), Vector2(w, 18))
		for other in placed:
			if (other as Rect2).intersects(rect):
				rect.position.y = (other as Rect2).end.y + 2.0
		placed.append(rect)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(col.darkened(0.35), 0.92)
		sb.border_color = Color(0.95, 0.25, 0.2) if bool(V.field(d, "в_бою", false)) else (Color(0.95, 0.8, 0.4) if ours else Color(0, 0, 0, 0.8))
		sb.set_border_width_all(2 if ours or bool(V.field(d, "в_бою", false)) else 1)
		sb.set_corner_radius_all(4)
		_canvas.draw_style_box(sb, rect)
		_canvas.draw_string(font, rect.position + Vector2(7, 13), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		_canvas.draw_line(s, Vector2(s.x, rect.end.y), Color(1, 1, 1, 0.5), 1.0)
		_canvas.draw_circle(s, 2.5, Color.WHITE)
		_hits.append({"pos": rect.get_center(), "r": maxf(w * 0.5, 10.0), "lines": [str(V.field(d, "имя", "")), str(V.field(d, "подпись", ""))]})


static func _people(n: float) -> String:
	if n >= 1e6:
		return "%.1fM" % (n / 1e6)
	if n >= 1e3:
		return "%.0fk" % (n / 1e3) if n >= 1e4 else "%.1fk" % (n / 1e3)
	return str(int(n))


func _draw_marks() -> void:
	var font := _canvas.get_theme_default_font()
	for m in _list("marks"):
		if not (m is Dictionary) or not ((m as Dictionary).get("uv") is Vector2):
			continue
		var d: Dictionary = m
		var s := _uv(d["uv"])
		if not _on_screen(s):
			continue
		var col: Color = V.field(d, "цвет", Color.WHITE)
		var r := 7.0 if bool(V.field(d, "активна", false)) else 5.0
		_canvas.draw_colored_polygon(PackedVector2Array([s + Vector2(0, -r), s + Vector2(r, 0), s + Vector2(0, r), s + Vector2(-r, 0)]), col)
		var label := str(V.field(d, "подпись", ""))
		if not label.is_empty():
			_canvas.draw_string_outline(font, s + Vector2(r + 4, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.8))
			_canvas.draw_string(font, s + Vector2(r + 4, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.92))


func _draw_tip() -> void:
	if _hover.is_empty():
		return
	var lines: Array = (_hover["lines"] as Array).filter(func(x: Variant) -> bool: return not str(x).is_empty())
	if lines.is_empty():
		return
	var font := _canvas.get_theme_default_font()
	var fs := 13
	var w := 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(str(l), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var box := Rect2((_hover["pos"] as Vector2) + Vector2(16, -10), Vector2(w + 16.0, lines.size() * (fs + 4.0) + 10.0))
	if bool(_hover.get("bubble", false)):
		# A bubble over the building: rounded, above and right of the cursor, a tail down to it.
		var at: Vector2 = _hover["pos"]
		box = Rect2(at + Vector2(18, -box.size.y - 22), box.size + Vector2(8, 4))
		if box.end.x > _canvas.size.x:
			box.position.x = at.x - box.size.x - 18.0
		if box.position.y < 0.0:
			box.position.y = at.y + 22.0
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.09, 0.12, 0.94)
		sb.border_color = Color(0.95, 0.78, 0.32, 0.85)
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(10)
		sb.shadow_color = Color(0, 0, 0, 0.45)
		sb.shadow_size = 8
		var base_x := clampf(at.x, box.position.x + 14.0, box.end.x - 14.0)
		var base_y := box.end.y if box.end.y <= at.y else box.position.y
		_canvas.draw_colored_polygon(PackedVector2Array([Vector2(base_x - 7.0, base_y), Vector2(base_x + 7.0, base_y), at]), sb.border_color)
		_canvas.draw_style_box(sb, box)
		box.position += Vector2(4, 2)
		for i in lines.size():
			_canvas.draw_string(font, box.position + Vector2(8, 6 + fs + i * (fs + 4.0)), str(lines[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs + (1 if i == 0 else 0), Color(1, 1, 1, 1.0 if i == 0 else 0.75))
		return
	if box.end.x > _canvas.size.x:
		box.position.x -= box.size.x + 32.0
	_canvas.draw_rect(box, Color(0.06, 0.07, 0.09, 0.95))
	_canvas.draw_rect(box, Color(0.95, 0.78, 0.32, 0.8), false, 1.0)
	for i in lines.size():
		_canvas.draw_string(font, box.position + Vector2(8, 6 + fs + i * (fs + 4.0)), str(lines[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 1.0 if i == 0 else 0.75))
