extends RefCounted
## The mod's life: loading (models, the globe), the world's start, on/off, telling Pax Corporations the 3D is here.
## Part of main.gd (split out of it; the host keeps one-line wrappers with the same names).

const Host := preload("res://mods/pax_corpinc3d/main.gd")
const Log := preload("res://mods/pax_corpinc3d/src/shared/log.gd")

var app: Host   # the host: its modules and data


func _init(host: Host) -> void:
	app = host


func _mod_loaded() -> void:
	Log.setup(app, "pax_corpinc3d")
	app.photo = Host.Photo.new()
	app.photo.setup(app)
	app.add_child(app.photo)
	Engine.set_meta(Host.META, app.photo)
	app.globe = Host.Globe.new()
	app.globe.setup(app, app.photo)
	app.add_child(app.globe)
	app.earth = Host.Earth.new()
	app.earth.setup(app)
	app.add_child(app.earth)
	Engine.set_meta(&"pax_corpinc3d_earth", app.earth)   # other mods outline a country on the globe (focus_country)
	app.descent = Host.Descent.new()
	app.descent.setup(app)
	app.add_child(app.descent)
	app.layers = Host.GlobeLayers.new()
	app.layers.setup(app)
	app.add_child(app.layers)
	app.experimental = Host.Experimental.new()
	app.experimental.setup(app)
	app.add_child(app.experimental)
	app.satellites = Host.Satellites.new()
	app.satellites.setup(app)
	app.add_child(app.satellites)
	app.forest = Host.Forest.new()
	app.forest.setup(app)
	app.add_child(app.forest)
	app.gear = Host.Gear.new()
	app.gear.setup(app)
	app.add_child(app.gear)
	app.flat_clean = Host.FlatClean.new()
	app.flat_clean.setup(app)
	app.add_child(app.flat_clean)
	app.quality_ctl.start()
	Pax.register_command("inc3d", func(args: PackedStringArray) -> String:
		if args.size() > 0 and args[0] == "probe":
			return _probe()
		if args.size() > 0 and args[0] == "layers":
			return "3D layers: " + app.layers.diag() + ", trees %d" % app.forest.built_count()
		if args.size() > 0 and args[0] == "political":
			app.earth.set_political(not app.earth.political)
			return "political map: %s" % ("on" if app.earth.political else "off")
		if args.size() > 0 and args[0] in ["on", "off"]:
			set_on(args[0] == "on")
		elif args.size() > 0 and args[0] in ["eco", "normal", "max"]:
			app.quality_ctl.choose(args[0])
		var st := app.quality_ctl.status()
		return "Pax CorpInc3D: mode %s, buildings on the globe %d, %d FPS" % [str(st["quality"]), int(st["count"]), int(st["fps"])],
		"inc3d [on|off|eco|normal|max|probe|political|layers] — Pax CorpInc3D: the 3D buildings' mode; probe — the game's names the 3D layers read; layers — what the 3D layers see (armies, ships, planes)")
	Pax.register_command("earth", func(args: PackedStringArray) -> String:
		if args.size() > 0 and args[0] in ["on", "off"]:
			app.earth.set_enabled(args[0] == "on")
		return "Earth HD: %s, maps %s" % ["on" if app.earth.enabled else "off", str(app.earth.maps_found())],
		"earth [on|off] — Pax CorpInc3D: the Earth with real maps (Earth HD)")


func _mod_unloaded() -> void:
	Log.shutdown(app)
	if Engine.has_meta(Host.META) and Engine.get_meta(Host.META) == app.photo:
		Engine.remove_meta(Host.META)
	if app.globe != null:
		app.globe.clear()
	if app.forest != null:
		app.forest.clear()
	if app.flat_clean != null:
		app.flat_clean.restore()   # the other mods' flat-map layers as they were
	if app.earth != null:
		app.earth.restore()
	if Engine.has_meta(&"pax_corpinc3d_earth") and Engine.get_meta(&"pax_corpinc3d_earth") == app.earth:
		Engine.remove_meta(&"pax_corpinc3d_earth")
	_tell_corporations()
	if app.whatsnew != null:
		app.whatsnew.teardown()
	app.whatsnew = null


