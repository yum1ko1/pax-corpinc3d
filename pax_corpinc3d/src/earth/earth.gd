extends Node
## Earth HD: the Earth from orbit with real maps (NASA). The game's globe stays the game's — its body, its material,
## its sun, its cloud shell — only what it is drawn with changes:
##   the Earth's material gets shaders/earth.gdshader (the game's planet shader + night lights, relief, a sharp sea,
##   cloud shadows, a softer atmosphere), the sphere a finer mesh (a round limb up close);
##   the clouds are a shell of its own (shaders/earth_clouds.gdshader), the game's cloud shells are hidden;
##   a new shell a little larger than the planet (shaders/earth_air.gdshader) glows at the limb.
## Each map is used only if its file is in the mod (config/earth.json «maps»); without any the look is the game's
## planet with the new atmosphere. Switching off (setting «earth_hd») gives everything back as it was.
## The game may rebuild the Earth (a loaded save, a reload of the data): the check every half second puts it on again.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")   # Main's methods and the mod's JSON, game 0.24
const V := preload("res://mods/pax_corpinc3d/src/core/v024.gd")             # game 0.24's English keys
const BODY := "Земля"
const Terrain := preload("res://mods/pax_corpinc3d/src/earth/terrain.gd")

var mod: PaxMod
var game: PaxGame
var enabled := true
var cfg: Dictionary = {}
var _shader: Shader
var _cloud_shader: Shader
var _air_shader: Shader
var _tex: Dictionary = {}          # uniform name -> Texture2D (with mipmaps), loaded once
var _loaded := false
var _mat: ShaderMaterial           # the Earth's material we changed, and what it had
var _orig_shader: Shader
var _node: MeshInstance3D
var _orig_mesh: Mesh
var _cloud: MeshInstance3D
var _cloud_mat: ShaderMaterial
var _game_clouds: Array = []        # the game's cloud shells, kept hidden while ours is on
var _air: MeshInstance3D
var _air_mat: ShaderMaterial
var _check := 0.0
var _terrain: Node3D                # the ground in 3D (terrain.gd), a child of the Earth's node
var _height: Image                  # the height map, for the buildings' footing (surface_radius)
var _why := ""                     # why Earth HD is not on the planet now ("" — it is)
var _why_logged := "-"
var political := false             # the political map (set_political)
var show_zones := true             # the economic zones' tint («Слои глобуса»: zones)
var show_clouds := true            # our cloud shell («Слои глобуса»: clouds)
var selected := ""                 # the country clicked on the globe (select_country)
var _focus := ""                   # the country outlined on the globe (focus_country)
var _big: Dictionary = {}           # uniform name -> BigMap being read on a worker thread (config «big_maps»)
var _orig_albedo: Variant = null    # the game's own colour map, given back on restore()


## A map too big for the main thread (NASA day 16384 x 8192, night 12288 x 6144): decoded, mipmapped and compressed
## for the video card (S3TC: 4 bits a pixel, ~85 MB instead of ~700 MB for the day map) on a worker thread; the
## game's own map stays until it is ready.
class BigMap extends RefCounted:
	var bytes: PackedByteArray
	var ext := ""
	var compress := true
	var file := ""
	var task := -1
	var img: Image

	func run() -> void:
		var im := Image.new()
		var err := im.load_png_from_buffer(bytes) if ext == "png" else im.load_jpg_from_buffer(bytes)
		bytes = PackedByteArray()
		if err != OK or im.is_empty():
			return
		im.generate_mipmaps()
		if compress:
			im.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		img = im


func setup(m: PaxMod) -> void:
	mod = m
	var raw: Variant = GameApi.json(m, "config/earth.json", {})
	cfg = raw if raw is Dictionary else {}
	enabled = bool(m.get_setting("earth_hd", true))
	political = bool(m.get_setting("political", false))
	_shader = m.shader("shaders/earth.gdshader")
	_cloud_shader = m.shader("shaders/earth_clouds.gdshader")
	_air_shader = m.shader("shaders/earth_air.gdshader")


func _ready() -> void:
	name = "PaxCorpInc3DEarth"
	process_mode = Node.PROCESS_MODE_ALWAYS


func start(g: PaxGame) -> void:
	restore()
	game = g


