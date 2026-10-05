extends CanvasLayer
## A second click on the chosen country of the 3D globe (globe_layers.gd): a ring of the country's colour closes round
## it, the closed ring falls into itself like a drop, a splash leaps up from where it fell — and out of the splash the
## country's map opens: its regions (the game's provinces, from our ids map textures/earth/borders_ids.png), each a
## shade of the country's colour, their borders; hovering a region tells its name, area, coast, neighbours, its
## largest cities (config/cities.json) and the level of its networks and services (the game's region_nets). ✕ or Esc
## closes it. The map is drawn on a worker thread while the ring plays.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const RING_SEC := 0.55
const DROP_SEC := 0.4
const SPLASH_SEC := 0.55
const MAP_W := 880
const MAP_H := 560

var mod: PaxMod
var game: PaxGame
var _canvas: Control
var _t := -1.0                      # seconds into the animation (−1 — none)
var _centre := Vector2.ZERO
var _radius := 60.0
var _col := Color.WHITE
var _country := ""
var _drops: Array = []              # [offset from the centre, velocity]
var _anchor := Callable()           # the country's middle on the screen now (the Earth turns, the camera moves)
var _window: PanelContainer
var _job: MapJob
# Jobs still running on a worker thread that are not the current one any more (another click started a new map, or
# none was needed): kept here until their thread is done. The thread holds only a Callable, not the job — dropped by
# the last reference while running, the job was freed under the thread and the game crashed (a click on the chosen
# country again before its map was ready).
var _old_jobs: Array = []
var _cities: Array = []             # [lat, lon, pop, name_en, name_ru]
var _info: RichTextLabel
var _map_rect: TextureRect


## The country's map: our ids image cut to the country's latitudes and longitudes, its provinces shaded.
class MapJob extends RefCounted:
	var ids: Image
	var mine: Dictionary            # province id -> true
	var col: Color
	var lat0 := 0.0
	var lat1 := 0.0
	var lon0 := 0.0
	var lon1 := 0.0
	var w := 880
	var h := 560
	var task := -1
	var img: Image
	var grid := PackedInt32Array()  # the province id under each pixel of the map (for the hover)
	var stop := false               # a newer map was asked for: this one gives up (checked every row)

	func run() -> void:
		var iw := ids.get_width()
		var ih := ids.get_height()
		img = Image.create(w, h, false, Image.FORMAT_RGBA8)
		grid.resize(w * h)
		for y in h:
			if stop:
				return
			var lat := lerpf(lat1, lat0, (float(y) + 0.5) / float(h))
			var py := clampi(int((90.0 - lat) / 180.0 * ih), 0, ih - 1)
			for x in w:
				var lon := lerpf(lon0, lon1, (float(x) + 0.5) / float(w))
				var px := posmod(int((lon + 180.0) / 360.0 * iw), iw)
				var c := ids.get_pixel(px, py)
				grid[y * w + x] = roundi(c.r * 255.0) + roundi(c.g * 255.0) * 256
		for y in h:
			if stop:
				return
			for x in w:
				var id := grid[y * w + x]
				var out := Color(0.06, 0.08, 0.11) if id <= 0 else Color(0.16, 0.18, 0.21)
				if mine.has(id):
					var k := float(hash(id) % 1000) / 1000.0
					out = col.darkened(0.15 + 0.35 * k).lerp(col.lightened(0.15), 0.3 * (1.0 - k))
					var edge := false
					for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var ox: int = clampi(x + o.x, 0, w - 1)
						var oy: int = clampi(y + o.y, 0, h - 1)
						if grid[oy * w + ox] != id:
							edge = true
							break
					if edge:
						out = col.lightened(0.55)
				img.set_pixel(x, y, out)


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DCountryFocus"
	layer = 40
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_anim)
	add_child(_canvas)
	var raw: Variant = GameApi.json(m, "config/cities.json", {})
	_cities = (raw as Dictionary).get("cities", []) if raw is Dictionary else []


func start(g: PaxGame) -> void:
	game = g


## The ring round the country on the screen, then the drop, the splash and the map.
func play(country: String, col: Color, centre: Vector2, radius: float, anchor: Callable = Callable()) -> void:
	if game == null or country.is_empty():
		return
	_close_window()
	_country = country
	_col = col
	_centre = centre
	_anchor = anchor
	_radius = clampf(radius, 40.0, 420.0)
	_t = 0.0
	_drops.clear()
	_start_map()