func _world_ready(g: PaxGame) -> void:
	app.game = g
	app.globe.start(g)
	app.earth.start(g)
	app.descent.start(g)
	app.layers.start(g)
	app.experimental.start(g)
	app.satellites.start(g)
	app.forest.start(g)
	app.quality_ctl.apply()
	app.gear.start(g)   # the settings: a gear above the chronicle, not a button of the bottom bar
	_tell_corporations()
	if app.whatsnew != null:
		app.whatsnew.teardown()
	app.whatsnew = Host.WhatsNew.new()
	app.whatsnew.setup(app, g, "pax_corpinc3d_")
	app.get_tree().create_timer(3.8).timeout.connect(func() -> void:
		if app.whatsnew != null:
			app.whatsnew.maybe_show())


## On — the last mode that was not «off» (normal at first); off — no 3D at all.
func set_on(on: bool) -> void:
	var was := str(app.get_setting("quality_on", "normal"))
	app.quality_ctl.choose(was if on else "off")


## Pax Corporations rebuilds its buildings (it asks this mod for the pictures).
func _tell_corporations() -> void:
	if Engine.has_meta("pax_corporations_api"):
		var api: Variant = Engine.get_meta("pax_corporations_api")
		if api is Object and is_instance_valid(api) and (api as Object).has_method("refresh_buildings"):
			(api as Object).call("refresh_buildings")


## Console «inc3d probe»: how this game version names what the 3D layers read — the political map's lists and the keys
## of their first entries, the methods of Main and of its parts about the map and the camera. Sent by a player, it
## shows which of v024.gd's guesses hold.
func _probe() -> String:
	var g: PaxGame = app.game
	if g == null or not is_instance_valid(g.main):
		return "no world"
	var out: PackedStringArray = []
	if app.earth != null:
		out.append(str(app.earth.status()))
	var main: Object = g.main
	var map: Variant = main.get("полит_карта")
	out.append("political map: %s" % ("found" if map is Object else "MISSING (полит_карта)"))
	if map is Object:
		for p in (map as Object).get_property_list():
			var n := str((p as Dictionary)["name"])
			var v: Variant = (map as Object).get(n)
			if v is Array and not (v as Array).is_empty() and (v as Array)[0] is Dictionary:
				out.append("  %s [%d]: %s" % [n, (v as Array).size(), ", ".join(PackedStringArray(((v as Array)[0] as Dictionary).keys().map(func(k: Variant) -> String: return str(k))))])
			elif v is Array or v is Dictionary:
				out.append("  %s (%s, %d)" % [n, type_string(typeof(v)), (v as Array).size() if v is Array else (v as Dictionary).size()])
		var layers: Variant = (map as Object).get("слои")
		if layers == null:
			layers = (map as Object).get("layers")
		out.append("  layers: %s" % str(layers))
		var meths: PackedStringArray = []
		for m in (map as Object).get_method_list():
			var mn := str((m as Dictionary)["name"])
			if mn.contains("сло") or mn.contains("layer") or mn.contains("экран") or mn.contains("screen"):
				meths.append(mn)
		out.append("  map methods: %s" % ", ".join(meths))
	var main_m: PackedStringArray = []
	for m in main.get_method_list():
		var mn := str((m as Dictionary)["name"])
		if mn.contains("карт") or mn.contains("map") or mn.contains("сет") or mn.contains("net") or mn.contains("камер") or mn.contains("camera") or mn.contains("арми") or mn.contains("army"):
			main_m.append(mn)
	out.append("Main methods: %s" % ", ".join(main_m))
	for part in ["army_map_view", "camera_navigation", "galaxy_view", "hud"]:
		if main.has_method(part):
			var o: Variant = main.call(part)
			if o is Object:
				var pm: PackedStringArray = []
				for m in (o as Object).get_method_list():
					var mn := str((m as Dictionary)["name"])
					if not mn.begins_with("_") or mn.contains("карт") or mn.contains("map"):
						pm.append(mn)
				out.append("%s(): %s" % [part, ", ".join(pm.slice(0, 60))])
	var body: Dictionary = g.body(g.home_body())
	out.append("body keys: %s" % ", ".join(PackedStringArray(body.keys().map(func(k: Variant) -> String: return str(k)))))
	out.append("faction keys: %s" % ", ".join(PackedStringArray(g.player_faction().keys().map(func(k: Variant) -> String: return str(k)))))
	for v in ["режим", "цель_дист", "тангаж", "камера_рыскание", "пров"]:
		out.append("Main.%s: %s" % [v, "ok" if main.get(v) != null else "MISSING"])
	var text := "\n".join(out)
	app.log_info("probe:\n" + text)
	return text