## The air's glow at the rim (the shell earth_air.gdshader and the rim light in the ground's shader): off — the planet
## without the blue rim and sky (setting «air_glow»).
func set_air(on: bool) -> void:
	mod.set_setting("air_glow", on)
	_apply_air()


func _apply_air() -> void:
	var on := bool(mod.get_setting("air_glow", true))
	if is_instance_valid(_air):
		_air.visible = on
	if is_instance_valid(_mat) and _mat.shader == _shader:
		_mat.set_shader_parameter("air_glow", float((cfg.get("earth", {}) as Dictionary).get("air_glow", 0.7)) if on else 0.0)


func set_enabled(on: bool) -> void:
	enabled = on
	mod.set_setting("earth_hd", on)
	if not on:
		restore()
	_check = 1.0


## The country the player is looking at (its card, its statistics): its border is outlined on the globe. "" — none.
## What the 3D networks on the ground need (src/layers/roads3d.gd): the Earth's node (its own space), the height map
## and its exaggeration, the sun. null / defaults while Earth HD is off.
func node() -> MeshInstance3D:
	return _node if is_instance_valid(_node) and is_instance_valid(_mat) and _mat.shader == _shader else null


## The economic zones on the globe while Pax Corporations' layer «Экономические зоны» is on (its zone_colours():
## {country: colour}): a table «province id → its owner's zone colour» for the shader (zone_pal), remade every 3 s
## (owners change, countries join and leave). Engine meta «pax_corpinc3d_zones» tells Pax Corporations the land is
## tinted here (it then draws only the zones' names on the globe, not its discs).
var _zones_t := 0.0
var _zones_img: Image
var _zones_tex: ImageTexture
var _zones_on := false


func _update_zones() -> void:
	if not is_instance_valid(_mat) or _mat.shader != _shader or game == null:
		return
	var api: Variant = Engine.get_meta("pax_corporations_api") if Engine.has_meta("pax_corporations_api") else null
	var cols: Dictionary = {}
	if api is Object and is_instance_valid(api) and (api as Object).has_method("zone_colours"):
		var got: Variant = (api as Object).call("zone_colours")
		cols = got if got is Dictionary else {}
	if not show_zones:
		cols = {}
	var pal: Variant = _mat.get_shader_parameter("region_pal")
	var n := (pal as Texture2D).get_width() if pal is Texture2D else 0
	var on := not cols.is_empty() and n > 1
	if not on:
		if _zones_on:
			_zones_on = false
			_mat.set_shader_parameter("use_zones", 0.0)
		Engine.set_meta(&"pax_corpinc3d_zones", false)
		return
	if _zones_img == null or _zones_img.get_width() != n:
		_zones_img = Image.create(n, 1, false, Image.FORMAT_RGBA8)
		_zones_tex = null
	var body := game.home_body()
	for id in range(1, n):
		var owner := game.province_owner(body, id)
		var c: Variant = cols.get(owner) if not owner.is_empty() else null
		_zones_img.set_pixel(id, 0, Color(c as Color, 1.0) if c is Color else Color(0, 0, 0, 0))
	if _zones_tex == null:
		_zones_tex = ImageTexture.create_from_image(_zones_img)
	else:
		_zones_tex.update(_zones_img)
	_mat.set_shader_parameter("zone_pal", _zones_tex)
	_mat.set_shader_parameter("use_zones", 1.0)
	_zones_on = true
	Engine.set_meta(&"pax_corpinc3d_zones", true)


## The Earth turned by the game's time, as the real one (config «spin»: true): one turn a game day, the sun over
## Greenwich at noon UTC (its height over the equator is the game's: where its star stands). The game only
## turned it for the look (0.03 rad/s, a turn a day only during a time skip): its own turn is undone every frame and
## the right one set. The day's fraction: during a skip the skip's clock; otherwise measured from how often the day
## changes at the current speed (no turning on a pause). A spin by hand (the game's «импульс») stays as an offset.
var _day_seen := -1
var _day_at := 0.0                  # seconds (real) when the day changed
var _day_len := 0.0                 # seconds the last day took
var _spin_hand := 0.0               # radians the player turned it by hand
var _star: Node3D


