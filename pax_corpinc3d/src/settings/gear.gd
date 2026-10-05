extends CanvasLayer
## The gear at the bottom left, above the game's chronicle (Pax Corpface publishes where it is: meta «pax_feed_rect»):
## it opens and closes the «3D» settings (panel_3d.gd) in a window of its own just above it. It was a button of the
## game's bottom bar among the others — the player did not find it there.

const GameApi := preload("res://mods/pax_corpinc3d/src/shared/game_api.gd")
const Panel3D := preload("res://mods/pax_corpinc3d/src/settings/panel_3d.gd")

var mod: PaxMod
var game: PaxGame
var _btn: Button
var _panel: PanelContainer
var _tick := 0.0


func setup(m: PaxMod) -> void:
	mod = m
	name = "PaxCorpInc3DGear"
	layer = 6                         # over the game's HUD, with the globe's layers window
	process_mode = Node.PROCESS_MODE_ALWAYS
	_btn = Button.new()
	_btn.name = "PaxCorpInc3DGearButton"
	_btn.icon = GameApi.picture(m, "textures/ui/gear.svg", 0.5)
	_btn.expand_icon = true
	_btn.custom_minimum_size = Vector2(30, 28)
	_btn.size = Vector2(30, 28)
	_btn.focus_mode = Control.FOCUS_NONE
	_btn.tooltip_text = m.tr_key("pax_corpinc3d_button")
	_btn.visible = false
	_btn.pressed.connect(toggle)
	add_child(_btn)
	_panel = PanelContainer.new()
	_panel.name = "PaxCorpInc3DSettingsWindow"
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.11, 0.95)
	sb.border_color = Color(0.35, 0.5, 0.65, 0.6)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var v := VBoxContainer.new()
	_panel.add_child(v)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.size_flags_horizontal = Control.SIZE_SHRINK_END
	close.pressed.connect(func() -> void: _panel.visible = false)
	v.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(480, 0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	var p := Panel3D.new()
	p.mod = m
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(p)


func start(g: PaxGame) -> void:
	game = g
	_btn.visible = true
	_place()


func toggle() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_place()


func _process(delta: float) -> void:
	_tick -= delta
	if _tick > 0.0 or game == null:
		return
	_tick = 0.25
	_place()


## Above the chronicle: its box (shown) or Corpface's toggle (hidden); without Corpface the game's feed, else the corner.
func _place() -> void:
	if not is_inside_tree():
		return
	var view := get_viewport().get_visible_rect().size
	var at := Vector2(12.0, view.y - 70.0)
	var r := Rect2()
	if Engine.has_meta(&"pax_feed_rect") and Engine.get_meta(&"pax_feed_rect") is Rect2:
		r = Engine.get_meta(&"pax_feed_rect")
	elif game != null and is_instance_valid(game.main):
		var feed: Variant = game.main.get("лента_хроники")
		if feed is Control and is_instance_valid(feed) and (feed as Control).is_visible_in_tree():
			r = (feed as Control).get_global_rect()
	if r.size != Vector2.ZERO:
		at = Vector2(r.position.x, r.position.y - _btn.size.y - 6.0)
	at = at.clamp(Vector2.ZERO, (view - _btn.size).max(Vector2.ZERO))
	_btn.position = at
	if _panel.visible:
		var room := maxf(240.0, at.y - 80.0)   # from under the header down to the gear
		var want := _panel.get_combined_minimum_size()
		var body := (_panel.get_child(0) as Control).get_child(1) as ScrollContainer
		var inner := (body.get_child(0) as Control).get_combined_minimum_size().y + 50.0
		var sz := Vector2(want.x, minf(inner, room))
		_panel.size = sz
		_panel.position = Vector2(clampf(at.x, 0.0, maxf(view.x - sz.x, 0.0)), maxf(0.0, at.y - sz.y - 6.0))
