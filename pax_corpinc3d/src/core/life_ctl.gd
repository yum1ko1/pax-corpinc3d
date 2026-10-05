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
	app.forest = Host.Forest.new()
	app.forest.setup(app, app.globe)
	app.add_child(app.forest)
	app.quality_ctl.start()
	Pax.register_command("inc3d", func(args: PackedStringArray) -> String:
		if args.size() > 0 and args[0] in ["on", "off"]:
			set_on(args[0] == "on")
		elif args.size() > 0 and args[0] in ["eco", "normal", "max"]:
			app.quality_ctl.choose(args[0])
		var st := app.quality_ctl.status()
		return "Pax CorpInc3D: mode %s, buildings on the globe %d, %d FPS" % [str(st["quality"]), int(st["count"]), int(st["fps"])],
		"inc3d [on|off|eco|normal|max] — Pax CorpInc3D: the 3D buildings' mode")


func _mod_unloaded() -> void:
	Log.shutdown(app)
	if Engine.has_meta(Host.META) and Engine.get_meta(Host.META) == app.photo:
		Engine.remove_meta(Host.META)
	if app.globe != null:
		app.globe.clear()
	if app.forest != null:
		app.forest.clear()
	_tell_corporations()
	if app.whatsnew != null:
		app.whatsnew.teardown()
	app.whatsnew = null


func _world_ready(g: PaxGame) -> void:
	app.game = g
	app.globe.start(g)
	app.forest.start(g)
	app.quality_ctl.apply()
	var panel := Host.Panel3D.new()
	panel.mod = app
	g.add_window(app.tr_key("pax_corpinc3d_button"), panel, Vector2(500, 560))
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