func _spin(delta: float) -> void:
	if not bool(cfg.get("spin", true)) or not is_instance_valid(_node) or game == null:
		return
	var main: Object = game.main
	var now := Time.get_ticks_msec() / 1000.0
	var day := float(game.day())
	var frac := 0.0
	var skip: Variant = main.get("окно_перемотки")
	if skip is Object and is_instance_valid(skip) and str((skip as Object).get("состояние")) == "загрузка" and (skip as Object).has_method("день_на_часах_точно"):
		var exact := float((skip as Object).call("день_на_часах_точно"))
		day = floorf(exact)
		frac = exact - day
	else:
		if int(day) != _day_seen:
			if _day_seen >= 0 and int(day) == _day_seen + 1:
				_day_len = now - _day_at
			_day_seen = int(day)
			_day_at = now
		var running := bool(main.get("автоигра")) if main.get("автоигра") != null else true
		if not running:
			_day_at = now - _paused_frac * _day_len   # on a pause the clock stands: it goes on from there after
			frac = _paused_frac
		elif _day_len > 0.0:
			frac = clampf((now - _day_at) / _day_len, 0.0, 0.999)
		_paused_frac = frac
	_spin_hand += float(main.get("импульс")) * delta if main.get("импульс") != null else 0.0
	var star := _find_star()
	if star == null:
		return
	var b := _node.global_transform.basis.orthonormalized()
	var sun_local := (b.inverse() * (star.global_position - _node.global_position)).normalized()
	var lon := deg_to_rad((12.0 - frac * 24.0) * 15.0) + _spin_hand   # the sub-solar longitude
	var turn := atan2(sun_local.x, sun_local.z) - lon
	turn = wrapf(turn, -PI, PI)
	if absf(turn) > 1e-5:
		_node.rotate_object_local(Vector3.UP, turn)


var _paused_frac := 0.0


func _find_star() -> Node3D:
	if is_instance_valid(_star):
		return _star
	for n in game.body_names():
		var b: Dictionary = game.body(n)
		if str(V.pick(b, ["род", "kind", "type"], "")) in ["звезда", "star"]:
			var node: Variant = V.pick(b, ["узел", "node"])
			if node is Node3D and is_instance_valid(node):
				_star = node
				return _star
	return null


## The provinces' ids as an image (textures/earth/borders_ids.png: R + G × 256 a pixel, 0 — the sea), read once —
## roads3d.gd looks provinces up in it on worker threads (the game's book is not asked off the main thread).
var _ids_img: Image


func ids_image() -> Image:
	if _ids_img == null and _tex.has("borders_ids"):
		_ids_img = (_tex["borders_ids"] as Texture2D).get_image()
		if _ids_img != null and _ids_img.is_compressed():
			_ids_img.decompress()
	return _ids_img


## The height map as an image while the 3D ground is on (towns.gd reads it on a worker thread: the ground under the
## houses); null — the ground is the sphere.
func height_image() -> Image:
	return _height if is_instance_valid(_terrain) else null


func height_texture() -> Texture2D:
	return _tex.get("height_map") if is_instance_valid(_terrain) else null


func height_exag() -> float:
	return float((cfg.get("earth", {}) as Dictionary).get("height_exag", 3.5))


## The political map (as in Terra Invicta): the countries filled with their colours, the borders thicker and fully in
## the country's colour; off — the real Earth with thin borders (config/earth.json «earth»). Kept in the settings.
func set_political(on: bool) -> void:
	political = on
	mod.set_setting("political", on)
	_apply_political()


func _apply_political() -> void:
	if not is_instance_valid(_mat) or _mat.shader != _shader:
		return
	var e: Dictionary = cfg.get("earth", {})
	var p: Dictionary = cfg.get("political", {})
	for key in p.keys():
		if str(key).begins_with("_"):
			continue
		_mat.set_shader_parameter(str(key), p[key] if political else e.get(key, p[key]))


## For «inc3d probe»: is Earth HD on the planet, and what the game gave.
func status() -> String:
	var attached := is_instance_valid(_mat) and _mat.shader == _shader
	var line := "Earth HD: enabled %s, attached %s" % [str(enabled), str(attached)]
	if not _why.is_empty():
		line += " (" + _why + ")"
	line += "; the game's planet shader %s; terrain %s; maps %s" % [
		_orig_shader.resource_path if _orig_shader != null else "?", str(is_instance_valid(_terrain)), str(_tex.keys())]
	return line


