extends Node
## «Чистая 2D-карта» (setting flat_clean, on by default; a checkbox in the «3D» window): the buildings, roads and
## networks the author's mods drew on the game's flat map belong on the 3D Earth — there they are 3D (this mod). So
## while it is on, the flat map gets them no more:
##   Pax Corporations — its «Корпорации» layer (the companies' marks on the political map, and the same marks over the
##   globe) goes to «off» through its own set_mode, as if the player picked it in the layer's list;
##   Pax Corpface — its networks along the real cities on the flat map (setting nets2d) go off.
## What they were is remembered (flat_clean_prev) and given back when the checkbox is cleared or this mod unloaded.
## Checked every 2 s: a mod loaded later, or a layer the player switched on again by hand, is caught.

const CORP := "pax_corporations"
const FACE := "pax_corpface"

var mod: PaxMod
var _t := 0.0


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DFlatClean"
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_on() -> bool:
	return bool(mod.get_setting("flat_clean", true))


func set_on(on: bool) -> void:
	mod.set_setting("flat_clean", on)
	if on:
		apply()
	else:
		restore()


func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = 2.0
	if is_on():
		apply()


func _other(id: String) -> Object:
	var m: Variant = Pax.get_mod(id) if Pax.has_method("get_mod") else null
	return m as Object if m is Object and is_instance_valid(m) else null


func _prev() -> Dictionary:
	var raw: Variant = mod.get_setting("flat_clean_prev", {})
	return (raw as Dictionary).duplicate() if raw is Dictionary else {}


func apply() -> void:
	var prev := _prev()
	var changed := false
	var corp := _other(CORP)
	var layer: Variant = corp.get("_layer") if corp != null else null
	if layer is Object and is_instance_valid(layer) and (layer as Object).has_method("set_mode"):
		var now := int((layer as Object).get("mode"))
		if now != 0:
			if not prev.has("corp_layer"):
				prev["corp_layer"] = now
				changed = true
			(layer as Object).call("set_mode", 0)
	var face := _other(FACE)
	if face != null and face.has_method("get_setting") and bool(face.call("get_setting", "nets2d", true)):
		if not prev.has("nets2d"):
			prev["nets2d"] = true
			changed = true
		face.call("set_setting", "nets2d", false)
	if changed:
		mod.set_setting("flat_clean_prev", prev)


func restore() -> void:
	var prev := _prev()
	if prev.is_empty():
		return
	var corp := _other(CORP)
	var layer: Variant = corp.get("_layer") if corp != null else null
	if prev.has("corp_layer") and layer is Object and is_instance_valid(layer) and (layer as Object).has_method("set_mode"):
		(layer as Object).call("set_mode", int(prev["corp_layer"]))
	var face := _other(FACE)
	if prev.has("nets2d") and face != null and face.has_method("set_setting"):
		face.call("set_setting", "nets2d", bool(prev["nets2d"]))
	mod.set_setting("flat_clean_prev", {})
