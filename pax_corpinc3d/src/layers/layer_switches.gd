extends CanvasLayer
## «Слои глобуса»: every layer of the 3D Earth switched on and off in one window of its own — the game's layers
## (the networks, the armies, battles, the front, bases, trade, air routes, extraction sites, the indicators, marks)
## and ours (the companies' buildings, the cities, landmarks, satellites, clouds, the air's glow, the political fill,
## the economic zones, the cities' names). Kept in the setting «globe_layers» ({key: bool}), the same in every game.
## It does not depend on the flat map's «Слои» window any more: in game 0.24 that window and its table were often
## missing or renamed, and with them the rails, the power lines and the armies were gone from the globe.
## Tab over the globe opens and closes it (globe_layers.gd catches Tab); the «3D» window has a button too.
## Who reads the switches: globe_layers.gd (what it draws, the roads' mask, the 3D armies and ships), apply() (our 3D
## parts: earth.gd, globe.gd, satellites.gd).

## [group, [[key, default]…]] — the order of the window.
const GROUPS := [
	["nets", [["roads", true], ["rail", true], ["power", true], ["comms", false]]],
	["war", [["armies", true], ["armies3d", true], ["battles", true], ["front", false], ["bases", false]]],
	["trade", [["trade", true], ["flights", true], ["ships", true]]],
	["economy", [["sites", true], ["health", false], ["education", false], ["safety", false], ["corruption", false],
		["comms_icons", false], ["power_icons", false]]],
	["map", [["political", false], ["zones", true], ["labels", true], ["marks", true]]],
	["objects", [["buildings", true], ["towns", true], ["landmarks", true], ["trees", true], ["satellites", true],
		["clouds", true], ["air_glow", true]]],
]
## The game's indicator icons (globe_layers ICONS) by our key.
const ICON_KEYS := {"health": "здоровье", "education": "образование", "safety": "безопасность", "corruption": "коррупция",
	"comms_icons": "сеть", "power_icons": "ток"}

var mod: PaxMod
var on: Dictionary = {}              # key -> bool
var _panel: PanelContainer
var _boxes: Dictionary = {}          # key -> CheckBox
var _apply_t := 0.0


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DLayerSwitches"
	layer = 6                         # over the 3D view and the game's HUD bar, under its dialogs
	process_mode = Node.PROCESS_MODE_ALWAYS
	var saved: Variant = m.get_setting("globe_layers", {})
	var sd: Dictionary = saved if saved is Dictionary else {}
	for g in GROUPS:
		for pair in (g as Array)[1]:
			var k := str((pair as Array)[0])
			on[k] = bool(sd.get(k, (pair as Array)[1]))
	# The settings that lived elsewhere before: the cities' names, the air's glow.
	if not sd.has("labels"):
		on["labels"] = bool(m.get_setting("city_labels", true))
	if not sd.has("air_glow"):
		on["air_glow"] = bool(m.get_setting("air_glow", true))
	_build()


func is_on(key: String) -> bool:
	return bool(on.get(key, false))


func set_on(key: String, value: bool) -> void:
	on[key] = value
	mod.set_setting("globe_layers", on.duplicate())
	if key == "labels":
		mod.set_setting("city_labels", value)
	if _boxes.has(key) and (_boxes[key] as CheckBox).button_pressed != value:
		(_boxes[key] as CheckBox).set_pressed_no_signal(value)
	apply(true)


## The networks' bits for roads3d.gd: 1 roads, 2 rails, 4 communications, 8 power.
func nets_mask() -> int:
	return (1 if is_on("roads") else 0) | (2 if is_on("rail") else 0) | (4 if is_on("comms") else 0) | (8 if is_on("power") else 0)


## The game's indicator icons switched on (their names in globe_layers ICONS).
func icon_names() -> Array:
	var out: Array = []
	for k in ICON_KEYS:
		if is_on(str(k)):
			out.append(ICON_KEYS[k])
	return out


func toggle_window() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_place()


func window_shown() -> bool:
	return is_instance_valid(_panel) and _panel.visible


func hide_window() -> void:
	if is_instance_valid(_panel):
		_panel.visible = false


func _process(delta: float) -> void:
	_apply_t -= delta
	if _apply_t <= 0.0:
		_apply_t = 0.25
		apply(false)