func sun_dir() -> Vector3:
	var v: Variant = _mat.get_shader_parameter("sun_dir") if is_instance_valid(_mat) else null
	return v if v is Vector3 else Vector3.FORWARD


## Called by the windows of the other mods (Engine meta «pax_corpinc3d_earth»: focus_country(name)).
func focus_country(country: String) -> void:
	_focus = country
	_apply_focus()


## The country clicked on the globe (globe_layers.gd): lit apart from the focus outline. "" — none.
func select_country(country: String) -> void:
	selected = country
	_apply_focus()


func _faction_color(country: String) -> Variant:
	if country.is_empty() or game == null:
		return null
	for f in game.factions() + [game.player_faction()]:
		var fc: Variant = V.pick(f, ["colour", "цвет"])
		if f is Dictionary and str(V.pick(f, ["name", "имя"], "")) == country and fc is Color:
			return fc
	return null


func _apply_focus() -> void:
	if not is_instance_valid(_mat):
		return
	var sc: Variant = _faction_color(selected)
	_mat.set_shader_parameter("sel_on", 1.0 if sc is Color else 0.0)
	if sc is Color:
		var c2: Color = sc
		_mat.set_shader_parameter("sel_color", Vector3(int(c2.r * 255.0) / 255.0, int(c2.g * 255.0) / 255.0, int(c2.b * 255.0) / 255.0))
	var col: Variant = null
	if not _focus.is_empty() and game != null:
		for f in game.factions() + [game.player_faction()]:
			var fc: Variant = V.pick(f, ["colour", "цвет"])
			if f is Dictionary and str(V.pick(f, ["name", "имя"], "")) == _focus and fc is Color:
				col = fc
	_mat.set_shader_parameter("focus_on", 1.0 if col is Color else 0.0)
	if col is Color:
		var c: Color = col
		# The same bytes the game writes into region_pal (int(c * 255)), read back as the shader sees them.
		_mat.set_shader_parameter("focus_color", Vector3(int(c.r * 255.0) / 255.0, int(c.g * 255.0) / 255.0, int(c.b * 255.0) / 255.0))


## The ground's radius at a direction of the Earth's local space (1 — the sea level): where the buildings stand.
## The same height and exaggeration the shader uses (height_map, height_exag); 1 without the 3D ground.
func surface_radius(dir: Vector3) -> float:
	if _height == null or not is_instance_valid(_terrain):
		return 1.0
	var n := dir.normalized()
	var w := _height.get_width()
	var h := _height.get_height()
	var u := atan2(n.x, n.z) / TAU + 0.5
	var v := acos(clampf(n.y, -1.0, 1.0)) / PI
	var fx := u * w - 0.5
	var fy := v * h - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var ax := fx - x0
	var ay := fy - y0
	var top := lerpf(_h16(x0, y0, w, h), _h16(x0 + 1, y0, w, h), ax)
	var bottom := lerpf(_h16(x0, y0 + 1, w, h), _h16(x0 + 1, y0 + 1, w, h), ax)
	var exag := float((cfg.get("earth", {}) as Dictionary).get("height_exag", 3.5))
	return 1.0 + lerpf(top, bottom, ay) * 0.0010046 * exag


func _h16(x: int, y: int, w: int, h: int) -> float:
	var c := _height.get_pixel(posmod(x, w), clampi(y, 0, h - 1))
	return (roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0)) / 65535.0


## Which maps are there (for the window and the console): uniform name -> true/false.
func maps_found() -> Dictionary:
	_load_maps()
	var out := {}
	for key in (cfg.get("maps", {}) as Dictionary).keys():
		out[key] = _tex.has(key)
	return out


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_body(delta)
	GameApi.perf("corpinc3d.earth.process", t0)


