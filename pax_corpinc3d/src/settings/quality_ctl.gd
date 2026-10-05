extends RefCounted
## The 3D quality at work: the settings (quality.gd) put into the globe and the flat-map pictures, a mode chosen in the
## window «3D», an option changed, the automatic step down when the game lags (auto_quality.gd).
## Part of main.gd (its wrappers: set_quality, set_option, quality_status, set_on).

const Host := preload("res://mods/pax_corpinc3d/main.gd")
const Quality := preload("res://mods/pax_corpinc3d/src/settings/quality.gd")
const AutoQuality := preload("res://mods/pax_corpinc3d/src/settings/auto_quality.gd")
const Log := preload("res://mods/pax_corpinc3d/src/shared/log.gd")

var app: Host   # the host: its modules and data
var auto: AutoQuality
var last_auto := ""                 # the last automatic step («normal → eco»), shown in the window


func _init(host: Host) -> void:
	app = host


## Made once the globe exists (life_ctl._mod_loaded).
func start() -> void:
	auto = AutoQuality.new()
	auto.globe = app.globe
	auto.on_slow = step_down
	app.add_child(auto)
	apply()


## The settings into the globe, the pictures and the auto check; the buildings are built again.
func apply() -> void:
	var on := str(Quality.get_value(app, "quality")) != "off"
	var o := Quality.options(app)
	app.globe.limit = int(o["limit"])
	app.globe.hq_only = bool(o["hq_only"])
	app.globe.shadows = bool(o["shadows"])
	app.globe.hide_far = float(o["hide_far"])
	var q := str(Quality.get_value(app, "quality"))
	# The trees stay in «eco» too, only fewer and nearer: the automatic step down (auto_quality.gd) lands there when the
	# game lags, and the forest vanished with it — players took it for a bug. Off is the layer's switch («Деревья»).
	app.forest.enabled = on
	app.forest.radius_deg = 20.0 if q == "max" else (8.0 if q == "eco" else 12.0)
	app.forest.per_cell = 3.0 if q == "max" else (1.0 if q == "eco" else 2.0)
	app.forest.rebuild()
	if app.globe.enabled != on:
		app.globe.enabled = on
		app.globe.clear()
	if app.photo.enabled != on:
		app.photo.enabled = on
		app.photo.clear()
		_tell_corporations()
	app.globe.rebuild()
	if auto != null:
		auto.enabled = bool(Quality.get_value(app, "auto"))
		auto.threshold = int(Quality.get_value(app, "auto_fps"))
		auto.calm()


func choose(quality: String) -> void:
	Quality.choose(app, quality)
	Log.info("quality", "mode %s" % quality)
	apply()


func change(key: String, value: Variant) -> void:
	Quality.change(app, key, value)
	apply()


## The game lags with the buildings shown: one mode lower, told in the journal and a notification.
func step_down() -> void:
	var now := str(Quality.get_value(app, "quality"))
	var lower := Quality.lower(now)
	# By itself it stops at «eco»: «off» took away the buildings and the roads altogether, and players did not
	# know why — switching everything off is the player's own choice (the 3D window).
	if lower.is_empty() or lower == "off":
		return
	last_auto = "%s → %s" % [now, lower]
	Log.warn("quality", "below %d FPS: the 3D mode lowered %s" % [int(Quality.get_value(app, "auto_fps")), last_auto])
	choose(lower)
	if app.game != null:
		app.game.toast(app.tr_key("pax_corpinc3d_auto_lowered") % app.tr_key("pax_corpinc3d_q_" + lower))


## For the window: the mode, the options, frames per second, buildings drawn, the last automatic step.
func status() -> Dictionary:
	var out := Quality.options(app).duplicate()
	out["quality"] = str(Quality.get_value(app, "quality"))
	out["auto"] = bool(Quality.get_value(app, "auto"))
	out["auto_fps"] = int(Quality.get_value(app, "auto_fps"))
	out["fps"] = Engine.get_frames_per_second()
	out["count"] = app.globe.built_count() if app.globe.enabled else 0
	out["last_auto"] = last_auto
	return out


## Pax Corporations rebuilds its buildings (it asks this mod for the pictures).
func _tell_corporations() -> void:
	if Engine.has_meta("pax_corporations_api"):
		var api: Variant = Engine.get_meta("pax_corporations_api")
		if api is Object and is_instance_valid(api) and (api as Object).has_method("refresh_buildings"):
			(api as Object).call("refresh_buildings")