## Our 3D parts by the switches (the parts set some of their own visibility every frame — so again 4 times a second).
func apply(now: bool) -> void:
	var earth: Variant = mod.get("earth")
	if earth is Object and is_instance_valid(earth):
		var e: Object = earth
		if bool(e.get("political")) != is_on("political") and e.has_method("set_political"):
			e.call("set_political", is_on("political"))
		if now and e.has_method("set_air"):
			e.call("set_air", is_on("air_glow"))
		e.set("show_zones", is_on("zones"))
		e.set("show_clouds", is_on("clouds"))
	var globe: Variant = mod.get("globe")
	if globe is Object and is_instance_valid(globe):
		var g: Object = globe
		g.set("show_companies", is_on("buildings"))
		var towns: Variant = g.get("towns")
		if towns is Node3D and is_instance_valid(towns):
			(towns as Node3D).visible = is_on("towns")
		var lm: Variant = g.get("landmarks")
		if lm is Node3D and is_instance_valid(lm):
			(lm as Node3D).visible = is_on("landmarks")
	var sats: Variant = mod.get("satellites")
	if sats is Object and is_instance_valid(sats):
		(sats as Object).set("shown", is_on("satellites"))


# ---------- the window ----------

func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "PaxCorpInc3DLayersWindow"
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.11, 0.94)
	sb.border_color = Color(0.35, 0.5, 0.65, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_panel.add_child(v)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.mouse_default_cursor_shape = Control.CURSOR_MOVE
	head.gui_input.connect(_drag)
	v.add_child(head)
	var title := Label.new()
	title.text = mod.tr_key("pax_corpinc3d_lw_title")
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(hide_window)
	head.add_child(close)
	var hint := Label.new()
	hint.text = mod.tr_key("pax_corpinc3d_lw_hint")
	hint.modulate = Color(1, 1, 1, 0.6)
	hint.add_theme_font_size_override("font_size", 11)
	v.add_child(hint)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 18)
	v.add_child(cols)
	var col_a := VBoxContainer.new()
	var col_b := VBoxContainer.new()
	cols.add_child(col_a)
	cols.add_child(col_b)
	var i := 0
	for g in GROUPS:
		var col := col_a if i < 3 else col_b
		i += 1
		var gl := Label.new()
		gl.text = mod.tr_key("pax_corpinc3d_lw_g_" + str((g as Array)[0]))
		gl.add_theme_font_size_override("font_size", 13)
		gl.modulate = Color(0.75, 0.88, 1.0)
		col.add_child(gl)
		for pair in (g as Array)[1]:
			var k := str((pair as Array)[0])
			var cb := CheckBox.new()
			cb.text = mod.tr_key("pax_corpinc3d_lw_" + k)
			cb.focus_mode = Control.FOCUS_NONE
			cb.button_pressed = is_on(k)
			cb.toggled.connect(func(value: bool) -> void: set_on(k, value))
			col.add_child(cb)
			_boxes[k] = cb
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var all_on := Button.new()
	all_on.text = mod.tr_key("pax_corpinc3d_lw_all_on")
	all_on.focus_mode = Control.FOCUS_NONE
	all_on.pressed.connect(func() -> void: _set_all(true))
	row.add_child(all_on)
	var all_off := Button.new()
	all_off.text = mod.tr_key("pax_corpinc3d_lw_all_off")
	all_off.focus_mode = Control.FOCUS_NONE
	all_off.pressed.connect(func() -> void: _set_all(false))
	row.add_child(all_off)


## Dragged by its title like the game's windows.
var _drag_from := Vector2.INF


func _drag(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag_from = (e as InputEventMouseButton).global_position - _panel.position if (e as InputEventMouseButton).pressed else Vector2.INF
	elif e is InputEventMouseMotion and _drag_from != Vector2.INF:
		var view := get_viewport().get_visible_rect().size
		var p := (e as InputEventMouseMotion).global_position - _drag_from
		_panel.position = p.clamp(Vector2.ZERO, (view - _panel.size).max(Vector2.ZERO))


func _set_all(value: bool) -> void:
	for k in on.keys():
		on[k] = value
		if _boxes.has(k):
			(_boxes[k] as CheckBox).set_pressed_no_signal(value)
	mod.set_setting("globe_layers", on.duplicate())
	mod.set_setting("city_labels", value)
	apply(true)


## Right of Pax Corpface's column and under its header (meta pax_hud_rect), else at the top left.
func _place() -> void:
	var view := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1920, 1080)
	var at := Vector2(12, 120)
	if Engine.has_meta(&"pax_hud_rect"):
		var hud: Variant = Engine.get_meta(&"pax_hud_rect")
		if hud is Rect2:
			at = (hud as Rect2).position + Vector2(10, 10)
	var sz := _panel.get_combined_minimum_size()
	_panel.position = Vector2(clampf(at.x, 0.0, maxf(view.x - sz.x, 0.0)), clampf(at.y, 0.0, maxf(view.y - sz.y, 0.0)))