func _process_body(delta: float) -> void:
	if game == null or not is_instance_valid(game.main) or not enabled or _shader == null:
		return
	_check += delta
	if not _big.is_empty():
		_poll_big()
	_spin(delta)
	_zones_t -= delta
	if _zones_t <= 0.0:
		_zones_t = 3.0
		_update_zones()
	# The game gives the planet its own shader back now and then (the menu, the choice screen): put ours back on the
	# very next frame, not in half a second — the rim blinked between the game's violet one and ours.
	var reverted := is_instance_valid(_mat) and _mat.shader != _shader
	if reverted:
		_fights["shader back"] = int(_fights.get("shader back", 0)) + 1
	_tell_fights(delta)
	if _check >= 0.5 or reverted:
		_check = 0.0
		_attach()
	_follow()


# ---------- putting it on ----------

func _attach() -> void:
	var body: Dictionary = game.body(BODY)
	if body.is_empty():
		return
	var mat: Variant = V.pick(body, ["мат", "material", "mat"])
	var node0: Variant = V.pick(body, ["узел", "node"])
	if not (mat is ShaderMaterial) and node0 is MeshInstance3D and is_instance_valid(node0):
		mat = (node0 as MeshInstance3D).material_override   # the planet's material on its node, not in the record
	_why = "" if mat is ShaderMaterial and _shader != null else ("no planet ShaderMaterial (body keys: %s)" % ", ".join(PackedStringArray(body.keys().map(func(k: Variant) -> String: return str(k)))) if _shader != null else "shaders/earth.gdshader did not load")
	if _why != _why_logged:
		_why_logged = _why
		if _why.is_empty():
			mod.log_info("Earth HD: on the planet")
		else:
			mod.log_warning("Earth HD not attached: " + _why)
	if mat is ShaderMaterial and (mat as ShaderMaterial).shader != _shader:
		_load_maps()
		_mat = mat
		_orig_shader = _mat.shader
		_mat.shader = _shader
		_set_maps(_mat, ["night_map", "relief_map", "water_map", "clouds_map", "borders_ids", "borders_dist", "height_map", "detail_map", "urban_map", "map_albedo"])
		_set_params(_mat, cfg.get("earth", {}))
		_apply_air()
		_apply_focus()
		_apply_political()
	var node: Variant = V.pick(body, ["узел", "node"])
	if node is MeshInstance3D and is_instance_valid(node):
		var mi: MeshInstance3D = node
		if mi != _node:
			_node = mi
			_orig_mesh = mi.mesh
		var tcfg: Dictionary = cfg.get("terrain", {})
		if _tex.has("height_map") and bool(tcfg.get("enabled", true)) and is_instance_valid(_mat):
			# The ground in 3D: chunks with levels of detail draw the planet; its own sphere is hidden (the game
			# itself leaves a body without a mesh when a mod gives it a model).
			if not is_instance_valid(_terrain) or _terrain.get_parent() != mi:
				if is_instance_valid(_terrain):
					_terrain.queue_free()
				_terrain = Terrain.new()
				_terrain.call("setup", _mat, tcfg)
				mi.add_child(_terrain)
				# The buildings stand on the ground now: they are placed again at its heights.
				var globe: Variant = mod.get("globe")
				if globe is Object and is_instance_valid(globe) and (globe as Object).has_method("rebuild"):
					(globe as Object).call("rebuild")
			if mi.mesh != null:
				_fights["mesh back"] = int(_fights.get("mesh back", 0)) + 1
			mi.mesh = null
		else:
			var seg := Vector2i(int(cfg.get("earth_segments", 512)), int(cfg.get("earth_rings", 256)))
			if mi.mesh != null and not (mi.mesh is SphereMesh and (mi.mesh as SphereMesh).radial_segments == seg.x):
				mi.mesh = _sphere(seg)
		if not is_instance_valid(_air) or _air.get_parent() != mi:
			_make_air(mi)
	# The clouds are our own shell (a child of the Earth's node): the game's shells — in the record or found by name —
	# are hidden. Wearing our shader on the game's shell broke whenever the game gave it a new material: lit by the
	# scene's background they glowed violet and orange on the night side.
	var cl: Variant = V.pick(body, ["облака", "clouds"])
	var shells := _find_clouds(node)
	if cl is MeshInstance3D and is_instance_valid(cl) and not shells.has(cl):
		shells.append(cl)
	if shells.size() != _game_clouds.size():
		mod.log_info("Earth HD: the game's cloud shells hidden: %d" % shells.size())
	_game_clouds = shells
	if node is MeshInstance3D and is_instance_valid(node) and _cloud_shader != null and _tex.has("clouds_map"):
		if not is_instance_valid(_cloud) or _cloud.get_parent() != node:
			_make_clouds(node as MeshInstance3D)


