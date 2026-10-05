extends RefCounted
## Pax Universe 0.24 moved Main's methods into its parts (docs/modding/MAIN_TO_API.md): main._флаг_чей(x) is now
## main.army_map_view().owner_flag(x), and so on. The old names still answer through a compatibility layer for a
## while — but not has_method(), so the mods' checks failed (no flags, no window toggling). The mods ask here:
## has(main, old) / call_main(main, old, args) — the new way first, the old name only on an older game.

const NEW := {
	"_флаг_чей": ["army_map_view", "owner_flag"],
	"_переключить_окно": ["hud", "toggle_window"],
	"_спросить_помощника": ["assistant_questions", "ask"],
	"_говорить_с_контактом": ["conversation", "talk_with_contact"],
	"_обновить_контакты": ["conversation", "refresh_contacts"],
	"_карта_открыта": ["camera_navigation", "map_open"],
	"_переключить_карту": ["galaxy_view", "toggle_map"],
	"_казна_расклад": ["treasury", "breakdown"],
	"_ресурсы_расклад": ["treasury", "resources_breakdown"],
	"_окна_группы": ["hud", "group_windows"],
	"_цена_продукта": ["production", "product_price"],
	"_санкции_видами": ["market", "sanctions_by_kind"],
	"_наука_за_неделю": ["science_step", "per_week"],
	"_поставить_камеру": ["camera_navigation", "place_camera"],
	"_подсказка": ["hud_refresh", "hint"],
}


## The part of Main that does what the old method did (0.24+), null on an older game or when it is missing.
static func _part(main: Object, old: String) -> Object:
	var path: Array = NEW.get(old, [])
	if path.is_empty() or main == null or not main.has_method(str(path[0])):
		return null
	var o: Variant = main.call(str(path[0]))
	return o as Object if o is Object and is_instance_valid(o) and (o as Object).has_method(str(path[1])) else null


## Can the game do what Main's old method did?
static func has(main: Object, old: String) -> bool:
	if main == null or not is_instance_valid(main):
		return false
	return _part(main, old) != null or main.has_method(old)


## Main's old method, called the way this game version has it (null when it has none).
static func call_main(main: Object, old: String, args: Array = []) -> Variant:
	if main == null or not is_instance_valid(main):
		return null
	var o := _part(main, old)
	if o != null:
		return o.callv(str((NEW[old] as Array)[1]), args)
	if main.has_method(old):
		return main.callv(old, args)
	return null


## A JSON file of the mod as written. Game 0.24's load_json translates Russian keys and even values on the way in
## («название» → «title_name», «нефть» → «oil»), and the mods' data stopped matching their code. read_text does not.
static func json(mod: Object, relative: String, default_value: Variant = null) -> Variant:
	var text: String = str(mod.call("read_text", relative)) if is_instance_valid(mod) else ""
	if text.is_empty():
		return default_value
	var parsed: Variant = JSON.parse_string(text)
	return default_value if parsed == null else parsed


## A picture of the mod. Game 0.24's texture() gives an empty picture for an SVG (the icons were drawn as squares):
## an SVG is drawn here from its bytes (at «scale» × its own size), anything else goes through texture().
static func picture(mod: Object, relative: String, scale: float = 2.0) -> Texture2D:
	if not is_instance_valid(mod):
		return null
	if relative.get_extension().to_lower() == "svg":
		var bytes: Variant = mod.call("read_bytes", relative)
		if bytes is PackedByteArray and not (bytes as PackedByteArray).is_empty():
			var img := Image.new()
			if img.load_svg_from_buffer(bytes, scale) == OK and not img.is_empty():
				return ImageTexture.create_from_image(img)
	var tex: Variant = mod.call("texture", relative)
	return tex as Texture2D if tex is Texture2D else null


## The mods' own frame costs for the probe (zz_corp_probe diag.json): {name: [µs summed, calls]} in Engine meta
## «pax_perf»; the probe reads and clears it every 5 s.
static func perf(name: String, since_usec: int) -> void:
	var d: Dictionary = Engine.get_meta(&"pax_perf", {}) if Engine.has_meta(&"pax_perf") else {}
	var e: Array = d.get(name, [0, 0])
	e[0] = int(e[0]) + Time.get_ticks_usec() - since_usec
	e[1] = int(e[1]) + 1
	d[name] = e
	Engine.set_meta(&"pax_perf", d)


## Game 0.24 moved Main's methods into its parts under new names we do not know yet (the political map's refresh:
## _армии_на_карту, the networks: _обновить_сети_карты). Found here by their likely names, once: Main's own methods
## first, then the methods of Main's parts (army_map_view(), …) — only methods that take no arguments. «why» (an empty
## Array) gets a line for the journal: what was found or that nothing was. An invalid Callable — none.
static func discover(main: Object, words: Array, parts: Array, why: Array) -> Callable:
	if main == null or not is_instance_valid(main):
		return Callable()
	for w in words:
		for m in main.get_method_list():
			var nm := str((m as Dictionary)["name"])
			if nm.to_lower().contains(str(w)) and _no_args(m as Dictionary):
				why.append("Main.%s" % nm)
				return Callable(main, nm)
	for p in parts:
		if not main.has_method(str(p)):
			continue
		var part: Variant = main.call(str(p))
		if not (part is Object) or not is_instance_valid(part):
			continue
		for w in words:
			for m in (part as Object).get_method_list():
				var nm := str((m as Dictionary)["name"])
				if nm.to_lower().contains(str(w)) and _no_args(m as Dictionary):
					why.append("Main.%s().%s" % [str(p), nm])
					return Callable(part as Object, nm)
	why.append("none of %s" % str(words))
	return Callable()


static func _no_args(m: Dictionary) -> bool:
	var args: Array = m.get("args", [])
	var defs: Array = m.get("default_args", [])
	return args.size() - defs.size() <= 0

