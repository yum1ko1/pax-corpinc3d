extends RefCounted
## The mod's way into the shared journal (log_hub.gd):  Log.info("zones", "joined %s" % id)
## Levels: debug (kept only with «paxlog debug on»), info, warn, error. A line also goes to the game's own log
## (PaxMod.log_*), tagged with the mod id. setup() once in _mod_loaded; shutdown() in _mod_unloaded.

const META := &"pax_corpinc_log"
const Hub := preload("res://mods/pax_corpinc3d/src/shared/log_hub.gd")

static var _mod: Object
static var _id := ""


static func setup(mod: Object, id: String) -> void:
	_mod = mod
	_id = id
	Hub.ensure(mod)


static func shutdown(mod: Object) -> void:
	Hub.release(mod)
	_mod = null


static func debug(category: String, text: String) -> void:
	_add("debug", category, text)


static func info(category: String, text: String) -> void:
	_add("info", category, text)


static func warn(category: String, text: String) -> void:
	_add("warn", category, text)


static func error(category: String, text: String) -> void:
	_add("error", category, text)


## The shared journal (untyped: the first mod's copy of log_hub.gd), null when none.
static func hub() -> Object:
	var h: Variant = Engine.get_meta(META) if Engine.has_meta(META) else null
	return h as Object if h is Object and is_instance_valid(h) else null


static func _add(level: String, category: String, text: String) -> void:
	var h := hub()
	if h != null:
		h.call("add", _id, level, category, text)
	if level == "debug" or _mod == null or not is_instance_valid(_mod):
		return
	if h != null:
		h.set("muted", true)   # the engine echoes the printed line back to the journal — not twice
	_mod.call({"info": "log_info", "warn": "log_warning", "error": "log_error"}[level], "[%s] %s" % [category, text])
	if h != null:
		h.set("muted", false)