func _make_clouds(parent: MeshInstance3D) -> void:
	if is_instance_valid(_cloud):
		_cloud.queue_free()
	_cloud = MeshInstance3D.new()
	_cloud.name = "PaxCorpInc3DClouds"
	var r := float(cfg.get("cloud_radius", 1.008))
	var s := _sphere(Vector2i(int(cfg.get("cloud_segments", 256)), int(cfg.get("cloud_rings", 128))))
	s.radius = r
	s.height = r * 2.0
	_cloud.mesh = s
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = _cloud_shader
	_cloud_mat.render_priority = 1   # between the ground and the air (the see-through shells share a centre)
	_set_maps(_cloud_mat, ["clouds_map"])
	_set_params(_cloud_mat, cfg.get("clouds", {}))
	_cloud.material_override = _cloud_mat
	_cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(_cloud)
	mod.log_info("Earth HD: own cloud shell at %.3f R" % r)


func _make_air(parent: MeshInstance3D) -> void:
	if is_instance_valid(_air):
		_air.queue_free()
	if _air_shader == null:
		return
	_air = MeshInstance3D.new()
	_air.name = "PaxCorpInc3DAir"
	var r := float(cfg.get("air_radius", 1.025))
	var s := _sphere(Vector2i(192, 96))
	s.radius = r
	s.height = r * 2.0
	_air.mesh = s
	_air_mat = ShaderMaterial.new()
	_air_mat.shader = _air_shader
	_set_params(_air_mat, cfg.get("air", {}))
	_air_mat.set_shader_parameter("shell", r)
	# A fixed order among the planet's see-through shells (the air over the clouds over the ground): sorted by the
	# distance of their centres — the same point — they swapped places from frame to frame and the rim blinked.
	_air_mat.render_priority = 2
	_air.material_override = _air_mat
	_fights["air made"] = int(_fights.get("air made", 0)) + 1
	_air.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(_air)
	_apply_air()


## The game's cloud shells by their names, near the planet's node (game 0.24 keeps none in the planet's record).
static func _find_clouds(node: Variant) -> Array:
	var out: Array = []
	if not (node is Node) or not is_instance_valid(node):
		return out
	# Under the Earth's node at any depth; beside it (its parent holds every body) only its direct neighbours.
	var cands: Array = (node as Node).find_children("*", "MeshInstance3D", true, false)
	if (node as Node).get_parent() != null:
		cands += (node as Node).get_parent().get_children().filter(func(c: Node) -> bool: return c is MeshInstance3D)
	for ch in cands:
		if _is_cloud_shell(ch as MeshInstance3D) and not out.has(ch):
			out.append(ch)
	return out


## The game's cloud shell: by its name, or (game 0.24 renamed its nodes) by its shader — clouds.gdshader.
static func _is_cloud_shell(mi: MeshInstance3D) -> bool:
	var nm := str(mi.name).to_lower()
	if nm.begins_with("paxcorpinc3d"):
		return false
	if nm.contains("cloud") or nm.contains("облак"):
		return true
	var mats: Array = [mi.material_override]
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		mats.append(mi.mesh.surface_get_material(0))
	for m in mats:
		if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
			var path := (m as ShaderMaterial).shader.resource_path.to_lower()
			if path.contains("cloud") or path.contains("облак"):
				return true
	return false


## How often the game took the planet back (its shader, its sphere) or the air was made anew — the blinking rim's
## suspects; told to the journal every 10 s while any happen.
var _fights: Dictionary = {}
var _fights_t := 0.0


func _tell_fights(delta: float) -> void:
	_fights_t += delta
	if _fights_t < 10.0:
		return
	_fights_t = 0.0
	if _fights.is_empty():
		return
	mod.log_info("Earth HD: in 10 s — %s" % ", ".join(_fights.keys().map(func(k: Variant) -> String: return "%s ×%d" % [k, int(_fights[k])])))
	_fights.clear()


