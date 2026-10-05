extends RefCounted
## The 3D quality of Pax CorpInc3D, kept in the mod's settings:
##   quality — off | eco | normal | max | custom (custom: the options below as the player set them);
##   limit, hq_only, shadows, hide_far, trees, trees_deg — what a mode means (settings/../globe/globe.gd draws by them);
##   auto, auto_fps — lower the mode by itself when the game runs below auto_fps (settings/auto_quality.gd).
## «off» also stops the pictures for the flat map (photo.gd) — the weakest computers get no 3D at all.

const ORDER := ["off", "eco", "normal", "max"]
const PRESETS := {
	"eco": {"limit": 250, "hq_only": true, "shadows": false, "hide_far": 4.0, "trees": false, "trees_deg": 8.0},
	"normal": {"limit": 1500, "hq_only": false, "shadows": false, "hide_far": 0.0, "trees": true, "trees_deg": 12.0},
	"max": {"limit": 0, "hq_only": false, "shadows": true, "hide_far": 0.0, "trees": true, "trees_deg": 20.0},
}
const DEFAULTS := {"quality": "normal", "limit": 1500, "hq_only": false, "shadows": false, "hide_far": 0.0,
	"trees": true, "trees_deg": 12.0, "auto": true, "auto_fps": 25}


static func get_value(mod: Object, key: String) -> Variant:
	if key == "quality" and not bool(mod.call("get_setting", "on", true)):
		return "off"   # the old on/off setting
	return mod.call("get_setting", key, DEFAULTS[key])


## The options a mode means (custom — the player's own).
static func options(mod: Object) -> Dictionary:
	var q := str(get_value(mod, "quality"))
	if PRESETS.has(q):
		return PRESETS[q]
	return {"limit": int(get_value(mod, "limit")), "hq_only": bool(get_value(mod, "hq_only")),
		"shadows": bool(get_value(mod, "shadows")), "hide_far": float(get_value(mod, "hide_far")),
		"trees": bool(get_value(mod, "trees")), "trees_deg": float(get_value(mod, "trees_deg"))}


## A mode chosen: saved; a preset also writes its options (so «custom» starts from them).
static func choose(mod: Object, quality: String) -> void:
	mod.call("set_setting", "quality", quality)
	mod.call("set_setting", "on", quality != "off")
	if quality != "off":
		mod.call("set_setting", "quality_on", quality)   # «on» again brings this mode back
	if PRESETS.has(quality):
		for k in (PRESETS[quality] as Dictionary).keys():
			mod.call("set_setting", k, (PRESETS[quality] as Dictionary)[k])


## One option changed by hand: the mode becomes «custom».
static func change(mod: Object, key: String, value: Variant) -> void:
	if key in ["auto", "auto_fps"]:
		mod.call("set_setting", key, value)
		return
	var opts := options(mod)
	for k in opts.keys():
		mod.call("set_setting", k, opts[k])
	mod.call("set_setting", key, value)
	mod.call("set_setting", "quality", "custom")
	mod.call("set_setting", "on", true)


## The next lower mode (custom counts as normal); "" — already off.
static func lower(quality: String) -> String:
	var i := ORDER.find(quality if quality != "custom" else "normal")
	return ORDER[i - 1] if i > 0 else ""
