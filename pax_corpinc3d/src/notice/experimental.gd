extends Node
## A warning at the start of a game: a picture of the new 3D Earth and what it costs — the mod is experimental, heavy
## on the computer, crashes and damaged saves are possible, play at your own risk. Shown only when the «What's new»
## window (src/shared/whatsnew.gd, shared by the author's mods) is not open, so the two never stack; «Don't show
## again» in the bottom left keeps it closed for good (setting «warning_hidden»).

const WHATSNEW_WIN := &"pax_whatsnew_window"

var mod: PaxMod
var game: PaxGame
var _wait := 0.0
var _shown := false
var _panel: Control


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DExperimental"
	process_mode = Node.PROCESS_MODE_ALWAYS


## A new game or a loaded save: shown again once (unless hidden for good), after «What's new» had its turn.
func start(g: PaxGame) -> void:
	game = g
	_shown = false
	_wait = 4.5
	_close()


func _process(delta: float) -> void:
	if _shown or game == null or bool(mod.get_setting("warning_hidden", false)):
		return
	_wait -= delta
	if _wait > 0.0 or _whatsnew_open():
		return
	_shown = true
	_open()


static func _whatsnew_open() -> bool:
	if not Engine.has_meta(WHATSNEW_WIN):
		return false
	var o: Variant = Engine.get_meta(WHATSNEW_WIN)
	return o is Object and is_instance_valid(o) and bool((o as Object).call("owns_window"))


func _open() -> void:
	var hud := game.hud_layer() as CanvasLayer
	if hud == null:
		return
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.add_child(center)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.97)
	sb.border_color = Color(0.91, 0.72, 0.36, 0.75)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(620, 0)
	panel.add_child(col)
	var title := Label.new()
	title.text = mod.tr_key("pax_corpinc3d_warn_title")
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(0.95, 0.8, 0.45))
	col.add_child(title)
	var tex := mod.texture("textures/ui/earth_preview.jpg")
	if tex != null:
		var pic := TextureRect.new()
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		pic.custom_minimum_size = Vector2(620, 349)
		col.add_child(pic)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.custom_minimum_size = Vector2(620, 0)
	text.text = mod.tr_key("pax_corpinc3d_warn_text")
	col.add_child(text)
	var row := HBoxContainer.new()
	var never := CheckBox.new()
	never.text = mod.tr_key("pax_corpinc3d_warn_never")
	never.focus_mode = Control.FOCUS_NONE
	row.add_child(never)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	var ok := Button.new()
	ok.text = mod.tr_key("pax_corpinc3d_warn_ok")
	ok.custom_minimum_size = Vector2(150, 34)
	ok.pressed.connect(func() -> void:
		if never.button_pressed:
			mod.set_setting("warning_hidden", true)
		_close())
	row.add_child(ok)
	col.add_child(row)
	hud.add_child(shade)
	_panel = shade


func _close() -> void:
	if is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