## Every frame: the air's sun and the clouds' turn against the ground (for the clouds' shadows).
func _follow() -> void:
	if not is_instance_valid(_mat):
		return
	var sun: Variant = _mat.get_shader_parameter("sun_dir")
	if is_instance_valid(_air) and sun is Vector3:
		_air_mat.set_shader_parameter("sun_dir", sun)
		_air_mat.set_shader_parameter("atmo_visible", float(_mat.get_shader_parameter("atmo_visible")) if _mat.get_shader_parameter("atmo_visible") != null else 1.0)
	for g in _game_clouds:
		if is_instance_valid(g) and (g as Node3D).visible:
			(g as Node3D).visible = false
	_fade_clouds()
	if is_instance_valid(_cloud) and is_instance_valid(_node):
		# The clouds drift slowly round the axis; the sun of the Earth's space in the shell's own.
		_cloud.rotate_y(float((cfg.get("clouds", {}) as Dictionary).get("drift", 0.003)) * get_process_delta_time())
		var b := _cloud.transform.basis.orthonormalized().inverse()
		_mat.set_shader_parameter("cloud_basis", b)   # a direction in the Earth's space → the shell's
		if sun is Vector3:
			_cloud_mat.set_shader_parameter("sun_dir", b * (sun as Vector3))
		var av: Variant = _mat.get_shader_parameter("atmosphere")
		if av != null:
			_cloud_mat.set_shader_parameter("atmosphere", float(av))


## Coming close the clouds give way (they covered the land the camera came down to see): full from «fade_far»
## Earth radii from the centre, none at «fade_near» (config earth.json «clouds»); their shadows on the ground too.
var _clouds_gone := false


func _fade_clouds() -> void:
	# The camera that draws now (the game's, or the descent's when it has its own): the game's alone stayed far
	# while the view came down, and the clouds never gave way.
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null and game != null:
		cam = game.camera()
	if cam == null or not is_instance_valid(_node) or not cam.is_inside_tree():
		return
	var ccfg: Dictionary = cfg.get("clouds", {})
	var r := maxf(_node.global_transform.basis.get_scale().x, 1e-6)
	var d := cam.global_position.distance_to(_node.global_position) / r
	var fade := smoothstep(float(ccfg.get("fade_near", 1.45)), float(ccfg.get("fade_far", 2.2)), d)
	var gone := fade <= 0.02
	if gone != _clouds_gone:
		_clouds_gone = gone
		mod.log_info("Earth HD: clouds %s at %.2f R from the centre" % ["gone" if gone else "back", d])
	if is_instance_valid(_cloud):
		_cloud.visible = show_clouds and fade > 0.02   # gone close in; off by the «clouds» switch
		_cloud_mat.set_shader_parameter("near_fade", fade)
	_mat.set_shader_parameter("cloud_shadow", float((cfg.get("earth", {}) as Dictionary).get("cloud_shadow", 0.35)) * fade)


static func _sphere(seg: Vector2i) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = seg.x
	s.rings = seg.y
	return s


# ---------- maps ----------

## The maps listed in config/earth.json «maps» (uniform → file in the mod), the ones that are there, with mipmaps
## (a raw picture from a mod comes without them — far away the map would shimmer).
func _load_maps() -> void:
	if _loaded:
		return
	_loaded = true
	var maps: Dictionary = cfg.get("maps", {})
	var have := {}
	for key in maps.keys():
		var dir := str(maps[key]).get_base_dir()
		if not have.has(dir):
			have[dir] = mod.list_files(dir)
	var big: Array = cfg.get("big_maps", [])
	for key in maps.keys():
		var file := str(maps[key])
		if not (file.get_file() in (have[file.get_base_dir()] as PackedStringArray)):
			continue   # the map is not in the mod (yet): that layer stays off
		if str(key) in big:
			_start_big(str(key), file)
			continue
		var t: Texture2D = mod.texture(file)
		if t == null:
			continue
		var img := t.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		if not img.has_mipmaps() and not (str(key) in (cfg.get("no_mipmaps", []) as Array)):
			img.generate_mipmaps()   # ids and the border distance are read exactly, no mipmaps
		_tex[str(key)] = ImageTexture.create_from_image(img)
		if str(key) == "height_map":
			_height = img
		mod.log_info("Earth HD: %s %dx%d" % [file, img.get_width(), img.get_height()])


