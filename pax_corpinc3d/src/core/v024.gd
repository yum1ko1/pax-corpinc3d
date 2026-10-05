extends RefCounted
## Pax Universe 0.24 gave its data English keys (pax_corporations_dev/refactor/v024_game.txt: a country's «имя» →
## «name», «цвет» → «colour»; the political map's «отряды_карты» → «map_units», «промыслы_карты» → «map_mines»,
## «базы_карты» → «map_bases»…). Where the new name was seen it goes first; the old one stays after it (an older game),
## and for what was not seen yet a likely English name sits between. The first one present wins.

## The political map's lists and parts.
const MAP := {
	"units": ["map_units", "отряды_карты"],
	"mines": ["map_mines", "промыслы_карты"],
	"bases": ["map_bases", "базы_карты"],
	"caravans": ["map_caravans", "caravans", "караваны_карты"],
	"flights": ["map_flights", "flights", "авиарейсы_карты"],
	"battles": ["map_battles", "battles", "бои_карты"],
	"front": ["map_front", "front", "фронт_карты"],
	"operations": ["map_operations", "operations", "операции_карты"],
	"indicators": ["map_indicators", "indicators", "показатели_карты"],
	"marks": ["marks", "метки"],
	"lines": ["lines", "линии"],
	"layers": ["layers", "слои"],
	"material": ["мат", "mat", "material"],
	"layers_window": ["окно_слоёв", "layers_window"],
	"provinces": ["пров", "provinces"],
}

## The fields of the map's entries.
const F := {
	"цвет": ["colour", "color", "цвет"],
	"имя": ["name", "имя"],
	"люди": ["humans", "people", "люди"],
	"наш": ["ours", "own", "наш"],
	"подпись": ["caption", "label", "подпись"],
	"вид": ["kind", "type", "вид"],
	"точки": ["points", "точки"],
	"ход": ["progress", "course", "ход"],
	"в_бою": ["in_battle", "в_бою"],
	"цель_uv": ["target_uv", "цель_uv"],
	"цвет_а": ["colour_a", "color_a", "цвет_а"],
	"цвет_д": ["colour_d", "color_d", "цвет_д"],
	"а": ["a", "from", "а"],
	"б": ["b", "to", "б"],
	"фаза": ["phase", "фаза"],
	"строится": ["building", "under_construction", "строится"],
	"активна": ["active", "активна"],
}

## The map's layers (its «Слои» window).
const LAYER := {
	"дороги": ["roads", "дороги"],
	"жд": ["rail", "railways", "railway", "жд"],
	"сеть": ["comms", "network", "net", "сеть"],          # game 0.24: comms
	"ток": ["current", "power", "electricity", "ток"],    # game 0.24: current
	"здоровье": ["health", "здоровье"],
	"образование": ["education", "образование"],
	"безопасность": ["safety", "security", "безопасность"],
	"коррупция": ["corruption", "коррупция"],
	"авиа": ["air_arm", "air", "flights", "авиа"],        # game 0.24: air_arm
	"торговля": ["trade", "торговля"],
}

## Values of «вид» (a route's carrier).
const KIND := {
	"самолёт": ["самолёт", "plane", "airplane", "aircraft"],
	"корабль": ["корабль", "ship"],
}


static func pick(d: Variant, names: Array, default_value: Variant = null) -> Variant:
	if not (d is Dictionary):
		return default_value
	for n in names:
		if (d as Dictionary).has(n):
			return (d as Dictionary)[n]
	return default_value


static func field(d: Variant, old: String, default_value: Variant = null) -> Variant:
	return pick(d, F.get(old, [old]), default_value)


static func prop(o: Object, names: Array) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	for n in names:
		var v: Variant = o.get(str(n))
		if v != null:
			return v
	return null


static func layer_on(layers: Dictionary, old: String, default_value: bool = false) -> bool:
	return bool(pick(layers, LAYER.get(old, [old]), default_value))


static func is_kind(value: Variant, old: String) -> bool:
	return str(value) in (KIND.get(old, [old]) as Array)


## Calls the first method an object has of the names; null if none.
static func call_any(o: Object, names: Array, args: Array = []) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	for n in names:
		if o.has_method(str(n)):
			return o.callv(str(n), args)
	return null


static func has_any(o: Object, names: Array) -> bool:
	if o == null or not is_instance_valid(o):
		return false
	for n in names:
		if o.has_method(str(n)):
			return true
	return false