func _process(delta: float) -> void:
	_reap_old()
	if _job != null and _job.task >= 0 and WorkerThreadPool.is_task_completed(_job.task):
		_map_ready()
	if _t < 0.0:
		return
	_t += delta
	# Pinned to the country, not to the screen: it moved off the country as the Earth turned or the camera went.
	if _anchor.is_valid():
		var now: Variant = _anchor.call()
		if now is Vector2 and (now as Vector2).x > -10000.0:
			_centre = now
	var splash_at := RING_SEC + DROP_SEC
	if _t >= splash_at and _drops.is_empty():
		for i in 14:
			var a := -PI * 0.5 + randf_range(-0.9, 0.9)
			_drops.append([Vector2.ZERO, Vector2(cos(a), sin(a)) * randf_range(180.0, 420.0)])
	for d in _drops:
		d[1] = (d[1] as Vector2) + Vector2(0, 900.0) * delta
		d[0] = (d[0] as Vector2) + (d[1] as Vector2) * delta
	if _t >= splash_at + SPLASH_SEC * 0.45 and not is_instance_valid(_window):
		_open_window()
	if _t >= splash_at + SPLASH_SEC:
		_t = -1.0
		_drops.clear()
	if _job != null and _job.task >= 0 and WorkerThreadPool.is_task_completed(_job.task):
		_map_ready()
	_reap_old()
	_canvas.queue_redraw()


func _draw_anim() -> void:
	if _t < 0.0:
		return
	if _t < RING_SEC:
		# The ring closes: an arc grows round the country.
		var k := ease(_t / RING_SEC, 0.6)
		_canvas.draw_arc(_centre, _radius, -PI * 0.5, -PI * 0.5 + TAU * k, 96, Color(_col, 0.35), 12.0, true)
		_canvas.draw_arc(_centre, _radius, -PI * 0.5, -PI * 0.5 + TAU * k, 96, _col.lightened(0.2), 4.0, true)
	elif _t < RING_SEC + DROP_SEC:
		# The closed ring falls into itself: smaller and thicker, a drop.
		var k := ease((_t - RING_SEC) / DROP_SEC, 2.4)
		var r := lerpf(_radius, 6.0, k)
		_canvas.draw_arc(_centre, r, 0.0, TAU, 96, _col.lightened(0.2), lerpf(4.0, 12.0, k), true)
		_canvas.draw_circle(_centre, lerpf(0.0, 7.0, k), Color(_col.lightened(0.3), k))
	else:
		# The splash: a ripple running out and the drops leaping up.
		var k := clampf((_t - RING_SEC - DROP_SEC) / SPLASH_SEC, 0.0, 1.0)
		_canvas.draw_arc(_centre, lerpf(8.0, _radius * 0.9, k), 0.0, TAU, 96, Color(_col.lightened(0.3), 1.0 - k), 3.0, true)
		for d in _drops:
			_canvas.draw_circle(_centre + (d[0] as Vector2), lerpf(5.0, 2.0, k), Color(_col.lightened(0.35), 1.0 - k * 0.8))