func _start_big(key: String, file: String) -> void:
	if _big.has(key):
		return   # already being read on a worker thread: a second job would drop the first one under its thread
	var job := BigMap.new()
	job.bytes = mod.read_bytes(file)
	if job.bytes.is_empty():
		return
	job.ext = file.get_extension().to_lower()
	job.file = file
	job.compress = bool(cfg.get("compress_big", true)) and RenderingServer.has_os_feature("s3tc")
	if Engine.has_meta(&"pax_threads") and not bool(Engine.get_meta(&"pax_threads")):
		job.run()   # Pax Corptimizer switched the threads off: here and now
		job.task = WorkerThreadPool.add_task(func() -> void: pass)
	else:
		job.task = WorkerThreadPool.add_task(job.run, false, "pax_corpinc3d " + file.get_file())
	_big[key] = job


## A big map is ready: on the planet from now on.
func _poll_big() -> void:
	for key in _big.keys():
		var job: BigMap = _big[key]
		if not WorkerThreadPool.is_task_completed(job.task):
			continue
		WorkerThreadPool.wait_for_task_completion(job.task)
		_big.erase(key)
		if job.img == null:
			mod.log_warning("Earth HD: %s could not be read" % job.file)
			continue
		_tex[str(key)] = ImageTexture.create_from_image(job.img)
		mod.log_info("Earth HD: %s %dx%d%s" % [job.file, job.img.get_width(), job.img.get_height(), " (S3TC)" if job.img.is_compressed() else ""])
		if is_instance_valid(_mat) and _mat.shader == _shader:
			_set_maps(_mat, [key])


func _exit_tree() -> void:
	for key in _big.keys():
		WorkerThreadPool.wait_for_task_completion((_big[key] as BigMap).task)
	_big.clear()


func _set_maps(m: ShaderMaterial, keys: Array) -> void:
	for key in keys:
		var k := str(key)
		var flag := str((cfg.get("flags", {}) as Dictionary).get(k, ""))
		if k == "map_albedo" and _tex.has(k) and _orig_albedo == null:
			_orig_albedo = m.get_shader_parameter(k)   # the game's own, for restore()
		if _tex.has(k):
			m.set_shader_parameter(k, _tex[k])
		if not flag.is_empty():
			m.set_shader_parameter(flag, 1.0 if _tex.has(k) else 0.0)


static func _set_params(m: ShaderMaterial, params: Variant) -> void:
	if not (params is Dictionary):
		return
	for k in (params as Dictionary).keys():
		if str(k).begins_with("_"):
			continue
		var v: Variant = (params as Dictionary)[k]
		if v is Array and ((v as Array).size() == 3 or (v as Array).size() == 4):
			var a: Array = v
			m.set_shader_parameter(str(k), Color(float(a[0]), float(a[1]), float(a[2])))
		elif v is float or v is int:
			m.set_shader_parameter(str(k), float(v))


# ---------- giving it back ----------

func restore() -> void:
	Engine.set_meta(&"pax_corpinc3d_zones", false)   # the zones are drawn by Pax Corporations again
	_zones_on = false
	if is_instance_valid(_mat) and _orig_shader != null and _mat.shader == _shader:
		_mat.shader = _orig_shader
	if is_instance_valid(_mat) and _orig_albedo != null:
		_mat.set_shader_parameter("map_albedo", _orig_albedo)
	_orig_albedo = null
	if is_instance_valid(_node) and _orig_mesh != null:
		_node.mesh = _orig_mesh
	if is_instance_valid(_cloud):
		_cloud.queue_free()
	for g in _game_clouds:
		if is_instance_valid(g):
			(g as Node3D).visible = true
	_game_clouds = []
	if is_instance_valid(_air):
		_air.queue_free()
	if is_instance_valid(_terrain):
		_terrain.queue_free()
	_terrain = null
	_mat = null
	_orig_shader = null
	_node = null
	_orig_mesh = null
	_cloud = null
	_cloud_mat = null
	_air = null
