extends VBoxContainer
## The window «3D» — the settings of Pax CorpInc3D: the quality mode (off · eco · normal · max · custom), its options
## (how many buildings, headquarters only, shadows, hide when far), the automatic step down when the game lags,
## and what it costs now (frames per second, buildings drawn). «?» explains in place.
## Talks to the mod only through its entry points (set_quality, set_option, quality_status).

const MODES := ["off", "eco", "normal", "max", "custom"]

var mod: Node
var _mode: OptionButton
var _mode_text: Label
var _limit: SpinBox
var _hq: CheckBox
var _shadows: CheckBox
var _far: SpinBox
var _auto: CheckBox
var _auto_fps: SpinBox
var _now: Label
var _custom: VBoxContainer
var _filling := false
var _tick := 0.0


func _t(key: String) -> String:
	return str(mod.call("tr_key", "pax_corpinc3d_" + key))


func _ready() -> void:
	name = "PaxCorpInc3DPanel"
	custom_minimum_size = Vector2(460, 0)
	add_theme_constant_override("separation", 8)
	var head := HBoxContainer.new()
	add_child(head)
	var title := Label.new()
	title.text = _t("title")
	title.add_theme_font_size_override("font_size", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var help := Button.new()
	help.text = "?"
	help.tooltip_text = _t("help_tip")
	help.focus_mode = Control.FOCUS_NONE
	help.custom_minimum_size = Vector2(30, 26)
	head.add_child(help)
	var how := _note(_t("help"), 0.7)
	how.visible = false
	add_child(how)
	help.pressed.connect(func() -> void: how.visible = not how.visible)

	# The mode.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	add_child(row)
	row.add_child(_label(_t("q_label")))
	_mode = OptionButton.new()
	for m in MODES:
		_mode.add_item(_t("q_" + m))
	_mode.focus_mode = Control.FOCUS_NONE
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode.item_selected.connect(func(i: int) -> void:
		if not _filling and MODES[i] != "custom":
			mod.call("set_quality", MODES[i])
		_fill())
	row.add_child(_mode)
	_mode_text = _note("", 0.65)
	add_child(_mode_text)

	# The options (changing one makes the mode «custom»).
	_custom = VBoxContainer.new()
	_custom.add_theme_constant_override("separation", 6)
	add_child(_custom)
	_limit = _spin(0, 20000, 50)
	_option_row(_t("o_limit"), _t("o_limit_tip"), _limit)
	_limit.value_changed.connect(func(v: float) -> void: _set_option("limit", int(v)))
	_hq = _check(_t("o_hq"), _t("o_hq_tip"))
	_hq.toggled.connect(func(v: bool) -> void: _set_option("hq_only", v))
	_shadows = _check(_t("o_shadows"), _t("o_shadows_tip"))
	_shadows.toggled.connect(func(v: bool) -> void: _set_option("shadows", v))
	_far = _spin(0, 20, 0.5)
	_option_row(_t("o_far"), _t("o_far_tip"), _far)
	_far.value_changed.connect(func(v: float) -> void: _set_option("hide_far", v))

	add_child(HSeparator.new())
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 8)
	add_child(arow)
	_auto = CheckBox.new()
	_auto.text = _t("o_auto")
	_auto.tooltip_text = _t("o_auto_tip")
	_auto.focus_mode = Control.FOCUS_NONE
	_auto.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_auto.toggled.connect(func(v: bool) -> void: _set_option("auto", v))
	arow.add_child(_auto)
	_auto_fps = _spin(10, 60, 1)
	_auto_fps.suffix = "FPS"
	_auto_fps.value_changed.connect(func(v: float) -> void: _set_option("auto_fps", int(v)))
	arow.add_child(_auto_fps)

	# The air's glow at the planet's rim («the RGB light» to some players): may be switched off.
	var air := CheckBox.new()
	air.text = _t("o_air")
	air.tooltip_text = _t("o_air_tip")
	air.focus_mode = Control.FOCUS_NONE
	air.button_pressed = bool(mod.call("get_setting", "air_glow", true))
	air.toggled.connect(func(v: bool) -> void:
		var sw := _switches()
		if sw != null:
			sw.call("set_on", "air_glow", v)
		else:
			var earth: Variant = mod.get("earth")
			if earth is Object and is_instance_valid(earth):
				(earth as Object).call("set_air", v))
	add_child(air)
	# The mods' buildings and roads off the flat map (core/flat_clean.gd): they are 3D on the globe.
	var flat := CheckBox.new()
	flat.text = _t("o_flat")
	flat.tooltip_text = _t("o_flat_tip")
	flat.focus_mode = Control.FOCUS_NONE
	flat.button_pressed = bool(mod.call("get_setting", "flat_clean", true))
	flat.toggled.connect(func(v: bool) -> void:
		var fc: Variant = mod.get("flat_clean")
		if fc is Object and is_instance_valid(fc):
			(fc as Object).call("set_on", v))
	add_child(flat)
	# Every layer of the globe — the game's and ours — in the «Слои глобуса» window (also Tab over the globe).
	var lw := Button.new()
	lw.text = _t("o_layers")
	lw.tooltip_text = _t("o_layers_tip")
	lw.focus_mode = Control.FOCUS_NONE
	lw.pressed.connect(func() -> void:
		var sw := _switches()
		if sw != null:
			sw.call("toggle_window"))
	add_child(lw)

	_now = _note("", 0.8)
	add_child(_now)
	add_child(_note(_t("needs" if not Engine.has_meta("pax_corporations_api") else "where"), 0.55))
	_fill()


func _switches() -> Object:
	var layers: Variant = mod.get("layers")
	var sw: Variant = (layers as Object).get("switches") if layers is Object and is_instance_valid(layers) else null
	return sw as Object if sw is Object and is_instance_valid(sw) else null


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or not is_visible_in_tree():
		return
	_tick = 0.5
	var st: Dictionary = mod.call("quality_status")
	_now.text = _t("now") % [int(st["fps"]), int(st["count"])] + \
		("" if str(st["last_auto"]).is_empty() else "\n" + _t("now_auto") % str(st["last_auto"]))


## The controls from the settings (without echoing the changes back).
func _fill() -> void:
	var st: Dictionary = mod.call("quality_status")
	_filling = true
	var q := str(st["quality"])
	_mode.select(maxi(0, MODES.find(q)))
	_mode_text.text = _t("q_" + q + "_text")
	_limit.value = int(st["limit"])
	_hq.button_pressed = bool(st["hq_only"])
	_shadows.button_pressed = bool(st["shadows"])
	_far.value = float(st["hide_far"])
	_auto.button_pressed = bool(st["auto"])
	_auto_fps.value = int(st["auto_fps"])
	_custom.modulate.a = 0.45 if q == "off" else 1.0
	_filling = false


func _set_option(key: String, value: Variant) -> void:
	if _filling:
		return
	mod.call("set_option", key, value)
	_fill()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _note(text: String, alpha: float) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(440, 0)
	l.modulate = Color(1, 1, 1, alpha)
	return l


func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(110, 0)
	return s


func _option_row(text: String, tip: String, control: Control) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	var l := _label(text)
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(l)
	control.tooltip_text = tip
	r.add_child(control)
	_custom.add_child(r)


func _check(text: String, tip: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.tooltip_text = tip
	c.focus_mode = Control.FOCUS_NONE
	_custom.add_child(c)
	return c