func _start_map() -> void:
	_retire_job()
	var earth: Variant = mod.get("earth")
	var ids: Image = (earth as Object).call("ids_image") as Image if earth is Object and is_instance_valid(earth) else null
	if ids == null:
		_job = null
		return
	var body := game.home_body()
	var mine := {}
	var lat0 := 90.0
	var lat1 := -90.0
	var lons: Array = []
	for id in game.provinces_of(body, _country):
		mine[int(id)] = true
		var d := game.province_direction(body, int(id)).normalized()
		var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
		lat0 = minf(lat0, lat)
		lat1 = maxf(lat1, lat)
		lons.append(rad_to_deg(atan2(d.x, d.z)))
	mine.erase(0)   # the sea
	if mine.is_empty():
		_job = null
		return
	# The longitudes round the country's middle (a country across the date line stays whole).
	var mid := float(lons[0])
	var lon0 := 0.0
	var lon1 := 0.0
	for l in lons:
		var rel := wrapf(float(l) - mid, -180.0, 180.0)
		lon0 = minf(lon0, rel)
		lon1 = maxf(lon1, rel)
	lon0 += mid
	lon1 += mid
	# A margin round it, and the map's shape: a degree of longitude is cos(latitude) of a degree of latitude.
	var pad := maxf(1.0, (lat1 - lat0) * 0.12)
	lat0 -= pad
	lat1 += pad
	lon0 -= pad
	lon1 += pad
	var k := cos(deg_to_rad((lat0 + lat1) * 0.5))
	var want := float(MAP_W) / float(MAP_H)
	var have := (lon1 - lon0) * k / maxf(lat1 - lat0, 0.01)
	if have < want:
		var grow := ((lat1 - lat0) * want / maxf(k, 0.05) - (lon1 - lon0)) * 0.5
		lon0 -= grow
		lon1 += grow
	else:
		var grow2 := ((lon1 - lon0) * k / want - (lat1 - lat0)) * 0.5
		lat0 -= grow2
		lat1 += grow2
	var job := MapJob.new()
	job.ids = ids
	job.mine = mine
	job.col = _col
	job.lat0 = clampf(lat0, -89.0, 89.0)
	job.lat1 = clampf(lat1, -89.0, 89.0)
	job.lon0 = lon0
	job.lon1 = lon1
	job.w = MAP_W
	job.h = MAP_H
	job.task = WorkerThreadPool.add_task(job.run, false, "pax_corpinc3d country map")
	_job = job


func _map_ready() -> void:
	WorkerThreadPool.wait_for_task_completion(_job.task)
	_job.task = -1
	if is_instance_valid(_map_rect) and _job.img != null:
		_map_rect.texture = ImageTexture.create_from_image(_job.img)


func _open_window() -> void:
	var view := _canvas.get_viewport_rect().size
	_window = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.11, 0.97)
	sb.border_color = Color(_col.lightened(0.2), 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 12
	sb.content_margin_bottom = 14
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 18
	_window.add_theme_stylebox_override("panel", sb)
	_window.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_window)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_window.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var title := Label.new()
	title.text = mod.tr_key("pax_corpinc3d_regions_title") % _country
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", _col.lightened(0.35))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var x := Button.new()
	x.text = "✕"
	x.focus_mode = Control.FOCUS_NONE
	x.custom_minimum_size = Vector2(34, 30)
	x.pressed.connect(_close_window)
	head.add_child(x)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	_map_rect = TextureRect.new()
	_map_rect.custom_minimum_size = Vector2(MAP_W, MAP_H) * minf(1.0, (view.x - 420.0) / float(MAP_W))
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_map_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_rect.gui_input.connect(_map_input)
	row.add_child(_map_rect)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.custom_minimum_size = Vector2(300, 0)
	_info.text = mod.tr_key("pax_corpinc3d_regions_hint")
	row.add_child(_info)
	if _job != null and _job.task < 0 and _job.img != null:
		_map_rect.texture = ImageTexture.create_from_image(_job.img)
	# Out of the splash: from a dot at the splash, growing to its place in the middle of the screen.
	_window.reset_size()
	var sz := _window.get_combined_minimum_size()
	_window.size = sz
	_window.position = (view - sz) / 2.0
	_window.pivot_offset = _centre - _window.position
	_window.scale = Vector2(0.05, 0.05)
	_window.modulate.a = 0.0
	var tw := _window.create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_window, "scale", Vector2.ONE, 0.45)
	tw.tween_property(_window, "modulate:a", 1.0, 0.3)


func _close_window() -> void:
	if is_instance_valid(_window):
		_window.queue_free()
	_window = null
	_map_rect = null
	_info = null


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k != null and k.pressed and k.keycode == KEY_ESCAPE and is_instance_valid(_window):
		_close_window()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if _job != null and _job.task >= 0:
		_job.stop = true
		WorkerThreadPool.wait_for_task_completion(_job.task)
		_job.task = -1
	for j in _old_jobs:
		if (j as MapJob).task >= 0:
			WorkerThreadPool.wait_for_task_completion((j as MapJob).task)
	_old_jobs.clear()


## The current job, if its thread still runs, is kept alive until it ends (never freed under the thread).
func _retire_job() -> void:
	if _job != null and _job.task >= 0:
		_job.stop = true
		_old_jobs.append(_job)
	_job = null


## The old jobs whose threads have ended: waited (the pool frees the task) and let go.
func _reap_old() -> void:
	for i in range(_old_jobs.size() - 1, -1, -1):
		var j: MapJob = _old_jobs[i]
		if WorkerThreadPool.is_task_completed(j.task):
			WorkerThreadPool.wait_for_task_completion(j.task)
			_old_jobs.remove_at(i)


## Hovering the map: the region under the cursor and what is known of it.
var _hover_id := -1


func _map_input(e: InputEvent) -> void:
	if not (e is InputEventMouseMotion) or _job == null or _job.img == null or _job.task >= 0:
		return
	var p := (e as InputEventMouseMotion).position / _map_rect.size * Vector2(MAP_W, MAP_H)
	var x := clampi(int(p.x), 0, MAP_W - 1)
	var y := clampi(int(p.y), 0, MAP_H - 1)
	var id := _job.grid[y * MAP_W + x]
	if id == _hover_id:
		return
	_hover_id = id
	if id <= 0 or not _job.mine.has(id):
		_info.text = mod.tr_key("pax_corpinc3d_regions_hint")
		return
	_info.text = _describe(id)


func _describe(id: int) -> String:
	var body := game.home_body()
	var p := game.province(body, id)
	var lines: PackedStringArray = []
	lines.append("[font_size=18][b]%s[/b][/font_size]" % str(p.get("name", "#%d" % id)))
	lines.append(mod.tr_key("pax_corpinc3d_regions_area") % _num(float(p.get("area_km2", 0.0))))
	lines.append(mod.tr_key("pax_corpinc3d_regions_coast_yes" if bool(p.get("coastal", false)) else "pax_corpinc3d_regions_coast_no"))
	lines.append(mod.tr_key("pax_corpinc3d_regions_neighbours") % (p.get("neighbours", []) as Array).size())
	# The largest cities whose place falls in this region.
	var ids: Image = _job.ids
	var big: Array = []
	for c in _cities:
		var r: Array = c
		var px := posmod(int((float(r[1]) + 180.0) / 360.0 * ids.get_width()), ids.get_width())
		var py := clampi(int((90.0 - float(r[0])) / 180.0 * ids.get_height()), 0, ids.get_height() - 1)
		var col := ids.get_pixel(px, py)
		if roundi(col.r * 255.0) + roundi(col.g * 255.0) * 256 == id:
			big.append(r)
			if big.size() >= 3:
				break
	if not big.is_empty():
		lines.append("")
		lines.append("[b]%s[/b]" % mod.tr_key("pax_corpinc3d_regions_cities"))
		var ru := TranslationServer.get_locale().begins_with("ru")
		for r in big:
			lines.append("• %s — %s" % [str(r[5]) if ru and (r as Array).size() > 5 else str(r[4]), _num(float(r[2]))])
	# The game's levels of the region's networks and services.
	var earth: Variant = mod.get("earth")
	var mat: Variant = (earth as Object).get("_mat") if earth is Object and is_instance_valid(earth) else null
	var nets: Variant = (mat as ShaderMaterial).get_shader_parameter("region_nets") if mat is ShaderMaterial else null
	if nets is Texture2D:
		var img := (nets as Texture2D).get_image()
		if img != null and id < img.get_width():
			if img.is_compressed():
				img.decompress()
			var n0 := img.get_pixel(id, 0)
			var n1 := img.get_pixel(id, 1) if img.get_height() > 1 else Color(0, 0, 0, 0)
			lines.append("")
			lines.append("[b]%s[/b]" % mod.tr_key("pax_corpinc3d_regions_nets"))
			var rows := [["roads", n0.r], ["rail", n0.b], ["comms", n0.g], ["power", n0.a], ["safety", n1.r], ["health", n1.g], ["education", n1.b]]
			for row in rows:
				lines.append("%s: %d%%" % [mod.tr_key("pax_corpinc3d_regions_" + str(row[0])), roundi(float(row[1]) * 100.0)])
	return "\n".join(lines)


func _num(x: float) -> String:
	if x >= 1e6:
		return "%.1f %s" % [x / 1e6, mod.tr_key("pax_corpinc3d_regions_mln")]
	if x >= 1e3:
		return "%.0f %s" % [x / 1e3, mod.tr_key("pax_corpinc3d_regions_thousand")]
	return "%.0f" % x
